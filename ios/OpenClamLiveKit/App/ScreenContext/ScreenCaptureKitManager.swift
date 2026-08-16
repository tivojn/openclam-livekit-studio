import Combine
import Foundation

enum ScreenCaptureKitManagerState: Equatable, Sendable {
    case unavailable
    case disclosureRequired
    case readyForSystemPicker
    case choosingContent
    case readyToStart
    case capturing
    case stopped
    case failed(String)
}

#if OPENCLAM_LIVE_SCREEN_CONTEXT && compiler(>=6.4) && canImport(ScreenCaptureKit)
import CoreImage
import CoreMedia
@preconcurrency import ScreenCaptureKit
import UIKit

/// Public-API-only full-display context for iOS 27.
///
/// The person must accept a session disclosure, select content in Apple's system picker, and tap
/// Start. The active system indicator remains visible until they explicitly stop. The adapter
/// retains one downscaled JPEG only, pairs it with one explicit Shortcut question, and never calls
/// an AI provider itself.
@available(iOS 27.0, *)
@MainActor
final class ScreenCaptureKitManager: NSObject, ObservableObject {
    @Published private(set) var state: ScreenCaptureKitManagerState = .disclosureRequired
    @Published private(set) var lastMessage: String?

    let contextSession: ScreenContextCaptureSession

    private let picker = SCContentSharingPicker.shared
    private let questionInbox: ScreenContextQuestionInbox
    private let output = ScreenCaptureFrameOutput()
    private var pickerObserver: ScreenCapturePickerObserver?
    private var pendingFilter: SCContentFilter?
    private var stream: SCStream?
    private var pollingTask: Task<Void, Never>?

    init(
        questionInbox: ScreenContextQuestionInbox,
        contextSession: ScreenContextCaptureSession
    ) {
        self.questionInbox = questionInbox
        self.contextSession = contextSession
        super.init()
        output.manager = self
        pickerObserver = ScreenCapturePickerObserver(manager: self)
    }

    convenience init(questionInbox: ScreenContextQuestionInbox) {
        self.init(
            questionInbox: questionInbox,
            contextSession: ScreenContextCaptureSession()
        )
    }

    static func appGroupBacked() throws -> ScreenCaptureKitManager {
        ScreenCaptureKitManager(questionInbox: try ScreenContextQuestionInbox.appGroup())
    }

    var activeIndicatorText: String? {
        state == .capturing
            ? "Screen Context capture is active. The system recording indicator stays visible until you tap Stop."
            : nil
    }

    func acknowledgeSessionDisclosure() {
        guard state == .disclosureRequired || state == .stopped else { return }
        contextSession.acceptDisclosure()
        state = .readyForSystemPicker
        lastMessage = "Disclosure accepted for this capture session. Nothing is being captured yet."
    }

    func presentSystemPicker() throws {
        guard contextSession.disclosureAccepted else {
            throw ScreenContextCaptureError.disclosureRequired
        }
        guard picker.isAvailable else {
            state = .unavailable
            throw ScreenContextCaptureError.requiresIOS27
        }
        guard let pickerObserver else {
            state = .failed("The system picker observer is unavailable.")
            throw ScreenContextCaptureError.captureNotReady
        }
        pendingFilter = nil
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        if !picker.isActive {
            picker.add(pickerObserver)
            picker.isActive = true
        }
        state = .choosingContent
        lastMessage = "Choose the screen in Apple's system picker. Capture will not start automatically."
        picker.present()
    }

