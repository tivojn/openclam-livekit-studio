import CoreGraphics
import Foundation

/// Camera angles shared by gesture previews and the SceneKit renderer.
struct OpenClam3DOrbit: Equatable, Sendable {
    var yaw: Double = 0
    var pitch: Double = 0

    var sanitized: Self {
        let y = yaw.isFinite ? yaw : 0
        let p = pitch.isFinite ? pitch : 0
        return Self(yaw: atan2(sin(y), cos(y)), pitch: min(.pi * 0.44, max(-.pi * 0.44, p)))
    }

    func dragging(_ translation: CGSize) -> Self {
        Self(yaw: yaw - Double(translation.width) * 0.009,
             pitch: pitch + Double(translation.height) * 0.007).sanitized
    }
}

/// Invert the overlay placement into a camera crop, so zoom renders the
/// visible pixels at screen resolution instead of enlarging a cached layer.
enum OpenClam3DViewportPolicy {
    static func crop(logicalCrop: CGRect, stageFrame: CGRect, canvas: CGRect,
                     transform: OpenClamAvatarStandbyTransform) -> CGRect {
        let fit = min(stageFrame.width / max(1, logicalCrop.width),
                      stageFrame.height / max(1, logicalCrop.height))
        let width = stageFrame.width / max(0.0001, fit)
        let height = stageFrame.height / max(0.0001, fit)
        let base = CGRect(x: logicalCrop.midX - width / 2, y: logicalCrop.midY - height / 2,
                          width: width, height: height)
        let scale = max(0.0001, stageFrame.width / max(1, base.width) * transform.scale)
        let origin = CGPoint(
            x: stageFrame.midX - stageFrame.width * transform.scale / 2
                + transform.normalizedOffset.x * canvas.width,
            y: stageFrame.minY + transform.normalizedOffset.y * canvas.height)
        return CGRect(x: base.minX + (canvas.minX - origin.x) / scale,
                      y: base.minY + (canvas.minY - origin.y) / scale,
                      width: canvas.width / scale, height: canvas.height / scale)
    }
}

/// Pure, renderer-independent pieces of the 3D avatar path: the glTF binary
/// reader used for import validation, the viseme and expression channel
/// tables shared with the Mac renderer (`web/avatar3d.js`), and the pose
/// solver that turns the app's existing lip-sync, reaction and face-mirror
/// state into morph-target weights.
enum OpenClam3DModelError: LocalizedError, Equatable {
    case notGLB
    case unsupportedContainerVersion(UInt32)
    case missingJSONChunk
    case invalidJSON
    case unsupportedAssetVersion
    case externalResources
    case unsupportedExtension(String)
    case nothingToAnimate

    var errorDescription: String? {
        switch self {
        case .notGLB:
            "The model is not a binary glTF (.glb) file."
        case let .unsupportedContainerVersion(version):
            "glTF container version \(version) is not supported."
        case .missingJSONChunk, .invalidJSON:
            "The model file is damaged."
        case .unsupportedAssetVersion:
            "Only glTF 2.0 models are supported."
        case .externalResources:
            "The model references external files; export a single .glb."
        case let .unsupportedExtension(name):
            "The model needs \(name), which OpenClam cannot decode on iPhone."
        case .nothingToAnimate:
            "The model has no facial shape keys or skeleton."
        }
    }
}

struct OpenClam3DGLBSummary: Equatable, Sendable {
    /// Morph target names per mesh name, in target order.
    let targetNames: [String: [String]]
    let joints: [String]
    let imageCount: Int
    let extensionsRequired: [String]
    /// glTF `alphaMode` per material name (OPAQUE, MASK or BLEND).
    let materialAlphaModes: [String: String]

    init(
        targetNames: [String: [String]],
        joints: [String],
        imageCount: Int,
        extensionsRequired: [String],
        materialAlphaModes: [String: String] = [:]
    ) {
        self.targetNames = targetNames
        self.joints = joints
        self.imageCount = imageCount
        self.extensionsRequired = extensionsRequired
        self.materialAlphaModes = materialAlphaModes
    }

    var allTargetNames: Set<String> {
        Set(targetNames.values.flatMap { $0 })
    }
}

enum OpenClam3DGLBReader {
    static let magic: UInt32 = 0x4654_6C67           // "glTF"
    static let jsonChunk: UInt32 = 0x4E4F_534A       // "JSON"
    static let unsupportedExtensions: Set<String> = [
        "KHR_draco_mesh_compression",
        "EXT_meshopt_compression",
        "KHR_texture_basisu",
    ]

