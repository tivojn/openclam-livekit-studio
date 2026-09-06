import Foundation
import GLTFKit2
import SceneKit
import UIKit
import simd

/// A loaded 3D avatar: the SceneKit scene GLTFKit2 built from the package's
/// `.glb`, the morphers and bones the pose solver drives, and a camera that
/// frames the figure exactly like the desktop renderer so the package's
/// `faceBounds` line up with what is drawn.
@MainActor
final class OpenClam3DAvatarRig {
    struct MorphBinding {
        let morpher: SCNMorpher
        /// lower-cased target name -> index
        let indices: [String: Int]
    }

    let scene: SCNScene
    let cameraNode: SCNNode
    let frame: CGSize
    let binding: OpenClam3DChannels.Binding
    private(set) var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)
    private var morphBindings: [MorphBinding] = []
    private var head: SCNNode?
    private var neck: SCNNode?
    private var chest: SCNNode?
    private var eyes: [SCNNode] = []
    private var baseOrientations: [ObjectIdentifier: simd_quatf] = [:]
    private var smoothed = SIMD3<Double>(repeating: 0)
    private var lastPoseTime: TimeInterval?
    private var appliedWeights: [ObjectIdentifier: [Int: CGFloat]] = [:]
    private var currentCrop: CGRect = .zero
    private let fieldOfView: Double = 22

    static func load(
        modelURL: URL,
        frame: CGSize,
        targetNames: [String: [String]]
    ) async throws -> OpenClam3DAvatarRig {
        let asset: GLTFAsset = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            GLTFAsset.load(with: modelURL, options: [:]) { _, status, maybeAsset, maybeError, _ in
                guard !resumed else { return }
                if let error = maybeError {
                    resumed = true
                    continuation.resume(throwing: error)
                } else if status == .complete, let loaded = maybeAsset {
                    resumed = true
                    continuation.resume(returning: loaded)
                }
            }
        }
        // Convert unsupported transmission before SceneKit constructs skinning
        // geometry, so every geometry receives the same transparent material.
        for material in asset.materials {
            if let transmission = material.transmission {
                applyTransmissionFallback(material, factor: transmission.transmissionFactor,
                                          indexOfRefraction: material.indexOfRefraction?.floatValue ?? 1.5)
            }
        }
        let scene = SCNScene(gltfAsset: asset)
        return OpenClam3DAvatarRig(scene: scene, frame: frame, targetNames: targetNames)
    }

    init(scene: SCNScene, frame: CGSize, targetNames: [String: [String]]) {
        self.scene = scene
        self.frame = frame
        self.binding = OpenClam3DChannels.Binding.resolve(
            targetNames: targetNames.values.flatMap { $0 }
        )
        cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.wantsHDR = false
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 100
        bounds = (SIMD3(repeating: 0), SIMD3(repeating: 1))
        scene.rootNode.addChildNode(cameraNode)
        scene.background.contents = nil
        // GLTFKit2 supplies the authored alpha cutoff, blending and sidedness.
        // Preserve those materials instead of guessing from mesh/material names.
        bindMorphers(targetNames: targetNames)
        collectBones()
        relaxArms()
        measure()
        addLights()
        frameCamera()
    }

    static func applyTransmissionFallback(
        _ material: GLTFMaterial, factor: Float, indexOfRefraction: Float
    ) {
        guard factor.isFinite, factor > 0 else { return }
        let transmission = min(1, factor)
        let ior = indexOfRefraction.isFinite ? max(1, indexOfRefraction) : 1.5
        let reflectance = pow((ior - 1) / (ior + 1), 2)
        let opacity = 1 - transmission + transmission * reflectance
        let pbr = material.metallicRoughness ?? GLTFPBRMetallicRoughnessParams()
        var color = pbr.baseColorFactor
        color.w *= opacity
        pbr.baseColorFactor = color
        material.metallicRoughness = pbr
        material.alphaMode = .blend
    }

    // MARK: Loading

    private func bindMorphers(targetNames: [String: [String]]) {
        let byCount = Dictionary(grouping: targetNames.values, by: \.count)
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let morpher = node.morpher, !morpher.targets.isEmpty else { return }
            let names: [String]? = targetNames[node.name ?? ""]
                ?? targetNames[node.geometry?.name ?? ""]
                ?? byCount[morpher.targets.count]?.first
            guard let names else { return }
            var indices: [String: Int] = [:]
            for (index, name) in names.enumerated() where index < morpher.targets.count {
                indices[name.lowercased()] = index
            }
            morpher.calculationMode = .additive
            morphBindings.append(MorphBinding(morpher: morpher, indices: indices))
        }
    }

    private static let bonePatterns: [(key: String, pattern: String)] = [
        ("head", "(^|[^a-z])head($|[^a-z]|\\.x$)|j_bip_c_head|mixamorighead|^c_head"),
        ("neck", "(^|[^a-z])neck(_?0?1)?($|[^a-z]|\\.x$)|j_bip_c_neck|mixamorigneck"),
        ("chest", "(^|[^a-z])(spine_?0?[23]|chest|spine2|upperchest)($|[^a-z])|j_bip_c_chest|mixamorigspine1"),
        ("eye", "((^|[^a-z])eye($|[^a-z])|c_eye[._]|j_bip_[lr]_faceeye|mixamorig(left|right)eye$)"),
        ("upperArm", "(upperarm|upper_arm|uparm|^(c_)?arm(_stretch)?[._]|leftarm$|rightarm$|j_bip_[lr]_upperarm|mixamorig(left|right)arm$)"),
        ("lowerArm", "(lowerarm|lower_arm|^(c_)?forearm(_stretch)?[._]|forearm|j_bip_[lr]_lowerarm|mixamorig(left|right)forearm$)"),
        ("hand", "((^|[^a-z])hand($|[^a-z])|j_bip_[lr]_hand|mixamorig(left|right)hand$)"),
        ("finger", "(index|middle|ring|pinky|thumb|finger|j_bip_[lr]_(index|middle|ring|little|thumb))"),
    ]
    private static let compiledPatterns: [String: NSRegularExpression] = {
        var result: [String: NSRegularExpression] = [:]
        for entry in bonePatterns {
            result[entry.key] = try? NSRegularExpression(pattern: entry.pattern)
        }
        return result
    }()

    private var boneGroups: [String: [String: [SCNNode]]] = [:]

    private static func matches(_ key: String, _ name: String) -> Bool {
        guard let regex = compiledPatterns[key] else { return false }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private static func side(of name: String) -> String? {
        let n = name.lowercased()
        if n.range(of: "(^|[^a-z])(left|l)([^a-z]|$)|_l$|\\.l$|^l_|left", options: .regularExpression) != nil { return "l" }
        if n.range(of: "(^|[^a-z])(right|r)([^a-z]|$)|_r$|\\.r$|^r_|right", options: .regularExpression) != nil { return "r" }
        return nil
    }

    private static func penalty(_ name: String) -> Double {
        let n = name.lowercased()
        var score = 0.0
        for token in ["ik_", "_ik", "offset", "twist", "stretch", "pole", "_fk", "nostr",
                      "ref", "track", "target", "ctrl", "control", "helper", "master", "scale_fix"]
        where n.contains(token) {
            score += 10
        }
        if n.hasPrefix("c_") { score += 5 }
        return score + Double(n.count) * 0.01
    }

    private func collectBones() {
        var candidates: [String: [SCNNode]] = [:]
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let name = node.name, node.geometry == nil else { return }
            let lowered = name.lowercased()
            for entry in Self.bonePatterns where Self.matches(entry.key, lowered) {
                candidates[entry.key, default: []].append(node)
            }
        }
        func best(_ nodes: [SCNNode]) -> SCNNode? {
            nodes.min { Self.penalty($0.name ?? "") < Self.penalty($1.name ?? "") }
        }
        head = best(candidates["head"] ?? [])
        neck = best(candidates["neck"] ?? [])
        chest = best(candidates["chest"] ?? [])
        for key in ["upperArm", "lowerArm", "hand", "finger", "eye"] {
            var sides: [String: [SCNNode]] = [:]
            for node in candidates[key] ?? [] {
                if let side = Self.side(of: node.name ?? "") {
                    sides[side, default: []].append(node)
                }
            }
            boneGroups[key] = sides
        }
        eyes = ["l", "r"].compactMap { best(boneGroups["eye"]?[$0] ?? []) }
        for node in [head, neck, chest].compactMap({ $0 }) + eyes {
            baseOrientations[ObjectIdentifier(node)] = node.simdOrientation
        }
    }

    /// Turn raised A/T-pose arms down beside the body, moving every deform
    /// bone of a segment as one rigid group about the joint.
    private func relaxArms() {
        let down = SIMD3<Float>(0, -1, 0)
        for side in ["l", "r"] {
            guard let upper = (boneGroups["upperArm"]?[side]).flatMap({ $0.min { Self.penalty($0.name ?? "") < Self.penalty($1.name ?? "") } }),
                  let forearm = (boneGroups["lowerArm"]?[side]).flatMap({ $0.min { Self.penalty($0.name ?? "") < Self.penalty($1.name ?? "") } })
            else { continue }
            let outward: Float = side == "l" ? 1 : -1
            let group = ["upperArm", "lowerArm", "hand", "finger"].flatMap { boneGroups[$0]?[side] ?? [] }
            guard rotateGroup(group, pivot: upper, end: forearm,
                              target: simd_normalize(SIMD3(0.16 * outward, -1, 0.04)),
                              reference: down, minimumDegrees: 22) else { continue }
            if let hand = (boneGroups["hand"]?[side]).flatMap({ $0.min { Self.penalty($0.name ?? "") < Self.penalty($1.name ?? "") } }) {
                let forearmGroup = ["lowerArm", "hand", "finger"].flatMap { boneGroups[$0]?[side] ?? [] }
                _ = rotateGroup(forearmGroup, pivot: forearm, end: hand,
                                target: simd_normalize(SIMD3(0.05 * outward, -1, 0.12)),
                                reference: down, minimumDegrees: 12)
            }
        }
    }

    private func rotateGroup(
        _ group: [SCNNode], pivot: SCNNode, end: SCNNode,
        target: SIMD3<Float>, reference: SIMD3<Float>, minimumDegrees: Float
    ) -> Bool {
        let pivotPosition = pivot.simdWorldPosition
        var current = end.simdWorldPosition - pivotPosition
        guard simd_length_squared(current) > 1e-10 else { return false }
        current = simd_normalize(current)
        let angle = acos(max(-1, min(1, simd_dot(current, reference)))) * 180 / .pi
        guard angle >= minimumDegrees else { return false }
        let rotation = simd_quatf(from: current, to: target)
        let members = Set(group.map(ObjectIdentifier.init))
        let roots = group.filter { node in
            var ancestor = node.parent
            while let candidate = ancestor {
                if members.contains(ObjectIdentifier(candidate)) { return false }
                ancestor = candidate.parent
            }
            return true
        }
        for node in roots {
            let worldPosition = node.simdWorldPosition
            let rotated = pivotPosition + rotation.act(worldPosition - pivotPosition)
            node.simdWorldOrientation = rotation * node.simdWorldOrientation
            node.simdWorldPosition = rotated
            if baseOrientations[ObjectIdentifier(node)] != nil {
                baseOrientations[ObjectIdentifier(node)] = node.simdOrientation
            }
        }
        return !roots.isEmpty
    }

    private func measure() {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        scene.rootNode.enumerateHierarchy { node, _ in
            guard node.geometry != nil, node !== cameraNode else { return }
            let box = node.boundingBox
            let transform = node.simdWorldTransform
            for corner in [
                SIMD3(box.min.x, box.min.y, box.min.z), SIMD3(box.max.x, box.min.y, box.min.z),
                SIMD3(box.min.x, box.max.y, box.min.z), SIMD3(box.max.x, box.max.y, box.min.z),
                SIMD3(box.min.x, box.min.y, box.max.z), SIMD3(box.max.x, box.min.y, box.max.z),
                SIMD3(box.min.x, box.max.y, box.max.z), SIMD3(box.max.x, box.max.y, box.max.z),
            ] {
                let world = transform * SIMD4(corner.x, corner.y, corner.z, 1)
                minimum = simd_min(minimum, SIMD3(world.x, world.y, world.z))
                maximum = simd_max(maximum, SIMD3(world.x, world.y, world.z))
            }
        }
        if minimum.x <= maximum.x {
            bounds = (minimum, maximum)
        }
    }

    private func addLights() {
        func light(_ type: SCNLight.LightType, _ intensity: CGFloat, _ color: UIColor,
                   position: SIMD3<Float>? = nil) {
            let node = SCNNode()
            node.light = SCNLight()
            node.light?.type = type
            node.light?.intensity = intensity
            node.light?.color = color
            if let position {
                let center = (bounds.min + bounds.max) / 2
                node.simdPosition = center + position * simd_length(bounds.max - bounds.min)
                node.simdLook(at: center)
            }
            scene.rootNode.addChildNode(node)
        }
        // SceneKit PBR reads intensity in lux-like units; a 1000 default
        // directional plus a bright ambient blows stylized skin out to white.
        light(.ambient, 180, UIColor(red: 0.98, green: 0.96, blue: 0.94, alpha: 1))
        light(.directional, 520, UIColor(red: 1, green: 0.95, blue: 0.89, alpha: 1), position: SIMD3(-0.6, 0.9, 1.1))
        light(.directional, 220, UIColor(red: 0.9, green: 0.93, blue: 1, alpha: 1), position: SIMD3(0.9, 0.5, 0.8))
        light(.directional, 320, .white, position: SIMD3(0.2, 0.9, -1))
        scene.lightingEnvironment.contents = Self.environmentImage
        scene.lightingEnvironment.intensity = 0.55
    }

    /// A tiny sky-to-ground gradient so physically based materials have
    /// something to reflect; a real HDRI is not shipped in the package.
    private static let environmentImage: UIImage = {
        let size = CGSize(width: 128, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let colors = [
                UIColor(red: 0.86, green: 0.9, blue: 0.98, alpha: 1).cgColor,
                UIColor(red: 0.74, green: 0.74, blue: 0.76, alpha: 1).cgColor,
                UIColor(red: 0.34, green: 0.32, blue: 0.3, alpha: 1).cgColor,
            ]
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0, 0.55, 1]
            )!
            context.cgContext.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: []
            )
        }
    }()

    private func frameCamera() {
        let size = bounds.max - bounds.min
        let center = (bounds.min + bounds.max) / 2
        let height = max(1e-4, size.y), width = max(1e-4, size.x)
        let vertical = Float(fieldOfView * .pi / 180) / 2
        let aspect = Float(frame.width / frame.height)
        let horizontal = atan(tan(vertical) * aspect)
        let distance = max(height * 0.5 * 1.06 / tan(vertical), width * 0.5 * 1.12 / tan(horizontal))
        cameraNode.simdPosition = SIMD3(center.x, center.y, bounds.max.z + distance)
        cameraNode.simdLook(at: center)
        cameraNode.camera?.zNear = Double(max(0.01, distance * 0.1))
        cameraNode.camera?.zFar = Double(distance * 6 + height * 4)
        setCrop(CGRect(origin: .zero, size: frame))
    }

    /// Render only `crop` (in the logical frame) by offsetting the projection.
    func setCrop(_ crop: CGRect) {
        guard crop != currentCrop, crop.width > 0, crop.height > 0 else { return }
        currentCrop = crop
        let near = Float(cameraNode.camera?.zNear ?? 0.1)
        let far = Float(cameraNode.camera?.zFar ?? 100)
        let f = 1 / tan(Float(fieldOfView * .pi / 180) / 2)
        let aspect = Float(frame.width / frame.height)
        var projection = simd_float4x4(0)
        projection[0][0] = f / aspect
        projection[1][1] = f
        projection[2][2] = (far + near) / (near - far)
        projection[2][3] = -1
        projection[3][2] = 2 * far * near / (near - far)
        let x0 = Float(2 * crop.minX / frame.width - 1)
        let x1 = Float(2 * crop.maxX / frame.width - 1)
        let y0 = Float(1 - 2 * crop.maxY / frame.height)
        let y1 = Float(1 - 2 * crop.minY / frame.height)
        var window = matrix_identity_float4x4
        window[0][0] = 2 / (x1 - x0)
        window[1][1] = 2 / (y1 - y0)
        window[3][0] = -(x0 + x1) / (x1 - x0)
        window[3][1] = -(y0 + y1) / (y1 - y0)
        cameraNode.camera?.projectionTransform = SCNMatrix4(window * projection)
    }

    // MARK: Per-frame

    func apply(_ pose: OpenClam3DAvatarPose) {
        let weights = pose.targetWeights(binding: binding)
        for entry in morphBindings {
            let key = ObjectIdentifier(entry.morpher)
            var applied = appliedWeights[key] ?? [:]
            var next: [Int: CGFloat] = [:]
            for (name, value) in weights {
                if let index = entry.indices[name] {
                    next[index] = CGFloat(min(1, max(0, value)))
                }
            }
            for (index, _) in applied where next[index] == nil {
                entry.morpher.setWeight(0, forTargetAt: index)
            }
            for (index, value) in next where applied[index] != value {
                entry.morpher.setWeight(value, forTargetAt: index)
            }
            applied = next
            appliedWeights[key] = applied
        }
        poseBones(pose)
    }

    private func poseBones(_ pose: OpenClam3DAvatarPose) {
        let t = pose.time
        let idle = pose.reduceMotion ? 0.0 : 1.0
        let yawTarget = pose.gazeX * 0.16 + idle * (sin(t * 0.37) * 0.012 + sin(t * 0.11) * 0.01) + pose.headYaw
        let pitchTarget = pose.gazeY * 0.1 + idle * sin(t * 0.29 + 1.3) * 0.008
            + (pose.speaking ? sin(t * 2.1) * 0.006 : 0) + pose.headPitch
        let rollTarget = idle * sin(t * 0.19 + 0.7) * 0.006 + pose.headRoll
        let elapsed = lastPoseTime.map { min(0.12, max(0.001, t - $0)) } ?? 0.016
        lastPoseTime = t
        let response = pose.reduceMotion ? 1 : 1 - exp(-elapsed / 0.11)
        smoothed.x += (yawTarget - smoothed.x) * response
        smoothed.y += (pitchTarget - smoothed.y) * response
        smoothed.z += (rollTarget - smoothed.z) * response
        if let neck {
            rotate(neck, yaw: smoothed.x * 0.4, pitch: -smoothed.y * 0.4, roll: smoothed.z * 0.4)
        }
        if let head {
            let share = neck == nil ? 1.0 : 0.6
            rotate(head, yaw: smoothed.x * share, pitch: -smoothed.y * share, roll: smoothed.z * share)
        }
        if let chest {
            let breath = sin(t / 1.25) * idle
            rotate(chest, yaw: idle * sin(t * 0.23) * 0.006, pitch: -breath * 0.006, roll: 0)
        }
        if binding.channels["eyeLookOutLeft"] == nil {
            for eye in eyes {
                rotate(eye, yaw: pose.gazeX * 0.18, pitch: -pose.gazeY * 0.12, roll: 0)
            }
        }
    }

    private func rotate(_ node: SCNNode, yaw: Double, pitch: Double, roll: Double) {
        guard let base = baseOrientations[ObjectIdentifier(node)] else { return }
        let world = simd_quatf(angle: Float(yaw), axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: Float(pitch), axis: SIMD3(1, 0, 0))
            * simd_quatf(angle: Float(roll), axis: SIMD3(0, 0, 1))
        let parentWorld = node.parent?.simdWorldOrientation ?? simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        let local = parentWorld.inverse * world * parentWorld
        node.simdOrientation = local * base
    }
}
