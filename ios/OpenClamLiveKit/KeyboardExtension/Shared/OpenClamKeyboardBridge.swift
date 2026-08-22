import Darwin
import Foundation

enum OpenClamKeyboardWarmEarState {
    static let enabledKey = "keyboard.warmEar.enabled"
    private static let legacyReadyUntilKey = "keyboard.warmEar.readyUntil"
    static let heartbeatKey = "keyboard.warmEar.heartbeat"
    static let listeningRequestIDKey = "keyboard.warmEar.listeningRequestID"
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
            heartbeat: defaults.double(forKey: heartbeatKey),
            at: date
        )
    }

    static func isReady(
        enabled: Bool,
        heartbeat: TimeInterval,
        at date: Date
    ) -> Bool {
        guard enabled else { return false }
        let heartbeatAge = date.timeIntervalSince1970 - heartbeat
        return heartbeatAge >= -1 && heartbeatAge <= heartbeatTolerance
    }

    static func markReady(heartbeat date: Date = Date()) {
        defaults?.set(date.timeIntervalSince1970, forKey: heartbeatKey)
    }

    static func updateHeartbeat(at date: Date = Date()) {
        guard isEnabled else {
            clearReadiness()
            return
        }
        defaults?.set(date.timeIntervalSince1970, forKey: heartbeatKey)
    }

    static func clearReadiness() {
        defaults?.removeObject(forKey: legacyReadyUntilKey)
        defaults?.removeObject(forKey: heartbeatKey)
        defaults?.removeObject(forKey: listeningRequestIDKey)
    }

    static func markListening(requestID: UUID) {
        defaults?.set(requestID.uuidString.lowercased(), forKey: listeningRequestIDKey)
    }

    static func isListening(requestID: UUID) -> Bool {
        defaults?.string(forKey: listeningRequestIDKey)
            == requestID.uuidString.lowercased()
    }

    static func clearListening(requestID: UUID? = nil) {
        if let requestID,
           defaults?.string(forKey: listeningRequestIDKey)
            != requestID.uuidString.lowercased() {
            return
        }
        defaults?.removeObject(forKey: listeningRequestIDKey)
    }
}

enum OpenClamKeyboardWarmEarSignal {
    static let beginRequestName = "com.lionheart.openclam.livekitpilot.keyboard.begin-request"
    static let cancelRequestName = "com.lionheart.openclam.livekitpilot.keyboard.cancel-request"

    static func postBeginRequest() {
        post(name: beginRequestName)
    }

    static func postCancelRequest() {
        post(name: cancelRequestName)
    }

    private static func post(name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
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

    /// The app must be visible when a real microphone lease starts. Once armed, the app may serve
    /// keyboard turns in the background until the user turns it off or another audio owner pauses it.
    static let requiresVisibleContainingAppForVoiceInput = false
    static let supportsBoundedForegroundStartedBackgroundCapture = true
}

enum OpenClamKeyboardUserCopy {
    static let setupWorkflow = "Turn on Allow Full Access for OpenClam Keyboard, choose your speech provider in OpenClam, then turn on Quick Dictation once. Return to any app, tap Start in OpenClam Keyboard, wait for Listening, and speak."

    static let boundedMicrophoneDisclosure = "Quick Dictation keeps one visible, foreground-started microphone readiness session active until you turn it off; standby audio is discarded and the keyboard itself never records"
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
              !Self.noLeadingSpacePunctuation.contains(first),
              !Self.openingPunctuation.contains(previous),
              !Self.usesNoSpaceWordBoundaries(previous),
              !Self.usesNoSpaceWordBoundaries(first) else {
            return cleaned
        }
        return " " + cleaned
    }

    private static let noLeadingSpacePunctuation = CharacterSet(
        charactersIn: ".,!?;:،؛؟，。！？；：、)]}）］｝》〉」』】〕〗〙〛”’'…"
    )

    private static let openingPunctuation = CharacterSet(
        charactersIn: "([{（［｛《〈「『【〔〖〘〚“‘"
    )

