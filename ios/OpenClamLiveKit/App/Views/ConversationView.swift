import Accessibility
import CoreTransferable
import PhotosUI
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
}

struct ConversationComposerTextInsets: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, ConversationComposerLayout.textHorizontalInset)
            .padding(.vertical, ConversationComposerLayout.textVerticalInset)
            .contentShape(Rectangle())
    }
}

private struct AvatarOverlayInteractionShape: Shape {
    // Assistant response actions occupy the compact leading lane. The avatar and its
    // controls remain interactive across the larger trailing portion of the stage.
    private static let leadingPassThroughFraction: CGFloat = 0.34

    func path(in rect: CGRect) -> Path {
        let leadingWidth = rect.width * Self.leadingPassThroughFraction
        return Path(
            CGRect(
                x: rect.minX + leadingWidth,
                y: rect.minY,
                width: rect.width - leadingWidth,
                height: rect.height
            )
        )
    }
}

struct ConversationView: View {
    @EnvironmentObject private var commandModel: AssistantModel
    @EnvironmentObject private var conversation: ConversationModel
    @EnvironmentObject private var aiConfiguration: AIConfigurationModel
    @EnvironmentObject private var avatarLibrary: OpenClamAvatarLibrary
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    @State private var activeSessionImagePreviews: [UUID: UIImage] = [:]
    @State private var activeSessionImagePreviewOrder: [UUID] = []
    @State private var warmEarEnabled = OpenClamWarmEarControl.isEnabled
    @StateObject private var avatarInteractions = CaptainAyerOverlayInteractionRelay()
    @StateObject private var liveTalk = LiveTalkSessionController()
    @State private var liveTalkPTTNotice: String?
    @FocusState private var isComposerFocused: Bool

    let onShowSidebar: () -> Void
    let onSelectAvatar: (_ id: String, _ displayName: String) -> Void
    let onShowSettings: () -> Void
    let onShowAISettings: () -> Void

