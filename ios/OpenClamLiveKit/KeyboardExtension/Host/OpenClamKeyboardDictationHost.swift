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

/// The Ear button starts a real, foreground-authorized microphone lease. The keyboard never
/// records and never receives provider credentials; it only signals the already-running app.
@MainActor
enum OpenClamWarmEarControl {
    static let foregroundLeaseDuration: TimeInterval = 90

    static var isEnabled: Bool {
        OpenClamKeyboardWarmEarState.isEnabled
    }

    static var isForegroundReady: Bool {
        OpenClamKeyboardWarmEarState.isReady()
    }

    static var availabilityExplanation: String {
        if !isEnabled {
            return "Ear is off. Keyboard voice requests wait for you to open OpenClam."
        }
        if isForegroundReady {
            return "Ear is ready for up to 90 seconds. The microphone is on, but transcription starts only after you tap the OpenClam Keyboard microphone."
        }
        return "Ear is enabled but not armed. Keep OpenClam in the foreground briefly to start a new 90-second lease."
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
        // A foreground-started recording is intentionally allowed to finish its original bounded
        // lease after the app backgrounds. The host's timer clears readiness at the deadline.
        if !isEnabled {
            OpenClamKeyboardWarmEarState.clearReadiness()
        }
    }
}

private enum OpenClamWarmEarError: LocalizedError {
    case microphonePermissionDenied
    case speechPermissionDenied
    case microphoneUnavailable
    case foregroundStartRequired
    case leaseExpired

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone permission is required before Keyboard Ear can be armed."
        case .speechPermissionDenied:
            "Speech Recognition permission is required for the selected Apple speech provider."
        case .microphoneUnavailable:
            "The microphone could not be armed for Keyboard Ear."
        case .foregroundStartRequired:
            "OpenClam must be visible when a Keyboard Ear lease starts."
        case .leaseExpired:
            "The 90-second Keyboard Ear lease expired. Open OpenClam and tap the Ear again."
        }
    }
}

@MainActor
private final class OpenClamWarmEarLease {
    private let audioEngine = AVAudioEngine()
    private var hasInstalledTap = false
    private var heartbeatTask: Task<Void, Never>?
    private(set) var deadline: Date?
    private(set) var isTurnActive = false

    var onExpired: (() -> Void)?

    func armNewLease() async throws {
        guard UIApplication.shared.applicationState == .active else {
            throw OpenClamWarmEarError.foregroundStartRequired
        }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard granted else { throw OpenClamWarmEarError.microphonePermissionDenied }

        let deadline = Date().addingTimeInterval(OpenClamWarmEarControl.foregroundLeaseDuration)
        try startEngine(until: deadline, requiresForeground: true)
    }

    func suspendForTurn() throws -> Date {
        guard let deadline, deadline > Date(), OpenClamKeyboardWarmEarState.isReady() else {
            throw OpenClamWarmEarError.leaseExpired
        }
        stopEngine(deactivateAudioSession: false)
        isTurnActive = true
        OpenClamKeyboardWarmEarState.markReady(until: deadline)
        return deadline
    }

    func finishTurnAndRearm(until deadline: Date) async {
        isTurnActive = false
        guard OpenClamKeyboardWarmEarState.isEnabled, deadline > Date() else {
            disarm()
            return
        }
        do {
            try startEngine(until: deadline, requiresForeground: false)
        } catch {
            disarm()
        }
    }

