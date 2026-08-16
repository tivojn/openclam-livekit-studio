import AppIntents
import Foundation
import UniformTypeIdentifiers

#if !OPENCLAM_IOS27_APPINTENTS
/// Compile-time stand-in used by Xcode releases whose AppIntents SDK predates iOS 27.
/// It keeps the intent contract testable without pretending the unavailable system capability
/// will be registered on those SDKs.
enum OpenClamIntentExecutionTargets: Equatable {
    case main
}
#endif

/// Headless Action Button boundary. Shortcuts explicitly supplies one screenshot and final text
/// question. The returned plain text is intended to feed Apple's separate Speak Text action.
struct AskOpenClamAboutScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask OpenClam About Screen"
    static let description = IntentDescription(
        "Analyzes one explicitly supplied screenshot and question using the OpenAI or xAI model saved in OpenClam."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy =
        .requiresLocalDeviceAuthentication

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    #if OPENCLAM_IOS27_APPINTENTS
        @available(iOS 27.0, *)
        static var allowedExecutionTargets: IntentExecutionTargets { .main }
    #else
        @available(iOS 27.0, *)
        static var allowedExecutionTargets: OpenClamIntentExecutionTargets { .main }
    #endif

    @Parameter(
        title: "Screenshot",
        description: "The single image produced by Shortcuts' Take Screenshot action.",
        requestValueDialog: "Choose one JPEG or PNG screenshot."
    )
    var screenshot: IntentFile

    @Parameter(
        title: "Visible screen text",
        description: "Optional text explicitly returned by Shortcuts' onscreen-content action."
    )
    var visibleText: String?

    @Parameter(
        title: "Question",
        description: "Connect final text from Dictate Text or another explicit transcription action.",
        requestValueDialog: "What would you like to ask about this screen?",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$question) about \(\.$screenshot)") {
            \.$visibleText
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let payload = try await Self.materializeScreenshot(screenshot)
        let service = try ScreenPTTRuntime.makeService()
        let answer = try await service.ask(
            .init(
                screenshotData: payload.data,
                screenshotTypeIdentifier: payload.typeIdentifier,
                visibleText: visibleText,
                question: question
            )
        )
        return .result(value: answer)
    }

    /// Materializes an app-readable copy instead of opening Shortcuts' private temporary URL.
    /// iOS 17 retains the prior synchronous path because the brokered IntentFile API starts in
    /// iOS 18; current systems always keep every URL access inside `withFile`'s scoped closure.
    static func materializeScreenshot(
        _ file: IntentFile
    ) async throws -> (data: Data, typeIdentifier: String) {
        do {
            try Task.checkCancellation()
            if #available(iOS 18.0, *) {
                let contentType = try requestedScreenshotContentType(for: file)
                let payload = try await file.withFile(
                    contentType: contentType,
                    allowOpenInPlace: false
                ) { fileURL, _ in
                    try Task.checkCancellation()
                    let values = try fileURL.resourceValues(
                        forKeys: [.fileSizeKey, .isRegularFileKey]
                    )
                    guard values.isRegularFile != false,
                          let byteCount = values.fileSize,
                          byteCount > 0 else {
                        throw ScreenContextError.invalidShortcutImage
                    }
                    guard byteCount <= ScreenContextInbox.maximumImageBytes else {
                        throw ScreenContextError.imageTooLarge
                    }

                    let data = try Data(contentsOf: fileURL)
                    try Task.checkCancellation()
                    let validatedType = try ScreenContextInbox.validatedShortcutScreenshot(
                        data: data,
                        declaredTypeIdentifier: contentType.identifier
                    )
                    return (data, validatedType)
                }
                try Task.checkCancellation()
                return payload
            }

            try preflightLegacyFileSizeIfAvailable(file)
            let data = file.data
            try Task.checkCancellation()
            let validatedType = try ScreenContextInbox.validatedShortcutScreenshot(
                data: data,
                declaredTypeIdentifier: file.type?.identifier
            )
            return (data, validatedType)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ScreenContextError {
            throw error
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw ScreenContextError.invalidShortcutImage
        }
    }

    @available(iOS 18.0, *)
    private static func requestedScreenshotContentType(for file: IntentFile) throws -> UTType {
        let advertisedTypes = file.availableContentTypes
        if let declaredType = file.type,
           advertisedTypes.contains(where: { $0.identifier == declaredType.identifier }) {
            return declaredType
        }
        if let pngType = advertisedTypes.first(where: { $0.conforms(to: .png) }) {
            return pngType
        }
        if let jpegType = advertisedTypes.first(where: { $0.conforms(to: .jpeg) }) {
            return jpegType
        }
        if let imageType = advertisedTypes.first(where: { $0.conforms(to: .image) }) {
            return imageType
        }
        if let declaredType = file.type, declaredType.conforms(to: .image) {
            return declaredType
        }
        let filenameExtension = (file.filename as NSString).pathExtension
        if let filenameType = UTType(filenameExtension: filenameExtension),
           filenameType.conforms(to: .png) || filenameType.conforms(to: .jpeg) {
            return filenameType
        }
        throw ScreenContextError.invalidShortcutImage
    }

    private static func preflightLegacyFileSizeIfAvailable(_ file: IntentFile) throws {
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

struct ResetScreenPTTSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Screen PTT Session"
    static let description = IntentDescription(
        "Clears the bounded text-only follow-up context used by Ask OpenClam About Screen."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy =
        .requiresLocalDeviceAuthentication

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    #if OPENCLAM_IOS27_APPINTENTS
        @available(iOS 27.0, *)
        static var allowedExecutionTargets: IntentExecutionTargets { .main }
    #else
        @available(iOS 27.0, *)
        static var allowedExecutionTargets: OpenClamIntentExecutionTargets { .main }
    #endif

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let service = try ScreenPTTRuntime.makeService()
        try await service.resetSession()
        return .result(value: "Screen PTT follow-up context was reset.")
    }
}
