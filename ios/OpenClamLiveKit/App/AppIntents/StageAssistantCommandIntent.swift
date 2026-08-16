import AppIntents
import Foundation

extension AssistantAction: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Companion action")

    static let caseDisplayRepresentations: [AssistantAction: DisplayRepresentation] = [
        .clipboardCopy: "Copy to clipboard",
        .clipboardRead: "Read clipboard",
        .openURL: "Open URL",
        .mapsDestination: "Open place in Maps",
        .uberDestination: "Prefill Uber ride",
        .messageDraft: "Draft message",
        .mailDraft: "Draft email",
        .calendarEvent: "Add calendar event",
        .alarmSet: "Schedule alarm",
        .contactsSearch: "Search contacts",
        .flashlightOn: "Flashlight on",
        .flashlightOff: "Flashlight off",
        .phoneCall: "Open phone call",
        .shortcutFallback: "Run Device Action",
    ]
}

struct StageAssistantCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Review OpenClam Command"
    static let description = IntentDescription(
        "Opens the exact command review in OpenClam. It never runs the command silently."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Action")
    var action: AssistantAction

    @Parameter(title: "Primary value", description: "Text, recipient, destination, date, or contact query.")
    var primaryValue: String?

    @Parameter(title: "Secondary value", description: "Optional message body, event title, or alarm label.")
    var secondaryValue: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let value = primaryValue ?? ""
        let secondary = secondaryValue ?? ""
        let parameters: [String: String]
        switch action {
        case .clipboardCopy:
            parameters = ["text": value]
        case .clipboardRead, .flashlightOn, .flashlightOff:
            parameters = [:]
        case .openURL:
            parameters = ["url": value]
        case .mapsDestination:
            parameters = ["destination": value]
        case .uberDestination:
            let parts = secondary.split(separator: ",", maxSplits: 1).map(String.init)
            parameters = [
                "destination": value,
                "latitude": parts.first ?? "",
                "longitude": parts.count > 1 ? parts[1] : "",
            ]
        case .messageDraft:
            parameters = ["recipient": value, "body": secondary]
        case .mailDraft:
            parameters = ["recipient": value, "subject": "", "body": secondary]
        case .calendarEvent:
            parameters = ["title": secondary.isEmpty ? "OpenClam event" : secondary]
                .merging(value.isEmpty ? [:] : ["start": value]) { current, _ in current }
        case .alarmSet:
            parameters = ["date": value, "label": secondary.isEmpty ? "OpenClam alarm" : secondary]
        case .contactsSearch:
            parameters = ["query": value]
        case .phoneCall:
            parameters = ["number": value]
        case .shortcutFallback:
            let validated = try DeviceActionShortcut.validate(value)
            parameters = ["command": validated.command]
        }
        let command = AssistantCommand(action: action, parameters: parameters, source: .appIntent)
        PendingCommandStore.save(command)
        return .result(dialog: "Review \(action.title) in OpenClam, then tap Confirmed to run it.")
    }
}

struct CodexCompanionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskCodexCompanionIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Ask OpenClam",
            systemImageName: "brain.head.profile"
        )
        AppShortcut(
            intent: StageAssistantCommandIntent(),
            phrases: ["Review an iPhone command in \(.applicationName)"],
            shortTitle: "Review iPhone command",
            systemImageName: "iphone.gen3.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: PrepareScreenContextIntent(),
            phrases: [
                "Prepare screen context in \(.applicationName)",
                "Open screen context in \(.applicationName)",
            ],
            shortTitle: "Prepare Screen Context",
            systemImageName: "rectangle.dashed.badge.record"
        )
        AppShortcut(
            intent: ReceiveScreenContextIntent(),
            phrases: ["Review shared context in \(.applicationName)"],
            shortTitle: "Review Shared Context",
            systemImageName: "square.and.arrow.down"
        )
        AppShortcut(
            intent: AskOpenClamAboutScreenIntent(),
            phrases: ["Ask \(.applicationName) about this screenshot"],
            shortTitle: "Ask About Screen",
            systemImageName: "rectangle.and.text.magnifyingglass"
        )
        AppShortcut(
            intent: ResetScreenPTTSessionIntent(),
            phrases: ["Reset screen PTT in \(.applicationName)"],
            shortTitle: "Reset Screen PTT",
            systemImageName: "arrow.counterclockwise"
        )
#if OPENCLAM_LIVE_SCREEN_CONTEXT
        AppShortcut(
            intent: AskAboutCurrentScreenIntent(),
            phrases: ["Ask \(.applicationName) about this screen"],
            shortTitle: "Ask About Current Screen",
            systemImageName: "rectangle.and.text.magnifyingglass"
        )
#endif
    }
}

// `ReviewScreenshotAndDictationIntent` deliberately remains a discoverable Shortcuts action
// instead of a Siri phrase here. A phrase cannot provide another app's pixels; the action must be
// connected after Apple's explicit Take Screenshot and Dictate Text actions in a user Shortcut.
