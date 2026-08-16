import Foundation

enum OpenClamAvatarCatalog {
    static let defaultAvatarID = OpenClamAvatarID.captainAyer.rawValue

    static let avatars: [OpenClamAvatarDescriptor] = [
        captainAyer,
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
        displayName: "OpenClam Guide",
        sourceSlug: "synthetic-public-guide",
        sourceRelativeRuntimePath: "shared/avatar-package-v2/fixtures/ios-light-golden.avtr",
        includedByteCount: 58_246,
        geometry: rig(
            body: size(128, 192),
            transform: transform(
                a: 0.1, b: 0,
                c: 0, d: 0.1,
                tx: 12, ty: 4
            ),
            faceBounds: rect(35, 28, 58, 70),
            leftEye: rect(560, 480, 4, 4),
            rightEye: rect(456, 480, 4, 4),
            leftBrow: rect(560, 450, 4, 3),
            rightBrow: rect(456, 450, 4, 3),
            leftGaze: rect(560, 490, 4, 4),
            rightGaze: rect(458, 490, 4, 4)
        ),
        compatibility: standardCompatibility,
        assets: publicGuideAssets()
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

    private static func publicGuideAssets() -> [
        OpenClamAvatarAssetRole: OpenClamAvatarAssetReference
    ] {
        var result: [OpenClamAvatarAssetRole: OpenClamAvatarAssetReference] = [
            .thumbnail: bundled("public-guide", "thumbnail.png"),
            .body: bundled("public-guide", "body.png"),
            .headMask: bundled("public-guide", "head-mask.png"),
            .eyeLeft: bundled("public-guide", "eye-left.png"),
            .eyeRight: bundled("public-guide", "eye-right.png"),
            .browLeft: bundled("public-guide", "brow-left.png"),
            .browRight: bundled("public-guide", "brow-right.png"),
            .gazeLeftAtlas: bundled("public-guide", "gaze-left-atlas.png"),
            .gazeRightAtlas: bundled("public-guide", "gaze-right-atlas.png"),
        ]
        for viseme in OpenClamAvatarViseme.allCases {
            result[.viseme(viseme)] = bundled(
                "public-guide",
                "viseme-\(viseme.rawValue).png"
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
