import CryptoKit
import Foundation
import XCTest
@testable import OpenClamLiveKit

@MainActor
final class OpenClamAvatarStoreTests: XCTestCase {
    func testFrozenProductionCatalogContractDecodesVivieenFirst() throws {
        let document = try OpenClamAvatarStoreCatalogParser.decode(productionCatalogData())

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.entries.map(\.id), ["vivieen"])
        let vivieen = try XCTUnwrap(document.entries.first)
        XCTAssertEqual(vivieen.name, "Vivieen")
        XCTAssertEqual(vivieen.author, "OpenClam")
        XCTAssertEqual(vivieen.version, 1)
        XCTAssertEqual(vivieen.iosLight.bytes, 8_711_159)
        XCTAssertEqual(
            vivieen.iosLight.sha256,
            "fda2776d0f6103f15298ccbb4171565eddc7f29df2482b124b646f02e46a43d9"
        )
        XCTAssertEqual(vivieen.iosLight.profile, "ios-light")
        XCTAssertEqual(vivieen.variants.macOSFull.profile, "macos-full")
    }

    func testCatalogRejectsUnknownOrMissingFieldsAndWrongFirstEntry() throws {
        var root = try catalogObject()
        root["tracking"] = true
        try assertCatalogError(.invalidShape, object: root)

        root = try catalogObject()
        var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        var entry = entries[0]
        var variants = try XCTUnwrap(entry["variants"] as? [String: Any])
        variants.removeValue(forKey: "macos-full")
        entry["variants"] = variants
        entries[0] = entry
        root["entries"] = entries
        try assertCatalogError(.invalidShape, object: root)

        root = try catalogObject()
        entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        entry = entries[0]
        entry["id"] = "someone-else"
        entries[0] = entry
        root["entries"] = entries
        try assertCatalogError(.vivieenMustBeFirst, object: root)
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
            package["url"] = "https://github.com/tivojn/other/releases/download/v1/avatar.avtr"
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
        try assertEntryMutationError(.invalidEntry("vivieen")) { entry in
            var thumbnail = try XCTUnwrap(entry["thumbnail"] as? [String: Any])
            thumbnail["width"] = 100_000
            entry["thumbnail"] = thumbnail
        }
        try assertEntryMutationError(.invalidEntry("vivieen")) { entry in
            entry["name"] = "Vivi\u{0000}een"
        }
        try assertEntryMutationError(.invalidEntry("vivieen")) { entry in
            entry["author"] = "Another Publisher"
        }
    }

    func testURLPolicyAllowsOnlyExactStoreOriginsAndOpaqueReleaseRedirect() throws {
        let packageURL = try XCTUnwrap(URL(string:
            "https://github.com/tivojn/openclam-avatar-store/releases/download/avatars-v1.0.0/Vivieen-iPhone.avtr"
        ))
        let opaqueReleaseURL = try XCTUnwrap(URL(string:
            "https://release-assets.githubusercontent.com/github-production-release-asset/file?sp=r&sig=opaque"
        ))
        XCTAssertTrue(
            OpenClamAvatarStoreURLPolicy.allowsCatalogURL(
                OpenClamAvatarStoreURLPolicy.catalogURL
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
                for: OpenClamAvatarStoreURLPolicy.catalogURL
            )
        )
        XCTAssertFalse(
            OpenClamAvatarStoreURLPolicy.allowsPackageURL(
                try XCTUnwrap(URL(string:
                    "https://github.com/tivojn/openclam-avatar-store/releases/download/v1/avatar.avtr?token=leak"
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
                    "https://raw.githubusercontent.com/tivojn/openclam-avatar-store/main/catalog/v1/catalog.json?changed=1"
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

        let vivieenHalf = OpenClamAvatarStoreItemPhase.downloading(
            received: 4_355_580,
            total: 8_711_159
        )
        XCTAssertEqual(vivieenHalf.percentage, 50)
        XCTAssertEqual(
            OpenClamAvatarStorePresentation.buttonTitle(for: vivieenHalf),
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
        let catalog = productionCatalogData()
        try cache.storeCatalog(catalog)

        XCTAssertEqual(cache.loadCatalogData(), catalog)
        XCTAssertEqual(cache.catalogURL.deletingLastPathComponent(), root.standardizedFileURL)
        XCTAssertNoThrow(try OpenClamAvatarStoreCatalogParser.decode(cache.loadCatalogData()!))
    }

    func testVivieenProgressCancelRemovesPartialsAndRetryStartsFresh() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = OpenClamAvatarStoreCache(
            root: root.appendingPathComponent("cache", isDirectory: true)
        )
        let client = AvatarStoreScriptedTransferClient(catalogData: productionCatalogData())
        let suiteName = "OpenClamAvatarStoreTests.cancel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = OpenClamAvatarLibrary(
            storageRoot: root.appendingPathComponent("library", isDirectory: true)
        )
        let store = OpenClamAvatarStore(
            transferClient: client,
            cache: cache,
            defaults: defaults
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
        let client = AvatarStoreScriptedTransferClient(catalogData: productionCatalogData())
        let suiteName = "OpenClamAvatarStoreTests.offline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = OpenClamAvatarLibrary(
            storageRoot: root.appendingPathComponent("library", isDirectory: true)
        )
        let first = OpenClamAvatarStore(
            transferClient: client,
            cache: cache,
            defaults: defaults
        )
        first.load(library: library)
        await waitUntil { first.catalogStatus == .current }
        XCTAssertNotNil(cache.loadCatalogData())

        await client.setMode(.offline)
        let offline = OpenClamAvatarStore(
            transferClient: client,
            cache: cache,
            defaults: defaults
        )
        offline.load(library: library)
        XCTAssertEqual(offline.entries.map(\.id), ["vivieen"])
        await waitUntil {
            if case .cachedOffline = offline.catalogStatus { return true }
            return false
        }

        await client.setMode(.online)
        offline.load(library: library)
        await waitUntil { offline.catalogStatus == .current }
        XCTAssertEqual(offline.entries.map(\.id), ["vivieen"])
    }

    private func productionCatalogData() -> Data {
        Data(
            #"{"schemaVersion":1,"entries":[{"id":"vivieen","name":"Vivieen","author":"OpenClam","version":1,"thumbnail":{"url":"https://raw.githubusercontent.com/tivojn/openclam-avatar-store/main/catalog/v1/vivieen-thumbnail.png","sha256":"90b73228af6952947cbc0ef23044ae2f661632f1bb9498ce5597aface5c65940","bytes":908807,"mime":"image/png","width":1024,"height":1024},"variants":{"ios-light":{"url":"https://github.com/tivojn/openclam-avatar-store/releases/download/avatars-v1.0.0/Vivieen-iPhone.avtr","sha256":"fda2776d0f6103f15298ccbb4171565eddc7f29df2482b124b646f02e46a43d9","bytes":8711159,"format":"openclam-avatar","profile":"ios-light"},"macos-full":{"url":"https://github.com/tivojn/openclam-avatar-store/releases/download/avatars-v1.0.0/Vivieen-Mac.avtr","sha256":"1615d0fae457c16c36dd46497675e43e2c84e33cd08937c305ebdbba14490f41","bytes":225316946,"format":"openclam-avatar","profile":"macos-full"}}}]}"#.utf8
        )
    }

    private func catalogObject() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: productionCatalogData()) as? [String: Any]
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

    init(catalogData: Data) {
        self.catalogData = catalogData
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
    }

    func archiveAttemptCount() -> Int {
        archiveAttempts
    }

    func fetch(
        _ url: URL,
        maximumBytes: Int,
        expectedBytes: Int?,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> OpenClamAvatarStoreTransferResult {
        if mode == .offline {
            throw URLError(.notConnectedToInternet)
        }
        if OpenClamAvatarStoreURLPolicy.allowsCatalogURL(url) {
            return .init(data: catalogData, responseURL: url, mimeType: "application/json")
        }
        if url.pathExtension.lowercased() == "avtr" {
            archiveAttempts += 1
            progress(4_355_580, 8_711_159)
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw URLError(.timedOut)
        }
        throw URLError(.resourceUnavailable)
    }
}
