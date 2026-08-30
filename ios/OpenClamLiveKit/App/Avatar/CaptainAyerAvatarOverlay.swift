import AVFoundation
import LiveKit
import SwiftUI
import UIKit

struct OpenClamAvatarMotionRuntimeContext: Equatable, Sendable {
    let hasAsset: Bool
    let reduceMotion: Bool
    let isSpeaking: Bool
    let isLiveTalkActive: Bool
    let isAvatarHidden: Bool
    let isFaceMirrorActive: Bool
}

enum OpenClamAvatarMotionAvailabilityPolicy {
    static func disabledReason(
        for context: OpenClamAvatarMotionRuntimeContext
    ) -> String? {
        if !context.hasAsset { return "Not included in this avatar" }
        if context.reduceMotion { return "Unavailable with Reduce Motion" }
        if context.isLiveTalkActive { return "Unavailable during Live Talk" }
        if context.isSpeaking { return "Unavailable while speaking" }
        if context.isAvatarHidden { return "Unavailable while avatar is hidden" }
        if context.isFaceMirrorActive { return "Unavailable during face mirroring" }
        return nil
    }
}

enum OpenClamAvatarMotionSessionAction: Equatable, Sendable {
    case none
    case start(OpenClamAvatarMotionKind)
    case stop(OpenClamAvatarMotionKind)
    case replace(OpenClamAvatarMotionKind, OpenClamAvatarMotionKind)
}

/// A single owner for every full-body clip. Speech, Live Talk, Reduce Motion,
/// visibility, face mirroring, scene lifecycle, and stage interaction all use
/// `interrupt`; this prevents a clip from competing with the live face rig.
struct OpenClamAvatarMotionSessionState: Equatable, Sendable {
    private(set) var activeKind: OpenClamAvatarMotionKind? = nil

    mutating func request(
        _ kind: OpenClamAvatarMotionKind,
        canStart: Bool
    ) -> OpenClamAvatarMotionSessionAction {
        guard canStart else { return .none }
        if activeKind == kind {
            // Display modes are selections, not toggle buttons. Selecting an
            // already-active motion is therefore idempotent; Standby is the
            // explicit way to leave it.
            return .none
        }
        if let previous = activeKind {
            activeKind = kind
            return .replace(previous, kind)
        }
        activeKind = kind
        return .start(kind)
    }

    mutating func interrupt() -> OpenClamAvatarMotionSessionAction {
        guard let activeKind else { return .none }
        self.activeKind = nil
        return .stop(activeKind)
    }

    mutating func complete(
        _ kind: OpenClamAvatarMotionKind
    ) -> OpenClamAvatarMotionSessionAction {
        guard activeKind == kind else { return .none }
        activeKind = nil
        return .stop(kind)
    }
}

enum OpenClamAvatarDisplayMode: String, CaseIterable, Sendable {
    case standby
    case closeUp = "close-up"
    case horizonWalk = "horizon-walk"
    case edgeIdle = "edge-idle"
    case moves

    var title: String {
        switch self {
        case .standby: "Standby"
        case .closeUp: "Close-up"
        case .horizonWalk: "Horizon Walk"
        case .edgeIdle: "Edge Idle"
        case .moves: "Moves"
        }
    }

    var systemImage: String {
        switch self {
        case .standby: "figure.stand"
        case .closeUp: "person.crop.square"
        case .horizonWalk: "figure.walk"
        case .edgeIdle: "figure.stand.line.dotted.figure.stand"
        case .moves: "figure.dance"
        }
    }

    var motionKind: OpenClamAvatarMotionKind? {
        switch self {
        case .standby, .closeUp: nil
        case .horizonWalk: .walk
        case .edgeIdle: .edgeIdle
        case .moves: .moves
        }
    }

    var isMotion: Bool { motionKind != nil }

    /// Touching the avatar or interacting with the conversation dismisses a
    /// transient clip, but intentionally leaves an explicit Close-up intact.
    var afterUserActivity: Self { isMotion ? .standby : self }

    init(motionKind: OpenClamAvatarMotionKind) {
        switch motionKind {
        case .walk: self = .horizonWalk
        case .edgeIdle: self = .edgeIdle
        case .moves: self = .moves
        }
    }
}

struct OpenClamAvatarStandbyTransform: Equatable, Sendable {
    static let factory = Self(scale: 1, normalizedOffset: .zero)

    let scale: CGFloat
    let normalizedOffset: CGPoint
}

enum OpenClamAvatarStandbyTransformPolicy {
    static let maximumNormalizedOffset: CGFloat = 0.48

    static func sanitized(
        scale: CGFloat,
        normalizedOffset: CGPoint
    ) -> OpenClamAvatarStandbyTransform {
        OpenClamAvatarStandbyTransform(
            scale: CaptainAyerOverlayTuning.clampedScale(scale),
            normalizedOffset: CGPoint(
                x: clampOffset(normalizedOffset.x),
                y: clampVerticalOffset(normalizedOffset.y)
            )
        )
    }

    static func translated(
        from startingOffset: CGPoint,
        by translation: CGSize,
        in canvasSize: CGSize
    ) -> CGPoint {
        guard canvasSize.width.isFinite,
              canvasSize.height.isFinite,
              canvasSize.width > 0,
              canvasSize.height > 0 else {
            return CGPoint(
                x: clampOffset(startingOffset.x),
                y: clampVerticalOffset(startingOffset.y)
            )
        }
        return CGPoint(
            x: clampOffset(startingOffset.x + translation.width / canvasSize.width),
            y: clampVerticalOffset(
                startingOffset.y + translation.height / canvasSize.height
            )
        )
    }

    static func transformed(
        from startingTransform: OpenClamAvatarStandbyTransform,
        magnification: CGFloat,
        centroidTranslation: CGSize,
        in canvasSize: CGSize
    ) -> OpenClamAvatarStandbyTransform {
        let safeMagnification = magnification.isFinite && magnification > 0
            ? magnification
            : 1
        return sanitized(
            scale: startingTransform.scale * safeMagnification,
            normalizedOffset: translated(
                from: startingTransform.normalizedOffset,
                by: centroidTranslation,
                in: canvasSize
            )
        )
    }

    private static func clampOffset(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(maximumNormalizedOffset, max(-maximumNormalizedOffset, value))
    }

    /// Every static mode scales the complete body from its top edge. Moving
    /// upward would therefore move the hat/head outside the safe conversation
    /// canvas. Downward movement remains available across the full persisted
    /// range.
    private static func clampVerticalOffset(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(maximumNormalizedOffset, max(0, value))
    }
}

/// One full-body plate backs both Standby and Close-up. Close-up differs only
/// by its initial transform; pinching back to 1x reveals the complete body
/// without swapping to a permanently cropped head-and-shoulders texture.
enum OpenClamAvatarFramingPresetPolicy {
    static let fullBodyTransformVersion = 1
    static let closeUpFaceHeights: CGFloat = 3.5

    static func legacyCompactToFullBodyScaleFactor(
        for geometry: OpenClamAvatarRigGeometry
    ) -> CGFloat {
        let bodyHeight = geometry.bodySize.cgSize.height
        let faceHeight = geometry.faceBoundsInBody.cgRect.height
        guard bodyHeight.isFinite,
              faceHeight.isFinite,
              bodyHeight > 0,
              faceHeight > 0 else { return 1 }
        let priorVisibleHeight = min(bodyHeight, faceHeight * closeUpFaceHeights)
        return CaptainAyerOverlayTuning.clampedScale(
            bodyHeight / priorVisibleHeight
        )
    }

    static func migratedCloseUpTransform(
        from legacyTransform: OpenClamAvatarStandbyTransform,
        geometry: OpenClamAvatarRigGeometry
    ) -> OpenClamAvatarStandbyTransform {
        OpenClamAvatarStandbyTransformPolicy.sanitized(
            scale: legacyTransform.scale
                * legacyCompactToFullBodyScaleFactor(for: geometry),
            normalizedOffset: legacyTransform.normalizedOffset
        )
    }
}