    private static func usesNoSpaceWordBoundaries(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3400 ... 0x4DBF).contains(value)
                || (0x4E00 ... 0x9FFF).contains(value)
                || (0xF900 ... 0xFAFF).contains(value)
                || (0x20000 ... 0x2FA1F).contains(value)
                || (0x3040 ... 0x30FF).contains(value)
                || (0x31F0 ... 0x31FF).contains(value)
                || (0x3100 ... 0x312F).contains(value)
                || (0x31A0 ... 0x31BF).contains(value)
                || (0xFF66 ... 0xFF9D).contains(value)
                || (0x0E00 ... 0x0E7F).contains(value)
                || (0x0E80 ... 0x0EFF).contains(value)
                || (0x1000 ... 0x109F).contains(value)
                || (0xA9E0 ... 0xA9FF).contains(value)
                || (0xAA60 ... 0xAA7F).contains(value)
                || (0x1780 ... 0x17FF).contains(value)
                || (0x19E0 ... 0x19FF).contains(value)
        }
    }
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
    case artifactTooLarge

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
        case .artifactTooLarge:
            "The keyboard handoff was larger than OpenClam's private safety limit. Start a new request."
        }
    }
}

struct OpenClamKeyboardHandoffStore {
    static let appGroupIdentifier = "group.com.lionheart.openclam.livekitpilot.shared"
    static let maximumArtifactBytes = 256 * 1_024

    private struct ActivePointer: Codable {
        let requestID: UUID
    }

    private struct CancellationMarker: Codable {
        let requestID: UUID
        let createdAt: Date

        func isCurrent(at date: Date) -> Bool {
            let age = date.timeIntervalSince(createdAt)
            return age >= -5 && age <= OpenClamKeyboardRequest.maximumAge
        }
    }

    private let directory: URL
    private let fileManager: FileManager
    private let transactionLock: OpenClamKeyboardTransactionLock
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(containerURL: URL, fileManager: FileManager = .default) {
        directory = containerURL.appendingPathComponent("OpenClamKeyboard", isDirectory: true)
        self.fileManager = fileManager
        transactionLock = OpenClamKeyboardTransactionLock(directory: directory)
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
        return try transactionLock.withExclusiveLock {
            do {
                try pruneExpiredArtifacts(at: date)
            } catch OpenClamKeyboardStoreError.staleRequest {
                // Pruning already removed the expired single-request transaction; begin fresh.
            }
            if let request = try activeRequestWithoutPruning(at: date) {
                return request
            }
            let request = OpenClamKeyboardRequest(id: UUID(), createdAt: date)
            do {
                try write(request, to: requestURL(request.id))
                try write(ActivePointer(requestID: request.id), to: activeURL)
                return request
            } catch {
                try? removeArtifacts(for: request.id, includingActivePointer: true)
                throw error
            }
        }
    }

    func activeRequest(at date: Date = Date()) throws -> OpenClamKeyboardRequest? {
        try ensureDirectory()
        return try transactionLock.withExclusiveLock {
            try activeRequestLocked(at: date)
        }
    }

    private func activeRequestLocked(at date: Date) throws -> OpenClamKeyboardRequest? {
        try pruneExpiredArtifacts(at: date)
        return try activeRequestWithoutPruning(at: date)
    }

    private func activeRequestWithoutPruning(
        at date: Date
    ) throws -> OpenClamKeyboardRequest? {
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
        try ensureDirectory()
        return try transactionLock.withExclusiveLock {
            try requestLocked(id: id, at: date)
        }
    }

