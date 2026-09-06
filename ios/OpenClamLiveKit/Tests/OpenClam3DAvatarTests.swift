import CryptoKit
import Foundation
import GLTFKit2
import SceneKit
import UIKit
import XCTest
import ZIPFoundation
@testable import OpenClamLiveKit

@MainActor
final class OpenClam3DAvatarTests: XCTestCase {
    private static let oculusTargets = [
        "vrc.v_sil", "vrc.v_pp", "vrc.v_ff", "vrc.v_th", "vrc.v_dd", "vrc.v_kk",
        "vrc.v_ch", "vrc.v_ss", "vrc.v_nn", "vrc.v_rr", "vrc.v_aa", "vrc.v_ee",
        "vrc.v_ih", "vrc.v_oh", "vrc.v_ou", "eyeBlinkLeft", "eyeBlinkRight",
    ]

    func testPlaybackAndCursorDefaultsRememberAnExplicitOptOut() {
        let name = "OpenClam3DDefaultsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OpenClam3DOptionsStore(defaults: defaults)
        XCTAssertTrue(store.enabled("playTransitions", for: "tia"))
        XCTAssertTrue(store.enabled("followCursor", for: "tia"))
        store.point(CGPoint(x: 100, y: 75), in: CGSize(width: 200, height: 300), for: "tia")
        XCTAssertEqual(store.pointers["tia"], CGPoint(x: 0.5, y: 0.25))
        store.setEnabled(false, key: "followCursor", for: "tia")
        store.setEnabled(false, key: "playTransitions", for: "tia")
        XCTAssertNil(store.pointers["tia"])
        let reopened = OpenClam3DOptionsStore(defaults: defaults)
        XCTAssertFalse(reopened.enabled("playTransitions", for: "tia"))
        XCTAssertFalse(reopened.enabled("followCursor", for: "tia"))
        XCTAssertTrue(reopened.enabled("playTransitions", for: "another"))
        reopened.reset("tia")
        XCTAssertFalse(reopened.enabled("followCursor", for: "tia"))
        reopened.setEnabled(true, key: "playTransitions", for: "tia")
        XCTAssertTrue(OpenClam3DOptionsStore(defaults: defaults).enabled("playTransitions", for: "tia"))
    }