    func startAfterUserConfirmation() async throws {
        guard contextSession.disclosureAccepted else {
            throw ScreenContextCaptureError.disclosureRequired
        }
        guard state == .readyToStart, let pendingFilter else {
            throw ScreenContextCaptureError.captureNotReady
        }
        let configuration = Self.streamConfiguration(for: pendingFilter)
        configuration.capturesAudio = false
        let newStream = SCStream(filter: pendingFilter, configuration: configuration, delegate: self)
        do {
            try newStream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: output.sampleQueue
            )
            output.isAcceptingFrames = true
            try await newStream.startCapture()
            stream = newStream
            state = .capturing
            lastMessage = "Visible screen capture is active. Only the latest bounded frame is retained."
            beginQuestionPolling()
        } catch {
            output.isAcceptingFrames = false
            stream = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func stop() async {
        pollingTask?.cancel()
        pollingTask = nil
        output.isAcceptingFrames = false
        if let stream {
            try? stream.removeStreamOutput(output, type: .screen)
            try? await stream.stopCapture()
        }
        stream = nil
        pendingFilter = nil
        if let pickerObserver, picker.isActive {
            picker.isActive = false
            picker.remove(pickerObserver)
        }
        contextSession.endSession()
        state = .stopped
        lastMessage = "Screen capture stopped. The retained frame and any unsubmitted pair were discarded."
    }

    func consumeQuestionForOneRequest(questionID: UUID) throws -> ScreenContextQuestion {
        try contextSession.consumeForOneRequest(questionID: questionID)
    }

    func consumePendingQuestionForOneRequestIfAvailable() throws -> ScreenContextQuestion? {
        try contextSession.consumePendingForOneRequestIfAvailable()
    }

    fileprivate func pickerSelected(_ filter: SCContentFilter) {
        guard state == .choosingContent else {
            lastMessage = "Stop the current session before changing captured content."
            return
        }
        pendingFilter = filter
        state = .readyToStart
        lastMessage = "Screen selected. Review the disclosure, then tap Start; capture is still off."
    }

    fileprivate func pickerCancelled() {
        guard state == .choosingContent else { return }
        pendingFilter = nil
        state = .readyForSystemPicker
        lastMessage = "Screen selection cancelled. Nothing was captured."
    }

    fileprivate func pickerFailed(_ error: Error) {
        pendingFilter = nil
        state = .failed(error.localizedDescription)
        lastMessage = "The system screen picker failed. Nothing was captured."
    }

    fileprivate func acceptJPEGFrame(
        _ jpegData: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        capturedAt: Date
    ) {
        guard state == .capturing else { return }
        let frame = ScreenContextFrame(
            id: UUID(),
            jpegData: jpegData,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            capturedAt: capturedAt
        )
        try? contextSession.replaceLatestFrame(frame)
    }

    fileprivate func streamStoppedUnexpectedly(_ error: Error) {
        pollingTask?.cancel()
        pollingTask = nil
        output.isAcceptingFrames = false
        stream = nil
        pendingFilter = nil
        contextSession.endSession()
        state = .failed(error.localizedDescription)
        lastMessage = "Screen capture stopped unexpectedly; all retained context was discarded."
    }

    private static func streamConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let nativeWidth = max(filter.contentRect.width * CGFloat(filter.pointPixelScale), 1)
        let nativeHeight = max(filter.contentRect.height * CGFloat(filter.pointPixelScale), 1)
        let scale = min(
            1,
            CGFloat(ScreenContextCapturePolicy.maximumFrameDimension) / max(nativeWidth, nativeHeight)
        )
        configuration.width = max(Int((nativeWidth * scale).rounded()), 1)
        configuration.height = max(Int((nativeHeight * scale).rounded()), 1)
        return configuration
    }

    private func beginQuestionPolling() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.state == .capturing {
                await self.pollForQuestion()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func pollForQuestion() async {
        guard contextSession.pendingQuestion == nil,
              contextSession.latestFrame != nil else { return }
        do {
            guard let queued = try await questionInbox.take() else { return }
            _ = try contextSession.pair(queued)
            lastMessage = "A dictated question was paired with the current frame for one request."
        } catch {
            lastMessage = "A queued question was discarded because it could not be paired safely."
        }
    }
}

@available(iOS 27.0, *)
private final class ScreenCapturePickerObserver: NSObject,
                                                SCContentSharingPickerObserver,
                                                @unchecked Sendable {
    private weak var manager: ScreenCaptureKitManager?

    init(manager: ScreenCaptureKitManager) {
        self.manager = manager
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor [weak manager] in
            manager?.pickerSelected(filter)
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor [weak manager] in
            manager?.pickerCancelled()
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak manager] in
            manager?.pickerFailed(error)
        }
    }
}

