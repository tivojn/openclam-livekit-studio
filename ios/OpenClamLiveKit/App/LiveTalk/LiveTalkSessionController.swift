import Combine
import Foundation
import LiveKit

enum LiveTalkEmailDraftToolBridge {
    static let rpcMethod = "openclam.prepareEmailDraft.v1"
    static let maximumPayloadBytes = 12_000
    static let maximumSpokenRequestBytes = 8_000
    static let maximumRecipientCharacters = 320
    static let maximumSubjectCharacters = 240
    static let maximumBodyBytes = 6_000
    static let minimumResponseTimeout: TimeInterval = 1
    static let maximumResponseTimeout: TimeInterval = 20

    private static let confirmationOnlyRequests: Set<String> = [
        "approve", "approve it", "confirm", "confirm it", "do it",
        "go ahead", "ok send it", "okay send it", "send", "send it",
        "yes", "yes send it",
    ]
    private static let negations = [
        "can t", "cannot", "do not", "don t", "dont", "must not",
        "mustn t", "never", "should not", "shouldn t", "won t",
    ]
    private static let cancellationOrNonComposingTerms: Set<String> = [
        "asked", "avoid", "cancel", "check", "drafted", "emailed", "find",
        "forwarded", "mentioned", "no", "not", "open", "pasted", "prepared",
        "quoted", "read", "received", "reported", "said", "says", "search",
        "sent", "show", "stop", "summarise", "summarize", "told", "wrote",
    ]
    private static let politePrefixes = [
        "please would you", "please could you", "please can you", "would you",
        "could you", "i want to", "i need to", "i d like to", "will you",
        "help me", "id like to", "please", "let s", "can you", "lets",
    ]
    private static let composingActions = [
        "compose", "create", "draft", "prepare", "send", "write",
    ]

    static func canonicalize(_ value: String) -> String {
        String(
            value
                .lowercased()
                .map { $0.isLetter || $0.isNumber ? $0 : " " }
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        )
    }

    static func isConfirmationOnly(_ value: String) -> Bool {
        confirmationOnlyRequests.contains(canonicalize(value))
    }

    static func isExplicitNewEmailRequest(
        _ value: String,
        recipientName: String
    ) -> Bool {
        let normalized = canonicalize(value)
        let recipient = canonicalize(recipientName)
        guard !normalized.isEmpty,
              !recipient.isEmpty,
              !isConfirmationOnly(value),
              !looksQuoted(value),
              !negations.contains(where: { hasCanonicalTerm(normalized, term: $0) }),
              !cancellationOrNonComposingTerms.contains(where: {
                  hasCanonicalTerm(normalized, term: $0)
              }) else {
            return false
        }

        var request = normalized
        for prefix in politePrefixes where request.hasPrefix("\(prefix) ") {
            request = String(request.dropFirst(prefix.count + 1))
            break
        }

        var candidates = ["email \(recipient)", "email to \(recipient)"]
        for action in composingActions {
            candidates.append(contentsOf: [
                "\(action) an email to \(recipient)",
                "\(action) a email to \(recipient)",
                "\(action) email to \(recipient)",
                "\(action) an email for \(recipient)",
                "\(action) a email for \(recipient)",
                "\(action) email for \(recipient)",
                "\(action) \(recipient) an email",
                "\(action) \(recipient) a email",
                "\(action) \(recipient) email",
            ])
        }
        return candidates.contains(where: {
            request == $0 || request.hasPrefix("\($0) ")
        })
    }

