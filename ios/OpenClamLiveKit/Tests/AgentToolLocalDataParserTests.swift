import Foundation
import XCTest
@testable import OpenClamLiveKit

final class AgentToolLocalDataParserTests: XCTestCase {
    func testAdvancedCalendarCreateParsesExactFiveMinuteAlert() throws {
        let call = toolCall(
            "stage_calendar_event",
            arguments: [
                "title": .string("Architecture review"),
                "all_day": .bool(false),
                "start_iso8601": .string("2030-06-10T09:00:00+08:00"),
                "end_iso8601": .string("2030-06-10T10:30:00+08:00"),
                "start_date": .string(""),
                "end_date_exclusive": .string(""),
                "time_zone": .string("Asia/Shanghai"),
                "calendar_name": .string("Work"),
                "location": .string("Room 12"),
                "notes": .string("Review the agent architecture."),
                "url": .string("https://example.com/architecture"),
                "availability": .string("busy"),
                "recurrence_frequency": .string("weekly"),
                "recurrence_interval": .integer(2),
                "recurrence_weekdays": integers([2, 5]),
                "recurrence_end_iso8601": .string(""),
                "recurrence_count": .integer(6),
                "alert_minutes_before": integers([5]),
            ]
        )

        let draft = try AgentToolLocalDataParser.calendarDraft(from: call)

        XCTAssertEqual(draft.title, "Architecture review")
        XCTAssertEqual(draft.calendarName, "Work")
        XCTAssertEqual(draft.location, "Room 12")
        XCTAssertEqual(draft.notes, "Review the agent architecture.")
        XCTAssertEqual(draft.url, URL(string: "https://example.com/architecture"))
        XCTAssertEqual(draft.availability, .busy)
        XCTAssertEqual(draft.alertMinutesBeforeStart, [5])
        XCTAssertEqual(
            EventKitAgentMapper.eventAlarms(minutesBeforeStart: draft.alertMinutesBeforeStart)
                .first?.relativeOffset,
            -300
        )

        guard case let .timed(start, end, timeZoneIdentifier) = draft.schedule else {
            return XCTFail("Expected a timed Calendar event")
        }
        XCTAssertEqual(start, try isoDate("2030-06-10T09:00:00+08:00"))
        XCTAssertEqual(end, try isoDate("2030-06-10T10:30:00+08:00"))
        XCTAssertEqual(timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(
            draft.recurrence,
            try EventKitRecurrenceSpec(
                frequency: .weekly,
                interval: 2,
                weekdays: [.monday, .thursday],
                end: .afterOccurrences(6)
            )
        )
    }

    func testCalendarUpdateParsesCandidateBoundTwoReviewPatch() throws {
        let call = toolCall(
            "stage_calendar_lookup",
            arguments: [
                "operation": .string("update"),
                "query": .string("Architecture review"),
                "range_start_iso8601": .string("2030-06-10T00:00:00+08:00"),
                "range_end_iso8601": .string("2030-06-11T00:00:00+08:00"),
                "calendar_name": .string("Work"),
                "recurring_scope": .string("future_events"),
                "new_title": .string("Architecture review — moved"),
                "change_schedule": .bool(true),
                "new_all_day": .bool(false),
                "new_start_iso8601": .string("2030-06-10T11:00:00+08:00"),
                "new_end_iso8601": .string("2030-06-10T12:30:00+08:00"),
                "new_start_date": .string(""),
                "new_end_date_exclusive": .string(""),
                "new_time_zone": .string("Asia/Shanghai"),
                "new_calendar_name": .string("Planning"),
                "new_location": .string("Room 18"),
                "new_notes": .string(""),
                "new_url": .string(""),
                "new_availability": .string("free"),
                "new_recurrence_frequency": .string("weekly"),
                "new_recurrence_interval": .integer(1),
                "new_recurrence_weekdays": integers([2]),
                "new_recurrence_end_iso8601": .string(""),
                "new_recurrence_count": .integer(4),
                "new_alert_minutes_before": integers([5]),
                "clear_fields": strings(["notes", "url"]),
            ]
        )

        let parsed = try AgentToolLocalDataParser.calendarLookup(from: call)

        XCTAssertEqual(parsed.search.query, "Architecture review")
        XCTAssertEqual(parsed.search.calendarName, "Work")
        guard case let .update(patch, scope) = parsed.operation else {
            return XCTFail("Expected a Calendar update operation")
        }
        XCTAssertEqual(scope, .futureEvents)
        XCTAssertEqual(patch.title, .set("Architecture review — moved"))
        XCTAssertEqual(patch.calendarName, .set("Planning"))
        XCTAssertEqual(patch.location, .set("Room 18"))
        XCTAssertEqual(patch.notes, .clear)
        XCTAssertEqual(patch.url, .clear)
        XCTAssertEqual(patch.availability, .set(.free))
        XCTAssertEqual(patch.alertMinutesBeforeStart, .set([5]))
        XCTAssertEqual(
            patch.recurrence,
            .set(
                try EventKitRecurrenceSpec(
                    frequency: .weekly,
                    weekdays: [.monday],
                    end: .afterOccurrences(4)
                )
            )
        )
        guard case let .set(.timed(start, end, timeZoneIdentifier)) = patch.schedule else {
            return XCTFail("Expected a replacement timed schedule")
        }
        XCTAssertEqual(start, try isoDate("2030-06-10T11:00:00+08:00"))
        XCTAssertEqual(end, try isoDate("2030-06-10T12:30:00+08:00"))
        XCTAssertEqual(timeZoneIdentifier, "Asia/Shanghai")

        let afterSelection = EventKitCalendarAfterSelection.update(
            patch: patch,
            scope: scope
        )
        let reviewFields = EventKitAgentReviewFormatter.sections(
            for: .calendarSearch(
                request: parsed.search,
                afterSelection: afterSelection
            )
        ).flatMap(\.fields)
        XCTAssertEqual(
            reviewFields.first(where: { $0.label == "After results" })?.proposed,
            "Choose one result locally, then review the exact update"
        )
    }

    func testAdvancedReminderCreateParsesDuePriorityRecurrenceAndAlert() throws {
        let call = toolCall(
            "stage_reminder",
            arguments: [
                "title": .string("Submit expenses"),
                "list_name": .string("Work"),
                "all_day": .bool(false),
                "start_iso8601": .string(""),
                "due_iso8601": .string("2030-06-12T17:00:00+08:00"),
                "start_date": .string(""),
                "due_date": .string(""),
                "time_zone": .string("Asia/Shanghai"),
                "notes": .string("Attach the taxi receipt."),
                "url": .string("https://example.com/expenses"),
                "priority": .string("high"),
                "recurrence_frequency": .string("monthly"),
                "recurrence_interval": .integer(1),
                "recurrence_weekdays": integers([]),
                "recurrence_end_iso8601": .string(""),
                "recurrence_count": .integer(3),
                "alert_minutes_before_due": integers([5]),
            ]
        )

        let draft = try AgentToolLocalDataParser.reminderDraft(from: call)

        XCTAssertEqual(draft.title, "Submit expenses")
        XCTAssertEqual(draft.listName, "Work")
        XCTAssertEqual(draft.notes, "Attach the taxi receipt.")
        XCTAssertEqual(draft.url, URL(string: "https://example.com/expenses"))
        XCTAssertEqual(draft.priority, .high)
        XCTAssertEqual(draft.alertMinutesBeforeDue, [5])
        XCTAssertNil(draft.schedule.start)
        XCTAssertEqual(
            draft.schedule.due,
            .timed(
                try isoDate("2030-06-12T17:00:00+08:00"),
                timeZoneIdentifier: "Asia/Shanghai"
            )
        )
        XCTAssertEqual(draft.schedule.effectiveStart, draft.schedule.due)
        XCTAssertEqual(
            draft.recurrence,
            try EventKitRecurrenceSpec(
                frequency: .monthly,
                end: .afterOccurrences(3)
            )
        )
    }

    func testReminderCompletionLookupDoesNotManufactureAnUpdatePatch() throws {
        let call = toolCall(
            "stage_reminder_lookup",
            arguments: [
                "operation": .string("complete"),
                "query": .string("Submit expenses"),
                "status": .string("incomplete"),
                "due_start_iso8601": .string(""),
                "due_end_iso8601": .string(""),
                "list_name": .string("Work"),
                "new_title": .string(""),
                "new_list_name": .string(""),
                "change_schedule": .bool(false),
                "new_all_day": .bool(false),
                "new_start_iso8601": .string(""),
                "new_due_iso8601": .string(""),
                "new_start_date": .string(""),
                "new_due_date": .string(""),
                "new_time_zone": .string(""),
                "new_notes": .string(""),
                "new_url": .string(""),
                "new_priority": .string(""),
                "new_recurrence_frequency": .string(""),
                "new_recurrence_interval": .integer(1),
                "new_recurrence_weekdays": integers([]),
                "new_recurrence_end_iso8601": .string(""),
                "new_recurrence_count": .integer(0),
                "new_alert_minutes_before_due": integers([]),
                "clear_fields": strings([]),
            ]
        )

        let parsed = try AgentToolLocalDataParser.reminderLookup(from: call)

        XCTAssertEqual(parsed.search.query, "Submit expenses")
        XCTAssertEqual(parsed.search.status, .incomplete)
        XCTAssertEqual(parsed.search.listName, "Work")
        XCTAssertNil(parsed.search.dueStart)
        XCTAssertNil(parsed.search.dueEnd)
        XCTAssertEqual(parsed.operation, .completion(true))
        guard case let .completion(completed) = parsed.operation else {
            return XCTFail("Expected a completion lookup")
        }
        XCTAssertEqual(EventKitReminderAfterSelection.complete(completed), .complete(true))
    }

    func testContactFieldArraysMapAliasesAndClassifyNotesAsUnavailable() throws {
        let call = toolCall(
            "stage_contacts_search",
            arguments: [
                "query": .string("Emma"),
                "search_fields": strings(["name", "organization", "phone_number"]),
                "requested_fields": strings(["email_address", "postal_address", "notes"]),
            ]
        )

        let searchFields = try AgentToolLocalDataParser.contactFields(
            from: call,
            argument: "search_fields"
        )
        let requestedFields = try AgentToolLocalDataParser.contactFields(
            from: call,
            argument: "requested_fields"
        )

        XCTAssertEqual(searchFields, [.name, .organization, .phone])
        XCTAssertEqual(requestedFields, [.email, .postalAddress, .note])
        XCTAssertEqual(LocalContactFieldKind.email.availability, .available)
        guard case let .unavailable(reason) = LocalContactFieldKind.note.availability else {
            return XCTFail("Contact Notes must remain explicitly unavailable")
        }
        XCTAssertEqual(reason, LocalContactFieldKind.noteUnavailableReason)
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("entitlement"))
        XCTAssertThrowsError(try LocalContactSearchRequest.validate(fields: requestedFields)) { error in
            XCTAssertEqual(
                error as? LocalContactStoreError,
                .unavailableField(.note, reason: LocalContactFieldKind.noteUnavailableReason)
            )
        }
    }

    private func toolCall(
        _ name: String,
        arguments: [String: AgentJSONValue]
    ) -> OpenAIToolCall {
        OpenAIToolCall(
            callID: UUID().uuidString,
            name: name,
            arguments: arguments,
            rawArguments: "{}"
        )
    }

    private func strings(_ values: [String]) -> AgentJSONValue {
        .array(values.map(AgentJSONValue.string))
    }

    private func integers(_ values: [Int]) -> AgentJSONValue {
        .array(values.map(AgentJSONValue.integer))
    }

    private func isoDate(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}
