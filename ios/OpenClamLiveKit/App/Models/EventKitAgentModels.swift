import Foundation

enum EventKitAgentError: LocalizedError, Equatable {
    case invalidField(String, String)
    case calendarAccessDenied
    case calendarAccessRestricted
    case remindersAccessDenied
    case remindersAccessRestricted
    case calendarNotFound(String)
    case reminderListNotFound(String)
    case noWritableCalendar
    case noWritableReminderList
    case ambiguousCalendar(String, Int)
    case ambiguousReminderList(String, Int)
    case readOnlyCalendar(String)
    case unsupportedAvailability(String)
    case unsupportedExistingAlarms(Int)
    case eventStoreFailure(String)
    case localSelectionExpired
    case localSelectionStale
    case localSelectionMissing

    var errorDescription: String? {
        switch self {
        case let .invalidField(field, reason):
            "Invalid \(field): \(reason)"
        case .calendarAccessDenied:
            "Calendar access is off. Enable it in Settings to use this Calendar action."
        case .calendarAccessRestricted:
            "Calendar access is restricted on this device."
        case .remindersAccessDenied:
            "Reminders access is off. Enable it in Settings to use this Reminders action."
        case .remindersAccessRestricted:
            "Reminders access is restricted on this device."
        case let .calendarNotFound(name):
            "No Calendar named “\(name)” is available."
        case let .reminderListNotFound(name):
            "No Reminders list named “\(name)” is available."
        case .noWritableCalendar:
            "No writable Calendar is available."
        case .noWritableReminderList:
            "No writable Reminders list is available."
        case let .ambiguousCalendar(name, count):
            "\(count) Calendars are named “\(name)”. Choose one on this device."
        case let .ambiguousReminderList(name, count):
            "\(count) Reminders lists are named “\(name)”. Choose one on this device."
        case let .readOnlyCalendar(name):
            "“\(name)” does not allow item changes."
        case let .unsupportedAvailability(value):
            "The selected Calendar does not support “\(value)” availability."
        case let .unsupportedExistingAlarms(count):
            "This item has \(count) absolute or unsupported existing alarm\(count == 1 ? "" : "s"). To preserve them, edit this item in Apple Calendar or Reminders."
        case let .eventStoreFailure(message):
            "Calendar or Reminders could not finish the change: \(message)"
        case .localSelectionExpired:
            "That local selection expired. Search again before making a change."
        case .localSelectionStale:
            "That item changed after it was selected. Search again and review its latest details."
        case .localSelectionMissing:
            "That local selection is no longer available. Search again."
        }
    }
}

struct EventKitLocalDate: Equatable, Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else {
            throw EventKitAgentError.invalidField("date", "use a real Gregorian calendar date")
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            throw EventKitAgentError.invalidField("date", "use a real Gregorian calendar date")
        }
        self.year = year
        self.month = month
        self.day = day
    }

    func date(in timeZone: TimeZone) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else {
            throw EventKitAgentError.invalidField("date", "could not resolve this date in the selected time zone")
        }
        return date
    }

    func dateComponents(in timeZone: TimeZone) -> DateComponents {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day
        return components
    }
}

enum EventKitCalendarSchedule: Equatable, Sendable {
    case timed(start: Date, end: Date, timeZoneIdentifier: String)
    case allDay(start: EventKitLocalDate, endExclusive: EventKitLocalDate)

    func resolvedDates(allDayTimeZone: TimeZone = .current) throws -> (start: Date, end: Date, timeZone: TimeZone?) {
        switch self {
        case let .timed(start, end, timeZoneIdentifier):
            guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
                throw EventKitAgentError.invalidField("time zone", "use a valid IANA time-zone identifier")
            }
            guard end > start else {
                throw EventKitAgentError.invalidField("event schedule", "the end must be after the start")
            }
            guard end.timeIntervalSince(start) <= EventKitAgentLimits.maximumScheduleDuration else {
                throw EventKitAgentError.invalidField("event schedule", "keep one event within 366 days")
            }
            return (start, end, timeZone)
        case let .allDay(start, endExclusive):
            let startDate = try start.date(in: allDayTimeZone)
            let endDate = try endExclusive.date(in: allDayTimeZone)
            guard endDate > startDate else {
                throw EventKitAgentError.invalidField("all-day schedule", "the exclusive end date must follow the start date")
            }
            guard endDate.timeIntervalSince(startDate) <= EventKitAgentLimits.maximumScheduleDuration else {
                throw EventKitAgentError.invalidField("all-day schedule", "keep one event within 366 days")
            }
            return (startDate, endDate, nil)
        }
    }
}

