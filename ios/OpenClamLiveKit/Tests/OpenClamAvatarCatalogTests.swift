import CryptoKit
import ImageIO
import XCTest
@testable import OpenClamLiveKit

final class OpenClamAvatarCatalogTests: XCTestCase {
    func testCatalogHasExactStableIDsNamesAndDefault() {
        XCTAssertEqual(
            OpenClamAvatarCatalog.avatars.map(\.id),
            ["captain-ayer", "ara"]
        )
        XCTAssertEqual(
            OpenClamAvatarCatalog.avatars.map(\.displayName),
            ["Captain Ayer", "Ara"]
        )
        XCTAssertEqual(OpenClamAvatarID.bundled, [.captainAyer, .ara])
        XCTAssertEqual(OpenClamAvatarCatalog.defaultAvatarID, "captain-ayer")
    }

    func testSelectionBridgeCarriesOnlyIDAndDisplayName() throws {
        let ara = try XCTUnwrap(OpenClamAvatarCatalog.avatar(id: "ara"))
        XCTAssertEqual(
            OpenClamAvatarSelection(ara),
            OpenClamAvatarSelection(id: "ara", displayName: "Ara")
        )
    }

    func testPackAverageMatchesTheTwoAuthorizedBundledAvatars() {
        XCTAssertGreaterThan(OpenClamAvatarCatalog.averageIncludedByteCount, 24_000_000)
        XCTAssertLessThan(OpenClamAvatarCatalog.averageIncludedByteCount, 32_000_000)
    }

