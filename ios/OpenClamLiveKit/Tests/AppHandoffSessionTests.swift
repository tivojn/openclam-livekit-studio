import Foundation
import XCTest
@testable import OpenClamLiveKit

final class AppHandoffSessionTests: XCTestCase {
    func testPublicHTTPSRequiresAnExplicitHostAndExactDeepTarget() throws {
        let root = try AppHandoffURLPolicy.validate(
            "https://www.apple.com",
            latestUserText: "Open www.apple.com.",
            origin: .agentPublicWebProposal
        )
        XCTAssertEqual(root.kind, .publicHTTPS)
        XCTAssertEqual(root.displayTarget, "www.apple.com")

        XCTAssertThrowsError(
            try AppHandoffURLPolicy.validate(
                "https://www.apple.com/account?tab=security",
                latestUserText: "Open www.apple.com.",
                origin: .agentPublicWebProposal
            )
        ) { error in
            XCTAssertEqual(error as? AppHandoffError, .notExplicitlyRequested)
        }

        let deep = try AppHandoffURLPolicy.validate(
            "https://www.apple.com/account?tab=security",
            latestUserText: "Open https://www.apple.com/account?tab=security",
            origin: .agentPublicWebProposal
        )
        XCTAssertEqual(deep.url.absoluteString, "https://www.apple.com/account?tab=security")

        XCTAssertThrowsError(
            try AppHandoffURLPolicy.validate(
                "https://www.apple.com",
                latestUserText: "Open notwww.apple.com instead.",
                origin: .agentPublicWebProposal
            )
        )
        XCTAssertThrowsError(
            try AppHandoffURLPolicy.validate(
                "https://www.apple.com/account",
                latestUserText: "Open https://www.apple.com/account-attacker",
                origin: .agentPublicWebProposal
            )
        )
    }

    func testPublicHTTPSRejectsPrivateAmbiguousAndCredentialTargets() {
        let values = [
            "http://example.com",
            "https://localhost/private",
            "https://127.0.0.1/private",
            "https://router.home.arpa/private",
            "https://demo.example/private",
            "https://user:password@apple.com/private",
            "https://apple.com:8443/private",
        ]
        for value in values {
            XCTAssertThrowsError(
                try AppHandoffURLPolicy.validate(
                    value,
                    latestUserText: "Open \(value)",
                    origin: .agentPublicWebProposal
                ),
                "Expected \(value) to be rejected."
            )
        }
    }

    func testCustomSchemeMustBeExactUserEntryAndDangerousSchemesStayDenied() throws {
        let custom = try AppHandoffURLPolicy.validate(
            "comgooglemaps://?q=Apple%20Park",
            latestUserText: "Open comgooglemaps://?q=Apple%20Park",
            origin: .exactUserEntry
        )
        XCTAssertEqual(custom.kind, .userEnteredScheme)
        XCTAssertEqual(custom.displayTarget, "comgooglemaps://")

        XCTAssertThrowsError(
            try AppHandoffURLPolicy.validate(
                "comgooglemaps://?q=Apple%20Park",
                latestUserText: "Open the Google Maps app.",
                origin: .exactUserEntry
            )
        )
        XCTAssertThrowsError(
            try AppHandoffURLPolicy.validate(
                "comgooglemaps://?q=Apple%20Park",
                latestUserText: "Open comgooglemaps://?q=Apple%20Park",
                origin: .agentPublicWebProposal
            )
        )

        for value in [
            "shortcuts://run-shortcut?name=Private",
            "tel://15551234567",
            "sms://15551234567",
            "mailto://private@example.com",
            "file:///private/var/mobile/secret",
            "javascript://alert(1)",
            "App-Prefs://root=Privacy",
        ] {
            XCTAssertThrowsError(
                try AppHandoffURLPolicy.validate(
                    value,
                    latestUserText: "Open \(value)",
                    origin: .exactUserEntry
                ),
                "Expected \(value) to be denied."
            )
        }
    }

    @MainActor
    func testUserManagedAliasPersistsExactNonSecretDestination() throws {
        let suiteName = "AppAliasRegistryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = AppAliasRegistry(defaults: defaults, storageKey: "aliases")
        let alias = try registry.add(
            displayName: "Work Maps",
            rawURL: "comgooglemaps://?q=Apple%20Park"
        )

        XCTAssertEqual(registry.resolve(name: "work maps"), alias)
        XCTAssertEqual(
            AppAliasRegistry(defaults: defaults, storageKey: "aliases").aliases,
            [alias]
        )
        XCTAssertTrue(AppAliasRegistry.platformLimitation.contains("no public installed-app enumeration"))
    }

    @MainActor
    func testAliasRejectsSecretsAndRequiresLatestTurnToNameIt() throws {
        let suiteName = "AppAliasRegistryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = AppAliasRegistry(defaults: defaults, storageKey: "aliases")

        XCTAssertThrowsError(
            try registry.add(
                displayName: "Unsafe",
                rawURL: "https://www.apple.com/path?access_token=not-for-storage"
            )
        ) { error in
            XCTAssertEqual(error as? AppAliasRegistryError, .sensitiveDestination)
        }
        let secretLikePath = ["sk", "proj", "not", "for", "storage"].joined(separator: "-")
        XCTAssertThrowsError(
            try registry.add(
                displayName: "Unsafe Path",
                rawURL: "exampleapp://open/\(secretLikePath)"
            )
        ) { error in
            XCTAssertEqual(error as? AppAliasRegistryError, .sensitiveDestination)
        }

        let alias = try registry.add(
            displayName: "Work Maps",
            rawURL: "comgooglemaps://?q=Apple%20Park"
        )
        XCTAssertFalse(
            AppAliasRegistry.latestTurnExplicitlyRequests(
                alias: alias,
                latestUserText: "Open my navigation app"
            )
        )
        XCTAssertFalse(
            AppAliasRegistry.latestTurnExplicitlyRequests(
                alias: alias,
                latestUserText: "Don't open Work Maps"
            )
        )
        XCTAssertTrue(
            AppAliasRegistry.latestTurnExplicitlyRequests(
                alias: alias,
                latestUserText: "Open Work Maps"
            )
        )
    }

