import AVFoundation
import Contacts
import EventKit
import Foundation
import MessageUI
import UIKit

@MainActor
final class AssistantModel: ObservableObject {
    private struct ExecutionOutcome {
        let message: String
        let state: ActivityRecord.State

        static func completed(_ message: String) -> Self {
            .init(message: message, state: .completed)
        }

        static func dispatched(_ message: String) -> Self {
            .init(message: message, state: .dispatched)
        }
    }

    @Published private(set) var pendingCommand: AssistantCommand?
    @Published private(set) var activity: [ActivityRecord] = []
    @Published var messageDraft: MessageDraft?
    @Published var mailDraft: MailDraftContent?
    @Published var lastResult = "No command has run yet."
    @Published private(set) var isExecuting = false

    func restoreStagedCommand() {
        guard pendingCommand == nil, let command = PendingCommandStore.take() else { return }
        stage(command)
    }

    func stage(url: URL) {
        do {
            stage(try AssistantCommand(deepLink: url))
        } catch {
            record(title: "Rejected command link", detail: error.localizedDescription, state: .failed)
        }
    }

    func stage(_ command: AssistantCommand) {
        pendingCommand = command
        lastResult = "Review required before this command can run."
        record(title: command.action.title, detail: command.summary, state: .staged)
    }

    func synchronizeStagedMessageDraft(with replacement: AssistantCommand?) {
        guard let current = pendingCommand, current.action == .messageDraft else { return }
        guard let replacement, replacement.action == .messageDraft else {
            pendingCommand = nil
            lastResult = "The staged message was removed because the editable draft no longer has a valid recipient."
            return
        }

        pendingCommand = .init(
            id: current.id,
            action: .messageDraft,
            parameters: replacement.parameters,
            source: current.source,
            createdAt: current.createdAt
        )
        lastResult = "The pending message was synchronized with the editable draft. Review the updated text, then tap Confirmed."
    }

    func synchronizeStagedMailDraft(with replacement: AssistantCommand?) {
        guard let current = pendingCommand, current.action == .mailDraft else { return }
        guard let replacement, replacement.action == .mailDraft else {
            pendingCommand = nil
            lastResult = "The staged email was removed because the editable draft no longer has a valid recipient."
            return
        }

        pendingCommand = .init(
            id: current.id,
            action: .mailDraft,
            parameters: replacement.parameters,
            source: current.source,
            createdAt: current.createdAt
        )
        lastResult = "The pending email was synchronized with the editable draft. Review the updated subject and body, then tap Confirmed."
    }

    func cancelPending() {
        if let pendingCommand {
            record(title: "Cancelled", detail: pendingCommand.summary, state: .cancelled)
        }
        pendingCommand = nil
        lastResult = "The staged command was cancelled."
    }

    func runPending() async {
        guard !isExecuting, let command = pendingCommand else { return }
        pendingCommand = nil
        _ = await perform(command)
    }

    /// Executes an action the user has already inspected on the Assistant screen.
    /// Unlike `stage`, this deliberately leaves an unrelated deep-link/App Intent
    /// command alone and does not require a second trip through the Command tab.
    @discardableResult
    func runConfirmed(_ command: AssistantCommand) async -> Bool {
        await perform(command)
    }

    @discardableResult
    private func perform(_ command: AssistantCommand) async -> Bool {
        guard !isExecuting else {
            lastResult = "Another confirmed action is still running."
            return false
        }
        isExecuting = true
        defer { isExecuting = false }
        do {
            let outcome = try await execute(command)
            lastResult = outcome.message
            record(title: command.action.title, detail: outcome.message, state: outcome.state)
            return true
        } catch {
            lastResult = error.localizedDescription
            record(title: command.action.title, detail: error.localizedDescription, state: .failed)
            return false
        }
    }

    func finishMessageDraft(_ result: MessageComposeResult) {
        messageDraft = nil
        let outcome: (String, ActivityRecord.State)
        switch result {
        case .cancelled:
            outcome = ("The message draft was cancelled.", .cancelled)
        case .sent:
            outcome = ("Messages queued or sent the message; delivery is not verified.", .dispatched)
        case .failed:
            outcome = ("Messages could not queue or send the message.", .failed)
        @unknown default:
            outcome = ("Messages closed with an unknown result.", .failed)
        }
        lastResult = outcome.0
        record(title: "Message composer", detail: outcome.0, state: outcome.1)
    }

