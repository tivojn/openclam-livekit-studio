import AVFoundation
import Foundation
import Speech

func screenVoicePTTWithTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await openClamWithHardDeadline(
        seconds: seconds,
        timeoutError: { ScreenVoicePTTError.transcriptionTimedOut },
        operation: operation
    )
}

private protocol ScreenVoicePTTTranscriptionBackend: Sendable {
    func start() async throws
    func consume(_ chunk: ScreenVoicePTTAudioChunk) async throws
    func shouldStopAfterProviderEndpoint() async throws -> Bool
    func finish() async throws -> String
    func cancel() async
}

private struct ScreenVoicePTTSettingsLoader: Sendable {
    private static let currentKey = "ai.provider.settings.v2"
    private static let legacyKey = "ai.provider.settings.v1"

    func load() throws -> AIProviderSettings {
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: Self.currentKey)
            ?? defaults.data(forKey: Self.legacyKey)
        guard let data else { return AIProviderSettings() }
        guard let settings = try? JSONDecoder().decode(AIProviderSettings.self, from: data) else {
            throw AIProviderSettingsError.missingModel
        }
        return try settings.validated()
    }
}

@MainActor
final class ScreenVoicePTTQuestionTranscriber: ScreenVoicePTTQuestionTranscribing {
    static let maximumTranscriptionDuration: TimeInterval = 35

    private let microphone: ScreenVoicePTTMicrophoneSource
    private let settingsLoader: ScreenVoicePTTSettingsLoader
    private let credentialVault: any ProviderCredentialVault
    private let activity: any ScreenVoicePTTActivityPresenting
    private var backend: (any ScreenVoicePTTTranscriptionBackend)?
    private var isActive = false

    init(
        microphone: ScreenVoicePTTMicrophoneSource? = nil,
        credentialVault: any ProviderCredentialVault = KeychainProviderCredentialVault(),
        activity: any ScreenVoicePTTActivityPresenting
    ) {
        self.microphone = microphone ?? ScreenVoicePTTMicrophoneSource()
        settingsLoader = .init()
        self.credentialVault = credentialVault
        self.activity = activity
    }

    func transcribeBoundedQuestion() async throws -> String {
        guard !isActive else { throw ScreenVoicePTTError.busy }
        isActive = true
        defer {
            backend = nil
            isActive = false
        }

        let selection = try settingsLoader.load().speechToText.validated(
            for: .speechToText
        )
        // Resolve first-time consent before starting the turn deadline or opening a realtime
        // provider socket. A person can safely read the system permission sheet without the
        // provider's initial-audio deadline expiring.
        try await microphone.preflightPermission()

        return try await withTaskCancellationHandler {
            do {
                let selectedBackend = try makeBackend(selection: selection)
                backend = selectedBackend
                if selection.provider == .apple {
                    // Apple can present a first-use Speech Recognition sheet. Complete that
                    // explicit consent before the bounded recording/transcription clock begins.
                    try await selectedBackend.start()
                }
                return try await screenVoicePTTWithTimeout(
                    seconds: Self.maximumTranscriptionDuration
                ) { [self] in
                    try await performTranscription(
                        selectedBackend,
                        startBackend: selection.provider != .apple
                    )
                }
            } catch {
                microphone.cancel()
                if let backend { await backend.cancel() }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.microphone.cancel()
                if let backend = self.backend { await backend.cancel() }
            }
        }
    }

