#if OPENCLAM_LIVE_SCREEN_CONTEXT
import SwiftUI
import UIKit

/// iOS 27 UI for the explicitly disclosed, visibly active full-display Screen Context session.
/// A dictated Shortcut question is itself the per-request action: the view consumes the pair once
/// and hands it to the root callback. This file never contains provider credentials or networking.
@available(iOS 27.0, *)
struct ScreenCaptureSessionView: View {
    @ObservedObject var manager: ScreenCaptureKitManager
    @ObservedObject private var contextSession: ScreenContextCaptureSession
    let onQuestionReadyForOneRequest: (ScreenContextQuestion) -> Void

    @State private var errorMessage: String?

    init(
        manager: ScreenCaptureKitManager,
        onQuestionReadyForOneRequest: @escaping (ScreenContextQuestion) -> Void
    ) {
        self.manager = manager
        _contextSession = ObservedObject(wrappedValue: manager.contextSession)
        self.onQuestionReadyForOneRequest = onQuestionReadyForOneRequest
    }

    var body: some View {
        Form {
            Section("How this session works") {
                Text(ScreenContextCapturePolicy.disclosure)
                    .font(.footnote)
                Label("Apple's system picker chooses the captured screen", systemImage: "checkmark.shield")
                Label("Only one latest frame is retained; older frames are replaced", systemImage: "rectangle.stack.badge.minus")
                Label("No wake word, microphone stream, recording, or camera", systemImage: "mic.slash")
            }

            controlsSection

            if manager.state == .capturing {
                Section("Capture is active") {
                    Label(
                        "Visible screen capture is on",
                        systemImage: "record.circle.fill"
                    )
                    .foregroundStyle(.red)

                    if let frame = contextSession.latestFrame,
                       let image = UIImage(data: frame.jpegData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Latest retained screen frame")
                        Text("Latest only • \(frame.pixelWidth)×\(frame.pixelHeight) • \(ByteCountFormatter.string(fromByteCount: Int64(frame.jpegData.count), countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView("Waiting for the first bounded frame…")
                    }

                    Text("Run your Action Button Shortcut: Dictate Text → Ask About Current Screen. The question expires after two minutes if this active session cannot consume it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Stop Screen Context", role: .destructive) {
                        Task { await manager.stop() }
                    }
                }
            }

            if let lastMessage = manager.lastMessage {
                Section("Status") {
                    Text(lastMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Live Screen Context")
        .onChange(of: contextSession.pendingQuestion?.id, initial: true) { _, _ in
            consumePendingQuestionIfAvailable()
        }
        .alert(
            "Screen Context error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "The screen session could not continue.")
        }
    }

    private func consumePendingQuestionIfAvailable() {
        do {
            guard let payload = try manager.consumePendingQuestionForOneRequestIfAvailable() else {
                return
            }
            onQuestionReadyForOneRequest(payload)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        Section("Session controls") {
            switch manager.state {
            case .unavailable:
                Text("Full-display Screen Context is unavailable. It requires iOS 27, the Screen Recording capability, and a supported device.")
                    .foregroundStyle(.secondary)
            case .disclosureRequired, .stopped:
                Button("I understand — continue") {
                    manager.acknowledgeSessionDisclosure()
                }
            case .readyForSystemPicker:
                Button("Choose screen with Apple’s picker") {
                    do {
                        try manager.presentSystemPicker()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            case .choosingContent:
                ProgressView("Waiting for Apple’s system picker…")
            case .readyToStart:
                Button("Start visible capture") {
                    Task {
                        do {
                            try await manager.startAfterUserConfirmation()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            case .capturing:
                Text("Capture stays active while you switch apps. Return here and tap Stop when finished.")
                    .foregroundStyle(.secondary)
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.red)
                Button("Stop and clear session") {
                    Task { await manager.stop() }
                }
            }
        }
    }
}
#endif
