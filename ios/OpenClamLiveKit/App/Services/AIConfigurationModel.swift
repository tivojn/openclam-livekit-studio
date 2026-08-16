import Foundation

@MainActor
final class AIConfigurationModel: ObservableObject {
    @Published var settings: AIProviderSettings {
        didSet {
            selectedAgentCredentialStore.provider = settings.llm.provider
            persist(settings)
        }
    }

    @Published private(set) var cachedModels: [AIProviderID: [AICapability: [String]]] = [:]
    @Published private(set) var activeAvatarID: String {
        didSet { persistActiveAvatarID() }
    }
    @Published private(set) var avatarAgentProfiles: [String: AvatarAgentProfile] {
        didSet { persistAvatarAgentProfiles() }
    }
    @Published private(set) var avatarAgentThreads: AvatarAgentThreadMap {
        didSet { persistAvatarAgentThreads() }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let modelCacheKey: String
    private let avatarProfilesKey: String
    private let activeAvatarKey: String
    private let avatarThreadsKey: String
    private let providerVault: ProviderCredentialVault
    private let selectedAgentCredentialStore: SelectedProviderAgentCredentialStore

    let agentCredentialStore: AgentCredentialStore
    let settingsCredentialStore: AgentSettingsCredentialBridge

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "ai.provider.settings.v2",
        credentialStore: AgentCredentialStore = KeychainAgentCredentialStore(),
        providerVault injectedVault: ProviderCredentialVault? = nil,
        providerClient: ProviderAPIClient = ProviderAPIClient()
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        modelCacheKey = storageKey + ".models"
        let avatarProfilesStorageKey = storageKey + ".avatar-agents.v1"
        let activeAvatarStorageKey = storageKey + ".active-avatar.v1"
        let avatarThreadsStorageKey = storageKey + ".avatar-threads.v1"
        avatarProfilesKey = avatarProfilesStorageKey
        activeAvatarKey = activeAvatarStorageKey
        avatarThreadsKey = avatarThreadsStorageKey

        let restored: AIProviderSettings
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(AIProviderSettings.self, from: data),
           let validated = try? saved.validated() {
            restored = validated
        } else if storageKey == "ai.provider.settings.v2",
                  let legacyData = defaults.data(forKey: "ai.provider.settings.v1"),
                  let legacy = try? JSONDecoder().decode(AIProviderSettings.self, from: legacyData),
                  let validated = try? legacy.validated() {
            restored = validated
        } else {
            restored = AIProviderSettings()
        }

        let vault = injectedVault ?? KeychainProviderCredentialVault(
            legacyOpenAIStore: credentialStore
        )
        providerVault = vault
        let selectedStore = SelectedProviderAgentCredentialStore(
            provider: restored.llm.provider,
            vault: vault
        )
        selectedAgentCredentialStore = selectedStore
        agentCredentialStore = selectedStore
        settingsCredentialStore = AgentSettingsCredentialBridge(
            vault: vault,
            providerClient: providerClient
        )
        settings = restored

        var restoredProfiles: [String: AvatarAgentProfile] = [:]
        if let data = defaults.data(forKey: avatarProfilesStorageKey),
           let decoded = try? JSONDecoder().decode([String: AvatarAgentProfile].self, from: data) {
            restoredProfiles = decoded.compactMapValues { try? $0.validated() }
        }
        for identity in AvatarAgentIdentity.defaultPack where restoredProfiles[identity.id] == nil {
            restoredProfiles[identity.id] = AvatarAgentProfile(
                id: identity.id,
                displayName: identity.displayName
            )
        }
        avatarAgentProfiles = restoredProfiles
        let savedActiveAvatar = defaults.string(forKey: activeAvatarStorageKey)
        if let savedActiveAvatar, restoredProfiles[savedActiveAvatar] != nil {
            activeAvatarID = savedActiveAvatar
        } else {
            activeAvatarID = AvatarAgentIdentity.defaultID
        }
        if let data = defaults.data(forKey: avatarThreadsStorageKey),
           let decoded = try? JSONDecoder().decode(AvatarAgentThreadMap.self, from: data) {
            avatarAgentThreads = decoded
        } else {
            avatarAgentThreads = AvatarAgentThreadMap()
        }

        if let cacheData = defaults.data(forKey: modelCacheKey) {
            if let decoded = try? JSONDecoder().decode(
                [AIProviderID: [AICapability: [String]]].self,
                from: cacheData
            ) {
                cachedModels = decoded
            } else if let legacy = try? JSONDecoder().decode(
                [AIProviderID: [String]].self,
                from: cacheData
            ) {
                cachedModels = Self.migratedModelCache(legacy)
                persistModelCache()
            }
        }
    }

