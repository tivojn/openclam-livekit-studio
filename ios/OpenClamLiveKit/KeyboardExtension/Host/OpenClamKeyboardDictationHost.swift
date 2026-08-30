import AVFoundation
import Speech
import SwiftUI
import UIKit

private extension Notification.Name {
    static let openClamWarmEarPreferenceDidChange = Notification.Name(
        "OpenClamWarmEarPreferenceDidChange"
    )
    static let openClamWarmEarRenewRequested = Notification.Name(
        "OpenClamWarmEarRenewRequested"
    )
}

enum OpenClamWarmEarPresentationState: Equatable, Sendable {
    case off
    case arming
    case paused
    case ready
    case busy
    case failed(String)

    var title: String {
        switch self {
        case .off:
            "Quick Dictation is off"
        case .arming:
            "Preparing Quick Dictation"
        case .paused:
            "Quick Dictation is paused"
        case .ready:
            "Quick Dictation is ready"
        case .busy:
            "Quick Dictation is listening"
        case .failed:
            "Quick Dictation needs attention"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "Turn it on while OpenClam is visible to prepare keyboard voice input."
        case .arming:
            return "Keep OpenClam visible briefly while persistent microphone readiness starts."
        case .paused:
            return "Another microphone or speaker feature is active. Quick Dictation will become ready again when it finishes."
        case .ready:
            return "Ready for keyboard voice requests until you turn Quick Dictation off."
        case .busy:
            return "Recording the current keyboard voice request. You can stop it from the keyboard."
        case let .failed(message):
            return message
        }
    }

    var symbolName: String {
        switch self {
        case .off: "ear"
        case .arming, .paused: "ear"
        case .ready: "ear.fill"
        case .busy: "waveform"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

enum OpenClamKeyboardAutomaticTurnPolicy {
    static func supportsSettledPartialTranscript(_ selection: AIServiceSelection) -> Bool {
        selection.provider == .apple
            || AIProviderRegistry.usesRealtimeSpeechRecognition(selection)
    }
}

enum OpenClamAppAudioActivityOwner: Hashable, Sendable {
    case conversation
    case speechOutput
    case liveScreen
}

/// Quick Dictation starts a real, foreground-authorized microphone lease. The keyboard never
/// records and never receives provider credentials; it only signals the already-running app.
@MainActor
enum OpenClamWarmEarControl {
    static var isEnabled: Bool {
        OpenClamKeyboardWarmEarState.isEnabled
    }

    static var isForegroundReady: Bool {
        OpenClamKeyboardWarmEarState.isReady()
    }

    static var availabilityExplanation: String {
        if !isEnabled {
            return "Quick Dictation is off. Keyboard voice requests wait for you to open OpenClam."
        }
        if isForegroundReady {
            return "Quick Dictation is ready until you turn it off. Standby audio is discarded; transcription starts only after you tap Start in OpenClam Keyboard."
        }
        return "Quick Dictation is preparing. Keep OpenClam visible briefly while microphone readiness starts."
    }

    static func setEnabled(_ enabled: Bool) {
        OpenClamKeyboardWarmEarState.setEnabled(enabled)
        NotificationCenter.default.post(name: .openClamWarmEarPreferenceDidChange, object: nil)
    }

    static func renewForegroundLease(at _: Date = Date()) {
        guard isEnabled,
              UIApplication.shared.applicationState == .active else { return }
        NotificationCenter.default.post(name: .openClamWarmEarRenewRequested, object: nil)
    }

    static func clearForegroundLease() {
        // A successfully foreground-started readiness session intentionally continues after the
        // app backgrounds. Turning Quick Dictation off explicitly clears it.
        if !isEnabled {
            OpenClamKeyboardWarmEarState.clearReadiness()
        }
    }
}

private enum OpenClamWarmEarError: LocalizedError {
    case microphonePermissionDenied
    case microphonePermissionTimedOut
    case speechPermissionDenied
    case microphoneUnavailable
    case foregroundStartRequired
    case leaseUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone permission is required before Quick Dictation can be prepared."
        case .microphonePermissionTimedOut:
            "Microphone permission did not respond. Check Settings, then try Quick Dictation again."
        case .speechPermissionDenied:
            "Speech Recognition permission is required for the selected Apple speech provider."
        case .microphoneUnavailable:
            "The microphone could not be prepared for Quick Dictation."
        case .foregroundStartRequired:
            "OpenClam must be visible when a Quick Dictation lease starts."
        case .leaseUnavailable:
            "Quick Dictation lost microphone readiness. Open OpenClam to prepare it again."
        }
    }
}

@MainActor
private final class OpenClamWarmEarLease {
    private enum RecordPermissionResult: Sendable {
        case response(Bool)
        case timedOut
        case cancelled
    }

