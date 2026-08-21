import SwiftUI
import UIKit

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
    @Published private(set) var title = "Quick Dictation"
    @Published private(set) var detail = "Open OpenClam first for instant voice input."
    @Published private(set) var primaryActionTitle = "Start"
    @Published private(set) var hasFullAccess = false
    @Published private(set) var warmEarIsReady = false
    @Published private(set) var showsInputModeSwitchKey = true
    @Published private(set) var returnKeyLabel = "Return"
    @Published private(set) var compactLayout = false

    private let insertText: (String) -> Void
    private let contextBeforeInput: () -> String?
    private var store: OpenClamKeyboardHandoffStore?
    private var pollingTimer: Timer?
    private var isVisible = false
    private var locallyConsumedResultIDs: Set<UUID> = []

    init(
        insertText: @escaping (String) -> Void,
        contextBeforeInput: @escaping () -> String?
    ) {
        self.insertText = insertText
        self.contextBeforeInput = contextBeforeInput
    }

    var microphoneSymbol: String {
        switch phase {
        case .waiting: "xmark"
        case .inserted: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .needsFullAccess: "lock.fill"
        case .ready: "mic.fill"
        }
    }

    var microphoneIsEnabled: Bool { hasFullAccess }

    var accentColor: Color {
        switch phase {
        case .failed: .orange
        case .inserted: .green
        case .waiting: .red
        case .needsFullAccess: .secondary
        case .ready: .blue
        }
    }

    var isWaiting: Bool { phase == .waiting }

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
            detail = "Required only for the local transcript handoff. The keyboard never receives your provider key."
            primaryActionTitle = "Full Access Required"
            updatePolling()
        }
    }

    func startPolling() {
        isVisible = true
        refresh()
        updatePolling()
    }

    func stopPolling() {
        isVisible = false
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    func updateKeyboardTraits(
        showsInputModeSwitchKey: Bool,
        returnKeyLabel: String,
        compactLayout: Bool
    ) {
        if self.showsInputModeSwitchKey != showsInputModeSwitchKey {
            self.showsInputModeSwitchKey = showsInputModeSwitchKey
        }
        if self.returnKeyLabel != returnKeyLabel {
            self.returnKeyLabel = returnKeyLabel
        }
        if self.compactLayout != compactLayout {
            self.compactLayout = compactLayout
        }
    }

    func performPrimaryAction() {
        if phase == .waiting {
            cancelVoiceInput()
        } else {
            beginVoiceInput()
        }
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
            updatePolling()
        } catch {
            showFailure(error.localizedDescription)
        }
    }

    func cancelVoiceInput() {
        guard phase == .waiting else { return }
        do {
            let availableStore = try store ?? OpenClamKeyboardHandoffStore.live()
            store = availableStore
            _ = try availableStore.cancelActiveRequest()
            OpenClamKeyboardWarmEarSignal.postCancelRequest()
            refresh()
            if phase == .waiting {
                showReady(detail: "Voice input cancelled.")
            }
        } catch {
            showFailure(error.localizedDescription)
        }
    }

    func refresh(at date: Date = Date()) {
        guard hasFullAccess else { return }
        do {
            let availableStore = try store ?? OpenClamKeyboardHandoffStore.live()
            store = availableStore
            if let result = try availableStore.peekActiveResult(at: date) {
                if !locallyConsumedResultIDs.contains(result.requestID) {
                    consume(result)
                    locallyConsumedResultIDs.insert(result.requestID)
                }
                try availableStore.acknowledgeActiveResult(
                    requestID: result.requestID,
                    at: date
                )
                locallyConsumedResultIDs.remove(result.requestID)
                return
            }
            if try availableStore.activeRequest(at: date) != nil {
                phase = .waiting
                warmEarIsReady = OpenClamKeyboardWarmEarState.isReady(at: date)
                updateWaitingCopy()
            } else if phase == .waiting {
                showReady()
            }
            updatePolling()
        } catch OpenClamKeyboardStoreError.staleRequest {
            showFailure("The voice request expired. Tap Try Again to start a new one.")
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
            detail = "Transcript added at the cursor and cleared from the handoff."
            primaryActionTitle = "Dictate Again"
            announce("Transcript inserted")
            updatePolling()
        case .cancelled:
            showReady(detail: result.message ?? "Voice input was cancelled.")
        case .failed:
            showFailure(result.message ?? "Voice input failed in OpenClam.")
        }
    }

    private func showReady(detail: String? = nil) {
        phase = .ready
        warmEarIsReady = OpenClamKeyboardWarmEarState.isReady()
        title = warmEarIsReady ? "Ready for Quick Dictation" : "Quick Dictation"
        self.detail = detail ?? (warmEarIsReady
            ? "Tap Start and speak. OpenClam stops after you pause."
            : "Open OpenClam first for instant voice input.")
        primaryActionTitle = "Start"
        updatePolling()
    }

    private func showFailure(_ message: String) {
        phase = .failed
        title = "Voice Input Unavailable"
        detail = message
        primaryActionTitle = "Try Again"
        warmEarIsReady = false
        announce("Voice input unavailable. \(message)")
        updatePolling()
    }

    private func updateWaitingCopy() {
        let previousTitle = title
        if warmEarIsReady {
            title = "Listening"
            detail = "Speak now. OpenClam stops after your pause."
        } else {
            title = "Waiting for OpenClam"
            detail = "Open OpenClam, finish the visible voice screen, then return."
        }
        primaryActionTitle = "Cancel"
        if title != previousTitle {
            announce(title)
        }
    }

    private func updatePolling() {
        let shouldPoll = isVisible && phase == .waiting
        if shouldPoll, pollingTimer == nil {
            pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) {
                [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        } else if !shouldPoll {
            pollingTimer?.invalidate()
            pollingTimer = nil
        }
    }

    private func announce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning else {
            return
        }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

struct OpenClamKeyboardView: View {
    @ObservedObject var model: OpenClamKeyboardViewModel

    let performPrimaryAction: () -> Void
    let showInputModeList: (UIButton, UIEvent) -> Void
    let deleteBackward: () -> Void
    let insertSpace: () -> Void
    let insertReturn: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: model.compactLayout ? 6 : 9) {
            if !model.compactLayout, !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    Label("OpenClam Voice", systemImage: "waveform.circle.fill")
                        .font(.headline)
                    Spacer()
                    Text(model.warmEarIsReady ? "Ready" : "Open app first")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.warmEarIsReady ? .green : .secondary)
                }
            }

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollView(.vertical) {
                            HStack(alignment: .top, spacing: 10) {
                                waitingIndicator
                                statusText
                            }
                        }
                        .frame(height: model.compactLayout ? 54 : 94)
                        .scrollBounceBehavior(.basedOnSize)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(model.title). \(model.detail)")
                        primaryActionButton(showLabel: true)
                    }
                } else {
                    HStack(spacing: 12) {
                        waitingIndicator
                        statusText
                        primaryActionButton(showLabel: false)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: model.compactLayout ? 62 : 72)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 16)
            )

            HStack(spacing: 8) {
                if model.showsInputModeSwitchKey {
                    OpenClamInputModeSwitchButton(action: showInputModeList)
                        .frame(width: 52, height: 44)
                        .accessibilityLabel("Next keyboard")
                        .accessibilityHint("Touch and hold to choose a keyboard")
                }
                editButton("delete.left", label: "Delete", action: deleteBackward)
                Button("space", action: insertSpace)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Space")
                editButton("return", label: model.returnKeyLabel, action: insertReturn)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, model.compactLayout ? 6 : 8)
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private var waitingIndicator: some View {
        if model.isWaiting {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: !reduceMotion)
                .accessibilityHidden(true)
        }
    }

    private var statusText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.title)
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            Text(model.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(
                    dynamicTypeSize.isAccessibilitySize
                        ? nil
                        : (model.compactLayout ? 1 : 2)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func primaryActionButton(showLabel: Bool) -> some View {
        Button(action: performPrimaryAction) {
            Group {
                if showLabel {
                    Label(model.primaryActionTitle, systemImage: model.microphoneSymbol)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    Image(systemName: model.microphoneSymbol)
                        .font(.system(size: 21, weight: .semibold))
                        .frame(width: 50, height: 50)
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(showLabel ? .capsule : .circle)
        .tint(model.accentColor)
        .disabled(!model.microphoneIsEnabled)
        .accessibilityLabel(model.primaryActionTitle)
        .accessibilityHint(model.detail)
    }

    private func editButton(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if systemName == "return", label != "Return" {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                } else {
                    Image(systemName: systemName)
                }
            }
            .frame(minWidth: 50, maxWidth: 66, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .buttonRepeatBehavior(systemName == "delete.left" ? .enabled : .disabled)
        .accessibilityLabel(label)
    }
}

private struct OpenClamInputModeSwitchButton: UIViewRepresentable {
    let action: (UIButton, UIEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.accessibilityLabel = "Next keyboard"
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handle(_:forEvent:)),
            for: .allTouchEvents
        )
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: (UIButton, UIEvent) -> Void

        init(action: @escaping (UIButton, UIEvent) -> Void) {
            self.action = action
        }

        @objc func handle(_ sender: UIButton, forEvent event: UIEvent) {
            action(sender, event)
        }
    }
}
