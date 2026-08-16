import SwiftUI

enum OpenClamRoute: Hashable {
    case settings
    case aiServices
    case avatarAgents
    case screenContext
    case appAliases
    case shortcutsAndIntegrations
    case capabilitiesAndPermissions
}

struct OpenClamSettingsView: View {
    @ObservedObject var configuration: AIConfigurationModel

    var body: some View {
        List {
            Section("AI Services") {
                NavigationLink(value: OpenClamRoute.aiServices) {
                    settingsRow(
                        title: "Chat & tap-to-talk AI",
                        detail: "Typed chat and tap-to-talk replies, tap-to-talk microphone, read-aloud voice, and search · \(activeAIServiceSummary)",
                        symbol: "brain.head.profile"
                    )
                }
                .accessibilityIdentifier("openclam-chat-ptt-ai-settings-link")

                NavigationLink(value: OpenClamRoute.avatarAgents) {
                    settingsRow(
                        title: "Avatar agents",
                        detail: "Each avatar’s personality and Continuous Live Talk model, speech recognition, and voice",
                        symbol: "person.3.sequence.fill"
                    )
                }
                .accessibilityIdentifier("openclam-avatar-agent-settings-link")
            }

            Section("iPhone Tools") {
                NavigationLink(value: OpenClamRoute.screenContext) {
                    settingsRow(
                        title: "Screen & Shared Context",
                        detail: "Review a screenshot, link, or text before adding it to a chat",
                        symbol: "rectangle.and.text.magnifyingglass"
                    )
                }

                NavigationLink(value: OpenClamRoute.appAliases) {
                    settingsRow(
                        title: "App Aliases",
                        detail: "Manage exact app and website destinations",
                        symbol: "square.grid.3x3.square"
                    )
                }

                NavigationLink(value: OpenClamRoute.shortcutsAndIntegrations) {
                    settingsRow(
                        title: "Shortcuts & Integrations",
                        detail: "Set up Siri, Device Actions, and the optional Mac bridge",
                        symbol: "point.3.connected.trianglepath.dotted"
                    )
                }
            }

            Section("About OpenClam") {
                NavigationLink(value: OpenClamRoute.capabilitiesAndPermissions) {
                    settingsRow(
                        title: "Capabilities & Permissions",
                        detail: "See supported commands and their iOS boundaries",
                        symbol: "checkmark.shield"
                    )
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "iphone")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Foreground by design")
                            .font(.subheadline.weight(.semibold))
                        Text("OpenClam listens, reads selected context, and contacts AI providers only when you explicitly ask it to.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var activeAIServiceSummary: String {
        let selection = configuration.settings.llm
        let provider = AIProviderRegistry.descriptor(for: selection.provider).displayName
        return "\(provider) · \(selection.model)"
    }

    private func settingsRow(
        title: String,
        detail: String,
        symbol: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}
