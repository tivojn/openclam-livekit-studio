import SwiftUI

/// Local settings UI for exact, user-managed app and web destinations.
/// Embed this view from Settings; it does not enumerate or infer installed apps.
struct AppAliasSettingsView: View {
    @ObservedObject var registry: AppAliasRegistry
    @StateObject private var handoffSession = AppHandoffSession()

    @State private var editorAlias: AppAlias?
    @State private var showsEditor = false
    @State private var aliasPendingRemoval: AppAlias?
    @State private var reviewProposal: AppHandoffProposal?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text(AppAliasRegistry.platformLimitation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("My app aliases") {
                if registry.aliases.isEmpty {
                    ContentUnavailableView(
                        "No app aliases",
                        systemImage: "link.badge.plus",
                        description: Text("Add a display name and the exact public URL or deep link supplied by that app.")
                    )
                }
                ForEach(registry.aliases) { alias in
                    aliasRow(alias)
                }
            }

            Section {
                Button {
                    editorAlias = nil
                    showsEditor = true
                } label: {
                    Label("Add app alias", systemImage: "plus")
                }
                .disabled(registry.aliases.count >= AppAliasRegistry.maximumAliases)
            } footer: {
                Text("Aliases are stored locally. URLs containing likely credentials are rejected.")
            }
        }
        .navigationTitle("App aliases")
        .sheet(isPresented: $showsEditor) {
            NavigationStack {
                AppAliasEditorView(registry: registry, alias: editorAlias)
            }
        }
        .sheet(item: $reviewProposal, onDismiss: cancelUnconsumedReview) { proposal in
            NavigationStack {
                AppHandoffConfirmationView(session: handoffSession, proposal: proposal)
            }
        }
        .alert(
            "Remove app alias?",
            isPresented: Binding(
                get: { aliasPendingRemoval != nil },
                set: { if !$0 { aliasPendingRemoval = nil } }
            ),
            presenting: aliasPendingRemoval
        ) { alias in
            Button("Remove", role: .destructive) {
                do {
                    try registry.remove(id: alias.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
                aliasPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                aliasPendingRemoval = nil
            }
        } message: { alias in
            Text("\(alias.displayName)\n\(alias.rawURL)")
        }
        .alert(
            "App alias error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "The app alias could not be updated.")
        }
    }

    private func aliasRow(_ alias: AppAlias) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(alias.displayName)
                .font(.headline)
            Text(alias.rawURL)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)

            HStack {
                Button("Test") {
                    stageLocalTest(alias)
                }
                .buttonStyle(.bordered)

                Button("Edit") {
                    editorAlias = alias
                    showsEditor = true
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Remove", role: .destructive) {
                    aliasPendingRemoval = alias
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func stageLocalTest(_ alias: AppAlias) {
        do {
            reviewProposal = try handoffSession.stage(
                alias: alias,
                latestUserText: "Open \(alias.displayName)"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancelUnconsumedReview() {
        if handoffSession.proposal != nil {
            handoffSession.cancel()
        }
    }
}

struct AppHandoffConfirmationView: View {
    @ObservedObject var session: AppHandoffSession
    let proposal: AppHandoffProposal

    @Environment(\.dismiss) private var dismiss
    @State private var isOpening = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Open once") {
                if let alias = proposal.aliasDisplayName {
                    LabeledContent("App alias", value: alias)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Exact destination")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(proposal.url.absoluteString)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section {
                Text("OpenClam will ask iOS to open only the exact destination above. iOS may open an app or its website; success inside that destination is not verified.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    isOpening = true
                    Task {
                        do {
                            try await session.openFromUserConfirmation(proposalID: proposal.id)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        isOpening = false
                    }
                } label: {
                    Label("Open this exact destination", systemImage: "arrow.up.forward.app")
                }
                .disabled(isOpening || session.proposal?.id != proposal.id)

                Button("Cancel", role: .cancel) {
                    session.cancel()
                    dismiss()
                }
            }
        }
        .navigationTitle("Confirm app handoff")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isOpening)
        .alert(
            "Could not open destination",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "iOS did not accept this destination.")
        }
    }
}

private struct AppAliasEditorView: View {
    @ObservedObject var registry: AppAliasRegistry
    let alias: AppAlias?

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var rawURL: String
    @State private var errorMessage: String?

    init(registry: AppAliasRegistry, alias: AppAlias?) {
        self.registry = registry
        self.alias = alias
        _displayName = State(initialValue: alias?.displayName ?? "")
        _rawURL = State(initialValue: alias?.rawURL ?? "")
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Display name")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    TextField("For example: Work chat", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("App alias display name")
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Exact URL or deep link")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)

                    TextField("Paste the documented destination", text: $rawURL, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .accessibilityLabel("Exact app URL or deep link")
                }
                .padding(.vertical, 2)
            } header: {
                Text("Alias")
            } footer: {
                Text("Copy the exact URL from the app or service's public documentation. OpenClam will not guess a scheme.")
            }

            if !rawURL.isEmpty {
                Section("Destination to save") {
                    Text(rawURL)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(alias == nil ? "Add app alias" : "Edit app alias")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
        .alert(
            "Could not save alias",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Check the display name and exact destination.")
        }
    }

    private func save() {
        do {
            if let alias {
                try registry.update(id: alias.id, displayName: displayName, rawURL: rawURL)
            } else {
                try registry.add(displayName: displayName, rawURL: rawURL)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
