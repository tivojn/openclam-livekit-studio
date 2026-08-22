import CryptoKit
import Foundation
import Security

struct AgentConnectorPersistedTerminal: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case completed
        case failed
    }

    let kind: Kind
    let text: String?
    let code: String?
    let message: String?

    static func completed(_ text: String) -> Self {
        .init(kind: .completed, text: text, code: nil, message: nil)
    }

    static func failed(code: String, message: String) -> Self {
        .init(kind: .failed, text: nil, code: code, message: message)
    }

    func validated() throws -> Self {
        switch kind {
        case .completed:
            guard let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 32_000,
                  code == nil,
                  message == nil else {
                throw AgentConnectorError.invalidFrame
            }
        case .failed:
            guard text == nil,
                  let code,
                  !code.isEmpty,
                  code.count <= 64,
                  let message,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  message.count <= 240 else {
                throw AgentConnectorError.invalidFrame
            }
        }
        return self
    }
}

struct AgentConnectorPendingTurn: Codable, Equatable, Sendable {
    static let maximumLifetimeMilliseconds: Int64 = 15 * 60 * 1_000

    let v: Int
    let connectionID: UUID
    let conversationID: UUID
    let turnID: UUID
    let accountID: String
    let agentID: String
    let displayName: String
    let userMessageID: UUID
    let assistantMessageID: UUID
    let userText: String
    let createdAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    var submitFrame: AgentConnectorEncodedFrame
    var submitDurablyPersisted: Bool
    var turnAccepted: Bool
    var cancelFrame: AgentConnectorEncodedFrame?
    var terminal: AgentConnectorPersistedTerminal?
    /// Latest safe enum-only status and verified local generated files. Optional fields
    /// preserve decoding of Build 31 outboxes without migration or re-pairing.
    var activity: AgentConnectorActivityUpdate? = nil
    var attachments: [AgentConnectorStoredAttachment]? = nil

    var binding: AvatarAgentConnectorBinding {
        .init(
            connectorID: .openClaw,
            connectionID: connectionID,
            accountID: accountID,
            agentID: agentID,
            displayName: displayName
        )
    }

    var request: AgentConnectorTurnRequest {
        .init(
            connectionID: connectionID,
            conversationID: conversationID,
            turnID: turnID,
            accountID: accountID,
            agentID: agentID,
            displayName: displayName,
            userMessageID: userMessageID,
            assistantMessageID: assistantMessageID,
            text: userText
        )
    }

    func isExpired(at milliseconds: Int64) -> Bool {
        milliseconds >= expiresAtMilliseconds
    }

    func validated() throws -> Self {
        guard v == 1,
              !userText.isEmpty,
              userText.count <= 32_000,
              (0 ... 9_007_199_254_740_991).contains(createdAtMilliseconds),
              expiresAtMilliseconds > createdAtMilliseconds,
              expiresAtMilliseconds - createdAtMilliseconds
                <= Self.maximumLifetimeMilliseconds,
              expiresAtMilliseconds <= 9_007_199_254_740_991 else {
            throw AgentConnectorError.invalidFrame
        }
        _ = try binding.validated()
        try Self.validate(
            submitFrame,
            kind: "turn.submit",
            connectionID: connectionID,
            conversationID: conversationID,
            turnID: turnID,
            accountID: accountID,
            text: userText
        )
        if let cancelFrame {
            try Self.validate(
                cancelFrame,
                kind: "turn.cancel",
                connectionID: connectionID,
                conversationID: conversationID,
                turnID: turnID,
                accountID: nil,
                text: nil
            )
        }
        _ = try terminal?.validated()
        _ = try activity?.validated()
        let storedAttachments = attachments ?? []
        guard storedAttachments.count <= 8,
              storedAttachments.reduce(0, { $0 + $1.metadata.byteCount })
                <= 64 * 1_024 * 1_024,
              Set(storedAttachments.map(\.metadata.attachmentID)).count
                == storedAttachments.count else {
            throw AgentConnectorError.invalidFrame
        }
        for attachment in storedAttachments {
            let validated = try attachment.validated()
            guard validated.metadata.connectionID == connectionID,
                  validated.metadata.turnID == turnID else {
                throw AgentConnectorError.invalidFrame
            }
        }
        return self
    }

    private static func validate(
        _ encoded: AgentConnectorEncodedFrame,
        kind: String,
        connectionID: UUID,
        conversationID: UUID,
        turnID: UUID,
        accountID: String?,
        text: String?
    ) throws {
        guard (1 ... 9_007_199_254_740_991).contains(encoded.sequence),
              let data = encoded.text.data(using: .utf8),
              data.count <= OpenClawAgentConnector.maximumFrameBytes,
              let frame = try? JSONDecoder().decode(
                AgentConnectorWireFrame.self,
                from: data
              ),
              frame.v == 1,
              frame.kind == kind,
              frame.seq == encoded.sequence,
              frame.messageID == encoded.messageID.uuidString.lowercased(),
              try frame.validatedUUID(frame.connectionID) == connectionID,
              try frame.conversationID.map(frame.validatedUUID) == conversationID,
              try frame.payload.turnID.map(frame.validatedUUID) == turnID else {
            throw AgentConnectorError.invalidFrame
        }
        if kind == "turn.submit" {
            guard frame.payload.accountID == accountID,
                  frame.payload.text == text,
                  frame.payload.capabilities == nil
                    || frame.payload.capabilities == ["activity-v1", "attachments-v1"] else {
                throw AgentConnectorError.invalidFrame
            }
        }
    }
}