enum EventKitRecurrenceFrequency: String, CaseIterable, Equatable, Sendable {
    case daily
    case weekly
    case monthly
    case yearly
}

enum EventKitWeekday: Int, CaseIterable, Equatable, Hashable, Sendable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
}

enum EventKitRecurrenceEnd: Equatable, Sendable {
    case never
    case onDate(Date)
    case afterOccurrences(Int)
}

struct EventKitRecurrenceSpec: Equatable, Sendable {
    let frequency: EventKitRecurrenceFrequency
    let interval: Int
    let weekdays: [EventKitWeekday]
    let end: EventKitRecurrenceEnd

    init(
        frequency: EventKitRecurrenceFrequency,
        interval: Int = 1,
        weekdays: [EventKitWeekday] = [],
        end: EventKitRecurrenceEnd = .never
    ) throws {
        guard (1 ... 99).contains(interval) else {
            throw EventKitAgentError.invalidField("recurrence interval", "use a value from 1 through 99")
        }
        guard Set(weekdays).count == weekdays.count else {
            throw EventKitAgentError.invalidField("recurrence weekdays", "do not repeat a weekday")
        }
        guard frequency == .weekly || weekdays.isEmpty else {
            throw EventKitAgentError.invalidField("recurrence weekdays", "weekdays are supported only for weekly recurrence")
        }
        if case let .afterOccurrences(count) = end, !(1 ... 999).contains(count) {
            throw EventKitAgentError.invalidField("recurrence count", "use a value from 1 through 999")
        }
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays.sorted { $0.rawValue < $1.rawValue }
        self.end = end
    }

    func validate(anchor: Date) throws {
        if case let .onDate(endDate) = end, endDate <= anchor {
            throw EventKitAgentError.invalidField("recurrence end", "the recurrence end must follow the first occurrence")
        }
    }
}

enum EventKitEventAvailability: String, CaseIterable, Equatable, Sendable {
    case systemDefault
    case busy
    case free
    case tentative
    case unavailable
}

struct EventKitCalendarSearchRequest: Equatable, Sendable {
    let query: String
    let rangeStart: Date
    let rangeEnd: Date
    let calendarName: String?
    let limit: Int

    init(
        query: String,
        rangeStart: Date,
        rangeEnd: Date,
        calendarName: String? = nil,
        limit: Int = 20
    ) throws {
        self.query = try EventKitAgentValidation.text(
            query,
            field: "calendar query",
            minimum: 0,
            maximum: 240,
            multiline: false
        )
        try EventKitAgentValidation.searchRange(start: rangeStart, end: rangeEnd)
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.calendarName = try EventKitAgentValidation.optionalText(
            calendarName,
            field: "calendar name",
            maximum: 160,
            multiline: false
        )
        guard (1 ... EventKitAgentLimits.maximumSearchResults).contains(limit) else {
            throw EventKitAgentError.invalidField("result limit", "use a value from 1 through 50")
        }
        self.limit = limit
    }
}

struct EventKitCalendarEventDraft: Equatable, Sendable {
    let title: String
    let schedule: EventKitCalendarSchedule
    let calendarName: String?
    let location: String?
    let notes: String?
    let url: URL?
    let availability: EventKitEventAvailability
    let recurrence: EventKitRecurrenceSpec?
    let alertMinutesBeforeStart: [Int]

    init(
        title: String,
        schedule: EventKitCalendarSchedule,
        calendarName: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil,
        availability: EventKitEventAvailability = .systemDefault,
        recurrence: EventKitRecurrenceSpec? = nil,
        alertMinutesBeforeStart: [Int] = []
    ) throws {
        self.title = try EventKitAgentValidation.text(
            title,
            field: "event title",
            minimum: 1,
            maximum: 240,
            multiline: false
        )
        let resolved = try schedule.resolvedDates()
        try recurrence?.validate(anchor: resolved.start)
        self.schedule = schedule
        self.calendarName = try EventKitAgentValidation.optionalText(
            calendarName,
            field: "calendar name",
            maximum: 160,
            multiline: false
        )
        self.location = try EventKitAgentValidation.optionalText(
            location,
            field: "event location",
            maximum: 500,
            multiline: false
        )
        self.notes = try EventKitAgentValidation.optionalText(
            notes,
            field: "event notes",
            maximum: 10_000,
            multiline: true
        )
        self.url = try EventKitAgentValidation.httpsURL(url, field: "event URL")
        self.availability = availability
        self.recurrence = recurrence
        self.alertMinutesBeforeStart = try EventKitAgentValidation.alertOffsets(alertMinutesBeforeStart)
    }
}

