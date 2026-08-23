import Foundation

struct ConversationThread: Identifiable, Codable, Equatable, Sendable {
    static let defaultTitle = "New chat"

    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [ConversationMessage]
    var isTitleCustomized: Bool

    init(
        id: UUID = UUID(),
        title: String = ConversationThread.defaultTitle,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        messages: [ConversationMessage] = [],
        isTitleCustomized: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.messages = messages
        self.isTitleCustomized = isTitleCustomized
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case updatedAt
        case messages
        case isTitleCustomized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? Self.defaultTitle
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? Date(timeIntervalSince1970: 0)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        messages = try container.decodeIfPresent([ConversationMessage].self, forKey: .messages) ?? []
        isTitleCustomized = try container.decodeIfPresent(
            Bool.self,
            forKey: .isTitleCustomized
        ) ?? (title != Self.defaultTitle)
    }
}

struct ConversationThreadSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let preview: String
    let updatedAt: Date
    let messageCount: Int
}

struct ConversationHistoryState: Equatable, Sendable {
    let selectedThreadID: UUID?
    let threads: [ConversationThread]

    var selectedThread: ConversationThread? {
        guard let selectedThreadID else { return nil }
        return threads.first { $0.id == selectedThreadID }
    }

    var summaries: [ConversationThreadSummary] {
        threads.map { thread in
            ConversationThreadSummary(
                id: thread.id,
                title: thread.title,
                preview: Self.preview(for: thread),
                updatedAt: thread.updatedAt,
                messageCount: thread.messages.count
            )
        }
    }

    static let empty = ConversationHistoryState(selectedThreadID: nil, threads: [])

    private static func preview(for thread: ConversationThread) -> String {
        thread.messages.reversed().lazy
            .map(\.text)
            .map { $0.replacingOccurrences(of: "\n", with: " ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            .map { String($0.prefix(120)) }
            ?? "No messages yet"
    }
}

enum ConversationHistoryStoreError: Error, Equatable {
    case threadNotFound
    case invalidTitle
    case storageLimitTooSmall
    case malformedArchiveQuarantined(filename: String)
}

extension ConversationHistoryStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .threadNotFound:
            "That chat is no longer available."
        case .invalidTitle:
            "Give this chat a name."
        case .storageLimitTooSmall:
            "Chat history could not fit inside its local storage limit."
        case .malformedArchiveQuarantined(let filename):
            "Chat history was damaged, so OpenClam preserved it as \(filename) and started a recoverable empty history."
        }
    }
}

