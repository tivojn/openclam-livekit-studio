import Foundation

protocol AgentConnector: Sendable {
    func streamTurn(
        _ request: AgentConnectorTurnRequest,
        clientToken: String
    ) -> AsyncThrowingStream<AgentConnectorStreamEvent, Error>
}

protocol AgentConnectorPersistentCancellation: Sendable {
    func cancelTurn(
        _ request: AgentConnectorTurnRequest,
        clientToken: String
    ) async throws
}

struct AgentConnectorWirePayload: Codable, Sendable {
    var ackSeq: Int?
    var turnID: String?
    var accountID: String?
    var capabilities: [String]?
    var revision: Int?
    var status: String?
    var text: String?
    var code: String?
    var message: String?
    var retryable: Bool?
    var lastReceivedSeq: Int?
    var attachmentID: String?
    var fileName: String?
    var mediaType: String?
    var byteCount: Int?
    var sha256: String?
    var downloadPath: String?
    var expiresAt: Int64?
    private(set) var decodedKeys: Set<String> = []

    enum CodingKeys: String, CodingKey {
        case ackSeq
        case turnID = "turnId"
        case accountID = "accountId"
        case capabilities, revision, status, text, code, message, retryable, lastReceivedSeq
        case attachmentID = "attachmentId"
        case fileName, mediaType, byteCount, sha256, downloadPath, expiresAt
    }

