import Foundation

enum CommandSource: String, Codable {
    case inApp
    case deepLink
    case appIntent

    var label: String {
        switch self {
        case .inApp: "In app"
        case .deepLink: "Deep link"
        case .appIntent: "Shortcut / Siri"
        }
    }
}

enum AssistantAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case clipboardCopy = "clipboard_copy"
    case clipboardRead = "clipboard_read"
    case openURL = "open_url"
    case mapsDestination = "maps_destination"
    case uberDestination = "uber_destination"
    case messageDraft = "message_draft"
    case mailDraft = "mail_draft"
    case calendarEvent = "calendar_event"
    case alarmSet = "alarm_set"
    case contactsSearch = "contacts_search"
    case flashlightOn = "flashlight_on"
    case flashlightOff = "flashlight_off"
    case phoneCall = "phone_call"
    case shortcutFallback = "shortcut_fallback"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboardCopy: "Copy to clipboard"
        case .clipboardRead: "Read clipboard"
        case .openURL: "Open a URL"
        case .mapsDestination: "Open place in Maps"
        case .uberDestination: "Prefill an Uber ride"
        case .messageDraft: "Draft a message"
        case .mailDraft: "Draft an email"
        case .calendarEvent: "Add calendar event"
        case .alarmSet: "Schedule alarm"
        case .contactsSearch: "Search contacts"
        case .flashlightOn: "Turn flashlight on"
        case .flashlightOff: "Turn flashlight off"
        case .phoneCall: "Open phone call"
        case .shortcutFallback: "Run a Shortcut action"
        }
    }

    var systemImage: String {
        switch self {
        case .clipboardCopy, .clipboardRead: "doc.on.clipboard"
        case .openURL: "safari"
        case .mapsDestination: "map"
        case .uberDestination: "car.side.fill"
        case .messageDraft: "message"
        case .mailDraft: "envelope"
        case .calendarEvent: "calendar.badge.plus"
        case .alarmSet: "alarm"
        case .contactsSearch: "person.crop.circle.badge.questionmark"
        case .flashlightOn, .flashlightOff: "flashlight.on.fill"
        case .phoneCall: "phone"
        case .shortcutFallback: "command"
        }
    }
}

struct AssistantCommand: Identifiable, Codable, Equatable {
    let id: UUID
    let action: AssistantAction
    let parameters: [String: String]
    let source: CommandSource
    let createdAt: Date

    init(
        id: UUID = UUID(),
        action: AssistantAction,
        parameters: [String: String] = [:],
        source: CommandSource = .inApp,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.action = action
        self.parameters = parameters
        self.source = source
        self.createdAt = createdAt
    }

    init(deepLink url: URL) throws {
        let allowedSchemes = ["openclam-livekit-pilot"]
        guard let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme),
              url.host?.lowercased() == "command" else {
            throw CommandValidationError.invalidDeepLink
        }
        guard url.absoluteString.utf8.count <= 8_192 else {
            throw CommandValidationError.commandTooLarge
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CommandValidationError.invalidDeepLink
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                values[item.name] = value
            }
        }
        guard let rawAction = values.removeValue(forKey: "action"),
              let action = AssistantAction(rawValue: rawAction) else {
            throw CommandValidationError.unsupportedAction
        }
        if action == .shortcutFallback {
            guard let rawCommand = values["command"] else {
                throw CommandValidationError.missingParameter("command")
            }
            let validated = try DeviceActionShortcut.validate(rawCommand)
            values = ["command": validated.command]
        }
        self.init(action: action, parameters: values, source: .deepLink)
    }

    var summary: String {
        if action == .shortcutFallback {
            guard let command = parameters["command"],
                  let validated = try? DeviceActionShortcut.validate(command) else {
                return "Invalid Device Actions command"
            }
            return validated.reviewSummary
        }

        return switch action {
        case .clipboardCopy:
            "Replace the clipboard with “\(parameters["text"] ?? "")”"
        case .clipboardRead:
            "Read the clipboard while OpenClam is active"
        case .openURL:
            "Open \(parameters["url"] ?? "a URL")"
        case .mapsDestination:
            "Open directions to \(parameters["destination"] ?? "a destination")"
        case .uberDestination:
            "Open Uber with \(parameters["destination"] ?? "a destination") prefilled"
        case .messageDraft:
            "Draft “\(parameters["body"] ?? "")” to \(parameters["recipient"] ?? "a recipient")"
        case .mailDraft:
            "Draft email “\(parameters["subject"] ?? "No subject")” to \(parameters["recipient"] ?? "a recipient")"
        case .calendarEvent:
            "Add “\(parameters["title"] ?? "Untitled event")” on \(displayDate(parameter: "start")) for \(parameters["duration_minutes"] ?? "60") minutes (\(TimeZone.current.identifier))"
        case .alarmSet:
            "Schedule “\(parameters["label"] ?? "Alarm")” for \(displayDate(parameter: "date")) (\(TimeZone.current.identifier))"
        case .contactsSearch:
            "Search Contacts for “\(parameters["query"] ?? "")”"
        case .flashlightOn:
            "Turn the flashlight on while the app remains active"
        case .flashlightOff:
            "Turn the flashlight off"
        case .phoneCall:
            "Open a system-confirmed call to \(parameters["number"] ?? "a number")"
        case .shortcutFallback:
            "Invalid Device Actions command"
        }
    }

    private func displayDate(parameter name: String) -> String {
        guard let raw = parameters[name] else { return "an unspecified time" }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
            return raw
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

enum CommandValidationError: LocalizedError {
    case invalidDeepLink
    case unsupportedAction
    case commandTooLarge
    case missingParameter(String)
    case invalidParameter(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidDeepLink: "This is not an OpenClam command link."
        case .unsupportedAction: "The requested action is not supported."
        case .commandTooLarge: "The command is larger than the app accepts."
        case .missingParameter(let name): "The command is missing “\(name)”."
        case .invalidParameter(let name): "The “\(name)” value is invalid."
        case .unavailable(let reason): reason
        }
    }
}

extension AssistantCommand {
    func required(_ name: String) throws -> String {
        guard let value = parameters[name], !value.isEmpty else {
            throw CommandValidationError.missingParameter(name)
        }
        return value
    }
}
