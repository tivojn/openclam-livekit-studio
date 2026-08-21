import Foundation

enum AICapability: String, Codable, CaseIterable, Sendable {
    case llm
    case textToSpeech
    case speechToText
    case imageGeneration
    case videoGeneration
    case webSearch

    var displayName: String {
        switch self {
        case .llm: "Language model"
        case .textToSpeech: "Text to speech"
        case .speechToText: "Speech recognition"
        case .imageGeneration: "Image generation"
        case .videoGeneration: "Video generation"
        case .webSearch: "Web search"
        }
    }
}

enum AIProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple
    case openAI = "openai"
    case anthropic
    case gemini
    case xAI = "xai"
    case kieAI = "kie-ai"
    case openRouter = "openrouter"
    case elevenLabs = "elevenlabs"
    case deepgram
    case soniox
    case tavily
    case brave
    case exa
    case bing
    case googleCustomSearch = "google-custom-search"

    var id: String { rawValue }
}

enum AIProviderAvailability: String, Codable, Equatable, Sendable {
    case available
    case retired
    case legacyOnly
    case unavailable
}

struct AIProviderDescriptor: Identifiable, Equatable, Sendable {
    let id: AIProviderID
    let displayName: String
    let credentialLabel: String?
    let keyManagementURL: URL?
    let documentationURL: URL
    let capabilities: Set<AICapability>
    let availability: AIProviderAvailability
    let availabilityNote: String?
    let agentResponsesEndpoint: URL?
    let modelListEndpoint: URL?
    let defaultModels: [AICapability: [String]]

    func supports(_ capability: AICapability) -> Bool {
        availability == .available && capabilities.contains(capability)
    }
}

struct AIVoiceDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
}

struct AISpeechRecognitionLanguageOption: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
}

enum AIProviderRegistry {
    static let xAIBatchSpeechToTextModel = "grok-transcribe"
    static let xAILiveSpeechToTextModel = "grok-transcribe-live"
    static let sonioxRealtimeSpeechToTextModel = "stt-rt-v5"
    static let sonioxBatchSpeechToTextModel = "stt-async-v5"

