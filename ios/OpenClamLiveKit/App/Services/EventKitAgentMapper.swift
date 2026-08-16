import EventKit
import Foundation

enum EventKitAgentMapper {
    static func recurrenceRule(from spec: EventKitRecurrenceSpec) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch spec.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }

        let end: EKRecurrenceEnd?
        switch spec.end {
        case .never:
            end = nil
        case let .onDate(date):
            end = EKRecurrenceEnd(end: date)
        case let .afterOccurrences(count):
            end = EKRecurrenceEnd(occurrenceCount: count)
        }

        guard !spec.weekdays.isEmpty else {
            return EKRecurrenceRule(
                recurrenceWith: frequency,
                interval: spec.interval,
                end: end
            )
        }

        let weekdays = spec.weekdays.map { weekday in
            EKRecurrenceDayOfWeek(EKWeekday(rawValue: weekday.rawValue)!)
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: spec.interval,
            daysOfTheWeek: weekdays,
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: end
        )
    }

    static func dateComponents(from value: EventKitReminderDateValue) throws -> DateComponents {
        switch value {
        case let .timed(date, timeZoneIdentifier):
            let timeZone = try EventKitAgentValidation.timeZone(identifier: timeZoneIdentifier)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            var components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: date
            )
            components.calendar = calendar
            components.timeZone = timeZone
            return components
        case let .allDay(localDate):
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.year = localDate.year
            components.month = localDate.month
            components.day = localDate.day
            return components
        }
    }

    static func reminderDateValue(from components: DateComponents?) throws -> EventKitReminderDateValue? {
        guard let components else { return nil }
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            throw EventKitAgentError.invalidField(
                "reminder schedule",
                "the stored reminder is missing a calendar date"
            )
        }

        let isTimed = components.hour != nil || components.minute != nil || components.second != nil
        if !isTimed {
            return .allDay(try EventKitLocalDate(year: year, month: month, day: day))
        }

        let timeZone = components.timeZone ?? .current
        var calendar = components.calendar ?? Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var resolved = components
        resolved.calendar = calendar
        resolved.timeZone = timeZone
        guard let date = calendar.date(from: resolved) else {
            throw EventKitAgentError.invalidField(
                "reminder schedule",
                "the stored reminder date could not be resolved"
            )
        }
        return .timed(date, timeZoneIdentifier: timeZone.identifier)
    }

    static func eventAlarms(minutesBeforeStart values: [Int]) -> [EKAlarm] {
        values.map { EKAlarm(relativeOffset: -TimeInterval($0 * 60)) }
    }

    static func eventAlertMinutesBeforeStart(_ alarms: [EKAlarm]?) -> [Int] {
        inspectEventAlarms(alarms).supportedMinutesBefore
    }

    static func inspectEventAlarms(_ alarms: [EKAlarm]?) -> EventKitAlarmInspection {
        inspectRelativeAlarms(alarms)
    }

    static func reminderAlarms(
        minutesBeforeDue values: [Int],
        schedule: EventKitReminderSchedule,
        hasRecurrence: Bool
    ) throws -> [EKAlarm] {
        guard !values.isEmpty else { return [] }
        guard let due = schedule.due else {
            throw EventKitAgentError.invalidField(
                "reminder alerts",
                "a due date is required for minute-offset alerts"
            )
        }
        guard case let .timed(dueDate, _) = due else {
            throw EventKitAgentError.invalidField(
                "reminder alerts",
                "minute-offset alerts require a timed due date"
            )
        }
        guard case let .timed(startDate, _)? = schedule.effectiveStart else {
            throw EventKitAgentError.invalidField(
                "reminder alerts",
                "a timed start date is required for minute-offset alerts"
            )
        }

        guard abs(dueDate.timeIntervalSince(startDate)) < 0.5 else {
            let recurrenceContext = hasRecurrence ? "repeating " : ""
            throw EventKitAgentError.invalidField(
                "reminder alerts",
                "\(recurrenceContext)reminders need matching start and due times for safe minute-offset alerts"
            )
        }
        return values.map { EKAlarm(relativeOffset: -TimeInterval($0 * 60)) }
    }

    static func reminderAlertMinutesBeforeDue(
        _ alarms: [EKAlarm]?,
        schedule: EventKitReminderSchedule
    ) -> [Int] {
        inspectReminderAlarms(alarms, schedule: schedule).supportedMinutesBefore
    }

    static func inspectReminderAlarms(
        _ alarms: [EKAlarm]?,
        schedule: EventKitReminderSchedule
    ) -> EventKitAlarmInspection {
        let alarms = alarms ?? []
        guard !alarms.isEmpty else {
            return EventKitAlarmInspection(
                supportedMinutesBefore: [],
                unsupportedAlarmCount: 0
            )
        }
        guard case let .timed(dueDate, _)? = schedule.due,
              case let .timed(startDate, _)? = schedule.effectiveStart,
              abs(dueDate.timeIntervalSince(startDate)) < 0.5 else {
            return EventKitAlarmInspection(
                supportedMinutesBefore: [],
                unsupportedAlarmCount: alarms.count
            )
        }
        return inspectRelativeAlarms(alarms)
    }

    static func eventAvailability(from availability: EKEventAvailability) -> EventKitEventAvailability {
        switch availability {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        case .notSupported: .systemDefault
        @unknown default: .systemDefault
        }
    }

    static func nativeAvailability(
        from availability: EventKitEventAvailability
    ) -> (value: EKEventAvailability, mask: EKCalendarEventAvailabilityMask)? {
        switch availability {
        case .systemDefault:
            nil
        case .busy:
            (.busy, .busy)
        case .free:
            (.free, .free)
        case .tentative:
            (.tentative, .tentative)
        case .unavailable:
            (.unavailable, .unavailable)
        }
    }

    static func resolvedDate(for value: EventKitReminderDateValue) throws -> Date {
        switch value {
        case let .timed(date, timeZoneIdentifier):
            _ = try EventKitAgentValidation.timeZone(identifier: timeZoneIdentifier)
            return date
        case let .allDay(localDate):
            return try localDate.date(in: .current)
        }
    }

    private static func inspectRelativeAlarms(
        _ alarms: [EKAlarm]?
    ) -> EventKitAlarmInspection {
        var supported: [Int] = []
        var unsupportedCount = 0
        for alarm in alarms ?? [] {
            guard alarm.absoluteDate == nil,
                  alarm.structuredLocation == nil,
                  alarm.proximity == .none,
                  let minutes = exactSupportedMinutes(-alarm.relativeOffset / 60),
                  !supported.contains(minutes),
                  supported.count < EventKitAgentLimits.maximumAlertCount else {
                unsupportedCount += 1
                continue
            }
            supported.append(minutes)
        }
        return EventKitAlarmInspection(
            supportedMinutesBefore: supported.sorted(),
            unsupportedAlarmCount: unsupportedCount
        )
    }

    private static func exactSupportedMinutes(_ rawValue: Double) -> Int? {
        guard rawValue.isFinite else { return nil }
        let rounded = rawValue.rounded()
        guard abs(rawValue - rounded) < 0.000_001,
              let minutes = Int(exactly: rounded),
              (0 ... EventKitAgentLimits.maximumAlertMinutes).contains(minutes) else {
            return nil
        }
        return minutes
    }
}