/// A bounded, device-local transcript store. It persists rendered text and safe attachment
/// descriptors only; staged files, data URLs, provider payloads, and Keychain values never enter
/// its archive.
actor ConversationHistoryStore {
    enum IOOperation: Equatable, Sendable {
        case read
        case persist
        case quarantine
    }

    typealias FailureInjector = @Sendable (IOOperation) throws -> Void

    struct Limits: Equatable, Sendable {
        static let standard = Limits()

        var maximumThreads = 100
        var maximumMessagesPerThread = 250
        var maximumMessageCharacters = 24_000
        var maximumTitleCharacters = 80
        var maximumAttachmentsPerMessage = 8
        var maximumArchiveBytes = 5_000_000

        var isValid: Bool {
            (1 ... 500).contains(maximumThreads)
                && (1 ... 2_000).contains(maximumMessagesPerThread)
                && (1_000 ... 100_000).contains(maximumMessageCharacters)
                && (20 ... 200).contains(maximumTitleCharacters)
                && (1 ... 20).contains(maximumAttachmentsPerMessage)
                && (100_000 ... 50_000_000).contains(maximumArchiveBytes)
        }
    }

    static let archiveFilename = "conversation-history-v1.json"

    let fileURL: URL
    let limits: Limits

    private let fileManager: FileManager
    private let failureInjector: FailureInjector
    private var cachedArchive: Archive?
    private var recoveryWarning: ConversationHistoryStoreError?

    init(
        fileURL: URL = ConversationHistoryStore.defaultFileURL(),
        limits: Limits = .standard,
        fileManager: FileManager = .default,
        failureInjector: @escaping FailureInjector = { _ in }
    ) {
        self.fileURL = fileURL
        self.limits = limits
        self.fileManager = fileManager
        self.failureInjector = failureInjector
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent("OpenClam", isDirectory: true)
            .appendingPathComponent(archiveFilename, isDirectory: false)
    }

    /// Loads history once and recovers a malformed archive as an empty local history.
    func load() throws -> ConversationHistoryState {
        try state(from: loadArchiveIfNeeded())
    }

    /// Returns a non-fatal recovery warning once. A successful load can still surface that a
    /// confirmed malformed archive was quarantined rather than silently discarded.
    func takeRecoveryWarning() -> ConversationHistoryStoreError? {
        defer { recoveryWarning = nil }
        return recoveryWarning
    }

    /// Ensures there is a selected chat, preserving stable IDs on later launches.
    @discardableResult
    func bootstrap(
        initialMessages: [ConversationMessage] = [],
        now: Date = Date()
    ) throws -> ConversationHistoryState {
        var archive = try loadArchiveIfNeeded()
        guard archive.threads.isEmpty else {
            if archive.selectedThreadID == nil
                || !archive.threads.contains(where: { $0.id == archive.selectedThreadID }) {
                archive.selectedThreadID = sortedThreads(archive.threads).first?.id
                return try persistAndReturn(archive)
            }
            return state(from: archive)
        }
        let thread = makeThread(title: nil, initialMessages: initialMessages, now: now)
        archive.threads = [thread]
        archive.selectedThreadID = thread.id
        return try persistAndReturn(archive)
    }

    @discardableResult
    func createThread(
        title: String? = nil,
        initialMessages: [ConversationMessage] = [],
        now: Date = Date()
    ) throws -> ConversationHistoryState {
        var archive = try loadArchiveIfNeeded()
        let thread = makeThread(title: title, initialMessages: initialMessages, now: now)
        archive.threads.append(thread)
        archive.selectedThreadID = thread.id
        return try persistAndReturn(archive)
    }

    @discardableResult
    func selectThread(id: UUID) throws -> ConversationHistoryState {
        var archive = try loadArchiveIfNeeded()
        guard archive.threads.contains(where: { $0.id == id }) else {
            throw ConversationHistoryStoreError.threadNotFound
        }
        archive.selectedThreadID = id
        return try persistAndReturn(archive)
    }

    @discardableResult
    func append(
        _ message: ConversationMessage,
        to threadID: UUID,
        now: Date = Date()
    ) throws -> ConversationHistoryState {
        var archive = try loadArchiveIfNeeded()
        guard let index = archive.threads.firstIndex(where: { $0.id == threadID }) else {
            throw ConversationHistoryStoreError.threadNotFound
        }
        if let safeMessage = sanitized(message) {
            archive.threads[index].messages.append(safeMessage)
            updateAutomaticTitle(&archive.threads[index])
        }
        archive.threads[index].updatedAt = now
        archive.selectedThreadID = threadID
        return try persistAndReturn(archive)
    }

    /// ConversationModel integration point: save its current rendered transcript after a turn.
    @discardableResult
    func replaceMessages(
        _ messages: [ConversationMessage],
        in threadID: UUID,
        now: Date = Date()
    ) throws -> ConversationHistoryState {
        var archive = try loadArchiveIfNeeded()
        guard let index = archive.threads.firstIndex(where: { $0.id == threadID }) else {
            throw ConversationHistoryStoreError.threadNotFound
        }
        archive.threads[index].messages = messages.compactMap(sanitized)
        archive.threads[index].updatedAt = now
        updateAutomaticTitle(&archive.threads[index])
        archive.selectedThreadID = threadID
        return try persistAndReturn(archive)
    }

    @discardableResult
    func renameThread(
        id: UUID,
        title rawTitle: String,
        now: Date = Date()
    ) throws -> ConversationHistoryState {
        let title = normalizedTitle(rawTitle)
        guard !title.isEmpty else { throw ConversationHistoryStoreError.invalidTitle }
        var archive = try loadArchiveIfNeeded()
        guard let index = archive.threads.firstIndex(where: { $0.id == id }) else {
            throw ConversationHistoryStoreError.threadNotFound
        }
        archive.threads[index].title = title
        archive.threads[index].isTitleCustomized = true
        archive.threads[index].updatedAt = now
        return try persistAndReturn(archive)
    }

    @discardableResult
    func deleteThread(
        id: UUID,
        replacementMessages: [ConversationMessage]? = nil,
        now: Date = Date()
    ) throws -> ConversationHistoryState {
        var archive = try loadArchiveIfNeeded()
        guard archive.threads.contains(where: { $0.id == id }) else {
            throw ConversationHistoryStoreError.threadNotFound
        }
        archive.threads.removeAll { $0.id == id }
        if archive.selectedThreadID == id {
            archive.selectedThreadID = sortedThreads(archive.threads).first?.id
        }
        if archive.threads.isEmpty, let replacementMessages {
            let replacement = makeThread(
                title: nil,
                initialMessages: replacementMessages,
                now: now
            )
            archive.threads = [replacement]
            archive.selectedThreadID = replacement.id
        }
        return try persistAndReturn(archive)
    }

    private struct Archive: Codable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var selectedThreadID: UUID?
        var threads: [ConversationThread]

        init(
            schemaVersion: Int = currentSchemaVersion,
            selectedThreadID: UUID? = nil,
            threads: [ConversationThread] = []
        ) {
            self.schemaVersion = schemaVersion
            self.selectedThreadID = selectedThreadID
            self.threads = threads
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case selectedThreadID
            case threads
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            selectedThreadID = try container.decodeIfPresent(UUID.self, forKey: .selectedThreadID)
            threads = try container.decodeIfPresent([ConversationThread].self, forKey: .threads) ?? []
        }
    }

    private func loadArchiveIfNeeded() throws -> Archive {
        guard limits.isValid else { throw ConversationHistoryStoreError.storageLimitTooSmall }
        if let cachedArchive { return cachedArchive }

        let data: Data
        do {
            try failureInjector(.read)
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let empty = Archive()
            cachedArchive = empty
            return empty
        } catch {
            // Protection, coordination, and ordinary I/O failures are not proof of corruption.
            // Preserve the original archive and let the caller retry after surfacing the error.
            throw error
        }

        do {
            var archive = try JSONDecoder().decode(Archive.self, from: data)
            archive = normalized(archive)
            cachedArchive = archive
            return archive
        } catch {
            // The bytes were readable but not a valid archive. Preserve them for recovery rather
            // than deleting them or overwriting them with a fresh archive.
            let quarantineURL = quarantineURLForMalformedArchive()
            try failureInjector(.quarantine)
            try fileManager.moveItem(at: fileURL, to: quarantineURL)
            recoveryWarning = .malformedArchiveQuarantined(
                filename: quarantineURL.lastPathComponent
            )
            let empty = Archive()
            cachedArchive = empty
            return empty
        }
    }

    private func persistAndReturn(_ proposedArchive: Archive) throws -> ConversationHistoryState {
        let archive = try prunedToEncodedLimit(normalized(proposedArchive))
        let data = try encoded(archive)
        let directory = fileURL.deletingLastPathComponent()
        try failureInjector(.persist)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        cachedArchive = archive
        return state(from: archive)
    }

    private func quarantineURLForMalformedArchive() -> URL {
        let filename = "\(fileURL.lastPathComponent).corrupt-\(UUID().uuidString)"
        return fileURL.deletingLastPathComponent().appendingPathComponent(filename)
    }

    private func state(from archive: Archive) -> ConversationHistoryState {
        ConversationHistoryState(
            selectedThreadID: archive.selectedThreadID,
            threads: sortedThreads(archive.threads)
        )
    }

    private func normalized(_ archive: Archive) -> Archive {
        var seen = Set<UUID>()
        var threads = archive.threads.compactMap { source -> ConversationThread? in
            guard seen.insert(source.id).inserted else { return nil }
            var thread = source
            thread.title = normalizedTitle(thread.title)
            if thread.title.isEmpty { thread.title = ConversationThread.defaultTitle }
            thread.messages = Array(
                thread.messages
                    .compactMap(sanitized)
                    .suffix(limits.maximumMessagesPerThread)
            )
            if thread.updatedAt < thread.createdAt { thread.updatedAt = thread.createdAt }
            updateAutomaticTitle(&thread)
            return thread
        }
        threads = Array(sortedThreads(threads).prefix(limits.maximumThreads))
        let selectedID = threads.contains(where: { $0.id == archive.selectedThreadID })
            ? archive.selectedThreadID
            : threads.first?.id
        return Archive(selectedThreadID: selectedID, threads: threads)
    }

    private func prunedToEncodedLimit(_ source: Archive) throws -> Archive {
        var archive = source
        while try encoded(archive).count > limits.maximumArchiveBytes {
            guard let oldestIndex = archive.threads.indices.last else {
                throw ConversationHistoryStoreError.storageLimitTooSmall
            }
            if archive.threads[oldestIndex].messages.count > 1 {
                archive.threads[oldestIndex].messages.removeFirst()
            } else if archive.threads.count > 1 {
                let removedID = archive.threads.remove(at: oldestIndex).id
                if archive.selectedThreadID == removedID {
                    archive.selectedThreadID = archive.threads.first?.id
                }
            } else if !archive.threads[oldestIndex].messages.isEmpty {
                archive.threads[oldestIndex].messages.removeFirst()
            } else {
                throw ConversationHistoryStoreError.storageLimitTooSmall
            }
        }
        return archive
    }

    private func encoded(_ archive: Archive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    private func sortedThreads(_ threads: [ConversationThread]) -> [ConversationThread] {
        threads.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func makeThread(
        title rawTitle: String?,
        initialMessages: [ConversationMessage],
        now: Date
    ) -> ConversationThread {
        let requestedTitle = rawTitle.map(normalizedTitle) ?? ""
        var thread = ConversationThread(
            title: requestedTitle.isEmpty ? ConversationThread.defaultTitle : requestedTitle,
            createdAt: now,
            messages: initialMessages.compactMap(sanitized),
            isTitleCustomized: !requestedTitle.isEmpty
        )
        updateAutomaticTitle(&thread)
        return thread
    }

    private func updateAutomaticTitle(_ thread: inout ConversationThread) {
        guard !thread.isTitleCustomized,
              let firstUserText = thread.messages.first(where: { $0.role == .user })?.text else {
            return
        }
        let candidate = firstUserText
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if !candidate.isEmpty {
            thread.title = normalizedTitle(candidate)
        }
    }

    private func normalizedTitle(_ rawTitle: String) -> String {
        let singleLine = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(singleLine.prefix(limits.maximumTitleCharacters))
    }

    private func sanitized(_ message: ConversationMessage) -> ConversationMessage? {
        guard message.historyPersistence == .history else { return nil }
        return ConversationMessage(
            id: message.id,
            role: message.role,
            text: sanitizedText(message.text),
            attachments: Array(
                message.attachments
                    .prefix(limits.maximumAttachmentsPerMessage)
                    .map(sanitized)
            ),
            workSteps: Array(
                message.workSteps
                    .compactMap { try? $0.validated() }
                    .prefix(12)
            ),
            date: message.date,
            isEligibleForAIContext: message.isEligibleForAIContext,
            historyPersistence: .history
        )
    }

    private func sanitized(_ attachment: ConversationAttachmentDescriptor) -> ConversationAttachmentDescriptor {
        let pathSafeName = attachment.displayName
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = String((pathSafeName?.isEmpty == false ? pathSafeName! : "Attachment").prefix(160))
        let mimeType = attachment.mimeType.flatMap { candidate -> String? in
            let value = String(candidate.prefix(100)).lowercased()
            let pattern = #"^[a-z0-9.+-]+/[a-z0-9.+-]+$"#
            return value.range(of: pattern, options: .regularExpression) == nil ? nil : value
        }
        let byteCount = attachment.sourceByteCount.flatMap { $0 >= 0 ? $0 : nil }
        let connectorArtifact = attachment.connectorArtifact.flatMap {
            try? $0.validated()
        }
        return ConversationAttachmentDescriptor(
            id: attachment.id,
            kind: attachment.kind,
            displayName: displayName,
            mimeType: mimeType,
            sourceByteCount: byteCount,
            connectorArtifact: connectorArtifact
        )
    }

    private func sanitizedText(_ rawText: String) -> String {
        var text = String(rawText.prefix(limits.maximumMessageCharacters))
        let replacements: [(String, String)] = [
            (#"(?i)data:[a-z0-9.+-]+/[a-z0-9.+-]+;base64,[a-z0-9+/=\r\n]+"#, "[binary attachment omitted]"),
            (#"(?i)\bBearer\s+[a-z0-9._~+/=-]{12,}"#, "Bearer [redacted]"),
            (#"(?i)(\b(?:api[-_ ]?key|authorization|access[-_ ]?token|secret)\b\s*[\"']?\s*[:=]\s*[\"']?)([^\s,\"'}]+)"#, "$1[redacted]"),
            (#"\b(?:sk|xai|tvly|brv|exa)[-_][A-Za-z0-9_-]{12,}\b"#, "[credential redacted]"),
            (#"(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{256,}={0,2}(?![A-Za-z0-9+/=])"#, "[binary data omitted]"),
        ]
        for (pattern, replacement) in replacements {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            text = expression.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: replacement
            )
        }
        return text
    }
}
