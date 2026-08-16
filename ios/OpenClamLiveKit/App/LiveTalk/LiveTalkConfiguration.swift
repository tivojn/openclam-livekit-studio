import Foundation

enum LiveTalkStage: String, Codable, CaseIterable, Sendable {
    case llm
    case stt
    case tts

    var title: String {
        switch self {
        case .llm: "Language model"
        case .stt: "Speech recognition"
        case .tts: "Speaking voice"
        }
    }
}

enum LiveTalkCredentialSource: String, Codable, Sendable {
    case managed
    case byok

    var title: String {
        switch self {
        case .managed: "LiveKit managed"
        case .byok: "My API key"
        }
    }
}

/// Language values reviewed across the iOS catalog, broker, and agent constructors.
///
/// The wire model remains a String for backward-compatible decoding of saved pilot
/// profiles. New selections are created and resolved through this closed enum.
enum LiveTalkLanguage: String, Codable, CaseIterable, Sendable {
    case automatic = "auto"
    case english = "en"
    case multilingual = "multi"
    case chinese = "zh"

    static func explicitRecognitionLanguage(
        for composerLanguageCode: String?
    ) -> Self? {
        guard let composerLanguageCode else { return nil }
        let primaryCode = composerLanguageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first

        switch primaryCode {
        case "en": return .english
        case "zh": return .chinese
        default: return nil
        }
    }
}

/// A closed, non-secret selection. Provider credentials never become part of this Codable value.
struct LiveTalkStageSelection: Codable, Equatable, Sendable {
    var source: LiveTalkCredentialSource
    var provider: String
    var model: String
    var voice: String?
    var language: String?
}

struct LiveTalkConfiguration: Codable, Equatable, Sendable {
    var llm: LiveTalkStageSelection
    var stt: LiveTalkStageSelection
    var tts: LiveTalkStageSelection

    static let managedDefault = Self(
        llm: LiveTalkCatalog.managedLLM.selection,
        stt: LiveTalkCatalog.managedSTT.selection,
        tts: LiveTalkCatalog.managedTTS.selection
    )

    subscript(stage: LiveTalkStage) -> LiveTalkStageSelection {
        get {
            switch stage {
            case .llm: llm
            case .stt: stt
            case .tts: tts
            }
        }
        set {
            switch stage {
            case .llm: llm = newValue
            case .stt: stt = newValue
            case .tts: tts = newValue
            }
        }
    }

    func validated() throws -> Self {
        var result = self
        for stage in LiveTalkStage.allCases {
            guard let option = LiveTalkCatalog.option(
                matching: self[stage],
                for: stage
            ) else {
                throw LiveTalkConfigurationError.selectionNotSupported(stage)
            }
            result[stage] = option.selection
        }
        return result
    }

    var summary: String {
        LiveTalkStage.allCases.map { stage in
            LiveTalkCatalog.option(matching: self[stage], for: stage)?.shortTitle
                ?? "Unavailable"
        }.joined(separator: " · ")
    }
}

/// Local-only source-of-truth for how an avatar chooses each Live Talk stage.
///
/// `followAvatar` is deliberately resolved to an exact, reviewed BYOK tuple before the
/// broker request is built. It is never serialized into the broker contract. `fixed` keeps
/// previously shipped TestFlight selections working until the user explicitly changes them.
enum LiveTalkStagePreference: Codable, Equatable, Sendable {
    case managed
    case followAvatar
    case fixed(LiveTalkStageSelection)

    func validated(for stage: LiveTalkStage) throws -> Self {
        guard case let .fixed(selection) = self else { return self }
        guard let option = LiveTalkCatalog.option(matching: selection, for: stage) else {
            throw LiveTalkConfigurationError.selectionNotSupported(stage)
        }
        return .fixed(option.selection)
    }
}

struct LiveTalkPreferences: Codable, Equatable, Sendable {
    var llm: LiveTalkStagePreference
    var stt: LiveTalkStagePreference
    var tts: LiveTalkStagePreference
    /// Optional for forward-compatible decoding. Nil means the reviewed managed default.
    var managedTTSVoice: String?

