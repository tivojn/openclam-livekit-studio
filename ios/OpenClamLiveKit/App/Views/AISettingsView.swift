import AVFoundation
import SwiftUI

@MainActor
struct AISettingsView: View {
    @ObservedObject private var configuration: AIConfigurationModel
    private let credentialStore: any AISettingsCredentialStoring

    @State private var draftSettings: AIProviderSettings
    @State private var credentialStatus: [AIProviderID: Bool] = [:]
    @State private var editingCredential: AIProviderID?
    @State private var capabilityNotices: [AICapability: SettingsNotice] = [:]
    @State private var isRefreshing: AICapability?
    @StateObject private var voicePreview = VoicePreviewController()

    init(
        configuration: AIConfigurationModel
    ) {
        self.configuration = configuration
        _draftSettings = State(initialValue: configuration.settings)
        credentialStore = configuration.settingsCredentialStore
    }

    var body: some View {
        Form {
            Section {
                Text("Language model → typed chat and tap-to-talk replies\nSpeech recognition → tap-to-talk microphone only\nText to speech → speaker and read-aloud replies")
                    .font(.subheadline)
                    .accessibilityIdentifier("openclam-chat-ptt-ai-map")

                NavigationLink(value: OpenClamRoute.avatarAgents) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Configure Continuous Live Talk")
                            .font(.body.weight(.semibold))
                        Text("Choose LiveKit managed services or follow one avatar’s exact settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("openclam-open-avatar-live-talk-settings")
            } header: {
                Text("Chat & tap-to-talk")
            } footer: {
                Text("These are the normal chat and tap-to-talk defaults. Continuous Live Talk is configured per avatar in Avatar Agents.")
            }

            Section {
                capabilityEditor(.llm)
            } header: {
                Text("Language model")
            } footer: {
                Text(llmFooter)
            }

            Section {
                capabilityEditor(.textToSpeech)
            } header: {
                Text("Text to speech")
            } footer: {
                Text("This reads chat replies aloud, including replies started through tap-to-talk. Apple is the default; cloud voices need a validated key. For Chinese replies, choose a multilingual voice—an English-only voice can sound wrong even when speech recognition succeeds. Continuous Live Talk has its own per-avatar voice choice.")
            }

            Section {
                capabilityEditor(.speechToText)
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("This recognizes only the tap-to-talk microphone. Choose the spoken language before recording, or use a provider whose Automatic option covers it. Deepgram Auto multilingual supports Chinese and English; xAI Automatic covers its documented 25-language list but not Chinese. Apple follows one selected iPhone locale. Cloud recognition needs a validated key. Continuous Live Talk is configured separately per avatar.")
            }

            Section {
                capabilityEditor(.imageGeneration)
            } header: {
                Text("Image generation")
            } footer: {
                Text("OpenAI GPT Image 2 is the default. These controls save the provider and model foundation only; this build does not yet expose an image-generation action.")
            }

            Section {
                capabilityEditor(.videoGeneration)
            } header: {
                Text("Video generation")
            } footer: {
                Text("xAI Grok Imagine Video is the default. These controls save the provider and model foundation only; this build does not yet submit or poll video-generation jobs.")
            }

            Section {
                webSearchPreferenceEditor
                webSearchReadiness
            } header: {
                Text("Web search")
            } footer: {
                Text("xAI X Search is the default. Other listed providers run only for an explicit live-search request and may charge for use.")
            }

            Section {
                ForEach(AIProviderRegistry.credentialProviders) { provider in
                    Button {
                        editingCredential = provider.id
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: credentialStatus[provider.id] == true
                                  ? "checkmark.shield.fill"
                                  : "key")
                                .foregroundStyle(credentialStatus[provider.id] == true ? .green : .secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                    .foregroundStyle(.primary)
                                Text(credentialStatus[provider.id] == true ? "Validated key saved" : "No validated key")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityHint("Manage a write-only API key for \(provider.displayName).")
                }
            } header: {
                Text("Credentials")
            } footer: {
                Text("Provider keys stay protected in this iPhone’s Keychain. LiveKit managed calls do not use them. If a Continuous Live Talk choice says Follow this avatar, only the key for that selected service is shared securely for that call.")
            }

            Section("Unavailable services") {
                unavailableRow(.bing)
                unavailableRow(.googleCustomSearch)
            }

            Section("Privacy and control") {
                disclosureRow(
                    symbol: "lock.shield.fill",
                    title: "Keys stay write-only",
                    detail: "Each provider has its own item in secure device Keychain storage. The app can replace, validate, use, or delete a key, but this screen cannot read it back."
                )
                disclosureRow(
                    symbol: "network.badge.shield.half.filled",
                    title: "Official endpoints only",
                    detail: "Requests are limited to pinned HTTPS provider hosts, use short timeouts and bounded responses, and do not follow redirects that might leak an authorization header."
                )
                disclosureRow(
                    symbol: "iphone",
                    title: "Foreground requests",
                    detail: "The agent does not become an always-listening background process. Protected iPhone data and external changes keep their visible confirmation boundaries."
                )
            }
        }
        .navigationTitle("Chat & Tap-to-Talk AI")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshCredentialStatuses() }
        .onChange(of: configuration.settings) { _, settings in
            guard settings != draftSettings else { return }
            draftSettings = settings
        }
        .onDisappear { voicePreview.stop() }
        .sheet(item: $editingCredential) { provider in
            NavigationStack {
                ProviderCredentialEditor(
                    provider: provider,
                    credentialStore: credentialStore,
                    hasSavedCredential: credentialStatus[provider] == true
                ) { validated in
                    credentialStatus[provider] = validated
                    if validated,
                       let capability = AIProviderRegistry.preferredModelCatalogCapability(
                        for: provider
                       ) {
                        Task { try? await configuration.refreshModels(for: provider, capability: capability) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func capabilityEditor(_ capability: AICapability) -> some View {
        let selection = draftSettings.selection(for: capability)
        let descriptor = AIProviderRegistry.descriptor(for: selection.provider)

        Picker("Provider", selection: providerBinding(for: capability)) {
            ForEach(selectableProviders(for: capability)) { provider in
                Text(provider.displayName).tag(provider.id)
            }
        }

        Picker("Model", selection: modelBinding(for: capability)) {
            ForEach(modelOptions(for: capability, provider: selection.provider), id: \.self) {
                Text(
                    AIProviderRegistry.modelDisplayName(
                        for: $0,
                        provider: selection.provider,
                        capability: capability
                    )
                )
                .tag($0)
            }
        }

        if capability == .speechToText {
            Picker("Spoken language", selection: speechLanguageBinding) {
                ForEach(
                    AIProviderRegistry.speechRecognitionLanguageOptions(
                        for: selection.provider
                    )
                ) { option in
                    Text(option.displayName).tag(option.id)
                }
            }
            .accessibilityIdentifier("openclam-stt-language")
        }

        if capability == .textToSpeech {
            let voices = voiceOptions(for: selection.provider)
            if voices.count > 1 {
                Picker("Voice", selection: voiceBinding(for: capability)) {
                    ForEach(voices) { voice in
                        Text(voice.displayName).tag(voice.id)
                    }
                }
            }

            Button {
                previewVoice(selection)
            } label: {
                if voicePreview.isPreparing {
                    Label("Cancel preview", systemImage: "stop.fill")
                } else {
                    Label(
                        voicePreview.isActive ? "Stop preview" : "Preview voice",
                        systemImage: voicePreview.isActive ? "stop.fill" : "play.fill"
                    )
                }
            }
            .accessibilityHint("Plays a short sample with the selected voice without changing settings.")
        }

        if AIProviderRegistry.supportsModelRefresh(
            provider: selection.provider,
            capability: capability
        ) {
            Button {
                Task { await refreshModels(for: selection.provider, capability: capability) }
            } label: {
                if isRefreshing == capability {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Refreshing models…")
                    }
                } else {
                    Label("Refresh available models", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isRefreshing != nil || credentialStatus[selection.provider] != true)
        }

        if let note = descriptor.availabilityNote {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let note = AIProviderRegistry.configurationNote(
            provider: selection.provider,
            capability: capability
        ) {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if capability == .llm,
           !AIProviderRegistry.supportsAttachmentInput(provider: selection.provider) {
            Text("This language-model adapter is currently text-only. Choose OpenAI or xAI for photo, video-frame, file, or explicitly shared screen-context requests.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        capabilityStatus(for: capability)
    }

    @ViewBuilder
    private var webSearchPreferenceEditor: some View {
        let selection = draftSettings.webSearch
        Picker("Preferred provider", selection: providerBinding(for: .webSearch)) {
            ForEach(selectableProviders(for: .webSearch)) { provider in
                Text(provider.displayName).tag(provider.id)
            }
        }
        Picker("Search API", selection: modelBinding(for: .webSearch)) {
            ForEach(modelOptions(for: .webSearch, provider: selection.provider), id: \.self) {
                Text($0).tag($0)
            }
        }
        capabilityStatus(for: .webSearch)
    }

    @ViewBuilder
    private var webSearchReadiness: some View {
        let provider = draftSettings.webSearch.provider
        if credentialStatus[provider] == true {
            Label("Ready for explicit live search requests", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("Add and validate a \(AIProviderRegistry.descriptor(for: provider).displayName) key to enable search", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        }
    }

    private var llmFooter: String {
        return "This model writes typed-chat replies and replies after tap-to-talk transcription. OpenAI GPT-5.6 Luna is the default; every model keeps the same visible confirmation rules for iPhone actions."
    }

    private func selectableProviders(for capability: AICapability) -> [AIProviderDescriptor] {
        let providers = AIProviderRegistry.providers(for: capability)
        if capability == .imageGeneration || capability == .videoGeneration {
            return providers
        }
        return providers.filter {
            AIProviderRegistry.hasRuntimeAdapter(provider: $0.id, capability: capability)
        }
    }

    private func providerBinding(for capability: AICapability) -> Binding<AIProviderID> {
        Binding(
            get: { draftSettings.selection(for: capability).provider },
            set: { provider in
                voicePreview.stop()
                let model = configuration.preferredModel(
                    for: capability,
                    provider: provider
                ) ?? "unavailable"
                let selection = AIServiceSelection(
                    provider: provider,
                    model: model,
                    voice: capability == .textToSpeech
                        ? AIProviderRegistry.defaultVoice(for: provider)
                        : nil,
                    language: capability == .speechToText
                        ? AIProviderRegistry.defaultSpeechRecognitionLanguage(
                            for: provider
                        )
                        : nil
                )
                draftSettings.setSelection(selection, for: capability)
                commitSelection(selection, for: capability)
            }
        )
    }

    private func modelBinding(for capability: AICapability) -> Binding<String> {
        Binding(
            get: { draftSettings.selection(for: capability).model },
            set: { model in
                voicePreview.stop()
                var selection = draftSettings.selection(for: capability)
                selection.model = model
                draftSettings.setSelection(selection, for: capability)
                commitSelection(selection, for: capability)
            }
        )
    }

    private func voiceBinding(for capability: AICapability) -> Binding<String> {
        Binding(
            get: {
                let selection = draftSettings.selection(for: capability)
                return selection.voice
                    ?? AIProviderRegistry.defaultVoice(for: selection.provider)
                    ?? "default"
            },
            set: { voice in
                voicePreview.stop()
                var selection = draftSettings.selection(for: capability)
                selection.voice = voice
                draftSettings.setSelection(selection, for: capability)
                commitSelection(selection, for: capability)
            }
        )
    }

    private var speechLanguageBinding: Binding<String> {
        Binding(
            get: {
                let selection = draftSettings.speechToText
                return selection.language
                    ?? AIProviderRegistry.defaultSpeechRecognitionLanguage(
                        for: selection.provider
                    )
            },
            set: { language in
                var selection = draftSettings.speechToText
                selection.language = language
                draftSettings.speechToText = selection
                commitSelection(selection, for: .speechToText)
            }
        )
    }

    private func modelOptions(for capability: AICapability, provider: AIProviderID) -> [String] {
        let available = configuration.models(for: capability, provider: provider)
        let current = draftSettings.selection(for: capability)
        let selected = current.provider == provider ? [current.model] : []
        return Array(Set(available + selected)).filter { !$0.isEmpty }.sorted()
    }

    private func voiceOptions(for provider: AIProviderID) -> [AIVoiceDescriptor] {
        var voices = AIProviderRegistry.voiceOptions(for: provider)
        let current = draftSettings.textToSpeech
        if current.provider == provider,
           let selected = current.voice,
           !selected.isEmpty,
           !voices.contains(where: { $0.id == selected }) {
            voices.append(.init(id: selected, displayName: selected))
        }
        return voices
    }

    private func commitSelection(_ selection: AIServiceSelection, for capability: AICapability) {
        do {
            let validated = try configuration.updateSelection(selection, for: capability)
            draftSettings = configuration.settings
            draftSettings.setSelection(validated, for: capability)
            capabilityNotices[capability] = .success("Saved")
        } catch {
            draftSettings.setSelection(
                configuration.settings.selection(for: capability),
                for: capability
            )
            capabilityNotices[capability] = .error(error.localizedDescription)
        }
    }

    private func previewVoice(_ selection: AIServiceSelection) {
        if voicePreview.isActive || voicePreview.isPreparing {
            voicePreview.stop()
            return
        }
        if selection.provider != .apple,
           credentialStatus[selection.provider] != true {
            capabilityNotices[.textToSpeech] = .error(
                "Add and validate a \(AIProviderRegistry.descriptor(for: selection.provider).displayName) key before previewing."
            )
            return
        }
        voicePreview.play(selection: selection, configuration: configuration) { message in
            capabilityNotices[.textToSpeech] = .error(message)
        }
    }

    @ViewBuilder
    private func capabilityStatus(for capability: AICapability) -> some View {
        if let notice = capabilityNotices[capability] {
            Label(notice.message, systemImage: notice.symbol)
                .font(.caption)
                .foregroundStyle(notice.color)
                .accessibilityElement(children: .combine)
        } else {
            Label("Changes save automatically", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        }
    }

    private func refreshModels(for provider: AIProviderID, capability: AICapability) async {
        guard isRefreshing == nil else { return }
        isRefreshing = capability
        defer { isRefreshing = nil }
        do {
            let models = try await configuration.refreshModels(
                for: provider,
                capability: capability
            )
            capabilityNotices[capability] = .success("Refreshed \(models.count) models")
        } catch {
            capabilityNotices[capability] = .error(error.localizedDescription)
        }
    }

    private func refreshCredentialStatuses() async {
        for provider in AIProviderRegistry.credentialProviders.map(\.id) {
            credentialStatus[provider] = (try? await credentialStore.containsCredential(for: provider)) ?? false
        }
    }

    private func unavailableRow(_ id: AIProviderID) -> some View {
        let provider = AIProviderRegistry.descriptor(for: id)
        return VStack(alignment: .leading, spacing: 4) {
            Text(provider.displayName).font(.headline)
            Text(provider.availabilityNote ?? "Unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("Official notice", destination: provider.documentationURL)
                .font(.caption)
        }
        .padding(.vertical, 3)
    }

    private func disclosureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(OpenClamTheme.active)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private final class VoicePreviewController: NSObject, ObservableObject,
    @preconcurrency AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let sampleText = "Hello, I’m OpenClam. This is a preview of my voice."

    @Published private(set) var isPreparing = false
    @Published private(set) var isActive = false

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var preparationTask: Task<Void, Never>?
    private var previewRequestID: UUID?
    private var isSystemSpeechActive = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func play(
        selection: AIServiceSelection,
        configuration: AIConfigurationModel,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        stop()
        if selection.provider == .apple {
            do {
                try activateAudioSession()
                let utterance = AVSpeechUtterance(string: Self.sampleText)
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                utterance.voice = selection.voice.flatMap(AVSpeechSynthesisVoice.init(identifier:))
                    ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
                isSystemSpeechActive = true
                isActive = true
                synthesizer.speak(utterance)
            } catch {
                finish()
                onFailure(error.localizedDescription)
            }
            return
        }

        isPreparing = true
        let requestID = UUID()
        previewRequestID = requestID
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await configuration.synthesizeVoicePreview(
                    selection: selection,
                    text: Self.sampleText
                )
                try Task.checkCancellation()
                guard self.previewRequestID == requestID else { return }
                try self.startCloudPlayback(audio.data)
                self.preparationTask = nil
            } catch is CancellationError {
                guard self.previewRequestID == requestID else { return }
                self.finish()
            } catch {
                guard self.previewRequestID == requestID else { return }
                self.finish()
                onFailure(error.localizedDescription)
            }
        }
    }

    func stop() {
        previewRequestID = nil
        preparationTask?.cancel()
        preparationTask = nil
        isSystemSpeechActive = false
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        player?.stop()
        finish()
    }

    private func startCloudPlayback(_ data: Data) throws {
        guard !data.isEmpty else { throw CloudVoiceServiceError.missingAudio }
        try activateAudioSession()
        let player = try AVAudioPlayer(data: data)
        self.player = player
        player.delegate = self
        guard player.prepareToPlay(), player.play() else {
            self.player = nil
            throw CloudVoiceServiceError.missingAudio
        }
        isPreparing = false
        isActive = true
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    private func finish() {
        previewRequestID = nil
        preparationTask = nil
        isSystemSpeechActive = false
        player = nil
        isPreparing = false
        isActive = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        guard isSystemSpeechActive else { return }
        finish()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        guard isSystemSpeechActive else { return }
        finish()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        finish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        finish()
    }
}

private struct ProviderCredentialEditor: View {
    let provider: AIProviderID
    let credentialStore: any AISettingsCredentialStoring
    let onChange: @MainActor (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hasSavedCredential: Bool
    @State private var credential = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmRemoval = false

    private var descriptor: AIProviderDescriptor {
        AIProviderRegistry.descriptor(for: provider)
    }

    init(
        provider: AIProviderID,
        credentialStore: any AISettingsCredentialStoring,
        hasSavedCredential: Bool,
        onChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.provider = provider
        self.credentialStore = credentialStore
        self.onChange = onChange
        _hasSavedCredential = State(initialValue: hasSavedCredential)
    }

    var body: some View {
        Form {
            Section {
                Label(
                    hasSavedCredential ? "A validated key is saved" : "No key is saved",
                    systemImage: hasSavedCredential ? "checkmark.shield.fill" : "key.slash"
                )
                .foregroundStyle(hasSavedCredential ? .green : .secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("\(descriptor.displayName) API key")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    SecureField("Paste a new key", text: $credential)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .accessibilityLabel("\(descriptor.displayName) API key")
                        .accessibilityHint("Paste a new key. A saved key is never shown again.")
                }
                .padding(.vertical, 2)

                Button {
                    Task { await validateAndSave() }
                } label: {
                    if isWorking {
                        HStack { ProgressView(); Text("Validating…") }
                    } else {
                        Label("Validate and save", systemImage: "checkmark.icloud")
                    }
                }
                .disabled(isWorking || credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasSavedCredential {
                    Button("Remove saved key", systemImage: "trash", role: .destructive) {
                        confirmRemoval = true
                    }
                    .disabled(isWorking)
                }
            } footer: {
                Text("Validation contacts only \(descriptor.displayName)’s official endpoint. The key is saved only after validation succeeds, cannot be read back, and is cleared from this screen.")
            }

            if let note = descriptor.availabilityNote {
                Section { Text(note).foregroundStyle(.secondary) }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Link("Create or manage a key", destination: descriptor.keyManagementURL!)
                Link("Official API documentation", destination: descriptor.documentationURL)
            }
        }
        .navigationTitle(descriptor.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog("Remove the saved key?", isPresented: $confirmRemoval) {
            Button("Remove key", role: .destructive) {
                Task { await removeCredential() }
            }
            Button("Keep key", role: .cancel) {}
        }
    }

    private func validateAndSave() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await credentialStore.validateAndSaveCredential(credential, for: provider)
            credential = ""
            errorMessage = nil
            hasSavedCredential = true
            onChange(true)
        } catch {
            credential = ""
            errorMessage = error.localizedDescription
            onChange(hasSavedCredential)
        }
    }

    private func removeCredential() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await credentialStore.removeCredential(for: provider)
            credential = ""
            errorMessage = nil
            hasSavedCredential = false
            onChange(false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SettingsNotice {
    let message: String
    let symbol: String
    let color: Color

    static func success(_ message: String) -> Self {
        .init(message: message, symbol: "checkmark.circle.fill", color: .green)
    }

    static func error(_ message: String) -> Self {
        .init(message: message, symbol: "exclamationmark.triangle.fill", color: .red)
    }
}