/// Geometry-level last line of defence for persisted transforms and future
/// stage-layout changes. With a top-anchored full-body plate, this guarantees
/// the complete source top (including hats and hair) never crosses the upper
/// safe edge, at every supported scale.
enum OpenClamAvatarFramingConstraintPolicy {
    static func keepingHeadVisible(
        _ transform: OpenClamAvatarStandbyTransform,
        stageFrame: CGRect,
        canvasBounds: CGRect
    ) -> OpenClamAvatarStandbyTransform {
        let sanitized = OpenClamAvatarStandbyTransformPolicy.sanitized(
            scale: transform.scale,
            normalizedOffset: transform.normalizedOffset
        )
        guard canvasBounds.height.isFinite,
              canvasBounds.height > 0,
              canvasBounds.minY.isFinite,
              stageFrame.minY.isFinite else { return sanitized }

        let requestedOffsetY = sanitized.normalizedOffset.y * canvasBounds.height
        let minimumOffsetY = max(0, canvasBounds.minY - stageFrame.minY)
        return OpenClamAvatarStandbyTransform(
            scale: sanitized.scale,
            normalizedOffset: CGPoint(
                x: sanitized.normalizedOffset.x,
                // Safety wins if a future layout places the unscaled stage
                // more than the normal gesture range above the canvas.
                y: max(requestedOffsetY, minimumOffsetY) / canvasBounds.height
            )
        )
    }
}

enum OpenClamAvatarStagePresentationPolicy {
    static func presentation(
        for _: OpenClamAvatarDisplayMode
    ) -> OpenClamCatalogAvatarStage.Presentation {
        .expanded
    }
}

/// A two-finger interaction always derives its preview from one immutable
/// starting transform. Gesture updates are cumulative-from-start values, so
/// UIKit's overlapping pinch and pan recognizers can never compound drift.
struct OpenClamAvatarTransformSession: Equatable, Sendable {
    let mode: OpenClamAvatarDisplayMode
    let startingTransform: OpenClamAvatarStandbyTransform
    private(set) var previewTransform: OpenClamAvatarStandbyTransform

    init(
        mode: OpenClamAvatarDisplayMode,
        startingTransform: OpenClamAvatarStandbyTransform
    ) {
        self.mode = mode
        self.startingTransform = startingTransform
        previewTransform = startingTransform
    }

    mutating func update(
        magnification: CGFloat,
        centroidTranslation: CGSize,
        canvasSize: CGSize
    ) -> OpenClamAvatarStandbyTransform {
        previewTransform = OpenClamAvatarStandbyTransformPolicy.transformed(
            from: startingTransform,
            magnification: magnification,
            centroidTranslation: centroidTranslation,
            in: canvasSize
        )
        return previewTransform
    }

    mutating func replacePreview(
        with transform: OpenClamAvatarStandbyTransform
    ) {
        previewTransform = transform
    }
}

struct OpenClamAvatarMotionLayout: Equatable, Sendable {
    let playerFrame: CGRect
    let clippingBounds: CGRect
}

struct OpenClamAvatarConversationCanvasLayout: Equatable, Sendable {
    let bounds: CGRect
    let stageFrame: CGRect
}

enum OpenClamAvatarConversationCanvasPolicy {
    static let composerGap: CGFloat = 4
    /// Generated body plates retain a narrow transparent production margin
    /// below the shoes. Bleeding only that margin outside the clip makes the
    /// visible heels meet the conversation floor without distorting the body.
    static let fullBodyVisibleBottomFraction: CGFloat = 0.975
    /// Captain Ayer predates the current production canvas contract and keeps
    /// a larger transparent footer than Ara. Use each reviewed bundled
    /// plate's measured alpha union so both avatars meet the same visual floor.
    static let captainAyerVisibleBottomFraction: CGFloat = 1_587.0 / 1_672.0
    static let araVisibleBottomFraction: CGFloat = 1_406.0 / 1_448.0

    static func fullBodyVisibleBottomFraction(
        for avatar: OpenClamAvatarDescriptor
    ) -> CGFloat {
        switch avatar.id {
        case OpenClamAvatarID.captainAyer.rawValue:
            captainAyerVisibleBottomFraction
        case OpenClamAvatarID.ara.rawValue:
            araVisibleBottomFraction
        default:
            fullBodyVisibleBottomFraction
        }
    }

    static func bounds(
        overlaySize: CGSize,
        overlayGlobalMinY: CGFloat,
        composerTopGlobal: CGFloat?,
        topInset: CGFloat
    ) -> CGRect {
        let width = finiteNonnegative(overlaySize.width)
        let height = finiteNonnegative(overlaySize.height)
        let top = min(height, max(0, finiteNonnegative(topInset)))
        let measuredBottom: CGFloat
        if let composerTopGlobal,
           composerTopGlobal.isFinite,
           overlayGlobalMinY.isFinite {
            measuredBottom = composerTopGlobal
                - overlayGlobalMinY
                - composerGap
        } else {
            measuredBottom = height
        }
        let bottom = min(height, max(top, measuredBottom))
        return CGRect(x: 0, y: top, width: width, height: bottom - top)
    }

    static func layout(
        crop: CGRect,
        in bounds: CGRect,
        alignsVisibleFeet: Bool,
        visibleBottomFraction: CGFloat = fullBodyVisibleBottomFraction
    ) -> OpenClamAvatarConversationCanvasLayout {
        guard bounds.width > 0,
              bounds.height > 0,
              crop.width.isFinite,
              crop.height.isFinite,
              crop.width > 0,
              crop.height > 0 else {
            return OpenClamAvatarConversationCanvasLayout(
                bounds: bounds,
                stageFrame: .zero
            )
        }

        // Portrait body plates deliberately carry generous transparent side
        // margins. Height-fill is therefore the correct conversation framing:
        // it fills the thread vertically while clipping only empty side canvas.
        let resolvedVisibleBottomFraction = alignsVisibleFeet
            ? min(1, max(0.01, visibleBottomFraction))
            : 1
        let stageHeight = bounds.height / resolvedVisibleBottomFraction
        let stageWidth = stageHeight * crop.width / crop.height
        let stageFrame = CGRect(
            x: bounds.midX - stageWidth / 2,
            y: bounds.maxY - stageHeight * resolvedVisibleBottomFraction,
            width: stageWidth,
            height: stageHeight
        )
        return OpenClamAvatarConversationCanvasLayout(
            bounds: bounds,
            stageFrame: stageFrame
        )
    }

    private static func finiteNonnegative(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }
}

enum OpenClamAvatarMotionLayoutPolicy {
    /// Retained-alpha unions measured across the production motion twins.
    /// Vertical alignment must use the visible subject, not the transparent
    /// 720 x 1088 video plate, or shoes float above the composer floor.
    static let walkContentBounds = CGRect(
        x: 0,
        y: 73.0 / 1_088.0,
        width: 1,
        height: 980.0 / 1_088.0
    )
    static let movesContentBounds = CGRect(
        x: 0,
        y: 58.0 / 1_088.0,
        width: 1,
        height: 989.0 / 1_088.0
    )
    /// Measured from all 73 retained frames of Ara's 720 x 1088 Edge Idle
    /// clip. The foreground union is x=188..<532, y=48..<1064 and the stable
    /// screen-left contact is x=192 in 66/73 frames. Pin the contact, not the
    /// far knee/foot at the opposite side of the silhouette: Edge Idle is the
    /// canonical left-edge pose used by the Mac runtime too.
    static let edgeIdleContentBounds = CGRect(
        x: 188.0 / 720.0,
        y: 48.0 / 1_088.0,
        width: 344.0 / 720.0,
        height: 1_016.0 / 1_088.0
    )
    static let edgeIdleLeftContactFraction: CGFloat = 192.0 / 720.0
    static let edgeIdlePreferredInset: CGFloat = 3

    static func contentBounds(for kind: OpenClamAvatarMotionKind) -> CGRect {
        switch kind {
        case .walk: walkContentBounds
        case .edgeIdle: edgeIdleContentBounds
        case .moves: movesContentBounds
        }
    }