    static let managedDefault = Self(llm: .managed, stt: .managed, tts: .managed)

    init(
        llm: LiveTalkStagePreference = .managed,
        stt: LiveTalkStagePreference = .managed,
        tts: LiveTalkStagePreference = .managed,
        managedTTSVoice: String? = nil
    ) {
        self.llm = llm
        self.stt = stt
        self.tts = tts
        self.managedTTSVoice = managedTTSVoice
    }

    init(legacy configuration: LiveTalkConfiguration) {
        llm = Self.preference(for: .llm, selection: configuration.llm)
        stt = Self.preference(for: .stt, selection: configuration.stt)
        tts = Self.preference(for: .tts, selection: configuration.tts)
        managedTTSVoice = configuration.tts.source == .managed
            ? configuration.tts.voice
            : nil
    }

    subscript(stage: LiveTalkStage) -> LiveTalkStagePreference {
        get {
            switch stage {
            case .llm: llm
            case .stt: stt
            case .tts: tts
            }
        }
        set {
            switch stage {
            case .llm: llm = newValue
            case .stt: stt = newValue
            case .tts: tts = newValue
            }
        }
    }

    func validated() throws -> Self {
        var result = self
        for stage in LiveTalkStage.allCases {
            result[stage] = try self[stage].validated(for: stage)
        }
        if case .managed = result.tts,
           let managedTTSVoice,
           LiveTalkCatalog.managedTTSOption(voice: managedTTSVoice) == nil {
            throw LiveTalkConfigurationError.selectionNotSupported(.tts)
        }
        return result
    }

    private static func preference(
        for stage: LiveTalkStage,
        selection: LiveTalkStageSelection
    ) -> LiveTalkStagePreference {
        guard let option = LiveTalkCatalog.option(matching: selection, for: stage) else {
            return .fixed(selection)
        }
        if option.selection.source == .managed {
            return .managed
        }
        return .fixed(option.selection)
    }
}

struct LiveTalkProviderOption: Identifiable, Equatable, Sendable {
    let stage: LiveTalkStage
    let selection: LiveTalkStageSelection
    let title: String
    let shortTitle: String
    let detail: String
    let credentialProvider: AIProviderID?

    var id: String {
        [
            stage.rawValue,
            selection.source.rawValue,
            selection.provider,
            selection.model,
            selection.voice ?? "",
            selection.language ?? "",
        ].joined(separator: "|")
    }
}

enum LiveTalkCatalog {
    static let managedLLM = option(
        .llm, .managed, "livekit", "google/gemma-4-31b-it",
        "LiveKit managed", "Managed LLM", "Gemma 4 31B through LiveKit Inference"
    )
    static let managedSTT = option(
        .stt, .managed, "livekit", "deepgram/nova-3",
        "LiveKit managed", "Managed STT", "Deepgram Nova-3 through LiveKit Inference",
        language: .multilingual
    )
    static let managedTTS = option(
        .tts, .managed, "livekit", "fishaudio/s2.1-pro",
        "Sarah — engaged", "Managed TTS · Sarah", "Sarah is engaged and attentive through Fish Audio S2.1 Pro",
        voice: "933563129e564b19a115bedd57b7406a"
    )

