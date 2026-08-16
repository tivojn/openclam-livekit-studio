import CoreGraphics
import Foundation

/// A validated, stable avatar identifier. Bundled avatars expose named constants,
/// while imported avatars use the same value type without being limited to a
/// compile-time enum.
struct OpenClamAvatarID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    static let captainAyer = Self(unchecked: "captain-ayer")
    static let vivieen = Self(unchecked: "vivieen")

    static let bundled: [Self] = [
        .captainAyer,
    ]

    let rawValue: String

    init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let validated = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid OpenClam avatar identifier"
                )
            )
        }
        self = validated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }

    static func isValid(_ value: String) -> Bool {
        value.range(
            of: #"^[a-z0-9][a-z0-9-]{0,63}$"#,
            options: .regularExpression
        ) != nil
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }
}

enum OpenClamAvatarViseme: String, CaseIterable, Codable, Hashable, Sendable {
    case silence = "sil"
    case labiodental = "FF"
    case dental = "TH"
    case nasal = "nn"
    case rhotic = "RR"
    case open = "aa"
    case wide = "E"
    case nearClose = "ih"
    case rounded = "ou"
}

enum OpenClamAvatarAssetRole: Hashable, Sendable {
    case thumbnail
    case body
    case headMask
    case eyeLeft
    case eyeRight
    case browLeft
    case browRight
    case gazeLeftAtlas
    case gazeRightAtlas
    case viseme(OpenClamAvatarViseme)
}

enum OpenClamAvatarAssetReference: Hashable, Sendable {
    /// An image already compiled into OpenClam's main asset catalog.
    case assetCatalog(name: String)
    /// A file inside AvatarCatalogAssets.bundle.
    case catalogBundle(directory: String, filename: String)
    /// A validated file installed in this app's Application Support directory.
    case installedFile(URL)
}

struct OpenClamAvatarPoint: Codable, Equatable, Hashable, Sendable {
    let x: Double
    let y: Double

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct OpenClamAvatarSize: Codable, Equatable, Hashable, Sendable {
    let width: Double
    let height: Double

    var cgSize: CGSize { CGSize(width: width, height: height) }
}

struct OpenClamAvatarRect: Codable, Equatable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// The source rig stores a 2×3 affine matrix in face-source to body coordinates.
struct OpenClamAvatarFaceTransform: Codable, Equatable, Hashable, Sendable {
    let a: Double
    let b: Double
    let c: Double
    let d: Double
    let tx: Double
    let ty: Double

    var cgAffineTransform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    var uniformScale: Double { hypot(a, b) }
    var rotationDegrees: Double { atan2(b, a) * 180 / .pi }

    func applying(to point: OpenClamAvatarPoint) -> OpenClamAvatarPoint {
        OpenClamAvatarPoint(
            x: a * point.x + c * point.y + tx,
            y: b * point.x + d * point.y + ty
        )
    }
}

enum OpenClamAvatarSpriteStorage: String, Codable, Equatable, Hashable, Sendable {
    /// Frames are stacked from top to bottom. Logical row-major state is still
    /// `row * columns + column`.
    case verticalStrip
    /// Frames are laid out as the declared columns and rows in a 2D texture.
    case gridAtlas
}

struct OpenClamAvatarSpriteGeometry: Codable, Equatable, Hashable, Sendable {
    let box: OpenClamAvatarRect
    let columns: Int
    let rows: Int
    let storage: OpenClamAvatarSpriteStorage

    var frameCount: Int { columns * rows }
}

struct OpenClamAvatarRigGeometry: Codable, Equatable, Hashable, Sendable {
    static let faceSourceSize = OpenClamAvatarSize(width: 1_024, height: 1_024)

    let bodySize: OpenClamAvatarSize
    let faceTransform: OpenClamAvatarFaceTransform
    let faceBoundsInBody: OpenClamAvatarRect
    let leftEye: OpenClamAvatarSpriteGeometry
    let rightEye: OpenClamAvatarSpriteGeometry
    let leftBrow: OpenClamAvatarSpriteGeometry
    let rightBrow: OpenClamAvatarSpriteGeometry
    let leftGaze: OpenClamAvatarSpriteGeometry
    let rightGaze: OpenClamAvatarSpriteGeometry

    var eyeAnchorInFaceSource: OpenClamAvatarPoint {
        let left = leftGaze.box
        let right = rightGaze.box
        return OpenClamAvatarPoint(
            x: ((left.x + left.width / 2) + (right.x + right.width / 2)) / 2,
            y: ((left.y + left.height / 2) + (right.y + right.height / 2)) / 2
        )
    }

    var faceCenterInBody: OpenClamAvatarPoint {
        faceTransform.applying(to: OpenClamAvatarPoint(x: 512, y: 512))
    }

    var eyeAnchorInBody: OpenClamAvatarPoint {
        faceTransform.applying(to: eyeAnchorInFaceSource)
    }
}

struct OpenClamAvatarRigCompatibility: Codable, Equatable, Hashable, Sendable {
    let canonicalVisemeCount: Int
    let eyeStateCount: Int
    let browVerticalStateCount: Int
    let browSqueezeStateCount: Int
    let gazeHorizontalStateCount: Int
    let gazeVerticalStateCount: Int

    var supportsFullLocalStage: Bool {
        canonicalVisemeCount == OpenClamAvatarViseme.allCases.count
            && eyeStateCount == 8
            && browVerticalStateCount == 14
            && browSqueezeStateCount == 3
            && gazeHorizontalStateCount == 25
            && gazeVerticalStateCount == 11
    }
}

struct OpenClamAvatarDescriptor: Identifiable, Equatable, Sendable {
    let avatarID: OpenClamAvatarID
    let displayName: String
    let sourceSlug: String
    let sourceRelativeRuntimePath: String
    let includedByteCount: Int
    let geometry: OpenClamAvatarRigGeometry
    let compatibility: OpenClamAvatarRigCompatibility
    let assets: [OpenClamAvatarAssetRole: OpenClamAvatarAssetReference]

    var id: String { avatarID.rawValue }
    var includedMegabytes: Double { Double(includedByteCount) / 1_000_000 }

    func asset(_ role: OpenClamAvatarAssetRole) -> OpenClamAvatarAssetReference? {
        assets[role]
    }
}

struct OpenClamAvatarSelection: Codable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    init(_ avatar: OpenClamAvatarDescriptor) {
        id = avatar.id
        displayName = avatar.displayName
    }
}
