import Combine
import Foundation

struct ScreenContextFrame: Identifiable, Equatable, Sendable {
    let id: UUID
    let jpegData: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let capturedAt: Date
}

/// A question and the single latest frame that was present when the active session consumed it.
/// This value performs no networking; the root integration may use it for exactly one request.
struct ScreenContextQuestion: Identifiable, Equatable, Sendable {
    let id: UUID
    let question: String
    let latestFrame: ScreenContextFrame
    let createdAt: Date
}

enum ScreenContextCaptureError: Error, Equatable, LocalizedError {
    case disclosureRequired
    case captureNotReady
    case staleFrame
    case frameTooLarge
    case invalidFrame
    case anotherQuestionIsWaiting
    case noQuestionWaiting
    case questionMismatch
    case requiresIOS27

    var errorDescription: String? {
        switch self {
        case .disclosureRequired:
            "Review and accept the screen-session disclosure first."
        case .captureNotReady:
            "Start visible screen capture and wait for a current frame first."
        case .staleFrame:
            "The retained screen frame was no longer current. Wait for a fresh frame, then ask again."
        case .frameTooLarge:
            "The current screen frame exceeded the 1 MB boundary and was dropped."
        case .invalidFrame:
            "The current screen frame is invalid."
        case .anotherQuestionIsWaiting:
            "Review the current screen question before asking another one."
        case .noQuestionWaiting:
            "There is no screen question waiting for this session."
        case .questionMismatch:
            "That screen question no longer matches the one waiting for review."
        case .requiresIOS27:
            "Full-display Screen Context requires iOS 27 and the Screen Recording capability."
        }
    }
}

enum ScreenContextCapturePolicy {
    static let maximumFrameBytes = 1_000_000
    static let maximumFrameDimension = 1_280
    /// Frames normally arrive every 0.75 seconds. Three seconds tolerates brief background
    /// scheduling delays while failing closed if capture stalls or protected content yields no
    /// current frame.
    static let maximumFrameAge: TimeInterval = 3
    static let disclosure = "During this capture session, each question you explicitly dictate through your Shortcut will send that question and the current screen frame to your selected AI provider. Screen capture remains visibly active until you stop it. OpenClam does not use a wake word or keep its microphone listening."
}

/// Testable consent and one-shot buffer used by the iOS 27 ScreenCaptureKit adapter.
/// It retains only the latest live frame; every accepted frame replaces the previous frame.
@MainActor
final class ScreenContextCaptureSession: ObservableObject {
    @Published private(set) var disclosureAccepted = false
    @Published private(set) var latestFrame: ScreenContextFrame?
    @Published private(set) var pendingQuestion: ScreenContextQuestion?

    func acceptDisclosure() {
        disclosureAccepted = true
    }

    func replaceLatestFrame(_ frame: ScreenContextFrame) throws {
        guard disclosureAccepted else { throw ScreenContextCaptureError.disclosureRequired }
        guard !frame.jpegData.isEmpty, frame.pixelWidth > 0, frame.pixelHeight > 0 else {
            throw ScreenContextCaptureError.invalidFrame
        }
        guard frame.jpegData.count <= ScreenContextCapturePolicy.maximumFrameBytes,
              frame.pixelWidth <= ScreenContextCapturePolicy.maximumFrameDimension,
              frame.pixelHeight <= ScreenContextCapturePolicy.maximumFrameDimension else {
            throw ScreenContextCaptureError.frameTooLarge
        }
        latestFrame = frame
    }

    @discardableResult
    func pair(
        _ queued: QueuedScreenContextQuestion,
        now: Date = Date()
    ) throws -> ScreenContextQuestion {
        guard disclosureAccepted else { throw ScreenContextCaptureError.disclosureRequired }
        guard pendingQuestion == nil else {
            throw ScreenContextCaptureError.anotherQuestionIsWaiting
        }
        guard queued.expiresAt > now, let latestFrame else {
            throw ScreenContextCaptureError.captureNotReady
        }
        let frameAge = now.timeIntervalSince(latestFrame.capturedAt)
        guard frameAge >= 0, frameAge <= ScreenContextCapturePolicy.maximumFrameAge else {
            // The Shortcut question has already been removed from its one-slot inbox before it
            // reaches this boundary. Discard the stale frame too, so neither can be reused for a
            // later request after capture stalls or the wall clock moves backwards.
            self.latestFrame = nil
            pendingQuestion = nil
            throw ScreenContextCaptureError.staleFrame
        }
        let paired = ScreenContextQuestion(
            id: queued.id,
            question: queued.question,
            latestFrame: latestFrame,
            createdAt: now
        )
        pendingQuestion = paired
        return paired
    }

    /// Burn the pair before handing it to the root. The session disclosure authorizes one request
    /// for each explicit dictated question; retries require dictating another question.
    func consumeForOneRequest(questionID: UUID) throws -> ScreenContextQuestion {
        guard disclosureAccepted else { throw ScreenContextCaptureError.disclosureRequired }
        guard let current = pendingQuestion else {
            throw ScreenContextCaptureError.noQuestionWaiting
        }
        pendingQuestion = nil
        guard current.id == questionID else {
            throw ScreenContextCaptureError.questionMismatch
        }
        return current
    }

    /// Used when the live-session view is mounted after a question was already paired. Returning
    /// nil is intentionally harmless; a non-nil pair is burned before the caller can submit it.
    func consumePendingForOneRequestIfAvailable() throws -> ScreenContextQuestion? {
        guard let questionID = pendingQuestion?.id else { return nil }
        return try consumeForOneRequest(questionID: questionID)
    }

    func endSession() {
        disclosureAccepted = false
        latestFrame = nil
        pendingQuestion = nil
    }
}
