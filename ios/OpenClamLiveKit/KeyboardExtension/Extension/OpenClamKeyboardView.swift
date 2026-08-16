import SwiftUI

@MainActor
final class OpenClamKeyboardViewModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case needsFullAccess
        case waiting
        case inserted
        case failed
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var title = "Voice input"
    @Published private(set) var detail = "Tap the microphone to speak in OpenClam."
    @Published private(set) var hasFullAccess = false
    @Published private(set) var warmEarIsReady = false

    private let insertText: (String) -> Void
    private let contextBeforeInput: () -> String?
    private var store: OpenClamKeyboardHandoffStore?
    private var pollingTimer: Timer?

    init(
        insertText: @escaping (String) -> Void,
        contextBeforeInput: @escaping () -> String?
    ) {
        self.insertText = insertText
        self.contextBeforeInput = contextBeforeInput
    }

    var microphoneSymbol: String {
        switch phase {
        case .waiting: warmEarIsReady ? "waveform" : "arrow.up.forward.app.fill"
        case .inserted: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .needsFullAccess: "lock.fill"
        case .ready: "mic.fill"
        }
    }

    var microphoneIsEnabled: Bool {
        hasFullAccess && phase != .waiting
    }

    var accentColor: Color {
        switch phase {
        case .failed: .orange
        case .inserted: .green
        case .waiting: .blue
        case .needsFullAccess: .secondary
        case .ready: .primary
        }
    }

    func updateFullAccess(_ enabled: Bool) {
        hasFullAccess = enabled
        if enabled {
            if phase == .needsFullAccess {
                showReady()
            }
            if store == nil {
                store = try? OpenClamKeyboardHandoffStore.live()
            }
            refresh()
        } else {
            phase = .needsFullAccess
            title = "Allow Full Access"
            detail = "iOS gives custom keyboards no microphone. Full Access lets OpenClam return only the finished transcript through its shared container."
        }
    }

    func startPolling() {
        stopPolling()
        refresh()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    func beginVoiceInput() {
        guard hasFullAccess else {
            updateFullAccess(false)
            return
        }

        do {
            let availableStore = try store ?? OpenClamKeyboardHandoffStore.live()
            store = availableStore
            _ = try availableStore.beginRequest()
            warmEarIsReady = OpenClamKeyboardWarmEarState.isReady()
            OpenClamKeyboardWarmEarSignal.postBeginRequest()
            phase = .waiting
            updateWaitingCopy()
        } catch {
            showFailure(error.localizedDescription)
        }
    }

    func refresh(at date: Date = Date()) {
        guard hasFullAccess else { return }
        do {
            let availableStore = try store ?? OpenClamKeyboardHandoffStore.live()
            store = availableStore
            if let result = try availableStore.takeActiveResult(at: date) {
                consume(result)
                return
            }
            if try availableStore.activeRequest(at: date) != nil {
                phase = .waiting
                warmEarIsReady = OpenClamKeyboardWarmEarState.isReady(at: date)
                updateWaitingCopy()
            } else if phase == .waiting {
                showReady()
            }
        } catch OpenClamKeyboardStoreError.staleRequest {
            showFailure("The voice request expired. Tap the microphone to start again.")
        } catch {
            showFailure(error.localizedDescription)
        }
    }

    private func consume(_ result: OpenClamKeyboardResult) {
        switch result.state {
        case .completed:
            guard let transcript = result.transcript,
                  let insertion = OpenClamKeyboardInsertionPlan.text(
                      for: transcript,
                      contextBeforeInput: contextBeforeInput()
                  ) else {
                showFailure("OpenClam returned an empty transcript. Try again.")
                return
            }
            insertText(insertion)
            phase = .inserted
            title = "Inserted"
            detail = "The finished transcript was placed at the cursor and removed from the shared container."
        case .cancelled:
            showReady(detail: result.message ?? "Voice input was cancelled.")
        case .failed:
            showFailure(result.message ?? "Voice input failed in OpenClam.")
        }
    }

    private func showReady(detail: String = "Tap the microphone to speak in OpenClam.") {
        phase = .ready
        title = "Voice input"
        self.detail = detail
        warmEarIsReady = OpenClamKeyboardWarmEarState.isReady()
    }

    private func showFailure(_ message: String) {
        phase = .failed
        title = "Voice input unavailable"
        detail = message
        warmEarIsReady = false
    }

    private func updateWaitingCopy() {
        if warmEarIsReady {
            title = "Listening in OpenClam"
            detail = "Speak now. OpenClam will stop automatically, return one final transcript, and release the microphone."
        } else {
            title = "Open OpenClam"
            detail = "The Ear lease is not ready. Open OpenClam from the Home Screen, speak on its visible voice screen, then return here."
        }
    }
}

struct OpenClamKeyboardView: View {
    @ObservedObject var model: OpenClamKeyboardViewModel

    let beginVoiceInput: () -> Void
    let advanceKeyboard: () -> Void
    let deleteBackward: () -> Void
    let insertSpace: () -> Void
    let insertReturn: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenClam Keyboard")
                        .font(.headline)
                    Text("Voice is recorded only by the OpenClam app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: advanceKeyboard) {
                    Image(systemName: "globe")
                        .frame(width: 36, height: 30)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Next keyboard")
            }

            Button(action: beginVoiceInput) {
                HStack(spacing: 12) {
                    Image(systemName: model.microphoneSymbol)
                        .font(.system(size: 24, weight: .semibold))
                        .symbolEffect(.pulse, isActive: model.phase == .waiting)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title)
                            .font(.system(size: 16, weight: .semibold))
                        Text(model.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .tint(model.accentColor)
            .disabled(!model.microphoneIsEnabled)
            .accessibilityLabel(model.title)
            .accessibilityHint(model.detail)

            HStack(spacing: 8) {
                editButton("delete.left", label: "Delete", action: deleteBackward)
                Button("space", action: insertSpace)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Space")
                editButton("return", label: "Return", action: insertReturn)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemBackground))
    }

    private func editButton(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 50)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }
}