    private static let recordPermissionRequestTimeout: Duration = .seconds(15)

    private let audioEngine = AVAudioEngine()
    private var hasInstalledTap = false
    private var heartbeatTask: Task<Void, Never>?
    private(set) var isTurnActive = false

    var onReadinessLost: (() -> Void)?

    func armNewLease() async throws {
        guard UIApplication.shared.applicationState == .active else {
            throw OpenClamWarmEarError.foregroundStartRequired
        }
        let granted = try await microphonePermissionIsGranted()
        guard granted else { throw OpenClamWarmEarError.microphonePermissionDenied }
        try Task.checkCancellation()
        guard OpenClamKeyboardWarmEarState.isEnabled else { throw CancellationError() }

        try startEngine(requiresForeground: true)
    }

    private func microphonePermissionIsGranted() async throws -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            // Do not re-enter the system permission callback for an already-authorized app. On
            // Simulator that callback can be delayed indefinitely even though access is granted.
            return true
        case .denied:
            return false
        case .undetermined:
            return try await requestMicrophonePermission()
        @unknown default:
            return false
        }
    }

    private func requestMicrophonePermission() async throws -> Bool {
        let responses = AsyncStream<Bool> { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.yield(granted)
                continuation.finish()
            }
        }

        let result = await withTaskGroup(of: RecordPermissionResult.self) { group in
            group.addTask {
                for await granted in responses {
                    return .response(granted)
                }
                return Task.isCancelled ? .cancelled : .timedOut
            }
            group.addTask {
                try? await Task.sleep(for: Self.recordPermissionRequestTimeout)
                return Task.isCancelled ? .cancelled : .timedOut
            }

            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }

        try Task.checkCancellation()
        switch result {
        case let .response(granted):
            return granted
        case .timedOut:
            throw OpenClamWarmEarError.microphonePermissionTimedOut
        case .cancelled:
            throw CancellationError()
        }
    }

    func suspendForTurn() throws {
        guard audioEngine.isRunning else {
            throw OpenClamWarmEarError.leaseUnavailable
        }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stopEngine(deactivateAudioSession: false)
        isTurnActive = true
        OpenClamKeyboardWarmEarState.clearReadiness()
    }

    /// The App Group heartbeat is a cross-process hint, not the lease authority. Background task
    /// scheduling can briefly delay it even while the foreground-started audio engine is healthy.
    /// Refresh it from the owning process before accepting a keyboard request.
    @discardableResult
    func refreshReadinessIfArmed(at date: Date = Date()) -> Bool {
        guard audioEngine.isRunning else { return false }
        OpenClamKeyboardWarmEarState.markReady(heartbeat: date)
        return true
    }

    @discardableResult
    func finishTurnAndRearm() async -> Bool {
        isTurnActive = false
        guard OpenClamKeyboardWarmEarState.isEnabled else {
            disarm()
            return false
        }
        do {
            try startEngine(requiresForeground: false)
            return true
        } catch {
            disarm()
            return false
        }
    }

    func disarm(deactivateAudioSession: Bool = true) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stopEngine(deactivateAudioSession: false)
        isTurnActive = false
        OpenClamKeyboardWarmEarState.clearReadiness()
        if deactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private func startEngine(requiresForeground: Bool) throws {
        if requiresForeground, UIApplication.shared.applicationState != .active {
            throw OpenClamWarmEarError.foregroundStartRequired
        }

        stopEngine(deactivateAudioSession: false)
        let session = AVAudioSession.sharedInstance()
        // Keep playback available while the foreground-started readiness session is armed.
        // ConversationView still yields this lease before any competing microphone flow begins.
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw OpenClamWarmEarError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { _, _ in
            // A real microphone tap keeps readiness alive. Audio is deliberately
            // discarded until a keyboard request arrives; no provider sees warm-up audio.
        }
        hasInstalledTap = true
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            hasInstalledTap = false
            throw error
        }

        isTurnActive = false
        OpenClamKeyboardWarmEarState.markReady()
        startHeartbeat()
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled,
                  let self,
                  self.audioEngine.isRunning,
                  OpenClamKeyboardWarmEarState.isEnabled {
                OpenClamKeyboardWarmEarState.updateHeartbeat()
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self, !self.isTurnActive else { return }
            self.stopEngine(deactivateAudioSession: true)
            OpenClamKeyboardWarmEarState.clearReadiness()
            self.onReadinessLost?()
        }
    }

    private func stopEngine(deactivateAudioSession: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        audioEngine.reset()
        if deactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }
}