    static func summary(of data: Data) throws -> OpenClam3DGLBSummary {
        guard data.count >= 20 else { throw OpenClam3DModelError.notGLB }
        let header = data.withUnsafeBytes { raw -> (UInt32, UInt32, UInt32, UInt32, UInt32) in
            (
                raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian,
                raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian,
                raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian,
                raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian,
                raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self).littleEndian
            )
        }
        guard header.0 == magic else { throw OpenClam3DModelError.notGLB }
        guard header.1 == 2 else {
            throw OpenClam3DModelError.unsupportedContainerVersion(header.1)
        }
        guard header.4 == jsonChunk else { throw OpenClam3DModelError.missingJSONChunk }
        let jsonLength = Int(header.3)
        guard jsonLength > 0, 20 + jsonLength <= data.count else {
            throw OpenClam3DModelError.missingJSONChunk
        }
        let document: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(
                with: data.subdata(in: 20 ..< 20 + jsonLength)
            ) as? [String: Any] else {
                throw OpenClam3DModelError.invalidJSON
            }
            document = object
        } catch {
            throw OpenClam3DModelError.invalidJSON
        }
        let asset = document["asset"] as? [String: Any] ?? [:]
        guard String(describing: asset["version"] ?? "").hasPrefix("2") else {
            throw OpenClam3DModelError.unsupportedAssetVersion
        }
        let required = (document["extensionsRequired"] as? [String]) ?? []
        if let blocked = required.first(where: unsupportedExtensions.contains) {
            throw OpenClam3DModelError.unsupportedExtension(blocked)
        }
        for buffer in (document["buffers"] as? [[String: Any]]) ?? [] {
            if let uri = buffer["uri"] as? String, !uri.hasPrefix("data:") {
                throw OpenClam3DModelError.externalResources
            }
        }
        let images = (document["images"] as? [[String: Any]]) ?? []
        for image in images {
            if let uri = image["uri"] as? String, !uri.hasPrefix("data:") {
                throw OpenClam3DModelError.externalResources
            }
        }
        var targetNames: [String: [String]] = [:]
        for (index, mesh) in ((document["meshes"] as? [[String: Any]]) ?? []).enumerated() {
            let primitives = (mesh["primitives"] as? [[String: Any]]) ?? []
            let hasTargets = primitives.contains { ($0["targets"] as? [Any])?.isEmpty == false }
            guard hasTargets else { continue }
            let name = (mesh["name"] as? String) ?? "mesh\(index)"
            if let names = (mesh["extras"] as? [String: Any])?["targetNames"] as? [String] {
                targetNames[name] = names
            } else if let names = primitives.lazy.compactMap({
                ($0["extras"] as? [String: Any])?["targetNames"] as? [String]
            }).first {
                targetNames[name] = names
            }
        }
        let nodes = (document["nodes"] as? [[String: Any]]) ?? []
        var joints: [String] = []
        for skin in (document["skins"] as? [[String: Any]]) ?? [] {
            for case let index as Int in (skin["joints"] as? [Any]) ?? [] where nodes.indices.contains(index) {
                joints.append((nodes[index]["name"] as? String) ?? "joint\(index)")
            }
        }
        var alphaModes: [String: String] = [:]
        for (index, material) in ((document["materials"] as? [[String: Any]]) ?? []).enumerated() {
            let name = (material["name"] as? String) ?? "material\(index)"
            alphaModes[name] = (material["alphaMode"] as? String)?.uppercased() ?? "OPAQUE"
        }
        return OpenClam3DGLBSummary(
            targetNames: targetNames,
            joints: joints,
            imageCount: images.count,
            extensionsRequired: required,
            materialAlphaModes: alphaModes
        )
    }
}

// MARK: - Channel tables