    var activeAvatarProfile: AvatarAgentProfile {
        avatarAgentProfiles[activeAvatarID]
            ?? AvatarAgentProfile(
                id: activeAvatarID,
                displayName: AvatarAgentIdentity.displayName(for: activeAvatarID)
            )
    }

    var effectiveSettings: AIProviderSettings {
        effectiveSettings(for: activeAvatarID)
    }

    func effectiveSettings(for avatarID: String) -> AIProviderSettings {
        profile(for: avatarID).effectiveSettings(inheriting: settings)
    }

    func resolvedLiveTalkConfiguration(for avatarID: String) throws -> LiveTalkConfiguration {
        try LiveTalkConfigurationResolver.resolve(
            profile: profile(for: avatarID),
            sharedSettings: settings
        )
    }

    var activeAvatarPromptContext: ActiveAvatarPromptContext {
        let profile = activeAvatarProfile
        return .init(
            avatarName: profile.displayName,
            systemPrompt: profile.systemPrompt,
            userPrompt: profile.userPrompt
        )
    }

    func profile(for avatarID: String) -> AvatarAgentProfile {
        avatarAgentProfiles[avatarID]
            ?? AvatarAgentProfile(
                id: avatarID,
                displayName: AvatarAgentIdentity.displayName(for: avatarID)
            )
    }

    func activateAvatar(id: String, displayName: String) {
        guard OpenClamAvatarID.isValid(id) else {
            return
        }
        if avatarAgentProfiles[id] == nil {
            let candidate = AvatarAgentProfile(id: id, displayName: displayName)
            guard let validated = try? candidate.validated() else { return }
            avatarAgentProfiles[id] = validated
        }
        activeAvatarID = id
    }

    func reconcileAvatarCatalog(_ identities: [AvatarAgentIdentity]) {
        let availableIDs = Set(identities.map(\.id))
        for identity in identities where avatarAgentProfiles[identity.id] == nil {
            let profile = AvatarAgentProfile(
                id: identity.id,
                displayName: identity.displayName
            )
            if let validated = try? profile.validated() {
                avatarAgentProfiles[identity.id] = validated
            }
        }
        if !availableIDs.contains(activeAvatarID) {
            activeAvatarID = AvatarAgentIdentity.defaultID
        }
    }

    func removeImportedAvatarProfile(id: String) {
        guard !AvatarAgentIdentity.defaultPack.contains(where: { $0.id == id }) else {
            return
        }
        avatarAgentProfiles.removeValue(forKey: id)
        if activeAvatarID == id {
            activeAvatarID = AvatarAgentIdentity.defaultID
        }
        if let threadID = avatarAgentThreads.activeThreadByAvatar.removeValue(forKey: id) {
            avatarAgentThreads.avatarByThread.removeValue(forKey: threadID)
        }
        avatarAgentThreads.avatarByThread = avatarAgentThreads.avatarByThread.filter {
            $0.value != id
        }
    }

    @discardableResult
    func updateAvatarProfile(_ profile: AvatarAgentProfile) throws -> AvatarAgentProfile {
        let validated = try profile.validated()
        avatarAgentProfiles[validated.id] = validated
        return validated
    }