private final class OpenClamKeyboardDarwinObserver {
    private let name: CFNotificationName
    private let handler: () -> Void

    init(name: String, handler: @escaping () -> Void) {
        self.name = CFNotificationName(name as CFString)
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            openClamKeyboardDarwinNotificationCallback,
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            name,
            nil
        )
    }

    fileprivate func receive() {
        handler()
    }
}

private let openClamKeyboardDarwinNotificationCallback: CFNotificationCallback = {
    _, observer, _, _, _ in
    guard let observer else { return }
    Unmanaged<OpenClamKeyboardDarwinObserver>
        .fromOpaque(observer)
        .takeUnretainedValue()
        .receive()
}

@MainActor
final class OpenClamKeyboardDictationHostController: ObservableObject {
    @Published var activeRequest: OpenClamKeyboardRequest?
    @Published private(set) var lastError: String?
    @Published private(set) var warmEarPresentationState: OpenClamWarmEarPresentationState

    private var store: OpenClamKeyboardHandoffStore?
    private weak var aiConfiguration: AIConfigurationModel?
    // Keep the foreground-started AVAudioSession active while swapping between the warm tap and
    // the selected ASR controller. The lease itself performs the one final deactivation.
    private let automaticSpeech = SpeechInputController(
        audioSessionOwnership: SpeechInputAudioSessionOwnership {}
    )
    private let warmEarLease = OpenClamWarmEarLease()
    private var automaticRequest: OpenClamKeyboardRequest?
    private var automaticTask: Task<Void, Never>?
    private var armTask: Task<Void, Never>?
    private var externallyCancelledRequestIDs: Set<UUID> = []
    private var competingAppAudioOwners: Set<OpenClamAppAudioActivityOwner> = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var beginRequestObserver: OpenClamKeyboardDarwinObserver?
    private var cancelRequestObserver: OpenClamKeyboardDarwinObserver?

