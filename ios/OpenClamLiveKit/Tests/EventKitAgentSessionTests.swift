import Foundation
import XCTest
@testable import OpenClamLiveKit

@MainActor
final class EventKitAgentSessionTests: XCTestCase {
    func testCalendarWorkflowStagesReadWithoutCallingEventKit() throws {
        let service = RecordingEventKitAgentService()
        let session = EventKitAgentSession(service: service)
        let request = try calendarSearchRequest()

        let requestID = try session.stageCalendarWorkflow(
            search: request,
            afterSelection: .delete(scope: .thisEvent)
        )

        XCTAssertEqual(session.pendingRequest?.id, requestID)
        XCTAssertEqual(service.operationCount, 0)
        guard case let .calendarSearch(stagedRequest, afterSelection)? = session.pendingRequest?.operation else {
            return XCTFail("Expected a staged Calendar workflow")
        }
        XCTAssertEqual(stagedRequest, request)
        XCTAssertEqual(afterSelection, .delete(scope: .thisEvent))
    }

    func testReminderWorkflowStagesReadWithoutCallingEventKit() throws {
        let service = RecordingEventKitAgentService()
        let session = EventKitAgentSession(service: service)
        let request = try EventKitReminderSearchRequest(query: "passport")

        _ = try session.stageReminderWorkflow(
            search: request,
            afterSelection: .complete(true)
        )

        XCTAssertEqual(service.operationCount, 0)
        guard case let .reminderSearch(stagedRequest, afterSelection)? = session.pendingRequest?.operation else {
            return XCTFail("Expected a staged Reminders workflow")
        }
        XCTAssertEqual(stagedRequest, request)
        XCTAssertEqual(afterSelection, .complete(true))
    }

    func testPendingReviewCannotBeSilentlyReplaced() throws {
        let session = EventKitAgentSession(service: RecordingEventKitAgentService())
        _ = try session.stageCalendarSearch(calendarSearchRequest())

        XCTAssertThrowsError(
            try session.stageReminderSearch(EventKitReminderSearchRequest(query: ""))
        ) { error in
            XCTAssertEqual(error as? EventKitAgentSessionError, .pendingReviewExists)
        }
    }

    func testResetCancelsReviewAndInvalidatesLocalTokens() throws {
        let service = RecordingEventKitAgentService()
        let session = EventKitAgentSession(service: service)
        _ = try session.stageCalendarSearch(calendarSearchRequest())

        session.reset()

        XCTAssertNil(session.pendingRequest)
        XCTAssertTrue(session.calendarResults.isEmpty)
        XCTAssertTrue(session.reminderResults.isEmpty)
        XCTAssertEqual(service.invalidateCount, 1)
        XCTAssertEqual(service.operationCount, 0)
    }

    func testCalendarSelectionPlannerBindsPrivateCandidateToExactUpdate() throws {
        let candidate = calendarCandidate()
        var patch = EventKitCalendarEventPatch()
        patch.location = .set("Gate 12")
        patch.alertMinutesBeforeStart = .set([5])

        let operation = try XCTUnwrap(
            EventKitAgentWorkflowPlanner.calendarOperation(
                afterSelection: .update(patch: patch, scope: .futureEvents),
                current: candidate
            )
        )

        guard case let .calendarUpdate(current, stagedPatch, scope) = operation else {
            return XCTFail("Expected a candidate-bound update")
        }
        XCTAssertEqual(current, candidate)
        XCTAssertEqual(stagedPatch, patch)
        XCTAssertEqual(scope, .futureEvents)
    }

    func testReminderSelectionPlannerBindsPrivateCandidateToCompletion() throws {
        let candidate = reminderCandidate()
        let operation = try XCTUnwrap(
            EventKitAgentWorkflowPlanner.reminderOperation(
                afterSelection: .complete(true),
                current: candidate
            )
        )

        XCTAssertEqual(operation, .reminderCompletion(current: candidate, completed: true))
    }