    static func latestFinalUserTranscript(in messages: [ReceivedMessage]) -> String? {
        for message in messages.reversed() where message.isFinal {
            guard case let .userTranscript(rawText) = message.content else { continue }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }

    static func matchesLatestFinalUserTranscript(
        _ spokenRequest: String,
        messages: [ReceivedMessage]
    ) -> Bool {
        guard let latest = latestFinalUserTranscript(in: messages) else { return false }
        let claimed = canonicalize(spokenRequest)
        return !claimed.isEmpty && claimed == canonicalize(latest)
    }

    static func hasValidFieldBounds(
        spokenRequest: String,
        recipientName: String,
        subject: String,
        body: String
    ) -> Bool {
        !spokenRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && spokenRequest.utf8.count <= maximumSpokenRequestBytes
            && !recipientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Python's `len(str)` counts Unicode code points; Swift Unicode
            // scalars are the matching unit for enforcing the wire contract.
            && recipientName.unicodeScalars.count <= maximumRecipientCharacters
            && subject.unicodeScalars.count <= maximumSubjectCharacters
            && body.utf8.count <= maximumBodyBytes
    }

    private static func hasCanonicalTerm(_ value: String, term: String) -> Bool {
        " \(value) ".contains(" \(term) ")
    }

    private static func looksQuoted(_ value: String) -> Bool {
        let stripped = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = stripped.first, let last = stripped.last else { return false }
        let edgeQuoteCharacters: Set<Character> = [
            "\"", "'", "`", ">", "“", "”", "‘", "’", "«", "»",
        ]
        if edgeQuoteCharacters.contains(first) || edgeQuoteCharacters.contains(last) {
            return true
        }
        return stripped.filter { $0 == "\"" }.count >= 2
            || stripped.filter { $0 == "`" }.count >= 2
    }

    static func decodeRequest(_ payload: String) throws -> LiveTalkEmailDraftToolRequest {
        guard let data = payload.data(using: .utf8),
              data.count <= maximumPayloadBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schema_version", "request_id", "spoken_request", "tool"],
              let tool = root["tool"] as? [String: Any],
              Set(tool.keys) == ["name", "arguments"],
              let arguments = tool["arguments"] as? [String: Any],
              Set(arguments.keys) == ["recipient_name", "subject", "body"] else {
            throw LiveTalkEmailDraftToolBridgeError.invalidRequest
        }

        let decoded: WireRequest
        do {
            decoded = try JSONDecoder().decode(WireRequest.self, from: data)
        } catch {
            throw LiveTalkEmailDraftToolBridgeError.invalidRequest
        }
        guard decoded.schemaVersion == 1,
              decoded.tool.name == "prepare_email_draft",
              decoded.requestID.utf8.count == 64,
              decoded.requestID.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 102).contains($0)
              }),
              hasValidFieldBounds(
                  spokenRequest: decoded.spokenRequest,
                  recipientName: decoded.tool.arguments.recipientName,
                  subject: decoded.tool.arguments.subject,
                  body: decoded.tool.arguments.body
              ),
              isExplicitNewEmailRequest(
                  decoded.spokenRequest,
                  recipientName: decoded.tool.arguments.recipientName
              ) else {
            throw LiveTalkEmailDraftToolBridgeError.invalidRequest
        }
        return .init(
            requestID: decoded.requestID,
            spokenRequest: decoded.spokenRequest,
            recipientName: decoded.tool.arguments.recipientName,
            subject: decoded.tool.arguments.subject,
            body: decoded.tool.arguments.body
        )
    }

    static func encodeResponse(
        _ disposition: LiveTalkEmailDraftToolDisposition
    ) throws -> String {
        let data = try JSONEncoder().encode(
            WireResponse(schemaVersion: 1, status: disposition.rawValue)
        )
        guard let response = String(data: data, encoding: .utf8) else {
            throw LiveTalkEmailDraftToolBridgeError.invalidResponse
        }
        return response
    }

    private struct WireRequest: Decodable {
        let schemaVersion: Int
        let requestID: String
        let spokenRequest: String
        let tool: WireTool

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case requestID = "request_id"
            case spokenRequest = "spoken_request"
            case tool
        }
    }

    private struct WireTool: Decodable {
        let name: String
        let arguments: WireArguments
    }

    private struct WireArguments: Decodable {
        let recipientName: String
        let subject: String
        let body: String

        enum CodingKeys: String, CodingKey {
            case recipientName = "recipient_name"
            case subject
            case body
        }
    }

    private struct WireResponse: Encodable {
        let schemaVersion: Int
        let status: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case status
        }
    }
}

