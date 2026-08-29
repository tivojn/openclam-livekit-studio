import CryptoKit
import Foundation
import XCTest
@testable import OpenClamLiveKit

@MainActor
final class OpenClamAvatarStoreTests: XCTestCase {
    func testSyntheticCatalogContractRemainsGenericAndStrict() throws {
        let document = try OpenClamAvatarStoreCatalogParser.decode(syntheticCatalogData())

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.entries.map(\.id), ["fixture-avatar"])
        let fixture = try XCTUnwrap(document.entries.first)
        XCTAssertEqual(fixture.name, "Fixture Avatar")
        XCTAssertEqual(fixture.author, "Example Publisher")
        XCTAssertEqual(fixture.version, 1)
        XCTAssertEqual(fixture.iosLight.bytes, 10)
        XCTAssertEqual(
            fixture.iosLight.sha256,
            String(repeating: "1", count: 64)
        )
        XCTAssertEqual(fixture.iosLight.profile, "ios-light")
        XCTAssertEqual(try XCTUnwrap(fixture.variants.macOSFull).profile, "macos-full")
    }

    func testCatalogAcceptsAnIOSOnlyEntryWithoutInventingAMacPackage() throws {
        var root = try catalogObject()
        var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        var entry = entries[0]
        var variants = try XCTUnwrap(entry["variants"] as? [String: Any])
        variants.removeValue(forKey: "macos-full")
        entry["variants"] = variants
        entries[0] = entry
        root["entries"] = entries

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let decoded = try OpenClamAvatarStoreCatalogParser.decode(data)
        XCTAssertEqual(decoded.entries.first?.iosLight.profile, "ios-light")
        XCTAssertNil(decoded.entries.first?.variants.macOSFull)
    }

    func testCatalogRejectsUnknownMissingAndDuplicateEntries() throws {
        var root = try catalogObject()
        root["tracking"] = true
        try assertCatalogError(.invalidShape, object: root)

        root = try catalogObject()
        var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        var entry = entries[0]
        var variants = try XCTUnwrap(entry["variants"] as? [String: Any])
        variants.removeValue(forKey: "ios-light")
        entry["variants"] = variants
        entries[0] = entry
        root["entries"] = entries
        try assertCatalogError(.invalidShape, object: root)

        root = try catalogObject()
        entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        entry = entries[0]
        entries.append(entries[0])
        root["entries"] = entries
        try assertCatalogError(.duplicateIdentifier, object: root)
    }

    func testCatalogRejectsInvalidHashesSizesProfilesAndHosts() throws {
        try assertEntryMutationError(.invalidHash) { entry in
            var thumbnail = try XCTUnwrap(entry["thumbnail"] as? [String: Any])
            thumbnail["sha256"] = String(repeating: "A", count: 64)
            entry["thumbnail"] = thumbnail
        }
        try assertEntryMutationError(.invalidURL) { entry in
            var variants = try XCTUnwrap(entry["variants"] as? [String: Any])
            var package = try XCTUnwrap(variants["ios-light"] as? [String: Any])
            package["url"] = "https://github.com/other/repository/releases/download/v1/avatar.avtr"
            variants["ios-light"] = package
            entry["variants"] = variants
        }
        try assertEntryMutationError(.unsupportedPackage) { entry in
            var variants = try XCTUnwrap(entry["variants"] as? [String: Any])
            var package = try XCTUnwrap(variants["ios-light"] as? [String: Any])
            package["profile"] = "macos-full"
            variants["ios-light"] = package
            entry["variants"] = variants
        }
        try assertEntryMutationError(.invalidEntry("fixture-avatar")) { entry in
            var thumbnail = try XCTUnwrap(entry["thumbnail"] as? [String: Any])
            thumbnail["width"] = 100_000
            entry["thumbnail"] = thumbnail
        }
        try assertEntryMutationError(.invalidEntry("fixture-avatar")) { entry in
            entry["name"] = "Fixture\u{0000}Avatar"
        }
        try assertEntryMutationError(.invalidEntry("fixture-avatar")) { entry in
            entry["author"] = " Another Publisher"
        }
    }

    func testURLPolicyAllowsOnlyExactStoreOriginsAndOpaqueReleaseRedirect() throws {
        let packageURL = try XCTUnwrap(URL(string:
            "https://github.com/tivojn/openclam-livekit-studio/releases/download/avatar-store-v1.0.2/fixture-avatar-ios-light.avtr"
        ))
        let opaqueReleaseURL = try XCTUnwrap(URL(string:
            "https://release-assets.githubusercontent.com/github-production-release-asset/file?sp=r&sig=opaque"
        ))
        XCTAssertTrue(
            OpenClamAvatarStoreURLPolicy.allowsCatalogURL(
                OpenClamAvatarStoreURLPolicy.productionCatalogURL
            )
        )
        XCTAssertTrue(
            OpenClamAvatarStoreURLPolicy.allowsPackageURL(
                packageURL
            )
        )
        XCTAssertTrue(
            OpenClamAvatarStoreURLPolicy.allowsRedirectOrFinalURL(
                opaqueReleaseURL,
                for: packageURL
            )
        )
        XCTAssertFalse(
            OpenClamAvatarStoreURLPolicy.allowsRedirectOrFinalURL(
                opaqueReleaseURL,
                for: OpenClamAvatarStoreURLPolicy.productionCatalogURL
            )
        )
        XCTAssertFalse(
            OpenClamAvatarStoreURLPolicy.allowsPackageURL(
                try XCTUnwrap(URL(string:
                    "https://github.com/tivojn/openclam-livekit-studio/releases/download/v1/avatar.avtr?token=leak"
                ))
            )
        )
        XCTAssertFalse(
            OpenClamAvatarStoreURLPolicy.allowsRedirectOrFinalURL(
                try XCTUnwrap(URL(string: "https://evil.githubusercontent.com/file.avtr")),
                for: packageURL
            )
        )
        XCTAssertFalse(
            OpenClamAvatarStoreURLPolicy.allowsCatalogURL(
                try XCTUnwrap(URL(string:
                    "https://raw.githubusercontent.com/tivojn/openclam-livekit-studio/avatar-store-v1.0.4/shared/avatar-store-v1/catalog/v1/catalog.json?changed=1"
                ))
            )
        )
        XCTAssertFalse(
            OpenClamAvatarStoreURLPolicy.allowsCatalogURL(
                try XCTUnwrap(URL(string:
                    "https://raw.githubusercontent.com/tivojn/openclam-livekit-studio/avatar-store-v1.0.2/shared/avatar-store-v1/catalog/v1/catalog.json"
                ))
            )
        )
    }

    func testHashSizeAndDownloadPercentageAreExactAndBounded() {
        let data = Data("verified avatar".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(
            OpenClamAvatarStoreFileVerifier.verify(
                data: data,
                bytes: data.count,
                sha256: hash
            )
        )
        XCTAssertFalse(
            OpenClamAvatarStoreFileVerifier.verify(
                data: data,
                bytes: data.count + 1,
                sha256: hash
            )
        )
        XCTAssertFalse(
            OpenClamAvatarStoreFileVerifier.verify(
                data: data,
                bytes: data.count,
                sha256: String(repeating: "0", count: 64)
            )
        )

        XCTAssertEqual(
            OpenClamAvatarStoreItemPhase.downloading(received: 4, total: 10).percentage,
            40
        )
        XCTAssertEqual(
            OpenClamAvatarStoreItemPhase.downloading(received: 12, total: 10).percentage,
            99
        )
        XCTAssertEqual(
            OpenClamAvatarStoreItemPhase.downloading(received: -3, total: 10).percentage,
            0
        )
        XCTAssertNil(OpenClamAvatarStoreItemPhase.available.percentage)

        let fixtureHalf = OpenClamAvatarStoreItemPhase.downloading(
            received: 5,
            total: 10
        )
        XCTAssertEqual(fixtureHalf.percentage, 50)
        XCTAssertEqual(
            OpenClamAvatarStorePresentation.buttonTitle(for: fixtureHalf),
            "Cancel 50%"
        )
    }

    func testInstalledVersionPolicyRejectsDowngradesAndSameVersionHashDrift() {
        let installedHash = String(repeating: "a", count: 64)
        let differentHash = String(repeating: "b", count: 64)

        XCTAssertEqual(
            OpenClamAvatarStoreVersionPolicy.phase(
                installedVersion: 2,
                installedHash: installedHash,
                catalogVersion: 1,
                catalogHash: differentHash
            ),
            .installed
        )
        XCTAssertFalse(
            OpenClamAvatarStoreVersionPolicy.allowsInstall(
                installedVersion: 2,
                installedHash: installedHash,
                catalogVersion: 1,
                catalogHash: differentHash
            )
        )
        XCTAssertFalse(
            OpenClamAvatarStoreVersionPolicy.allowsInstall(
                installedVersion: 2,
                installedHash: installedHash,
                catalogVersion: 2,
                catalogHash: differentHash
            )
        )
        XCTAssertEqual(
            OpenClamAvatarStoreVersionPolicy.phase(
                installedVersion: 2,
                installedHash: installedHash,
                catalogVersion: 3,
                catalogHash: differentHash
            ),
            .updateAvailable
        )
        XCTAssertTrue(
            OpenClamAvatarStoreVersionPolicy.allowsInstall(
                installedVersion: 2,
                installedHash: installedHash,
                catalogVersion: 3,
                catalogHash: differentHash
            )
        )
    }

    func testCacheRoundTripsOnlyWithinItsDedicatedRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenClamAvatarStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = OpenClamAvatarStoreCache(root: root)
        let catalog = syntheticCatalogData()
        try cache.storeCatalog(catalog)

        XCTAssertEqual(cache.loadCatalogData(), catalog)
        XCTAssertEqual(cache.catalogURL.deletingLastPathComponent(), root.standardizedFileURL)
        XCTAssertNoThrow(try OpenClamAvatarStoreCatalogParser.decode(cache.loadCatalogData()!))
    }

    func testSyntheticProgressCancelRemovesPartialsAndRetryStartsFresh() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = OpenClamAvatarStoreCache(
            root: root.appendingPathComponent("cache", isDirectory: true)
        )
        let client = AvatarStoreScriptedTransferClient(catalogData: syntheticCatalogData())
        let suiteName = "OpenClamAvatarStoreTests.cancel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = OpenClamAvatarLibrary(
            storageRoot: root.appendingPathComponent("library", isDirectory: true)
        )
        let store = OpenClamAvatarStore(
            transferClient: client,
            cache: cache,
            defaults: defaults,
            remoteAccess: testRemoteAccess
        )
        store.load(library: library)
        await waitUntil { store.entries.count == 1 && store.catalogStatus == .current }
        let entry = try XCTUnwrap(store.entries.first)

        await client.setMode(.suspendedArchive)
        store.primaryAction(for: entry, library: library)
        await waitUntil {
            store.phases[entry.id]?.percentage == 50
        }
        XCTAssertEqual(store.buttonTitle(for: entry), "Cancel 50%")
        store.cancel(entry)
        await Task.yield()
        XCTAssertEqual(store.phases[entry.id], .available)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.archiveURL(for: entry).path))

        store.primaryAction(for: entry, library: library)
        await waitUntilAsync {
            let attempts = await client.archiveAttemptCount()
            return store.phases[entry.id]?.percentage == 50 && attempts >= 2
        }
        let archiveAttempts = await client.archiveAttemptCount()
        XCTAssertEqual(archiveAttempts, 2)
        store.cancel(entry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.archiveURL(for: entry).path))
    }

    func testLastValidatedCatalogWorksOfflineAndRefreshRetries() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = OpenClamAvatarStoreCache(
            root: root.appendingPathComponent("cache", isDirectory: true)
        )
        let client = AvatarStoreScriptedTransferClient(catalogData: syntheticCatalogData())
        let suiteName = "OpenClamAvatarStoreTests.offline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = OpenClamAvatarLibrary(
            storageRoot: root.appendingPathComponent("library", isDirectory: true)
        )
        let first = OpenClamAvatarStore(
            transferClient: client,
            cache: cache,
            defaults: defaults,
            remoteAccess: testRemoteAccess
        )
        first.load(library: library)
        await waitUntil { first.catalogStatus == .current }
        XCTAssertNotNil(cache.loadCatalogData())

        await client.setMode(.offline)
        let offline = OpenClamAvatarStore(
            transferClient: client,
            cache: cache,
            defaults: defaults,
            remoteAccess: testRemoteAccess
        )
        offline.load(library: library)
        XCTAssertEqual(offline.entries.map(\.id), ["fixture-avatar"])
        await waitUntil {
            if case .cachedOffline = offline.catalogStatus { return true }
            return false
        }

        await client.setMode(.online)
        offline.load(library: library)
        await waitUntil { offline.catalogStatus == .current }
        XCTAssertEqual(offline.entries.map(\.id), ["fixture-avatar"])
    }

    func testReleaseStoreUsesPinnedProductionCatalogEndpoint() {
        XCTAssertTrue(OpenClamAvatarStoreReleasePolicy.isAvailable)
        XCTAssertEqual(
            OpenClamAvatarStoreReleasePolicy.productionCatalogURL.absoluteString,
            "https://raw.githubusercontent.com/tivojn/openclam-livekit-studio/avatar-store-v1.0.4/shared/avatar-store-v1/catalog/v1/catalog.json"
        )
        XCTAssertEqual(
            OpenClamAvatarStoreReleasePolicy.catalogURL,
            OpenClamAvatarStoreReleasePolicy.productionCatalogURL
        )
        XCTAssertTrue(
            OpenClamAvatarStoreURLPolicy.allowsCatalogURL(
                OpenClamAvatarStoreReleasePolicy.productionCatalogURL
            )
        )
    }

    func testStoreAvailabilityLeavesDirectImportLibraryAndDeleteWorking() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = OpenClamAvatarLibrary(
            storageRoot: root.appendingPathComponent("library", isDirectory: true)
        )
        let imported = try await library.importAvatar(from: goldenFixtureURL)

        XCTAssertTrue(library.isImported(id: imported.id))
        XCTAssertEqual(library.avatar(id: imported.id)?.displayName, imported.displayName)

        try await library.deleteImportedAvatar(id: imported.id)
        XCTAssertFalse(library.isImported(id: imported.id))
    }

    private var testRemoteAccess: OpenClamAvatarStoreRemoteAccess {
        .testing(catalogURL: OpenClamAvatarStoreURLPolicy.productionCatalogURL)
    }

    private var goldenFixtureURL: URL {
        get throws {
            try XCTUnwrap(
                Bundle(for: Self.self).url(
                    forResource: "ios-light-golden",
                    withExtension: "avtr"
                )
            )
        }
    }

    private func syntheticCatalogData() -> Data {
        Data(
            #"{"schemaVersion":1,"entries":[{"id":"fixture-avatar","name":"Fixture Avatar","author":"Example Publisher","version":1,"thumbnail":{"url":"https://raw.githubusercontent.com/tivojn/openclam-livekit-studio/avatar-store-v1.0.2/shared/avatar-store-v1/catalog/v1/fixture-avatar-thumbnail.png","sha256":"0000000000000000000000000000000000000000000000000000000000000000","bytes":68,"mime":"image/png","width":1,"height":1},"variants":{"ios-light":{"url":"https://github.com/tivojn/openclam-livekit-studio/releases/download/avatar-store-v1.0.2/fixture-avatar-ios-light.avtr","sha256":"1111111111111111111111111111111111111111111111111111111111111111","bytes":10,"format":"openclam-avatar","profile":"ios-light"},"macos-full":{"url":"https://github.com/tivojn/openclam-livekit-studio/releases/download/avatar-store-v1.0.2/fixture-avatar-macos-full.avtr","sha256":"2222222222222222222222222222222222222222222222222222222222222222","bytes":20,"format":"openclam-avatar","profile":"macos-full"}}}]}"#.utf8
        )
    }

    private func catalogObject() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: syntheticCatalogData()) as? [String: Any]
        )
    }

    private func assertEntryMutationError(
        _ expected: OpenClamAvatarStoreCatalogError,
        mutation: (inout [String: Any]) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var root = try catalogObject()
        var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        var entry = entries[0]
        try mutation(&entry)
        entries[0] = entry
        root["entries"] = entries
        try assertCatalogError(expected, object: root, file: file, line: line)
    }

    private func assertCatalogError(
        _ expected: OpenClamAvatarStoreCatalogError,
        object: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(
            try OpenClamAvatarStoreCatalogParser.decode(data),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? OpenClamAvatarStoreCatalogError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenClamAvatarStoreTests-\(UUID().uuidString)")
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for Avatar Store state")
    }

    private func waitUntilAsync(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let didReachExpectedState = await condition()
        XCTAssertTrue(didReachExpectedState, "Timed out waiting for Avatar Store state")
    }

}

private actor AvatarStoreScriptedTransferClient: OpenClamAvatarStoreTransferring {
    enum Mode: Equatable {
        case online
        case offline
        case suspendedArchive
    }

    private let catalogData: Data
    private var mode: Mode = .online
    private var archiveAttempts = 0
    private var fetchRequests = 0

    init(catalogData: Data) {
        self.catalogData = catalogData
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
    }

    func archiveAttemptCount() -> Int {
        archiveAttempts
    }

    func fetchRequestCount() -> Int {
        fetchRequests
    }

    func fetch(
        _ url: URL,
        maximumBytes: Int,
        expectedBytes: Int?,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> OpenClamAvatarStoreTransferResult {
        fetchRequests += 1
        if mode == .offline {
            throw URLError(.notConnectedToInternet)
        }
        if OpenClamAvatarStoreURLPolicy.allowsCatalogURL(url) {
            return .init(data: catalogData, responseURL: url, mimeType: "application/json")
        }
        if url.pathExtension.lowercased() == "avtr" {
            archiveAttempts += 1
            progress(5, 10)
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw URLError(.timedOut)
        }
        throw URLError(.resourceUnavailable)
    }
}