/// Names are compared lower-cased. Keep in sync with `web/avatar3d.js`.
enum OpenClam3DChannels {
    static let visemeAliases: [OpenClamAvatarViseme: [String]] = [
        .silence: ["vrc.v_sil", "v_sil", "viseme_sil", "sil"],
        .bilabial: ["vrc.v_pp", "v_pp", "viseme_pp", "pp"],
        .labiodental: ["vrc.v_ff", "v_ff", "viseme_ff", "ff"],
        .dental: ["vrc.v_th", "v_th", "viseme_th", "th"],
        .alveolar: ["vrc.v_dd", "v_dd", "viseme_dd", "dd"],
        .velar: ["vrc.v_kk", "v_kk", "viseme_kk", "kk"],
        .postalveolar: ["vrc.v_ch", "v_ch", "viseme_ch", "ch"],
        .sibilant: ["vrc.v_ss", "v_ss", "viseme_ss", "ss"],
        .nasal: ["vrc.v_nn", "v_nn", "viseme_nn", "nn"],
        .rhotic: ["vrc.v_rr", "v_rr", "viseme_rr", "rr"],
        .open: ["vrc.v_aa", "v_aa", "viseme_aa", "aa", "a", "fcl_mth_a"],
        .wide: ["vrc.v_ee", "vrc.v_e", "v_ee", "v_e", "viseme_e", "viseme_ee", "ee", "e", "fcl_mth_e"],
        .nearClose: ["vrc.v_ih", "v_ih", "viseme_ih", "viseme_i", "ih", "i", "fcl_mth_i"],
        .openRounded: ["vrc.v_oh", "v_oh", "viseme_oh", "viseme_o", "oh", "o", "fcl_mth_o"],
        .rounded: ["vrc.v_ou", "v_ou", "viseme_ou", "viseme_u", "ou", "u", "fcl_mth_u"],
    ]

    /// ARKit approximations used when a viseme has no dedicated target.
    static let visemeRecipes: [OpenClamAvatarViseme: [String: Double]] = [
        .silence: [:],
        .bilabial: ["mouthClose": 0.55, "mouthPressLeft": 0.5, "mouthPressRight": 0.5, "jawOpen": 0.04],
        .labiodental: ["mouthRollLower": 0.65, "mouthFunnel": 0.1, "jawOpen": 0.08],
        .dental: ["jawOpen": 0.16, "tongueOut": 0.45, "mouthStretchLeft": 0.1, "mouthStretchRight": 0.1],
        .alveolar: ["jawOpen": 0.2, "mouthStretchLeft": 0.15, "mouthStretchRight": 0.15],
        .velar: ["jawOpen": 0.26],
        .postalveolar: ["jawOpen": 0.14, "mouthFunnel": 0.35, "mouthPucker": 0.2],
        .sibilant: ["jawOpen": 0.1, "mouthStretchLeft": 0.35, "mouthStretchRight": 0.35, "mouthSmileLeft": 0.1, "mouthSmileRight": 0.1],
        .nasal: ["jawOpen": 0.15, "mouthStretchLeft": 0.1, "mouthStretchRight": 0.1],
        .rhotic: ["jawOpen": 0.2, "mouthFunnel": 0.35, "mouthPucker": 0.15],
        .open: ["jawOpen": 0.72, "mouthStretchLeft": 0.08, "mouthStretchRight": 0.08],
        .wide: ["jawOpen": 0.36, "mouthStretchLeft": 0.4, "mouthStretchRight": 0.4, "mouthSmileLeft": 0.15, "mouthSmileRight": 0.15],
        .nearClose: ["jawOpen": 0.2, "mouthSmileLeft": 0.3, "mouthSmileRight": 0.3, "mouthStretchLeft": 0.2, "mouthStretchRight": 0.2],
        .openRounded: ["jawOpen": 0.5, "mouthFunnel": 0.6, "mouthPucker": 0.2],
        .rounded: ["jawOpen": 0.24, "mouthPucker": 0.8, "mouthFunnel": 0.5],
    ]

