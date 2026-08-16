import SwiftUI

struct OpenClamSidebarView: View {
    @ObservedObject var historyController: ConversationHistoryController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let canChangeChat: Bool
    let onClose: () -> Void
    let onNewChat: () -> Void
    let onSelectChat: (UUID) -> Void
    let onRenameChat: (UUID, String) -> Void
    let onDeleteChat: (UUID) -> Void
    let onShowSettings: () -> Void

    @State private var renameTarget: ConversationThreadSummary?
    @State private var renameTitle = ""
    @State private var deleteTarget: ConversationThreadSummary?
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            chatSearchField

            List {
                Section("Recent chats") {
                    if historyController.summaries.isEmpty {
                        ContentUnavailableView(
                            "No chats yet",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Start a chat and it will appear here on this iPhone.")
                        )
                        .listRowBackground(Color.clear)
                    } else if filteredSummaries.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(filteredSummaries) { summary in
                            chatRow(summary)
                                .listRowBackground(
                                    historyController.selectedThreadID == summary.id
                                        ? Color.primary.opacity(0.08)
                                        : Color.clear
                                )
                        }
                    }
                }

                if let error = historyController.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityElement(children: .combine)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Divider()

            Button {
                onNewChat()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
            .disabled(!canChangeChat)
            .accessibilityHint("Starts a new local conversation")

            Divider()
                .padding(.leading, 56)

            Button {
                onShowSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
            .accessibilityIdentifier("Sidebar settings")
            .accessibilityHint("Opens AI services and iPhone tool settings")
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .alert(
            "Rename chat",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Chat name", text: $renameTitle)
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
            Button("Rename") {
                guard let target = renameTarget else { return }
                onRenameChat(target.id, renameTitle)
                renameTarget = nil
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a name that will be easy to find in Recent chats.")
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { target in
            Button("Delete \(target.title)", role: .destructive) {
                onDeleteChat(target.id)
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: { _ in
            Text("This removes the local chat history from this iPhone.")
        }
    }

    private var filteredSummaries: [ConversationThreadSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return historyController.summaries }

        return historyController.summaries.filter { summary in
            summary.title.localizedCaseInsensitiveContains(query)
                || summary.preview.localizedCaseInsensitiveContains(query)
        }
    }

    private var chatSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search chats", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .frame(minHeight: 44)
                .accessibilityLabel("Search chats")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear chat search")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 12) {
            Image("OpenClamMark")
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            Text("OpenClam")
                .font(.title3.weight(.semibold))

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close sidebar")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }

    private func chatRow(_ summary: ConversationThreadSummary) -> some View {
        HStack(spacing: 8) {
            Button {
                onSelectChat(summary.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(summary.preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(summary.title). \(summary.preview)")
            .accessibilityValue(
                historyController.selectedThreadID == summary.id ? "Selected" : ""
            )
            .accessibilityAddTraits(
                historyController.selectedThreadID == summary.id ? .isSelected : []
            )

            Menu {
                Button {
                    renameTarget = summary
                    renameTitle = summary.title
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    deleteTarget = summary
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Chat options for \(summary.title)")
            .disabled(!canChangeChat)
        }
        .contextMenu {
            Button {
                renameTarget = summary
                renameTitle = summary.title
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTarget = summary
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .disabled(!canChangeChat)
    }
}