struct LiveTalkEmailDraftToolRequest: Equatable, Sendable {
    let requestID: String
    let spokenRequest: String
    let recipientName: String
    let subject: String
    let body: String

    var openAIToolCall: OpenAIToolCall {
        .init(
            callID: requestID,
            name: "prepare_email_draft",
            arguments: [
                "recipient_name": .string(recipientName),
                "subject": .string(subject),
                "body": .string(body),
            ],
            rawArguments: "{}"
        )
    }
}

enum LiveTalkEmailDraftToolDisposition: String, Equatable, Sendable {
    case presentedForReview = "presented_for_review"
    case rejected
    case busy
    case foregroundRequired = "foreground_required"
}

enum LiveTalkEmailDraftToolBridgeError: Error, Equatable {
    case invalidRequest
    case invalidResponse
    case untrustedCaller
    case staleSession
}

enum LiveTalkEmailDraftInvocationPolicy {
    static func isCurrentSession(
        attemptMatches: Bool,
        roomMatches: Bool,
        phase: LiveTalkConnectionPhase
    ) -> Bool {
        attemptMatches
            && roomMatches
            && (phase == .connected || phase == .reconnecting)
    }

    static func isTrustedCaller(
        trustedAgentCount: Int,
        callerIsTrusted: Bool
    ) -> Bool {
        trustedAgentCount == 1 && callerIsTrusted
    }

    static func acceptsResponseTimeout(_ value: TimeInterval) -> Bool {
        value.isFinite
            && value >= LiveTalkEmailDraftToolBridge.minimumResponseTimeout
            && value <= LiveTalkEmailDraftToolBridge.maximumResponseTimeout
    }

    static func hasTimeRemaining(
        now: TimeInterval,
        deadline: TimeInterval
    ) -> Bool {
        now.isFinite && deadline.isFinite && now < deadline
    }
}

struct LiveTalkToolReplayWindow: Equatable, Sendable {
    static let maximumRequestCount = 64
    private(set) var requestIDs: Set<String> = []

    mutating func claim(_ requestID: String) -> Bool {
        guard requestIDs.count < Self.maximumRequestCount else { return false }
        return requestIDs.insert(requestID).inserted
    }

    mutating func clear() {
        requestIDs.removeAll(keepingCapacity: false)
    }
}

typealias LiveTalkEmailDraftToolHandler = @MainActor @Sendable (
    LiveTalkEmailDraftToolRequest
) async -> LiveTalkEmailDraftToolDisposition

enum LiveTalkConnectionPhase: Equatable, Sendable {
    case idle
    case starting
    case connected
    case reconnecting
    case ending
    case failed(String)

    var isSessionActive: Bool {
        switch self {
        case .starting, .connected, .reconnecting, .ending: true
        case .idle, .failed: false
        }
    }

    var statusTitle: String {
        switch self {
        case .idle: "Ready"
        case .starting: "Connecting"
        case .connected: "Live"
        case .reconnecting: "Reconnecting"
        case .ending: "Ending"
        case .failed: "Needs attention"
        }
    }
}

enum LiveTalkAvatarSwitchPolicy {
    static let blockedGuidance = "Hang up Live Talk before changing avatars."

    static func allowsSwitch(during phase: LiveTalkConnectionPhase) -> Bool {
        !phase.isSessionActive
    }
}

