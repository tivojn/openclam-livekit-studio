import AppIntents
import Foundation

extension Notification.Name {
    static let pendingAgentPromptDidChange = Notification.Name(
        "CodexCompanion.pendingAgentPromptDidChange"
    )
}

enum PendingAgentPromptError: LocalizedError {
    case empty
    case tooLong

    var errorDescription: String? {
        switch self {
        case .empty: "The question is empty."
        case .tooLong: "The question is longer than 4,000 characters."
        }
    }
}

enum PendingAgentPromptStore {
    static let key = "pendingAgentPrompt"
    static let maximumLength = 4_000

    static func save(_ prompt: String, defaults: UserDefaults = .standard) throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PendingAgentPromptError.empty }
        guard trimmed.count <= maximumLength else { throw PendingAgentPromptError.tooLong }
        defaults.set(trimmed, forKey: key)
        NotificationCenter.default.post(name: .pendingAgentPromptDidChange, object: nil)
    }

    static func take(defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.string(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return value
    }
}

struct AskCodexCompanionIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask OpenClam"
    static let description = IntentDescription(
        "Opens OpenClam with a question ready for you to review and send to your configured AI provider."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
    var question: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try PendingAgentPromptStore.save(question)
        return .result(
            dialog: "I opened OpenClam with your question ready. Review it, then tap Send."
        )
    }
}
