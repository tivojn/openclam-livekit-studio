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
            activeKind = nil
            return .stop(kind)
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
    static let minimumOpacity = 0.10
    static let maximumOpacity = 1.0
    static let initialOpacity = 0.14
    static let opacityTravel: CGFloat = 300

    static let minimumScale = 0.60
    static let maximumScale = 4.5
    static let initialScale = 1.0
    static let railFadeDelay: TimeInterval = 4.0
    static let railIdleOpacity = 0.65

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
                .stroke(Color.accentColor.opacity(0.30 - 0.12 * wave), lineWidth: 1.5)
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

    func connect(_ handler: @escaping () -> Void) {
        threadInteractionHandler = handler
    }

    func disconnect() {
        threadInteractionHandler = nil
    }

    func noteThreadInteraction() {
        threadInteractionHandler?()
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
    let onPlayLatest: () -> Void
    let onStop: () -> Void
    let onToggleLiveTalk: () -> Void
    let onSelectAvatar: (_ id: String, _ displayName: String) -> Void

    @AppStorage("captainAyer.overlay.opacity")
    private var storedOpacity = CaptainAyerOverlayTuning.initialOpacity
    @AppStorage("captainAyer.overlay.framing")
    private var storedFraming = "closeup"
    @AppStorage("captainAyer.overlay.railFolded")
    private var storedRailFolded = false

    @State private var opacity = CaptainAyerOverlayTuning.initialOpacity
    @State private var scale = CaptainAyerOverlayTuning.initialScale
    @State private var isHeadAnchored = false
    @State private var gestureState = CaptainAyerOverlayGestureState()
    @State private var scaleAtPinchStart: CGFloat?
    @State private var isAvatarHidden = false
    @State private var isRailFolded = false
    @State private var showsOpacityPanel = false
    @State private var isRailDimmed = false
    @State private var showsAvatarCarousel = false
    @State private var railDimTask: Task<Void, Never>?
    @State private var lastAvatarWakeSignal = -TimeInterval.infinity
    @State private var motionSession = OpenClamAvatarMotionSessionState()
    @State private var motionCompletionTask: Task<Void, Never>?
    @State private var scaleBeforeMotion: CGFloat?
    @State private var headAnchoredBeforeMotion: Bool?

    var body: some View {
        GeometryReader { proxy in
            let topClearance = max(58, proxy.safeAreaInsets.top + 46)
            let bottomClearance = max(116, proxy.safeAreaInsets.bottom + 92)
            let railHeight = max(
                220,
                proxy.size.height - topClearance - bottomClearance
            )
            let bodySize = avatar.geometry.bodySize.cgSize
            let stageWidth = proxy.size.width
            let stageHeight = max(
                1,
                stageWidth * bodySize.height / max(1, bodySize.width)
            )
            let stageTop = max(0, proxy.safeAreaInsets.top + 42)

            ZStack(alignment: .trailing) {
                if !isAvatarHidden {
                    avatarStage(
                        width: stageWidth,
                        height: stageHeight
                    )
                    .position(
                        x: proxy.size.width / 2,
                        y: stageTop + stageHeight / 2
                    )
                    .transition(.opacity)
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
        }
        .onAppear {
            opacity = CaptainAyerOverlayTuning.clampedOpacity(storedOpacity)
            isHeadAnchored = storedFraming != "full"
            scale = isHeadAnchored ? 3.4 : CaptainAyerOverlayTuning.initialScale
            isAvatarHidden = false
            isRailFolded = storedRailFolded
            interactions.connect(wakeRail)
            wakeRail()
            connectionFeedback.synchronize(with: liveTalkPhase)
            motionSession = OpenClamAvatarMotionSessionState()
            motionCompletionTask?.cancel()
            motionCompletionTask = nil
            scaleBeforeMotion = nil
            headAnchoredBeforeMotion = nil
        }
        .onDisappear {
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

    private func avatarStage(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            OpenClamCatalogAvatarStage(
                avatar: avatar,
                controller: controller,
                reactions: faceReactions,
                faceMirror: faceMirror,
                presentation: .expanded,
                allowsGazeTracking: !faceMirror.isEnabled
                    && !gestureState.isPinching
                    && !gestureState.hasOpacityDrag,
                showsArtwork: motionSession.activeKind == nil,
                renderOpacity: opacity,
                onVerticalOpacityChanged: updateOpacityDrag,
                onVerticalOpacityEnded: endOpacityDrag,
                onMagnificationChanged: updatePinch,
                onMagnificationEnded: endPinch,
                onInteraction: noteAvatarInteraction
            )

            if let kind = motionSession.activeKind,
               let fileURL = motionFileURL(for: kind) {
                OpenClamTransparentMotionPlayer(fileURL: fileURL, kind: kind)
                    .opacity(opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: width, height: height)
        .scaleEffect(scale, anchor: isHeadAnchored ? .top : .center)
        .compositingGroup()
        // The artwork spans most of the screen but only a narrow silhouette is
        // interactive. Do not publish a full-stage accessibility replacement:
        // it obscures otherwise reachable chat controls in Switch Control and
        // UI automation. The compact rail control below owns the adjustable
        // opacity semantics; physical vertical swiping remains on the stage.
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

    private func updatePinch(magnification: CGFloat) {
        if scaleAtPinchStart == nil {
            stopAvatarMotion()
            if let revertedOpacity = gestureState.beginPinch() {
                setOpacity(revertedOpacity, persists: false)
            }
            scaleAtPinchStart = scale
            wakeRail()
        }
        guard let scaleAtPinchStart else { return }
        scale = CaptainAyerOverlayTuning.clampedScale(
            scaleAtPinchStart * magnification
        )
        isHeadAnchored = scale > 1.4
    }

    private func endPinch() {
        scaleAtPinchStart = nil
        gestureState.endPinch()
    }

    private var toolRail: some View {
        VStack(spacing: 10) {
            liveTalkControl

            avatarToolRail
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openclam-avatar-tool-rail")
        .accessibilityValue(isRailDimmed ? "Idle" : "Visible")
    }

    private var avatarToolRail: some View {
        VStack(spacing: 10) {
            if !isRailFolded {
                railButton(
                    systemImage: "person.2.fill",
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

                railButton(
                    systemImage: isHeadAnchored ? "person.fill" : "person.crop.circle",
                    label: isHeadAnchored ? "Show full body" : "Show face closeup",
                    value: "\(Int(scale * 100)) percent"
                ) {
                    stopAvatarMotion()
                    animate(.framing) {
                        isHeadAnchored.toggle()
                        scale = isHeadAnchored ? 3.4 : CaptainAyerOverlayTuning.initialScale
                        storedFraming = isHeadAnchored ? "closeup" : "full"
                    }
                }

                motionRailButton(
                    kind: .walk,
                    systemImage: "figure.walk"
                )
                .accessibilityIdentifier("openclam-avatar-walk-button")

                motionRailButton(
                    kind: .edgeIdle,
                    systemImage: "figure.stand.line.dotted.figure.stand"
                )
                .accessibilityIdentifier("openclam-avatar-edge-idle-button")

                motionRailButton(
                    kind: .moves,
                    systemImage: "figure.dance"
                )
                .accessibilityIdentifier("openclam-avatar-moves-button")

                railButton(
                    systemImage: controller.isSpeaking
                        ? "stop.fill"
                        : (isTTSEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"),
                    label: controller.isSpeaking ? "Stop speaking" : "Play latest reply",
                    isActive: controller.isSpeaking,
                    isEnabled: !liveTalkPhase.isSessionActive
                ) {
                    stopAvatarMotion()
                    controller.isSpeaking ? onStop() : onPlayLatest()
                }

                railButton(
                    systemImage: isAvatarHidden ? "eye.slash.fill" : "eye.fill",
                    label: isAvatarHidden ? "Show \(avatar.displayName)" : "Hide \(avatar.displayName)",
                    isActive: isAvatarHidden
                ) {
                    if !isAvatarHidden {
                        stopAvatarMotion()
                    }
                    animate(.toggle) {
                        isAvatarHidden.toggle()
                        if isAvatarHidden {
                            faceMirror.stop()
                            showsOpacityPanel = false
                        }
                    }
                }

                railButton(
                    systemImage: "drop.fill",
                    label: showsOpacityPanel ? "Close opacity control" : "Open opacity control",
                    value: "\(Int(opacity * 100)) percent",
                    isActive: showsOpacityPanel
                ) {
                    animate(.toggle) {
                        showsOpacityPanel.toggle()
                    }
                }
                .accessibilityIdentifier("openclam-avatar-opacity-control")

                railButton(
                    systemImage: "face.smiling",
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

            railButton(
                systemImage: isRailFolded ? "chevron.up" : "chevron.down",
                label: isRailFolded ? "Show avatar tools" : "Fold avatar tools",
                isBare: true
            ) {
                animate(.toggle) {
                    isRailFolded.toggle()
                    storedRailFolded = isRailFolded
                    if isRailFolded {
                        showsOpacityPanel = false
                    }
                }
            }
            .accessibilityIdentifier("openclam-avatar-rail-fold-button")
        }
        .opacity(isRailDimmed ? CaptainAyerOverlayTuning.railIdleOpacity : 1)
        .animation(
            reduceMotion ? nil : .timingCurve(0.25, 1, 0.5, 1, duration: 0.5),
            value: isRailDimmed
        )
    }

    private var liveTalkControl: some View {
        VStack(spacing: 2) {
            railButton(
                systemImage: liveTalkPhase.isSessionActive ? "phone.down.fill" : "phone.fill",
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
            Image(systemName: "drop.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { opacity },
                    set: { setOpacity($0, persists: true) }
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
        action: @escaping () -> Void
    ) -> some View {
        Button {
            wakeRail()
            action()
        } label: {
            ZStack {
                if !isBare {
                    Circle()
                        .fill(
                            isActive
                                ? Color.primary.opacity(0.90)
                                : Color(uiColor: .systemBackground).opacity(0.84)
                        )
                        .overlay {
                            Circle()
                                .stroke(.primary.opacity(0.12), lineWidth: 1)
                        }
                }

                Image(systemName: systemImage)
                    .font(.system(size: isBare ? 22 : 18, weight: .semibold))
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .shadow(color: isBare ? .clear : .black.opacity(0.10), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .foregroundStyle(
            isActive && !isBare
                ? Color(uiColor: .systemBackground)
                : Color.primary
        )
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
    }

    private func motionRailButton(
        kind: OpenClamAvatarMotionKind,
        systemImage: String
    ) -> some View {
        let disabledReason = motionDisabledReason(for: kind)
        let isActive = motionSession.activeKind == kind
        let label: String = switch kind {
        case .walk: "Walk"
        case .edgeIdle: "Edge idle"
        case .moves: "Moves"
        }
        return railButton(
            systemImage: isActive ? "stop.fill" : systemImage,
            label: isActive ? "Stop \(label.lowercased())" : "Play \(label.lowercased())",
            value: isActive ? "Playing" : (disabledReason ?? "Ready"),
            isActive: isActive,
            isEnabled: disabledReason == nil
        ) {
            toggleAvatarMotion(kind)
        }
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
            guard !Task.isCancelled else { return }
            isRailDimmed = true
        }
    }

    private func noteAvatarInteraction() {
        stopAvatarMotion()
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAvatarWakeSignal >= 0.15 else { return }
        lastAvatarWakeSignal = now
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

    private func toggleAvatarMotion(_ kind: OpenClamAvatarMotionKind) {
        let action = motionSession.request(
            kind,
            canStart: motionDisabledReason(for: kind) == nil
        )
        applyMotionAction(action)
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
            beginAvatarMotion(kind, savesFraming: true)
        case let .replace(_, kind):
            beginAvatarMotion(kind, savesFraming: false)
        case .stop:
            motionCompletionTask?.cancel()
            motionCompletionTask = nil
            if restoreFraming,
               let scaleBeforeMotion,
               let headAnchoredBeforeMotion {
                animate(.framing) {
                    scale = scaleBeforeMotion
                    isHeadAnchored = headAnchoredBeforeMotion
                }
            }
            self.scaleBeforeMotion = nil
            self.headAnchoredBeforeMotion = nil
            if !reduceMotion && !faceMirror.isCapturing {
                faceReactions.startAmbientMotion()
            }
        }
    }

    private func beginAvatarMotion(
        _ kind: OpenClamAvatarMotionKind,
        savesFraming: Bool
    ) {
        guard let asset = avatar.motion(kind),
              motionFileURL(for: kind) != nil else {
            _ = motionSession.interrupt()
            return
        }
        motionCompletionTask?.cancel()
        motionCompletionTask = nil
        if savesFraming {
            scaleBeforeMotion = scale
            headAnchoredBeforeMotion = isHeadAnchored
        }
        faceReactions.cancelAll()
        animate(.framing) {
            scale = CaptainAyerOverlayTuning.initialScale
            isHeadAnchored = false
        }

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
