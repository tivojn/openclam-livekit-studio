import Combine
import Foundation
import UIKit

enum AppHandoffInputOrigin: Equatable, Sendable {
    /// A complete URL that appears verbatim in the latest user-authored turn.
    case exactUserEntry

    /// A public HTTPS URL proposed by the agent from an explicitly named public host.
    /// Custom schemes are never accepted from this origin.
    case agentPublicWebProposal
}

enum AppHandoffTargetKind: String, Equatable, Sendable {
    case publicHTTPS
    case userEnteredScheme
}

struct AppHandoffProposal: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let kind: AppHandoffTargetKind
    let aliasDisplayName: String?
    let displayTarget: String
    let createdAt: Date
    let expiresAt: Date
}

enum AppHandoffError: Error, Equatable, LocalizedError {
    case emptyURL
    case URLTooLong
    case invalidURL
    case privateOrAmbiguousHost
    case schemeNotAllowed
    case notExplicitlyRequested
    case anotherProposalIsWaiting
    case missingOrExpiredProposal
    case proposalMismatch
    case destinationUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            "Enter a URL to open."
        case .URLTooLong:
            "That URL is longer than the 2,048-byte handoff limit."
        case .invalidURL:
            "That URL is not a valid handoff target."
        case .privateOrAmbiguousHost:
            "Only a clearly public HTTPS host can be proposed by the agent."
        case .schemeNotAllowed:
            "That URL scheme is not allowed for a generic app handoff."
        case .notExplicitlyRequested:
            "The exact destination must appear in the latest user request."
        case .anotherProposalIsWaiting:
            "Another app handoff is already waiting for review."
        case .missingOrExpiredProposal:
            "That app handoff review expired. Stage it again."
        case .proposalMismatch:
            "The reviewed app handoff no longer matches."
        case .destinationUnavailable:
            "iOS could not find an app or website that accepts that reviewed URL."
        }
    }
}

@MainActor
protocol AppHandoffURLOpening {
    func open(_ url: URL) async -> Bool
}

@MainActor
struct SystemAppHandoffURLOpener: AppHandoffURLOpening {
    func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url, options: [:])
    }
}

/// A two-phase, in-memory boundary for opening a public URL or an exact user-entered deep link.
///
/// Agent code may call `stage`, but only a local review control should call
/// `openFromUserConfirmation`. The proposal is consumed before opening, so a repeated tap or a
/// stale model/tool call can't open the target twice. This type deliberately never calls
/// `canOpenURL`; it neither needs `LSApplicationQueriesSchemes` nor exposes an installed-app list.
@MainActor
final class AppHandoffSession: ObservableObject {
    static let reviewLifetime: TimeInterval = 5 * 60

    @Published private(set) var proposal: AppHandoffProposal?
    @Published private(set) var lastResult: String?

    func stage(
        rawURL: String,
        latestUserText: String,
        origin: AppHandoffInputOrigin,
        now: Date = Date()
    ) throws -> AppHandoffProposal {
        guard proposal == nil else {
            throw AppHandoffError.anotherProposalIsWaiting
        }
        let validated = try AppHandoffURLPolicy.validate(
            rawURL,
            latestUserText: latestUserText,
            origin: origin
        )
        let staged = AppHandoffProposal(
            id: UUID(),
            url: validated.url,
            kind: validated.kind,
            aliasDisplayName: nil,
            displayTarget: validated.displayTarget,
            createdAt: now,
            expiresAt: now.addingTimeInterval(Self.reviewLifetime)
        )
        proposal = staged
        lastResult = nil
        return staged
    }

    func stage(
        alias: AppAlias,
        latestUserText: String,
        now: Date = Date()
    ) throws -> AppHandoffProposal {
        guard proposal == nil else {
            throw AppHandoffError.anotherProposalIsWaiting
        }
        guard AppAliasRegistry.latestTurnExplicitlyRequests(
            alias: alias,
            latestUserText: latestUserText
        ) else {
            throw AppHandoffError.notExplicitlyRequested
        }
        let validated = try AppHandoffURLPolicy.validateUserManagedAlias(alias.rawURL)
        let staged = AppHandoffProposal(
            id: UUID(),
            url: validated.url,
            kind: validated.kind,
            aliasDisplayName: alias.displayName,
            displayTarget: validated.displayTarget,
            createdAt: now,
            expiresAt: now.addingTimeInterval(Self.reviewLifetime)
        )
        proposal = staged
        lastResult = nil
        return staged
    }

    func cancel() {
        proposal = nil
        lastResult = "App handoff cancelled. Nothing opened."
    }

    /// Call this only from the exact local button that displays `proposal.url` for review.
    func openFromUserConfirmation(
        proposalID: UUID,
        now: Date = Date(),
        opener: (any AppHandoffURLOpening)? = nil
    ) async throws {
        guard let current = proposal else {
            throw AppHandoffError.missingOrExpiredProposal
        }

        // Burn the review before awaiting an external handoff. Failures require a fresh review.
        proposal = nil
        guard current.id == proposalID else {
            throw AppHandoffError.proposalMismatch
        }
        guard current.expiresAt > now else {
            throw AppHandoffError.missingOrExpiredProposal
        }
        let resolvedOpener = opener ?? SystemAppHandoffURLOpener()
        guard await resolvedOpener.open(current.url) else {
            lastResult = "iOS did not open the reviewed destination."
            throw AppHandoffError.destinationUnavailable
        }
        lastResult = "iOS accepted the reviewed handoff. The destination app's result is not verified."
    }
}