    func testWorkflowRejectsAnEmptyUpdateBeforeAnyRead() throws {
        let service = RecordingEventKitAgentService()
        let session = EventKitAgentSession(service: service)

        XCTAssertThrowsError(
            try session.stageCalendarWorkflow(
                search: calendarSearchRequest(),
                afterSelection: .update(
                    patch: EventKitCalendarEventPatch(),
                    scope: .thisEvent
                )
            )
        ) { error in
            XCTAssertEqual(error as? EventKitAgentSessionError, .emptyUpdate)
        }
        XCTAssertNil(session.pendingRequest)
        XCTAssertEqual(service.operationCount, 0)
    }

    func testReviewShowsAdvancedDetailsAndExactFiveMinuteAlert() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let recurrence = try EventKitRecurrenceSpec(
            frequency: .weekly,
            weekdays: [.monday],
            end: .afterOccurrences(4)
        )
        let draft = try EventKitCalendarEventDraft(
            title: "Flight",
            schedule: .timed(
                start: start,
                end: start.addingTimeInterval(3_600),
                timeZoneIdentifier: "Asia/Shanghai"
            ),
            calendarName: "Travel",
            location: "Gate 12",
            notes: "Bring passport",
            url: try XCTUnwrap(URL(string: "https://example.com/flight")),
            availability: .busy,
            recurrence: recurrence,
            alertMinutesBeforeStart: [5]
        )

