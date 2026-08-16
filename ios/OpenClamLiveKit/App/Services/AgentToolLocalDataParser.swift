import Foundation

enum AgentCalendarLookupOperation: Equatable {
    case search
    case update(EventKitCalendarEventPatch, EventKitRecurringEventScope)
    case delete(EventKitRecurringEventScope)
}

struct AgentCalendarLookupRequest: Equatable {
    let search: EventKitCalendarSearchRequest
    let operation: AgentCalendarLookupOperation
}

enum AgentReminderLookupOperation: Equatable {
    case search
    case update(EventKitReminderPatch)
    case completion(Bool)
    case delete
}

struct AgentReminderLookupRequest: Equatable {
    let search: EventKitReminderSearchRequest
    let operation: AgentReminderLookupOperation
}

enum AgentToolLocalDataParser {
    static func contactFields(
        from call: OpenAIToolCall,
        argument: String
    ) throws -> Set<LocalContactFieldKind> {
        let values = try call.stringArray(
            argument,
            count: 1 ... 10,
            itemMaximumLength: 40
        )
        let fields = try values.map { value -> LocalContactFieldKind in
            switch normalizedEnum(value) {
            case "name": .name
            case "organization": .organization
            case "department": .department
            case "job_title", "jobtitle", "title": .jobTitle
            case "phone", "phone_number": .phone
            case "email", "email_address": .email
            case "postal_address", "address", "home_address": .postalAddress
            case "birthday": .birthday
            case "website", "url": .url
            case "relationship", "relation": .relationship
            case "note", "notes": .note
            default: throw CompanionAgentToolError.invalidArgument(argument)
            }
        }
        guard Set(fields).count == fields.count else {
            throw CompanionAgentToolError.invalidArgument(argument)
        }
        return Set(fields)
    }

    static func calendarDraft(from call: OpenAIToolCall) throws -> EventKitCalendarEventDraft {
        let allDay = try call.boolean("all_day")
        let schedule: EventKitCalendarSchedule
        if allDay {
            schedule = .allDay(
                start: try localDate(call, "start_date"),
                endExclusive: try localDate(call, "end_date_exclusive")
            )
        } else {
            let timeZone = try call.singleLine("time_zone", maximumLength: 100)
            schedule = .timed(
                start: try call.iso8601("start_iso8601", mustBeFuture: false),
                end: try call.iso8601("end_iso8601", mustBeFuture: false),
                timeZoneIdentifier: timeZone
            )
        }
        return try EventKitCalendarEventDraft(
            title: call.singleLine("title", maximumLength: 240),
            schedule: schedule,
            calendarName: call.optionalSingleLine("calendar_name", maximumLength: 160),
            location: call.optionalSingleLine("location", maximumLength: 500),
            notes: call.optionalMultiline("notes", maximumLength: 10_000),
            url: try optionalHTTPSURL(call, "url"),
            availability: try availability(call.singleLine("availability", maximumLength: 30)),
            recurrence: try recurrence(
                frequency: call.singleLine("recurrence_frequency", maximumLength: 20),
                interval: call.integer("recurrence_interval", range: 1 ... 99),
                weekdays: call.integerArray(
                    "recurrence_weekdays",
                    count: 0 ... 7,
                    itemRange: 1 ... 7
                ),
                endText: call.optionalSingleLine("recurrence_end_iso8601", maximumLength: 80),
                count: call.integer("recurrence_count", range: 0 ... 999)
            ),
            alertMinutesBeforeStart: call.integerArray(
                "alert_minutes_before",
                count: 0 ... 5,
                itemRange: 0 ... 10_080
            )
        )
    }

    static func calendarLookup(from call: OpenAIToolCall) throws -> AgentCalendarLookupRequest {
        let search = try EventKitCalendarSearchRequest(
            query: call.singleLine("query", minimumLength: 0, maximumLength: 240),
            rangeStart: call.iso8601("range_start_iso8601", mustBeFuture: false),
            rangeEnd: call.iso8601("range_end_iso8601", mustBeFuture: false),
            calendarName: call.optionalSingleLine("calendar_name", maximumLength: 160),
            limit: 20
        )
        let scope: EventKitRecurringEventScope
        switch normalizedEnum(try call.singleLine("recurring_scope", maximumLength: 30)) {
        case "this_event": scope = .thisEvent
        case "future_events": scope = .futureEvents
        default: throw CompanionAgentToolError.invalidArgument("recurring_scope")
        }
        let operation: AgentCalendarLookupOperation
        switch normalizedEnum(try call.singleLine("operation", maximumLength: 20)) {
        case "search":
            operation = .search
        case "update":
            operation = .update(try calendarPatch(from: call), scope)
        case "delete":
            operation = .delete(scope)
        default:
            throw CompanionAgentToolError.invalidArgument("operation")
        }
        return .init(search: search, operation: operation)
    }