    private func requestLocked(id: UUID, at date: Date) throws -> OpenClamKeyboardRequest {
        try pruneExpiredArtifacts(at: date)
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

    /// Commits exactly one terminal result. App and keyboard processes share a filesystem lock,
    /// so cancellation, completion, and failure are first-writer-wins rather than last-writer-wins.
    @discardableResult
    func write(_ result: OpenClamKeyboardResult, at date: Date = Date()) throws -> Bool {
        try ensureDirectory()
        return try transactionLock.withExclusiveLock {
            let request = try requestLocked(id: result.requestID, at: date)
            guard request.id == result.requestID else {
                throw OpenClamKeyboardStoreError.mismatchedResult
            }
            guard try resultLocked(for: result.requestID) == nil else { return false }
            try write(result, to: resultURL(result.requestID))
            return true
        }
    }

    func result(for requestID: UUID) throws -> OpenClamKeyboardResult? {
        try ensureDirectory()
        return try transactionLock.withExclusiveLock {
            try resultLocked(for: requestID)
        }
    }

    private func resultLocked(for requestID: UUID) throws -> OpenClamKeyboardResult? {
        try readIfPresent(
            OpenClamKeyboardResult.self,
            from: resultURL(requestID)
        )
    }

    /// Reads one final result without deleting it. The extension acknowledges only after the
    /// synchronous text-proxy insertion returns, preventing delete-before-insert data loss.
    func peekActiveResult(at date: Date = Date()) throws -> OpenClamKeyboardResult? {
        try ensureDirectory()
        return try transactionLock.withExclusiveLock {
            try peekActiveResultLocked(at: date)
        }
    }

    private func peekActiveResultLocked(at date: Date) throws -> OpenClamKeyboardResult? {
        guard let request = try activeRequestLocked(at: date) else { return nil }
        guard let result = try resultLocked(for: request.id) else { return nil }
        guard result.requestID == request.id else {
            throw OpenClamKeyboardStoreError.mismatchedResult
        }
        return result
    }

    func acknowledgeActiveResult(requestID: UUID, at date: Date = Date()) throws {
        try ensureDirectory()
        try transactionLock.withExclusiveLock {
            guard let request = try activeRequestLocked(at: date), request.id == requestID else {
                throw OpenClamKeyboardStoreError.mismatchedResult
            }
            guard let result = try resultLocked(for: requestID), result.requestID == requestID else {
                throw OpenClamKeyboardStoreError.mismatchedResult
            }
            try removeArtifacts(for: request.id, includingActivePointer: true)
        }
    }

    /// Compatibility helper for non-insertion consumers. Keyboard insertion uses peek/ack above.
    func takeActiveResult(at date: Date = Date()) throws -> OpenClamKeyboardResult? {
        try ensureDirectory()
        return try transactionLock.withExclusiveLock {
            guard let result = try peekActiveResultLocked(at: date) else { return nil }
            try removeArtifacts(for: result.requestID, includingActivePointer: true)
            return result
        }
    }

    @discardableResult
    func cancelActiveRequest(at date: Date = Date()) throws -> OpenClamKeyboardRequest? {
        try ensureDirectory()
        return try transactionLock.withExclusiveLock {
            guard let request = try activeRequestLocked(at: date) else { return nil }
            let existing = try resultLocked(for: request.id)
            guard existing == nil || existing?.state == .cancelled else { return request }
            if existing == nil {
                try write(
                    OpenClamKeyboardResult.cancelled(requestID: request.id, at: date),
                    to: resultURL(request.id)
                )
            }
            try write(
                CancellationMarker(requestID: request.id, createdAt: date),
                to: cancellationURL(request.id)
            )
            return request
        }
    }

    /// Cancellation signals carry no Darwin payload. This persistent UUID marker makes a delayed
    /// wake-up request-safe and survives until the app acknowledges the exact resource owner.
    func pendingCancellationRequestIDs(at date: Date = Date()) throws -> [UUID] {
        try ensureDirectory()
        return try transactionLock.withExclusiveLock {
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ).filter(Self.isCancellationArtifact)
            var pending: [UUID] = []
            for url in urls {
                do {
                    guard let marker: CancellationMarker = try readIfPresent(
                        CancellationMarker.self,
                        from: url
                    ), marker.isCurrent(at: date), cancellationURL(marker.requestID) == url else {
                        try fileManager.removeItem(at: url)
                        continue
                    }
                    pending.append(marker.requestID)
                } catch {
                    try? fileManager.removeItem(at: url)
                }
            }
            return pending
        }
    }