    static let descriptors: [AIProviderDescriptor] = [
        .init(
            id: .apple,
            displayName: "Apple voice & dictation",
            credentialLabel: nil,
            keyManagementURL: nil,
            documentationURL: URL(string: "https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer")!,
            capabilities: [.textToSpeech, .speechToText],
            availability: .available,
            availabilityNote: "Uses iOS voices and Apple speech recognition under your device settings, without a third-party API key.",
            agentResponsesEndpoint: nil,
            modelListEndpoint: nil,
            defaultModels: [
                .textToSpeech: ["system-voice"],
                .speechToText: ["apple-dictation"],
            ]
        ),
        .init(
            id: .openAI,
            displayName: "OpenAI",
            credentialLabel: "OpenAI API key",
            keyManagementURL: URL(string: "https://platform.openai.com/api-keys")!,
            documentationURL: URL(string: "https://developers.openai.com/api/docs/models")!,
            capabilities: [.llm, .textToSpeech, .speechToText, .imageGeneration, .videoGeneration],
            availability: .available,
            availabilityNote: nil,
            agentResponsesEndpoint: URL(string: "https://api.openai.com/v1/responses")!,
            modelListEndpoint: URL(string: "https://api.openai.com/v1/models")!,
            defaultModels: [
                .llm: ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"],
                .textToSpeech: ["tts-1", "tts-1-hd"],
                .speechToText: ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"],
                .imageGeneration: ["gpt-image-2"],
                .videoGeneration: ["sora-2"],
            ]
        ),
        .init(
            id: .anthropic,
            displayName: "Anthropic",
            credentialLabel: "Claude API key",
            keyManagementURL: URL(string: "https://console.anthropic.com/settings/keys")!,
            documentationURL: URL(string: "https://platform.claude.com/docs/en/api/models")!,
            capabilities: [.llm],
            availability: .available,
            availabilityNote: "Claude is a language-model provider; it does not provide standalone TTS or ASR endpoints.",
            agentResponsesEndpoint: nil,
            modelListEndpoint: URL(string: "https://api.anthropic.com/v1/models")!,
            defaultModels: [
                .llm: ["claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5"],
            ]
        ),
        .init(
            id: .gemini,
            displayName: "Google Gemini",
            credentialLabel: "Gemini API key",
            keyManagementURL: URL(string: "https://aistudio.google.com/app/apikey")!,
            documentationURL: URL(string: "https://ai.google.dev/api/models")!,
            capabilities: [.llm, .textToSpeech, .imageGeneration, .videoGeneration, .webSearch],
            availability: .available,
            availabilityNote: "Gemini provides speech generation. Multimodal audio understanding is not presented here as a standalone dictation endpoint.",
            agentResponsesEndpoint: nil,
            modelListEndpoint: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!,
            defaultModels: [
                .llm: ["gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite"],
                .textToSpeech: ["gemini-3.1-flash-tts-preview", "gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts"],
                .imageGeneration: ["gemini-3.1-flash-image"],
                .videoGeneration: ["veo-3.1-generate-preview"],
                .webSearch: ["gemini-3.6-flash"],
            ]
        ),
        .init(
            id: .xAI,
            displayName: "xAI",
            credentialLabel: "xAI API key",
            keyManagementURL: URL(string: "https://console.x.ai/")!,
            documentationURL: URL(string: "https://docs.x.ai/developers/models")!,
            capabilities: [.llm, .textToSpeech, .speechToText, .imageGeneration, .videoGeneration, .webSearch],
            availability: .available,
            availabilityNote: "Includes Grok language models, X Search, and both batch and live Grok Transcribe. Batch is lower cost; Live shows text while you speak. Automatic detection covers xAI's documented 25 languages; Chinese is not supported.",
            agentResponsesEndpoint: URL(string: "https://api.x.ai/v1/responses")!,
            modelListEndpoint: URL(string: "https://api.x.ai/v1/models")!,
            defaultModels: [
                .llm: ["grok-4.5"],
                .textToSpeech: ["xai-tts"],
                .speechToText: [xAIBatchSpeechToTextModel, xAILiveSpeechToTextModel],
                .imageGeneration: ["grok-imagine-image-quality"],
                .videoGeneration: ["grok-imagine-video"],
                .webSearch: ["x_search"],
            ]
        ),
        .init(
            id: .kieAI,
            displayName: "KIE.ai",
            credentialLabel: "KIE.ai API key",
            keyManagementURL: URL(string: "https://kie.ai/api-key")!,
            documentationURL: URL(string: "https://docs.kie.ai/market/quickstart")!,
            capabilities: [.imageGeneration, .videoGeneration],
            availability: .available,
            availabilityNote: "KIE.ai exposes asynchronous media jobs and advises against embedding keys in client apps. This build can validate a Keychain-held key and save the preference, but does not submit generation jobs; a production workflow should keep the key on a server.",
            agentResponsesEndpoint: nil,
            modelListEndpoint: nil,
            defaultModels: [
                .imageGeneration: ["gpt-image-2-text-to-image"],
                .videoGeneration: ["grok-imagine-video-1-5-preview"],
            ]
        ),
        .init(
            id: .openRouter,
            displayName: "OpenRouter",
            credentialLabel: "OpenRouter API key",
            keyManagementURL: URL(string: "https://openrouter.ai/settings/keys")!,
            documentationURL: URL(string: "https://openrouter.ai/docs/guides/overview/models")!,
            capabilities: [.llm, .textToSpeech, .speechToText, .imageGeneration, .videoGeneration],
            availability: .available,
            availabilityNote: "Model availability and voices vary by routed provider. Refresh each category after saving a key; only models whose declared output modality matches that category are shown.",
            agentResponsesEndpoint: URL(string: "https://openrouter.ai/api/v1/responses")!,
            modelListEndpoint: URL(string: "https://openrouter.ai/api/v1/models")!,
            defaultModels: [
                .llm: ["openai/gpt-4o"],
                .textToSpeech: ["openai/gpt-4o-mini-tts-2025-12-15"],
                .speechToText: ["openai/whisper-large-v3"],
                .imageGeneration: ["bytedance-seed/seedream-4.5"],
                .videoGeneration: ["x-ai/grok-imagine-video"],
            ]
        ),
        .init(
            id: .elevenLabs,
            displayName: "ElevenLabs",
            credentialLabel: "ElevenLabs API key",
            keyManagementURL: URL(string: "https://elevenlabs.io/app/settings/api-keys")!,
            documentationURL: URL(string: "https://elevenlabs.io/docs/api-reference/models/list")!,
            capabilities: [.textToSpeech, .speechToText],
            availability: .available,
            availabilityNote: nil,
            agentResponsesEndpoint: nil,
            modelListEndpoint: URL(string: "https://api.elevenlabs.io/v1/models")!,
            defaultModels: [
                .textToSpeech: ["eleven_flash_v2_5", "eleven_multilingual_v2"],
                .speechToText: ["scribe_v2"],
            ]
        ),
        .init(
            id: .deepgram,
            displayName: "Deepgram",
            credentialLabel: "Deepgram API key",
            keyManagementURL: URL(string: "https://console.deepgram.com/")!,
            documentationURL: URL(string: "https://developers.deepgram.com/docs")!,
            capabilities: [.textToSpeech, .speechToText],
            availability: .available,
            availabilityNote: "Nova-3 can transcribe tap-to-talk with automatic multilingual detection, including Chinese and English. A personal Deepgram key is required outside managed Live Talk.",
            agentResponsesEndpoint: nil,
            modelListEndpoint: nil,
            defaultModels: [
                .speechToText: ["nova-3"],
            ]
        ),
        .init(
            id: .soniox,
            displayName: "Soniox",
            credentialLabel: "Soniox API key",
            keyManagementURL: URL(string: "https://console.soniox.com/")!,
            documentationURL: URL(string: "https://soniox.com/docs/api-reference")!,
            capabilities: [.textToSpeech, .speechToText],
            availability: .available,
            availabilityNote: nil,
            agentResponsesEndpoint: nil,
            modelListEndpoint: URL(string: "https://api.soniox.com/v1/models")!,
            defaultModels: [
                .textToSpeech: ["tts-rt-v1"],
                // Live microphone input defaults to Soniox's WebSocket model. The asynchronous
                // model remains an explicit recorded-file fallback rather than a silent migration.
                .speechToText: [
                    sonioxRealtimeSpeechToTextModel,
                    sonioxBatchSpeechToTextModel,
                ],
            ]
        ),
        .init(
            id: .tavily,
            displayName: "Tavily",
            credentialLabel: "Tavily API key",
            keyManagementURL: URL(string: "https://app.tavily.com/home")!,
            documentationURL: URL(string: "https://docs.tavily.com/documentation/api-reference/endpoint/search")!,
            capabilities: [.webSearch],
            availability: .available,
            availabilityNote: "Connection validation performs one small billable search.",
            agentResponsesEndpoint: nil,
            modelListEndpoint: nil,
            defaultModels: [.webSearch: ["tavily-search"]]
        ),
        .init(
            id: .brave,
            displayName: "Brave Search",
            credentialLabel: "Brave subscription token",
            keyManagementURL: URL(string: "https://api.search.brave.com/app/keys")!,
            documentationURL: URL(string: "https://api-dashboard.search.brave.com/app/documentation/web-search/get-started")!,
            capabilities: [.webSearch],
            availability: .available,
            availabilityNote: "Connection validation performs one small billable search.",
            agentResponsesEndpoint: nil,
            modelListEndpoint: nil,
            defaultModels: [.webSearch: ["brave-web-search"]]
        ),
        .init(
            id: .exa,
            displayName: "Exa",
            credentialLabel: "Exa API key",
            keyManagementURL: URL(string: "https://dashboard.exa.ai/api-keys")!,
            documentationURL: URL(string: "https://exa.ai/docs/reference/search")!,
            capabilities: [.webSearch],
            availability: .available,
            availabilityNote: "Connection validation performs one small billable search.",
            agentResponsesEndpoint: nil,
            modelListEndpoint: nil,
            defaultModels: [.webSearch: ["exa-search"]]
        ),
        .init(
            id: .bing,
            displayName: "Bing Search API",
            credentialLabel: nil,
            keyManagementURL: nil,
            documentationURL: URL(string: "https://learn.microsoft.com/en-us/lifecycle/announcements/bing-search-api-retirement")!,
            capabilities: [],
            availability: .retired,
            availabilityNote: "Microsoft retired the Bing Search APIs on August 11, 2025. The Azure agent-only replacement is not a direct API-key search service.",
            agentResponsesEndpoint: nil,
            modelListEndpoint: nil,
            defaultModels: [:]
        ),
        .init(
            id: .googleCustomSearch,
            displayName: "Google Custom Search JSON API",
            credentialLabel: nil,
            keyManagementURL: nil,
            documentationURL: URL(string: "https://developers.google.com/custom-search/v1/overview")!,
            capabilities: [],
            availability: .legacyOnly,
            availabilityNote: "Closed to new customers and scheduled for discontinuation on January 1, 2027; it also requires a search-engine ID in addition to a key.",
            agentResponsesEndpoint: nil,
            modelListEndpoint: nil,
            defaultModels: [:]
        ),
    ]

