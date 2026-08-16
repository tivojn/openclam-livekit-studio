import SwiftUI

struct CapabilitiesView: View {
    var body: some View {
        List {
            Section {
                Text("Speak naturally. Your selected AI model chooses a typed tool, OpenClam shows the exact action, and you approve anything that changes the phone or leaves the app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Agent command catalog") {
                ForEach(AgentCommandCatalog.groups) { group in
                    DisclosureGroup {
                        ForEach(group.commands) { command in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(command.title)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer(minLength: 8)
                                    Label(command.boundary.rawValue, systemImage: command.boundary.systemImage)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(command.boundary.color)
                                }
                                Text("“\(command.example)”")
                                    .font(.subheadline)
                                Text(command.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                            .accessibilityElement(children: .combine)
                        }
                    } label: {
                        Label("\(group.title) · \(group.commands.count)", systemImage: group.systemImage)
                            .font(.headline)
                    }
                }
            }

            Section {
                Text("The matrix below distinguishes native operations, reviewed handoffs, the installed Device Actions Shortcut, and controls iOS does not expose to third-party apps.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(CapabilitySupport.allCases, id: \.self) { support in
                let values = Capability.matrix.filter { $0.support == support }
                if !values.isEmpty {
                    Section {
                        ForEach(values) { capability in
                            VStack(alignment: .leading, spacing: 7) {
                                Label(capability.title, systemImage: support.systemImage)
                                    .font(.headline)
                                    .foregroundStyle(support.color)
                                Text(capability.detail)
                                    .font(.subheadline)
                                Text("Permission: \(capability.permission)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text(support.rawValue)
                    }
                }
            }
        }
        .navigationTitle("Capabilities & Permissions")
        .navigationBarTitleDisplayMode(.inline)
    }
}