struct LiveTalkLifecycle: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case start
        case roomConnected(agentIsConnected: Bool)
        case reconnecting
        case end
        case ended
        case fail(String)
    }

    private(set) var phase: LiveTalkConnectionPhase = .idle

    mutating func apply(_ event: Event) {
        switch event {
        case .start:
            guard !phase.isSessionActive else { return }
            phase = .starting
        case let .roomConnected(agentIsConnected):
            guard agentIsConnected,
                  phase == .starting || phase == .reconnecting else { return }
            phase = .connected
        case .reconnecting:
            guard phase == .connected else { return }
            phase = .reconnecting
        case .end:
            guard phase.isSessionActive else { return }
            phase = .ending
        case .ended:
            phase = .idle
        case let .fail(message):
            phase = .failed(message)
        }
    }
}

struct LiveTalkTranscript: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case agent
    }

    let id: String
    let role: Role
    let text: String
    let isFinal: Bool
}

struct LiveTalkTranscriptWindow: Equatable, Sendable {
    private(set) var items: [LiveTalkTranscript] = []

    mutating func replace(with items: [LiveTalkTranscript]) {
        self.items = items
    }

    mutating func clear() {
        items.removeAll(keepingCapacity: false)
    }
}

enum LiveTalkRemoteAudioActivity {
    static let audibleThreshold: Float = 0.018

    static func isActive(reportedSpeaking: Bool, audioLevel: Float) -> Bool {
        reportedSpeaking || audioLevel > audibleThreshold
    }
}

@MainActor
final class LiveTalkSessionController: ObservableObject {
    @Published private(set) var phase: LiveTalkConnectionPhase = .idle
    @Published private(set) var activityTitle = "Ready to talk"
    @Published private(set) var isMuted = false
    @Published private(set) var transcripts: [LiveTalkTranscript] = []
    @Published private(set) var remoteAudioLevel: Float = 0

    private let credentialVault: ProviderCredentialVault
    private let configurationLoader: @Sendable () throws -> LiveTalkAppConfiguration
    private let sessionStarter: @Sendable (Session) async -> Void
    private let sessionEnder: @Sendable (Session) async -> Void
    private var lifecycle = LiveTalkLifecycle()
    private var session: Session?
    private var startTask: Task<Void, Never>?
    private var observations = Set<AnyCancellable>()
    private var activeAttempt: UUID?
    private weak var avatarController: CaptainAyerLipSyncController?
    private var avatarGeneration = 40_000
    private var avatarIsSpeaking = false
    private var lastAgentTranscript = ""
    private var transcriptWindow = LiveTalkTranscriptWindow()
    private var emailDraftReplayWindow = LiveTalkToolReplayWindow()

    init(
        credentialVault: ProviderCredentialVault = KeychainProviderCredentialVault(),
        configurationLoader: @escaping @Sendable () throws -> LiveTalkAppConfiguration = {
            try LiveTalkAppConfiguration.load()
        },
        sessionStarter: @escaping @Sendable (Session) async -> Void = { session in
            await session.start()
        },
        sessionEnder: @escaping @Sendable (Session) async -> Void = { session in
            await session.end()
        }
    ) {
        self.credentialVault = credentialVault
        self.configurationLoader = configurationLoader
        self.sessionStarter = sessionStarter
        self.sessionEnder = sessionEnder
    }

    deinit {
        startTask?.cancel()
    }

    var errorMessage: String? {
        guard case let .failed(message) = phase else { return nil }
        return message
    }

    var canStart: Bool {
        !phase.isSessionActive
    }

