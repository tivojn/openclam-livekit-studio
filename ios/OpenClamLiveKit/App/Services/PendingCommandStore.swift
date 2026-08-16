import Foundation

extension Notification.Name {
    static let pendingCommandDidChange = Notification.Name(
        "CodexCompanion.pendingCommandDidChange"
    )
}

enum PendingCommandStore {
    private static let key = "openclam.livekitpilot.pendingCommand"

    static func save(
        _ command: AssistantCommand,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: .pendingCommandDidChange, object: nil)
    }

    static func take(defaults: UserDefaults = .standard) -> AssistantCommand? {
        guard let data = defaults.data(forKey: key),
              let command = try? JSONDecoder().decode(AssistantCommand.self, from: data) else {
            return nil
        }
        defaults.removeObject(forKey: key)
        return command
    }
}