enum EventKitFieldChange<Value>: Equatable, Sendable where Value: Equatable & Sendable {
    case keep
    case set(Value)
    case clear
}

struct EventKitCalendarEventPatch: Equatable, Sendable {
    var title: EventKitFieldChange<String> = .keep
    var schedule: EventKitFieldChange<EventKitCalendarSchedule> = .keep
    var calendarName: EventKitFieldChange<String> = .keep
    var location: EventKitFieldChange<String> = .keep
    var notes: EventKitFieldChange<String> = .keep
    var url: EventKitFieldChange<URL> = .keep
    var availability: EventKitFieldChange<EventKitEventAvailability> = .keep
    var recurrence: EventKitFieldChange<EventKitRecurrenceSpec> = .keep
    var alertMinutesBeforeStart: EventKitFieldChange<[Int]> = .keep

    var hasChanges: Bool {
        [
            title.isChange,
            schedule.isChange,
            calendarName.isChange,
            location.isChange,
            notes.isChange,
            url.isChange,
            availability.isChange,
            recurrence.isChange,
            alertMinutesBeforeStart.isChange,
        ].contains(true)
    }
}

enum EventKitRecurringEventScope: Equatable, Sendable {
    case thisEvent
    case futureEvents
}

struct EventKitLocalSelectionToken: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct EventKitCalendarEventCandidate: Identifiable, Equatable, Sendable {
    let id: EventKitLocalSelectionToken
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let timeZoneIdentifier: String?
    let calendarTitle: String
    let location: String?
    let notes: String?
    let url: URL?
    let availability: EventKitEventAvailability
    let alertMinutesBeforeStart: [Int]
    let unsupportedAlarmCount: Int
    let hasRecurrence: Bool
    let canModify: Bool
    let lastModifiedDate: Date?
}

enum EventKitReminderDateValue: Equatable, Sendable {
    case timed(Date, timeZoneIdentifier: String)
    case allDay(EventKitLocalDate)
}

struct EventKitReminderSchedule: Equatable, Sendable {
    let start: EventKitReminderDateValue?
    let due: EventKitReminderDateValue?

    init(start: EventKitReminderDateValue? = nil, due: EventKitReminderDateValue? = nil) throws {
        if let start, let due {
            switch (start, due) {
            case let (.timed(startDate, _), .timed(dueDate, _)):
                guard dueDate >= startDate else {
                    throw EventKitAgentError.invalidField("reminder schedule", "the due date must not precede the start date")
                }
            case let (.allDay(startDate), .allDay(dueDate)):
                let timeZone = TimeZone(secondsFromGMT: 0)!
                guard try dueDate.date(in: timeZone) >= startDate.date(in: timeZone) else {
                    throw EventKitAgentError.invalidField("reminder schedule", "the due date must not precede the start date")
                }
            default:
                throw EventKitAgentError.invalidField("reminder schedule", "start and due must both be timed or both be all-day")
            }
        }
        if case let .timed(_, timeZoneIdentifier)? = start {
            try EventKitAgentValidation.timeZone(identifier: timeZoneIdentifier)
        }
        if case let .timed(_, timeZoneIdentifier)? = due {
            try EventKitAgentValidation.timeZone(identifier: timeZoneIdentifier)
        }
        self.start = start
        self.due = due
    }

    var effectiveStart: EventKitReminderDateValue? {
        start ?? due
    }
}

enum EventKitReminderPriority: Int, CaseIterable, Equatable, Sendable {
    case none = 0
    case high = 1
    case medium = 5
    case low = 9
}

enum EventKitReminderSearchStatus: Equatable, Sendable {
    case incomplete
    case completed
    case all
}

