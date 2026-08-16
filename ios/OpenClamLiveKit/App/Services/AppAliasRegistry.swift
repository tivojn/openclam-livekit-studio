import Combine
import Foundation

struct AppAlias: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var rawURL: String
    let createdAt: Date
    var updatedAt: Date
}

enum AppAliasRegistryError: Error, Equatable, LocalizedError {
    case invalidName
    case tooManyAliases
    case duplicateName
    case sensitiveDestination
    case unknownAlias

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Use a display name between 1 and 60 characters."
        case .tooManyAliases:
            "OpenClam stores at most \(AppAliasRegistry.maximumAliases) app aliases."
        case .duplicateName:
            "An app alias with that display name already exists."
        case .sensitiveDestination:
            "Remove passwords, tokens, signatures, or other credentials from the destination URL."
        case .unknownAlias:
            "That app alias is not in your local registry."
        }
    }
}

/// A deliberately bounded, user-managed registry of exact URL destinations.
///
/// It does not query `canOpenURL`, enumerate apps, or infer schemes. Values are plain local
/// preferences, so URLs that look like they contain credentials are rejected rather than stored.
@MainActor
final class AppAliasRegistry: ObservableObject {
    nonisolated static let maximumAliases = 100

    @Published private(set) var aliases: [AppAlias]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "AppAliasRegistry.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        aliases = Self.loadAliases(defaults: defaults, storageKey: storageKey)
    }

    nonisolated static var platformLimitation: String {
        AppAliasPolicy.platformLimitation
    }

    @discardableResult
    func add(
        displayName: String,
        rawURL: String,
        now: Date = Date()
    ) throws -> AppAlias {
        guard aliases.count < Self.maximumAliases else {
            throw AppAliasRegistryError.tooManyAliases
        }
        let name = try AppAliasPolicy.validatedDisplayName(displayName)
        guard resolve(name: name) == nil else {
            throw AppAliasRegistryError.duplicateName
        }
        let destination = try AppAliasPolicy.validatedDestination(rawURL)
        let alias = AppAlias(
            id: UUID(),
            displayName: name,
            rawURL: destination,
            createdAt: now,
            updatedAt: now
        )
        aliases.append(alias)
        sortAndPersist()
        return alias
    }

    @discardableResult
    func update(
        id: UUID,
        displayName: String,
        rawURL: String,
        now: Date = Date()
    ) throws -> AppAlias {
        guard let index = aliases.firstIndex(where: { $0.id == id }) else {
            throw AppAliasRegistryError.unknownAlias
        }
        let name = try AppAliasPolicy.validatedDisplayName(displayName)
        guard !aliases.contains(where: {
            $0.id != id && $0.displayName.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw AppAliasRegistryError.duplicateName
        }
        let destination = try AppAliasPolicy.validatedDestination(rawURL)
        let updated = AppAlias(
            id: aliases[index].id,
            displayName: name,
            rawURL: destination,
            createdAt: aliases[index].createdAt,
            updatedAt: now
        )
        aliases[index] = updated
        sortAndPersist()
        return updated
    }

    func remove(id: UUID) throws {
        guard let index = aliases.firstIndex(where: { $0.id == id }) else {
            throw AppAliasRegistryError.unknownAlias
        }
        aliases.remove(at: index)
        persist()
    }

    func resolve(name: String) -> AppAlias? {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return aliases.first {
            $0.displayName.caseInsensitiveCompare(candidate) == .orderedSame
        }
    }

    /// Model/tool integration must enter through this method: it resolves only an existing local
    /// alias, then lets `AppHandoffSession` verify that the latest user turn explicitly named it.
    func stageExistingAlias(
        named displayName: String,
        latestUserText: String,
        in session: AppHandoffSession,
        now: Date = Date()
    ) throws -> AppHandoffProposal {
        guard let alias = resolve(name: displayName) else {
            throw AppAliasRegistryError.unknownAlias
        }
        return try session.stage(alias: alias, latestUserText: latestUserText, now: now)
    }

    nonisolated static func latestTurnExplicitlyRequests(
        alias: AppAlias,
        latestUserText: String
    ) -> Bool {
        AppAliasPolicy.latestTurnExplicitlyRequests(alias: alias, latestUserText: latestUserText)
    }

    private func sortAndPersist() {
        aliases.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(aliases) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func loadAliases(defaults: UserDefaults, storageKey: String) -> [AppAlias] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([AppAlias].self, from: data) else {
            return []
        }
        var names = Set<String>()
        return decoded
            .filter { alias in
                guard (try? AppAliasPolicy.validatedDisplayName(alias.displayName)) != nil,
                      (try? AppAliasPolicy.validatedDestination(alias.rawURL)) != nil else {
                    return false
                }
                return names.insert(alias.displayName.lowercased()).inserted
            }
            .prefix(maximumAliases)
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }
}