    func begin(
        avatar: AvatarAgentProfile,
        sharedSettings: AIProviderSettings,
        avatarController: CaptainAyerLipSyncController,
        emailDraftToolHandler: @escaping LiveTalkEmailDraftToolHandler = { _ in .rejected }
    ) {
        guard canStart else { return }
        let attempt = UUID()
        activeAttempt = attempt
        self.avatarController = avatarController
        isMuted = false
        clearSessionTranscripts()
        emailDraftReplayWindow.clear()
        transition(.start)
        activityTitle = "Requesting a private session"

        do {
            let configuration = try configurationLoader()
            let resolvedLiveTalk = try LiveTalkConfigurationResolver.resolve(
                profile: avatar,
                sharedSettings: sharedSettings
            )
            let builder = LiveTalkSessionRequestBuilder(credentialVault: credentialVault)
            try builder.validateCredentialAvailability(for: resolvedLiveTalk)
            let source = LiveTalkBrokerTokenSource(
                configuration: configuration,
                avatar: try avatar.validated(),
                liveTalkConfiguration: resolvedLiveTalk,
                credentialVault: credentialVault
            )
            let room = Room()
            let nextSession = Session(
                tokenSource: source,
                options: .init(room: room, preConnectAudio: true, agentConnectTimeout: 30)
            )
            session = nextSession
            observe(nextSession)
            activityTitle = "Connecting to LiveKit"
            let startOperation = sessionStarter
            let endOperation = sessionEnder
            startTask = Task { [weak self, weak room] in
                guard let room else { return }
                do {
                    try await room.registerRpcMethod(
                        LiveTalkEmailDraftToolBridge.rpcMethod
                    ) { [weak self, weak room] invocation in
                        guard let self, let room else {
                            throw LiveTalkEmailDraftToolBridgeError.staleSession
                        }
                        return try await self.handleEmailDraftToolInvocation(
                            invocation,
                            room: room,
                            attempt: attempt,
                            handler: emailDraftToolHandler
                        )
                    }
                } catch {
                    guard let self else {
                        await endOperation(nextSession)
                        return
                    }
                    self.fail(
                        "Live Talk could not enable foreground draft review. "
                            + "End the session and try again."
                    )
                    return
                }
                await startOperation(nextSession)
                guard !Task.isCancelled else {
                    if self == nil {
                        await endOperation(nextSession)
                    }
                    return
                }
                guard let self else {
                    await endOperation(nextSession)
                    return
                }
                await self.finishStart(nextSession, attempt: attempt)
            }
        } catch let error as LiveTalkBrokerError {
            fail(error.localizedDescription)
        } catch let error as LiveTalkConfigurationError {
            fail(error.localizedDescription)
        } catch {
            fail("Live Talk could not start safely. Check the selected services and try again.")
        }
    }

    private func finishStart(_ startedSession: Session, attempt: UUID) async {
        guard activeAttempt == attempt, session === startedSession else {
            await sessionEnder(startedSession)
            return
        }
        startTask = nil
        refreshFromSession()
        guard activeAttempt == attempt else { return }
        if startedSession.room.connectionState == .disconnected {
            fail("Live Talk could not connect. Check the build configuration and try again.")
        }
    }

    func toggleMute() async {
        guard let session, phase.isSessionActive else { return }
        let shouldEnable = isMuted
        do {
            try await session.room.localParticipant.setMicrophone(enabled: shouldEnable)
            isMuted = !shouldEnable
            refreshFromSession()
        } catch {
            fail("The microphone could not be changed. End the session and try again.")
        }
    }

    func stop() async {
        guard phase != .ending else { return }
        guard phase.isSessionActive || session != nil else {
            resetAfterSession()
            return
        }
        activeAttempt = nil
        transition(.end)
        activityTitle = "Ending Live Talk"
        clearSessionTranscripts()
        let endingSession = session
        let pendingStart = startTask
        startTask = nil
        pendingStart?.cancel()
        observations.removeAll()
        if let endingSession {
            await endingSession.room.unregisterRpcMethod(
                LiveTalkEmailDraftToolBridge.rpcMethod
            )
            await sessionEnder(endingSession)
        }
        await pendingStart?.value
        resetAfterSession()
    }

    func clearError() {
        guard case .failed = phase else { return }
        transition(.ended)
        activityTitle = "Ready to talk"
    }

