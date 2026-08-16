import Foundation
import Security

protocol ProviderCredentialVault: Sendable {
    func containsCredential(for provider: AIProviderID) throws -> Bool
    func saveCredential(_ credential: String, for provider: AIProviderID) throws
    func loadCredential(for provider: AIProviderID) throws -> String?
    func deleteCredential(for provider: AIProviderID) throws
}

/// One Keychain item per provider. Secrets never enter UserDefaults, Codable
/// settings, analytics, logs, or the settings screen after saving.
final class KeychainProviderCredentialVault: ProviderCredentialVault, @unchecked Sendable {
    static let defaultService = "com.lionheart.openclam.livekitpilot.provider-credentials"

    private let service: String
    private let accessGroup: String?
    private let legacyOpenAIStore: AgentCredentialStore?

    init(
        service: String = KeychainProviderCredentialVault.defaultService,
        accessGroup: String? = nil,
        legacyOpenAIStore: AgentCredentialStore? = KeychainAgentCredentialStore()
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.legacyOpenAIStore = legacyOpenAIStore
    }

    func containsCredential(for provider: AIProviderID) throws -> Bool {
        try loadCredential(for: provider) != nil
    }

    func saveCredential(_ credential: String, for provider: AIProviderID) throws {
        guard AIProviderRegistry.descriptor(for: provider).credentialLabel != nil else {
            throw ProviderCredentialVaultError.providerDoesNotUseCredential
        }
        let normalized = try AgentCredentialValidator.normalizedAPIKey(credential)
        let query = baseQuery(provider)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(normalized.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            var addQuery = query
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ProviderCredentialVaultError.keychainFailure(addStatus)
            }
        default:
            throw ProviderCredentialVaultError.keychainFailure(updateStatus)
        }

        // Build 7 stored OpenAI in the original account. Keep that one account
        // synchronized so rollback builds and the isolated Contacts boundary work.
        if provider == .openAI {
            try legacyOpenAIStore?.saveAPIKey(normalized)
        }
    }

    func loadCredential(for provider: AIProviderID) throws -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw ProviderCredentialVaultError.unexpectedKeychainData
            }
            return try AgentCredentialValidator.normalizedAPIKey(value)
        case errSecItemNotFound:
            if provider == .openAI {
                return try legacyOpenAIStore?.loadAPIKey()
            }
            return nil
        default:
            throw ProviderCredentialVaultError.keychainFailure(status)
        }
    }

    func deleteCredential(for provider: AIProviderID) throws {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderCredentialVaultError.keychainFailure(status)
        }
        if provider == .openAI {
            try legacyOpenAIStore?.deleteAPIKey()
        }
    }

    private func baseQuery(_ provider: AIProviderID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "provider.\(provider.rawValue).api-key",
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

enum ProviderCredentialVaultError: Error, Equatable, LocalizedError {
    case providerDoesNotUseCredential
    case unexpectedKeychainData
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .providerDoesNotUseCredential:
            "This service does not use an API key."
        case .unexpectedKeychainData:
            "The saved provider credential could not be read."
        case .keychainFailure:
            "Secure device storage is unavailable."
        }
    }
}

/// Adapts one provider slot to the existing Responses client without exposing
/// the credential outside the narrow request boundary.
struct ProviderScopedAgentCredentialStore: AgentCredentialStore, Sendable {
    let provider: AIProviderID
    let vault: ProviderCredentialVault

    func saveAPIKey(_ apiKey: String) throws {
        try vault.saveCredential(apiKey, for: provider)
    }

    func loadAPIKey() throws -> String? {
        try vault.loadCredential(for: provider)
    }

    func deleteAPIKey() throws {
        try vault.deleteCredential(for: provider)
    }
}

struct InMemoryProviderCredentialVault: ProviderCredentialVault, @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var values: [AIProviderID: String] = [:]
    }

    private let storage = Storage()

    func containsCredential(for provider: AIProviderID) throws -> Bool {
        storage.lock.withLock { storage.values[provider] != nil }
    }

    func saveCredential(_ credential: String, for provider: AIProviderID) throws {
        let normalized = try AgentCredentialValidator.normalizedAPIKey(credential)
        storage.lock.withLock { storage.values[provider] = normalized }
    }

    func loadCredential(for provider: AIProviderID) throws -> String? {
        storage.lock.withLock { storage.values[provider] }
    }

    func deleteCredential(for provider: AIProviderID) throws {
        _ = storage.lock.withLock { storage.values.removeValue(forKey: provider) }
    }
}
