import CryptoKit
import Foundation
import Security

protocol AgentConnectorTokenVault: Sendable {
    func saveClientToken(_ token: String, for connectionID: UUID) throws
    func loadClientToken(for connectionID: UUID) throws -> String?
    func deleteClientToken(for connectionID: UUID) throws
}

final class KeychainAgentConnectorTokenVault: AgentConnectorTokenVault, @unchecked Sendable {
    static let service = "com.lionheart.openclam.livekitpilot.agent-connectors"

    private let gatewayScope: String

    init(gatewayOrigin: String) {
        gatewayScope = Self.digest(gatewayOrigin)
    }

    func saveClientToken(_ token: String, for connectionID: UUID) throws {
        let value = try AgentConnectorTokenValidator.normalized(token)
        let data = Data(value.utf8)
        let query = baseQuery(connectionID: connectionID)
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
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
                throw AgentConnectorError.secureStoreUnavailable
            }
        default:
            throw AgentConnectorError.secureStoreUnavailable
        }
    }

    func loadClientToken(for connectionID: UUID) throws -> String? {
        var query = baseQuery(connectionID: connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw AgentConnectorError.secureStoreUnavailable
            }
            return try AgentConnectorTokenValidator.normalized(value)
        case errSecItemNotFound:
            return nil
        default:
            throw AgentConnectorError.secureStoreUnavailable
        }
    }

    func deleteClientToken(for connectionID: UUID) throws {
        let status = SecItemDelete(baseQuery(connectionID: connectionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentConnectorError.secureStoreUnavailable
        }
    }

    private func baseQuery(connectionID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String:
                "\(gatewayScope).\(connectionID.uuidString.lowercased()).client-token",
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class InMemoryAgentConnectorTokenVault: AgentConnectorTokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: String] = [:]

    func saveClientToken(_ token: String, for connectionID: UUID) throws {
        let value = try AgentConnectorTokenValidator.normalized(token)
        lock.withLock { tokens[connectionID] = value }
    }

    func loadClientToken(for connectionID: UUID) throws -> String? {
        lock.withLock { tokens[connectionID] }
    }

    func deleteClientToken(for connectionID: UUID) throws {
        _ = lock.withLock { tokens.removeValue(forKey: connectionID) }
    }
}
