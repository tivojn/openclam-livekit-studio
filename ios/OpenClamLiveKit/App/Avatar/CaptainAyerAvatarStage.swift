import SwiftUI

@MainActor
struct CaptainAyerAvatarStage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var touchStart: CGPoint?
    @State private var touchExceededTapSlop = false

    enum Presentation: Sendable {
        /// Head-and-torso crop suitable for a conversation overlay.
        case compact
        /// The complete transparent full-body avatar.
        case expanded

        fileprivate var crop: CGRect {
            switch self {
            case .compact:
                CGRect(x: 205, y: 0, width: 535, height: 790)
            case .expanded:
                CGRect(x: 0, y: 0, width: 941, height: 1672)
            }
        }
    }

    @ObservedObject var controller: CaptainAyerLipSyncController
    @ObservedObject var reactions: CaptainAyerFaceReactionController
    @ObservedObject var faceMirror: CaptainAyerFaceMirrorController
    var presentation: Presentation
    var allowsGazeTracking: Bool
    var onInteraction: () -> Void

    init(
        controller: CaptainAyerLipSyncController,
        reactions: CaptainAyerFaceReactionController,
        faceMirror: CaptainAyerFaceMirrorController,
        presentation: Presentation = .expanded,
        allowsGazeTracking: Bool = true,
        onInteraction: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.reactions = reactions
        self.faceMirror = faceMirror
        self.presentation = presentation
        self.allowsGazeTracking = allowsGazeTracking
        self.onInteraction = onInteraction
    }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 30.0,
                    paused: reduceMotion || !(
                        controller.isExpressionAnimating
                            || reactions.isAnimating
                            || reactions.isGazeAnimating
                            || reactions.isAmbientAnimating
                            || faceMirror.isCapturing
                    )
                )
            ) { context in
                let mirrorsFace = faceMirror.isCapturing
                let mirroredExpression = faceMirror.expression
                let localReaction = reduceMotion
                    ? reactions.reducedMotionRenderState(at: context.date)
                    : reactions.renderState(at: context.date)
                let spokenReaction = controller.expressionRenderState(
                    at: context.date,
                    reduceMotion: reduceMotion
                )
                CaptainAyerAvatarArtwork(
                    state: mirrorsFace
                        ? mirroredExpression.mouthRenderState
                        : (reduceMotion ? .idle : controller.renderState(at: context.date)),
                    reaction: mirrorsFace
                        ? CaptainAyerFaceMirrorRenderMapper.renderState(
                            for: mirroredExpression,
                            reduceMotion: reduceMotion
                        )
                        : localReaction.mergingSpeech(spokenReaction),
                    showsReactionMouth: !mirrorsFace
                        && !controller.isExpressionAnimating,
                    crop: presentation.crop
                )
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
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
                        if hypot(value.translation.width, value.translation.height)
                            > CaptainAyerAvatarGesturePolicy.tapSlop {
                            touchExceededTapSlop = true
                        }
                        reactions.updateGaze(
                            toward: normalizedGazeDirection(
                                for: value.location,
                                stageSize: proxy.size
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
                            let point = normalizedFacePoint(
                                for: value.location,
                                stageSize: proxy.size
                            )
                            let didReactToFace = reactions.react(
                                atNormalizedFacePoint: point
                            )
                            if !didReactToFace {
                                reactions.react(
                                    atNormalizedBodyPoint: normalizedBodyPoint(
                                        for: value.location,
                                        stageSize: proxy.size
                                    )
                                )
                            }
                        }
                        onInteraction()
                    }
            )
        }
        .aspectRatio(presentation.crop.width / presentation.crop.height, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Captain Ayer")
        .accessibilityValue(
            faceMirror.isCapturing
                ? (faceMirror.isTrackingFace ? "Mirroring your face" : "Looking for your face")
                : (controller.isSpeaking
                    ? "Speaking"
                    : (reactions.isAnimating ? "Reacting" : "Idle"))
        )
        .accessibilityAction(named: "React") {
            reactions.flourish()
            onInteraction()
        }
        .onAppear(perform: synchronizeAmbientMotion)
        .onChange(of: reduceMotion) { _, _ in
            synchronizeAmbientMotion()
        }
        .onChange(of: faceMirror.isCapturing) { _, _ in
            synchronizeAmbientMotion()
        }
        .onChange(of: allowsGazeTracking) { _, enabled in
            if !enabled { reactions.cancelGaze() }
        }
        .onDisappear {
            reactions.stopAmbientMotion()
            reactions.cancelGaze()
        }
    }

    private func normalizedGazeDirection(
        for location: CGPoint,
        stageSize: CGSize
    ) -> CGPoint {
        let crop = presentation.crop
        let scale = min(stageSize.width / crop.width, stageSize.height / crop.height)
        guard scale.isFinite, scale > 0 else { return .zero }
        let origin = CGPoint(
            x: (stageSize.width - crop.width * scale) / 2 - crop.minX * scale,
            y: (stageSize.height - crop.height * scale) / 2 - crop.minY * scale
        )
        let faceBounds = CGRect(x: 426, y: 119, width: 114, height: 137)
        let eyeMidpoint = CGPoint(
            x: origin.x + (faceBounds.minX + faceBounds.width * 0.4972) * scale,
            y: origin.y + (faceBounds.minY + faceBounds.height * 0.2647) * scale
        )
        return CGPoint(
            x: tanh((location.x - eyeMidpoint.x) / 90),
            y: tanh((location.y - eyeMidpoint.y) / 130)
        )
    }

    private func normalizedFacePoint(
        for location: CGPoint,
        stageSize: CGSize
    ) -> CGPoint {
        let crop = presentation.crop
        let scale = min(stageSize.width / crop.width, stageSize.height / crop.height)
        guard scale.isFinite, scale > 0 else {
            return CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        }
        let origin = CGPoint(
            x: (stageSize.width - crop.width * scale) / 2 - crop.minX * scale,
            y: (stageSize.height - crop.height * scale) / 2 - crop.minY * scale
        )
        let bodyPoint = CGPoint(
            x: (location.x - origin.x) / scale,
            y: (location.y - origin.y) / scale
        )
        let faceBounds = CGRect(x: 426, y: 119, width: 114, height: 137)
        return CGPoint(
            x: (bodyPoint.x - faceBounds.minX) / faceBounds.width,
            y: (bodyPoint.y - faceBounds.minY) / faceBounds.height
        )
    }

    private func normalizedBodyPoint(
        for location: CGPoint,
        stageSize: CGSize
    ) -> CGPoint {
        let crop = presentation.crop
        let scale = min(stageSize.width / crop.width, stageSize.height / crop.height)
        guard scale.isFinite, scale > 0 else {
            return CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        }
        let origin = CGPoint(
            x: (stageSize.width - crop.width * scale) / 2 - crop.minX * scale,
            y: (stageSize.height - crop.height * scale) / 2 - crop.minY * scale
        )
        return CGPoint(
            x: ((location.x - origin.x) / scale) / 941,
            y: ((location.y - origin.y) / scale) / 1_672
        )
    }

    private func synchronizeAmbientMotion() {
        if reduceMotion || faceMirror.isCapturing {
            reactions.stopAmbientMotion()
        } else {
            reactions.startAmbientMotion()
        }
    }
}

