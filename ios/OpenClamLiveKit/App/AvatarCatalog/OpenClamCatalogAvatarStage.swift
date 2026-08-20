import SwiftUI

enum OpenClamAvatarFacePlateScope: Equatable, Sendable {
    case fullHead
    case speechPatch
}

struct OpenClamAvatarFacePlateLayer: Equatable, Sendable {
    let viseme: OpenClamAvatarViseme
    let opacity: Double
    let scope: OpenClamAvatarFacePlateScope
}

/// One opaque back plate with, at most, one source-over front plate. The view
/// applies the feathered mouth mask to this assembled patch exactly once.
/// Keeping the transition as one value prevents the old plate from leaking
/// through the feather when the blend reaches its endpoint.
struct OpenClamAvatarSpeechPatchPlan: Equatable, Sendable {
    let back: OpenClamAvatarFacePlateLayer
    let front: OpenClamAvatarFacePlateLayer?
}

struct OpenClamAvatarFacePlatePlan: Equatable, Sendable {
    let base: OpenClamAvatarFacePlateLayer
    let speechPatch: OpenClamAvatarSpeechPatchPlan?
}

/// The face is composited over the body with Porter-Duff source-atop. This
/// lets its color replace the matching body pixels while preserving the
/// body's alpha exactly, including at partially transparent hair edges.
enum OpenClamAvatarStageFaceBlendRule: Equatable, Sendable {
    case sourceAtopPreservingBodyAlpha
}

struct OpenClamAvatarStageOpacityPlan: Equatable, Sendable {
    let bodyOpacity: Double
    let faceBlendRule: OpenClamAvatarStageFaceBlendRule
    let userOpacityApplicationCount: Int
    let requiresWholeStageRasterization: Bool
}

enum OpenClamAvatarStageOpacityPolicy {
    static func plan(for requestedOpacity: Double) -> OpenClamAvatarStageOpacityPlan {
        OpenClamAvatarStageOpacityPlan(
            bodyOpacity: min(1, max(0, requestedOpacity)),
            faceBlendRule: .sourceAtopPreservingBodyAlpha,
            userOpacityApplicationCount: 1,
            requiresWholeStageRasterization: false
        )
    }

    /// Alpha produced by the stage's source-atop composition. Keeping the
    /// formula here makes the renderer invariant deterministic and testable:
    /// face animation may change color, but it can never darken or brighten
    /// the assembled avatar's silhouette.
    static func composedAlpha(
        bodyAlpha: Double,
        faceAlpha: Double,
        requestedOpacity: Double
    ) -> Double {
        let destinationAlpha = min(1, max(0, bodyAlpha))
            * plan(for: requestedOpacity).bodyOpacity
        let sourceAlpha = min(1, max(0, faceAlpha))

        // Porter-Duff source-atop: As * Ad + Ad * (1 - As) == Ad.
        return sourceAlpha * destinationAlpha
            + destinationAlpha * (1 - sourceAlpha)
    }
}

enum OpenClamAvatarSpeechPatchTransition {
    /// A linear source-over blend minimizes per-frame luminance deltas for the
    /// published plates. Clamping keeps malformed render states harmless.
    static func opacity(for linearBlend: Double) -> Double {
        min(1, max(0, linearBlend))
    }
}

enum OpenClamAvatarFaceAnimationPolicy {
    /// The body remains outside the timeline. Advancing only the face at the
    /// display cadence gives short 45-105 ms mouth transitions enough frames
    /// to remain smooth without repainting hands or clothing.
    static let minimumInterval: TimeInterval = 1.0 / 60.0
}

/// Keeps identity-bearing pixels stable while speech changes. The full head is
/// always the published silence plate; viseme changes are permitted only in a
/// feathered lower-face patch. This avoids re-crossfading hair, eyes, skin,
/// and JPEG noise at every 58-105 ms phoneme cue.
enum OpenClamAvatarFacePlatePolicy {
    static func plan(
        for state: CaptainAyerAvatarRenderState
    ) -> OpenClamAvatarFacePlatePlan {
        let base = OpenClamAvatarFacePlateLayer(
            viseme: .silence,
            opacity: 1,
            scope: .fullHead
        )
        let previous = state.previous.catalogViseme
        let current = state.current.catalogViseme
        let blend = OpenClamAvatarSpeechPatchTransition.opacity(for: state.blend)

        if previous == current {
            guard current != .silence else {
                return OpenClamAvatarFacePlatePlan(base: base, speechPatch: nil)
            }
            return OpenClamAvatarFacePlatePlan(
                base: base,
                speechPatch: OpenClamAvatarSpeechPatchPlan(
                    back: OpenClamAvatarFacePlateLayer(
                        viseme: current,
                        opacity: 1,
                        scope: .speechPatch
                    ),
                    front: nil
                )
            )
        }

        // Assemble the opaque previous plate and the source-over current
        // plate before applying the feathered mask. This is valid for
        // silence-to-speech and speech-to-silence as well: the silence plate
        // matches the immutable base exactly at both endpoints.
        return OpenClamAvatarFacePlatePlan(
            base: base,
            speechPatch: OpenClamAvatarSpeechPatchPlan(
                back: OpenClamAvatarFacePlateLayer(
                    viseme: previous,
                    opacity: 1,
                    scope: .speechPatch
                ),
                front: OpenClamAvatarFacePlateLayer(
                    viseme: current,
                    opacity: blend,
                    scope: .speechPatch
                )
            )
        )
    }
}