    @MainActor
    func testAliasRegistrySupportsOneHundredExplicitAppsAndFailsClosedAtItsBound() throws {
        let suiteName = "AppAliasRegistryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = AppAliasRegistry(defaults: defaults, storageKey: "aliases")

        for index in 0 ..< AppAliasRegistry.maximumAliases {
            try registry.add(
                displayName: "App \(index)",
                rawURL: "https://example.com/apps/\(index)"
            )
        }

        XCTAssertEqual(AppAliasRegistry.maximumAliases, 100)
        XCTAssertEqual(registry.aliases.count, 100)
        XCTAssertThrowsError(
            try registry.add(
                displayName: "App 101",
                rawURL: "https://example.com/apps/101"
            )
        ) { error in
            XCTAssertEqual(error as? AppAliasRegistryError, .tooManyAliases)
        }
    }

    @MainActor
    func testAliasProposalShowsAliasAndFullDestinationAndRemainsOneShot() async throws {
        let alias = AppAlias(
            id: UUID(),
            displayName: "Work Maps",
            rawURL: "comgooglemaps://?q=Apple%20Park",
            createdAt: Date(),
            updatedAt: Date()
        )
        let session = AppHandoffSession()
        let proposal = try session.stage(alias: alias, latestUserText: "Open Work Maps")
        XCTAssertEqual(proposal.aliasDisplayName, "Work Maps")
        XCTAssertEqual(proposal.url.absoluteString, "comgooglemaps://?q=Apple%20Park")
        XCTAssertEqual(proposal.displayTarget, "comgooglemaps://")

        let opener = RecordingAppHandoffOpener(result: true)
        try await session.openFromUserConfirmation(proposalID: proposal.id, opener: opener)
        XCTAssertEqual(opener.openedURLs, [proposal.url])
        XCTAssertNil(session.proposal)
    }

    @MainActor
    func testReviewedHandoffIsOneShotAndBurnsBeforeOpening() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = AppHandoffSession()
        let proposal = try session.stage(
            rawURL: "https://www.apple.com",
            latestUserText: "Open www.apple.com.",
            origin: .agentPublicWebProposal,
            now: now
        )
        let opener = RecordingAppHandoffOpener(result: true)

        try await session.openFromUserConfirmation(
            proposalID: proposal.id,
            now: now.addingTimeInterval(10),
            opener: opener
        )
        XCTAssertNil(session.proposal)
        XCTAssertEqual(opener.openedURLs, [proposal.url])

        do {
            try await session.openFromUserConfirmation(
                proposalID: proposal.id,
                now: now.addingTimeInterval(11),
                opener: opener
            )
            XCTFail("A consumed review must not open twice.")
        } catch let error as AppHandoffError {
            XCTAssertEqual(error, .missingOrExpiredProposal)
        }
        XCTAssertEqual(opener.openedURLs, [proposal.url])
    }

    @MainActor
    func testExpiredOrMismatchedReviewDoesNotOpenAndRequiresFreshReview() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredSession = AppHandoffSession()
        let expired = try expiredSession.stage(
            rawURL: "https://www.apple.com",
            latestUserText: "Open www.apple.com.",
            origin: .agentPublicWebProposal,
            now: now
        )
        let opener = RecordingAppHandoffOpener(result: true)
        do {
            try await expiredSession.openFromUserConfirmation(
                proposalID: expired.id,
                now: expired.expiresAt,
                opener: opener
            )
            XCTFail("Expected an expired review to fail closed.")
        } catch let error as AppHandoffError {
            XCTAssertEqual(error, .missingOrExpiredProposal)
        }
        XCTAssertTrue(opener.openedURLs.isEmpty)
        XCTAssertNil(expiredSession.proposal)

        let mismatchSession = AppHandoffSession()
        _ = try mismatchSession.stage(
            rawURL: "https://www.apple.com",
            latestUserText: "Open www.apple.com.",
            origin: .agentPublicWebProposal,
            now: now
        )
        do {
            try await mismatchSession.openFromUserConfirmation(
                proposalID: UUID(),
                now: now,
                opener: opener
            )
            XCTFail("Expected a mismatched review to fail closed.")
        } catch let error as AppHandoffError {
            XCTAssertEqual(error, .proposalMismatch)
        }
        XCTAssertTrue(opener.openedURLs.isEmpty)
        XCTAssertNil(mismatchSession.proposal)
    }
}

@MainActor
private final class RecordingAppHandoffOpener: AppHandoffURLOpening {
    private let result: Bool
    private(set) var openedURLs: [URL] = []

    init(result: Bool) {
        self.result = result
    }

    func open(_ url: URL) async -> Bool {
        openedURLs.append(url)
        return result
    }
}
