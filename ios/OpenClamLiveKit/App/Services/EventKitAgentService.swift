import EventKit
import Foundation

@MainActor
final class EventKitOneShotRegistry<Value> {
    private struct Entry {
        let value: Value
        let issuedAt: Date
    }

    private let tokenLifetime: TimeInterval
    private let maximumEntries: Int
    private let now: () -> Date
    private var entries: [UUID: Entry] = [:]

    init(
        tokenLifetime: TimeInterval = 10 * 60,
        maximumEntries: Int = 100,
        now: @escaping () -> Date = Date.init
    ) {
        self.tokenLifetime = max(1, tokenLifetime)
        self.maximumEntries = max(1, maximumEntries)
        self.now = now
    }

    var count: Int { entries.count }

    func issue(_ value: Value) -> EventKitLocalSelectionToken {
        pruneExpired()
        if entries.count >= maximumEntries,
           let oldest = entries.min(by: { $0.value.issuedAt < $1.value.issuedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        let token = EventKitLocalSelectionToken()
        entries[token.rawValue] = Entry(value: value, issuedAt: now())
        return token
    }

    func consume(_ token: EventKitLocalSelectionToken) throws -> Value {
        guard let entry = entries.removeValue(forKey: token.rawValue) else {
            throw EventKitAgentError.localSelectionMissing
        }
        guard now().timeIntervalSince(entry.issuedAt) < tokenLifetime else {
            throw EventKitAgentError.localSelectionExpired
        }
        return entry.value
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    private func pruneExpired() {
        let cutoff = now().addingTimeInterval(-tokenLifetime)
        entries = entries.filter { $0.value.issuedAt > cutoff }
    }
}

@MainActor
final class EventKitAgentService {
    static let shared = EventKitAgentService()

    private struct CalendarSelection {
        let event: EKEvent
        let fingerprint: CalendarEventFingerprint
    }

    private struct ReminderSelection {
        let reminder: EKReminder
        let fingerprint: ReminderFingerprint
    }

    private let eventStore: EKEventStore
    private let calendarSelections: EventKitOneShotRegistry<CalendarSelection>
    private let reminderSelections: EventKitOneShotRegistry<ReminderSelection>

    init(
        eventStore: EKEventStore = EKEventStore(),
        tokenLifetime: TimeInterval = 10 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.eventStore = eventStore
        calendarSelections = EventKitOneShotRegistry(tokenLifetime: tokenLifetime, now: now)
        reminderSelections = EventKitOneShotRegistry(tokenLifetime: tokenLifetime, now: now)
    }

    func searchCalendar(
        _ request: EventKitCalendarSearchRequest
    ) async throws -> [EventKitCalendarEventCandidate] {
        try await requireFullEventAccess()
        let calendars = try calendarsForSearch(named: request.calendarName, entity: .event)
        let predicate = eventStore.predicateForEvents(
            withStart: request.rangeStart,
            end: request.rangeEnd,
            calendars: calendars
        )
        let query = Self.normalizedSearchText(request.query)
        let events = eventStore.events(matching: predicate)
            .prefix(EventKitAgentLimits.maximumScannedItems)
            .filter { event in
                guard !query.isEmpty else { return true }
                return [event.title, event.location, event.notes]
                    .compactMap { $0 }
                    .contains { Self.normalizedSearchText($0).contains(query) }
            }
            .sorted { left, right in
                if left.startDate != right.startDate { return left.startDate < right.startDate }
                if left.endDate != right.endDate { return left.endDate < right.endDate }
                return (left.title ?? "").localizedCaseInsensitiveCompare(right.title ?? "") == .orderedAscending
            }

        calendarSelections.removeAll()
        var candidates: [EventKitCalendarEventCandidate] = []
        for event in events.prefix(request.limit) {
            guard let candidate = makeCalendarCandidate(event) else { continue }
            candidates.append(candidate)
        }
        return candidates
    }

    func createCalendarEvent(
        _ draft: EventKitCalendarEventDraft
    ) async throws -> EventKitAgentMutationReceipt {
        if draft.calendarName == nil {
            try await requireEventCreationAccess()
        } else {
            try await requireFullEventAccess()
        }

        let calendar = try resolveWritableCalendar(named: draft.calendarName, entity: .event)
        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = draft.title
        try apply(schedule: draft.schedule, to: event)
        event.location = draft.location
        event.notes = draft.notes
        event.url = draft.url
        try apply(availability: draft.availability, to: event, calendar: calendar)
        event.recurrenceRules = draft.recurrence.map { [EventKitAgentMapper.recurrenceRule(from: $0)] }
        event.alarms = EventKitAgentMapper.eventAlarms(
            minutesBeforeStart: draft.alertMinutesBeforeStart
        )

        try save(event, span: .thisEvent)
        return EventKitAgentMutationReceipt(
            entity: .calendarEvent,
            operation: .created,
            title: draft.title,
            containerTitle: calendar.title
        )
    }

    func updateCalendarEvent(
        token: EventKitLocalSelectionToken,
        patch: EventKitCalendarEventPatch,
        scope: EventKitRecurringEventScope = .thisEvent
    ) async throws -> EventKitAgentMutationReceipt {
        try await requireFullEventAccess()
        let event = try consumeCalendarEvent(token)
        guard event.calendar.allowsContentModifications else {
            throw EventKitAgentError.readOnlyCalendar(event.calendar.title)
        }
        let alarmInspection = EventKitAgentMapper.inspectEventAlarms(event.alarms)
        guard alarmInspection.isSafeForEditing else {
            throw EventKitAgentError.unsupportedExistingAlarms(
                alarmInspection.unsupportedAlarmCount
            )
        }
        guard patch.hasChanges else {
            throw EventKitAgentError.invalidField("event update", "provide at least one change")
        }

        let destination = try destinationCalendar(for: patch.calendarName, current: event.calendar, entity: .event)
        try validate(patch: patch, for: event, destination: destination)

        event.calendar = destination
        switch patch.title {
        case .keep: break
        case let .set(value):
            event.title = try EventKitAgentValidation.text(
                value,
                field: "event title",
                minimum: 1,
                maximum: 240,
                multiline: false
            )
        case .clear:
            throw EventKitAgentError.invalidField("event title", "an event title cannot be cleared")
        }
        switch patch.schedule {
        case .keep: break
        case let .set(schedule): try apply(schedule: schedule, to: event)
        case .clear:
            throw EventKitAgentError.invalidField("event schedule", "an event schedule cannot be cleared")
        }
        event.location = try changedOptionalText(
            patch.location,
            current: event.location,
            field: "event location",
            maximum: 500,
            multiline: false
        )
        event.notes = try changedOptionalText(
            patch.notes,
            current: event.notes,
            field: "event notes",
            maximum: 10_000,
            multiline: true
        )
        event.url = try changedURL(patch.url, current: event.url, field: "event URL")
        switch patch.availability {
        case .keep: break
        case let .set(value): try apply(availability: value, to: event, calendar: destination)
        case .clear: try apply(availability: .systemDefault, to: event, calendar: destination)
        }
        switch patch.recurrence {
        case .keep: break
        case let .set(spec): event.recurrenceRules = [EventKitAgentMapper.recurrenceRule(from: spec)]
        case .clear: event.recurrenceRules = nil
        }
        switch patch.alertMinutesBeforeStart {
        case .keep: break
        case let .set(offsets):
            event.alarms = EventKitAgentMapper.eventAlarms(
                minutesBeforeStart: try EventKitAgentValidation.alertOffsets(offsets)
            )
        case .clear: event.alarms = nil
        }

        try save(event, span: nativeSpan(scope))
        return EventKitAgentMutationReceipt(
            entity: .calendarEvent,
            operation: .updated,
            title: event.title ?? "Event",
            containerTitle: destination.title
        )
    }

    func deleteCalendarEvent(
        token: EventKitLocalSelectionToken,
        scope: EventKitRecurringEventScope = .thisEvent
    ) async throws -> EventKitAgentMutationReceipt {
        try await requireFullEventAccess()
        let event = try consumeCalendarEvent(token)
        guard event.calendar.allowsContentModifications else {
            throw EventKitAgentError.readOnlyCalendar(event.calendar.title)
        }
        let title = event.title ?? "Event"
        let calendarTitle = event.calendar.title
        do {
            _ = try eventStore.remove(event, span: nativeSpan(scope), commit: true)
        } catch {
            throw storeFailure(error)
        }
        return EventKitAgentMutationReceipt(
            entity: .calendarEvent,
            operation: .deleted,
            title: title,
            containerTitle: calendarTitle
        )
    }

    func searchReminders(
        _ request: EventKitReminderSearchRequest
    ) async throws -> [EventKitReminderCandidate] {
        try await requireFullReminderAccess()
        let calendars = try calendarsForSearch(named: request.listName, entity: .reminder)
        let predicate = eventStore.predicateForReminders(in: calendars)
        let fetched = await fetchReminders(matching: predicate)
        let query = Self.normalizedSearchText(request.query)

        var matches: [(reminder: EKReminder, schedule: EventKitReminderSchedule)] = []
        for reminder in fetched.prefix(EventKitAgentLimits.maximumScannedItems) {
            switch request.status {
            case .incomplete where reminder.isCompleted: continue
            case .completed where !reminder.isCompleted: continue
            case .incomplete, .completed, .all: break
            }
            if !query.isEmpty {
                let matchesText = [reminder.title, reminder.notes]
                    .compactMap { $0 }
                    .contains { Self.normalizedSearchText($0).contains(query) }
                guard matchesText else { continue }
            }
            guard let schedule = try? reminderSchedule(from: reminder) else { continue }
            if let dueStart = request.dueStart, let dueEnd = request.dueEnd {
                guard let due = schedule.due,
                      let dueDate = try? EventKitAgentMapper.resolvedDate(for: due),
                      dueDate >= dueStart,
                      dueDate < dueEnd else { continue }
            }
            matches.append((reminder, schedule))
        }

        matches.sort { left, right in
            let leftDue = left.schedule.due.flatMap { try? EventKitAgentMapper.resolvedDate(for: $0) }
            let rightDue = right.schedule.due.flatMap { try? EventKitAgentMapper.resolvedDate(for: $0) }
            switch (leftDue, rightDue) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                return (left.reminder.title ?? "").localizedCaseInsensitiveCompare(
                    right.reminder.title ?? ""
                ) == .orderedAscending
            }
        }

        reminderSelections.removeAll()
        var candidates: [EventKitReminderCandidate] = []
        for match in matches.prefix(request.limit) {
            candidates.append(makeReminderCandidate(match.reminder, schedule: match.schedule))
        }
        return candidates
    }

    func createReminder(
        _ draft: EventKitReminderDraft
    ) async throws -> EventKitAgentMutationReceipt {
        try await requireFullReminderAccess()
        let list = try resolveWritableCalendar(named: draft.listName, entity: .reminder)
        if let recurrence = draft.recurrence {
            guard let anchor = draft.schedule.effectiveStart else {
                throw EventKitAgentError.invalidField(
                    "reminder recurrence",
                    "a repeating reminder needs a start or due date"
                )
            }
            try recurrence.validate(anchor: EventKitAgentMapper.resolvedDate(for: anchor))
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = list
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.url = draft.url
        reminder.priority = draft.priority.rawValue
        try apply(schedule: draft.schedule, to: reminder)
        reminder.recurrenceRules = draft.recurrence.map { [EventKitAgentMapper.recurrenceRule(from: $0)] }
        reminder.alarms = try EventKitAgentMapper.reminderAlarms(
            minutesBeforeDue: draft.alertMinutesBeforeDue,
            schedule: draft.schedule,
            hasRecurrence: draft.recurrence != nil
        )

        try save(reminder)
        return EventKitAgentMutationReceipt(
            entity: .reminder,
            operation: .created,
            title: draft.title,
            containerTitle: list.title
        )
    }

    func updateReminder(
        token: EventKitLocalSelectionToken,
        patch: EventKitReminderPatch
    ) async throws -> EventKitAgentMutationReceipt {
        try await requireFullReminderAccess()
        let reminder = try consumeReminder(token)
        guard reminder.calendar.allowsContentModifications else {
            throw EventKitAgentError.readOnlyCalendar(reminder.calendar.title)
        }
        guard patch.hasChanges else {
            throw EventKitAgentError.invalidField("reminder update", "provide at least one change")
        }

        let currentSchedule = try reminderSchedule(from: reminder)
        let alarmInspection = EventKitAgentMapper.inspectReminderAlarms(
            reminder.alarms,
            schedule: currentSchedule
        )
        guard alarmInspection.isSafeForEditing else {
            throw EventKitAgentError.unsupportedExistingAlarms(
                alarmInspection.unsupportedAlarmCount
            )
        }
        let finalSchedule: EventKitReminderSchedule
        switch patch.schedule {
        case .keep: finalSchedule = currentSchedule
        case let .set(schedule): finalSchedule = schedule
        case .clear: finalSchedule = try EventKitReminderSchedule()
        }
        let destination = try destinationCalendar(
            for: patch.listName,
            current: reminder.calendar,
            entity: .reminder
        )
        try validate(
            patch: patch,
            for: reminder,
            finalSchedule: finalSchedule,
            destination: destination
        )

        let finalHasRecurrence: Bool
        switch patch.recurrence {
        case .keep: finalHasRecurrence = reminder.hasRecurrenceRules
        case .set: finalHasRecurrence = true
        case .clear: finalHasRecurrence = false
        }
        let replacementAlarms: [EKAlarm]?
        switch patch.alertMinutesBeforeDue {
        case .keep:
            replacementAlarms = nil
        case let .set(offsets):
            replacementAlarms = try EventKitAgentMapper.reminderAlarms(
                minutesBeforeDue: EventKitAgentValidation.alertOffsets(offsets),
                schedule: finalSchedule,
                hasRecurrence: finalHasRecurrence
            )
        case .clear:
            replacementAlarms = []
        }

        reminder.calendar = destination
        switch patch.title {
        case .keep: break
        case let .set(value):
            reminder.title = try EventKitAgentValidation.text(
                value,
                field: "reminder title",
                minimum: 1,
                maximum: 240,
                multiline: false
            )
        case .clear:
            throw EventKitAgentError.invalidField("reminder title", "a reminder title cannot be cleared")
        }
        if patch.schedule.isChange {
            try apply(schedule: finalSchedule, to: reminder)
        }
        reminder.notes = try changedOptionalText(
            patch.notes,
            current: reminder.notes,
            field: "reminder notes",
            maximum: 10_000,
            multiline: true
        )
        reminder.url = try changedURL(patch.url, current: reminder.url, field: "reminder URL")
        switch patch.priority {
        case .keep: break
        case let .set(priority): reminder.priority = priority.rawValue
        case .clear: reminder.priority = 0
        }
        switch patch.recurrence {
        case .keep: break
        case let .set(spec): reminder.recurrenceRules = [EventKitAgentMapper.recurrenceRule(from: spec)]
        case .clear: reminder.recurrenceRules = nil
        }
        if let replacementAlarms {
            reminder.alarms = replacementAlarms
        }

        try save(reminder)
        return EventKitAgentMutationReceipt(
            entity: .reminder,
            operation: .updated,
            title: reminder.title ?? "Reminder",
            containerTitle: destination.title
        )
    }

    func setReminderCompletion(
        token: EventKitLocalSelectionToken,
        completed: Bool
    ) async throws -> EventKitAgentMutationReceipt {
        try await requireFullReminderAccess()
        let reminder = try consumeReminder(token)
        guard reminder.calendar.allowsContentModifications else {
            throw EventKitAgentError.readOnlyCalendar(reminder.calendar.title)
        }
        let schedule = try reminderSchedule(from: reminder)
        let alarmInspection = EventKitAgentMapper.inspectReminderAlarms(
            reminder.alarms,
            schedule: schedule
        )
        guard alarmInspection.isSafeForEditing else {
            throw EventKitAgentError.unsupportedExistingAlarms(
                alarmInspection.unsupportedAlarmCount
            )
        }
        reminder.isCompleted = completed
        try save(reminder)
        return EventKitAgentMutationReceipt(
            entity: .reminder,
            operation: completed ? .completed : .reopened,
            title: reminder.title ?? "Reminder",
            containerTitle: reminder.calendar.title
        )
    }

    func deleteReminder(
        token: EventKitLocalSelectionToken
    ) async throws -> EventKitAgentMutationReceipt {
        try await requireFullReminderAccess()
        let reminder = try consumeReminder(token)
        guard reminder.calendar.allowsContentModifications else {
            throw EventKitAgentError.readOnlyCalendar(reminder.calendar.title)
        }
        let title = reminder.title ?? "Reminder"
        let listTitle = reminder.calendar.title
        do {
            _ = try eventStore.remove(reminder, commit: true)
        } catch {
            throw storeFailure(error)
        }
        return EventKitAgentMutationReceipt(
            entity: .reminder,
            operation: .deleted,
            title: title,
            containerTitle: listTitle
        )
    }

    func invalidateLocalSelections() {
        calendarSelections.removeAll()
        reminderSelections.removeAll()
    }
}

private extension EventKitAgentService {
    func requireEventCreationAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly:
            return
        case .notDetermined:
            do {
                guard try await eventStore.requestWriteOnlyAccessToEvents() else {
                    throw EventKitAgentError.calendarAccessDenied
                }
            } catch let error as EventKitAgentError {
                throw error
            } catch {
                throw storeFailure(error)
            }
        case .restricted:
            throw EventKitAgentError.calendarAccessRestricted
        case .denied:
            throw EventKitAgentError.calendarAccessDenied
        @unknown default:
            throw EventKitAgentError.calendarAccessDenied
        }
    }

    func requireFullEventAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined, .writeOnly:
            do {
                guard try await eventStore.requestFullAccessToEvents() else {
                    throw EventKitAgentError.calendarAccessDenied
                }
            } catch let error as EventKitAgentError {
                throw error
            } catch {
                throw storeFailure(error)
            }
        case .restricted:
            throw EventKitAgentError.calendarAccessRestricted
        case .denied:
            throw EventKitAgentError.calendarAccessDenied
        @unknown default:
            throw EventKitAgentError.calendarAccessDenied
        }
    }

    func requireFullReminderAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined, .writeOnly:
            do {
                guard try await eventStore.requestFullAccessToReminders() else {
                    throw EventKitAgentError.remindersAccessDenied
                }
            } catch let error as EventKitAgentError {
                throw error
            } catch {
                throw storeFailure(error)
            }
        case .restricted:
            throw EventKitAgentError.remindersAccessRestricted
        case .denied:
            throw EventKitAgentError.remindersAccessDenied
        @unknown default:
            throw EventKitAgentError.remindersAccessDenied
        }
    }

    func calendarsForSearch(named name: String?, entity: EKEntityType) throws -> [EKCalendar]? {
        guard let name else { return nil }
        let matches = eventStore.calendars(for: entity).filter {
            Self.normalizedContainerName($0.title) == Self.normalizedContainerName(name)
        }
        guard !matches.isEmpty else {
            if entity == .event { throw EventKitAgentError.calendarNotFound(name) }
            throw EventKitAgentError.reminderListNotFound(name)
        }
        guard matches.count == 1 else {
            if entity == .event { throw EventKitAgentError.ambiguousCalendar(name, matches.count) }
            throw EventKitAgentError.ambiguousReminderList(name, matches.count)
        }
        return matches
    }

    func resolveWritableCalendar(named name: String?, entity: EKEntityType) throws -> EKCalendar {
        if let name {
            let matches = eventStore.calendars(for: entity).filter {
                Self.normalizedContainerName($0.title) == Self.normalizedContainerName(name)
            }
            guard !matches.isEmpty else {
                if entity == .event { throw EventKitAgentError.calendarNotFound(name) }
                throw EventKitAgentError.reminderListNotFound(name)
            }
            let writable = matches.filter(\.allowsContentModifications)
            guard !writable.isEmpty else {
                throw EventKitAgentError.readOnlyCalendar(name)
            }
            guard writable.count == 1 else {
                if entity == .event { throw EventKitAgentError.ambiguousCalendar(name, writable.count) }
                throw EventKitAgentError.ambiguousReminderList(name, writable.count)
            }
            return writable[0]
        }

        let preferred: EKCalendar?
        if entity == .event {
            preferred = eventStore.defaultCalendarForNewEvents
        } else {
            preferred = eventStore.defaultCalendarForNewReminders()
        }
        if let preferred, preferred.allowsContentModifications {
            return preferred
        }

        let writable = eventStore.calendars(for: entity).filter(\.allowsContentModifications)
        guard !writable.isEmpty else {
            if entity == .event { throw EventKitAgentError.noWritableCalendar }
            throw EventKitAgentError.noWritableReminderList
        }
        guard writable.count == 1 else {
            if entity == .event {
                throw EventKitAgentError.ambiguousCalendar("available writable calendars", writable.count)
            }
            throw EventKitAgentError.ambiguousReminderList("available writable lists", writable.count)
        }
        return writable[0]
    }

    func destinationCalendar(
        for change: EventKitFieldChange<String>,
        current: EKCalendar,
        entity: EKEntityType
    ) throws -> EKCalendar {
        switch change {
        case .keep: current
        case let .set(name): try resolveWritableCalendar(named: name, entity: entity)
        case .clear: try resolveWritableCalendar(named: nil, entity: entity)
        }
    }

    func validate(
        patch: EventKitCalendarEventPatch,
        for event: EKEvent,
        destination: EKCalendar
    ) throws {
        switch patch.title {
        case .keep: break
        case let .set(value):
            _ = try EventKitAgentValidation.text(
                value,
                field: "event title",
                minimum: 1,
                maximum: 240,
                multiline: false
            )
        case .clear:
            throw EventKitAgentError.invalidField("event title", "an event title cannot be cleared")
        }
        let anchor: Date
        switch patch.schedule {
        case .keep: anchor = event.startDate
        case let .set(schedule): anchor = try schedule.resolvedDates().start
        case .clear:
            throw EventKitAgentError.invalidField("event schedule", "an event schedule cannot be cleared")
        }
        _ = try changedOptionalText(
            patch.location,
            current: event.location,
            field: "event location",
            maximum: 500,
            multiline: false
        )
        _ = try changedOptionalText(
            patch.notes,
            current: event.notes,
            field: "event notes",
            maximum: 10_000,
            multiline: true
        )
        _ = try changedURL(patch.url, current: event.url, field: "event URL")
        switch patch.availability {
        case .keep: break
        case let .set(value): try validate(availability: value, calendar: destination)
        case .clear: break
        }
        if case let .set(spec) = patch.recurrence {
            try spec.validate(anchor: anchor)
        }
        if case let .set(offsets) = patch.alertMinutesBeforeStart {
            _ = try EventKitAgentValidation.alertOffsets(offsets)
        }
    }

    func validate(
        patch: EventKitReminderPatch,
        for reminder: EKReminder,
        finalSchedule: EventKitReminderSchedule,
        destination: EKCalendar
    ) throws {
        guard destination.allowsContentModifications else {
            throw EventKitAgentError.readOnlyCalendar(destination.title)
        }
        switch patch.title {
        case .keep: break
        case let .set(value):
            _ = try EventKitAgentValidation.text(
                value,
                field: "reminder title",
                minimum: 1,
                maximum: 240,
                multiline: false
            )
        case .clear:
            throw EventKitAgentError.invalidField("reminder title", "a reminder title cannot be cleared")
        }
        _ = try changedOptionalText(
            patch.notes,
            current: reminder.notes,
            field: "reminder notes",
            maximum: 10_000,
            multiline: true
        )
        _ = try changedURL(patch.url, current: reminder.url, field: "reminder URL")

        if reminder.hasAlarms,
           patch.alertMinutesBeforeDue == .keep,
           (patch.schedule.isChange || patch.recurrence.isChange) {
            throw EventKitAgentError.invalidField(
                "reminder alerts",
                "set or clear alerts explicitly when changing the schedule or recurrence"
            )
        }
        if case let .set(spec) = patch.recurrence {
            guard let anchor = finalSchedule.effectiveStart else {
                throw EventKitAgentError.invalidField(
                    "reminder recurrence",
                    "a repeating reminder needs a start or due date"
                )
            }
            try spec.validate(anchor: EventKitAgentMapper.resolvedDate(for: anchor))
        }
        if case let .set(offsets) = patch.alertMinutesBeforeDue {
            _ = try EventKitAgentValidation.alertOffsets(offsets)
        }
    }

    func apply(schedule: EventKitCalendarSchedule, to event: EKEvent) throws {
        let resolved = try schedule.resolvedDates()
        switch schedule {
        case .timed:
            event.isAllDay = false
            event.timeZone = resolved.timeZone
        case .allDay:
            event.isAllDay = true
            event.timeZone = nil
        }
        event.startDate = resolved.start
        event.endDate = resolved.end
    }

    func apply(schedule: EventKitReminderSchedule, to reminder: EKReminder) throws {
        reminder.startDateComponents = try schedule.effectiveStart.map {
            try EventKitAgentMapper.dateComponents(from: $0)
        }
        reminder.dueDateComponents = try schedule.due.map {
            try EventKitAgentMapper.dateComponents(from: $0)
        }
    }

    func apply(
        availability: EventKitEventAvailability,
        to event: EKEvent,
        calendar: EKCalendar
    ) throws {
        guard let native = EventKitAgentMapper.nativeAvailability(from: availability) else {
            if calendar.supportedEventAvailabilities.contains(.busy) {
                event.availability = .busy
            }
            return
        }
        guard calendar.supportedEventAvailabilities.contains(native.mask) else {
            throw EventKitAgentError.unsupportedAvailability(availability.rawValue)
        }
        event.availability = native.value
    }

    func validate(availability: EventKitEventAvailability, calendar: EKCalendar) throws {
        guard let native = EventKitAgentMapper.nativeAvailability(from: availability) else { return }
        guard calendar.supportedEventAvailabilities.contains(native.mask) else {
            throw EventKitAgentError.unsupportedAvailability(availability.rawValue)
        }
    }

    func reminderSchedule(from reminder: EKReminder) throws -> EventKitReminderSchedule {
        try EventKitReminderSchedule(
            start: EventKitAgentMapper.reminderDateValue(from: reminder.startDateComponents),
            due: EventKitAgentMapper.reminderDateValue(from: reminder.dueDateComponents)
        )
    }

    func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            _ = eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    func makeCalendarCandidate(_ event: EKEvent) -> EventKitCalendarEventCandidate? {
        guard let startDate = event.startDate,
              let endDate = event.endDate,
              let calendar = event.calendar else { return nil }
        let selection = CalendarSelection(
            event: event,
            fingerprint: CalendarEventFingerprint(event)
        )
        let token = calendarSelections.issue(selection)
        let alarmInspection = EventKitAgentMapper.inspectEventAlarms(event.alarms)
        return EventKitCalendarEventCandidate(
            id: token,
            title: event.title ?? "Untitled event",
            startDate: startDate,
            endDate: endDate,
            isAllDay: event.isAllDay,
            timeZoneIdentifier: event.timeZone?.identifier,
            calendarTitle: calendar.title,
            location: event.location,
            notes: event.notes,
            url: event.url,
            availability: EventKitAgentMapper.eventAvailability(from: event.availability),
            alertMinutesBeforeStart: alarmInspection.supportedMinutesBefore,
            unsupportedAlarmCount: alarmInspection.unsupportedAlarmCount,
            hasRecurrence: event.hasRecurrenceRules,
            canModify: calendar.allowsContentModifications,
            lastModifiedDate: event.lastModifiedDate
        )
    }

    func makeReminderCandidate(
        _ reminder: EKReminder,
        schedule: EventKitReminderSchedule
    ) -> EventKitReminderCandidate {
        let selection = ReminderSelection(
            reminder: reminder,
            fingerprint: ReminderFingerprint(reminder)
        )
        let token = reminderSelections.issue(selection)
        let alarmInspection = EventKitAgentMapper.inspectReminderAlarms(
            reminder.alarms,
            schedule: schedule
        )
        return EventKitReminderCandidate(
            id: token,
            title: reminder.title ?? "Untitled reminder",
            listTitle: reminder.calendar.title,
            start: schedule.start,
            due: schedule.due,
            notes: reminder.notes,
            url: reminder.url,
            priority: Self.reminderPriority(reminder.priority),
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            hasRecurrence: reminder.hasRecurrenceRules,
            alertMinutesBeforeDue: alarmInspection.supportedMinutesBefore,
            unsupportedAlarmCount: alarmInspection.unsupportedAlarmCount,
            canModify: reminder.calendar.allowsContentModifications,
            lastModifiedDate: reminder.lastModifiedDate
        )
    }

    func consumeCalendarEvent(_ token: EventKitLocalSelectionToken) throws -> EKEvent {
        let selection = try calendarSelections.consume(token)
        guard selection.event.refresh() else {
            throw EventKitAgentError.localSelectionStale
        }
        guard CalendarEventFingerprint(selection.event) == selection.fingerprint else {
            throw EventKitAgentError.localSelectionStale
        }
        return selection.event
    }

    func consumeReminder(_ token: EventKitLocalSelectionToken) throws -> EKReminder {
        let selection = try reminderSelections.consume(token)
        guard selection.reminder.refresh() else {
            throw EventKitAgentError.localSelectionStale
        }
        guard ReminderFingerprint(selection.reminder) == selection.fingerprint else {
            throw EventKitAgentError.localSelectionStale
        }
        return selection.reminder
    }

    func save(_ event: EKEvent, span: EKSpan) throws {
        do {
            _ = try eventStore.save(event, span: span, commit: true)
        } catch {
            throw storeFailure(error)
        }
    }

    func save(_ reminder: EKReminder) throws {
        do {
            _ = try eventStore.save(reminder, commit: true)
        } catch {
            throw storeFailure(error)
        }
    }

    func storeFailure(_ error: Error) -> EventKitAgentError {
        EventKitAgentError.eventStoreFailure(error.localizedDescription)
    }

    func nativeSpan(_ scope: EventKitRecurringEventScope) -> EKSpan {
        switch scope {
        case .thisEvent: .thisEvent
        case .futureEvents: .futureEvents
        }
    }

    func changedOptionalText(
        _ change: EventKitFieldChange<String>,
        current: String?,
        field: String,
        maximum: Int,
        multiline: Bool
    ) throws -> String? {
        switch change {
        case .keep: current
        case let .set(value):
            try EventKitAgentValidation.optionalText(
                value,
                field: field,
                maximum: maximum,
                multiline: multiline
            )
        case .clear: nil
        }
    }

    func changedURL(
        _ change: EventKitFieldChange<URL>,
        current: URL?,
        field: String
    ) throws -> URL? {
        switch change {
        case .keep: current
        case let .set(value): try EventKitAgentValidation.httpsURL(value, field: field)
        case .clear: nil
        }
    }

    static func reminderPriority(_ rawValue: Int) -> EventKitReminderPriority {
        switch rawValue {
        case 1 ... 4: .high
        case 5: .medium
        case 6 ... 9: .low
        default: .none
        }
    }

    static func normalizedContainerName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func normalizedSearchText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }
}