    @discardableResult
    func updateActiveAvatarLanguageModel(
        _ selection: AIServiceSelection
    ) throws -> AvatarAgentProfile {
        var profile = activeAvatarProfile
        profile.languageModelOverride = try selection.validated(for: .llm)
        return try updateAvatarProfile(profile)
    }

    func resetAvatarProfile(_ avatarID: String) {
        let name = avatarAgentProfiles[avatarID]?.displayName
            ?? AvatarAgentIdentity.displayName(for: avatarID)
        avatarAgentProfiles[avatarID] = AvatarAgentProfile(id: avatarID, displayName: name)
    }

    func activeThreadID(for avatarID: String) -> UUID? {
        avatarAgentThreads.activeThreadByAvatar[avatarID]
    }

    func avatarID(for threadID: UUID) -> String? {
        avatarAgentThreads.avatarByThread[threadID]
    }

    func registerThread(_ threadID: UUID, for avatarID: String) {
        avatarAgentThreads.activeThreadByAvatar[avatarID] = threadID
        avatarAgentThreads.avatarByThread[threadID] = avatarID
    }

    func removeThread(_ threadID: UUID) {
        guard let avatarID = avatarAgentThreads.avatarByThread.removeValue(forKey: threadID) else {
            return
        }
        if avatarAgentThreads.activeThreadByAvatar[avatarID] == threadID {
            avatarAgentThreads.activeThreadByAvatar.removeValue(forKey: avatarID)
        }
    }

    func containsRuntimeCredential(for capability: AICapability) throws -> Bool {
        let provider = effectiveSettings.selection(for: capability).provider
        if provider == .apple { return true }
        return try providerVault.containsCredential(for: provider)
    }

    func models(for capability: AICapability, provider: AIProviderID) -> [String] {
        let fetched = cachedModels[provider]?[capability] ?? []
        let filtered = Self.filteredModels(fetched, for: capability, provider: provider)
        let defaults = AIProviderRegistry.descriptor(for: provider).defaultModels[capability] ?? []
        return Array(Set(defaults + filtered)).sorted()
    }

    /// The provider's documented default stays first even when the displayed catalog is sorted.
    /// This prevents changing providers from silently picking an unrelated alphabetically-first
    /// model (for example an older GPT model).
    func preferredModel(for capability: AICapability, provider: AIProviderID) -> String? {
        let descriptor = AIProviderRegistry.descriptor(for: provider)
        return descriptor.defaultModels[capability]?.first
            ?? models(for: capability, provider: provider).first
    }

    /// Commits exactly one capability. Other capability drafts cannot block or overwrite it.
    @discardableResult
    func updateSelection(
        _ selection: AIServiceSelection,
        for capability: AICapability
    ) throws -> AIServiceSelection {
        let validated = try selection.validated(for: capability)
        var updated = settings
        updated.setSelection(validated, for: capability)
        settings = updated
        return validated
    }

    @discardableResult
    func refreshModels(
        for provider: AIProviderID,
        capability: AICapability
    ) async throws -> [String] {
        let models = try await settingsCredentialStore.refreshModels(
            for: provider,
            capability: capability
        )
        cachedModels[provider, default: [:]][capability] = models
        persistModelCache()
        return self.models(for: capability, provider: provider)
    }

    func containsSelectedCredential(for capability: AICapability) async throws -> Bool {
        try containsRuntimeCredential(for: capability)
    }

    func runtimeReadiness(for capability: AICapability) async -> AICapabilityRuntimeReadiness {
        let provider = effectiveSettings.selection(for: capability).provider
        guard AIProviderRegistry.hasRuntimeAdapter(provider: provider, capability: capability) else {
            return .adapterUnavailable
        }
        if provider == .apple { return .ready }
        do {
            return try await settingsCredentialStore.containsCredential(for: provider)
                ? .ready
                : .missingCredential
        } catch {
            return .credentialStoreUnavailable
        }
    }