    @MainActor
    func testAraOffersItsThreeValidatedFullExpressionClips() throws {
        let ara = try XCTUnwrap(OpenClamAvatarCatalog.avatar(id: "ara"))
        XCTAssertEqual(Set(ara.motions.keys), [.walk, .edgeIdle, .moves])
        XCTAssertTrue(ara.compatibility.supportsMacV22ExpressionParity)
        XCTAssertNotNil(ara.expressionGeometry)

        for kind in OpenClamAvatarMotionKind.allCases {
            let motion = try XCTUnwrap(ara.motion(kind))
            XCTAssertEqual(motion.pixelSize, OpenClamAvatarSize(width: 720, height: 1_088))
            XCTAssertGreaterThanOrEqual(motion.durationMilliseconds, 250)
            XCTAssertLessThanOrEqual(motion.durationMilliseconds, 12_000)
            let url = try XCTUnwrap(
                OpenClamAvatarAssetStore.shared.resourceURL(for: motion)
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testEveryAvatarHasTheCompleteLocalCoreRig() {
        let expectedRoles = Set(
            [
                OpenClamAvatarAssetRole.thumbnail,
                .body,
                .headMask,
                .eyeLeft,
                .eyeRight,
                .browLeft,
                .browRight,
                .gazeLeftAtlas,
                .gazeRightAtlas,
            ] + OpenClamAvatarViseme.allCases.map(OpenClamAvatarAssetRole.viseme)
        )

        for avatar in OpenClamAvatarCatalog.avatars {
            XCTAssertTrue(avatar.compatibility.supportsFullLocalStage, avatar.displayName)
            XCTAssertTrue(
                expectedRoles.isSubset(of: Set(avatar.assets.keys)),
                avatar.displayName
            )
            XCTAssertEqual(avatar.geometry.leftEye.storage, .verticalStrip)
            XCTAssertEqual(avatar.geometry.leftBrow.storage, .verticalStrip)
            XCTAssertEqual(avatar.geometry.leftGaze.storage, .gridAtlas)
            XCTAssertEqual(avatar.geometry.rightGaze.storage, .gridAtlas)
        }

        let ara = OpenClamAvatarCatalog.avatar(id: "ara")
        XCTAssertEqual(
            Set(ara?.assets.keys.map { $0 } ?? []),
            expectedRoles.union([
                .smileAtlas,
                .emotionMouthAtlas,
                .foreheadLeft,
                .foreheadRight,
                .cheekLeft,
                .cheekRight,
                .underEyeLeft,
                .underEyeRight,
            ])
        )
    }

    @MainActor
    func testBundledPackByteCountsAndSpriteGeometry() throws {
        let bundle = try XCTUnwrap(
            OpenClamAvatarAssetStore.findCatalogBundle(in: .main),
            "AvatarCatalogAssets.bundle must be copied into the app target"
        )

        for avatar in OpenClamAvatarCatalog.avatars where avatar.avatarID != .captainAyer {
            let directory = try bundledDirectory(for: avatar)
            let directoryURL = bundle.bundleURL.appendingPathComponent(
                directory,
                isDirectory: true
            )
            XCTAssertEqual(
                try byteCount(ofRegularFilesIn: directoryURL),
                avatar.includedByteCount,
                avatar.displayName
            )

            try assertPixelSize(
                role: .body,
                avatar: avatar,
                expected: avatar.geometry.bodySize.cgSize,
                bundle: bundle
            )
            try assertStrip(
                role: .eyeLeft,
                geometry: avatar.geometry.leftEye,
                avatar: avatar,
                bundle: bundle
            )
            try assertStrip(
                role: .eyeRight,
                geometry: avatar.geometry.rightEye,
                avatar: avatar,
                bundle: bundle
            )
            try assertStrip(
                role: .browLeft,
                geometry: avatar.geometry.leftBrow,
                avatar: avatar,
                bundle: bundle
            )
            try assertStrip(
                role: .browRight,
                geometry: avatar.geometry.rightBrow,
                avatar: avatar,
                bundle: bundle
            )
            try assertAtlas(
                role: .gazeLeftAtlas,
                geometry: avatar.geometry.leftGaze,
                avatar: avatar,
                bundle: bundle
            )
            try assertAtlas(
                role: .gazeRightAtlas,
                geometry: avatar.geometry.rightGaze,
                avatar: avatar,
                bundle: bundle
            )
            for viseme in OpenClamAvatarViseme.allCases {
                try assertPixelSize(
                    role: .viseme(viseme),
                    avatar: avatar,
                    expected: CGSize(width: 1_024, height: 1_024),
                    bundle: bundle
                )
            }
            if let expression = avatar.expressionGeometry {
                try assertAtlas(
                    role: .smileAtlas,
                    geometry: expression.smile,
                    avatar: avatar,
                    bundle: bundle
                )
                try assertAtlas(
                    role: .emotionMouthAtlas,
                    geometry: expression.emotionMouth,
                    avatar: avatar,
                    bundle: bundle
                )
                for (role, geometry) in [
                    (OpenClamAvatarAssetRole.foreheadLeft, expression.leftForehead),
                    (.foreheadRight, expression.rightForehead),
                    (.cheekLeft, expression.leftCheek),
                    (.cheekRight, expression.rightCheek),
                    (.underEyeLeft, expression.leftUnderEye),
                    (.underEyeRight, expression.rightUnderEye),
                ] {
                    try assertStrip(
                        role: role,
                        geometry: geometry,
                        avatar: avatar,
                        bundle: bundle
                    )
                }
            }
        }
    }

    @MainActor
    func testBundledAraIsTheHashPinnedFullExpressionPackagePayload() throws {
        let bundle = try XCTUnwrap(
            OpenClamAvatarAssetStore.findCatalogBundle(in: .main)
        )
        let directoryURL = bundle.bundleURL.appendingPathComponent(
            "ara",
            isDirectory: true
        )
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            OpenClamAvatarPackageManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertEqual(manifest.format, "openclam-avatar")
        XCTAssertEqual(manifest.version, 4)
        XCTAssertEqual(manifest.variant, "ios-light")
        XCTAssertEqual(manifest.id, "ara")
        XCTAssertEqual(manifest.displayName, "Ara")
        XCTAssertNotNil(manifest.expression)
        XCTAssertEqual(Set(manifest.motions?.keys.map { $0 } ?? []), [
            "walk", "edgeIdle", "moves",
        ])

        let declared = Array(manifest.assets.values) + Array(
            manifest.motions?.values.map {
                OpenClamAvatarPackageAsset(
                    path: $0.path,
                    sha256: $0.sha256,
                    byteCount: $0.byteCount,
                    mediaType: $0.mediaType,
                    width: $0.width,
                    height: $0.height
                )
            } ?? []
        )
        let expectedNames = Set(
            declared.map { URL(fileURLWithPath: $0.path).lastPathComponent }
                + ["manifest.json"]
        )
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)),
            expectedNames
        )
        for record in declared {
            let url = directoryURL.appendingPathComponent(
                URL(fileURLWithPath: record.path).lastPathComponent
            )
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            XCTAssertEqual(data.count, record.byteCount, record.path)
            XCTAssertEqual(
                SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined(),
                record.sha256,
                record.path
            )
        }
    }

