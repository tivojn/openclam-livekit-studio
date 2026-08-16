import SwiftUI

/// Descriptor-driven counterpart to CaptainAyerAvatarStage. It deliberately
/// owns only face gaze/tap behavior; scale, pinch, 10–100% opacity, and true
/// hide/pass-through remain the overlay's responsibility.
@MainActor
struct OpenClamCatalogAvatarStage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var touchStart: CGPoint?
    @State private var touchExceededTapSlop = false

    enum Presentation: Sendable {
        case compact
        case expanded

        func crop(for avatar: OpenClamAvatarDescriptor) -> CGRect {
            let body = avatar.geometry.bodySize.cgSize
            switch self {
            case .expanded:
                return CGRect(origin: .zero, size: body)
            case .compact:
                let face = avatar.geometry.faceBoundsInBody.cgRect
                let height = min(body.height, max(face.height * 5.8, body.height * 0.47))
                let width = min(body.width, height * 0.677)
                let x = min(max(0, face.midX - width / 2), max(0, body.width - width))
                return CGRect(x: x, y: 0, width: width, height: height)
            }
        }
    }

    let avatar: OpenClamAvatarDescriptor
    @ObservedObject var controller: CaptainAyerLipSyncController
    @ObservedObject var reactions: CaptainAyerFaceReactionController
    @ObservedObject var faceMirror: CaptainAyerFaceMirrorController
    let presentation: Presentation
    let allowsGazeTracking: Bool
    let onInteraction: () -> Void
    private let imageStore: OpenClamAvatarAssetStore

    init(
        avatar: OpenClamAvatarDescriptor,
        controller: CaptainAyerLipSyncController,
        reactions: CaptainAyerFaceReactionController,
        faceMirror: CaptainAyerFaceMirrorController,
        presentation: Presentation = .expanded,
        allowsGazeTracking: Bool = true,
        imageStore: OpenClamAvatarAssetStore? = nil,
        onInteraction: @escaping () -> Void = {}
    ) {
        self.avatar = avatar
        self.controller = controller
        self.reactions = reactions
        self.faceMirror = faceMirror
        self.presentation = presentation
        self.allowsGazeTracking = allowsGazeTracking
        self.imageStore = imageStore ?? .shared
        self.onInteraction = onInteraction
    }

    var body: some View {
        let crop = presentation.crop(for: avatar)
        GeometryReader { proxy in
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 30.0,
                    paused: reduceMotion || !(
                        controller.isSpeaking
                            || reactions.isAnimating
                            || reactions.isGazeAnimating
                            || faceMirror.isCapturing
                    )
                )
            ) { context in
                let mirrorsFace = faceMirror.isCapturing
                let mirroredExpression = faceMirror.expression
                OpenClamCatalogAvatarArtwork(
                    avatar: avatar,
                    imageStore: imageStore,
                    state: mirrorsFace
                        ? mirroredExpression.mouthRenderState
                        : (reduceMotion ? .idle : controller.renderState(at: context.date)),
                    reaction: mirrorsFace
                        ? CaptainAyerFaceMirrorRenderMapper.renderState(
                            for: mirroredExpression,
                            reduceMotion: reduceMotion
                        )
                        : (reduceMotion
                            ? reactions.reducedMotionRenderState(at: context.date)
                            : reactions.renderState(at: context.date)),
                    showsReactionMouth: !mirrorsFace && !controller.isSpeaking,
                    crop: crop
                )
            }
            .contentShape(Rectangle())
            .simultaneousGesture(faceGesture(stageSize: proxy.size, crop: crop))
        }
        .aspectRatio(crop.width / crop.height, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(avatar.displayName)
        .accessibilityValue(accessibilityValue)
        .accessibilityAction(named: "React") {
            reactions.flourish()
            onInteraction()
        }
        .onChange(of: allowsGazeTracking) { _, enabled in
            if !enabled { reactions.cancelGaze() }
        }
        .onDisappear {
            reactions.cancelGaze()
        }
    }

    private func faceGesture(stageSize: CGSize, crop: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard allowsGazeTracking else {
                    reactions.cancelGaze()
                    return
                }
                if touchStart == nil {
                    touchStart = value.startLocation
                    touchExceededTapSlop = false
                }
                if hypot(
                    value.location.x - value.startLocation.x,
                    value.location.y - value.startLocation.y
                ) > 4 {
                    touchExceededTapSlop = true
                }
                reactions.updateGaze(
                    toward: normalizedGazeDirection(
                        for: value.location,
                        stageSize: stageSize,
                        crop: crop
                    )
                )
                onInteraction()
            }
            .onEnded { value in
                defer {
                    touchStart = nil
                    touchExceededTapSlop = false
                }
                guard allowsGazeTracking else {
                    reactions.cancelGaze()
                    return
                }
                reactions.releaseGaze(reduceMotion: reduceMotion)
                if !touchExceededTapSlop {
                    reactions.react(
                        atNormalizedFacePoint: normalizedFacePoint(
                            for: value.location,
                            stageSize: stageSize,
                            crop: crop
                        )
                    )
                }
                onInteraction()
            }
    }

    private func normalizedGazeDirection(
        for location: CGPoint,
        stageSize: CGSize,
        crop: CGRect
    ) -> CGPoint {
        guard let placement = placement(stageSize: stageSize, crop: crop) else { return .zero }
        let anchor = avatar.geometry.eyeAnchorInBody.cgPoint
        let eye = CGPoint(
            x: placement.origin.x + anchor.x * placement.scale,
            y: placement.origin.y + anchor.y * placement.scale
        )
        return CGPoint(
            x: tanh((location.x - eye.x) / 90),
            y: tanh((location.y - eye.y) / 130)
        )
    }

    private func normalizedFacePoint(
        for location: CGPoint,
        stageSize: CGSize,
        crop: CGRect
    ) -> CGPoint {
        guard let placement = placement(stageSize: stageSize, crop: crop) else {
            return CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        }
        let bodyPoint = CGPoint(
            x: (location.x - placement.origin.x) / placement.scale,
            y: (location.y - placement.origin.y) / placement.scale
        )
        let face = avatar.geometry.faceBoundsInBody.cgRect
        return CGPoint(
            x: (bodyPoint.x - face.minX) / face.width,
            y: (bodyPoint.y - face.minY) / face.height
        )
    }

    private func placement(stageSize: CGSize, crop: CGRect) -> (origin: CGPoint, scale: CGFloat)? {
        let scale = min(stageSize.width / crop.width, stageSize.height / crop.height)
        guard scale.isFinite, scale > 0 else { return nil }
        return (
            CGPoint(
                x: (stageSize.width - crop.width * scale) / 2 - crop.minX * scale,
                y: (stageSize.height - crop.height * scale) / 2 - crop.minY * scale
            ),
            scale
        )
    }

    private var accessibilityValue: String {
        if faceMirror.isCapturing {
            return faceMirror.isTrackingFace ? "Mirroring your face" : "Looking for your face"
        }
        if controller.isSpeaking { return "Speaking" }
        if reactions.isAnimating { return "Reacting" }
        return "Idle"
    }
}