    static func layout(
        kind: OpenClamAvatarMotionKind,
        availableSize: CGSize,
        pixelSize: CGSize
    ) -> OpenClamAvatarMotionLayout {
        let availableWidth = finiteNonnegative(availableSize.width)
        let availableHeight = finiteNonnegative(availableSize.height)
        let sourceWidth = finiteNonnegative(pixelSize.width)
        let sourceHeight = finiteNonnegative(pixelSize.height)
        let clippingBounds = CGRect(
            origin: .zero,
            size: CGSize(width: availableWidth, height: availableHeight)
        )

        guard availableWidth > 0,
              availableHeight > 0,
              sourceWidth > 0,
              sourceHeight > 0 else {
            return OpenClamAvatarMotionLayout(
                playerFrame: .zero,
                clippingBounds: clippingBounds
            )
        }

        // Fill by the retained subject alpha rather than by the transparent
        // media canvas. Edge Idle may scale down in narrow Split View to keep
        // all horizontal alpha, but its shoes still stay on the same floor.
        let contentBounds = contentBounds(for: kind)
        let fullHeightScale = availableHeight
            / (sourceHeight * contentBounds.height)
        let playerScale: CGFloat
        let originX: CGFloat
        let originY: CGFloat
        switch kind {
        case .edgeIdle:
            // The avatar rail is physically on the right, in both LTR and
            // RTL. Edge Idle belongs to the opposite physical screen edge;
            // this geometry is deliberately not mirrored by locale.
            let visibleContentInset = min(
                edgeIdlePreferredInset,
                availableWidth / 100
            )
            let contentWidth = sourceWidth * edgeIdleContentBounds.width
            let horizontalFitScale = max(
                0,
                (availableWidth - 2 * visibleContentInset) / contentWidth
            )
            playerScale = min(fullHeightScale, horizontalFitScale)
            let playerWidth = sourceWidth * playerScale
            // Use the all-frame leading envelope for placement. The stable
            // contact is four source pixels inside that envelope, so it still
            // reads as touching the wall while no retained alpha is clipped on
            // tall phones, iPad, Split View, or tiny defensive layouts.
            originX = visibleContentInset
                - playerWidth * edgeIdleContentBounds.minX
            originY = availableHeight
                - sourceHeight * playerScale * contentBounds.maxY
        case .walk, .moves:
            playerScale = fullHeightScale
            let playerWidth = sourceWidth * playerScale
            originX = (availableWidth - playerWidth) / 2
            originY = -sourceHeight * playerScale * contentBounds.minY
        }

        let playerWidth = sourceWidth * playerScale
        let playerHeight = sourceHeight * playerScale

        return OpenClamAvatarMotionLayout(
            playerFrame: CGRect(
                x: originX,
                y: originY,
                width: playerWidth,
                height: playerHeight
            ),
            clippingBounds: clippingBounds
        )
    }

    private static func finiteNonnegative(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }
}

@MainActor
private final class OpenClamTransparentMotionUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var player: AVPlayer?
    private var looper: AVPlayerLooper?
    private var configuredURL: URL?
    private var configuredKind: OpenClamAvatarMotionKind?

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        playerLayer.backgroundColor = UIColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        fileURL: URL,
        kind: OpenClamAvatarMotionKind
    ) {
        guard configuredURL != fileURL || configuredKind != kind else {
            return
        }
        stop()
        configuredURL = fileURL
        configuredKind = kind

        let item = AVPlayerItem(url: fileURL)
        if kind.loops {
            let queue = AVQueuePlayer()
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
        } else {
            player = AVPlayer(playerItem: item)
        }
        player?.isMuted = true
        playerLayer.player = player
        player?.play()
    }

    func stop() {
        player?.pause()
        playerLayer.player = nil
        looper = nil
        player = nil
        configuredURL = nil
        configuredKind = nil
    }
}

@MainActor
private struct OpenClamTransparentMotionPlayer: UIViewRepresentable {
    let fileURL: URL
    let kind: OpenClamAvatarMotionKind

    func makeUIView(context _: Context) -> OpenClamTransparentMotionUIView {
        let view = OpenClamTransparentMotionUIView(frame: .zero)
        view.configure(fileURL: fileURL, kind: kind)
        return view
    }

    func updateUIView(
        _ uiView: OpenClamTransparentMotionUIView,
        context _: Context
    ) {
        uiView.configure(fileURL: fileURL, kind: kind)
    }

    static func dismantleUIView(
        _ uiView: OpenClamTransparentMotionUIView,
        coordinator _: Void
    ) {
        uiView.stop()
    }
}

enum CaptainAyerOverlayTuning {
    static let minimumOpacity = 0.0
    static let maximumOpacity = 1.0
    static let initialOpacity = 0.14
    static let opacityTravel: CGFloat = 300

    static let minimumScale = 0.60
    static let maximumScale = 4.5
    static let initialScale = 1.0
    static let railFadeDelay: TimeInterval = 2.0
    static let railIdleOpacity = 0.14

    static func clampedOpacity(_ value: Double) -> Double {
        min(maximumOpacity, max(minimumOpacity, value))
    }

    static func clampedScale(_ value: CGFloat) -> CGFloat {
        min(maximumScale, max(minimumScale, value))
    }

    static func opacity(
        from startingOpacity: Double,
        verticalTranslation: CGFloat
    ) -> Double {
        clampedOpacity(
            startingOpacity - Double(verticalTranslation / opacityTravel)
        )
    }

}

enum CaptainAyerInteractionLayer: String, CaseIterable, Sendable {
    case avatar
    case thread

    /// The avatar layer keeps its narrow silhouette gesture surface even at
    /// 0% opacity so an upward swipe can make it visible again. Thread mode
    /// remains fully pass-through regardless of the visual opacity.
    var allowsAvatarGestures: Bool { self == .avatar }

    var title: String {
        switch self {
        case .avatar: "Avatar in front"
        case .thread: "Thread in front"
        }
    }

    var detail: String {
        switch self {
        case .avatar: "Two fingers resize or move; one-finger vertical swipe changes opacity"
        case .thread: "Swipe to scroll the chat; avatar gestures are off"
        }
    }

    var toggled: Self {
        switch self {
        case .avatar: .thread
        case .thread: .avatar
        }
    }
}

struct CaptainAyerOpacityDragSession: Equatable, Sendable {
    let startingOpacity: Double
    private(set) var previewOpacity: Double
    private(set) var persistedValue: Double?

    init(startingOpacity: Double) {
        let opacity = CaptainAyerOverlayTuning.clampedOpacity(startingOpacity)
        self.startingOpacity = opacity
        self.previewOpacity = opacity
        self.persistedValue = nil
    }

    mutating func update(verticalTranslation: CGFloat) {
        guard persistedValue == nil else { return }
        previewOpacity = CaptainAyerOverlayTuning.opacity(
            from: startingOpacity,
            verticalTranslation: verticalTranslation
        )
    }

    /// Intermediate updates remain a reversible visual preview. Only the
    /// gesture's completed path calls this method and persists its result.
    mutating func complete() -> Double {
        persistedValue = previewOpacity
        return previewOpacity
    }
}

/// Resolves the only overlapping avatar gestures. Pinch owns the interaction
/// as soon as it begins: an opacity preview is discarded and its original
/// value is returned for immediate visual restoration. A late drag end then
/// has no session left to commit.
struct CaptainAyerOverlayGestureState: Equatable, Sendable {
    private var opacityDragSession: CaptainAyerOpacityDragSession?
    private(set) var isPinching = false
    private(set) var suppressesOpacityUntilDragEnd = false

    var hasOpacityDrag: Bool { opacityDragSession != nil }

    mutating func updateOpacityDrag(
        startingOpacity: Double,
        verticalTranslation: CGFloat
    ) -> Double? {
        guard !isPinching, !suppressesOpacityUntilDragEnd else { return nil }
        if opacityDragSession == nil {
            opacityDragSession = CaptainAyerOpacityDragSession(
                startingOpacity: startingOpacity
            )
        }
        opacityDragSession?.update(verticalTranslation: verticalTranslation)
        return opacityDragSession?.previewOpacity
    }

    mutating func completeOpacityDrag() -> Double? {
        if suppressesOpacityUntilDragEnd {
            suppressesOpacityUntilDragEnd = false
            opacityDragSession = nil
            return nil
        }
        guard !isPinching, var opacityDragSession else {
            self.opacityDragSession = nil
            return nil
        }
        let value = opacityDragSession.complete()
        self.opacityDragSession = nil
        return value
    }

    /// Returns the pre-drag opacity when there is a preview to revert.
    mutating func beginPinch() -> Double? {
        isPinching = true
        let revertedOpacity = opacityDragSession?.startingOpacity
        if opacityDragSession != nil {
            suppressesOpacityUntilDragEnd = true
        }
        opacityDragSession = nil
        return revertedOpacity
    }

