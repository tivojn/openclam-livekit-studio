import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OpenClamLiveKit

final class CloudVoiceServiceTests: XCTestCase {
    func testSpeechProviderLimitsAcceptBelowAndAtBoundaryButRejectAbove() throws {
        let providers: [AIProviderID] = [
            .openAI, .openRouter, .elevenLabs, .soniox, .gemini, .xAI,
        ]

        for provider in providers {
            let maximum = CloudSpeechTextLimits.maximumInputBytes(for: provider)
            let below = String(repeating: "a", count: maximum - 1)
            let at = String(repeating: "a", count: maximum)
            let above = String(repeating: "a", count: maximum + 1)

            XCTAssertEqual(
                try CloudVoiceRequestSupport.text(below, maximumBytes: maximum),
                below,
                "\(provider) should accept one byte below its limit."
            )
            XCTAssertEqual(
                try CloudVoiceRequestSupport.text(at, maximumBytes: maximum),
                at,
                "\(provider) should accept its exact byte limit."
            )
            XCTAssertThrowsError(
                try CloudVoiceRequestSupport.text(above, maximumBytes: maximum),
                "\(provider) must reject one byte above its limit."
            ) { error in
                XCTAssertEqual(error as? CloudVoiceServiceError, .invalidText)
            }
            XCTAssertEqual(
                CloudSpeechTextLimits.safeChunkBytes(for: provider),
                maximum - CloudSpeechTextLimits.chunkHeadroomBytes
            )
        }
    }

    func testSpeechNormalizationRemovesUnsafeControlsButPreservesSemanticUnicode() throws {
        let family = "👩🏽‍💻"
        let raw = " \u{0000}\tCafe\u{0301}\r\n你好\u{0007}  \(family)\u{200E} مرحبا  "
        let plan = try CloudSpeechTextPlanner.plan(raw, provider: .openAI)

        XCTAssertEqual(plan.normalizedText, "Café 你好 \(family)\u{200E} مرحبا")
        XCTAssertEqual(plan.reconstructedText, plan.normalizedText)
        XCTAssertFalse(
            plan.normalizedText.unicodeScalars.contains {
                $0.properties.generalCategory == .control
            }
        )
        XCTAssertTrue(
            plan.normalizedText.unicodeScalars.contains { $0.value == 0x200D },
            "Emoji ZWJ must survive."
        )
        XCTAssertTrue(
            plan.normalizedText.unicodeScalars.contains { $0.value == 0x200E },
            "Direction marks are semantic format scalars."
        )
    }

    func testHugeMultilingualSpeechPlanPreservesEveryNormalizedCharacterInOrder() throws {
        let paragraph = "Part one keeps emoji 👨‍👩‍👧‍👦 and café. 第二段保留中文、かな、한글。 مرحبا بالعالم!\n"
        let raw = String(repeating: paragraph, count: 900)
        let plan = try CloudSpeechTextPlanner.plan(raw, provider: .openAI)
        let safeLimit = CloudSpeechTextLimits.safeChunkBytes(for: .openAI)

        XCTAssertGreaterThan(plan.normalizedText.utf8.count, safeLimit * 10)
        XCTAssertGreaterThan(plan.chunks.count, 10)
        XCTAssertEqual(plan.reconstructedText, plan.normalizedText)
        for chunk in plan.chunks {
            XCTAssertFalse(chunk.text.isEmpty)
            XCTAssertLessThanOrEqual(chunk.text.utf8.count, safeLimit)
            XCTAssertEqual(
                try CloudVoiceRequestSupport.text(
                    chunk.text,
                    maximumBytes: CloudSpeechTextLimits.maximumInputBytes(for: .openAI)
                ),
                chunk.text
            )
        }
    }

    func testSpeechPlannerNeverSplitsExtendedGraphemeClusters() throws {
        let grapheme = "👩🏽‍💻"
        let raw = Array(repeating: grapheme, count: 2_000).joined()
        let plan = try CloudSpeechTextPlanner.plan(raw, provider: .openAI)

        XCTAssertGreaterThan(plan.chunks.count, 1)
        XCTAssertEqual(plan.reconstructedText, raw)
        XCTAssertTrue(
            plan.chunks.allSatisfy { chunk in
                chunk.text.allSatisfy { String($0) == grapheme }
            }
        )
    }

    func testSpeechPlannerPrefersSentenceBoundaryBeforeHardLimit() throws {
        let first = String(repeating: "a", count: 2_200) + "."
        let second = String(repeating: "b", count: 2_200) + "."
        let plan = try CloudSpeechTextPlanner.plan("\(first) \(second)", provider: .openAI)

        XCTAssertEqual(plan.chunks.count, 2)
        XCTAssertEqual(plan.chunks[0].text, first)
        XCTAssertEqual(plan.chunks[1].separatorBefore, " ")
        XCTAssertEqual(plan.chunks[1].text, second)
        XCTAssertEqual(plan.reconstructedText, plan.normalizedText)
    }

    func testSpeechSequenceAdvancesOnlyAfterConfirmedCompletionAndKeepsOrder() throws {
        let plan = try CloudSpeechTextPlanner.plan(
            String(repeating: "Sentence with ordered content. ", count: 1_000),
            provider: .openAI
        )
        var sequence = SpeechOutputSequence(generation: 41, chunks: plan.chunks)
        var spoken: [CloudSpeechTextChunk] = []

        while let part = sequence.beginNextPart() {
            XCTAssertNil(
                sequence.beginNextPart(),
                "A second part must not begin while the current part is active."
            )
            spoken.append(part.chunk)
            let isComplete = sequence.completeActivePart()
            XCTAssertEqual(isComplete, spoken.count == plan.chunks.count)
        }

        XCTAssertEqual(spoken, plan.chunks)
        XCTAssertEqual(
            spoken.map { $0.separatorBefore + $0.text }.joined(),
            plan.normalizedText
        )
    }

    func testMidSequenceFailureNamesPartAndRequiresExplicitRetryFromStart() {
        let chunks = [
            CloudSpeechTextChunk(separatorBefore: "", text: "One."),
            CloudSpeechTextChunk(separatorBefore: " ", text: "Two."),
            CloudSpeechTextChunk(separatorBefore: " ", text: "Three."),
        ]
        var sequence = SpeechOutputSequence(generation: 8, chunks: chunks)
        _ = sequence.beginNextPart()
        XCTAssertFalse(sequence.completeActivePart())
        _ = sequence.beginNextPart()

        XCTAssertEqual(sequence.activePartNumber, 2)
        XCTAssertEqual(
            sequence.failureMessage(detail: "Provider unavailable."),
            "Speech stopped at part 2 of 3: Provider unavailable. Tap Read Aloud to retry from the beginning."
        )
        XCTAssertNil(sequence.beginNextPart(), "Failure cannot silently skip the active part.")
    }

    @MainActor
    func testLongSpeechCancellationInvalidatesGenerationAndResetsLipSync() {
        var releaseCount = 0
        let lifecycle = SpeechOutputLifecycleCoordinator { releaseCount += 1 }
        let avatar = CaptainAyerLipSyncController()
        let generation = lifecycle.begin()
        lifecycle.markAudioSessionActive(for: generation)
        avatar.prepare(text: "First long part", generation: generation)
        avatar.begin(generation: generation, duration: 2)
        XCTAssertTrue(avatar.isSpeaking)

        let shouldDeactivate = lifecycle.invalidate()
        avatar.cancelAll()
        lifecycle.deactivateAfterExplicitStop(ifNeeded: shouldDeactivate)

        XCTAssertFalse(lifecycle.finish(generation), "A stale completion cannot revive speech.")
        XCTAssertEqual(avatar.phase, .idle)
        XCTAssertNil(avatar.generation)
        XCTAssertEqual(releaseCount, 1)
    }

