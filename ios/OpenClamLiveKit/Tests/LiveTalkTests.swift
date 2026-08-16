import LiveKit
import XCTest
@testable import OpenClamLiveKit

@MainActor
final class LiveTalkTests: XCTestCase {
    func testDefaultConfigurationUsesManagedLiveKitForEveryStage() throws {
        let configuration = try LiveTalkConfiguration.managedDefault.validated()

        for stage in LiveTalkStage.allCases {
            XCTAssertEqual(configuration[stage].source, .managed)
            XCTAssertEqual(configuration[stage].provider, "livekit")
        }
        XCTAssertEqual(configuration.llm.model, "google/gemma-4-31b-it")
        XCTAssertEqual(configuration.stt.model, "deepgram/nova-3")
        XCTAssertEqual(configuration.tts.model, "fishaudio/s2.1-pro")
        XCTAssertEqual(configuration.tts.voice, "933563129e564b19a115bedd57b7406a")
    }

    func testManagedFishVoicesAreClosedAndSarahIsTheDefault() {
        XCTAssertEqual(LiveTalkCatalog.managedTTS.title, "Sarah — engaged")
        XCTAssertEqual(
            managedTTSTupleSignatures(),
            [
                "Adrian — friendly & casual|bf322df2096a46f18c579d0baa36f41d",
                "Ethan — curious explainer|536d3a5e000945adb7038665781a4aca",
                "Hannah — conversational|9a9cf47702da476aa4629e2506d4a857",
                "Jordan — motivational|79d0bd3e4e5444b18f7b6d89b5927bf1",
                "Laura — confident narrator|e3cd384158934cc9a01029cd7d278634",
                "Sarah — engaged|933563129e564b19a115bedd57b7406a",
                "Selene — meditative (legacy)|b347db033a6549378b48d00acb0d06cd",
            ]
        )
        XCTAssertTrue(
            LiveTalkCatalog.managedOptions(for: .tts).allSatisfy {
                $0.selection.provider == "livekit"
                    && $0.selection.model == "fishaudio/s2.1-pro"
                    && $0.selection.source == .managed
            }
        )
    }

    func testManagedFishVoicePreferenceResolvesExactly() throws {
        let hannah = "9a9cf47702da476aa4629e2506d4a857"
        let profile = AvatarAgentProfile(
            id: "vivieen",
            displayName: "Vivieen",
            liveTalkPreferences: .init(managedTTSVoice: hannah)
        )

        let configuration = try LiveTalkConfigurationResolver.resolve(
            profile: profile,
            sharedSettings: .init()
        )

        XCTAssertEqual(configuration.tts.voice, hannah)
        XCTAssertEqual(configuration.tts.source, .managed)
        XCTAssertEqual(configuration.summary, "Managed LLM · Managed STT · Managed TTS · Hannah")
    }

    func testLegacyManagedSeleneSelectionMigratesWithoutChangingVoice() throws {
        let selene = try XCTUnwrap(
            LiveTalkCatalog.managedTTSOption(
                voice: "b347db033a6549378b48d00acb0d06cd"
            )
        )
        var legacyConfiguration = LiveTalkConfiguration.managedDefault
        legacyConfiguration.tts = selene.selection
        let profile = AvatarAgentProfile(
            id: "cleo",
            displayName: "Cleo",
            liveTalkConfiguration: legacyConfiguration
        )

        XCTAssertEqual(
            profile.effectiveLiveTalkPreferences.managedTTSVoice,
            selene.selection.voice
        )
        XCTAssertEqual(
            try LiveTalkConfigurationResolver.resolve(
                profile: profile,
                sharedSettings: .init()
            ).tts,
            selene.selection
        )
    }

    func testDefaultPreferencesResolveToManagedLiveKitForEveryStage() throws {
        let profile = AvatarAgentProfile(id: "captain-ayer", displayName: "Captain Ayer")

        XCTAssertEqual(profile.effectiveLiveTalkPreferences, .managedDefault)
        XCTAssertEqual(
            try LiveTalkConfigurationResolver.resolve(
                profile: profile,
                sharedSettings: .init()
            ),
            .managedDefault
        )
    }

    func testFollowAvatarResolvesAnExactImmutableCallSnapshot() throws {
        let profile = AvatarAgentProfile(
            id: "captain-ayer",
            displayName: "Captain Ayer",
            languageModelOverride: .init(provider: .openAI, model: "gpt-5.6-luna"),
            voiceOverride: .init(provider: .xAI, model: "xai-tts", voice: "rex"),
            speechRecognitionOverride: .init(provider: .xAI, model: "grok-transcribe"),
            liveTalkPreferences: .init(
                llm: .followAvatar,
                stt: .followAvatar,
                tts: .followAvatar
            )
        )

        let snapshot = try LiveTalkConfigurationResolver.resolve(
            profile: profile,
            sharedSettings: .init()
        )

        XCTAssertEqual(snapshot.llm.provider, "openai")
        XCTAssertEqual(snapshot.llm.model, "gpt-5.6-luna")
        XCTAssertEqual(snapshot.stt.provider, "xai")
        XCTAssertEqual(snapshot.stt.model, "grok-transcribe")
        XCTAssertEqual(snapshot.tts.provider, "xai")
        XCTAssertEqual(snapshot.tts.model, "xai-tts")
        XCTAssertEqual(snapshot.tts.voice, "rex")
        XCTAssertTrue(LiveTalkStage.allCases.allSatisfy { snapshot[$0].source == .byok })
    }

    func testFollowAvatarResolvesChineseRecognitionAndAutomaticXAITTS() throws {
        let profile = AvatarAgentProfile(
            id: "captain-ayer",
            displayName: "Captain Ayer",
            voiceOverride: .init(provider: .xAI, model: "xai-tts", voice: "rex"),
            speechRecognitionOverride: .init(
                provider: .openAI,
                model: "gpt-4o-transcribe"
            ),
            liveTalkPreferences: .init(stt: .followAvatar, tts: .followAvatar)
        )

        let snapshot = try LiveTalkConfigurationResolver.resolve(
            profile: profile,
            sharedSettings: .init(),
            composerLanguageCode: "zh-Hans"
        )

        XCTAssertEqual(snapshot.stt.language, "zh")
        XCTAssertEqual(snapshot.tts.language, "auto")
    }

    func testFollowAvatarRejectsUnsupportedExplicitRecognitionLanguage() throws {
        let profile = AvatarAgentProfile(
            id: "captain-ayer",
            displayName: "Captain Ayer",
            speechRecognitionOverride: .init(
                provider: .openAI,
                model: "gpt-4o-transcribe"
            ),
            liveTalkPreferences: .init(stt: .followAvatar)
        )

        XCTAssertThrowsError(
            try LiveTalkConfigurationResolver.resolve(
                profile: profile,
                sharedSettings: .init(),
                composerLanguageCode: "fr-FR"
            )
        ) { error in
            XCTAssertEqual(
                error as? LiveTalkConfigurationError,
                .avatarLanguageNotSupported(.openAI, "fr-FR")
            )
        }
    }