    func finishMailDraft(_ event: MailComposeEvent) {
        let outcome: (String, ActivityRecord.State, Bool)
        switch event {
        case .unavailable(let message):
            outcome = (message, .failed, false)
        case .fallbackCopied:
            outcome = ("The email draft was copied from the fallback screen. Nothing was sent.", .completed, true)
        case .finished(let result):
            switch result {
            case .cancelled:
                outcome = ("The email draft was cancelled.", .cancelled, true)
            case .saved:
                outcome = ("Mail saved the draft. Nothing was reported as sent.", .completed, true)
            case .submitted:
                outcome = ("Mail accepted the send request; delivery is not verified.", .dispatched, true)
            case .failed(let message):
                outcome = (message, .failed, true)
            }
        }
        if outcome.2 { mailDraft = nil }
        lastResult = outcome.0
        record(title: "Mail composer", detail: outcome.0, state: outcome.1)
    }

    private func execute(_ command: AssistantCommand) async throws -> ExecutionOutcome {
        switch command.action {
        case .clipboardCopy:
            UIPasteboard.general.string = try command.required("text")
            return .completed("Clipboard text replaced.")

        case .clipboardRead:
            let value = UIPasteboard.general.string ?? ""
            return .completed(value.isEmpty ? "The clipboard is empty." : "Clipboard: \(value)")

        case .openURL:
            let rawURL = try command.required("url")
            guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(),
                  ["https", "http"].contains(scheme) else {
                throw CommandValidationError.invalidParameter("url")
            }
            guard await open(url) else {
                throw CommandValidationError.unavailable("iOS could not open that URL.")
            }
            return .dispatched("iOS accepted the reviewed URL; the destination app’s result is not verified.")

        case .mapsDestination:
            let destination = try command.required("destination")
            let url = try GoogleMapsURLBuilder.drivingDirections(to: destination)
            guard await open(url) else {
                throw CommandValidationError.unavailable("Google Maps or the web fallback could not open that destination.")
            }
            return .dispatched("iOS accepted the Maps handoff; the place result is not verified and navigation remains under your control.")

        case .uberDestination:
            let destination = try command.required("destination")
            guard let latitude = Double(try command.required("latitude")),
                  (-90 ... 90).contains(latitude),
                  let longitude = Double(try command.required("longitude")),
                  (-180 ... 180).contains(longitude) else {
                throw CommandValidationError.invalidParameter("latitude / longitude")
            }
            let queryItems = [
                URLQueryItem(name: "pickup", value: "my_location"),
                URLQueryItem(name: "dropoff[latitude]", value: String(latitude)),
                URLQueryItem(name: "dropoff[longitude]", value: String(longitude)),
                URLQueryItem(name: "dropoff[nickname]", value: destination),
                URLQueryItem(name: "dropoff[formatted_address]", value: command.parameters["address"] ?? destination),
            ]
            var native = URLComponents(string: "uber://riderequest")
            native?.queryItems = queryItems
            if let url = native?.url, await open(url) {
                return .dispatched("iOS accepted the Uber handoff with a destination prefilled; fare, pickup, payment, and booking still require you.")
            }

            let web = URLComponents(string: "https://m.uber.com/")
            guard let url = web?.url, await open(url) else {
                throw CommandValidationError.unavailable("Uber or its web fallback could not open.")
            }
            return .dispatched("Uber is not installed, so iOS opened Uber’s website without a verified destination prefill. Enter and confirm the destination, fare, pickup, payment, and booking there.")

        case .messageDraft:
            guard MFMessageComposeViewController.canSendText() else {
                throw CommandValidationError.unavailable("Messages composition is unavailable on this device.")
            }
            let recipient = try await resolvedMessageRecipient(try command.required("recipient"))
            messageDraft = MessageDraft(
                recipient: recipient,
                body: command.parameters["body"] ?? ""
            )
            return .dispatched("Presented an unsent message draft. Messages will report whether you cancel, fail, or queue/send it; delivery is never inferred.")

        case .mailDraft:
            mailDraft = try MailDraftContent(
                recipientName: command.parameters["recipient_name"],
                recipient: try command.required("recipient"),
                subject: command.parameters["subject"] ?? "",
                body: command.parameters["body"] ?? ""
            )
            return .dispatched("Presented an editable, unsent email draft. Mail controls save/send/cancel, and delivery is never inferred.")

        case .calendarEvent:
            let title = try command.required("title")
            let start = try parsedDate(try command.required("start"))
            guard let durationMinutes = Int(command.parameters["duration_minutes"] ?? "60"),
                  (1 ... 10_080).contains(durationMinutes) else {
                throw CommandValidationError.invalidParameter("duration_minutes")
            }
            let duration = TimeInterval(durationMinutes) * 60
            let store = EKEventStore()
            guard try await store.requestWriteOnlyAccessToEvents() else {
                throw CommandValidationError.unavailable("Calendar write access was not granted.")
            }
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = start.addingTimeInterval(duration)
            event.notes = "Created after review in OpenClam."
            event.calendar = store.defaultCalendarForNewEvents
            try store.save(event, span: .thisEvent, commit: true)
            return .completed("Added “\(title)” to Calendar.")

        case .alarmSet:
            let label = command.parameters["label"] ?? "OpenClam alarm"
            let date = try parsedDate(try command.required("date"))
            guard date > Date() else {
                throw CommandValidationError.invalidParameter("date")
            }
            try await AlarmService.schedule(date: date, label: label)
            return .completed("Scheduled “\(label)” with AlarmKit.")

        case .contactsSearch:
            let query = try command.required("query")
            let names = try await contactNames(matching: query)
            return .completed(names.isEmpty ? "No matching contacts." : "Matches: \(names.joined(separator: ", "))")

        case .flashlightOn:
            try setTorch(enabled: true)
            return .completed("Flashlight enabled. It may turn off when the app leaves the foreground.")

        case .flashlightOff:
            try setTorch(enabled: false)
            return .completed("Flashlight disabled.")

        case .phoneCall:
            let number = try command.required("number")
            let allowed = CharacterSet(charactersIn: "+0123456789-() ")
            guard number.unicodeScalars.allSatisfy(allowed.contains) else {
                throw CommandValidationError.invalidParameter("number")
            }
            let digits = number.filter { "+0123456789".contains($0) }
            guard digits.filter(\.isNumber).count >= 3 else {
                throw CommandValidationError.invalidParameter("number")
            }
            guard let url = URL(string: "tel:\(digits)"), await open(url) else {
                throw CommandValidationError.unavailable("Phone could not open that number.")
            }
            return .dispatched("iOS accepted the phone handoff; the system still controls call confirmation.")

        case .shortcutFallback:
            let validated = try DeviceActionShortcut.validate(command.required("command"))
            var components = URLComponents(string: "shortcuts://run-shortcut")
            components?.queryItems = [
                URLQueryItem(name: "name", value: DeviceActionShortcut.name),
                URLQueryItem(name: "input", value: "text"),
                URLQueryItem(name: "text", value: validated.command),
            ]
            guard let url = components?.url, await open(url) else {
                throw CommandValidationError.unavailable("The Device Actions Shortcut could not be opened.")
            }
            return .dispatched("iOS accepted the reviewed handoff to \(DeviceActionShortcut.name); Shortcut execution is not verified here.")
        }
    }

