import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var model: AssistantModel

    var body: some View {
        List {
            Section("Three complementary paths") {
                setupRow(
                    number: "1",
                    title: "Native companion",
                    detail: "Use this app for foreground AI conversation, explicitly sent attachments, nearby Maps search, reviewed Contacts sharing, Calendar and Reminders actions, drafts, and clear review screens."
                )
                setupRow(
                    number: "2",
                    title: "Device Actions Shortcut",
                    detail: "Install the secret-free AirDrop Shortcut for reviewed timers, Clock alarms, Low Power Mode, flashlight, Home, and Control Center actions. It contains no AI key or Mac receiver token."
                )
                setupRow(
                    number: "3",
                    title: "Mac + Shortcut bridge",
                    detail: "The optional private bridge adds Mac-initiated commands and selected phone-to-Mac responses. It needs its own hostname, token, iMessage setup, and personal automation."
                )
            }

            Section("Receive a reviewed command") {
                NavigationLink(value: OpenClamRoute.screenContext) {
                    Label(
                        model.pendingCommand == nil
                            ? "Open command review"
                            : "External command waiting",
                        systemImage: model.pendingCommand == nil
                            ? "hand.raised.square"
                            : "hand.raised.square.fill"
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Deep link example").font(.headline)
                    Text("openclam-livekit-pilot://command?action=clipboard_copy&text=Hello")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Opening the link shows the exact request in Screen & Shared Context. Confirmed runs it and Cancel discards it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Shortcuts / Siri").font(.headline)
                    Text("Say “Ask OpenClam” to have Siri collect a question and open it here for review. “Review OpenClam Command” remains available for structured automations.")
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }

            Section("OpenClam Keyboard") {
                Label(
                    "Add OpenClam Keyboard in Settings › General › Keyboard › Keyboards",
                    systemImage: "keyboard"
                )
                Label(
                    "Enable Allow Full Access for OpenClam's private transcript handoff",
                    systemImage: "lock.open"
                )
                Text(OpenClamKeyboardUserCopy.setupWorkflow)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(
                    "Use Start in OpenClam Keyboard; Listening confirms your selected provider is ready",
                    systemImage: "waveform.circle.fill"
                )
            }

            Section("Security posture") {
                Label("Provider keys stay in the device-only iOS Keychain", systemImage: "key.fill")
                Label("Submitted prompts go only to the HTTPS provider shown in AI Settings", systemImage: "network.badge.shield.half.filled")
                Label("Selected attachments leave the iPhone only after you tap Send", systemImage: "paperclip")
                Label("Only exact contact fields you review can be shared once", systemImage: "person.text.rectangle")
                Label("Contact notes are not requested or read", systemImage: "note.text.badge.plus")
                Label(OpenClamKeyboardUserCopy.boundedMicrophoneDisclosure, systemImage: "mic.fill")
                Label("No live screen capture; screen context comes only from content you select or explicitly share", systemImage: "rectangle.dashed")
                Label("No invented review, rating, menu, or venue claims", systemImage: "checkmark.shield")
                Label("No silent messages, calls, orders, rides, or purchases", systemImage: "hand.raised")
                Label("Bounded chat text and attachment descriptors persist on this iPhone; private review payloads and attachment bytes do not enter chat history", systemImage: "lock.doc")
            }
        }
        .navigationTitle("Shortcuts & Integrations")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setupRow(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.indigo, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
