import Foundation

enum OpenClamAvatarCatalog {
    static let defaultAvatarID = OpenClamAvatarID.captainAyer.rawValue

    static let avatars: [OpenClamAvatarDescriptor] = [
        captainAyer,
        ara,
    ]

    static var averageIncludedByteCount: Int {
        guard !avatars.isEmpty else { return 0 }
        return avatars.reduce(0) { $0 + $1.includedByteCount } / avatars.count
    }

    static func avatar(id: String) -> OpenClamAvatarDescriptor? {
        avatars.first { $0.id == id }
    }

    private static let standardCompatibility = OpenClamAvatarRigCompatibility(
        canonicalVisemeCount: 9,
        eyeStateCount: 8,
        browVerticalStateCount: 14,
        browSqueezeStateCount: 3,
        gazeHorizontalStateCount: 25,
        gazeVerticalStateCount: 11
    )

    private static let fullExpressionCompatibility = OpenClamAvatarRigCompatibility(
        canonicalVisemeCount: OpenClamAvatarViseme.allCases.count,
        eyeStateCount: 8,
        browVerticalStateCount: 14,
        browSqueezeStateCount: 3,
        gazeHorizontalStateCount: 25,
        gazeVerticalStateCount: 11
    )

    private static let captainAyer = OpenClamAvatarDescriptor(
        avatarID: .captainAyer,
        displayName: "Captain Ayer",
        sourceSlug: "sparrow-avatar",
        sourceRelativeRuntimePath: "avatars/sparrow-avatar/runtime",
        includedByteCount: 10_942_430,
        geometry: rig(
            body: size(941, 1_672),
            transform: transform(
                a: 0.2375028, b: -0.000602,
                c: 0.000602, d: 0.2375028,
                tx: 360.640128, ty: 29.3446383
            ),
            faceBounds: rect(426, 119, 114, 137),
            leftEye: rect(524, 470, 182, 104),
            rightEye: rect(320, 471, 176, 105),
            leftBrow: rect(530, 436, 213, 104),
            rightBrow: rect(281, 439, 214, 102),
            leftGaze: rect(557, 501, 115, 59),
            rightGaze: rect(353, 502, 115, 61)
        ),
        compatibility: standardCompatibility,
        assets: captainAyerAssets()
    )

    private static let ara = bundledPackageAvatar(
        directory: "ara",
        expectedID: .ara,
        expectedName: "Ara",
        sourceSlug: "cleo-full-expression-fresh-20260827"
    )