    func testXAIRecognitionKeepsItsProviderMultilingualFormattingHint() throws {
        let profile = AvatarAgentProfile(
            id: "captain-ayer",
            displayName: "Captain Ayer",
            speechRecognitionOverride: .init(
                provider: .xAI,
                model: "grok-transcribe"
            ),
            liveTalkPreferences: .init(stt: .followAvatar)
        )

        let snapshot = try LiveTalkConfigurationResolver.resolve(
            profile: profile,
            sharedSettings: .init(),
            composerLanguageCode: "zh-Hans"
        )

        // xAI recognizes multilingual speech independently; this value is its
        // pinned plugin's inverse-text-formatting hint, not a translation target.
        XCTAssertEqual(snapshot.stt.language, "en")
    }

    func testLegacyXAITTSWithoutLanguageCanonicalizesToAutoInPayload() throws {
        var legacyConfiguration = LiveTalkConfiguration.managedDefault
        legacyConfiguration.tts = .init(
            source: .byok,
            provider: "xai",
            model: "xai-tts",
            voice: "rex",
            language: nil
        )
        let validated = try legacyConfiguration.validated()
        XCTAssertEqual(validated.tts.language, "auto")

        let vault = InMemoryProviderCredentialVault()
        try vault.saveCredential("xai-migration-test-key", for: .xAI)
        let payload = try LiveTalkSessionRequestBuilder(credentialVault: vault)
            .makePayload(
                avatar: .init(id: "captain-ayer", displayName: "Captain Ayer"),
                configuration: legacyConfiguration
            )

        XCTAssertEqual(payload.profile.tts.language, "auto")
        let encoded = try JSONEncoder().encode(payload)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"language\":\"auto\""))
    }

    func testFollowAvatarFailsClosedForAppleWithoutManagedFallback() throws {
        let profile = AvatarAgentProfile(
            id: "captain-ayer",
            displayName: "Captain Ayer",
            liveTalkPreferences: .init(stt: .followAvatar)
        )

        XCTAssertThrowsError(
            try LiveTalkConfigurationResolver.resolve(
                profile: profile,
                sharedSettings: .init()
            )
        ) { error in
            XCTAssertEqual(
                error as? LiveTalkConfigurationError,
                .avatarSelectionNotSupported(
                    .stt,
                    .apple,
                    "apple-dictation",
                    nil
                )
            )
        }
    }

    func testElevenLabsFollowUsesOnlyReviewedModelVoiceTuples() throws {
        let flashJBF = try XCTUnwrap(
            LiveTalkCatalog.option(
                following: .init(
                    provider: .elevenLabs,
                    model: "eleven_flash_v2_5",
                    voice: "JBFqnCBsd6RMkjVDRZzb"
                ),
                for: .tts
            )
        )
        let multilingualJBF = try XCTUnwrap(
            LiveTalkCatalog.option(
                following: .init(
                    provider: .elevenLabs,
                    model: "eleven_multilingual_v2",
                    voice: "JBFqnCBsd6RMkjVDRZzb"
                ),
                for: .tts
            )
        )

        XCTAssertEqual(flashJBF.selection.voice, "JBFqnCBsd6RMkjVDRZzb")
        XCTAssertEqual(multilingualJBF.selection.voice, "JBFqnCBsd6RMkjVDRZzb")
        XCTAssertNotNil(
            LiveTalkCatalog.option(
                following: .init(
                    provider: .elevenLabs,
                    model: "eleven_flash_v2_5",
                    voice: "EXAVITQu4vr4xnSDxMaL"
                ),
                for: .tts
            )
        )
        XCTAssertNil(
            LiveTalkCatalog.option(
                following: .init(
                    provider: .elevenLabs,
                    model: "eleven_multilingual_v2",
                    voice: "EXAVITQu4vr4xnSDxMaL"
                ),
                for: .tts
            )
        )
    }

    func testBuildConfigurationAcceptsOnlyExactHTTPSBrokerContract() throws {
        let token = String(repeating: "p", count: 32)
        let valid = try LiveTalkAppConfiguration.validated(
            rawURL: "https://broker.example/v1/live-talk/sessions",
            rawToken: token,
            rawExpectedServerHost: "expected.livekit.cloud"
        )
        XCTAssertEqual(valid.sessionEndpoint.path, "/v1/live-talk/sessions")
        XCTAssertEqual(valid.expectedServerHost, "expected.livekit.cloud")

        for invalidURL in [
            "http://broker.example/v1/live-talk/sessions",
            "https://broker.example/v1/live-talk/sessions?key=value",
            "https://broker.example/other",
            "$(OPENCLAM_LIVETALK_BROKER_URL)",
        ] {
            XCTAssertThrowsError(
                try LiveTalkAppConfiguration.validated(
                    rawURL: invalidURL,
                    rawToken: token,
                    rawExpectedServerHost: "expected.livekit.cloud"
                )
            ) { error in
                XCTAssertEqual(error as? LiveTalkBrokerError, .notConfigured)
            }
        }
        XCTAssertThrowsError(
            try LiveTalkAppConfiguration.validated(
                rawURL: valid.sessionEndpoint.absoluteString,
                rawToken: "too-short",
                rawExpectedServerHost: "expected.livekit.cloud"
            )
        ) { error in
            XCTAssertEqual(error as? LiveTalkBrokerError, .notConfigured)
        }
    }

    func testBuildConfigurationRequiresLowercaseExpectedLiveKitHost() throws {
        let endpoint = "https://broker.example/v1/live-talk/sessions"
        let token = String(repeating: "p", count: 32)

        for invalidHost in [
            "",
            "$(OPENCLAM_LIVETALK_EXPECTED_SERVER_HOST)",
            "EXPECTED.livekit.cloud",
            "livekit",
            "https://expected.livekit.cloud",
            "-expected.livekit.cloud",
            "expected.livekit.cloud.",
        ] {
            XCTAssertThrowsError(
                try LiveTalkAppConfiguration.validated(
                    rawURL: endpoint,
                    rawToken: token,
                    rawExpectedServerHost: invalidHost
                )
            ) { error in
                XCTAssertEqual(error as? LiveTalkBrokerError, .notConfigured)
            }
        }

        XCTAssertThrowsError(
            try LiveTalkAppConfiguration.validated(
                rawURL: endpoint,
                rawToken: token,
                rawExpectedServerHost: nil
            )
        ) { error in
            XCTAssertEqual(error as? LiveTalkBrokerError, .notConfigured)
        }
    }

    func testBrokerServerURLIsPinnedToExpectedLiveKitHost() throws {
        let expectedHost = "expected.livekit.cloud"

        for validURL in [
            "wss://expected.livekit.cloud",
            "wss://expected.livekit.cloud/",
            "wss://expected.livekit.cloud:443/",
        ] {
            XCTAssertNoThrow(
                try LiveTalkBrokerTokenSource.validatedServerURL(
                    validURL,
                    expectedHost: expectedHost
                )
            )
        }

        for invalidURL in [
            "ws://expected.livekit.cloud",
            "https://expected.livekit.cloud",
            "wss://attacker.livekit.cloud",
            "wss://EXPECTED.livekit.cloud",
            "wss://user@expected.livekit.cloud",
            "wss://expected.livekit.cloud?room=secret",
            "wss://expected.livekit.cloud#fragment",
            "wss://expected.livekit.cloud:",
            "wss://expected.livekit.cloud:8443",
            "wss://expected.livekit.cloud/rooms/pilot",
        ] {
            XCTAssertThrowsError(
                try LiveTalkBrokerTokenSource.validatedServerURL(
                    invalidURL,
                    expectedHost: expectedHost
                )
            ) { error in
                XCTAssertEqual(error as? LiveTalkBrokerError, .invalidResponse)
            }
        }
    }

    func testBrokerSessionRejects307And308BeforeCredentialBodyCanBeResent() throws {
        let brokerURL = try XCTUnwrap(
            URL(string: "https://broker.example/v1/live-talk/sessions")
        )
        let attackerURL = try XCTUnwrap(
            URL(string: "https://redirect.invalid/collect")
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: brokerURL)
        defer { task.cancel() }
        let delegate = LiveTalkBrokerNoRedirectSessionDelegate()
        let secret = "provider-credential-must-not-follow"

        for statusCode in [307, 308] {
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: brokerURL,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": attackerURL.absoluteString]
                )
            )
            var proposedRequest = URLRequest(url: attackerURL)
            proposedRequest.httpMethod = "POST"
            proposedRequest.httpBody = Data(secret.utf8)
            var followedRequest: URLRequest? = proposedRequest

            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: proposedRequest
            ) { acceptedRequest in
                followedRequest = acceptedRequest
            }

            XCTAssertNil(followedRequest, "HTTP \(statusCode) must not replay BYOK data")
        }
    }

    func testBrokerTokenSourceFailsSafelyOn307And308WithoutSecondRequest() async throws {
        let brokerURL = try XCTUnwrap(
            URL(string: "https://broker.example/v1/live-talk/sessions")
        )
        let attackerURL = try XCTUnwrap(
            URL(string: "https://redirect.invalid/collect")
        )
        let selectedSecret = "xai-stage-credential-never-redirect"
        let vault = InMemoryProviderCredentialVault()
        try vault.saveCredential(selectedSecret, for: .xAI)
        var liveTalkConfiguration = LiveTalkConfiguration.managedDefault
        liveTalkConfiguration.stt = try XCTUnwrap(
            option(stage: .stt, provider: "xai")
        ).selection

        for statusCode in [307, 308] {
            let recorder = LiveTalkBrokerRequestRecorder()
            let source = LiveTalkBrokerTokenSource(
                configuration: .init(
                    sessionEndpoint: brokerURL,
                    appToken: String(repeating: "p", count: 32),
                    expectedServerHost: "expected.livekit.cloud"
                ),
                avatar: .init(id: "captain-ayer", displayName: "Captain Ayer"),
                liveTalkConfiguration: liveTalkConfiguration,
                credentialVault: vault,
                requestPerformer: { request in
                    await recorder.record(request)
                    return (
                        Data(),
                        HTTPURLResponse(
                            url: brokerURL,
                            statusCode: statusCode,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Location": attackerURL.absoluteString]
                        )!
                    )
                }
            )

            do {
                _ = try await source.fetch()
                XCTFail("HTTP \(statusCode) must not produce a LiveKit token")
            } catch {
                XCTAssertEqual(error as? LiveTalkBrokerError, .sessionRejected)
            }

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.url, brokerURL)
            XCTAssertFalse(requests.contains(where: { $0.url?.host == attackerURL.host }))
            XCTAssertTrue(
                requests.first?.httpBody.map {
                    String(decoding: $0, as: UTF8.self).contains(selectedSecret)
                } == true,
                "The test must exercise a real credential-bearing broker payload"
            )
        }
    }

    func testCatalogPublishesOnlyBrokerSupportedStageCapabilities() {
        XCTAssertNotNil(option(stage: .llm, provider: "gemini"))
        XCTAssertNil(option(stage: .stt, provider: "gemini"))
        XCTAssertNotNil(option(stage: .tts, provider: "gemini"))
        XCTAssertNotNil(option(stage: .llm, provider: "anthropic"))
        XCTAssertNil(option(stage: .stt, provider: "anthropic"))
        XCTAssertNil(option(stage: .tts, provider: "anthropic"))

        XCTAssertEqual(option(stage: .stt, provider: "xai")?.selection.model, "grok-transcribe")
        XCTAssertEqual(option(stage: .tts, provider: "xai")?.selection.model, "xai-tts")
        XCTAssertEqual(
            option(stage: .tts, provider: "elevenlabs")?.selection.model,
            "eleven_flash_v2_5"
        )
        XCTAssertTrue(
            AIProviderRegistry.credentialProviders.map(\.id).contains(.deepgram)
        )
        XCTAssertTrue(
            !AIProviderRegistry.hasRuntimeAdapter(
                provider: .deepgram,
                capability: .speechToText
            ),
            "Deepgram remains a Live Talk choice unless an ordinary runtime adapter is added."
        )
    }

    func testCatalogMatchesTheReviewedBrokerTupleMatrix() {
        XCTAssertEqual(
            byokTupleSignatures(for: .llm),
            [
                "anthropic|claude-haiku-4-5|-|-",
                "anthropic|claude-sonnet-4-6|-|-",
                "gemini|gemini-3.5-flash-lite|-|-",
                "gemini|gemini-3.5-flash|-|-",
                "gemini|gemini-3.6-flash|-|-",
                "openai|gpt-5.4-mini|-|-",
                "openai|gpt-5.6-luna|-|-",
                "openai|gpt-5.6-sol|-|-",
                "openai|gpt-5.6-terra|-|-",
                "xai|grok-4.3|-|-",
                "xai|grok-4.5|-|-",
            ]
        )
        XCTAssertEqual(
            byokTupleSignatures(for: .stt),
            [
                "deepgram|nova-3|-|multi",
                "elevenlabs|scribe_v2_realtime|-|multi",
                "openai|gpt-4o-mini-transcribe|-|en",
                "openai|gpt-4o-mini-transcribe|-|zh",
                "openai|gpt-4o-transcribe|-|en",
                "openai|gpt-4o-transcribe|-|zh",
                "openai|whisper-1|-|en",
                "openai|whisper-1|-|zh",
                "xai|grok-transcribe|-|en",
            ]
        )
        XCTAssertEqual(
            byokTupleSignatures(for: .tts),
            [
                "deepgram|aura-2-andromeda-en|aura-2-andromeda-en|-",
                "elevenlabs|eleven_flash_v2_5|EXAVITQu4vr4xnSDxMaL|-",
                "elevenlabs|eleven_flash_v2_5|JBFqnCBsd6RMkjVDRZzb|-",
                "elevenlabs|eleven_multilingual_v2|JBFqnCBsd6RMkjVDRZzb|-",
                "gemini|gemini-3.1-flash-tts-preview|Kore|-",
                "gemini|gemini-3.1-flash-tts-preview|Sadachbia|-",
                "openai|gpt-4o-mini-tts|alloy|-",
                "openai|tts-1-hd|alloy|-",
                "openai|tts-1|alloy|-",
                "xai|xai-tts|ara|auto",
                "xai|xai-tts|eve|auto",
                "xai|xai-tts|leo|auto",
                "xai|xai-tts|rex|auto",
                "xai|xai-tts|sal|auto",
            ]
        )
    }

    func testBYOKPayloadLoadsOnlyTheSelectedStageCredential() throws {
        let vault = InMemoryProviderCredentialVault()
        let selectedSecret = "xai-stage-only-secret"
        let unrelatedSecret = "openai-must-not-leave-keychain"
        try vault.saveCredential(selectedSecret, for: .xAI)
        try vault.saveCredential(unrelatedSecret, for: .openAI)

        var configuration = LiveTalkConfiguration.managedDefault
        configuration.stt = try XCTUnwrap(option(stage: .stt, provider: "xai")).selection
        let avatar = AvatarAgentProfile(
            id: "captain-ayer",
            displayName: "Captain Ayer",
            liveTalkConfiguration: configuration
        )

        let payload = try LiveTalkSessionRequestBuilder(credentialVault: vault)
            .makePayload(
                avatar: avatar,
                configuration: configuration,
                participantName: "Pilot"
            )
        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let credentials = try XCTUnwrap(json["credentials"] as? [String: Any])

        XCTAssertEqual(Set(credentials.keys), ["stt"])
        XCTAssertEqual(
            (credentials["stt"] as? [String: String])?["api_key"],
            selectedSecret
        )
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(unrelatedSecret))
        XCTAssertNil(json["metadata"])
    }

    func testProfilePersistenceContainsSelectionsButNeverProviderKeys() throws {
        let suite = "LiveTalkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secret = "gemini-keychain-only-secret"
        let vault = InMemoryProviderCredentialVault()
        try vault.saveCredential(secret, for: .gemini)

        var configuration = LiveTalkConfiguration.managedDefault
        configuration.tts = try XCTUnwrap(option(stage: .tts, provider: "gemini")).selection
        let profile = AvatarAgentProfile(
            id: "vivieen",
            displayName: "Vivieen",
            liveTalkConfiguration: configuration
        )
        let encoded = try JSONEncoder().encode(profile)
        defaults.set(encoded, forKey: "avatar")

        let persisted = try XCTUnwrap(defaults.data(forKey: "avatar"))
        let persistedText = String(decoding: persisted, as: UTF8.self)
        XCTAssertTrue(persistedText.contains("gemini-3.1-flash-tts-preview"))
        XCTAssertFalse(persistedText.contains(secret))

        let restored = try JSONDecoder().decode(AvatarAgentProfile.self, from: persisted)
        XCTAssertEqual(restored.liveTalkConfiguration, configuration)
        XCTAssertEqual(restored.effectiveLiveTalkPreferences.tts, .fixed(configuration.tts))
        let restoredConfiguration = try LiveTalkConfigurationResolver.resolve(
            profile: restored,
            sharedSettings: .init()
        )
        XCTAssertThrowsError(
            try LiveTalkSessionRequestBuilder(credentialVault: InMemoryProviderCredentialVault())
                .makePayload(
                    avatar: restored,
                    configuration: restoredConfiguration
                )
        ) { error in
            XCTAssertEqual(error as? LiveTalkBrokerError, .missingCredential(.tts, .gemini))
        }
    }

    func testLegacyAvatarProfileDecodesWithManagedLiveTalkDefault() throws {
        let legacy = Data(
            #"{"id":"cleo","displayName":"Cleo","systemPrompt":"","userPrompt":""}"#.utf8
        )

        let profile = try JSONDecoder().decode(AvatarAgentProfile.self, from: legacy)

        XCTAssertNil(profile.liveTalkConfiguration)
        XCTAssertNil(profile.liveTalkPreferences)
        XCTAssertEqual(profile.effectiveLiveTalkPreferences, .managedDefault)
        XCTAssertEqual(
            try LiveTalkConfigurationResolver.resolve(
                profile: profile,
                sharedSettings: .init()
            ),
            .managedDefault
        )
    }

    func testPersonaAndParticipantBoundsAreUTF8Safe() throws {
        let emoji = "🦀"
        let profile = AvatarAgentProfile(
            id: "octavia",
            displayName: String(repeating: emoji, count: 64),
            systemPrompt: String(repeating: emoji, count: 2_000),
            userPrompt: String(repeating: "multibyte-é-", count: 300)
        )

        let payload = try LiveTalkSessionRequestBuilder(
            credentialVault: InMemoryProviderCredentialVault()
        ).makePayload(
            avatar: profile,
            configuration: .managedDefault
        )

        XCTAssertLessThanOrEqual(
            payload.profile.persona.name.utf8.count,
            LiveTalkBrokerPersona.maximumNameUTF8Bytes
        )
        XCTAssertLessThanOrEqual(
            payload.profile.persona.instructions.utf8.count,
            LiveTalkBrokerPersona.maximumInstructionsUTF8Bytes
        )
        XCTAssertTrue(payload.profile.persona.instructions.hasPrefix("Have a warm, natural"))
        XCTAssertTrue(
            payload.profile.persona.instructions.contains(
                "Reply in the language the user is speaking"
            )
        )
        XCTAssertFalse(payload.profile.persona.instructions.contains("�"))

        XCTAssertThrowsError(
            try LiveTalkSessionRequestBuilder(
                credentialVault: InMemoryProviderCredentialVault()
            ).makePayload(
                avatar: AvatarAgentProfile(id: "emma", displayName: "Emma"),
                configuration: .managedDefault,
                participantName: String(repeating: emoji, count: 21)
            )
        ) { error in
            XCTAssertEqual(error as? LiveTalkBrokerError, .invalidProfile)
        }
    }

    func testLifecycleTransitionsAreClosedAndReusable() {
        var lifecycle = LiveTalkLifecycle()
        lifecycle.apply(.roomConnected(agentIsConnected: true))
        XCTAssertEqual(lifecycle.phase, .idle)

        lifecycle.apply(.start)
        lifecycle.apply(.roomConnected(agentIsConnected: true))
        lifecycle.apply(.reconnecting)
        lifecycle.apply(.roomConnected(agentIsConnected: true))
        XCTAssertEqual(lifecycle.phase, .connected)

        lifecycle.apply(.end)
        XCTAssertEqual(lifecycle.phase, .ending)
        lifecycle.apply(.ended)
        XCTAssertEqual(lifecycle.phase, .idle)

        lifecycle.apply(.fail("closed"))
        XCTAssertEqual(lifecycle.phase, .failed("closed"))
        lifecycle.apply(.start)
        XCTAssertEqual(lifecycle.phase, .starting)
    }

    func testRoomConnectionWaitsForAgentReadinessWithoutStoppingInitialFeedback() {
        var lifecycle = LiveTalkLifecycle()
        lifecycle.apply(.start)

        lifecycle.apply(.roomConnected(agentIsConnected: false))

        XCTAssertEqual(lifecycle.phase, .starting)
        XCTAssertEqual(
            LiveTalkConnectionFeedbackPolicy.soundAction(
                from: .starting,
                to: lifecycle.phase
            ),
            .none
        )

        lifecycle.apply(.roomConnected(agentIsConnected: true))

        XCTAssertEqual(lifecycle.phase, .connected)
        XCTAssertEqual(
            LiveTalkConnectionFeedbackPolicy.soundAction(
                from: .starting,
                to: lifecycle.phase
            ),
            .stop
        )
    }

    func testRoomConnectionPreservesReconnectUntilAgentReturns() {
        var lifecycle = LiveTalkLifecycle()
        lifecycle.apply(.start)
        lifecycle.apply(.roomConnected(agentIsConnected: true))
        lifecycle.apply(.reconnecting)

        lifecycle.apply(.roomConnected(agentIsConnected: false))
        XCTAssertEqual(lifecycle.phase, .reconnecting)

        lifecycle.apply(.roomConnected(agentIsConnected: true))
        XCTAssertEqual(lifecycle.phase, .connected)
    }

    func testNewPendingEmailRequestsOneReviewRevealOnly() {
        let firstID = UUID()
        let secondID = UUID()

        XCTAssertTrue(
            ConversationReviewRevealPolicy.shouldRevealPendingEmail(
                previousID: nil,
                currentID: firstID
            )
        )
        XCTAssertFalse(
            ConversationReviewRevealPolicy.shouldRevealPendingEmail(
                previousID: firstID,
                currentID: firstID
            )
        )
        XCTAssertFalse(
            ConversationReviewRevealPolicy.shouldRevealPendingEmail(
                previousID: firstID,
                currentID: nil
            )
        )
        XCTAssertTrue(
            ConversationReviewRevealPolicy.shouldRevealPendingEmail(
                previousID: firstID,
                currentID: secondID
            )
        )
    }

    func testTapToTalkIsBlockedWheneverLiveTalkOwnsTheMicrophone() {
        for phase in [
            LiveTalkConnectionPhase.starting,
            .connected,
            .reconnecting,
            .ending,
        ] {
            XCTAssertEqual(
                ConversationMicrophoneOwnership.tapToTalkBlockReason(
                    liveTalkPhase: phase
                ),
                "Hang up Live Talk before tap-to-talk."
            )
        }
        XCTAssertNil(
            ConversationMicrophoneOwnership.tapToTalkBlockReason(
                liveTalkPhase: .idle
            )
        )
        XCTAssertNil(
            ConversationMicrophoneOwnership.tapToTalkBlockReason(
                liveTalkPhase: .failed("Unavailable")
            )
        )
    }

    func testAvatarSwitchingIsBlockedUntilLiveTalkIsFullyInactive() {
        for phase in [
            LiveTalkConnectionPhase.starting,
            .connected,
            .reconnecting,
            .ending,
        ] {
            XCTAssertFalse(
                LiveTalkAvatarSwitchPolicy.allowsSwitch(during: phase),
                "Avatar switching must stay blocked during \(phase)."
            )
        }
        XCTAssertTrue(LiveTalkAvatarSwitchPolicy.allowsSwitch(during: .idle))
        XCTAssertTrue(
            LiveTalkAvatarSwitchPolicy.allowsSwitch(during: .failed("Unavailable"))
        )
        XCTAssertEqual(
            LiveTalkAvatarSwitchPolicy.blockedGuidance,
            "Hang up Live Talk before changing avatars."
        )
    }

    func testSidebarNavigationIsBlockedUntilLiveTalkIsFullyInactive() {
        for phase in [
            LiveTalkConnectionPhase.starting,
            .connected,
            .reconnecting,
            .ending,
        ] {
            XCTAssertEqual(
                ConversationLiveTalkNavigationPolicy.sidebarBlockReason(
                    liveTalkPhase: phase
                ),
                "Hang up Live Talk before changing avatars.",
                "Sidebar navigation must stay blocked during \(phase)."
            )
        }
        XCTAssertNil(
            ConversationLiveTalkNavigationPolicy.sidebarBlockReason(
                liveTalkPhase: .idle
            )
        )
        XCTAssertNil(
            ConversationLiveTalkNavigationPolicy.sidebarBlockReason(
                liveTalkPhase: .failed("Unavailable")
            )
        )
    }

    func testBYOKDisclosureCoversFollowAndMigratedPreviousSelections() throws {
        XCTAssertEqual(
            AvatarLiveTalkSettingsPresentation.credentialProvider(
                for: .followAvatar,
                stage: .tts,
                avatarSelection: .init(
                    provider: .xAI,
                    model: "xai-tts",
                    voice: "rex"
                )
            ),
            .xAI
        )

        let previous = try XCTUnwrap(
            LiveTalkCatalog.option(
                following: .init(provider: .openAI, model: "gpt-5.6-luna"),
                for: .llm
            )
        )
        XCTAssertEqual(
            AvatarLiveTalkSettingsPresentation.credentialProvider(
                for: .fixed(previous.selection),
                stage: .llm,
                avatarSelection: .init(provider: .apple, model: "unused")
            ),
            .openAI
        )
        XCTAssertNil(
            AvatarLiveTalkSettingsPresentation.credentialProvider(
                for: .managed,
                stage: .tts,
                avatarSelection: .init(
                    provider: .xAI,
                    model: "xai-tts",
                    voice: "rex"
                )
            )
        )
    }

    func testEmailDraftToolBridgeAcceptsOnlyTheClosedBoundedContract() throws {
        let requestID = String(repeating: "a", count: 64)
        let payload = """
        {
          "schema_version": 1,
          "request_id": "\(requestID)",
          "spoken_request": "Email Emma",
          "tool": {
            "name": "prepare_email_draft",
            "arguments": {
              "recipient_name": "Emma",
              "subject": "",
              "body": ""
            }
          }
        }
        """

        let request = try LiveTalkEmailDraftToolBridge.decodeRequest(payload)
        XCTAssertEqual(request.requestID, requestID)
        XCTAssertEqual(request.spokenRequest, "Email Emma")
        XCTAssertEqual(request.openAIToolCall.name, "prepare_email_draft")
        XCTAssertEqual(
            request.openAIToolCall.arguments["recipient_name"],
            .string("Emma")
        )

        for invalid in [
            payload.replacingOccurrences(
                of: #""schema_version": 1,"#,
                with: #""schema_version": 2,"#
            ),
            payload.replacingOccurrences(
                of: #""prepare_email_draft""#,
                with: #""prepare_message_draft""#
            ),
            payload.replacingOccurrences(
                of: #""spoken_request": "Email Emma","#,
                with: #""spoken_request": "Email Emma", "extra": true,"#
            ),
            payload.replacingOccurrences(of: requestID, with: "not-a-request-id"),
        ] {
            XCTAssertThrowsError(
                try LiveTalkEmailDraftToolBridge.decodeRequest(invalid)
            ) { error in
                XCTAssertEqual(
                    error as? LiveTalkEmailDraftToolBridgeError,
                    .invalidRequest
                )
            }
        }

        XCTAssertThrowsError(
            try LiveTalkEmailDraftToolBridge.decodeRequest(
                String(repeating: "x", count: LiveTalkEmailDraftToolBridge.maximumPayloadBytes + 1)
            )
        )
        let response = try LiveTalkEmailDraftToolBridge.encodeResponse(
            .presentedForReview
        )
        let responseObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(Set(responseObject.keys), ["schema_version", "status"])
        XCTAssertEqual(responseObject["schema_version"] as? Int, 1)
        XCTAssertEqual(responseObject["status"] as? String, "presented_for_review")
    }

    func testEmailDraftToolBridgeEnforcesTheSamePerFieldLimitsAsTheAgent() {
        let requestID = String(repeating: "a", count: 64)
        let payload = """
        {
          "schema_version": 1,
          "request_id": "\(requestID)",
          "spoken_request": "Email Emma",
          "tool": {
            "name": "prepare_email_draft",
            "arguments": {
              "recipient_name": "Emma",
              "subject": "",
              "body": ""
            }
          }
        }
        """
        let tooLongRecipient = String(
            repeating: "e",
            count: LiveTalkEmailDraftToolBridge.maximumRecipientCharacters + 1
        )
        let tooLongSubject = String(
            repeating: "s",
            count: LiveTalkEmailDraftToolBridge.maximumSubjectCharacters + 1
        )
        let tooLongUTF8Body = String(
            repeating: "🦀",
            count: LiveTalkEmailDraftToolBridge.maximumBodyBytes / 4 + 1
        )
        let tooManyRecipientCodePoints = String(
            repeating: "e\u{301}",
            count: LiveTalkEmailDraftToolBridge.maximumRecipientCharacters / 2 + 1
        )

        for invalid in [
            payload.replacingOccurrences(
                of: #""recipient_name": "Emma""#,
                with: #""recipient_name": "\#(tooLongRecipient)""#
            ),
            payload.replacingOccurrences(
                of: #""subject": """#,
                with: #""subject": "\#(tooLongSubject)""#
            ),
            payload.replacingOccurrences(
                of: #""body": """#,
                with: #""body": "\#(tooLongUTF8Body)""#
            ),
            payload.replacingOccurrences(
                of: #""recipient_name": "Emma""#,
                with: #""recipient_name": "\#(tooManyRecipientCodePoints)""#
            ),
        ] {
            XCTAssertThrowsError(
                try LiveTalkEmailDraftToolBridge.decodeRequest(invalid)
            ) { error in
                XCTAssertEqual(
                    error as? LiveTalkEmailDraftToolBridgeError,
                    .invalidRequest
                )
            }
        }
    }

    func testExplicitNewEmailIntentGateIsConservativeAndDeterministic() {
        for request in [
            "Email Emma",
            "Draft an email to Emma",
            "Please email Emma that I will be ten minutes late.",
            "Could you compose an email for Emma?",
            "Write Emma an email about tomorrow",
        ] {
            XCTAssertTrue(
                LiveTalkEmailDraftToolBridge.isExplicitNewEmailRequest(
                    request,
                    recipientName: "Emma"
                ),
                request
            )
        }

        for request in [
            "Do not email Emma",
            "Don't email Emma",
            "No, email Emma",
            "Yes, send it",
            "\"Email Emma\"",
            "Emma said email Emma",
            "I told the assistant to email Emma",
            "I emailed Emma yesterday",
            "I drafted an email to Emma",
            "Read Emma's email",
            "Show me the email from Emma",
        ] {
            XCTAssertFalse(
                LiveTalkEmailDraftToolBridge.isExplicitNewEmailRequest(
                    request,
                    recipientName: "Emma"
                ),
                request
            )
        }

        XCTAssertEqual(
            LiveTalkEmailDraftToolBridge.canonicalize("  EMAIL—Emma!  "),
            "email emma"
        )
    }

    func testEmailDraftRPCBindsToLatestFinalLiveKitUserTranscript() {
        let messages = [
            ReceivedMessage(
                id: "old-user",
                timestamp: Date(timeIntervalSince1970: 1),
                content: .userTranscript("Email Olivia"),
                isFinal: true
            ),
            ReceivedMessage(
                id: "typed-input",
                timestamp: Date(timeIntervalSince1970: 2),
                content: .userInput("Email Emma"),
                isFinal: true
            ),
            ReceivedMessage(
                id: "agent",
                timestamp: Date(timeIntervalSince1970: 3),
                content: .agentTranscript("Okay"),
                isFinal: true
            ),
            ReceivedMessage(
                id: "partial-user",
                timestamp: Date(timeIntervalSince1970: 4),
                content: .userTranscript("Email Emma and"),
                isFinal: false
            ),
        ]

        XCTAssertEqual(
            LiveTalkEmailDraftToolBridge.latestFinalUserTranscript(in: messages),
            "Email Olivia"
        )
        XCTAssertTrue(
            LiveTalkEmailDraftToolBridge.matchesLatestFinalUserTranscript(
                " email—OLIVIA! ",
                messages: messages
            )
        )
        XCTAssertFalse(
            LiveTalkEmailDraftToolBridge.matchesLatestFinalUserTranscript(
                "Email Emma",
                messages: messages
            )
        )
        XCTAssertFalse(
            LiveTalkEmailDraftToolBridge.matchesLatestFinalUserTranscript(
                "Email Olivia",
                messages: messages.filter { !$0.isFinal }
            )
        )
    }

    func testEmailDraftInvocationPolicyRejectsStaleUntrustedAndExpiredCalls() {
        XCTAssertTrue(
            LiveTalkEmailDraftInvocationPolicy.isCurrentSession(
                attemptMatches: true,
                roomMatches: true,
                phase: .connected
            )
        )
        XCTAssertTrue(
            LiveTalkEmailDraftInvocationPolicy.isCurrentSession(
                attemptMatches: true,
                roomMatches: true,
                phase: .reconnecting
            )
        )
        for (attemptMatches, roomMatches, phase) in [
            (false, true, LiveTalkConnectionPhase.connected),
            (true, false, LiveTalkConnectionPhase.connected),
            (true, true, LiveTalkConnectionPhase.starting),
            (true, true, LiveTalkConnectionPhase.ending),
            (true, true, LiveTalkConnectionPhase.idle),
        ] {
            XCTAssertFalse(
                LiveTalkEmailDraftInvocationPolicy.isCurrentSession(
                    attemptMatches: attemptMatches,
                    roomMatches: roomMatches,
                    phase: phase
                )
            )
        }

        XCTAssertTrue(
            LiveTalkEmailDraftInvocationPolicy.isTrustedCaller(
                trustedAgentCount: 1,
                callerIsTrusted: true
            )
        )
        XCTAssertFalse(
            LiveTalkEmailDraftInvocationPolicy.isTrustedCaller(
                trustedAgentCount: 1,
                callerIsTrusted: false
            )
        )
        XCTAssertFalse(
            LiveTalkEmailDraftInvocationPolicy.isTrustedCaller(
                trustedAgentCount: 2,
                callerIsTrusted: true
            )
        )
        XCTAssertFalse(
            LiveTalkEmailDraftInvocationPolicy.isTrustedCaller(
                trustedAgentCount: 0,
                callerIsTrusted: false
            )
        )

        XCTAssertTrue(LiveTalkEmailDraftInvocationPolicy.acceptsResponseTimeout(15))
        XCTAssertFalse(LiveTalkEmailDraftInvocationPolicy.acceptsResponseTimeout(0.5))
        XCTAssertFalse(LiveTalkEmailDraftInvocationPolicy.acceptsResponseTimeout(21))
        XCTAssertFalse(LiveTalkEmailDraftInvocationPolicy.acceptsResponseTimeout(.nan))
        XCTAssertTrue(
            LiveTalkEmailDraftInvocationPolicy.hasTimeRemaining(now: 10, deadline: 11)
        )
        XCTAssertFalse(
            LiveTalkEmailDraftInvocationPolicy.hasTimeRemaining(now: 11, deadline: 11)
        )
        XCTAssertFalse(
            LiveTalkEmailDraftInvocationPolicy.hasTimeRemaining(now: 12, deadline: 11)
        )
    }

    func testEmailDraftToolReplayWindowIsSessionBoundedAndRejectsReplay() {
        var replayWindow = LiveTalkToolReplayWindow()
        XCTAssertTrue(replayWindow.claim(String(repeating: "a", count: 64)))
        XCTAssertFalse(replayWindow.claim(String(repeating: "a", count: 64)))
        replayWindow.clear()
        XCTAssertTrue(replayWindow.claim(String(repeating: "a", count: 64)))

        var bounded = LiveTalkToolReplayWindow()
        for index in 0 ..< LiveTalkToolReplayWindow.maximumRequestCount {
            XCTAssertTrue(bounded.claim("request-\(index)"))
        }
        XCTAssertFalse(bounded.claim("one-too-many"))
    }

    func testLiveTalkEmailEmmaStagesOnlyAnEditableUnsentForegroundDraft() async {
        let model = ConversationModel()
        let messagesBefore = model.messages
        let request = LiveTalkEmailDraftToolRequest(
            requestID: String(repeating: "a", count: 64),
            spokenRequest: "Email Emma",
            recipientName: "Emma",
            subject: "",
            body: ""
        )

        let disposition = await model.stageLiveTalkEmailDraft(
            request,
            appIsActive: true
        )

        XCTAssertEqual(disposition, .presentedForReview)
        XCTAssertEqual(model.pendingEmail?.recipientQuery, "Emma")
        XCTAssertEqual(model.pendingEmail?.subject, "")
        XCTAssertEqual(model.pendingEmail?.body, "")
        XCTAssertNil(model.pendingEmail?.emailAddress)
        XCTAssertTrue(model.pendingEmail?.choices.isEmpty == true)
        XCTAssertNil(model.emailCommand())
        XCTAssertEqual(model.messages, messagesBefore)
    }

    func testSpokenSendItCannotConfirmOrMutateThePendingLiveTalkDraft() async {
        let model = ConversationModel()
        let initial = LiveTalkEmailDraftToolRequest(
            requestID: String(repeating: "a", count: 64),
            spokenRequest: "Email Emma that I will be ten minutes late",
            recipientName: "Emma",
            subject: "Running late",
            body: "I will be ten minutes late."
        )
        let initialDisposition = await model.stageLiveTalkEmailDraft(
            initial,
            appIsActive: true
        )
        XCTAssertEqual(initialDisposition, .presentedForReview)
        let pendingID = model.pendingEmail?.id
        let pendingSubject = model.pendingEmail?.subject
        let pendingBody = model.pendingEmail?.body

        let spokenApproval = LiveTalkEmailDraftToolRequest(
            requestID: String(repeating: "b", count: 64),
            spokenRequest: "Yes, send it",
            recipientName: "Emma",
            subject: "Changed by approval",
            body: "This must not replace the visible draft."
        )
        let approvalDisposition = await model.stageLiveTalkEmailDraft(
            spokenApproval,
            appIsActive: true
        )
        XCTAssertEqual(approvalDisposition, .rejected)
        XCTAssertEqual(model.pendingEmail?.id, pendingID)
        XCTAssertEqual(model.pendingEmail?.subject, pendingSubject)
        XCTAssertEqual(model.pendingEmail?.body, pendingBody)
        XCTAssertNil(model.pendingEmail?.emailAddress)
        XCTAssertNil(model.emailCommand())
    }

    func testSpokenSendItCannotStageAnythingWithoutAPendingDraft() async {
        let model = ConversationModel()
        let spokenApproval = LiveTalkEmailDraftToolRequest(
            requestID: String(repeating: "a", count: 64),
            spokenRequest: "Yes, send it",
            recipientName: "yes",
            subject: "Should not appear",
            body: "This must never become a draft."
        )

        let disposition = await model.stageLiveTalkEmailDraft(
            spokenApproval,
            appIsActive: true
        )

        XCTAssertEqual(disposition, .rejected)
        XCTAssertNil(model.pendingEmail)
        XCTAssertNil(model.emailCommand())
    }

    func testLiveTalkModelRejectsNegatedReportedPastReadAndOversizedRequests() async {
        for spokenRequest in [
            "Do not email Emma",
            "Emma said email Emma",
            "I emailed Emma yesterday",
            "Read Emma's email",
        ] {
            let model = ConversationModel()
            let request = LiveTalkEmailDraftToolRequest(
                requestID: String(repeating: "a", count: 64),
                spokenRequest: spokenRequest,
                recipientName: "Emma",
                subject: "",
                body: ""
            )

            let disposition = await model.stageLiveTalkEmailDraft(
                request,
                appIsActive: true
            )
            XCTAssertEqual(disposition, .rejected, spokenRequest)
            XCTAssertNil(model.pendingEmail)
            XCTAssertNil(model.emailCommand())
        }

        let model = ConversationModel()
        let oversizedBody = String(
            repeating: "🦀",
            count: LiveTalkEmailDraftToolBridge.maximumBodyBytes / 4 + 1
        )
        let oversized = LiveTalkEmailDraftToolRequest(
            requestID: String(repeating: "b", count: 64),
            spokenRequest: "Email Emma",
            recipientName: "Emma",
            subject: "",
            body: oversizedBody
        )
        let oversizedDisposition = await model.stageLiveTalkEmailDraft(
            oversized,
            appIsActive: true
        )
        XCTAssertEqual(oversizedDisposition, .rejected)
        XCTAssertNil(model.pendingEmail)
        XCTAssertNil(model.emailCommand())
    }

    func testNewSpokenEmailCannotOverwriteADraftAwaitingReview() async {
        let model = ConversationModel()
        let initial = LiveTalkEmailDraftToolRequest(
            requestID: String(repeating: "a", count: 64),
            spokenRequest: "Email Emma",
            recipientName: "Emma",
            subject: "First draft",
            body: "Keep this draft."
        )
        let initialDisposition = await model.stageLiveTalkEmailDraft(
            initial,
            appIsActive: true
        )
        XCTAssertEqual(initialDisposition, .presentedForReview)
        let pendingID = model.pendingEmail?.id

        let replacement = LiveTalkEmailDraftToolRequest(
            requestID: String(repeating: "b", count: 64),
            spokenRequest: "Email Olivia",
            recipientName: "Olivia",
            subject: "Replacement",
            body: "This must not overwrite the first draft."
        )
        let replacementDisposition = await model.stageLiveTalkEmailDraft(
            replacement,
            appIsActive: true
        )
        XCTAssertEqual(replacementDisposition, .rejected)
        XCTAssertEqual(model.pendingEmail?.id, pendingID)
        XCTAssertEqual(model.pendingEmail?.recipientQuery, "Emma")
        XCTAssertEqual(model.pendingEmail?.subject, "First draft")
        XCTAssertEqual(model.pendingEmail?.body, "Keep this draft.")
    }

    func testLiveTalkDraftRequiresTheForegroundBeforeStaging() async {
        let model = ConversationModel()
        let request = LiveTalkEmailDraftToolRequest(
            requestID: String(repeating: "a", count: 64),
            spokenRequest: "Email Emma",
            recipientName: "Emma",
            subject: "",
            body: ""
        )

        let disposition = await model.stageLiveTalkEmailDraft(
            request,
            appIsActive: false
        )
        XCTAssertEqual(disposition, .foregroundRequired)
        XCTAssertNil(model.pendingEmail)
    }

    func testStopCancelsInFlightStartBeforeEndingSession() async {
        let started = expectation(description: "start operation entered")
        let cancelled = expectation(description: "start operation cancelled")
        let ended = expectation(description: "room ended")
        let events = LiveTalkLifecycleEventRecorder()
        let controller = LiveTalkSessionController(
            credentialVault: InMemoryProviderCredentialVault(),
            configurationLoader: {
                .init(
                    sessionEndpoint: URL(
                        string: "https://broker.example/v1/live-talk/sessions"
                    )!,
                    appToken: String(repeating: "p", count: 32),
                    expectedServerHost: "expected.livekit.cloud"
                )
            },
            sessionStarter: { _ in
                await events.append("start")
                started.fulfill()
                await withTaskCancellationHandler {
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {}
                } onCancel: {
                    cancelled.fulfill()
                }
            },
            sessionEnder: { _ in
                await events.append("end")
                ended.fulfill()
            }
        )

        controller.begin(
            avatar: .init(id: "captain-ayer", displayName: "Captain Ayer"),
            sharedSettings: .init(),
            avatarController: CaptainAyerLipSyncController()
        )
        await fulfillment(of: [started], timeout: 2)

        await controller.stop()

        await fulfillment(of: [cancelled, ended], timeout: 2)
        XCTAssertEqual(controller.phase, .idle)
        let recordedEvents = await events.values()
        XCTAssertEqual(recordedEvents, ["start", "end"])
    }

    func testTranscriptPanelIsBoundedAndRemoteAudioCanDriveAvatar() {
        let messages = (0..<20).map { index in
            ReceivedMessage(
                id: "m\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                content: index.isMultiple(of: 2)
                    ? .userTranscript("user \(index)")
                    : .agentTranscript("agent \(index)"),
                isFinal: true
            )
        }

        let transcripts = LiveTalkSessionController.boundedTranscripts(
            from: messages,
            limit: 12
        )

        XCTAssertEqual(transcripts.count, 12)
        XCTAssertEqual(transcripts.first?.id, "m8")
        XCTAssertTrue(
            LiveTalkRemoteAudioActivity.isActive(
                reportedSpeaking: false,
                audioLevel: LiveTalkRemoteAudioActivity.audibleThreshold + 0.001
            )
        )
        XCTAssertFalse(
            LiveTalkRemoteAudioActivity.isActive(reportedSpeaking: false, audioLevel: 0)
        )
    }

    func testTranscriptWindowClearsWhenSessionBoundaryEnds() {
        var window = LiveTalkTranscriptWindow()
        window.replace(
            with: [
                .init(id: "user", role: .user, text: "private words", isFinal: true),
                .init(id: "agent", role: .agent, text: "private reply", isFinal: true),
            ]
        )

        XCTAssertEqual(window.items.count, 2)
        window.clear()
        XCTAssertTrue(window.items.isEmpty)
    }

    private func option(
        stage: LiveTalkStage,
        provider: String
    ) -> LiveTalkProviderOption? {
        LiveTalkCatalog.options(for: stage).first(where: {
            $0.selection.provider == provider
        })
    }

    private func byokTupleSignatures(for stage: LiveTalkStage) -> Set<String> {
        Set(
            LiveTalkCatalog.options(for: stage)
                .filter { $0.selection.source == .byok }
                .map { option in
                    let selection = option.selection
                    return [
                        selection.provider,
                        selection.model,
                        selection.voice ?? "-",
                        selection.language ?? "-",
                    ].joined(separator: "|")
                }
        )
    }

    private func managedTTSTupleSignatures() -> Set<String> {
        Set(
            LiveTalkCatalog.managedOptions(for: .tts).map { option in
                "\(option.title)|\(option.selection.voice ?? "-")"
            }
        )
    }
}

private actor LiveTalkLifecycleEventRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}

private actor LiveTalkBrokerRequestRecorder {
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func snapshot() -> [URLRequest] {
        requests
    }
}
