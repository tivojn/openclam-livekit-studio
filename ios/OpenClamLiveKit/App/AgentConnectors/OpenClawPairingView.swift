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
                        Text("On your Mac, open OpenClam Studio → Settings → AI & Voice → OpenClaw · iPhone pairing, then create a code. If it expires, create another—nothing needs to be reset. The code is never saved; the revocable connection token stays in device-only Keychain.")
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
                    Label("Text-only requests", systemImage: "text.bubble")
                    Label("No iPhone tools or file uploads", systemImage: "iphone.slash")
                    Label("Verified generated files can be received", systemImage: "doc.badge.arrow.down")
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
    @ObservedObject var configuration: AIConfigurationModel

    let onConnectorRouteChanged: (String) -> Void

    @State private var showsPairing = false
    @State private var disconnectCandidate: AgentConnectorConnection?
    @State private var errorMessage: String?
    @State private var notice: String?

    var body: some View {
        List {
            Section {
                Button {
                    showsPairing = true
                } label: {
                    Label("Pair this iPhone", systemImage: "link.badge.plus")
                }
                .disabled(!connections.isConfigured)
            } footer: {
                Text(connections.isConfigured
                     ? "Create the one-time code in OpenClam Studio on your Mac. After pairing, choose an agent and it will be assigned to the active avatar automatically."
                     : "OpenClaw pairing is not configured in this build.")
            }

            Section("Paired gateways") {
                if connections.connections.isEmpty {
                    Text("No OpenClaw gateways paired")
                        .foregroundStyle(.secondary)
                }
                ForEach(connections.connections) { connection in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.gatewayLabel)
                                .font(.body.weight(.semibold))
                            Text(connection.accounts.map(\.displayName).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if !avatarNames(using: connection).isEmpty {
                                Text("Used by \(avatarNames(using: connection).joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if connections.revokingConnectionIDs.contains(connection.connectionID) {
                            ProgressView()
                        } else {
                            Button(role: .destructive) {
                                disconnectCandidate = connection
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(connection.gatewayLabel) pairing")
                            .accessibilityIdentifier(
                                "openclam-openclaw-disconnect-\(connection.connectionID.uuidString.lowercased())"
                            )
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
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

            if let notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Agent Connections")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsPairing) {
            OpenClawPairingView { binding in
                assignToActiveAvatar(binding)
            }
                .environmentObject(connections)
        }
        .confirmationDialog(
            "Remove this OpenClaw pairing?",
            isPresented: Binding(
                get: { disconnectCandidate != nil },
                set: { if !$0 { disconnectCandidate = nil } }
            ),
            presenting: disconnectCandidate
        ) { connection in
            Button("Remove pairing", role: .destructive) {
                Task { @MainActor in
                    do {
                        let affectedAvatarIDs = configuration.avatarAgentProfiles.values
                            .filter {
                                $0.agentConnectorBinding?.connectionID
                                    == connection.connectionID
                            }
                            .map(\.id)
                        try await connections.disconnect(
                            connection.connectionID,
                            discardPendingTurns: true
                        )
                        for avatarID in affectedAvatarIDs {
                            var profile = configuration.profile(for: avatarID)
                            profile.agentConnectorBinding = nil
                            try configuration.updateAvatarProfile(profile)
                            onConnectorRouteChanged(avatarID)
                        }
                        disconnectCandidate = nil
                        notice = "Removed \(connection.gatewayLabel). Affected avatars will use On iPhone for new chats."
                    } catch {
                        disconnectCandidate = nil
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) { disconnectCandidate = nil }
        } message: { _ in
            Text("This revokes the connection, discards any saved unfinished turn for it, and returns affected avatars to On iPhone for new chats. Existing chat history and received files stay on this iPhone.")
        }
    }

    private func avatarNames(
        using connection: AgentConnectorConnection
    ) -> [String] {
        configuration.avatarAgentProfiles.values
            .filter {
                $0.agentConnectorBinding?.connectionID == connection.connectionID
            }
            .map(\.displayName)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func assignToActiveAvatar(_ binding: AvatarAgentConnectorBinding) {
        do {
            var profile = configuration.activeAvatarProfile
            let routeChanged = profile.agentConnectorBinding != binding
            profile.agentConnectorBinding = binding
            try configuration.updateAvatarProfile(profile)
            if routeChanged {
                onConnectorRouteChanged(profile.id)
            }
            errorMessage = nil
            notice = "\(connections.displayLabel(for: binding)) is now assigned to \(profile.displayName)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