    init(
        ackSeq: Int? = nil,
        turnID: String? = nil,
        accountID: String? = nil,
        capabilities: [String]? = nil,
        revision: Int? = nil,
        status: String? = nil,
        text: String? = nil,
        code: String? = nil,
        message: String? = nil,
        retryable: Bool? = nil,
        lastReceivedSeq: Int? = nil,
        attachmentID: String? = nil,
        fileName: String? = nil,
        mediaType: String? = nil,
        byteCount: Int? = nil,
        sha256: String? = nil,
        downloadPath: String? = nil,
        expiresAt: Int64? = nil
    ) {
        self.ackSeq = ackSeq
        self.turnID = turnID
        self.accountID = accountID
        self.capabilities = capabilities
        self.revision = revision
        self.status = status
        self.text = text
        self.code = code
        self.message = message
        self.retryable = retryable
        self.lastReceivedSeq = lastReceivedSeq
        self.attachmentID = attachmentID
        self.fileName = fileName
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.downloadPath = downloadPath
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        try AgentConnectorStrictCoding.requireKeys(
            decoder,
            required: [],
            allowed: [
                "ackSeq", "turnId", "accountId", "revision", "text",
                "capabilities", "status", "code", "message", "retryable",
                "lastReceivedSeq", "attachmentId", "fileName", "mediaType",
                "byteCount", "sha256", "downloadPath", "expiresAt",
            ]
        )
        let dynamic = try decoder.container(keyedBy: AgentConnectorAnyWireCodingKey.self)
        decodedKeys = Set(dynamic.allKeys.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decodePresent<Value: Decodable>(
            _ type: Value.Type,
            forKey key: CodingKeys
        ) throws -> Value? {
            guard container.contains(key) else { return nil }
            return try container.decode(type, forKey: key)
        }
        ackSeq = try decodePresent(Int.self, forKey: .ackSeq)
        turnID = try decodePresent(String.self, forKey: .turnID)
        accountID = try decodePresent(String.self, forKey: .accountID)
        capabilities = try decodePresent([String].self, forKey: .capabilities)
        revision = try decodePresent(Int.self, forKey: .revision)
        status = try decodePresent(String.self, forKey: .status)
        text = try decodePresent(String.self, forKey: .text)
        code = try decodePresent(String.self, forKey: .code)
        message = try decodePresent(String.self, forKey: .message)
        retryable = try decodePresent(Bool.self, forKey: .retryable)
        lastReceivedSeq = try decodePresent(Int.self, forKey: .lastReceivedSeq)
        attachmentID = try decodePresent(String.self, forKey: .attachmentID)
        fileName = try decodePresent(String.self, forKey: .fileName)
        mediaType = try decodePresent(String.self, forKey: .mediaType)
        byteCount = try decodePresent(Int.self, forKey: .byteCount)
        sha256 = try decodePresent(String.self, forKey: .sha256)
        downloadPath = try decodePresent(String.self, forKey: .downloadPath)
        expiresAt = try decodePresent(Int64.self, forKey: .expiresAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(ackSeq, forKey: .ackSeq)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encodeIfPresent(accountID, forKey: .accountID)
        try container.encodeIfPresent(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(revision, forKey: .revision)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(retryable, forKey: .retryable)
        try container.encodeIfPresent(lastReceivedSeq, forKey: .lastReceivedSeq)
        try container.encodeIfPresent(attachmentID, forKey: .attachmentID)
        try container.encodeIfPresent(fileName, forKey: .fileName)
        try container.encodeIfPresent(mediaType, forKey: .mediaType)
        try container.encodeIfPresent(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(sha256, forKey: .sha256)
        try container.encodeIfPresent(downloadPath, forKey: .downloadPath)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
    }
}

private struct AgentConnectorAnyWireCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct AgentConnectorWireFrame: Codable, Sendable {
    let v: Int
    let kind: String
    let connectionID: String
    let conversationID: String?
    let messageID: String
    let seq: Int
    let replyTo: Int?
    let sentAt: Int64
    let payload: AgentConnectorWirePayload

    enum CodingKeys: String, CodingKey {
        case v, kind
        case connectionID = "connectionId"
        case conversationID = "conversationId"
        case messageID = "messageId"
        case seq, replyTo, sentAt, payload
    }

    init(
        v: Int,
        kind: String,
        connectionID: String,
        conversationID: String?,
        messageID: String,
        seq: Int,
        replyTo: Int?,
        sentAt: Int64,
        payload: AgentConnectorWirePayload
    ) {
        self.v = v
        self.kind = kind
        self.connectionID = connectionID
        self.conversationID = conversationID
        self.messageID = messageID
        self.seq = seq
        self.replyTo = replyTo
        self.sentAt = sentAt
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        try AgentConnectorStrictCoding.requireKeys(
            decoder,
            required: ["v", "kind", "connectionId", "messageId", "seq", "sentAt", "payload"],
            allowed: [
                "v", "kind", "connectionId", "conversationId", "messageId",
                "seq", "replyTo", "sentAt", "payload",
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        kind = try container.decode(String.self, forKey: .kind)
        connectionID = try container.decode(String.self, forKey: .connectionID)
        conversationID = container.contains(.conversationID)
            ? try container.decode(String.self, forKey: .conversationID)
            : nil
        messageID = try container.decode(String.self, forKey: .messageID)
        seq = try container.decode(Int.self, forKey: .seq)
        replyTo = container.contains(.replyTo)
            ? try container.decode(Int.self, forKey: .replyTo)
            : nil
        sentAt = try container.decode(Int64.self, forKey: .sentAt)
        payload = try container.decode(AgentConnectorWirePayload.self, forKey: .payload)
        guard Self.payloadKeysAreExact(payload.decodedKeys, for: kind) else {
            throw AgentConnectorError.invalidFrame
        }
    }

    private static func payloadKeysAreExact(_ keys: Set<String>, for kind: String) -> Bool {
        switch kind {
        case "ack":
            return keys == ["ackSeq"]
        case "heartbeat":
            return keys.isSubset(of: ["lastReceivedSeq"])
        case "turn.submit":
            return keys == ["turnId", "accountId", "text"]
                || keys == ["turnId", "accountId", "text", "capabilities"]
        case "turn.accepted", "turn.cancel":
            return keys == ["turnId"]
        case "assistant.delta":
            return keys == ["turnId", "revision", "text"]
        case "assistant.completed":
            return keys == ["turnId", "text"]
        case "assistant.activity.upsert":
            return keys == ["turnId", "revision", "status"]
        case "assistant.activity.clear":
            return keys == ["turnId", "revision"]
        case "assistant.attachment":
            return keys == [
                "turnId", "attachmentId", "fileName", "mediaType", "byteCount",
                "sha256", "downloadPath", "expiresAt",
            ]
        case "turn.error":
            return keys == ["turnId", "code", "message", "retryable"]
        default:
            return false
        }
    }

    func validatedUUID(_ value: String) throws -> UUID {
        guard value == value.lowercased(),
              value.range(
                of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
                options: .regularExpression
              ) != nil,
              let id = UUID(uuidString: value) else {
            throw AgentConnectorError.invalidFrame
        }
        return id
    }
}

private struct AgentConnectorWireKindProbe: Decodable {
    let kind: String
}

private struct AgentConnectorRelayPersistenceReceipt: Decodable, Sendable {
    enum Disposition: Equatable {
        case matching
        case retired
    }

    struct Payload: Decodable, Sendable {
        let senderSequence: Int
        let messageID: String

        enum CodingKeys: String, CodingKey {
            case senderSequence = "senderSeq"
            case messageID = "messageId"
        }

        init(from decoder: Decoder) throws {
            try AgentConnectorStrictCoding.requireExactKeys(
                decoder,
                expected: ["senderSeq", "messageId"]
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            senderSequence = try container.decode(Int.self, forKey: .senderSequence)
            messageID = try container.decode(String.self, forKey: .messageID)
        }
    }

    let v: Int
    let kind: String
    let connectionID: String
    let payload: Payload

    enum CodingKeys: String, CodingKey {
        case v, kind, payload
        case connectionID = "connectionId"
    }

    init(from decoder: Decoder) throws {
        try AgentConnectorStrictCoding.requireExactKeys(
            decoder,
            expected: ["v", "kind", "connectionId", "payload"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        kind = try container.decode(String.self, forKey: .kind)
        connectionID = try container.decode(String.self, forKey: .connectionID)
        payload = try container.decode(Payload.self, forKey: .payload)
    }

    func disposition(
        connectionID expectedConnectionID: UUID,
        outboundFrame: AgentConnectorEncodedFrame
    ) throws -> Disposition {
        guard v == 1,
              kind == "relay.persisted",
              self.connectionID == self.connectionID.lowercased(),
              self.connectionID.range(
                of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
                options: .regularExpression
              ) != nil,
              UUID(uuidString: self.connectionID) == expectedConnectionID,
              (1 ... 9_007_199_254_740_991).contains(payload.senderSequence),
              payload.messageID == payload.messageID.lowercased(),
              payload.messageID.range(
                of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
                options: .regularExpression
              ) != nil,
              UUID(uuidString: payload.messageID) != nil,
              payload.senderSequence <= outboundFrame.sequence else {
            throw AgentConnectorError.invalidFrame
        }
        if payload.senderSequence < outboundFrame.sequence {
            return .retired
        }
        guard UUID(uuidString: payload.messageID) == outboundFrame.messageID else {
            // Reusing the current sequence for a different message is not a
            // harmless stale receipt; fail closed instead of suppressing replay.
            throw AgentConnectorError.invalidFrame
        }
        return .matching
    }
}

struct AgentConnectorEncodedFrame: Codable, Equatable, Sendable {
    let sequence: Int
    let messageID: UUID
    let text: String
}

final class AgentConnectorCursorStore: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storagePrefix: String

    init(
        defaults: UserDefaults = .standard,
        storagePrefix: String = "agent.connector.v1.cursor"
    ) {
        self.defaults = defaults
        self.storagePrefix = storagePrefix
    }

    func nextOutbound(connectionID: UUID) -> Int {
        lock.withLock {
            let key = outboundKey(connectionID)
            let next = max(1, defaults.integer(forKey: key) + 1)
            defaults.set(next, forKey: key)
            return next
        }
    }

    func lastAcknowledgedInbound(connectionID: UUID) -> Int {
        lock.withLock { defaults.integer(forKey: inboundKey(connectionID)) }
    }

    func acknowledgeInbound(_ seq: Int, connectionID: UUID) {
        lock.withLock {
            let key = inboundKey(connectionID)
            if seq > defaults.integer(forKey: key) {
                defaults.set(seq, forKey: key)
            }
        }
    }

    private func outboundKey(_ id: UUID) -> String {
        storagePrefix + "." + id.uuidString.lowercased() + ".out"
    }

    private func inboundKey(_ id: UUID) -> String {
        storagePrefix + "." + id.uuidString.lowercased() + ".in"
    }
}

enum AgentConnectorInboundDisposition: Equatable {
    case new
    case alreadyAcknowledged
    case unrelated
}

struct AgentConnectorInboundValidator {
    private static let maximumSafeInteger = 9_007_199_254_740_991

    let connectionID: UUID
    let conversationID: UUID
    let turnID: UUID
    let cursorStore: AgentConnectorCursorStore

    private(set) var lastSocketSequence = 0
    private(set) var seenMessageIDs: Set<UUID> = []

    mutating func validate(
        _ frame: AgentConnectorWireFrame
    ) throws -> AgentConnectorInboundDisposition {
        guard frame.v == 1,
              (1 ... Self.maximumSafeInteger).contains(frame.seq),
              (0 ... Int64(Self.maximumSafeInteger)).contains(frame.sentAt),
              frame.replyTo.map({
                  (1 ... Self.maximumSafeInteger).contains($0)
              }) ?? true,
              try frame.validatedUUID(frame.connectionID) == connectionID,
              [
                "ack", "heartbeat", "turn.accepted", "assistant.delta",
                "assistant.completed", "assistant.activity.upsert",
                "assistant.activity.clear", "assistant.attachment", "turn.error",
              ].contains(frame.kind) else {
            throw AgentConnectorError.invalidFrame
        }
        let messageID = try frame.validatedUUID(frame.messageID)
        let decodedConversationID = try frame.conversationID.map(frame.validatedUUID)
        let decodedTurnID: UUID?
        if frame.kind == "ack" {
            guard let ackSequence = frame.payload.ackSeq,
                  (1 ... Self.maximumSafeInteger).contains(ackSequence) else {
                throw AgentConnectorError.invalidFrame
            }
            decodedTurnID = nil
        } else if frame.kind == "heartbeat" {
            if let peerSequence = frame.payload.lastReceivedSeq,
               !(0 ... Self.maximumSafeInteger).contains(peerSequence) {
                throw AgentConnectorError.invalidFrame
            }
            decodedTurnID = nil
        } else {
            guard let turnIDValue = frame.payload.turnID else {
                throw AgentConnectorError.invalidFrame
            }
            decodedTurnID = try frame.validatedUUID(turnIDValue)
            guard decodedConversationID != nil else {
                throw AgentConnectorError.invalidFrame
            }
            switch frame.kind {
            case "turn.accepted":
                break
            case "assistant.delta":
                guard let revision = frame.payload.revision,
                      (1 ... 100_000).contains(revision),
                      let text = frame.payload.text,
                      text.count <= 32_000 else {
                    throw AgentConnectorError.invalidFrame
                }
            case "assistant.completed":
                guard let text = frame.payload.text,
                      !text.isEmpty, text.count <= 32_000 else {
                    throw AgentConnectorError.invalidFrame
                }
            case "assistant.activity.upsert":
                guard let revision = frame.payload.revision,
                      (1 ... 100_000).contains(revision),
                      let rawStatus = frame.payload.status,
                      AgentConnectorActivityStatus(rawValue: rawStatus) != nil else {
                    throw AgentConnectorError.invalidFrame
                }
            case "assistant.activity.clear":
                guard let revision = frame.payload.revision,
                      (1 ... 100_000).contains(revision) else {
                    throw AgentConnectorError.invalidFrame
                }
            case "assistant.attachment":
                guard let rawAttachmentID = frame.payload.attachmentID,
                      let attachmentID = try? frame.validatedUUID(rawAttachmentID),
                      let fileName = frame.payload.fileName,
                      let mediaType = frame.payload.mediaType,
                      let byteCount = frame.payload.byteCount,
                      let sha256 = frame.payload.sha256,
                      let downloadPath = frame.payload.downloadPath,
                      let expiresAt = frame.payload.expiresAt,
                      let decodedTurnID,
                      let attachment = try? AgentConnectorAttachmentMetadata(
                        connectionID: connectionID,
                        turnID: decodedTurnID,
                        attachmentID: attachmentID,
                        fileName: fileName,
                        mediaType: mediaType,
                        byteCount: byteCount,
                        sha256: sha256,
                        expiresAtMilliseconds: expiresAt
                      ).validated(),
                      attachment.downloadPath == downloadPath,
                      expiresAt > frame.sentAt,
                      expiresAt - frame.sentAt <= 7 * 24 * 60 * 60 * 1_000 else {
                    throw AgentConnectorError.invalidFrame
                }
            case "turn.error":
                guard let code = frame.payload.code,
                      !code.isEmpty, code.count <= 64,
                      let message = frame.payload.message,
                      !message.isEmpty, message.count <= 240,
                      frame.payload.retryable != nil else {
                    throw AgentConnectorError.invalidFrame
                }
            default:
                throw AgentConnectorError.invalidFrame
            }
        }

        // The Worker may replay an old terminal frame when this device persisted its ACK
        // before the peer observed it. Validate its envelope and identifiers, ACK it again,
        // and only then apply current-turn identity checks to genuinely new frames.
        let acknowledged = cursorStore.lastAcknowledgedInbound(connectionID: connectionID)
        if frame.seq <= acknowledged {
            return .alreadyAcknowledged
        }

        guard frame.seq > lastSocketSequence,
              seenMessageIDs.insert(messageID).inserted else {
            throw AgentConnectorError.staleOrDuplicateFrame
        }
        lastSocketSequence = frame.seq
        if seenMessageIDs.count > 512 {
            seenMessageIDs.removeAll(keepingCapacity: true)
            seenMessageIDs.insert(messageID)
        }
        if !["ack", "heartbeat"].contains(frame.kind),
           decodedTurnID != turnID || decodedConversationID != conversationID {
            return .unrelated
        }
        if let decodedConversationID,
           ["ack", "heartbeat"].contains(frame.kind),
           decodedConversationID != conversationID {
            throw AgentConnectorError.invalidFrame
        }
        return .new
    }

    mutating func prepareForReconnect() {
        lastSocketSequence = cursorStore.lastAcknowledgedInbound(
            connectionID: connectionID
        )
        seenMessageIDs.removeAll(keepingCapacity: true)
    }
}

protocol AgentConnectorSocket: Sendable {
    func send(text: String) async throws
    func receiveText() async throws -> String
    func close()
}

protocol AgentConnectorSocketConnecting: Sendable {
    func connect(
        request: URLRequest,
        maximumMessageBytes: Int
    ) throws -> any AgentConnectorSocket
}

struct URLSessionAgentConnectorSocketFactory: AgentConnectorSocketConnecting, Sendable {
    func connect(
        request: URLRequest,
        maximumMessageBytes: Int
    ) throws -> any AgentConnectorSocket {
        URLSessionAgentConnectorSocket(
            request: request,
            maximumMessageBytes: maximumMessageBytes
        )
    }
}

private final class URLSessionAgentConnectorSocket: AgentConnectorSocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let statusRequest: URLRequest?

    init(request: URLRequest, maximumMessageBytes: Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 300
        let delegate = AgentConnectorNoRedirectDelegate()
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        if let requestURL = request.url,
           let statusURL = AgentConnectorTransportErrorMapper.statusURL(
                forEventsURL: requestURL
           ) {
            var statusRequest = request
            statusRequest.url = statusURL
            statusRequest.httpMethod = "GET"
            statusRequest.httpBody = nil
            self.statusRequest = statusRequest
        } else {
            statusRequest = nil
        }
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageBytes
        task.resume()
    }

    func send(text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw await translatedTransportError(error)
        }
    }

    func receiveText() async throws -> String {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw await translatedTransportError(error)
        }
        guard case let .string(text) = message else {
            throw AgentConnectorError.frameTooLarge
        }
        return text
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func permanentPairingError() async -> AgentConnectorError? {
        guard let statusRequest else { return nil }
        do {
            let (_, response) = try await session.data(for: statusRequest)
            guard let http = response as? HTTPURLResponse else { return nil }
            return AgentConnectorTransportErrorMapper.error(
                forHTTPStatusCode: http.statusCode
            )
        } catch {
            return nil
        }
    }

    private func translatedTransportError(_ error: Error) async -> Error {
        if let statusCode = (task.response as? HTTPURLResponse)?.statusCode,
           let connectorError = AgentConnectorTransportErrorMapper.error(
            forHTTPStatusCode: statusCode
           ) {
            return connectorError
        }
        if let connectorError = await permanentPairingError() {
            return connectorError
        }
        return error
    }
}

enum AgentConnectorTransportErrorMapper {
    static func error(forHTTPStatusCode statusCode: Int) -> AgentConnectorError? {
        switch statusCode {
        case 401, 403, 404, 410:
            .pairingRequired
        default:
            nil
        }
    }

    static func statusURL(forEventsURL url: URL) -> URL? {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else { return nil }
        switch components.scheme?.lowercased() {
        case "wss": components.scheme = "https"
        case "ws": components.scheme = "http"
        default: return nil
        }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 4,
              path[0] == "v1",
              path[1] == "connectors",
              UUID(uuidString: String(path[2])) != nil,
              path[3] == "events" else {
            return nil
        }
        components.path = "/v1/connectors/\(path[2])/status"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct AgentConnectorReconnectPolicy: Equatable, Sendable {
    static let production = Self(
        maximumReconnectAttempts: 2,
        baseDelayMilliseconds: 200
    )

    let maximumReconnectAttempts: Int
    let baseDelayMilliseconds: Int

    init(maximumReconnectAttempts: Int, baseDelayMilliseconds: Int) {
        self.maximumReconnectAttempts = min(max(0, maximumReconnectAttempts), 3)
        self.baseDelayMilliseconds = min(max(0, baseDelayMilliseconds), 1_000)
    }

    func wait(beforeAttempt attempt: Int) async throws {
        guard baseDelayMilliseconds > 0 else {
            try Task.checkCancellation()
            return
        }
        let multiplier = min(max(1, attempt), 3)
        try await Task.sleep(
            for: .milliseconds(baseDelayMilliseconds * multiplier)
        )
    }
}

struct OpenClawAgentConnector: AgentConnector, Sendable {
    static let maximumFrameBytes = 64 * 1_024

    let origin: AgentConnectorOrigin
    let cursorStore: AgentConnectorCursorStore
    let outboxVault: any AgentConnectorOutboxVault
    let socketConnector: any AgentConnectorSocketConnecting
    let artifactService: any AgentConnectorArtifactServicing
    let reconnectPolicy: AgentConnectorReconnectPolicy
    let nowMilliseconds: @Sendable () -> Int64

    init(
        origin: AgentConnectorOrigin,
        cursorStore: AgentConnectorCursorStore = AgentConnectorCursorStore(),
        outboxVault: (any AgentConnectorOutboxVault)? = nil,
        socketConnector: any AgentConnectorSocketConnecting = URLSessionAgentConnectorSocketFactory(),
        artifactService injectedArtifactService: (any AgentConnectorArtifactServicing)? = nil,
        reconnectPolicy: AgentConnectorReconnectPolicy = .production,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.origin = origin
        self.cursorStore = cursorStore
        self.outboxVault = outboxVault ?? KeychainAgentConnectorOutboxVault(
            gatewayOrigin: origin.canonicalString
        )
        self.socketConnector = socketConnector
        artifactService = injectedArtifactService
            ?? OpenClawAgentConnectorArtifactService(origin: origin)
        self.reconnectPolicy = reconnectPolicy
        self.nowMilliseconds = nowMilliseconds
    }

    func streamTurn(
        _ request: AgentConnectorTurnRequest,
        clientToken: String
    ) -> AsyncThrowingStream<AgentConnectorStreamEvent, Error> {
        let session = OpenClawTurnSession(
            origin: origin,
            cursorStore: cursorStore,
            outboxVault: outboxVault,
            request: request,
            clientToken: clientToken,
            socketConnector: socketConnector,
            artifactService: artifactService,
            reconnectPolicy: reconnectPolicy,
            nowMilliseconds: nowMilliseconds
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await session.run { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
            }
        }
    }
}

extension OpenClawAgentConnector: AgentConnectorPersistentCancellation {
    func cancelTurn(
        _ request: AgentConnectorTurnRequest,
        clientToken: String
    ) async throws {
        let session = OpenClawTurnSession(
            origin: origin,
            cursorStore: cursorStore,
            outboxVault: outboxVault,
            request: request,
            clientToken: clientToken,
            socketConnector: socketConnector,
            artifactService: artifactService,
            reconnectPolicy: reconnectPolicy,
            nowMilliseconds: nowMilliseconds
        )
        try await session.cancelPersistently()
    }
}

private actor OpenClawTurnSession {
    private let origin: AgentConnectorOrigin
    private let cursorStore: AgentConnectorCursorStore
    private let outboxVault: any AgentConnectorOutboxVault
    private let request: AgentConnectorTurnRequest
    private let clientToken: String
    private let socketConnector: any AgentConnectorSocketConnecting
    private let artifactService: any AgentConnectorArtifactServicing
    private let reconnectPolicy: AgentConnectorReconnectPolicy
    private let nowMilliseconds: @Sendable () -> Int64
    private var socket: (any AgentConnectorSocket)?
    private var isTerminal = false
    private var pendingTurn: AgentConnectorPendingTurn?
    private var inboundValidator: AgentConnectorInboundValidator
    private var lastRevision = 0
    private var lastActivityRevision = 0

    init(
        origin: AgentConnectorOrigin,
        cursorStore: AgentConnectorCursorStore,
        outboxVault: any AgentConnectorOutboxVault,
        request: AgentConnectorTurnRequest,
        clientToken: String,
        socketConnector: any AgentConnectorSocketConnecting,
        artifactService: any AgentConnectorArtifactServicing,
        reconnectPolicy: AgentConnectorReconnectPolicy,
        nowMilliseconds: @escaping @Sendable () -> Int64
    ) {
        self.origin = origin
        self.cursorStore = cursorStore
        self.outboxVault = outboxVault
        self.request = request
        self.clientToken = clientToken
        self.socketConnector = socketConnector
        self.artifactService = artifactService
        self.reconnectPolicy = reconnectPolicy
        self.nowMilliseconds = nowMilliseconds
        inboundValidator = AgentConnectorInboundValidator(
            connectionID: request.connectionID,
            conversationID: request.conversationID,
            turnID: request.turnID,
            cursorStore: cursorStore
        )
    }

    func run(yield: @Sendable (AgentConnectorStreamEvent) -> Void) async throws {
        guard request.text.count <= 32_000,
              !request.text.isEmpty,
              request.accountID.count <= 64,
              request.agentID.count <= 64,
              !request.displayName.isEmpty,
              request.displayName.count <= 80 else {
            throw AgentConnectorError.invalidFrame
        }
        _ = try AgentConnectorTokenValidator.normalized(clientToken)
        let durableTurn = try loadOrCreatePendingTurn()
        pendingTurn = durableTurn
        yield(.submissionSaved)
        if durableTurn.isExpired(at: nowMilliseconds()) {
            throw AgentConnectorError.recoveryExpired
        }
        for attachment in durableTurn.attachments ?? [] {
            yield(.attachment(attachment))
        }
        if let terminal = durableTurn.terminal {
            isTerminal = true
            switch terminal.kind {
            case .completed:
                guard let text = terminal.text else {
                    throw AgentConnectorError.invalidFrame
                }
                yield(.completed(text))
                return
            case .failed:
                let code = terminal.code ?? "remote_error"
                let message = terminal.message
                    ?? "OpenClaw could not complete this message."
                if code == "conversation_busy" {
                    throw AgentConnectorError.conversationBusy
                }
                throw AgentConnectorError.remote(code: code, message: message)
            }
        }
        if durableTurn.cancelFrame != nil {
            try await flushCancellation()
            throw CancellationError()
        }

        if let activity = durableTurn.activity {
            lastActivityRevision = activity.revision
            if activity.status == nil {
                yield(.activityCleared(revision: activity.revision))
            } else {
                yield(.activity(activity))
            }
        }

        socket = try openSocket()
        defer {
            socket?.close()
            socket = nil
        }

        let submitFrame = durableTurn.submitFrame

        var accepted = durableTurn.turnAccepted
        var finished = false
        var submitIsDurablyPersisted = durableTurn.submitDurablyPersisted
        var submitNeedsSending = !submitIsDurablyPersisted
        var reconnectAttempts = 0
        while !finished {
            do {
                try Task.checkCancellation()
                if submitNeedsSending {
                    try await sendEncoded(submitFrame)
                    submitNeedsSending = false
                }
                guard let socket else {
                    throw AgentConnectorError.connectionUnavailable
                }
                let text: String
                do {
                    text = try await socket.receiveText()
                } catch is CancellationError {
                    throw CancellationError()
                } catch let connectorError as AgentConnectorError {
                    throw connectorError
                } catch {
                    throw AgentConnectorError.connectionUnavailable
                }
                guard let data = text.data(using: .utf8),
                      data.count <= OpenClawAgentConnector.maximumFrameBytes else {
                    throw AgentConnectorError.frameTooLarge
                }
                let kind: String
                do {
                    kind = try JSONDecoder().decode(
                        AgentConnectorWireKindProbe.self,
                        from: data
                    ).kind
                } catch {
                    throw AgentConnectorError.invalidFrame
                }
                if kind == "relay.persisted" {
                    let receipt: AgentConnectorRelayPersistenceReceipt
                    do {
                        receipt = try JSONDecoder().decode(
                            AgentConnectorRelayPersistenceReceipt.self,
                            from: data
                        )
                    } catch let connectorError as AgentConnectorError {
                        throw connectorError
                    } catch {
                        throw AgentConnectorError.invalidFrame
                    }
                    let receiptDisposition = try receipt.disposition(
                        connectionID: request.connectionID,
                        outboundFrame: submitFrame
                    )
                    if receiptDisposition == .matching {
                        try persistSubmitState(isDurable: true)
                        submitIsDurablyPersisted = true
                    }
                    continue
                }
                let frame: AgentConnectorWireFrame
                do {
                    frame = try JSONDecoder().decode(
                        AgentConnectorWireFrame.self,
                        from: data
                    )
                } catch let connectorError as AgentConnectorError {
                    throw connectorError
                } catch {
                    throw AgentConnectorError.invalidFrame
                }
                let disposition = try inboundValidator.validate(frame)
                if disposition == .alreadyAcknowledged {
                    if frame.kind != "ack" {
                        try await sendAcknowledgement(frame.seq)
                    }
                    continue
                }
                if disposition == .unrelated {
                    try await sendAcknowledgement(frame.seq)
                    cursorStore.acknowledgeInbound(
                        frame.seq,
                        connectionID: request.connectionID
                    )
                    continue
                }
                switch frame.kind {
                case "ack":
                    continue
                case "heartbeat":
                    try await acknowledge(frame)
                    continue
                case "turn.accepted":
                    if accepted {
                        // The accepted bit is saved before its ACK. If the process exits in
                        // that narrow window, the relay must be able to replay the same
                        // strictly validated lifecycle event without stranding the turn.
                        guard pendingTurn?.turnAccepted == true else {
                            throw AgentConnectorError.invalidFrame
                        }
                        try await acknowledge(frame)
                        continue
                    }
                    try persistAcceptedTurn()
                    try await acknowledge(frame)
                    accepted = true
                    submitIsDurablyPersisted = true
                    yield(.accepted)
                case "assistant.activity.upsert":
                    guard accepted,
                          let revision = frame.payload.revision,
                          let rawStatus = frame.payload.status,
                          let status = AgentConnectorActivityStatus(rawValue: rawStatus) else {
                        throw AgentConnectorError.invalidFrame
                    }
                    let activity = try AgentConnectorActivityUpdate(
                        revision: revision,
                        status: status
                    ).validated()
                    if revision == lastActivityRevision {
                        guard pendingTurn?.activity == activity else {
                            throw AgentConnectorError.invalidFrame
                        }
                        try await acknowledge(frame)
                        continue
                    }
                    guard revision > lastActivityRevision else {
                        throw AgentConnectorError.invalidFrame
                    }
                    try persistActivity(activity)
                    try await acknowledge(frame)
                    lastActivityRevision = revision
                    yield(.activity(activity))
                case "assistant.activity.clear":
                    guard accepted,
                          let revision = frame.payload.revision else {
                        throw AgentConnectorError.invalidFrame
                    }
                    let activity = try AgentConnectorActivityUpdate(
                        revision: revision,
                        status: nil
                    ).validated()
                    if revision == lastActivityRevision {
                        guard pendingTurn?.activity == activity else {
                            throw AgentConnectorError.invalidFrame
                        }
                        try await acknowledge(frame)
                        continue
                    }
                    guard revision > lastActivityRevision else {
                        throw AgentConnectorError.invalidFrame
                    }
                    try persistActivity(activity)
                    try await acknowledge(frame)
                    lastActivityRevision = revision
                    yield(.activityCleared(revision: revision))
                case "assistant.attachment":
                    guard accepted else { throw AgentConnectorError.invalidFrame }
                    // The relay may delete its blob as soon as this frame is ACKed. Full GET,
                    // exact verification, Complete/no-backup storage, and durable turn binding
                    // therefore all happen before the acknowledgement is sent.
                    let stored = try await downloadAndPersistAttachment(from: frame)
                    try await acknowledge(frame)
                    yield(.attachment(stored))
                case "assistant.delta":
                    guard accepted,
                          let revision = frame.payload.revision,
                          revision > lastRevision,
                          revision <= 100_000,
                          let value = frame.payload.text,
                          value.count <= 32_000 else {
                        throw AgentConnectorError.invalidFrame
                    }
                    try await acknowledge(frame)
                    lastRevision = revision
                    yield(.cumulativeText(value))
                case "assistant.completed":
                    guard accepted, !finished,
                          let value = frame.payload.text?.trimmingCharacters(
                            in: .whitespacesAndNewlines
                          ),
                          !value.isEmpty, value.count <= 32_000 else {
                        throw AgentConnectorError.invalidFrame
                    }
                    try persistTerminal(.completed(value))
                    try await acknowledge(frame)
                    finished = true
                    isTerminal = true
                    submitIsDurablyPersisted = true
                    yield(.completed(value))
                case "turn.error":
                    isTerminal = true
                    submitIsDurablyPersisted = true
                    let code = frame.payload.code ?? "remote_error"
                    let message = frame.payload.message?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) ?? "OpenClaw could not complete this message."
                    guard frame.payload.retryable != nil,
                          !code.isEmpty, code.count <= 64,
                          !message.isEmpty, message.count <= 240 else {
                        throw AgentConnectorError.invalidFrame
                    }
                    let discardedAttachments = pendingTurn?.attachments ?? []
                    if !discardedAttachments.isEmpty {
                        await artifactService.deleteArtifacts(
                            discardedAttachments.map(\.metadata.conversationReference)
                        )
                        try clearPendingAttachments()
                    }
                    try persistTerminal(.failed(
                        code: String(code.prefix(64)),
                        message: message
                    ))
                    try await acknowledge(frame)
                    if code == "conversation_busy" {
                        throw AgentConnectorError.conversationBusy
                    }
                    throw AgentConnectorError.remote(
                        code: String(code.prefix(64)),
                        message: message
                    )
                default:
                    throw AgentConnectorError.invalidFrame
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let connectorError as AgentConnectorError
                where connectorError == .connectionUnavailable {
                guard !isTerminal,
                      reconnectAttempts < reconnectPolicy.maximumReconnectAttempts else {
                    throw AgentConnectorError.connectionUnavailable
                }
                reconnectAttempts += 1
                submitNeedsSending = !submitIsDurablyPersisted && !accepted
                socket?.close()
                socket = nil
                inboundValidator.prepareForReconnect()
                try await reconnectPolicy.wait(beforeAttempt: reconnectAttempts)
                try Task.checkCancellation()
                do {
                    socket = try openSocket()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if reconnectAttempts >= reconnectPolicy.maximumReconnectAttempts {
                        throw AgentConnectorError.connectionUnavailable
                    }
                }
            }
        }
    }

    func cancelPersistently() async throws {
        let durableTurn = try loadOrCreatePendingTurn()
        pendingTurn = durableTurn
        if durableTurn.isExpired(at: nowMilliseconds()) {
            throw AgentConnectorError.recoveryExpired
        }
        guard durableTurn.terminal == nil else {
            isTerminal = true
            return
        }
        isTerminal = true
        socket?.close()
        socket = nil
        try await flushCancellation()
    }

    private func loadOrCreatePendingTurn() throws -> AgentConnectorPendingTurn {
        if let existing = try outboxVault.load(
            connectionID: request.connectionID,
            turnID: request.turnID
        ) {
            guard existing.request == request else {
                throw AgentConnectorError.invalidFrame
            }
            return existing
        }
        let createdAt = nowMilliseconds()
        guard (0 ... 9_007_199_254_740_991).contains(createdAt),
              createdAt <= 9_007_199_254_740_991
                - AgentConnectorPendingTurn.maximumLifetimeMilliseconds else {
            throw AgentConnectorError.invalidFrame
        }
        let submit = try makeEncodedFrame(
            kind: "turn.submit",
            payload: .init(
                turnID: request.turnID.uuidString.lowercased(),
                accountID: request.accountID,
                capabilities: ["activity-v1", "attachments-v1"],
                text: request.text
            )
        )
        let turn = try AgentConnectorPendingTurn(
            v: 1,
            connectionID: request.connectionID,
            conversationID: request.conversationID,
            turnID: request.turnID,
            accountID: request.accountID,
            agentID: request.agentID,
            displayName: request.displayName,
            userMessageID: request.userMessageID,
            assistantMessageID: request.assistantMessageID,
            userText: request.text,
            createdAtMilliseconds: createdAt,
            expiresAtMilliseconds: createdAt
                + AgentConnectorPendingTurn.maximumLifetimeMilliseconds,
            submitFrame: submit,
            submitDurablyPersisted: false,
            turnAccepted: false,
            cancelFrame: nil,
            terminal: nil
        ).validated()
        try outboxVault.save(turn)
        return turn
    }

    private func persistSubmitState(isDurable: Bool) throws {
        guard var turn = pendingTurn else {
            throw AgentConnectorError.invalidFrame
        }
        if isDurable && !turn.submitDurablyPersisted {
            turn.submitDurablyPersisted = true
            try outboxVault.save(turn)
            pendingTurn = turn
        }
    }

    private func persistAcceptedTurn() throws {
        guard var turn = pendingTurn else {
            throw AgentConnectorError.invalidFrame
        }
        turn.submitDurablyPersisted = true
        turn.turnAccepted = true
        try outboxVault.save(turn)
        pendingTurn = turn
    }

    private func persistTerminal(_ terminal: AgentConnectorPersistedTerminal) throws {
        guard var turn = pendingTurn else {
            throw AgentConnectorError.invalidFrame
        }
        turn.submitDurablyPersisted = true
        turn.terminal = try terminal.validated()
        try outboxVault.save(turn)
        pendingTurn = turn
    }

    private func persistActivity(_ activity: AgentConnectorActivityUpdate) throws {
        guard var turn = pendingTurn else {
            throw AgentConnectorError.invalidFrame
        }
        turn.activity = try activity.validated()
        try outboxVault.save(turn)
        pendingTurn = turn
    }

    private func downloadAndPersistAttachment(
        from frame: AgentConnectorWireFrame
    ) async throws -> AgentConnectorStoredAttachment {
        guard frame.kind == "assistant.attachment",
              let rawAttachmentID = frame.payload.attachmentID,
              let attachmentID = try? frame.validatedUUID(rawAttachmentID),
              let fileName = frame.payload.fileName,
              let mediaType = frame.payload.mediaType,
              let byteCount = frame.payload.byteCount,
              let sha256 = frame.payload.sha256,
              let downloadPath = frame.payload.downloadPath,
              let expiresAt = frame.payload.expiresAt else {
            throw AgentConnectorError.invalidFrame
        }
        let metadata = try AgentConnectorAttachmentMetadata(
            connectionID: request.connectionID,
            turnID: request.turnID,
            attachmentID: attachmentID,
            fileName: fileName,
            mediaType: mediaType,
            byteCount: byteCount,
            sha256: sha256,
            expiresAtMilliseconds: expiresAt
        ).validated(nowMilliseconds: nowMilliseconds())
        guard metadata.downloadPath == downloadPath else {
            throw AgentConnectorError.invalidFrame
        }
        let stored = try await artifactService.downloadAndStore(
            metadata,
            clientToken: clientToken
        )
        try persistAttachment(stored)
        return stored
    }

    private func persistAttachment(_ rawAttachment: AgentConnectorStoredAttachment) throws {
        let attachment = try rawAttachment.validated()
        guard var turn = pendingTurn,
              attachment.metadata.connectionID == request.connectionID,
              attachment.metadata.turnID == request.turnID else {
            throw AgentConnectorError.invalidFrame
        }
        var attachments = turn.attachments ?? []
        if let existing = attachments.first(where: {
            $0.metadata.attachmentID == attachment.metadata.attachmentID
        }) {
            guard existing == attachment else {
                throw AgentConnectorError.invalidFrame
            }
            return
        }
        attachments.append(attachment)
        guard attachments.count <= 8,
              attachments.reduce(0, { $0 + $1.metadata.byteCount })
                <= 64 * 1_024 * 1_024 else {
            throw AgentConnectorError.responseTooLarge
        }
        turn.attachments = attachments
        try outboxVault.save(turn)
        pendingTurn = turn
    }

    private func clearPendingAttachments() throws {
        guard var turn = pendingTurn else {
            throw AgentConnectorError.invalidFrame
        }
        turn.attachments = nil
        try outboxVault.save(turn)
        pendingTurn = turn
    }

    private func flushCancellation() async throws {
        guard var turn = pendingTurn else {
            throw AgentConnectorError.invalidFrame
        }
        if turn.terminal != nil {
            return
        }
        if turn.isExpired(at: nowMilliseconds()) {
            throw AgentConnectorError.recoveryExpired
        }
        let cancelFrame: AgentConnectorEncodedFrame
        if let existing = turn.cancelFrame {
            cancelFrame = existing
        } else {
            cancelFrame = try makeEncodedFrame(
                kind: "turn.cancel",
                payload: .init(turnID: request.turnID.uuidString.lowercased())
            )
            turn.cancelFrame = cancelFrame
            try outboxVault.save(turn)
            pendingTurn = turn
        }

        var attempt = 0
        while true {
            do {
                socket?.close()
                socket = try openSocket()
                try await sendEncoded(cancelFrame)
                while true {
                    guard let socket else {
                        throw AgentConnectorError.connectionUnavailable
                    }
                    let text = try await receiveText(
                        from: socket,
                        timeoutMilliseconds: 2_000
                    )
                    guard let data = text.data(using: .utf8),
                          data.count <= OpenClawAgentConnector.maximumFrameBytes else {
                        throw AgentConnectorError.frameTooLarge
                    }
                    let kind: String
                    do {
                        kind = try JSONDecoder().decode(
                            AgentConnectorWireKindProbe.self,
                            from: data
                        ).kind
                    } catch {
                        throw AgentConnectorError.invalidFrame
                    }
                    if kind == "relay.persisted" {
                        let receipt: AgentConnectorRelayPersistenceReceipt
                        do {
                            receipt = try JSONDecoder().decode(
                                AgentConnectorRelayPersistenceReceipt.self,
                                from: data
                            )
                        } catch let connectorError as AgentConnectorError {
                            throw connectorError
                        } catch {
                            throw AgentConnectorError.invalidFrame
                        }
                        let disposition = try receipt.disposition(
                            connectionID: request.connectionID,
                            outboundFrame: cancelFrame
                        )
                        if disposition == .matching {
                            await artifactService.deleteArtifacts(
                                (pendingTurn?.attachments ?? [])
                                    .map(\.metadata.conversationReference)
                            )
                            try outboxVault.delete(
                                connectionID: request.connectionID,
                                turnID: request.turnID
                            )
                            pendingTurn = nil
                            socket.close()
                            self.socket = nil
                            return
                        }
                        continue
                    }
                    let frame: AgentConnectorWireFrame
                    do {
                        frame = try JSONDecoder().decode(
                            AgentConnectorWireFrame.self,
                            from: data
                        )
                    } catch let connectorError as AgentConnectorError {
                        throw connectorError
                    } catch {
                        throw AgentConnectorError.invalidFrame
                    }
                    let disposition = try inboundValidator.validate(frame)
                    if disposition == .alreadyAcknowledged {
                        if frame.kind != "ack" {
                            try await sendAcknowledgement(frame.seq)
                        }
                        continue
                    }
                    if disposition == .unrelated {
                        try await sendAcknowledgement(frame.seq)
                        cursorStore.acknowledgeInbound(
                            frame.seq,
                            connectionID: request.connectionID
                        )
                        continue
                    }
                    if frame.kind == "assistant.attachment" {
                        _ = try await downloadAndPersistAttachment(from: frame)
                        try await acknowledge(frame)
                        continue
                    }
                    if frame.kind == "assistant.completed",
                       let text = frame.payload.text {
                        // The terminal won the race, so preserve it for history
                        // reconciliation instead of overwriting it with cancellation.
                        try persistTerminal(.completed(text))
                        try await acknowledge(frame)
                        return
                    }
                    if frame.kind == "turn.error",
                       let code = frame.payload.code,
                       let message = frame.payload.message {
                        let discardedAttachments = pendingTurn?.attachments ?? []
                        if !discardedAttachments.isEmpty {
                            await artifactService.deleteArtifacts(
                                discardedAttachments.map(\.metadata.conversationReference)
                            )
                            try clearPendingAttachments()
                        }
                        try persistTerminal(.failed(code: code, message: message))
                        try await acknowledge(frame)
                        return
                    }
                    if frame.kind != "ack" {
                        try await acknowledge(frame)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let connectorError as AgentConnectorError
                where connectorError == .connectionUnavailable {
                guard attempt < reconnectPolicy.maximumReconnectAttempts else {
                    socket?.close()
                    socket = nil
                    throw AgentConnectorError.connectionUnavailable
                }
                attempt += 1
                socket?.close()
                socket = nil
                inboundValidator.prepareForReconnect()
                try await reconnectPolicy.wait(beforeAttempt: attempt)
            }
        }
    }

    private func receiveText(
        from socket: any AgentConnectorSocket,
        timeoutMilliseconds: Int
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await socket.receiveText() }
            group.addTask {
                try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                throw AgentConnectorError.connectionUnavailable
            }
            guard let first = try await group.next() else {
                throw AgentConnectorError.connectionUnavailable
            }
            group.cancelAll()
            return first
        }
    }

    private func openSocket() throws -> any AgentConnectorSocket {
        var urlRequest = URLRequest(
            url: origin.eventsURL(connectionID: request.connectionID)
        )
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("Bearer \(clientToken)", forHTTPHeaderField: "Authorization")
        return try socketConnector.connect(
            request: urlRequest,
            maximumMessageBytes: OpenClawAgentConnector.maximumFrameBytes
        )
    }

    private func sendAcknowledgement(_ inboundSequence: Int) async throws {
        try await sendNewFrame(kind: "ack", payload: .init(ackSeq: inboundSequence))
    }

    private func acknowledge(_ frame: AgentConnectorWireFrame) async throws {
        try await sendAcknowledgement(frame.seq)
        cursorStore.acknowledgeInbound(frame.seq, connectionID: request.connectionID)
    }

    private func makeEncodedFrame(
        kind: String,
        payload: AgentConnectorWirePayload
    ) throws -> AgentConnectorEncodedFrame {
        let sequence = cursorStore.nextOutbound(connectionID: request.connectionID)
        let messageID = UUID()
        let includesConversation = !["ack", "heartbeat"].contains(kind)
        let frame = AgentConnectorWireFrame(
            v: 1,
            kind: kind,
            connectionID: request.connectionID.uuidString.lowercased(),
            conversationID: includesConversation
                ? request.conversationID.uuidString.lowercased()
                : nil,
            messageID: messageID.uuidString.lowercased(),
            seq: sequence,
            replyTo: nil,
            sentAt: nowMilliseconds(),
            payload: payload
        )
        let data = try JSONEncoder().encode(frame)
        guard data.count <= OpenClawAgentConnector.maximumFrameBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw AgentConnectorError.frameTooLarge
        }
        return AgentConnectorEncodedFrame(
            sequence: sequence,
            messageID: messageID,
            text: text
        )
    }

    private func sendNewFrame(
        kind: String,
        payload: AgentConnectorWirePayload
    ) async throws {
        try await sendEncoded(makeEncodedFrame(kind: kind, payload: payload))
    }

    private func sendEncoded(_ frame: AgentConnectorEncodedFrame) async throws {
        guard let socket else { throw AgentConnectorError.connectionUnavailable }
        do {
            try await socket.send(text: frame.text)
        } catch is CancellationError {
            throw CancellationError()
        } catch let connectorError as AgentConnectorError {
            throw connectorError
        } catch {
            throw AgentConnectorError.connectionUnavailable
        }
    }
}
