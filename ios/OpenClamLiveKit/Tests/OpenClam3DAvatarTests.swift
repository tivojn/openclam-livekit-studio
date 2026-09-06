import CryptoKit
import Foundation
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
        mesh.geometry?.materials = [glass, mask]
        scene.rootNode.addChildNode(mesh)
        _ = OpenClam3DAvatarRig(scene: scene, frame: CGSize(width: 1024, height: 1536), targetNames: [:])
        XCTAssertEqual(glass.transparency, 0.65)
        XCTAssertEqual(glass.blendMode, .alpha)
        XCTAssertEqual(glass.transparencyMode, .dualLayer)
        XCTAssertFalse(glass.writesToDepthBuffer)
        XCTAssertFalse(glass.isDoubleSided)
        XCTAssertEqual(mask.blendMode, .replace)
        XCTAssertEqual(mask.shaderModifiers?[.fragment], cutoff)
        XCTAssertFalse(mask.isDoubleSided)
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

    private static func makeGLB(_ document: [String: Any]) -> Data {
        var payload = try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        while payload.count % 4 != 0 { payload.append(0x20) }
        let binary = Data(repeating: 0, count: 4)
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