    private func performTranscription(
        _ selectedBackend: any ScreenVoicePTTTranscriptionBackend,
        startBackend: Bool
    ) async throws -> String {
        if startBackend {
            try await screenVoicePTTWithTimeout(seconds: 5) {
                try await selectedBackend.start()
            }
        }
        let stream = try await microphone.start()

        var vad = ScreenVoicePTTVAD()
        captureLoop: for try await chunk in stream {
            try Task.checkCancellation()
            try await screenVoicePTTWithTimeout(seconds: 3) {
                try await selectedBackend.consume(chunk)
            }

            let decision = vad.ingest(rms: chunk.rms, duration: chunk.duration)
            if vad.hasSpeech {
                microphone.markSpeechDetected()
            }
            if try await selectedBackend.shouldStopAfterProviderEndpoint(), vad.hasSpeech {
                break captureLoop
            }
            switch decision {
            case .continueListening:
                break
            case .finishAfterSpeech, .hardTimeout:
                break captureLoop
            case .noSpeechTimeout:
                throw ScreenVoicePTTError.noSpeechDetected
            }
        }

        try Task.checkCancellation()
        microphone.stop()
        await activity.update(.transcribing)
        let rawTranscript = try await screenVoicePTTWithTimeout(seconds: 20) {
            try await selectedBackend.finish()
        }
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw ScreenVoicePTTError.emptyTranscript }
        guard transcript.count <= 2_000 else {
            throw ScreenVoicePTTError.transcriptTooLong
        }
        return transcript
    }

    func cancel() async {
        microphone.cancel()
        if let backend { await backend.cancel() }
    }

    private func makeBackend(
        selection: AIServiceSelection
    ) throws -> any ScreenVoicePTTTranscriptionBackend {
        let language = AIProviderRegistry.speechRecognitionRequestLanguage(
            for: selection
        )
        if selection.provider == .apple {
            return AppleScreenVoicePTTTranscriptionBackend(
                languageCode: language
            )
        }

        do {
            guard try credentialVault.containsCredential(for: selection.provider) else {
                throw ScreenVoicePTTError.missingSpeechCredential(selection.provider)
            }
        } catch let error as ScreenVoicePTTError {
            throw error
        } catch {
            throw ScreenVoicePTTError.missingSpeechCredential(selection.provider)
        }

        let credentialStore = ProviderScopedAgentCredentialStore(
            provider: selection.provider,
            vault: credentialVault
        )
        switch selection.provider {
        case .soniox where selection.model == SonioxRealtimeSpeechToTextService.model:
            return SonioxScreenVoicePTTTranscriptionBackend(
                service: SonioxRealtimeSpeechToTextService(credentialStore: credentialStore),
                model: selection.model,
                languageCode: language
            )
        case .soniox where selection.model == "stt-async-v5":
            return BufferedScreenVoicePTTTranscriptionBackend(
                service: SonioxCloudSpeechToTextService(credentialStore: credentialStore),
                model: selection.model,
                languageCode: language
            )
        case .xAI:
            return BufferedScreenVoicePTTTranscriptionBackend(
                service: XAICloudVoiceService(credentialStore: credentialStore),
                model: selection.model,
                languageCode: language
            )
        case .openAI:
            return BufferedScreenVoicePTTTranscriptionBackend(
                service: OpenAICloudVoiceService(credentialStore: credentialStore),
                model: selection.model,
                languageCode: language
            )
        case .openRouter:
            return BufferedScreenVoicePTTTranscriptionBackend(
                service: OpenRouterCloudVoiceService(credentialStore: credentialStore),
                model: selection.model,
                languageCode: language
            )
        case .deepgram:
            return BufferedScreenVoicePTTTranscriptionBackend(
                service: DeepgramCloudSpeechToTextService(
                    credentialStore: credentialStore
                ),
                model: selection.model,
                languageCode: language
            )
        case .elevenLabs:
            return BufferedScreenVoicePTTTranscriptionBackend(
                service: ElevenLabsCloudVoiceService(credentialStore: credentialStore),
                model: selection.model,
                languageCode: language
            )
        default:
            throw ScreenVoicePTTError.unsupportedSpeechProvider(selection.provider)
        }
    }
}

@MainActor
private final class AppleScreenVoicePTTTranscriptionBackend: ScreenVoicePTTTranscriptionBackend {
    private let languageCode: String?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcriptState = AppleDictationTranscriptState()
    private var segmentID = 0
    private var stopFinalReceived = false
    private var recognitionError: Error?

    init(languageCode: String?) {
        self.languageCode = languageCode
    }

    func start() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard status == .authorized else { throw ScreenVoicePTTError.speechPermissionDenied }
        let locale = languageCode.map(Locale.init(identifier:)) ?? .current
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw ScreenVoicePTTError.speechRecognitionUnavailable
        }

        self.recognizer = recognizer
        transcriptState = AppleDictationTranscriptState()
        beginRecognitionSegment()
    }

    private func beginRecognitionSegment() {
        guard let recognizer else { return }
        segmentID += 1
        let currentSegmentID = segmentID
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, segmentID == currentSegmentID else { return }
                if let result {
                    let action = transcriptState.receive(
                        result.bestTranscription.formattedString,
                        isFinal: result.isFinal
                    )
                    switch action {
                    case .none:
                        break
                    case .restartRecognition:
                        // Apple can finalize after a single word. That is only a segment boundary;
                        // local VAD remains the sole authority that ends this bounded utterance.
                        task = nil
                        self.request = nil
                        beginRecognitionSegment()
                    case .finishRequestedStop:
                        stopFinalReceived = true
                    }
                }
                if let error, result == nil { recognitionError = error }
            }
        }
    }

    func consume(_ chunk: ScreenVoicePTTAudioChunk) async throws {
        if let recognitionError, transcriptState.text.isEmpty { throw recognitionError }
        guard let request,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: Double(ScreenVoicePTTAudioChunk.sampleRate),
                  channels: 1,
                  interleaved: false
              ) else { throw ScreenVoicePTTError.speechRecognitionUnavailable }
        let sampleCount = chunk.pcm16LittleEndian.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              sampleCount <= Int(UInt32.max),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(sampleCount)
              ), let destination = buffer.int16ChannelData?.pointee else {
            throw ScreenVoicePTTError.audioCaptureUnavailable
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        chunk.pcm16LittleEndian.withUnsafeBytes { source in
            if let baseAddress = source.baseAddress {
                memcpy(destination, baseAddress, chunk.pcm16LittleEndian.count)
            }
        }
        request.append(buffer)
    }

    func shouldStopAfterProviderEndpoint() async throws -> Bool {
        if let recognitionError, transcriptState.text.isEmpty { throw recognitionError }
        return false
    }

    func finish() async throws -> String {
        transcriptState.requestStop()
        request?.endAudio()
        task?.finish()
        for _ in 0..<30 where !stopFinalReceived && recognitionError == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let value = transcriptState.text
        let error = recognitionError
        cleanup(cancel: false)
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let error {
            throw error
        }
        return value
    }

    func cancel() async {
        cleanup(cancel: true)
    }

    private func cleanup(cancel: Bool) {
        if cancel { task?.cancel() }
        task = nil
        request = nil
        recognizer = nil
    }
}