protocol AgentConnectorOutboxVault: Sendable {
    func save(_ turn: AgentConnectorPendingTurn) throws
    func load(connectionID: UUID, turnID: UUID) throws -> AgentConnectorPendingTurn?
    func loadAll() throws -> [AgentConnectorPendingTurn]
    func delete(connectionID: UUID, turnID: UUID) throws
}

final class KeychainAgentConnectorOutboxVault: AgentConnectorOutboxVault, @unchecked Sendable {
    static let service = "com.lionheart.openclam.livekitpilot.agent-connector-outbox"

    private let lock = NSLock()
    private let gatewayScope: String

    init(gatewayOrigin: String) {
        gatewayScope = SHA256.hash(data: Data(gatewayOrigin.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func save(_ turn: AgentConnectorPendingTurn) throws {
        let validated = try turn.validated()
        let data = try JSONEncoder().encode(validated)
        guard data.count <= 96 * 1_024 else {
            throw AgentConnectorError.frameTooLarge
        }
        try lock.withLock {
            let query = baseQuery(
                connectionID: validated.connectionID,
                turnID: validated.turnID
            )
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            switch SecItemUpdate(query as CFDictionary, attributes as CFDictionary) {
            case errSecSuccess:
                return
            case errSecItemNotFound:
                var insertion = query
                insertion[kSecValueData as String] = data
                insertion[kSecAttrAccessible as String]
                    = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
                    throw AgentConnectorError.secureStoreUnavailable
                }
            default:
                throw AgentConnectorError.secureStoreUnavailable
            }
        }
    }

    func load(
        connectionID: UUID,
        turnID: UUID
    ) throws -> AgentConnectorPendingTurn? {
        try lock.withLock {
            var query = baseQuery(connectionID: connectionID, turnID: turnID)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &result) {
            case errSecSuccess:
                guard let data = result as? Data else {
                    throw AgentConnectorError.secureStoreUnavailable
                }
                return try decode(data)
            case errSecItemNotFound:
                return nil
            default:
                throw AgentConnectorError.secureStoreUnavailable
            }
        }
    }

    func loadAll() throws -> [AgentConnectorPendingTurn] {
        try lock.withLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]
            var result: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &result) {
            case errSecSuccess:
                guard let rows = result as? [[String: Any]] else {
                    throw AgentConnectorError.secureStoreUnavailable
                }
                return try rows.compactMap { row in
                    guard let account = row[kSecAttrAccount as String] as? String,
                          account.hasPrefix(gatewayScope + "."),
                          let data = row[kSecValueData as String] as? Data else {
                        return nil
                    }
                    return try decode(data)
                }.sorted { $0.createdAtMilliseconds < $1.createdAtMilliseconds }
            case errSecItemNotFound:
                return []
            default:
                throw AgentConnectorError.secureStoreUnavailable
            }
        }
    }

    func delete(connectionID: UUID, turnID: UUID) throws {
        try lock.withLock {
            let status = SecItemDelete(
                baseQuery(connectionID: connectionID, turnID: turnID) as CFDictionary
            )
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AgentConnectorError.secureStoreUnavailable
            }
        }
    }

    private func decode(_ data: Data) throws -> AgentConnectorPendingTurn {
        do {
            return try JSONDecoder().decode(
                AgentConnectorPendingTurn.self,
                from: data
            ).validated()
        } catch let connectorError as AgentConnectorError {
            throw connectorError
        } catch {
            throw AgentConnectorError.secureStoreUnavailable
        }
    }

    private func baseQuery(connectionID: UUID, turnID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: [
                gatewayScope,
                connectionID.uuidString.lowercased(),
                turnID.uuidString.lowercased(),
            ].joined(separator: "."),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

final class InMemoryAgentConnectorOutboxVault: AgentConnectorOutboxVault, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [UUID: AgentConnectorPendingTurn] = [:]

    func save(_ turn: AgentConnectorPendingTurn) throws {
        let value = try turn.validated()
        lock.withLock { turns[value.turnID] = value }
    }

    func load(
        connectionID: UUID,
        turnID: UUID
    ) throws -> AgentConnectorPendingTurn? {
        try lock.withLock {
            guard let value = turns[turnID], value.connectionID == connectionID else {
                return nil
            }
            return try value.validated()
        }
    }

    func loadAll() throws -> [AgentConnectorPendingTurn] {
        try lock.withLock {
            try turns.values.map { try $0.validated() }
                .sorted { $0.createdAtMilliseconds < $1.createdAtMilliseconds }
        }
    }

    func delete(connectionID: UUID, turnID: UUID) throws {
        lock.withLock {
            guard turns[turnID]?.connectionID == connectionID else { return }
            turns.removeValue(forKey: turnID)
        }
    }
}