    static func reminderDraft(from call: OpenAIToolCall) throws -> EventKitReminderDraft {
        let schedule = try reminderSchedule(
            allDay: call.boolean("all_day"),
            startISO: call.optionalSingleLine("start_iso8601", maximumLength: 80),
            dueISO: call.optionalSingleLine("due_iso8601", maximumLength: 80),
            startDate: call.optionalSingleLine("start_date", maximumLength: 10),
            dueDate: call.optionalSingleLine("due_date", maximumLength: 10),
            timeZone: call.optionalSingleLine("time_zone", maximumLength: 100)
        )
        return try EventKitReminderDraft(
            title: call.singleLine("title", maximumLength: 240),
            listName: call.optionalSingleLine("list_name", maximumLength: 160),
            schedule: schedule,
            notes: call.optionalMultiline("notes", maximumLength: 10_000),
            url: try optionalHTTPSURL(call, "url"),
            priority: try priority(call.singleLine("priority", maximumLength: 20)),
            recurrence: try recurrence(
                frequency: call.singleLine("recurrence_frequency", maximumLength: 20),
                interval: call.integer("recurrence_interval", range: 1 ... 99),
                weekdays: call.integerArray(
                    "recurrence_weekdays",
                    count: 0 ... 7,
                    itemRange: 1 ... 7
                ),
                endText: call.optionalSingleLine("recurrence_end_iso8601", maximumLength: 80),
                count: call.integer("recurrence_count", range: 0 ... 999)
            ),
            alertMinutesBeforeDue: call.integerArray(
                "alert_minutes_before_due",
                count: 0 ... 5,
                itemRange: 0 ... 10_080
            )
        )
    }

    static func reminderLookup(from call: OpenAIToolCall) throws -> AgentReminderLookupRequest {
        let dueStartText = try call.optionalSingleLine("due_start_iso8601", maximumLength: 80)
        let dueEndText = try call.optionalSingleLine("due_end_iso8601", maximumLength: 80)
        let dueStart = try dueStartText.map(parseISO8601)
        let dueEnd = try dueEndText.map(parseISO8601)
        let status: EventKitReminderSearchStatus
        switch normalizedEnum(try call.singleLine("status", maximumLength: 20)) {
        case "incomplete": status = .incomplete
        case "completed": status = .completed
        case "all": status = .all
        default: throw CompanionAgentToolError.invalidArgument("status")
        }
        let search = try EventKitReminderSearchRequest(
            query: call.singleLine("query", minimumLength: 0, maximumLength: 240),
            status: status,
            dueStart: dueStart,
            dueEnd: dueEnd,
            listName: call.optionalSingleLine("list_name", maximumLength: 160),
            limit: 20
        )
        let operation: AgentReminderLookupOperation
        switch normalizedEnum(try call.singleLine("operation", maximumLength: 20)) {
        case "search": operation = .search
        case "update": operation = .update(try reminderPatch(from: call))
        case "complete": operation = .completion(true)
        case "reopen": operation = .completion(false)
        case "delete": operation = .delete
        default: throw CompanionAgentToolError.invalidArgument("operation")
        }
        return .init(search: search, operation: operation)
    }

    private static func calendarPatch(from call: OpenAIToolCall) throws -> EventKitCalendarEventPatch {
        let clearFields = try clearFieldSet(
            call,
            allowed: ["location", "notes", "url", "recurrence", "alerts"]
        )
        var patch = EventKitCalendarEventPatch()
        if let title = try call.optionalSingleLine("new_title", maximumLength: 240) {
            patch.title = .set(title)
        }
        if try call.boolean("change_schedule") {
            if try call.boolean("new_all_day") {
                patch.schedule = .set(
                    .allDay(
                        start: try localDate(call, "new_start_date"),
                        endExclusive: try localDate(call, "new_end_date_exclusive")
                    )
                )
            } else {
                patch.schedule = .set(
                    .timed(
                        start: try call.iso8601("new_start_iso8601", mustBeFuture: false),
                        end: try call.iso8601("new_end_iso8601", mustBeFuture: false),
                        timeZoneIdentifier: try call.singleLine("new_time_zone", maximumLength: 100)
                    )
                )
            }
        }
        if let value = try call.optionalSingleLine("new_calendar_name", maximumLength: 160) {
            patch.calendarName = .set(value)
        }
        patch.location = try textChange(call, "new_location", clear: clearFields.contains("location"), maximumLength: 500)
        patch.notes = try textChange(call, "new_notes", clear: clearFields.contains("notes"), maximumLength: 10_000, multiline: true)
        patch.url = try urlChange(call, "new_url", clear: clearFields.contains("url"))
        if let value = try call.optionalSingleLine("new_availability", maximumLength: 30) {
            patch.availability = .set(try availability(value))
        }
        patch.recurrence = try recurrenceChange(
            call,
            prefix: "new_",
            clear: clearFields.contains("recurrence")
        )
        let alerts = try call.integerArray(
            "new_alert_minutes_before",
            count: 0 ... 5,
            itemRange: 0 ... 10_080
        )
        if clearFields.contains("alerts") {
            patch.alertMinutesBeforeStart = .clear
        } else if !alerts.isEmpty {
            patch.alertMinutesBeforeStart = .set(alerts)
        }
        return patch
    }