enum AppAliasPolicy {
    static let platformLimitation = "iOS provides no public installed-app enumeration. An alias works only when an app or website exposes the exact URL or universal link you enter."

    private static let sensitiveQueryNames: Set<String> = [
        "access_token", "api_key", "apikey", "auth", "authorization", "code", "jwt", "key",
        "passwd", "password", "secret", "session", "sig", "signature", "token",
    ]

    static func validatedDisplayName(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 60).contains(value.count),
              value.utf8.count <= 180,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AppAliasRegistryError.invalidName
        }
        return value
    }

    static func validatedDestination(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try AppHandoffURLPolicy.validateUserManagedAlias(value)
        guard let components = URLComponents(string: value),
              components.fragment == nil,
              !looksSensitive(components),
              !looksSensitivePath(components.percentEncodedPath) else {
            throw AppAliasRegistryError.sensitiveDestination
        }
        return value
    }

    static func latestTurnExplicitlyRequests(
        alias: AppAlias,
        latestUserText: String
    ) -> Bool {
        let input = normalizedWords(latestUserText)
        let name = normalizedWords(alias.displayName)
        guard !name.isEmpty,
              containsSubsequence(name, in: input),
              containsOpenPhrase(in: input) else {
            return false
        }
        let joined = input.joined(separator: " ")
        let deniedPhrases = [
            "do not open", "don t open", "dont open", "never open",
            "do not launch", "don t launch", "dont launch", "never launch",
            "do not visit", "don t visit", "dont visit", "never visit",
            "do not browse", "don t browse", "dont browse", "never browse",
            "do not go to", "don t go to", "dont go to", "never go to",
            "do not take me to", "don t take me to", "dont take me to", "never take me to",
        ]
        return !deniedPhrases.contains(where: joined.contains)
    }

    private static func looksSensitive(_ components: URLComponents) -> Bool {
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
                .replacingOccurrences(of: "-", with: "_")
            guard !sensitiveQueryNames.contains(name) else { return true }
            let value = (item.value ?? "").lowercased()
            if value.contains("bearer ") || value.contains("sk-") || looksLikeJWT(value) {
                return true
            }
        }
        return false
    }

    private static func looksLikeJWT(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return parts.count == 3 && parts.allSatisfy {
            $0.count >= 8 && $0.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    private static func looksSensitivePath(_ value: String) -> Bool {
        let decoded = value.removingPercentEncoding ?? value
        if decoded.localizedCaseInsensitiveContains("sk-")
            || decoded.localizedCaseInsensitiveContains("bearer ") {
            return true
        }
        return decoded
            .split(separator: "/", omittingEmptySubsequences: true)
            .contains { looksLikeJWT(String($0)) }
    }

    private static func normalizedWords(_ value: String) -> [String] {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func containsSubsequence(_ needle: [String], in haystack: [String]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for index in 0 ... haystack.count - needle.count
        where Array(haystack[index ..< index + needle.count]) == needle {
            return true
        }
        return false
    }

    private static func containsOpenPhrase(in words: [String]) -> Bool {
        let singleWords: Set<String> = ["open", "launch", "visit", "browse"]
        if words.contains(where: singleWords.contains) { return true }
        return containsSubsequence(["go", "to"], in: words)
            || containsSubsequence(["take", "me", "to"], in: words)
    }
}
