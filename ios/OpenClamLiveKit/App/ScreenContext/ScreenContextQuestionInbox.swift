import Foundation

extension Notification.Name {
    static let pendingScreenContextQuestionDidChange = Notification.Name(
        "CodexCompanion.pendingScreenContextQuestionDidChange"
    )
}

struct QueuedScreenContextQuestion: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let question: String
    let createdAt: Date
    let expiresAt: Date
}

enum ScreenContextQuestionError: Error, Equatable, LocalizedError {
    case appGroupUnavailable
    case emptyQuestion
    case questionTooLong
    case storageUnavailable
    case invalidStoredQuestion

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The shared Screen Context container isn't configured for this build."
        case .emptyQuestion:
            "Dictate or enter a question first."
        case .questionTooLong:
            "The screen question is longer than the 2,000-character limit."
        case .storageUnavailable:
            "The screen question could not be stored securely."
        case .invalidStoredQuestion:
            "The pending screen question was invalid or changed and was discarded."
        }
    }
}

/// A one-slot, expiring mailbox shared by the main app and its App Intents process.
///
/// It stores only the person's question. It never stores provider credentials, starts capture, or
/// sends a request. A new explicit Shortcut run replaces the previous unconsumed question.
actor ScreenContextQuestionInbox {
    static let maximumCharacters = 2_000
    static let maximumBytes = 8_000
    static let maximumRecordBytes = 16_000
    static let questionLifetime: TimeInterval = 2 * 60

    let directory: URL

    private let fileManager: FileManager
    private let transactionLock: AppGroupTransactionLock

    init(containerURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        directory = containerURL.appendingPathComponent("ScreenContextQuestions", isDirectory: true)
        transactionLock = AppGroupTransactionLock(directory: directory)
    }

    static func appGroup(fileManager: FileManager = .default) throws -> ScreenContextQuestionInbox {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: ScreenContextInbox.appGroupIdentifier
        ) else {
            throw ScreenContextQuestionError.appGroupUnavailable
        }
        return ScreenContextQuestionInbox(containerURL: containerURL, fileManager: fileManager)
    }

    @discardableResult
    func stage(_ rawQuestion: String, now: Date = Date()) throws -> QueuedScreenContextQuestion {
        let question = try Self.validatedQuestion(rawQuestion)
        let record = QueuedScreenContextQuestion(
            id: UUID(),
            question: question,
            createdAt: now,
            expiresAt: now.addingTimeInterval(Self.questionLifetime)
        )
        do {
            try ensureDirectory()
            try transactionLock.withExclusiveLock {
                try purgePayloads()
                do {
                    let encoded = try JSONEncoder().encode(record)
                    guard (1 ... Self.maximumRecordBytes).contains(encoded.count) else {
                        throw ScreenContextQuestionError.invalidStoredQuestion
                    }
                    let recordURL = self.recordURL(for: record.id)
                    try encoded.write(to: recordURL, options: [.atomic])
                    try protectFile(at: recordURL)
                } catch {
                    try? purgePayloads()
                    throw error
                }
            }
        } catch let error as ScreenContextQuestionError {
            throw error
        } catch {
            throw ScreenContextQuestionError.storageUnavailable
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .pendingScreenContextQuestionDidChange, object: nil)
        }
        return record
    }

    func peek(now: Date = Date()) throws -> QueuedScreenContextQuestion? {
        try load(now: now, consumes: false)
    }

    func take(now: Date = Date()) throws -> QueuedScreenContextQuestion? {
        try load(now: now, consumes: true)
    }

    func discard() throws {
        do {
            try ensureDirectory()
            try transactionLock.withExclusiveLock {
                try purgePayloads()
            }
        } catch {
            throw ScreenContextQuestionError.storageUnavailable
        }
    }

    static func validatedQuestion(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ScreenContextQuestionError.emptyQuestion }
        guard value.count <= maximumCharacters, value.utf8.count <= maximumBytes else {
            throw ScreenContextQuestionError.questionTooLong
        }
        return value
    }

    private func load(now: Date, consumes: Bool) throws -> QueuedScreenContextQuestion? {
        do {
            try ensureDirectory()
            return try transactionLock.withExclusiveLock {
                try loadLocked(now: now, consumes: consumes)
            }
        } catch let error as ScreenContextQuestionError {
            throw error
        } catch {
            throw ScreenContextQuestionError.invalidStoredQuestion
        }
    }

    private func loadLocked(now: Date, consumes: Bool) throws -> QueuedScreenContextQuestion? {
        let payloads = try payloadURLs()
        guard !payloads.isEmpty else { return nil }
        do {
            guard payloads.count == 1, let recordURL = payloads.first else {
                throw ScreenContextQuestionError.invalidStoredQuestion
            }
            let expectedSize = try byteCount(at: recordURL)
            guard (1 ... Self.maximumRecordBytes).contains(expectedSize) else {
                throw ScreenContextQuestionError.invalidStoredQuestion
            }
            let data = try Data(contentsOf: recordURL, options: [.mappedIfSafe])
            guard data.count == expectedSize else {
                throw ScreenContextQuestionError.invalidStoredQuestion
            }
            let record = try JSONDecoder().decode(QueuedScreenContextQuestion.self, from: data)
            guard recordURL.lastPathComponent == "pending-question-\(record.id.uuidString).json" else {
                throw ScreenContextQuestionError.invalidStoredQuestion
            }
            guard record.expiresAt > record.createdAt,
                  record.expiresAt.timeIntervalSince(record.createdAt) <= Self.questionLifetime else {
                throw ScreenContextQuestionError.invalidStoredQuestion
            }
            guard record.expiresAt > now else {
                try purgePayloads()
                return nil
            }
            guard try Self.validatedQuestion(record.question) == record.question else {
                throw ScreenContextQuestionError.invalidStoredQuestion
            }
            if consumes {
                try purgePayloads()
            }
            return record
        } catch let error as ScreenContextQuestionError {
            try? purgePayloads()
            throw error
        } catch {
            try? purgePayloads()
            throw ScreenContextQuestionError.invalidStoredQuestion
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
    }

    private func protectFile(at url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func recordURL(for id: UUID) -> URL {
        directory.appendingPathComponent(
            "pending-question-\(id.uuidString).json",
            isDirectory: false
        )
    }

    private func payloadURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.lastPathComponent != AppGroupTransactionLock.fileName }
    }

    private func purgePayloads() throws {
        for item in try payloadURLs() {
            guard item.deletingLastPathComponent().standardizedFileURL
                == directory.standardizedFileURL else { continue }
            try fileManager.removeItem(at: item)
        }
    }

    private func byteCount(at url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value > 0,
              size.int64Value <= Int64(Int.max) else {
            throw ScreenContextQuestionError.invalidStoredQuestion
        }
        return size.intValue
    }
}
