import CoreGraphics
import Foundation

/// A validated, stable avatar identifier. Bundled avatars expose named constants,
/// while imported avatars use the same value type without being limited to a
/// compile-time enum.
struct OpenClamAvatarID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    static let captainAyer = Self(unchecked: "captain-ayer")
    static let ara = Self(unchecked: "ara")

    static let bundled: [Self] = [
        .captainAyer, .ara,
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
    case bilabial = "PP"
    case labiodental = "FF"
    case dental = "TH"
    case alveolar = "DD"
    case velar = "kk"
    case postalveolar = "CH"
    case sibilant = "SS"
    case nasal = "nn"
    case rhotic = "RR"
    case open = "aa"
    case wide = "E"
    case nearClose = "ih"
    case openRounded = "oh"
    case rounded = "ou"

    static let legacyCases: [Self] = [
        .silence, .labiodental, .dental, .nasal, .rhotic,
        .open, .wide, .nearClose, .rounded,
    ]

    var legacyFallback: Self {
        switch self {
        case .bilabial: .labiodental
        case .alveolar, .velar: .nasal
        case .postalveolar, .sibilant: .nearClose
        case .openRounded: .rounded
        default: self
        }
    }
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
    case smileAtlas
    case emotionMouthAtlas
    case foreheadLeft
    case foreheadRight
    case cheekLeft
    case cheekRight
    case underEyeLeft
    case underEyeRight
}

enum OpenClamAvatarAssetReference: Hashable, Sendable {
    /// An image already compiled into OpenClam's main asset catalog.
    case assetCatalog(name: String)
    /// A file inside AvatarCatalogAssets.bundle.
    case catalogBundle(directory: String, filename: String)
    /// A validated file installed in this app's Application Support directory.
    case installedFile(URL)
}

/// Optional transparent motion clips carried by an ios-light v3 package.
/// Playback behavior is deliberately part of the role rather than package
/// metadata so an imported archive cannot request arbitrary runtime behavior.
enum OpenClamAvatarMotionKind: String, CaseIterable, Codable, Hashable, Sendable {
    case walk
    case edgeIdle
    case moves

    var loops: Bool {
        switch self {
        case .walk, .edgeIdle:
            true
        case .moves:
            false
        }
    }
}

enum OpenClamAvatarMotionReference: Equatable, Hashable, Sendable {
    case catalogBundle(directory: String, filename: String)
    case installedFile(URL)
}

struct OpenClamAvatarMotionAsset: Equatable, Hashable, Sendable {
    let reference: OpenClamAvatarMotionReference
    let pixelSize: OpenClamAvatarSize
    let durationMilliseconds: Int
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

/// Geometry and calibrated state values for a full macOS-v22 face bank.
/// It is optional on v2/v3 descriptors, keeping every existing downloaded
/// avatar readable, and mandatory for the v4 ios-light package.
struct OpenClamAvatarExpressionGeometry: Codable, Equatable, Hashable, Sendable {
    static let canonicalBrowOffsets = [
        -5.0, -3.5, -2.0, -1.0, 0.0, 0.75, 1.5,
        2.5, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0,
    ]
    static let canonicalBrowSqueezeOffsets = [-3.0, 0.0, 4.0]
    static let canonicalSmileStrengths = [0.0, 0.18, 0.34, 0.68, 1.0]
    static let canonicalEmotionMouthStrengths = [0.0, 0.34, 0.68, 1.0]
    static let canonicalCheekOffsets = [0.0, 0.8, 1.6, 2.45, 3.3]
    static let canonicalUnderEyeOffsets = [0.0, 0.5, 1.0, 1.6, 2.3]

