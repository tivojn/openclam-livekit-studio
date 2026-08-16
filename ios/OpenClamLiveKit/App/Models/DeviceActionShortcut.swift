import Foundation

struct ValidatedDeviceAction: Equatable, Sendable {
    let command: String
    let reviewSummary: String
}

enum DeviceActionShortcut {
    // This separately installed Shortcut keeps its original exact name so existing
    // Build 8 installations continue to work after the OpenClam app rename.
    static let name = "Codex Companion Device Actions"

    private static let fixedReviewSummaries = [
        "hola timer pause": "Pause the current Clock timer",
        "hola timer resume": "Resume the current Clock timer",
        "hola timer cancel": "Cancel the current Clock timer",
        "hola lowpower on": "Turn Low Power Mode on",
        "hola lowpower off": "Turn Low Power Mode off",
        "hola controlcenter open": "Show Control Center",
        "hola controlcenter close": "Close Control Center",
        "hola homescreen": "Go to the Home Screen",
        "hola flashlight on": "Turn the flashlight on",
        "hola flashlight off": "Turn the flashlight off",
    ]

    /// All 20 top-level source-template branch tokens. Alarm labels may contain
    /// ordinary uses of “hola”, but never a complete second branch token.
    private static let reservedBranchTokens = [
        "hola timer start", "hola timer pause", "hola timer resume", "hola timer cancel",
        "hola flashlight on", "hola flashlight off", "hola call", "hola lowpower on",
        "hola lowpower off", "hola copytoclipboard", "hola getclipboard",
        "hola controlcenter open", "hola controlcenter close", "hola openurl",
        "hola screentext", "hola screenshot", "hola homescreen", "hola alarm get",
        "hola alarm set", "hola alarm off",
    ]

    static func timerCommand(operation: String, durationSeconds: Int) throws -> String {
        switch operation {
        case "start":
            guard 1 ... 86_400 ~= durationSeconds else {
                throw CommandValidationError.invalidParameter("duration_seconds")
            }
            return "hola timer start \(durationSeconds)"
        case "pause", "resume", "cancel":
            guard durationSeconds == 0 else {
                throw CommandValidationError.invalidParameter("duration_seconds")
            }
            return "hola timer \(operation)"
        default:
            throw CommandValidationError.invalidParameter("operation")
        }
    }

    static func systemCommand(operation: String) throws -> String {
        switch operation {
        case "low_power_on": "hola lowpower on"
        case "low_power_off": "hola lowpower off"
        case "control_center_open": "hola controlcenter open"
        case "control_center_close": "hola controlcenter close"
        case "home_screen": "hola homescreen"
        case "flashlight_on": "hola flashlight on"
        case "flashlight_off": "hola flashlight off"
        default: throw CommandValidationError.invalidParameter("operation")
        }
    }

    /// The shareable Shortcut creates a Clock alarm for the next occurrence of a
    /// local wall-clock time. It does not carry a calendar date.
    static func alarmCommand(
        operation: String,
        time24h: String,
        label: String
    ) throws -> String {
        let time = try validatedTime24h(time24h)
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)

        switch operation {
        case "set":
            try validateAlarmLabel(trimmed, parameter: "label", allowEmpty: true)
            return "hola alarm set \(time) \(trimmed.isEmpty ? "OpenClam alarm" : trimmed)"
        case "disable":
            guard trimmed.isEmpty else {
                throw CommandValidationError.invalidParameter("label")
            }
            return "hola alarm off \(time)"
        default:
            throw CommandValidationError.invalidParameter("operation")
        }
    }

    static func commandParameters(_ command: String) -> [String: String] {
        ["command": command]
    }

    /// Re-parses the complete command at every trust boundary. Only commands
    /// implemented by the secret-free Device Actions Shortcut are accepted.
    static func validate(_ rawCommand: String) throws -> ValidatedDeviceAction {
        if let reviewSummary = fixedReviewSummaries[rawCommand] {
            return .init(command: rawCommand, reviewSummary: reviewSummary)
        }

        let timerPrefix = "hola timer start "
        if rawCommand.hasPrefix(timerPrefix) {
            let rawSeconds = String(rawCommand.dropFirst(timerPrefix.count))
            guard !rawSeconds.isEmpty,
                  rawSeconds.unicodeScalars.allSatisfy(isASCIIDigit),
                  rawSeconds.first != "0",
                  let seconds = Int(rawSeconds),
                  1 ... 86_400 ~= seconds,
                  rawCommand == "\(timerPrefix)\(seconds)" else {
                throw CommandValidationError.invalidParameter("command")
            }
            return .init(
                command: rawCommand,
                reviewSummary: "Start a Clock timer for \(seconds) seconds"
            )
        }

        let alarmSetPrefix = "hola alarm set "
        if rawCommand.hasPrefix(alarmSetPrefix) {
            let remainder = String(rawCommand.dropFirst(alarmSetPrefix.count))
            guard remainder.count >= 7 else {
                throw CommandValidationError.invalidParameter("command")
            }
            let time = String(remainder.prefix(5))
            guard remainder.dropFirst(5).first == " " else {
                throw CommandValidationError.invalidParameter("command")
            }
            let label = String(remainder.dropFirst(6))
            _ = try validatedTime24h(time)
            guard label == label.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw CommandValidationError.invalidParameter("command")
            }
            try validateAlarmLabel(label, parameter: "command", allowEmpty: false)
            return .init(
                command: rawCommand,
                reviewSummary: "Create a Clock alarm for the next occurrence of \(time), labeled “\(label)”"
            )
        }

        let alarmOffPrefix = "hola alarm off "
        if rawCommand.hasPrefix(alarmOffPrefix) {
            let time = String(rawCommand.dropFirst(alarmOffPrefix.count))
            _ = try validatedTime24h(time)
            return .init(
                command: rawCommand,
                reviewSummary: "Disable every enabled Clock alarm at \(time); alarm labels are not checked"
            )
        }

        throw CommandValidationError.invalidParameter("command")
    }

    private static func validatedTime24h(_ rawTime: String) throws -> String {
        let characters = Array(rawTime)
        guard characters.count == 5,
              characters[2] == ":",
              rawTime.unicodeScalars.enumerated().allSatisfy({ offset, scalar in
                  offset == 2 ? scalar == ":" : isASCIIDigit(scalar)
              }),
              let hour = Int(String(characters[0 ... 1])),
              let minute = Int(String(characters[3 ... 4])),
              0 ... 23 ~= hour,
              0 ... 59 ~= minute else {
            throw CommandValidationError.invalidParameter("time_24h")
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48 ... 57).contains(scalar.value)
    }

    /// Each source Shortcut branch is an independent text condition. Keeping
    /// the reserved command token out of free-form labels prevents one
    /// reviewed alarm command from also matching a second device branch.
    private static func validateAlarmLabel(
        _ label: String,
        parameter: String,
        allowEmpty: Bool
    ) throws {
        guard (allowEmpty || !label.isEmpty),
              label.count <= 100,
              label.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              !reservedBranchTokens.contains(where: { token in
                  label.range(
                      of: token,
                      options: [.caseInsensitive, .diacriticInsensitive]
                  ) != nil
              }) else {
            throw CommandValidationError.invalidParameter(parameter)
        }
    }
}