    func makeClient() throws -> any LLMAgentClient {
        let selection = try effectiveSettings.llm.validated(for: .llm)
        let credentialStore = ProviderScopedAgentCredentialStore(
            provider: selection.provider,
            vault: providerVault
        )
        switch selection.provider {
        case .openAI, .xAI, .openRouter:
            let descriptor = AIProviderRegistry.descriptor(for: selection.provider)
            guard let endpoint = descriptor.agentResponsesEndpoint else {
                throw AIProviderSettingsError.agentRuntimeUnavailable(selection.provider)
            }
            return OpenAIResponsesClient(
                configuration: try OpenAIResponsesConfiguration(
                    endpoint: endpoint,
                    model: selection.model
                ),
                credentialStore: credentialStore,
                // Live search is a separate locally authorized function tool. Keeping the hosted
                // tool off here prevents a model from searching when the latest user turn did not
                // explicitly ask for current/live information.
                enablesXSearch: false
            )
        case .anthropic:
            return try AnthropicMessagesAgentClient(
                model: selection.model,
                credentialStore: credentialStore
            )
        case .gemini:
            return try GeminiInteractionsAgentClient(
                model: selection.model,
                credentialStore: credentialStore
            )
        default:
            throw AIProviderSettingsError.agentRuntimeUnavailable(selection.provider)
        }
    }

    func makeWebSearchService() throws -> any ProviderWebSearchServicing {
        let selection = try settings.webSearch.validated(for: .webSearch)
        guard AIProviderRegistry.hasRuntimeAdapter(
            provider: selection.provider,
            capability: .webSearch
        ) else {
            throw AIProviderSettingsError.agentRuntimeUnavailable(selection.provider)
        }
        let credentialStore = ProviderScopedAgentCredentialStore(
            provider: selection.provider,
            vault: providerVault
        )
        switch selection.provider {
        case .xAI where selection.model == "x_search":
            return XAIWebSearchService(credentialStore: credentialStore)
        case .gemini:
            return try GeminiWebSearchService(
                model: selection.model,
                credentialStore: credentialStore
            )
        case .tavily where selection.model == "tavily-search":
            return TavilyWebSearchService(credentialStore: credentialStore)
        case .brave where selection.model == "brave-web-search":
            return BraveWebSearchService(credentialStore: credentialStore)
        case .exa where selection.model == "exa-search":
            return ExaWebSearchService(credentialStore: credentialStore)
        default:
            throw AIProviderSettingsError.agentRuntimeUnavailable(selection.provider)
        }
    }

    /// Cloud speech adapter used by the composer speaker when a supported provider is selected.
    func makeCloudTextToSpeechService() throws -> any CloudTextToSpeechServicing {
        let selection = try effectiveSettings.textToSpeech.validated(for: .textToSpeech)
        return try makeCloudTextToSpeechService(for: selection)
    }

    /// Produces a bounded preview from an explicit draft without mutating or persisting it.
    /// AISettingsView uses this boundary so tapping Preview never acts like a hidden Save button.
    func synthesizeVoicePreview(
        selection rawSelection: AIServiceSelection,
        text: String
    ) async throws -> CloudSpeechAudio {
        let selection = try rawSelection.validated(for: .textToSpeech)
        guard selection.provider != .apple else {
            throw AIProviderSettingsError.agentRuntimeUnavailable(.apple)
        }
        let service = try makeCloudTextToSpeechService(for: selection)
        let voice = selection.voice
            ?? AIProviderRegistry.defaultVoice(for: selection.provider)
            ?? "alloy"
        return try await service.synthesize(
            .init(
                text: text,
                model: selection.model,
                voice: voice,
                languageCode: Locale.current.language.languageCode?.identifier
            )
        )
    }

