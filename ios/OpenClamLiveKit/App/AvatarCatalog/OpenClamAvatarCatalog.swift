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

    private static let ara = OpenClamAvatarDescriptor(
        avatarID: .ara,
        displayName: "Ara",
        sourceSlug: "ara",
        sourceRelativeRuntimePath: "bundled/ara",
        includedByteCount: 13_856_550,
        geometry: rig(
            body: size(864, 1_152),
            transform: transform(
                a: 0.2020784, b: 0.0069517,
                c: -0.0069517, d: 0.2020784,
                tx: 330.7539131, ty: -4.8994852
            ),
            faceBounds: rect(385, 66, 97, 125),
            leftEye: rect(551, 481, 171, 101),
            rightEye: rect(331, 471, 174, 104),
            leftBrow: rect(555, 425, 200, 112),
            rightBrow: rect(290, 410, 230, 122),
            leftGaze: rect(580, 512, 108, 56),
            rightGaze: rect(364, 502, 114, 57)
        ),
        compatibility: standardCompatibility,
        assets: bundledAssets(directory: "ara"),
        motions: [
            .edgeIdle: OpenClamAvatarMotionAsset(
                reference: .catalogBundle(
                    directory: "ara",
                    filename: "motion-edge-idle.mov"
                ),
                pixelSize: size(720, 1_088),
                durationMilliseconds: 6_083
            ),
            .moves: OpenClamAvatarMotionAsset(
                reference: .catalogBundle(
                    directory: "ara",
                    filename: "motion-moves.mov"
                ),
                pixelSize: size(720, 1_088),
                durationMilliseconds: 6_083
            ),
        ]
    )

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
            .labiodental: "CaptainAyerVisemeFF",
            .dental: "CaptainAyerVisemeTH",
            .nasal: "CaptainAyerVisemeNN",
            .rhotic: "CaptainAyerVisemeRR",
            .open: "CaptainAyerVisemeAA",
            .wide: "CaptainAyerVisemeE",
            .nearClose: "CaptainAyerVisemeIH",
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
        for viseme in OpenClamAvatarViseme.allCases {
            result[.viseme(viseme)] = bundled(
                directory,
                "viseme-\(viseme.rawValue).jpg"
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
