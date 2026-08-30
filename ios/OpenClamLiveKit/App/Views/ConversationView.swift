import Accessibility
import AVKit
import CoreTransferable
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ConversationMicrophoneOwnership {
    static let liveTalkPTTGuidance = "Hang up Live Talk before tap-to-talk."

    static func tapToTalkBlockReason(
        liveTalkPhase: LiveTalkConnectionPhase
    ) -> String? {
        liveTalkPhase.isSessionActive ? liveTalkPTTGuidance : nil
    }
}

enum ConversationLiveTalkNavigationPolicy {
    static func sidebarBlockReason(
        liveTalkPhase: LiveTalkConnectionPhase
    ) -> String? {
        guard !LiveTalkAvatarSwitchPolicy.allowsSwitch(during: liveTalkPhase) else {
            return nil
        }
        return LiveTalkAvatarSwitchPolicy.blockedGuidance
    }
}

enum ConversationNavigationTitlePresentation {
    static func title(
        threadTitle: String,
        remoteAgentDisplayName: String?,
        isRemoteTurnActive: Bool
    ) -> String {
        guard let remoteAgentDisplayName = remoteAgentDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !remoteAgentDisplayName.isEmpty else {
            return threadTitle
        }

        return isRemoteTurnActive
            ? "Typing..."
            : "OpenClaw - \(remoteAgentDisplayName)"
    }
}

enum ConversationReviewRevealPolicy {
    static let pendingEmailAnchorID = "openclam-pending-email-review"

    static func shouldRevealPendingEmail(
        previousID: UUID?,
        currentID: UUID?
    ) -> Bool {
        currentID != nil && currentID != previousID
    }
}

enum ConversationComposerLayout {
    // The rounded composer already provides ten points around its children.
    // These are the text editor's own insets, keeping the insertion point and
    // placeholder away from that outer edge without moving the controls row.
    static let textHorizontalInset: CGFloat = 12
    static let textVerticalInset: CGFloat = 8
    static let minimumExpandedTextHeight: CGFloat = 62
    static let restingReservedHeight: CGFloat = 72
    static let threadClearance: CGFloat = 8
}

private struct ConversationComposerTopPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(
        value: inout CGFloat?,
        nextValue: () -> CGFloat?
    ) {
        value = nextValue() ?? value
    }
}

private struct ConversationComposerHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(
        value: inout CGFloat,
        nextValue: () -> CGFloat
    ) {
        value = nextValue()
    }
}

enum ConversationSpeechStatusCopy {
    static func listening(
        selection: AIServiceSelection,
        providerName: String
    ) -> String {
        let model = selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if selection.provider == .xAI,
           model == AIProviderRegistry.xAILiveSpeechToTextModel {
            return "Live text with xAI · words appear as you speak · tap Stop"
        }
        if selection.provider == .xAI,
           model == AIProviderRegistry.xAIBatchSpeechToTextModel {
            return "Recording with xAI Batch · transcript appears after Stop"
        }
        return "Listening with \(providerName) · tap Stop"
    }
}

enum ConversationThreadLayout {
    static let horizontalContentInset: CGFloat = 16
    static let avatarRailWidth: CGFloat = 64
    static let avatarRailTextClearance: CGFloat = 12
    static let trailingMessageInset = avatarRailWidth + avatarRailTextClearance
    static let standardAnchoredTurnTopClearance: CGFloat = 64
    static let accessibilityAnchoredTurnTopClearance: CGFloat = 80
    static let userBubbleMaximumWidth: CGFloat = 560
    static let userBubbleMaximumWidthFraction: CGFloat = 0.85
    static let userBubbleMinimumWidth: CGFloat = 44
    static let userBubbleHorizontalPadding: CGFloat = 28
    // UITextView's typographic fit can be slightly wider than NSString's single-line estimate.
    // Keep a small reserve so a content-sized bubble never clips its final word at the edge.
    static let userBubbleTextMeasurementSafety: CGFloat = 16
    static let standardUserTurnHeightAllowance: CGFloat = 40
    static let accessibilityUserTurnHeightAllowance: CGFloat = 72
    static let minimumStandardResponseReserve: CGFloat = 240
    static let minimumAccessibilityResponseReserve: CGFloat = 320

    /// Keeps enough content below a newly submitted user turn for ScrollView to
    /// place that turn at the top of its viewport. The larger accessibility
    /// floor accommodates a multi-line user bubble without relying on a fixed
    /// font height; subtracting only the bubble allowance adapts to every
    /// phone and keyboard viewport while guaranteeing a valid top anchor.
    static func responseReserveHeight(
        viewportHeight: CGFloat,
        usesAccessibilityType: Bool
    ) -> CGFloat {
        let boundedHeight = max(0, viewportHeight)
        let userTurnAllowance = usesAccessibilityType
            ? accessibilityUserTurnHeightAllowance
            : standardUserTurnHeightAllowance
        let minimum = usesAccessibilityType
            ? minimumAccessibilityResponseReserve
            : minimumStandardResponseReserve
        return max(minimum, boundedHeight - userTurnAllowance)
    }

    static func anchoredTurnTopClearance(
        usesAccessibilityType: Bool
    ) -> CGFloat {
        usesAccessibilityType
            ? accessibilityAnchoredTurnTopClearance
            : standardAnchoredTurnTopClearance
    }

    static func userBubbleWidth(
        viewportWidth: CGFloat,
        naturalTextWidth: CGFloat,
        hasAttachments: Bool
    ) -> CGFloat {
        let availableWidth = messageLaneWidth(viewportWidth: viewportWidth)
        let maximumWidth = min(
            availableWidth,
            userBubbleMaximumWidth,
            max(userBubbleMinimumWidth, availableWidth * userBubbleMaximumWidthFraction)
        )
        let desiredWidth = hasAttachments
            ? maximumWidth
            : max(0, naturalTextWidth)
                + userBubbleHorizontalPadding
                + userBubbleTextMeasurementSafety
        return min(maximumWidth, max(userBubbleMinimumWidth, desiredWidth))
    }

    /// The avatar tool rail owns the physical trailing edge of the screen.
    /// Keep every transcript row to its left so text remains readable while
    /// the transparent space between rail buttons can still scroll normally.
    static func messageLaneWidth(viewportWidth: CGFloat) -> CGFloat {
        max(
            0,
            viewportWidth - horizontalContentInset - trailingMessageInset
        )
    }

    /// The stack already supplies `horizontalContentInset` on both sides, so
    /// rows need only the difference to establish the full trailing safe lane.
    static var additionalMessageRowTrailingPadding: CGFloat {
        max(0, trailingMessageInset - horizontalContentInset)
    }
}

enum ConversationThreadScrollDirective: Equatable {
    case placeUserTurn(UUID)
    case followLatest
    case preservePosition
}

struct ConversationThreadPositioningState: Equatable {
    private(set) var anchoredUserMessageID: UUID?
    private(set) var hasManualScrollSincePlacement = false
    private(set) var isAwayFromLatest = false

    var shouldFollowLatest: Bool {
        anchoredUserMessageID == nil && !hasManualScrollSincePlacement
    }

    mutating func beginUserTurn(messageID: UUID) {
        anchoredUserMessageID = messageID
        hasManualScrollSincePlacement = false
        isAwayFromLatest = false
    }

    mutating func noteManualScroll() {
        hasManualScrollSincePlacement = true
    }

    mutating func noteLatestVisibility(_ isLatestVisible: Bool) {
        if isLatestVisible {
            resumeFollowingLatest()
        } else {
            hasManualScrollSincePlacement = true
            isAwayFromLatest = true
        }
    }

    mutating func resumeFollowingLatest() {
        anchoredUserMessageID = nil
        hasManualScrollSincePlacement = false
        isAwayFromLatest = false
    }

    /// A newly submitted user turn always owns placement, including when a
    /// very fast local answer is coalesced into the same SwiftUI update. Once
    /// placed, its anchor stays active while the answer is appended so the
    /// response grows below it instead of collapsing the whole turn back to
    /// the composer's bottom edge.
    mutating func receiveAppendedMessages(
        userMessageID: UUID?,
        assistantMessageID: UUID?
    ) -> ConversationThreadScrollDirective {
        if let userMessageID {
            beginUserTurn(messageID: userMessageID)
            return .placeUserTurn(userMessageID)
        }

        if assistantMessageID != nil, anchoredUserMessageID != nil {
            return .preservePosition
        }

        return shouldFollowLatest ? .followLatest : .preservePosition
    }

    mutating func resetForThreadChange() {
        resumeFollowingLatest()
    }
}

struct ConversationComposerTextInsets: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, ConversationComposerLayout.textHorizontalInset)
            .padding(.vertical, ConversationComposerLayout.textVerticalInset)
            .contentShape(Rectangle())
    }
}

struct ConversationView: View {
    @EnvironmentObject private var commandModel: AssistantModel
    @EnvironmentObject private var conversation: ConversationModel
    @EnvironmentObject private var aiConfiguration: AIConfigurationModel
    @EnvironmentObject private var agentConnections: AgentConnectionModel
    @EnvironmentObject private var avatarLibrary: OpenClamAvatarLibrary
    @EnvironmentObject private var keyboardDictationHost: OpenClamKeyboardDictationHostController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var speech = SpeechInputController()
    @State private var input = ""
    @State private var selectedMedia: [PhotosPickerItem] = []
    @State private var stagedAttachments: [StagedAgentAttachment] = []
    @State private var isLoadingAttachments = false
    @State private var attachmentPreparationTask: Task<Void, Never>?
    @State private var attachmentPreparationID: UUID?
    @State private var showsMediaPicker = false
    @State private var showsCamera = false
    @State private var showsFileImporter = false
    @State private var photoError: String?
    @State private var activeRequestTask: Task<Void, Never>?
    @State private var activeRequestID: UUID?
    @State private var confirmedActionNotice: String?
    @State private var confirmedActionSucceeded = true
    @State private var modelSelectionError: String?
    @State private var suppressesSpeechError = false
    @State private var expandsComposerForEditing = false
    @State private var readAloudMessageID: UUID?
    @State private var assistantReplyDeliveryBoundary = AssistantReplyDeliveryBoundary()
    @State private var userTurnPlacementBoundary = ConversationUserTurnPlacementBoundary()
    @State private var threadPositioning = ConversationThreadPositioningState()
    @State private var activeSessionImagePreviews: [UUID: UIImage] = [:]
    @State private var activeSessionImagePreviewOrder: [UUID] = []
    @State private var persistedConnectorVisualPreviews: [UUID: UIImage] = [:]
    @State private var presentedConnectorArtifact: ConnectorArtifactPresentation?
    @State private var sharedConnectorArtifact: ConnectorArtifactPresentation?
    @State private var exportedConnectorArtifact: ConnectorArtifactExportPresentation?
    @State private var connectorArtifactFeedback: ConnectorArtifactFeedback?
    @State private var expandedWorkSteps: Set<String> = []
    @State private var remoteWorkStartedAt: [UUID: Date] = [:]
    @State private var warmEarEnabled = OpenClamWarmEarControl.isEnabled
    @AppStorage("captainAyer.overlay.railFolded.v2")
    private var isAvatarRailFolded = true
    @StateObject private var avatarInteractions = CaptainAyerOverlayInteractionRelay()
    @StateObject private var liveTalk = LiveTalkSessionController()
    @State private var liveTalkPTTNotice: String?
    @State private var composerTopGlobal: CGFloat?
    @State private var composerHeight = ConversationComposerLayout.restingReservedHeight
    @State private var goToLatestMessageRequest = 0
    @FocusState private var isComposerFocused: Bool

    let onShowSidebar: () -> Void
    let onSelectAvatar: (_ id: String, _ displayName: String) -> Void
    let onShowAISettings: () -> Void
    let onShowAgentConnections: () -> Void

    var body: some View { lifecycleObservedSurface }