struct OpenClamAvatarSpeechPatchGeometry: Equatable, Sendable {
    static let canonicalSize = CGSize(width: 1_024, height: 1_024)
    static let featherRadius: CGFloat = 18

    let coreBounds: CGRect
    let conservativeDynamicBounds: CGRect

    init(rig: OpenClamAvatarRigGeometry) {
        let eyeBottom = max(rig.leftEye.box.cgRect.maxY, rig.rightEye.box.cgRect.maxY)
        // Three feather radii plus an eight-pixel guard keeps even the soft
        // edge below the published eye plates. There is deliberately no upper
        // cap: an imported rig with unusually low eyes must never let speech
        // repaint those eyes merely to preserve a larger mouth patch.
        let coreTop = max(630, eyeBottom + Self.featherRadius * 3 + 8)
        let coreBottom: CGFloat = 916
        coreBounds = CGRect(
            x: 352,
            y: coreTop,
            width: 320,
            height: max(1, coreBottom - coreTop)
        )
        conservativeDynamicBounds = coreBounds
            .insetBy(dx: -Self.featherRadius * 3, dy: -Self.featherRadius * 3)
            .intersection(CGRect(origin: .zero, size: Self.canonicalSize))
    }
}

private struct OpenClamAvatarSpeechPatchMask: View {
    let geometry: OpenClamAvatarSpeechPatchGeometry