    static func descriptor(for id: AIProviderID) -> AIProviderDescriptor {
        descriptors.first(where: { $0.id == id })!
    }

    static func preferredModelCatalogCapability(for provider: AIProviderID) -> AICapability? {
        let descriptor = descriptor(for: provider)
        // Soniox's TTS and STT catalogs are separate. Speech recognition is its primary OpenClam
        // integration, so saving a key must refresh the STT catalog (including stt-rt-v5) instead
        // of silently refreshing only TTS and leaving the speech picker stale.
        if provider == .soniox, descriptor.supports(.speechToText) {
            return .speechToText
        }
        return [
            AICapability.llm,
            .textToSpeech,
            .speechToText,
            .imageGeneration,
            .videoGeneration,
            .webSearch,
        ].first(where: descriptor.supports)
    }

    static func supportsModelRefresh(
        provider: AIProviderID,
        capability: AICapability
    ) -> Bool {
        guard descriptor(for: provider).modelListEndpoint != nil else { return false }
        // xAI publishes separate capability catalogs. This client currently refreshes its
        // language catalog only; the voice and Imagine identifiers stay pinned to documented
        // defaults rather than being mixed together from the generic endpoint.
        if provider == .xAI, capability != .llm {
            return false
        }
        return descriptor(for: provider).supports(capability)
    }

    static func providers(for capability: AICapability) -> [AIProviderDescriptor] {
        descriptors.filter { $0.supports(capability) }
    }