    private var baseConversationSurface: some View {
        ZStack {
            GeometryReader { threadViewport in
                ScrollViewReader { proxy in
                    observedThreadScroll(in: threadViewport, proxy: proxy)
                }
            }

            avatarOverlay
                .zIndex(2)
                .ignoresSafeArea()
                // The overlay publishes hit regions only for the visible avatar
                // silhouette and actual rail controls. Its transparent geometry
                // must never replace the conversation's native scroll surface.
        }
        .navigationTitle(conversationNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            composer
                // The composer floats over the shared thread/avatar canvas.
                // Text reserves its own scroll margin below, while close-up
                // artwork may remain visible through the material shell.
                .zIndex(100)
                .contentShape(Rectangle())
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ConversationComposerHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                }
        }
        .onPreferenceChange(ConversationComposerTopPreferenceKey.self) { top in
            guard let top, top.isFinite else { return }
            composerTopGlobal = top
        }
        .onPreferenceChange(ConversationComposerHeightPreferenceKey.self) { height in
            guard height.isFinite, height > 0 else { return }
            composerHeight = height
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismissKeyboard()
                    if let reason = ConversationLiveTalkNavigationPolicy.sidebarBlockReason(
                        liveTalkPhase: liveTalk.phase
                    ) {
                        liveTalkPTTNotice = reason
                        return
                    }
                    onShowSidebar()
                } label: {
                    Label("Open sidebar", systemImage: "sidebar.left")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .accessibilityHint("Shows new chat, recent chats, and Settings")
            }

            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarTrailing) {
                    warmEarToolbarButton
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    warmEarToolbarButton
                }
            }
        }
    }

    private var warmEarToolbarButton: some View {
        Button {
            dismissKeyboard()
            if !warmEarEnabled, appAudioActivityIsActive {
                liveTalkPTTNotice = "Finish the current microphone or speaker activity before preparing Quick Dictation."
                return
            }
            warmEarEnabled.toggle()
            OpenClamWarmEarControl.setEnabled(warmEarEnabled)
            liveTalkPTTNotice = OpenClamWarmEarControl.availabilityExplanation
        } label: {
            Image(systemName: keyboardDictationHost.warmEarPresentationState.symbolName)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentTransition(.symbolEffect(.replace))
        }
        .foregroundStyle(quickDictationStatusColor)
        .accessibilityLabel("Quick Dictation")
        .accessibilityValue(keyboardDictationHost.warmEarPresentationState.title)
        .accessibilityHint(keyboardDictationHost.warmEarPresentationState.detail)
        .accessibilityIdentifier("openclam-warm-ear-button")
        .buttonStyle(.plain)
    }

    private var mediaObservedSurface: some View {
        baseConversationSurface
        .onChange(of: selectedMedia) { _, items in
            guard !items.isEmpty else { return }
            beginAttachmentPreparation { requestID in
                await stageSelectedMedia(items, requestID: requestID)
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleImportedFiles
        )
        .photosPicker(
            isPresented: $showsMediaPicker,
            selection: $selectedMedia,
            maxSelectionCount: max(1, 4 - stagedAttachments.count),
            matching: .any(of: [.images, .videos])
        )
        .fullScreenCover(isPresented: $showsCamera) {
            OpenClamCameraPicker(
                onCapture: { image in
                    showsCamera = false
                    beginAttachmentPreparation { requestID in
                        await stageCameraImage(image, requestID: requestID)
                    }
                },
                onCancel: {
                    showsCamera = false
                }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $presentedConnectorArtifact) { presentation in
            ConnectorArtifactPreview(presentation: presentation)
        }
        .sheet(item: $sharedConnectorArtifact) { presentation in
            ConnectorArtifactShareSheet(url: presentation.url)
        }
        .sheet(
            item: $exportedConnectorArtifact,
            onDismiss: clearConnectorArtifactExport
        ) { presentation in
            ConnectorArtifactFilesExporter(url: presentation.stagedURL) { destinationURL in
                handleConnectorArtifactExportCompletion(destinationURL: destinationURL)
            }
        }
    }

    private var conversationObservedSurface: some View {
        mediaObservedSurface
        .onChange(of: speech.transcript) { _, transcript in
            guard speech.isListening || speech.isTranscribing else { return }
            input = transcript
        }
        .onChange(of: input) { _, _ in
            // Typing and dictation are conversation activity too: leave only
            // transient Walk / Edge Idle / Moves, while an explicit Close-up
            // remains selected.
            avatarInteractions.noteThreadInteraction()
            if !liveTalk.phase.isSessionActive {
                conversation.stopSpeechOutput()
            }
            liveTalkPTTNotice = nil
        }
        .onChange(of: conversation.pendingSMS) { _, _ in
            commandModel.synchronizeStagedMessageDraft(with: conversation.messageCommand())
        }
        .onChange(of: conversation.pendingEmail) { _, _ in
            commandModel.synchronizeStagedMailDraft(with: conversation.emailCommand())
        }
        .onChange(of: conversation.isSpeechOutputActive) { _, isActive in
            if !isActive {
                readAloudMessageID = nil
            }
        }
        .onChange(of: appAudioActivityIsActive) { _, _ in
            synchronizeQuickDictationAudioOwnership()
        }
        .onChange(of: liveTalk.transcripts) { _, transcripts in
            conversation.ingestLiveTalkTranscripts(transcripts)
        }
        .onChange(of: liveTalk.phase) { previousPhase, currentPhase in
            if previousPhase.isSessionActive, !currentPhase.isSessionActive {
                conversation.endLiveTalkTranscriptSession()
            }
        }
        .onChange(of: conversation.pendingShortcutPrompt) { _, prompt in
            receivePendingShortcutPrompt(prompt)
        }
        .onChange(of: keyboardDictationHost.warmEarPresentationState) { _, state in
            warmEarEnabled = OpenClamWarmEarControl.isEnabled
            if case .failed = state {
                liveTalkPTTNotice = state.detail
            }
        }
        .onChange(of: conversation.historyController.selectedThreadID) { previousID, selectedID in
            guard previousID != nil, previousID != selectedID else { return }
            threadPositioning.resetForThreadChange()
            resetComposerForChatChange()
        }
    }

    private var lifecycleObservedSurface: some View {
        conversationObservedSurface
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                warmEarEnabled = OpenClamWarmEarControl.isEnabled
                OpenClamWarmEarControl.renewForegroundLease()
            } else {
                OpenClamWarmEarControl.clearForegroundLease()
            }
            if phase != .active {
                speech.cancel()
                conversation.stopSpeechOutput()
                Task { await conversation.persistConversationHistory() }
            }
            if phase == .background {
                cancelActiveRequest()
                conversation.eventKitAgentSession.invalidate()
                Task { await conversation.contactAgentSession.invalidate() }
                conversation.endLiveTalkTranscriptSession()
                Task { await liveTalk.stop() }
            }
        }
        .onDisappear {
            speech.cancel()
            conversation.stopSpeechOutput()
            cancelActiveRequest()
            conversation.endLiveTalkTranscriptSession()
            Task { await liveTalk.stop() }
            keyboardDictationHost.setCompetingAppAudioActive(false)
        }
        .onAppear {
            warmEarEnabled = OpenClamWarmEarControl.isEnabled
            OpenClamWarmEarControl.renewForegroundLease()
            synchronizeQuickDictationAudioOwnership()
            receivePendingShortcutPrompt(conversation.pendingShortcutPrompt)
            if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let submission = conversation.pendingScreenContextSubmission {
                input = submission.instruction
            }
        }
        .task(id: connectorVisualThumbnailSnapshot) {
            await loadPersistedConnectorVisualPreviews()
        }
        .alert(
            "Live Talk",
            isPresented: Binding(
                get: { liveTalk.errorMessage != nil },
                set: { presented in
                    if !presented { liveTalk.clearError() }
                }
            )
        ) {
            Button("OK") { liveTalk.clearError() }
        } message: {
            Text(liveTalk.errorMessage ?? "Live Talk stopped.")
        }
        .alert(
            connectorArtifactFeedback?.title ?? "OpenClaw File",
            isPresented: Binding(
                get: { connectorArtifactFeedback != nil },
                set: { presented in
                    if !presented { connectorArtifactFeedback = nil }
                }
            )
        ) {
            if connectorArtifactFeedback?.offersSettings == true {
                Button("Open Settings") {
                    connectorArtifactFeedback = nil
                    guard let settingsURL = URL(
                        string: UIApplication.openSettingsURLString
                    ) else { return }
                    UIApplication.shared.open(settingsURL)
                }
            }
            Button("OK", role: .cancel) { connectorArtifactFeedback = nil }
        } message: {
            Text(
                connectorArtifactFeedback?.message
                    ?? "The generated file is unavailable."
            )
        }
    }

    private var assistantBackground: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
    }

    private var isFreshConversation: Bool {
        conversation.messages.count == 1
    }

    private func baseThreadScroll(in viewport: GeometryProxy) -> some View {
        ScrollView {
            threadContent(in: viewport)
                .padding(.horizontal, ConversationThreadLayout.horizontalContentInset)
                .padding(.top, isFreshConversation ? 36 : 12)
                .padding(.bottom, 8)
                .disabled(
                    (conversation.isWorking && conversation.remoteAgentActivity == nil)
                        || commandModel.isExecuting
                        || (activeRequestTask != nil && conversation.remoteAgentActivity == nil)
                )
                .background(alignment: .topLeading) {
                    ConversationThreadInteractionObserver(
                        onTapInteraction: avatarInteractions.noteThreadInteraction,
                        onScrollInteraction: avatarInteractions.noteThreadScrollInteraction,
                        onManualScroll: { threadPositioning.noteManualScroll() },
                        onLatestVisibilityChanged: { isLatestVisible in
                            threadPositioning.noteLatestVisibility(isLatestVisible)
                        }
                    )
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                }
        }
        .accessibilityIdentifier("openclam-conversation-thread")
        .defaultScrollAnchor(isFreshConversation ? .top : .bottom)
        .scrollDismissesKeyboard(.interactively)
        .contentMargins(
            .bottom,
            composerHeight + ConversationComposerLayout.threadClearance,
            for: .scrollContent
        )
        .background(assistantBackground)
    }

    private func deliveryObservedThreadScroll(
        in viewport: GeometryProxy,
        proxy: ScrollViewProxy
    ) -> some View {
        baseThreadScroll(in: viewport)
            .onChange(of: conversation.pendingEmail?.id) { previousID, currentID in
                guard ConversationReviewRevealPolicy.shouldRevealPendingEmail(
                    previousID: previousID,
                    currentID: currentID
                ) else { return }
                revealPendingEmailReview(using: proxy)
            }
            .onChange(of: assistantReplyDeliverySnapshot) { _, snapshot in
                let newUserMessageID = userTurnPlacementBoundary.observe(snapshot)
                let newAssistantMessageID = deliverNewAssistantReply(from: snapshot)
                switch threadPositioning.receiveAppendedMessages(
                    userMessageID: newUserMessageID,
                    assistantMessageID: newAssistantMessageID
                ) {
                case .placeUserTurn(let messageID):
                    placeNewUserTurn(messageID, using: proxy)
                case .followLatest:
                    if !isFreshConversation { scrollToLatest(using: proxy) }
                case .preservePosition:
                    break
                }
            }
            .onChange(of: conversation.isWorking) { _, _ in
                if threadPositioning.shouldFollowLatest { scrollToLatest(using: proxy) }
            }
            .onChange(of: conversation.remoteAgentActivity) { _, activity in
                if let activity, remoteWorkStartedAt[activity.id] == nil {
                    remoteWorkStartedAt[activity.id] = Date()
                }
                if activity != nil, threadPositioning.shouldFollowLatest {
                    scrollToLatest(using: proxy)
                }
            }
            .onChange(of: conversation.remoteAgentWorkSteps) { _, steps in
                if !steps.isEmpty, threadPositioning.shouldFollowLatest {
                    scrollToLatest(using: proxy)
                }
            }
            .onChange(of: conversation.streamingAssistantReply) { _, reply in
                if reply?.isEmpty == false, threadPositioning.shouldFollowLatest {
                    scrollToLatest(using: proxy)
                }
            }
            .onChange(of: conversation.liveTalkStreamingMessages) { _, _ in
                if threadPositioning.shouldFollowLatest {
                    scrollToLatest(using: proxy)
                }
            }
    }

    private func observedThreadScroll(
        in viewport: GeometryProxy,
        proxy: ScrollViewProxy
    ) -> some View {
        deliveryObservedThreadScroll(in: viewport, proxy: proxy)
            .onChange(of: goToLatestMessageRequest) { _, _ in
                scrollToLatest(using: proxy)
            }
            .onChange(of: confirmedActionNotice) { _, notice in
                if notice != nil { scrollToLatest(using: proxy) }
            }
            .onChange(of: isComposerFocused) { _, focused in
                expandsComposerForEditing = focused
                if focused {
                    avatarInteractions.noteThreadInteraction()
                }
                if focused, threadPositioning.shouldFollowLatest {
                    scrollToLatest(using: proxy)
                }
            }
            .onChange(of: stagedAttachments.count) { _, _ in
                if threadPositioning.shouldFollowLatest { scrollToLatest(using: proxy) }
            }
            .onChange(of: conversation.pendingScreenContextSubmission?.reviewID) {
                _, submissionID in
                guard submissionID != nil else { return }
                if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let submission = conversation.pendingScreenContextSubmission {
                    input = submission.instruction
                }
                scrollToLatest(using: proxy)
            }
            .onAppear {
                assistantReplyDeliveryBoundary.prime(with: assistantReplyDeliverySnapshot)
                userTurnPlacementBoundary.prime(with: assistantReplyDeliverySnapshot)
                threadPositioning.resetForThreadChange()
                if !isFreshConversation {
                    scrollToLatest(using: proxy, animated: false)
                }
            }
    }

    @ViewBuilder
    private func threadContent(in viewport: GeometryProxy) -> some View {
        LazyVStack(spacing: 14) {
            ForEach(conversation.messages) { message in
                threadMessageRow(message, viewportWidth: viewport.size.width)
            }

            ForEach(conversation.liveTalkStreamingMessages) { message in
                liveTalkStreamingThreadRow(
                    message,
                    viewportWidth: viewport.size.width
                )
            }

            if conversation.messages.count == 1,
               !dynamicTypeSize.isAccessibilitySize {
                suggestionRow
            }
            if let activity = conversation.remoteAgentActivity {
                remoteAgentActivityCard(activity)
            }
            if conversation.isWorking,
               conversation.streamingAssistantReply?.isEmpty == false {
                workingRow
            }
            if conversation.screenshotData != nil || conversation.pronunciation != nil {
                pronunciationCard
            }
            if !conversation.venueResults.isEmpty { venueCard }
            if conversation.pendingNearbySearchQuery != nil { pendingNearbySearchCard }
            if conversation.contactAgentSession.status != .idle {
                ContactAgentCard(
                    session: conversation.contactAgentSession,
                    providerID: aiConfiguration.effectiveSettings.llm.provider,
                    providerModel: aiConfiguration.effectiveSettings.model,
                    onSharedReply: { conversation.recordFeatureReply($0) }
                )
            }
            EventKitAgentCard(session: conversation.eventKitAgentSession)
            if !conversation.nearbyPlaceResults.isEmpty { nearbyPlacesCard }
            if !conversation.replySuggestions.isEmpty { replySuggestionsCard }
            if conversation.researchRequest != nil { researchCard }
            if conversation.pendingSMS != nil { messageDraftCard }
            if conversation.pendingEmail != nil {
                emailDraftCard.id(ConversationReviewRevealPolicy.pendingEmailAnchorID)
            }
            if let proposal = conversation.pendingAppHandoffProposal {
                appHandoffCard(proposal)
            }
            if conversation.proposedCommand != nil { proposedCommandCard }
            if conversation.rideDestination != nil { rideCard }
            if let confirmedActionNotice { confirmedActionReceipt(confirmedActionNotice) }
            if let prompt = conversation.pendingShortcutPrompt { pendingSiriPromptCard(prompt) }
            if let submission = conversation.pendingScreenContextSubmission {
                pendingScreenContextComposerCard(submission)
            }
            if !stagedAttachments.isEmpty || isLoadingAttachments { attachmentTray }
            if threadPositioning.anchoredUserMessageID != nil {
                Color.clear
                    .frame(
                        height: ConversationThreadLayout.responseReserveHeight(
                            viewportHeight: viewport.size.height,
                            usesAccessibilityType: dynamicTypeSize.isAccessibilitySize
                        )
                    )
                    .accessibilityHidden(true)
            }
            Color.clear.frame(height: 4).id("bottom")
        }
    }

    private func threadMessageRow(
        _ message: ConversationMessage,
        viewportWidth: CGFloat
    ) -> some View {
        messageBubble(message, viewportWidth: viewportWidth)
            .padding(
                physicalRightThreadEdge,
                ConversationThreadLayout.additionalMessageRowTrailingPadding
            )
            .padding(
                .top,
                message.id == threadPositioning.anchoredUserMessageID
                    ? ConversationThreadLayout.anchoredTurnTopClearance(
                        usesAccessibilityType: dynamicTypeSize.isAccessibilitySize
                    )
                    : 0
            )
            .id(message.id)
    }

    private func liveTalkStreamingThreadRow(
        _ message: ConversationMessage,
        viewportWidth: CGFloat
    ) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user { Spacer(minLength: 18) }
            Text(message.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, message.role == .user ? 14 : 2)
                .padding(.vertical, message.role == .user ? 10 : 6)
                .background(
                    message.role == .user
                        ? AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
                        : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .frame(
                    width: message.role == .user
                        ? ConversationThreadLayout.userBubbleWidth(
                            viewportWidth: viewportWidth,
                            naturalTextWidth: naturalUserMessageWidth(message.text),
                            hasAttachments: false
                        )
                        : nil,
                    alignment: .leading
                )
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel(
                    message.role == .user
                        ? "Transcribing your speech"
                        : "Receiving the agent's reply"
                )
            if message.role == .assistant { Spacer(minLength: 18) }
        }
        .frame(maxWidth: .infinity)
        .padding(
            physicalRightThreadEdge,
            ConversationThreadLayout.additionalMessageRowTrailingPadding
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            message.role == .user
                ? "openclam-live-talk-user-transcript"
                : "openclam-live-talk-agent-transcript"
        )
        .id(message.id)
    }

    @ViewBuilder
    private func messageBubble(
        _ message: ConversationMessage,
        viewportWidth: CGFloat
    ) -> some View {
        if message.role == .user {
            messageBubbleContent(message)
                .frame(
                    width: ConversationThreadLayout.userBubbleWidth(
                        viewportWidth: viewportWidth,
                        naturalTextWidth: naturalUserMessageWidth(message.text),
                        hasAttachments: !message.attachments.isEmpty
                    ),
                    alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityElement(children: .contain)
        } else {
            HStack(alignment: .top) {
                messageBubbleContent(message)
                Spacer(minLength: 18)
            }
            .accessibilityElement(children: .contain)
            .frame(maxWidth: .infinity)
        }
    }

    private func messageBubbleContent(_ message: ConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !message.workSteps.isEmpty {
                openClawWorkCard(
                    steps: message.workSteps,
                    cardID: message.id,
                    isLive: false
                )
                .padding(.bottom, 8)
            }

            messageContent(message)
                .foregroundStyle(.primary)
                .padding(.horizontal, message.role == .user ? 14 : 2)
                .padding(.vertical, message.role == .user ? 10 : 6)
                .background(
                    message.role == .user
                        ? AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
                        : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            if ConversationMessageInteractionPolicy.supportsAssistantActions(message) {
                assistantMessageActions(message)
            }
        }
        .accessibilityIdentifier(messageAccessibilityIdentifier(for: message))
        .accessibilityValue(message.text)
    }

    private func naturalUserMessageWidth(_ text: String) -> CGFloat {
        let traits = UITraitCollection(
            preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)
        )
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        return text
            .components(separatedBy: .newlines)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
    }

    /// The avatar rail is physically right-aligned even in right-to-left
    /// locales, while SwiftUI's leading/trailing edges are semantic.
    private var physicalRightThreadEdge: Edge.Set {
        layoutDirection == .rightToLeft ? .leading : .trailing
    }

    private func messageAccessibilityIdentifier(
        for message: ConversationMessage
    ) -> String {
        if message.role == .user,
           message.id == conversation.messages.last(where: { $0.role == .user })?.id {
            return "openclam-latest-user-message"
        }
        return "openclam-thread-message-\(message.id.uuidString)"
    }

    @ViewBuilder
    private func messageContent(_ message: ConversationMessage) -> some View {
        if dynamicTypeSize.isAccessibilitySize,
           isFreshConversation,
           message.role == .assistant,
           message.id == conversation.messages.first?.id {
            SelectableMessageText(
                attributedText: AttributedString(
                    "Ask anything. Actions stay visible for confirmation."
                ),
                textStyle: .body,
                onAskAI: { selectedText in
                    stageSelectedTextForAI(selectedText)
                }
            )
        } else {
            MarkdownMessageView(
                message: message,
                localVisualPreviews: messageVisualPreviews,
                onAskAISelection: message.role == .assistant
                    ? { selectedText in stageSelectedTextForAI(selectedText) }
                    : nil,
                onOpenAttachment: { attachment in
                    presentConnectorArtifact(attachment, forSharing: false)
                },
                onSaveToPhotosAttachment: { attachment in
                    saveConnectorArtifactToPhotos(attachment)
                },
                onSaveAttachment: { attachment in
                    saveConnectorArtifactToFiles(attachment)
                },
                onShareAttachment: { attachment in
                    presentConnectorArtifact(attachment, forSharing: true)
                }
            )
        }
    }

    private func assistantMessageActions(_ message: ConversationMessage) -> some View {
        let isReadingThisMessage = conversation.isSpeechOutputActive
            && readAloudMessageID == message.id
        let isReadingAnotherMessage = conversation.isSpeechOutputActive
            && !isReadingThisMessage
        let readAloudHint: String
        if isReadingThisMessage {
            readAloudHint = "Stops this response"
        } else if liveTalk.phase.isSessionActive {
            readAloudHint = "Hang up Live Talk first"
        } else {
            readAloudHint = "Reads this complete response using the selected voice"
        }

        return HStack(spacing: 0) {
            Button {
                copyAssistantMessage(message)
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Copy assistant response")
            .accessibilityHint("Copies this complete response")
            .accessibilityIdentifier("openclam-copy-assistant-response-\(message.id.uuidString)")

            Button {
                toggleAssistantMessageReadAloud(message)
            } label: {
                Image(systemName: isReadingThisMessage ? "stop.fill" : "speaker.wave.2")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(
                liveTalk.phase.isSessionActive
                    || speech.isListening
                    || speech.isTranscribing
                    || isChatTransitioning
                    || isReadingAnotherMessage
            )
            .accessibilityLabel(
                isReadingThisMessage
                    ? "Stop speaking"
                    : "Read assistant response aloud"
            )
            .accessibilityHint(readAloudHint)
            .accessibilityIdentifier("openclam-read-assistant-response-\(message.id.uuidString)")
        }
        .font(.body.weight(.medium))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openclam-assistant-response-actions-\(message.id.uuidString)")
    }

    @ViewBuilder
    private var workingRow: some View {
        if let streaming = conversation.streamingAssistantReply,
           !streaming.isEmpty {
            HStack(alignment: .top) {
                Text(streaming)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Spacer(minLength: 18)
            }
            .padding(.horizontal, 2)
            .accessibilityLabel("Assistant response in progress")
            .accessibilityValue(streaming)
            .accessibilityIdentifier("openclam-openclaw-streaming-reply")
        } else if conversation.remoteAgentActivity == nil {
            HStack(spacing: 10) {
                ProgressView()
                Text(currentRemoteBinding == nil
                     ? "Working with available services…"
                     : "Waiting for OpenClaw…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .accessibilityElement(children: .combine)
        }
    }

    private func remoteAgentActivityCard(
        _ activity: RemoteAgentActivityPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if activity.showsProgress {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = workDurationLabel(
                            from: remoteWorkStartedAt[activity.id] ?? context.date,
                            to: context.date
                        )
                        Text("Working for \(elapsed)")
                    }
                } else {
                    Text(activity.phase == .needsAttention ? "OpenClaw needs attention" : "OpenClaw work")
                }
                Spacer(minLength: 8)
                if activity.showsProgress {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.primary.opacity(0.68))

            Divider()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: remoteAgentActivityIcon(activity.phase))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(
                        activity.phase == .needsAttention ? .orange : .secondary
                    )
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 5) {
                    Text(activity.title)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let detail = activity.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !conversation.remoteAgentWorkSteps.isEmpty {
                openClawWorkCard(
                    steps: conversation.remoteAgentWorkSteps,
                    cardID: activity.id,
                    isLive: true
                )
            }

            if activity.allowsRetry || activity.allowsCancel || activity.allowsRepair {
                HStack(spacing: 10) {
                        if activity.allowsRepair {
                            Button("Pair again") {
                                dismissKeyboard()
                                onShowAgentConnections()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier("openclam-openclaw-activity-repair")
                        }

                        if activity.allowsRetry {
                            Button("Retry") {
                                retryRemoteAgentActivity()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier("openclam-openclaw-activity-retry")
                        }

                        if activity.allowsCancel {
                            Button("Cancel", role: .cancel) {
                                cancelRemoteAgentActivity()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("openclam-openclaw-activity-cancel")
                        }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .onAppear {
            if remoteWorkStartedAt[activity.id] == nil {
                remoteWorkStartedAt[activity.id] = Date()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openclam-openclaw-activity-card")
        .id(activity.id)
    }

    private func openClawWorkCard(
        steps: [AgentConnectorWorkStep],
        cardID: UUID,
        isLive: Bool
    ) -> some View {
        let ordered = steps.sorted { lhs, rhs in
            if lhs.revision == rhs.revision { return lhs.stepID < rhs.stepID }
            return lhs.revision < rhs.revision
        }
        let completedCount = ordered.filter { $0.state == .completed }.count
        return VStack(alignment: .leading, spacing: 0) {
            if !isLive {
                HStack(spacing: 8) {
                    Text("Work")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(completedCount) of \(ordered.count) completed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 32)
                Divider().padding(.bottom, 4)
            }

            ForEach(ordered) { step in
                openClawWorkStep(step, cardID: cardID)
                if step.id != ordered.last?.id {
                    Divider().padding(.leading, 30)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openclam-openclaw-work-\(cardID.uuidString)")
    }

    private func openClawWorkStep(
        _ step: AgentConnectorWorkStep,
        cardID: UUID
    ) -> some View {
        let key = "\(cardID.uuidString):\(step.stepID)"
        let hasDetails = [
            step.detail,
            step.tool.map { "Tool · \($0)" },
        ].contains { $0?.isEmpty == false }

        return VStack(alignment: .leading, spacing: 5) {
            Button {
                guard hasDetails else { return }
                if expandedWorkSteps.contains(key) {
                    expandedWorkSteps.remove(key)
                } else {
                    expandedWorkSteps.insert(key)
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: workStepIcon(step))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(workStepColor(step))
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Text(workStateLabel(step.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    if hasDetails {
                        Image(
                            systemName: expandedWorkSteps.contains(key)
                                ? "chevron.up"
                                : "chevron.down"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasDetails)

            if hasDetails, expandedWorkSteps.contains(key) {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = step.detail {
                        Text(detail)
                    }
                    if let tool = step.tool {
                        workDetailRow("Tool", value: tool, monospaced: false)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(10)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .padding(.leading, 28)
                .padding(.bottom, 8)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openclam-openclaw-work-step-\(step.stepID)")
    }

    private func workDetailRow(
        _ label: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
            Text(value)
                .font(monospaced ? .caption2.monospaced() : .caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func workDurationLabel(from start: Date, to end: Date) -> String {
        let elapsed = max(0, Int(end.timeIntervalSince(start)))
        if elapsed < 60 { return "\(elapsed)s" }
        return "\(elapsed / 60)m \(elapsed % 60)s"
    }

    private func workStateLabel(_ state: AgentConnectorWorkState) -> String {
        switch state {
        case .running: "In progress"
        case .completed: "Completed"
        case .failed: "Failed"
        case .waiting: "Waiting"
        }
    }

    private func workStepIcon(_ step: AgentConnectorWorkStep) -> String {
        if step.state == .failed { return "xmark.circle.fill" }
        if step.state == .completed { return "checkmark.circle.fill" }
        if step.state == .waiting { return "pause.circle.fill" }
        return switch step.category {
        case .reasoningSummary: "brain.head.profile"
        case .plan: "list.bullet.clipboard"
        case .tool: "wrench.and.screwdriver.fill"
        case .command: "terminal.fill"
        case .file: "doc.fill"
        case .approval: "person.badge.key.fill"
        case .status: "circle.dotted"
        }
    }

    private func workStepColor(_ step: AgentConnectorWorkStep) -> Color {
        switch step.state {
        case .running: OpenClamTheme.active
        case .completed: .green
        case .failed: .red
        case .waiting: .orange
        }
    }

    private func remoteAgentActivityIcon(
        _ phase: RemoteAgentActivityPresentation.Phase
    ) -> String {
        switch phase {
        case .needsAttention:
            "exclamationmark.triangle.fill"
        case .downloading:
            "arrow.down.circle.fill"
        case .usingTool:
            "wrench.and.screwdriver.fill"
        case .cancelling:
            "xmark.circle.fill"
        case .connecting, .queued, .working, .finalizing, .reconnecting:
            "link"
        }
    }

    private func retryRemoteAgentActivity() {
        guard !conversation.isWorking else { return }
        beginAgentTask {
            await conversation.recoverPendingRemoteTurnIfNeeded(
                aiConfiguration: aiConfiguration,
                agentConnections: agentConnections
            )
        }
    }

    private func cancelRemoteAgentActivity() {
        if conversation.isWorking {
            activeRequestTask?.cancel()
            return
        }
        beginAgentTask {
            await conversation.cancelPendingRemoteTurnIfNeeded(
                aiConfiguration: aiConfiguration,
                agentConnections: agentConnections
            )
        }
    }

    private var suggestionRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Try OpenClam")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    suggestion(
                        "Nearby McDonald’s",
                        icon: "location.fill",
                        prompt: "Find the nearest McDonald’s to me."
                    )
                    suggestion(
                        "Email Emma",
                        icon: "envelope",
                        prompt: "Write an email to Emma in my contacts saying I’ll be about 15 minutes late."
                    )
                    suggestion(
                        "Calendar",
                        icon: "calendar.badge.plus",
                        prompt: "Add dinner tomorrow at 7 PM for 90 minutes."
                    )
                    suggestion(
                        "Ask anything",
                        icon: "sparkles",
                        prompt: "Explain in simple terms why the sky looks blue."
                    )
                }
            }
            .accessibilityIdentifier("openclam-starter-suggestions")
            .padding(.trailing, 68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func suggestion(_ title: String, icon: String, prompt: String) -> some View {
        Button {
            conversation.stopSpeechOutput()
            confirmedActionNotice = nil
            beginAgentTask {
                await conversation.submit(
                    prompt,
                    aiConfiguration: aiConfiguration,
                    agentConnections: agentConnections
                )
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    private var pronunciationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader("Local OCR & pronunciation", icon: "text.viewfinder", color: OpenClamTheme.active)

            if let data = conversation.screenshotData,
               let image = LocalAttachmentPreviewFactory.makePreview(from: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Label("OCR run locally", systemImage: "lock.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
            }

            if !conversation.observedText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OCR preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(conversation.observedText)
                        .font(.caption)
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        conversation.useObservedTextForPronunciation()
                    } label: {
                        Label("Choose OCR text for pronunciation", systemImage: "waveform.badge.plus")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Exact text proposed for AI sharing (editable)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $conversation.screenshotAIShareText)
                        .frame(minHeight: 130)
                        .padding(7)
                        .scrollContentBackground(.hidden)
                        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Editable screenshot text proposed for AI sharing")
                    Text("\(conversation.screenshotAIShareText.count) / \(ConversationModel.screenshotShareCharacterLimit) characters")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(
                            conversation.screenshotAIShareText.count > ConversationModel.screenshotShareCharacterLimit
                                ? Color.red
                                : Color.secondary
                        )
                    if conversation.screenshotShareWasTruncated {
                        Text("OCR was longer than the sharing limit. This box contains only the first \(ConversationModel.screenshotShareCharacterLimit) characters; review and edit it before sending.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Button {
                    beginAgentTask {
                        await conversation.askAIAboutScreenshot(using: aiConfiguration)
                    }
                } label: {
                    Label("Send reviewed text to AI for replies", systemImage: "text.bubble.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(OpenClamTheme.accent)
                .disabled(
                    conversation.screenshotAIShareText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || conversation.screenshotAIShareText.count > ConversationModel.screenshotShareCharacterLimit
                )

                Text("Only the exact edited text above is sent after this tap. It is handled in a reply-only AI request with no Contacts, Location, or action tools; the screenshot image stays on this iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Word or short phrase", text: $conversation.pronunciationInput)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .accessibilityLabel("Word or short phrase for local pronunciation")
                .onSubmit { conversation.analyzePronunciation() }

            if let result = conversation.pronunciation {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Detector suggests \(result.languageName)")
                            .font(.subheadline.weight(.semibold))
                        Text("Rough guide: \(result.approximation)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        guard reserveAppAudioLane() else { return }
                        conversation.speakPronunciation()
                        synchronizeQuickDictationAudioOwnership()
                    } label: {
                        Label("Hear it", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(OpenClamTheme.accent)
                    .disabled(!conversation.isTTSEnabled)
                    .accessibilityHint(conversation.isTTSEnabled ? "Plays the system voice" : "Turn on the speaker in the composer first")
                }
            } else {
                Button {
                    conversation.analyzePronunciation()
                } label: {
                    Label("Analyze pronunciation", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(OpenClamTheme.accent)
                .disabled(conversation.pronunciationInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Language detection and Latin-letter guidance are approximate; the system voice is not a linguistic guarantee.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .assistantCard(stroke: OpenClamTheme.subtleStroke)
    }

    private var venueCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            cardHeader("Live Maps candidates", icon: "map.fill", color: .green)

            if let note = conversation.venueSearchNote {
                Label(note, systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(conversation.venueResults) { venue in
                Button {
                    conversation.selectVenue(venue)
                } label: {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: venue.matchKind.systemImage)
                            .foregroundStyle(venue.matchKind == .nameMatch ? .green : .orange)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(venue.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            if !venue.address.isEmpty {
                                Text(venue.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(venue.matchKind.label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(venue.matchKind == .nameMatch ? .green : .orange)
                        }
                        Spacer()
                        Image(systemName: conversation.selectedVenue?.id == venue.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(conversation.selectedVenue?.id == venue.id ? OpenClamTheme.active : Color.gray.opacity(0.55))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityValue(conversation.selectedVenue?.id == venue.id ? "Selected" : "Not selected")
                .accessibilityAddTraits(conversation.selectedVenue?.id == venue.id ? .isSelected : [])

                if venue.id != conversation.venueResults.last?.id { Divider() }
            }

            if let selected = conversation.selectedVenue {
                HStack {
                    Button {
                        if let command = conversation.mapsCommand() {
                            confirm(command)
                        }
                    } label: {
                        Label("Google Maps", systemImage: "map")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        confirm(
                            .init(
                                action: .uberDestination,
                                parameters: [
                                    "destination": selected.name,
                                    "address": selected.address,
                                    "latitude": String(selected.latitude),
                                    "longitude": String(selected.longitude),
                                ]
                            )
                        )
                    } label: {
                        Label("Ride here", systemImage: "car.side.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .assistantCard(stroke: .green.opacity(0.2))
    }

    private var nearbyPlacesCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            cardHeader("Nearby live Maps results", icon: "location.fill", color: .green)

            Text("Distances are calculated on this iPhone from a live Apple Maps search. Exact device and place coordinates are not sent to the AI model.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(conversation.nearbyPlaceResults) { place in
                Button {
                    conversation.selectNearbyPlace(place)
                } label: {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.green)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(place.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            if !place.address.isEmpty {
                                Text(place.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(distanceLabel(place.distanceMeters))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Image(systemName: conversation.selectedNearbyPlace?.id == place.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(conversation.selectedNearbyPlace?.id == place.id ? OpenClamTheme.active : Color.gray.opacity(0.55))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityValue(conversation.selectedNearbyPlace?.id == place.id ? "Selected" : "Not selected")
                .accessibilityAddTraits(conversation.selectedNearbyPlace?.id == place.id ? .isSelected : [])

                if place.id != conversation.nearbyPlaceResults.last?.id { Divider() }
            }

            if conversation.selectedNearbyPlace != nil {
                HStack {
                    Button {
                        if let command = conversation.nearbyMapsCommand() { confirm(command) }
                    } label: {
                        Label("Google Maps", systemImage: "map")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        if let command = conversation.nearbyRideCommand() { confirm(command) }
                    } label: {
                        Label("Ride here", systemImage: "car.side.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .assistantCard(stroke: .green.opacity(0.2))
    }

    private var pendingNearbySearchCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            cardHeader("Approve nearby search", icon: "location.circle.fill", color: .green)
            if let query = conversation.pendingNearbySearchQuery {
                Text("Approve a nearby Apple Maps search for: \(query)")
                    .font(.subheadline.weight(.semibold))
                Text("Location is not read until you tap Search nearby. The search and exact results stay on this iPhone and are not sent back to the AI provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) {
                        Button {
                            beginAgentTask {
                                await conversation.runApprovedNearbySearch()
                            }
                        } label: {
                            Label("Search nearby", systemImage: "location.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        Button("Discard", role: .cancel) {
                            conversation.dismissPendingNearbySearch()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    HStack {
                        Button("Discard", role: .cancel) {
                            conversation.dismissPendingNearbySearch()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button {
                            beginAgentTask {
                                await conversation.runApprovedNearbySearch()
                            }
                        } label: {
                            Label("Search nearby", systemImage: "location.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
            }
        }
        .assistantCard(stroke: .green.opacity(0.22))
    }

    private var replySuggestionsCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            cardHeader("Reply suggestions", icon: "text.bubble.fill", color: OpenClamTheme.active)
            Text("Nothing is pasted or sent automatically. Choose the exact suggestion, then tap Confirmed to copy it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(conversation.replySuggestions.enumerated()), id: \.element.id) { index, suggestion in
                VStack(alignment: .leading, spacing: 9) {
                    Text("Option \(index + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(suggestion.text)
                        .font(.body)
                        .textSelection(.enabled)
                    Button {
                        confirm(.init(action: .clipboardCopy, parameters: ["text": suggestion.text]))
                    } label: {
                        Label("Confirmed", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Confirmed. Copy option \(index + 1)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(OpenClamTheme.subtleFill, in: RoundedRectangle(cornerRadius: 12))
            }

            Button("Dismiss suggestions", role: .cancel) {
                conversation.dismissReplySuggestions()
            }
            .buttonStyle(.bordered)
        }
        .assistantCard(stroke: OpenClamTheme.subtleStroke)
    }

    private var researchCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            cardHeader("Current reviews & menu", icon: "sparkle.magnifyingglass", color: OpenClamTheme.active)
            if let request = conversation.researchRequest {
                Text(request.subject)
                    .font(.subheadline.weight(.semibold))
                Text(request.prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("No review feed is connected on this phone. Use sourced Mac/Codex research or inspect the live Maps listing—no rating or dish is inferred here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    if let command = conversation.researchCommand() { confirm(command) }
                } label: {
                    Label("Copy research brief", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)

                if conversation.selectedVenue != nil {
                    Button {
                        if let command = conversation.mapsCommand() { confirm(command) }
                    } label: {
                        Label("Maps", systemImage: "map")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .assistantCard(stroke: OpenClamTheme.subtleStroke)
    }

    private var messageDraftCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            cardHeader("Unsent message draft", icon: "message.badge", color: .primary)

            if let draft = conversation.pendingSMS {
                Text("To: \(draft.recipientDisplay)")
                    .font(.subheadline.weight(.semibold))

                if (draft.phoneNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   draft.choices.isEmpty {
                    Button {
                        beginAgentTask {
                            await conversation.resolvePendingMessageContact()
                        }
                    } label: {
                        Label("Find in Contacts", systemImage: "person.crop.circle.badge.questionmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(OpenClamTheme.accent)

                    Text("Contacts is not read until you tap. Matching names and phone numbers stay on this iPhone and are not sent back to the AI provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !draft.choices.isEmpty && (draft.phoneNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose a saved phone number")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(draft.choices) { choice in
                            Button {
                                conversation.chooseContact(choice)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(choice.displayName)
                                        Text("\(choice.label) · \(choice.phoneNumber)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if draft.phoneNumber == choice.phoneNumber {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                TextField(
                    "Phone number",
                    text: Binding(
                        get: { conversation.pendingSMS?.phoneNumber ?? "" },
                        set: { conversation.setManualPhoneNumber($0) }
                    )
                )
                .keyboardType(.phonePad)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Message recipient phone number")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Message")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(
                        text: Binding(
                            get: { conversation.pendingSMS?.body ?? "" },
                            set: { conversation.pendingSMS?.body = $0 }
                        )
                    )
                    .frame(minHeight: 88)
                    .padding(7)
                    .scrollContentBackground(.hidden)
                    .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Message")
                }

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) {
                        Button {
                            if let command = conversation.messageCommand() { confirm(command) }
                        } label: {
                            Label("Confirmed", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(OpenClamTheme.accent)
                        .disabled(conversation.messageCommand() == nil)
                        .accessibilityLabel("Confirmed. Open unsent message draft")

                        Button("Discard", role: .destructive) {
                            conversation.dismissSMSDraft()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    HStack {
                        Button("Discard", role: .destructive) {
                            conversation.dismissSMSDraft()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button {
                            if let command = conversation.messageCommand() { confirm(command) }
                        } label: {
                            Label("Confirmed", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(OpenClamTheme.accent)
                        .disabled(conversation.messageCommand() == nil)
                        .accessibilityLabel("Confirmed. Open unsent message draft")
                    }
                }

                Text("Confirmed opens Apple’s message composer immediately. You manually send or cancel there; delivery is never assumed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .assistantCard(stroke: Color.primary.opacity(0.14))
    }

    private var emailDraftCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            cardHeader("Unsent email draft", icon: "envelope.badge", color: OpenClamTheme.active)

            if let draft = conversation.pendingEmail {
                Text("To: \(draft.recipientDisplay)")
                    .font(.subheadline.weight(.semibold))

                if (draft.emailAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   draft.choices.isEmpty {
                    Button {
                        beginAgentTask {
                            await conversation.resolvePendingEmailContact()
                        }
                    } label: {
                        Label("Find in Contacts", systemImage: "person.crop.circle.badge.questionmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(OpenClamTheme.accent)

                    Text("Contacts is not read until you tap. Matching names and email addresses stay on this iPhone and are not sent back to the AI provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !draft.choices.isEmpty && (draft.emailAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose a saved email address")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(draft.choices) { choice in
                            Button {
                                conversation.chooseEmailContact(choice)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(choice.displayName)
                                        Text("\(choice.label) · \(choice.emailAddress)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                TextField(
                    "Email address",
                    text: Binding(
                        get: { conversation.pendingEmail?.emailAddress ?? "" },
                        set: { conversation.setManualEmailAddress($0) }
                    )
                )
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Email recipient address")

                TextField(
                    "Subject",
                    text: Binding(
                        get: { conversation.pendingEmail?.subject ?? "" },
                        set: { conversation.pendingEmail?.subject = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Email subject")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Email body")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(
                        text: Binding(
                            get: { conversation.pendingEmail?.body ?? "" },
                            set: { conversation.pendingEmail?.body = $0 }
                        )
                    )
                    .frame(minHeight: 110)
                    .padding(7)
                    .scrollContentBackground(.hidden)
                    .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Email body")
                }

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) {
                        Button {
                            if let command = conversation.emailCommand() { confirm(command) }
                        } label: {
                            Label("Confirmed", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(OpenClamTheme.accent)
                        .disabled(conversation.emailCommand() == nil)
                        .accessibilityLabel("Confirmed. Open unsent email draft")

                        Button("Discard", role: .destructive) {
                            conversation.dismissEmailDraft()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    HStack {
                        Button("Discard", role: .destructive) {
                            conversation.dismissEmailDraft()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button {
                            if let command = conversation.emailCommand() { confirm(command) }
                        } label: {
                            Label("Confirmed", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(OpenClamTheme.accent)
                        .disabled(conversation.emailCommand() == nil)
                        .accessibilityLabel("Confirmed. Open unsent email draft")
                    }
                }

                Text("Confirmed opens Apple’s editable Mail composer immediately. You manually send, save, or cancel there; delivery is never assumed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .assistantCard(stroke: OpenClamTheme.emphasizedStroke)
    }

    private var proposedCommandCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            cardHeader("AI-proposed action", icon: "hand.raised.square.fill", color: .orange)
            if let command = conversation.proposedCommand {
                Text(command.action.title)
                    .font(.headline)
                Text(command.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Discard", role: .destructive) {
                        conversation.dismissProposedCommand()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        conversation.dismissProposedCommand()
                        confirm(command)
                    } label: {
                        Label("Confirmed", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .accessibilityLabel("Confirmed. \(command.action.title)")
                }
            }
        }
        .assistantCard(stroke: .orange.opacity(0.22))
    }

    private func appHandoffCard(_ proposal: AppHandoffProposal) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            cardHeader("Open app alias", icon: "arrow.up.forward.app.fill", color: OpenClamTheme.active)
            if let alias = proposal.aliasDisplayName {
                Text(alias)
                    .font(.headline)
            }
            Text(proposal.url.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("iOS will receive only the exact local destination shown above. The app cannot verify what happens after the handoff.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    confirmedAppHandoffButton(proposal)
                    discardAppHandoffButton
                }
            } else {
                HStack {
                    discardAppHandoffButton
                    Spacer()
                    confirmedAppHandoffButton(proposal)
                }
            }
        }
        .assistantCard(stroke: OpenClamTheme.emphasizedStroke)
    }

    private func confirmedAppHandoffButton(_ proposal: AppHandoffProposal) -> some View {
        Button {
            beginAgentTask {
                confirmedActionSucceeded = await conversation.openConfirmedAppHandoff(proposal)
                confirmedActionNotice = conversation.appHandoffSession.lastResult
                    ?? (confirmedActionSucceeded
                        ? "iOS accepted the reviewed app handoff."
                        : "iOS could not open the reviewed app handoff.")
            }
        } label: {
            Label("Confirmed", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(OpenClamTheme.accent)
    }

    private var discardAppHandoffButton: some View {
        Button("Discard", role: .cancel) {
            conversation.discardPendingAppHandoff()
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
    }

    private var rideCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            cardHeader("Uber destination handoff", icon: "car.side.fill", color: .orange)
            if let destination = conversation.rideDestination {
                Text(destination.name)
                    .font(.headline)
                if !destination.address.isEmpty {
                    Text(destination.address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button {
                    if let command = conversation.rideCommand() { confirm(command) }
                } label: {
                    Label("Confirmed", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .accessibilityLabel("Confirmed. Open Uber handoff")
                Text("Uber remains responsible for pickup, fare, payment, availability, and final booking confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .assistantCard(stroke: .orange.opacity(0.22))
    }

    private func confirmedActionReceipt(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: confirmedActionSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(confirmedActionSucceeded ? Color.green : Color.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                confirmedActionNotice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss confirmed action result")
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var composer: some View {
        ViewThatFits(in: .horizontal) {
            compactComposer
                .frame(maxWidth: .infinity)
                .frame(minWidth: shouldUseExpandedComposer ? 10_000 : nil)
            expandedComposer
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ConversationComposerTopPreferenceKey.self,
                    value: proxy.frame(in: .global).minY
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var shouldUseExpandedComposer: Bool {
        dynamicTypeSize.isAccessibilitySize
            || expandsComposerForEditing
            || isComposerFocused
            || speech.isListening
            || speech.isTranscribing
            || isRequestActive
            || isLoadingAttachments
            || !stagedAttachments.isEmpty
            || conversation.pendingScreenContextSubmission != nil
            || input.contains("\n")
            || input.count > 48
            || speechStatusText != nil
            || composerSupportError != nil
            || isChatTransitioning
    }

    private var composerPlaceholder: String {
        stagedAttachments.isEmpty && conversation.pendingScreenContextSubmission == nil
            ? "Ask a follow-up"
            : "Tell the AI what to do with these"
    }

    private var compactComposer: some View {
        HStack(spacing: 2) {
            attachmentMenu
            compactComposerPrompt
                .frame(minWidth: 72)
                .layoutPriority(2)
            composerActionButton
        }
    }

    private var compactComposerPrompt: some View {
        Button {
            expandsComposerForEditing = true
            DispatchQueue.main.async {
                isComposerFocused = true
            }
        } label: {
            Text(input.isEmpty ? "Message" : input)
                .lineLimit(1)
                .foregroundStyle(input.isEmpty ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Message the AI assistant")
        .disabled(
            speech.isListening
                || isRequestActive
                || isLoadingAttachments
                || isChatTransitioning
        )
    }

    private var expandedComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            composerStatus
            composerTextField(placeholder: composerPlaceholder, lineLimit: 2 ... 5)
                .frame(
                    minHeight: ConversationComposerLayout.minimumExpandedTextHeight,
                    alignment: .topLeading
                )

            if dynamicTypeSize.isAccessibilitySize {
                modelSelectionMenu(expandsToWidth: true)
                HStack(spacing: 4) {
                    attachmentMenu
                    textToSpeechButton
                    Spacer(minLength: 4)
                    composerActionButton
                }
            } else {
                HStack(spacing: 4) {
                    attachmentMenu
                    textToSpeechButton
                    Spacer(minLength: 2)
                    modelSelectionMenu(expandsToWidth: false)
                        .layoutPriority(1)
                    composerActionButton
                }
            }
        }
    }

    @ViewBuilder
    private var composerStatus: some View {
        if isChatTransitioning {
            Label("Loading chats…", systemImage: "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        } else if let status = speechStatusText {
            Label(status, systemImage: speech.isListening ? "waveform" : "ellipsis.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(speech.isListening ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("openclam-speech-status")
        } else if let error = composerSupportError {
            composerErrorCard(error)
        }
    }

    private func composerTextField(
        placeholder: String,
        lineLimit: ClosedRange<Int>
    ) -> some View {
        TextField(
            placeholder,
            text: $input,
            axis: .vertical
        )
        .lineLimit(lineLimit)
        .textFieldStyle(.plain)
        .modifier(ConversationComposerTextInsets())
        .submitLabel(.send)
        .onSubmit { sendInput() }
        .focused($isComposerFocused)
        .disabled(
            speech.isListening
                || isRequestActive
                || isLoadingAttachments
                || isChatTransitioning
        )
        .accessibilityLabel(
            stagedAttachments.isEmpty && conversation.pendingScreenContextSubmission == nil
                ? "Message the AI assistant"
                : "Context or attachment instruction"
        )
    }

    private var attachmentMenu: some View {
        Menu {
            Button {
                showsCamera = true
            } label: {
                Label("Take Photo", systemImage: "camera")
            }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

            Button {
                showsMediaPicker = true
            } label: {
                Label("Choose photo or video", systemImage: "photo.on.rectangle.angled")
            }
            Button {
                showsFileImporter = true
            } label: {
                Label("Choose file", systemImage: "doc.badge.plus")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .medium))
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if !stagedAttachments.isEmpty {
                        Text("\(stagedAttachments.count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Color.primary, in: Circle())
                    }
                }
        }
        .accessibilityLabel("Add photo, video, or file")
        .accessibilityHint(currentRemoteBinding == nil
            ? "Opens camera, photo library, and file choices"
            : "Messages to OpenClaw are text only. OpenClaw replies can include verified generated files.")
        .accessibilityIdentifier("openclam-attachment-menu")
        .accessibilityValue(
            stagedAttachments.isEmpty
                ? "No attachments"
                : "\(stagedAttachments.count) ready"
        )
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .disabled(
            stagedAttachments.count >= 4
                || isLoadingAttachments
                || isRequestActive
                || isChatTransitioning
                || conversation.pendingScreenContextSubmission != nil
                || currentRemoteBinding != nil
        )
    }

    private var textToSpeechButton: some View {
        Button {
            let enabled = !conversation.isTTSEnabled
            if enabled, !reserveAppAudioLane() { return }
            conversation.setTTSEnabled(enabled)
            if enabled {
                conversation.speakLatestAssistantReply(using: aiConfiguration)
            }
            synchronizeQuickDictationAudioOwnership()
        } label: {
            Image(systemName: conversation.isTTSEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .contentTransition(.symbolEffect(.replace))
        }
        .foregroundStyle(conversation.isTTSEnabled ? Color.primary : Color.secondary)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Text to speech")
        .accessibilityValue(conversation.isTTSEnabled ? "On" : "Off")
        .accessibilityHint(conversation.isTTSEnabled ? "Turns off speech and stops current audio" : "Turns on speech and reads the latest assistant reply")
        .accessibilityIdentifier("openclam-tts-button")
        .disabled(isChatTransitioning || liveTalk.phase.isSessionActive)
    }

    private var composerActionButton: some View {
        Button {
            performComposerAction()
        } label: {
            Image(systemName: composerIcon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(width: 44, height: 44)
                .background(composerColor, in: Circle())
                .symbolEffect(.pulse, isActive: speech.isListening)
        }
        .accessibilityLabel(composerAccessibilityLabel)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .disabled(isLoadingAttachments || isChatTransitioning || speech.isTranscribing)
    }

    @ViewBuilder
    private func modelSelectionMenu(
        expandsToWidth: Bool,
        compact: Bool = false
    ) -> some View {
        if let binding = currentRemoteBinding {
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.caption.weight(.semibold))
                Text(binding.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Menu labels can inherit a nearly transparent hierarchical tint
            // from the floating material on iOS 26. Use a concrete color so
            // the selected model remains visibly present once the composer is
            // expanded, while still reading as secondary information.
            .foregroundStyle(Color.primary.opacity(0.68))
            .frame(
                minWidth: expandsToWidth ? nil : (compact ? 128 : 116),
                maxWidth: expandsToWidth ? .infinity : (compact ? 136 : 156),
                minHeight: 44,
                alignment: expandsToWidth ? .leading : .center
            )
            .accessibilityLabel("OpenClaw agent")
            .accessibilityValue(binding.displayName)
        } else {
            Menu {
            ForEach(languageModelProviders) { provider in
                Menu(provider.displayName) {
                    ForEach(languageModels(for: provider.id), id: \.self) { model in
                        Button {
                            updateLanguageModel(provider: provider.id, model: model)
                        } label: {
                            if aiConfiguration.effectiveSettings.llm.provider == provider.id,
                               aiConfiguration.effectiveSettings.llm.model == model {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                dismissKeyboard()
                onShowAISettings()
            } label: {
                Label("Manage AI Settings", systemImage: "gearshape")
            }
        } label: {
            HStack(spacing: 4) {
                Text(composerModelDisplayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1 : (expandsToWidth ? 2 : 1))
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            .frame(
                minWidth: expandsToWidth ? nil : (compact ? 128 : 116),
                maxWidth: expandsToWidth ? .infinity : (compact ? 136 : 156),
                minHeight: 44,
                alignment: expandsToWidth ? .leading : .center
            )
            .contentShape(Rectangle())
        }
        .tint(Color.primary.opacity(0.68))
        .disabled(isRequestActive)
        .accessibilityLabel("Language model")
        .accessibilityValue("\(configuredProviderName), \(configuredModelName)")
            .accessibilityHint("Choose a provider and model, or open AI Settings")
        }
    }

    private var attachmentTray: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Ready to attach", systemImage: "paperclip.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OpenClamTheme.active)
                Spacer()
                Text("\(stagedAttachments.count) / 4")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if isLoadingAttachments {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing a private local copy…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(stagedAttachments) { attachment in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        attachmentPreview(attachment)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("\(attachment.kind.displayName) · \(formattedByteCount(attachment.sourceByteCount))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if attachment.kind == .video {
                                Text("The selected AI provider receives sampled still frames only—no audio or full motion.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        Button(role: .destructive) {
                            removeAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.displayName)")
                    }

                    if case .imageData(let data, _) = attachment.source {
                        Button {
                            beginAgentTask {
                                await conversation.importScreenshot(data)
                            }
                        } label: {
                            Label("Extract text on this iPhone", systemImage: "text.viewfinder")
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                    }
                }
                .padding(9)
                .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Text("Selection alone does not run OCR, pronunciation, or AI. Type what the AI should do, then Send. That instruction and these exact items go once to \(configuredProviderLabel); attachment bytes are not added to later chat history.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(OpenClamTheme.subtleFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func attachmentPreview(_ attachment: StagedAgentAttachment) -> some View {
        if case .imageData(let data, _) = attachment.source,
           let image = LocalAttachmentPreviewFactory.makePreview(from: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: attachment.kind.systemImage)
                .font(.title2)
                .foregroundStyle(OpenClamTheme.active)
                .frame(width: 46, height: 46)
                .background(OpenClamTheme.emphasizedFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private var configuredProviderLabel: String {
        if let binding = currentRemoteBinding,
           let connection = agentConnections.connection(for: binding) {
            return "OpenClaw via \(connection.gatewayLabel)"
        }
        guard let url = URL(string: aiConfiguration.effectiveSettings.endpoint),
              let host = url.host else { return "the configured AI provider" }
        return host + (url.path.isEmpty || url.path == "/" ? "" : url.path)
    }

    private var avatarOverlay: some View {
        CaptainAyerAvatarOverlay(
            controller: conversation.captainAyerAvatar,
            interactions: avatarInteractions,
            avatar: activeAvatarDescriptor,
            isTTSEnabled: conversation.isTTSEnabled,
            liveTalkPhase: liveTalk.phase,
            composerTopGlobal: composerTopGlobal,
            isRailFolded: $isAvatarRailFolded,
            showsLatestMessageButton: threadPositioning.isAwayFromLatest,
            onGoToLatestMessage: {
                threadPositioning.resumeFollowingLatest()
                goToLatestMessageRequest &+= 1
            },
            onPlayLatest: {
                guard reserveAppAudioLane() else { return }
                if !conversation.isTTSEnabled {
                    conversation.setTTSEnabled(true)
                }
                conversation.speakLatestAssistantReply(using: aiConfiguration)
                synchronizeQuickDictationAudioOwnership()
            },
            onStop: conversation.stopSpeechOutput,
            onToggleLiveTalk: toggleLiveTalk,
            onSelectAvatar: requestAvatarSwitch
        )
    }

    private var activeAvatarDescriptor: OpenClamAvatarDescriptor {
        avatarLibrary.avatar(id: aiConfiguration.activeAvatarID)
            ?? OpenClamAvatarCatalog.avatars[0]
    }

    private var configuredModelName: String {
        if let binding = currentRemoteBinding { return binding.displayName }
        let value = aiConfiguration.effectiveSettings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "AI" : value
    }

    private var composerModelDisplayName: String {
        guard dynamicTypeSize.isAccessibilitySize else { return configuredModelName }
        guard configuredModelName.lowercased().hasPrefix("gpt-") else {
            return configuredModelName
        }

        return String(configuredModelName.dropFirst(4))
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private var configuredProviderName: String {
        if currentRemoteBinding != nil { return "OpenClaw" }
        return AIProviderRegistry.descriptor(
            for: aiConfiguration.effectiveSettings.llm.provider
        ).displayName
    }

    private var currentRemoteBinding: AvatarAgentConnectorBinding? {
        aiConfiguration.conversationRoute(
            for: conversation.historyController.selectedThreadID
        ).connectorBinding
    }

    private var conversationNavigationTitle: String {
        ConversationNavigationTitlePresentation.title(
            threadTitle: conversation.currentThreadTitle,
            remoteAgentDisplayName: currentRemoteBinding?.displayName,
            isRemoteTurnActive: isRemoteOpenClawTurnActive
        )
    }

    private var isRemoteOpenClawTurnActive: Bool {
        currentRemoteBinding != nil && conversation.isWorking
    }

    private var assistantReplyDeliverySnapshot: AssistantReplyDeliverySnapshot {
        AssistantReplyDeliverySnapshot(
            threadID: conversation.historyController.selectedThreadID,
            messages: conversation.messages
        )
    }

    private var languageModelProviders: [AIProviderDescriptor] {
        AIProviderRegistry.providers(for: .llm).filter {
            AIProviderRegistry.hasRuntimeAdapter(provider: $0.id, capability: .llm)
        }
    }

    private func languageModels(for provider: AIProviderID) -> [String] {
        var models = aiConfiguration.models(for: .llm, provider: provider)
        let current = aiConfiguration.effectiveSettings.llm
        if current.provider == provider,
           !current.model.isEmpty,
           !models.contains(current.model) {
            models.insert(current.model, at: 0)
        }
        return models
    }

    private func updateLanguageModel(provider: AIProviderID, model: String) {
        do {
            try aiConfiguration.updateActiveAvatarLanguageModel(
                .init(provider: provider, model: model)
            )
            modelSelectionError = nil
        } catch {
            modelSelectionError = error.localizedDescription
        }
    }

    private var speechProviderName: String {
        AIProviderRegistry.descriptor(
            for: aiConfiguration.effectiveSettings.speechToText.provider
        ).displayName
    }

    private var speechStatusText: String? {
        if speech.isListening {
            return ConversationSpeechStatusCopy.listening(
                selection: aiConfiguration.effectiveSettings.speechToText,
                providerName: speechProviderName
            )
        }
        if speech.isTranscribing {
            return "Transcribing with \(speechProviderName)…"
        }
        return nil
    }

    private var composerSupportError: String? {
        (suppressesSpeechError ? nil : speech.errorMessage)
            ?? conversation.speechOutputError
            ?? photoError
            ?? modelSelectionError
            ?? liveTalkPTTNotice
    }

    private func composerErrorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Composer error: \(message)")
        .accessibilityIdentifier("openclam-composer-error")
    }

    private func formattedByteCount(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func pendingSiriPromptCard(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Siri question ready", systemImage: "quote.bubble.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OpenClamTheme.active)
            Text(prompt)
                .font(.subheadline)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Dismiss") {
                    conversation.clearPendingShortcutPrompt()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Use question" : "Replace draft") {
                    input = prompt
                    conversation.clearPendingShortcutPrompt()
                }
                .buttonStyle(.borderedProminent)
                .tint(OpenClamTheme.accent)
            }
        }
        .padding(10)
        .background(OpenClamTheme.subtleFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func pendingScreenContextComposerCard(
        _ submission: ScreenContextSubmission
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Reviewed context ready", systemImage: "rectangle.and.text.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OpenClamTheme.active)

            HStack(spacing: 12) {
                if let text = submission.includedText {
                    Label("\(text.count) text characters", systemImage: "text.quote")
                }
                if submission.includedURL != nil {
                    Label("1 web link", systemImage: "link")
                }
                if submission.includedImageData != nil {
                    Label("1 image", systemImage: "photo")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !stagedAttachments.isEmpty {
                Text("Remove or send the existing attachments first; they are not mixed into this reviewed context request.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Edit the instruction below if needed, then tap Send. It is sent as one isolated provider request with no device tools; its rendered message stays in this local chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    useReviewedContextButton(submission)
                    discardReviewedContextButton
                }
            } else {
                HStack {
                    discardReviewedContextButton
                    Spacer()
                    useReviewedContextButton(submission)
                }
            }
        }
        .padding(10)
        .background(OpenClamTheme.subtleFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func useReviewedContextButton(
        _ submission: ScreenContextSubmission
    ) -> some View {
        Button(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Use instruction" : "Restore reviewed instruction") {
            input = submission.instruction
        }
        .buttonStyle(.borderedProminent)
        .tint(OpenClamTheme.accent)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
    }

    private var discardReviewedContextButton: some View {
        Button("Discard context", role: .destructive) {
            conversation.discardPendingScreenContextSubmission()
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
    }

    private func receivePendingShortcutPrompt(_ prompt: String?) {
        guard let prompt,
              input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        input = prompt
        conversation.clearPendingShortcutPrompt()
    }

    private var quickDictationStatusColor: Color {
        switch keyboardDictationHost.warmEarPresentationState {
        case .off, .arming, .paused:
            .secondary
        case .ready:
            OpenClamTheme.active
        case .busy:
            .red
        case .failed:
            .orange
        }
    }

    private var composerIcon: String {
        if speech.isTranscribing { return "ellipsis" }
        if isRemoteOpenClawTurnActive { return "stop.fill" }
        if isRequestActive { return "stop.fill" }
        if speech.isListening { return "stop.fill" }
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "mic.fill" }
        return "arrow.up"
    }

    private var composerColor: Color {
        return speech.isListening ? .red : .primary
    }

    private var composerAccessibilityLabel: String {
        if speech.isTranscribing { return "Transcribing speech" }
        if isRemoteOpenClawTurnActive { return "Stop OpenClaw task" }
        if isRequestActive { return "Stop current request" }
        if speech.isListening { return "Stop listening and send" }
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Start tap to talk" }
        return "Send message"
    }

    private var isRequestActive: Bool {
        activeRequestTask != nil
            || conversation.isWorking
            || commandModel.isExecuting
            || speech.isTranscribing
    }

    private var isChatTransitioning: Bool {
        !conversation.isHistoryReady || conversation.isChangingChat
    }

    private func performComposerAction() {
        guard !isChatTransitioning, !speech.isTranscribing else { return }
        if !liveTalk.phase.isSessionActive {
            conversation.stopSpeechOutput()
        }
        if isRequestActive {
            speech.cancel()
            if isRemoteOpenClawTurnActive {
                // Cancelling the owner task reaches ConversationModel's durable
                // cancellation path for this exact saved OpenClaw turn.
                cancelRemoteAgentActivity()
            } else {
                cancelActiveRequest()
            }
        } else if speech.isListening {
            finishSpeechAndSend()
        } else if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let reason = ConversationMicrophoneOwnership.tapToTalkBlockReason(
                liveTalkPhase: liveTalk.phase
            ) {
                liveTalkPTTNotice = reason
            } else {
                guard reserveAppAudioLane() else { return }
                suppressesSpeechError = false
                liveTalkPTTNotice = nil
                Task {
                    await speech.start(using: aiConfiguration)
                    synchronizeQuickDictationAudioOwnership()
                }
            }
        } else {
            sendInput()
        }
    }

    private func dismissKeyboard() {
        isComposerFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func cardHeader(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(color)
    }

    private func distanceLabel(_ meters: Double) -> String {
        if meters < 1_000 {
            return "About \(Int(meters.rounded())) m away"
        }
        return String(format: "About %.1f km away", meters / 1_000)
    }

    private func copyAssistantMessage(_ message: ConversationMessage) {
        guard let text = ConversationMessageInteractionPolicy.wholeEntryText(for: message) else {
            return
        }
        UIPasteboard.general.string = text
        AccessibilityNotification.Announcement("Assistant response copied.").post()
    }

    private func toggleAssistantMessageReadAloud(_ message: ConversationMessage) {
        if conversation.isSpeechOutputActive, readAloudMessageID == message.id {
            conversation.stopSpeechOutput()
            readAloudMessageID = nil
            return
        }

        guard !liveTalk.phase.isSessionActive,
              !speech.isListening,
              !speech.isTranscribing,
              let text = ConversationMessageInteractionPolicy.wholeEntryText(for: message) else {
            return
        }
        guard reserveAppAudioLane() else { return }
        readAloudMessageID = message.id
        conversation.readAssistantReplyAloud(text, using: aiConfiguration)
        synchronizeQuickDictationAudioOwnership()
        if !conversation.isSpeechOutputActive {
            readAloudMessageID = nil
        }
    }

    private func stageSelectedTextForAI(_ selectedText: String) {
        guard let draft = ConversationMessageInteractionPolicy.askAIDraft(
            selectedText: selectedText,
            existingDraft: input
        ) else { return }

        // A partial-selection action explicitly transitions ordinary tap-to-talk back to an
        // editable draft. Continuous Live Talk remains untouched; the existing input-change
        // boundary also avoids interrupting its remote audio session.
        if speech.isListening || speech.isTranscribing {
            speech.cancel()
        }
        input = draft
        expandsComposerForEditing = true
        DispatchQueue.main.async {
            isComposerFocused = true
            AccessibilityNotification.Announcement(
                "Selected text is ready in the composer. Review it, then tap Send."
            ).post()
        }
    }

    private func presentConnectorArtifact(
        _ attachment: ConversationAttachmentDescriptor,
        forSharing: Bool
    ) {
        guard attachment.connectorArtifact != nil else { return }
        Task { @MainActor in
            guard let url = await agentConnections.storedArtifactURL(for: attachment) else {
                connectorArtifactFeedback = .error(
                    "This verified OpenClaw file is no longer stored on this iPhone."
                )
                return
            }
            let presentation = ConnectorArtifactPresentation(
                attachment: attachment,
                url: url
            )
            if forSharing {
                sharedConnectorArtifact = presentation
            } else {
                presentedConnectorArtifact = presentation
            }
        }
    }

    private func saveConnectorArtifactToPhotos(
        _ attachment: ConversationAttachmentDescriptor
    ) {
        guard attachment.connectorArtifact != nil,
              attachment.kind == .image || attachment.kind == .video else { return }
        Task { @MainActor in
            guard let sourceURL = await agentConnections.storedArtifactURL(for: attachment) else {
                connectorArtifactFeedback = .error(
                    "This verified OpenClaw file is no longer stored on this iPhone."
                )
                return
            }
            do {
                try await ConnectorArtifactPhotoLibrarySaver.save(
                    sourceURL: sourceURL,
                    kind: attachment.kind
                )
                connectorArtifactFeedback = .init(
                    title: "Saved to Photos",
                    message: "\(attachment.displayName) is now in your photo library."
                )
                AccessibilityNotification.Announcement(
                    "Saved \(attachment.displayName) to Photos."
                ).post()
            } catch {
                let photoError = error as? ConnectorArtifactPhotoLibrarySaveError
                connectorArtifactFeedback = .init(
                    title: "Couldn’t Save to Photos",
                    message: error.localizedDescription,
                    offersSettings: photoError?.offersSettings == true
                )
            }
        }
    }

    private func saveConnectorArtifactToFiles(
        _ attachment: ConversationAttachmentDescriptor
    ) {
        guard attachment.connectorArtifact != nil else { return }
        Task { @MainActor in
            guard let sourceURL = await agentConnections.storedArtifactURL(for: attachment) else {
                connectorArtifactFeedback = .error(
                    "This verified OpenClaw file is no longer stored on this iPhone."
                )
                return
            }
            clearConnectorArtifactExport()
            do {
                let stagedURL = try ConnectorArtifactExportStager.stageCopy(
                    of: sourceURL,
                    displayName: attachment.displayName
                )
                exportedConnectorArtifact = .init(
                    defaultFilename: stagedURL.lastPathComponent,
                    stagedURL: stagedURL
                )
            } catch {
                connectorArtifactFeedback = .error(
                    "OpenClam could not prepare this verified file for saving. \(error.localizedDescription)"
                )
            }
        }
    }

    private func handleConnectorArtifactExportCompletion(destinationURL: URL?) {
        let savedName = exportedConnectorArtifact?.defaultFilename ?? "file"
        defer { clearConnectorArtifactExport() }
        if destinationURL != nil {
            AccessibilityNotification.Announcement(
                "Saved \(savedName) to Files."
            ).post()
        }
    }

    private func clearConnectorArtifactExport() {
        if let stagedURL = exportedConnectorArtifact?.stagedURL {
            ConnectorArtifactExportStager.removeStagedCopy(at: stagedURL)
        }
        exportedConnectorArtifact = nil
    }

    private func sendInput(_ submittedValue: String? = nil) {
        guard !conversation.isWorking, !isChatTransitioning else { return }
        // A deliberate conversation turn always brings the remembered
        // Standby companion back from a transient walk, edge idle, or move.
        avatarInteractions.noteThreadInteraction()
        conversation.stopSpeechOutput()
        confirmedActionNotice = nil
        if speech.isListening {
            finishSpeechAndSend()
            return
        }
        let value = (submittedValue ?? input)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if conversation.pendingScreenContextSubmission != nil {
            guard stagedAttachments.isEmpty else {
                photoError = "Remove or send the existing attachments before sending the reviewed screen context."
                return
            }
            beginAgentTask {
                let succeeded = await conversation.submitPendingScreenContext(
                    editedInstruction: value,
                    using: aiConfiguration
                )
                guard succeeded else { return }
                input = ""
                photoError = nil
            }
            return
        }
        if stagedAttachments.isEmpty {
            if currentRemoteBinding != nil {
                beginAgentTask {
                    await conversation.submit(
                        value,
                        aiConfiguration: aiConfiguration,
                        agentConnections: agentConnections,
                        onSubmissionSaved: {
                            // Do not erase edits made while the secure outbox was being created.
                            if input.trimmingCharacters(in: .whitespacesAndNewlines) == value {
                                input = ""
                            }
                        }
                    )
                }
            } else {
                input = ""
                beginAgentTask {
                    await conversation.submit(
                        value,
                        aiConfiguration: aiConfiguration,
                        agentConnections: agentConnections
                    )
                }
            }
        } else {
            let submittedAttachments = stagedAttachments
            cacheActiveSessionImagePreviews(from: submittedAttachments)
            beginAgentTask {
                let succeeded = await conversation.submitAttachments(
                    value,
                    attachments: submittedAttachments,
                    using: aiConfiguration
                )
                guard succeeded else { return }
                await conversation.removeAttachments(submittedAttachments)
                let submittedIDs = Set(submittedAttachments.map(\.id))
                stagedAttachments.removeAll { submittedIDs.contains($0.id) }
                selectedMedia = []
                input = ""
                photoError = nil
            }
        }
    }

    private func finishSpeechAndSend() {
        Task { @MainActor in
            let value = await speech.stopForSubmission(using: aiConfiguration)
            input = value
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            sendInput(value)
        }
    }

    private func beginAttachmentPreparation(
        _ operation: @escaping @MainActor (UUID) async -> Void
    ) {
        attachmentPreparationTask?.cancel()
        let requestID = UUID()
        attachmentPreparationID = requestID
        attachmentPreparationTask = Task { @MainActor in
            await operation(requestID)
            guard attachmentPreparationID == requestID else { return }
            attachmentPreparationTask = nil
            attachmentPreparationID = nil
        }
    }

    private func stageSelectedMedia(
        _ items: [PhotosPickerItem],
        requestID: UUID
    ) async {
        guard attachmentPreparationID == requestID, !isLoadingAttachments else { return }
        let availableSlots = max(0, 4 - stagedAttachments.count)
        guard availableSlots > 0 else {
            photoError = "Remove an attachment before adding another one."
            selectedMedia = []
            return
        }

        isLoadingAttachments = true
        defer {
            if attachmentPreparationID == requestID {
                isLoadingAttachments = false
                selectedMedia = []
            }
        }
        photoError = nil

        for (offset, item) in items.prefix(availableSlots).enumerated() {
            do {
                let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
                if isVideo {
                    guard let transferred = try await item.loadTransferable(type: PickerVideoFile.self) else {
                        throw AttachmentPreparationError.invalidVideo
                    }
                    defer { try? FileManager.default.removeItem(at: transferred.url) }
                    let mimeType = item.supportedContentTypes
                        .first(where: { $0.conforms(to: .movie) })?
                        .preferredMIMEType
                    let attachment = try await conversation.stageVideoAttachment(
                        at: transferred.url,
                        displayName: "Selected video \(offset + 1).mov",
                        mimeType: mimeType
                    )
                    guard attachmentPreparationID == requestID, !Task.isCancelled else {
                        await conversation.removeAttachments([attachment])
                        return
                    }
                    stagedAttachments.append(attachment)
                } else {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw AttachmentPreparationError.invalidImage
                    }
                    let mimeType = item.supportedContentTypes
                        .first(where: { $0.conforms(to: .image) })?
                        .preferredMIMEType
                    let attachment = try await conversation.stageImageAttachment(
                        data,
                        filename: "Selected image \(offset + 1).jpg",
                        mimeType: mimeType
                    )
                    guard attachmentPreparationID == requestID, !Task.isCancelled else {
                        await conversation.removeAttachments([attachment])
                        return
                    }
                    stagedAttachments.append(attachment)
                }
            } catch {
                guard attachmentPreparationID == requestID, !Task.isCancelled else { return }
                photoError = error.localizedDescription
                break
            }
        }
    }

    private func stageCameraImage(_ image: UIImage, requestID: UUID) async {
        guard attachmentPreparationID == requestID, !isLoadingAttachments else { return }
        guard stagedAttachments.count < 4 else {
            photoError = "Remove an attachment before adding another one."
            return
        }
        guard let data = image.jpegData(compressionQuality: 0.90) else {
            photoError = "The captured photo could not be prepared."
            return
        }

        isLoadingAttachments = true
        defer {
            if attachmentPreparationID == requestID {
                isLoadingAttachments = false
            }
        }
        photoError = nil

        do {
            let attachment = try await conversation.stageImageAttachment(
                data,
                filename: "Camera photo.jpg",
                mimeType: "image/jpeg"
            )
            guard attachmentPreparationID == requestID, !Task.isCancelled else {
                await conversation.removeAttachments([attachment])
                return
            }
            stagedAttachments.append(attachment)
        } catch {
            guard attachmentPreparationID == requestID, !Task.isCancelled else { return }
            photoError = error.localizedDescription
        }
    }

    private func handleImportedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            photoError = error.localizedDescription
        case .success(let urls):
            beginAttachmentPreparation { requestID in
                await stageImportedFiles(urls, requestID: requestID)
            }
        }
    }

    private func stageImportedFiles(_ urls: [URL], requestID: UUID) async {
        guard attachmentPreparationID == requestID, !isLoadingAttachments else { return }
        let availableSlots = max(0, 4 - stagedAttachments.count)
        guard availableSlots > 0 else {
            photoError = "Remove an attachment before adding another one."
            return
        }
        isLoadingAttachments = true
        defer {
            if attachmentPreparationID == requestID {
                isLoadingAttachments = false
            }
        }
        photoError = nil
        for url in urls.prefix(availableSlots) {
            do {
                let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                let attachment: StagedAgentAttachment
                if type?.conforms(to: .movie) == true {
                    attachment = try await conversation.stageVideoAttachment(
                        at: url,
                        displayName: url.lastPathComponent,
                        mimeType: type?.preferredMIMEType
                    )
                } else {
                    attachment = try await conversation.stageFileAttachment(
                        at: url,
                        displayName: url.lastPathComponent,
                        mimeType: type?.preferredMIMEType
                    )
                }
                guard attachmentPreparationID == requestID, !Task.isCancelled else {
                    await conversation.removeAttachments([attachment])
                    return
                }
                stagedAttachments.append(attachment)
            } catch {
                guard attachmentPreparationID == requestID, !Task.isCancelled else { return }
                photoError = error.localizedDescription
                break
            }
        }
    }

    private func resetComposerForChatChange() {
        let attachmentsToRemove = stagedAttachments
        attachmentPreparationID = nil
        attachmentPreparationTask?.cancel()
        attachmentPreparationTask = nil
        cancelActiveRequest()
        speech.cancel()
        conversation.stopSpeechOutput()
        dismissKeyboard()

        input = ""
        selectedMedia = []
        stagedAttachments = []
        isLoadingAttachments = false
        showsMediaPicker = false
        showsCamera = false
        showsFileImporter = false
        photoError = nil
        presentedConnectorArtifact = nil
        sharedConnectorArtifact = nil
        clearConnectorArtifactExport()
        connectorArtifactFeedback = nil
        persistedConnectorVisualPreviews = [:]
        modelSelectionError = nil
        suppressesSpeechError = true
        confirmedActionNotice = nil
        confirmedActionSucceeded = true

        guard !attachmentsToRemove.isEmpty else { return }
        Task { await conversation.removeAttachments(attachmentsToRemove) }
    }

    private func removeAttachment(_ attachment: StagedAgentAttachment) {
        stagedAttachments.removeAll { $0.id == attachment.id }
        Task { await conversation.removeAttachments([attachment]) }
    }

    private func cacheActiveSessionImagePreviews(
        from attachments: [StagedAgentAttachment]
    ) {
        for attachment in attachments {
            guard case .imageData(let data, _) = attachment.source,
                  let preview = LocalAttachmentPreviewFactory.makePreview(from: data) else {
                continue
            }

            activeSessionImagePreviews[attachment.id] = preview
            activeSessionImagePreviewOrder.removeAll { $0 == attachment.id }
            activeSessionImagePreviewOrder.append(attachment.id)
        }

        while activeSessionImagePreviewOrder.count
            > LocalAttachmentPreviewFactory.maximumCachedPreviewCount {
            let removedID = activeSessionImagePreviewOrder.removeFirst()
            activeSessionImagePreviews[removedID] = nil
        }
    }

    private var messageVisualPreviews: [UUID: UIImage] {
        persistedConnectorVisualPreviews.merging(activeSessionImagePreviews) { _, active in
            active
        }
    }

    private var connectorVisualThumbnailSnapshot: String {
        let thread = conversation.historyController.selectedThreadID?.uuidString ?? "none"
        let artifacts: [String] = conversation.messages
            .flatMap(\.attachments)
            .compactMap { attachment -> String? in
            guard attachment.kind == .image || attachment.kind == .video,
                  let reference = attachment.connectorArtifact else { return nil }
            return attachment.id.uuidString.lowercased() + ":" + reference.sha256
            }
        return ([thread] + artifacts).joined(separator: "|")
    }

    private func loadPersistedConnectorVisualPreviews() async {
        let descriptors = conversation.messages.flatMap(\.attachments).filter {
            ($0.kind == .image || $0.kind == .video) && $0.connectorArtifact != nil
        }
        let desiredIDs = Set(descriptors.map(\.id))
        persistedConnectorVisualPreviews = persistedConnectorVisualPreviews.filter {
            desiredIDs.contains($0.key)
        }
        for descriptor in descriptors where persistedConnectorVisualPreviews[descriptor.id] == nil {
            guard !Task.isCancelled,
                  let data = await agentConnections.storedArtifactThumbnailData(for: descriptor),
                  !Task.isCancelled,
                  let image = UIImage(data: data),
                  conversation.messages.flatMap(\.attachments).contains(where: {
                      $0.id == descriptor.id
                          && $0.connectorArtifact == descriptor.connectorArtifact
                  }) else { continue }
            persistedConnectorVisualPreviews[descriptor.id] = image
        }
    }

    private func confirm(_ command: AssistantCommand) {
        guard !conversation.isWorking, !commandModel.isExecuting else { return }
        conversation.stopSpeechOutput()
        beginAgentTask {
            confirmedActionSucceeded = await commandModel.runConfirmed(command)
            confirmedActionNotice = commandModel.lastResult
        }
    }

    private func beginAgentTask(_ operation: @escaping @MainActor () async -> Void) {
        guard activeRequestTask == nil else { return }
        let requestID = UUID()
        activeRequestID = requestID
        activeRequestTask = Task { @MainActor in
            await operation()
            guard activeRequestID == requestID else { return }
            activeRequestTask = nil
            activeRequestID = nil
        }
    }

    private func cancelActiveRequest() {
        activeRequestID = nil
        activeRequestTask?.cancel()
        activeRequestTask = nil
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, animated: Bool = true) {
        Task { @MainActor in
            await Task.yield()
            if animated && !reduceMotion {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func placeNewUserTurn(
        _ messageID: UUID,
        using proxy: ScrollViewProxy
    ) {
        Task { @MainActor in
            // The message and its response reserve enter the lazy stack in the
            // same update. Yield once so ScrollView measures both before asking
            // it to place the submitted bubble at the top.
            await Task.yield()
            guard threadPositioning.anchoredUserMessageID == messageID,
                  !threadPositioning.hasManualScrollSincePlacement else {
                return
            }
            if reduceMotion {
                proxy.scrollTo(messageID, anchor: .top)
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(messageID, anchor: .top)
                }
            }
        }
    }

    private func revealPendingEmailReview(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            if reduceMotion {
                proxy.scrollTo(
                    ConversationReviewRevealPolicy.pendingEmailAnchorID,
                    anchor: .top
                )
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(
                        ConversationReviewRevealPolicy.pendingEmailAnchorID,
                        anchor: .top
                    )
                }
            }
        }
    }

    @discardableResult
    private func deliverNewAssistantReply(
        from snapshot: AssistantReplyDeliverySnapshot
    ) -> UUID? {
        guard let messageID = assistantReplyDeliveryBoundary.observe(snapshot),
              let message = conversation.messages.first(where: { $0.id == messageID }) else {
            return nil
        }
        AccessibilityNotification.Announcement("Assistant: \(message.text)").post()
        if !liveTalk.phase.isSessionActive, reserveAppAudioLane() {
            conversation.speakAssistantReply(message.text, using: aiConfiguration)
            synchronizeQuickDictationAudioOwnership()
        }
        return messageID
    }

    private func toggleLiveTalk() {
        dismissKeyboard()
        if liveTalk.phase.isSessionActive {
            conversation.ingestLiveTalkTranscripts(liveTalk.transcripts)
            conversation.endLiveTalkTranscriptSession()
            Task {
                await liveTalk.stop()
                liveTalkPTTNotice = nil
            }
            return
        }

        guard reserveAppAudioLane() else { return }
        speech.cancel()
        conversation.stopSpeechOutput()
        liveTalkPTTNotice = nil
        guard conversation.beginLiveTalkTranscriptSession() else {
            liveTalkPTTNotice = "Wait for this chat to finish loading, then start Live Talk again."
            return
        }
        liveTalk.begin(
            avatar: aiConfiguration.activeAvatarProfile,
            sharedSettings: aiConfiguration.settings,
            avatarController: conversation.captainAyerAvatar,
            emailDraftToolHandler: { request in
                await conversation.stageLiveTalkEmailDraft(
                    request,
                    appIsActive: UIApplication.shared.applicationState == .active
                )
            },
            agentTurnToolHandler: { request in
                guard UIApplication.shared.applicationState == .active else {
                    return .foregroundRequired
                }
                // Commit the authoritative final transcript before routing so
                // the connector reuses its visible user bubble instead of adding
                // a duplicate message.
                conversation.ingestLiveTalkTranscripts(liveTalk.transcripts)
                guard let binding = aiConfiguration.conversationRoute(
                    for: conversation.historyController.selectedThreadID
                ).connectorBinding else {
                    return .completed(
                        "Choose a paired OpenClaw agent for this chat before asking Live Talk to run actions."
                    )
                }
                return await conversation.submitLiveTalkAgentTurn(
                    request.spokenRequest,
                    binding: binding,
                    agentConnections: agentConnections
                )
            }
        )
        synchronizeQuickDictationAudioOwnership()
    }

    private var appAudioActivityIsActive: Bool {
        liveTalk.phase.isSessionActive
            || speech.isListening
            || speech.isTranscribing
            || conversation.isSpeechOutputActive
            || conversation.isPronunciationOutputActive
    }

    @discardableResult
    private func reserveAppAudioLane() -> Bool {
        if let reason = keyboardDictationHost.prepareForCompetingAppAudio() {
            liveTalkPTTNotice = reason
            return false
        }
        return true
    }

    private func synchronizeQuickDictationAudioOwnership() {
        keyboardDictationHost.setCompetingAppAudioActive(appAudioActivityIsActive)
    }

    private func requestAvatarSwitch(_ id: String, _ displayName: String) {
        guard LiveTalkAvatarSwitchPolicy.allowsSwitch(during: liveTalk.phase) else {
            liveTalkPTTNotice = LiveTalkAvatarSwitchPolicy.blockedGuidance
            return
        }
        onSelectAvatar(id, displayName)
    }
}

struct AssistantReplyDeliverySnapshot: Equatable {
    struct MessageSignature: Equatable {
        let id: UUID
        let role: ConversationMessage.Role
    }

    let threadID: UUID?
    let messages: [MessageSignature]

    init(threadID: UUID?, messages: [ConversationMessage]) {
        self.threadID = threadID
        self.messages = messages.map { MessageSignature(id: $0.id, role: $0.role) }
    }
}

/// A view-owned event boundary that distinguishes an append in the active chat from restoring or
/// selecting history. History transitions only establish a baseline; they never emit speech.
struct AssistantReplyDeliveryBoundary {
    private var isPrimed = false
    private var threadID: UUID?
    private var messages: [AssistantReplyDeliverySnapshot.MessageSignature] = []

    mutating func prime(with snapshot: AssistantReplyDeliverySnapshot) {
        isPrimed = true
        threadID = snapshot.threadID
        messages = snapshot.messages
    }

    mutating func observe(_ snapshot: AssistantReplyDeliverySnapshot) -> UUID? {
        guard isPrimed else {
            prime(with: snapshot)
            return nil
        }

        let previousThreadID = threadID
        let previousMessages = messages
        prime(with: snapshot)

        guard snapshot.threadID == previousThreadID,
              snapshot.messages.count > previousMessages.count,
              Array(snapshot.messages.prefix(previousMessages.count)) == previousMessages else {
            return nil
        }

        return snapshot.messages
            .dropFirst(previousMessages.count)
            .last(where: { $0.role == .assistant })?
            .id
    }
}

/// Tracks only genuine appends in the selected thread. A restored history or a
/// thread switch establishes a new baseline and must never reposition content.
/// Scanning the appended suffix also handles a fast local reply where SwiftUI
/// observes the user and assistant messages in one coalesced update.
struct ConversationUserTurnPlacementBoundary {
    private var isPrimed = false
    private var threadID: UUID?
    private var messages: [AssistantReplyDeliverySnapshot.MessageSignature] = []

    mutating func prime(with snapshot: AssistantReplyDeliverySnapshot) {
        isPrimed = true
        threadID = snapshot.threadID
        messages = snapshot.messages
    }

    mutating func observe(_ snapshot: AssistantReplyDeliverySnapshot) -> UUID? {
        guard isPrimed else {
            prime(with: snapshot)
            return nil
        }

        let previousThreadID = threadID
        let previousMessages = messages
        prime(with: snapshot)

        guard snapshot.threadID == previousThreadID,
              snapshot.messages.count > previousMessages.count,
              Array(snapshot.messages.prefix(previousMessages.count)) == previousMessages else {
            return nil
        }

        return snapshot.messages
            .dropFirst(previousMessages.count)
            .last(where: { $0.role == .user })?
            .id
    }
}

enum LocalAttachmentPreviewFactory {
    static let maximumPixelDimension: CGFloat = 384
    static let maximumCachedPreviewCount = 16

    static func makePreview(from data: Data) -> UIImage? {
        let maximumDimension = Int(maximumPixelDimension.rounded(.down))
        guard let thumbnail = try? BoundedImageData.makeThumbnail(
            from: data,
            maximumThumbnailDimension: maximumDimension
        ) else { return nil }
        // One point equals one decoded thumbnail pixel, independent of device screen scale.
        return UIImage(cgImage: thumbnail, scale: 1, orientation: .up)
    }
}

/// Camera capture stays inside the composer attachment flow: taking a photo
/// only stages it, and the user still supplies an instruction and taps Send.
@MainActor
private struct OpenClamCameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
        UINavigationControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

/// Observes the scroll view's own pan recognizer and adds a non-cancelling tap
/// observer. It never installs a competing pan gesture, so chat scrolling and
/// message controls keep their native gesture arbitration.
@MainActor
private struct ConversationThreadInteractionObserver: UIViewRepresentable {
    let onTapInteraction: () -> Void
    let onScrollInteraction: () -> Void
    let onManualScroll: () -> Void
    let onLatestVisibilityChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTapInteraction: onTapInteraction,
            onScrollInteraction: onScrollInteraction,
            onManualScroll: onManualScroll,
            onLatestVisibilityChanged: onLatestVisibilityChanged
        )
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        view.scheduleAttachment()
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        context.coordinator.onTapInteraction = onTapInteraction
        context.coordinator.onScrollInteraction = onScrollInteraction
        context.coordinator.onManualScroll = onManualScroll
        context.coordinator.onLatestVisibilityChanged = onLatestVisibilityChanged
        uiView.coordinator = context.coordinator
        uiView.scheduleAttachment()
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
        uiView.coordinator = nil
    }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleAttachment()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            scheduleAttachment()
        }

        func scheduleAttachment() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                coordinator?.attach(from: self)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTapInteraction: () -> Void
        var onScrollInteraction: () -> Void
        var onManualScroll: () -> Void
        var onLatestVisibilityChanged: (Bool) -> Void

        private weak var scrollView: UIScrollView?
        private var tapGesture: UITapGestureRecognizer?
        private var lastScrollSignal = -TimeInterval.infinity

        init(
            onTapInteraction: @escaping () -> Void,
            onScrollInteraction: @escaping () -> Void,
            onManualScroll: @escaping () -> Void,
            onLatestVisibilityChanged: @escaping (Bool) -> Void
        ) {
            self.onTapInteraction = onTapInteraction
            self.onScrollInteraction = onScrollInteraction
            self.onManualScroll = onManualScroll
            self.onLatestVisibilityChanged = onLatestVisibilityChanged
        }

        func attach(from probe: UIView) {
            var ancestor = probe.superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    attach(to: scrollView)
                    return
                }
                ancestor = current.superview
            }
        }

        func detach() {
            guard let scrollView else { return }
            scrollView.panGestureRecognizer.removeTarget(
                self,
                action: #selector(scrollPanChanged(_:))
            )
            if let tapGesture {
                scrollView.removeGestureRecognizer(tapGesture)
            }
            self.scrollView = nil
            tapGesture = nil
        }

        private func attach(to newScrollView: UIScrollView) {
            guard scrollView !== newScrollView else { return }
            detach()
            scrollView = newScrollView
            newScrollView.panGestureRecognizer.addTarget(
                self,
                action: #selector(scrollPanChanged(_:))
            )

            let tapGesture = UITapGestureRecognizer(
                target: self,
                action: #selector(threadTapped(_:))
            )
            tapGesture.cancelsTouchesInView = false
            tapGesture.delaysTouchesBegan = false
            tapGesture.delaysTouchesEnded = false
            tapGesture.delegate = self
            newScrollView.addGestureRecognizer(tapGesture)
            self.tapGesture = tapGesture
        }

        @objc private func scrollPanChanged(_ gesture: UIPanGestureRecognizer) {
            let now = ProcessInfo.processInfo.systemUptime
            switch gesture.state {
            case .began:
                onManualScroll()
                lastScrollSignal = now
                onScrollInteraction()
            case .ended, .cancelled:
                lastScrollSignal = now
                publishLatestVisibility()
                onScrollInteraction()
            case .changed where now - lastScrollSignal >= 0.15:
                lastScrollSignal = now
                publishLatestVisibility()
                onScrollInteraction()
            default:
                break
            }
        }

        private func publishLatestVisibility() {
            guard let scrollView else { return }
            let minimumOffsetY = -scrollView.adjustedContentInset.top
            let maximumOffsetY = max(
                minimumOffsetY,
                scrollView.contentSize.height
                    - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom
            )
            let distanceFromLatest = maximumOffsetY - scrollView.contentOffset.y
            onLatestVisibilityChanged(distanceFromLatest <= 24)
        }

        @objc private func threadTapped(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            onTapInteraction()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private extension View {
    func assistantCard(stroke: Color) -> some View {
        padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.035), radius: 8, y: 3)
    }
}

private struct ConnectorArtifactFeedback {
    let title: String
    let message: String
    var offersSettings = false

    static func error(_ message: String) -> Self {
        .init(title: "OpenClaw File", message: message)
    }
}

enum ConnectorArtifactPhotoAuthorizationDecision: Equatable {
    case request
    case save
    case deny
}

enum ConnectorArtifactPhotoLibrarySaveError: LocalizedError {
    case unsupportedAttachment
    case attachmentUnavailable
    case permissionDenied
    case permissionRestricted
    case photoLibraryFailure(Error?)

    var offersSettings: Bool {
        if case .permissionDenied = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedAttachment:
            "Only verified images and videos can be saved to Photos."
        case .attachmentUnavailable:
            "This verified OpenClaw media file is no longer available on this iPhone."
        case .permissionDenied:
            "Allow OpenClam to add photos in Settings, then try again."
        case .permissionRestricted:
            "This iPhone does not allow OpenClam to add items to Photos."
        case .photoLibraryFailure(let underlyingError):
            underlyingError?.localizedDescription
                ?? "Photos could not save this media file. Please try again."
        }
    }
}

/// Saves only an already verified, app-local connector artifact. No network request or second
/// download is performed, and `shouldMoveFile` stays false so Photos cannot remove the private
/// artifact that still backs the conversation preview and Share action.
enum ConnectorArtifactPhotoLibrarySaver {
    static func authorizationDecision(
        for status: PHAuthorizationStatus
    ) -> ConnectorArtifactPhotoAuthorizationDecision {
        switch status {
        case .notDetermined:
            .request
        case .authorized, .limited:
            .save
        case .denied, .restricted:
            .deny
        @unknown default:
            .deny
        }
    }

    static func resourceType(
        for kind: ConversationAttachmentDescriptor.Kind
    ) -> PHAssetResourceType? {
        switch kind {
        case .image: .photo
        case .video: .video
        case .file, .unknown: nil
        }
    }

    static func save(
        sourceURL: URL,
        kind: ConversationAttachmentDescriptor.Kind
    ) async throws {
        guard let resourceType = resourceType(for: kind) else {
            throw ConnectorArtifactPhotoLibrarySaveError.unsupportedAttachment
        }
        guard let values = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            throw ConnectorArtifactPhotoLibrarySaveError.attachmentUnavailable
        }

        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if authorizationDecision(for: status) == .request {
            status = await requestAddOnlyAuthorization()
        }
        switch status {
        case .authorized, .limited:
            break
        case .restricted:
            throw ConnectorArtifactPhotoLibrarySaveError.permissionRestricted
        case .denied, .notDetermined:
            throw ConnectorArtifactPhotoLibrarySaveError.permissionDenied
        @unknown default:
            throw ConnectorArtifactPhotoLibrarySaveError.permissionDenied
        }

        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                creationRequest.addResource(
                    with: resourceType,
                    fileURL: sourceURL,
                    options: options
                )
            } completionHandler: { saved, error in
                if saved {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: ConnectorArtifactPhotoLibrarySaveError
                            .photoLibraryFailure(error)
                    )
                }
            }
        }
    }

    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

/// Creates a short-lived, user-named copy of an already verified connector artifact for the
/// system Files exporter. Export never performs another network request and never exposes the
/// app-private `content.<ext>` storage name to the user.
enum ConnectorArtifactExportStager {
    private static let containerName = "OpenClamArtifactExports"
    private static let maximumFilenameLength = 160

    static func stageCopy(
        of sourceURL: URL,
        displayName: String,
        fileManager: FileManager = .default,
        temporaryRoot: URL? = nil
    ) throws -> URL {
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw AgentConnectorError.attachmentUnavailable
        }

        let root = (temporaryRoot ?? fileManager.temporaryDirectory)
            .appendingPathComponent(containerName, isDirectory: true)
        let exportDirectory = root
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: exportDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            var mutableDirectory = exportDirectory
            try mutableDirectory.setResourceValues(directoryValues)

            let destination = exportDirectory.appendingPathComponent(
                sanitizedFilename(displayName: displayName, sourceURL: sourceURL),
                isDirectory: false
            )
            try fileManager.copyItem(at: sourceURL, to: destination)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: destination.path
            )
            var fileValues = URLResourceValues()
            fileValues.isExcludedFromBackup = true
            var mutableDestination = destination
            try mutableDestination.setResourceValues(fileValues)
            return destination
        } catch {
            try? fileManager.removeItem(at: exportDirectory)
            throw error
        }
    }

    static func sanitizedFilename(
        displayName: String,
        sourceURL: URL
    ) -> String {
        let normalized = displayName.replacingOccurrences(of: "\\", with: "/")
        let leaf = normalized.split(separator: "/", omittingEmptySubsequences: true)
            .last.map(String.init) ?? ""
        let safeScalars = leaf.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == ":" {
                return "-"
            }
            return Character(scalar)
        }
        var candidate = String(safeScalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty || candidate == "." || candidate == ".." {
            candidate = "OpenClam file"
        }

        let sourceExtension = sourceURL.pathExtension.lowercased()
        let hasSafeSourceExtension = sourceExtension.range(
            of: #"^[a-z0-9]{1,12}$"#,
            options: .regularExpression
        ) != nil
        if (candidate as NSString).pathExtension.isEmpty, hasSafeSourceExtension {
            candidate += ".\(sourceExtension)"
        }

        guard candidate.count > maximumFilenameLength else { return candidate }
        let candidateExtension = (candidate as NSString).pathExtension
        let suffix = candidateExtension.isEmpty ? "" : ".\(candidateExtension)"
        let stem = (candidate as NSString).deletingPathExtension
        let maximumStemLength = max(1, maximumFilenameLength - suffix.count)
        return String(stem.prefix(maximumStemLength)) + suffix
    }

    static func removeStagedCopy(
        at stagedURL: URL,
        fileManager: FileManager = .default
    ) {
        let exportDirectory = stagedURL.deletingLastPathComponent()
        guard exportDirectory.deletingLastPathComponent().lastPathComponent == containerName else {
            return
        }
        try? fileManager.removeItem(at: exportDirectory)
    }
}

private struct ConnectorArtifactPresentation: Identifiable {
    let attachment: ConversationAttachmentDescriptor
    let url: URL

    var id: UUID { attachment.id }
}

private struct ConnectorArtifactExportPresentation: Identifiable {
    let id = UUID()
    let defaultFilename: String
    let stagedURL: URL
}

private struct ConnectorArtifactPreview: View {
    @Environment(\.dismiss) private var dismiss
    let presentation: ConnectorArtifactPresentation

    var body: some View {
        NavigationStack {
            Group {
                switch presentation.attachment.kind {
                case .image:
                    // Quick Look owns the full-resolution decode. Inline thread previews use a
                    // separately bounded, off-main thumbnail cache.
                    ConnectorQuickLookPreview(url: presentation.url)
                case .video:
                    ConnectorVideoPreview(url: presentation.url)
                case .file, .unknown:
                    ConnectorQuickLookPreview(url: presentation.url)
                }
            }
            .navigationTitle(presentation.attachment.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("openclam-openclaw-file-preview")
    }
}

private struct ConnectorVideoPreview: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
            .accessibilityLabel("Generated video preview")
    }
}

private struct ConnectorQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: QLPreviewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct ConnectorArtifactShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct ConnectorArtifactFilesExporter: UIViewControllerRepresentable {
    let url: URL
    let onFinish: (URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forExporting: [url],
            asCopy: true
        )
        controller.delegate = context.coordinator
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: (URL?) -> Void
        private var hasFinished = false

        init(onFinish: @escaping (URL?) -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            finish(with: urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(with: nil)
        }

        private func finish(with destinationURL: URL?) {
            guard !hasFinished else { return }
            hasFinished = true
            onFinish(destinationURL)
        }
    }
}

private struct PickerVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let sourceExtension = received.file.pathExtension.isEmpty
                ? "mov"
                : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexPicker-\(UUID().uuidString).\(sourceExtension)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}

private extension AgentAttachmentKind {
    var displayName: String {
        switch self {
        case .image: "Image"
        case .file: "File"
        case .video: "Video"
        }
    }

    var systemImage: String {
        switch self {
        case .image: "photo"
        case .file: "doc.fill"
        case .video: "video.fill"
        }
    }
}