    @MainActor
    func testSuccessfulMultiPartLipSyncUsesOneGenerationAndFinishesOnce() {
        var releaseCount = 0
        let lifecycle = SpeechOutputLifecycleCoordinator { releaseCount += 1 }
        let avatar = CaptainAyerLipSyncController()
        let chunks = [
            CloudSpeechTextChunk(separatorBefore: "", text: "First part."),
            CloudSpeechTextChunk(separatorBefore: " ", text: "第二部分。"),
            CloudSpeechTextChunk(separatorBefore: " ", text: "Emoji 🙂 finish."),
        ]
        let generation = lifecycle.begin()
        lifecycle.markAudioSessionActive(for: generation)
        var sequence = SpeechOutputSequence(generation: generation, chunks: chunks)

        while let part = sequence.beginNextPart() {
            avatar.prepare(text: part.chunk.text, generation: generation)
            avatar.begin(generation: generation, duration: 1)
            XCTAssertTrue(avatar.isSpeaking)
            if sequence.completeActivePart() {
                XCTAssertTrue(lifecycle.finish(generation))
                avatar.finish(generation: generation)
            }
        }

        XCTAssertEqual(avatar.phase, .idle)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertFalse(lifecycle.finish(generation))
    }

    @MainActor
    func testPronunciationReplacesAssistantSpeechWithoutPublishingCancellationError() async throws {
        let directory = try temporaryDirectory()
        let suiteName = "PronunciationSpeechReplacement-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        preferences.set(true, forKey: "assistant.tts-enabled")
        var releaseCount = 0
        let lifecycle = SpeechOutputLifecycleCoordinator { releaseCount += 1 }
        let model = ConversationModel(
            preferences: preferences,
            historyController: ConversationHistoryController(
                store: ConversationHistoryStore(
                    fileURL: directory.appendingPathComponent("history.json")
                )
            ),
            speechOutputLifecycle: lifecycle
        )
        defer {
            model.stopSpeechOutput()
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let historyIsReady = await model.ensureHistoryReady()
        XCTAssertTrue(historyIsReady)
        model.analyzePronunciation("hello")
        XCTAssertNotNil(model.pronunciation)

        model.readAssistantReplyAloud(
            String(repeating: "This assistant response is still speaking. ", count: 80)
        )
        XCTAssertTrue(model.isSpeechOutputActive)

        model.speakPronunciation()

        XCTAssertFalse(model.isSpeechOutputActive)
        XCTAssertNil(model.speechOutputError)
        XCTAssertEqual(model.captainAyerAvatar.phase, .idle)
        XCTAssertEqual(releaseCount, 1)
    }

    @MainActor
    func testInvalidatedAssistantUtteranceCancellationCannotCompleteReplacement() {
        let lifecycle = SpeechOutputLifecycleCoordinator {}
        let proxy = SpeechOutputDelegateProxy()
        let synthesizer = AVSpeechSynthesizer()
        let replacedUtterance = AVSpeechUtterance(string: "Replaced assistant speech")
        let replacedGeneration = lifecycle.begin()
        var completion: (generation: Int, error: String?)?
        proxy.onCompletion = { completion = (generation: $0, error: $1) }
        proxy.register(replacedUtterance, generation: replacedGeneration)

        _ = lifecycle.invalidate()
        proxy.invalidateAll()
        let replacementGeneration = lifecycle.begin()
        proxy.speechSynthesizer(
            synthesizer,
            didCancel: replacedUtterance
        )

        XCTAssertNil(completion)
        XCTAssertTrue(lifecycle.isCurrent(replacementGeneration))
    }

    func testOpenAITTSUsesPinnedEndpointAndBoundedMP3Request() async throws {
        let transport = CloudVoiceRecordingTransport(responses: [
            .init(data: Data([1, 2, 3]), statusCode: 200),
        ])
        let service = OpenAICloudVoiceService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "openai-fake-key"),
            transport: transport
        )

        let audio = try await service.synthesize(.init(
            text: "Hello",
            model: "tts-1",
            voice: "alloy"
        ))