private struct CalendarEventFingerprint: Equatable {
    let eventIdentifier: String?
    let calendarIdentifier: String
    let title: String?
    let startDate: Date?
    let endDate: Date?
    let isAllDay: Bool
    let timeZoneIdentifier: String?
    let location: String?
    let notes: String?
    let url: URL?
    let availability: Int
    let lastModifiedDate: Date?
    let alarms: [AlarmFingerprint]
    let recurrence: [RecurrenceFingerprint]

    init(_ event: EKEvent) {
        eventIdentifier = event.eventIdentifier
        calendarIdentifier = event.calendar.calendarIdentifier
        title = event.title
        startDate = event.startDate
        endDate = event.endDate
        isAllDay = event.isAllDay
        timeZoneIdentifier = event.timeZone?.identifier
        location = event.location
        notes = event.notes
        url = event.url
        availability = event.availability.rawValue
        lastModifiedDate = event.lastModifiedDate
        alarms = (event.alarms ?? []).map(AlarmFingerprint.init)
        recurrence = (event.recurrenceRules ?? []).map(RecurrenceFingerprint.init)
    }
}

private struct ReminderFingerprint: Equatable {
    let identifier: String
    let calendarIdentifier: String
    let title: String?
    let startDateComponents: DateComponents?
    let dueDateComponents: DateComponents?
    let notes: String?
    let url: URL?
    let priority: Int
    let isCompleted: Bool
    let completionDate: Date?
    let lastModifiedDate: Date?
    let alarms: [AlarmFingerprint]
    let recurrence: [RecurrenceFingerprint]

