import AVFoundation
import Foundation

@MainActor
final class ScreenVoicePTTAnswerSpeaker: NSObject, ScreenVoicePTTSpeaking,
    @preconcurrency AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let credentialVault: any ProviderCredentialVault
    private let audioSession: any ScreenVoicePTTAudioSessionConfiguring
    private let settingsLoader = ScreenVoicePTTSpeakerSettingsLoader()
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var cloudTask: Task<CloudSpeechAudio, Error>?
    private var playbackContinuation: CheckedContinuation<Void, Error>?
    private var interruptionObserver: NSObjectProtocol?
    private var audiblePlaybackStartedAt: Date?

    init(
        credentialVault: any ProviderCredentialVault = KeychainProviderCredentialVault(),
        audioSession: any ScreenVoicePTTAudioSessionConfiguring = AVAudioSession.sharedInstance()
    ) {
        self.credentialVault = credentialVault
        self.audioSession = audioSession
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ScreenVoicePTTError.playbackFailed }
        guard playbackContinuation == nil, cloudTask == nil else {
            throw ScreenVoicePTTError.busy
        }
        audiblePlaybackStartedAt = nil

        let selection = try settingsLoader.load().textToSpeech.validated(for: .textToSpeech)
        try activatePlaybackSession()
        do {
            if selection.provider == .apple {
                try await speakWithApple(normalized)
            } else {
                let service = try makeCloudService(for: selection.provider)
                let task = Task {
                    try await service.synthesize(
                        CloudSpeechSynthesisRequestResolver.resolve(
                            text: normalized,
                            selection: selection,
                            localeLanguageCode: Locale.current.language.languageCode?.identifier
                        )
                    )
                }
                cloudTask = task
                let audio = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                cloudTask = nil
                try await playCloudAudio(audio.data)
            }
            deactivatePlaybackSession()
        } catch {
            cancelPlayback(throwing: error)
            throw error
        }
    }

    func cancel() async {
        cancelPlayback(throwing: CancellationError())
    }

    func audiblePlaybackDuration() async -> TimeInterval {
        guard let audiblePlaybackStartedAt else { return 0 }
        return max(0, Date().timeIntervalSince(audiblePlaybackStartedAt))
    }

    private func speakWithApple(_ text: String) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                playbackContinuation = continuation
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPlayback(throwing: CancellationError())
            }
        }
    }

    private func playCloudAudio(_ data: Data) async throws {
        guard !data.isEmpty else { throw ScreenVoicePTTError.playbackFailed }
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data)
        } catch {
            throw ScreenVoicePTTError.playbackFailed
        }
        self.player = player
        player.delegate = self
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                playbackContinuation = continuation
                guard player.prepareToPlay(), player.play() else {
                    playbackContinuation = nil
                    self.player = nil
                    continuation.resume(throwing: ScreenVoicePTTError.playbackFailed)
                    return
                }
                audiblePlaybackStartedAt = Date()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPlayback(throwing: CancellationError())
            }
        }
    }

    private func makeCloudService(
        for provider: AIProviderID
    ) throws -> any CloudTextToSpeechServicing {
        do {
            guard try credentialVault.containsCredential(for: provider) else {
                throw ScreenVoicePTTError.missingSpeechCredential(provider)
            }
        } catch let error as ScreenVoicePTTError {
            throw error
        } catch {
            throw ScreenVoicePTTError.missingSpeechCredential(provider)
        }

        let credentialStore = ProviderScopedAgentCredentialStore(
            provider: provider,
            vault: credentialVault
        )
        switch provider {
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
            throw ScreenVoicePTTError.unsupportedSpeechProvider(provider)
        }
    }

    func activatePlaybackSession() throws {
        try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try audioSession.setActive(true, options: [])
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            guard let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                    as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawValue) == .began else { return }
            Task { @MainActor [weak self] in
                self?.cancelPlayback(throwing: ScreenVoicePTTError.interrupted)
            }
        }
    }

    func deactivatePlaybackSession() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        try? audioSession.setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func cancelPlayback(throwing error: Error) {
        cloudTask?.cancel()
        cloudTask = nil
        let continuation = playbackContinuation
        playbackContinuation = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        player?.stop()
        player = nil
        continuation?.resume(throwing: error)
        deactivatePlaybackSession()
    }

    private func finishPlayback(_ result: Result<Void, Error>) {
        player = nil
        let continuation = playbackContinuation
        playbackContinuation = nil
        continuation?.resume(with: result)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        audiblePlaybackStartedAt = Date()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        finishPlayback(.success(()))
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        finishPlayback(.failure(CancellationError()))
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishPlayback(flag ? .success(()) : .failure(ScreenVoicePTTError.playbackFailed))
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finishPlayback(.failure(error ?? ScreenVoicePTTError.playbackFailed))
    }
}

private struct ScreenVoicePTTSpeakerSettingsLoader: Sendable {
    func load() throws -> AIProviderSettings {
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: "ai.provider.settings.v2")
            ?? defaults.data(forKey: "ai.provider.settings.v1")
        guard let data else { return AIProviderSettings() }
        guard let settings = try? JSONDecoder().decode(AIProviderSettings.self, from: data) else {
            throw AIProviderSettingsError.missingModel
        }
        return try settings.validated()
    }
}
