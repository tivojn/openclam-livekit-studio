import Combine
import Foundation

protocol ScreenContextTextRecognizing: Sendable {
    func recognizeText(in imageData: Data) async throws -> String
}

struct SystemScreenContextTextRecognizer: ScreenContextTextRecognizing {
    func recognizeText(in imageData: Data) async throws -> String {
        try await ScreenshotOCRService.recognizeText(in: imageData)
    }
}

/// Main-app review state for explicitly shared or selected context.
///
/// Restoring, selecting, and local OCR never contact an AI provider. `consumeForOneRequest`
/// clears the review before returning an exact payload; the caller still needs a separate user
/// Send action through the app's bounded request path.
@MainActor
final class ScreenContextReviewSession: ObservableObject {
    @Published private(set) var review: ScreenContextReview?
    @Published private(set) var lastMessage: String?

    private let inbox: ScreenContextInbox?

    init(inbox: ScreenContextInbox? = nil) {
        self.inbox = inbox
    }

    static func appGroupBacked() throws -> ScreenContextReviewSession {
        ScreenContextReviewSession(inbox: try ScreenContextInbox.appGroup())
    }

    @discardableResult
    func restorePendingIntake(now: Date = Date()) async throws -> Bool {
        guard let inbox else { throw ScreenContextError.appGroupUnavailable }
        guard let intake = try await inbox.take(now: now) else { return false }
        review = ScreenContextReview(intake: intake)
        lastMessage = intake.source == .actionButton
            ? "Screen Context is ready. Choose a screenshot or share content, then say what to do with it."
            : "Shared context is ready for local review. Nothing has been sent."
        return true
    }

    func stageSelectedScreenshot(
        data: Data,
        typeIdentifier: String,
        instruction: String,
        now: Date = Date()
    ) throws {
        let draft = try ScreenContextInbox.validated(
            .init(
                source: .selectedScreenshot,
                instruction: instruction,
                imageData: data,
                imageTypeIdentifier: typeIdentifier
            )
        )
        review = ScreenContextReview(
            intake: .init(
                id: UUID(),
                source: draft.source,
                instruction: draft.instruction,
                sharedText: nil,
                sharedURL: nil,
                imageData: draft.imageData,
                imageTypeIdentifier: draft.imageTypeIdentifier,
                createdAt: now,
                expiresAt: now.addingTimeInterval(ScreenContextInbox.intakeLifetime)
            )
        )
        lastMessage = "Screenshot selected. No OCR or AI request has run."
    }

    func extractTextAfterUserConfirmation(
        reviewID: UUID,
        recognizer: any ScreenContextTextRecognizing = SystemScreenContextTextRecognizer()
    ) async throws {
        guard var current = review, current.id == reviewID else {
            throw ScreenContextError.noPendingIntake
        }
        guard current.expiresAt > Date() else {
            review = nil
            throw ScreenContextError.noPendingIntake
        }
        guard current.locallyExtractedText == nil else {
            throw ScreenContextError.OCRAlreadyRequested
        }
        guard let imageData = current.imageData else {
            throw ScreenContextError.noSelectedImage
        }
        let text = try await recognizer.recognizeText(in: imageData)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedText = String(text.prefix(ScreenContextInbox.maximumTextCharacters))
        current.locallyExtractedText = boundedText
        current.extractionWasTruncated = text.count > boundedText.count
        review = current
        lastMessage = "Text was extracted locally. Review and edit the request before sending."
    }

    func consumeForOneRequest(
        reviewID: UUID,
        editedInstruction: String,
        includeText: Bool,
        includeURL: Bool,
        includeImage: Bool,
        now: Date = Date()
    ) throws -> ScreenContextSubmission {
        guard let current = review, current.id == reviewID, current.expiresAt > now else {
            review = nil
            throw ScreenContextError.noPendingIntake
        }
        let instruction = editedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { throw ScreenContextError.instructionRequired }
        guard instruction.count <= ScreenContextInbox.maximumInstructionCharacters,
              instruction.utf8.count <= ScreenContextInbox.maximumInstructionBytes else {
            throw ScreenContextError.instructionTooLong
        }

        let chosenText = includeText
            ? (current.locallyExtractedText ?? current.sharedText)
            : nil
        let chosenURL = includeURL ? current.sharedURL : nil
        let chosenImage = includeImage ? current.imageData : nil
        guard chosenText?.isEmpty == false || chosenURL != nil || chosenImage != nil else {
            throw ScreenContextError.noIncludedContext
        }

        // Burn the review before handing bytes to the caller. A retry needs a fresh local review.
        review = nil
        lastMessage = "Context approved for one request. Nothing has been sent yet."
        return .init(
            reviewID: current.id,
            instruction: instruction,
            includedText: chosenText,
            includedURL: chosenURL,
            includedImageData: chosenImage,
            includedImageTypeIdentifier: chosenImage == nil ? nil : current.imageTypeIdentifier
        )
    }

    func discard() {
        review = nil
        lastMessage = "Screen context discarded. Nothing was sent."
    }
}