    /// Voices that this build can present without claiming access to a provider/account-specific
    /// catalog. xAI and Soniox entries are the built-in voices published by their Voice APIs.
    static func voiceOptions(for provider: AIProviderID) -> [AIVoiceDescriptor] {
        switch provider {
        case .xAI:
            return [
                .init(id: "ara", displayName: "Ara"),
                .init(id: "eve", displayName: "Eve"),
                .init(id: "leo", displayName: "Leo"),
                .init(id: "rex", displayName: "Rex"),
                .init(id: "sal", displayName: "Sal"),
            ]
        case .openAI:
            return [.init(id: "alloy", displayName: "Alloy")]
        case .gemini:
            return [.init(id: "Kore", displayName: "Kore")]
        case .elevenLabs:
            return [.init(id: "JBFqnCBsd6RMkjVDRZzb", displayName: "Default voice")]
        case .soniox:
            return [
                .init(id: "Maya", displayName: "Maya"),
                .init(id: "Daniel", displayName: "Daniel"),
                .init(id: "Noah", displayName: "Noah"),
                .init(id: "Nina", displayName: "Nina"),
                .init(id: "Emma", displayName: "Emma"),
                .init(id: "Jack", displayName: "Jack"),
                .init(id: "Adrian", displayName: "Adrian"),
                .init(id: "Claire", displayName: "Claire"),
                .init(id: "Grace", displayName: "Grace"),
                .init(id: "Owen", displayName: "Owen"),
                .init(id: "Mina", displayName: "Mina"),
                .init(id: "Kenji", displayName: "Kenji"),
                .init(id: "Rafael", displayName: "Rafael"),
                .init(id: "Mateo", displayName: "Mateo"),
                .init(id: "Lucia", displayName: "Lucia"),
                .init(id: "Sofia", displayName: "Sofia"),
                .init(id: "Oliver", displayName: "Oliver"),
                .init(id: "Arthur", displayName: "Arthur"),
                .init(id: "Isla", displayName: "Isla"),
                .init(id: "Victoria", displayName: "Victoria"),
                .init(id: "Cooper", displayName: "Cooper"),
                .init(id: "Mason", displayName: "Mason"),
                .init(id: "Ruby", displayName: "Ruby"),
                .init(id: "Elise", displayName: "Elise"),
                .init(id: "Arjun", displayName: "Arjun"),
                .init(id: "Rohan", displayName: "Rohan"),
                .init(id: "Priya", displayName: "Priya"),
                .init(id: "Meera", displayName: "Meera"),
            ]
        case .openRouter:
            return [
                .init(id: "alloy", displayName: "Alloy"),
                .init(id: "echo", displayName: "Echo"),
                .init(id: "fable", displayName: "Fable"),
                .init(id: "onyx", displayName: "Onyx"),
                .init(id: "nova", displayName: "Nova"),
                .init(id: "shimmer", displayName: "Shimmer"),
            ]
        default:
            return []
        }
    }

    static func defaultVoice(for provider: AIProviderID) -> String? {
        switch provider {
        case .xAI: "eve"
        case .soniox: "Adrian"
        case .openRouter: "nova"
        default: voiceOptions(for: provider).first?.id
        }
    }

    static var credentialProviders: [AIProviderDescriptor] {
        descriptors.filter { $0.availability == .available && $0.credentialLabel != nil }
    }

    /// Runtime truth for Build 9. The broader `capabilities` set describes
    /// official vendor APIs and drives credential/model management; this set
    /// describes adapters that are actually connected to the app today.
    static func hasRuntimeAdapter(
        provider: AIProviderID,
        capability: AICapability
    ) -> Bool {
        switch (provider, capability) {
        case (.openAI, .llm), (.xAI, .llm), (.anthropic, .llm), (.gemini, .llm),
             (.openRouter, .llm),
             (.xAI, .webSearch), (.gemini, .webSearch),
             (.tavily, .webSearch), (.brave, .webSearch), (.exa, .webSearch),
             (.apple, .textToSpeech), (.apple, .speechToText),
             (.openAI, .textToSpeech), (.openAI, .speechToText),
             (.xAI, .textToSpeech), (.xAI, .speechToText),
             (.openRouter, .textToSpeech), (.openRouter, .speechToText),
             (.gemini, .textToSpeech),
             (.deepgram, .speechToText),
             (.elevenLabs, .textToSpeech), (.elevenLabs, .speechToText),
             (.soniox, .textToSpeech), (.soniox, .speechToText):
            return true
        default:
            return false
        }
    }

    /// Bounded cloud voice implementations used by the active composer audio paths.
    static func hasCloudVoiceServiceAdapter(
        provider: AIProviderID,
        capability: AICapability
    ) -> Bool {
        switch (provider, capability) {
        case (.openAI, .textToSpeech), (.openAI, .speechToText),
             (.xAI, .textToSpeech), (.xAI, .speechToText),
             (.openRouter, .textToSpeech), (.openRouter, .speechToText),
             (.gemini, .textToSpeech),
             (.deepgram, .speechToText),
             (.elevenLabs, .textToSpeech), (.elevenLabs, .speechToText),
             (.soniox, .textToSpeech), (.soniox, .speechToText):
            return true
        default:
            return false
        }
    }

