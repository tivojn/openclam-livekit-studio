import Foundation

struct ScreenVoicePTTRequest: Sendable {
    let screenshotData: Data
    let screenshotTypeIdentifier: String?
    let visibleText: String?

    init(
        screenshotData: Data,
        screenshotTypeIdentifier: String? = nil,
        visibleText: String? = nil
    ) {
        self.screenshotData = screenshotData
        self.screenshotTypeIdentifier = screenshotTypeIdentifier
        self.visibleText = visibleText
    }
}


enum ScreenVoicePTTError: Error, Equatable, LocalizedError {
    case busy
    case microphonePermissionDenied
    case speechPermissionDenied
    case speechRecognitionUnavailable
    case audioCaptureUnavailable
    case audioStreamOverflow
    case interrupted
    case noSpeechDetected
    case recordingTimedOut
    case transcriptionTimedOut
    case emptyTranscript
    case transcriptTooLong
    case unsupportedSpeechProvider(AIProviderID)
    case missingSpeechCredential(AIProviderID)
    case invalidScreenshot
    case liveActivitiesDisabled
    case playbackFailed
    case playbackTimedOut

    var errorDescription: String? {
        switch self {
        case .busy:
            "OpenClam is already handling a Screen Voice question."
        case .microphonePermissionDenied:
            "Allow microphone access for OpenClam, then press the Action Button again."
        case .speechPermissionDenied:
            "Allow speech recognition for OpenClam, then press the Action Button again."
        case .speechRecognitionUnavailable:
            "The selected speech-recognition service is unavailable right now."
        case .audioCaptureUnavailable:
            "OpenClam could not start a bounded microphone recording."
        case .audioStreamOverflow:
            "The microphone stream could not keep up safely. Please try again."
        case .interrupted:
            "The Screen Voice turn was interrupted by another audio session."
        case .noSpeechDetected:
            "No speech was detected. Press the Action Button and ask again."
        case .recordingTimedOut:
            "The Screen Voice question reached its recording limit."
        case .transcriptionTimedOut:
            "The selected speech-recognition service did not finish in time. Please try again."
        case .emptyTranscript:
            "OpenClam could not recognize a question."
        case .transcriptTooLong:
            "Keep a Screen Voice question under 2,000 characters."
        case .unsupportedSpeechProvider(let provider):
            "Screen Voice does not support the selected \(AIProviderRegistry.descriptor(for: provider).displayName) voice mode."
        case .missingSpeechCredential(let provider):
            "Save a \(AIProviderRegistry.descriptor(for: provider).displayName) key in OpenClam, then try again."
        case .invalidScreenshot:
            "The Shortcut did not pass one valid screenshot to OpenClam."
        case .liveActivitiesDisabled:
            "Enable Live Activities for OpenClam before using background Screen Voice."
        case .playbackFailed:
            "OpenClam produced an answer but could not play it aloud."
        case .playbackTimedOut:
            "OpenClam stopped the spoken answer at the one-minute safety limit."
        }
    }
}
