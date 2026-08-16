import SwiftUI

enum CapabilitySupport: String, CaseIterable {
    case native = "Native"
    case consent = "Native + consent"
    case handoff = "Review / handoff"
    case shortcut = "Apple Shortcut"
    case unavailable = "Not public API"

    var color: Color {
        switch self {
        case .native: .green
        case .consent: .blue
        case .handoff: .orange
        case .shortcut: .purple
        case .unavailable: .red
        }
    }

    var systemImage: String {
        switch self {
        case .native: "checkmark.seal.fill"
        case .consent: "person.badge.key.fill"
        case .handoff: "hand.raised.fill"
        case .shortcut: "command.circle.fill"
        case .unavailable: "nosign"
        }
    }
}

struct Capability: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let support: CapabilitySupport
    let permission: String

    static let matrix: [Capability] = [
        .init(
            title: "Open-ended AI questions and tool planning",
            detail: "Uses the official HTTPS endpoint and model configured in the AI tab. Requests start only from a user-driven app flow.",
            support: .consent,
            permission: "User-supplied provider key in iOS Keychain"
        ),
        .init(
            title: "Nearby place search",
            detail: "The AI can propose an exact nearby query, but Location and Apple Maps are accessed only after you tap Search nearby. Location and results stay on this iPhone.",
            support: .consent,
            permission: "Location While Using the App"
        ),
        .init(
            title: "Selected screenshot OCR and reply suggestions",
            detail: "Recognizes a selected image on-device. Recognized text is sent to the configured AI provider only after a separate explicit tap.",
            support: .consent,
            permission: "Selected Photos"
        ),
        .init(
            title: "Explicitly sent attachments",
            detail: "Selecting a photo, video, or supported file only stages it locally. The typed instruction and selected items go once to the configured AI provider only after you tap Send; videos are represented by sampled still frames without audio.",
            support: .consent,
            permission: "Selected Photos or Files"
        ),
        .init(
            title: "Clipboard read and write",
            detail: "Works while the app or its App Intent is active; iOS may show a paste privacy prompt.",
            support: .native,
            permission: "Pasteboard privacy prompt when reading"
        ),
        .init(
            title: "Local Contacts search and reviewed sharing",
            detail: "Contacts is searched locally only after approval. Results stay on this iPhone unless you select exact fields and confirm a one-time share to the configured AI provider. Contact notes are unavailable without Apple’s protected entitlement.",
            support: .consent,
            permission: "Contacts"
        ),
        .init(
            title: "Calendar search and event changes",
            detail: "Creates a reviewed event with write-only access. Search, edit, and delete use full Calendar access, local result selection, and a separate reviewed change.",
            support: .consent,
            permission: "Write-only or Full Calendar access"
        ),
        .init(
            title: "Reminders search and changes",
            detail: "Searches reminders locally and creates, edits, completes, reopens, or deletes only a reviewed item using EventKit.",
            support: .consent,
            permission: "Full Reminders access"
        ),
        .init(
            title: "App-owned alarms",
            detail: "AlarmKit on iOS 26+ can schedule prominent alarms owned by this app. It cannot edit Clock app alarms.",
            support: .consent,
            permission: "Alarms (iOS 26+)"
        ),
        .init(
            title: "Maps, websites, Spotify, Uber, and DoorDash",
            detail: "Uses public universal links or URL schemes and leaves the final action to the destination app.",
            support: .handoff,
            permission: "Destination app confirmation"
        ),
        .init(
            title: "Mail, Messages, and phone",
            detail: "Opens an editable email/message composer or a system-confirmed call. The app never presses Send or starts a call silently.",
            support: .handoff,
            permission: "User confirmation"
        ),
        .init(
            title: "Flashlight",
            detail: "Uses the camera torch while OpenClam is in the foreground.",
            support: .consent,
            permission: "Camera"
        ),
        .init(
            title: "Selected or shared screen context",
            detail: "Choose a screenshot in OpenClam or explicitly share supported text, a public web link, or an image into its review screen. Nothing is sent until you choose exactly what to include and tap Send.",
            support: .consent,
            permission: "Selected Photos or Share Sheet"
        ),
        .init(
            title: "Clock alarms, Home Screen, Low Power, Control Center",
            detail: "The secret-free Device Actions Shortcut can run these only after the app presents the exact review card and you tap Confirmed.",
            support: .shortcut,
            permission: "Per-action Shortcuts prompts"
        ),
        .init(
            title: "Live, silent, or always-on cross-app screen reading",
            detail: "This TestFlight build includes no live screen capture. Public iOS APIs do not allow hidden inspection of other apps, so use an explicit Share Sheet or selected-screenshot handoff.",
            support: .unavailable,
            permission: "Screen Recording capability not included"
        ),
        .init(
            title: "Read Messages history",
            detail: "iOS apps cannot read the Messages database. The upstream Mac helper can read the Mac’s synced database with Full Disk Access.",
            support: .unavailable,
            permission: "Mac-only Full Disk Access in upstream bridge"
        ),
        .init(
            title: "Read contact notes",
            detail: "Apple protects contact notes with a separately approved entitlement. This build does not request that entitlement or fetch contact notes.",
            support: .unavailable,
            permission: "Apple contacts-notes entitlement not requested"
        ),
        .init(
            title: "Arbitrary taps, typing, purchases, rides, and food orders",
            detail: "Public iOS APIs do not grant third-party apps unattended control of other apps or permission to complete consequential transactions.",
            support: .unavailable,
            permission: "Deliberately not requested"
        ),
    ]
}
