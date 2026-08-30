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
    @Published private(set) var title = "OpenClam Voice"
    @Published private(set) var detail = "Turn on Quick Dictation in OpenClam once, then dictate here with your selected speech provider."
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
    private var activeRequestID: UUID?
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

    var microphoneIsEnabled: Bool {
        hasFullAccess
            && (OpenClamKeyboardWarmEarState.isEnabled || phase == .waiting)
    }

    var showsOpenClamVoiceAction: Bool {
        true
    }

    var headerStatusText: String {
        switch phase {
        case .needsFullAccess:
            "Setup"
        case .waiting:
            title == "Listening" ? "Listening" : "Connecting"
        case .inserted:
            "Inserted"
        case .failed:
            "Attention"
        case .ready:
            if warmEarIsReady {
                "Ready"
            } else if OpenClamKeyboardWarmEarState.isEnabled {
                "Preparing"
            } else {
                "Needs OpenClam"
            }
        }
    }

    var headerStatusColor: Color {
        switch phase {
        case .inserted:
            .green
        case .waiting where title == "Listening":
            .green
        case .ready where warmEarIsReady:
            .green
        case .failed:
            .orange
        default:
            .secondary
        }
    }

    var accentColor: Color {
        switch phase {
        case .failed: .orange
        case .inserted: .green
        case .waiting: .red
        case .needsFullAccess: .secondary
        case .ready: .primary
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
            store = nil
            phase = .needsFullAccess
            warmEarIsReady = false
            title = "Allow Full Access"
            detail = "Full Access lets OpenClam return the finished provider transcript through its private shared container."
            primaryActionTitle = "OpenClam Voice"
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
        guard OpenClamKeyboardWarmEarState.isEnabled else {
            showReady(detail: "Turn on Quick Dictation in OpenClam once, then return here.")
            return
        }

        do {
            let availableStore = try store ?? OpenClamKeyboardHandoffStore.live()
            store = availableStore
            let request = try availableStore.beginRequest()
            activeRequestID = request.id
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
            activeRequestID = nil
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
            if let request = try availableStore.activeRequest(at: date) {
                activeRequestID = request.id
                phase = .waiting
                warmEarIsReady = OpenClamKeyboardWarmEarState.isReady(at: date)
                updateWaitingCopy()
            } else {
                activeRequestID = nil
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
        activeRequestID = nil
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
        if !hasFullAccess {
            updateFullAccess(false)
        } else if warmEarIsReady {
            title = "OpenClam Voice Ready"
            self.detail = detail ?? "Tap Start and speak. OpenClam stops after your pause."
            primaryActionTitle = "Start"
            updatePolling()
        } else if OpenClamKeyboardWarmEarState.isEnabled {
            title = "OpenClam Voice"
            self.detail = detail
                ?? "Tap Start. If Quick Dictation is still preparing, listening begins as soon as it is ready."
            primaryActionTitle = "Start"
            updatePolling()
        } else {
            title = "OpenClam Voice"
            self.detail = detail
                ?? "Turn on Quick Dictation in OpenClam once, then return here."
            primaryActionTitle = "Start"
            updatePolling()
        }
    }

    private func showFailure(_ message: String) {
        phase = .failed
        warmEarIsReady = OpenClamKeyboardWarmEarState.isReady()
        title = "OpenClam Voice failed"
        detail = message
        primaryActionTitle = "Try Again"
        announce("OpenClam Voice failed. \(message)")
        updatePolling()
    }

    private func updateWaitingCopy() {
        let previousTitle = title
        if let activeRequestID,
           OpenClamKeyboardWarmEarState.isListening(requestID: activeRequestID) {
            title = "Listening"
            detail = "Speak now. OpenClam stops after your pause."
        } else {
            title = "Connecting to OpenClam"
            detail = "Wait for Listening, then speak. Your provider starts automatically."
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
                    Label(
                        model.showsOpenClamVoiceAction ? "OpenClam Voice" : "Voice Input",
                        systemImage: model.showsOpenClamVoiceAction
                            ? "waveform.circle.fill"
                            : "mic.circle.fill"
                    )
                        .font(.headline)
                    Spacer()
                    Text(model.headerStatusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.headerStatusColor)
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