    private func makeCloudTextToSpeechService(
        for selection: AIServiceSelection
    ) throws -> any CloudTextToSpeechServicing {
        let credentialStore = ProviderScopedAgentCredentialStore(
            provider: selection.provider,
            vault: providerVault
        )
        switch selection.provider {
        case .openAI:
            return OpenAICloudVoiceService(credentialStore: credentialStore)
        case .xAI:
            return XAICloudVoiceService(credentialStore: credentialStore)
        case .openRouter:
            return OpenRouterCloudVoiceService(credentialStore: credentialStore)
        case .gemini:
            return GeminiCloudTextToSpeechService(credentialStore: credentialStore)
        case .elevenLabs:
            return ElevenLabsCloudVoiceService(credentialStore: credentialStore)
        case .soniox:
            return SonioxCloudTextToSpeechService(credentialStore: credentialStore)
        default:
            throw AIProviderSettingsError.agentRuntimeUnavailable(selection.provider)
        }
    }

    /// Cloud transcription adapter used by tap-to-talk when a supported provider is selected.
    func makeCloudSpeechToTextService() throws -> any CloudSpeechToTextServicing {
        let selection = try effectiveSettings.speechToText.validated(for: .speechToText)
        let credentialStore = ProviderScopedAgentCredentialStore(
            provider: selection.provider,
            vault: providerVault
        )
        switch selection.provider {
        case .openAI:
            return OpenAICloudVoiceService(credentialStore: credentialStore)
        case .xAI:
            return XAICloudVoiceService(credentialStore: credentialStore)
        case .openRouter:
            return OpenRouterCloudVoiceService(credentialStore: credentialStore)
        case .elevenLabs:
            return ElevenLabsCloudVoiceService(credentialStore: credentialStore)
        case .soniox:
            guard selection.model == "stt-async-v5" else {
                throw AIProviderSettingsError.agentRuntimeUnavailable(selection.provider)
            }
            return SonioxCloudSpeechToTextService(credentialStore: credentialStore)
        default:
            throw AIProviderSettingsError.agentRuntimeUnavailable(selection.provider)
        }
    }

    /// Real-time microphone adapter used when Soniox's streaming model is selected.
    func makeRealtimeSpeechToTextService() throws -> any RealtimeSpeechToTextServicing {
        let selection = try effectiveSettings.speechToText.validated(for: .speechToText)
        guard selection.provider == .soniox,
              selection.model == SonioxRealtimeSpeechToTextService.model else {
            throw AIProviderSettingsError.agentRuntimeUnavailable(selection.provider)
        }
        let credentialStore = ProviderScopedAgentCredentialStore(
            provider: selection.provider,
            vault: providerVault
        )
        return SonioxRealtimeSpeechToTextService(credentialStore: credentialStore)
    }

    func testConnection(oneUseAPIKey: String?) async throws {
        let validated = try settings.validated()
        try await Self.testConnection(
            settings: validated,
            oneUseAPIKey: oneUseAPIKey,
            savedCredentialStore: agentCredentialStore
        )
    }

    nonisolated static func testConnection(
        settings: AIProviderSettings,
        oneUseAPIKey: String?,
        savedCredentialStore: AgentCredentialStore
    ) async throws {
        let validated = try settings.validated()
        let credentialStore: AgentCredentialStore
        if let oneUseAPIKey {
            credentialStore = try OneUseAgentCredentialStore(apiKey: oneUseAPIKey)
        } else {
            credentialStore = savedCredentialStore
        }
        let limits = try OpenAIResponsesConfiguration(
            endpoint: testEndpoint(for: validated.llm.provider),
            model: validated.llm.model,
            requestTimeout: 30,
            maxToolRounds: 0,
            maxResponseBytes: 256_000,
            maxToolOutputBytes: 8_000,
            maxInputItems: 4,
            maxInputCharacters: 8_000
        )
        let client: any LLMAgentClient
        switch validated.llm.provider {
        case .openAI, .xAI, .openRouter:
            client = OpenAIResponsesClient(
                configuration: limits,
                credentialStore: credentialStore,
                enablesXSearch: false
            )
        case .anthropic:
            client = try AnthropicMessagesAgentClient(
                model: validated.llm.model,
                credentialStore: credentialStore,
                limits: limits
            )
        case .gemini:
            client = try GeminiInteractionsAgentClient(
                model: validated.llm.model,
                credentialStore: credentialStore,
                limits: limits
            )
        default:
            throw AIProviderSettingsError.agentRuntimeUnavailable(validated.llm.provider)
        }
        _ = try await client.respond(
            input: [.message(role: .user, content: "Reply with only the word ready.")],
            instructions: "This is a connection test. Reply with only the word ready."
        )
    }

