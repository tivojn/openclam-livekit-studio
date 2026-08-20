import CryptoKit
import Foundation
import ImageIO
import XCTest
import ZIPFoundation
@testable import OpenClamLiveKit

final class OpenClamAvatarPackageTests: XCTestCase {
    func testDynamicAvatarIDKeepsBundledConstantsAndAcceptsValidatedStrings() throws {
        XCTAssertEqual(OpenClamAvatarID.captainAyer.rawValue, "captain-ayer")
        XCTAssertEqual(OpenClamAvatarID(rawValue: "my-new-avatar")?.rawValue, "my-new-avatar")
        XCTAssertNil(OpenClamAvatarID(rawValue: "My Avatar"))
        XCTAssertNil(OpenClamAvatarID(rawValue: "../avatar"))
        XCTAssertNil(OpenClamAvatarID(rawValue: String(repeating: "a", count: 65)))

        let original = try XCTUnwrap(OpenClamAvatarID(rawValue: "portable-guide"))
        let restored = try JSONDecoder().decode(
            OpenClamAvatarID.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(restored, original)
    }

    func testGoldenFixtureImportsWithAllLightweightRolesAndReloads() throws {
        let root = try temporaryDirectory()
        let store = OpenClamAvatarPackageStore(storageRoot: root)
        let descriptor = try store.installArchive(at: goldenFixtureURL)

        XCTAssertEqual(descriptor.id, "golden-guide")
        XCTAssertEqual(descriptor.displayName, "Golden Guide")
        XCTAssertTrue(descriptor.motions.isEmpty)
        XCTAssertTrue(descriptor.compatibility.supportsFullLocalStage)
        XCTAssertEqual(
            Set(descriptor.assets.keys),
            expectedAssetRoles
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            ["golden-guide"]
        )

        for reference in descriptor.assets.values {
            guard case let .installedFile(url) = reference else {
                return XCTFail("Every imported asset must resolve to Application Support")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNotNil(CGImageSourceCreateWithURL(url as CFURL, nil))
        }

        let reloaded = store.loadInstalledDescriptors()
        XCTAssertEqual(reloaded.map(\.id), ["golden-guide"])
        XCTAssertEqual(reloaded.first?.geometry, descriptor.geometry)
        XCTAssertTrue(reloaded.first?.motions.isEmpty == true)
    }

    func testMotionV3FixtureImportsValidatedOptionalClipsAndReloads() throws {
        let root = try temporaryDirectory()
        let store = OpenClamAvatarPackageStore(storageRoot: root)
        let descriptor = try store.installArchive(at: motionFixtureURL)

        XCTAssertEqual(descriptor.id, "motion-guide")
        XCTAssertEqual(descriptor.displayName, "Motion Guide")
        XCTAssertEqual(Set(descriptor.motions.keys), [.edgeIdle, .moves])
        XCTAssertNil(descriptor.motion(.walk))
        for kind in [OpenClamAvatarMotionKind.edgeIdle, .moves] {
            let motion = try XCTUnwrap(descriptor.motion(kind))
            XCTAssertEqual(motion.pixelSize, OpenClamAvatarSize(width: 64, height: 96))
            XCTAssertEqual(motion.durationMilliseconds, 500)
            guard case let .installedFile(url) = motion.reference else {
                return XCTFail("Every v3 motion must resolve to Application Support")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }

        let reloaded = try XCTUnwrap(store.loadInstalledDescriptors().first)
        XCTAssertEqual(reloaded.id, descriptor.id)
        XCTAssertEqual(Set(reloaded.motions.keys), [.edgeIdle, .moves])
    }

    func testAuthorizedAraV3HandoffPassesValidationBeforeBundledIDGate() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "OPENCLAM_AUTHORIZED_ARA_V3_PATH"
        ], !path.isEmpty else {
            throw XCTSkip(
                "Set OPENCLAM_AUTHORIZED_ARA_V3_PATH for the local owned-package cross-import audit."
            )
        }

        let root = try temporaryDirectory()
        XCTAssertThrowsError(
            try OpenClamAvatarPackageStore(storageRoot: root).installArchive(
                at: URL(fileURLWithPath: path)
            )
        ) { error in
            // The protected-ID check runs only after extraction, strict
            // manifest validation, hashes, image decoding, and alpha-video
            // probing. Reaching this error proves the handoff passed the full
            // importer contract without installing over the bundled Ara.
            XCTAssertEqual(
                error as? OpenClamAvatarPackageError,
                .bundledIdentifierCollision
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testExactAuthorizedLegacyAraV2IsQuarantinedWithoutDeletion() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "OPENCLAM_AUTHORIZED_ARA_V2_PATH"
        ], !path.isEmpty else {
            throw XCTSkip(
                "Set OPENCLAM_AUTHORIZED_ARA_V2_PATH for the local owned-package migration audit."
            )
        }

        let root = try temporaryDirectory()
        let store = OpenClamAvatarPackageStore(storageRoot: root)
        _ = try store.installArchive(at: URL(fileURLWithPath: path))
        XCTAssertEqual(store.loadInstalledDescriptors().map(\.id), ["ara-2"])

        XCTAssertEqual(
            store.quarantineOwnedLegacyDuplicates(),
            [
                .init(
                    sourceID: "ara-2",
                    targetID: "ara",
                    targetDisplayName: "Ara"
                ),
            ]
        )
        XCTAssertTrue(store.loadInstalledDescriptors().isEmpty)
        let quarantine = root.appendingPathComponent(
            ".retired-owned-ara-2-to-ara-05b4747752bf",
            isDirectory: true
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: quarantine.appendingPathComponent("manifest.json").path
            ),
            "Migration must retain the validated legacy package in a recoverable quarantine."
        )
        XCTAssertEqual(
            store.quarantineOwnedLegacyDuplicates().map(\.sourceID),
            ["ara-2"],
            "The durable quarantine must make profile migration retry-safe after a crash."
        )
    }

    func testNonmatchingAra2PackageRemainsInstalledAndIsNeverQuarantined() throws {
        let root = try temporaryDirectory()
        let arbitraryAra = try archiveByMutatingManifest { manifest in
            manifest["id"] = "ara-2"
            manifest["displayName"] = "Ara"
        }
        let store = OpenClamAvatarPackageStore(storageRoot: root)
        _ = try store.installArchive(at: arbitraryAra)

        XCTAssertTrue(store.quarantineOwnedLegacyDuplicates().isEmpty)
        XCTAssertEqual(store.loadInstalledDescriptors().map(\.id), ["ara-2"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("ara-2/manifest.json").path
            )
        )
    }

    func testMotionV3RejectsDurationMismatchAndCorruptTransparentVideo() throws {
        let wrongDuration = try archiveByMutatingMotionManifest { manifest in
            var motions = try XCTUnwrap(manifest["motions"] as? [String: Any])
            var edgeIdle = try XCTUnwrap(motions["edgeIdle"] as? [String: Any])
            edgeIdle["durationMilliseconds"] = 700
            motions["edgeIdle"] = edgeIdle
            manifest["motions"] = motions
        }
        try assertImportError(.motionDurationMismatch("edgeIdle"), archive: wrongDuration)

        let corruptVideo = try archiveByMutatingMotionEntries { entries in
            let videoIndex = try XCTUnwrap(
                entries.firstIndex(where: { $0.path == "assets/motion-moves.mov" })
            )
            entries[videoIndex].data = Data("not a transparent QuickTime movie".utf8)

            let manifestIndex = try XCTUnwrap(
                entries.firstIndex(where: { $0.path == "manifest.json" })
            )
            var manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(with: entries[manifestIndex].data)
                    as? [String: Any]
            )
            var motions = try XCTUnwrap(manifest["motions"] as? [String: Any])
            var moves = try XCTUnwrap(motions["moves"] as? [String: Any])
            moves["byteCount"] = entries[videoIndex].data.count
            moves["sha256"] = SHA256.hash(data: entries[videoIndex].data)
                .map { String(format: "%02x", $0) }
                .joined()
            motions["moves"] = moves
            manifest["motions"] = motions
            entries[manifestIndex].data = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys]
            )
        }
        try assertImportError(.invalidMotionMedia("moves"), archive: corruptVideo)
    }

    func testRejectsLegacyFormatAlias() throws {
        try assertManifestMutationRejected(
            expected: .unsupportedFormat("vivieen-avatar")
        ) { $0["format"] = "vivieen-avatar" }
    }

    func testRejectsUnsupportedFormatVersionAndVariant() throws {
        try assertManifestMutationRejected(
            expected: .unsupportedFormat("legacy-avatar")
        ) { $0["format"] = "legacy-avatar" }
        try assertManifestMutationRejected(
            expected: .unsupportedVersion(1)
        ) { $0["version"] = 1 }
        try assertManifestMutationRejected(
            expected: .unsupportedVariant("authoring-macos")
        ) { $0["variant"] = "authoring-macos" }
    }

    func testRejectsPrivateManifestFieldsAndLeavesNoInstallResidue() throws {
        let root = try temporaryDirectory()
        let archive = try archiveByMutatingManifest { manifest in
            manifest["prompt"] = "private authoring prompt"
        }
        XCTAssertThrowsError(
            try OpenClamAvatarPackageStore(storageRoot: root).installArchive(at: archive)
        ) { error in
            XCTAssertEqual(error as? OpenClamAvatarPackageError, .privateMetadataNotAllowed)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testRejectsExtraRawSourceAndRollsBackStagingDirectory() throws {
        let root = try temporaryDirectory()
        var entries = try fixtureEntries()
        entries.append(
            .init(path: "assets/source-portrait.png", type: .file, data: Data("private".utf8))
        )
        let archive = try makeArchive(entries)
        XCTAssertThrowsError(
            try OpenClamAvatarPackageStore(storageRoot: root).installArchive(at: archive)
        ) { error in
            XCTAssertEqual(
                error as? OpenClamAvatarPackageError,
                .unexpectedArchivePath("assets/source-portrait.png")
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testRejectsHashMIMEAndDimensionMismatches() throws {
        let hashArchive = try archiveByMutatingEntries { entries in
            let index = try XCTUnwrap(
                entries.firstIndex(where: { $0.path == "assets/body.png" })
            )
            let last = try XCTUnwrap(entries[index].data.indices.last)
            entries[index].data[last] ^= 0x01
        }
        try assertImportError(.hashMismatch("body"), archive: hashArchive)

        let mimeArchive = try archiveByMutatingManifest { manifest in
            var assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
            var body = try XCTUnwrap(assets["body"] as? [String: Any])
            body["mediaType"] = "image/jpeg"
            assets["body"] = body
            manifest["assets"] = assets
        }
        try assertImportError(.mimeTypeMismatch("body"), archive: mimeArchive)

        let dimensionArchive = try archiveByMutatingManifest { manifest in
            var assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
            var body = try XCTUnwrap(assets["body"] as? [String: Any])
            body["width"] = 127
            assets["body"] = body
            manifest["assets"] = assets
        }
        try assertImportError(.dimensionMismatch("body"), archive: dimensionArchive)

        let corruptImageArchive = try archiveByMutatingEntries { entries in
            let bodyIndex = try XCTUnwrap(
                entries.firstIndex(where: { $0.path == "assets/body.png" })
            )
            entries[bodyIndex].data = Data("not a PNG image".utf8)

            let manifestIndex = try XCTUnwrap(
                entries.firstIndex(where: { $0.path == "manifest.json" })
            )
            var manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(with: entries[manifestIndex].data)
                    as? [String: Any]
            )
            var assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
            var body = try XCTUnwrap(assets["body"] as? [String: Any])
            body["byteCount"] = entries[bodyIndex].data.count
            body["sha256"] = SHA256.hash(data: entries[bodyIndex].data)
                .map { String(format: "%02x", $0) }
                .joined()
            assets["body"] = body
            manifest["assets"] = assets
            entries[manifestIndex].data = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys]
            )
        }
        try assertImportError(.invalidAssetImage("body"), archive: corruptImageArchive)
    }

    func testRejectsInvalidRigAssetPathAndMissingRole() throws {
        let rigArchive = try archiveByMutatingManifest { manifest in
            var rig = try XCTUnwrap(manifest["rig"] as? [String: Any])
            var eye = try XCTUnwrap(rig["leftEye"] as? [String: Any])
            eye["rows"] = 7
            rig["leftEye"] = eye
            manifest["rig"] = rig
        }
        try assertImportError(.invalidRig, archive: rigArchive)

        let pathArchive = try archiveByMutatingManifest { manifest in
            var assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
            var body = try XCTUnwrap(assets["body"] as? [String: Any])
            body["path"] = "assets/body.jpg"
            body["mediaType"] = "image/jpeg"
            assets["body"] = body
            manifest["assets"] = assets
        }
        try assertImportError(.invalidAssetPath("body"), archive: pathArchive)

        let missingArchive = try archiveByMutatingManifest { manifest in
            var assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
            assets.removeValue(forKey: "viseme-ou")
            manifest["assets"] = assets
        }
        try assertImportError(.privateMetadataNotAllowed, archive: missingArchive)
    }

    func testRejectsShearedReflectedAndOversizedDecodedRigs() throws {
        let shearedArchive = try archiveByMutatingManifest { manifest in
            var rig = try XCTUnwrap(manifest["rig"] as? [String: Any])
            var transform = try XCTUnwrap(rig["faceTransform"] as? [String: Any])
            transform["c"] = 0.1
            rig["faceTransform"] = transform
            manifest["rig"] = rig
        }
        try assertImportError(.invalidRig, archive: shearedArchive)

        let reflectedArchive = try archiveByMutatingManifest { manifest in
            var rig = try XCTUnwrap(manifest["rig"] as? [String: Any])
            var transform = try XCTUnwrap(rig["faceTransform"] as? [String: Any])
            transform["d"] = -0.1
            rig["faceTransform"] = transform
            manifest["rig"] = rig
        }
        try assertImportError(.invalidRig, archive: reflectedArchive)

        let oversizedAtlasArchive = try archiveByMutatingManifest { manifest in
            var rig = try XCTUnwrap(manifest["rig"] as? [String: Any])
            var brow = try XCTUnwrap(rig["leftBrow"] as? [String: Any])
            var box = try XCTUnwrap(brow["box"] as? [String: Any])
            box["height"] = 200
            brow["box"] = box
            rig["leftBrow"] = brow
            manifest["rig"] = rig
        }
        try assertImportError(.invalidRig, archive: oversizedAtlasArchive)
    }

    func testBundledAndInstalledIdentifierCollisionsNeverOverwrite() throws {
        let bundledRoot = try temporaryDirectory()
        let bundledArchive = try archiveByMutatingManifest { manifest in
            manifest["id"] = "captain-ayer"
            manifest["displayName"] = "Replacement"
        }
        XCTAssertThrowsError(
            try OpenClamAvatarPackageStore(storageRoot: bundledRoot)
                .installArchive(at: bundledArchive)
        ) { error in
            XCTAssertEqual(
                error as? OpenClamAvatarPackageError,
                .bundledIdentifierCollision
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bundledRoot.path), [])

        let installedRoot = try temporaryDirectory()
        let store = OpenClamAvatarPackageStore(storageRoot: installedRoot)
        _ = try store.installArchive(at: goldenFixtureURL)
        XCTAssertThrowsError(try store.installArchive(at: goldenFixtureURL)) { error in
            XCTAssertEqual(error as? OpenClamAvatarPackageError, .avatarAlreadyInstalled)
        }
        XCTAssertEqual(store.loadInstalledDescriptors().map(\.id), ["golden-guide"])
    }

    func testCatalogInstallRequiresExpectedIdentityAndAtomicUpdateKeepsOneAvatar() throws {
        let mismatchedRoot = try temporaryDirectory()
        XCTAssertThrowsError(
            try OpenClamAvatarPackageStore(storageRoot: mismatchedRoot)
                .installArchive(at: goldenFixtureURL, expectedID: "vivieen")
        ) { error in
            XCTAssertEqual(
                error as? OpenClamAvatarPackageError,
                .catalogIdentityMismatch
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: mismatchedRoot.path),
            []
        )

        let updateRoot = try temporaryDirectory()
        let store = OpenClamAvatarPackageStore(storageRoot: updateRoot)
        let original = try store.installArchive(
            at: goldenFixtureURL,
            expectedID: "golden-guide"
        )
        let updated = try store.installArchive(
            at: goldenFixtureURL,
            expectedID: "golden-guide",
            replacingExisting: true
        )
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(store.loadInstalledDescriptors().map(\.id), ["golden-guide"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: updateRoot.path),
            ["golden-guide"]
        )
    }

    func testInvalidCatalogUpdateLeavesExistingAvatarUntouched() throws {
        let root = try temporaryDirectory()
        let store = OpenClamAvatarPackageStore(storageRoot: root)
        _ = try store.installArchive(at: goldenFixtureURL)
        let corrupt = try archiveByMutatingEntries { entries in
            let index = try XCTUnwrap(entries.firstIndex(where: { $0.path == "assets/body.png" }))
            entries[index].data.append(0)
        }

        XCTAssertThrowsError(
            try store.installArchive(
                at: corrupt,
                expectedID: "golden-guide",
                replacingExisting: true
            )
        )
        XCTAssertEqual(store.loadInstalledDescriptors().map(\.id), ["golden-guide"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            ["golden-guide"]
        )
    }

    func testInterruptedUpdateRestoresPriorValidatedAvatarOnNextLaunch() throws {
        let root = try temporaryDirectory()
        let originalStore = OpenClamAvatarPackageStore(storageRoot: root)
        _ = try originalStore.installArchive(at: goldenFixtureURL)

        let destination = root.appendingPathComponent("golden-guide", isDirectory: true)
        let backup = root.appendingPathComponent(
            ".replace-golden-guide.\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        // Simulate termination after the prior validated package is moved out,
        // but before the already-validated update is moved into place.
        try FileManager.default.moveItem(at: destination, to: backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let relaunchedStore = OpenClamAvatarPackageStore(storageRoot: root)
        XCTAssertEqual(relaunchedStore.loadInstalledDescriptors().map(\.id), ["golden-guide"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testDeleteAffectsOnlyImportedAvatarAndSupportsCleanRestart() throws {
        let root = try temporaryDirectory()
        let store = OpenClamAvatarPackageStore(storageRoot: root)
        _ = try store.installArchive(at: goldenFixtureURL)
        XCTAssertEqual(store.loadInstalledDescriptors().map(\.id), ["golden-guide"])

        try store.deleteInstalledAvatar(id: "golden-guide")
        XCTAssertEqual(store.loadInstalledDescriptors(), [])
        XCTAssertEqual(store.committedDeletionIDs(), ["golden-guide"])
        store.acknowledgeCommittedDeletion(id: "golden-guide")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])

        XCTAssertThrowsError(try store.deleteInstalledAvatar(id: "captain-ayer")) { error in
            XCTAssertEqual(error as? OpenClamAvatarPackageError, .protectedAvatar)
        }
    }

    func testInterruptedCommittedDeletePurgesExactTombstoneOnRestart() throws {
        let root = try temporaryDirectory()
        let store = OpenClamAvatarPackageStore(storageRoot: root)
        _ = try store.installArchive(at: goldenFixtureURL)
        let installed = root.appendingPathComponent("golden-guide", isDirectory: true)
        let tombstone = root.appendingPathComponent(
            ".delete-golden-guide.\(UUID().uuidString.lowercased())",
            isDirectory: true
        )

        // Simulate termination immediately after the atomic deletion rename,
        // before best-effort recursive cleanup begins.
        try FileManager.default.moveItem(at: installed, to: tombstone)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstone.path))

        let restarted = OpenClamAvatarPackageStore(storageRoot: root)
        XCTAssertEqual(restarted.loadInstalledDescriptors(), [])
        XCTAssertEqual(restarted.committedDeletionIDs(), ["golden-guide"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        restarted.acknowledgeCommittedDeletion(id: "golden-guide")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testRecoveryKeepsTombstoneWhenReceiptCannotBecomeRegularFile() throws {
        let root = try temporaryDirectory()
        let store = OpenClamAvatarPackageStore(storageRoot: root)
        _ = try store.installArchive(at: goldenFixtureURL)
        let transactionID = UUID().uuidString.lowercased()
        let installed = root.appendingPathComponent("golden-guide", isDirectory: true)
        let tombstone = root.appendingPathComponent(
            ".delete-golden-guide.\(transactionID)",
            isDirectory: true
        )
        let blockedReceipt = root.appendingPathComponent(
            ".delete-receipt-golden-guide.\(transactionID)",
            isDirectory: true
        )

        try FileManager.default.moveItem(at: installed, to: tombstone)
        // A damaged prior launch left a directory where the durable receipt
        // file belongs. Recovery must retain the only committed-delete marker.
        try FileManager.default.createDirectory(
            at: blockedReceipt,
            withIntermediateDirectories: false
        )

        let blockedRestart = OpenClamAvatarPackageStore(storageRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstone.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blockedReceipt.path))
        XCTAssertEqual(blockedRestart.committedDeletionIDs(), [])

        // Once the obstruction is repaired, the next launch creates a valid
        // receipt, purges the tombstone, and exposes cleanup for reconciliation.
        try FileManager.default.removeItem(at: blockedReceipt)
        let retry = OpenClamAvatarPackageStore(storageRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
        XCTAssertEqual(retry.committedDeletionIDs(), ["golden-guide"])
        retry.acknowledgeCommittedDeletion(id: "golden-guide")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    @MainActor
    func testLibrarySelectionCanPersistAcrossModelAndLibraryRestart() async throws {
        let root = try temporaryDirectory()
        let suiteName = "OpenClamAvatarPackageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let library = OpenClamAvatarLibrary(storageRoot: root)
        let imported = try await library.importAvatar(from: goldenFixtureURL)
        let model = AIConfigurationModel(
            defaults: defaults,
            storageKey: "avatar-package-selection",
            credentialStore: AvatarPackageMemoryCredentialStore()
        )
        model.reconcileAvatarCatalog(library.identities)
        model.activateAvatar(id: imported.id, displayName: imported.displayName)
        let importedThreadID = UUID()
        model.registerThread(importedThreadID, for: imported.id)
        XCTAssertEqual(model.activeAvatarID, "golden-guide")

        let restartedLibrary = OpenClamAvatarLibrary(storageRoot: root)
        let restartedModel = AIConfigurationModel(
            defaults: defaults,
            storageKey: "avatar-package-selection",
            credentialStore: AvatarPackageMemoryCredentialStore()
        )
        restartedModel.reconcileAvatarCatalog(restartedLibrary.identities)
        XCTAssertEqual(restartedLibrary.avatar(id: "golden-guide")?.displayName, "Golden Guide")
        XCTAssertEqual(restartedModel.activeAvatarID, "golden-guide")

        let descriptor = try XCTUnwrap(restartedLibrary.avatar(id: "golden-guide"))
        let result = try await OpenClamAvatarDeletionCoordinator.perform(
            decision: .confirm,
            avatar: descriptor,
            library: restartedLibrary,
            configuration: restartedModel
        )
        XCTAssertEqual(restartedModel.activeAvatarID, AvatarAgentIdentity.defaultID)
        XCTAssertNil(restartedLibrary.avatar(id: "golden-guide"))
        XCTAssertNil(restartedModel.avatarAgentProfiles["golden-guide"])
        XCTAssertNil(restartedModel.activeThreadID(for: "golden-guide"))
        XCTAssertNil(restartedModel.avatarID(for: importedThreadID))
        XCTAssertEqual(result?.fallbackIdentity?.id, AvatarAgentIdentity.defaultID)
    }

    @MainActor
    func testCancelDeletionLeavesAvatarProfileThreadAndFilesUntouched() async throws {
        let root = try temporaryDirectory()
        let library = OpenClamAvatarLibrary(storageRoot: root)
        let avatar = try await library.importAvatar(from: goldenFixtureURL)
        let model = AIConfigurationModel(
            defaults: try isolatedDefaults(),
            storageKey: "avatar-delete-cancel",
            credentialStore: AvatarPackageMemoryCredentialStore()
        )
        model.reconcileAvatarCatalog(library.identities)
        model.activateAvatar(id: avatar.id, displayName: avatar.displayName)
        let threadID = UUID()
        model.registerThread(threadID, for: avatar.id)

        let result = try await OpenClamAvatarDeletionCoordinator.perform(
            decision: .cancel,
            avatar: avatar,
            library: library,
            configuration: model
        )

        XCTAssertNil(result)
        XCTAssertTrue(library.isImported(id: avatar.id))
        XCTAssertEqual(model.activeAvatarID, avatar.id)
        XCTAssertNotNil(model.avatarAgentProfiles[avatar.id])
        XCTAssertEqual(model.activeThreadID(for: avatar.id), threadID)
        XCTAssertEqual(model.avatarID(for: threadID), avatar.id)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(avatar.id).path
            )
        )
    }

    @MainActor
    func testPrecommitDeletionFailureRollsBackLibraryAndSelections() async throws {
        let root = try temporaryDirectory()
        let library = OpenClamAvatarLibrary(
            storageRoot: root,
            deletionMoveItem: { _, _ in
                throw CocoaError(.fileWriteNoPermission)
            }
        )
        let avatar = try await library.importAvatar(from: goldenFixtureURL)
        let model = AIConfigurationModel(
            defaults: try isolatedDefaults(),
            storageKey: "avatar-delete-failure",
            credentialStore: AvatarPackageMemoryCredentialStore()
        )
        model.reconcileAvatarCatalog(library.identities)
        model.activateAvatar(id: avatar.id, displayName: avatar.displayName)
        let threadID = UUID()
        model.registerThread(threadID, for: avatar.id)

        do {
            _ = try await OpenClamAvatarDeletionCoordinator.perform(
                decision: .confirm,
                avatar: avatar,
                library: library,
                configuration: model
            )
            XCTFail("A failed atomic rename must not report successful deletion")
        } catch {
            XCTAssertEqual(error as? OpenClamAvatarPackageError, .deletionFailed)
        }

        XCTAssertFalse(library.isMutating)
        XCTAssertTrue(library.isImported(id: avatar.id))
        XCTAssertEqual(model.activeAvatarID, avatar.id)
        XCTAssertNotNil(model.avatarAgentProfiles[avatar.id])
        XCTAssertEqual(model.activeThreadID(for: avatar.id), threadID)
        XCTAssertEqual(model.avatarID(for: threadID), avatar.id)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            [avatar.id]
        )
    }

    @MainActor
    func testPostcommitCleanupFailureStaysDeletedAndPurgesOnRestart() async throws {
        let root = try temporaryDirectory()
        let library = OpenClamAvatarLibrary(
            storageRoot: root,
            deletionRemoveItem: { _ in
                throw CocoaError(.fileWriteNoPermission)
            }
        )
        let avatar = try await library.importAvatar(from: goldenFixtureURL)
        let model = AIConfigurationModel(
            defaults: try isolatedDefaults(),
            storageKey: "avatar-delete-cleanup",
            credentialStore: AvatarPackageMemoryCredentialStore()
        )
        model.reconcileAvatarCatalog(library.identities)
        model.activateAvatar(id: avatar.id, displayName: avatar.displayName)

        let result = try await OpenClamAvatarDeletionCoordinator.perform(
            decision: .confirm,
            avatar: avatar,
            library: library,
            configuration: model
        )

        XCTAssertEqual(result?.deletedAvatarID, avatar.id)
        XCTAssertFalse(library.isImported(id: avatar.id))
        XCTAssertEqual(model.activeAvatarID, AvatarAgentIdentity.defaultID)
        let residue = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(residue.count, 1)
        XCTAssertTrue(residue[0].hasPrefix(".delete-\(avatar.id)."))

        let restarted = OpenClamAvatarLibrary(storageRoot: root)
        XCTAssertFalse(restarted.isImported(id: avatar.id))
        XCTAssertEqual(restarted.pendingCommittedDeletionIDs, [avatar.id])
        restarted.reconcileCommittedDeletions(configuration: model)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            []
        )
    }

    @MainActor
    func testCommittedDeletionReceiptPreventsPersonaResurrectionAfterCrash() async throws {
        let root = try temporaryDirectory()
        let suiteName = "OpenClamAvatarPackageTests.receipt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "avatar-delete-receipt"

        let firstLibrary = OpenClamAvatarLibrary(storageRoot: root)
        let imported = try await firstLibrary.importAvatar(from: goldenFixtureURL)
        let firstModel = AIConfigurationModel(
            defaults: defaults,
            storageKey: storageKey,
            credentialStore: AvatarPackageMemoryCredentialStore()
        )
        firstModel.reconcileAvatarCatalog(firstLibrary.identities)
        var personalized = firstModel.profile(for: imported.id)
        personalized.systemPrompt = "A private persona that must not resurrect."
        personalized.userPrompt = "A saved preference that must be removed."
        try firstModel.updateAvatarProfile(personalized)
        firstModel.activateAvatar(
            id: imported.id,
            displayName: imported.displayName
        )
        let threadID = UUID()
        firstModel.registerThread(threadID, for: imported.id)

        // Simulate termination after the atomic package commit, before the
        // in-process coordinator can remove the persisted profile and threads.
        try OpenClamAvatarPackageStore(storageRoot: root)
            .deleteInstalledAvatar(id: imported.id)

        let restartedLibrary = OpenClamAvatarLibrary(storageRoot: root)
        let restartedModel = AIConfigurationModel(
            defaults: defaults,
            storageKey: storageKey,
            credentialStore: AvatarPackageMemoryCredentialStore()
        )
        XCTAssertEqual(
            restartedLibrary.pendingCommittedDeletionIDs,
            [imported.id]
        )
        XCTAssertEqual(
            restartedModel.profile(for: imported.id).systemPrompt,
            personalized.systemPrompt
        )

        restartedLibrary.reconcileCommittedDeletions(
            configuration: restartedModel
        )
        restartedModel.reconcileAvatarCatalog(restartedLibrary.identities)

        XCTAssertEqual(
            restartedModel.activeAvatarID,
            AvatarAgentIdentity.defaultID
        )
        XCTAssertNil(restartedModel.avatarAgentProfiles[imported.id])
        XCTAssertNil(restartedModel.activeThreadID(for: imported.id))
        XCTAssertNil(restartedModel.avatarID(for: threadID))
        XCTAssertTrue(restartedLibrary.pendingCommittedDeletionIDs.isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            []
        )

        let reimported = try await restartedLibrary.importAvatar(
            from: goldenFixtureURL
        )
        restartedModel.reconcileAvatarCatalog(restartedLibrary.identities)
        XCTAssertEqual(reimported.id, imported.id)
        XCTAssertEqual(restartedModel.profile(for: imported.id).systemPrompt, "")
        XCTAssertEqual(restartedModel.profile(for: imported.id).userPrompt, "")
    }

    @MainActor
    func testConcurrentDeleteTapIsRejectedWhileCommitIsInFlight() async throws {
        let root = try temporaryDirectory()
        let enteredCommit = expectation(description: "entered deletion commit")
        let releaseCommit = DispatchSemaphore(value: 0)
        let library = OpenClamAvatarLibrary(
            storageRoot: root,
            deletionMoveItem: { source, destination in
                enteredCommit.fulfill()
                guard releaseCommit.wait(timeout: .now() + 3) == .success else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        )
        let avatar = try await library.importAvatar(from: goldenFixtureURL)
        let firstDelete = Task { @MainActor in
            try await library.deleteImportedAvatar(id: avatar.id)
        }

        await fulfillment(of: [enteredCommit], timeout: 3)
        XCTAssertEqual(library.mutation, .deleting(avatar.id))
        do {
            try await library.deleteImportedAvatar(id: avatar.id)
            XCTFail("A second delete tap must not start another filesystem transaction")
        } catch {
            XCTAssertEqual(
                error as? OpenClamAvatarPackageError,
                .avatarOperationInProgress
            )
        }

        releaseCommit.signal()
        try await firstDelete.value
        XCTAssertFalse(library.isMutating)
        XCTAssertFalse(library.isImported(id: avatar.id))
    }

    @MainActor
    func testProtectedAvatarDeletionIsRejectedWithoutMutation() async throws {
        let root = try temporaryDirectory()
        let library = OpenClamAvatarLibrary(storageRoot: root)
        let model = AIConfigurationModel(
            defaults: try isolatedDefaults(),
            storageKey: "avatar-delete-protected",
            credentialStore: AvatarPackageMemoryCredentialStore()
        )
        model.reconcileAvatarCatalog(library.identities)
        let protectedAvatar = try XCTUnwrap(
            library.avatar(id: AvatarAgentIdentity.defaultID)
        )

        do {
            _ = try await OpenClamAvatarDeletionCoordinator.perform(
                decision: .confirm,
                avatar: protectedAvatar,
                library: library,
                configuration: model
            )
            XCTFail("A bundled avatar must never be deletable")
        } catch {
            XCTAssertEqual(error as? OpenClamAvatarPackageError, .protectedAvatar)
        }

        XCTAssertEqual(model.activeAvatarID, AvatarAgentIdentity.defaultID)
        XCTAssertNotNil(library.avatar(id: AvatarAgentIdentity.defaultID))
        XCTAssertFalse(library.isMutating)
    }

    func testArchiveMetadataAcceptsOnlyTheExactSafeFileSet() throws {
        let valid = validArchiveMetadata()
        XCTAssertNoThrow(
            try OpenClamAvatarPackageContract.validateArchiveMetadata(
                valid,
                archiveByteCount: 24_000
            )
        )

        var duplicate = valid
        duplicate[duplicate.count - 1] = duplicate[1]
        try assertMetadataError(.duplicateArchivePath(duplicate[1].path), entries: duplicate)

        var traversal = valid
        traversal[traversal.count - 1] = .init(
            path: "../source.png",
            kind: .file,
            compressedSize: 1,
            uncompressedSize: 1
        )
        try assertMetadataError(.invalidArchiveEntry("../source.png"), entries: traversal)

        var extra = valid
        extra[extra.count - 1] = .init(
            path: "assets/source.png",
            kind: .file,
            compressedSize: 1,
            uncompressedSize: 1
        )
        try assertMetadataError(.unexpectedArchivePath("assets/source.png"), entries: extra)

        var symlink = valid
        symlink[1] = .init(
            path: symlink[1].path,
            kind: .symbolicLink,
            compressedSize: 1,
            uncompressedSize: 1
        )
        try assertMetadataError(.invalidArchiveEntry(symlink[1].path), entries: symlink)

        try assertMetadataError(.tooManyFiles, entries: Array(valid.dropLast()))
    }

    func testArchiveMetadataEnforcesCompressedAndExpandedLimitsWithoutAllocating() throws {
        let valid = validArchiveMetadata()
        XCTAssertThrowsError(
            try OpenClamAvatarPackageContract.validateArchiveMetadata(
                valid,
                archiveByteCount: OpenClamAvatarPackageContract.maximumArchiveByteCount + 1
            )
        ) { error in
            XCTAssertEqual(error as? OpenClamAvatarPackageError, .archiveTooLarge)
        }

        var oversizedFile = valid
        oversizedFile[1] = .init(
            path: oversizedFile[1].path,
            kind: .file,
            compressedSize: 1,
            uncompressedSize: OpenClamAvatarPackageContract.maximumAssetByteCount + 1
        )
        try assertMetadataError(.packageContentsTooLarge, entries: oversizedFile)

        let expandedTotal = valid.enumerated().map { index, entry in
            OpenClamAvatarArchiveEntryMetadata(
                path: entry.path,
                kind: .file,
                compressedSize: 1,
                uncompressedSize: index == 0 ? 1 : 4 * 1_024 * 1_024
            )
        }
        try assertMetadataError(.packageContentsTooLarge, entries: expandedTotal)
    }

    func testInvalidExtensionAndCorruptArchiveAreFriendlyFailures() throws {
        let root = try temporaryDirectory()
        let wrongExtension = root.appendingPathComponent("avatar.zip")
        try Data("not an avatar".utf8).write(to: wrongExtension)
        XCTAssertThrowsError(
            try OpenClamAvatarPackageStore(storageRoot: root.appendingPathComponent("store"))
                .installArchive(at: wrongExtension)
        ) { error in
            XCTAssertEqual(error as? OpenClamAvatarPackageError, .invalidFileExtension)
        }

        let corrupt = root.appendingPathComponent("avatar.avtr")
        try Data("not a zip".utf8).write(to: corrupt)
        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenClamAvatarImports", isDirectory: true)
        let snapshotsBefore = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: snapshotDirectory.path)) ?? []
        )
        XCTAssertThrowsError(
            try OpenClamAvatarPackageStore(storageRoot: root.appendingPathComponent("store"))
                .installArchive(at: corrupt)
        ) { error in
            XCTAssertEqual(error as? OpenClamAvatarPackageError, .invalidArchive)
        }
        let snapshotsAfter = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: snapshotDirectory.path)) ?? []
        )
        XCTAssertEqual(snapshotsAfter, snapshotsBefore)
    }

    private var goldenFixtureURL: URL {
        get throws {
            try XCTUnwrap(
                Bundle(for: Self.self).url(
                    forResource: "ios-light-golden",
                    withExtension: "avtr"
                ),
                "The generated ios-light golden AVTR must be copied into the test bundle."
            )
        }
    }

    private var motionFixtureURL: URL {
        get throws {
            try XCTUnwrap(
                Bundle(for: Self.self).url(
                    forResource: "ios-light-motion-v3-golden",
                    withExtension: "avtr"
                ),
                "The generated ios-light v3 motion fixture must be in the test bundle."
            )
        }
    }

    private var expectedAssetRoles: Set<OpenClamAvatarAssetRole> {
        Set(
            [
                .thumbnail, .body, .headMask, .eyeLeft, .eyeRight,
                .browLeft, .browRight, .gazeLeftAtlas, .gazeRightAtlas,
            ] + OpenClamAvatarViseme.allCases.map(OpenClamAvatarAssetRole.viseme)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenClamAvatarPackageTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "OpenClamAvatarPackageTests.defaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func assertManifestMutationRejected(
        expected: OpenClamAvatarPackageError,
        mutate: (inout [String: Any]) throws -> Void
    ) throws {
        try assertImportError(expected, archive: archiveByMutatingManifest(mutate))
    }

    private func assertImportError(
        _ expected: OpenClamAvatarPackageError,
        archive: URL
    ) throws {
        let root = try temporaryDirectory().appendingPathComponent("installed")
        XCTAssertThrowsError(
            try OpenClamAvatarPackageStore(storageRoot: root).installArchive(at: archive)
        ) { error in
            XCTAssertEqual(error as? OpenClamAvatarPackageError, expected)
        }
    }

    private func assertMetadataError(
        _ expected: OpenClamAvatarPackageError,
        entries: [OpenClamAvatarArchiveEntryMetadata]
    ) throws {
        XCTAssertThrowsError(
            try OpenClamAvatarPackageContract.validateArchiveMetadata(
                entries,
                archiveByteCount: 24_000
            )
        ) { error in
            XCTAssertEqual(error as? OpenClamAvatarPackageError, expected)
        }
    }

    private func validArchiveMetadata() -> [OpenClamAvatarArchiveEntryMetadata] {
        let assetPaths = OpenClamAvatarPackageContract.assetSpecifications.map {
            "assets/\($0.baseFilename).png"
        }
        return ([OpenClamAvatarPackageContract.manifestPath] + assetPaths).map {
            .init(path: $0, kind: .file, compressedSize: 100, uncompressedSize: 200)
        }
    }

    private struct FixtureEntry {
        let path: String
        let type: ZIPFoundation.Entry.EntryType
        var data: Data
    }

    private func fixtureEntries() throws -> [FixtureEntry] {
        try fixtureEntries(from: goldenFixtureURL)
    }

    private func fixtureEntries(from fixtureURL: URL) throws -> [FixtureEntry] {
        let archive = try ZIPFoundation.Archive(url: fixtureURL, accessMode: .read)
        return try archive.map { entry in
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            return FixtureEntry(path: entry.path, type: entry.type, data: data)
        }
    }

    private func archiveByMutatingMotionManifest(
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws -> URL {
        try archiveByMutatingMotionEntries { entries in
            let index = try XCTUnwrap(
                entries.firstIndex(where: { $0.path == "manifest.json" })
            )
            var manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(with: entries[index].data)
                    as? [String: Any]
            )
            try mutate(&manifest)
            entries[index].data = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys]
            )
        }
    }

    private func archiveByMutatingMotionEntries(
        _ mutate: (inout [FixtureEntry]) throws -> Void
    ) throws -> URL {
        var entries = try fixtureEntries(from: motionFixtureURL)
        try mutate(&entries)
        return try makeArchive(entries)
    }

    private func archiveByMutatingManifest(
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws -> URL {
        try archiveByMutatingEntries { entries in
            let index = try XCTUnwrap(
                entries.firstIndex(where: { $0.path == "manifest.json" })
            )
            var manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(with: entries[index].data)
                    as? [String: Any]
            )
            try mutate(&manifest)
            entries[index].data = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys]
            )
        }
    }

    private func archiveByMutatingEntries(
        _ mutate: (inout [FixtureEntry]) throws -> Void
    ) throws -> URL {
        var entries = try fixtureEntries()
        try mutate(&entries)
        return try makeArchive(entries)
    }

    private func makeArchive(_ entries: [FixtureEntry]) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("fixture.avtr")
        let archive = try ZIPFoundation.Archive(url: url, accessMode: .create)
        for entry in entries {
            let data = entry.data
            try archive.addEntry(
                with: entry.path,
                type: entry.type,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let lowerBound = Int(position)
                let upperBound = min(data.count, lowerBound + size)
                return data.subdata(in: lowerBound ..< upperBound)
            }
        }
        return url
    }
}

private final class AvatarPackageMemoryCredentialStore: AgentCredentialStore,
    @unchecked Sendable {
    func saveAPIKey(_ apiKey: String) throws {}
    func loadAPIKey() throws -> String? { nil }
    func deleteAPIKey() throws {}
}
