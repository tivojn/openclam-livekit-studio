import Foundation

enum OpenClamKeyboardWarmEarState {
    static let enabledKey = "keyboard.warmEar.enabled"
    static let readyUntilKey = "keyboard.warmEar.readyUntil"
    static let heartbeatKey = "keyboard.warmEar.heartbeat"
    static let heartbeatTolerance: TimeInterval = 3

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: OpenClamKeyboardHandoffStore.appGroupIdentifier)
    }

    static var isEnabled: Bool {
        defaults?.bool(forKey: enabledKey) ?? false
    }

    static func setEnabled(_ enabled: Bool) {
        defaults?.set(enabled, forKey: enabledKey)
        if !enabled {
            clearReadiness()
        }
    }

    static func isReady(at date: Date = Date()) -> Bool {
        guard let defaults else { return false }
        return isReady(
            enabled: defaults.bool(forKey: enabledKey),
            readyUntil: defaults.double(forKey: readyUntilKey),
            heartbeat: defaults.double(forKey: heartbeatKey),
            at: date
        )
    }

    static func isReady(
        enabled: Bool,
        readyUntil: TimeInterval,
        heartbeat: TimeInterval,
        at date: Date
    ) -> Bool {
        guard enabled, readyUntil > date.timeIntervalSince1970 else { return false }
        let heartbeatAge = date.timeIntervalSince1970 - heartbeat
        return heartbeatAge >= -1 && heartbeatAge <= heartbeatTolerance
    }

    static func markReady(until deadline: Date, heartbeat date: Date = Date()) {
        defaults?.set(deadline.timeIntervalSince1970, forKey: readyUntilKey)
        defaults?.set(date.timeIntervalSince1970, forKey: heartbeatKey)
    }

    static func updateHeartbeat(at date: Date = Date()) {
        guard isEnabled else {
            clearReadiness()
            return
        }
        defaults?.set(date.timeIntervalSince1970, forKey: heartbeatKey)
    }

    static func readyUntil() -> Date? {
        guard let value = defaults?.double(forKey: readyUntilKey), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    static func clearReadiness() {
        defaults?.removeObject(forKey: readyUntilKey)
        defaults?.removeObject(forKey: heartbeatKey)
    }
}

enum OpenClamKeyboardWarmEarSignal {
    static let beginRequestName = "com.lionheart.openclam.livekitpilot.keyboard.begin-request"

    static func postBeginRequest() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(beginRequestName as CFString),
            nil,
            nil,
            true
        )
    }
}

enum OpenClamKeyboardCapability {
    /// Apple does not expose microphone or speaker access to custom keyboard extensions,
    /// including keyboards for which the user grants Full Access.
    static let microphoneAvailableInExtension = false

    /// Full Access gives a keyboard write access to its containing app's App Group. OpenClam
    /// uses that group only for a bounded request and its final transcript.
    static let requiresFullAccessForSharedHandoff = true

    /// `NSExtensionContext.open` isn't supported by the custom-keyboard extension point.
    /// The keyboard leaves a bounded request in the App Group, then the user opens OpenClam.
    static let canLaunchContainingAppFromExtension = false

    /// The app must be visible when a real microphone lease starts. During that bounded lease,
    /// the app may finish one keyboard turn after it moves to the background.
    static let requiresVisibleContainingAppForVoiceInput = false
    static let supportsBoundedForegroundStartedBackgroundCapture = true
}

struct OpenClamKeyboardRequest: Codable, Equatable, Identifiable, Sendable {
    static let maximumAge: TimeInterval = 5 * 60

    let id: UUID
    let createdAt: Date

    func isCurrent(at date: Date) -> Bool {
        let age = date.timeIntervalSince(createdAt)
        return age >= -5 && age <= Self.maximumAge
    }
}

enum OpenClamKeyboardResultState: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
    case failed
}

struct OpenClamKeyboardResult: Codable, Equatable, Sendable {
    let requestID: UUID
    let completedAt: Date
    let state: OpenClamKeyboardResultState
    let transcript: String?
    let message: String?

    static func completed(
        requestID: UUID,
        transcript: String,
        at date: Date = Date()
    ) -> Self {
        .init(
            requestID: requestID,
            completedAt: date,
            state: .completed,
            transcript: transcript,
            message: nil
        )
    }

    static func cancelled(requestID: UUID, at date: Date = Date()) -> Self {
        .init(
            requestID: requestID,
            completedAt: date,
            state: .cancelled,
            transcript: nil,
            message: "Voice input was cancelled."
        )
    }

    static func failed(
        requestID: UUID,
        message: String,
        at date: Date = Date()
    ) -> Self {
        .init(
            requestID: requestID,
            completedAt: date,
            state: .failed,
            transcript: nil,
            message: message
        )
    }
}

enum OpenClamKeyboardHandoffURL {
    static let scheme = "openclam-livekit-pilot"
    static let host = "keyboard-dictation"

    static func make(requestID: UUID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "request", value: requestID.uuidString.lowercased()),
        ]
        precondition(components.url != nil, "Static keyboard handoff URL must be valid")
        return components.url!
    }

    static func isKeyboardHandoff(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == host
    }

    static func requestID(from url: URL) -> UUID? {
        guard isKeyboardHandoff(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let matches = (components.queryItems ?? []).filter { $0.name == "request" }
        guard matches.count == 1,
              let raw = matches.first?.value,
              let id = UUID(uuidString: raw) else { return nil }
        return id
    }
}