    func disarm(deactivateAudioSession: Bool = true) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stopEngine(deactivateAudioSession: false)
        isTurnActive = false
        deadline = nil
        OpenClamKeyboardWarmEarState.clearReadiness()
        if deactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private func startEngine(until deadline: Date, requiresForeground: Bool) throws {
        guard deadline > Date() else { throw OpenClamWarmEarError.leaseExpired }
        if requiresForeground, UIApplication.shared.applicationState != .active {
            throw OpenClamWarmEarError.foregroundStartRequired
        }

        stopEngine(deactivateAudioSession: false)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw OpenClamWarmEarError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { _, _ in
            // A real microphone tap keeps the bounded audio lease alive. Audio is deliberately
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

        self.deadline = deadline
        isTurnActive = false
        OpenClamKeyboardWarmEarState.markReady(until: deadline)
        startHeartbeat(until: deadline)
    }

    private func startHeartbeat(until deadline: Date) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, Date() < deadline {
                OpenClamKeyboardWarmEarState.updateHeartbeat()
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self, self.deadline == deadline else { return }
            self.stopEngine(deactivateAudioSession: !self.isTurnActive)
            self.deadline = nil
            OpenClamKeyboardWarmEarState.clearReadiness()
            self.onExpired?()
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
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            openClamKeyboardDarwinNotificationCallback,
            OpenClamKeyboardWarmEarSignal.beginRequestName as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(OpenClamKeyboardWarmEarSignal.beginRequestName as CFString),
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
    private var notificationObservers: [NSObjectProtocol] = []
    private var darwinObserver: OpenClamKeyboardDarwinObserver?

    init(store: OpenClamKeyboardHandoffStore? = try? .live()) {
        self.store = store
        warmEarLease.onExpired = { [weak self] in
            self?.handleLeaseExpired()
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
        darwinObserver = OpenClamKeyboardDarwinObserver { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleWarmEarRequestSignal()
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
            activeRequest = request
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        return true
    }

    func restorePendingRequest(at date: Date = Date()) {
        guard activeRequest == nil else { return }
        do {
            let availableStore = try requireStore()
            guard let request = try availableStore.activeRequest(at: date),
                  try availableStore.result(for: request.id) == nil else { return }
            lastError = nil
            if OpenClamKeyboardWarmEarState.isReady(at: date), aiConfiguration != nil {
                beginAutomaticTurn(for: request)
            } else {
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
        try requireStore().write(.completed(requestID: request.id, transcript: cleaned))
    }

    func cancel(_ request: OpenClamKeyboardRequest) {
        do {
            try requireStore().write(.cancelled(requestID: request.id))
        } catch {
            lastError = error.localizedDescription
        }
        dismiss(request)
    }

    func fail(_ request: OpenClamKeyboardRequest, message: String) {
        do {
            try requireStore().write(.failed(requestID: request.id, message: message))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func dismiss(_ request: OpenClamKeyboardRequest) {
        guard activeRequest?.id == request.id else { return }
        activeRequest = nil
    }

    private func handleWarmEarPreferenceChange() {
        if OpenClamKeyboardWarmEarState.isEnabled {
            armWarmEarIfPossible()
        } else {
            armTask?.cancel()
            armTask = nil
            if let automaticRequest {
                automaticSpeech.cancel()
                fail(
                    automaticRequest,
                    message: "Keyboard Ear was turned off before voice input finished."
                )
                self.automaticRequest = nil
            }
            automaticTask?.cancel()
            automaticTask = nil
            warmEarLease.disarm()
        }
    }

    private func armWarmEarIfPossible() {
        guard OpenClamKeyboardWarmEarState.isEnabled,
              UIApplication.shared.applicationState == .active,
              let aiConfiguration,
              automaticTask == nil,
              !OpenClamKeyboardWarmEarState.isReady() else { return }

        armTask?.cancel()
        armTask = Task { @MainActor [weak self, weak aiConfiguration] in
            guard let self, let aiConfiguration else { return }
            do {
                try await self.preflightSpeechPermission(using: aiConfiguration)
                try Task.checkCancellation()
                try await self.warmEarLease.armNewLease()
                self.lastError = nil
            } catch is CancellationError {
                return
            } catch {
                self.lastError = error.localizedDescription
                self.warmEarLease.disarm()
            }
            self.armTask = nil
        }
    }

    private func preflightSpeechPermission(using aiConfiguration: AIConfigurationModel) async throws {
        guard aiConfiguration.settings.speechToText.provider == .apple else { return }
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else { throw OpenClamWarmEarError.speechPermissionDenied }
    }

    private func handleWarmEarRequestSignal() {
        guard automaticTask == nil,
              OpenClamKeyboardWarmEarState.isReady(),
              aiConfiguration != nil else { return }
        do {
            let availableStore = try requireStore()
            guard let request = try availableStore.activeRequest(),
                  try availableStore.result(for: request.id) == nil else { return }
            beginAutomaticTurn(for: request)
        } catch OpenClamKeyboardStoreError.staleRequest {
            lastError = nil
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
        automaticTask = Task { @MainActor [weak self, weak aiConfiguration] in
            guard let self, let aiConfiguration else { return }
            await self.runAutomaticTurn(request, using: aiConfiguration)
            if self.automaticRequest?.id == request.id {
                self.automaticRequest = nil
            }
            self.automaticTask = nil
        }
    }

    private func runAutomaticTurn(
        _ request: OpenClamKeyboardRequest,
        using aiConfiguration: AIConfigurationModel
    ) async {
        let leaseDeadline: Date
        do {
            leaseDeadline = try warmEarLease.suspendForTurn()
        } catch {
            failIfPending(request, message: error.localizedDescription)
            return
        }

        await automaticSpeech.start(using: aiConfiguration)
        guard !Task.isCancelled else {
            automaticSpeech.cancel()
            failIfPending(request, message: "Keyboard voice input was cancelled.")
            await warmEarLease.finishTurnAndRearm(until: leaseDeadline)
            return
        }
        guard automaticSpeech.isListening else {
            let message = automaticSpeech.errorMessage
                ?? "OpenClam could not start the selected speech provider in the background. Open OpenClam and try again."
            automaticSpeech.cancel()
            failIfPending(request, message: message)
            await warmEarLease.finishTurnAndRearm(until: leaseDeadline)
            return
        }

        await waitForAutomaticTurn(using: aiConfiguration, leaseDeadline: leaseDeadline)
        guard !Task.isCancelled else {
            automaticSpeech.cancel()
            failIfPending(request, message: "Keyboard voice input was cancelled.")
            await warmEarLease.finishTurnAndRearm(until: leaseDeadline)
            return
        }

        let transcript = await automaticSpeech.stop(using: aiConfiguration)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty {
            failIfPending(
                request,
                message: automaticSpeech.errorMessage
                    ?? "No speech was recognized during the bounded Keyboard Ear turn."
            )
        } else {
            do {
                try complete(request, transcript: transcript)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                failIfPending(request, message: error.localizedDescription)
            }
        }
        await warmEarLease.finishTurnAndRearm(until: leaseDeadline)
    }

    private func waitForAutomaticTurn(
        using aiConfiguration: AIConfigurationModel,
        leaseDeadline: Date
    ) async {
        let now = Date()
        let remainingLease = max(0, leaseDeadline.timeIntervalSince(now) - 0.75)
        let maximumTurn = min(12, remainingLease)
        guard maximumTurn > 0 else { return }

        let selection = aiConfiguration.settings.speechToText
        let supportsPartialTranscript = selection.provider == .apple
            || (selection.provider == .soniox
                && selection.model == SonioxRealtimeSpeechToTextService.model)
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

    private func handleLeaseExpired() {
        guard let automaticRequest else { return }
        automaticSpeech.cancel()
        automaticTask?.cancel()
        fail(automaticRequest, message: OpenClamWarmEarError.leaseExpired.localizedDescription)
        self.automaticRequest = nil
        warmEarLease.disarm()
    }

    private func failIfPending(_ request: OpenClamKeyboardRequest, message: String) {
        do {
            guard try requireStore().result(for: request.id) == nil else { return }
            fail(request, message: message)
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .fill(microphoneColor.opacity(0.14))
                        .frame(width: 150, height: 150)
                    Image(systemName: microphoneSymbol)
                        .font(.system(size: 58, weight: .semibold))
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

                if !speech.transcript.isEmpty {
                    ScrollView {
                        Text(speech.transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(14)
                    }
                    .frame(maxHeight: 150)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                }

                actionArea

                Text("The keyboard extension cannot access the microphone. OpenClam records only on this visible screen, stops before you return, and shares only the final transcript through the local App Group.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer(minLength: 8)
            }
            .padding(24)
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
        .interactiveDismissDisabled(phase == .listening || phase == .transcribing)
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
            if phase == .listening || phase == .transcribing {
                speech.cancel()
                if !deliveredResult {
                    host.fail(
                        request,
                        message: "Voice input closed before a transcript was ready."
                    )
                }
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
                Button("Try again") {
                    phase = .preparing
                    message = "Preparing microphone permission…"
                    Task { await startIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
                Button("Close") { host.dismiss(request) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var providerName: String {
        AIProviderRegistry.descriptor(
            for: aiConfiguration.settings.speechToText.provider
        ).displayName
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
        case .preparing, .transcribing: .blue
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
            deadlineTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
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
        speech.cancel()
        phase = .failed
        message = error
        if !deliveredResult {
            host.fail(request, message: error)
            deliveredResult = true
        }
    }
}