    private static let managedTTSOptions: [LiveTalkProviderOption] = [
        managedTTS,
        option(
            .tts, .managed, "livekit", "fishaudio/s2.1-pro",
            "Hannah — conversational", "Managed TTS · Hannah", "Hannah has a natural conversational style through Fish Audio S2.1 Pro",
            voice: "9a9cf47702da476aa4629e2506d4a857"
        ),
        option(
            .tts, .managed, "livekit", "fishaudio/s2.1-pro",
            "Jordan — motivational", "Managed TTS · Jordan", "Jordan has a motivational style through Fish Audio S2.1 Pro",
            voice: "79d0bd3e4e5444b18f7b6d89b5927bf1"
        ),
        option(
            .tts, .managed, "livekit", "fishaudio/s2.1-pro",
            "Adrian — friendly & casual", "Managed TTS · Adrian", "Adrian has a friendly, casual style through Fish Audio S2.1 Pro",
            voice: "bf322df2096a46f18c579d0baa36f41d"
        ),
        option(
            .tts, .managed, "livekit", "fishaudio/s2.1-pro",
            "Ethan — curious explainer", "Managed TTS · Ethan", "Ethan has a curious, explanatory style through Fish Audio S2.1 Pro",
            voice: "536d3a5e000945adb7038665781a4aca"
        ),
        option(
            .tts, .managed, "livekit", "fishaudio/s2.1-pro",
            "Laura — confident narrator", "Managed TTS · Laura", "Laura has a confident narrator style through Fish Audio S2.1 Pro",
            voice: "e3cd384158934cc9a01029cd7d278634"
        ),
        option(
            .tts, .managed, "livekit", "fishaudio/s2.1-pro",
            "Selene — meditative (legacy)", "Managed TTS · Selene", "Selene keeps the meditative voice used by earlier Live Talk builds",
            voice: "b347db033a6549378b48d00acb0d06cd"
        ),
    ]

    private static let llmOptions: [LiveTalkProviderOption] = [
        managedLLM,
        option(.llm, .byok, "openai", "gpt-5.6-luna", "OpenAI", "GPT-5.6 Luna", "OpenAI GPT-5.6 Luna", credential: .openAI),
        option(.llm, .byok, "openai", "gpt-5.6-terra", "OpenAI", "GPT-5.6 Terra", "OpenAI GPT-5.6 Terra", credential: .openAI),
        option(.llm, .byok, "openai", "gpt-5.6-sol", "OpenAI", "GPT-5.6 Sol", "OpenAI GPT-5.6 Sol", credential: .openAI),
        option(.llm, .byok, "openai", "gpt-5.4-mini", "OpenAI", "OpenAI", "GPT-5.4 mini", credential: .openAI),
        option(.llm, .byok, "xai", "grok-4.5", "xAI", "Grok 4.5", "xAI Grok 4.5", credential: .xAI),
        option(.llm, .byok, "xai", "grok-4.3", "xAI", "xAI", "Grok 4.3", credential: .xAI),
        option(.llm, .byok, "gemini", "gemini-3.6-flash", "Google Gemini", "Gemini 3.6 Flash", "Google Gemini 3.6 Flash", credential: .gemini),
        option(.llm, .byok, "gemini", "gemini-3.5-flash", "Google Gemini", "Gemini", "Gemini 3.5 Flash", credential: .gemini),
        option(.llm, .byok, "gemini", "gemini-3.5-flash-lite", "Google Gemini", "Gemini 3.5 Flash Lite", "Google Gemini 3.5 Flash Lite", credential: .gemini),
        option(.llm, .byok, "anthropic", "claude-haiku-4-5", "Anthropic", "Claude Haiku 4.5", "Anthropic Claude Haiku 4.5", credential: .anthropic),
        option(.llm, .byok, "anthropic", "claude-sonnet-4-6", "Anthropic", "Claude", "Claude Sonnet 4.6", credential: .anthropic),
    ]