struct EventKitReminderSearchRequest: Equatable, Sendable {
    let query: String
    let status: EventKitReminderSearchStatus
    let dueStart: Date?
    let dueEnd: Date?
    let listName: String?
    let limit: Int

    init(
        query: String,
        status: EventKitReminderSearchStatus = .incomplete,
        dueStart: Date? = nil,
        dueEnd: Date? = nil,
        listName: String? = nil,
        limit: Int = 20
    ) throws {
        self.query = try EventKitAgentValidation.text(
            query,
            field: "reminder query",
            minimum: 0,
            maximum: 240,
            multiline: false
        )
        if let dueStart, let dueEnd {
            try EventKitAgentValidation.searchRange(start: dueStart, end: dueEnd)
        } else if dueStart != nil || dueEnd != nil {
            throw EventKitAgentError.invalidField("reminder due range", "provide both the start and end, or neither")
        }
        self.status = status
        self.dueStart = dueStart
        self.dueEnd = dueEnd
        self.listName = try EventKitAgentValidation.optionalText(
            listName,
            field: "reminder list name",
            maximum: 160,
            multiline: false
        )
        guard (1 ... EventKitAgentLimits.maximumSearchResults).contains(limit) else {
            throw EventKitAgentError.invalidField("result limit", "use a value from 1 through 50")
        }
        self.limit = limit
    }
}

struct EventKitReminderDraft: Equatable, Sendable {
    let title: String
    let listName: String?
    let schedule: EventKitReminderSchedule
    let notes: String?
    let url: URL?
    let priority: EventKitReminderPriority
    let recurrence: EventKitRecurrenceSpec?
    let alertMinutesBeforeDue: [Int]

    init(
        title: String,
        listName: String? = nil,
        schedule: EventKitReminderSchedule? = nil,
        notes: String? = nil,
        url: URL? = nil,
        priority: EventKitReminderPriority = .none,
        recurrence: EventKitRecurrenceSpec? = nil,
        alertMinutesBeforeDue: [Int] = []
    ) throws {
        self.title = try EventKitAgentValidation.text(
            title,
            field: "reminder title",
            minimum: 1,
            maximum: 240,
            multiline: false
        )
        self.listName = try EventKitAgentValidation.optionalText(
            listName,
            field: "reminder list name",
            maximum: 160,
            multiline: false
        )
        let resolvedSchedule: EventKitReminderSchedule
        if let schedule {
            resolvedSchedule = schedule
        } else {
            resolvedSchedule = try EventKitReminderSchedule()
        }
        self.schedule = resolvedSchedule
        self.notes = try EventKitAgentValidation.optionalText(
            notes,
            field: "reminder notes",
            maximum: 10_000,
            multiline: true
        )
        self.url = try EventKitAgentValidation.httpsURL(url, field: "reminder URL")
        self.priority = priority
        self.recurrence = recurrence
        self.alertMinutesBeforeDue = try EventKitAgentValidation.alertOffsets(alertMinutesBeforeDue)
        if !self.alertMinutesBeforeDue.isEmpty, resolvedSchedule.due == nil {
            throw EventKitAgentError.invalidField("reminder alerts", "a due date is required for minute-offset alerts")
        }
        if let recurrence, let anchor = resolvedSchedule.effectiveStart?.absoluteDate {
            try recurrence.validate(anchor: anchor)
        }
    }
}

struct EventKitReminderPatch: Equatable, Sendable {
    var title: EventKitFieldChange<String> = .keep
    var listName: EventKitFieldChange<String> = .keep
    var schedule: EventKitFieldChange<EventKitReminderSchedule> = .keep
    var notes: EventKitFieldChange<String> = .keep
    var url: EventKitFieldChange<URL> = .keep
    var priority: EventKitFieldChange<EventKitReminderPriority> = .keep
    var recurrence: EventKitFieldChange<EventKitRecurrenceSpec> = .keep
    var alertMinutesBeforeDue: EventKitFieldChange<[Int]> = .keep

    var hasChanges: Bool {
        [
            title.isChange,
            listName.isChange,
            schedule.isChange,
            notes.isChange,
            url.isChange,
            priority.isChange,
            recurrence.isChange,
            alertMinutesBeforeDue.isChange,
        ].contains(true)
    }
}