    static let channelAliases: [String: [String]] = [
        "eyeBlinkLeft": ["eyeblinkleft", "vrc.blink_left", "blink_l", "blink_left", "blinkleft", "fcl_eye_close_l", "eye_close_l"],
        "eyeBlinkRight": ["eyeblinkright", "vrc.blink_right", "blink_r", "blink_right", "blinkright", "fcl_eye_close_r", "eye_close_r"],
        "blink": ["blink", "fcl_eye_close", "eyesclosed", "eyes_closed"],
        "eyeLookUpLeft": ["eyelookupleft"], "eyeLookDownLeft": ["eyelookdownleft"],
        "eyeLookInLeft": ["eyelookinleft"], "eyeLookOutLeft": ["eyelookoutleft"],
        "eyeLookUpRight": ["eyelookupright"], "eyeLookDownRight": ["eyelookdownright"],
        "eyeLookInRight": ["eyelookinright"], "eyeLookOutRight": ["eyelookoutright"],
        "eyeWideLeft": ["eyewideleft"], "eyeWideRight": ["eyewideright"],
        "browInnerUp": ["browinnerup", "fcl_brw_surprised"],
        "browOuterUpLeft": ["browouterupleft"], "browOuterUpRight": ["browouterupright"],
        "browDownLeft": ["browdownleft"], "browDownRight": ["browdownright"],
        "mouthSmileLeft": ["mouthsmileleft"], "mouthSmileRight": ["mouthsmileright"],
        "mouthFrownLeft": ["mouthfrownleft"], "mouthFrownRight": ["mouthfrownright"],
        "cheekSquintLeft": ["cheeksquintleft"], "cheekSquintRight": ["cheeksquintright"],
        "noseSneerLeft": ["nosesneerleft"], "noseSneerRight": ["nosesneerright"],
        "jawOpen": ["jawopen"], "mouthClose": ["mouthclose"], "mouthFunnel": ["mouthfunnel"],
        "mouthPucker": ["mouthpucker"], "mouthRollLower": ["mouthrolllower"],
        "mouthPressLeft": ["mouthpressleft"], "mouthPressRight": ["mouthpressright"],
        "mouthStretchLeft": ["mouthstretchleft"], "mouthStretchRight": ["mouthstretchright"],
        "tongueOut": ["tongueout"],
        "smile": ["fcl_mth_fun", "fcl_all_fun", "joy", "fun", "happy"],
        "sorrow": ["fcl_mth_sorrow", "fcl_all_sorrow", "sorrow", "sad"],
        "angry": ["fcl_all_angry", "angry"],
    ]

    /// Which morph target (lower-cased) serves each canonical channel and
    /// viseme, given the names a model actually has.
    struct Binding: Equatable, Sendable {
        let channels: [String: String]
        let visemes: [OpenClamAvatarViseme: String]

        var directVisemes: Set<OpenClamAvatarViseme> { Set(visemes.keys) }

        static func resolve(targetNames: some Sequence<String>) -> Binding {
            let available = Set(targetNames.map { $0.lowercased() })
            var channels: [String: String] = [:]
            for (channel, aliases) in channelAliases {
                if let match = aliases.first(where: available.contains) {
                    channels[channel] = match
                }
            }
            var visemes: [OpenClamAvatarViseme: String] = [:]
            for (viseme, aliases) in visemeAliases {
                if let match = aliases.first(where: available.contains) {
                    visemes[viseme] = match
                }
            }
            return Binding(channels: channels, visemes: visemes)
        }
    }
}

// MARK: - Pose

struct OpenClam3DAvatarPose: Equatable, Sendable {
    var visemeWeights: [OpenClamAvatarViseme: Double] = [:]
    var articulation: Double = 1
    var blinkLeft: Double = 0
    var blinkRight: Double = 0
    /// -1...1, positive is the viewer's right / screen down.
    var gazeX: Double = 0
    var gazeY: Double = 0
    /// -1 (furrow) ... 1 (raise).
    var brow: Double = 0
    var smile: Double = 0
    /// Idle mouth corners: 0 is the rig's authored neutral, 1 a full smile.
    static let restingSmile: Double = 0.35
    var sad: Double = 0
    var surprise: Double = 0
    var anger: Double = 0
    /// Radians, applied in world space on top of idle sway.
    var headYaw: Double = 0
    var headPitch: Double = 0
    var headRoll: Double = 0
    var speaking = false
    var reduceMotion = false
    var time: TimeInterval = 0

    static let idle = OpenClam3DAvatarPose()

