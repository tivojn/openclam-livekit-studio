import EventKit
import Foundation
import XCTest
@testable import OpenClamLiveKit

final class EventKitAgentFoundationTests: XCTestCase {
    func testLocalDateRejectsImpossibleGregorianDate() {
        XCTAssertThrowsError(try EventKitLocalDate(year: 2026, month: 2, day: 30))
        XCTAssertNoThrow(try EventKitLocalDate(year: 2028, month: 2, day: 29))
    }

    func testTimedEventScheduleRequiresAnEndAndKnownTimeZone() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertThrowsError(
            try EventKitCalendarSchedule
                .timed(start: start, end: start, timeZoneIdentifier: "Asia/Shanghai")
                .resolvedDates()
        )
        XCTAssertThrowsError(
            try EventKitCalendarSchedule
                .timed(
                    start: start,
                    end: start.addingTimeInterval(60),
                    timeZoneIdentifier: "Not/A_Time_Zone"
                )
                .resolvedDates()
        )
    }

    func testAllDayEventUsesExclusiveEndDate() throws {
        let day = try EventKitLocalDate(year: 2026, month: 8, day: 9)
        XCTAssertThrowsError(
            try EventKitCalendarSchedule.allDay(start: day, endExclusive: day).resolvedDates()
        )
    }

    func testFiveMinuteCalendarAlertMapsToExactNegative300Seconds() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = try EventKitCalendarEventDraft(
            title: "Dentist",
            schedule: .timed(
                start: start,
                end: start.addingTimeInterval(30 * 60),
                timeZoneIdentifier: "Asia/Shanghai"
            ),
            alertMinutesBeforeStart: [15, 5]
        )

        XCTAssertEqual(draft.alertMinutesBeforeStart, [5, 15])
        let alarms = EventKitAgentMapper.eventAlarms(
            minutesBeforeStart: draft.alertMinutesBeforeStart
        )
        XCTAssertEqual(alarms.map(\.relativeOffset), [-300, -900])
        XCTAssertEqual(
            EventKitAgentMapper.eventAlertMinutesBeforeStart(alarms),
            [5, 15]
        )
    }

    func testAlertValidationCapsCountRangeAndDuplicates() {
        XCTAssertThrowsError(try EventKitAgentValidation.alertOffsets([5, 5]))
        XCTAssertThrowsError(try EventKitAgentValidation.alertOffsets([-1]))
        XCTAssertThrowsError(try EventKitAgentValidation.alertOffsets([0, 1, 2, 3, 4, 5]))
        XCTAssertNoThrow(try EventKitAgentValidation.alertOffsets([0, 5, 10_080]))
    }

    func testWeeklyRecurrenceMapsWeekdaysAndOccurrenceEnd() throws {
        let spec = try EventKitRecurrenceSpec(
            frequency: .weekly,
            interval: 2,
            weekdays: [.monday, .friday],
            end: .afterOccurrences(8)
        )

        let rule = EventKitAgentMapper.recurrenceRule(from: spec)
        XCTAssertEqual(rule.frequency, .weekly)
        XCTAssertEqual(rule.interval, 2)
        XCTAssertEqual(rule.daysOfTheWeek?.map(\.dayOfTheWeek), [.monday, .friday])
        XCTAssertEqual(rule.recurrenceEnd?.occurrenceCount, 8)
    }

    func testReminderDueOnlyBecomesEffectiveStartForEventKit() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let schedule = try EventKitReminderSchedule(
            due: .timed(due, timeZoneIdentifier: "Asia/Shanghai")
        )

        XCTAssertEqual(schedule.effectiveStart, schedule.due)
        let alarms = try EventKitAgentMapper.reminderAlarms(
            minutesBeforeDue: [5],
            schedule: schedule,
            hasRecurrence: false
        )
        XCTAssertEqual(alarms.count, 1)
        XCTAssertNil(alarms[0].absoluteDate)
        XCTAssertEqual(alarms[0].relativeOffset, -300)
    }

    func testReminderWithDifferentStartRejectsUnsafeAbsoluteDueOffset() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let due = start.addingTimeInterval(3_600)
        let schedule = try EventKitReminderSchedule(
            start: .timed(start, timeZoneIdentifier: "UTC"),
            due: .timed(due, timeZoneIdentifier: "UTC")
        )

        XCTAssertThrowsError(
            try EventKitAgentMapper.reminderAlarms(
                minutesBeforeDue: [5],
                schedule: schedule,
                hasRecurrence: false
            )
        )
        XCTAssertThrowsError(
            try EventKitAgentMapper.reminderAlarms(
                minutesBeforeDue: [5],
                schedule: schedule,
                hasRecurrence: true
            )
        )
    }

    func testAlarmInspectionSeparatesSupportedRelativeAndUnsafeAbsoluteAlarms() throws {
        let absolute = EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_800_000_000))
        let fiveMinutes = EKAlarm(relativeOffset: -300)
        let fractionalMinute = EKAlarm(relativeOffset: -301)

        let eventInspection = EventKitAgentMapper.inspectEventAlarms([
            absolute,
            fiveMinutes,
            fractionalMinute,
        ])
        XCTAssertEqual(eventInspection.supportedMinutesBefore, [5])
        XCTAssertEqual(eventInspection.unsupportedAlarmCount, 2)
        XCTAssertFalse(eventInspection.isSafeForEditing)

        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let schedule = try EventKitReminderSchedule(
            due: .timed(due, timeZoneIdentifier: "UTC")
        )
        let reminderInspection = EventKitAgentMapper.inspectReminderAlarms(
            [absolute, fiveMinutes],
            schedule: schedule
        )
        XCTAssertEqual(reminderInspection.supportedMinutesBefore, [5])
        XCTAssertEqual(reminderInspection.unsupportedAlarmCount, 1)
        XCTAssertFalse(reminderInspection.isSafeForEditing)
    }

    func testReminderAlarmInspectionFailsClosedForDifferentStartAndDue() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let schedule = try EventKitReminderSchedule(
            start: .timed(start, timeZoneIdentifier: "UTC"),
            due: .timed(start.addingTimeInterval(3_600), timeZoneIdentifier: "UTC")
        )
        let inspection = EventKitAgentMapper.inspectReminderAlarms(
            [EKAlarm(relativeOffset: -300)],
            schedule: schedule
        )

        XCTAssertEqual(inspection.supportedMinutesBefore, [])
        XCTAssertEqual(inspection.unsupportedAlarmCount, 1)
        XCTAssertFalse(inspection.isSafeForEditing)
    }

    func testAllDayReminderRejectsMinuteOffsetAlarm() throws {
        let due = try EventKitLocalDate(year: 2026, month: 8, day: 9)
        let schedule = try EventKitReminderSchedule(due: .allDay(due))
        XCTAssertThrowsError(
            try EventKitAgentMapper.reminderAlarms(
                minutesBeforeDue: [5],
                schedule: schedule,
                hasRecurrence: false
            )
        )
    }

    func testReminderDateComponentsRoundTripTimedAndAllDayValues() throws {
        let timed = EventKitReminderDateValue.timed(
            Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let timedComponents = try EventKitAgentMapper.dateComponents(from: timed)
        XCTAssertEqual(
            try EventKitAgentMapper.reminderDateValue(from: timedComponents),
            timed
        )

        let allDay = EventKitReminderDateValue.allDay(
            try EventKitLocalDate(year: 2026, month: 8, day: 9)
        )
        let allDayComponents = try EventKitAgentMapper.dateComponents(from: allDay)
        XCTAssertNil(allDayComponents.hour)
        XCTAssertEqual(
            try EventKitAgentMapper.reminderDateValue(from: allDayComponents),
            allDay
        )
    }

    func testURLsRequireHTTPSAndRejectEmbeddedCredentials() throws {
        XCTAssertThrowsError(
            try EventKitAgentValidation.httpsURL(
                URL(string: "http://example.com/event"),
                field: "event URL"
            )
        )
        XCTAssertThrowsError(
            try EventKitAgentValidation.httpsURL(
                URL(string: "https://user:password@example.com/event"),
                field: "event URL"
            )
        )
        XCTAssertEqual(
            try EventKitAgentValidation.httpsURL(
                URL(string: "https://example.com/event"),
                field: "event URL"
            )?.host,
            "example.com"
        )
    }

    func testSearchAndPatchValidationAreBounded() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertThrowsError(
            try EventKitCalendarSearchRequest(
                query: "",
                rangeStart: start,
                rangeEnd: start.addingTimeInterval(367 * 24 * 60 * 60)
            )
        )
        XCTAssertThrowsError(
            try EventKitCalendarSearchRequest(
                query: "",
                rangeStart: start,
                rangeEnd: start.addingTimeInterval(60),
                limit: 51
            )
        )
        XCTAssertFalse(EventKitCalendarEventPatch().hasChanges)
        var patch = EventKitCalendarEventPatch()
        patch.alertMinutesBeforeStart = .set([5])
        XCTAssertTrue(patch.hasChanges)
    }

    @MainActor
    func testLocalSelectionTokensAreOneShot() throws {
        let registry = EventKitOneShotRegistry<String>()
        let token = registry.issue("private local value")

        XCTAssertEqual(try registry.consume(token), "private local value")
        XCTAssertThrowsError(try registry.consume(token)) { error in
            XCTAssertEqual(error as? EventKitAgentError, .localSelectionMissing)
        }
    }

    @MainActor
    func testLocalSelectionTokensExpireWithoutExposingStoredValue() throws {
        var now = Date(timeIntervalSince1970: 100)
        let registry = EventKitOneShotRegistry<String>(tokenLifetime: 10, now: { now })
        let token = registry.issue("private local value")
        now = now.addingTimeInterval(10)

        XCTAssertThrowsError(try registry.consume(token)) { error in
            XCTAssertEqual(error as? EventKitAgentError, .localSelectionExpired)
        }
        XCTAssertEqual(registry.count, 0)
    }
}
