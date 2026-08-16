import XCTest
@testable import OpenClamLiveKit

@MainActor
final class AvatarAgentProfileTests: XCTestCase {
    func testDefaultPackInheritsSharedModelAndVoice() {
        let configuration = makeConfiguration()

        XCTAssertEqual(configuration.activeAvatarID, "captain-ayer")
        XCTAssertEqual(configuration.avatarAgentProfiles.count, 1)
        XCTAssertNil(configuration.activeAvatarProfile.languageModelOverride)
        XCTAssertNil(configuration.activeAvatarProfile.voiceOverride)
        XCTAssertNil(configuration.activeAvatarProfile.speechRecognitionOverride)
        XCTAssertNil(configuration.activeAvatarProfile.liveTalkPreferences)
        XCTAssertEqual(configuration.effectiveSettings, configuration.settings)
    }

    func testLegacyVivieenSelectionFallsBackUntilStoreAvatarIsAvailable() throws {
        let suite = "AvatarAgentProfileTests.legacy-vivieen.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storageKey = "settings.\(UUID().uuidString)"
        let legacyVivieen = AvatarAgentProfile(id: "vivieen", displayName: "Vivieen")
        defaults.set(
            try JSONEncoder().encode(["vivieen": legacyVivieen]),
            forKey: storageKey + ".avatar-agents.v1"
        )
        defaults.set("vivieen", forKey: storageKey + ".active-avatar.v1")

        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: storageKey,
            providerVault: InMemoryProviderCredentialVault()
        )
        XCTAssertEqual(configuration.activeAvatarID, "vivieen")

        configuration.reconcileAvatarCatalog(
            OpenClamAvatarCatalog.avatars.map {
                AvatarAgentIdentity(id: $0.id, displayName: $0.displayName)
            }
        )
        XCTAssertEqual(configuration.activeAvatarID, AvatarAgentIdentity.defaultID)