    /// Runtime media truth for the current provider-neutral agent clients. OpenAI and xAI use
    /// the Responses content-part mapping; the current Anthropic and Gemini adapters are text-only.
    static func supportsAttachmentInput(provider: AIProviderID) -> Bool {
        provider == .openAI || provider == .xAI
    }

    static func configurationNote(
        provider: AIProviderID,
        capability: AICapability
    ) -> String? {
        switch (provider, capability) {
        case (.apple, .speechToText):
            return "Apple Dictation follows one selected locale. Automatic means this iPhone’s current language; choose English or Chinese here before speaking another language."
        case (.deepgram, .speechToText):
            return "Auto multilingual uses Nova-3 language detection and supports mixed Chinese and English speech."
        case (.xAI, .speechToText):
            return "Grok Transcribe — Batch sends one recording after Stop and costs $0.10 per audio hour. Grok Transcribe — Live text streams partial text while you speak and costs $0.20 per audio hour. Automatic detection covers exactly Arabic, Czech, Danish, Dutch, English, Filipino, French, German, Hindi, Indonesian, Italian, Japanese, Korean, Macedonian, Malay, Persian, Polish, Portuguese, Romanian, Russian, Spanish, Swedish, Thai, Turkish, and Vietnamese. Chinese is not supported; choose Deepgram for Chinese or mixed Chinese and English."
        case (.openAI, .videoGeneration):
            return "OpenAI currently lists Sora 2 as a legacy model. This build saves the preference only and does not submit generation requests."
        case (_, .imageGeneration), (_, .videoGeneration):
            return "This saves a model preference and key for a future generation workflow. This build does not yet send image or video generation requests."
        case (.openRouter, .llm):
            return "OpenRouter language models use its official stateless Responses API, currently marked beta by OpenRouter."
        case (.openRouter, .textToSpeech):
            return "OpenRouter uses its dedicated speech endpoint. Voice IDs are model-specific; the listed voices match the documented default OpenAI-routed model."
        case (.openRouter, .speechToText):
            return "OpenRouter uses its dedicated transcription endpoint. Live streaming is not enabled; OpenClam sends one bounded recording after you stop."
        default:
            return nil
        }
    }

    static func speechRecognitionLanguageOptions(
        for provider: AIProviderID
    ) -> [AISpeechRecognitionLanguageOption] {
        switch provider {
        case .apple:
            return [
                .init(id: "auto", displayName: "Device language (automatic)"),
                .init(id: "en", displayName: "English"),
                .init(id: "zh", displayName: "Chinese"),
            ]
        case .deepgram:
            return [
                .init(id: "multi", displayName: "Auto multilingual · Chinese + English"),
                .init(id: "en", displayName: "English"),
                .init(id: "zh", displayName: "Chinese"),
            ]
        case .xAI:
            return [
                .init(id: "auto", displayName: "Automatic · 25 languages, no Chinese"),
                .init(id: "ar", displayName: "Arabic"),
                .init(id: "cs", displayName: "Czech"),
                .init(id: "da", displayName: "Danish"),
                .init(id: "nl", displayName: "Dutch"),
                .init(id: "en", displayName: "English"),
                .init(id: "fil", displayName: "Filipino"),
                .init(id: "fr", displayName: "French"),
                .init(id: "de", displayName: "German"),
                .init(id: "hi", displayName: "Hindi"),
                .init(id: "id", displayName: "Indonesian"),
                .init(id: "it", displayName: "Italian"),
                .init(id: "ja", displayName: "Japanese"),
                .init(id: "ko", displayName: "Korean"),
                .init(id: "mk", displayName: "Macedonian"),
                .init(id: "ms", displayName: "Malay"),
                .init(id: "fa", displayName: "Persian"),
                .init(id: "pl", displayName: "Polish"),
                .init(id: "pt", displayName: "Portuguese"),
                .init(id: "ro", displayName: "Romanian"),
                .init(id: "ru", displayName: "Russian"),
                .init(id: "es", displayName: "Spanish"),
                .init(id: "sv", displayName: "Swedish"),
                .init(id: "th", displayName: "Thai"),
                .init(id: "tr", displayName: "Turkish"),
                .init(id: "vi", displayName: "Vietnamese"),
            ]
        case .openAI, .openRouter, .elevenLabs, .soniox:
            return [
                .init(id: "auto", displayName: "Automatic language detection"),
                .init(id: "en", displayName: "English"),
                .init(id: "zh", displayName: "Chinese"),
            ]
        default:
            return [.init(id: "auto", displayName: "Automatic")]
        }
    }

    static func modelDisplayName(
        for model: String,
        provider: AIProviderID,
        capability: AICapability
    ) -> String {
        guard provider == .xAI, capability == .speechToText else { return model }
        switch model {
        case xAIBatchSpeechToTextModel:
            return "Grok Transcribe — Batch (lower cost)"
        case xAILiveSpeechToTextModel:
            return "Grok Transcribe — Live text"
        default:
            return model
        }
    }

    static func usesRealtimeSpeechRecognition(_ selection: AIServiceSelection) -> Bool {
        let model = selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (selection.provider, model) {
        case (.soniox, sonioxRealtimeSpeechToTextModel),
             (.xAI, xAILiveSpeechToTextModel):
            return true
        default:
            return false
        }
    }