    private func observe(_ session: Session) {
        observations.removeAll()
        session.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.refreshFromSession()
                }
            }
            .store(in: &observations)
        session.room.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.refreshFromSession()
                }
            }
            .store(in: &observations)
    }

    private func handleEmailDraftToolInvocation(
        _ invocation: RpcInvocationData,
        room: Room,
        attempt: UUID,
        handler: LiveTalkEmailDraftToolHandler
    ) async throws -> String {
        guard let currentSession = session,
              LiveTalkEmailDraftInvocationPolicy.isCurrentSession(
                  attemptMatches: activeAttempt == attempt,
                  roomMatches: currentSession.room === room,
                  phase: phase
              ) else {
            throw LiveTalkEmailDraftToolBridgeError.staleSession
        }
        let trustedAgents = room.agentParticipants
        guard LiveTalkEmailDraftInvocationPolicy.isTrustedCaller(
            trustedAgentCount: trustedAgents.count,
            callerIsTrusted: trustedAgents[invocation.callerIdentity] != nil
        ) else {
            throw LiveTalkEmailDraftToolBridgeError.untrustedCaller
        }
        guard LiveTalkEmailDraftInvocationPolicy.acceptsResponseTimeout(
            invocation.responseTimeout
        ) else {
            return try LiveTalkEmailDraftToolBridge.encodeResponse(.rejected)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + invocation.responseTimeout

        let request: LiveTalkEmailDraftToolRequest
        do {
            request = try LiveTalkEmailDraftToolBridge.decodeRequest(invocation.payload)
        } catch {
            return try LiveTalkEmailDraftToolBridge.encodeResponse(.rejected)
        }
        guard LiveTalkEmailDraftToolBridge.matchesLatestFinalUserTranscript(
            request.spokenRequest,
            messages: currentSession.messages
        ) else {
            return try LiveTalkEmailDraftToolBridge.encodeResponse(.rejected)
        }
        guard emailDraftReplayWindow.claim(request.requestID) else {
            return try LiveTalkEmailDraftToolBridge.encodeResponse(.rejected)
        }
        let disposition = await handler(request)
        if disposition == .presentedForReview {
            guard let completionSession = session,
                  LiveTalkEmailDraftInvocationPolicy.isCurrentSession(
                      attemptMatches: activeAttempt == attempt,
                      roomMatches: completionSession.room === room,
                      phase: phase
                  ) else {
                return try LiveTalkEmailDraftToolBridge.encodeResponse(.rejected)
            }
            let completionTrustedAgents = room.agentParticipants
            guard LiveTalkEmailDraftInvocationPolicy.isTrustedCaller(
                trustedAgentCount: completionTrustedAgents.count,
                callerIsTrusted: completionTrustedAgents[invocation.callerIdentity] != nil
            ),
            LiveTalkEmailDraftInvocationPolicy.hasTimeRemaining(
                now: ProcessInfo.processInfo.systemUptime,
                deadline: deadline
            ) else {
                return try LiveTalkEmailDraftToolBridge.encodeResponse(.rejected)
            }
        }
        return try LiveTalkEmailDraftToolBridge.encodeResponse(disposition)
    }

    private func refreshFromSession() {
        guard let session else { return }
        switch session.room.connectionState {
        case .connecting:
            activityTitle = "Connecting to LiveKit"
        case .reconnecting:
            transition(.reconnecting)
            activityTitle = "Restoring the conversation"
        case .connected:
            // A LiveKit room can connect before its dispatched voice agent joins.
            // Keep the initial call in `.starting` (and a restored call in
            // `.reconnecting`) until both sides are ready so feedback never
            // claims the conversation is live during the agent wait.
            transition(.roomConnected(agentIsConnected: session.agent.isConnected))
            activityTitle = agentActivityTitle(session.agent)
        case .disconnecting:
            activityTitle = "Ending Live Talk"
        case .disconnected:
            if phase != .starting, phase != .ending, activeAttempt != nil {
                fail("The Live Talk session ended. Start a new session to continue.")
            }
        }

        isMuted = !session.room.localParticipant.isMicrophoneEnabled()
        transcriptWindow.replace(with: Self.boundedTranscripts(from: session.messages))
        transcripts = transcriptWindow.items
        if let latest = transcripts.last(where: { $0.role == .agent })?.text,
           !latest.isEmpty {
            lastAgentTranscript = latest
        }
        updateAvatar(from: session)

        if session.error != nil, session.room.connectionState == .disconnected {
            fail("Live Talk could not connect. Check the selected services and try again.")
        } else if session.agent.error != nil {
            fail("The voice agent left this session. Start a new session to continue.")
        }
    }

    nonisolated static func boundedTranscripts(
        from messages: [ReceivedMessage],
        limit: Int = 12
    ) -> [LiveTalkTranscript] {
        let converted = messages.compactMap { message -> LiveTalkTranscript? in
            let role: LiveTalkTranscript.Role
            let rawText: String
            switch message.content {
            case let .agentTranscript(text):
                role = .agent
                rawText = text
            case let .userTranscript(text), let .userInput(text):
                role = .user
                rawText = text
            }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return .init(id: message.id, role: role, text: text, isFinal: message.isFinal)
        }
        return Array(converted.suffix(max(1, limit)))
    }

    private func updateAvatar(from session: Session) {
        let participant = session.room.agentParticipant
        let level = participant?.audioLevel ?? 0
        remoteAudioLevel = level
        let speaks = LiveTalkRemoteAudioActivity.isActive(
            reportedSpeaking: participant?.isSpeaking == true,
            audioLevel: level
        )
        guard let avatarController else { return }
        if speaks {
            if !avatarIsSpeaking || avatarController.preparedText != lastAgentTranscript {
                avatarGeneration += 1
                let text = lastAgentTranscript.isEmpty ? "Speaking naturally" : lastAgentTranscript
                avatarController.prepare(text: text, generation: avatarGeneration)
                avatarController.begin(generation: avatarGeneration)
            }
            avatarIsSpeaking = true
        } else if avatarIsSpeaking {
            avatarController.finish(generation: avatarGeneration)
            avatarIsSpeaking = false
        }
    }

    private func agentActivityTitle(_ agent: Agent) -> String {
        if !agent.isConnected {
            return "Waiting for the voice agent"
        }
        return switch agent.agentState {
        case .listening: isMuted ? "Microphone muted" : "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .initializing, .idle, .none: "Getting ready"
        }
    }

    private func fail(_ message: String) {
        activeAttempt = nil
        observations.removeAll()
        let endingSession = session
        let pendingStart = startTask
        startTask = nil
        pendingStart?.cancel()
        session = nil
        isMuted = false
        remoteAudioLevel = 0
        clearSessionTranscripts()
        emailDraftReplayWindow.clear()
        avatarController?.cancelAll()
        avatarIsSpeaking = false
        transition(.fail(message))
        activityTitle = "Live Talk stopped"
        Task { [sessionEnder] in
            if let endingSession {
                await endingSession.room.unregisterRpcMethod(
                    LiveTalkEmailDraftToolBridge.rpcMethod
                )
                await sessionEnder(endingSession)
            }
            await pendingStart?.value
        }
    }

    private func resetAfterSession() {
        activeAttempt = nil
        observations.removeAll()
        startTask?.cancel()
        startTask = nil
        session = nil
        isMuted = false
        remoteAudioLevel = 0
        clearSessionTranscripts()
        emailDraftReplayWindow.clear()
        avatarController?.cancelAll()
        avatarController = nil
        avatarIsSpeaking = false
        transition(.ended)
        activityTitle = "Ready to talk"
    }

    private func clearSessionTranscripts() {
        transcriptWindow.clear()
        transcripts = transcriptWindow.items
        lastAgentTranscript = ""
    }

    private func transition(_ event: LiveTalkLifecycle.Event) {
        lifecycle.apply(event)
        phase = lifecycle.phase
    }
}