@MainActor
private struct OpenClamCatalogAvatarArtwork: View {
    let avatar: OpenClamAvatarDescriptor
    let imageStore: OpenClamAvatarAssetStore
    let state: CaptainAyerAvatarRenderState
    let reaction: CaptainAyerFaceReactionRenderState
    let showsReactionMouth: Bool
    let crop: CGRect

    var body: some View {
        GeometryReader { proxy in
            let body = avatar.geometry.bodySize.cgSize
            let scale = min(proxy.size.width / crop.width, proxy.size.height / crop.height)
            let origin = CGPoint(
                x: (proxy.size.width - crop.width * scale) / 2 - crop.minX * scale,
                y: (proxy.size.height - crop.height * scale) / 2 - crop.minY * scale
            )
            let transform = avatar.geometry.faceTransform
            let faceCenter = avatar.geometry.faceCenterInBody.cgPoint

            ZStack(alignment: .topLeading) {
                OpenClamAvatarAssetImage(
                    image: imageStore.image(for: avatar, role: .body)
                )
                .frame(width: body.width * scale, height: body.height * scale)
                .offset(x: origin.x, y: origin.y)

                facePlates
                    .frame(
                        width: 1_024 * transform.uniformScale * scale,
                        height: 1_024 * transform.uniformScale * scale
                    )
                    .rotation3DEffect(
                        .degrees(reaction.headPose.pitch * 3.2),
                        axis: (x: 1, y: 0, z: 0),
                        perspective: 0.22
                    )
                    .rotation3DEffect(
                        .degrees(-reaction.headPose.yaw * 4.0),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.22
                    )
                    .rotationEffect(
                        .degrees(transform.rotationDegrees + reaction.headPose.roll * 3.4)
                    )
                    .offset(
                        x: reaction.headPose.yaw * 2.4 * scale,
                        y: reaction.headPose.pitch * 1.8 * scale
                    )
                    .position(
                        x: origin.x + faceCenter.x * scale,
                        y: origin.y + faceCenter.y * scale
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Body, face, and reaction plates become one alpha surface before
            // the overlay dims it. Without this group, translucent face plates
            // blend independently and expose the head/body join.
            .compositingGroup()
        }
    }

    private var facePlates: some View {
        ZStack {
            visemeImage(state.previous)
                .opacity(1 - state.blend)
            visemeImage(state.current)
                .opacity(state.blend)

            if showsReactionMouth, reaction.wideMouthOpacity > 0 {
                assetImage(.viseme(.wide))
                    .opacity(reaction.wideMouthOpacity)
            }

            OpenClamCatalogReactionLayers(
                avatar: avatar,
                imageStore: imageStore,
                state: reaction
            )
        }
        .mask {
            assetImage(.headMask)
        }
        .compositingGroup()
    }

    private func visemeImage(_ viseme: CaptainAyerViseme) -> some View {
        assetImage(.viseme(viseme.catalogViseme))
    }

    private func assetImage(_ role: OpenClamAvatarAssetRole) -> some View {
        OpenClamAvatarAssetImage(image: imageStore.image(for: avatar, role: role))
    }
}

@MainActor
private struct OpenClamCatalogReactionLayers: View {
    let avatar: OpenClamAvatarDescriptor
    let imageStore: OpenClamAvatarAssetStore
    let state: CaptainAyerFaceReactionRenderState

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let frame = state.leftBrowFrame {
                    verticalSprite(
                        role: .browLeft,
                        frame: frame,
                        geometry: avatar.geometry.leftBrow,
                        in: proxy.size
                    )
                }
                if let frame = state.rightBrowFrame {
                    verticalSprite(
                        role: .browRight,
                        frame: frame,
                        geometry: avatar.geometry.rightBrow,
                        in: proxy.size
                    )
                }
                if let frame = state.gazeFrame {
                    gridSprite(
                        role: .gazeLeftAtlas,
                        frame: frame,
                        geometry: avatar.geometry.leftGaze,
                        in: proxy.size
                    )
                    gridSprite(
                        role: .gazeRightAtlas,
                        frame: frame,
                        geometry: avatar.geometry.rightGaze,
                        in: proxy.size
                    )
                }
                if let eye = state.leftEye {
                    eyeLayers(
                        eye,
                        role: .eyeLeft,
                        geometry: avatar.geometry.leftEye,
                        in: proxy.size
                    )
                }
                if let eye = state.rightEye {
                    eyeLayers(
                        eye,
                        role: .eyeRight,
                        geometry: avatar.geometry.rightEye,
                        in: proxy.size
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func eyeLayers(
        _ eye: CaptainAyerEyeReactionState,
        role: OpenClamAvatarAssetRole,
        geometry: OpenClamAvatarSpriteGeometry,
        in size: CGSize
    ) -> some View {
        if let lowerFrame = eye.lowerFrame {
            verticalSprite(role: role, frame: lowerFrame, geometry: geometry, in: size)
        }
        verticalSprite(role: role, frame: eye.upperFrame, geometry: geometry, in: size)
            .opacity(eye.upperOpacity)
    }

    private func verticalSprite(
        role: OpenClamAvatarAssetRole,
        frame: Int,
        geometry: OpenClamAvatarSpriteGeometry,
        in size: CGSize
    ) -> some View {
        let scaleX = size.width / 1_024
        let scaleY = size.height / 1_024
        return OpenClamAvatarVerticalSpriteFrame(
            image: imageStore.image(for: avatar, role: role),
            frame: frame,
            frameCount: geometry.frameCount
        )
        .frame(width: geometry.box.width * scaleX, height: geometry.box.height * scaleY)
        .offset(x: geometry.box.x * scaleX, y: geometry.box.y * scaleY)
    }

    private func gridSprite(
        role: OpenClamAvatarAssetRole,
        frame: Int,
        geometry: OpenClamAvatarSpriteGeometry,
        in size: CGSize
    ) -> some View {
        let scaleX = size.width / 1_024
        let scaleY = size.height / 1_024
        return OpenClamAvatarGridSpriteFrame(
            image: imageStore.image(for: avatar, role: role),
            frame: frame,
            columns: geometry.columns,
            rows: geometry.rows
        )
        .frame(width: geometry.box.width * scaleX, height: geometry.box.height * scaleY)
        .offset(x: geometry.box.x * scaleX, y: geometry.box.y * scaleY)
    }
}

@MainActor
private struct OpenClamAvatarAssetImage: View {
    let image: UIImage?

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Color.clear
        }
    }
}

@MainActor
private struct OpenClamAvatarVerticalSpriteFrame: View {
    let image: UIImage?
    let frame: Int
    let frameCount: Int

    var body: some View {
        GeometryReader { proxy in
            OpenClamAvatarAssetImage(image: image)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height * CGFloat(frameCount),
                    alignment: .top
                )
                .offset(y: -CGFloat(clampedFrame) * proxy.size.height)
        }
        .clipped()
    }

    private var clampedFrame: Int {
        min(max(0, frame), max(0, frameCount - 1))
    }
}

@MainActor
private struct OpenClamAvatarGridSpriteFrame: View {
    let image: UIImage?
    let frame: Int
    let columns: Int
    let rows: Int

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, columns * rows)
            let clamped = min(max(0, frame), count - 1)
            let column = clamped % max(1, columns)
            let row = clamped / max(1, columns)
            OpenClamAvatarAssetImage(image: image)
                .frame(
                    width: proxy.size.width * CGFloat(max(1, columns)),
                    height: proxy.size.height * CGFloat(max(1, rows)),
                    alignment: .topLeading
                )
                .offset(
                    x: -CGFloat(column) * proxy.size.width,
                    y: -CGFloat(row) * proxy.size.height
                )
        }
        .clipped()
    }
}

private extension CaptainAyerViseme {
    var catalogViseme: OpenClamAvatarViseme {
        switch self {
        case .silence: .silence
        case .labiodental: .labiodental
        case .dental: .dental
        case .alveolar: .nasal
        case .rhotic: .rhotic
        case .open: .open
        case .wide: .wide
        case .narrow: .nearClose
        case .rounded: .rounded
        }
    }
}