    var body: some View {
        GeometryReader { proxy in
            let scaleX = proxy.size.width
                / OpenClamAvatarSpeechPatchGeometry.canonicalSize.width
            let scaleY = proxy.size.height
                / OpenClamAvatarSpeechPatchGeometry.canonicalSize.height
            let bounds = geometry.coreBounds

            RoundedRectangle(
                cornerRadius: min(bounds.width, bounds.height) * 0.34,
                style: .continuous
            )
            .fill(Color.white)
            .frame(
                width: bounds.width * scaleX,
                height: bounds.height * scaleY
            )
            .position(
                x: bounds.midX * scaleX,
                y: bounds.midY * scaleY
            )
            .blur(
                radius: OpenClamAvatarSpeechPatchGeometry.featherRadius
                    * min(scaleX, scaleY)
            )
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// A conservative local interaction silhouette in body-image coordinates.
/// Avatar packages deliberately contain only rendering and face-rig metadata;
/// they do not expose a pixel alpha hit mask. These regions are therefore
/// derived from the validated face bounds and body size, and intentionally
/// leave the surrounding transparent canvas (and the gaps between limbs)
/// available to the conversation underneath.
enum OpenClamAvatarStageInteractionGeometry {
    static func bodyRegions(
        for geometry: OpenClamAvatarRigGeometry
    ) -> [CGRect] {
        let body = geometry.bodySize.cgSize
        let bodyBounds = CGRect(origin: .zero, size: body)
        let face = geometry.faceBoundsInBody.cgRect
        guard body.width > 0, body.height > 0,
              bodyBounds.contains(face) else {
            return []
        }

        // Imported and bundled rigs keep the face near the visual center.
        // Clamp it defensively so malformed but otherwise displayable metadata
        // can never expand the interaction surface across the whole stage.
        let centerX = min(max(face.midX, body.width * 0.42), body.width * 0.58)
        let headWidth = max(face.width * 1.90, body.width * 0.16)
        let headHeight = max(face.height * 1.72, body.height * 0.095)
        let head = CGRect(
            x: centerX - headWidth / 2,
            y: face.minY - face.height * 0.34,
            width: headWidth,
            height: headHeight
        )

        let shoulderTop = max(head.maxY - face.height * 0.20, body.height * 0.11)
        let shoulders = CGRect(
            x: centerX - body.width * 0.23,
            y: shoulderTop,
            width: body.width * 0.46,
            height: body.height * 0.16
        )
        let torso = CGRect(
            x: centerX - body.width * 0.19,
            y: shoulders.minY + body.height * 0.08,
            width: body.width * 0.38,
            height: body.height * 0.30
        )
        let armTop = shoulders.minY + body.height * 0.035
        let leftArm = CGRect(
            x: centerX - body.width * 0.26,
            y: armTop,
            width: body.width * 0.10,
            height: body.height * 0.32
        )
        let rightArm = CGRect(
            x: centerX + body.width * 0.16,
            y: armTop,
            width: body.width * 0.10,
            height: body.height * 0.32
        )
        let hips = CGRect(
            x: centerX - body.width * 0.19,
            y: torso.maxY - body.height * 0.045,
            width: body.width * 0.38,
            height: body.height * 0.14
        )
        let legTop = hips.maxY - body.height * 0.020
        let leftLeg = CGRect(
            x: centerX - body.width * 0.20,
            y: legTop,
            width: body.width * 0.17,
            height: body.height * 0.39
        )
        let rightLeg = CGRect(
            x: centerX + body.width * 0.03,
            y: legTop,
            width: body.width * 0.17,
            height: body.height * 0.39
        )

        return [head, shoulders, torso, leftArm, rightArm, hips, leftLeg, rightLeg]
            .map { $0.intersection(bodyBounds) }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }
}

private struct OpenClamAvatarStageInteractionSurface: Shape {
    let region: Path

    func path(in _: CGRect) -> Path { region }
}

/// Descriptor-driven counterpart to CaptainAyerAvatarStage. It classifies
/// face gaze, taps, and vertical opacity drags, while the overlay owns scale,
/// pinch arbitration, persisted opacity, and true hide/pass-through.
@MainActor
struct OpenClamCatalogAvatarStage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var touchStart: CGPoint?
    @State private var dragSession = CaptainAyerAvatarDragSession()

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
    /// Motion clips replace only the artwork. The stage's narrow interaction
    /// silhouette remains mounted so tap, gaze, opacity, and pinch can
    /// deterministically interrupt motion and return to the live face rig.
    let showsArtwork: Bool
    /// Kept separate from the interaction surface. The overlay intentionally
    /// opens at a subtle alpha, and visual alpha must not alter the available
    /// body area for a vertical opacity gesture.
    let renderOpacity: Double
    let onVerticalOpacityChanged: ((CGFloat) -> Void)?
    let onVerticalOpacityEnded: (() -> Void)?
    /// The overlay owns persisted scale and its drag/pinch arbitration, while
    /// this stage owns the hit region. Keeping this callback here ensures a
    /// pinch cannot silently make the transparent canvas interactive again.
    let onMagnificationChanged: ((CGFloat) -> Void)?
    let onMagnificationEnded: (() -> Void)?
    let onInteraction: () -> Void
    private let imageStore: OpenClamAvatarAssetStore

    init(
        avatar: OpenClamAvatarDescriptor,
        controller: CaptainAyerLipSyncController,
        reactions: CaptainAyerFaceReactionController,
        faceMirror: CaptainAyerFaceMirrorController,
        presentation: Presentation = .expanded,
        allowsGazeTracking: Bool = true,
        showsArtwork: Bool = true,
        renderOpacity: Double = 1,
        onVerticalOpacityChanged: ((CGFloat) -> Void)? = nil,
        onVerticalOpacityEnded: (() -> Void)? = nil,
        onMagnificationChanged: ((CGFloat) -> Void)? = nil,
        onMagnificationEnded: (() -> Void)? = nil,
        imageStore: OpenClamAvatarAssetStore? = nil,
        onInteraction: @escaping () -> Void = {}
    ) {
        self.avatar = avatar
        self.controller = controller
        self.reactions = reactions
        self.faceMirror = faceMirror
        self.presentation = presentation
        self.allowsGazeTracking = allowsGazeTracking
        self.showsArtwork = showsArtwork
        self.renderOpacity = min(1, max(0, renderOpacity))
        self.onVerticalOpacityChanged = onVerticalOpacityChanged
        self.onVerticalOpacityEnded = onVerticalOpacityEnded
        self.onMagnificationChanged = onMagnificationChanged
        self.onMagnificationEnded = onMagnificationEnded
        self.imageStore = imageStore ?? .shared
        self.onInteraction = onInteraction
    }

    var body: some View {
        let crop = presentation.crop(for: avatar)
        let opacityPlan = OpenClamAvatarStageOpacityPolicy.plan(for: renderOpacity)
        GeometryReader { proxy in
            ZStack {
                if showsArtwork {
                    ZStack {
                    // The full body is deliberately outside TimelineView. It
                    // remains a stable texture while only the much smaller
                    // face surface advances on the speech clock.
                    OpenClamCatalogAvatarBodyArtwork(
                        avatar: avatar,
                        imageStore: imageStore,
                        crop: crop
                    )
                    .opacity(opacityPlan.bodyOpacity)

                    TimelineView(
                        .animation(
                            minimumInterval: OpenClamAvatarFaceAnimationPolicy.minimumInterval,
                            paused: reduceMotion || !(
                                controller.isSpeaking
                                    || reactions.isAnimating
                                    || reactions.isGazeAnimating
                                    || reactions.isAmbientAnimating
                                    || faceMirror.isCapturing
                            )
                        )
                    ) { context in
                        let mirrorsFace = faceMirror.isCapturing
                        let mirroredExpression = faceMirror.expression
                        OpenClamCatalogAvatarFaceArtwork(
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
                        // The static body is the destination. Source-atop
                        // changes only its color, never its alpha, so the head
                        // and mouth cannot become more opaque than the body.
                        .blendMode(.sourceAtop)
                    }
                    }
                    // A regular compositing group isolates source-atop from the
                    // conversation behind the avatar without rasterizing the
                    // whole stage. Body and hair therefore remain native-sharp
                    // when the overlay magnifies this view.
                    .clipped()
                    .compositingGroup()
                    .allowsHitTesting(false)
                }

                // This surface deliberately stays outside the visual alpha,
                // but follows a narrow local body silhouette rather than the
                // stage rectangle. It uses simultaneous recognition so the
                // conversation retains its normal scroll gesture.
                let surface = OpenClamAvatarStageInteractionSurface(
                    region: interactionPath(stageSize: proxy.size, crop: crop)
                )
                surface
                    .fill(Color.clear)
                    .contentShape(surface)
                    .simultaneousGesture(
                        faceGesture(stageSize: proxy.size, crop: crop),
                        including: .all
                    )
                    .simultaneousGesture(
                        stagePinchGesture,
                        including: .all
                    )
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(crop.width / crop.height, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(avatar.displayName)
        .accessibilityValue(accessibilityValue)
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

    private func faceGesture(stageSize: CGSize, crop: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if touchStart == nil {
                    touchStart = value.startLocation
                    dragSession = CaptainAyerAvatarDragSession()
                }
                dragSession.update(
                    translation: value.translation,
                    supportsOpacity: onVerticalOpacityChanged != nil
                        && onVerticalOpacityEnded != nil
                )
                if dragSession.intent == .opacity {
                    reactions.cancelGaze()
                }

                if dragSession.intent == .opacity {
                    onVerticalOpacityChanged?(value.translation.height)
                    onInteraction()
                    return
                }
                guard dragSession.intent == .gaze else {
                    reactions.cancelGaze()
                    return
                }
                guard allowsGazeTracking else {
                    reactions.cancelGaze()
                    return
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
                let completion = dragSession.completion
                defer {
                    touchStart = nil
                    dragSession = CaptainAyerAvatarDragSession()
                }
                if completion == .opacity {
                    reactions.cancelGaze()
                    onVerticalOpacityEnded?()
                    onInteraction()
                    return
                }
                guard allowsGazeTracking else {
                    reactions.cancelGaze()
                    return
                }
                reactions.releaseGaze(reduceMotion: reduceMotion)
                if completion == .tap {
                    let didReactToFace = reactions.react(
                        atNormalizedFacePoint: normalizedFacePoint(
                            for: value.location,
                            stageSize: stageSize,
                            crop: crop
                        )
                    )
                    if !didReactToFace {
                        reactions.react(
                            atNormalizedBodyPoint: normalizedBodyPoint(
                                for: value.location,
                                stageSize: stageSize,
                                crop: crop
                            )
                        )
                    }
                }
                onInteraction()
            }
    }

    /// Pinch is intentionally registered on the same silhouette as face
    /// gestures. `simultaneousGesture` leaves the underlying ScrollView's
    /// recognizer intact, and empty stage canvas remains fully click-through.
    private var stagePinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                onMagnificationChanged?(value.magnification)
            }
            .onEnded { _ in
                onMagnificationEnded?()
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

    private func normalizedBodyPoint(
        for location: CGPoint,
        stageSize: CGSize,
        crop: CGRect
    ) -> CGPoint {
        guard let placement = placement(stageSize: stageSize, crop: crop) else {
            return CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        }
        let body = avatar.geometry.bodySize.cgSize
        let bodyPoint = CGPoint(
            x: (location.x - placement.origin.x) / placement.scale,
            y: (location.y - placement.origin.y) / placement.scale
        )
        return CGPoint(
            x: bodyPoint.x / max(1, body.width),
            y: bodyPoint.y / max(1, body.height)
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

    private func interactionPath(stageSize: CGSize, crop: CGRect) -> Path {
        guard let placement = placement(stageSize: stageSize, crop: crop) else {
            return Path()
        }
        let regions = OpenClamAvatarStageInteractionGeometry.bodyRegions(
            for: avatar.geometry
        )
        var path = Path()
        for (index, bodyRegion) in regions.enumerated() {
            let stageRegion = CGRect(
                x: placement.origin.x + bodyRegion.minX * placement.scale,
                y: placement.origin.y + bodyRegion.minY * placement.scale,
                width: bodyRegion.width * placement.scale,
                height: bodyRegion.height * placement.scale
            )
            guard stageRegion.width > 0, stageRegion.height > 0 else { continue }
            if index == 0 {
                path.addEllipse(in: stageRegion)
            } else {
                let radius = min(stageRegion.width, stageRegion.height) * 0.30
                path.addRoundedRect(
                    in: stageRegion,
                    cornerSize: CGSize(width: radius, height: radius)
                )
            }
        }
        return path
    }

    private var accessibilityValue: String {
        if faceMirror.isCapturing {
            return faceMirror.isTrackingFace ? "Mirroring your face" : "Looking for your face"
        }
        if controller.isSpeaking { return "Speaking" }
        if reactions.isAnimating { return "Reacting" }
        return "Idle"
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
private struct OpenClamCatalogAvatarBodyArtwork: View {
    let avatar: OpenClamAvatarDescriptor
    let imageStore: OpenClamAvatarAssetStore
    let crop: CGRect

    var body: some View {
        GeometryReader { proxy in
            let body = avatar.geometry.bodySize.cgSize
            let scale = min(proxy.size.width / crop.width, proxy.size.height / crop.height)
            let origin = CGPoint(
                x: (proxy.size.width - crop.width * scale) / 2 - crop.minX * scale,
                y: (proxy.size.height - crop.height * scale) / 2 - crop.minY * scale
            )

            OpenClamAvatarAssetImage(
                image: imageStore.image(for: avatar, role: .body)
            )
            .frame(width: body.width * scale, height: body.height * scale)
            .offset(x: origin.x, y: origin.y)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}

@MainActor
private struct OpenClamCatalogAvatarFaceArtwork: View {
    let avatar: OpenClamAvatarDescriptor
    let imageStore: OpenClamAvatarAssetStore
    let state: CaptainAyerAvatarRenderState
    let reaction: CaptainAyerFaceReactionRenderState
    let showsReactionMouth: Bool
    let crop: CGRect

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / crop.width, proxy.size.height / crop.height)
            let origin = CGPoint(
                x: (proxy.size.width - crop.width * scale) / 2 - crop.minX * scale,
                y: (proxy.size.height - crop.height * scale) / 2 - crop.minY * scale
            )
            let transform = avatar.geometry.faceTransform
            let faceCenter = avatar.geometry.faceCenterInBody.cgPoint

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
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }

    private var facePlates: some View {
        let plan = OpenClamAvatarFacePlatePolicy.plan(for: state)
        let patchGeometry = OpenClamAvatarSpeechPatchGeometry(rig: avatar.geometry)

        return ZStack {
            // This is the only identity-bearing full-head plate. It never
            // changes during speech, so hair, eyes, and skin cannot flicker.
            assetImage(.viseme(plan.base.viseme))

            if plan.speechPatch != nil
                || (showsReactionMouth && reaction.wideMouthOpacity > 0) {
                ZStack {
                    if let patch = plan.speechPatch {
                        assetImage(.viseme(patch.back.viseme))
                        if let front = patch.front {
                            assetImage(.viseme(front.viseme))
                                .opacity(front.opacity)
                        }
                    }

                    if showsReactionMouth, reaction.wideMouthOpacity > 0 {
                        assetImage(.viseme(.wide))
                            .opacity(reaction.wideMouthOpacity)
                    }
                }
                .compositingGroup()
                .mask {
                    OpenClamAvatarSpeechPatchMask(geometry: patchGeometry)
                }
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