    private static func reminderPatch(from call: OpenAIToolCall) throws -> EventKitReminderPatch {
        let clearFields = try clearFieldSet(
            call,
            allowed: ["schedule", "notes", "url", "priority", "recurrence", "alerts"]
        )
        var patch = EventKitReminderPatch()
        if let title = try call.optionalSingleLine("new_title", maximumLength: 240) {
            patch.title = .set(title)
        }
        if let list = try call.optionalSingleLine("new_list_name", maximumLength: 160) {
            patch.listName = .set(list)
        }
        if clearFields.contains("schedule") {
            patch.schedule = .clear
        } else if try call.boolean("change_schedule") {
            patch.schedule = .set(
                try reminderSchedule(
                    allDay: call.boolean("new_all_day"),
                    startISO: call.optionalSingleLine("new_start_iso8601", maximumLength: 80),
                    dueISO: call.optionalSingleLine("new_due_iso8601", maximumLength: 80),
                    startDate: call.optionalSingleLine("new_start_date", maximumLength: 10),
                    dueDate: call.optionalSingleLine("new_due_date", maximumLength: 10),
                    timeZone: call.optionalSingleLine("new_time_zone", maximumLength: 100)
                )
            )
        }
        patch.notes = try textChange(call, "new_notes", clear: clearFields.contains("notes"), maximumLength: 10_000, multiline: true)
        patch.url = try urlChange(call, "new_url", clear: clearFields.contains("url"))
        if clearFields.contains("priority") {
            patch.priority = .clear
        } else if let value = try call.optionalSingleLine("new_priority", maximumLength: 20) {
            patch.priority = .set(try priority(value))
        }
        patch.recurrence = try recurrenceChange(
            call,
            prefix: "new_",
            clear: clearFields.contains("recurrence")
        )
        let alerts = try call.integerArray(
            "new_alert_minutes_before_due",
            count: 0 ... 5,
            itemRange: 0 ... 10_080
        )
        if clearFields.contains("alerts") {
            patch.alertMinutesBeforeDue = .clear
        } else if !alerts.isEmpty {
            patch.alertMinutesBeforeDue = .set(alerts)
        }
        return patch
    }

    private static func reminderSchedule(
        allDay: Bool,
        startISO: String?,
        dueISO: String?,
        startDate: String?,
        dueDate: String?,
        timeZone: String?
    ) throws -> EventKitReminderSchedule {
        if allDay {
            return try .init(
                start: try startDate.map { .allDay(try parseLocalDate($0)) },
                due: try dueDate.map { .allDay(try parseLocalDate($0)) }
            )
        }
        if startISO != nil || dueISO != nil {
            guard let timeZone, !timeZone.isEmpty else {
                throw CompanionAgentToolError.invalidArgument("time_zone")
            }
            return try .init(
                start: try startISO.map { .timed(try parseISO8601($0), timeZoneIdentifier: timeZone) },
                due: try dueISO.map { .timed(try parseISO8601($0), timeZoneIdentifier: timeZone) }
            )
        }
        return try .init()
    }

    private static func recurrenceChange(
        _ call: OpenAIToolCall,
        prefix: String,
        clear: Bool
    ) throws -> EventKitFieldChange<EventKitRecurrenceSpec> {
        if clear { return .clear }
        guard let frequency = try call.optionalSingleLine(
            "\(prefix)recurrence_frequency",
            maximumLength: 20
        ) else { return .keep }
        if normalizedEnum(frequency) == "none" { return .clear }
        let value = try recurrence(
            frequency: frequency,
            interval: call.integer("\(prefix)recurrence_interval", range: 1 ... 99),
            weekdays: call.integerArray(
                "\(prefix)recurrence_weekdays",
                count: 0 ... 7,
                itemRange: 1 ... 7
            ),
            endText: call.optionalSingleLine("\(prefix)recurrence_end_iso8601", maximumLength: 80),
            count: call.integer("\(prefix)recurrence_count", range: 0 ... 999)
        )
        guard let value else { return .clear }
        return .set(value)
    }