    static func defaultSpeechRecognitionLanguage(for provider: AIProviderID) -> String {
        provider == .deepgram ? "multi" : "auto"
    }

    static func speechRecognitionLanguageLabel(for selection: AIServiceSelection) -> String {
        let selected = selection.language
            ?? defaultSpeechRecognitionLanguage(for: selection.provider)
        return speechRecognitionLanguageOptions(for: selection.provider)
            .first(where: { $0.id == selected })?.displayName
            ?? selected
    }

    static func speechRecognitionRequestLanguage(
        for selection: AIServiceSelection,
        locale: Locale = .current
    ) -> String? {
        let selected = selection.language
            ?? defaultSpeechRecognitionLanguage(for: selection.provider)
        if selection.provider == .apple, selected == "auto" {
            return locale.identifier
        }
        if selection.provider == .deepgram, selected == "auto" {
            return "multi"
        }
        if selected == "auto" {
            return nil
        }
        return selected
    }

    /// Resolves Apple Dictation only within the requested language. Device locales can contain a
    /// region for which Speech has no recognizer (for example `en_CN`), even though the same
    /// language is supported as `en-US`. Prefer an exact locale, then the requested/default region,
    /// and never fall through to an unrelated language.
    static func resolvedAppleSpeechRecognitionLocaleIdentifier(
        requestedLanguageCode: String?,
        locale: Locale = .current,
        supportedLocaleIdentifiers: Set<String>
    ) -> String? {
        let trimmedRequest = requestedLanguageCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedIdentifier: String
        if let trimmedRequest, !trimmedRequest.isEmpty {
            requestedIdentifier = trimmedRequest
        } else {
            requestedIdentifier = locale.identifier
        }
        let requestedLocale = Locale(identifier: requestedIdentifier)
        guard let languageCode = requestedLocale.language.languageCode?.identifier.lowercased()
        else { return nil }

        let candidates = supportedLocaleIdentifiers.compactMap { identifier -> (String, Locale)? in
            let candidate = Locale(identifier: identifier)
            guard candidate.language.languageCode?.identifier.lowercased() == languageCode else {
                return nil
            }
            return (identifier, candidate)
        }
        guard !candidates.isEmpty else { return nil }

        func normalized(_ identifier: String) -> String {
            identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        }
        if let exact = candidates.filter({
            normalized($0.0) == normalized(requestedIdentifier)
        }).sorted(by: { $0.0 < $1.0 }).first {
            return exact.0
        }

        let requestedRegion = requestedLocale.region?.identifier.uppercased()
        let requestedScript = requestedLocale.language.script?.identifier.lowercased()
        let defaultLocale = Locale(
            identifier: Locale(identifier: languageCode).language.maximalIdentifier
        )
        let defaultRegion = defaultLocale.region?.identifier.uppercased()

        return candidates.sorted { lhs, rhs in
            func score(_ candidate: Locale) -> Int {
                var value = 0
                if let requestedRegion,
                   candidate.region?.identifier.uppercased() == requestedRegion {
                    value += 16
                }
                if let requestedScript,
                   candidate.language.script?.identifier.lowercased() == requestedScript {
                    value += 8
                }
                if let defaultRegion,
                   candidate.region?.identifier.uppercased() == defaultRegion {
                    value += 4
                }
                return value
            }
            let lhsScore = score(lhs.1)
            let rhsScore = score(rhs.1)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            let normalizedLHS = normalized(lhs.0)
            let normalizedRHS = normalized(rhs.0)
            if normalizedLHS != normalizedRHS { return normalizedLHS < normalizedRHS }
            return lhs.0 < rhs.0
        }.first?.0
    }

    static func provider(forResponsesEndpoint rawEndpoint: String) -> AIProviderID? {
        let normalized = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return descriptors.first(where: { $0.agentResponsesEndpoint?.absoluteString == normalized })?.id
    }
}

struct AIServiceSelection: Codable, Equatable, Sendable {
    var provider: AIProviderID
    var model: String
    var voice: String?
    var language: String?

    init(
        provider: AIProviderID,
        model: String,
        voice: String? = nil,
        language: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.voice = voice
        self.language = language
    }

    func validated(for capability: AICapability) throws -> Self {
        let descriptor = AIProviderRegistry.descriptor(for: provider)
        guard descriptor.supports(capability) else {
            throw AIProviderSettingsError.unsupportedCapability(provider, capability)
        }
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else { throw AIProviderSettingsError.missingModel }
        guard normalizedModel.count <= 128,
              !normalizedModel.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AIProviderSettingsError.invalidModel
        }

        if capability == .speechToText, provider == .soniox {
            guard [
                AIProviderRegistry.sonioxRealtimeSpeechToTextModel,
                AIProviderRegistry.sonioxBatchSpeechToTextModel,
            ].contains(normalizedModel) else {
                throw AIProviderSettingsError.invalidModel
            }
        }
        if capability == .speechToText, provider == .xAI {
            guard [
                AIProviderRegistry.xAIBatchSpeechToTextModel,
                AIProviderRegistry.xAILiveSpeechToTextModel,
            ].contains(normalizedModel) else {
                throw AIProviderSettingsError.invalidModel
            }
        }