    @MainActor
    func testShippingBundleContainsOnlyPublicRuntimeManifestAndNoSensitiveBuildMetadata() throws {
        let bundle = try XCTUnwrap(OpenClamAvatarAssetStore.findCatalogBundle(in: .main))
        let files = try FileManager.default.contentsOfDirectory(
            at: bundle.bundleURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(files.contains { $0.lastPathComponent.hasPrefix("source-") })

        let provenanceURL = try XCTUnwrap(
            bundle.url(forResource: "provenance", withExtension: "json")
        )
        let provenance = try String(contentsOf: provenanceURL, encoding: .utf8)
        for forbidden in [
            "/Users/", "OpenAI", "open_ai", "xAI", "provider", "prompt",
            "persona", "EnConvo", "relay",
        ] {
            XCTAssertFalse(provenance.localizedCaseInsensitiveContains(forbidden), forbidden)
        }

        for avatar in OpenClamAvatarCatalog.avatars where avatar.avatarID != .captainAyer {
            let directoryURL = bundle.bundleURL.appendingPathComponent(
                try bundledDirectory(for: avatar),
                isDirectory: true
            )
            let names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            XCTAssertEqual(
                names.filter { $0.localizedCaseInsensitiveContains("manifest") },
                ["manifest.json"]
            )
            let manifest = try String(
                contentsOf: directoryURL.appendingPathComponent("manifest.json"),
                encoding: .utf8
            )
            for forbidden in [
                "/Users/", "provider", "prompt", "persona", "credential", "token",
            ] {
                XCTAssertFalse(
                    manifest.localizedCaseInsensitiveContains(forbidden),
                    forbidden
                )
            }
        }
    }

    private func bundledDirectory(for avatar: OpenClamAvatarDescriptor) throws -> String {
        let reference = try XCTUnwrap(avatar.asset(.thumbnail))
        guard case let .catalogBundle(directory, _) = reference else {
            throw TestFailure("Expected bundled thumbnail for \(avatar.displayName)")
        }
        return directory
    }

    private func byteCount(ofRegularFilesIn directory: URL) throws -> Int {
        try FileManager.default
            .contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            )
            .reduce(0) { total, url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                return total + (values.isRegularFile == true ? values.fileSize ?? 0 : 0)
            }
    }

    private func assertStrip(
        role: OpenClamAvatarAssetRole,
        geometry: OpenClamAvatarSpriteGeometry,
        avatar: OpenClamAvatarDescriptor,
        bundle: Bundle,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(geometry.storage, .verticalStrip, file: file, line: line)
        try assertPixelSize(
            role: role,
            avatar: avatar,
            expected: CGSize(
                width: geometry.box.width,
                height: geometry.box.height * Double(geometry.frameCount)
            ),
            bundle: bundle,
            file: file,
            line: line
        )
    }

    private func assertAtlas(
        role: OpenClamAvatarAssetRole,
        geometry: OpenClamAvatarSpriteGeometry,
        avatar: OpenClamAvatarDescriptor,
        bundle: Bundle,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(geometry.storage, .gridAtlas, file: file, line: line)
        try assertPixelSize(
            role: role,
            avatar: avatar,
            expected: CGSize(
                width: geometry.box.width * Double(geometry.columns),
                height: geometry.box.height * Double(geometry.rows)
            ),
            bundle: bundle,
            file: file,
            line: line
        )
    }

    private func assertPixelSize(
        role: OpenClamAvatarAssetRole,
        avatar: OpenClamAvatarDescriptor,
        expected: CGSize,
        bundle: Bundle,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let reference = try XCTUnwrap(avatar.asset(role), file: file, line: line)
        guard case let .catalogBundle(directory, filename) = reference else {
            throw TestFailure("Expected bundled asset for \(avatar.displayName)")
        }
        let url = bundle.bundleURL
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(filename)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, Int(expected.width), file: file, line: line)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, Int(expected.height), file: file, line: line)
    }

    private struct TestFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