    mutating func endPinch() {
        isPinching = false
    }

    mutating func cancelOpacityDrag() -> Double? {
        let revertedOpacity = opacityDragSession?.startingOpacity
        opacityDragSession = nil
        suppressesOpacityUntilDragEnd = false
        return revertedOpacity
    }

    /// Cancels any preview without persisting it. The original opacity is
    /// returned so switching to Thread-in-front can immediately restore the
    /// last committed appearance before disabling avatar hit testing.
    mutating func cancelAll() -> Double? {
        let revertedOpacity = cancelOpacityDrag()
        self = CaptainAyerOverlayGestureState()
        return revertedOpacity
    }
}

enum LiveTalkConnectionFeedbackPolicy {
    enum SoundAction: Equatable {
        case none
        case start
        case stop
    }

    static func soundAction(
        from previousPhase: LiveTalkConnectionPhase?,
        to phase: LiveTalkConnectionPhase
    ) -> SoundAction {
        guard phase == .starting else { return .stop }
        return previousPhase == .starting ? .none : .start
    }

    static func showsAnimatedRailFeedback(
        during phase: LiveTalkConnectionPhase,
        reduceMotion: Bool
    ) -> Bool {
        phase == .starting && !reduceMotion
    }
}

enum LiveTalkConnectionSoundAsset {
    static let filename = "live-talk-connection"

    @MainActor
    static func url(in mainBundle: Bundle = .main) -> URL? {
        OpenClamAvatarAssetStore
            .findCatalogBundle(in: mainBundle)?
            .url(forResource: filename, withExtension: "wav")
    }
}

/// Owns only the short local connection signature. LiveKit's SoundPlayer
/// coordinates with the SDK audio session, and `.local` prevents this sound
/// from ever reaching the room or the agent's microphone track.
@MainActor
final class LiveTalkConnectionFeedbackController: ObservableObject {
    private var observedPhase: LiveTalkConnectionPhase?
    private var generation = 0
    private var preparationTask: Task<Void, Never>?
    private var soundHandle: SoundHandle?
    private(set) var isSoundRequested = false

    func synchronize(with phase: LiveTalkConnectionPhase) {
        let action = LiveTalkConnectionFeedbackPolicy.soundAction(
            from: observedPhase,
            to: phase
        )
        observedPhase = phase

        switch action {
        case .none:
            break
        case .start:
            start()
        case .stop:
            stop()
        }
    }

    func stop() {
        isSoundRequested = false
        generation &+= 1
        preparationTask?.cancel()
        preparationTask = nil

        guard let handle = soundHandle else { return }
        soundHandle = nil
        Task(priority: .userInitiated) {
            await handle.stop(destination: .local)
            await handle.release()
        }
    }

    func isPlaying(
        destination: SoundPlaybackOptions.Destination
    ) async -> Bool {
        guard let soundHandle else { return false }
        return await soundHandle.isPlaying(destination: destination)
    }

    private func start() {
        guard !isSoundRequested else { return }
        guard let fileURL = LiveTalkConnectionSoundAsset.url() else { return }

        isSoundRequested = true
        generation &+= 1
        let requestedGeneration = generation

        preparationTask = Task { [weak self] in
            do {
                let handle = try await SoundPlayer.shared.prepare(fileURL: fileURL)
                guard let self else {
                    await handle.release()
                    return
                }
                guard !Task.isCancelled,
                      self.isSoundRequested,
                      self.generation == requestedGeneration
                else {
                    await handle.release()
                    return
                }

                self.soundHandle = handle
                self.preparationTask = nil
                do {
                    try await handle.play(
                        options: SoundPlaybackOptions(
                            mode: .replace,
                            loop: true,
                            destination: .local
                        )
                    )
                } catch {
                    await handle.release()
                    if self.soundHandle == handle {
                        self.soundHandle = nil
                        self.isSoundRequested = false
                    }
                }
            } catch {
                guard let self,
                      self.generation == requestedGeneration
                else { return }
                self.preparationTask = nil
                self.isSoundRequested = false
            }
        }
    }

    deinit {
        preparationTask?.cancel()
        if let handle = soundHandle {
            Task(priority: .userInitiated) {
                await handle.stop(destination: .local)
                await handle.release()
            }
        }
    }
}