    /// The bundled Ara files are the byte-exact contents of the reviewed AVTR
    /// v4 Store package. Decode its small manifest instead of duplicating the
    /// calibrated face geometry in Swift, so the app fallback and Store update
    /// cannot silently drift apart when Ara is rebuilt.
    private static func bundledPackageAvatar(
        directory: String,
        expectedID: OpenClamAvatarID,
        expectedName: String,
        sourceSlug: String
    ) -> OpenClamAvatarDescriptor {
        let mainBundle = Bundle.main
        let bundleURL = mainBundle.url(
            forResource: "AvatarCatalogAssets",
            withExtension: "bundle"
        ) ?? mainBundle.resourceURL?.appendingPathComponent(
            "AvatarCatalogAssets.bundle",
            isDirectory: true
        )
        guard let bundleURL,
              let catalogBundle = Bundle(url: bundleURL) else {
            preconditionFailure("AvatarCatalogAssets.bundle is missing")
        }
        let manifestURL = catalogBundle.bundleURL
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(
                OpenClamAvatarPackageManifest.self,
                from: data
              ),
              manifest.format == OpenClamAvatarPackageContract.canonicalFormat,
              manifest.version == OpenClamAvatarPackageContract.expressionVersion,
              manifest.variant == OpenClamAvatarPackageContract.variant,
              manifest.id == expectedID.rawValue,
              manifest.displayName == expectedName,
              manifest.expression != nil else {
            preconditionFailure("Bundled \(expectedName) manifest is invalid")
        }

        var assets: [OpenClamAvatarAssetRole: OpenClamAvatarAssetReference] = [:]
        var includedByteCount = data.count
        for specification in OpenClamAvatarPackageContract.assetSpecifications(
            for: manifest.version
        ) {
            guard let asset = manifest.assets[specification.key],
                  asset.path.hasPrefix("assets/"),
                  URL(fileURLWithPath: asset.path).deletingLastPathComponent()
                    .lastPathComponent == "assets" else {
                preconditionFailure(
                    "Bundled \(expectedName) asset ledger is invalid"
                )
            }
            assets[specification.role] = bundled(
                directory,
                URL(fileURLWithPath: asset.path).lastPathComponent
            )
            let sum = includedByteCount.addingReportingOverflow(asset.byteCount)
            guard !sum.overflow else {
                preconditionFailure("Bundled \(expectedName) is too large")
            }
            includedByteCount = sum.partialValue
        }

        var motions: [OpenClamAvatarMotionKind: OpenClamAvatarMotionAsset] = [:]
        for specification in OpenClamAvatarPackageContract.motionSpecifications {
            guard let motion = manifest.motions?[specification.kind.rawValue] else {
                continue
            }
            motions[specification.kind] = OpenClamAvatarMotionAsset(
                reference: .catalogBundle(
                    directory: directory,
                    filename: URL(fileURLWithPath: motion.path).lastPathComponent
                ),
                pixelSize: size(Double(motion.width), Double(motion.height)),
                durationMilliseconds: motion.durationMilliseconds
            )
            let sum = includedByteCount.addingReportingOverflow(motion.byteCount)
            guard !sum.overflow else {
                preconditionFailure("Bundled \(expectedName) is too large")
            }
            includedByteCount = sum.partialValue
        }

        return OpenClamAvatarDescriptor(
            avatarID: expectedID,
            displayName: expectedName,
            sourceSlug: sourceSlug,
            sourceRelativeRuntimePath: "bundled/\(directory)",
            includedByteCount: includedByteCount,
            geometry: manifest.rig,
            expressionGeometry: manifest.expression,
            compatibility: fullExpressionCompatibility,
            assets: assets,
            motions: motions
        )
    }

    private static func size(_ width: Double, _ height: Double) -> OpenClamAvatarSize {
        OpenClamAvatarSize(width: width, height: height)
    }

    private static func rect(
        _ x: Double,
        _ y: Double,
        _ width: Double,
        _ height: Double
    ) -> OpenClamAvatarRect {
        OpenClamAvatarRect(x: x, y: y, width: width, height: height)
    }