    private static let sttOptions: [LiveTalkProviderOption] = [
        managedSTT,
        option(.stt, .byok, "openai", "gpt-4o-transcribe", "OpenAI", "GPT-4o Transcribe", "GPT-4o Transcribe · English", credential: .openAI, language: .english),
        option(.stt, .byok, "openai", "gpt-4o-transcribe", "OpenAI", "GPT-4o Transcribe", "GPT-4o Transcribe · Chinese", credential: .openAI, language: .chinese),
        option(.stt, .byok, "openai", "gpt-4o-mini-transcribe", "OpenAI", "OpenAI STT", "GPT-4o mini transcribe · English", credential: .openAI, language: .english),
        option(.stt, .byok, "openai", "gpt-4o-mini-transcribe", "OpenAI", "OpenAI STT", "GPT-4o mini transcribe · Chinese", credential: .openAI, language: .chinese),
        option(.stt, .byok, "openai", "whisper-1", "OpenAI", "Whisper 1", "OpenAI Whisper 1 · English", credential: .openAI, language: .english),
        option(.stt, .byok, "openai", "whisper-1", "OpenAI", "Whisper 1", "OpenAI Whisper 1 · Chinese", credential: .openAI, language: .chinese),
        // xAI STT detects spoken languages independently. Its pinned `language`
        // constructor value controls text formatting, whose reviewed list omits zh.
        option(.stt, .byok, "xai", "grok-transcribe", "xAI", "xAI STT", "Grok multilingual transcription", credential: .xAI, language: .english),
        option(.stt, .byok, "deepgram", "nova-3", "Deepgram", "Deepgram", "Nova-3 multilingual", credential: .deepgram, language: .multilingual),
        option(.stt, .byok, "elevenlabs", "scribe_v2_realtime", "ElevenLabs", "ElevenLabs STT", "Scribe v2 realtime", credential: .elevenLabs, language: .multilingual),
    ]

    private static let ttsOptions: [LiveTalkProviderOption] = managedTTSOptions + [
        option(.tts, .byok, "openai", "tts-1", "OpenAI", "OpenAI TTS 1 · Alloy", "OpenAI TTS 1 · Alloy", credential: .openAI, voice: "alloy"),
        option(.tts, .byok, "openai", "tts-1-hd", "OpenAI", "OpenAI TTS 1 HD · Alloy", "OpenAI TTS 1 HD · Alloy", credential: .openAI, voice: "alloy"),
        option(.tts, .byok, "openai", "gpt-4o-mini-tts", "OpenAI", "OpenAI TTS", "GPT-4o mini TTS · Alloy", credential: .openAI, voice: "alloy"),
        option(.tts, .byok, "xai", "xai-tts", "xAI", "xAI TTS", "Expressive multilingual Ara voice", credential: .xAI, voice: "ara", language: .automatic),
        option(.tts, .byok, "xai", "xai-tts", "xAI", "xAI TTS · Eve", "Expressive multilingual Eve voice", credential: .xAI, voice: "eve", language: .automatic),
        option(.tts, .byok, "xai", "xai-tts", "xAI", "xAI TTS · Leo", "Expressive multilingual Leo voice", credential: .xAI, voice: "leo", language: .automatic),
        option(.tts, .byok, "xai", "xai-tts", "xAI", "xAI TTS · Rex", "Expressive multilingual Rex voice", credential: .xAI, voice: "rex", language: .automatic),
        option(.tts, .byok, "xai", "xai-tts", "xAI", "xAI TTS · Sal", "Expressive multilingual Sal voice", credential: .xAI, voice: "sal", language: .automatic),
        option(.tts, .byok, "gemini", "gemini-3.1-flash-tts-preview", "Google Gemini", "Gemini TTS", "Gemini 3.1 Flash TTS · Sadachbia", credential: .gemini, voice: "Sadachbia"),
        option(.tts, .byok, "gemini", "gemini-3.1-flash-tts-preview", "Google Gemini", "Gemini TTS · Kore", "Gemini 3.1 Flash TTS · Kore", credential: .gemini, voice: "Kore"),
        option(.tts, .byok, "deepgram", "aura-2-andromeda-en", "Deepgram", "Deepgram TTS", "Aura-2 Andromeda", credential: .deepgram, voice: "aura-2-andromeda-en"),
        option(.tts, .byok, "elevenlabs", "eleven_flash_v2_5", "ElevenLabs", "ElevenLabs TTS", "Flash v2.5 default voice", credential: .elevenLabs, voice: "EXAVITQu4vr4xnSDxMaL"),
        option(.tts, .byok, "elevenlabs", "eleven_flash_v2_5", "ElevenLabs", "ElevenLabs Flash", "Flash v2.5 reviewed voice", credential: .elevenLabs, voice: "JBFqnCBsd6RMkjVDRZzb"),
        option(.tts, .byok, "elevenlabs", "eleven_multilingual_v2", "ElevenLabs", "ElevenLabs Multilingual", "Multilingual v2 reviewed voice", credential: .elevenLabs, voice: "JBFqnCBsd6RMkjVDRZzb"),
    ]