        let fields = EventKitAgentReviewFormatter.sections(for: .calendarCreate(draft))
            .flatMap(\.fields)
        XCTAssertEqual(fields.first(where: { $0.label == "Calendar" })?.proposed, "Travel")
        XCTAssertEqual(fields.first(where: { $0.label == "Location" })?.proposed, "Gate 12")
        XCTAssertEqual(fields.first(where: { $0.label == "Notes" })?.proposed, "Bring passport")
        XCTAssertEqual(fields.first(where: { $0.label == "URL" })?.proposed, "https://example.com/flight")
        XCTAssertEqual(fields.first(where: { $0.label == "Availability" })?.proposed, "Busy")
        XCTAssertEqual(fields.first(where: { $0.label == "Alerts" })?.proposed, "5 minutes before")
        XCTAssertTrue(fields.first(where: { $0.label == "Recurrence" })?.proposed?.contains("Monday") == true)
    }

    func testTimedReviewsUseStagedNewYorkTimeZoneOnShanghaiDevice() throws {
        let originalTimeZone = NSTimeZone.default
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        NSTimeZone.default = shanghai
        defer { NSTimeZone.default = originalTimeZone }

        let newYorkIdentifier = "America/New_York"
        let newYork = try XCTUnwrap(TimeZone(identifier: newYorkIdentifier))
        let start = Date(timeIntervalSince1970: 1_907_315_200)
        let calendar = calendarCandidate(timeZoneIdentifier: newYorkIdentifier)
        let timedStart = EventKitReminderDateValue.timed(
            start,
            timeZoneIdentifier: newYorkIdentifier
        )
        let reminder = reminderCandidate(start: timedStart, due: timedStart)
        let calendarDraft = try EventKitCalendarEventDraft(
            title: "New York call",
            schedule: .timed(
                start: start,
                end: start.addingTimeInterval(3_600),
                timeZoneIdentifier: newYorkIdentifier
            )
        )
        let reminderDraft = try EventKitReminderDraft(
            title: "New York reminder",
            schedule: EventKitReminderSchedule(due: timedStart)
        )

        let expectedFormatter = DateFormatter()
        expectedFormatter.dateStyle = .medium
        expectedFormatter.timeStyle = .short
        expectedFormatter.timeZone = newYork
        let expectedNewYork = expectedFormatter.string(from: start)
        expectedFormatter.timeZone = shanghai
        let wrongShanghai = expectedFormatter.string(from: start)
        XCTAssertNotEqual(expectedNewYork, wrongShanghai)

        let calendarText = EventKitAgentReviewFormatter.calendarSchedule(calendar)
        let reminderText = EventKitAgentReviewFormatter.reminderSchedule(reminder)
        let stagedCalendarText = EventKitAgentReviewFormatter.sections(
            for: .calendarCreate(calendarDraft)
        ).flatMap(\.fields).first { $0.label == "Schedule" }?.proposed
        let stagedReminderText = EventKitAgentReviewFormatter.sections(
            for: .reminderCreate(reminderDraft)
        ).flatMap(\.fields).first { $0.label == "Due" }?.proposed
        XCTAssertTrue(calendarText.contains(expectedNewYork))
        XCTAssertFalse(calendarText.contains(wrongShanghai))
        XCTAssertTrue(reminderText.contains(expectedNewYork))
        XCTAssertFalse(reminderText.contains(wrongShanghai))
        XCTAssertTrue(stagedCalendarText?.contains(expectedNewYork) == true)
        XCTAssertFalse(stagedCalendarText?.contains(wrongShanghai) == true)
        XCTAssertTrue(stagedReminderText?.contains(expectedNewYork) == true)
        XCTAssertFalse(stagedReminderText?.contains(wrongShanghai) == true)
    }

    func testUnsafeExistingAlarmsBlockUpdateAndCompletionButAllowExplicitDelete() throws {
        let unsafeCalendar = calendarCandidate(unsupportedAlarmCount: 1)
        var calendarPatch = EventKitCalendarEventPatch()
        calendarPatch.location = .set("Gate 14")
        XCTAssertThrowsError(
            try EventKitAgentWorkflowPlanner.calendarOperation(
                afterSelection: .update(patch: calendarPatch, scope: .thisEvent),
                current: unsafeCalendar
            )
        ) { error in
            XCTAssertEqual(
                error as? EventKitAgentSessionError,
                .unsupportedExistingAlarms(1)
            )
        }
        XCTAssertNoThrow(
            try EventKitAgentWorkflowPlanner.calendarOperation(
                afterSelection: .delete(scope: .thisEvent),
                current: unsafeCalendar
            )
        )

        let unsafeReminder = reminderCandidate(unsupportedAlarmCount: 2)
        XCTAssertThrowsError(
            try EventKitAgentWorkflowPlanner.reminderOperation(
                afterSelection: .complete(true),
                current: unsafeReminder
            )
        ) { error in
            XCTAssertEqual(
                error as? EventKitAgentSessionError,
                .unsupportedExistingAlarms(2)
            )
        }
        XCTAssertNoThrow(
            try EventKitAgentWorkflowPlanner.reminderOperation(
                afterSelection: .delete,
                current: unsafeReminder
            )
        )
    }

    func testUnsafeAlarmWarningIsTruthfulInLocalReviewFields() {
        let calendarFields = EventKitAgentReviewFormatter.calendarCurrentFields(
            calendarCandidate(unsupportedAlarmCount: 1)
        )
        let reminderFields = EventKitAgentReviewFormatter.reminderCurrentFields(
            reminderCandidate(unsupportedAlarmCount: 2)
        )

        let calendarWarning = calendarFields.first { $0.label == "Alarm compatibility" }?.current
        let reminderWarning = reminderFields.first { $0.label == "Alarm compatibility" }?.current
        XCTAssertTrue(calendarWarning?.contains("absolute or unsupported alarm") == true)
        XCTAssertTrue(calendarWarning?.contains("edits are blocked") == true)
        XCTAssertTrue(reminderWarning?.contains("2 absolute or unsupported alarms") == true)
        XCTAssertTrue(reminderWarning?.contains("preserve them") == true)
    }

    private func calendarSearchRequest() throws -> EventKitCalendarSearchRequest {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return try EventKitCalendarSearchRequest(
            query: "flight",
            rangeStart: start,
            rangeEnd: start.addingTimeInterval(24 * 60 * 60)
        )
    }

    private func calendarCandidate(
        unsupportedAlarmCount: Int = 0,
        timeZoneIdentifier: String? = "Asia/Shanghai"
    ) -> EventKitCalendarEventCandidate {
        let start = Date(timeIntervalSince1970: 1_907_315_200)
        return EventKitCalendarEventCandidate(
            id: EventKitLocalSelectionToken(),
            title: "Flight",
            startDate: start,
            endDate: start.addingTimeInterval(3_600),
            isAllDay: false,
            timeZoneIdentifier: timeZoneIdentifier,
            calendarTitle: "Travel",
            location: "Terminal 1",
            notes: "Bring passport",
            url: URL(string: "https://example.com/flight"),
            availability: .busy,
            alertMinutesBeforeStart: [5],
            unsupportedAlarmCount: unsupportedAlarmCount,
            hasRecurrence: true,
            canModify: true,
            lastModifiedDate: nil
        )
    }

    private func reminderCandidate(
        start: EventKitReminderDateValue? = nil,
        due: EventKitReminderDateValue? = nil,
        unsupportedAlarmCount: Int = 0
    ) -> EventKitReminderCandidate {
        EventKitReminderCandidate(
            id: EventKitLocalSelectionToken(),
            title: "Bring passport",
            listTitle: "Travel",
            start: start,
            due: due,
            notes: nil,
            url: nil,
            priority: .high,
            isCompleted: false,
            completionDate: nil,
            hasRecurrence: false,
            alertMinutesBeforeDue: [],
            unsupportedAlarmCount: unsupportedAlarmCount,
            canModify: true,
            lastModifiedDate: nil
        )
    }
}

