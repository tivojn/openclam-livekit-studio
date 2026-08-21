import Foundation
import XCTest
@testable import OpenClamLiveKit

final class AIProviderSettingsTests: XCTestCase {
    func testDefaultsUseOpenAILunaAppleAudioXSearchAndDirectMediaProviders() throws {
        let settings = try AIProviderSettings().validated()

        XCTAssertEqual(settings.endpoint, "https://api.openai.com/v1/responses")
        XCTAssertEqual(settings.llm, .init(provider: .openAI, model: "gpt-5.6-luna"))
        XCTAssertEqual(settings.textToSpeech, .init(provider: .apple, model: "system-voice"))
        XCTAssertEqual(settings.speechToText, .init(provider: .apple, model: "apple-dictation"))
        XCTAssertEqual(settings.imageGeneration, .init(provider: .openAI, model: "gpt-image-2"))
        XCTAssertEqual(settings.videoGeneration, .init(provider: .xAI, model: "grok-imagine-video"))
        XCTAssertEqual(settings.webSearch, .init(provider: .xAI, model: "x_search"))
    }

    func testAppleNativeAudioCapabilitiesMatchRuntimeAdapters() throws {
        let descriptor = AIProviderRegistry.descriptor(for: .apple)
        let selections: [(AICapability, String)] = [
            (.textToSpeech, "system-voice"),
            (.speechToText, "apple-dictation"),
        ]

        XCTAssertEqual(descriptor.capabilities, [.textToSpeech, .speechToText])
        for (capability, model) in selections {
            XCTAssertTrue(descriptor.supports(capability))
            XCTAssertTrue(
                AIProviderRegistry.providers(for: capability).contains { $0.id == .apple }
            )
            XCTAssertTrue(
                AIProviderRegistry.hasRuntimeAdapter(
                    provider: .apple,
                    capability: capability
                )
            )
            XCTAssertNoThrow(
                try AIServiceSelection(provider: .apple, model: model)
                    .validated(for: capability)
            )
        }
    }

    @MainActor
    func testDefaultAppleAudioDoesNotBlockLanguageClientConstruction() throws {
        let suiteName = "AIProviderSettingsTests.apple-audio.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: "test.apple-audio",
            providerVault: InMemoryProviderCredentialVault()
        )