@MainActor
private struct CaptainAyerAvatarArtwork: View {
    private enum Geometry {
        static let bodySize = CGSize(width: 941, height: 1672)
        static let faceSourceSize = CGSize(width: 1024, height: 1024)

        // Local body-coordinate transform from Captain Ayer's bundled rig.
        static let faceScale: CGFloat = 0.2375036
        static let faceRotation = Angle.degrees(-0.1452)
        static let faceCenter = CGPoint(x: 482.55, y: 150.64)
    }

    let state: CaptainAyerAvatarRenderState
    let reaction: CaptainAyerFaceReactionRenderState
    let showsReactionMouth: Bool
    let crop: CGRect

    var body: some View {
        GeometryReader { proxy in
            let scale = min(
                proxy.size.width / crop.width,
                proxy.size.height / crop.height
            )
            let origin = CGPoint(
                x: (proxy.size.width - crop.width * scale) / 2 - crop.minX * scale,
                y: (proxy.size.height - crop.height * scale) / 2 - crop.minY * scale
            )

            ZStack(alignment: .topLeading) {
                Image("CaptainAyerBody")
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: Geometry.bodySize.width * scale,
                        height: Geometry.bodySize.height * scale
                    )
                    .offset(x: origin.x, y: origin.y)

                facePlates
                    .frame(
                        width: Geometry.faceSourceSize.width * Geometry.faceScale * scale,
                        height: Geometry.faceSourceSize.height * Geometry.faceScale * scale
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
                        .degrees(
                            Geometry.faceRotation.degrees
                                + reaction.headPose.roll * 3.4
                        )
                    )
                    .offset(
                        x: reaction.headPose.yaw * 2.4 * scale,
                        y: reaction.headPose.pitch * 1.8 * scale
                    )
                    .position(
                        x: origin.x + Geometry.faceCenter.x * scale,
                        y: origin.y + Geometry.faceCenter.y * scale
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private var facePlates: some View {
        ZStack {
            Image(state.previous.assetName)
                .resizable()
                .interpolation(.high)
                .opacity(1 - state.blend)
            Image(state.current.assetName)
                .resizable()
                .interpolation(.high)
                .opacity(state.blend)

            if showsReactionMouth, reaction.wideMouthOpacity > 0 {
                Image("CaptainAyerVisemeE")
                    .resizable()
                    .interpolation(.high)
                    .opacity(reaction.wideMouthOpacity)
            }

            CaptainAyerFaceReactionLayers(state: reaction)
        }
        .mask {
            Image("CaptainAyerHeadMask")
                .resizable()
                .interpolation(.high)
        }
        .compositingGroup()
    }
}

@MainActor
private struct CaptainAyerFaceReactionLayers: View {
    private struct SpriteBox {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    private static let faceSize: CGFloat = 1024
    private static let leftEyeBox = SpriteBox(x: 524, y: 470, width: 182, height: 104)
    private static let rightEyeBox = SpriteBox(x: 320, y: 471, width: 176, height: 105)
    private static let leftBrowBox = SpriteBox(x: 530, y: 436, width: 213, height: 104)
    private static let rightBrowBox = SpriteBox(x: 281, y: 439, width: 214, height: 102)
    private static let leftGazeBox = SpriteBox(x: 557, y: 501, width: 115, height: 59)
    private static let rightGazeBox = SpriteBox(x: 353, y: 502, width: 115, height: 61)

    let state: CaptainAyerFaceReactionRenderState

    var body: some View {
        GeometryReader { proxy in
            let leftBrowFrame = OpenClamAvatarBrowFramePolicy.frame(
                fallback: state.leftBrowFrame,
                offset: state.leftBrowOffset,
                squeeze: state.browSqueezeOffset,
                expression: nil
            )
            let rightBrowFrame = OpenClamAvatarBrowFramePolicy.frame(
                fallback: state.rightBrowFrame,
                offset: state.rightBrowOffset,
                squeeze: state.browSqueezeOffset,
                expression: nil
            )
            ZStack(alignment: .topLeading) {
                if let frame = leftBrowFrame {
                    sprite(
                        assetName: "CaptainAyerBrowLeft",
                        frame: frame,
                        frameCount: 42,
                        box: Self.leftBrowBox,
                        in: proxy.size
                    )
                }
                if let frame = rightBrowFrame {
                    sprite(
                        assetName: "CaptainAyerBrowRight",
                        frame: frame,
                        frameCount: 42,
                        box: Self.rightBrowBox,
                        in: proxy.size
                    )
                }
                if let frame = state.gazeFrame {
                    gridSprite(
                        assetName: "CaptainAyerGazeLeftAtlas",
                        frame: frame,
                        columns: 25,
                        rows: 11,
                        box: Self.leftGazeBox,
                        in: proxy.size
                    )
                    gridSprite(
                        assetName: "CaptainAyerGazeRightAtlas",
                        frame: frame,
                        columns: 25,
                        rows: 11,
                        box: Self.rightGazeBox,
                        in: proxy.size
                    )
                }
                if let eye = state.leftEye {
                    eyeLayers(
                        eye,
                        assetName: "CaptainAyerEyeLeft",
                        box: Self.leftEyeBox,
                        in: proxy.size
                    )
                }
                if let eye = state.rightEye {
                    eyeLayers(
                        eye,
                        assetName: "CaptainAyerEyeRight",
                        box: Self.rightEyeBox,
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
        assetName: String,
        box: SpriteBox,
        in size: CGSize
    ) -> some View {
        if let lowerFrame = eye.lowerFrame {
            sprite(
                assetName: assetName,
                frame: lowerFrame,
                frameCount: 8,
                box: box,
                in: size
            )
        }
        sprite(
            assetName: assetName,
            frame: eye.upperFrame,
            frameCount: 8,
            box: box,
            in: size
        )
        .opacity(eye.upperOpacity)
    }

    private func sprite(
        assetName: String,
        frame: Int,
        frameCount: Int,
        box: SpriteBox,
        in size: CGSize
    ) -> some View {
        let scaleX = size.width / Self.faceSize
        let scaleY = size.height / Self.faceSize
        return CaptainAyerSpriteFrame(
            assetName: assetName,
            frame: frame,
            frameCount: frameCount
        )
        .frame(width: box.width * scaleX, height: box.height * scaleY)
        .offset(x: box.x * scaleX, y: box.y * scaleY)
    }

    private func gridSprite(
        assetName: String,
        frame: Int,
        columns: Int,
        rows: Int,
        box: SpriteBox,
        in size: CGSize
    ) -> some View {
        let scaleX = size.width / Self.faceSize
        let scaleY = size.height / Self.faceSize
        return CaptainAyerGridSpriteFrame(
            assetName: assetName,
            frame: frame,
            columns: columns,
            rows: rows
        )
        .frame(width: box.width * scaleX, height: box.height * scaleY)
        .offset(x: box.x * scaleX, y: box.y * scaleY)
    }
}

@MainActor
private struct CaptainAyerSpriteFrame: View {
    let assetName: String
    let frame: Int
    let frameCount: Int

    var body: some View {
        GeometryReader { proxy in
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height * CGFloat(frameCount),
                    alignment: .top
                )
                .offset(
                    y: CaptainAyerSpriteSheet.verticalOffsetInFrames(
                        frame,
                        frameCount: frameCount
                    ) * proxy.size.height
                )
        }
        .clipped()
    }
}

@MainActor
private struct CaptainAyerGridSpriteFrame: View {
    let assetName: String
    let frame: Int
    let columns: Int
    let rows: Int

    var body: some View {
        GeometryReader { proxy in
            let clamped = CaptainAyerSpriteSheet.clampedFrame(
                frame,
                frameCount: columns * rows
            )
            let column = clamped % columns
            let row = clamped / columns
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .frame(
                    width: proxy.size.width * CGFloat(columns),
                    height: proxy.size.height * CGFloat(rows),
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
