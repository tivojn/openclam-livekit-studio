import Foundation

struct AgentConnectorID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    static let openClaw = Self(rawValue: "openclaw")

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    func validated() throws -> Self {
        guard rawValue.range(
            of: #"^[a-z][a-z0-9-]{0,31}$"#,
            options: .regularExpression
        ) != nil else {
            throw AgentConnectorError.invalidBinding
        }
        return self
    }
}

struct AvatarAgentConnectorBinding: Codable, Equatable, Hashable, Sendable {
    let connectorID: AgentConnectorID
    let connectionID: UUID
    let accountID: String
    let agentID: String
    let displayName: String

    func validated() throws -> Self {
        _ = try connectorID.validated()
        guard Self.isValidRemoteIdentifier(accountID),
              Self.isValidRemoteIdentifier(agentID) else {
            throw AgentConnectorError.invalidBinding
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentConnectorError.invalidBinding
        }
        return .init(
            connectorID: connectorID,
            connectionID: connectionID,
            accountID: accountID,
            agentID: agentID,
            displayName: name
        )
    }

    private static func isValidRemoteIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"#,
            options: .regularExpression
        ) != nil
    }
}

struct AgentConversationRoute: Codable, Equatable, Hashable, Sendable {
    var connectorBinding: AvatarAgentConnectorBinding?

    static let onDevice = Self(connectorBinding: nil)

    static func remote(_ binding: AvatarAgentConnectorBinding) -> Self {
        .init(connectorBinding: binding)
    }

    var isRemote: Bool { connectorBinding != nil }
}

enum AgentConnectorV1Policy {
    static func permitsLocalLanguageModel(for route: AgentConversationRoute) -> Bool {
        !route.isRemote
    }

    static func permitsAttachments(for route: AgentConversationRoute) -> Bool {
        !route.isRemote
    }

    static func permitsLocalTools(for route: AgentConversationRoute) -> Bool {
        !route.isRemote
    }
}

struct AgentConnectorAccount: Codable, Equatable, Hashable, Identifiable, Sendable {
    let accountID: String
    let agentID: String
    let displayName: String

    var id: String { "\(accountID)|\(agentID)" }

    enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case agentID = "agentId"
        case displayName
    }

    init(accountID: String, agentID: String, displayName: String) {
        self.accountID = accountID
        self.agentID = agentID
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        try AgentConnectorStrictCoding.requireExactKeys(
            decoder,
            expected: ["accountId", "agentId", "displayName"],
            error: .invalidPairingResponse
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(String.self, forKey: .accountID)
        agentID = try container.decode(String.self, forKey: .agentID)
        displayName = try container.decode(String.self, forKey: .displayName)
    }

    func validated() throws -> Self {
        let binding = AvatarAgentConnectorBinding(
            connectorID: .openClaw,
            connectionID: UUID(),
            accountID: accountID,
            agentID: agentID,
            displayName: displayName
        )
        let validated = try binding.validated()
        return .init(
            accountID: validated.accountID,
            agentID: validated.agentID,
            displayName: validated.displayName
        )
    }
}

struct AgentConnectorConnection: Codable, Equatable, Hashable, Identifiable, Sendable {
    let connectorID: AgentConnectorID
    let connectionID: UUID
    let gatewayLabel: String
    let accounts: [AgentConnectorAccount]

    var id: UUID { connectionID }

    func validated() throws -> Self {
        _ = try connectorID.validated()
        let label = gatewayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 80,
              (1 ... 32).contains(accounts.count),
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentConnectorError.invalidPairingResponse
        }
        let validatedAccounts = try accounts.map { try $0.validated() }
        guard Set(validatedAccounts.map(\.id)).count == validatedAccounts.count else {
            throw AgentConnectorError.invalidPairingResponse
        }
        return .init(
            connectorID: connectorID,
            connectionID: connectionID,
            gatewayLabel: label,
            accounts: validatedAccounts
        )
    }

    func binding(for account: AgentConnectorAccount) -> AvatarAgentConnectorBinding {
        .init(
            connectorID: connectorID,
            connectionID: connectionID,
            accountID: account.accountID,
            agentID: account.agentID,
            displayName: account.displayName
        )
    }
}

