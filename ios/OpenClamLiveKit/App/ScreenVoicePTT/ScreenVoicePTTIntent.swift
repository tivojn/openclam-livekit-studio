import AppIntents
import Foundation
import UniformTypeIdentifiers

/// One user-visible, user-initiated Screen Voice turn for an Action Button Shortcut:
/// Take Screenshot -> Ask OpenClam With Voice.
///
/// The marker protocols authorize the bounded recording/playback operation; they do not create a
/// hidden always-on microphone or screen observer. OpenClam starts a Live Activity before opening
/// the microphone and ends both audio and activity before this invocation returns.
@available(iOS 27.0, *)
struct AskOpenClamWithVoiceIntent: AppIntent, AudioRecordingIntent, AudioPlaybackIntent,
    LiveActivityIntent {
    static let title: LocalizedStringResource = "Ask OpenClam With Voice"
    static let description = IntentDescription(
        "Uses one screenshot supplied by Shortcuts, listens for one bounded question, analyzes it, and speaks the answer while the current app stays visible."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy =
        .requiresLocalDeviceAuthentication
    static var supportedModes: IntentModes { .background }
    #if OPENCLAM_IOS27_APPINTENTS
        static var allowedExecutionTargets: IntentExecutionTargets { .main }
    #else
        static var allowedExecutionTargets: OpenClamIntentExecutionTargets { .main }
    #endif

    @Parameter(
        title: "Screenshot",
        description: "Connect the single result of Shortcuts' Take Screenshot action.",
        supportedContentTypes: [.png, .jpeg],
        requestValueDialog: "Pass one screenshot to OpenClam.",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var screenshot: IntentFile

    @Parameter(
        title: "Visible screen text",
        description: "Optional text explicitly supplied by Shortcuts' onscreen-content action."
    )
    var visibleText: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask about \(\.$screenshot)") {
            \.$visibleText
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let payload = try await Self.materializeScreenshot(screenshot)
        let request = ScreenVoicePTTRequest(
            screenshotData: payload.data,
            screenshotTypeIdentifier: payload.typeIdentifier,
            visibleText: visibleText
        )
        #if OPENCLAM_IOS27_APPINTENTS
            let intentProgress = progress
        #else
            let intentProgress = Progress(totalUnitCount: 100)
        #endif
        let progressReporter = FoundationScreenVoicePTTProgressReporter(progress: intentProgress)
        let dependencies = try await MainActor.run {
            try ScreenVoicePTTRuntime.makeDependencies(progress: progressReporter)
        }
        let coordinator = ScreenVoicePTTRuntime.coordinator
        #if OPENCLAM_IOS27_APPINTENTS
            let answer: String = try await performBackgroundTask {
                try await coordinator.run(request, dependencies: dependencies)
            } onCancel: { _ in
                Task { await coordinator.cancelCurrent() }
            }
        #else
            let answer: String = try await withTaskCancellationHandler {
                try await coordinator.run(request, dependencies: dependencies)
            } onCancel: {
                Task { await coordinator.cancelCurrent() }
            }
        #endif
        return .result(value: answer)
    }

    /// Ask App Intents to materialize an app-readable representation instead of opening
    /// Shortcuts' private temporary file URL directly. Keeping the read inside `withFile` also
    /// lets us reject oversized inputs before allocating their bytes.
    static func materializeScreenshot(
        _ file: IntentFile
    ) async throws -> (data: Data, typeIdentifier: String) {
        do {
            try Task.checkCancellation()
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
                      byteCount > 0,
                      byteCount <= ScreenContextInbox.maximumImageBytes else {
                    throw ScreenVoicePTTError.invalidScreenshot
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw ScreenVoicePTTError.invalidScreenshot
        }
    }

    /// `withFile` must request a representation that App Intents actually advertises. In
    /// particular, Shortcuts may describe a PNG screenshot only as the generic `public.image`.
    /// Byte validation below still limits accepted media to a real single-frame PNG or JPEG.
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
        throw ScreenVoicePTTError.invalidScreenshot
    }
}

#if OPENCLAM_IOS27_APPINTENTS
    @available(iOS 27.0, *)
    extension AskOpenClamWithVoiceIntent: LongRunningIntent, CancellableIntent {}
#endif