private actor SonioxScreenVoicePTTTranscriptionBackend: ScreenVoicePTTTranscriptionBackend {
    private let service: any RealtimeSpeechToTextServicing
    private let model: String
    private let languageCode: String?
    private var session: (any RealtimeSpeechToTextSession)?
    private var receiveTask: Task<Void, Never>?
    private var transcript = ""
    private var endpointDetected = false
    private var finished = false
    private var receiveError: Error?

    init(
        service: any RealtimeSpeechToTextServicing,
        model: String,
        languageCode: String?
    ) {
        self.service = service
        self.model = model
        self.languageCode = languageCode
    }

    func start() async throws {
        let startedSession = try await service.startSession(
            model: model,
            languageCode: languageCode
        )
        do {
            try Task.checkCancellation()
            session = startedSession
            receiveTask = Task { [weak self] in
                do {
                    while let update = try await startedSession.receiveUpdate() {
                        await self?.accept(update)
                        if update.isFinished { return }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await self?.accept(error)
                }
            }
        } catch {
            await startedSession.cancel()
            throw error
        }
    }

    func consume(_ chunk: ScreenVoicePTTAudioChunk) async throws {
        if let receiveError { throw receiveError }
        guard let session else { throw ScreenVoicePTTError.speechRecognitionUnavailable }
        try await session.sendPCM(chunk.pcm16LittleEndian)
    }

    func shouldStopAfterProviderEndpoint() async throws -> Bool {
        if let receiveError { throw receiveError }
        return endpointDetected
    }

    func finish() async throws -> String {
        guard let session else { throw ScreenVoicePTTError.speechRecognitionUnavailable }
        try await session.finishAudio()
        for _ in 0..<50 where !finished && receiveError == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let receiveError { throw receiveError }
        guard finished else {
            await cancel()
            throw CloudVoiceServiceError.processingTimedOut
        }
        receiveTask?.cancel()
        receiveTask = nil
        self.session = nil
        return transcript
    }

    func cancel() async {
        receiveTask?.cancel()
        receiveTask = nil
        if let session { await session.cancel() }
        self.session = nil
    }

    private func accept(_ update: RealtimeTranscriptionUpdate) {
        transcript = update.text
        endpointDetected = endpointDetected || update.endpointDetected
        finished = finished || update.isFinished
    }

    private func accept(_ error: Error) {
        receiveError = error
    }
}

private actor BufferedScreenVoicePTTTranscriptionBackend: ScreenVoicePTTTranscriptionBackend {
    private static let maximumPCMBytes = 4_000_000

    private let service: any CloudSpeechToTextServicing
    private let model: String
    private let languageCode: String?
    private var pcm = Data()
    private var task: Task<CloudTranscription, Error>?

    init(
        service: any CloudSpeechToTextServicing,
        model: String,
        languageCode: String?
    ) {
        self.service = service
        self.model = model
        self.languageCode = languageCode
    }

    func start() async throws {}

    func consume(_ chunk: ScreenVoicePTTAudioChunk) async throws {
        guard pcm.count <= Self.maximumPCMBytes - chunk.pcm16LittleEndian.count else {
            throw ScreenVoicePTTError.recordingTimedOut
        }
        pcm.append(chunk.pcm16LittleEndian)
    }

    func shouldStopAfterProviderEndpoint() async throws -> Bool { false }

    func finish() async throws -> String {
        let wav = try Self.wavData(pcm: pcm)
        pcm.removeAll(keepingCapacity: false)
        let request = CloudTranscriptionRequest(
            audioData: wav,
            filename: "openclam-screen-voice.wav",
            mimeType: "audio/wav",
            model: model,
            languageCode: languageCode
        )
        let task = Task { try await service.transcribe(request) }
        self.task = task
        defer { self.task = nil }
        return try await task.value.text
    }

    func cancel() async {
        task?.cancel()
        task = nil
        pcm.removeAll(keepingCapacity: false)
    }

    private static func wavData(pcm: Data) throws -> Data {
        guard !pcm.isEmpty,
              pcm.count.isMultiple(of: MemoryLayout<Int16>.size),
              pcm.count <= Int(UInt32.max) - 44 else {
            throw ScreenVoicePTTError.emptyTranscript
        }
        var data = Data()
        data.append(Data("RIFF".utf8))
        append(UInt32(36 + pcm.count), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(ScreenVoicePTTAudioChunk.sampleRate), to: &data)
        append(UInt32(ScreenVoicePTTAudioChunk.sampleRate * 2), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        append(UInt32(pcm.count), to: &data)
        data.append(pcm)
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