    private func parsedDate(_ value: String?) throws -> Date {
        guard let value else { return Date().addingTimeInterval(3_600) }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) {
            return date
        }
        throw CommandValidationError.invalidParameter("date")
    }

    private func contactNames(matching query: String) async throws -> [String] {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined, try await !store.requestAccess(for: .contacts) {
            throw CommandValidationError.unavailable("Contacts access was not granted.")
        }
        let current = CNContactStore.authorizationStatus(for: .contacts)
        let hasAccess: Bool
        if #available(iOS 18.0, *), current == .limited {
            hasAccess = true
        } else {
            hasAccess = current == .authorized
        }
        guard hasAccess else {
            throw CommandValidationError.unavailable("Contacts access is disabled in Settings.")
        }
        let predicate = CNContact.predicateForContacts(matchingName: query)
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        return contacts.prefix(10).compactMap { CNContactFormatter.string(from: $0, style: .fullName) }
    }

    private func resolvedMessageRecipient(_ rawValue: String) async throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("@") || value.filter(\.isNumber).count >= 3 {
            return value
        }

        let candidates = try await ContactPhoneResolver.resolve(name: value)
        guard let candidate = candidates.first else {
            throw CommandValidationError.unavailable(
                "No saved phone number matched “\(value)”. Use the Assistant tab to choose or enter a recipient."
            )
        }
        guard candidates.count == 1,
              ContactPhoneResolver.isExactNameMatch(query: value, displayName: candidate.displayName) else {
            throw CommandValidationError.unavailable(
                "No single exact saved contact matched “\(value)”. Use the Assistant tab to choose one."
            )
        }
        return candidate.phoneNumber
    }

    private func setTorch(enabled: Bool) throws {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            throw CommandValidationError.unavailable("This device has no controllable torch.")
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if enabled {
            try device.setTorchModeOn(level: min(0.8, AVCaptureDevice.maxAvailableTorchLevel))
        } else {
            device.torchMode = .off
        }
    }

    private func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { continuation.resume(returning: $0) }
        }
    }

    private func record(title: String, detail: String, state: ActivityRecord.State) {
        activity.insert(.init(date: Date(), title: title, detail: detail, state: state), at: 0)
        if activity.count > 30 {
            activity.removeLast(activity.count - 30)
        }
    }
}