    static func options(for stage: LiveTalkStage) -> [LiveTalkProviderOption] {
        switch stage {
        case .llm: llmOptions
        case .stt: sttOptions
        case .tts: ttsOptions
        }
    }

    static func managedOptions(for stage: LiveTalkStage) -> [LiveTalkProviderOption] {
        options(for: stage).filter { $0.selection.source == .managed }
    }

    static func managedTTSOption(voice: String?) -> LiveTalkProviderOption? {
        guard let voice else { return managedTTS }
        return managedTTSOptions.first { $0.selection.voice == voice }
    }

    static func option(
        matching selection: LiveTalkStageSelection,
        for stage: LiveTalkStage
    ) -> LiveTalkProviderOption? {
        let selection = canonicalSelection(selection, for: stage)
        return options(for: stage).first(where: { $0.selection == selection })
    }

    static func option(
        following selection: AIServiceSelection,
        for stage: LiveTalkStage,
        composerLanguageCode: String? = Locale.current.language.languageCode?.identifier
    ) -> LiveTalkProviderOption? {
        let language: LiveTalkLanguage?
        do {
            language = try LiveTalkLanguageResolver.resolve(
                stage: stage,
                provider: selection.provider,
                composerLanguageCode: composerLanguageCode
            )
        } catch {
            return nil
        }
        return option(following: selection, for: stage, language: language)
    }

    static func option(
        following selection: AIServiceSelection,
        for stage: LiveTalkStage,
        language: LiveTalkLanguage?
    ) -> LiveTalkProviderOption? {
        let voice: String?
        if stage == .tts {
            voice = selection.voice ?? AIProviderRegistry.defaultVoice(for: selection.provider)
        } else {
            voice = nil
        }
        return options(for: stage).first { option in
            option.selection.source == .byok
                && option.credentialProvider == selection.provider
                && option.selection.model == selection.model
                && option.selection.voice == voice
                && option.selection.language == language?.rawValue
        }
    }

    static func managedOption(for stage: LiveTalkStage) -> LiveTalkProviderOption {
        switch stage {
        case .llm: managedLLM
        case .stt: managedSTT
        case .tts: managedTTS
        }
    }

    private static func option(
        _ stage: LiveTalkStage,
        _ source: LiveTalkCredentialSource,
        _ provider: String,
        _ model: String,
        _ title: String,
        _ shortTitle: String,
        _ detail: String,
        credential: AIProviderID? = nil,
        voice: String? = nil,
        language: LiveTalkLanguage? = nil
    ) -> LiveTalkProviderOption {
        .init(
            stage: stage,
            selection: .init(
                source: source,
                provider: provider,
                model: model,
                voice: voice,
                language: language?.rawValue
            ),
            title: title,
            shortTitle: shortTitle,
            detail: detail,
            credentialProvider: credential
        )
    }

    private static func canonicalSelection(
        _ selection: LiveTalkStageSelection,
        for stage: LiveTalkStage
    ) -> LiveTalkStageSelection {
        var selection = selection
        // Builds before the language contract stored xAI TTS without a language.
        // Canonicalize that one legacy shape to provider-side automatic detection.
        if stage == .tts,
           selection.source == .byok,
           selection.provider == "xai",
           selection.model == "xai-tts",
           selection.language == nil {
            selection.language = LiveTalkLanguage.automatic.rawValue
        }
        return selection
    }
}