    private static func recurrence(
        frequency rawFrequency: String,
        interval: Int,
        weekdays: [Int],
        endText: String?,
        count: Int
    ) throws -> EventKitRecurrenceSpec? {
        let frequency: EventKitRecurrenceFrequency
        switch normalizedEnum(rawFrequency) {
        case "none":
            guard weekdays.isEmpty, endText == nil, count == 0 else {
                throw CompanionAgentToolError.invalidArgument("recurrence")
            }
            return nil
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default: throw CompanionAgentToolError.invalidArgument("recurrence_frequency")
        }
        guard endText == nil || count == 0 else {
            throw CompanionAgentToolError.invalidArgument("recurrence_end")
        }
        let recurrenceEnd: EventKitRecurrenceEnd
        if let endText {
            recurrenceEnd = .onDate(try parseISO8601(endText))
        } else if count > 0 {
            recurrenceEnd = .afterOccurrences(count)
        } else {
            recurrenceEnd = .never
        }
        let mappedWeekdays = try weekdays.map { raw -> EventKitWeekday in
            guard let weekday = EventKitWeekday(rawValue: raw) else {
                throw CompanionAgentToolError.invalidArgument("recurrence_weekdays")
            }
            return weekday
        }
        return try .init(
            frequency: frequency,
            interval: interval,
            weekdays: mappedWeekdays,
            end: recurrenceEnd
        )
    }

    private static func availability(_ rawValue: String) throws -> EventKitEventAvailability {
        switch normalizedEnum(rawValue) {
        case "system_default", "default": .systemDefault
        case "busy": .busy
        case "free": .free
        case "tentative": .tentative
        case "unavailable": .unavailable
        default: throw CompanionAgentToolError.invalidArgument("availability")
        }
    }

    private static func priority(_ rawValue: String) throws -> EventKitReminderPriority {
        switch normalizedEnum(rawValue) {
        case "none": .none
        case "high": .high
        case "medium": .medium
        case "low": .low
        default: throw CompanionAgentToolError.invalidArgument("priority")
        }
    }

    private static func textChange(
        _ call: OpenAIToolCall,
        _ argument: String,
        clear: Bool,
        maximumLength: Int,
        multiline: Bool = false
    ) throws -> EventKitFieldChange<String> {
        if clear { return .clear }
        let value = multiline
            ? try call.optionalMultiline(argument, maximumLength: maximumLength)
            : try call.optionalSingleLine(argument, maximumLength: maximumLength)
        return value.map(EventKitFieldChange.set) ?? .keep
    }

    private static func urlChange(
        _ call: OpenAIToolCall,
        _ argument: String,
        clear: Bool
    ) throws -> EventKitFieldChange<URL> {
        if clear { return .clear }
        return try optionalHTTPSURL(call, argument).map(EventKitFieldChange.set) ?? .keep
    }

    private static func clearFieldSet(
        _ call: OpenAIToolCall,
        allowed: Set<String>
    ) throws -> Set<String> {
        let values = try call.stringArray("clear_fields", count: 0 ... allowed.count, itemMaximumLength: 30)
            .map(normalizedEnum)
        guard Set(values).count == values.count, Set(values).isSubset(of: allowed) else {
            throw CompanionAgentToolError.invalidArgument("clear_fields")
        }
        return Set(values)
    }

    private static func optionalHTTPSURL(
        _ call: OpenAIToolCall,
        _ argument: String
    ) throws -> URL? {
        guard let value = try call.optionalSingleLine(argument, maximumLength: 2_048) else {
            return nil
        }
        guard let url = URL(string: value) else {
            throw CompanionAgentToolError.invalidArgument(argument)
        }
        return url
    }

    private static func localDate(_ call: OpenAIToolCall, _ argument: String) throws -> EventKitLocalDate {
        try parseLocalDate(call.singleLine(argument, maximumLength: 10))
    }

    private static func parseLocalDate(_ value: String) throws -> EventKitLocalDate {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            throw CompanionAgentToolError.invalidArgument("date")
        }
        return try EventKitLocalDate(year: year, month: month, day: day)
    }

    private static func parseISO8601(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            throw CompanionAgentToolError.invalidArgument("date")
        }
        return date
    }

    private static func normalizedEnum(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