        let normalizedVoice: String?
        if capability == .textToSpeech,
           let rawVoice = voice?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawVoice.isEmpty {
            guard rawVoice.count <= 128,
                  !rawVoice.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw AIProviderSettingsError.invalidVoice
            }
            normalizedVoice = rawVoice
        } else {
            normalizedVoice = nil
        }

        let normalizedLanguage: String?
        if capability == .speechToText,
           let rawLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawLanguage.isEmpty {
            let canonicalLanguage = provider == .deepgram && rawLanguage == "auto"
                ? "multi"
                : rawLanguage
            guard AIProviderRegistry.speechRecognitionLanguageOptions(for: provider)
                .contains(where: { $0.id == canonicalLanguage }) else {
                throw AIProviderSettingsError.unsupportedSpeechLanguage(
                    provider,
                    rawLanguage
                )
            }
            normalizedLanguage = canonicalLanguage
        } else {
            normalizedLanguage = nil
        }
        return .init(
            provider: provider,
            model: normalizedModel,
            voice: normalizedVoice,
            language: normalizedLanguage
        )
    }
}

struct AIProviderSettings: Codable, Equatable, Sendable {
    static let officialResponsesEndpoint = "https://api.openai.com/v1/responses"
    static let defaultModel = "gpt-5.6-luna"

    var llm: AIServiceSelection
    var textToSpeech: AIServiceSelection
    var speechToText: AIServiceSelection
    var imageGeneration: AIServiceSelection
    var videoGeneration: AIServiceSelection
    var webSearch: AIServiceSelection
    private var rejectedEndpoint: String?

    var endpoint: String {
        rejectedEndpoint
            ?? AIProviderRegistry.descriptor(for: llm.provider).agentResponsesEndpoint?.absoluteString
            ?? ""
    }

    var model: String {
        get { llm.model }
        set { llm.model = newValue }
    }

    init(
        llm: AIServiceSelection = .init(provider: .openAI, model: Self.defaultModel),
        textToSpeech: AIServiceSelection = .init(provider: .apple, model: "system-voice"),
        speechToText: AIServiceSelection = .init(provider: .apple, model: "apple-dictation"),
        imageGeneration: AIServiceSelection = .init(provider: .openAI, model: "gpt-image-2"),
        videoGeneration: AIServiceSelection = .init(provider: .xAI, model: "grok-imagine-video"),
        webSearch: AIServiceSelection = .init(provider: .xAI, model: "x_search")
    ) {
        self.llm = llm
        self.textToSpeech = textToSpeech
        self.speechToText = speechToText
        self.imageGeneration = imageGeneration
        self.videoGeneration = videoGeneration
        self.webSearch = webSearch
        rejectedEndpoint = nil
    }

    /// Compatibility initializer used by the isolated contact review boundary.
    /// Only pinned, officially registered Responses endpoints are accepted.
    init(endpoint: String = Self.officialResponsesEndpoint, model: String = Self.defaultModel) {
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = AIProviderRegistry.provider(forResponsesEndpoint: normalizedEndpoint) ?? .openAI
        self.init(llm: .init(provider: provider, model: model))
        if AIProviderRegistry.provider(forResponsesEndpoint: normalizedEndpoint) == nil {
            rejectedEndpoint = normalizedEndpoint
        }
    }

    func validated() throws -> Self {
        guard rejectedEndpoint == nil else { throw AIProviderSettingsError.invalidEndpoint }
        let validatedLLM = try llm.validated(for: .llm)
        return .init(
            llm: validatedLLM,
            textToSpeech: try textToSpeech.validated(for: .textToSpeech),
            speechToText: try speechToText.validated(for: .speechToText),
            imageGeneration: try imageGeneration.validated(for: .imageGeneration),
            videoGeneration: try videoGeneration.validated(for: .videoGeneration),
            webSearch: try webSearch.validated(for: .webSearch)
        )
    }

    func selection(for capability: AICapability) -> AIServiceSelection {
        switch capability {
        case .llm: llm
        case .textToSpeech: textToSpeech
        case .speechToText: speechToText
        case .imageGeneration: imageGeneration
        case .videoGeneration: videoGeneration
        case .webSearch: webSearch
        }
    }

    mutating func setSelection(_ selection: AIServiceSelection, for capability: AICapability) {
        switch capability {
        case .llm: llm = selection
        case .textToSpeech: textToSpeech = selection
        case .speechToText: speechToText = selection
        case .imageGeneration: imageGeneration = selection
        case .videoGeneration: videoGeneration = selection
        case .webSearch: webSearch = selection
        }
    }

