import SwiftUI

enum AgentCommandBoundary: String, CaseIterable, Sendable {
    case answer = "AI answer"
    case localReview = "Review + Confirmed"
    case editableDraft = "Editable draft"
    case localResult = "Local result"
    case deviceShortcut = "Reviewed Shortcut"

    var color: Color {
        switch self {
        case .answer: OpenClamTheme.active
        case .localReview: .orange
        case .editableDraft: OpenClamTheme.active
        case .localResult: .green
        case .deviceShortcut: OpenClamTheme.active
        }
    }

    var systemImage: String {
        switch self {
        case .answer: "sparkles"
        case .localReview: "checkmark.shield.fill"
        case .editableDraft: "square.and.pencil"
        case .localResult: "iphone.gen3"
        case .deviceShortcut: "command.circle.fill"
        }
    }
}

struct AgentCommandCapability: Identifiable, Sendable {
    let id: String
    let title: String
    let example: String
    let detail: String
    let boundary: AgentCommandBoundary
}

struct AgentCommandGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let commands: [AgentCommandCapability]
}

enum AgentCommandCatalog {
    static let groups: [AgentCommandGroup] = [
        .init(
            id: "ask-write",
            title: "Ask & write",
            systemImage: "text.bubble.fill",
            commands: [
                command(
                    "answer",
                    "Answer a question",
                    "Explain why the sky is blue in simple terms.",
                    "The selected AI model answers without running a device action.",
                    .answer
                ),
                command(
                    "email",
                    "Draft an email",
                    "Email Emma saying I’ll be 15 minutes late.",
                    "The editable draft appears first. Tap Find in Contacts locally, then Apple’s Mail composer controls sending.",
                    .editableDraft
                ),
                command(
                    "message",
                    "Draft a message",
                    "Message Alex that I’m outside.",
                    "The editable draft appears first. Tap Find in Contacts locally; the phone number stays on the iPhone and Messages controls sending.",
                    .editableDraft
                ),
                command(
                    "reply",
                    "Suggest a reply",
                    "What should I reply to this message?",
                    "Type text or explicitly share reviewed screenshot OCR, then choose a suggestion before copying.",
                    .editableDraft
                ),
                command(
                    "clipboard-copy",
                    "Copy specific text",
                    "Copy ‘Meet me by the north entrance.’",
                    "The exact replacement is shown before the clipboard changes.",
                    .localReview
                ),
                command(
                    "clipboard-read",
                    "Read the clipboard locally",
                    "Show me what is on my clipboard.",
                    "iOS may ask for paste permission. Clipboard contents stay in the local result and are not returned to the AI provider.",
                    .localReview
                ),
            ]
        ),
        .init(
            id: "find-open",
            title: "Find & open",
            systemImage: "location.fill",
            commands: [
                command(
                    "nearby",
                    "Find something nearby",
                    "Find the nearest McDonald’s.",
                    "The selected AI model proposes the exact query. Location and Apple Maps are accessed only after you tap Search nearby; all results stay on the iPhone.",
                    .localResult
                ),
                command(
                    "maps",
                    "Open a Maps destination",
                    "Open Google Maps for SFO.",
                    "The destination is reviewed before Maps opens; navigation never starts silently.",
                    .localReview
                ),
                command(
                    "uber",
                    "Prepare an Uber ride",
                    "Get me an Uber to SFO.",
                    "The handoff prefills a destination; fare, pickup, payment, and booking remain in Uber.",
                    .localReview
                ),
                command(
                    "secure-link",
                    "Open an explicit secure link",
                    "Open https://open.spotify.com/ in Safari.",
                    "Only an HTTPS link explicitly present in the latest request can be staged.",
                    .localReview
                ),
                command(
                    "contacts",
                    "Search Contacts locally",
                    "Look up Emma in my contacts.",
                    "The exact search is reviewed, and contact details are not returned to the AI provider.",
                    .localReview
                ),
            ]
        ),
        .init(
            id: "organize",
            title: "Plan & remember",
            systemImage: "calendar.badge.clock",
            commands: [
                command(
                    "calendar",
                    "Add a calendar event",
                    "Add dinner tomorrow at 7 PM for 90 minutes.",
                    "The device time zone, start time, and duration appear on the review card before saving.",
                    .localReview
                ),
                command(
                    "dated-alarm",
                    "Schedule a dated alarm",
                    "Set an alarm for next Friday at 7 AM called Airport.",
                    "AlarmKit owns the reviewed alarm on supported iOS versions.",
                    .localReview
                ),
                command(
                    "timer-start",
                    "Start a timer",
                    "Start a 12-minute timer.",
                    "Runs the secret-free Device Actions Shortcut only after review.",
                    .deviceShortcut
                ),
                command(
                    "timer-control",
                    "Pause, resume, or cancel the timer",
                    "Pause the timer.",
                    "Each requested Clock timer operation gets its own review card.",
                    .deviceShortcut
                ),
                command(
                    "clock-alarm",
                    "Set or disable a Clock alarm",
                    "Set a Clock alarm for 7:30 AM called Wake up.",
                    "Clock alarms use the next occurrence of a local wall-clock time and require the Device Actions Shortcut.",
                    .deviceShortcut
                ),
            ]
        ),
        .init(
            id: "device",
            title: "Control this iPhone",
            systemImage: "iphone.gen3.radiowaves.left.and.right",
            commands: [
                command(
                    "flashlight",
                    "Turn the flashlight on or off",
                    "Turn on the flashlight.",
                    "The reviewed action uses either the foreground camera torch or the installed Device Actions Shortcut.",
                    .localReview
                ),
                command(
                    "low-power",
                    "Change Low Power Mode",
                    "Turn on Low Power Mode.",
                    "Runs the exact allowlisted Device Actions branch after review.",
                    .deviceShortcut
                ),
                command(
                    "control-center",
                    "Open or close Control Center",
                    "Open Control Center.",
                    "Runs the exact allowlisted Device Actions branch after review.",
                    .deviceShortcut
                ),
                command(
                    "home-screen",
                    "Go to the Home Screen",
                    "Go to my Home Screen.",
                    "Runs the exact allowlisted Device Actions branch after review.",
                    .deviceShortcut
                ),
                command(
                    "phone-call",
                    "Prepare a phone call",
                    "Call +1 415 555 0100.",
                    "The number must appear in the latest request, the app shows it for review, and iOS controls the call.",
                    .localReview
                ),
            ]
        ),
    ]

    static var commands: [AgentCommandCapability] {
        groups.flatMap(\.commands)
    }

    private static func command(
        _ id: String,
        _ title: String,
        _ example: String,
        _ detail: String,
        _ boundary: AgentCommandBoundary
    ) -> AgentCommandCapability {
        .init(id: id, title: title, example: example, detail: detail, boundary: boundary)
    }
}
