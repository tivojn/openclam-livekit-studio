import LiveKit
import SwiftUI

enum CaptainAyerOverlayTuning {
    static let minimumOpacity = 0.10
    static let maximumOpacity = 1.0
    static let initialOpacity = 0.14
    static let opacityTravel: CGFloat = 300
    static let verticalDragThreshold: CGFloat = 24

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
    @State private var opacityAtDragStart: Double?
    @State private var scaleAtPinchStart: CGFloat?
    @State private var isPinching = false
    @State private var isAvatarHidden = false
    @State private var isRailFolded = false
    @State private var showsOpacityPanel = false
    @State private var isRailDimmed = false
    @State private var showsAvatarCarousel = false
    @State private var railDimTask: Task<Void, Never>?
    @State private var lastAvatarWakeSignal = -TimeInterval.infinity

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
        }
        .onDisappear {
            connectionFeedback.stop()
            faceMirror.stop()
            interactions.disconnect()
            railDimTask?.cancel()
            railDimTask = nil
        }
        .onChange(of: liveTalkPhase) { _, phase in
            connectionFeedback.synchronize(with: phase)
            if !LiveTalkAvatarSwitchPolicy.allowsSwitch(during: phase) {
                showsAvatarCarousel = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
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
        OpenClamCatalogAvatarStage(
            avatar: avatar,
            controller: controller,
            reactions: faceReactions,
            faceMirror: faceMirror,
            presentation: .expanded,
            allowsGazeTracking: !faceMirror.isEnabled
                && !isPinching
                && opacityAtDragStart == nil,
            onInteraction: noteAvatarInteraction
        )
        .frame(width: width, height: height)
        .scaleEffect(scale, anchor: isHeadAnchored ? .top : .center)
        .compositingGroup()
        .opacity(opacity)
        .contentShape(Rectangle())
        .highPriorityGesture(verticalOpacityGesture)
        .simultaneousGesture(pinchGesture)
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { opacity },
                    set: { setOpacity($0, persists: true) }
                ),
                in: CaptainAyerOverlayTuning.minimumOpacity
                    ... CaptainAyerOverlayTuning.maximumOpacity,
                step: 0.05
            ) {
                Text("\(avatar.displayName) opacity")
            }
            .accessibilityValue("\(Int(opacity * 100)) percent")
            .accessibilityHint("Swipe up or down to change avatar opacity.")
            .accessibilityCustomContent("Speech", avatarSpeechAccessibilityValue)
            .accessibilityCustomContent("Size", "\(Int(scale * 100)) percent")
        }
    }

    private var verticalOpacityGesture: some Gesture {
        DragGesture(minimumDistance: CaptainAyerOverlayTuning.verticalDragThreshold)
            .onChanged { value in
                guard !isPinching else { return }
                let verticalDistance = abs(value.translation.height)
                guard verticalDistance >= abs(value.translation.width) else { return }

                if opacityAtDragStart == nil {
                    opacityAtDragStart = opacity
                    wakeRail()
                }
                guard let opacityAtDragStart else { return }
                setOpacity(
                    CaptainAyerOverlayTuning.opacity(
                        from: opacityAtDragStart,
                        verticalTranslation: value.translation.height
                    ),
                    persists: false
                )
            }
            .onEnded { _ in
                if opacityAtDragStart != nil {
                    storedOpacity = opacity
                }
                opacityAtDragStart = nil
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if scaleAtPinchStart == nil {
                    scaleAtPinchStart = scale
                    wakeRail()
                }
                isPinching = true
                guard let scaleAtPinchStart else { return }
                scale = CaptainAyerOverlayTuning.clampedScale(
                    scaleAtPinchStart * value.magnification
                )
                isHeadAnchored = scale > 1.4
            }
            .onEnded { _ in
                scaleAtPinchStart = nil
                isPinching = false
            }
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
                    showsOpacityPanel = false
                    showsAvatarCarousel = true
                }

                railButton(
                    systemImage: isHeadAnchored ? "person.fill" : "person.crop.circle",
                    label: isHeadAnchored ? "Show full body" : "Show face closeup",
                    value: "\(Int(scale * 100)) percent"
                ) {
                    animate(.framing) {
                        isHeadAnchored.toggle()
                        scale = isHeadAnchored ? 3.4 : CaptainAyerOverlayTuning.initialScale
                        storedFraming = isHeadAnchored ? "closeup" : "full"
                    }
                }

                railButton(
                    systemImage: controller.isSpeaking
                        ? "stop.fill"
                        : (isTTSEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"),
                    label: controller.isSpeaking ? "Stop speaking" : "Play latest reply",
                    isActive: controller.isSpeaking,
                    isEnabled: !liveTalkPhase.isSessionActive
                ) {
                    controller.isSpeaking ? onStop() : onPlayLatest()
                }

                railButton(
                    systemImage: isAvatarHidden ? "eye.slash.fill" : "eye.fill",
                    label: isAvatarHidden ? "Show \(avatar.displayName)" : "Hide \(avatar.displayName)",
                    isActive: isAvatarHidden
                ) {
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
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAvatarWakeSignal >= 0.15 else { return }
        lastAvatarWakeSignal = now
        wakeRail()
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
