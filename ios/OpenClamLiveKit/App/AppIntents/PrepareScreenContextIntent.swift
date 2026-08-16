import AppIntents
import Foundation
import UniformTypeIdentifiers

/// An Action Button-safe entry point. Running it captures no screen content: it only opens the
/// app at a consent boundary where the person can choose a screenshot or use the Share sheet.
struct PrepareScreenContextIntent: AppIntent {
    static let title: LocalizedStringResource = "Prepare Screen Context"
    static let description = IntentDescription(
        "Opens OpenClam so you can choose or share context. It does not inspect the current screen."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let inbox = try ScreenContextInbox.appGroup()
        _ = try await inbox.stage(.init(source: .actionButton))
        return .result(
            dialog: "OpenClam is ready. Choose a screenshot or share content, then say what you want done."
        )
    }
}

/// A user-built Shortcut may explicitly pass text or a public web URL into the review inbox.
/// The intent has no API for reading another app's current screen and never contacts an AI service.
struct ReceiveScreenContextIntent: AppIntent {
    static let title: LocalizedStringResource = "Review Shared Context"
    static let description = IntentDescription(
        "Saves text or a web link that you explicitly pass from Shortcuts for review in OpenClam."
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "What should OpenClam do?",
        requestValueDialog: "What should OpenClam do with this context?"
    )
    var instruction: String

    @Parameter(title: "Shared text")
    var sharedText: String?

    @Parameter(title: "Shared web link")
    var sharedURL: URL?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let inbox = try ScreenContextInbox.appGroup()
        _ = try await inbox.stage(
            .init(
                source: .shortcut,
                instruction: instruction,
                sharedText: sharedText,
                sharedURL: sharedURL
            )
        )
        return .result(
            dialog: "The context is waiting in OpenClam. Review exactly what is included, then tap Send."
        )
    }
}

/// The near-live public-API fallback for asking about another app's screen.
///
/// The user-created Shortcut owns the explicit `Take Screenshot` and `Dictate Text` steps. This
/// action accepts only those two outputs, validates and stages them locally for one review, then
/// opens OpenClam. It never captures a screen, records audio, runs OCR, or contacts an AI provider.
struct ReviewScreenshotAndDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Review Screenshot and Dictation"
    static let description = IntentDescription(
        "Stages one screenshot and your dictated instruction for review in OpenClam. Nothing is analyzed or sent automatically."
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "Screenshot",
        description: "The single image produced by Shortcuts' Take Screenshot action.",
        requestValueDialog: "Choose one JPEG or PNG screenshot."
    )
    var screenshot: IntentFile

    @Parameter(
        title: "What should OpenClam do?",
        description: "Connect the result of Shortcuts' Dictate Text action.",
        requestValueDialog: "What should OpenClam do with this screenshot?",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var instruction: String

    static var parameterSummary: some ParameterSummary {
        Summary("Review \(\.$screenshot) using \(\.$instruction)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let validatedInstruction = try ScreenContextInbox.validatedShortcutInstruction(instruction)
        try preflightFileSizeIfAvailable(screenshot)
        let imageData = screenshot.data
        let typeIdentifier = try ScreenContextInbox.validatedShortcutScreenshot(
            data: imageData,
            declaredTypeIdentifier: screenshot.type?.identifier
        )
        let inbox = try ScreenContextInbox.appGroup()
        _ = try await inbox.stage(
            .init(
                source: .shortcut,
                instruction: validatedInstruction,
                imageData: imageData,
                imageTypeIdentifier: typeIdentifier
            )
        )
        return .result(
            dialog: "The screenshot and instruction are waiting in OpenClam for your review. No OCR or AI request has run."
        )
    }

    private func preflightFileSizeIfAvailable(_ file: IntentFile) throws {
        guard let fileURL = file.fileURL else { return }
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false else {
            throw ScreenContextError.invalidShortcutImage
        }
        if let byteCount = values.fileSize,
           byteCount <= 0 || byteCount > ScreenContextInbox.maximumImageBytes {
            throw ScreenContextError.imageTooLarge
        }
    }
}

#if OPENCLAM_LIVE_SCREEN_CONTEXT
/// Intended for an Action Button Shortcut whose `question` input is supplied by Shortcuts'
/// "Dictate Text" action. This intent does not open the app, start capture, access a microphone,
/// or contain provider credentials. It queues one short-lived question for an already active,
/// visibly disclosed iOS 27 screen-capture session.
struct AskAboutCurrentScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask About Current Screen"
    static let description = IntentDescription(
        "Queues one dictated question for your active, visibly disclosed Screen Context session."
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "Question",
        requestValueDialog: "What would you like to ask about the current screen?"
    )
    var question: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let inbox = try ScreenContextQuestionInbox.appGroup()
        _ = try await inbox.stage(question)
        return .result(
            dialog: "Question queued for the active Screen Context session. It expires in two minutes if no session consumes it."
        )
    }
}
#endif