    nonisolated private static func testEndpoint(for provider: AIProviderID) throws -> URL {
        switch provider {
        case .openAI, .xAI, .openRouter:
            guard let endpoint = AIProviderRegistry.descriptor(for: provider).agentResponsesEndpoint else {
                throw AIProviderSettingsError.agentRuntimeUnavailable(provider)
            }
            return endpoint
        case .anthropic:
            return AnthropicMessagesAgentClient.endpoint
        case .gemini:
            return GeminiInteractionsAgentClient.endpoint
        default:
            throw AIProviderSettingsError.agentRuntimeUnavailable(provider)
        }
    }

    nonisolated private static func filteredModels(
        _ models: [String],
        for capability: AICapability,
        provider: AIProviderID
    ) -> [String] {
        models.filter { rawModel in
            let model = rawModel.lowercased()
            switch (provider, capability) {
            case (.openAI, .llm):
                let isReasoningModel = model.range(
                    of: #"^o[0-9]"#,
                    options: .regularExpression
                ) != nil
                return (model.hasPrefix("gpt-") || isReasoningModel)
                    && !model.contains("tts")
                    && !model.contains("transcribe")
                    && !model.contains("audio")
                    && !model.contains("realtime")
                    && !model.contains("image")
            case (.openAI, .textToSpeech):
                return model.contains("tts")
            case (.openAI, .speechToText):
                return model.contains("transcribe") || model.contains("whisper")
            case (.openAI, .imageGeneration):
                return model.contains("image")
            case (.openAI, .videoGeneration):
                return model.contains("sora") || model.contains("video")
            case (.gemini, .llm):
                return model.contains("gemini")
                    && !model.contains("tts")
                    && !model.contains("live")
                    && !model.contains("image")
                    && !model.contains("embedding")
            case (.gemini, .textToSpeech):
                return model.contains("tts")
            case (.gemini, .webSearch):
                return model.contains("gemini")
                    && !model.contains("tts")
                    && !model.contains("live")
                    && !model.contains("image")
                    && !model.contains("embedding")
            case (.gemini, .speechToText):
                return model.contains("gemini")
                    && !model.contains("tts")
                    && !model.contains("image")
            case (.gemini, .imageGeneration):
                return model.contains("image") || model.contains("imagen")
            case (.gemini, .videoGeneration):
                return model.contains("veo") || model.contains("video")
            case (.elevenLabs, .textToSpeech):
                return model.contains("eleven")
            case (.elevenLabs, .speechToText):
                return model.contains("scribe")
            case (.soniox, .textToSpeech):
                return model.contains("tts")
            case (.soniox, .speechToText):
                return model == "stt-rt-v5" || model == "stt-async-v5"
            case (.openRouter, _):
                // ProviderAPIClient already requires the model's declared output modality to
                // match the requested per-capability catalog before it enters this cache.
                return true
            case (.anthropic, .llm), (.xAI, .llm):
                return true
            default:
                return false
            }
        }.sorted()
    }

    nonisolated private static func migratedModelCache(
        _ legacy: [AIProviderID: [String]]
    ) -> [AIProviderID: [AICapability: [String]]] {
        var migrated: [AIProviderID: [AICapability: [String]]] = [:]
        for (provider, identifiers) in legacy {
            let descriptor = AIProviderRegistry.descriptor(for: provider)
            for capability in descriptor.capabilities {
                let matching = filteredModels(identifiers, for: capability, provider: provider)
                if !matching.isEmpty {
                    migrated[provider, default: [:]][capability] = matching
                }
            }
        }
        return migrated
    }

