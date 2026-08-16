import MessageUI
import SwiftUI
import UIKit

enum MailComposeResult: Equatable, Sendable {
    case cancelled
    case saved
    case submitted
    case failed(message: String)
}

enum MailComposeEvent: Equatable, Sendable {
    case unavailable(message: String)
    case fallbackCopied
    case finished(MailComposeResult)
}

struct MailComposeView: View {
    static var isAvailable: Bool {
        MFMailComposeViewController.canSendMail()
    }

    let draft: MailDraftContent
    let onEvent: (MailComposeEvent) -> Void

    var body: some View {
        if Self.isAvailable {
            MailControllerRepresentable(draft: draft, onEvent: onEvent)
                .ignoresSafeArea()
        } else {
            MailUnavailableFallback(draft: draft, onEvent: onEvent)
        }
    }
}

private struct MailControllerRepresentable: UIViewControllerRepresentable {
    let draft: MailDraftContent
    let onEvent: (MailComposeEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([draft.recipient])
        controller.setSubject(draft.subject)
        controller.setMessageBody(draft.body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
        let onEvent: (MailComposeEvent) -> Void

        init(onEvent: @escaping (MailComposeEvent) -> Void) {
            self.onEvent = onEvent
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            let outcome: MailComposeResult
            switch result {
            case .cancelled:
                outcome = .cancelled
            case .saved:
                outcome = .saved
            case .sent:
                // "Submitted" deliberately does not claim that the email was delivered.
                outcome = .submitted
            case .failed:
                outcome = .failed(message: error?.localizedDescription ?? "Mail could not submit the draft.")
            @unknown default:
                outcome = .failed(message: "Mail closed with an unknown result.")
            }
            controller.dismiss(animated: true)
            onEvent(.finished(outcome))
        }
    }
}

private struct MailUnavailableFallback: View {
    let draft: MailDraftContent
    let onEvent: (MailComposeEvent) -> Void
    @State private var didSignalUnavailable = false

    private let unavailableMessage = "Apple Mail cannot compose a draft on this device. You can copy the draft and paste it into another mail app."

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)

                Text("Mail composer unavailable")
                    .font(.title2.bold())
                Text(unavailableMessage)
                    .foregroundStyle(.secondary)

                Text(draft.fallbackPlainText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                Button {
                    UIPasteboard.general.string = draft.fallbackPlainText
                    onEvent(.fallbackCopied)
                } label: {
                    Label("Copy email draft", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding(24)
            .navigationTitle("Email Draft")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !didSignalUnavailable else { return }
                didSignalUnavailable = true
                onEvent(.unavailable(message: unavailableMessage))
            }
        }
    }
}
