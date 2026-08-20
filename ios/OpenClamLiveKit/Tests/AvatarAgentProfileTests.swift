import XCTest
@testable import OpenClamLiveKit

@MainActor
final class AvatarAgentProfileTests: XCTestCase {
    func testDefaultPackInheritsSharedModelAndVoice() {
        let configuration = makeConfiguration()

        XCTAssertEqual(configuration.activeAvatarID, "captain-ayer")
        XCTAssertEqual(
            AvatarAgentIdentity.defaultPack,
            [
                .init(id: "captain-ayer", displayName: "Captain Ayer"),
                .init(id: "ara", displayName: "Ara"),
            ]
        )
        XCTAssertEqual(Set(configuration.avatarAgentProfiles.keys), ["captain-ayer", "ara"])
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

    func testCatalogReconciliationDropsUnavailableAgentThreadSelections() {
        let configuration = makeConfiguration()
        let removedID = "removed-import"
        let threadID = UUID()
        configuration.activateAvatar(id: removedID, displayName: "Removed Import")
        configuration.registerThread(threadID, for: removedID)

        configuration.reconcileAvatarCatalog(AvatarAgentIdentity.defaultPack)

        XCTAssertEqual(
            configuration.activeAvatarID,
            AvatarAgentIdentity.defaultID
        )
        XCTAssertNil(configuration.activeThreadID(for: removedID))
        XCTAssertNil(configuration.avatarID(for: threadID))
    }

    func testCatalogMigrationRetiresOldBundledProfilesButKeepsInstalledAvatarState() throws {
        let suite = "AvatarAgentProfileTests.retired-pack.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storageKey = "settings.\(UUID().uuidString)"
        let importedID = "my-installed-avatar"
        let retiredThread = UUID()
        let importedThread = UUID()
        let profiles = [
            "vvn": AvatarAgentProfile(
                id: "vvn",
                displayName: "Vvn",
                systemPrompt: "Retired bundled profile"
            ),
            "cleo": AvatarAgentProfile(
                id: "cleo",
                displayName: "Cleo",
                userPrompt: "Retired bundled preference"
            ),
            importedID: AvatarAgentProfile(
                id: importedID,
                displayName: "My Installed Avatar",
                systemPrompt: "Keep this user-authored persona"
            ),
        ]
        let threads = AvatarAgentThreadMap(
            activeThreadByAvatar: [
                "vvn": retiredThread,
                importedID: importedThread,
            ],
            avatarByThread: [
                retiredThread: "vvn",
                importedThread: importedID,
            ]
        )
        defaults.set(
            try JSONEncoder().encode(profiles),
            forKey: storageKey + ".avatar-agents.v1"
        )
        defaults.set("vvn", forKey: storageKey + ".active-avatar.v1")
        defaults.set(
            try JSONEncoder().encode(threads),
            forKey: storageKey + ".avatar-threads.v1"
        )

        let available = AvatarAgentIdentity.defaultPack + [
            .init(id: importedID, displayName: "My Installed Avatar"),
        ]
        var configuration: AIConfigurationModel? = AIConfigurationModel(
            defaults: defaults,
            storageKey: storageKey,
            providerVault: InMemoryProviderCredentialVault()
        )
        configuration!.reconcileAvatarCatalog(available)

        XCTAssertEqual(
            Set(configuration!.avatarAgentProfiles.keys),
            ["captain-ayer", "ara", importedID]
        )
        XCTAssertNil(configuration!.avatarAgentProfiles["vvn"])
        XCTAssertNil(configuration!.avatarAgentProfiles["cleo"])
        XCTAssertEqual(
            configuration!.avatarAgentProfiles[importedID]?.systemPrompt,
            "Keep this user-authored persona"
        )
        XCTAssertEqual(configuration!.activeAvatarID, AvatarAgentIdentity.defaultID)
        XCTAssertNil(configuration!.avatarID(for: retiredThread))
        XCTAssertEqual(configuration!.avatarID(for: importedThread), importedID)
        XCTAssertEqual(configuration!.activeThreadID(for: importedID), importedThread)

        configuration = nil
        let restarted = AIConfigurationModel(
            defaults: defaults,
            storageKey: storageKey,
            providerVault: InMemoryProviderCredentialVault()
        )
        restarted.reconcileAvatarCatalog(available)
        XCTAssertEqual(
            Set(restarted.avatarAgentProfiles.keys),
            ["captain-ayer", "ara", importedID]
        )
        XCTAssertEqual(
            restarted.avatarAgentProfiles[importedID]?.systemPrompt,
            "Keep this user-authored persona"
        )
    }

    func testOwnedLegacyAraIdentityMigrationPreservesPersonaSelectionAndThreads() throws {
        let suite = "AvatarAgentProfileTests.legacy-owned-ara.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storageKey = "settings.\(UUID().uuidString)"
        let activeThread = UUID()
        let historicalThread = UUID()
        let unrelatedThread = UUID()
        let legacy = AvatarAgentProfile(
            id: "ara-2",
            displayName: "Ara",
            languageModelOverride: .init(provider: .xAI, model: "grok-4.5"),
            systemPrompt: "Keep Ara's user-authored persona",
            userPrompt: "Keep this user preference"
        )
        let unrelated = AvatarAgentProfile(
            id: "my-installed-avatar",
            displayName: "My Installed Avatar",
            systemPrompt: "Never migrate this arbitrary avatar"
        )
        defaults.set(
            try JSONEncoder().encode([
                "ara-2": legacy,
                "my-installed-avatar": unrelated,
            ]),
            forKey: storageKey + ".avatar-agents.v1"
        )
        defaults.set("ara-2", forKey: storageKey + ".active-avatar.v1")
        defaults.set(
            try JSONEncoder().encode(
                AvatarAgentThreadMap(
                    activeThreadByAvatar: [
                        "ara-2": activeThread,
                        "my-installed-avatar": unrelatedThread,
                    ],
                    avatarByThread: [
                        activeThread: "ara-2",
                        historicalThread: "ara-2",
                        unrelatedThread: "my-installed-avatar",
                    ]
                )
            ),
            forKey: storageKey + ".avatar-threads.v1"
        )

        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: storageKey,
            providerVault: InMemoryProviderCredentialVault()
        )
        configuration.migrateAvatarIdentity(
            from: "ara-2",
            to: .init(id: "ara", displayName: "Ara")
        )

        XCTAssertEqual(configuration.activeAvatarID, "ara")
        XCTAssertNil(configuration.avatarAgentProfiles["ara-2"])
        XCTAssertEqual(
            configuration.avatarAgentProfiles["ara"]?.systemPrompt,
            "Keep Ara's user-authored persona"
        )
        XCTAssertEqual(
            configuration.avatarAgentProfiles["ara"]?.userPrompt,
            "Keep this user preference"
        )
        XCTAssertEqual(
            configuration.avatarAgentProfiles["ara"]?.languageModelOverride,
            legacy.languageModelOverride
        )
        XCTAssertEqual(configuration.activeThreadID(for: "ara"), activeThread)
        XCTAssertEqual(configuration.avatarID(for: activeThread), "ara")
        XCTAssertEqual(configuration.avatarID(for: historicalThread), "ara")
        XCTAssertEqual(
            configuration.avatarAgentProfiles["my-installed-avatar"]?.systemPrompt,
            "Never migrate this arbitrary avatar"
        )
        XCTAssertEqual(
            configuration.activeThreadID(for: "my-installed-avatar"),
            unrelatedThread
        )
    }