    private enum CodingKeys: String, CodingKey {
        case llm, textToSpeech, speechToText, imageGeneration, videoGeneration, webSearch
        case endpoint, model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let llm = try container.decodeIfPresent(AIServiceSelection.self, forKey: .llm) {
            self.init(
                llm: llm,
                textToSpeech: try container.decodeIfPresent(
                    AIServiceSelection.self,
                    forKey: .textToSpeech
                ) ?? .init(provider: .apple, model: "system-voice"),
                speechToText: try container.decodeIfPresent(
                    AIServiceSelection.self,
                    forKey: .speechToText
                ) ?? .init(provider: .apple, model: "apple-dictation"),
                imageGeneration: try container.decodeIfPresent(
                    AIServiceSelection.self,
                    forKey: .imageGeneration
                ) ?? .init(provider: .openAI, model: "gpt-image-2"),
                videoGeneration: try container.decodeIfPresent(
                    AIServiceSelection.self,
                    forKey: .videoGeneration
                ) ?? .init(provider: .xAI, model: "grok-imagine-video"),
                webSearch: try container.decodeIfPresent(
                    AIServiceSelection.self,
                    forKey: .webSearch
                ) ?? .init(provider: .xAI, model: "x_search")
            )
        } else {
            let oldEndpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
                ?? Self.officialResponsesEndpoint
            let oldModel = try container.decodeIfPresent(String.self, forKey: .model)
                ?? Self.defaultModel
            self.init(endpoint: oldEndpoint, model: oldModel)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(llm, forKey: .llm)
        try container.encode(textToSpeech, forKey: .textToSpeech)
        try container.encode(speechToText, forKey: .speechToText)
        try container.encode(imageGeneration, forKey: .imageGeneration)
        try container.encode(videoGeneration, forKey: .videoGeneration)
        try container.encode(webSearch, forKey: .webSearch)
    }
}

enum AIProviderSettingsError: LocalizedError, Equatable {
    case invalidEndpoint
    case missingModel
    case invalidModel
    case invalidVoice
    case unsupportedSpeechLanguage(AIProviderID, String)
    case missingAPIKey
    case unsupportedCapability(AIProviderID, AICapability)
    case agentRuntimeUnavailable(AIProviderID)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Choose an official AI provider. Custom service addresses are not accepted."
        case .missingModel:
            return "Choose a model."
        case .invalidModel:
            return "Use a model name of 128 characters or fewer without spaces or control characters."
        case .invalidVoice:
            return "Choose a valid voice."
        case .unsupportedSpeechLanguage(let provider, let language):
            if provider == .xAI, language == "zh" {
                return "xAI Grok Transcribe does not support Chinese. Choose Deepgram Auto multilingual for Chinese or mixed Chinese and English."
            }
            return "\(AIProviderRegistry.descriptor(for: provider).displayName) does not support the selected speech-recognition language. Choose another language or provider."
        case .missingAPIKey:
            return "Paste an access key, or save one before testing the connection."
        case .unsupportedCapability(let provider, let capability):
            return "\(AIProviderRegistry.descriptor(for: provider).displayName) does not provide \(capability.displayName.lowercased()) through a supported API."
        case .agentRuntimeUnavailable(let provider):
            return "\(AIProviderRegistry.descriptor(for: provider).displayName) credentials and models can be managed here, but its typed iPhone-agent adapter is not available in this build."
        }
    }
}

/// A deliberately write-only settings boundary. It can report whether a key
/// exists and use it for bounded provider operations, but cannot reveal it.
protocol AISettingsCredentialStoring: Sendable {
    func containsAPIKey() async throws -> Bool
    func saveAPIKey(_ apiKey: String) async throws
    func removeAPIKey() async throws

    func containsCredential(for provider: AIProviderID) async throws -> Bool
    func validateAndSaveCredential(_ credential: String, for provider: AIProviderID) async throws
    func removeCredential(for provider: AIProviderID) async throws
    func refreshModels(
        for provider: AIProviderID,
        capability: AICapability
    ) async throws -> [String]
}

extension AISettingsCredentialStoring {
    func containsCredential(for provider: AIProviderID) async throws -> Bool {
        guard provider == .openAI else { return false }
        return try await containsAPIKey()
    }

    func validateAndSaveCredential(_ credential: String, for provider: AIProviderID) async throws {
        guard provider == .openAI else {
            throw AIProviderSettingsError.unsupportedCapability(provider, .llm)
        }
        try await saveAPIKey(credential)
    }

    func removeCredential(for provider: AIProviderID) async throws {
        guard provider == .openAI else { return }
        try await removeAPIKey()
    }

    func refreshModels(for provider: AIProviderID) async throws -> [String] {
        guard let capability = AIProviderRegistry.preferredModelCatalogCapability(for: provider) else {
            throw AIProviderSettingsError.agentRuntimeUnavailable(provider)
        }
        return try await refreshModels(for: provider, capability: capability)
    }

    func refreshModels(
        for provider: AIProviderID,
        capability: AICapability
    ) async throws -> [String] {
        AIProviderRegistry.descriptor(for: provider).defaultModels[capability] ?? []
    }
}

typealias AISettingsConnectionTesting = @Sendable (
    _ settings: AIProviderSettings,
    _ oneUseAPIKey: String?
) async throws -> Void