    init(_ reminder: EKReminder) {
        identifier = reminder.calendarItemIdentifier
        calendarIdentifier = reminder.calendar.calendarIdentifier
        title = reminder.title
        startDateComponents = reminder.startDateComponents
        dueDateComponents = reminder.dueDateComponents
        notes = reminder.notes
        url = reminder.url
        priority = reminder.priority
        isCompleted = reminder.isCompleted
        completionDate = reminder.completionDate
        lastModifiedDate = reminder.lastModifiedDate
        alarms = (reminder.alarms ?? []).map(AlarmFingerprint.init)
        recurrence = (reminder.recurrenceRules ?? []).map(RecurrenceFingerprint.init)
    }
}

private struct AlarmFingerprint: Equatable {
    let absoluteDate: Date?
    let relativeOffset: TimeInterval
    let proximity: Int

    init(_ alarm: EKAlarm) {
        absoluteDate = alarm.absoluteDate
        relativeOffset = alarm.relativeOffset
        proximity = alarm.proximity.rawValue
    }
}

private struct RecurrenceFingerprint: Equatable {
    let frequency: Int
    let interval: Int
    let weekdays: [(weekday: Int, weekNumber: Int)]
    let endDate: Date?
    let occurrenceCount: Int

    init(_ rule: EKRecurrenceRule) {
        frequency = rule.frequency.rawValue
        interval = rule.interval
        weekdays = (rule.daysOfTheWeek ?? []).map {
            ($0.dayOfTheWeek.rawValue, $0.weekNumber)
        }
        endDate = rule.recurrenceEnd?.endDate
        occurrenceCount = rule.recurrenceEnd?.occurrenceCount ?? 0
    }

    static func == (left: RecurrenceFingerprint, right: RecurrenceFingerprint) -> Bool {
        left.frequency == right.frequency
            && left.interval == right.interval
            && left.weekdays.elementsEqual(right.weekdays) {
                $0.weekday == $1.weekday && $0.weekNumber == $1.weekNumber
            }
            && left.endDate == right.endDate
            && left.occurrenceCount == right.occurrenceCount
    }
}