@MainActor
private final class RecordingEventKitAgentService: EventKitAgentServicing {
    private(set) var operationCount = 0
    private(set) var invalidateCount = 0

    func searchCalendar(
        _ request: EventKitCalendarSearchRequest
    ) async throws -> [EventKitCalendarEventCandidate] {
        operationCount += 1
        return []
    }

    func createCalendarEvent(
        _ draft: EventKitCalendarEventDraft
    ) async throws -> EventKitAgentMutationReceipt {
        operationCount += 1
        return calendarReceipt(.created)
    }

    func updateCalendarEvent(
        token: EventKitLocalSelectionToken,
        patch: EventKitCalendarEventPatch,
        scope: EventKitRecurringEventScope
    ) async throws -> EventKitAgentMutationReceipt {
        operationCount += 1
        return calendarReceipt(.updated)
    }

    func deleteCalendarEvent(
        token: EventKitLocalSelectionToken,
        scope: EventKitRecurringEventScope
    ) async throws -> EventKitAgentMutationReceipt {
        operationCount += 1
        return calendarReceipt(.deleted)
    }

    func searchReminders(
        _ request: EventKitReminderSearchRequest
    ) async throws -> [EventKitReminderCandidate] {
        operationCount += 1
        return []
    }

    func createReminder(
        _ draft: EventKitReminderDraft
    ) async throws -> EventKitAgentMutationReceipt {
        operationCount += 1
        return reminderReceipt(.created)
    }

    func updateReminder(
        token: EventKitLocalSelectionToken,
        patch: EventKitReminderPatch
    ) async throws -> EventKitAgentMutationReceipt {
        operationCount += 1
        return reminderReceipt(.updated)
    }

    func setReminderCompletion(
        token: EventKitLocalSelectionToken,
        completed: Bool
    ) async throws -> EventKitAgentMutationReceipt {
        operationCount += 1
        return reminderReceipt(completed ? .completed : .reopened)
    }

    func deleteReminder(
        token: EventKitLocalSelectionToken
    ) async throws -> EventKitAgentMutationReceipt {
        operationCount += 1
        return reminderReceipt(.deleted)
    }

    func invalidateLocalSelections() {
        invalidateCount += 1
    }

    private func calendarReceipt(
        _ operation: EventKitAgentMutationOperation
    ) -> EventKitAgentMutationReceipt {
        EventKitAgentMutationReceipt(
            entity: .calendarEvent,
            operation: operation,
            title: "Event",
            containerTitle: "Calendar"
        )
    }

    private func reminderReceipt(
        _ operation: EventKitAgentMutationOperation
    ) -> EventKitAgentMutationReceipt {
        EventKitAgentMutationReceipt(
            entity: .reminder,
            operation: operation,
            title: "Reminder",
            containerTitle: "Reminders"
        )
    }
}
