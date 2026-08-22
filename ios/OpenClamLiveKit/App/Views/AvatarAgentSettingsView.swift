import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum AvatarLiveTalkSettingsPresentation {
    static func credentialProvider(
        for preference: LiveTalkStagePreference,
        stage: LiveTalkStage,
        avatarSelection: AIServiceSelection
    ) -> AIProviderID? {
        let option: LiveTalkProviderOption?
        switch preference {
        case .managed:
            option = nil
        case .followAvatar:
            option = LiveTalkCatalog.option(
                following: avatarSelection,
                for: stage
            )
        case let .fixed(selection):
            option = LiveTalkCatalog.option(matching: selection, for: stage)
        }
        return option?.credentialProvider
    }

    static func compactListSummary(
        profile: AvatarAgentProfile,
        configuration: LiveTalkConfiguration
    ) -> String {
        if LiveTalkStage.allCases.allSatisfy({ configuration[$0].source == .managed }) {
            let voice = LiveTalkCatalog.option(
                matching: configuration.tts,
                for: .tts
            )?.shortTitle
                .split(separator: "·")
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Managed voice"
            return "LiveKit managed · \(voice)"
        }

        let preferences = profile.effectiveLiveTalkPreferences
        let followCount = LiveTalkStage.allCases.filter {
            preferences[$0] == .followAvatar
        }.count
        let hasPrevious = LiveTalkStage.allCases.contains { stage in
            if case .fixed = preferences[stage] { return true }
            return false
        }
        if followCount == LiveTalkStage.allCases.count {
            return "Follows avatar · all stages"
        }
        if followCount > 0, hasPrevious {
            return "Mixed · avatar + saved BYOK"
        }
        if hasPrevious {
            return "Mixed · saved BYOK"
        }
        if followCount > 0 {
            return "Mixed · follows avatar"
        }
        return "Mixed services"
    }
}

enum AvatarAgentServicePresentation {
    static func modelName(
        provider: AIProviderID,
        capability: AICapability,
        model: String
    ) -> String {
        guard provider == .apple else {
            return AIProviderRegistry.modelDisplayName(
                for: model,
                provider: provider,
                capability: capability
            )
        }
        switch (capability, model) {
        case (.textToSpeech, "system-voice"):
            return "System voice"
        case (.speechToText, "apple-dictation"):
            return "Apple Dictation"
        default:
            return model
        }
    }

    static func voiceName(for selection: AIServiceSelection) -> String {
        if selection.provider == .apple {
            return modelName(
                provider: selection.provider,
                capability: .textToSpeech,
                model: selection.model
            )
        }

        let voice = selection.voice
            ?? AIProviderRegistry.defaultVoice(for: selection.provider)
            ?? selection.model
        return AIProviderRegistry.voiceOptions(for: selection.provider)
            .first(where: { $0.id.caseInsensitiveCompare(voice) == .orderedSame })?
            .displayName
            ?? voice
    }
}

struct AvatarAgentSettingsView: View {
    @EnvironmentObject private var avatarLibrary: OpenClamAvatarLibrary
    @ObservedObject var configuration: AIConfigurationModel
    let onActivate: (String, String) -> Void
    let onConnectorRouteChanged: (String) -> Void

    @State private var showsAvatarImporter = false
    @State private var isImportingAvatar = false
    @State private var pendingDeletion: OpenClamAvatarDescriptor?
    @State private var libraryNotice: AvatarLibraryNotice?

    init(
        configuration: AIConfigurationModel,
        onActivate: @escaping (String, String) -> Void = { _, _ in },
        onConnectorRouteChanged: @escaping (String) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.onActivate = onActivate
        self.onConnectorRouteChanged = onConnectorRouteChanged
    }

