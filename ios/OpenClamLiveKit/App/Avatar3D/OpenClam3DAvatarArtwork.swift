import SceneKit
import SwiftUI

/// Loads one package's model once per process and keeps the rig alive across
/// SwiftUI re-mounts of the stage.
@MainActor
final class OpenClam3DAvatarLoader: ObservableObject {
    @Published private(set) var rig: OpenClam3DAvatarRig?
    @Published private(set) var failure: String?
    let smoother = OpenClam3DPoseSmoother()
    private var loadedID: String?
    private static var cache: [String: OpenClam3DAvatarRig] = [:]

    func load(_ avatar: OpenClamAvatarDescriptor) async {
        guard loadedID != avatar.id else { return }
        loadedID = avatar.id
        failure = nil
        if let cached = Self.cache[avatar.id] {
            rig = cached
            return
        }
        guard case let .installedFile(url)? = avatar.asset(.model) else {
            failure = "This avatar has no 3D model."
            return
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let summary = try OpenClam3DGLBReader.summary(of: data)
            let frame = avatar.geometry.bodySize.cgSize
            let loaded = try await OpenClam3DAvatarRig.load(
                modelURL: url,
                frame: frame,
                targetNames: summary.targetNames
            )
            guard loadedID == avatar.id else { return }
            Self.cache[avatar.id] = loaded
            rig = loaded
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// The 3D replacement for the body/face artwork inside
/// `OpenClamCatalogAvatarStage`. It draws the same logical crop the 2D stage
/// would, so presentation, gestures and opacity behave identically.
@MainActor
struct OpenClam3DAvatarArtwork: View {
    let avatar: OpenClamAvatarDescriptor
    @ObservedObject var controller: CaptainAyerLipSyncController
    @ObservedObject var reactions: CaptainAyerFaceReactionController
    @ObservedObject var faceMirror: CaptainAyerFaceMirrorController
    let crop: CGRect
    let reduceMotion: Bool
    @StateObject private var loader = OpenClam3DAvatarLoader()

    var body: some View {
        GeometryReader { proxy in
            if let rig = loader.rig {
                TimelineView(
                    .animation(
                        minimumInterval: OpenClam3DAvatarFramePolicy.minimumInterval(
                            speaking: controller.isExpressionAnimating || faceMirror.isCapturing,
                            reduceMotion: reduceMotion
                        ),
                        paused: false
                    )
                ) { context in
                    OpenClam3DSceneView(
                        rig: rig,
                        pose: pose(at: context.date),
                        visibleRect: Self.visibleRect(crop: crop, in: proxy.size)
                    )
                }
            } else {
                OpenClam3DAvatarPlaceholder(
                    avatar: avatar,
                    crop: crop,
                    message: loader.failure
                )
            }
        }
        .task(id: avatar.id) { await loader.load(avatar) }
        .allowsHitTesting(false)
    }

    /// The 2D stage letterboxes `crop` into the stage with `min` scaling. The
    /// scene shows the same crop widened/heightened to the stage aspect so
    /// nothing is stretched and the face lands where `faceBounds` says.
    static func visibleRect(crop: CGRect, in size: CGSize) -> CGRect {
        guard crop.width > 0, crop.height > 0, size.width > 0, size.height > 0 else { return crop }
        let scale = min(size.width / crop.width, size.height / crop.height)
        let width = size.width / scale, height = size.height / scale
        return CGRect(
            x: crop.midX - width / 2,
            y: crop.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func pose(at date: Date) -> OpenClam3DAvatarPose {
        var pose = OpenClam3DAvatarPose()
        let time = date.timeIntervalSinceReferenceDate
        pose.time = time
        pose.reduceMotion = reduceMotion
        if faceMirror.isCapturing {
            let expression = faceMirror.expression
            pose.visemeWeights = loader.smoother.smoothedVisemeWeights(
                target: expression.mouthRenderState.visemeTargets, at: time
            )
            pose.articulation = 1
            pose.blinkLeft = expression.leftBlink
            pose.blinkRight = expression.rightBlink
            pose.brow = min(1, max(-1, (expression.leftBrowRaise + expression.rightBrowRaise) / 2))
            pose.gazeX = min(1, max(-1, Double(expression.gaze.x)))
            pose.gazeY = min(1, max(-1, Double(expression.gaze.y)))
            pose.headYaw = expression.headPose.yaw
            pose.headPitch = expression.headPose.pitch
            pose.headRoll = expression.headPose.roll
            pose.speaking = expression.mouthViseme != .silence
            return pose
        }
        let render = reduceMotion ? .idle : controller.renderState(at: date)
        pose.visemeWeights = loader.smoother.smoothedVisemeWeights(
            target: render.visemeTargets, at: time
        )
        pose.speaking = controller.isExpressionAnimating
        pose.articulation = pose.speaking ? 1 : 0.85
        let reaction = reduceMotion
            ? reactions.reducedMotionRenderState(at: date)
            : reactions.renderState(at: date)
        let spoken = controller.expressionRenderState(at: date, reduceMotion: reduceMotion)
        let merged = reaction.mergingSpeech(spoken)
        pose.blinkLeft = Self.closure(of: merged.leftEye)
        pose.blinkRight = Self.closure(of: merged.rightEye)
        if let frame = merged.gazeFrame {
            let columns = 25, rows = 11
            let column = Double(frame % columns), row = Double(frame / columns)
            pose.gazeX = (column - Double(columns / 2)) / Double(columns / 2)
            pose.gazeY = (row - Double(rows / 2)) / Double(rows / 2)
        }
        let browOffset = ((merged.leftBrowOffset ?? 0) + (merged.rightBrowOffset ?? 0)) / 2
        // Atlas offsets are pixels of upward brow travel (negative is raised).
        pose.brow = min(1, max(-1, -browOffset / 12))
        let layers = merged.expressionLayers
        pose.smile = min(1, max(0, layers.smile))
        pose.sad = min(1, max(0, layers.sorrowMouth))
        pose.surprise = min(1, max(0, layers.horrorMouth))
        pose.anger = min(1, max(0, layers.angerMouth))
        pose.headYaw = merged.headPose.yaw
        pose.headPitch = merged.headPose.pitch
        pose.headRoll = merged.headPose.roll
        return pose
    }

    private static func closure(of eye: CaptainAyerEyeReactionState?) -> Double {
        guard let eye else { return 0 }
        // Upper-lid frames run from barely lowered (0) to closed (7).
        return min(1, max(0, Double(eye.upperFrame + 1) / 8)) * min(1, max(0, eye.upperOpacity))
    }
}

enum OpenClam3DAvatarFramePolicy {
    static func minimumInterval(speaking: Bool, reduceMotion: Bool) -> TimeInterval {
        if reduceMotion { return 1.0 / 4 }
        return speaking ? 1.0 / 60 : 1.0 / 30
    }
}

/// The package thumbnail, letterboxed like the body plate, while the model
/// decodes (or if it cannot).
private struct OpenClam3DAvatarPlaceholder: View {
    let avatar: OpenClamAvatarDescriptor
    let crop: CGRect
    let message: String?

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / max(1, crop.width), proxy.size.height / max(1, crop.height))
            let face = avatar.geometry.faceBoundsInBody.cgRect
            let side = max(face.width, face.height) * 2.2
            ZStack {
                if let image = OpenClamAvatarAssetStore.shared.image(for: avatar, role: .thumbnail) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: side * scale, height: side * scale)
                        .position(
                            x: (face.midX - crop.minX) * scale,
                            y: (face.midY + face.height * 0.05 - crop.minY) * scale
                        )
                        .opacity(0.9)
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: proxy.size.width * 0.8)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.9)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }
}

private struct OpenClam3DSceneView: UIViewRepresentable {
    let rig: OpenClam3DAvatarRig
    let pose: OpenClam3DAvatarPose
    let visibleRect: CGRect

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = rig.scene
        view.pointOfView = rig.cameraNode
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.isJitteringEnabled = false
        view.preferredFramesPerSecond = 60
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if view.scene !== rig.scene {
            view.scene = rig.scene
            view.pointOfView = rig.cameraNode
        }
        rig.setCrop(visibleRect)
        rig.apply(pose)
        view.setNeedsDisplay()
    }
}