    var body: some View {
        ZStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(conversation.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }

                        if conversation.messages.count == 1,
                           !dynamicTypeSize.isAccessibilitySize {
                            suggestionRow
                        }

                        if conversation.isWorking {
                            workingRow
                        }

                        if conversation.screenshotData != nil || conversation.pronunciation != nil {
                            pronunciationCard
                        }

                        if !conversation.venueResults.isEmpty {
                            venueCard
                        }

                        if conversation.pendingNearbySearchQuery != nil {
                            pendingNearbySearchCard
                        }

                        if conversation.contactAgentSession.status != .idle {
                            ContactAgentCard(
                                session: conversation.contactAgentSession,
                                providerID: aiConfiguration.effectiveSettings.llm.provider,
                                providerModel: aiConfiguration.effectiveSettings.model,
                                onSharedReply: { conversation.recordFeatureReply($0) }
                            )
                        }

                        EventKitAgentCard(session: conversation.eventKitAgentSession)

                        if !conversation.nearbyPlaceResults.isEmpty {
                            nearbyPlacesCard
                        }

                        if !conversation.replySuggestions.isEmpty {
                            replySuggestionsCard
                        }

                        if conversation.researchRequest != nil {
                            researchCard
                        }

                        if conversation.pendingSMS != nil {
                            messageDraftCard
                        }

                        if conversation.pendingEmail != nil {
                            emailDraftCard
                                .id(ConversationReviewRevealPolicy.pendingEmailAnchorID)
                        }

                        if let proposal = conversation.pendingAppHandoffProposal {
                            appHandoffCard(proposal)
                        }

                        if conversation.proposedCommand != nil {
                            proposedCommandCard
                        }

                        if conversation.rideDestination != nil {
                            rideCard
                        }

                    if let confirmedActionNotice {
                        confirmedActionReceipt(confirmedActionNotice)
                    }

                    if let prompt = conversation.pendingShortcutPrompt {
                        pendingSiriPromptCard(prompt)
                    }

                    if let submission = conversation.pendingScreenContextSubmission {
                        pendingScreenContextComposerCard(submission)
                    }

                    if let error = composerSupportError {
                        composerErrorCard(error)
                    }

                    if !stagedAttachments.isEmpty || isLoadingAttachments {
                        attachmentTray
                    }

                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, isFreshConversation ? 36 : 12)
                .padding(.bottom, 8)
                .disabled(conversation.isWorking || commandModel.isExecuting || activeRequestTask != nil)
                .background(alignment: .topLeading) {
                    ConversationThreadInteractionObserver(
                        onInteraction: avatarInteractions.noteThreadInteraction
                    )
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                }
            }
            .defaultScrollAnchor(isFreshConversation ? .top : .bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(assistantBackground)
            .onChange(of: conversation.pendingEmail?.id) { previousID, currentID in
                guard ConversationReviewRevealPolicy.shouldRevealPendingEmail(
                    previousID: previousID,
                    currentID: currentID
                ) else { return }
                revealPendingEmailReview(using: proxy)
            }
            .onChange(of: assistantReplyDeliverySnapshot) { _, snapshot in
                if !isFreshConversation {
                    scrollToLatest(using: proxy)
                }
                deliverNewAssistantReply(from: snapshot)
            }
            .onChange(of: conversation.isWorking) { _, _ in
                scrollToLatest(using: proxy)
            }
            .onChange(of: confirmedActionNotice) { _, notice in
                if notice != nil {
                    scrollToLatest(using: proxy)
                }
            }
            .onChange(of: isComposerFocused) { _, focused in
                if focused {
                    expandsComposerForEditing = true
                    scrollToLatest(using: proxy)
                } else {
                    expandsComposerForEditing = false
                }
            }
            .onChange(of: stagedAttachments.count) { _, _ in
                scrollToLatest(using: proxy)
            }
            .onChange(of: conversation.pendingScreenContextSubmission?.reviewID) { _, submissionID in
                guard submissionID != nil else { return }
                if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let submission = conversation.pendingScreenContextSubmission {
                    input = submission.instruction
                }
                scrollToLatest(using: proxy)
            }
            .onAppear {
                assistantReplyDeliveryBoundary.prime(with: assistantReplyDeliverySnapshot)
                if !isFreshConversation {
                    scrollToLatest(using: proxy, animated: false)
                }
            }
            }

            avatarOverlay
                .zIndex(2)
                .ignoresSafeArea()
                // The avatar stage supports pinch and vertical-opacity gestures, but its
                // transparent full-screen bounds must not swallow the assistant actions on
                // the leading side of the conversation. Keep the visible avatar/right rail
                // interactive while allowing ordinary chat controls to receive real taps.
                .contentShape(.interaction, AvatarOverlayInteractionShape())
        }
        .navigationTitle(conversation.currentThreadTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { composer }
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

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dismissKeyboard()
                    warmEarEnabled.toggle()
                    OpenClamWarmEarControl.setEnabled(warmEarEnabled)
                } label: {
                    Image(systemName: warmEarEnabled ? "ear.fill" : "ear")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .foregroundStyle(warmEarEnabled ? Color.primary : Color.secondary)
                .accessibilityLabel("Keyboard ears")
                .accessibilityValue(warmEarEnabled ? "On" : "Off")
                .accessibilityHint(OpenClamWarmEarControl.availabilityExplanation)
                .accessibilityIdentifier("openclam-warm-ear-button")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dismissKeyboard()
                    if let reason = ConversationLiveTalkNavigationPolicy
                        .sidebarBlockReason(liveTalkPhase: liveTalk.phase) {
                        liveTalkPTTNotice = reason
                        return
                    }
                    onShowSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .accessibilityHint("Opens AI services and iPhone tool settings")
            }
        }
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
        .onChange(of: speech.transcript) { _, transcript in
            input = transcript
        }
        .onChange(of: input) { _, _ in
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
        .onChange(of: conversation.pendingShortcutPrompt) { _, prompt in
            receivePendingShortcutPrompt(prompt)
        }
        .onChange(of: conversation.historyController.selectedThreadID) { previousID, selectedID in
            guard previousID != nil, previousID != selectedID else { return }
            resetComposerForChatChange()
        }
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
                Task { await liveTalk.stop() }
            }
        }
        .onDisappear {
            speech.cancel()
            conversation.stopSpeechOutput()
            cancelActiveRequest()
            Task { await liveTalk.stop() }
        }
        .onAppear {
            warmEarEnabled = OpenClamWarmEarControl.isEnabled
            OpenClamWarmEarControl.renewForegroundLease()
            receivePendingShortcutPrompt(conversation.pendingShortcutPrompt)
            if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let submission = conversation.pendingScreenContextSubmission {
                input = submission.instruction
            }
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
    }

    private var assistantBackground: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
    }

    private var isFreshConversation: Bool {
        conversation.messages.count == 1
    }

    private func messageBubble(_ message: ConversationMessage) -> some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 52) }
            VStack(alignment: .leading, spacing: 2) {
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
            if message.role == .assistant { Spacer(minLength: 18) }
        }
        .accessibilityElement(children: .contain)
        .frame(maxWidth: .infinity)
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
                localImagePreviews: activeSessionImagePreviews,
                onAskAISelection: message.role == .assistant
                    ? { selectedText in stageSelectedTextForAI(selectedText) }
                    : nil
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

    private var workingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Working with available services…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
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
                await conversation.submit(prompt, aiConfiguration: aiConfiguration)
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
            cardHeader("Local OCR & pronunciation", icon: "text.viewfinder", color: .purple)

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
                .tint(.indigo)
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
                        conversation.speakPronunciation()
                    } label: {
                        Label("Hear it", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
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
                .tint(.purple)
                .disabled(conversation.pronunciationInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Language detection and Latin-letter guidance are approximate; the system voice is not a linguistic guarantee.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .assistantCard(stroke: .purple.opacity(0.18))
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
                            .foregroundStyle(conversation.selectedVenue?.id == venue.id ? Color.indigo : Color.gray.opacity(0.55))
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
                            .foregroundStyle(conversation.selectedNearbyPlace?.id == place.id ? Color.indigo : Color.gray.opacity(0.55))
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
            cardHeader("Reply suggestions", icon: "text.bubble.fill", color: .indigo)
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
                .background(.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }

            Button("Dismiss suggestions", role: .cancel) {
                conversation.dismissReplySuggestions()
            }
            .buttonStyle(.bordered)
        }
        .assistantCard(stroke: .indigo.opacity(0.2))
    }

    private var researchCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            cardHeader("Current reviews & menu", icon: "sparkle.magnifyingglass", color: .blue)
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
        .assistantCard(stroke: .blue.opacity(0.2))
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
                    .tint(.blue)

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
                        .tint(.blue)
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
                        .tint(.blue)
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
            cardHeader("Unsent email draft", icon: "envelope.badge", color: .blue)

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
                    .tint(.blue)

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
                        .tint(.blue)
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
                        .tint(.blue)
                        .disabled(conversation.emailCommand() == nil)
                        .accessibilityLabel("Confirmed. Open unsent email draft")
                    }
                }

                Text("Confirmed opens Apple’s editable Mail composer immediately. You manually send, save, or cancel there; delivery is never assumed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .assistantCard(stroke: .blue.opacity(0.22))
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
            cardHeader("Open app alias", icon: "arrow.up.forward.app.fill", color: .indigo)
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
        .assistantCard(stroke: .indigo.opacity(0.25))
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
        .tint(.indigo)
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
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: shouldUseExpandedComposer ? 10_000 : nil)
            expandedComposer
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 16, y: 5)
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
            modelSelectionMenu(expandsToWidth: false, compact: true)
                .layoutPriority(1)
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
        .accessibilityHint("Opens camera, photo library, and file choices")
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
        )
    }

    private var textToSpeechButton: some View {
        Button {
            let enabled = !conversation.isTTSEnabled
            conversation.setTTSEnabled(enabled)
            if enabled {
                conversation.speakLatestAssistantReply(using: aiConfiguration)
            }
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
        .disabled(isLoadingAttachments || isChatTransitioning)
    }

    private func modelSelectionMenu(
        expandsToWidth: Bool,
        compact: Bool = false
    ) -> some View {
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
        .tint(.secondary)
        .disabled(isRequestActive)
        .accessibilityLabel("Language model")
        .accessibilityValue("\(configuredProviderName), \(configuredModelName)")
        .accessibilityHint("Choose a provider and model, or open AI Settings")
    }

    private var attachmentTray: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Ready to attach", systemImage: "paperclip.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
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
        .background(.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                .foregroundStyle(.indigo)
                .frame(width: 46, height: 46)
                .background(.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private var configuredProviderLabel: String {
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
            onPlayLatest: {
                if !conversation.isTTSEnabled {
                    conversation.setTTSEnabled(true)
                }
                conversation.speakLatestAssistantReply(using: aiConfiguration)
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
        AIProviderRegistry.descriptor(for: aiConfiguration.effectiveSettings.llm.provider).displayName
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
            return "Listening with \(speechProviderName) · tap Stop"
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
    }

    private func formattedByteCount(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func pendingSiriPromptCard(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Siri question ready", systemImage: "quote.bubble.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.indigo)
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
                .tint(.indigo)
            }
        }
        .padding(10)
        .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func pendingScreenContextComposerCard(
        _ submission: ScreenContextSubmission
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Reviewed context ready", systemImage: "rectangle.and.text.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.indigo)

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
        .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func useReviewedContextButton(
        _ submission: ScreenContextSubmission
    ) -> some View {
        Button(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Use instruction" : "Restore reviewed instruction") {
            input = submission.instruction
        }
        .buttonStyle(.borderedProminent)
        .tint(.indigo)
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

    private var composerIcon: String {
        if isRequestActive { return "stop.fill" }
        if speech.isListening { return "stop.fill" }
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "mic.fill" }
        return "arrow.up"
    }

    private var composerColor: Color {
        return speech.isListening ? .red : .primary
    }

    private var composerAccessibilityLabel: String {
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
        guard !isChatTransitioning else { return }
        if !liveTalk.phase.isSessionActive {
            conversation.stopSpeechOutput()
        }
        if isRequestActive {
            speech.cancel()
            cancelActiveRequest()
        } else if speech.isListening {
            finishSpeechAndSend()
        } else if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let reason = ConversationMicrophoneOwnership.tapToTalkBlockReason(
                liveTalkPhase: liveTalk.phase
            ) {
                liveTalkPTTNotice = reason
            } else {
                suppressesSpeechError = false
                liveTalkPTTNotice = nil
                Task { await speech.start(using: aiConfiguration) }
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
        readAloudMessageID = message.id
        conversation.readAssistantReplyAloud(text, using: aiConfiguration)
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

    private func sendInput() {
        guard !conversation.isWorking, !isChatTransitioning else { return }
        conversation.stopSpeechOutput()
        confirmedActionNotice = nil
        if speech.isListening {
            finishSpeechAndSend()
            return
        }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
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
            input = ""
            beginAgentTask {
                await conversation.submit(value, aiConfiguration: aiConfiguration)
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
            let value = await speech.stop(using: aiConfiguration)
            input = value
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            sendInput()
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

    private func deliverNewAssistantReply(
        from snapshot: AssistantReplyDeliverySnapshot
    ) {
        guard let messageID = assistantReplyDeliveryBoundary.observe(snapshot),
              let message = conversation.messages.first(where: { $0.id == messageID }) else {
            return
        }
        AccessibilityNotification.Announcement("Assistant: \(message.text)").post()
        if !liveTalk.phase.isSessionActive {
            conversation.speakAssistantReply(message.text, using: aiConfiguration)
        }
    }

    private func toggleLiveTalk() {
        dismissKeyboard()
        if liveTalk.phase.isSessionActive {
            Task {
                await liveTalk.stop()
                liveTalkPTTNotice = nil
            }
            return
        }

        speech.cancel()
        conversation.stopSpeechOutput()
        liveTalkPTTNotice = nil
        liveTalk.begin(
            avatar: aiConfiguration.activeAvatarProfile,
            sharedSettings: aiConfiguration.settings,
            avatarController: conversation.captainAyerAvatar,
            emailDraftToolHandler: { request in
                await conversation.stageLiveTalkEmailDraft(
                    request,
                    appIsActive: UIApplication.shared.applicationState == .active
                )
            }
        )
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
    let onInteraction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInteraction: onInteraction)
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        view.scheduleAttachment()
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        context.coordinator.onInteraction = onInteraction
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
        var onInteraction: () -> Void

        private weak var scrollView: UIScrollView?
        private var tapGesture: UITapGestureRecognizer?
        private var lastScrollSignal = -TimeInterval.infinity

        init(onInteraction: @escaping () -> Void) {
            self.onInteraction = onInteraction
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
            case .began, .ended, .cancelled:
                lastScrollSignal = now
                onInteraction()
            case .changed where now - lastScrollSignal >= 0.15:
                lastScrollSignal = now
                onInteraction()
            default:
                break
            }
        }

        @objc private func threadTapped(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            onInteraction()
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