    var body: some View {
        List {
            if OpenClamAvatarStoreReleasePolicy.isAvailable {
                Section {
                    NavigationLink {
                        OpenClamAvatarStoreView(
                            configuration: configuration,
                            onActivate: onActivate
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.square.filled.and.at.rectangle")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 32, height: 32)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Avatar Store")
                                    .font(.body.weight(.semibold))
                                Text("Preview and download verified avatars")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .accessibilityIdentifier("openclam-avatar-store-link")
                }
            }

            Section {
                Button {
                    showsAvatarImporter = true
                } label: {
                    Label("Import Avatar from Files", systemImage: "square.and.arrow.down")
                }
                .disabled(isImportingAvatar || avatarLibrary.isMutating)
                .accessibilityIdentifier("openclam-import-avatar")

                if isImportingAvatar {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking and installing avatar…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("openclam-avatar-import-progress")
                }

                if avatarLibrary.importedAvatars.isEmpty, !isImportingAvatar {
                    Text("Your imported avatars will appear here and in the avatar carousel.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if avatarLibrary.skippedInvalidInstallCount > 0 {
                    Label(
                        "One or more damaged imported avatars were left off the list.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }

                if let deletingID = avatarLibrary.deletingAvatarID,
                   let deletingAvatar = avatarLibrary.avatar(id: deletingID) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Deleting \(deletingAvatar.displayName)…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "Deleting \(deletingAvatar.displayName)"
                    )
                    .accessibilityIdentifier(
                        "openclam-avatar-delete-progress"
                    )
                }
            } header: {
                Text("Avatar library")
            } footer: {
                Text("Import an .avtr file exported as version 2 · ios-light. OpenClam accepts only the lightweight render images—never raw photos, prompts, histories, or API keys.")
            }

            Section {
                ForEach(avatarLibrary.avatars) { avatar in
                    NavigationLink {
                        AvatarAgentEditorView(
                            configuration: configuration,
                            avatarID: avatar.id,
                            onActivate: onActivate,
                            onConnectorRouteChanged: onConnectorRouteChanged
                        )
                    } label: {
                        agentCard(avatar)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if avatarLibrary.isImported(id: avatar.id),
                           !avatarLibrary.isProtected(id: avatar.id) {
                            Button("Delete", role: .destructive) {
                                requestDeletion(of: avatar)
                            }
                            .disabled(avatarLibrary.isMutating)
                            .accessibilityLabel(
                                "Delete \(avatar.displayName)"
                            )
                            .accessibilityIdentifier(
                                "openclam-delete-avatar-\(avatar.id)"
                            )
                        }
                    }
                    .accessibilityIdentifier("openclam-avatar-agent-\(avatar.id)")
                }
            } header: {
                Text("Avatar agents")
            } footer: {
                Text("Chat and tap-to-talk use the shared language model, read-aloud voice, and tap-to-talk microphone until you change an avatar here. Continuous Live Talk has separate choices inside each avatar. API keys stay protected in this iPhone’s Keychain.")
            }
        }
        .navigationTitle("Avatar Agents")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showsAvatarImporter,
            allowedContentTypes: [.openClamAvatarPackage],
            allowsMultipleSelection: false,
            onCompletion: handleAvatarFileSelection
        )
        .confirmationDialog(
            pendingDeletion.map { "Delete \($0.displayName)?" }
                ?? "Delete imported avatar?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { avatar in
            Button("Delete \(avatar.displayName)", role: .destructive) {
                delete(avatar)
            }
            .disabled(avatarLibrary.isMutating)
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { avatar in
            Text("This permanently removes \(avatar.displayName) from this iPhone. You can import or download it again later.")
        }
        .alert(item: $libraryNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func agentCard(_ avatar: OpenClamAvatarDescriptor) -> some View {
        let profile = configuration.profile(for: avatar.id)
        let effectiveSettings = profile.effectiveSettings(inheriting: configuration.settings)
        let model = profile.agentConnectorBinding.map {
            "OpenClaw · \($0.displayName)"
        } ?? effectiveSettings.llm.model
        let voice = AvatarAgentServicePresentation.voiceName(
            for: effectiveSettings.textToSpeech
        )
        let speechRecognition = AvatarAgentServicePresentation.modelName(
            provider: effectiveSettings.speechToText.provider,
            capability: .speechToText,
            model: effectiveSettings.speechToText.model
        )
        let resolvedLiveTalk = try? LiveTalkConfigurationResolver.resolve(
            profile: profile,
            sharedSettings: configuration.settings
        )
        let liveTalkSummary = resolvedLiveTalk.map {
            AvatarLiveTalkSettingsPresentation.compactListSummary(
                profile: profile,
                configuration: $0
            )
        } ?? "Review settings"
        let fullLiveTalkSummary = resolvedLiveTalk?.summary ?? "Review settings"

        return HStack(spacing: 12) {
            Group {
                if let thumbnail = OpenClamAvatarAssetStore.shared.image(
                       for: avatar,
                       role: .thumbnail
                   ) {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.secondary.opacity(0.10)
                        Text(String(profile.displayName.prefix(1)).uppercased())
                            .font(.headline)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay {
                Circle().stroke(
                    avatar.id == configuration.activeAvatarID
                        ? Color.accentColor
                        : Color.secondary.opacity(0.18),
                    lineWidth: avatar.id == configuration.activeAvatarID ? 2 : 1
                )
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.body.weight(.semibold))
                    if avatar.id == configuration.activeAvatarID {
                        Text("ACTIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    if avatarLibrary.isImported(id: avatar.id) {
                        Text(
                            avatarLibrary.isProtected(id: avatar.id)
                                ? "DOWNLOADED"
                                : "IMPORTED"
                        )
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(model) · \(voice)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Speech: \(speechRecognition)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Live Talk: \(liveTalkSummary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier(
                        "openclam-avatar-live-talk-summary-\(avatar.id)"
                    )
                    .accessibilityLabel("Live Talk: \(fullLiveTalkSummary)")
                    .accessibilityValue(liveTalkSummary)
                if !profile.systemPrompt.isEmpty || !profile.userPrompt.isEmpty {
                    Label("Custom prompts", systemImage: "text.badge.checkmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func handleAvatarFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            isImportingAvatar = true
            Task { @MainActor in
                defer { isImportingAvatar = false }
                do {
                    let avatar = try await avatarLibrary.importAvatar(from: url)
                    configuration.activateAvatar(
                        id: avatar.id,
                        displayName: avatar.displayName
                    )
                    onActivate(avatar.id, avatar.displayName)
                    libraryNotice = .init(
                        title: "Avatar imported",
                        message: "\(avatar.displayName) is installed and selected. It is also available in the avatar carousel."
                    )
                } catch {
                    libraryNotice = .init(
                        title: "Couldn’t import avatar",
                        message: error.localizedDescription
                    )
                }
            }
        case let .failure(error):
            if (error as NSError).code != NSUserCancelledError {
                libraryNotice = .init(
                    title: "Couldn’t open avatar",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func requestDeletion(of avatar: OpenClamAvatarDescriptor) {
        guard avatarLibrary.isImported(id: avatar.id),
              !avatarLibrary.isProtected(id: avatar.id),
              !avatarLibrary.isMutating else {
            return
        }
        pendingDeletion = avatar
    }

    private func delete(_ avatar: OpenClamAvatarDescriptor) {
        pendingDeletion = nil
        Task { @MainActor in
            do {
                let result = try await OpenClamAvatarDeletionCoordinator.perform(
                    decision: .confirm,
                    avatar: avatar,
                    library: avatarLibrary,
                    configuration: configuration
                )
                if let fallback = result?.fallbackIdentity {
                    onActivate(fallback.id, fallback.displayName)
                }
                libraryNotice = .init(
                    title: "Avatar deleted",
                    message: "\(avatar.displayName) was removed from this iPhone."
                )
            } catch {
                libraryNotice = .init(
                    title: "Couldn’t delete avatar",
                    message: error.localizedDescription
                )
            }
        }
    }
}

private struct AvatarLibraryNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum AvatarAgentEditorSaveError: LocalizedError, Equatable {
    case avatarUnavailable

    var errorDescription: String? {
        switch self {
        case .avatarUnavailable:
            "This avatar is no longer installed. Its old settings were not saved."
        }
    }
}

/// Keeps Save terminal after a successful write so two rapid taps cannot
/// persist the same stale editor twice while NavigationStack removes it.
struct AvatarAgentEditorSaveGate: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case saving
        case saved
    }

    private(set) var phase: Phase = .idle

    var canSubmit: Bool { phase == .idle }

    mutating func begin() -> Bool {
        guard canSubmit else { return false }
        phase = .saving
        return true
    }

    mutating func fail() {
        guard phase == .saving else { return }
        phase = .idle
    }

    mutating func succeed() {
        guard phase == .saving else { return }
        phase = .saved
    }
}

@MainActor
enum AvatarAgentEditorSaveOperation {
    static func persist(
        draft: AvatarAgentProfile,
        configuration: AIConfigurationModel,
        avatarIsAvailable: Bool
    ) throws -> AvatarAgentProfile {
        guard avatarIsAvailable else {
            throw AvatarAgentEditorSaveError.avatarUnavailable
        }
        _ = try LiveTalkConfigurationResolver.resolve(
            profile: draft,
            sharedSettings: configuration.settings
        )
        return try configuration.updateAvatarProfile(draft)
    }
}

struct AvatarAgentEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var avatarLibrary: OpenClamAvatarLibrary
    @EnvironmentObject private var agentConnections: AgentConnectionModel
    @ObservedObject var configuration: AIConfigurationModel
    let avatarID: String
    let onActivate: (String, String) -> Void
    let onConnectorRouteChanged: (String) -> Void

    @State private var draft: AvatarAgentProfile
    @State private var notice: String?
    @State private var showsResetConfirmation = false
    @State private var showsDeleteConfirmation = false
    @State private var isDeletingAvatar = false
    @State private var deletionNotice: AvatarLibraryNotice?
    @State private var saveGate = AvatarAgentEditorSaveGate()
    @State private var showsOpenClawPairing = false
    private let originalConnectorBinding: AvatarAgentConnectorBinding?

    init(
        configuration: AIConfigurationModel,
        avatarID: String,
        onActivate: @escaping (String, String) -> Void,
        onConnectorRouteChanged: @escaping (String) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.avatarID = avatarID
        self.onActivate = onActivate
        self.onConnectorRouteChanged = onConnectorRouteChanged
        let profile = configuration.profile(for: avatarID)
        originalConnectorBinding = profile.agentConnectorBinding
        _draft = State(initialValue: profile)
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Agent name", text: $draft.displayName)
                    .textInputAutocapitalization(.words)

                if configuration.activeAvatarID == avatarID {
                    Label("Active avatar", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Make this the active agent") {
                        onActivate(avatarID, draft.displayName)
                    }
                }

                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "openclam-avatar-editor-notice"
                        )
                }
            }

            agentConnectorSection

            Section {
                Toggle("Use a different language model", isOn: customModelBinding)
                    .accessibilityIdentifier("openclam-avatar-custom-llm-toggle")
                if draft.languageModelOverride != nil {
                    modelEditor
                } else {
                    inheritedRow(
                        title: "Current model",
                        value: "\(providerName(configuration.settings.llm.provider)) · \(configuration.settings.llm.model)"
                    )
                }
            } header: {
                Text("Language model")
            } footer: {
                Text(draft.agentConnectorBinding == nil
                     ? "This model writes typed-chat replies and replies after tap-to-talk transcription. Leaving the override off follows Chat & Tap-to-Talk AI Settings."
                     : "OpenClaw writes replies for new connected chats. This saved On iPhone model remains available when you switch this avatar back.")
            }
            .disabled(draft.agentConnectorBinding != nil)

            Section {
                Toggle("Use a different speaking voice", isOn: customVoiceBinding)
                    .accessibilityIdentifier("openclam-avatar-custom-voice-toggle")
                if draft.voiceOverride != nil {
                    voiceEditor
                } else {
                    let selection = configuration.settings.textToSpeech
                    inheritedRow(
                        title: "Current voice",
                        value: voiceSummary(selection)
                    )
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("This voice reads chat replies aloud, including replies started with tap-to-talk. For Chinese replies, choose a multilingual voice; an English-only voice can sound wrong even when speech recognition succeeds. It does not change Continuous Live Talk unless Speaking voice below is set to Follow this avatar.")
            }

            Section {
                Toggle("Use a different speech recognition service", isOn: customSpeechRecognitionBinding)
                    .accessibilityIdentifier("openclam-avatar-custom-stt-toggle")
                if draft.speechRecognitionOverride != nil {
                    speechRecognitionEditor
                } else {
                    inheritedRow(
                        title: "Current speech recognition",
                        value: serviceSummary(configuration.settings.speechToText)
                    )
                }
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("This recognizes only the tap-to-talk microphone. Apple stays on this iPhone; a cloud provider needs its saved key. Continuous Live Talk uses this service only when you choose Follow this avatar below.")
            }

            Section {
                ForEach(LiveTalkStage.allCases, id: \.self) { stage in
                    VStack(alignment: .leading, spacing: 6) {
                        Picker(stage.title, selection: liveTalkModeBinding(for: stage)) {
                            Text("LiveKit managed").tag(LiveTalkEditorMode.managed)
                            Text("Follow this avatar")
                                .tag(LiveTalkEditorMode.followAvatar)
                                .disabled(!canFollowAvatar(for: stage))
                            if isLegacyFixedSelection(stage) {
                                Text("Previous Live Talk choice")
                                    .tag(LiveTalkEditorMode.previousChoice)
                            }
                        }
                        .accessibilityIdentifier("openclam-live-talk-mode-\(stage.rawValue)")

                        if stage == .tts,
                           liveTalkModeBinding(for: stage).wrappedValue == .managed {
                            Picker(
                                "Managed Fish voice",
                                selection: managedTTSVoiceBinding
                            ) {
                                ForEach(LiveTalkCatalog.managedOptions(for: .tts)) { option in
                                    Text(option.title).tag(option.selection.voice ?? "")
                                }
                            }
                            .accessibilityIdentifier("openclam-managed-fish-voice")
                            .accessibilityValue(managedTTSVoiceAccessibilityValue)
                        }

                        if let detail = liveTalkDetail(for: stage) {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if followsAvatar(stage), !canFollowAvatar(for: stage) {
                            Text(liveTalkUnavailableMessage(for: stage))
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        liveTalkCredentialDisclosure(for: stage)
                    }
                    .padding(.vertical, 2)
                }
                if let warning = liveTalkLanguageCompatibilityWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier(
                            "openclam-live-talk-language-compatibility-warning"
                        )
                }
            } header: {
                Text("Continuous Live Talk")
                    .accessibilityIdentifier("openclam-avatar-live-talk-section")
            } footer: {
                Text("Tap the phone button to start a continuous LiveKit call. LiveKit managed uses the included services; choose a Fish voice here. Follow this avatar uses that avatar’s model, tap-to-talk microphone service, or read-aloud voice. If you choose a service marked YOUR API KEY, only its matching saved key is shared securely for that call. Unsupported choices are blocked instead of silently replaced.")
            }

            Section {
                promptEditor(
                    title: "System prompt",
                    placeholder: "Define this agent’s personality, expertise, tone, and response style.",
                    text: $draft.systemPrompt,
                    limit: AvatarAgentProfile.maximumSystemPromptCharacters
                )
            } footer: {
                Text(draft.agentConnectorBinding == nil
                     ? "Persona text can shape the answer but cannot weaken OpenClam’s privacy, confirmation, or tool-safety boundaries."
                     : "The selected OpenClaw agent owns its persona. This saved On iPhone prompt is not sent to OpenClaw.")
            }
            .disabled(draft.agentConnectorBinding != nil)

            Section {
                promptEditor(
                    title: "User prompt",
                    placeholder: "Add a standing preference supplied with each request, such as language, format, or audience.",
                    text: $draft.userPrompt,
                    limit: AvatarAgentProfile.maximumUserPromptCharacters
                )
            } footer: {
                Text(draft.agentConnectorBinding == nil
                     ? "This is stored as user-authored context. Only the message you send in the chat can authorize an iPhone action."
                     : "The selected OpenClaw agent owns its standing instructions. This saved On iPhone prompt is not sent to OpenClaw.")
            }
            .disabled(draft.agentConnectorBinding != nil)

            Section {
                Button("Reset this agent", role: .destructive) {
                    showsResetConfirmation = true
                }
                .disabled(!saveGate.canSubmit || isDeletingAvatar)
            }

            if avatarLibrary.isImported(id: avatarID) {
                Section {
                    Button(
                        "Delete \(deletionDisplayName)",
                        role: .destructive
                    ) {
                        showsDeleteConfirmation = true
                    }
                    .disabled(
                        !saveGate.canSubmit
                            || isDeletingAvatar
                            || avatarLibrary.isMutating
                    )
                    .accessibilityLabel(
                        "Delete avatar \(deletionDisplayName)"
                    )
                    .accessibilityHint(
                        "Shows a confirmation before removing this avatar from the iPhone."
                    )
                    .accessibilityIdentifier(
                        "openclam-avatar-editor-delete"
                    )

                    if isDeletingAvatar
                        || avatarLibrary.deletingAvatarID == avatarID {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Deleting avatar…")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "Deleting avatar \(deletionDisplayName)"
                        )
                        .accessibilityIdentifier(
                            "openclam-avatar-editor-delete-progress"
                        )
                    }
                } header: {
                    Text("Installed avatar")
                } footer: {
                    Text("This removes the imported avatar from this iPhone. Built-in avatars are protected and never show this option.")
                }
            }

        }
        .navigationTitle(draft.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(
                        !saveGate.canSubmit
                            || isDeletingAvatar
                            || avatarLibrary.isMutating
                            || !isAvatarAvailable
                    )
                    .accessibilityHint(
                        "Saves changes and returns to Avatar Agents."
                    )
                    .accessibilityIdentifier(
                        "openclam-avatar-save-and-close"
                    )
            }
        }
        .onChange(of: avatarLibrary.avatars.map(\.id)) { _, availableIDs in
            if !availableIDs.contains(avatarID), !isDeletingAvatar {
                dismiss()
            }
        }
        .confirmationDialog(
            "Reset model, voice, speech recognition, Live Talk, and prompts?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Agent", role: .destructive) {
                let changedRoute = configuration.profile(for: avatarID)
                    .agentConnectorBinding != nil
                configuration.resetAvatarProfile(avatarID)
                draft = configuration.profile(for: avatarID)
                notice = "Reset to shared chat settings and LiveKit managed Live Talk."
                if changedRoute {
                    onConnectorRouteChanged(avatarID)
                }
            }
            .disabled(!saveGate.canSubmit || isDeletingAvatar)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \(deletionDisplayName)?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(deletionDisplayName)", role: .destructive) {
                deleteImportedAvatar()
            }
            .disabled(isDeletingAvatar || avatarLibrary.isMutating)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(deletionDisplayName) from this iPhone. You can import or download it again later.")
        }
        .alert(item: $deletionNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $showsOpenClawPairing) {
            OpenClawPairingView { binding in
                draft.agentConnectorBinding = binding
            }
            .environmentObject(agentConnections)
        }
    }

    private var deletionDisplayName: String {
        avatarLibrary.avatar(id: avatarID)?.displayName
            ?? draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var agentConnectorSection: some View {
        Section {
            if let selected = draft.agentConnectorBinding {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("OpenClaw")
                        Text(selected.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "link.circle.fill")
                        .foregroundStyle(.green)
                }

                if !agentConnections.availableBindings.isEmpty {
                    Picker("OpenClaw agent", selection: Binding(
                        get: { selected },
                        set: { draft.agentConnectorBinding = $0 }
                    )) {
                        ForEach(agentConnections.availableBindings, id: \.self) { binding in
                            Text(binding.displayName).tag(binding)
                        }
                    }
                    .accessibilityIdentifier("openclam-avatar-openclaw-agent-picker")
                }

                Button("Use On iPhone for new chats") {
                    draft.agentConnectorBinding = nil
                }
            } else {
                Label("On iPhone", systemImage: "iphone")
                Button("Use an OpenClaw agent") {
                    if let first = agentConnections.availableBindings.first {
                        draft.agentConnectorBinding = first
                    } else {
                        showsOpenClawPairing = true
                    }
                }
                .disabled(!agentConnections.isConfigured)
                .accessibilityIdentifier("openclam-avatar-use-openclaw")
            }

            Button("Pair another OpenClaw gateway") {
                showsOpenClawPairing = true
            }
            .disabled(!agentConnections.isConfigured)
        } header: {
            Text("Chat agent")
        } footer: {
            Text("On iPhone uses this app’s saved language model and reviewed iPhone tools. OpenClaw sends your typed or dictated text to the selected remote agent—never screenshots, local tools, provider keys, or an automatic fallback. Its replies can show live progress and include verified generated files. Changing this choice starts a new chat; old chats keep their original route.")
        }
    }

    private var isAvatarAvailable: Bool {
        avatarLibrary.avatar(id: avatarID) != nil
    }

    private func deleteImportedAvatar() {
        guard saveGate.canSubmit,
              !isDeletingAvatar,
              !avatarLibrary.isMutating,
              avatarLibrary.isImported(id: avatarID),
              let avatar = avatarLibrary.avatar(id: avatarID) else {
            return
        }

        isDeletingAvatar = true
        Task { @MainActor in
            defer { isDeletingAvatar = false }
            do {
                let result = try await OpenClamAvatarDeletionCoordinator.perform(
                    decision: .confirm,
                    avatar: avatar,
                    library: avatarLibrary,
                    configuration: configuration
                )
                if let fallback = result?.fallbackIdentity {
                    // RootView stops speech output before switching the active
                    // conversation and stage to this deterministic fallback.
                    onActivate(fallback.id, fallback.displayName)
                }
                // Leave only after every disk, library, profile, and thread
                // update succeeds. This prevents the stale editor draft from
                // saving a deleted profile back into UserDefaults.
                dismiss()
            } catch {
                deletionNotice = .init(
                    title: "Couldn’t delete avatar",
                    message: error.localizedDescription
                )
            }
        }
    }

    private var customModelBinding: Binding<Bool> {
        Binding(
            get: { draft.languageModelOverride != nil },
            set: { enabled in
                draft.languageModelOverride = enabled ? configuration.settings.llm : nil
            }
        )
    }

    private var customVoiceBinding: Binding<Bool> {
        Binding(
            get: { draft.voiceOverride != nil },
            set: { enabled in
                draft.voiceOverride = enabled ? configuration.settings.textToSpeech : nil
            }
        )
    }

    private var customSpeechRecognitionBinding: Binding<Bool> {
        Binding(
            get: { draft.speechRecognitionOverride != nil },
            set: { enabled in
                draft.speechRecognitionOverride = enabled
                    ? configuration.settings.speechToText
                    : nil
            }
        )
    }

    private func liveTalkModeBinding(for stage: LiveTalkStage) -> Binding<LiveTalkEditorMode> {
        Binding(
            get: {
                switch draft.effectiveLiveTalkPreferences[stage] {
                case .managed: .managed
                case .followAvatar: .followAvatar
                case .fixed: .previousChoice
                }
            },
            set: { mode in
                guard mode != .previousChoice else { return }
                var preferences = draft.effectiveLiveTalkPreferences
                preferences[stage] = mode == .managed ? .managed : .followAvatar
                draft.liveTalkPreferences = preferences
                draft.liveTalkConfiguration = nil
            }
        )
    }

    private var managedTTSVoiceBinding: Binding<String> {
        Binding(
            get: {
                draft.effectiveLiveTalkPreferences.managedTTSVoice
                    ?? LiveTalkCatalog.managedTTS.selection.voice
                    ?? ""
            },
            set: { voice in
                var preferences = draft.effectiveLiveTalkPreferences
                preferences.managedTTSVoice = voice
                draft.liveTalkPreferences = preferences
                draft.liveTalkConfiguration = nil
            }
        )
    }

    private var managedTTSVoiceAccessibilityValue: String {
        LiveTalkCatalog.managedTTSOption(
            voice: managedTTSVoiceBinding.wrappedValue
        )?.title ?? managedTTSVoiceBinding.wrappedValue
    }

    private var modelEditor: some View {
        Group {
            Picker("Provider", selection: modelProviderBinding) {
                ForEach(runtimeProviders(for: .llm)) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            .accessibilityIdentifier("openclam-avatar-llm-provider")
            Picker("Model", selection: modelBinding) {
                ForEach(modelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .accessibilityIdentifier("openclam-avatar-llm-model")
        }
    }

    private var voiceEditor: some View {
        Group {
            Picker("Provider", selection: voiceProviderBinding) {
                ForEach(runtimeProviders(for: .textToSpeech)) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            .accessibilityIdentifier("openclam-avatar-voice-provider")
            Picker("Model", selection: voiceModelBinding) {
                ForEach(voiceModelOptions, id: \.self) { model in
                    Text(
                        AvatarAgentServicePresentation.modelName(
                            provider: voiceProviderBinding.wrappedValue,
                            capability: .textToSpeech,
                            model: model
                        )
                    )
                    .tag(model)
                }
            }
            .accessibilityIdentifier("openclam-avatar-voice-model")
            let voices = AIProviderRegistry.voiceOptions(
                for: draft.voiceOverride?.provider ?? configuration.settings.textToSpeech.provider
            )
            if voices.count > 1 {
                Picker("Voice", selection: voiceBinding) {
                    ForEach(voices) { voice in
                        Text(voice.displayName).tag(voice.id)
                    }
                }
                .accessibilityIdentifier("openclam-avatar-voice")
            }
        }
    }

    private var speechRecognitionEditor: some View {
        Group {
            Picker("Provider", selection: speechRecognitionProviderBinding) {
                ForEach(runtimeProviders(for: .speechToText)) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            .accessibilityIdentifier("openclam-avatar-stt-provider")
            Picker("Model", selection: speechRecognitionModelBinding) {
                ForEach(speechRecognitionModelOptions, id: \.self) { model in
                    Text(
                        AvatarAgentServicePresentation.modelName(
                            provider: speechRecognitionProviderBinding.wrappedValue,
                            capability: .speechToText,
                            model: model
                        )
                    )
                    .tag(model)
                }
            }
            .accessibilityIdentifier("openclam-avatar-stt-model")
            .accessibilityValue(speechRecognitionModelBinding.wrappedValue)
            Picker("Spoken language", selection: speechRecognitionLanguageBinding) {
                ForEach(
                    AIProviderRegistry.speechRecognitionLanguageOptions(
                        for: speechRecognitionProviderBinding.wrappedValue
                    )
                ) { option in
                    Text(option.displayName).tag(option.id)
                }
            }
            .accessibilityIdentifier("openclam-avatar-stt-language")
            if let note = AIProviderRegistry.configurationNote(
                provider: speechRecognitionProviderBinding.wrappedValue,
                capability: .speechToText
            ) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelProviderBinding: Binding<AIProviderID> {
        Binding(
            get: { draft.languageModelOverride?.provider ?? configuration.settings.llm.provider },
            set: { provider in
                draft.languageModelOverride = .init(
                    provider: provider,
                    model: configuration.preferredModel(for: .llm, provider: provider) ?? ""
                )
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { draft.languageModelOverride?.model ?? configuration.settings.llm.model },
            set: { draft.languageModelOverride?.model = $0 }
        )
    }

    private var voiceProviderBinding: Binding<AIProviderID> {
        Binding(
            get: { draft.voiceOverride?.provider ?? configuration.settings.textToSpeech.provider },
            set: { provider in
                draft.voiceOverride = .init(
                    provider: provider,
                    model: configuration.preferredModel(for: .textToSpeech, provider: provider) ?? "",
                    voice: AIProviderRegistry.defaultVoice(for: provider)
                )
            }
        )
    }

    private var voiceModelBinding: Binding<String> {
        Binding(
            get: { draft.voiceOverride?.model ?? configuration.settings.textToSpeech.model },
            set: { draft.voiceOverride?.model = $0 }
        )
    }

    private var voiceBinding: Binding<String> {
        Binding(
            get: {
                let provider = draft.voiceOverride?.provider ?? configuration.settings.textToSpeech.provider
                return draft.voiceOverride?.voice
                    ?? AIProviderRegistry.defaultVoice(for: provider)
                    ?? ""
            },
            set: { draft.voiceOverride?.voice = $0 }
        )
    }

    private var speechRecognitionProviderBinding: Binding<AIProviderID> {
        Binding(
            get: {
                draft.speechRecognitionOverride?.provider
                    ?? configuration.settings.speechToText.provider
            },
            set: { provider in
                draft.speechRecognitionOverride = .init(
                    provider: provider,
                    model: configuration.preferredModel(
                        for: .speechToText,
                        provider: provider
                    ) ?? "",
                    language: AIProviderRegistry.defaultSpeechRecognitionLanguage(
                        for: provider
                    )
                )
            }
        )
    }

    private var speechRecognitionModelBinding: Binding<String> {
        Binding(
            get: {
                draft.speechRecognitionOverride?.model
                    ?? configuration.settings.speechToText.model
            },
            set: { draft.speechRecognitionOverride?.model = $0 }
        )
    }

    private var speechRecognitionLanguageBinding: Binding<String> {
        Binding(
            get: {
                let selection = draft.speechRecognitionOverride
                    ?? configuration.settings.speechToText
                return selection.language
                    ?? AIProviderRegistry.defaultSpeechRecognitionLanguage(
                        for: selection.provider
                    )
            },
            set: { language in
                var selection = draft.speechRecognitionOverride
                    ?? configuration.settings.speechToText
                selection.language = language
                draft.speechRecognitionOverride = selection
            }
        )
    }

    private var modelOptions: [String] {
        let selection = draft.languageModelOverride ?? configuration.settings.llm
        return options(for: .llm, selection: selection)
    }

    private var voiceModelOptions: [String] {
        let selection = draft.voiceOverride ?? configuration.settings.textToSpeech
        return options(for: .textToSpeech, selection: selection)
    }

    private var speechRecognitionModelOptions: [String] {
        let selection = draft.speechRecognitionOverride
            ?? configuration.settings.speechToText
        return options(for: .speechToText, selection: selection)
    }

    private func followsAvatar(_ stage: LiveTalkStage) -> Bool {
        draft.effectiveLiveTalkPreferences[stage] == .followAvatar
    }

    private func isLegacyFixedSelection(_ stage: LiveTalkStage) -> Bool {
        if case .fixed = draft.effectiveLiveTalkPreferences[stage] {
            return true
        }
        return false
    }

    private func canFollowAvatar(for stage: LiveTalkStage) -> Bool {
        LiveTalkCatalog.option(
            following: avatarSelection(for: stage),
            for: stage
        ) != nil
    }

    private func avatarSelection(for stage: LiveTalkStage) -> AIServiceSelection {
        let settings = draft.effectiveSettings(inheriting: configuration.settings)
        switch stage {
        case .llm: return settings.llm
        case .stt: return settings.speechToText
        case .tts: return settings.textToSpeech
        }
    }

    private func liveTalkDetail(for stage: LiveTalkStage) -> String? {
        switch draft.effectiveLiveTalkPreferences[stage] {
        case .managed:
            if stage == .tts {
                return LiveTalkCatalog.managedTTSOption(
                    voice: draft.effectiveLiveTalkPreferences.managedTTSVoice
                )?.detail
            }
            return LiveTalkCatalog.managedOption(for: stage).detail
        case .followAvatar:
            return LiveTalkCatalog.option(
                following: avatarSelection(for: stage),
                for: stage
            )?.detail
        case let .fixed(selection):
            return LiveTalkCatalog.option(matching: selection, for: stage)?.detail
        }
    }

    private var liveTalkLanguageCompatibilityWarning: String? {
        guard let resolved = try? LiveTalkConfigurationResolver.resolve(
            profile: draft,
            sharedSettings: configuration.settings
        ),
        resolved.tts.provider == "deepgram",
        resolved.tts.model == "aura-2-andromeda-en",
        resolved.stt.language == LiveTalkLanguage.multilingual.rawValue
            || resolved.stt.language == LiveTalkLanguage.chinese.rawValue else {
            return nil
        }
        return "Deepgram Aura-2 Andromeda is English-only. Chinese may transcribe correctly, but this voice cannot reliably speak the Chinese reply; choose a multilingual speaking voice before starting Live Talk."
    }

    private func liveTalkUnavailableMessage(for stage: LiveTalkStage) -> String {
        let selection = avatarSelection(for: stage)
        return LiveTalkConfigurationError.avatarSelectionNotSupported(
            stage,
            selection.provider,
            selection.model,
            selection.voice
        ).localizedDescription
    }

    @ViewBuilder
    private func liveTalkCredentialDisclosure(for stage: LiveTalkStage) -> some View {
        if let provider = liveTalkCredentialProvider(for: stage) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("YOUR API KEY")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.10), in: Capsule())

                Text("Only the matching \(providerName(provider)) key is shared securely for this Live Talk \(stage.title.lowercased()) choice.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("openclam-live-talk-byok-\(stage.rawValue)")
        }
    }

    private func liveTalkCredentialProvider(
        for stage: LiveTalkStage
    ) -> AIProviderID? {
        AvatarLiveTalkSettingsPresentation.credentialProvider(
            for: draft.effectiveLiveTalkPreferences[stage],
            stage: stage,
            avatarSelection: avatarSelection(for: stage)
        )
    }

    private func options(
        for capability: AICapability,
        selection: AIServiceSelection
    ) -> [String] {
        var result = configuration.models(for: capability, provider: selection.provider)
        if !selection.model.isEmpty, !result.contains(selection.model) {
            result.insert(selection.model, at: 0)
        }
        return result
    }

    private func runtimeProviders(for capability: AICapability) -> [AIProviderDescriptor] {
        AIProviderRegistry.providers(for: capability).filter {
            AIProviderRegistry.hasRuntimeAdapter(provider: $0.id, capability: capability)
        }
    }

    private func inheritedRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func promptEditor(
        title: String,
        placeholder: String,
        text: Binding<String>,
        limit: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
            }
            Text("\(text.wrappedValue.count) / \(limit)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(text.wrappedValue.count > limit ? .red : .secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func providerName(_ provider: AIProviderID) -> String {
        AIProviderRegistry.descriptor(for: provider).displayName
    }

    private func serviceSummary(_ selection: AIServiceSelection) -> String {
        let model = AvatarAgentServicePresentation.modelName(
            provider: selection.provider,
            capability: .speechToText,
            model: selection.model
        )
        let language = AIProviderRegistry.speechRecognitionLanguageLabel(
            for: selection
        )
        return "\(providerName(selection.provider)) · \(model) · \(language)"
    }

    private func voiceSummary(_ selection: AIServiceSelection) -> String {
        let model = AvatarAgentServicePresentation.modelName(
            provider: selection.provider,
            capability: .textToSpeech,
            model: selection.model
        )
        let voice = AvatarAgentServicePresentation.voiceName(for: selection)
        if selection.provider == .apple || voice == model {
            return "\(providerName(selection.provider)) · \(voice)"
        }
        return "\(providerName(selection.provider)) · \(model) · \(voice)"
    }

    private func save() {
        guard !isDeletingAvatar,
              !avatarLibrary.isMutating,
              saveGate.begin() else { return }

        do {
            draft = try AvatarAgentEditorSaveOperation.persist(
                draft: draft,
                configuration: configuration,
                avatarIsAvailable: isAvatarAvailable
            )
            if draft.agentConnectorBinding != originalConnectorBinding {
                onConnectorRouteChanged(avatarID)
            }
            saveGate.succeed()
            dismiss()
        } catch {
            saveGate.fail()
            notice = error.localizedDescription
        }
    }
}

private enum LiveTalkEditorMode: Hashable {
    case managed
    case followAvatar
    case previousChoice
}