        XCTAssertEqual(audio, .init(data: Data([1, 2, 3]), mimeType: "audio/mpeg"))
        XCTAssertEqual(service.requestStorageBehavior, .providerDefaultNoRequestFlag)
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url, OpenAICloudVoiceService.speechEndpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openai-fake-key")
        let body = try jsonObject(request)
        XCTAssertEqual(body["input"] as? String, "Hello")
        XCTAssertEqual(body["model"] as? String, "tts-1")
        XCTAssertEqual(body["voice"] as? String, "alloy")
        XCTAssertEqual(body["response_format"] as? String, "mp3")
        XCTAssertNil(body["store"])
    }

    func testOpenAISTTUsesMultipartWithoutEmbeddingCredential() async throws {
        let transport = CloudVoiceRecordingTransport(responses: [
            .json(#"{"text":"Hello world"}"#),
        ])
        let service = OpenAICloudVoiceService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "openai-fake-key"),
            transport: transport
        )

        let result = try await service.transcribe(.init(
            audioData: Data([0, 1, 2]),
            filename: "voice.m4a",
            mimeType: "audio/mp4",
            model: "gpt-4o-mini-transcribe",
            languageCode: "en"
        ))

        XCTAssertEqual(result.text, "Hello world")
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url, OpenAICloudVoiceService.transcriptionEndpoint)
        let body = try XCTUnwrap(request.httpBody)
        let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(bodyText.contains("name=\"model\"\r\n\r\ngpt-4o-mini-transcribe"))
        XCTAssertTrue(bodyText.contains("filename=\"voice.m4a\""))
        XCTAssertFalse(bodyText.contains("openai-fake-key"))
    }

    func testXAIVoiceUsesOfficialBoundedRESTSpeechEndpoints() async throws {
        let transport = CloudVoiceRecordingTransport(responses: [
            .init(data: Data([9, 8, 7]), statusCode: 200),
            .json(#"{"text":"xAI transcript","language":"","duration":1.2}"#),
        ])
        let service = XAICloudVoiceService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "xai-fake-key"),
            transport: transport
        )

        let audio = try await service.synthesize(.init(
            text: "Hello from xAI",
            model: "xai-tts",
            voice: "eve",
            languageCode: "en"
        ))
        let transcript = try await service.transcribe(.init(
            audioData: Data([0, 1, 2]),
            filename: "voice.m4a",
            mimeType: "audio/mp4",
            model: "grok-transcribe",
            languageCode: "en"
        ))

        XCTAssertEqual(audio, .init(data: Data([9, 8, 7]), mimeType: "audio/mpeg"))
        XCTAssertEqual(transcript.text, "xAI transcript")
        XCTAssertEqual(service.requestStorageBehavior, .providerDefaultNoRequestFlag)
        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.url), [
            XAICloudVoiceService.speechEndpoint,
            XAICloudVoiceService.transcriptionEndpoint,
        ])
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer xai-fake-key", "Bearer xai-fake-key"]
        )
        let speechBody = try jsonObject(requests[0])
        XCTAssertEqual(speechBody["voice_id"] as? String, "eve")
        XCTAssertEqual(speechBody["language"] as? String, "en")
        XCTAssertEqual((speechBody["output_format"] as? [String: Any])?["codec"] as? String, "mp3")
        let transcriptionBody = try XCTUnwrap(String(data: requests[1].httpBody!, encoding: .utf8))
        XCTAssertTrue(transcriptionBody.contains("filename=\"voice.m4a\""))
        XCTAssertTrue(transcriptionBody.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertTrue(transcriptionBody.contains("name=\"format\"\r\n\r\ntrue"))
        XCTAssertFalse(transcriptionBody.contains("xai-fake-key"))
    }

    func testXAITranscriptionAutoOmitsLanguageAndFormattingFields() async throws {
        let transport = CloudVoiceRecordingTransport(responses: [
            .json(#"{"text":"automatic transcript"}"#),
        ])
        let service = XAICloudVoiceService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "xai-fake-key"),
            transport: transport
        )

        let transcript = try await service.transcribe(.init(
            audioData: Data([0, 1, 2]),
            filename: "voice.m4a",
            mimeType: "audio/mp4",
            model: "grok-transcribe",
            languageCode: nil
        ))

        XCTAssertEqual(transcript.text, "automatic transcript")
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(String(data: request.httpBody!, encoding: .utf8))
        XCTAssertFalse(body.contains("name=\"language\""))
        XCTAssertFalse(body.contains("name=\"format\""))
    }

    func testDeepgramNova3UsesPinnedAutoMultilingualRequestContract() async throws {
        let transport = CloudVoiceRecordingTransport(responses: [
            .json(#"{"results":{"channels":[{"alternatives":[{"transcript":"你好, hello"}]}]}}"#),
        ])
        let service = DeepgramCloudSpeechToTextService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "deepgram-fake-key"),
            transport: transport
        )
        let audio = Data([7, 6, 5, 4])

        let transcript = try await service.transcribe(.init(
            audioData: audio,
            filename: "voice.wav",
            mimeType: "audio/wav",
            model: "nova-3",
            languageCode: nil
        ))

        XCTAssertEqual(transcript.text, "你好, hello")
        XCTAssertEqual(service.requestStorageBehavior, .providerDefaultLogging)
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api.deepgram.com")
        XCTAssertEqual(components.path, "/v1/listen")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }),
            ["model": "nova-3", "language": "multi", "smart_format": "true"]
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token deepgram-fake-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        XCTAssertEqual(request.httpBody, audio)
        XCTAssertFalse(
            try XCTUnwrap(String(data: request.httpBody!, encoding: .isoLatin1))
                .contains("deepgram-fake-key")
        )
    }

    func testDeepgramRejectsUnknownModelLanguageAndOversizedAudioBeforeNetwork() async throws {
        let transport = CloudVoiceRecordingTransport(responses: [])
        let service = DeepgramCloudSpeechToTextService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "deepgram-fake-key"),
            transport: transport
        )
        let base = CloudTranscriptionRequest(
            audioData: Data([1]),
            filename: "voice.wav",
            mimeType: "audio/wav",
            model: "nova-3",
            languageCode: "multi"
        )

        do {
            _ = try await service.transcribe(.init(
                audioData: base.audioData,
                filename: base.filename,
                mimeType: base.mimeType,
                model: "future-model",
                languageCode: base.languageCode
            ))
            XCTFail("An unreviewed Deepgram model must fail before networking.")
        } catch {
            XCTAssertEqual(error as? CloudVoiceServiceError, .invalidIdentifier)
        }
        do {
            _ = try await service.transcribe(.init(
                audioData: base.audioData,
                filename: base.filename,
                mimeType: base.mimeType,
                model: base.model,
                languageCode: "auto"
            ))
            XCTFail("Deepgram must use its explicit multi contract, not auto.")
        } catch {
            XCTAssertEqual(error as? CloudVoiceServiceError, .invalidLanguage)
        }
        do {
            _ = try await service.transcribe(.init(
                audioData: Data(
                    repeating: 0,
                    count: CloudVoiceRequestSupport.maximumAudioInputBytes + 1
                ),
                filename: base.filename,
                mimeType: base.mimeType,
                model: base.model,
                languageCode: base.languageCode
            ))
            XCTFail("Oversized audio must fail before networking.")
        } catch {
            XCTAssertEqual(error as? CloudVoiceServiceError, .invalidAudio)
        }
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testOpenRouterVoiceUsesDedicatedCapabilityEndpointsAndProviderScopedBearerKey() async throws {
        let transport = CloudVoiceRecordingTransport(responses: [
            .init(data: Data([5, 4, 3]), statusCode: 200),
            .json(#"{"text":"OpenRouter transcript","usage":{"seconds":1.0}}"#),
        ])
        let service = OpenRouterCloudVoiceService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "openrouter-fake-key"),
            transport: transport
        )

        let audio = try await service.synthesize(.init(
            text: "Hello from OpenRouter",
            model: "openai/gpt-4o-mini-tts-2025-12-15",
            voice: "nova"
        ))
        let transcript = try await service.transcribe(.init(
            audioData: Data([0, 1, 2]),
            filename: "voice.m4a",
            mimeType: "audio/mp4",
            model: "openai/whisper-large-v3",
            languageCode: "en"
        ))

        XCTAssertEqual(audio, .init(data: Data([5, 4, 3]), mimeType: "audio/mpeg"))
        XCTAssertEqual(transcript.text, "OpenRouter transcript")
        XCTAssertEqual(service.requestStorageBehavior, .providerDefaultLogging)
        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.url), [
            OpenRouterCloudVoiceService.speechEndpoint,
            OpenRouterCloudVoiceService.transcriptionEndpoint,
        ])
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer openrouter-fake-key", "Bearer openrouter-fake-key"]
        )

        let speechBody = try jsonObject(requests[0])
        XCTAssertEqual(speechBody["input"] as? String, "Hello from OpenRouter")
        XCTAssertEqual(
            speechBody["model"] as? String,
            "openai/gpt-4o-mini-tts-2025-12-15"
        )
        XCTAssertEqual(speechBody["voice"] as? String, "nova")
        XCTAssertEqual(speechBody["response_format"] as? String, "mp3")

        let transcriptionBody = try jsonObject(requests[1])
        XCTAssertEqual(transcriptionBody["model"] as? String, "openai/whisper-large-v3")
        XCTAssertEqual(transcriptionBody["language"] as? String, "en")
        let inputAudio = try XCTUnwrap(transcriptionBody["input_audio"] as? [String: Any])
        XCTAssertEqual(inputAudio["format"] as? String, "m4a")
        XCTAssertEqual(inputAudio["data"] as? String, Data([0, 1, 2]).base64EncodedString())
        XCTAssertFalse(
            try XCTUnwrap(String(data: requests[1].httpBody!, encoding: .utf8))
                .contains("openrouter-fake-key")
        )
    }

    func testGeminiTTSUsesInteractionsStoreFalseAndDecodesPCM() async throws {
        let pcm = Data([10, 11, 12, 13])
        let transport = CloudVoiceRecordingTransport(responses: [
            .json(#"{"output_audio":{"data":"\#(pcm.base64EncodedString())"}}"#),
        ])
        let service = GeminiCloudTextToSpeechService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "gemini-fake-key"),
            transport: transport
        )

        let audio = try await service.synthesize(.init(
            text: "Have a wonderful day",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Kore",
            languageCode: "en-US"
        ))

        XCTAssertEqual(audio.data, pcm)
        XCTAssertEqual(audio.mimeType, "audio/L16;rate=24000;channels=1")
        XCTAssertEqual(service.requestStorageBehavior, .storeFalse)
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url, GeminiCloudTextToSpeechService.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-fake-key")
        let body = try jsonObject(request)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "audio")
    }

    func testElevenLabsVoiceAdaptersUseOfficialEndpointsAndProviderDefaultLogging() async throws {
        let transport = CloudVoiceRecordingTransport(responses: [
            .init(data: Data([3, 2, 1]), statusCode: 200),
            .json(#"{"text":"A transcript"}"#),
        ])
        let service = ElevenLabsCloudVoiceService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "eleven-fake-key"),
            transport: transport
        )

        _ = try await service.synthesize(.init(
            text: "Hello",
            model: "eleven_multilingual_v2",
            voice: "JBFqnCBsd6RMkjVDRZzb"
        ))
        let transcript = try await service.transcribe(.init(
            audioData: Data([1, 2]),
            filename: "note.wav",
            mimeType: "audio/wav",
            model: "scribe_v2"
        ))

        XCTAssertEqual(transcript.text, "A transcript")
        XCTAssertEqual(service.requestStorageBehavior, .providerDefaultLogging)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb")
        XCTAssertEqual(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "output_format" })?.value,
            "mp3_44100_128"
        )
        XCTAssertNil(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "enable_logging" })
        )
        XCTAssertEqual(requests[1].url, ElevenLabsCloudVoiceService.transcriptionEndpoint)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "xi-api-key"), "eleven-fake-key")
    }

    func testElevenLabsRejectsPathInjectionBeforeNetworkUse() async throws {
        let transport = CloudVoiceRecordingTransport(responses: [])
        let service = ElevenLabsCloudVoiceService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "eleven-fake-key"),
            transport: transport
        )

        do {
            _ = try await service.synthesize(.init(
                text: "Hello",
                model: "eleven_multilingual_v2",
                voice: "../other-endpoint"
            ))
            XCTFail("Expected path injection to be rejected")
        } catch {
            XCTAssertEqual(error as? CloudVoiceServiceError, .invalidIdentifier)
        }
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testSonioxTTSRequiresLanguageAndUsesPinnedRawAudioEndpoint() async throws {
        let transport = CloudVoiceRecordingTransport(responses: [
            .init(data: Data([4, 5, 6]), statusCode: 200),
        ])
        let service = SonioxCloudTextToSpeechService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "soniox-fake-key"),
            transport: transport
        )

        _ = try await service.synthesize(.init(
            text: "Hello",
            model: "tts-rt-v1",
            voice: "Adrian",
            languageCode: "en"
        ))

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url, SonioxCloudTextToSpeechService.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer soniox-fake-key")
        let body = try jsonObject(request)
        XCTAssertEqual(body["audio_format"] as? String, "mp3")
        XCTAssertEqual(body["language"] as? String, "en")
        XCTAssertNil(body["store"])
    }

    func testSonioxRealtimeSTTStreamsBoundedPCMAndHandlesFinalEndpointTokens() async throws {
        let socket = RecordingCloudVoiceWebSocketTask(received: [
            .string(#"{"tokens":[{"text":"Hel","is_final":false},{"text":"lo","is_final":false}],"final_audio_proc_ms":0,"total_audio_proc_ms":240}"#),
            .string(#"{"tokens":[{"text":"Hello","is_final":true},{"text":" wor","is_final":false}],"final_audio_proc_ms":400,"total_audio_proc_ms":520}"#),
            .string(#"{"tokens":[{"text":" world","is_final":true},{"text":"<end>","is_final":true}],"final_audio_proc_ms":760,"total_audio_proc_ms":760}"#),
            .string(#"{"tokens":[],"final_audio_proc_ms":760,"total_audio_proc_ms":760,"finished":true}"#),
        ])
        let factory = RecordingCloudVoiceWebSocketTaskFactory(task: socket)
        let service = SonioxRealtimeSpeechToTextService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "soniox-fake-key"),
            socketFactory: factory
        )

        let session = try await service.startSession(model: "stt-rt-v5", languageCode: "en")
        try await session.sendPCM(Data([1, 0, 2, 0]))
        let provisional = try await session.receiveUpdate()
        XCTAssertEqual(
            provisional,
            .init(text: "Hello", isFinal: false, endpointDetected: false, isFinished: false)
        )
        let mixed = try await session.receiveUpdate()
        XCTAssertEqual(
            mixed,
            .init(text: "Hello wor", isFinal: false, endpointDetected: false, isFinished: false)
        )
        let endpoint = try await session.receiveUpdate()
        XCTAssertEqual(
            endpoint,
            .init(text: "Hello world", isFinal: true, endpointDetected: true, isFinished: false)
        )
        try await session.finishAudio()
        let finished = try await session.receiveUpdate()
        XCTAssertEqual(
            finished,
            .init(text: "Hello world", isFinal: true, endpointDetected: false, isFinished: true)
        )
        let afterFinished = try await session.receiveUpdate()
        XCTAssertNil(afterFinished)

        let request = try XCTUnwrap(factory.request())
        XCTAssertEqual(request.url, SonioxRealtimeSpeechToTextService.endpoint)
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(request.url?.absoluteString.contains("soniox-fake-key") == true)
        XCTAssertEqual(socket.resumeCount(), 1)

        let sent = socket.sentMessages()
        XCTAssertEqual(sent.count, 3)
        guard case .string(let configurationText) = sent[0] else {
            return XCTFail("Expected the configuration frame first")
        }
        let configuration = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(configurationText.utf8)) as? [String: Any]
        )
        XCTAssertEqual(configuration["api_key"] as? String, "soniox-fake-key")
        XCTAssertEqual(configuration["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(configuration["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(configuration["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(configuration["num_channels"] as? Int, 1)
        XCTAssertEqual(configuration["language_hints"] as? [String], ["en"])
        XCTAssertEqual(configuration["enable_endpoint_detection"] as? Bool, true)
        XCTAssertEqual(sent[1], .data(Data([1, 0, 2, 0])))
        XCTAssertEqual(sent[2], .string(""))
    }

    func testSonioxRealtimeSTTMapsCredentialErrorWithoutExposingProviderMessage() async throws {
        let socket = RecordingCloudVoiceWebSocketTask(received: [
            .string(#"{"tokens":[],"error_code":401,"error_type":"unauthenticated","error_message":"bad key soniox-fake-key"}"#),
        ])
        let service = SonioxRealtimeSpeechToTextService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "soniox-fake-key"),
            socketFactory: RecordingCloudVoiceWebSocketTaskFactory(task: socket)
        )
        let session = try await service.startSession(model: "stt-rt-v5", languageCode: nil)

        do {
            _ = try await session.receiveUpdate()
            XCTFail("Expected credential rejection")
        } catch {
            XCTAssertEqual(error as? CloudVoiceServiceError, .credentialRejected)
            XCTAssertFalse(error.localizedDescription.contains("soniox-fake-key"))
            XCTAssertFalse(error.localizedDescription.contains("bad key"))
        }
    }

    func testSonioxRealtimeEndpointPolicyAndSessionDelegateRejectRedirectOrigins() throws {
        XCTAssertTrue(
            SonioxRealtimeSpeechToTextService.isTrustedEndpoint(
                SonioxRealtimeSpeechToTextService.endpoint
            )
        )
        for untrusted in [
            "https://stt-rt.soniox.com/transcribe-websocket",
            "wss://stt-rt.soniox.com.evil.example/transcribe-websocket",
            "wss://stt-rt.soniox.com:444/transcribe-websocket",
            "wss://user@stt-rt.soniox.com/transcribe-websocket",
            "wss://stt-rt.soniox.com/other",
            "wss://stt-rt.soniox.com/transcribe-websocket?next=evil",
        ] {
            XCTAssertFalse(
                SonioxRealtimeSpeechToTextService.isTrustedEndpoint(URL(string: untrusted)),
                untrusted
            )
        }

        let delegate = CloudVoiceNoRedirectURLSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let originalURL = try XCTUnwrap(URL(string: "https://stt-rt.soniox.com/handshake"))
        let redirectedURL = try XCTUnwrap(URL(string: "https://evil.example/handshake"))
        let task = session.dataTask(with: originalURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectedURL.absoluteString]
        ))
        var followedRequest: URLRequest? = URLRequest(url: redirectedURL)
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectedURL)
        ) { followedRequest = $0 }
        XCTAssertNil(followedRequest)
    }

    func testSonioxRealtimeSTTRejectsInvalidPCMAndCancelsSocket() async throws {
        let socket = RecordingCloudVoiceWebSocketTask(received: [])
        let service = SonioxRealtimeSpeechToTextService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "soniox-fake-key"),
            socketFactory: RecordingCloudVoiceWebSocketTaskFactory(task: socket)
        )
        let session = try await service.startSession(model: "stt-rt-v5", languageCode: "en")

        do {
            try await session.sendPCM(Data([1]))
            XCTFail("Expected odd-length PCM to be rejected")
        } catch {
            XCTAssertEqual(error as? CloudVoiceServiceError, .invalidAudio)
        }
        do {
            try await session.sendPCM(Data(repeating: 0, count: 65_538))
            XCTFail("Expected an oversized PCM frame to be rejected")
        } catch {
            XCTAssertEqual(error as? CloudVoiceServiceError, .invalidAudio)
        }
        await session.cancel()
        XCTAssertEqual(socket.cancelCount(), 1)
        XCTAssertEqual(socket.sentMessages().count, 1)
    }

    func testRealtimePCMBackpressureFailsClosedInsteadOfDroppingAudioSilently() async {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        let overflow = LockedCallbackCounter()
        let sink = BoundedRealtimePCMStreamSink(continuation: continuation) {
            overflow.increment()
        }

        XCTAssertTrue(sink.enqueue(Data([1, 0])))
        XCTAssertFalse(sink.enqueue(Data([2, 0])))
        XCTAssertFalse(sink.enqueue(Data([3, 0])))
        XCTAssertEqual(overflow.value(), 1)

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let finished = await iterator.next()
        XCTAssertEqual(first, Data([1, 0]))
        XCTAssertNil(finished)
    }

    func testSpeechInputCaptureRouteKeepsStartedProviderSnapshotAfterSettingsChange() {
        let startedRealtime = AIServiceSelection(provider: .soniox, model: "stt-rt-v5")
        let laterApple = AIServiceSelection(provider: .apple, model: "apple-dictation")
        var state = SpeechInputCaptureRouteState()

        state.begin(.sonioxRealtime(startedRealtime))
        XCTAssertEqual(state.active, .sonioxRealtime(startedRealtime))
        XCTAssertNotEqual(state.active, .apple)
        XCTAssertEqual(laterApple.provider, .apple)

        let startedFile = AIServiceSelection(provider: .xAI, model: "grok-transcribe")
        state.begin(.cloudRecording(startedFile))
        XCTAssertEqual(state.active, .cloudRecording(startedFile))
        XCTAssertNotEqual(state.active, .sonioxRealtime(startedRealtime))

        state.end()
        XCTAssertEqual(state.active, .none)
    }

    func testSpeechInputCompletionNeverDropsAnEmptyRecordingSilently() {
        let empty = SpeechInputCompletion.resolve("  \n ", existingError: nil)
        XCTAssertEqual(empty.transcript, "")
        XCTAssertEqual(
            empty.errorMessage,
            LocalAssistantServiceError.noSpeechRecognized.localizedDescription
        )

        let providerFailure = SpeechInputCompletion.resolve(
            "",
            existingError: "The speech provider did not respond."
        )
        XCTAssertEqual(
            providerFailure.errorMessage,
            "The speech provider did not respond."
        )

        let recognized = SpeechInputCompletion.resolve(
            "  Send this message.  ",
            existingError: nil
        )
        XCTAssertEqual(recognized.transcript, "Send this message.")
        XCTAssertNil(recognized.errorMessage)
    }

    @MainActor
    func testAppleSpeechAvailabilityWaitsForServiceBeforeUsingOnDeviceRecognition() async {
        let snapshots = [
            AppleSpeechRecognitionAvailabilitySnapshot(
                isAvailable: false,
                supportsOnDeviceRecognition: true
            ),
            AppleSpeechRecognitionAvailabilitySnapshot(
                isAvailable: false,
                supportsOnDeviceRecognition: true
            ),
            AppleSpeechRecognitionAvailabilitySnapshot(
                isAvailable: true,
                supportsOnDeviceRecognition: true
            ),
        ]
        var snapshotIndex = 0
        var sleepCount = 0

        let outcome = await AppleSpeechRecognitionAvailabilityWaiter.wait(
            maximumChecks: snapshots.count,
            retryDelayNanoseconds: 1,
            snapshot: {
                defer { snapshotIndex += 1 }
                return snapshots[min(snapshotIndex, snapshots.count - 1)]
            },
            isCancelled: { false },
            sleep: { _ in sleepCount += 1 }
        )

        XCTAssertEqual(outcome, .available(requiresOnDeviceRecognition: true))
        XCTAssertEqual(snapshotIndex, 3)
        XCTAssertEqual(sleepCount, 2)
    }

    @MainActor
    func testAppleSpeechAvailabilityStopsAfterBoundedUnavailableChecks() async {
        var snapshotCount = 0
        var sleepCount = 0

        let outcome = await AppleSpeechRecognitionAvailabilityWaiter.wait(
            maximumChecks: 4,
            retryDelayNanoseconds: 1,
            snapshot: {
                snapshotCount += 1
                return .init(
                    isAvailable: false,
                    supportsOnDeviceRecognition: true
                )
            },
            isCancelled: { false },
            sleep: { _ in sleepCount += 1 }
        )

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(snapshotCount, 4)
        XCTAssertEqual(sleepCount, 3)
    }

    @MainActor
    func testAppleSpeechAvailabilityWaitHonorsCancellation() async {
        var snapshotCount = 0
        var sleepCount = 0

        let outcome = await AppleSpeechRecognitionAvailabilityWaiter.wait(
            maximumChecks: 6,
            retryDelayNanoseconds: 1,
            snapshot: {
                snapshotCount += 1
                return .init(
                    isAvailable: false,
                    supportsOnDeviceRecognition: false
                )
            },
            isCancelled: { snapshotCount == 1 },
            sleep: { _ in sleepCount += 1 }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(snapshotCount, 1)
        XCTAssertEqual(sleepCount, 1)
    }

    func testAppleSpeechTaskGateNeverCreatesTaskBeforeServiceIsAvailableAndCleansUp() {
        var startCount = 0
        var simulatedIsListening = true
        var simulatedOwnsAudioSession = true
        var surfacedError: String?
        let unavailableTask: Int? = AppleSpeechRecognitionTaskGate.startIfAvailable(
            snapshot: .init(
                isAvailable: false,
                supportsOnDeviceRecognition: true
            ),
            onUnavailable: {
                simulatedIsListening = false
                simulatedOwnsAudioSession = false
                surfacedError = LocalAssistantServiceError.appleSpeechServiceUnavailable
                    .localizedDescription
            }
        ) { _ in
            startCount += 1
            return startCount
        }
        XCTAssertNil(unavailableTask)
        XCTAssertEqual(startCount, 0)
        XCTAssertFalse(simulatedIsListening)
        XCTAssertFalse(simulatedOwnsAudioSession)
        XCTAssertEqual(
            surfacedError,
            LocalAssistantServiceError.appleSpeechServiceUnavailable.localizedDescription
        )

        var requiresOnDeviceRecognition: Bool?
        let availableTask: Int? = AppleSpeechRecognitionTaskGate.startIfAvailable(
            snapshot: .init(
                isAvailable: true,
                supportsOnDeviceRecognition: true
            )
        ) { requiresOnDevice in
            startCount += 1
            requiresOnDeviceRecognition = requiresOnDevice
            return startCount
        }
        XCTAssertEqual(availableTask, 1)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(requiresOnDeviceRecognition, true)

        let networkBackedTask: Int? = AppleSpeechRecognitionTaskGate.startIfAvailable(
            snapshot: .init(
                isAvailable: true,
                supportsOnDeviceRecognition: false
            )
        ) { requiresOnDevice in
            requiresOnDeviceRecognition = requiresOnDevice
            return 2
        }
        XCTAssertEqual(networkBackedTask, 2)
        XCTAssertEqual(requiresOnDeviceRecognition, false)
    }

    func testAppleSpeechStartupErrorsDistinguishLocaleAndTemporaryServiceFailures() {
        let unsupportedLocale = LocalAssistantServiceError.appleSpeechLocaleUnavailable
            .localizedDescription
        let unavailableService = LocalAssistantServiceError.appleSpeechServiceUnavailable
            .localizedDescription
        XCTAssertNotEqual(unsupportedLocale, unavailableService)
        XCTAssertTrue(unsupportedLocale.contains("language"))
        XCTAssertTrue(unsupportedLocale.contains("Settings"))
        XCTAssertTrue(unavailableService.contains("temporarily"))
        XCTAssertTrue(unavailableService.contains("connection"))
    }

    @MainActor
    func testRealtimeStopTimeoutCancelsStalledSendAndFinishOperations() async {
        // Repeat enough times to exercise both scheduler orderings. The
        // timeout result must be stable even when cancelling finishAudio wakes
        // its waiter immediately.
        for iteration in 0..<20 {
            let session = StalledRealtimeSpeechToTextSession()
            let sendTask = Task<Void, Never> {
                try? await session.sendPCM(Data([1, 0]))
            }

            let drained = await SpeechInputController.awaitRealtimeSendDrain(
                sendTask,
                session: session,
                timeoutNanoseconds: 1_000_000
            )
            XCTAssertFalse(drained, "iteration \(iteration)")
            let afterSendCancel = await session.cancelCount()
            XCTAssertEqual(afterSendCancel, 1, "iteration \(iteration)")

            do {
                try await SpeechInputController.finishRealtimeSession(
                    session,
                    timeoutNanoseconds: 1_000_000
                )
                XCTFail("Expected stalled finish to time out (iteration \(iteration))")
            } catch {
                XCTAssertEqual(
                    error as? CloudVoiceServiceError,
                    .processingTimedOut,
                    "iteration \(iteration)"
                )
            }
            let afterFinishCancel = await session.cancelCount()
            XCTAssertEqual(afterFinishCancel, 2, "iteration \(iteration)")
        }
    }

    func testSonioxSTTCompletesBoundedLifecycleAndDeletesRemoteResources() async throws {
        let fileID = "84c32fc6-4fb5-4e7a-b656-b5becfd310c8"
        let transcriptionID = "19b6d61d-02db-4c25-bc71-b4094dc310c8"
        let transport = CloudVoiceRecordingTransport(responses: [
            .json(#"{"id":"\#(fileID)","filename":"note.wav","size":3}"#, statusCode: 201),
            .json(#"{"id":"\#(transcriptionID)","status":"completed"}"#, statusCode: 201),
            .json(#"{"id":"\#(transcriptionID)","text":"Cleaned transcript","tokens":[]}"#),
            .init(data: Data(), statusCode: 204),
            .init(data: Data(), statusCode: 404),
        ])
        let service = SonioxCloudSpeechToTextService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "soniox-fake-key"),
            transport: transport
        )

        let result = try await service.transcribe(.init(
            audioData: Data([0, 1, 2]),
            filename: "note.wav",
            mimeType: "audio/wav",
            model: "stt-async-v5",
            languageCode: "en"
        ))

        XCTAssertEqual(result.text, "Cleaned transcript")
        XCTAssertEqual(service.requestStorageBehavior, .deletesRemoteResourcesAfterCompletion)
        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "GET", "DELETE", "DELETE"])
        XCTAssertEqual(requests[0].url, SonioxCloudSpeechToTextService.filesEndpoint)
        XCTAssertEqual(requests[1].url, SonioxCloudSpeechToTextService.transcriptionsEndpoint)
        XCTAssertEqual(requests[2].url?.path, "/v1/transcriptions/\(transcriptionID)/transcript")
        XCTAssertEqual(requests[3].url?.path, "/v1/transcriptions/\(transcriptionID)")
        XCTAssertEqual(requests[4].url?.path, "/v1/files/\(fileID)")
    }

    func testSonioxSTTReportsOneUnverifiedCleanupSweepWithoutRetrying() async throws {
        let fileID = "84c32fc6-4fb5-4e7a-b656-b5becfd310c8"
        let transcriptionID = "19b6d61d-02db-4c25-bc71-b4094dc310c8"
        let transport = CloudVoiceRecordingTransport(responses: [
            .json(#"{"id":"\#(fileID)","filename":"note.wav","size":3}"#, statusCode: 201),
            .json(#"{"id":"\#(transcriptionID)","status":"completed"}"#, statusCode: 201),
            .json(#"{"id":"\#(transcriptionID)","text":"Transcript","tokens":[]}"#),
            .init(data: Data(), statusCode: 500),
            .init(data: Data(), statusCode: 204),
        ])
        let service = SonioxCloudSpeechToTextService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "soniox-fake-key"),
            transport: transport
        )

        do {
            _ = try await service.transcribe(.init(
                audioData: Data([0, 1, 2]),
                filename: "note.wav",
                mimeType: "audio/wav",
                model: "stt-async-v5"
            ))
            XCTFail("Expected unverified remote cleanup")
        } catch {
            XCTAssertEqual(error as? CloudVoiceServiceError, .remoteCleanupFailed)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "GET", "DELETE", "DELETE"])
    }

    func testSonioxSTTCancellationDeletesRemoteResourcesFromFreshTask() async throws {
        let transport = CancellableSonioxTransport(deleteStatusCode: 204)
        let service = SonioxCloudSpeechToTextService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "soniox-fake-key"),
            transport: transport
        )
        let task = Task {
            try await service.transcribe(.init(
                audioData: Data([0, 1, 2]),
                filename: "note.wav",
                mimeType: "audio/wav",
                model: "stt-async-v5",
                languageCode: "en"
            ))
        }

        await transport.waitUntilPollingStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation after verified cleanup")
        } catch is CancellationError {
            // Expected only after both remote resources were verified deleted.
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.method), ["POST", "POST", "GET", "DELETE", "DELETE"])
        XCTAssertEqual(requests[3].path, "/v1/transcriptions/19b6d61d-02db-4c25-bc71-b4094dc310c8")
        XCTAssertEqual(requests[4].path, "/v1/files/84c32fc6-4fb5-4e7a-b656-b5becfd310c8")
        XCTAssertFalse(requests[3].taskWasCancelled)
        XCTAssertFalse(requests[4].taskWasCancelled)
    }

    func testSonioxSTTCancellationReportsUnverifiedRemoteCleanup() async throws {
        let transport = CancellableSonioxTransport(deleteStatusCode: 500)
        let service = SonioxCloudSpeechToTextService(
            credentialStore: CloudVoiceMemoryCredentialStore(key: "soniox-fake-key"),
            transport: transport
        )
        let task = Task {
            try await service.transcribe(.init(
                audioData: Data([0, 1, 2]),
                filename: "note.wav",
                mimeType: "audio/wav",
                model: "stt-async-v5"
            ))
        }

        await transport.waitUntilPollingStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cleanup verification failure")
        } catch {
            XCTAssertEqual(error as? CloudVoiceServiceError, .remoteCleanupFailed)
        }
    }

    @MainActor
    func testRemoteCleanupFailureSurvivesCancelledSpeechGenerationGuard() {
        XCTAssertTrue(
            SpeechInputController.shouldSurfaceCloudTranscriptionError(
                CloudVoiceServiceError.remoteCleanupFailed,
                generationMatches: false
            )
        )
        XCTAssertFalse(
            SpeechInputController.shouldSurfaceCloudTranscriptionError(
                URLError(.cancelled),
                generationMatches: false
            )
        )
        XCTAssertTrue(
            SpeechInputController.shouldSurfaceCloudTranscriptionError(
                URLError(.cannotConnectToHost),
                generationMatches: true
            )
        )
    }

    func testAppleDictationKeepsListeningAfterAnEarlyFinalSegment() {
        var state = AppleDictationTranscriptState()

        XCTAssertEqual(state.receive("Hello", isFinal: false), .none)
        XCTAssertEqual(state.text, "Hello")
        XCTAssertEqual(state.receive("Hello", isFinal: true), .restartRecognition)
        XCTAssertEqual(state.text, "Hello")

        XCTAssertEqual(state.receive("world", isFinal: false), .none)
        XCTAssertEqual(state.text, "Hello world")
        XCTAssertFalse(state.stopRequested)
    }

    func testAppleDictationAcceptsDelayedFinalTranscriptAfterStop() {
        var state = AppleDictationTranscriptState()
        _ = state.receive("Please schedule", isFinal: false)

        state.requestStop()

        XCTAssertEqual(
            state.receive("Please schedule lunch tomorrow", isFinal: true),
            .finishRequestedStop
        )
        XCTAssertEqual(state.text, "Please schedule lunch tomorrow")
    }

    func testAppleDictationCombinesFinalizedSegmentsWithoutRepeatingThem() {
        var state = AppleDictationTranscriptState()
        _ = state.receive("Open", isFinal: true)
        _ = state.receive("Open", isFinal: true)
        _ = state.receive("Calendar", isFinal: false)

        XCTAssertEqual(state.text, "Open Calendar")
    }

    func testCloudDictationLaunchScrubIsProcessOnceAndDoesNotDeleteLaterRecording() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scrubber = CloudDictationTemporaryFileScrubber()
        let stale = CloudDictationTemporaryFileScrubber.recordingURL(in: root)
        let unrelated = root.appendingPathComponent("OtherApp-\(UUID().uuidString).m4a")
        let malformed = root.appendingPathComponent("CodexCloudDictation-not-a-uuid.m4a")
        try Data([1]).write(to: stale)
        try Data([2]).write(to: unrelated)
        try Data([3]).write(to: malformed)

        scrubber.scrubOnce(in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))

        let activeAfterLaunch = CloudDictationTemporaryFileScrubber.recordingURL(in: root)
        try Data([4]).write(to: activeAfterLaunch)
        scrubber.scrubOnce(in: root)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: activeAfterLaunch.path),
            "A controller/view recreation must not scrub a recording created in this process."
        )
    }

    func testCloudDictationLaunchScrubBoundsDeletionWork() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0 ... CloudDictationTemporaryFileScrubber.maximumFilesToRemove {
            try Data([1]).write(
                to: CloudDictationTemporaryFileScrubber.recordingURL(in: root)
            )
        }

        CloudDictationTemporaryFileScrubber().scrubOnce(in: root)

        let remaining = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(
            CloudDictationTemporaryFileScrubber.fileNamePrefix
        ) }
        XCTAssertEqual(remaining.count, 1)
    }

    func testCloudDictationRecordingUsesCompleteFileProtection() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = CloudDictationTemporaryFileScrubber.recordingURL(in: root)
        try Data([1]).write(to: recording)

        try CloudDictationTemporaryFileScrubber.protectRecording(at: recording)

        XCTAssertEqual(
            CloudDictationTemporaryFileScrubber.recordingFileProtection,
            FileProtectionType.complete
        )