struct AgentConnectorPairingRedeemRequest: Encodable, Equatable, Sendable {
    let v = 1
    let code: String
    let installationID: UUID
    let deviceLabel: String

    enum CodingKeys: String, CodingKey {
        case v, code
        case installationID = "installationId"
        case deviceLabel
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(code, forKey: .code)
        try container.encode(
            installationID.uuidString.lowercased(),
            forKey: .installationID
        )
        try container.encode(deviceLabel, forKey: .deviceLabel)
    }
}

struct AgentConnectorPairingRedeemResponse: Decodable, Equatable, Sendable {
    let v: Int
    let connectionID: UUID
    let gatewayLabel: String
    let accounts: [AgentConnectorAccount]
    let clientToken: String

    enum CodingKeys: String, CodingKey {
        case v
        case connectionID = "connectionId"
        case gatewayLabel, accounts, clientToken
    }

    init(
        v: Int = 1,
        connectionID: UUID,
        gatewayLabel: String,
        accounts: [AgentConnectorAccount],
        clientToken: String
    ) {
        self.v = v
        self.connectionID = connectionID
        self.gatewayLabel = gatewayLabel
        self.accounts = accounts
        self.clientToken = clientToken
    }

    init(from decoder: Decoder) throws {
        try AgentConnectorStrictCoding.requireExactKeys(
            decoder,
            expected: ["v", "connectionId", "gatewayLabel", "accounts", "clientToken"],
            error: .invalidPairingResponse
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        let rawConnectionID = try container.decode(String.self, forKey: .connectionID)
        guard rawConnectionID == rawConnectionID.lowercased(),
              rawConnectionID.range(
                of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
                options: .regularExpression
              ) != nil,
              let parsedConnectionID = UUID(uuidString: rawConnectionID) else {
            throw AgentConnectorError.invalidPairingResponse
        }
        connectionID = parsedConnectionID
        gatewayLabel = try container.decode(String.self, forKey: .gatewayLabel)
        accounts = try container.decode([AgentConnectorAccount].self, forKey: .accounts)
        clientToken = try container.decode(String.self, forKey: .clientToken)
    }

    func validated() throws -> (connection: AgentConnectorConnection, clientToken: String) {
        guard v == 1 else { throw AgentConnectorError.unsupportedProtocol }
        let token = try AgentConnectorTokenValidator.normalized(clientToken)
        let connection = try AgentConnectorConnection(
            connectorID: .openClaw,
            connectionID: connectionID,
            gatewayLabel: gatewayLabel,
            accounts: accounts
        ).validated()
        return (connection, token)
    }
}

struct AgentConnectorErrorEnvelope: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        let code: String
        let message: String
    }
    let error: Detail
}

enum AgentConnectorPairingCode {
    static let maximumCharacters = 17

    static func normalized(_ rawValue: String) -> String {
        var body = rawValue.uppercased().filter { character in
            character.isLetter || character.isNumber
        }
        if body.isEmpty { return "" }
        if body == "O" { return "O" }
        if body == "OC" { return "OC" }
        if body.hasPrefix("OC") {
            body.removeFirst(2)
        }
        body = String(body.prefix(12))
        let groups = stride(from: 0, to: body.count, by: 4).map { offset -> String in
            let start = body.index(body.startIndex, offsetBy: offset)
            let end = body.index(start, offsetBy: min(4, body.count - offset))
            return String(body[start ..< end])
        }
        return (["OC"] + groups).joined(separator: "-")
    }

    static func validated(_ rawValue: String) throws -> String {
        let code = normalized(rawValue)
        guard code.range(
            of: #"^OC-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$"#,
            options: .regularExpression
        ) != nil else {
            throw AgentConnectorError.invalidPairingCode
        }
        return code
    }
}