@available(iOS 27.0, *)
private final class ScreenCaptureFrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let sampleQueue = DispatchQueue(
        label: "com.lionheart.openclam.livekitpilot.screen-context-frames",
        qos: .userInitiated
    )
    weak var manager: ScreenCaptureKitManager?

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var acceptingFrames = false
    private var lastConversionTime: TimeInterval = 0

    var isAcceptingFrames: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return acceptingFrames
        }
        set {
            lock.lock()
            acceptingFrames = newValue
            if !newValue { lastConversionTime = 0 }
            lock.unlock()
        }
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, shouldConvertFrame(),
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let encoded = boundedJPEG(from: pixelBuffer) else { return }
        Task { @MainActor [weak manager] in
            manager?.acceptJPEGFrame(
                encoded.data,
                pixelWidth: encoded.width,
                pixelHeight: encoded.height,
                capturedAt: Date()
            )
        }
    }

    private nonisolated func shouldConvertFrame(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingFrames, now - lastConversionTime >= 0.75 else { return false }
        lastConversionTime = now
        return true
    }

    private nonisolated func boundedJPEG(
        from pixelBuffer: CVPixelBuffer
    ) -> (data: Data, width: Int, height: Int)? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width <= ScreenContextCapturePolicy.maximumFrameDimension,
              height <= ScreenContextCapturePolicy.maximumFrameDimension else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        for quality in [0.72, 0.55, 0.4, 0.28, 0.18] {
            if let data = uiImage.jpegData(compressionQuality: quality),
               data.count <= ScreenContextCapturePolicy.maximumFrameBytes {
                return (data, width, height)
            }
        }
        return nil
    }
}

@available(iOS 27.0, *)
extension ScreenCaptureKitManager: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.streamStoppedUnexpectedly(error)
        }
    }
}

#else

/// Compatibility surface for builds without the provisioned live-screen capability or made with
/// an SDK that predates iOS 27 ScreenCaptureKit. It fails at the capability boundary.
@MainActor
final class ScreenCaptureKitManager: ObservableObject {
    @Published private(set) var state: ScreenCaptureKitManagerState = .unavailable
    @Published private(set) var lastMessage: String? = ScreenContextCaptureError.requiresIOS27.errorDescription

    let contextSession: ScreenContextCaptureSession

    init(
        questionInbox: ScreenContextQuestionInbox,
        contextSession: ScreenContextCaptureSession
    ) {
        self.contextSession = contextSession
    }

    convenience init(questionInbox: ScreenContextQuestionInbox) {
        self.init(
            questionInbox: questionInbox,
            contextSession: ScreenContextCaptureSession()
        )
    }

    static func appGroupBacked() throws -> ScreenCaptureKitManager {
        ScreenCaptureKitManager(questionInbox: try ScreenContextQuestionInbox.appGroup())
    }

    var activeIndicatorText: String? { nil }

    func acknowledgeSessionDisclosure() {
        contextSession.acceptDisclosure()
    }

    func presentSystemPicker() throws {
        throw ScreenContextCaptureError.requiresIOS27
    }

    func startAfterUserConfirmation() async throws {
        throw ScreenContextCaptureError.requiresIOS27
    }

    func stop() async {
        contextSession.endSession()
        state = .stopped
        lastMessage = "No screen capture was active."
    }

    func consumeQuestionForOneRequest(questionID: UUID) throws -> ScreenContextQuestion {
        try contextSession.consumeForOneRequest(questionID: questionID)
    }

    func consumePendingQuestionForOneRequestIfAvailable() throws -> ScreenContextQuestion? {
        try contextSession.consumePendingForOneRequestIfAvailable()
    }
}

#endif