enum AppHandoffURLPolicy {
    static let maximumURLBytes = 2_048

    struct ValidatedTarget: Equatable, Sendable {
        let url: URL
        let kind: AppHandoffTargetKind
        let displayTarget: String
    }

    private static let deniedGenericSchemes: Set<String> = [
        "about", "app-prefs", "blob", "data", "facetime", "facetime-audio", "file",
        "ftp", "itms-services", "javascript", "mailto", "prefs", "shortcuts", "sms",
        "tel", "x-apple.systempreferences",
    ]

    static func validate(
        _ rawValue: String,
        latestUserText: String,
        origin: AppHandoffInputOrigin
    ) throws -> ValidatedTarget {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AppHandoffError.emptyURL }
        guard value.utf8.count <= maximumURLBytes else {
            throw AppHandoffError.URLTooLong
        }
        guard !value.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }),
              var components = URLComponents(string: value),
              let rawScheme = components.scheme?.lowercased(),
              isValidScheme(rawScheme),
              components.user == nil,
              components.password == nil else {
            throw AppHandoffError.invalidURL
        }

        if rawScheme == "https" {
            let host = try validatedPublicHost(components)
            components.scheme = "https"
            components.host = host
            guard let url = components.url else { throw AppHandoffError.invalidURL }
            guard publicURLWasExplicitlyRequested(
                url,
                rawValue: value,
                latestUserText: latestUserText
            ) else {
                throw AppHandoffError.notExplicitlyRequested
            }
            return .init(url: url, kind: .publicHTTPS, displayTarget: host)
        }

        guard rawScheme != "http",
              origin == .exactUserEntry,
              !deniedGenericSchemes.contains(rawScheme),
              exactURL(value, appearsIn: latestUserText),
              let url = components.url,
              url.absoluteString == value else {
            if deniedGenericSchemes.contains(rawScheme) || rawScheme == "http" {
                throw AppHandoffError.schemeNotAllowed
            }
            throw AppHandoffError.notExplicitlyRequested
        }
        return .init(url: url, kind: .userEnteredScheme, displayTarget: rawScheme + "://")
    }

    static func validateUserManagedAlias(_ rawValue: String) throws -> ValidatedTarget {
        try validate(
            rawValue,
            latestUserText: "Open " + rawValue,
            origin: .exactUserEntry
        )
    }

    private static func isValidScheme(_ value: String) -> Bool {
        guard (2 ... 32).contains(value.utf8.count),
              let first = value.unicodeScalars.first,
              CharacterSet.lowercaseLetters.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+.-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func validatedPublicHost(_ components: URLComponents) throws -> String {
        guard let originalHost = components.host?.lowercased(),
              !originalHost.isEmpty,
              components.port == nil || components.port == 443 else {
            throw AppHandoffError.invalidURL
        }
        let host = originalHost.hasSuffix(".") ? String(originalHost.dropLast()) : originalHost
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let blockedSuffixes = [
            "localhost", "local", "internal", "lan", "home", "test", "invalid",
            "example", "onion", "alt", "home.arpa",
        ]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let topLevelLabel = String(labels.last ?? "")
        guard labels.count >= 2,
              !host.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789.").contains($0)
              }),
              topLevelLabel.unicodeScalars.contains(where: CharacterSet.letters.contains),
              !blockedSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              labels.allSatisfy({ label in
                  !label.isEmpty
                      && label.count <= 63
                      && label.first != "-"
                      && label.last != "-"
                      && label.unicodeScalars.allSatisfy(allowed.contains)
              }) else {
            throw AppHandoffError.privateOrAmbiguousHost
        }
        return host
    }

    private static func publicURLWasExplicitlyRequested(
        _ url: URL,
        rawValue: String,
        latestUserText: String
    ) -> Bool {
        let loweredInput = latestUserText.lowercased()
        let openPhrases = ["open", "visit", "browse", "go to", "take me to", "launch"]
        guard openPhrases.contains(where: loweredInput.contains) else { return false }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let deepTarget = components.map {
            (!$0.percentEncodedPath.isEmpty && $0.percentEncodedPath != "/")
                || $0.percentEncodedQuery != nil
                || $0.percentEncodedFragment != nil
        } ?? false
        if deepTarget {
            return exactURL(rawValue, appearsIn: latestUserText)
        }
        guard let host = url.host?.lowercased() else { return false }
        return exactHost(host, appearsIn: loweredInput)
    }

    private static func exactURL(_ url: String, appearsIn userText: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: url)
        let URLCharacter = "A-Za-z0-9%+._~:/?#@!$&'()\\[\\]*,;=-"
        let pattern = "(?i)(?<![\(URLCharacter)])\(escaped)(?![\(URLCharacter)])"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(userText.startIndex..., in: userText)
        return expression.firstMatch(in: userText, range: range) != nil
    }

    private static func exactHost(_ host: String, appearsIn userText: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: host)
        // A terminal sentence period is allowed, but a dotted hostname suffix is not.
        let pattern = "(?i)(?<![A-Za-z0-9._-])\(escaped)(?![A-Za-z0-9_-]|\\.[A-Za-z0-9])"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(userText.startIndex..., in: userText)
        return expression.firstMatch(in: userText, range: range) != nil
    }
}