#if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: recording.path)
        let protection = attributes[.protectionKey]
        XCTAssertEqual(
            (protection as? FileProtectionType)?.rawValue ?? protection as? String,
            FileProtectionType.complete.rawValue
        )
#endif
    }

    func testCloudDictationUsesPortableMonoPCMUploadContract() {
        let settings = CloudDictationTemporaryFileScrubber.recorderSettings()

        XCTAssertEqual(
            settings[AVFormatIDKey] as? AudioFormatID,
            kAudioFormatLinearPCM
        )
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 16_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsNonInterleaved] as? Bool, false)
        XCTAssertEqual(CloudDictationTemporaryFileScrubber.fileNameSuffix, ".wav")
        XCTAssertEqual(
            CloudDictationTemporaryFileScrubber.uploadFilename,
            "openclam-dictation.wav"
        )
        XCTAssertEqual(
            CloudDictationTemporaryFileScrubber.uploadMIMEType,
            "audio/wav"
        )
        XCTAssertEqual(
            CloudDictationTemporaryFileScrubber.maximumRecordingDuration,
            60
        )
    }

    @MainActor
    func testCloudManualStopCapturesBoundedTailBeforeStoppingAndStopsOnCancellation() async {
        var events: [String] = []
        var requestedGrace: UInt64?

        let shouldTranscribe = await CloudRecordingManualStopTailCapture.waitThenStop(
            sleep: { nanoseconds in
                requestedGrace = nanoseconds
                events.append("tail")
            },
            stop: { events.append("stop") }
        )

        XCTAssertTrue(shouldTranscribe)
        XCTAssertEqual(
            requestedGrace,
            CloudRecordingManualStopTailCapture.graceNanoseconds
        )
        XCTAssertEqual(events, ["tail", "stop"])
        XCTAssertLessThanOrEqual(
            CloudRecordingManualStopTailCapture.graceNanoseconds,
            500_000_000
        )

        events = []
        let shouldTranscribeAfterCancellation = await CloudRecordingManualStopTailCapture
            .waitThenStop(
                sleep: { _ in
                    events.append("tail")
                    throw CancellationError()
                },
                stop: { events.append("stop") }
            )

        XCTAssertFalse(shouldTranscribeAfterCancellation)
        XCTAssertEqual(events, ["tail", "stop"])
    }

    func testScreenshotOCRRejectsOversizedMetadataBeforeImageDecode() throws {
        let validPNG = try encodedImage(type: .png, frameCount: 1)
        let oversizedDimension = png(
            validPNG,
            replacingWidth: ScreenshotOCRService.maximumImageDimension + 1,
            height: 1
        )
        let oversizedPixels = png(
            validPNG,
            replacingWidth: 10_000,
            height: (ScreenshotOCRService.maximumImagePixels / 10_000) + 1
        )

        XCTAssertThrowsError(try ScreenshotOCRService.validatedImage(in: oversizedDimension)) {
            XCTAssertEqual($0 as? LocalAssistantServiceError, .invalidImage)
        }
        XCTAssertThrowsError(try ScreenshotOCRService.validatedImage(in: oversizedPixels)) {
            XCTAssertEqual($0 as? LocalAssistantServiceError, .invalidImage)
        }
    }

    func testScreenshotOCRRejectsMalformedAndMultiframeImages() throws {
        XCTAssertThrowsError(
            try ScreenshotOCRService.validatedImage(in: Data("not an image".utf8))
        ) {
            XCTAssertEqual($0 as? LocalAssistantServiceError, .invalidImage)
        }

        let animatedGIF = try encodedImage(type: .gif, frameCount: 2)
        XCTAssertThrowsError(try ScreenshotOCRService.validatedImage(in: animatedGIF)) {
            XCTAssertEqual($0 as? LocalAssistantServiceError, .invalidImage)
        }
    }

    func testScreenshotOCRAcceptsBoundedSingleFrameRasterImage() throws {
        let image = try ScreenshotOCRService.validatedImage(
            in: encodedImage(type: .png, frameCount: 1)
        )

        XCTAssertEqual(image.cgImage.width, 1)
        XCTAssertEqual(image.cgImage.height, 1)
        XCTAssertEqual(image.orientation, .up)
    }

    @MainActor
    func testCloudFinalizationManualThenDelegateSharesOneUploadAndDeletion() async throws {
        try await assertSharedCloudFinalization(triggerOrder: [.manual, .delegate])
    }

    @MainActor
    func testCloudFinalizationDelegateThenManualSharesOneUploadAndDeletion() async throws {
        try await assertSharedCloudFinalization(triggerOrder: [.delegate, .manual])
    }

    @MainActor
    func testCloudFinalizationSimultaneousTriggersShareOneUploadAndDeletion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = directory.appendingPathComponent("recording.m4a")
        try Data("shared transcript".utf8).write(to: recording)
        let coordinator = CloudRecordingFinalizationCoordinator()
        let probe = CloudFinalizationProbe()

        let manual = Task { @MainActor in
            await coordinator.task {
                await probe.finalize(recording: recording)
            }.value
        }
        let delegate = Task { @MainActor in
            await coordinator.task {
                await probe.finalize(recording: recording)
            }.value
        }
        let values = await [manual.value, delegate.value]

        XCTAssertEqual(values, ["shared transcript", "shared transcript"])
        XCTAssertEqual(probe.uploadCount, 1)
        XCTAssertEqual(probe.deletionCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path))
    }

    @MainActor
    func testNaturalSpeechCompletionReleasesAudioSessionExactlyOnce() {
        var releaseCount = 0
        let lifecycle = SpeechOutputLifecycleCoordinator { releaseCount += 1 }
        let generation = lifecycle.begin()
        lifecycle.markAudioSessionActive(for: generation)

        XCTAssertTrue(lifecycle.finish(generation))
        XCTAssertFalse(lifecycle.finish(generation))
        XCTAssertEqual(releaseCount, 1)
    }

    @MainActor
    func testReplacementMakesOldSpeechDelegateCompletionHarmless() {
        var releaseCount = 0
        let lifecycle = SpeechOutputLifecycleCoordinator { releaseCount += 1 }
        let replacedGeneration = lifecycle.begin()
        lifecycle.markAudioSessionActive(for: replacedGeneration)
        let shouldDeactivateReplacedOutput = lifecycle.invalidate()
        lifecycle.deactivateAfterExplicitStop(ifNeeded: shouldDeactivateReplacedOutput)
        let currentGeneration = lifecycle.begin()
        lifecycle.markAudioSessionActive(for: currentGeneration)

        XCTAssertFalse(lifecycle.finish(replacedGeneration))
        XCTAssertTrue(lifecycle.isCurrent(currentGeneration))
        XCTAssertEqual(releaseCount, 1)

        XCTAssertTrue(lifecycle.finish(currentGeneration))
        XCTAssertEqual(releaseCount, 2)
    }

    @MainActor
    func testExplicitSpeechStopInvalidatesLaterDelegateCallback() {
        var releaseCount = 0
        let lifecycle = SpeechOutputLifecycleCoordinator { releaseCount += 1 }
        let stoppedGeneration = lifecycle.begin()
        lifecycle.markAudioSessionActive(for: stoppedGeneration)

        let shouldDeactivate = lifecycle.invalidate()
        lifecycle.deactivateAfterExplicitStop(ifNeeded: shouldDeactivate)
        let repeatedStopShouldDeactivate = lifecycle.invalidate()
        lifecycle.deactivateAfterExplicitStop(ifNeeded: repeatedStopShouldDeactivate)

        XCTAssertFalse(lifecycle.finish(stoppedGeneration))
        XCTAssertEqual(releaseCount, 1)
    }

    @MainActor
    func testRepeatedNoOutputStopsDoNotDeactivateMockRecognitionSession() {
        let suiteName = "NoOutputStopRecognition-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        var recognitionSessionIsActive = true
        var releaseCount = 0
        let lifecycle = SpeechOutputLifecycleCoordinator {
            recognitionSessionIsActive = false
            releaseCount += 1
        }
        let model = ConversationModel(
            preferences: preferences,
            speechOutputLifecycle: lifecycle
        )

        model.stopSpeechOutput()
        model.stopSpeechOutput()
        model.stopSpeechOutput()

        XCTAssertTrue(recognitionSessionIsActive)
        XCTAssertEqual(releaseCount, 0)
    }

    @MainActor
    func testSpeechInputCancelWithoutCaptureIsNoOpAndOwnedSessionReleasesOnce() {
        var releaseCount = 0
        let ownership = SpeechInputAudioSessionOwnership { releaseCount += 1 }
        let controller = SpeechInputController(audioSessionOwnership: ownership)

        controller.cancel()
        controller.cancel()
        XCTAssertEqual(releaseCount, 0)

        ownership.claim()
        controller.cancel()
        controller.cancel()
        XCTAssertEqual(releaseCount, 1)
    }

    @MainActor
    private func assertSharedCloudFinalization(
        triggerOrder: [CloudFinalizationTrigger]
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = directory.appendingPathComponent("recording.m4a")
        try Data("shared transcript".utf8).write(to: recording)
        let coordinator = CloudRecordingFinalizationCoordinator()
        let probe = CloudFinalizationProbe()
        var tasks: [Task<String, Never>] = []

        for _ in triggerOrder {
            tasks.append(coordinator.task {
                await probe.finalize(recording: recording)
            })
        }

        var values: [String] = []
        for task in tasks {
            values.append(await task.value)
        }
        XCTAssertEqual(values, Array(repeating: "shared transcript", count: triggerOrder.count))
        XCTAssertEqual(probe.uploadCount, 1)
        XCTAssertEqual(probe.deletionCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path))
    }

    private func encodedImage(type: UTType, frameCount: Int) throws -> Data {
        let bytes = Data([255, 255, 255, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            frameCount,
            nil
        ))
        for _ in 0 ..< frameCount {
            CGImageDestinationAddImage(destination, image, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func png(_ source: Data, replacingWidth width: Int, height: Int) -> Data {
        precondition(source.count >= 33)
        var result = source
        result.replaceSubrange(16 ..< 20, with: bigEndianBytes(UInt32(width)))
        result.replaceSubrange(20 ..< 24, with: bigEndianBytes(UInt32(height)))
        let checksum = crc32(result.subdata(in: 12 ..< 29))
        result.replaceSubrange(29 ..< 33, with: bigEndianBytes(checksum))
        return result
    }

    private func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        let value = value.bigEndian
        return withUnsafeBytes(of: value) { Array($0) }
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }

    private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private enum CloudFinalizationTrigger {
    case manual
    case delegate
}

@MainActor
private final class CloudFinalizationProbe {
    private(set) var uploadCount = 0
    private(set) var deletionCount = 0

    func finalize(recording: URL) async -> String {
        uploadCount += 1
        let value = (try? String(contentsOf: recording, encoding: .utf8)) ?? ""
        await Task.yield()
        if FileManager.default.fileExists(atPath: recording.path) {
            try? FileManager.default.removeItem(at: recording)
            deletionCount += 1
        }
        return value
    }
}

private struct CloudVoiceMemoryCredentialStore: AgentCredentialStore {
    let key: String?

    func saveAPIKey(_ apiKey: String) throws {}
    func loadAPIKey() throws -> String? { key }
    func deleteAPIKey() throws {}
}

private actor CloudVoiceRecordingTransport: OpenAIResponsesTransport {
    struct Response: Sendable {
        let data: Data
        let statusCode: Int

        static func json(_ value: String, statusCode: Int = 200) -> Self {
            .init(data: Data(value.utf8), statusCode: statusCode)
        }
    }

    private var queued: [Response]
    private var recorded: [URLRequest] = []

    init(responses: [Response]) { queued = responses }

    func send(_ request: URLRequest) async throws -> OpenAITransportResponse {
        recorded.append(request)
        guard !queued.isEmpty else { throw URLError(.badServerResponse) }
        let next = queued.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return .init(data: next.data, response: response)
    }

    func requests() -> [URLRequest] { recorded }
}

private final class RecordingCloudVoiceWebSocketTaskFactory: CloudVoiceWebSocketTaskFactory,
                                                               @unchecked Sendable {
    private let lock = NSLock()
    private let task: RecordingCloudVoiceWebSocketTask
    private var recordedRequest: URLRequest?

    init(task: RecordingCloudVoiceWebSocketTask) {
        self.task = task
    }

    func makeTask(for request: URLRequest) -> any CloudVoiceWebSocketTask {
        lock.withLock { recordedRequest = request }
        return task
    }

    func request() -> URLRequest? {
        lock.withLock { recordedRequest }
    }
}

private final class RecordingCloudVoiceWebSocketTask: CloudVoiceWebSocketTask,
                                                       @unchecked Sendable {
    private let lock = NSLock()
    private var received: [CloudVoiceWebSocketMessage]
    private var sent: [CloudVoiceWebSocketMessage] = []
    private var resumes = 0
    private var cancellations = 0

    init(received: [CloudVoiceWebSocketMessage]) {
        self.received = received
    }

    func resume() {
        lock.withLock { resumes += 1 }
    }

    func send(_ message: CloudVoiceWebSocketMessage) async throws {
        lock.withLock { sent.append(message) }
    }

    func receive() async throws -> CloudVoiceWebSocketMessage {
        try dequeueReceivedMessage()
    }

    func cancel() {
        lock.withLock { cancellations += 1 }
    }

    func sentMessages() -> [CloudVoiceWebSocketMessage] {
        lock.withLock { sent }
    }

    func resumeCount() -> Int {
        lock.withLock { resumes }
    }

    func cancelCount() -> Int {
        lock.withLock { cancellations }
    }

    private func dequeueReceivedMessage() throws -> CloudVoiceWebSocketMessage {
        try lock.withLock {
            guard !received.isEmpty else { throw URLError(.badServerResponse) }
            return received.removeFirst()
        }
    }
}

private actor StalledRealtimeSpeechToTextSession: RealtimeSpeechToTextSession {
    private var cancellations = 0

    func sendPCM(_ data: Data) async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }

    func finishAudio() async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }

    func receiveUpdate() async throws -> RealtimeTranscriptionUpdate? {
        nil
    }

    func cancel() {
        cancellations += 1
    }

    func cancelCount() -> Int {
        cancellations
    }
}

