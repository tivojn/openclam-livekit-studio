import SwiftUI

struct OpenClawPairingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var connections: AgentConnectionModel

    let onSelect: (AvatarAgentConnectorBinding) -> Void

    @State private var pairingCode = ""
    @State private var pairedConnection: AgentConnectorConnection?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let pairedConnection {
                    Section {
                        ForEach(pairedConnection.accounts) { account in
                            Button {
                                onSelect(pairedConnection.binding(for: account))
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.displayName)
                                        .foregroundStyle(.primary)
                                    Text("\(pairedConnection.gatewayLabel) · \(account.agentID)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier(
                                "openclam-openclaw-agent-\(account.id)"
                            )
                        }
                    } header: {
                        Text("Choose an OpenClaw agent")
                    } footer: {
                        Text("Each avatar chooses one agent. You can use this same paired gateway with other avatars later.")
                    }
                } else {
                    Section {
                        TextField("OC-XXXX-XXXX-XXXX", text: $pairingCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .onChange(of: pairingCode) { _, value in
                                let normalized = AgentConnectorPairingCode.normalized(value)
                                if pairingCode != normalized {
                                    pairingCode = normalized
                                }
                            }
                            .accessibilityLabel("OpenClam pairing code")
                            .accessibilityIdentifier("openclam-openclaw-pairing-code")

                        Button {
                            pair()
                        } label: {
                            HStack {
                                if connections.isPairing { ProgressView() }
                                Text(connections.isPairing ? "Pairing…" : "Pair securely")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(
                            connections.isPairing
                                || (try? AgentConnectorPairingCode.validated(pairingCode)) == nil
                        )
                        .accessibilityIdentifier("openclam-openclaw-pair-button")
                    } header: {
                        Text("Pair with OpenClaw")
                    } footer: {
                        Text("Create a one-time OpenClam pairing code on your OpenClaw host, then enter it here. The code expires quickly and is never saved. OpenClam stores only a revocable, device-only connection token.")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("openclam-openclaw-pairing-error")
                    }
                }

                Section("Privacy boundary") {
                    Label("Text messages only", systemImage: "text.bubble")
                    Label("No iPhone tools or attachments", systemImage: "iphone.slash")
                    Label("No AI provider keys are shared", systemImage: "key.slash")
                }
            }
            .navigationTitle("Connect OpenClaw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func pair() {
        errorMessage = nil
        let code = pairingCode
        Task { @MainActor in
            do {
                let connection = try await connections.redeemPairingCode(code)
                pairingCode = ""
                pairedConnection = connection
            } catch {
                if !AgentConnectorPairingRetryPolicy.shouldRetainCode(after: error) {
                    pairingCode = ""
                }
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct AgentConnectionsSettingsView: View {
    @EnvironmentObject private var connections: AgentConnectionModel
    @State private var showsPairing = false
    @State private var disconnectCandidate: AgentConnectorConnection?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    showsPairing = true
                } label: {
                    Label("Pair OpenClaw", systemImage: "link.badge.plus")
                }
                .disabled(!connections.isConfigured)
            } footer: {
                Text(connections.isConfigured
                     ? "Pairing connects this iPhone to your OpenClaw host. Assign an agent to an avatar from Avatar Agents."
                     : "OpenClaw pairing is not configured in this build.")
            }

            Section("Paired gateways") {
                if connections.connections.isEmpty {
                    Text("No OpenClaw gateways paired")
                        .foregroundStyle(.secondary)
                }
                ForEach(connections.connections) { connection in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.gatewayLabel)
                                .font(.body.weight(.semibold))
                            Text("\(connection.accounts.count) agent\(connection.accounts.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if connections.revokingConnectionIDs.contains(connection.connectionID) {
                            ProgressView()
                        }
                    }
                    .swipeActions {
                        Button("Disconnect", role: .destructive) {
                            disconnectCandidate = connection
                        }
                        .disabled(connections.revokingConnectionIDs.contains(connection.connectionID))
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Agent Connections")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsPairing) {
            OpenClawPairingView { _ in }
                .environmentObject(connections)
        }
        .confirmationDialog(
            "Disconnect this OpenClaw gateway?",
            isPresented: Binding(
                get: { disconnectCandidate != nil },
                set: { if !$0 { disconnectCandidate = nil } }
            ),
            presenting: disconnectCandidate
        ) { connection in
            Button("Disconnect", role: .destructive) {
                Task { @MainActor in
                    do {
                        try await connections.disconnect(connection.connectionID)
                        disconnectCandidate = nil
                    } catch {
                        disconnectCandidate = nil
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) { disconnectCandidate = nil }
        } message: { _ in
            Text("Existing chats stay pinned to OpenClaw and will fail closed until you pair again. They never switch to the On iPhone model automatically.")
        }
    }
}