    /// Morph-target weights keyed by lower-cased target name.
    func targetWeights(binding: OpenClam3DChannels.Binding) -> [String: Double] {
        var weights: [String: Double] = [:]
        func add(_ channel: String, _ value: Double) {
            guard value > 0.001, let target = binding.channels[channel] else { return }
            weights[target] = min(1, (weights[target] ?? 0) + value)
        }
        for (viseme, weight) in visemeWeights where viseme != .silence && weight > 0.002 {
            let scaled = weight * articulation
            if let target = binding.visemes[viseme] {
                weights[target] = min(1, (weights[target] ?? 0) + scaled)
            } else {
                for (channel, amount) in OpenClam3DChannels.visemeRecipes[viseme] ?? [:] {
                    add(channel, amount * scaled)
                }
            }
        }
        if binding.channels["eyeBlinkLeft"] != nil || binding.channels["eyeBlinkRight"] != nil {
            add("eyeBlinkLeft", blinkLeft)
            add("eyeBlinkRight", blinkRight)
        } else {
            add("blink", max(blinkLeft, blinkRight))
        }
        let gx = min(1, max(-1, gazeX)), gy = min(1, max(-1, gazeY))
        if gx > 0 { add("eyeLookOutLeft", gx); add("eyeLookInRight", gx) }
        if gx < 0 { add("eyeLookInLeft", -gx); add("eyeLookOutRight", -gx) }
        if gy > 0 { add("eyeLookDownLeft", gy); add("eyeLookDownRight", gy) }
        if gy < 0 { add("eyeLookUpLeft", -gy); add("eyeLookUpRight", -gy) }
        let browAmount = min(1, max(-1, brow))
        if browAmount > 0 {
            add("browInnerUp", browAmount * 0.45)
            add("browOuterUpLeft", browAmount * 0.35)
            add("browOuterUpRight", browAmount * 0.35)
        } else if browAmount < 0 {
            add("browDownLeft", -browAmount * 0.4)
            add("browDownRight", -browAmount * 0.4)
        }
        // Same resting hint of a smile as the desktop renderer, so the rig
        // never reads as blank or stern between replies.
        let restingSmile = max(0, OpenClam3DAvatarPose.restingSmile - max(0, sad) - max(0, anger))
        let smile = max(restingSmile, self.smile)
        if smile > 0 {
            add("mouthSmileLeft", smile * 0.5); add("mouthSmileRight", smile * 0.5)
            add("cheekSquintLeft", smile * 0.3); add("cheekSquintRight", smile * 0.3)
            add("smile", smile * 0.5)
        }
        if sad > 0 {
            add("mouthFrownLeft", sad * 0.35); add("mouthFrownRight", sad * 0.35)
            add("browInnerUp", sad * 0.4); add("sorrow", sad * 0.4)
        }
        if surprise > 0 {
            add("eyeWideLeft", surprise * 0.4); add("eyeWideRight", surprise * 0.4)
            add("browInnerUp", surprise * 0.3)
            add("browOuterUpLeft", surprise * 0.3); add("browOuterUpRight", surprise * 0.3)
        }
        if anger > 0 {
            add("browDownLeft", anger * 0.5); add("browDownRight", anger * 0.5)
            add("noseSneerLeft", anger * 0.2); add("noseSneerRight", anger * 0.2)
            add("angry", anger * 0.4)
        }
        return weights
    }
}

/// Keeps one smoothed weight per viseme so a fast consonant–vowel run passes
/// through real in-between shapes instead of snapping between plates.
final class OpenClam3DPoseSmoother: @unchecked Sendable {
    static let attack: TimeInterval = 0.038
    static let release: TimeInterval = 0.064

    private var weights: [OpenClamAvatarViseme: Double] = [:]
    private var lastTime: TimeInterval?
    private let lock = NSLock()

    func smoothedVisemeWeights(
        target: [OpenClamAvatarViseme: Double],
        at time: TimeInterval
    ) -> [OpenClamAvatarViseme: Double] {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = lastTime.map { min(0.12, max(0.001, time - $0)) } ?? 0.016
        lastTime = time
        var result: [OpenClamAvatarViseme: Double] = [:]
        for viseme in OpenClamAvatarViseme.allCases where viseme != .silence {
            let wanted = min(1, max(0, target[viseme] ?? 0))
            let current = weights[viseme] ?? 0
            let tau = wanted > current ? Self.attack : Self.release
            let next = current + (wanted - current) * (1 - exp(-elapsed / tau))
            weights[viseme] = next
            if next > 0.002 { result[viseme] = next }
        }
        return result
    }

    func reset() {
        lock.lock()
        weights = [:]
        lastTime = nil
        lock.unlock()
    }
}

extension OpenClamAvatarViseme {
    init(_ viseme: CaptainAyerViseme) {
        self = OpenClamAvatarViseme(rawValue: viseme.rawValue) ?? .silence
    }
}

extension CaptainAyerAvatarRenderState {
    /// The plate crossfade expressed as two viseme weights.
    var visemeTargets: [OpenClamAvatarViseme: Double] {
        var targets: [OpenClamAvatarViseme: Double] = [:]
        let now = OpenClamAvatarViseme(current), before = OpenClamAvatarViseme(previous)
        if now != .silence { targets[now] = blend }
        if before != .silence, before != now { targets[before] = 1 - blend }
        return targets
    }
}