    func acknowledgeCancellation(requestID: UUID) throws {
        try ensureDirectory()
        try transactionLock.withExclusiveLock {
            let url = cancellationURL(requestID)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
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

    private func cancellationURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("cancel-\(id.uuidString.lowercased()).json")
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? protectedDirectory.setResourceValues(values)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectory()
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumArtifactBytes else {
            throw OpenClamKeyboardStoreError.artifactTooLarge
        }
        try data.write(to: url, options: [.atomic])
#if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
#endif
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? protectedURL.setResourceValues(values)
    }

    private func readIfPresent<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize,
           fileSize > Self.maximumArtifactBytes {
            throw OpenClamKeyboardStoreError.artifactTooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= Self.maximumArtifactBytes else {
            throw OpenClamKeyboardStoreError.artifactTooLarge
        }
        return try decoder.decode(type, from: data)
    }

    private func pruneExpiredArtifacts(at date: Date) throws {
        try ensureDirectory()
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let ownedArtifacts = urls.filter(Self.isTransactionArtifact)
        for url in urls.filter(Self.isCancellationArtifact) {
            do {
                guard let marker: CancellationMarker = try readIfPresent(
                    CancellationMarker.self,
                    from: url
                ), marker.isCurrent(at: date), cancellationURL(marker.requestID) == url else {
                    try fileManager.removeItem(at: url)
                    continue
                }
            } catch {
                try? fileManager.removeItem(at: url)
            }
        }

        guard fileManager.fileExists(atPath: activeURL.path) else {
            try remove(urls: ownedArtifacts)
            return
        }

        let pointer: ActivePointer
        let request: OpenClamKeyboardRequest
        do {
            guard let decodedPointer: ActivePointer = try readIfPresent(
                ActivePointer.self,
                from: activeURL
            ), let decodedRequest: OpenClamKeyboardRequest = try readIfPresent(
                OpenClamKeyboardRequest.self,
                from: requestURL(decodedPointer.requestID)
            ), decodedRequest.id == decodedPointer.requestID else {
                try remove(urls: ownedArtifacts)
                return
            }
            pointer = decodedPointer
            request = decodedRequest
        } catch {
            try remove(urls: ownedArtifacts)
            return
        }

        guard request.isCurrent(at: date) else {
            try remove(urls: ownedArtifacts)
            throw OpenClamKeyboardStoreError.staleRequest
        }

        let activeNames = Set([
            activeURL.lastPathComponent,
            requestURL(pointer.requestID).lastPathComponent,
            resultURL(pointer.requestID).lastPathComponent,
        ])
        try remove(urls: ownedArtifacts.filter { !activeNames.contains($0.lastPathComponent) })

        let activeResultURL = resultURL(pointer.requestID)
        if fileManager.fileExists(atPath: activeResultURL.path) {
            do {
                let result: OpenClamKeyboardResult? = try readIfPresent(
                    OpenClamKeyboardResult.self,
                    from: activeResultURL
                )
                if result?.requestID != pointer.requestID {
                    try fileManager.removeItem(at: activeResultURL)
                }
            } catch {
                try fileManager.removeItem(at: activeResultURL)
            }
        }
    }

    private static func isTransactionArtifact(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == "active.json"
            || (name.hasPrefix("request-") && name.hasSuffix(".json"))
            || (name.hasPrefix("result-") && name.hasSuffix(".json"))
    }

    private static func isCancellationArtifact(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("cancel-") && name.hasSuffix(".json")
    }

    private func remove(urls: [URL]) throws {
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
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

private struct OpenClamKeyboardTransactionLock {
    private let lockURL: URL

    init(directory: URL) {
        lockURL = directory.appendingPathComponent(".transaction.lock", isDirectory: false)
    }

    func withExclusiveLock<Result>(_ operation: () throws -> Result) throws -> Result {
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = Darwin.close(descriptor) }
#if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: lockURL.path
        )
#endif
        var lockResult: Int32
        repeat {
            lockResult = flock(descriptor, LOCK_EX)
        } while lockResult != 0 && errno == EINTR
        guard lockResult == 0 else { throw CocoaError(.fileLocking) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

enum OpenClamKeyboardTextMutation {
    static func commitMarkedTextThen(
        _ mutation: () -> Void,
        unmarkText: () -> Void
    ) {
        unmarkText()
        mutation()
    }
}