enum LiveTalkLanguageResolver {
    static func resolve(
        stage: LiveTalkStage,
        provider: AIProviderID,
        composerLanguageCode: String?
    ) throws -> LiveTalkLanguage? {
        switch stage {
        case .llm:
            return nil
        case .tts:
            return provider == .xAI ? .automatic : nil
        case .stt:
            switch provider {
            case .deepgram, .elevenLabs:
                return .multilingual
            case .xAI:
                // xAI transcribes multilingual speech regardless of this value;
                // its STT language parameter is only a formatting hint.
                return .english
            case .openAI:
                guard let language = LiveTalkLanguage.explicitRecognitionLanguage(
                    for: composerLanguageCode
                ) else {
                    throw LiveTalkConfigurationError.avatarLanguageNotSupported(
                        provider,
                        composerLanguageCode
                    )
                }
                return language
            default:
                return nil
            }
        }
    }
}

enum LiveTalkConfigurationResolver {
    static func resolve(
        profile: AvatarAgentProfile,
        sharedSettings: AIProviderSettings,
        composerLanguageCode: String? = Locale.current.language.languageCode?.identifier
    ) throws -> LiveTalkConfiguration {
        let preferences = try profile.effectiveLiveTalkPreferences.validated()
        let avatarSettings = profile.effectiveSettings(inheriting: sharedSettings)
        var result = LiveTalkConfiguration.managedDefault
        for stage in LiveTalkStage.allCases {
            switch preferences[stage] {
            case .managed:
                if stage == .tts {
                    guard let option = LiveTalkCatalog.managedTTSOption(
                        voice: preferences.managedTTSVoice
                    ) else {
                        throw LiveTalkConfigurationError.selectionNotSupported(.tts)
                    }
                    result[stage] = option.selection
                } else {
                    result[stage] = LiveTalkCatalog.managedOption(for: stage).selection
                }
            case .followAvatar:
                let avatarSelection = avatarSettings.selection(for: stage.capability)
                let language = try LiveTalkLanguageResolver.resolve(
                    stage: stage,
                    provider: avatarSelection.provider,
                    composerLanguageCode: composerLanguageCode
                )
                guard let option = LiveTalkCatalog.option(
                    following: avatarSelection,
                    for: stage,
                    language: language
                ) else {
                    throw LiveTalkConfigurationError.avatarSelectionNotSupported(
                        stage,
                        avatarSelection.provider,
                        avatarSelection.model,
                        avatarSelection.voice
                    )
                }
                result[stage] = option.selection
            case let .fixed(selection):
                guard let option = LiveTalkCatalog.option(matching: selection, for: stage) else {
                    throw LiveTalkConfigurationError.selectionNotSupported(stage)
                }
                result[stage] = option.selection
            }
        }
        return try result.validated()
    }
}

private extension LiveTalkStage {
    var capability: AICapability {
        switch self {
        case .llm: .llm
        case .stt: .speechToText
        case .tts: .textToSpeech
        }
    }
}

enum LiveTalkConfigurationError: LocalizedError, Equatable {
    case selectionNotSupported(LiveTalkStage)
    case avatarSelectionNotSupported(LiveTalkStage, AIProviderID, String, String?)
    case avatarLanguageNotSupported(AIProviderID, String?)

    var errorDescription: String? {
        switch self {
        case let .selectionNotSupported(stage):
            return "The saved \(stage.title.lowercased()) choice is no longer supported. Choose it again."
        case let .avatarSelectionNotSupported(stage, provider, model, voice):
            let providerName = AIProviderRegistry.descriptor(for: provider).displayName
            let voiceDetail = voice.map { " · \($0)" } ?? ""
            return "\(providerName) · \(model)\(voiceDetail) cannot be followed for \(stage.title.lowercased()) in Live Talk. Choose a supported avatar service or use LiveKit managed."
        case let .avatarLanguageNotSupported(provider, languageCode):
            let providerName = AIProviderRegistry.descriptor(for: provider).displayName
            let language = languageCode.flatMap { $0.isEmpty ? nil : $0 }
                ?? "the current language"
            return "\(providerName) speech recognition is not approved for \(language) in Live Talk. Choose English or Chinese, or use a multilingual speech-recognition service."
        }
    }
}