    private static func transform(
        a: Double,
        b: Double,
        c: Double,
        d: Double,
        tx: Double,
        ty: Double
    ) -> OpenClamAvatarFaceTransform {
        OpenClamAvatarFaceTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    private static func rig(
        body: OpenClamAvatarSize,
        transform: OpenClamAvatarFaceTransform,
        faceBounds: OpenClamAvatarRect,
        leftEye: OpenClamAvatarRect,
        rightEye: OpenClamAvatarRect,
        leftBrow: OpenClamAvatarRect,
        rightBrow: OpenClamAvatarRect,
        leftGaze: OpenClamAvatarRect,
        rightGaze: OpenClamAvatarRect
    ) -> OpenClamAvatarRigGeometry {
        OpenClamAvatarRigGeometry(
            bodySize: body,
            faceTransform: transform,
            faceBoundsInBody: faceBounds,
            leftEye: OpenClamAvatarSpriteGeometry(
                box: leftEye, columns: 1, rows: 8, storage: .verticalStrip
            ),
            rightEye: OpenClamAvatarSpriteGeometry(
                box: rightEye, columns: 1, rows: 8, storage: .verticalStrip
            ),
            leftBrow: OpenClamAvatarSpriteGeometry(
                box: leftBrow, columns: 14, rows: 3, storage: .verticalStrip
            ),
            rightBrow: OpenClamAvatarSpriteGeometry(
                box: rightBrow, columns: 14, rows: 3, storage: .verticalStrip
            ),
            leftGaze: OpenClamAvatarSpriteGeometry(
                box: leftGaze, columns: 25, rows: 11, storage: .gridAtlas
            ),
            rightGaze: OpenClamAvatarSpriteGeometry(
                box: rightGaze, columns: 25, rows: 11, storage: .gridAtlas
            )
        )
    }

    private static func captainAyerAssets() -> [
        OpenClamAvatarAssetRole: OpenClamAvatarAssetReference
    ] {
        var result: [OpenClamAvatarAssetRole: OpenClamAvatarAssetReference] = [
            .thumbnail: .assetCatalog(name: "CaptainAyerKeyframe"),
            .body: .assetCatalog(name: "CaptainAyerBody"),
            .headMask: .assetCatalog(name: "CaptainAyerHeadMask"),
            .eyeLeft: .assetCatalog(name: "CaptainAyerEyeLeft"),
            .eyeRight: .assetCatalog(name: "CaptainAyerEyeRight"),
            .browLeft: .assetCatalog(name: "CaptainAyerBrowLeft"),
            .browRight: .assetCatalog(name: "CaptainAyerBrowRight"),
            .gazeLeftAtlas: .assetCatalog(name: "CaptainAyerGazeLeftAtlas"),
            .gazeRightAtlas: .assetCatalog(name: "CaptainAyerGazeRightAtlas"),
        ]
        let names: [OpenClamAvatarViseme: String] = [
            .silence: "CaptainAyerVisemeSil",
            .bilabial: "CaptainAyerVisemeFF",
            .labiodental: "CaptainAyerVisemeFF",
            .dental: "CaptainAyerVisemeTH",
            .alveolar: "CaptainAyerVisemeNN",
            .velar: "CaptainAyerVisemeNN",
            .postalveolar: "CaptainAyerVisemeIH",
            .sibilant: "CaptainAyerVisemeIH",
            .nasal: "CaptainAyerVisemeNN",
            .rhotic: "CaptainAyerVisemeRR",
            .open: "CaptainAyerVisemeAA",
            .wide: "CaptainAyerVisemeE",
            .nearClose: "CaptainAyerVisemeIH",
            .openRounded: "CaptainAyerVisemeOU",
            .rounded: "CaptainAyerVisemeOU",
        ]
        for (viseme, name) in names {
            result[.viseme(viseme)] = .assetCatalog(name: name)
        }
        return result
    }

    private static func bundledAssets(directory: String) -> [
        OpenClamAvatarAssetRole: OpenClamAvatarAssetReference
    ] {
        var result: [OpenClamAvatarAssetRole: OpenClamAvatarAssetReference] = [
            .thumbnail: bundled(directory, "thumbnail.jpg"),
            .body: bundled(directory, "body.png"),
            .headMask: bundled(directory, "head-mask.png"),
            .eyeLeft: bundled(directory, "eye-left.png"),
            .eyeRight: bundled(directory, "eye-right.png"),
            .browLeft: bundled(directory, "brow-left.png"),
            .browRight: bundled(directory, "brow-right.png"),
            .gazeLeftAtlas: bundled(directory, "gaze-left-atlas.png"),
            .gazeRightAtlas: bundled(directory, "gaze-right-atlas.png"),
        ]
        let filenames: [OpenClamAvatarViseme: String] = [
            .silence: "viseme-sil.jpg",
            .bilabial: "viseme-FF.jpg",
            .labiodental: "viseme-FF.jpg",
            .dental: "viseme-TH.jpg",
            .alveolar: "viseme-nn.jpg",
            .velar: "viseme-nn.jpg",
            .postalveolar: "viseme-ih.jpg",
            .sibilant: "viseme-ih.jpg",
            .nasal: "viseme-nn.jpg",
            .rhotic: "viseme-RR.jpg",
            .open: "viseme-aa.jpg",
            .wide: "viseme-E.jpg",
            .nearClose: "viseme-ih.jpg",
            .openRounded: "viseme-ou.jpg",
            .rounded: "viseme-ou.jpg",
        ]
        for (viseme, filename) in filenames {
            result[.viseme(viseme)] = bundled(
                directory,
                filename
            )
        }
        return result
    }

    private static func bundled(
        _ directory: String,
        _ filename: String
    ) -> OpenClamAvatarAssetReference {
        .catalogBundle(directory: directory, filename: filename)
    }
}