    private func persistModelCache() {
        if let data = try? JSONEncoder().encode(cachedModels) {
            defaults.set(data, forKey: modelCacheKey)
        }
    }

    private func persistAvatarAgentProfiles() {
        guard let data = try? JSONEncoder().encode(avatarAgentProfiles) else { return }
        defaults.set(data, forKey: avatarProfilesKey)
    }

    private func persistActiveAvatarID() {
        defaults.set(activeAvatarID, forKey: activeAvatarKey)
    }

    private func persistAvatarAgentThreads() {
        guard let data = try? JSONEncoder().encode(avatarAgentThreads) else { return }
        defaults.set(data, forKey: avatarThreadsKey)
    }

    private func persist(_ value: AIProviderSettings) {
        guard let validated = try? value.validated(),
              let data = try? JSONEncoder().encode(validated) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

enum AICapabilityRuntimeReadiness: Equatable, Sendable {
    case ready
    case missingCredential
    case adapterUnavailable
    case credentialStoreUnavailable
}

final class SelectedProviderAgentCredentialStore: AgentCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var selectedProvider: AIProviderID
    private let vault: ProviderCredentialVault

    var provider: AIProviderID {
        get { lock.withLock { selectedProvider } }
        set { lock.withLock { selectedProvider = newValue } }
    }

    init(provider: AIProviderID, vault: ProviderCredentialVault) {
        selectedProvider = provider
        self.vault = vault
    }

    func saveAPIKey(_ apiKey: String) throws {
        try vault.saveCredential(apiKey, for: provider)
    }

    func loadAPIKey() throws -> String? {
        try vault.loadCredential(for: provider)
    }

    func deleteAPIKey() throws {
        try vault.deleteCredential(for: provider)
    }
}

actor AgentSettingsCredentialBridge: AISettingsCredentialStoring {
    private let vault: ProviderCredentialVault
    private let providerClient: ProviderAPIClient

    init(vault: ProviderCredentialVault, providerClient: ProviderAPIClient) {
        self.vault = vault
        self.providerClient = providerClient
    }

    init(store: AgentCredentialStore) {
        vault = KeychainProviderCredentialVault(legacyOpenAIStore: store)
        providerClient = ProviderAPIClient()
    }

    func containsAPIKey() async throws -> Bool {
        try vault.containsCredential(for: .openAI)
    }

    func saveAPIKey(_ apiKey: String) async throws {
        try vault.saveCredential(apiKey, for: .openAI)
    }

    func removeAPIKey() async throws {
        try vault.deleteCredential(for: .openAI)
    }

    func containsCredential(for provider: AIProviderID) async throws -> Bool {
        try vault.containsCredential(for: provider)
    }

    func validateAndSaveCredential(_ credential: String, for provider: AIProviderID) async throws {
        try await providerClient.validateCredential(credential, for: provider)
        try vault.saveCredential(credential, for: provider)
    }

    func removeCredential(for provider: AIProviderID) async throws {
        try vault.deleteCredential(for: provider)
    }

    func refreshModels(
        for provider: AIProviderID,
        capability: AICapability
    ) async throws -> [String] {
        guard let credential = try vault.loadCredential(for: provider) else {
            throw AIProviderSettingsError.missingAPIKey
        }
        return try await providerClient.fetchModels(
            credential: credential,
            provider: provider,
            capability: capability
        ).modelIDs
    }
}

private struct OneUseAgentCredentialStore: AgentCredentialStore {
    let apiKey: String

    init(apiKey: String) throws {
        self.apiKey = try AgentCredentialValidator.normalizedAPIKey(apiKey)
    }

    func saveAPIKey(_ apiKey: String) throws {}
    func loadAPIKey() throws -> String? { apiKey }
    func deleteAPIKey() throws {}
}
