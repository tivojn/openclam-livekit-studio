import Foundation
import Security

/// Stores the agent credential outside app preferences and source-controlled files.
///
/// Implementations must never log the credential or include it in an error description.
protocol AgentCredentialStore: Sendable {
    func saveAPIKey(_ apiKey: String) throws
    func loadAPIKey() throws -> String?
    func deleteAPIKey() throws
}

enum AgentCredentialStoreError: Error, Equatable {
    case invalidAPIKey
    case unexpectedKeychainData
    case keychainFailure(OSStatus)
}

extension AgentCredentialStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "The API key is empty or contains unsupported whitespace."
        case .unexpectedKeychainData:
            return "The saved API key could not be read."
        case .keychainFailure:
            return "The secure credential store is unavailable."
        }
    }
}

/// A device-only Keychain store. The key is accessible only while the device is unlocked.
final class KeychainAgentCredentialStore: AgentCredentialStore, @unchecked Sendable {
    static let defaultService = "com.lionheart.openclam.livekitpilot.ai-agent"

    private let service: String
    private let account: String
    private let accessGroup: String?

    init(
        service: String = KeychainAgentCredentialStore.defaultService,
        account: String = "provider-api-key",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    func saveAPIKey(_ apiKey: String) throws {
        let normalizedKey = try AgentCredentialValidator.normalizedAPIKey(apiKey)
        let data = Data(normalizedKey.utf8)
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AgentCredentialStoreError.keychainFailure(addStatus)
            }
        default:
            throw AgentCredentialStoreError.keychainFailure(updateStatus)
        }
    }

    func loadAPIKey() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw AgentCredentialStoreError.unexpectedKeychainData
            }
            return try AgentCredentialValidator.normalizedAPIKey(value)
        case errSecItemNotFound:
            return nil
        default:
            throw AgentCredentialStoreError.keychainFailure(status)
        }
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentCredentialStoreError.keychainFailure(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

enum AgentCredentialValidator {
    static func normalizedAPIKey(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 4_096,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AgentCredentialStoreError.invalidAPIKey
        }
        return normalized
    }
}