    let smile: OpenClamAvatarSpriteGeometry
    let emotionMouth: OpenClamAvatarSpriteGeometry
    let leftForehead: OpenClamAvatarSpriteGeometry
    let rightForehead: OpenClamAvatarSpriteGeometry
    let leftCheek: OpenClamAvatarSpriteGeometry
    let rightCheek: OpenClamAvatarSpriteGeometry
    let leftUnderEye: OpenClamAvatarSpriteGeometry
    let rightUnderEye: OpenClamAvatarSpriteGeometry
    let browOffsets: [Double]
    let browSqueezeOffsets: [Double]
    let smileStrengths: [Double]
    let smileVisemes: [OpenClamAvatarViseme]
    let emotionMouthStrengths: [Double]
    let emotionMouthEmotions: [String]
    let emotionMouthVisemes: [OpenClamAvatarViseme]
    let cheekOffsets: [Double]
    let underEyeOffsets: [Double]
    let browGain: Double
    let foreheadGain: Double
    let underEyeGain: Double
}

struct OpenClamAvatarRigCompatibility: Codable, Equatable, Hashable, Sendable {
    let canonicalVisemeCount: Int
    let eyeStateCount: Int
    let browVerticalStateCount: Int
    let browSqueezeStateCount: Int
    let gazeHorizontalStateCount: Int
    let gazeVerticalStateCount: Int

    var supportsFullLocalStage: Bool {
        [OpenClamAvatarViseme.legacyCases.count, OpenClamAvatarViseme.allCases.count]
            .contains(canonicalVisemeCount)
            && eyeStateCount == 8
            && browVerticalStateCount == 14
            && browSqueezeStateCount == 3
            && gazeHorizontalStateCount == 25
            && gazeVerticalStateCount == 11
    }


    var supportsMacV22ExpressionParity: Bool {
        canonicalVisemeCount == OpenClamAvatarViseme.allCases.count
            && supportsFullLocalStage
    }
}

struct OpenClamAvatarDescriptor: Identifiable, Equatable, Sendable {
    let avatarID: OpenClamAvatarID
    let displayName: String
    let sourceSlug: String
    let sourceRelativeRuntimePath: String
    let includedByteCount: Int
    let geometry: OpenClamAvatarRigGeometry
    let expressionGeometry: OpenClamAvatarExpressionGeometry?
    let compatibility: OpenClamAvatarRigCompatibility
    let assets: [OpenClamAvatarAssetRole: OpenClamAvatarAssetReference]
    let motions: [OpenClamAvatarMotionKind: OpenClamAvatarMotionAsset]

    init(
        avatarID: OpenClamAvatarID,
        displayName: String,
        sourceSlug: String,
        sourceRelativeRuntimePath: String,
        includedByteCount: Int,
        geometry: OpenClamAvatarRigGeometry,
        expressionGeometry: OpenClamAvatarExpressionGeometry? = nil,
        compatibility: OpenClamAvatarRigCompatibility,
        assets: [OpenClamAvatarAssetRole: OpenClamAvatarAssetReference],
        motions: [OpenClamAvatarMotionKind: OpenClamAvatarMotionAsset] = [:]
    ) {
        self.avatarID = avatarID
        self.displayName = displayName
        self.sourceSlug = sourceSlug
        self.sourceRelativeRuntimePath = sourceRelativeRuntimePath
        self.includedByteCount = includedByteCount
        self.geometry = geometry
        self.expressionGeometry = expressionGeometry
        self.compatibility = compatibility
        self.assets = assets
        self.motions = motions
    }

    var id: String { avatarID.rawValue }
    var includedMegabytes: Double { Double(includedByteCount) / 1_000_000 }

    func asset(_ role: OpenClamAvatarAssetRole) -> OpenClamAvatarAssetReference? {
        if let exact = assets[role] { return exact }
        guard expressionGeometry == nil,
              case let .viseme(viseme) = role else { return nil }
        return assets[.viseme(viseme.legacyFallback)]
    }

    func motion(_ kind: OpenClamAvatarMotionKind) -> OpenClamAvatarMotionAsset? {
        motions[kind]
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
