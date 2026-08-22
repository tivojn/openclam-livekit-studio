import Combine
import Foundation

/// Main-actor adapter for sidebar and ConversationModel integration. The UI reads `summaries`
/// and `selectedMessages`; it asks ConversationModel to display the latter when selection changes,
/// then calls `saveSelectedMessages` after each completed turn.
@MainActor
final class ConversationHistoryController: ObservableObject {
    @Published private(set) var state: ConversationHistoryState = .empty
    @Published private(set) var errorMessage: String?

    let store: ConversationHistoryStore

    init(store: ConversationHistoryStore = ConversationHistoryStore()) {
        self.store = store
    }

    var summaries: [ConversationThreadSummary] { state.summaries }
    var selectedThreadID: UUID? { state.selectedThreadID }
    var selectedThread: ConversationThread? { state.selectedThread }
    var selectedMessages: [ConversationMessage] { selectedThread?.messages ?? [] }
    var allMessages: [ConversationMessage] { state.threads.flatMap(\.messages) }

    func messages(in threadID: UUID) -> [ConversationMessage] {
        state.threads.first(where: { $0.id == threadID })?.messages ?? []
    }

    @discardableResult
    func start(initialMessages: [ConversationMessage] = []) async -> ConversationHistoryState? {
        await perform {
            try await store.bootstrap(initialMessages: initialMessages)
        }
    }

    @discardableResult
    func newChat(initialMessages: [ConversationMessage] = []) async -> ConversationHistoryState? {
        await perform {
            try await store.createThread(initialMessages: initialMessages)
        }
    }

    @discardableResult
    func selectChat(id: UUID) async -> ConversationHistoryState? {
        await perform {
            try await store.selectThread(id: id)
        }
    }

    @discardableResult
    func saveSelectedMessages(_ messages: [ConversationMessage]) async -> ConversationHistoryState? {
        guard let selectedThreadID else {
            errorMessage = ConversationHistoryStoreError.threadNotFound.localizedDescription
            return nil
        }
        return await perform {
            try await store.replaceMessages(messages, in: selectedThreadID)
        }
    }

    @discardableResult
    func renameChat(id: UUID, title: String) async -> ConversationHistoryState? {
        await perform {
            try await store.renameThread(id: id, title: title)
        }
    }

    @discardableResult
    func deleteChat(
        id: UUID,
        replacementMessages: [ConversationMessage] = []
    ) async -> ConversationHistoryState? {
        await perform {
            try await store.deleteThread(
                id: id,
                replacementMessages: replacementMessages
            )
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func perform(
        _ operation: () async throws -> ConversationHistoryState
    ) async -> ConversationHistoryState? {
        do {
            let nextState = try await operation()
            state = nextState
            errorMessage = await store.takeRecoveryWarning()?.localizedDescription
            return nextState
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