enum AgentConnectorPairingRetryPolicy {
    static func shouldRetainCode(after error: Error) -> Bool {
        guard let connectorError = error as? AgentConnectorError else {
            return true
        }
        switch connectorError {
        case .connectionUnavailable:
            return true
        case let .remote(code, _):
            return code == "unavailable" || code == "rate_limited"
        default:
            return false
        }
    }
}

struct AgentConnectorOrigin: Equatable, Hashable, Sendable {
    let httpsURL: URL
    let webSocketURL: URL

    init(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw AgentConnectorError.invalidOrigin
        }
        components.scheme = "https"
        components.path = ""
        guard let httpsURL = components.url else {
            throw AgentConnectorError.invalidOrigin
        }
        components.scheme = "wss"
        guard let webSocketURL = components.url else {
            throw AgentConnectorError.invalidOrigin
        }
        self.httpsURL = httpsURL
        self.webSocketURL = webSocketURL
    }

    var canonicalString: String { httpsURL.absoluteString }

    var pairingRedeemURL: URL {
        httpsURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("pairings", isDirectory: true)
            .appendingPathComponent("redeem", isDirectory: false)
    }

    func eventsURL(connectionID: UUID) -> URL {
        webSocketURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent(connectionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("events", isDirectory: false)
    }

    func connectorURL(connectionID: UUID) -> URL {
        httpsURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent(connectionID.uuidString.lowercased(), isDirectory: false)
    }

    func attachmentURL(connectionID: UUID, attachmentID: UUID) -> URL {
        httpsURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent(connectionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(attachmentID.uuidString.lowercased(), isDirectory: false)
    }
}

struct AgentConnectorTurnRequest: Equatable, Sendable {
    let connectionID: UUID
    let conversationID: UUID
    let turnID: UUID
    let accountID: String
    let agentID: String
    let displayName: String
    let userMessageID: UUID
    let assistantMessageID: UUID
    let text: String

    init(
        connectionID: UUID,
        conversationID: UUID,
        turnID: UUID,
        accountID: String,
        agentID: String = "agent",
        displayName: String = "OpenClaw agent",
        userMessageID: UUID = UUID(),
        assistantMessageID: UUID = UUID(),
        text: String
    ) {
        self.connectionID = connectionID
        self.conversationID = conversationID
        self.turnID = turnID
        self.accountID = accountID
        self.agentID = agentID
        self.displayName = displayName
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.text = text
    }
}

enum AgentConnectorActivityStatus: String, Codable, Equatable, Sendable {
    case thinking
    case planning
    case searching
    case reading
    case editing
    case runningAction = "running_action"
    case usingTools = "using_tools"
    case creatingMedia = "creating_media"
    case preparingFiles = "preparing_files"
    case waitingForApproval = "waiting_for_approval"
    case finalizing
}

struct AgentConnectorActivityUpdate: Codable, Equatable, Sendable {
    let revision: Int
    let status: AgentConnectorActivityStatus?

    func validated() throws -> Self {
        guard (1 ... 100_000).contains(revision) else {
            throw AgentConnectorError.invalidFrame
        }
        return self
    }
}

enum AgentConnectorWorkCategory: String, Codable, Equatable, Sendable {
    case reasoningSummary = "reasoning_summary"
    case plan
    case tool
    case command
    case file
    case approval
    case status
}

enum AgentConnectorWorkState: String, Codable, Equatable, Sendable {
    case running
    case completed
    case failed
    case waiting
}

struct AgentConnectorWorkStep: Codable, Equatable, Identifiable, Sendable {
    let revision: Int
    let stepID: String
    let category: AgentConnectorWorkCategory
    let state: AgentConnectorWorkState
    let title: String
    let detail: String?
    let tool: String?
    let command: String?
    let path: String?
    let output: String?

    var id: String { stepID }

    func validated() throws -> Self {
        guard (1 ... 100_000).contains(revision),
              stepID.range(
                of: #"^[a-z0-9][a-z0-9._:-]{0,63}$"#,
                options: .regularExpression
              ) != nil,
              Self.isSafe(title, maximum: 120),
              detail.map({ Self.isSafe($0, maximum: 1_000) }) ?? true,
              tool.map({ Self.isSafe($0, maximum: 80) }) ?? true,
              command.map({ Self.isSafe($0, maximum: 1_000) }) ?? true,
              output.map({ Self.isSafe($0, maximum: 2_000) }) ?? true,
              path.map(Self.isSafeRelativePath) ?? true else {
            throw AgentConnectorError.invalidFrame
        }
        return self
    }

    private static func isSafe(_ value: String, maximum: Int) -> Bool {
        guard !value.isEmpty,
              value.count <= maximum,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              value.range(
                of: #"(?:file://|(?:^|\s)[A-Za-z]:[\\/]|\\\\[^\s\\]+\\|(?:^|\s)/(?!/))"#,
                options: [.regularExpression, .caseInsensitive]
              ) == nil,
              value.range(
                of: #"(?:authorization\s*:|\bbearer\s+[A-Za-z0-9._~+\/-]+=*|\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|cookie)\s*[:=])"#,
                options: [.regularExpression, .caseInsensitive]
              ) == nil else {
            return false
        }
        return true
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        isSafe(value, maximum: 512)
            && !value.hasPrefix("/")
            && !value.hasPrefix("\\\\")
            && value.range(
                of: #"^[A-Za-z]:[\\/]"#,
                options: .regularExpression
            ) == nil
            && !value.lowercased().hasPrefix("file:")
            && !value.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/")
                .contains("..")
    }
}

struct AgentConnectorAttachmentMetadata: Codable, Equatable, Sendable {
    static let maximumByteCount = 32 * 1_024 * 1_024

    let connectionID: UUID
    let turnID: UUID
    let attachmentID: UUID
    let fileName: String
    let mediaType: String
    let byteCount: Int
    let sha256: String
    let expiresAtMilliseconds: Int64

    var downloadPath: String {
        "/v1/connectors/\(connectionID.uuidString.lowercased())/attachments/\(attachmentID.uuidString.lowercased())"
    }

    func validated(nowMilliseconds: Int64? = nil) throws -> Self {
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalidName = trimmedName.isEmpty
            || trimmedName != fileName
            || fileName.count > 160
            || fileName == "."
            || fileName == ".."
            || fileName.contains("/")
            || fileName.contains("\\")
            || fileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        guard !invalidName,
              mediaType == mediaType.lowercased(),
              mediaType.count <= 127,
              mediaType.range(
                of: #"^[a-z0-9][a-z0-9!#$&^_.+-]{0,62}/[a-z0-9][a-z0-9!#$&^_.+-]{0,62}$"#,
                options: .regularExpression
              ) != nil,
              (1 ... Self.maximumByteCount).contains(byteCount),
              sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              (1 ... 9_007_199_254_740_991).contains(expiresAtMilliseconds),
              nowMilliseconds.map({ expiresAtMilliseconds > $0 }) ?? true else {
            throw AgentConnectorError.invalidFrame
        }
        return self
    }

    var conversationReference: ConversationConnectorArtifactReference {
        .init(
            connectionID: connectionID,
            attachmentID: attachmentID,
            sha256: sha256,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
    }
}

struct AgentConnectorStoredAttachment: Codable, Equatable, Sendable {
    let metadata: AgentConnectorAttachmentMetadata
    /// App-private key relative to the connector artifact root. Never an absolute path.
    let assetKey: String

    func validated() throws -> Self {
        _ = try metadata.validated()
        let expectedPrefix = metadata.connectionID.uuidString.lowercased()
            + "/" + metadata.attachmentID.uuidString.lowercased() + "/"
        guard assetKey.hasPrefix(expectedPrefix),
              !assetKey.hasPrefix("/"),
              !assetKey.contains(".."),
              !assetKey.contains("\\") else {
            throw AgentConnectorError.invalidFrame
        }
        return self
    }
}

enum AgentConnectorStreamEvent: Equatable, Sendable {
    /// The exact submit frame is now in the device-only durable outbox. The composer
    /// may clear without risking loss even if the network is unavailable afterward.
    case submissionSaved
    case accepted
    case activity(AgentConnectorActivityUpdate)
    case activityCleared(revision: Int)
    case work(AgentConnectorWorkStep)
    case attachment(AgentConnectorStoredAttachment)
    case cumulativeText(String)
    case completed(String)
}

enum AgentConnectorError: LocalizedError, Equatable {
    case notConfigured
    case invalidOrigin
    case invalidPairingCode
    case invalidPairingResponse
    case invalidBinding
    case unsupportedProtocol
    case missingConnection
    case missingClientToken
    case pairingRequired
    case connectionUnavailable
    case redirected
    case responseTooLarge
    case attachmentExpired
    case attachmentUnavailable
    case attachmentIntegrityFailed
    case frameTooLarge
    case invalidFrame
    case staleOrDuplicateFrame
    case conversationBusy
    case recoveryPending
    case recoveryExpired
    case revocationUnavailable
    case remote(code: String, message: String)
    case secureStoreUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "OpenClaw pairing is not configured in this build."
        case .invalidOrigin:
            "The OpenClaw connector address is invalid."
        case .invalidPairingCode:
            "Enter the complete OpenClam pairing code shown by OpenClaw."
        case .invalidPairingResponse:
            "OpenClaw returned an invalid pairing response."
        case .invalidBinding:
            "That OpenClaw agent selection is invalid."
        case .unsupportedProtocol:
            "This OpenClaw connector uses an unsupported protocol version."
        case .missingConnection:
            "This chat’s OpenClaw connection is no longer available. Pair it again or start a new On iPhone chat."
        case .missingClientToken:
            "This OpenClaw connection is no longer authorized. Pair it again."
        case .pairingRequired:
            "This OpenClaw pairing was replaced or removed. Pair this iPhone again."
        case .connectionUnavailable:
            "OpenClaw is unavailable right now. This message was not sent to the On iPhone model."
        case .redirected:
            "The OpenClaw connector tried to redirect the secure connection."
        case .responseTooLarge:
            "The OpenClaw connector returned an oversized response."
        case .attachmentExpired:
            "This OpenClaw file is no longer available to download."
        case .attachmentUnavailable:
            "The OpenClaw file could not be downloaded securely."
        case .attachmentIntegrityFailed:
            "The OpenClaw file did not match its verified description and was not opened."
        case .frameTooLarge:
            "The OpenClaw connector sent an oversized message."
        case .invalidFrame, .staleOrDuplicateFrame:
            "The OpenClaw connector sent an invalid message."
        case .conversationBusy:
            "This OpenClaw chat is already handling another message."
        case .recoveryPending:
            "OpenClam is safely recovering the previous OpenClaw message. Wait for it to finish before sending another."
        case .recoveryExpired:
            "OpenClam could not safely resume this message because its recovery window expired. The remote agent may already have acted; check OpenClaw before sending it again."
        case .revocationUnavailable:
            "OpenClaw could not revoke this connection. It remains paired on this iPhone; try again."
        case let .remote(_, message):
            message
        case .secureStoreUnavailable:
            "The secure OpenClaw credential store is unavailable."
        }
    }
}

enum AgentConnectorTokenValidator {
    static func normalized(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(
            of: #"^[A-Za-z0-9_-]{40,128}$"#,
            options: .regularExpression
        ) != nil else {
            throw AgentConnectorError.invalidPairingResponse
        }
        return value
    }
}

private struct AgentConnectorAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

enum AgentConnectorStrictCoding {
    static func requireExactKeys(
        _ decoder: Decoder,
        expected: Set<String>,
        error: AgentConnectorError = .invalidFrame
    ) throws {
        let container = try decoder.container(keyedBy: AgentConnectorAnyCodingKey.self)
        guard Set(container.allKeys.map(\.stringValue)) == expected else {
            throw error
        }
    }

    static func requireKeys(
        _ decoder: Decoder,
        required: Set<String>,
        allowed: Set<String>,
        error: AgentConnectorError = .invalidFrame
    ) throws {
        let container = try decoder.container(keyedBy: AgentConnectorAnyCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard required.isSubset(of: keys), keys.isSubset(of: allowed) else {
            throw error
        }
    }
}