        XCTAssertEqual(configuration.settings.speechToText.provider, .apple)
        XCTAssertEqual(configuration.settings.textToSpeech.provider, .apple)
        XCTAssertNoThrow(try configuration.makeClient())
    }

    func testMediaProviderRegistryIsHonestAboutConfigurationOnlyFoundation() {
        let expectedProviders: Set<AIProviderID> = [.openAI, .gemini, .xAI, .kieAI, .openRouter]

        XCTAssertEqual(
            Set(AIProviderRegistry.providers(for: .imageGeneration).map(\.id)),
            expectedProviders
        )
        XCTAssertEqual(
            Set(AIProviderRegistry.providers(for: .videoGeneration).map(\.id)),
            expectedProviders
        )
        for provider in expectedProviders {
            XCTAssertFalse(
                AIProviderRegistry.hasRuntimeAdapter(
                    provider: provider,
                    capability: .imageGeneration
                )
            )
            XCTAssertFalse(
                AIProviderRegistry.hasRuntimeAdapter(
                    provider: provider,
                    capability: .videoGeneration
                )
            )
            XCTAssertNotNil(
                AIProviderRegistry.configurationNote(
                    provider: provider,
                    capability: .imageGeneration
                )
            )
        }
    }

    func testOpenRouterAdvertisesOnlyItsConnectedAndDiscoverableCapabilities() {
        let descriptor = AIProviderRegistry.descriptor(for: .openRouter)

        XCTAssertEqual(
            descriptor.capabilities,
            [.llm, .textToSpeech, .speechToText, .imageGeneration, .videoGeneration]
        )
        XCTAssertEqual(
            descriptor.agentResponsesEndpoint?.absoluteString,
            "https://openrouter.ai/api/v1/responses"
        )
        XCTAssertEqual(
            descriptor.modelListEndpoint?.absoluteString,
            "https://openrouter.ai/api/v1/models"
        )
        XCTAssertEqual(descriptor.defaultModels[.llm], ["openai/gpt-4o"])
        XCTAssertEqual(
            descriptor.defaultModels[.textToSpeech],
            ["openai/gpt-4o-mini-tts-2025-12-15"]
        )
        XCTAssertEqual(
            descriptor.defaultModels[.speechToText],
            ["openai/whisper-large-v3"]
        )
        XCTAssertEqual(
            descriptor.defaultModels[.imageGeneration],
            ["bytedance-seed/seedream-4.5"]
        )
        XCTAssertEqual(
            descriptor.defaultModels[.videoGeneration],
            ["x-ai/grok-imagine-video"]
        )
        XCTAssertEqual(AIProviderRegistry.defaultVoice(for: .openRouter), "nova")
        for capability in [AICapability.llm, .textToSpeech, .speechToText] {
            XCTAssertTrue(
                AIProviderRegistry.hasRuntimeAdapter(
                    provider: .openRouter,
                    capability: capability
                )
            )
            XCTAssertTrue(
                AIProviderRegistry.supportsModelRefresh(
                    provider: .openRouter,
                    capability: capability
                )
            )
        }
        for capability in [AICapability.imageGeneration, .videoGeneration] {
            XCTAssertFalse(
                AIProviderRegistry.hasRuntimeAdapter(
                    provider: .openRouter,
                    capability: capability
                )
            )
            XCTAssertTrue(
                AIProviderRegistry.supportsModelRefresh(
                    provider: .openRouter,
                    capability: capability
                )
            )
        }
    }

    func testLegacySettingsDecodeAddsDirectMediaDefaults() throws {
        let legacy = Data(
            #"{"llm":{"provider":"openai","model":"gpt-5.6-luna"},"textToSpeech":{"provider":"apple","model":"system-voice"},"speechToText":{"provider":"apple","model":"apple-dictation"},"webSearch":{"provider":"xai","model":"x_search"}}"#.utf8
        )

        let decoded = try JSONDecoder().decode(AIProviderSettings.self, from: legacy)

        XCTAssertEqual(decoded.imageGeneration, .init(provider: .openAI, model: "gpt-image-2"))
        XCTAssertEqual(decoded.videoGeneration, .init(provider: .xAI, model: "grok-imagine-video"))
    }

    func testXAIBuiltInVoicesHaveEveAsDefault() {
        XCTAssertEqual(
            AIProviderRegistry.voiceOptions(for: .xAI),
            [
                .init(id: "ara", displayName: "Ara"),
                .init(id: "eve", displayName: "Eve"),
                .init(id: "leo", displayName: "Leo"),
                .init(id: "rex", displayName: "Rex"),
                .init(id: "sal", displayName: "Sal"),
            ]
        )
        XCTAssertEqual(AIProviderRegistry.defaultVoice(for: .xAI), "eve")
    }

    func testSonioxBuiltInVoicesAreSelectableWithoutChangingLegacyDefault() {
        let voices = AIProviderRegistry.voiceOptions(for: .soniox)

        XCTAssertEqual(voices.count, 28)
        XCTAssertTrue(voices.contains(.init(id: "Maya", displayName: "Maya")))
        XCTAssertTrue(voices.contains(.init(id: "Meera", displayName: "Meera")))
        XCTAssertEqual(AIProviderRegistry.defaultVoice(for: .soniox), "Adrian")
    }

    func testVoiceSelectionPersistsAndLegacySelectionWithoutVoiceStillDecodes() throws {
        let selected = AIServiceSelection(
            provider: .xAI,
            model: "xai-tts",
            voice: "sal"
        )
        let roundTrip = try JSONDecoder().decode(
            AIServiceSelection.self,
            from: JSONEncoder().encode(selected)
        )
        XCTAssertEqual(roundTrip, selected)

        let legacy = try JSONDecoder().decode(
            AIServiceSelection.self,
            from: Data(#"{"provider":"xai","model":"xai-tts"}"#.utf8)
        )
        XCTAssertNil(legacy.voice)
        XCTAssertEqual(
            AIProviderRegistry.defaultVoice(for: legacy.provider),
            "eve"
        )
    }

    func testSpeechLanguageSelectionPersistsAndLegacySelectionDefaultsSafely() throws {
        let selected = AIServiceSelection(
            provider: .deepgram,
            model: "nova-3",
            language: "multi"
        )
        let roundTrip = try JSONDecoder().decode(
            AIServiceSelection.self,
            from: JSONEncoder().encode(selected)
        )
        XCTAssertEqual(roundTrip, selected)

        let legacy = try JSONDecoder().decode(
            AIServiceSelection.self,
            from: Data(#"{"provider":"deepgram","model":"nova-3"}"#.utf8)
        )
        XCTAssertNil(legacy.language)
        XCTAssertEqual(
            AIProviderRegistry.speechRecognitionRequestLanguage(for: legacy),
            "multi"
        )
        XCTAssertEqual(
            try AIServiceSelection(
                provider: .deepgram,
                model: "nova-3",
                language: "auto"
            ).validated(for: .speechToText).language,
            "multi"
        )
        XCTAssertEqual(
            AIProviderRegistry.speechRecognitionRequestLanguage(
                for: .init(
                    provider: .deepgram,
                    model: "nova-3",
                    language: "auto"
                )
            ),
            "multi"
        )
    }

    func testSpeechLanguageCatalogAndResolverDoNotClaimXAIChineseSupport() throws {
        let xAIOptions = AIProviderRegistry.speechRecognitionLanguageOptions(for: .xAI)
        XCTAssertEqual(xAIOptions.first?.id, "auto")
        XCTAssertEqual(xAIOptions.count, 26)
        XCTAssertFalse(xAIOptions.contains(where: { $0.id == "zh" }))
        XCTAssertNil(
            AIProviderRegistry.speechRecognitionRequestLanguage(
                for: .init(
                    provider: .xAI,
                    model: "grok-transcribe",
                    language: "auto"
                )
            )
        )
        XCTAssertEqual(
            AIProviderRegistry.speechRecognitionRequestLanguage(
                for: .init(
                    provider: .xAI,
                    model: "grok-transcribe",
                    language: "fr"
                )
            ),
            "fr"
        )
        XCTAssertThrowsError(
            try AIServiceSelection(
                provider: .xAI,
                model: "grok-transcribe",
                language: "zh"
            ).validated(for: .speechToText)
        ) { error in
            XCTAssertEqual(
                error as? AIProviderSettingsError,
                .unsupportedSpeechLanguage(.xAI, "zh")
            )
        }
    }

    func testSharedSpeechLanguageResolverCoversBothPTTRequestShapes() {
        let deepgram = AIServiceSelection(
            provider: .deepgram,
            model: "nova-3",
            language: nil
        )
        XCTAssertEqual(
            AIProviderRegistry.speechRecognitionRequestLanguage(for: deepgram),
            "multi"
        )

        let apple = AIServiceSelection(
            provider: .apple,
            model: "apple-dictation",
            language: "auto"
        )
        XCTAssertEqual(
            AIProviderRegistry.speechRecognitionRequestLanguage(
                for: apple,
                locale: Locale(identifier: "zh-Hans-CN")
            ),
            "zh-Hans-CN"
        )
        XCTAssertEqual(
            AIProviderRegistry.speechRecognitionRequestLanguage(
                for: .init(
                    provider: .apple,
                    model: "apple-dictation",
                    language: "zh"
                ),
                locale: Locale(identifier: "en-US")
            ),
            "zh"
        )
    }

    func testAppleSpeechLocaleResolverFallsBackWithinRequestedLanguageOnly() {
        let supported: Set<String> = [
            "en-AE", "en-GB", "en-US", "fr-FR", "zh-CN", "zh-HK", "zh-TW",
        ]

        XCTAssertEqual(
            AIProviderRegistry.resolvedAppleSpeechRecognitionLocaleIdentifier(
                requestedLanguageCode: "en_CN",
                supportedLocaleIdentifiers: supported
            ),
            "en-US"
        )
        XCTAssertEqual(
            AIProviderRegistry.resolvedAppleSpeechRecognitionLocaleIdentifier(
                requestedLanguageCode: "zh_Hans_CN",
                supportedLocaleIdentifiers: supported
            ),
            "zh-CN"
        )
        XCTAssertEqual(
            AIProviderRegistry.resolvedAppleSpeechRecognitionLocaleIdentifier(
                requestedLanguageCode: "en",
                supportedLocaleIdentifiers: supported
            ),
            "en-US"
        )
        XCTAssertEqual(
            AIProviderRegistry.resolvedAppleSpeechRecognitionLocaleIdentifier(
                requestedLanguageCode: "zh",
                supportedLocaleIdentifiers: supported
            ),
            "zh-CN"
        )
        XCTAssertEqual(
            AIProviderRegistry.resolvedAppleSpeechRecognitionLocaleIdentifier(
                requestedLanguageCode: "zh_HK",
                supportedLocaleIdentifiers: supported
            ),
            "zh-HK"
        )
        XCTAssertEqual(
            AIProviderRegistry.resolvedAppleSpeechRecognitionLocaleIdentifier(
                requestedLanguageCode: "en-GB",
                supportedLocaleIdentifiers: supported
            ),
            "en-GB"
        )
        XCTAssertNil(
            AIProviderRegistry.resolvedAppleSpeechRecognitionLocaleIdentifier(
                requestedLanguageCode: "ja_JP",
                supportedLocaleIdentifiers: supported
            )
        )
    }

    func testSonioxDefaultsToRealtimeAndKeepsAsyncAsExplicitFallback() throws {
        XCTAssertEqual(
            AIProviderRegistry.descriptor(for: .soniox).defaultModels[.speechToText],
            ["stt-rt-v5", "stt-async-v5"]
        )
        let realtime = try AIServiceSelection(
            provider: .soniox,
            model: "stt-rt-v5"
        ).validated(for: .speechToText)
        XCTAssertEqual(realtime.model, "stt-rt-v5")
        let fallback = try AIServiceSelection(
            provider: .soniox,
            model: "stt-async-v5"
        ).validated(for: .speechToText)
        XCTAssertEqual(fallback.model, "stt-async-v5")
        XCTAssertEqual(
            AIProviderRegistry.preferredModelCatalogCapability(for: .soniox),
            .speechToText
        )
        XCTAssertThrowsError(
            try AIServiceSelection(provider: .soniox, model: "stt-legacy-v4")
                .validated(for: .speechToText)
        )
    }

    func testXAIBatchStaysDefaultAndLiveModeIsExplicitlySelectable() throws {
        let batch = AIServiceSelection(
            provider: .xAI,
            model: AIProviderRegistry.xAIBatchSpeechToTextModel
        )
        let live = AIServiceSelection(
            provider: .xAI,
            model: AIProviderRegistry.xAILiveSpeechToTextModel
        )

        XCTAssertEqual(
            AIProviderRegistry.descriptor(for: .xAI).defaultModels[.speechToText],
            [
                AIProviderRegistry.xAIBatchSpeechToTextModel,
                AIProviderRegistry.xAILiveSpeechToTextModel,
            ]
        )
        XCTAssertEqual(
            AIProviderRegistry.modelDisplayName(
                for: batch.model,
                provider: .xAI,
                capability: .speechToText
            ),
            "Grok Transcribe — Batch (lower cost)"
        )
        XCTAssertEqual(
            AIProviderRegistry.modelDisplayName(
                for: live.model,
                provider: .xAI,
                capability: .speechToText
            ),
            "Grok Transcribe — Live text"
        )
        XCTAssertNoThrow(try batch.validated(for: .speechToText))
        XCTAssertNoThrow(try live.validated(for: .speechToText))
        XCTAssertThrowsError(
            try AIServiceSelection(provider: .xAI, model: "grok-transcribe-unknown")
                .validated(for: .speechToText)
        ) { error in
            XCTAssertEqual(error as? AIProviderSettingsError, .invalidModel)
        }

        XCTAssertFalse(AIProviderRegistry.usesRealtimeSpeechRecognition(batch))
        XCTAssertTrue(AIProviderRegistry.usesRealtimeSpeechRecognition(live))
        XCTAssertTrue(
            AIProviderRegistry.usesRealtimeSpeechRecognition(
                .init(
                    provider: .soniox,
                    model: AIProviderRegistry.sonioxRealtimeSpeechToTextModel
                )
            )
        )
        XCTAssertFalse(
            AIProviderRegistry.usesRealtimeSpeechRecognition(
                .init(
                    provider: .soniox,
                    model: AIProviderRegistry.sonioxBatchSpeechToTextModel
                )
            )
        )

        let note = try XCTUnwrap(
            AIProviderRegistry.configurationNote(
                provider: .xAI,
                capability: .speechToText
            )
        )
        XCTAssertTrue(note.contains("$0.10"))
        XCTAssertTrue(note.contains("$0.20"))
        XCTAssertTrue(note.contains("Live text"))
    }

    @MainActor
    func testXAISpeechFactoriesKeepBatchAndRealtimeRoutesSeparate() throws {
        let batch = AIServiceSelection(
            provider: .xAI,
            model: AIProviderRegistry.xAIBatchSpeechToTextModel
        )
        let live = AIServiceSelection(
            provider: .xAI,
            model: AIProviderRegistry.xAILiveSpeechToTextModel
        )
        let suiteName = "AIProviderSettingsTests.xai-stt-modes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: "test.xai-stt-modes",
            providerVault: InMemoryProviderCredentialVault()
        )
        XCTAssertEqual(
            configuration.preferredModel(for: .speechToText, provider: .xAI),
            AIProviderRegistry.xAIBatchSpeechToTextModel
        )

        configuration.settings.speechToText = batch
        XCTAssertNoThrow(try configuration.makeCloudSpeechToTextService())
        XCTAssertThrowsError(try configuration.makeRealtimeSpeechToTextService())

        configuration.settings.speechToText = live
        XCTAssertThrowsError(try configuration.makeCloudSpeechToTextService())
        XCTAssertNoThrow(try configuration.makeRealtimeSpeechToTextService())
    }

    func testCloudSpeechRequestUsesSelectedXAIVoiceAndAutomaticLanguage() throws {
        let shared = try CloudSpeechSynthesisRequestResolver.resolve(
            text: "Hello 世界",
            selection: .init(provider: .xAI, model: "xai-tts", voice: "sal"),
            localeLanguageCode: "en"
        )
        let selected = try ConversationModel.cloudSpeechSynthesisRequest(
            text: "Hello 世界",
            selection: .init(provider: .xAI, model: "xai-tts", voice: "sal"),
            localeLanguageCode: "en"
        )
        XCTAssertEqual(selected, shared)
        XCTAssertEqual(selected.voice, "sal")
        XCTAssertNil(selected.languageCode)

        let migratedDefault = try ConversationModel.cloudSpeechSynthesisRequest(
            text: "Hello",
            selection: .init(provider: .xAI, model: "xai-tts"),
            localeLanguageCode: "en"
        )
        XCTAssertEqual(migratedDefault.voice, "eve")
        XCTAssertNil(migratedDefault.languageCode)

        let openAI = try CloudSpeechSynthesisRequestResolver.resolve(
            text: "Hello",
            selection: .init(provider: .openAI, model: "tts-1", voice: "alloy"),
            localeLanguageCode: "en"
        )
        XCTAssertEqual(openAI.languageCode, "en")
    }

    func testValidationTrimsModelsAndKeepsOfficialEndpoint() throws {
        let settings = try AIProviderSettings(
            endpoint: "  https://api.x.ai/v1/responses  ",
            model: "  grok-4.5  "
        ).validated()

        XCTAssertEqual(settings.endpoint, "https://api.x.ai/v1/responses")
        XCTAssertEqual(settings.llm.provider, .xAI)
        XCTAssertEqual(settings.model, "grok-4.5")
    }

    func testValidationRejectsCustomOrInsecureEndpoint() {
        for endpoint in ["http://example.com/v1/responses", "https://example.com/v1/responses"] {
            XCTAssertThrowsError(try AIProviderSettings(endpoint: endpoint).validated()) { error in
                XCTAssertEqual(error as? AIProviderSettingsError, .invalidEndpoint)
            }
        }
    }

    func testValidationRequiresValidCapabilityModel() {
        XCTAssertThrowsError(
            try AIProviderSettings(llm: .init(provider: .openAI, model: "   ")).validated()
        ) { error in
            XCTAssertEqual(error as? AIProviderSettingsError, .missingModel)
        }
        XCTAssertThrowsError(
            try AIServiceSelection(provider: .anthropic, model: "claude-sonnet-5")
                .validated(for: .textToSpeech)
        ) { error in
            XCTAssertEqual(
                error as? AIProviderSettingsError,
                .unsupportedCapability(.anthropic, .textToSpeech)
            )
        }
    }

    func testRegistryDoesNotAdvertiseUnsupportedVoiceCombinations() {
        XCTAssertTrue(AIProviderRegistry.descriptor(for: .xAI).supports(.textToSpeech))
        XCTAssertTrue(AIProviderRegistry.descriptor(for: .xAI).supports(.speechToText))
        XCTAssertFalse(AIProviderRegistry.descriptor(for: .gemini).supports(.speechToText))
        XCTAssertFalse(AIProviderRegistry.descriptor(for: .anthropic).supports(.textToSpeech))
        XCTAssertTrue(AIProviderRegistry.descriptor(for: .elevenLabs).supports(.speechToText))
        XCTAssertTrue(AIProviderRegistry.descriptor(for: .soniox).supports(.textToSpeech))
    }

    func testRuntimeRegistryIncludesTypedLLMAdaptersAndOnlyConnectedSearch() {
        for provider in [AIProviderID.openAI, .xAI, .anthropic, .gemini, .openRouter] {
            XCTAssertTrue(AIProviderRegistry.hasRuntimeAdapter(provider: provider, capability: .llm))
        }
        XCTAssertTrue(AIProviderRegistry.hasRuntimeAdapter(provider: .xAI, capability: .webSearch))
        XCTAssertTrue(AIProviderRegistry.hasRuntimeAdapter(provider: .tavily, capability: .webSearch))
        XCTAssertTrue(AIProviderRegistry.hasRuntimeAdapter(provider: .brave, capability: .webSearch))
        XCTAssertTrue(AIProviderRegistry.hasRuntimeAdapter(provider: .exa, capability: .webSearch))
        XCTAssertTrue(AIProviderRegistry.hasRuntimeAdapter(provider: .gemini, capability: .webSearch))
        XCTAssertTrue(AIProviderRegistry.hasCloudVoiceServiceAdapter(provider: .openAI, capability: .textToSpeech))
        XCTAssertTrue(AIProviderRegistry.hasCloudVoiceServiceAdapter(provider: .openAI, capability: .speechToText))
        XCTAssertTrue(AIProviderRegistry.hasCloudVoiceServiceAdapter(provider: .gemini, capability: .textToSpeech))
        XCTAssertFalse(AIProviderRegistry.hasCloudVoiceServiceAdapter(provider: .gemini, capability: .speechToText))
        XCTAssertTrue(AIProviderRegistry.hasCloudVoiceServiceAdapter(provider: .elevenLabs, capability: .textToSpeech))
        XCTAssertTrue(AIProviderRegistry.hasCloudVoiceServiceAdapter(provider: .elevenLabs, capability: .speechToText))
        XCTAssertTrue(AIProviderRegistry.hasCloudVoiceServiceAdapter(provider: .soniox, capability: .textToSpeech))
        XCTAssertTrue(AIProviderRegistry.hasCloudVoiceServiceAdapter(provider: .soniox, capability: .speechToText))
        XCTAssertTrue(AIProviderRegistry.hasCloudVoiceServiceAdapter(provider: .xAI, capability: .textToSpeech))
        XCTAssertTrue(AIProviderRegistry.hasCloudVoiceServiceAdapter(provider: .xAI, capability: .speechToText))
        XCTAssertTrue(AIProviderRegistry.hasCloudVoiceServiceAdapter(provider: .openRouter, capability: .textToSpeech))
        XCTAssertTrue(AIProviderRegistry.hasCloudVoiceServiceAdapter(provider: .openRouter, capability: .speechToText))
        XCTAssertTrue(AIProviderRegistry.hasRuntimeAdapter(provider: .deepgram, capability: .speechToText))
        XCTAssertTrue(AIProviderRegistry.hasCloudVoiceServiceAdapter(provider: .deepgram, capability: .speechToText))
    }

    func testMediaInputIsOfferedOnlyForAdaptersThatEncodeContentParts() {
        XCTAssertTrue(AIProviderRegistry.supportsAttachmentInput(provider: .openAI))
        XCTAssertTrue(AIProviderRegistry.supportsAttachmentInput(provider: .xAI))
        XCTAssertFalse(AIProviderRegistry.supportsAttachmentInput(provider: .anthropic))
        XCTAssertFalse(AIProviderRegistry.supportsAttachmentInput(provider: .gemini))
    }

    func testRetiredSearchServicesCannotBeSelected() {
        XCTAssertEqual(AIProviderRegistry.descriptor(for: .bing).availability, .retired)
        XCTAssertEqual(
            AIProviderRegistry.descriptor(for: .googleCustomSearch).availability,
            .legacyOnly
        )
        XCTAssertFalse(AIProviderRegistry.providers(for: .webSearch).contains { $0.id == .bing })
        XCTAssertFalse(AIProviderRegistry.providers(for: .webSearch).contains { $0.id == .googleCustomSearch })
    }

    @MainActor
    func testConfigurationPersistsSelectionsWithoutCredentials() throws {
        let suiteName = "AIProviderSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vault = InMemoryProviderCredentialVault()

        let first = AIConfigurationModel(
            defaults: defaults,
            storageKey: "test.settings",
            providerVault: vault
        )
        first.settings = AIProviderSettings(
            llm: .init(provider: .xAI, model: "grok-4.5"),
            textToSpeech: .init(provider: .soniox, model: "tts-rt-v1"),
            speechToText: .init(provider: .elevenLabs, model: "scribe_v2"),
            webSearch: .init(provider: .tavily, model: "tavily-search")
        )

        let restored = AIConfigurationModel(
            defaults: defaults,
            storageKey: "test.settings",
            providerVault: vault
        )
        XCTAssertEqual(restored.settings, first.settings)
        XCTAssertNil(try vault.loadCredential(for: .xAI))
    }

    @MainActor
    func testConfigurationCommitsOnlyChangedCapabilityAndUsesProviderDefaultModel() throws {
        let suiteName = "AIProviderSettingsTests.single-capability.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: "test.single-capability",
            providerVault: InMemoryProviderCredentialVault()
        )
        configuration.settings.textToSpeech = .init(
            provider: .anthropic,
            model: "not-a-tts-model"
        )

        let saved = try configuration.updateSelection(
            .init(provider: .xAI, model: "x_search"),
            for: .webSearch
        )

        XCTAssertEqual(saved, .init(provider: .xAI, model: "x_search"))
        XCTAssertEqual(configuration.settings.webSearch, saved)
        XCTAssertEqual(configuration.settings.textToSpeech.provider, .anthropic)
        XCTAssertEqual(
            configuration.preferredModel(for: .llm, provider: .openAI),
            "gpt-5.6-luna"
        )
    }

    @MainActor
    func testConfigurationPersistsSelectedXAIVoice() throws {
        let suiteName = "AIProviderSettingsTests.voice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AIConfigurationModel(
            defaults: defaults,
            storageKey: "test.voice",
            providerVault: InMemoryProviderCredentialVault()
        )
        try first.updateSelection(
            .init(provider: .xAI, model: "xai-tts", voice: "rex"),
            for: .textToSpeech
        )

        let restored = AIConfigurationModel(
            defaults: defaults,
            storageKey: "test.voice",
            providerVault: InMemoryProviderCredentialVault()
        )
        XCTAssertEqual(restored.settings.textToSpeech.voice, "rex")
    }

    @MainActor
    func testVoicePreviewBoundaryDoesNotPersistItsDraftSelection() async throws {
        let suiteName = "AIProviderSettingsTests.preview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "test.preview"
        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: storageKey,
            providerVault: InMemoryProviderCredentialVault()
        )
        try configuration.updateSelection(
            .init(provider: .xAI, model: "xai-tts", voice: "rex"),
            for: .textToSpeech
        )
        let savedBeforePreview = configuration.settings

        do {
            _ = try await configuration.synthesizeVoicePreview(
                selection: .init(provider: .apple, model: "system-voice"),
                text: "A bounded preview"
            )
            XCTFail("Expected the cloud preview boundary to reject Apple system voice")
        } catch {
            XCTAssertEqual(
                error as? AIProviderSettingsError,
                .agentRuntimeUnavailable(.apple)
            )
        }

        XCTAssertEqual(configuration.settings, savedBeforePreview)
        let restored = AIConfigurationModel(
            defaults: defaults,
            storageKey: storageKey,
            providerVault: InMemoryProviderCredentialVault()
        )
        XCTAssertEqual(restored.settings, savedBeforePreview)
    }

    @MainActor
    func testCapabilitySpecificRefreshedModelsPersistAcrossConfigurationRecreation() async throws {
        let suiteName = "AIProviderSettingsTests.models.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vault = InMemoryProviderCredentialVault()
        try vault.saveCredential("soniox-key", for: .soniox)

        let first = AIConfigurationModel(
            defaults: defaults,
            storageKey: "test.models",
            providerVault: vault,
            providerClient: ProviderAPIClient(
                transport: StaticProviderTransport(
                    body: #"{"models":[{"id":"tts-custom-v2"}]}"#
                )
            )
        )
        let refreshed = try await first.refreshModels(
            for: .soniox,
            capability: .textToSpeech
        )
        XCTAssertTrue(refreshed.contains("tts-custom-v2"))
        XCTAssertFalse(first.models(for: .speechToText, provider: .soniox).contains("tts-custom-v2"))

        let restored = AIConfigurationModel(
            defaults: defaults,
            storageKey: "test.models",
            providerVault: vault,
            providerClient: ProviderAPIClient(transport: RejectingProviderTransport())
        )
        XCTAssertTrue(
            restored.models(for: .textToSpeech, provider: .soniox).contains("tts-custom-v2")
        )
    }

    func testInMemoryVaultIsProviderScopedAndWriteOnlyBridgeReportsExistence() async throws {
        let vault = InMemoryProviderCredentialVault()
        let bridge = AgentSettingsCredentialBridge(
            vault: vault,
            providerClient: ProviderAPIClient(transport: RejectingProviderTransport())
        )
        try vault.saveCredential("key-openai", for: .openAI)
        try vault.saveCredential("key-xai", for: .xAI)

        let containsOpenAI = try await bridge.containsCredential(for: .openAI)
        let containsXAI = try await bridge.containsCredential(for: .xAI)
        XCTAssertTrue(containsOpenAI)
        XCTAssertTrue(containsXAI)
        XCTAssertEqual(try vault.loadCredential(for: .openAI), "key-openai")
        XCTAssertEqual(try vault.loadCredential(for: .xAI), "key-xai")

        try await bridge.removeCredential(for: .xAI)
        let containsRemovedXAI = try await bridge.containsCredential(for: .xAI)
        let stillContainsOpenAI = try await bridge.containsCredential(for: .openAI)
        XCTAssertFalse(containsRemovedXAI)
        XCTAssertTrue(stillContainsOpenAI)
    }
}

private struct RejectingProviderTransport: ProviderAPITransport {
    func send(_ request: URLRequest) async throws -> OpenAITransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}

private struct StaticProviderTransport: ProviderAPITransport {
    let body: String

    func send(_ request: URLRequest) async throws -> OpenAITransportResponse {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return .init(data: Data(body.utf8), response: response)
    }
}