    init(store: OpenClamKeyboardHandoffStore? = try? .live()) {
        self.store = store
        if OpenClamKeyboardWarmEarState.isEnabled {
            warmEarPresentationState = .arming
        } else {
            warmEarPresentationState = .off
        }
        warmEarLease.onReadinessLost = { [weak self] in
            self?.handleReadinessLost()
        }
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .openClamWarmEarPreferenceDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleWarmEarPreferenceChange()
                }
            }
        )
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .openClamWarmEarRenewRequested,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.armWarmEarIfPossible()
                }
            }
        )
        beginRequestObserver = OpenClamKeyboardDarwinObserver(
            name: OpenClamKeyboardWarmEarSignal.beginRequestName
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleWarmEarRequestSignal()
            }
        }
        cancelRequestObserver = OpenClamKeyboardDarwinObserver(
            name: OpenClamKeyboardWarmEarSignal.cancelRequestName
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleWarmEarCancelSignal()
            }
        }
    }

    deinit {
        automaticTask?.cancel()
        armTask?.cancel()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func configure(aiConfiguration: AIConfigurationModel) {
        self.aiConfiguration = aiConfiguration
        armWarmEarIfPossible()
    }

    func applicationDidBecomeActive() {
        armWarmEarIfPossible()
    }

    var isHandlingVoiceRequest: Bool {
        automaticTask != nil || automaticRequest != nil || activeRequest != nil
            || warmEarLease.isTurnActive
    }

    var hasCompetingAppAudioActivity: Bool {
        !competingAppAudioOwners.isEmpty
    }

    /// Claims the app's one microphone/speaker lane for composer PTT, Live Talk, or TTS.
    /// A keyboard turn already in progress remains authoritative and must finish or be cancelled.
    func prepareForCompetingAppAudio(
        owner: OpenClamAppAudioActivityOwner = .conversation
    ) -> String? {
        guard !isHandlingVoiceRequest else {
            return "Finish or cancel the current Quick Dictation turn before starting another voice feature."
        }
        setCompetingAppAudioActive(true, owner: owner)
        return nil
    }

    func setCompetingAppAudioActive(
        _ active: Bool,
        owner: OpenClamAppAudioActivityOwner = .conversation
    ) {
        if active, isHandlingVoiceRequest { return }
        let wasActive = !competingAppAudioOwners.isEmpty
        if active {
            competingAppAudioOwners.insert(owner)
        } else {
            competingAppAudioOwners.remove(owner)
        }
        let isActive = !competingAppAudioOwners.isEmpty
        guard wasActive != isActive else { return }
        if active {
            armTask?.cancel()
            warmEarLease.disarm()
            warmEarPresentationState = OpenClamKeyboardWarmEarState.isEnabled ? .paused : .off
        } else {
            armWarmEarIfPossible()
        }
    }

    /// Returns true for every keyboard-dictation URL, including a malformed one, so the URL is
    /// never misreported as an assistant command link.
    func handle(_ url: URL, at date: Date = Date()) -> Bool {
        guard OpenClamKeyboardHandoffURL.isKeyboardHandoff(url) else { return false }
        guard let id = OpenClamKeyboardHandoffURL.requestID(from: url) else {
            lastError = OpenClamKeyboardStoreError.invalidRequest.localizedDescription
            return true
        }
        do {
            let availableStore = try requireStore()
            let request = try availableStore.request(id: id, at: date)
            guard try availableStore.result(for: id) == nil else { return true }
            suspendWarmLeaseForVisibleRequest()
            activeRequest = request
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        return true
    }

    func restorePendingRequest(at date: Date = Date()) {
        handleWarmEarCancelSignal(at: date)
        guard activeRequest == nil else { return }
        do {
            let availableStore = try requireStore()
            guard let request = try availableStore.activeRequest(at: date),
                  try availableStore.result(for: request.id) == nil else { return }
            lastError = nil
            if warmEarLease.refreshReadinessIfArmed(at: date), aiConfiguration != nil {
                beginAutomaticTurn(for: request)
            } else {
                suspendWarmLeaseForVisibleRequest()
                activeRequest = request
            }
        } catch OpenClamKeyboardStoreError.staleRequest {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func complete(_ request: OpenClamKeyboardRequest, transcript: String) throws {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw OpenClamKeyboardStoreError.invalidRequest
        }
        let availableStore = try requireStore()
        guard try availableStore.write(
            .completed(requestID: request.id, transcript: cleaned)
        ) else {
            throw OpenClamKeyboardStoreError.mismatchedResult
        }
    }

    func cancel(_ request: OpenClamKeyboardRequest) {
        writeCancellationIfPending(request)
        dismiss(request)
    }

    func fail(_ request: OpenClamKeyboardRequest, message: String) {
        do {
            _ = try requireStore().write(.failed(requestID: request.id, message: message))
        } catch OpenClamKeyboardStoreError.invalidRequest,
                OpenClamKeyboardStoreError.staleRequest {
            // A keyboard-side cancellation may remove its private request before the host sheet
            // finishes disappearing. That expected cleanup must not become a second failure.
        } catch {
            lastError = error.localizedDescription
        }
    }

    func dismiss(_ request: OpenClamKeyboardRequest) {
        guard activeRequest?.id == request.id else { return }
        activeRequest = nil
        armWarmEarIfPossible()
    }

    private func suspendWarmLeaseForVisibleRequest() {
        armTask?.cancel()
        warmEarLease.disarm()
        warmEarPresentationState = .busy
    }

    private func handleWarmEarPreferenceChange() {
        if OpenClamKeyboardWarmEarState.isEnabled {
            warmEarPresentationState = competingAppAudioOwners.isEmpty ? .arming : .paused
            armWarmEarIfPossible()
        } else {
            armTask?.cancel()
            if let automaticRequest {
                automaticSpeech.cancel()
                fail(
                    automaticRequest,
                    message: "Quick Dictation was turned off before voice input finished."
                )
                self.automaticRequest = nil
            }
            automaticTask?.cancel()
            warmEarLease.disarm()
            warmEarPresentationState = .off
        }
    }

    private func armWarmEarIfPossible() {
        guard OpenClamKeyboardWarmEarState.isEnabled else {
            warmEarPresentationState = .off
            return
        }
        guard competingAppAudioOwners.isEmpty else {
            warmEarLease.disarm()
            warmEarPresentationState = .paused
            return
        }
        if automaticTask != nil || warmEarLease.isTurnActive {
            warmEarPresentationState = .busy
            return
        }
        if warmEarLease.refreshReadinessIfArmed() {
            warmEarPresentationState = .ready
            drainReadyPendingRequest()
            return
        }
        warmEarPresentationState = .arming
        guard UIApplication.shared.applicationState == .active,
              let aiConfiguration,
              armTask == nil else { return }

        armTask = Task { @MainActor [weak self, weak aiConfiguration] in
            guard let self else { return }
            var retryAfterCancellation = false
            defer {
                self.armTask = nil
                if retryAfterCancellation {
                    self.armWarmEarIfPossible()
                }
            }
            guard let aiConfiguration else {
                self.refreshWarmEarPresentation()
                return
            }
            do {
                try await self.preflightSpeechPermission(using: aiConfiguration)
                try Task.checkCancellation()
                try await self.warmEarLease.armNewLease()
                self.lastError = nil
                self.refreshWarmEarPresentation()
                self.drainReadyPendingRequest()
            } catch is CancellationError {
                retryAfterCancellation = OpenClamKeyboardWarmEarState.isEnabled
                    && self.competingAppAudioOwners.isEmpty
                return
            } catch {
                self.lastError = error.localizedDescription
                self.warmEarLease.disarm()
                self.warmEarPresentationState = .failed(
            "Quick Dictation couldn't become ready. Check microphone and speech settings, then try again."
                )
            }
        }
    }

    private func preflightSpeechPermission(using aiConfiguration: AIConfigurationModel) async throws {
        guard aiConfiguration.effectiveSettings.speechToText.provider == .apple else { return }
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else { throw OpenClamWarmEarError.speechPermissionDenied }
    }

    private func handleWarmEarRequestSignal() {
        handleWarmEarCancelSignal()
        guard automaticTask == nil else {
            // Darwin notifications are intentionally only wake-up hints. The request remains in
            // the App Group and is drained when the current turn releases the microphone.
            return
        }
        drainReadyPendingRequest()
    }

    private func drainReadyPendingRequest(at date: Date = Date()) {
        guard automaticTask == nil,
              automaticRequest == nil,
              aiConfiguration != nil else { return }
        guard warmEarLease.refreshReadinessIfArmed(at: date) else { return }
        do {
            let availableStore = try requireStore()
            guard let request = try availableStore.activeRequest(at: date),
                  try availableStore.result(for: request.id) == nil else { return }
            beginAutomaticTurn(for: request)
        } catch OpenClamKeyboardStoreError.staleRequest {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleWarmEarCancelSignal(at date: Date = Date()) {
        do {
            let availableStore = try requireStore()
            let cancellationIDs = try availableStore.pendingCancellationRequestIDs(at: date)
            var releasedVisibleRequest = false
            for requestID in cancellationIDs {
                if automaticRequest?.id == requestID {
                    externallyCancelledRequestIDs.insert(requestID)
                    automaticSpeech.cancel()
                    automaticTask?.cancel()
                    warmEarPresentationState = OpenClamKeyboardWarmEarState.isEnabled
                        ? .arming
                        : .off
                }
                if activeRequest?.id == requestID {
                    activeRequest = nil
                    releasedVisibleRequest = true
                }
                try availableStore.acknowledgeCancellation(requestID: requestID)
            }
            if releasedVisibleRequest {
                armWarmEarIfPossible()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func beginAutomaticTurn(for request: OpenClamKeyboardRequest) {
        guard automaticTask == nil,
              automaticRequest == nil,
              let aiConfiguration else { return }
        automaticRequest = request
        activeRequest = nil
        warmEarPresentationState = .busy
        automaticTask = Task { @MainActor [weak self, weak aiConfiguration] in
            guard let self else { return }
            guard let aiConfiguration else {
                self.automaticRequest = nil
                self.automaticTask = nil
                self.armWarmEarIfPossible()
                return
            }
            await self.runAutomaticTurn(request, using: aiConfiguration)
            if self.automaticRequest?.id == request.id {
                self.automaticRequest = nil
            }
            self.externallyCancelledRequestIDs.remove(request.id)
            self.automaticTask = nil
            self.armWarmEarIfPossible()
        }
    }

    private func runAutomaticTurn(
        _ request: OpenClamKeyboardRequest,
        using aiConfiguration: AIConfigurationModel
    ) async {
        OpenClamKeyboardWarmEarState.clearListening(requestID: request.id)
        defer { OpenClamKeyboardWarmEarState.clearListening(requestID: request.id) }
        guard !Task.isCancelled,
              !externallyCancelledRequestIDs.contains(request.id) else { return }
        do {
            try warmEarLease.suspendForTurn()
            warmEarPresentationState = .busy
        } catch {
            failIfPending(request, message: error.localizedDescription)
            warmEarPresentationState = .failed(
                "Quick Dictation lost microphone readiness. Open OpenClam to prepare it again."
            )
            return
        }

        let speechSelection = aiConfiguration.effectiveSettings.speechToText
        await automaticSpeech.start(using: aiConfiguration)
        guard !Task.isCancelled else {
            automaticSpeech.cancel()
            if !externallyCancelledRequestIDs.contains(request.id) {
                failIfPending(request, message: "Keyboard voice input was cancelled.")
            }
            await finishAutomaticTurnAndRefresh()
            return
        }
        guard automaticSpeech.isListening else {
            let message = automaticSpeech.errorMessage
                ?? "OpenClam could not start the selected speech provider in the background. Open OpenClam and try again."
            automaticSpeech.cancel()
            failIfPending(request, message: message)
            await finishAutomaticTurnAndRefresh()
            return
        }
        OpenClamKeyboardWarmEarState.markListening(requestID: request.id)

        await waitForAutomaticTurn(selection: speechSelection)
        guard !Task.isCancelled else {
            automaticSpeech.cancel()
            if !externallyCancelledRequestIDs.contains(request.id) {
                failIfPending(request, message: "Keyboard voice input was cancelled.")
            }
            await finishAutomaticTurnAndRefresh()
            return
        }

        let transcript = await automaticSpeech.stop(using: aiConfiguration)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Task.isCancelled,
              !externallyCancelledRequestIDs.contains(request.id) else {
            automaticSpeech.cancel()
            await finishAutomaticTurnAndRefresh()
            return
        }
        if transcript.isEmpty {
            failIfPending(
                request,
                message: automaticSpeech.errorMessage
                    ?? "No speech was recognized during this Quick Dictation turn."
            )
        } else {
            do {
                try complete(request, transcript: transcript)
                lastError = nil
            } catch OpenClamKeyboardStoreError.mismatchedResult {
                // A keyboard-side Cancel can win after recognition finishes but before the final
                // transcript is committed. Its terminal result is authoritative and intentional.
            } catch {
                lastError = error.localizedDescription
                failIfPending(request, message: error.localizedDescription)
            }
        }
        await finishAutomaticTurnAndRefresh()
    }

    private func waitForAutomaticTurn(
        selection: AIServiceSelection
    ) async {
        let maximumTurn: TimeInterval = 12

        let supportsPartialTranscript = OpenClamKeyboardAutomaticTurnPolicy
            .supportsSettledPartialTranscript(selection)
        let startedAt = Date()
        var previousTranscript = automaticSpeech.transcript
        var lastTranscriptChange = startedAt

        while !Task.isCancelled, Date().timeIntervalSince(startedAt) < maximumTurn {
            try? await Task.sleep(for: .milliseconds(200))
            let currentTranscript = automaticSpeech.transcript
            if currentTranscript != previousTranscript {
                previousTranscript = currentTranscript
                lastTranscriptChange = Date()
            }
            if supportsPartialTranscript,
               !currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               Date().timeIntervalSince(startedAt) >= 1.5,
               Date().timeIntervalSince(lastTranscriptChange) >= 1.25 {
                return
            }
            if automaticSpeech.errorMessage != nil || !automaticSpeech.isListening {
                return
            }
        }
    }

    private func handleReadinessLost() {
        guard OpenClamKeyboardWarmEarState.isEnabled else {
            warmEarPresentationState = .off
            return
        }
        warmEarPresentationState = .failed(
            "Quick Dictation lost microphone readiness. Open OpenClam to prepare it again."
        )
    }

    private func finishAutomaticTurnAndRefresh() async {
        _ = await warmEarLease.finishTurnAndRearm()
        refreshWarmEarPresentation()
    }

    private func refreshWarmEarPresentation() {
        guard OpenClamKeyboardWarmEarState.isEnabled else {
            warmEarPresentationState = .off
            return
        }
        if !competingAppAudioOwners.isEmpty {
            warmEarPresentationState = .paused
            return
        }
        if automaticTask != nil || warmEarLease.isTurnActive {
            warmEarPresentationState = .busy
        } else if warmEarLease.refreshReadinessIfArmed() {
            warmEarPresentationState = .ready
        } else if armTask != nil {
            warmEarPresentationState = .arming
        }
    }

    private func writeCancellationIfPending(_ request: OpenClamKeyboardRequest) {
        do {
            _ = try requireStore().write(.cancelled(requestID: request.id))
        } catch OpenClamKeyboardStoreError.invalidRequest,
                OpenClamKeyboardStoreError.staleRequest {
            // The keyboard may remove its request before the process-wide cancellation signal is
            // delivered. Resource cancellation is still required, but there is nothing left to
            // persist or expose as an error.
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func failIfPending(_ request: OpenClamKeyboardRequest, message: String) {
        do {
            _ = try requireStore().write(
                .failed(requestID: request.id, message: message)
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func requireStore() throws -> OpenClamKeyboardHandoffStore {
        if let store { return store }
        let live = try OpenClamKeyboardHandoffStore.live()
        store = live
        return live
    }
}

@MainActor
struct OpenClamKeyboardDictationHostView: View {
    private static let maximumVisibleTurnDuration: TimeInterval = 30

    private enum Phase: Equatable {
        case preparing
        case listening
        case transcribing
        case completed
        case failed
    }

    let request: OpenClamKeyboardRequest
    @ObservedObject var host: OpenClamKeyboardDictationHostController
    @ObservedObject var aiConfiguration: AIConfigurationModel
    @StateObject private var speech = SpeechInputController()
    @Environment(\.scenePhase) private var scenePhase

    @State private var phase: Phase = .preparing
    @State private var message = "Preparing microphone permission…"
    @State private var deliveredResult = false
    @State private var deadlineTask: Task<Void, Never>?
    @State private var listeningDeadline: Date?
    @ScaledMetric(relativeTo: .largeTitle) private var microphoneArtworkSize: CGFloat = 132
    @ScaledMetric(relativeTo: .largeTitle) private var microphoneIconSize: CGFloat = 50

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(microphoneColor.opacity(0.14))
                            .frame(
                                width: min(microphoneArtworkSize, 180),
                                height: min(microphoneArtworkSize, 180)
                            )
                        Image(systemName: microphoneSymbol)
                            .font(
                                .system(
                                    size: min(microphoneIconSize, 70),
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(microphoneColor)
                            .symbolEffect(.pulse, isActive: phase == .listening)
                    }
                    .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text(title)
                            .font(.title2.bold())
                        Text(message)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text("Using \(providerName)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    timeoutProgress

                    if !speech.transcript.isEmpty {
                        Text(speech.transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(14)
                            .background(
                                .quaternary,
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                    }

                    actionArea

                    Text("The keyboard extension cannot access the microphone. OpenClam records only on this visible screen, stops before you return, and shares only the final transcript through the local App Group.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 620)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Keyboard Voice Input")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase != .completed {
                        Button("Cancel", action: cancel)
                    }
                }
            }
        }
        .interactiveDismissDisabled(!deliveredResult)
        .task(id: request.id) {
            await startIfNeeded()
        }
        .onChange(of: speech.errorMessage) { _, error in
            guard phase == .listening, let error, !error.isEmpty else { return }
            fail(error)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active,
                  phase == .listening || phase == .transcribing else { return }
            fail("Voice input stopped because OpenClam left the foreground. Return to the keyboard and try again.")
        }
        .onDisappear {
            deadlineTask?.cancel()
            deadlineTask = nil
            listeningDeadline = nil
            if !deliveredResult {
                speech.cancel()
                host.cancel(request)
                deliveredResult = true
            }
        }
    }

    @ViewBuilder
    private var timeoutProgress: some View {
        if phase == .listening, let listeningDeadline {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let remaining = max(0, listeningDeadline.timeIntervalSince(context.date))
                VStack(spacing: 6) {
                    ProgressView(
                        value: Self.maximumVisibleTurnDuration - remaining,
                        total: Self.maximumVisibleTurnDuration
                    )
                    Text("Automatic stop in \(Int(remaining.rounded(.up))) seconds")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Voice input time remaining")
                .accessibilityValue("\(Int(remaining.rounded(.up))) seconds")
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch phase {
        case .preparing:
            ProgressView()
                .controlSize(.large)
        case .listening:
            Button(action: { Task { await stopAndDeliver() } }) {
                Label("Stop and insert", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        case .transcribing:
            ProgressView("Finishing transcript…")
        case .completed:
            VStack(spacing: 10) {
                Label("Transcript ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                Text("Return to the previous app. OpenClam Keyboard will insert it once at the cursor.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") { host.dismiss(request) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .failed:
            VStack(spacing: 10) {
                Text("Return to the keyboard and tap Try Again to start a fresh request.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Close") { host.dismiss(request) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var providerName: String {
        let selection = aiConfiguration.effectiveSettings.speechToText
        let provider = AIProviderRegistry.descriptor(for: selection.provider).displayName
        let model = AIProviderRegistry.modelDisplayName(
            for: selection.model,
            provider: selection.provider,
            capability: .speechToText
        )
        return "\(provider) · \(model)"
    }

    private var title: String {
        switch phase {
        case .preparing: "Getting ready"
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .completed: "Ready to return"
        case .failed: "Voice input unavailable"
        }
    }

    private var microphoneSymbol: String {
        switch phase {
        case .preparing, .transcribing: "waveform"
        case .listening: "mic.fill"
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        }
    }

    private var microphoneColor: Color {
        switch phase {
        case .listening: .red
        case .completed: .green
        case .failed: .orange
        case .preparing, .transcribing: .primary
        }
    }

    private func startIfNeeded() async {
        guard phase == .preparing else { return }
        deliveredResult = false
        await speech.start(using: aiConfiguration)
        guard phase == .preparing else { return }
        if speech.isListening {
            phase = .listening
            message = "Speak now. Tap Stop when you are finished; OpenClam will release the microphone before you return."
            deadlineTask?.cancel()
            listeningDeadline = Date().addingTimeInterval(
                Self.maximumVisibleTurnDuration
            )
            deadlineTask = Task { @MainActor in
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.maximumVisibleTurnDuration * 1_000_000_000)
                )
                guard !Task.isCancelled, phase == .listening else { return }
                await stopAndDeliver()
            }
        } else {
            fail(speech.errorMessage ?? "Microphone or speech recognition is unavailable.")
        }
    }

    private func stopAndDeliver() async {
        guard phase == .listening else { return }
        deadlineTask?.cancel()
        deadlineTask = nil
        listeningDeadline = nil
        phase = .transcribing
        message = "OpenClam is finalizing the selected speech provider."
        let transcript = await speech.stop(using: aiConfiguration)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            fail(speech.errorMessage ?? "No speech was recognized. Try again and speak after Listening appears.")
            return
        }
        do {
            try host.complete(request, transcript: transcript)
            deliveredResult = true
            phase = .completed
            message = "The microphone is off and the final transcript is waiting for the keyboard."
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func cancel() {
        deadlineTask?.cancel()
        deadlineTask = nil
        listeningDeadline = nil
        speech.cancel()
        if !deliveredResult {
            host.cancel(request)
            deliveredResult = true
        } else {
            host.dismiss(request)
        }
    }

    private func fail(_ error: String) {
        deadlineTask?.cancel()
        deadlineTask = nil
        listeningDeadline = nil
        speech.cancel()
        phase = .failed
        message = error
        if !deliveredResult {
            host.fail(request, message: error)
            deliveredResult = true
        }
    }
}