private final class LockedCallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    func value() -> Int {
        lock.withLock { count }
    }
}

private actor CancellableSonioxTransport: OpenAIResponsesTransport {
    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let taskWasCancelled: Bool
    }

    private let deleteStatusCode: Int
    private let fileID = "84c32fc6-4fb5-4e7a-b656-b5becfd310c8"
    private let transcriptionID = "19b6d61d-02db-4c25-bc71-b4094dc310c8"
    private var recorded: [RecordedRequest] = []
    private var pollingStarted = false
    private var pollingWaiters: [CheckedContinuation<Void, Never>] = []

    init(deleteStatusCode: Int) {
        self.deleteStatusCode = deleteStatusCode
    }

    func send(_ request: URLRequest) async throws -> OpenAITransportResponse {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        recorded.append(.init(
            method: method,
            path: path,
            taskWasCancelled: Task.isCancelled
        ))

        if method == "GET" {
            pollingStarted = true
            let waiters = pollingWaiters
            pollingWaiters.removeAll()
            waiters.forEach { $0.resume() }
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }

        if method == "DELETE" {
            return response(for: request, data: Data(), statusCode: deleteStatusCode)
        }

        if path == "/v1/files" {
            return response(
                for: request,
                data: Data(#"{"id":"\#(fileID)"}"#.utf8),
                statusCode: 201
            )
        }
        return response(
            for: request,
            data: Data(#"{"id":"\#(transcriptionID)","status":"processing"}"#.utf8),
            statusCode: 201
        )
    }

    func waitUntilPollingStarted() async {
        guard !pollingStarted else { return }
        await withCheckedContinuation { continuation in
            pollingWaiters.append(continuation)
        }
    }

    func requests() -> [RecordedRequest] { recorded }

    private func response(
        for request: URLRequest,
        data: Data,
        statusCode: Int
    ) -> OpenAITransportResponse {
        .init(
            data: data,
            response: HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
        )
    }
}
