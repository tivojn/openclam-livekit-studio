import Foundation

/// Provider-independent, deterministic endpoint detector for a single push-to-talk question.
/// Provider semantic endpoints may finish sooner, but can never extend these local bounds.
struct ScreenVoicePTTVAD: Sendable {
    struct Configuration: Equatable, Sendable {
        var speechThreshold: Double = 0.025
        var silenceThreshold: Double = 0.012
        var minimumSpeechDuration: TimeInterval = 0.12
        var trailingSilenceDuration: TimeInterval = 0.85
        var noSpeechTimeout: TimeInterval = 7
        var hardTimeout: TimeInterval = 25

        func validated() -> Self {
            var copy = self
            copy.speechThreshold = max(0.001, min(1, copy.speechThreshold))
            copy.silenceThreshold = max(0, min(copy.speechThreshold, copy.silenceThreshold))
            copy.minimumSpeechDuration = max(0.04, min(2, copy.minimumSpeechDuration))
            copy.trailingSilenceDuration = max(0.2, min(4, copy.trailingSilenceDuration))
            copy.noSpeechTimeout = max(1, min(15, copy.noSpeechTimeout))
            copy.hardTimeout = max(copy.noSpeechTimeout, min(60, copy.hardTimeout))
            return copy
        }
    }

    enum Decision: Equatable, Sendable {
        case continueListening
        case finishAfterSpeech
        case noSpeechTimeout
        case hardTimeout
    }

    private let configuration: Configuration
    private(set) var elapsed: TimeInterval = 0
    private(set) var hasSpeech = false
    private var candidateSpeechDuration: TimeInterval = 0
    private var trailingSilenceDuration: TimeInterval = 0

    init(configuration: Configuration = .init()) {
        self.configuration = configuration.validated()
    }

    mutating func ingest(rms: Double, duration: TimeInterval) -> Decision {
        let boundedDuration = max(0, min(1, duration))
        let boundedRMS = max(0, min(1, rms.isFinite ? rms : 0))
        elapsed += boundedDuration

        if !hasSpeech {
            if boundedRMS >= configuration.speechThreshold {
                candidateSpeechDuration += boundedDuration
                if candidateSpeechDuration >= configuration.minimumSpeechDuration {
                    hasSpeech = true
                    trailingSilenceDuration = 0
                }
            } else {
                candidateSpeechDuration = 0
            }

            if !hasSpeech, elapsed >= configuration.noSpeechTimeout {
                return .noSpeechTimeout
            }
        } else if boundedRMS <= configuration.silenceThreshold {
            trailingSilenceDuration += boundedDuration
            if trailingSilenceDuration >= configuration.trailingSilenceDuration {
                return .finishAfterSpeech
            }
        } else {
            trailingSilenceDuration = 0
        }

        if elapsed >= configuration.hardTimeout {
            return hasSpeech ? .hardTimeout : .noSpeechTimeout
        }
        return .continueListening
    }

    static func rms(ofPCM16LittleEndian data: Data) -> Double {
        guard data.count >= 2 else { return 0 }
        return data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            let sampleCount = bytes.count / 2
            guard sampleCount > 0 else { return 0 }
            var sum = 0.0
            for index in 0..<sampleCount {
                let offset = index * 2
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let value = Double(Int16(bitPattern: bits)) / Double(Int16.max)
                sum += value * value
            }
            return sqrt(sum / Double(sampleCount))
        }
    }
}
