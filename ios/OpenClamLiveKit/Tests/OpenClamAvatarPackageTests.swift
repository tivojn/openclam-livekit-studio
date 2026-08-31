import CryptoKit
import CoreGraphics
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
        XCTAssertEqual(descriptor.sourceMedium, .photograph)
        XCTAssertNil(descriptor.speechPatch)
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

    @MainActor
    func testLibraryKeepsImportedAvatarAlongsideTwoBundledAvatars() async throws {
        let root = try temporaryDirectory()
        let library = OpenClamAvatarLibrary(storageRoot: root)

        XCTAssertEqual(
            library.avatars.map(\.id),
            ["captain-ayer", "ara"]
        )

        _ = try await library.importAvatar(from: goldenFixtureURL)

        XCTAssertEqual(
            library.avatars.map(\.id),
            ["captain-ayer", "ara", "golden-guide"]
        )
        XCTAssertEqual(
            OpenClamAvatarLibrary(storageRoot: root).avatars.map(\.id),
            ["captain-ayer", "ara", "golden-guide"]
        )
    }

    func testLegacyNineVisemePackageAliasesEveryNewProductionShape() throws {
        let root = try temporaryDirectory()
        let descriptor = try OpenClamAvatarPackageStore(storageRoot: root)
            .installArchive(at: goldenFixtureURL)

        XCTAssertNil(descriptor.expressionGeometry)
        for viseme in OpenClamAvatarViseme.allCases {
            XCTAssertNotNil(
                descriptor.asset(.viseme(viseme)),
                "Legacy v2/v3 avatars must keep speaking for \(viseme.rawValue)"
            )
        }
        XCTAssertEqual(
            descriptor.asset(.viseme(.bilabial)),
            descriptor.asset(.viseme(.labiodental))
        )
        XCTAssertEqual(
            descriptor.asset(.viseme(.openRounded)),
            descriptor.asset(.viseme(.rounded))
        )
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

    func testFullExpressionV4ImportsEveryFaceBankAndReloads() throws {
        let root = try temporaryDirectory()
        let store = OpenClamAvatarPackageStore(storageRoot: root)
        let descriptor = try store.installArchive(
            at: fullExpressionV4Archive()
        )

        let expression = try XCTUnwrap(descriptor.expressionGeometry)
        XCTAssertEqual(descriptor.id, "full-expression-guide")
        XCTAssertEqual(descriptor.sourceMedium, .photograph)
        XCTAssertNil(descriptor.speechPatch)
        XCTAssertTrue(descriptor.compatibility.supportsMacV22ExpressionParity)
        XCTAssertEqual(expression.smileVisemes, OpenClamAvatarViseme.allCases)
        XCTAssertEqual(expression.emotionMouthVisemes, OpenClamAvatarViseme.allCases)
        XCTAssertEqual(
            expression.emotionMouthEmotions,
            ["sorrow", "horror", "anger"]
        )
        XCTAssertEqual(Set(descriptor.assets.keys), fullExpressionAssetRoles)
        XCTAssertEqual(Set(descriptor.motions.keys), [.edgeIdle, .moves])
        for viseme in OpenClamAvatarViseme.allCases {
            XCTAssertNotNil(
                descriptor.assets[.viseme(viseme)],
                "v4 must contain a real production plate for \(viseme.rawValue), not a legacy alias"
            )
        }

        let reloaded = try XCTUnwrap(store.loadInstalledDescriptors().first)
        XCTAssertEqual(reloaded.id, descriptor.id)
        XCTAssertEqual(reloaded.expressionGeometry, expression)
        XCTAssertEqual(expression.smile.storage, .gridAtlas)
        XCTAssertEqual(expression.emotionMouth.storage, .gridAtlas)
        XCTAssertEqual(expression.browGain, 1)
        XCTAssertEqual(expression.foreheadGain, 1)
        XCTAssertEqual(expression.underEyeGain, 1)
        XCTAssertEqual(Set(reloaded.assets.keys), fullExpressionAssetRoles)
        XCTAssertEqual(Set(reloaded.motions.keys), [.edgeIdle, .moves])
        XCTAssertTrue(reloaded.compatibility.supportsMacV22ExpressionParity)
    }

    func testFullExpressionV4ImportsValidatedSpeechPatchAndReloads() throws {
        let archive = try fullExpressionV4Archive { manifest in
            manifest["sourceMedium"] = "illustration"
            manifest["speechPatch"] = self.validSpeechPatchManifest()
        }
        let root = try temporaryDirectory()
        let store = OpenClamAvatarPackageStore(storageRoot: root)
        let descriptor = try store.installArchive(at: archive)

        XCTAssertEqual(descriptor.sourceMedium, .illustration)
        let speechPatch = try XCTUnwrap(descriptor.speechPatch)
        XCTAssertNil(speechPatch.skinMatch)
        XCTAssertEqual(
            speechPatch.box,
            OpenClamAvatarRect(x: 400, y: 680, width: 240, height: 150)
        )
        XCTAssertEqual(speechPatch.xOffset(for: .silence), 0)
        XCTAssertEqual(speechPatch.xOffset(for: .bilabial), -96)
        XCTAssertEqual(speechPatch.xOffset(for: .labiodental), 96)
        XCTAssertEqual(speechPatch.xOffset(for: .open), 3)

        let reloaded = try XCTUnwrap(store.loadInstalledDescriptors().first)
        XCTAssertEqual(reloaded.sourceMedium, .illustration)
        XCTAssertEqual(reloaded.speechPatch, speechPatch)
    }

    func testFullExpressionV4ImportsOptionalMouthSkinMatchAndReloads() throws {
        let archive = try mouthSkinMatchArchive()
        let root = try temporaryDirectory().appendingPathComponent("installed")
        let store = OpenClamAvatarPackageStore(storageRoot: root)
        let descriptor = try store.installArchive(at: archive)
        let skin = try XCTUnwrap(descriptor.speechPatch?.skinMatch)
        XCTAssertEqual(skin.version, 1)
        XCTAssertEqual(skin.space, "canonical-pixels")
        XCTAssertEqual(Set(skin.contours.keys), Set(OpenClamAvatarViseme.allCases.map(\.rawValue)))
        XCTAssertEqual(skin.contours["sil"]?.count, 12)
        XCTAssertEqual(skin.emotionContours["smile"]?["ou"]?.count, 5)
        XCTAssertEqual(skin.emotionContours["horror"]?["aa"]?.count, 4)
        XCTAssertEqual(
            skin.emotionContours.values.reduce(skin.contours.count) { count, bank in
                count + bank.values.reduce(0) { $0 + $1.count }
            },
            270
        )
        let reloaded = try XCTUnwrap(store.loadInstalledDescriptors().first)
        XCTAssertEqual(reloaded.speechPatch?.skinMatch, skin)
        let encoded = try JSONEncoder().encode(skin)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(raw.keys), ["v", "space", "contours", "emotion_contours"])
        XCTAssertEqual(try JSONDecoder().decode(OpenClamAvatarMouthSkinMatchMetadata.self, from: encoded), skin)
    }

    func testSpeechPatchInitializerRemainsBackwardCompatible() {
        let value = OpenClamAvatarSpeechPatchMetadata(
            box: .init(x: 400, y: 680, width: 240, height: 150),
            visemeXOffsets: ["sil": 0]
        )
        XCTAssertNil(value.skinMatch)
    }

    func testMouthSkinMatchRequiresExplicitSoft3DClassification() throws {
        for medium in ["photograph", "illustration", "anime", "game art", nil] {
            try assertImportError(.invalidRig, archive: mouthSkinMatchArchive(sourceMedium: medium))
        }
    }

    func testMouthSkinMatchRejectsUnknownVersionAndCoordinateSpace() throws {
        for version: Any in [2, true, "1"] {
            try assertImportError(.invalidRig, archive: mouthSkinMatchArchive { skin in
                skin["v"] = version
            })
        }
        try assertImportError(.invalidRig, archive: mouthSkinMatchArchive { skin in
            skin["space"] = "mouth-local"
        })
    }

    func testMouthSkinMatchRejectsMissingOrExtraVisemesAndPrivateMetadata() throws {
        for extra in [false, true] {
            try assertImportError(.privateMetadataNotAllowed, archive: mouthSkinMatchArchive { skin in
                var contours = try XCTUnwrap(skin["contours"] as? [String: [[Double]]])
                if extra {
                    contours["future"] = contours["sil"]
                } else {
                    contours.removeValue(forKey: "ou")
                }
                skin["contours"] = contours
            })
        }
        try assertImportError(.privateMetadataNotAllowed, archive: mouthSkinMatchArchive { skin in
            skin["canonical_key"] = ["sha256": "private-authoring-provenance"]
        })
    }

    func testMouthSkinMatchRejectsMissingFamilyVisemeOrState() throws {
        for problem in 0 ... 2 {
            let expected: OpenClamAvatarPackageError = problem == 2 ? .invalidRig : .privateMetadataNotAllowed
            try assertImportError(expected, archive: mouthSkinMatchArchive { skin in
                var emotions = try XCTUnwrap(skin["emotion_contours"] as? [String: [String: [[[Double]]]]])
                if problem == 0 { emotions.removeValue(forKey: "anger") }
                if problem == 1 { emotions["anger"]?.removeValue(forKey: "TH") }
                if problem == 2 { emotions["smile"]?["PP"]?.removeLast() }
                skin["emotion_contours"] = emotions
            })
        }
    }

    func testMouthSkinMatchRejectsBooleanAndStringPointComponents() throws {
        for component: Any in [true, "512"] {
            try assertImportError(.invalidRig, archive: mouthSkinMatchArchive { skin in
                var contours = try XCTUnwrap(skin["contours"] as? [String: [[Double]]])
                    .mapValues { $0.map { $0.map { $0 as Any } } }
                contours["sil"]?[0][0] = component
                skin["contours"] = contours
            })
        }
    }

    func testMouthSkinMatchRejectsOutOfCanonicalAndMouthBounds() throws {
        for coordinate in [-1.0, 1_025.0, 10.0, 1_000.0] {
            try assertImportError(.invalidRig, archive: mouthSkinMatchArchive { skin in
                var contours = try XCTUnwrap(skin["contours"] as? [String: [[Double]]])
                contours["aa"]?[0][0] = coordinate
                skin["contours"] = contours
            })
        }
    }

    func testMouthSkinMatchRejectsShortCrossedAndDegeneratePolygons() throws {
        for problem in 0 ... 4 {
            try assertImportError(.invalidRig, archive: mouthSkinMatchArchive { skin in
                var contours = try XCTUnwrap(skin["contours"] as? [String: [[Double]]])
                var points = try XCTUnwrap(contours["sil"])
                switch problem {
                case 0: points = Array(points.prefix(7))
                case 1: points.swapAt(2, 8)
                case 2: points[points.count - 1] = points[0]
                case 3:
                    let ring = (0 ..< 9).map { index in
                        let angle = Double(index) * 2 * Double.pi / 9
                        return [511 + 42 * cos(angle), 752 + 13 * sin(angle)]
                    }
                    points = (0 ..< 9).map { ring[($0 * 2) % 9] }
                default: points = (0 ..< 8).map { [500.0 + Double($0), 750.0] }
                }
                contours["sil"] = points
                skin["contours"] = contours
            })
        }
    }

    func testMouthSkinMatchRejectsOversizedGeometryBeforeInstalling() throws {
        let archive = try mouthSkinMatchArchive { skin in
            skin = self.validMouthSkinMatchManifest(vertices: 64)
        }
        try assertImportError(.manifestTooLarge, archive: archive)
    }

    func testMouthSkinMatchFractionalContoursUseTypedByteBudget() throws {
        let archive = try shortestDoubleMouthSkinMatchArchive(vertices: 18)
        let manifestData = try XCTUnwrap(
            fixtureEntries(from: archive).first(where: { $0.path == "manifest.json" })?.data
        )
        let manifest = try JSONDecoder().decode(OpenClamAvatarPackageManifest.self, from: manifestData)
        let skin = try XCTUnwrap(manifest.speechPatch?.skinMatch)
        let compact = try JSONEncoder().encode(skin)
        let raw = try JSONSerialization.jsonObject(with: compact)
        let foundationExpanded = try JSONSerialization.data(withJSONObject: raw)

        XCTAssertLessThanOrEqual(UInt64(manifestData.count), OpenClamAvatarPackageContract.maximumManifestByteCount)
        XCTAssertLessThanOrEqual(compact.count, OpenClamAvatarPackageContract.maximumMouthSkinMatchByteCount)
        XCTAssertGreaterThan(foundationExpanded.count, OpenClamAvatarPackageContract.maximumMouthSkinMatchByteCount)

        let root = try temporaryDirectory().appendingPathComponent("installed")
        let store = OpenClamAvatarPackageStore(storageRoot: root)
        let descriptor = try store.installArchive(at: archive)
        XCTAssertEqual(descriptor.speechPatch?.skinMatch, skin)
        XCTAssertEqual(store.loadInstalledDescriptors().first?.speechPatch?.skinMatch, skin)
    }

    func testMouthSkinMatchTypedByteCapStillRejectsWithinManifestCap() throws {
        let archive = try shortestDoubleMouthSkinMatchArchive(vertices: 22)
        let manifestData = try XCTUnwrap(
            fixtureEntries(from: archive).first(where: { $0.path == "manifest.json" })?.data
        )
        let manifest = try JSONDecoder().decode(OpenClamAvatarPackageManifest.self, from: manifestData)
        let skin = try XCTUnwrap(manifest.speechPatch?.skinMatch)
        XCTAssertLessThanOrEqual(UInt64(manifestData.count), OpenClamAvatarPackageContract.maximumManifestByteCount)
        XCTAssertGreaterThan(
            try JSONEncoder().encode(skin).count,
            OpenClamAvatarPackageContract.maximumMouthSkinMatchByteCount
        )
        try assertImportError(.invalidRig, archive: archive)
    }

    func testSpeechPatchIsRejectedByV2AndV3Manifests() throws {
        let v2 = try archiveByMutatingManifest { manifest in
            manifest["speechPatch"] = self.validSpeechPatchManifest()
        }
        try assertImportError(.privateMetadataNotAllowed, archive: v2)

        let v3 = try archiveByMutatingMotionManifest { manifest in
            manifest["speechPatch"] = self.validSpeechPatchManifest()
        }
        try assertImportError(.privateMetadataNotAllowed, archive: v3)
    }

    func testFullExpressionV4RejectsIncompleteSpeechPatchVisemes() throws {
        let archive = try fullExpressionV4Archive { manifest in
            var speechPatch = self.validSpeechPatchManifest()
            var offsets = try XCTUnwrap(
                speechPatch["visemeXOffsets"] as? [String: Double]
            )
            offsets.removeValue(forKey: OpenClamAvatarViseme.rounded.rawValue)
            speechPatch["visemeXOffsets"] = offsets
            manifest["speechPatch"] = speechPatch
        }
        try assertImportError(.privateMetadataNotAllowed, archive: archive)
    }

    func testFullExpressionV4RejectsInvalidSpeechPatchCalibration() throws {
        let outsideFace = try fullExpressionV4Archive { manifest in
            var speechPatch = self.validSpeechPatchManifest()
            speechPatch["box"] = [
                "x": 900, "y": 680, "width": 240, "height": 150,
            ]
            manifest["speechPatch"] = speechPatch
        }
        try assertImportError(.invalidRig, archive: outsideFace)

        let excessiveOffset = try fullExpressionV4Archive { manifest in
            var speechPatch = self.validSpeechPatchManifest()
            var offsets = try XCTUnwrap(
                speechPatch["visemeXOffsets"] as? [String: Double]
            )
            offsets[OpenClamAvatarViseme.open.rawValue] = 96.001
            speechPatch["visemeXOffsets"] = offsets
            manifest["speechPatch"] = speechPatch
        }
        try assertImportError(.invalidRig, archive: excessiveOffset)

        let movingSilence = try fullExpressionV4Archive { manifest in
            var speechPatch = self.validSpeechPatchManifest()
            var offsets = try XCTUnwrap(
                speechPatch["visemeXOffsets"] as? [String: Double]
            )
            offsets[OpenClamAvatarViseme.silence.rawValue] = 0.001
            speechPatch["visemeXOffsets"] = offsets
            manifest["speechPatch"] = speechPatch
        }
        try assertImportError(.invalidRig, archive: movingSilence)
    }

    func testFullExpressionV4RejectsWrongExpressionAtlasGeometry() throws {
        let archive = try fullExpressionV4Archive { manifest in
            var expression = try XCTUnwrap(
                manifest["expression"] as? [String: Any]
            )
            var smile = try XCTUnwrap(expression["smile"] as? [String: Any])
            var box = try XCTUnwrap(smile["box"] as? [String: Any])
            box["width"] = 5
            smile["box"] = box
            expression["smile"] = smile
            manifest["expression"] = expression
        }

        try assertImportError(
            .dimensionMismatch("smile-atlas"),
            archive: archive
        )
    }

    func testFullExpressionV4RejectsOutOfRangeCalibrationGains() throws {
        for (key, value) in [
            ("browGain", 1.351),
            ("foreheadGain", -0.001),
            ("underEyeGain", 1.351),
        ] {
            let archive = try fullExpressionV4Archive { manifest in
                var expression = try XCTUnwrap(
                    manifest["expression"] as? [String: Any]
                )
                expression[key] = value
                manifest["expression"] = expression
            }
            try assertImportError(.invalidRig, archive: archive)
        }
    }

    func testPythonExporterGoldenV4ImportsThroughSwiftContract() throws {
        let data = try XCTUnwrap(
            Data(
                base64Encoded: Self.pythonExporterV4GoldenBase64,
                options: .ignoreUnknownCharacters
            )
        )
        XCTAssertEqual(
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "79c21dedb5c93b126e04b38df09e41aabd8375d7048cbcc3e5be39186f5545a3",
            "The fixture must remain the byte-exact output of avatar_package.py"
        )
        let archive = try temporaryDirectory()
            .appendingPathComponent("python-v4-golden.avtr")
        try data.write(to: archive, options: .atomic)
        let root = try temporaryDirectory()
        let descriptor = try OpenClamAvatarPackageStore(storageRoot: root)
            .installArchive(at: archive)

        XCTAssertEqual(descriptor.id, "python-v4-guide")
        XCTAssertEqual(
            descriptor.compatibility.canonicalVisemeCount,
            OpenClamAvatarViseme.allCases.count
        )
        XCTAssertTrue(descriptor.compatibility.supportsMacV22ExpressionParity)
        XCTAssertEqual(
            descriptor.expressionGeometry?.smileVisemes,
            OpenClamAvatarViseme.allCases
        )
        XCTAssertEqual(Set(descriptor.assets.keys), fullExpressionAssetRoles)
    }

    func testFullExpressionV4RejectsAggregateDecodedPixelBudget() throws {
        let archive = try fullExpressionV4Archive { manifest in
            var assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
            for role in ["viseme-sil", "viseme-PP", "viseme-FF", "viseme-TH"] {
                var record = try XCTUnwrap(assets[role] as? [String: Any])
                record["width"] = 4_096
                record["height"] = 4_096
                assets[role] = record
            }
            manifest["assets"] = assets
        }
        try assertImportError(.packageContentsTooLarge, archive: archive)
    }

    func testFullExpressionV4RejectsTextureDimensionAbove8192() throws {
        let archive = try fullExpressionV4Archive { manifest in
            var assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
            var emotion = try XCTUnwrap(
                assets["emotion-mouth-atlas"] as? [String: Any]
            )
            emotion["width"] = 8_193
            emotion["height"] = 1
            assets["emotion-mouth-atlas"] = emotion
            manifest["assets"] = assets
        }
        try assertImportError(
            .dimensionMismatch("emotion-mouth-atlas"),
            archive: archive
        )
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

    func testStagedProductionStorePackagesPassFullBundledUpdateImport() throws {
        guard let stagingPath = ProcessInfo.processInfo.environment[
            "OPENCLAM_AVATAR_STORE_STAGING"
        ], !stagingPath.isEmpty else {
            throw XCTSkip(
                "Set OPENCLAM_AVATAR_STORE_STAGING for the local production-package audit."
            )
        }

        let releaseRoot = URL(fileURLWithPath: stagingPath, isDirectory: true)
            .appendingPathComponent("release-assets", isDirectory: true)
        let packageURLs = try FileManager.default.contentsOfDirectory(
            at: releaseRoot,
            includingPropertiesForKeys: nil
        )
            .filter { $0.pathExtension == "avtr" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(
            packageURLs.isEmpty,
            "Production staging must contain at least one release AVTR."
        )

        for packageURL in packageURLs {
            let packageStem = packageURL.deletingPathExtension().lastPathComponent
            let variantSuffix = "-ios-light"
            XCTAssertTrue(
                packageStem.hasSuffix(variantSuffix),
                "Unexpected production package name: \(packageURL.lastPathComponent)"
            )
            let id = String(packageStem.dropLast(variantSuffix.count))
            XCTAssertFalse(id.isEmpty)

            let storageRoot = try temporaryDirectory()
            let descriptor = try OpenClamAvatarPackageStore(
                storageRoot: storageRoot
            ).installArchive(
                at: packageURL,
                expectedID: id,
                allowsBundledStoreUpdate: true
            )
            XCTAssertEqual(descriptor.id, id)
            XCTAssertEqual(
                OpenClamAvatarPackageStore(storageRoot: storageRoot)
                    .loadInstalledDescriptors().map(\.id),
                [id]
            )
        }
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

    @MainActor
    func testStoreOnlyPathInstallsProtectedBundledUpdateAndDirectImportStillFails() async throws {
        let archive = try archiveByMutatingManifest { manifest in
            manifest["id"] = "captain-ayer"
            manifest["displayName"] = "Captain Ayer Downloaded"
        }

        let directRoot = try temporaryDirectory()
        let directLibrary = OpenClamAvatarLibrary(storageRoot: directRoot)
        do {
            _ = try await directLibrary.importAvatar(from: archive)
            XCTFail("Direct Files import must not replace a bundled avatar.")
        } catch {
            XCTAssertEqual(
                error as? OpenClamAvatarPackageError,
                .bundledIdentifierCollision
            )
        }

        let storeRoot = try temporaryDirectory()
        let library = OpenClamAvatarLibrary(storageRoot: storeRoot)
        let installed = try await library.installStoreAvatar(
            from: archive,
            expectedID: "captain-ayer"
        )

        XCTAssertEqual(installed.id, "captain-ayer")
        XCTAssertEqual(
            library.avatar(id: "captain-ayer")?.displayName,
            "Captain Ayer Downloaded"
        )
        XCTAssertEqual(
            library.avatars.filter { $0.id == "captain-ayer" }.count,
            1,
            "The downloaded descriptor must replace, not duplicate, the bundled row."
        )
        XCTAssertTrue(library.isImported(id: "captain-ayer"))
        XCTAssertTrue(library.isProtected(id: "captain-ayer"))
        do {
            try await library.deleteImportedAvatar(id: "captain-ayer")
            XCTFail("A bundled fallback must remain protected after a Store update.")
        } catch {
            XCTAssertEqual(error as? OpenClamAvatarPackageError, .protectedAvatar)
        }

        let restarted = OpenClamAvatarLibrary(storageRoot: storeRoot)
        XCTAssertEqual(
            restarted.avatar(id: "captain-ayer")?.displayName,
            "Captain Ayer Downloaded"
        )
        XCTAssertTrue(restarted.isProtected(id: "captain-ayer"))
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
            ] + OpenClamAvatarViseme.legacyCases.map(OpenClamAvatarAssetRole.viseme)
        )
    }

    private var fullExpressionAssetRoles: Set<OpenClamAvatarAssetRole> {
        Set(
            [
                .thumbnail, .body, .headMask, .eyeLeft, .eyeRight,
                .browLeft, .browRight, .gazeLeftAtlas, .gazeRightAtlas,
                .smileAtlas, .emotionMouthAtlas, .foreheadLeft,
                .foreheadRight, .cheekLeft, .cheekRight,
                .underEyeLeft, .underEyeRight,
            ] + OpenClamAvatarViseme.allCases.map(OpenClamAvatarAssetRole.viseme)
        )
    }

    private func validSpeechPatchManifest() -> [String: Any] {
        var offsets = Dictionary(
            uniqueKeysWithValues: OpenClamAvatarViseme.allCases.enumerated().map {
                ($0.element.rawValue, Double($0.offset - 7))
            }
        )
        offsets[OpenClamAvatarViseme.silence.rawValue] = 0
        offsets[OpenClamAvatarViseme.bilabial.rawValue] = -96
        offsets[OpenClamAvatarViseme.labiodental.rawValue] = 96
        return [
            "box": ["x": 400, "y": 680, "width": 240, "height": 150],
            "visemeXOffsets": offsets,
        ]
    }

    private func validMouthSkinMatchManifest(vertices: Int = 12) -> [String: Any] {
        func polygon(shift: Double = 0) -> [[Double]] {
            (0 ..< vertices).map { index in
                let angle = Double(index) * 2 * Double.pi / Double(vertices)
                return [(1e4 * (511 + shift + 42 * cos(angle))).rounded() / 1e4,
                        (1e4 * (752 + 13 * sin(angle))).rounded() / 1e4]
            }
        }
        let names = OpenClamAvatarViseme.allCases.map(\.rawValue)
        let contours = Dictionary(uniqueKeysWithValues: names.enumerated().map {
            ($0.element, polygon(shift: Double($0.offset) * 0.1))
        })
        let emotions = Dictionary(uniqueKeysWithValues: ["smile", "sorrow", "horror", "anger"].map { family in
            (family, Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
                (name, (0 ..< (family == "smile" ? 5 : 4)).map {
                    polygon(shift: Double(index) * 0.1 + Double($0) * 0.05)
                })
            }))
        })
        return ["v": 1, "space": "canonical-pixels", "contours": contours, "emotion_contours": emotions]
    }

    private func mouthSkinMatchArchive(
        sourceMedium: String? = "3d render",
        mutate: ((inout [String: Any]) throws -> Void)? = nil
    ) throws -> URL {
        try fullExpressionV4Archive { manifest in
            manifest["sourceMedium"] = sourceMedium
            var speech = self.validSpeechPatchManifest()
            speech["visemeXOffsets"] = Dictionary(uniqueKeysWithValues: OpenClamAvatarViseme.allCases.map {
                ($0.rawValue, 0.0)
            })
            var skin = self.validMouthSkinMatchManifest()
            try mutate?(&skin)
            speech["skinMatch"] = skin
            manifest["speechPatch"] = speech
        }
    }

    private func shortestDoubleMouthSkinMatchArchive(vertices: Int) throws -> URL {
        let archive = try mouthSkinMatchArchive { skin in
            skin = self.validMouthSkinMatchManifest(vertices: vertices)
        }
        var entries = try fixtureEntries(from: archive)
        let index = try XCTUnwrap(entries.firstIndex(where: { $0.path == "manifest.json" }))
        let manifest = try JSONDecoder().decode(OpenClamAvatarPackageManifest.self, from: entries[index].data)
        entries[index].data = try JSONEncoder().encode(manifest)
        return try makeArchive(entries)
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

    private func fullExpressionV4Archive(
        mutateManifest: ((inout [String: Any]) throws -> Void)? = nil
    ) throws -> URL {
        var entries = try fixtureEntries(from: motionFixtureURL)
        let manifestIndex = try XCTUnwrap(
            entries.firstIndex(where: { $0.path == "manifest.json" })
        )
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: entries[manifestIndex].data)
                as? [String: Any]
        )
        manifest["version"] = OpenClamAvatarPackageContract.expressionVersion
        manifest["id"] = "full-expression-guide"
        manifest["displayName"] = "Full Expression Guide"

        var assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
        let legacyFallbacks = [
            "PP": "FF",
            "DD": "nn",
            "kk": "nn",
            "CH": "ih",
            "SS": "ih",
            "oh": "ou",
        ]
        for (viseme, fallback) in legacyFallbacks {
            let sourcePath = "assets/viseme-\(fallback).png"
            let destinationPath = "assets/viseme-\(viseme).png"
            let source = try XCTUnwrap(
                entries.first(where: { $0.path == sourcePath })
            )
            entries.append(
                FixtureEntry(
                    path: destinationPath,
                    type: .file,
                    data: source.data
                )
            )
            var record = try XCTUnwrap(
                assets["viseme-\(fallback)"] as? [String: Any]
            )
            record["path"] = destinationPath
            assets["viseme-\(viseme)"] = record
        }

        let expressionImages: [(
            key: String, path: String, width: Int, height: Int
        )] = [
            ("smile-atlas", "assets/smile-atlas.png", 20, 60),
            ("emotion-mouth-atlas", "assets/emotion-mouth-atlas.png", 16, 180),
            ("forehead-left", "assets/forehead-left.png", 4, 168),
            ("forehead-right", "assets/forehead-right.png", 4, 168),
            ("cheek-left", "assets/cheek-left.png", 4, 20),
            ("cheek-right", "assets/cheek-right.png", 4, 20),
            ("under-eye-left", "assets/under-eye-left.png", 4, 20),
            ("under-eye-right", "assets/under-eye-right.png", 4, 20),
        ]
        for (index, image) in expressionImages.enumerated() {
            let data = try expressionPNGData(
                width: image.width,
                height: image.height,
                shade: CGFloat(index + 1) / CGFloat(expressionImages.count + 1)
            )
            entries.append(
                FixtureEntry(path: image.path, type: .file, data: data)
            )
            assets[image.key] = [
                "path": image.path,
                "sha256": SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined(),
                "byteCount": data.count,
                "mediaType": "image/png",
                "width": image.width,
                "height": image.height,
            ]
        }
        manifest["assets"] = assets

        func sprite(
            x: Int,
            y: Int,
            columns: Int,
            rows: Int,
            storage: String = "verticalStrip"
        ) -> [String: Any] {
            [
                "box": ["x": x, "y": y, "width": 4, "height": 4],
                "columns": columns,
                "rows": rows,
                "storage": storage,
            ]
        }

        let visemes = OpenClamAvatarViseme.allCases.map(\.rawValue)
        manifest["expression"] = [
            "smile": sprite(
                x: 500,
                y: 650,
                columns: 5,
                rows: 15,
                storage: "gridAtlas"
            ),
            "emotionMouth": sprite(
                x: 500,
                y: 650,
                columns: 4,
                rows: 45,
                storage: "gridAtlas"
            ),
            "leftForehead": sprite(x: 560, y: 400, columns: 14, rows: 3),
            "rightForehead": sprite(x: 456, y: 400, columns: 14, rows: 3),
            "leftCheek": sprite(x: 560, y: 560, columns: 1, rows: 5),
            "rightCheek": sprite(x: 456, y: 560, columns: 1, rows: 5),
            "leftUnderEye": sprite(x: 560, y: 510, columns: 1, rows: 5),
            "rightUnderEye": sprite(x: 456, y: 510, columns: 1, rows: 5),
            "browOffsets": OpenClamAvatarExpressionGeometry.canonicalBrowOffsets,
            "browSqueezeOffsets": OpenClamAvatarExpressionGeometry
                .canonicalBrowSqueezeOffsets,
            "smileStrengths": OpenClamAvatarExpressionGeometry
                .canonicalSmileStrengths,
            "smileVisemes": visemes,
            "emotionMouthStrengths": OpenClamAvatarExpressionGeometry
                .canonicalEmotionMouthStrengths,
            "emotionMouthEmotions": ["sorrow", "horror", "anger"],
            "emotionMouthVisemes": visemes,
            "cheekOffsets": OpenClamAvatarExpressionGeometry.canonicalCheekOffsets,
            "underEyeOffsets": OpenClamAvatarExpressionGeometry
                .canonicalUnderEyeOffsets,
            "browGain": 1.0,
            "foreheadGain": 1.0,
            "underEyeGain": 1.0,
        ]

        try mutateManifest?(&manifest)
        entries[manifestIndex].data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        )
        return try makeArchive(entries)
    }

    private func expressionPNGData(
        width: Int,
        height: Int,
        shade: CGFloat
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(
            CGColor(
                colorSpace: colorSpace,
                components: [shade, 0.35, 0.65, 0.85]
            )!
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output,
                "public.png" as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// Byte-exact compact fixture produced by the macOS Python v4 exporter,
    /// not synthesized by Swift. Keeping the golden bytes here proves that
    /// exporter role names, paths, geometry, hashes, and image dimensions are
    /// accepted by the independent iOS decoder on every test run.
    private static let pythonExporterV4GoldenBase64 = """
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
"""

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