        configuration.reconcileAvatarCatalog(
            OpenClamAvatarCatalog.avatars.map {
                AvatarAgentIdentity(id: $0.id, displayName: $0.displayName)
            } + [.init(id: "vivieen", displayName: "Vivieen")]
        )
        configuration.activateAvatar(id: "vivieen", displayName: "Vivieen")
        XCTAssertEqual(configuration.activeAvatarID, "vivieen")
        XCTAssertEqual(configuration.activeAvatarProfile.displayName, "Vivieen")
    }

    func testActiveAvatarOverridesModelSpeakingVoiceAndSpeechRecognition() throws {
        let configuration = makeConfiguration()
        var profile = configuration.profile(for: "octavia")
        profile.languageModelOverride = .init(provider: .xAI, model: "grok-4.5")
        profile.voiceOverride = .init(
            provider: .soniox,
            model: "tts-rt-v1",
            voice: "Emma"
        )
        profile.speechRecognitionOverride = .init(
            provider: .xAI,
            model: "grok-transcribe"
        )
        try configuration.updateAvatarProfile(profile)
        configuration.activateAvatar(id: "octavia", displayName: "Octavia")

        XCTAssertEqual(configuration.effectiveSettings.llm, profile.languageModelOverride)
        XCTAssertEqual(configuration.effectiveSettings.textToSpeech, profile.voiceOverride)
        XCTAssertEqual(
            configuration.effectiveSettings.speechToText,
            profile.speechRecognitionOverride
        )
        XCTAssertEqual(
            configuration.effectiveSettings.webSearch,
            configuration.settings.webSearch
        )
    }

    func testComposerModelChangeTargetsOnlyActiveAvatar() throws {
        let configuration = makeConfiguration()
        let sharedModel = configuration.settings.llm

        try configuration.updateActiveAvatarLanguageModel(
            .init(provider: .xAI, model: "grok-4.5")
        )

        XCTAssertEqual(configuration.settings.llm, sharedModel)
        XCTAssertEqual(configuration.activeAvatarProfile.languageModelOverride?.provider, .xAI)
        XCTAssertEqual(configuration.effectiveSettings.llm.model, "grok-4.5")
    }

    func testProfilesAndActiveAvatarPersist() throws {
        let suite = "AvatarAgentProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storageKey = "settings.\(UUID().uuidString)"

        var first: AIConfigurationModel? = AIConfigurationModel(
            defaults: defaults,
            storageKey: storageKey,
            providerVault: InMemoryProviderCredentialVault()
        )
        var profile = first!.profile(for: "cleo")
        profile.systemPrompt = "Speak like a careful historian."
        profile.userPrompt = "Use short bullet points."
        profile.speechRecognitionOverride = .init(
            provider: .xAI,
            model: "grok-transcribe"
        )
        profile.liveTalkPreferences = .init(
            llm: .followAvatar,
            stt: .followAvatar,
            tts: .managed
        )
        try first!.updateAvatarProfile(profile)
        first!.activateAvatar(id: "cleo", displayName: "Cleo")
        first = nil

        let restored = AIConfigurationModel(
            defaults: defaults,
            storageKey: storageKey,
            providerVault: InMemoryProviderCredentialVault()
        )
        XCTAssertEqual(restored.activeAvatarID, "cleo")
        XCTAssertEqual(restored.activeAvatarProfile.systemPrompt, profile.systemPrompt)
        XCTAssertEqual(restored.activeAvatarProfile.userPrompt, profile.userPrompt)
        XCTAssertEqual(
            restored.activeAvatarProfile.speechRecognitionOverride,
            profile.speechRecognitionOverride
        )
        XCTAssertEqual(
            restored.activeAvatarProfile.liveTalkPreferences,
            profile.liveTalkPreferences
        )
    }

    func testRuntimeFactoriesValidateOnlyTheirOwnEffectiveStage() throws {
        let configuration = makeConfiguration()

        configuration.settings.speechToText = .init(provider: .apple, model: "")
        configuration.settings.textToSpeech = .init(provider: .apple, model: "")
        XCTAssertNoThrow(try configuration.makeClient())

        configuration.settings.llm = .init(provider: .apple, model: "")
        configuration.settings.textToSpeech = .init(
            provider: .xAI,
            model: "xai-tts",
            voice: "rex"
        )
        configuration.settings.speechToText = .init(
            provider: .xAI,
            model: "grok-transcribe"
        )
        XCTAssertNoThrow(try configuration.makeCloudTextToSpeechService())
        XCTAssertNoThrow(try configuration.makeCloudSpeechToTextService())

        configuration.settings.textToSpeech = .init(provider: .apple, model: "")
        configuration.settings.speechToText = .init(
            provider: .soniox,
            model: "stt-rt-v5"
        )
        XCTAssertNoThrow(try configuration.makeRealtimeSpeechToTextService())
    }

    func testAvatarListUsesCompactLiveTalkSummaryWithoutLosingResolvedDetail() throws {
        let profile = AvatarAgentProfile(id: "captain-ayer", displayName: "Captain Ayer")
        let resolved = try LiveTalkConfigurationResolver.resolve(
            profile: profile,
            sharedSettings: .init()
        )

        XCTAssertEqual(
            AvatarLiveTalkSettingsPresentation.compactListSummary(
                profile: profile,
                configuration: resolved
            ),
            "LiveKit managed · Sarah"
        )
        XCTAssertEqual(
            resolved.summary,
            "Managed LLM · Managed STT · Managed TTS · Sarah"
        )

        let mixedProfile = AvatarAgentProfile(
            id: "vivieen",
            displayName: "Vivieen",
            languageModelOverride: .init(provider: .openAI, model: "gpt-5.6-luna"),
            liveTalkPreferences: .init(llm: .followAvatar)
        )
        let mixed = try LiveTalkConfigurationResolver.resolve(
            profile: mixedProfile,
            sharedSettings: .init()
        )
        XCTAssertEqual(
            AvatarLiveTalkSettingsPresentation.compactListSummary(
                profile: mixedProfile,
                configuration: mixed
            ),
            "Mixed · follows avatar"
        )
    }

    func testAvatarServiceSummariesHideAppleInternalModelIdentifiers() {
        XCTAssertEqual(
            AvatarAgentServicePresentation.modelName(
                provider: .apple,
                capability: .textToSpeech,
                model: "system-voice"
            ),
            "System voice"
        )
        XCTAssertEqual(
            AvatarAgentServicePresentation.modelName(
                provider: .apple,
                capability: .speechToText,
                model: "apple-dictation"
            ),
            "Apple Dictation"
        )
        XCTAssertEqual(
            AvatarAgentServicePresentation.voiceName(
                for: .init(provider: .xAI, model: "xai-tts", voice: "rex")
            ),
            "Rex"
        )
    }

    func testThreadsRemainScopedToTheirAvatar() {
        let configuration = makeConfiguration()
        let captainThread = UUID()
        let cleoThread = UUID()

        configuration.registerThread(captainThread, for: "captain-ayer")
        configuration.registerThread(cleoThread, for: "cleo")

        XCTAssertEqual(configuration.activeThreadID(for: "captain-ayer"), captainThread)
        XCTAssertEqual(configuration.activeThreadID(for: "cleo"), cleoThread)
        XCTAssertEqual(configuration.avatarID(for: captainThread), "captain-ayer")
        XCTAssertEqual(configuration.avatarID(for: cleoThread), "cleo")

        configuration.removeThread(cleoThread)
        XCTAssertNil(configuration.activeThreadID(for: "cleo"))
        XCTAssertNil(configuration.avatarID(for: cleoThread))
    }

    func testPersonaIsAppendedAfterSafetyBoundary() {
        let context = ActiveAvatarPromptContext(
            avatarName: "Vivieen",
            systemPrompt: "Be playful.",
            userPrompt: "Answer in French."
        )
        let instructions = context.applyingPersona(to: "HARD BOUNDARY")

        XCTAssertTrue(instructions.hasPrefix("HARD BOUNDARY"))
        XCTAssertTrue(instructions.contains("cannot weaken the hard boundaries"))
        XCTAssertTrue(instructions.contains("Be playful."))
        XCTAssertNotNil(context.savedUserPromptInput)
    }

    func testPromptLimitsFailClosed() {
        let oversized = AvatarAgentProfile(
            id: "emma",
            displayName: "Emma",
            systemPrompt: String(
                repeating: "x",
                count: AvatarAgentProfile.maximumSystemPromptCharacters + 1
            )
        )

        XCTAssertThrowsError(try oversized.validated()) { error in
            XCTAssertEqual(error as? AvatarAgentProfileError, .systemPromptTooLong)
        }
    }

    private func makeConfiguration() -> AIConfigurationModel {
        let suite = "AvatarAgentProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AIConfigurationModel(
            defaults: defaults,
            storageKey: "settings.\(UUID().uuidString)",
            providerVault: InMemoryProviderCredentialVault()
        )
    }
}