    func testActiveAvatarOverridesModelSpeakingVoiceAndSpeechRecognition() throws {
        let configuration = makeConfiguration()
        var profile = configuration.profile(for: "ara")
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
        configuration.activateAvatar(id: "ara", displayName: "Ara")

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
        var profile = first!.profile(for: "ara")
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
        first!.activateAvatar(id: "ara", displayName: "Ara")
        first = nil

        let restored = AIConfigurationModel(
            defaults: defaults,
            storageKey: storageKey,
            providerVault: InMemoryProviderCredentialVault()
        )
        XCTAssertEqual(restored.activeAvatarID, "ara")
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
        let importedThread = UUID()

        configuration.registerThread(captainThread, for: "captain-ayer")
        configuration.registerThread(importedThread, for: "my-installed-avatar")

        XCTAssertEqual(configuration.activeThreadID(for: "captain-ayer"), captainThread)
        XCTAssertEqual(
            configuration.activeThreadID(for: "my-installed-avatar"),
            importedThread
        )
        XCTAssertEqual(configuration.avatarID(for: captainThread), "captain-ayer")
        XCTAssertEqual(
            configuration.avatarID(for: importedThread),
            "my-installed-avatar"
        )

        configuration.removeThread(importedThread)
        XCTAssertNil(configuration.activeThreadID(for: "my-installed-avatar"))
        XCTAssertNil(configuration.avatarID(for: importedThread))
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