enum OpenClamKeyboardInsertionPlan {
    static func text(
        for transcript: String,
        contextBeforeInput: String?
    ) -> String? {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard let previous = contextBeforeInput?.last,
              !previous.isWhitespace,
              let first = cleaned.first,
              !Self.noLeadingSpacePunctuation.contains(first) else {
            return cleaned
        }
        return " " + cleaned
    }

    private static let noLeadingSpacePunctuation = CharacterSet(
        charactersIn: ".,!?;:)]}”’"
    )

}

private extension CharacterSet {
    func contains(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(contains)
    }
}

enum OpenClamKeyboardStoreError: LocalizedError, Equatable {
    case appGroupUnavailable
    case invalidRequest
    case staleRequest
    case mismatchedResult

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "OpenClam Keyboard cannot reach its shared container. Turn on Allow Full Access and try again."
        case .invalidRequest:
            "The keyboard voice request is invalid. Return to the keyboard and try again."
        case .staleRequest:
            "The keyboard voice request expired. Return to the keyboard and start a new one."
        case .mismatchedResult:
            "The keyboard received a transcript for a different request."
        }
    }
}

struct OpenClamKeyboardHandoffStore {
    static let appGroupIdentifier = "group.com.lionheart.openclam.livekitpilot.shared"

    private struct ActivePointer: Codable {
        let requestID: UUID
    }

    private let directory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(containerURL: URL, fileManager: FileManager = .default) {
        directory = containerURL.appendingPathComponent("OpenClamKeyboard", isDirectory: true)
        self.fileManager = fileManager
    }

    static func live(fileManager: FileManager = .default) throws -> Self {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { throw OpenClamKeyboardStoreError.appGroupUnavailable }
        return .init(containerURL: containerURL, fileManager: fileManager)
    }

    @discardableResult
    func beginRequest(at date: Date = Date()) throws -> OpenClamKeyboardRequest {
        try ensureDirectory()
        try removeActiveArtifacts()
        let request = OpenClamKeyboardRequest(id: UUID(), createdAt: date)
        try write(request, to: requestURL(request.id))
        try write(ActivePointer(requestID: request.id), to: activeURL)
        return request
    }

    func activeRequest(at date: Date = Date()) throws -> OpenClamKeyboardRequest? {
        guard let pointer: ActivePointer = try readIfPresent(ActivePointer.self, from: activeURL),
              let request: OpenClamKeyboardRequest = try readIfPresent(
                  OpenClamKeyboardRequest.self,
                  from: requestURL(pointer.requestID)
              ) else { return nil }
        guard request.id == pointer.requestID else {
            throw OpenClamKeyboardStoreError.invalidRequest
        }
        guard request.isCurrent(at: date) else {
            try removeArtifacts(for: request.id, includingActivePointer: true)
            throw OpenClamKeyboardStoreError.staleRequest
        }
        return request
    }

    func request(id: UUID, at date: Date = Date()) throws -> OpenClamKeyboardRequest {
        guard let request: OpenClamKeyboardRequest = try readIfPresent(
            OpenClamKeyboardRequest.self,
            from: requestURL(id)
        ), request.id == id else {
            throw OpenClamKeyboardStoreError.invalidRequest
        }
        guard request.isCurrent(at: date) else {
            try removeArtifacts(for: id, includingActivePointer: true)
            throw OpenClamKeyboardStoreError.staleRequest
        }
        return request
    }

    func write(_ result: OpenClamKeyboardResult, at date: Date = Date()) throws {
        let request = try request(id: result.requestID, at: date)
        guard request.id == result.requestID else {
            throw OpenClamKeyboardStoreError.mismatchedResult
        }
        try write(result, to: resultURL(result.requestID))
    }

    func result(for requestID: UUID) throws -> OpenClamKeyboardResult? {
        try readIfPresent(
            OpenClamKeyboardResult.self,
            from: resultURL(requestID)
        )
    }

    /// Returns and deletes one final result. The transcript never remains in the shared container
    /// after the keyboard has inserted it.
    func takeActiveResult(at date: Date = Date()) throws -> OpenClamKeyboardResult? {
        guard let request = try activeRequest(at: date) else { return nil }
        guard let result: OpenClamKeyboardResult = try readIfPresent(
            OpenClamKeyboardResult.self,
            from: resultURL(request.id)
        ) else { return nil }
        guard result.requestID == request.id else {
            throw OpenClamKeyboardStoreError.mismatchedResult
        }
        try removeArtifacts(for: request.id, includingActivePointer: true)
        return result
    }

    func cancelActiveRequest() throws {
        try removeActiveArtifacts()
    }

    private var activeURL: URL {
        directory.appendingPathComponent("active.json", isDirectory: false)
    }

    private func requestURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("request-\(id.uuidString.lowercased()).json")
    }

    private func resultURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("result-\(id.uuidString.lowercased()).json")
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectory()
        try encoder.encode(value).write(to: url, options: [.atomic])
    }

    private func readIfPresent<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func removeActiveArtifacts() throws {
        guard let pointer: ActivePointer = try readIfPresent(ActivePointer.self, from: activeURL) else {
            return
        }
        try removeArtifacts(for: pointer.requestID, includingActivePointer: true)
    }

    private func removeArtifacts(for id: UUID, includingActivePointer: Bool) throws {
        for url in [requestURL(id), resultURL(id)] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        if includingActivePointer, fileManager.fileExists(atPath: activeURL.path) {
            try fileManager.removeItem(at: activeURL)
        }
    }
}