struct EventKitReminderCandidate: Identifiable, Equatable, Sendable {
    let id: EventKitLocalSelectionToken
    let title: String
    let listTitle: String
    let start: EventKitReminderDateValue?
    let due: EventKitReminderDateValue?
    let notes: String?
    let url: URL?
    let priority: EventKitReminderPriority
    let isCompleted: Bool
    let completionDate: Date?
    let hasRecurrence: Bool
    let alertMinutesBeforeDue: [Int]
    let unsupportedAlarmCount: Int
    let canModify: Bool
    let lastModifiedDate: Date?
}

enum EventKitAgentMutationEntity: Equatable, Sendable {
    case calendarEvent
    case reminder
}

enum EventKitAgentMutationOperation: Equatable, Sendable {
    case created
    case updated
    case completed
    case reopened
    case deleted
}

struct EventKitAgentMutationReceipt: Equatable, Sendable {
    let entity: EventKitAgentMutationEntity
    let operation: EventKitAgentMutationOperation
    let title: String
    let containerTitle: String
}

enum EventKitAgentLimits {
    static let maximumSearchResults = 50
    static let maximumSearchWindow: TimeInterval = 366 * 24 * 60 * 60
    static let maximumScheduleDuration: TimeInterval = 366 * 24 * 60 * 60
    static let maximumAlertCount = 5
    static let maximumAlertMinutes = 10_080
    static let maximumScannedItems = 5_000
}

struct EventKitAlarmInspection: Equatable, Sendable {
    let supportedMinutesBefore: [Int]
    let unsupportedAlarmCount: Int

    var isSafeForEditing: Bool {
        unsupportedAlarmCount == 0
    }
}

enum EventKitAgentValidation {
    static func text(
        _ rawValue: String,
        field: String,
        minimum: Int,
        maximum: Int,
        multiline: Bool
    ) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (minimum ... maximum).contains(value.count) else {
            throw EventKitAgentError.invalidField(field, "use \(minimum) through \(maximum) characters")
        }
        let invalidControl = value.unicodeScalars.contains { scalar in
            guard CharacterSet.controlCharacters.contains(scalar) else { return false }
            return !multiline || (scalar != "\n" && scalar != "\r" && scalar != "\t")
        }
        guard !invalidControl else {
            throw EventKitAgentError.invalidField(field, "unsupported control characters are not allowed")
        }
        return value
    }

    static func optionalText(
        _ rawValue: String?,
        field: String,
        maximum: Int,
        multiline: Bool
    ) throws -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try text(
            trimmed,
            field: field,
            minimum: 1,
            maximum: maximum,
            multiline: multiline
        )
    }

    static func httpsURL(_ url: URL?, field: String) throws -> URL? {
        guard let url else { return nil }
        guard url.absoluteString.utf8.count <= 2_048,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw EventKitAgentError.invalidField(field, "use an HTTPS URL without embedded credentials")
        }
        return url
    }

    static func searchRange(start: Date, end: Date) throws {
        guard end > start else {
            throw EventKitAgentError.invalidField("search range", "the end must be after the start")
        }
        guard end.timeIntervalSince(start) <= EventKitAgentLimits.maximumSearchWindow else {
            throw EventKitAgentError.invalidField("search range", "keep one search within 366 days")
        }
    }

    static func alertOffsets(_ values: [Int]) throws -> [Int] {
        guard values.count <= EventKitAgentLimits.maximumAlertCount else {
            throw EventKitAgentError.invalidField("alerts", "use at most five alerts")
        }
        guard Set(values).count == values.count else {
            throw EventKitAgentError.invalidField("alerts", "do not repeat an alert offset")
        }
        guard values.allSatisfy({ (0 ... EventKitAgentLimits.maximumAlertMinutes).contains($0) }) else {
            throw EventKitAgentError.invalidField("alerts", "use offsets from 0 through 10080 minutes")
        }
        return values.sorted()
    }

    @discardableResult
    static func timeZone(identifier: String) throws -> TimeZone {
        guard let timeZone = TimeZone(identifier: identifier) else {
            throw EventKitAgentError.invalidField("time zone", "use a valid IANA time-zone identifier")
        }
        return timeZone
    }
}

extension EventKitFieldChange {
    var isChange: Bool {
        switch self {
        case .keep: false
        case .set, .clear: true
        }
    }
}

extension EventKitReminderDateValue {
    var absoluteDate: Date? {
        switch self {
        case let .timed(date, _): date
        case .allDay: nil
        }
    }
}