    func testOrbitFitsEveryCornerAndResetRestoresTheFrontCamera() {
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: SCNBox(width: 0.7, height: 1.9, length: 0.45, chamferRadius: 0)))
        let rig = OpenClam3DAvatarRig(scene: scene, frame: CGSize(width: 1024, height: 1536), targetNames: [:])
        let original = rig.cameraNode.simdWorldTransform
        for yaw in [0.0, .pi / 2, .pi, -.pi / 2] {
            for pitch in [-Double.pi * 0.44, 0, Double.pi * 0.44] {
                rig.setOrbit(.init(yaw: yaw, pitch: pitch))
                let m = simd_float4x4(rig.cameraNode.camera!.projectionTransform) * rig.cameraNode.simdWorldTransform.inverse
                for x in [rig.bounds.min.x, rig.bounds.max.x] {
                    for y in [rig.bounds.min.y, rig.bounds.max.y] {
                        for z in [rig.bounds.min.z, rig.bounds.max.z] {
                            let p = m * SIMD4<Float>(x, y, z, 1)
                            XCTAssertLessThan(abs(p.x / p.w), 1)
                            XCTAssertLessThan(abs(p.y / p.w), 1)
                            XCTAssertGreaterThan(p.w, 0)
                        }
                    }
                }
            }
        }
        rig.setOrbit(.init())
        for i in 0..<4 { for j in 0..<4 {
            XCTAssertEqual(rig.cameraNode.simdWorldTransform[i][j], original[i][j], accuracy: 0.00001)
        } }
        let drag = OpenClam3DOrbit().dragging(CGSize(width: 200, height: 150))
        XCTAssertLessThan(drag.yaw, 0)
        XCTAssertGreaterThan(drag.pitch, 0)
        XCTAssertEqual(OpenClam3DOrbit(pitch: 100).sanitized.pitch, .pi * 0.44)
        XCTAssertEqual(OpenClam3DOrbit(yaw: .nan, pitch: .infinity).sanitized, .init())
    }

    func testSharedRendererResourcesAndWeightedSpeechAreAvailableOffline() throws {
        for name in OpenClam3DWebAssets.resources.values {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: nil), "Missing renderer dependency: \(name)")
        }
        var pose = OpenClam3DAvatarPose()
        pose.visemeWeights = [.open: 0.6, .bilabial: 0.4]
        let weights = try XCTUnwrap(pose.webState["visemeWeights"] as? [String: Double])
        XCTAssertEqual(weights, ["aa": 0.6, "PP": 0.4])
    }

    func testViewportZoomAndPlacementMapToTheVisibleCameraCrop() {
        let logical = CGRect(x: 0, y: 0, width: 1024, height: 1536)
        let canvas = CGRect(x: 0, y: 60, width: 400, height: 600)
        let full = OpenClam3DViewportPolicy.crop(logicalCrop: logical, stageFrame: canvas,
                                               canvas: canvas, transform: .factory)
        XCTAssertEqual(full, logical)
        let zoomed = OpenClam3DViewportPolicy.crop(logicalCrop: logical, stageFrame: canvas, canvas: canvas,
                            transform: .init(scale: 2, normalizedOffset: CGPoint(x: 0.1, y: 0.1)))
        XCTAssertEqual(zoomed.width, logical.width / 2, accuracy: 0.001)
        XCTAssertEqual(zoomed.height, logical.height / 2, accuracy: 0.001)
        XCTAssertEqual(zoomed.minX, 204.8, accuracy: 0.001)
        XCTAssertEqual(zoomed.minY, -76.8, accuracy: 0.001)
    }

    func testRigPreservesLoadedMaterialAppearance() {
        let scene = SCNScene()
        let mesh = SCNNode(geometry: SCNSphere(radius: 1))
        let glass = SCNMaterial()
        glass.name = "Cornea clear glass"
        glass.transparency = 0.65
        glass.blendMode = .alpha
        glass.transparencyMode = .dualLayer
        glass.writesToDepthBuffer = false
        glass.isDoubleSided = false
        let mask = SCNMaterial()
        mask.name = "Hair"
        mask.blendMode = .replace
        mask.isDoubleSided = false
        let cutoff = "if (_output.color.a < 0.65) { discard_fragment(); }"
        mask.shaderModifiers = [.fragment: cutoff]
        let authoredTransparency = glass.transparency
        mesh.geometry?.materials = [glass, mask]
        scene.rootNode.addChildNode(mesh)
        _ = OpenClam3DAvatarRig(scene: scene, frame: CGSize(width: 1024, height: 1536), targetNames: [:])
        XCTAssertEqual(glass.transparency, authoredTransparency)
        XCTAssertEqual(glass.blendMode, .alpha)
        XCTAssertEqual(glass.transparencyMode, .dualLayer)
        XCTAssertFalse(glass.writesToDepthBuffer)
        XCTAssertFalse(glass.isDoubleSided)
        XCTAssertEqual(mask.blendMode, .replace)
        XCTAssertEqual(mask.shaderModifiers?[.fragment], cutoff)
        XCTAssertFalse(mask.isDoubleSided)
    }

    func testTransmissionFallbackUsesAuthoredValuesWithoutNameHeuristics() {
        let material = GLTFMaterial()
        material.name = "Any material name"
        let pbr = GLTFPBRMetallicRoughnessParams()
        pbr.baseColorFactor = SIMD4<Float>(1, 0.8, 0.6, 0.5)
        material.metallicRoughness = pbr
        let originalColor = pbr.baseColorFactor
        OpenClam3DAvatarRig.applyTransmissionFallback(material, factor: 0, indexOfRefraction: 1.5)
        XCTAssertEqual(pbr.baseColorFactor, originalColor)
        XCTAssertEqual(material.alphaMode, .opaque)
        OpenClam3DAvatarRig.applyTransmissionFallback(material, factor: 1, indexOfRefraction: 1.5)
        XCTAssertEqual(pbr.baseColorFactor.w, originalColor.w * 0.04, accuracy: 0.00001)
        XCTAssertEqual(pbr.baseColorFactor.x, originalColor.x)
        XCTAssertEqual(pbr.baseColorFactor.y, originalColor.y)
        XCTAssertEqual(pbr.baseColorFactor.z, originalColor.z)
        XCTAssertEqual(material.alphaMode, .blend)
        XCTAssertFalse(material.isDoubleSided)
    }

    func testUnsignedBoneIndicesRemainPositiveAcrossTheSignedByteBoundary() throws {
        let raw = Data([99, 0, 127, 128, 156, 99, 99, 156, 128, 127, 0, 99])
        let source = SCNGeometrySource(data: raw, semantic: .boneIndices, vectorCount: 2,
                                       usesFloatComponents: false, componentsPerVector: 4,
                                       bytesPerComponent: 1, dataOffset: 1, dataStride: 6)
        let result = try XCTUnwrap(OpenClam3DAvatarRig.widenedBoneIndices(source, boneCount: 157))
        XCTAssertEqual(result.bytesPerComponent, 2)
        XCTAssertEqual(result.componentsPerVector, 4)
        XCTAssertEqual(result.vectorCount, 2)
        let values = result.data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        XCTAssertEqual(values, [0, 127, 128, 156, 156, 128, 127, 0])
        XCTAssertEqual(source.data, raw, "Loading must not rewrite the installed asset")
        XCTAssertNil(OpenClam3DAvatarRig.widenedBoneIndices(source, boneCount: 156))

        let wide: [UInt16] = [0, 255, 32_768, 65_535]
        let shorts = SCNGeometrySource(data: wide.withUnsafeBytes { Data($0) }, semantic: .boneIndices,
                                      vectorCount: 1, usesFloatComponents: false, componentsPerVector: 4,
                                      bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
        XCTAssertNil(OpenClam3DAvatarRig.widenedBoneIndices(shorts, boneCount: 65_536),
                     "Existing uint16 skinning indices need no widening")
        let truncated = SCNGeometrySource(data: Data([0, 1, 2]), semantic: .boneIndices,
                                         vectorCount: 2, usesFloatComponents: false, componentsPerVector: 4,
                                         bytesPerComponent: 1, dataOffset: 0, dataStride: 4)
        XCTAssertNil(OpenClam3DAvatarRig.widenedBoneIndices(truncated, boneCount: 157))
    }

    func testSkinnedFacialBlendPreservesTopologyAndNeverAccumulatesAcrossFrames() throws {
        func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic, components: Int = 3) -> SCNGeometrySource {
            SCNGeometrySource(data: values.withUnsafeBytes { Data($0) }, semantic: semantic,
                              vectorCount: values.count / components, usesFloatComponents: true,
                              componentsPerVector: components, bytesPerComponent: 4,
                              dataOffset: 0, dataStride: components * 4)
        }
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let normal = source([0, 0, 1, 0, 0, 1, 0, 0, 1], .normal)
        let uv = source([0, 0, 1, 0, 0, 1], .texcoord, components: 2)
        let element = SCNGeometryElement(indices: [UInt16(0), 1, 2], primitiveType: .triangles)
        let base = SCNGeometry(sources: [source(positions, .vertex), normal, uv], elements: [element])
        let material = SCNMaterial()
        base.materials = [material]
        let node = SCNNode(geometry: base)
        let head = SCNNode()
        let skinner = SCNSkinner(baseGeometry: base, bones: [head],
                                boneInverseBindTransforms: [NSValue(scnMatrix4: SCNMatrix4Identity)],
                                boneWeights: source([1, 1, 1], .boneWeights, components: 1),
                                boneIndices: SCNGeometrySource(data: Data([UInt8(0), 0, 0]), semantic: .boneIndices,
                                                               vectorCount: 3, usesFloatComponents: false,
                                                               componentsPerVector: 1, bytesPerComponent: 1,
                                                               dataOffset: 0, dataStride: 1))
        node.skinner = skinner
        let morpher = SCNMorpher()
        morpher.calculationMode = .additive
        var names = (0 ..< 71).map { "unused-\($0)" }
        names[0] = "wardrobeFit"; names[50] = "eyeBlinkLeft"; names[70] = "vrc.v_aa"
        morpher.targets = names.indices.map { index in
            var delta = [Float](repeating: 0, count: 9)
            if index == 0 { delta[0] = 0.2 }
            if index == 50 { delta[7] = -0.4 }
            if index == 70 { delta[5] = 0.6 }
            return SCNGeometry(sources: [source(delta, .vertex)], elements: [element])
        }
        morpher.setWeight(0.5, forTargetAt: 0)
        node.morpher = morpher
        let blend = try XCTUnwrap(OpenClam3DSkinnedMorphGeometry(node: node, names: names))
        XCTAssertNil(node.morpher, "GPU receives the blended surface, never 71 simultaneous morph buffers")
        let initial = try XCTUnwrap(node.geometry?.sources(for: .vertex).first?.data)
        for _ in 0 ..< 40 {
            blend.apply(["eyeblinkleft": 0.5, "vrc.v_aa": 0.75])
            XCTAssertEqual(blend.currentPositions[0], 0.1, accuracy: 0.00001, "Authored fit survives speech")
            XCTAssertEqual(blend.currentPositions[5], 0.45, accuracy: 0.00001)
            XCTAssertEqual(blend.currentPositions[7], 0.8, accuracy: 0.00001)
            XCTAssertTrue(node.geometry?.materials.first === material)
            XCTAssertTrue(node.geometry?.elements.first === element)
            XCTAssertTrue(node.skinner === skinner)
            XCTAssertTrue(node.geometry?.sources(for: .texcoord).first === uv)
            blend.apply([:])
            XCTAssertEqual(blend.currentPositions, [0.1, 0, 0, 1, 0, 0, 0, 1, 0])
        }
        XCTAssertEqual(initial, node.geometry?.sources(for: .vertex).first?.data,
                       "Previously rendered buffers stay immutable, and neutral returns exactly")
        blend.apply(["vrc.v_aa": .nan])
        XCTAssertTrue(blend.currentPositions.allSatisfy(\.isFinite))
    }

    func testInstalledModelRenderingWhenRequested() async throws {
        guard let id = ProcessInfo.processInfo.environment["OPENCLAM_QA_3D_AVATAR_ID"] else {
            throw XCTSkip("Opt-in local model render check")
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: false)
        let url = support.appendingPathComponent("OpenClam/Avatars/v2/\(id)/assets/model.glb")
        let data = try Data(contentsOf: url)
        let summary = try OpenClam3DGLBReader.summary(of: data)
        let rig = try await OpenClam3DAvatarRig.load(modelURL: url, frame: CGSize(width: 1024, height: 1536),
                                                   targetNames: summary.targetNames)
        var skins = 0
        rig.scene.rootNode.enumerateHierarchy { node, _ in
            guard let skin = node.skinner else { return }
            skins += 1
            XCTAssertEqual(skin.boneIndices.bytesPerComponent, 2, "\(node.name ?? "mesh") must use 16-bit bone indices")
            XCTAssertEqual(skin.boneIndices.vectorCount, skin.boneWeights.vectorCount)
        }
        XCTAssertGreaterThan(skins, 0)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = rig.scene
        renderer.pointOfView = rig.cameraNode
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 512, height: 768), antialiasingMode: .multisampling4X)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Imported 3D avatar"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["OPENCLAM_QA_3D_OUTPUT"] {
            try image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("loaded-model.png"))
            for (name, orbit) in [("front", OpenClam3DOrbit()),
                                   ("above", OpenClam3DOrbit(pitch: .pi / 4)),
                                   ("below", OpenClam3DOrbit(pitch: -.pi / 6)),
                                   ("side", OpenClam3DOrbit(yaw: .pi / 2)),
                                   ("back", OpenClam3DOrbit(yaw: .pi))] {
                rig.setOrbit(orbit)
                let view = renderer.snapshot(atTime: 0, with: CGSize(width: 512, height: 768), antialiasingMode: .multisampling4X)
                try view.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("orbit-\(name).png"))
            }
            rig.setOrbit(.init())
            // Exercise the animated path as well as the untouched load pose.
            // A neutral snapshot alone does not validate GPU morph + skinning.
            rig.setCrop(CGRect(x: 250, y: 20, width: 520, height: 720))
            for (index, phase) in ["idle", "blink", "gaze-left", "gaze-right", "speech", "mixed", "reset"].enumerated() {
                var pose = OpenClam3DAvatarPose()
                pose.time = Double(index + 1)
                pose.reduceMotion = true
                if phase == "blink" { pose.blinkLeft = 1; pose.blinkRight = 1 }
                if phase == "gaze-left" { pose.gazeX = -1 }
                if phase == "gaze-right" { pose.gazeX = 1 }
                if phase == "speech" { pose.visemeWeights = [.open: 1]; pose.speaking = true }
                if phase == "mixed" {
                    pose.visemeWeights = [.open: 0.5, .rounded: 0.5]
                    pose.blinkLeft = 0.5; pose.blinkRight = 0.5; pose.gazeX = 0.8; pose.brow = 0.7
                }
                rig.apply(pose)
                let frame = renderer.snapshot(atTime: pose.time, with: CGSize(width: 520, height: 720), antialiasingMode: .multisampling4X)
                try frame.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("pose-\(phase).png"))
            }
        }
    }

    // MARK: GLB reader

    func testReaderSummarisesTargetsAndJointsAndRejectsUnsupportedContainers() throws {
        let summary = try OpenClam3DGLBReader.summary(of: Self.makeGLB(Self.document(targets: Self.oculusTargets)))
        XCTAssertEqual(summary.targetNames["Face"], Self.oculusTargets)
        XCTAssertEqual(summary.joints, ["hips", "neck_01", "head"])
        XCTAssertEqual(summary.imageCount, 0)
        var withMaterials = Self.document(targets: Self.oculusTargets)
        withMaterials["materials"] = [["name": "Skin"], ["name": "Hair", "alphaMode": "BLEND"], ["name": "Lash", "alphaMode": "MASK"]]
        let modes = try OpenClam3DGLBReader.summary(of: Self.makeGLB(withMaterials)).materialAlphaModes
        XCTAssertEqual(modes, ["Skin": "OPAQUE", "Hair": "BLEND", "Lash": "MASK"])

        XCTAssertThrowsError(try OpenClam3DGLBReader.summary(of: Data("not a model at all, really".utf8))) {
            XCTAssertEqual($0 as? OpenClam3DModelError, .notGLB)
        }
        var draco = Self.document(targets: Self.oculusTargets)
        draco["extensionsRequired"] = ["KHR_draco_mesh_compression"]
        XCTAssertThrowsError(try OpenClam3DGLBReader.summary(of: Self.makeGLB(draco))) {
            XCTAssertEqual($0 as? OpenClam3DModelError, .unsupportedExtension("KHR_draco_mesh_compression"))
        }
        var external = Self.document(targets: Self.oculusTargets)
        external["images"] = [["uri": "skin.png"]]
        XCTAssertThrowsError(try OpenClam3DGLBReader.summary(of: Self.makeGLB(external))) {
            XCTAssertEqual($0 as? OpenClam3DModelError, .externalResources)
        }
    }

    // MARK: Channel binding and pose

    func testBindingResolvesDirectVisemesAndArkitRecipesFallBack() {
        let direct = OpenClam3DChannels.Binding.resolve(targetNames: Self.oculusTargets)
        XCTAssertEqual(direct.directVisemes, Set(OpenClamAvatarViseme.allCases))
        XCTAssertEqual(direct.visemes[.wide], "vrc.v_ee")
        XCTAssertEqual(direct.channels["eyeBlinkLeft"], "eyeblinkleft")

        let arkit = OpenClam3DChannels.Binding.resolve(
            targetNames: ["jawOpen", "mouthFunnel", "mouthPucker", "mouthClose", "eyeBlinkLeft", "eyeBlinkRight"]
        )
        XCTAssertTrue(arkit.directVisemes.isEmpty)
        var pose = OpenClam3DAvatarPose()
        pose.visemeWeights = [.open: 1]
        let weights = pose.targetWeights(binding: arkit)
        XCTAssertEqual(weights["jawopen"] ?? 0, 0.72, accuracy: 0.001)
        pose.visemeWeights = [.rounded: 1]
        let rounded = pose.targetWeights(binding: arkit)
        XCTAssertEqual(rounded["mouthpucker"] ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(rounded["mouthfunnel"] ?? 0, 0.5, accuracy: 0.001)
    }

    func testPoseMapsBlinkGazeAndMoodOntoNamedTargets() {
        let binding = OpenClam3DChannels.Binding.resolve(
            targetNames: Self.oculusTargets + ["eyeLookOutLeft", "eyeLookInRight", "browInnerUp", "mouthSmileLeft", "mouthSmileRight"]
        )
        var pose = OpenClam3DAvatarPose()
        pose.visemeWeights = [.open: 0.5, .wide: 0.5]
        pose.blinkLeft = 1
        pose.gazeX = 0.6
        pose.brow = 1
        pose.smile = 1
        let weights = pose.targetWeights(binding: binding)
        XCTAssertEqual(weights["vrc.v_aa"] ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(weights["vrc.v_ee"] ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(weights["eyeblinkleft"], 1)
        XCTAssertNil(weights["eyeblinkright"])
        XCTAssertEqual(weights["eyelookoutleft"] ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(weights["eyelookinright"] ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(weights["browinnerup"] ?? 0, 0.45, accuracy: 0.001)
        XCTAssertEqual(weights["mouthsmileleft"] ?? 0, 0.5, accuracy: 0.001)
    }

    func testSmootherApproachesTargetsWithoutSnapping() {
        let smoother = OpenClam3DPoseSmoother()
        let first = smoother.smoothedVisemeWeights(target: [.open: 1], at: 0)
        XCTAssertGreaterThan(first[.open] ?? 0, 0.2)
        XCTAssertLessThan(first[.open] ?? 0, 0.6)
        // Progress is capped per frame, so a long stall still settles over a
        // few frames instead of jumping.
        var settled = first
        for step in 1 ... 6 {
            settled = smoother.smoothedVisemeWeights(target: [.open: 1], at: 0.1 * Double(step))
        }
        XCTAssertGreaterThan(settled[.open] ?? 0, 0.99)
        let releasing = smoother.smoothedVisemeWeights(target: [:], at: 0.63)
        XCTAssertGreaterThan(releasing[.open] ?? 0, 0.4)
        XCTAssertLessThan(releasing[.open] ?? 0, 0.8)
        let state = CaptainAyerAvatarRenderState(previous: .open, current: .rounded, blend: 0.25)
        XCTAssertEqual(state.visemeTargets, [.rounded: 0.25, .open: 0.75])
    }

    func testVisibleRectWidensTheCropToTheStageAspect() {
        let crop = CGRect(x: 100, y: 200, width: 400, height: 800)
        let visible = OpenClam3DAvatarArtwork.visibleRect(crop: crop, in: CGSize(width: 300, height: 300))
        XCTAssertEqual(visible.width, 800, accuracy: 0.001)
        XCTAssertEqual(visible.height, 800, accuracy: 0.001)
        XCTAssertEqual(visible.midX, crop.midX, accuracy: 0.001)
    }

    // MARK: Package contract

    func testIOS3DPackageInstallsAsModelDrivenAvatar() throws {
        let root = try temporaryDirectory()
        let store = OpenClamAvatarPackageStore(storageRoot: root)
        let archive = try makeModelArchive()
        let descriptor = try store.installArchive(at: archive)
        XCTAssertEqual(descriptor.id, "tia-test")
        XCTAssertTrue(descriptor.compatibility.rendersModel)
        XCTAssertEqual(descriptor.sourceMedium, .rendered3D)
        XCTAssertEqual(descriptor.geometry.bodySize, OpenClamAvatarSize(width: 1_024, height: 1_536))
        XCTAssertEqual(descriptor.geometry.faceBoundsInBody, OpenClamAvatarRect(x: 407, y: 88, width: 210, height: 210))
        guard case let .installedFile(modelURL)? = descriptor.asset(.model) else {
            return XCTFail("model asset must be an installed file")
        }
        XCTAssertEqual(modelURL.lastPathComponent, "model.glb")
        XCTAssertNotNil(descriptor.asset(.thumbnail))
        let library = OpenClamAvatarLibrary(storageRoot: root)
        XCTAssertTrue(library.avatars.map(\.id).contains("tia-test"), "the library lists the model avatar beside the bundled ones")
        XCTAssertEqual(library.avatar(id: "tia-test")?.compatibility.rendersModel, true)
    }

    func testIOS3DPackageRejectsTamperedOrForeignModels() throws {
        let root = try temporaryDirectory()
        let store = OpenClamAvatarPackageStore(storageRoot: root)

        XCTAssertThrowsError(try store.installArchive(at: makeModelArchive(mutate: { manifest, _ in
            manifest["variant"] = "ios-light"
        }))) { XCTAssertEqual($0 as? OpenClamAvatarPackageError, .unsupportedVariant("ios-light")) }

        XCTAssertThrowsError(try store.installArchive(at: makeModelArchive(mutate: { _, model in
            model = Self.makeGLB(Self.document(targets: Self.oculusTargets, extensionsRequired: ["KHR_draco_mesh_compression"]))
        }))) { XCTAssertEqual($0 as? OpenClamAvatarPackageError, .invalidAssetImage("model")) }

        XCTAssertThrowsError(try store.installArchive(at: makeModelArchive(mutate: { manifest, _ in
            var model = manifest["model"] as! [String: Any]
            model["sha256"] = String(repeating: "0", count: 64)
            manifest["model"] = model
        }))) { XCTAssertEqual($0 as? OpenClamAvatarPackageError, .hashMismatch("model")) }

        XCTAssertThrowsError(try store.installArchive(at: makeModelArchive(mutate: { manifest, _ in
            manifest["rig"] = ["bodySize": ["width": 1, "height": 1]]
        }))) { XCTAssertEqual($0 as? OpenClamAvatarPackageError, .privateMetadataNotAllowed) }

        XCTAssertThrowsError(try store.installArchive(at: makeModelArchive(extraEntry: ("assets/notes.txt", Data("hi".utf8))))) {
            XCTAssertEqual($0 as? OpenClamAvatarPackageError, .unexpectedArchivePath("assets/notes.txt"))
        }
    }

    // MARK: Helpers

    private static func document(targets: [String], extensionsRequired: [String]? = nil) -> [String: Any] {
        var document: [String: Any] = [
            "asset": ["version": "2.0", "generator": "test"],
            "nodes": [["name": "hips"], ["name": "neck_01"], ["name": "head"],
                      ["name": "Face", "mesh": 0, "skin": 0]],
            "skins": [["joints": [0, 1, 2]]],
            "meshes": [[
                "name": "Face",
                "extras": ["targetNames": targets],
                "primitives": [[
                    "attributes": ["POSITION": 0],
                    "targets": targets.map { _ in ["POSITION": 0] },
                ]],
            ]],
            "accessors": [["componentType": 5126, "count": 3, "type": "VEC3"]],
            "buffers": [["byteLength": 4]],
        ]
        if let extensionsRequired { document["extensionsRequired"] = extensionsRequired }
        return document
    }

    private static func makeGLB(_ document: [String: Any], binary: Data = Data(repeating: 0, count: 4)) -> Data {
        var payload = try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        while payload.count % 4 != 0 { payload.append(0x20) }
        var body = Data()
        func append(_ value: UInt32) { var little = value.littleEndian; body.append(Data(bytes: &little, count: 4)) }
        append(UInt32(payload.count)); append(0x4E4F_534A); body.append(payload)
        append(UInt32(binary.count)); append(0x004E_4942); body.append(binary)
        var header = Data()
        func headerValue(_ value: UInt32) { var little = value.littleEndian; header.append(Data(bytes: &little, count: 4)) }
        headerValue(0x4654_6C67); headerValue(2); headerValue(UInt32(12 + body.count))
        return header + body
    }

    private static func thumbnailPNG() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format)
        return renderer.pngData { context in
            UIColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeModelArchive(
        mutate: ((inout [String: Any], inout Data) throws -> Void)? = nil,
        extraEntry: (String, Data)? = nil
    ) throws -> URL {
        var model = Self.makeGLB(Self.document(targets: Self.oculusTargets))
        let thumbnail = Self.thumbnailPNG()
        var manifest: [String: Any] = [
            "format": "openclam-avatar",
            "version": 5,
            "variant": "ios-3d",
            "id": "tia-test",
            "displayName": "Tia Test",
            "sourceMedium": "3d render",
            "model": [
                "path": "assets/model.glb",
                "sha256": sha256(model),
                "byteCount": model.count,
                "mediaType": "model/gltf-binary",
                "frame": ["width": 1024, "height": 1536],
                "bounds": ["x": 150, "y": 43, "width": 724, "height": 1449],
                "faceBounds": ["x": 407, "y": 88, "width": 210, "height": 210],
                "visemes": ["direct": OpenClamAvatarViseme.allCases.map(\.rawValue), "approximated": [], "missing": []],
            ],
            "assets": [
                "thumbnail": [
                    "path": "assets/thumbnail.png",
                    "sha256": sha256(thumbnail),
                    "byteCount": thumbnail.count,
                    "mediaType": "image/png",
                    "width": 512,
                    "height": 512,
                ],
            ],
        ]
        try mutate?(&manifest, &model)
        // A replaced model keeps a truthful byte count and hash so the size
        // check does not mask the assertion under test; a deliberately
        // corrupted hash (all zeros) is left alone.
        if var modelEntry = manifest["model"] as? [String: Any],
           modelEntry["sha256"] as? String != String(repeating: "0", count: 64) {
            modelEntry["byteCount"] = model.count
            modelEntry["sha256"] = sha256(model)
            manifest["model"] = modelEntry
        }
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        var entries: [(String, Data)] = [
            ("manifest.json", manifestData),
            ("assets/thumbnail.png", thumbnail),
            ("assets/model.glb", model),
        ]
        if let extraEntry { entries.append(extraEntry) }
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("model.avtr")
        let archive = try ZIPFoundation.Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .none
            ) { position, size in
                let lower = Int(position)
                return data.subdata(in: lower ..< min(data.count, lower + size))
            }
        }
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenClam3DAvatarTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

extension OpenClam3DAvatarTests {
    func testModelArchiveAboveSpriteLimitImportsThroughSnapshot() throws {
        let archive = try makeModelArchive { _, model in
            var document = Self.document(targets: Self.oculusTargets)
            let binary = Data(repeating: 0, count: 65 * 1024 * 1024)
            document["buffers"] = [["byteLength": binary.count]]
            model = Self.makeGLB(document, binary: binary)
        }
        let size = try XCTUnwrap(archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(UInt64(size), OpenClamAvatarPackageContract.maximumArchiveByteCount)
        let store = OpenClamAvatarPackageStore(storageRoot: try temporaryDirectory())
        let installed = try store.installArchive(at: archive)
        XCTAssertEqual(installed.id, "tia-test")
        XCTAssertTrue(installed.compatibility.rendersModel)
    }

    func testBundledWardrobeUpgradesExistingModelOnceAndDoesNotRestoreDeletedAvatar() async throws {
        let root = try temporaryDirectory()
        let library = OpenClamAvatarLibrary(storageRoot: root)
        let original = try await library.importAvatar(from: makeModelArchive())
        let modelURL = try installedModelURL(original)
        let before = try OpenClamBundledAvatarUpdate.sha256(at: modelURL)
        let resources = try bundledUpdateFixture(sourceHash: before)
        await library.applyBundledUpdates(at: resources)
        XCTAssertTrue(library.bundledUpdateErrors.isEmpty)
        XCTAssertEqual(library.importedAvatars.map(\.id), [original.id])
        XCTAssertNotEqual(try OpenClamBundledAvatarUpdate.sha256(at: modelURL), before)
        let modified = try modelURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        // An already applied update must not even need its archive again.
        try FileManager.default.removeItem(at: resources.appendingPathComponent("tia-test.avtr"))
        await library.applyBundledUpdates(at: resources)
        XCTAssertTrue(library.bundledUpdateErrors.isEmpty)
        XCTAssertEqual(try modelURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        try await library.deleteImportedAvatar(id: original.id)
        await library.applyBundledUpdates(at: resources)
        XCTAssertTrue(library.importedAvatars.isEmpty)
        XCTAssertNil(library.mutation)
    }

    func testBundledWardrobePreservesCustomModelsAndMissingAvatars() async throws {
        let library = OpenClamAvatarLibrary(storageRoot: try temporaryDirectory())
        let resources = try bundledUpdateFixture(sourceHash: String(repeating: "1", count: 64))
        await library.applyBundledUpdates(at: resources)
        XCTAssertTrue(library.importedAvatars.isEmpty)
        let original = try await library.importAvatar(from: makeModelArchive())
        let modelURL = try installedModelURL(original)
        let before = try Data(contentsOf: modelURL)
        await library.applyBundledUpdates(at: resources)
        XCTAssertEqual(try Data(contentsOf: modelURL), before)
        XCTAssertTrue(library.bundledUpdateErrors.isEmpty)
    }

    func testInvalidBundledWardrobePreservesOldModelAndCanRetry() async throws {
        let library = OpenClamAvatarLibrary(storageRoot: try temporaryDirectory())
        let original = try await library.importAvatar(from: makeModelArchive())
        let modelURL = try installedModelURL(original)
        let before = try Data(contentsOf: modelURL)
        let resources = try bundledUpdateFixture(sourceHash: sha256(before))
        let archive = resources.appendingPathComponent("tia-test.avtr")
        let valid = try Data(contentsOf: archive)
        try Data("broken".utf8).write(to: archive)
        await library.applyBundledUpdates(at: resources)
        XCTAssertNotNil(library.bundledUpdateErrors[original.id])
        XCTAssertEqual(try Data(contentsOf: modelURL), before)
        XCTAssertNil(library.mutation)
        try valid.write(to: archive)
        await library.applyBundledUpdates(at: resources)
        XCTAssertNil(library.bundledUpdateErrors[original.id])
        XCTAssertNotEqual(try Data(contentsOf: modelURL), before)
    }

    private func installedModelURL(_ avatar: OpenClamAvatarDescriptor) throws -> URL {
        guard case let .installedFile(url)? = avatar.asset(.model) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private func bundledUpdateFixture(sourceHash: String) throws -> URL {
        let root = try temporaryDirectory()
        let archive = try makeModelArchive { _, model in
            var document = Self.document(targets: Self.oculusTargets)
            document["extras"] = ["wardrobe-test": true]
            model = Self.makeGLB(document)
        }
        let targetStore = OpenClamAvatarPackageStore(storageRoot: try temporaryDirectory())
        let target = try targetStore.installArchive(at: archive)
        let targetURL = try installedModelURL(target)
        let update = OpenClamBundledAvatarUpdate(
            id: "tia-test", file: "tia-test.avtr",
            packageSHA256: try OpenClamBundledAvatarUpdate.sha256(at: archive),
            sourceModelSHA256: [sourceHash],
            targetModelSHA256: try OpenClamBundledAvatarUpdate.sha256(at: targetURL))
        try FileManager.default.copyItem(at: archive, to: root.appendingPathComponent(update.file))
        try JSONEncoder().encode([update]).write(to: root.appendingPathComponent("updates.json"))
        return root
    }

    func testWardrobeChoicesPersistPerAvatarAndBodyPosesClearHandOverrides() throws {
        let name = "OpenClam3DOptionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OpenClam3DOptionsStore(defaults: defaults)
        store.receive(["poses": [["id": "heart", "label": "Heart", "group": "body"],
                                  ["id": "fist", "label": "Fist", "group": "rightHand"]],
                       "outfits": [["id": "casual", "label": "Casual"]],
                       "props": [["id": "prop", "label": "Prop", "pose": "heart"]]], for: "character")
        store.select("casual", group: "outfit", for: "character")
        store.select("fist", group: "rightHand", for: "character")
        store.select("heart", group: "body", for: "character")
        XCTAssertNil(store.selection(for: "character")["rightHand"])
        XCTAssertEqual(store.selection(for: "character")["outfit"], "casual")
        XCTAssertEqual(OpenClam3DOptionsStore(defaults: defaults).selection(for: "character")["body"], "heart")
        XCTAssertTrue(store.selection(for: "another").isEmpty)
        store.select("unknown", group: "body", for: "character")
        XCTAssertEqual(store.selection(for: "character")["body"], "heart")
        store.select("prop", group: "prop", for: "character")
        XCTAssertFalse(store.enabled("playTransitions", for: "character"), "Equipping a prop preserves an explicit pause")
        store.setEnabled(true, key: "playTransitions", for: "character")
        XCTAssertEqual(store.selection(for: "character")["prop"], "prop", "Playback must keep the equipped prop")
        store.select("", group: "prop", for: "character")
        store.select("prop", group: "prop", for: "character")
        let reopened = OpenClam3DOptionsStore(defaults: defaults)
        XCTAssertTrue(reopened.enabled("playTransitions", for: "character"), "Equipping a prop must keep playback on")
        XCTAssertEqual(reopened.selection(for: "character")["prop"], "prop")
        store.reset("character")
        XCTAssertNil(store.selection(for: "character")["body"])
        XCTAssertFalse(store.enabled("playTransitions", for: "character"))
    }
}