private struct LiveTalkConnectionRailHalo: View {
    let isActive: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: !LiveTalkConnectionFeedbackPolicy.showsAnimatedRailFeedback(
                    during: isActive ? .starting : .idle,
                    reduceMotion: reduceMotion
                )
            )
        ) { timeline in
            let progress = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.8) / 1.8
            let wave = reduceMotion
                ? 0.0
                : 0.5 - 0.5 * cos(progress * 2.0 * .pi)

            Circle()
                .stroke(OpenClamTheme.active.opacity(0.30 - 0.12 * wave), lineWidth: 1.5)
                .frame(width: 52, height: 52)
                .scaleEffect(0.98 + 0.04 * wave)
                .opacity(isActive ? 1 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A scoped bridge from the conversation's scroll surface to its optional
/// avatar overlay. It carries no UI state, so thread scrolling never causes
/// RootView or the conversation to redraw.
@MainActor
final class CaptainAyerOverlayInteractionRelay: ObservableObject {
    private var threadInteractionHandler: (() -> Void)?
    private var threadScrollInteractionHandler: (() -> Void)?

    func connect(
        _ handler: @escaping () -> Void,
        onScroll scrollHandler: @escaping () -> Void
    ) {
        threadInteractionHandler = handler
        threadScrollInteractionHandler = scrollHandler
    }

    func connect(_ handler: @escaping () -> Void) {
        connect(handler, onScroll: handler)
    }

    func disconnect() {
        threadInteractionHandler = nil
        threadScrollInteractionHandler = nil
    }

    func noteThreadInteraction() {
        threadInteractionHandler?()
    }

    func noteThreadScrollInteraction() {
        threadScrollInteractionHandler?()
    }
}

/// Captain Ayer's local layer over the conversation. The avatar owns only
/// its visible stage and the tool buttons; the navigation bar and composer
/// remain part of OpenClam's live conversation underneath it.
@MainActor
struct CaptainAyerAvatarOverlay: View {
    @EnvironmentObject private var avatarLibrary: OpenClamAvatarLibrary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var controller: CaptainAyerLipSyncController
    @ObservedObject var interactions: CaptainAyerOverlayInteractionRelay
    @StateObject private var faceReactions = CaptainAyerFaceReactionController()
    @StateObject private var faceMirror = CaptainAyerFaceMirrorController()
    @StateObject private var connectionFeedback = LiveTalkConnectionFeedbackController()

    let avatar: OpenClamAvatarDescriptor
    let isTTSEnabled: Bool
    let liveTalkPhase: LiveTalkConnectionPhase
    let composerTopGlobal: CGFloat?
    @Binding var isRailFolded: Bool
    let onPlayLatest: () -> Void
    let onStop: () -> Void
    let onToggleLiveTalk: () -> Void
    let onSelectAvatar: (_ id: String, _ displayName: String) -> Void

    @AppStorage("captainAyer.overlay.opacity")
    private var storedOpacity = CaptainAyerOverlayTuning.initialOpacity
    @AppStorage("captainAyer.overlay.framing")
    private var storedFraming = "closeup"
    @AppStorage("captainAyer.overlay.mode")
    private var storedDisplayMode = ""
    @AppStorage("captainAyer.overlay.standbyScale")
    private var storedStandbyScale = Double(CaptainAyerOverlayTuning.initialScale)
    @AppStorage("captainAyer.overlay.standbyOffsetX")
    private var storedStandbyOffsetX = 0.0
    @AppStorage("captainAyer.overlay.standbyOffsetY")
    private var storedStandbyOffsetY = 0.0
    @AppStorage("captainAyer.overlay.closeUpScale")
    private var storedCloseUpScale = Double(CaptainAyerOverlayTuning.initialScale)
    @AppStorage("captainAyer.overlay.closeUpOffsetX")
    private var storedCloseUpOffsetX = 0.0
    @AppStorage("captainAyer.overlay.closeUpOffsetY")
    private var storedCloseUpOffsetY = 0.0
    @AppStorage("captainAyer.overlay.closeUpFullBodyTransformVersion")
    private var storedCloseUpFullBodyTransformVersion = 0
    @AppStorage("captainAyer.overlay.hidden")
    private var storedAvatarHidden = false
    @AppStorage("captainAyer.overlay.interactionLayer")
    private var storedInteractionLayer = CaptainAyerInteractionLayer.avatar.rawValue
    @State private var opacity = CaptainAyerOverlayTuning.initialOpacity
    @State private var scale = CaptainAyerOverlayTuning.initialScale
    @State private var displayMode = OpenClamAvatarDisplayMode.closeUp
    @State private var standbyOffset = CGPoint.zero
    @State private var closeUpOffset = CGPoint.zero
    @State private var gestureState = CaptainAyerOverlayGestureState()
    @State private var transformSession: OpenClamAvatarTransformSession?
    @State private var isAvatarHidden = false
    @State private var interactionLayer = CaptainAyerInteractionLayer.avatar
    @State private var showsOpacityPanel = false
    @State private var isRailDimmed = false
    @State private var showsAvatarCarousel = false
    @State private var railDimTask: Task<Void, Never>?
    @State private var lastAvatarWakeSignal = -TimeInterval.infinity
    @State private var motionSession = OpenClamAvatarMotionSessionState()
    @State private var motionCompletionTask: Task<Void, Never>?

    private var isCloseUp: Bool { displayMode == .closeUp }
    private var shouldDimRailControls: Bool {
        isRailDimmed
            && !liveTalkPhase.isSessionActive
            && !controller.isSpeaking
    }
    var body: some View {
        GeometryReader { proxy in
            let overlayGlobalMinY = proxy.frame(in: .global).minY
            let stageTop = max(0, proxy.safeAreaInsets.top + 42)
            let subjectBounds = OpenClamAvatarConversationCanvasPolicy.bounds(
                overlaySize: proxy.size,
                overlayGlobalMinY: overlayGlobalMinY,
                composerTopGlobal: composerTopGlobal,
                topInset: stageTop
            )
            let backdropBounds = OpenClamAvatarConversationCanvasPolicy.bounds(
                overlaySize: proxy.size,
                overlayGlobalMinY: overlayGlobalMinY,
                composerTopGlobal: nil,
                topInset: stageTop
            )
            let topClearance = max(58, proxy.safeAreaInsets.top + 46)
            let bottomClearance = max(0, proxy.size.height - subjectBounds.maxY)
            let railHeight = max(
                1,
                subjectBounds.maxY - topClearance
            )
            let presentation = OpenClamAvatarStagePresentationPolicy.presentation(
                for: displayMode
            )
            // Close-up is a visual backdrop and may continue behind the
            // translucent composer. Full-body standby and every motion share
            // the measured composer-top floor so their visible feet remain
            // immediately above the input shell.
            let stageBounds = isCloseUp ? backdropBounds : subjectBounds
            let stageLayout = OpenClamAvatarConversationCanvasPolicy.layout(
                crop: presentation.crop(for: avatar),
                in: stageBounds,
                alignsVisibleFeet: !isCloseUp,
                visibleBottomFraction: OpenClamAvatarConversationCanvasPolicy
                    .fullBodyVisibleBottomFraction(for: avatar)
            )
            let presentedTransform = OpenClamAvatarFramingConstraintPolicy
                .keepingHeadVisible(
                    activeFramingTransform,
                    stageFrame: stageLayout.stageFrame,
                    canvasBounds: stageBounds
                )

            ZStack(alignment: .trailing) {
                if !isAvatarHidden {
                    avatarStage(
                        presentation: presentation,
                        width: stageLayout.stageFrame.width,
                        height: stageLayout.stageFrame.height,
                        canvasSize: stageBounds.size,
                        stageFrame: stageLayout.stageFrame,
                        canvasBounds: stageBounds,
                        presentedScale: presentedTransform.scale
                    )
                    .position(
                        x: stageLayout.stageFrame.midX,
                        y: stageLayout.stageFrame.midY
                    )
                    .offset(
                        x: presentedTransform.normalizedOffset.x * stageBounds.width,
                        y: presentedTransform.normalizedOffset.y * stageBounds.height
                    )
                    // Keep the narrow silhouette gesture surface alive at 0%
                    // opacity so an upward swipe can recover the avatar. The
                    // thread layer still disables the surface completely.
                    .allowsHitTesting(interactionLayer.allowsAvatarGestures)
                    .transition(.opacity)

                    if let kind = motionSession.activeKind,
                       let fileURL = motionFileURL(for: kind),
                       let asset = avatar.motion(kind) {
                        motionLayer(
                            kind: kind,
                            fileURL: fileURL,
                            pixelSize: asset.pixelSize.cgSize,
                            availableSize: subjectBounds.size
                        )
                        .position(x: subjectBounds.midX, y: subjectBounds.midY)
                        .zIndex(10)
                        .transition(.opacity)
                    }
                }

                if showsOpacityPanel, !isRailFolded {
                    opacityPanel
                        .padding(.horizontal, 16)
                        .padding(.trailing, 54)
                        .padding(.bottom, bottomClearance + 12)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if !showsAvatarCarousel {
                    toolRail
                        .frame(width: 64, height: railHeight)
                        .position(
                            x: proxy.size.width - 32,
                            y: topClearance + railHeight / 2
                        )
                        .zIndex(30)
                }

            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading
            )
            .clipped()
        }
        .onAppear {
            // Older builds persisted a separate Hide flag. Migrate that state
            // once to the new, explicit 0% opacity. Its narrow recovery gesture
            // remains active only while the avatar layer is in front.
            if storedAvatarHidden {
                storedOpacity = CaptainAyerOverlayTuning.minimumOpacity
                storedAvatarHidden = false
            }
            opacity = CaptainAyerOverlayTuning.clampedOpacity(storedOpacity)
            if let persistedMode = OpenClamAvatarDisplayMode(
                rawValue: storedDisplayMode
            ), !persistedMode.isMotion {
                displayMode = persistedMode
            } else {
                displayMode = storedFraming == "full" ? .standby : .closeUp
            }
            storedDisplayMode = displayMode.rawValue
            let standby = OpenClamAvatarStandbyTransformPolicy.sanitized(
                scale: CGFloat(storedStandbyScale),
                normalizedOffset: CGPoint(
                    x: storedStandbyOffsetX,
                    y: storedStandbyOffsetY
                )
            )
            storedStandbyScale = Double(standby.scale)
            storedStandbyOffsetX = Double(standby.normalizedOffset.x)
            storedStandbyOffsetY = Double(standby.normalizedOffset.y)
            standbyOffset = standby.normalizedOffset
            let legacyCloseUp = OpenClamAvatarStandbyTransformPolicy.sanitized(
                scale: CGFloat(storedCloseUpScale),
                normalizedOffset: CGPoint(
                    x: storedCloseUpOffsetX,
                    y: storedCloseUpOffsetY
                )
            )
            let closeUp: OpenClamAvatarStandbyTransform
            if storedCloseUpFullBodyTransformVersion
                < OpenClamAvatarFramingPresetPolicy.fullBodyTransformVersion {
                closeUp = OpenClamAvatarFramingPresetPolicy
                    .migratedCloseUpTransform(
                        from: legacyCloseUp,
                        geometry: avatar.geometry
                    )
                storedCloseUpFullBodyTransformVersion =
                    OpenClamAvatarFramingPresetPolicy.fullBodyTransformVersion
            } else {
                closeUp = legacyCloseUp
            }
            storedCloseUpScale = Double(closeUp.scale)
            storedCloseUpOffsetX = Double(closeUp.normalizedOffset.x)
            storedCloseUpOffsetY = Double(closeUp.normalizedOffset.y)
            closeUpOffset = closeUp.normalizedOffset
            scale = displayMode == .standby ? standby.scale : closeUp.scale
            isAvatarHidden = false
            interactionLayer = CaptainAyerInteractionLayer(
                rawValue: storedInteractionLayer
            ) ?? .avatar
            interactions.connect(
                noteThreadInteraction,
                onScroll: noteThreadScrollInteraction
            )
            wakeRail()
            connectionFeedback.synchronize(with: liveTalkPhase)
            motionSession = OpenClamAvatarMotionSessionState()
            motionCompletionTask?.cancel()
            motionCompletionTask = nil
            transformSession = nil
        }
        .onDisappear {
            cancelAvatarGesturePreviews()
            stopAvatarMotion(restoreFraming: false)
            connectionFeedback.stop()
            faceMirror.stop()
            interactions.disconnect()
            railDimTask?.cancel()
            railDimTask = nil
        }
        .onChange(of: liveTalkPhase) { _, phase in
            connectionFeedback.synchronize(with: phase)
            if phase.isSessionActive {
                stopAvatarMotion()
            }
            if !LiveTalkAvatarSwitchPolicy.allowsSwitch(during: phase) {
                showsAvatarCarousel = false
            }
        }
        .onChange(of: isRailFolded) { _, folded in
            if folded {
                showsOpacityPanel = false
            } else {
                wakeRail()
            }
        }
        .onChange(of: controller.isSpeaking) { _, isSpeaking in
            if isSpeaking { stopAvatarMotion() }
        }
        .onChange(of: avatar.id) { _, _ in
            stopAvatarMotion()
        }
        .onChange(of: reduceMotion) { _, isEnabled in
            if isEnabled { stopAvatarMotion() }
        }
        .onChange(of: faceMirror.isEnabled) { _, isEnabled in
            if isEnabled { stopAvatarMotion() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                stopAvatarMotion()
                connectionFeedback.stop()
            }
        }
        .fullScreenCover(isPresented: $showsAvatarCarousel) {
            OpenClamAvatarCarousel(
                avatars: avatarLibrary.avatars,
                activeAvatarID: avatar.id,
                onActivate: { id, displayName in
                    guard LiveTalkAvatarSwitchPolicy.allowsSwitch(
                        during: liveTalkPhase
                    ) else {
                        showsAvatarCarousel = false
                        return
                    }
                    onSelectAvatar(id, displayName)
                    showsAvatarCarousel = false
                },
                onDismiss: {
                    showsAvatarCarousel = false
                }
            )
        }
        .alert(
            item: Binding(
                get: { faceMirror.issue },
                set: { issue in
                    if issue == nil { faceMirror.dismissIssue() }
                }
            )
        ) { issue in
            Alert(
                title: Text(issue.title),
                message: Text(issue.message),
                dismissButton: .default(Text("OK")) {
                    faceMirror.dismissIssue()
                }
            )
        }
    }

    private func avatarStage(
        presentation: OpenClamCatalogAvatarStage.Presentation,
        width: CGFloat,
        height: CGFloat,
        canvasSize: CGSize,
        stageFrame: CGRect,
        canvasBounds: CGRect,
        presentedScale: CGFloat
    ) -> some View {
        return OpenClamCatalogAvatarStage(
            avatar: avatar,
            controller: controller,
            reactions: faceReactions,
            faceMirror: faceMirror,
            presentation: presentation,
            allowsGazeTracking: !faceMirror.isEnabled
                && !gestureState.isPinching
                && !gestureState.hasOpacityDrag,
            showsArtwork: motionSession.activeKind == nil,
            renderOpacity: opacity,
            onVerticalOpacityChanged: updateOpacityDrag,
            onVerticalOpacityEnded: endOpacityDrag,
            onVerticalOpacityCancelled: cancelOpacityDrag,
            onTransformBegan: beginAvatarTransform,
            onTransformChanged: { magnification, translation in
                updateAvatarTransform(
                    magnification: magnification,
                    translation: translation,
                    canvasSize: canvasSize,
                    stageFrame: stageFrame,
                    canvasBounds: canvasBounds
                )
            },
            onTransformEnded: { cancelled in
                endAvatarTransform(
                    cancelled: cancelled,
                    stageFrame: stageFrame,
                    canvasBounds: canvasBounds
                )
            },
            onTapInteraction: dismissOpacityPanel,
            onInteraction: noteAvatarInteraction
        )
        .frame(width: width, height: height)
        .scaleEffect(presentedScale, anchor: .top)
        .compositingGroup()
        // The artwork spans most of the screen but only a narrow silhouette is
        // interactive. Do not publish a full-stage accessibility replacement:
        // it obscures otherwise reachable chat controls in Switch Control and
        // UI automation. The compact rail control below owns the adjustable
        // opacity semantics; physical vertical swiping remains on the stage.
        .accessibilityHidden(true)
        .onHover { hovering in
            if hovering { noteAvatarInteraction() }
        }
    }

    private func motionLayer(
        kind: OpenClamAvatarMotionKind,
        fileURL: URL,
        pixelSize: CGSize,
        availableSize: CGSize
    ) -> some View {
        let layout = OpenClamAvatarMotionLayoutPolicy.layout(
            kind: kind,
            availableSize: availableSize,
            pixelSize: pixelSize
        )
        return ZStack(alignment: .topLeading) {
            OpenClamTransparentMotionPlayer(fileURL: fileURL, kind: kind)
                .frame(
                    width: layout.playerFrame.width,
                    height: layout.playerFrame.height
                )
                .position(
                    x: layout.playerFrame.midX,
                    y: layout.playerFrame.midY
                )
        }
        .frame(
            width: layout.clippingBounds.width,
            height: layout.clippingBounds.height,
            alignment: .topLeading
        )
        .clipped()
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func updateOpacityDrag(verticalTranslation: CGFloat) {
        let beginsDrag = !gestureState.hasOpacityDrag
        guard let previewOpacity = gestureState.updateOpacityDrag(
            startingOpacity: opacity,
            verticalTranslation: verticalTranslation
        ) else { return }
        if beginsDrag {
            wakeRail()
        }
        setOpacity(previewOpacity, persists: false)
    }

    private func endOpacityDrag() {
        guard let completedOpacity = gestureState.completeOpacityDrag() else {
            return
        }
        storedOpacity = completedOpacity
    }

    private func cancelOpacityDrag() {
        guard let revertedOpacity = gestureState.cancelOpacityDrag() else { return }
        setOpacity(revertedOpacity, persists: false)
    }

    private func beginAvatarTransform() {
        guard interactionLayer.allowsAvatarGestures else { return }
        if displayMode.isMotion {
            stopAvatarMotion()
        }
        guard transformSession == nil else { return }
        if let revertedOpacity = gestureState.beginPinch() {
            setOpacity(revertedOpacity, persists: false)
        }
        transformSession = OpenClamAvatarTransformSession(
            mode: displayMode,
            startingTransform: activeFramingTransform
        )
        wakeRail()
    }

    private func updateAvatarTransform(
        magnification: CGFloat,
        translation: CGSize,
        canvasSize: CGSize,
        stageFrame: CGRect,
        canvasBounds: CGRect
    ) {
        if transformSession == nil {
            beginAvatarTransform()
        }
        guard var session = transformSession else { return }
        let unconstrainedPreview = session.update(
            magnification: magnification,
            centroidTranslation: translation,
            canvasSize: canvasSize
        )
        let preview = OpenClamAvatarFramingConstraintPolicy.keepingHeadVisible(
            unconstrainedPreview,
            stageFrame: stageFrame,
            canvasBounds: canvasBounds
        )
        session.replacePreview(with: preview)
        transformSession = session
        applyFramingTransform(preview, for: session.mode)
    }

    private func endAvatarTransform(
        cancelled: Bool,
        stageFrame: CGRect,
        canvasBounds: CGRect
    ) {
        guard let session = transformSession else {
            gestureState.endPinch()
            return
        }
        let candidate = cancelled
            ? session.startingTransform
            : session.previewTransform
        let result = OpenClamAvatarFramingConstraintPolicy.keepingHeadVisible(
            candidate,
            stageFrame: stageFrame,
            canvasBounds: canvasBounds
        )
        applyFramingTransform(result, for: session.mode)
        if !cancelled {
            persistFramingTransform(result, for: session.mode)
        }
        transformSession = nil
        gestureState.endPinch()
    }

    private func cancelAvatarGesturePreviews() {
        if let revertedOpacity = gestureState.cancelAll() {
            setOpacity(revertedOpacity, persists: false)
        }
        if let transformSession {
            applyFramingTransform(
                transformSession.startingTransform,
                for: transformSession.mode
            )
        }
        transformSession = nil
    }

    private var toolRail: some View {
        VStack(spacing: 10) {
            if !isRailFolded {
                VStack(spacing: 10) {
                    liveTalkControl
                        .opacity(
                            liveTalkPhase.isSessionActive
                                ? 1
                                : (shouldDimRailControls
                                    ? CaptainAyerOverlayTuning.railIdleOpacity
                                    : 1)
                        )
                    avatarToolRail
                        .opacity(
                            shouldDimRailControls
                                ? CaptainAyerOverlayTuning.railIdleOpacity
                                : 1
                        )
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .animation(
                    reduceMotion ? nil : .timingCurve(0.25, 1, 0.5, 1, duration: 0.5),
                    value: isRailDimmed
                )
            } else {
                Spacer(minLength: 0)
            }

            railFoldControl
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openclam-avatar-tool-rail")
        .accessibilityValue(shouldDimRailControls ? "Idle" : "Visible")
    }

    private var avatarToolRail: some View {
        VStack(spacing: 10) {
                railButton(
                    systemImage: "person.2",
                    label: "Choose avatar",
                    value: LiveTalkAvatarSwitchPolicy.allowsSwitch(during: liveTalkPhase)
                        ? avatar.displayName
                        : "Unavailable during Live Talk",
                    isEnabled: LiveTalkAvatarSwitchPolicy.allowsSwitch(
                        during: liveTalkPhase
                    )
                ) {
                    stopAvatarMotion()
                    showsOpacityPanel = false
                    showsAvatarCarousel = true
                }
                .accessibilityIdentifier("openclam-avatar-picker")

                avatarModeMenu

                railButton(
                    systemImage: controller.isSpeaking
                        ? "stop"
                        : (isTTSEnabled ? "waveform" : "speaker.slash"),
                    label: controller.isSpeaking ? "Stop speaking" : "Play latest reply",
                    isActive: controller.isSpeaking,
                    isEnabled: !liveTalkPhase.isSessionActive
                ) {
                    stopAvatarMotion()
                    controller.isSpeaking ? onStop() : onPlayLatest()
                }

                interactionLayerButton

                railButton(
                    systemImage: "circle.lefthalf.filled",
                    label: showsOpacityPanel ? "Close opacity control" : "Open opacity control",
                    value: "\(Int(opacity * 100)) percent",
                    isActive: showsOpacityPanel,
                    dismissesOpacityPanel: false
                ) {
                    animate(.toggle) {
                        showsOpacityPanel.toggle()
                    }
                }
                .accessibilityIdentifier("openclam-avatar-opacity-control")

                railButton(
                    systemImage: "face.dashed",
                    label: faceMirror.isEnabled
                        ? "Stop face mirroring"
                        : "Mirror your face",
                    value: faceMirror.statusText,
                    isActive: faceMirror.isEnabled
                ) {
                    if faceMirror.isEnabled {
                        faceMirror.stop()
                    } else {
                        stopAvatarMotion()
                        faceReactions.cancelAll()
                        faceMirror.start()
                    }
                }
        }
    }

    private var railFoldControl: some View {
        railButton(
            systemImage: isRailFolded ? "chevron.right" : "chevron.down",
            label: isRailFolded ? "Show all tools" : "Fold all tools",
            value: isRailFolded ? "Folded" : "Expanded",
            isActive: true
        ) {
            animate(.toggle) {
                isRailFolded.toggle()
            }
        }
        .accessibilityHint("Shows or hides the avatar tool rail")
        .accessibilityIdentifier("openclam-avatar-rail-fold-button")
    }

    private var avatarModeMenu: some View {
        Menu {
            ForEach(OpenClamAvatarDisplayMode.allCases, id: \.self) { mode in
                avatarModeMenuButton(mode)
            }
            Divider()
            Button {
                resetStandbyTransform()
            } label: {
                Label("Reset Standby Size & Position", systemImage: "arrow.counterclockwise")
            }
        } label: {
            railMenuLabel(
                systemImage: "figure.stand",
                isActive: displayMode != .standby
            )
        }
        .accessibilityLabel("Avatar mode")
        .accessibilityValue(displayMode.title)
        .accessibilityHint("Choose Standby, Close-up, Horizon Walk, Edge Idle, or Moves")
        .accessibilityIdentifier("openclam-avatar-mode-menu")
        .simultaneousGesture(TapGesture().onEnded {
            wakeRail()
            dismissOpacityPanel()
        })
    }

    private func avatarModeMenuButton(
        _ mode: OpenClamAvatarDisplayMode
    ) -> some View {
        let disabledReason = mode.motionKind.flatMap(motionDisabledReason)
        let isActive = displayMode == mode
        return Button {
            wakeRail()
            dismissOpacityPanel()
            selectAvatarMode(mode)
        } label: {
            HStack {
                Label(mode.title, systemImage: mode.systemImage)
                if isActive {
                    Image(systemName: "checkmark")
                }
            }
        }
        .disabled(disabledReason != nil)
    }

    private var interactionLayerButton: some View {
        railButton(
            systemImage: interactionLayer == .avatar
                ? "person.crop.rectangle"
                : "text.bubble",
            label: interactionLayer.toggled.title,
            value: interactionLayer.title,
            isActive: interactionLayer == .avatar
        ) {
            wakeRail()
            interactionLayer = interactionLayer.toggled
            storedInteractionLayer = interactionLayer.rawValue
            if interactionLayer == .thread {
                cancelAvatarGesturePreviews()
            }
        }
        .accessibilityLabel("Interaction layer")
        .accessibilityValue(interactionLayer.title)
        .accessibilityHint("Tap to switch to \(interactionLayer.toggled.title.lowercased())")
        .accessibilityIdentifier("openclam-avatar-layer-menu")
    }

    private func railMenuLabel(
        systemImage: String,
        isActive: Bool
    ) -> some View {
        ZStack {
            railControlSurface(isActive: isActive, isBare: false)
            Image(systemName: systemImage)
                .font(railIconFont(isBare: false))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(railForeground(isActive: isActive, isEnabled: true))
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    private var liveTalkControl: some View {
        VStack(spacing: 2) {
            railButton(
                systemImage: liveTalkPhase.isSessionActive ? "phone.down" : "phone",
                label: liveTalkPhase.isSessionActive ? "Hang up Live Talk" : "Start Live Talk",
                value: liveTalkPhase.statusTitle,
                isActive: liveTalkPhase.isSessionActive
            ) {
                stopAvatarMotion()
                if liveTalkPhase.isSessionActive {
                    connectionFeedback.stop()
                }
                onToggleLiveTalk()
            }
            .overlay {
                LiveTalkConnectionRailHalo(
                    isActive: liveTalkPhase == .starting,
                    reduceMotion: reduceMotion
                )
            }
            .accessibilityIdentifier("openclam-live-talk-rail-button")

            if liveTalkPhase.isSessionActive {
                Text(liveTalkPhase.statusTitle)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 54)
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 64)
    }

    private var opacityPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { opacity },
                    set: {
                        wakeRail()
                        setOpacity($0, persists: true)
                    }
                ),
                in: CaptainAyerOverlayTuning.minimumOpacity
                    ... CaptainAyerOverlayTuning.maximumOpacity,
                step: 0.05
            )
            .accessibilityLabel("Avatar opacity")
            // This is a real, laid-out Slider with usable scrubber bounds.
            // Keep the stable identifier here rather than publishing a
            // full-stage or virtual replacement that can obscure chat actions
            // or report zero geometry to assistive clients.
            .accessibilityIdentifier("openclam-avatar-opacity")
            .accessibilityValue("\(Int(opacity * 100)) percent")
            .accessibilityHint("Swipe up or down on the avatar, or adjust here.")

            Text("\(Int(opacity * 100))%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.primary.opacity(0.10), lineWidth: 1)
        }
        .onTapGesture(perform: wakeRail)
        .accessibilityElement(children: .contain)
    }

    private func railButton(
        systemImage: String,
        label: String,
        value: String? = nil,
        isActive: Bool = false,
        isBare: Bool = false,
        isEnabled: Bool = true,
        dismissesOpacityPanel: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            wakeRail()
            if dismissesOpacityPanel {
                dismissOpacityPanel()
            }
            action()
        } label: {
            ZStack {
                railControlSurface(isActive: isActive, isBare: isBare)

                Image(systemName: systemImage)
                    .font(railIconFont(isBare: isBare))
                    .symbolRenderingMode(.monochrome)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .foregroundStyle(railForeground(isActive: isActive, isEnabled: isEnabled))
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.46)
    }

    @ViewBuilder
    private func railControlSurface(
        isActive: Bool,
        isBare: Bool
    ) -> some View {
        if !isBare && isActive {
            Circle()
                .fill(Color.primary.opacity(0.10))
        }
    }

    private func railIconFont(isBare: Bool) -> Font {
        .system(size: isBare ? 21 : 18, weight: .regular)
    }

    private func railForeground(
        isActive: Bool,
        isEnabled: Bool
    ) -> Color {
        guard isEnabled else { return .secondary }
        return isActive ? OpenClamTheme.active : OpenClamTheme.inactive
    }

    private var avatarSpeechAccessibilityValue: String {
        if faceMirror.isEnabled {
            return faceMirror.statusText
        }
        return controller.isSpeaking ? "Speaking" : "Idle"
    }

    private func setOpacity(_ newValue: Double, persists: Bool) {
        opacity = CaptainAyerOverlayTuning.clampedOpacity(newValue)
        if persists {
            storedOpacity = opacity
        }
    }

    private func wakeRail() {
        isRailDimmed = false
        railDimTask?.cancel()
        railDimTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(CaptainAyerOverlayTuning.railFadeDelay))
            guard !Task.isCancelled, !isRailFolded else { return }
            isRailDimmed = true
        }
    }

    private func dismissOpacityPanel() {
        guard showsOpacityPanel else { return }
        animate(.toggle) {
            showsOpacityPanel = false
        }
    }

    private func noteAvatarInteraction() {
        if displayMode.afterUserActivity != displayMode {
            stopAvatarMotion()
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAvatarWakeSignal >= 0.15 else { return }
        lastAvatarWakeSignal = now
        wakeRail()
    }

    private func noteThreadInteraction() {
        dismissOpacityPanel()
        noteThreadScrollInteraction()
    }

    private func noteThreadScrollInteraction() {
        if displayMode.afterUserActivity != displayMode {
            stopAvatarMotion()
        }
        wakeRail()
    }

    private func motionDisabledReason(
        for kind: OpenClamAvatarMotionKind
    ) -> String? {
        OpenClamAvatarMotionAvailabilityPolicy.disabledReason(
            for: OpenClamAvatarMotionRuntimeContext(
                hasAsset: motionFileURL(for: kind) != nil,
                reduceMotion: reduceMotion,
                isSpeaking: controller.isSpeaking,
                isLiveTalkActive: liveTalkPhase.isSessionActive,
                isAvatarHidden: isAvatarHidden,
                isFaceMirrorActive: faceMirror.isEnabled
            )
        )
    }

    private func selectAvatarMode(_ mode: OpenClamAvatarDisplayMode) {
        if transformSession != nil || gestureState.hasOpacityDrag {
            cancelAvatarGesturePreviews()
        }
        guard let kind = mode.motionKind else {
            stopAvatarMotion(restoreFraming: false)
            let transform = mode == .standby
                ? restoredStandbyTransform
                : restoredCloseUpTransform
            animate(.framing) {
                displayMode = mode
                applyFramingTransform(transform, for: mode)
            }
            storedDisplayMode = mode.rawValue
            storedFraming = mode == .standby ? "full" : "closeup"
            return
        }

        let action = motionSession.request(
            kind,
            canStart: motionDisabledReason(for: kind) == nil
        )
        applyMotionAction(action)
    }

    private func resetStandbyTransform() {
        let factory = OpenClamAvatarStandbyTransform.factory
        storedStandbyScale = Double(factory.scale)
        storedStandbyOffsetX = Double(factory.normalizedOffset.x)
        storedStandbyOffsetY = Double(factory.normalizedOffset.y)
        standbyOffset = factory.normalizedOffset
        transformSession = nil
        selectAvatarMode(.standby)
    }

    private func stopAvatarMotion(restoreFraming: Bool = true) {
        applyMotionAction(
            motionSession.interrupt(),
            restoreFraming: restoreFraming
        )
    }

    private func applyMotionAction(
        _ action: OpenClamAvatarMotionSessionAction,
        restoreFraming: Bool = true
    ) {
        switch action {
        case .none:
            return
        case let .start(kind):
            beginAvatarMotion(kind)
        case let .replace(_, kind):
            beginAvatarMotion(kind)
        case .stop:
            motionCompletionTask?.cancel()
            motionCompletionTask = nil
            if restoreFraming {
                let standby = restoredStandbyTransform
                animate(.framing) {
                    displayMode = .standby
                    scale = standby.scale
                    standbyOffset = standby.normalizedOffset
                }
                storedDisplayMode = OpenClamAvatarDisplayMode.standby.rawValue
                storedFraming = "full"
            }
            if !reduceMotion && !faceMirror.isCapturing {
                faceReactions.startAmbientMotion()
            }
        }
    }

    private var restoredStandbyTransform: OpenClamAvatarStandbyTransform {
        OpenClamAvatarStandbyTransformPolicy.sanitized(
            scale: CGFloat(storedStandbyScale),
            normalizedOffset: CGPoint(
                x: storedStandbyOffsetX,
                y: storedStandbyOffsetY
            )
        )
    }

    private var restoredCloseUpTransform: OpenClamAvatarStandbyTransform {
        OpenClamAvatarStandbyTransformPolicy.sanitized(
            scale: CGFloat(storedCloseUpScale),
            normalizedOffset: CGPoint(
                x: storedCloseUpOffsetX,
                y: storedCloseUpOffsetY
            )
        )
    }

    private var activeFramingTransform: OpenClamAvatarStandbyTransform {
        switch displayMode {
        case .standby:
            OpenClamAvatarStandbyTransformPolicy.sanitized(
                scale: scale,
                normalizedOffset: standbyOffset
            )
        case .closeUp:
            OpenClamAvatarStandbyTransformPolicy.sanitized(
                scale: scale,
                normalizedOffset: closeUpOffset
            )
        case .horizonWalk, .edgeIdle, .moves:
            restoredStandbyTransform
        }
    }

    private func applyFramingTransform(
        _ transform: OpenClamAvatarStandbyTransform,
        for mode: OpenClamAvatarDisplayMode
    ) {
        scale = transform.scale
        switch mode {
        case .standby:
            standbyOffset = transform.normalizedOffset
        case .closeUp:
            closeUpOffset = transform.normalizedOffset
        case .horizonWalk, .edgeIdle, .moves:
            break
        }
    }

    private func persistFramingTransform(
        _ transform: OpenClamAvatarStandbyTransform,
        for mode: OpenClamAvatarDisplayMode
    ) {
        switch mode {
        case .standby:
            storedStandbyScale = Double(transform.scale)
            storedStandbyOffsetX = Double(transform.normalizedOffset.x)
            storedStandbyOffsetY = Double(transform.normalizedOffset.y)
        case .closeUp:
            storedCloseUpScale = Double(transform.scale)
            storedCloseUpOffsetX = Double(transform.normalizedOffset.x)
            storedCloseUpOffsetY = Double(transform.normalizedOffset.y)
        case .horizonWalk, .edgeIdle, .moves:
            break
        }
    }

    private func beginAvatarMotion(_ kind: OpenClamAvatarMotionKind) {
        guard let asset = avatar.motion(kind),
              motionFileURL(for: kind) != nil else {
            _ = motionSession.interrupt()
            return
        }
        motionCompletionTask?.cancel()
        motionCompletionTask = nil
        displayMode = OpenClamAvatarDisplayMode(motionKind: kind)
        faceReactions.cancelAll()

        guard !kind.loops else { return }
        let expectedKind = kind
        motionCompletionTask = Task { @MainActor in
            try? await Task.sleep(
                for: .milliseconds(asset.durationMilliseconds + 80)
            )
            guard !Task.isCancelled else { return }
            applyMotionAction(motionSession.complete(expectedKind))
        }
    }

    private func motionFileURL(for kind: OpenClamAvatarMotionKind) -> URL? {
        guard let motion = avatar.motion(kind) else { return nil }
        return OpenClamAvatarAssetStore.shared.resourceURL(for: motion)
    }

    private enum MotionKind {
        case toggle
        case framing
    }

    private func animate(_ kind: MotionKind, updates: () -> Void) {
        guard !reduceMotion else {
            updates()
            return
        }
        let animation: Animation
        switch kind {
        case .toggle:
            animation = .timingCurve(0.65, 0, 0.35, 1, duration: 0.22)
        case .framing:
            animation = .timingCurve(0.25, 1, 0.5, 1, duration: 0.30)
        }
        withAnimation(animation, updates)
    }
}
