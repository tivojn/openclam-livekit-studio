import AVFoundation
import Foundation

@MainActor
protocol ScreenVoicePTTAudioSessionConfiguring: AnyObject {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws

    func setActive(
        _ active: Bool,
        options: AVAudioSession.SetActiveOptions
    ) throws
}

extension AVAudioSession: ScreenVoicePTTAudioSessionConfiguring {}

struct ScreenVoicePTTAudioChunk: Equatable, Sendable {
    static let sampleRate = 16_000

    let pcm16LittleEndian: Data
    let duration: TimeInterval
    let rms: Double
}

@MainActor
final class ScreenVoicePTTMicrophoneSource {
    private let engine = AVAudioEngine()
    private let audioSession: any ScreenVoicePTTAudioSessionConfiguring
    private var continuation: AsyncThrowingStream<ScreenVoicePTTAudioChunk, Error>.Continuation?
    private var interruptionObserver: NSObjectProtocol?
    private var noSpeechWallClockTask: Task<Void, Never>?
    private var hardWallClockTask: Task<Void, Never>?
    private var hasTap = false
    private var active = false

    init(
        audioSession: any ScreenVoicePTTAudioSessionConfiguring = AVAudioSession.sharedInstance()
    ) {
        self.audioSession = audioSession
    }

    func preflightPermission() async throws {
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
        guard granted else { throw ScreenVoicePTTError.microphonePermissionDenied }
    }

    func start() async throws -> AsyncThrowingStream<ScreenVoicePTTAudioChunk, Error> {
        guard !active else { throw ScreenVoicePTTError.busy }
        try await preflightPermission()

        do {
            try configureAudioSessionForCapture()

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0,
                  inputFormat.channelCount > 0,
                  let converter = ScreenVoicePTTPCMConverter(inputFormat: inputFormat) else {
                throw ScreenVoicePTTError.audioCaptureUnavailable
            }

            var capturedContinuation: AsyncThrowingStream<ScreenVoicePTTAudioChunk, Error>.Continuation!
            let stream = AsyncThrowingStream<ScreenVoicePTTAudioChunk, Error>(
                bufferingPolicy: .bufferingOldest(64)
            ) { capturedContinuation = $0 }
            continuation = capturedContinuation

            input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) {
                [weak self] buffer, _ in
                guard let pcm = converter.convert(buffer), !pcm.isEmpty else { return }
                let chunk = ScreenVoicePTTAudioChunk(
                    pcm16LittleEndian: pcm,
                    duration: Double(pcm.count / 2) / Double(ScreenVoicePTTAudioChunk.sampleRate),
                    rms: ScreenVoicePTTVAD.rms(ofPCM16LittleEndian: pcm)
                )
                switch capturedContinuation.yield(chunk) {
                case .enqueued:
                    break
                case .dropped:
                    Task { @MainActor [weak self] in
                        self?.stop(throwing: ScreenVoicePTTError.audioStreamOverflow)
                    }
                case .terminated:
                    break
                @unknown default:
                    Task { @MainActor [weak self] in
                        self?.stop(throwing: ScreenVoicePTTError.audioStreamOverflow)
                    }
                }
            }
            hasTap = true
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] notification in
                guard let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                        as? UInt,
                      AVAudioSession.InterruptionType(rawValue: rawValue) == .began else { return }
                Task { @MainActor [weak self] in
                    self?.stop(throwing: ScreenVoicePTTError.interrupted)
                }
            }

            engine.prepare()
            try engine.start()
            active = true
            noSpeechWallClockTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                guard !Task.isCancelled else { return }
                self?.stop(throwing: ScreenVoicePTTError.noSpeechDetected)
            }
            hardWallClockTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled else { return }
                // A hard deadline ends the stream normally so a bounded partial question can
                // still be finalized instead of losing all recognized speech.
                self?.stop(throwing: nil)
            }
            return stream
        } catch {
            stop(throwing: error)
            throw error
        }
    }

    func stop() {
        stop(throwing: nil)
    }

    func cancel() {
        stop(throwing: CancellationError())
    }

    func markSpeechDetected() {
        noSpeechWallClockTask?.cancel()
        noSpeechWallClockTask = nil
    }

    private func stop(throwing error: Error?) {
        noSpeechWallClockTask?.cancel()
        noSpeechWallClockTask = nil
        hardWallClockTask?.cancel()
        hardWallClockTask = nil
        if engine.isRunning { engine.stop() }
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
        active = false
        deactivateAudioSession()
    }

    func configureAudioSessionForCapture() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.duckOthers]
        )
        try audioSession.setActive(true, options: [])
    }

    func deactivateAudioSession() {
        try? audioSession.setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}

private final class ScreenVoicePTTPCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(ScreenVoicePTTAudioChunk.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func convert(_ input: AVAudioPCMBuffer) -> Data? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = max(1, Int(ceil(Double(input.frameLength) * ratio)) + 32)
        guard capacity <= Int(UInt32.max),
              let output = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(capacity)
              ) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil,
              status != .error,
              output.frameLength > 0,
              let samples = output.int16ChannelData?.pointee else { return nil }
        return Data(
            bytes: samples,
            count: Int(output.frameLength) * MemoryLayout<Int16>.size
        )
    }
}
