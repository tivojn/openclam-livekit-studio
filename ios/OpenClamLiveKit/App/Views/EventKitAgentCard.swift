import Combine
import EventKit
import Foundation
import SwiftUI

@MainActor
protocol EventKitAgentServicing: AnyObject {
    func searchCalendar(
        _ request: EventKitCalendarSearchRequest
    ) async throws -> [EventKitCalendarEventCandidate]
    func createCalendarEvent(
        _ draft: EventKitCalendarEventDraft
    ) async throws -> EventKitAgentMutationReceipt
    func updateCalendarEvent(
        token: EventKitLocalSelectionToken,
        patch: EventKitCalendarEventPatch,
        scope: EventKitRecurringEventScope
    ) async throws -> EventKitAgentMutationReceipt
    func deleteCalendarEvent(
        token: EventKitLocalSelectionToken,
        scope: EventKitRecurringEventScope
    ) async throws -> EventKitAgentMutationReceipt
    func searchReminders(
        _ request: EventKitReminderSearchRequest
    ) async throws -> [EventKitReminderCandidate]
    func createReminder(
        _ draft: EventKitReminderDraft
    ) async throws -> EventKitAgentMutationReceipt
    func updateReminder(
        token: EventKitLocalSelectionToken,
        patch: EventKitReminderPatch
    ) async throws -> EventKitAgentMutationReceipt
    func setReminderCompletion(
        token: EventKitLocalSelectionToken,
        completed: Bool
    ) async throws -> EventKitAgentMutationReceipt
    func deleteReminder(
        token: EventKitLocalSelectionToken
    ) async throws -> EventKitAgentMutationReceipt
    func invalidateLocalSelections()
}

extension EventKitAgentService: EventKitAgentServicing {}

enum EventKitCalendarAfterSelection: Equatable, Sendable {
    case none
    case update(
        patch: EventKitCalendarEventPatch,
        scope: EventKitRecurringEventScope
    )
    case delete(scope: EventKitRecurringEventScope)
}

enum EventKitReminderAfterSelection: Equatable, Sendable {
    case none
    case update(patch: EventKitReminderPatch)
    case complete(Bool)
    case delete
}

enum EventKitAgentStagedOperation: Equatable {
    case calendarSearch(
        request: EventKitCalendarSearchRequest,
        afterSelection: EventKitCalendarAfterSelection
    )
    case calendarCreate(EventKitCalendarEventDraft)
    case calendarUpdate(
        current: EventKitCalendarEventCandidate,
        patch: EventKitCalendarEventPatch,
        scope: EventKitRecurringEventScope
    )
    case calendarDelete(
        current: EventKitCalendarEventCandidate,
        scope: EventKitRecurringEventScope
    )
    case reminderSearch(
        request: EventKitReminderSearchRequest,
        afterSelection: EventKitReminderAfterSelection
    )
    case reminderCreate(EventKitReminderDraft)
    case reminderUpdate(
        current: EventKitReminderCandidate,
        patch: EventKitReminderPatch
    )
    case reminderCompletion(
        current: EventKitReminderCandidate,
        completed: Bool
    )
    case reminderDelete(current: EventKitReminderCandidate)

    var title: String {
        switch self {
        case .calendarSearch: "Search Calendar"
        case .calendarCreate: "Create calendar event"
        case .calendarUpdate: "Update calendar event"
        case .calendarDelete: "Delete calendar event"
        case .reminderSearch: "Search Reminders"
        case .reminderCreate: "Create reminder"
        case .reminderUpdate: "Update reminder"
        case let .reminderCompletion(_, completed): completed ? "Complete reminder" : "Reopen reminder"
        case .reminderDelete: "Delete reminder"
        }
    }

    var approvalTitle: String {
        switch self {
        case .calendarSearch: "Allow Calendar search"
        case .calendarCreate: "Create event"
        case .calendarUpdate: "Update event"
        case .calendarDelete: "Delete event"
        case .reminderSearch: "Allow Reminders search"
        case .reminderCreate: "Create reminder"
        case .reminderUpdate: "Update reminder"
        case let .reminderCompletion(_, completed): completed ? "Mark complete" : "Reopen reminder"
        case .reminderDelete: "Delete reminder"
        }
    }

    var systemImage: String {
        switch self {
        case .calendarSearch: "calendar.badge.magnifyingglass"
        case .calendarCreate: "calendar.badge.plus"
        case .calendarUpdate: "calendar.badge.exclamationmark"
        case .calendarDelete: "calendar.badge.minus"
        case .reminderSearch: "list.bullet.clipboard"
        case .reminderCreate: "checklist"
        case .reminderUpdate: "pencil.and.list.clipboard"
        case let .reminderCompletion(_, completed): completed ? "checkmark.circle" : "arrow.uturn.backward.circle"
        case .reminderDelete: "trash"
        }
    }

    var privacyExplanation: String {
        switch self {
        case .calendarSearch:
            "This reads matching Calendar details only after this tap. Results remain local to the app."
        case .reminderSearch:
            "This reads matching Reminders details only after this tap. Results remain local to the app."
        default:
            "Nothing changes until you approve here. iOS may also ask for Calendar or Reminders permission."
        }
    }

    var isDestructive: Bool {
        switch self {
        case .calendarDelete, .reminderDelete: true
        default: false
        }
    }

    var isRead: Bool {
        switch self {
        case .calendarSearch, .reminderSearch: true
        default: false
        }
    }
}

struct EventKitAgentPendingRequest: Identifiable, Equatable {
    let id: UUID
    let operation: EventKitAgentStagedOperation
    let stagedAt: Date
    fileprivate let approvalNonce: UUID

    init(
        id: UUID = UUID(),
        operation: EventKitAgentStagedOperation,
        stagedAt: Date = Date(),
        approvalNonce: UUID = UUID()
    ) {
        self.id = id
        self.operation = operation
        self.stagedAt = stagedAt
        self.approvalNonce = approvalNonce
    }
}

enum EventKitAgentSessionError: LocalizedError, Equatable {
    case busy
    case pendingReviewExists
    case unknownLocalSelection
    case readOnlySelection
    case unsupportedExistingAlarms(Int)
    case emptyUpdate
    case invalidUpdate(String)
    case approvalMismatch

    var errorDescription: String? {
        switch self {
        case .busy:
            "Wait for the current Calendar or Reminders action to finish."
        case .pendingReviewExists:
            "Review or cancel the existing Calendar or Reminders request first."
        case .unknownLocalSelection:
            "That result is no longer in this local session. Search again."
        case .readOnlySelection:
            "The selected Calendar or Reminders list is read-only."
        case let .unsupportedExistingAlarms(count):
            "This item has \(count) absolute or unsupported existing alarm(s). To preserve them, edit this item in Apple Calendar or Reminders."
        case .emptyUpdate:
            "The proposed update does not contain any changes."
        case let .invalidUpdate(reason):
            "The proposed update is invalid: \(reason)"
        case .approvalMismatch:
            "That review is no longer current. Review the latest request instead."
        }
    }
}

enum EventKitAgentWorkflowPlanner {
    static func calendarOperation(
        afterSelection: EventKitCalendarAfterSelection,
        current: EventKitCalendarEventCandidate
    ) throws -> EventKitAgentStagedOperation? {
        switch afterSelection {
        case .none:
            return nil
        case let .update(patch, scope):
            guard current.unsupportedAlarmCount == 0 else {
                throw EventKitAgentSessionError.unsupportedExistingAlarms(
                    current.unsupportedAlarmCount
                )
            }
            guard patch.hasChanges else { throw EventKitAgentSessionError.emptyUpdate }
            if case .clear = patch.title {
                throw EventKitAgentSessionError.invalidUpdate("an event title cannot be cleared")
            }
            if case .clear = patch.schedule {
                throw EventKitAgentSessionError.invalidUpdate("an event schedule cannot be cleared")
            }
            return .calendarUpdate(current: current, patch: patch, scope: scope)
        case let .delete(scope):
            return .calendarDelete(current: current, scope: scope)
        }
    }

    static func reminderOperation(
        afterSelection: EventKitReminderAfterSelection,
        current: EventKitReminderCandidate
    ) throws -> EventKitAgentStagedOperation? {
        switch afterSelection {
        case .none:
            return nil
        case let .update(patch):
            guard current.unsupportedAlarmCount == 0 else {
                throw EventKitAgentSessionError.unsupportedExistingAlarms(
                    current.unsupportedAlarmCount
                )
            }
            guard patch.hasChanges else { throw EventKitAgentSessionError.emptyUpdate }
            if case .clear = patch.title {
                throw EventKitAgentSessionError.invalidUpdate("a reminder title cannot be cleared")
            }
            return .reminderUpdate(current: current, patch: patch)
        case let .complete(completed):
            guard current.unsupportedAlarmCount == 0 else {
                throw EventKitAgentSessionError.unsupportedExistingAlarms(
                    current.unsupportedAlarmCount
                )
            }
            return .reminderCompletion(current: current, completed: completed)
        case .delete:
            return .reminderDelete(current: current)
        }
    }
}

private struct EventKitAgentLocalApproval {
    let requestID: UUID
    let nonce: UUID
}

@MainActor
final class EventKitAgentSession: ObservableObject {
    @Published private(set) var pendingRequest: EventKitAgentPendingRequest?
    @Published private(set) var calendarResults: [EventKitCalendarEventCandidate] = []
    @Published private(set) var reminderResults: [EventKitReminderCandidate] = []
    @Published private(set) var lastReceipt: EventKitAgentMutationReceipt?
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPerforming = false

    private let service: any EventKitAgentServicing
    private var calendarAfterSelection: EventKitCalendarAfterSelection = .none
    private var reminderAfterSelection: EventKitReminderAfterSelection = .none
    private var shouldResetAfterCurrentOperation = false

    init() {
        service = EventKitAgentService.shared
    }

    init(service: any EventKitAgentServicing) {
        self.service = service
    }

    var hasVisibleContent: Bool {
        pendingRequest != nil
            || !calendarResults.isEmpty
            || !reminderResults.isEmpty
            || lastReceipt != nil
            || statusMessage != nil
            || errorMessage != nil
    }

    @discardableResult
    func stageCalendarSearch(_ request: EventKitCalendarSearchRequest) throws -> UUID {
        try stageCalendarWorkflow(search: request, afterSelection: .none)
    }

    @discardableResult
    func stageCalendarWorkflow(
        search request: EventKitCalendarSearchRequest,
        afterSelection: EventKitCalendarAfterSelection
    ) throws -> UUID {
        try validate(afterSelection: afterSelection)
        return try stage(.calendarSearch(request: request, afterSelection: afterSelection))
    }

    @discardableResult
    func stageCalendarCreate(_ draft: EventKitCalendarEventDraft) throws -> UUID {
        try stage(.calendarCreate(draft))
    }

    @discardableResult
    func stageCalendarUpdate(
        current: EventKitCalendarEventCandidate,
        patch: EventKitCalendarEventPatch,
        scope: EventKitRecurringEventScope = .thisEvent
    ) throws -> UUID {
        try validateCalendarSelection(current)
        try validateAlarmSafety(current.unsupportedAlarmCount)
        guard patch.hasChanges else { throw EventKitAgentSessionError.emptyUpdate }
        if case .clear = patch.title {
            throw EventKitAgentSessionError.invalidUpdate("an event title cannot be cleared")
        }
        if case .clear = patch.schedule {
            throw EventKitAgentSessionError.invalidUpdate("an event schedule cannot be cleared")
        }
        return try stage(.calendarUpdate(current: current, patch: patch, scope: scope))
    }

    @discardableResult
    func stageCalendarDelete(
        current: EventKitCalendarEventCandidate,
        scope: EventKitRecurringEventScope = .thisEvent
    ) throws -> UUID {
        try validateCalendarSelection(current)
        return try stage(.calendarDelete(current: current, scope: scope))
    }

    @discardableResult
    func stageReminderSearch(_ request: EventKitReminderSearchRequest) throws -> UUID {
        try stageReminderWorkflow(search: request, afterSelection: .none)
    }

    @discardableResult
    func stageReminderWorkflow(
        search request: EventKitReminderSearchRequest,
        afterSelection: EventKitReminderAfterSelection
    ) throws -> UUID {
        try validate(afterSelection: afterSelection)
        return try stage(.reminderSearch(request: request, afterSelection: afterSelection))
    }

    @discardableResult
    func stageReminderCreate(_ draft: EventKitReminderDraft) throws -> UUID {
        try stage(.reminderCreate(draft))
    }

    @discardableResult
    func stageReminderUpdate(
        current: EventKitReminderCandidate,
        patch: EventKitReminderPatch
    ) throws -> UUID {
        try validateReminderSelection(current)
        try validateAlarmSafety(current.unsupportedAlarmCount)
        guard patch.hasChanges else { throw EventKitAgentSessionError.emptyUpdate }
        if case .clear = patch.title {
            throw EventKitAgentSessionError.invalidUpdate("a reminder title cannot be cleared")
        }
        return try stage(.reminderUpdate(current: current, patch: patch))
    }

    @discardableResult
    func stageReminderCompletion(
        current: EventKitReminderCandidate,
        completed: Bool
    ) throws -> UUID {
        try validateReminderSelection(current)
        try validateAlarmSafety(current.unsupportedAlarmCount)
        return try stage(.reminderCompletion(current: current, completed: completed))
    }

    @discardableResult
    func stageReminderDelete(current: EventKitReminderCandidate) throws -> UUID {
        try validateReminderSelection(current)
        return try stage(.reminderDelete(current: current))
    }

    func cancelPending() {
        guard !isPerforming else { return }
        pendingRequest = nil
        statusMessage = "Calendar or Reminders request cancelled."
        lastReceipt = nil
        errorMessage = nil
    }

    func clearLocalResults() {
        guard !isPerforming, pendingRequest == nil else { return }
        service.invalidateLocalSelections()
        calendarResults.removeAll()
        reminderResults.removeAll()
        calendarAfterSelection = .none
        reminderAfterSelection = .none
        statusMessage = nil
        lastReceipt = nil
        errorMessage = nil
    }

    func reset() {
        guard !isPerforming else {
            shouldResetAfterCurrentOperation = true
            return
        }
        resetImmediately()
    }

    func invalidate() {
        reset()
    }

    func dismissFeedback() {
        guard !isPerforming else { return }
        statusMessage = nil
        lastReceipt = nil
        errorMessage = nil
    }

    private func stage(_ operation: EventKitAgentStagedOperation) throws -> UUID {
        guard !isPerforming else { throw EventKitAgentSessionError.busy }
        guard pendingRequest == nil else { throw EventKitAgentSessionError.pendingReviewExists }
        let pending = EventKitAgentPendingRequest(operation: operation)
        pendingRequest = pending
        statusMessage = nil
        lastReceipt = nil
        errorMessage = nil
        return pending.id
    }

    private func validateCalendarSelection(
        _ candidate: EventKitCalendarEventCandidate
    ) throws {
        guard calendarResults.contains(where: { $0 == candidate }) else {
            throw EventKitAgentSessionError.unknownLocalSelection
        }
        guard candidate.canModify else { throw EventKitAgentSessionError.readOnlySelection }
    }

    private func validateReminderSelection(_ candidate: EventKitReminderCandidate) throws {
        guard reminderResults.contains(where: { $0 == candidate }) else {
            throw EventKitAgentSessionError.unknownLocalSelection
        }
        guard candidate.canModify else { throw EventKitAgentSessionError.readOnlySelection }
    }

    private func validateAlarmSafety(_ unsupportedAlarmCount: Int) throws {
        guard unsupportedAlarmCount == 0 else {
            throw EventKitAgentSessionError.unsupportedExistingAlarms(unsupportedAlarmCount)
        }
    }

    private func validate(afterSelection: EventKitCalendarAfterSelection) throws {
        if case let .update(patch, _) = afterSelection {
            guard patch.hasChanges else { throw EventKitAgentSessionError.emptyUpdate }
            if case .clear = patch.title {
                throw EventKitAgentSessionError.invalidUpdate("an event title cannot be cleared")
            }
            if case .clear = patch.schedule {
                throw EventKitAgentSessionError.invalidUpdate("an event schedule cannot be cleared")
            }
        }
    }

    private func validate(afterSelection: EventKitReminderAfterSelection) throws {
        if case let .update(patch) = afterSelection {
            guard patch.hasChanges else { throw EventKitAgentSessionError.emptyUpdate }
            if case .clear = patch.title {
                throw EventKitAgentSessionError.invalidUpdate("a reminder title cannot be cleared")
            }
        }
    }

    fileprivate func select(_ candidate: EventKitCalendarEventCandidate) {
        guard !isPerforming, pendingRequest == nil else { return }
        do {
            try validateCalendarSelection(candidate)
            guard let operation = try EventKitAgentWorkflowPlanner.calendarOperation(
                afterSelection: calendarAfterSelection,
                current: candidate
            ) else { return }
            _ = try stage(operation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    fileprivate func select(_ candidate: EventKitReminderCandidate) {
        guard !isPerforming, pendingRequest == nil else { return }
        do {
            try validateReminderSelection(candidate)
            guard let operation = try EventKitAgentWorkflowPlanner.reminderOperation(
                afterSelection: reminderAfterSelection,
                current: candidate
            ) else { return }
            _ = try stage(operation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    fileprivate func perform(_ approval: EventKitAgentLocalApproval) async {
        guard !isPerforming else { return }
        guard let pending = pendingRequest,
              pending.id == approval.requestID,
              pending.approvalNonce == approval.nonce else {
            errorMessage = EventKitAgentSessionError.approvalMismatch.localizedDescription
            return
        }

        isPerforming = true
        errorMessage = nil
        lastReceipt = nil
        statusMessage = nil
        defer {
            isPerforming = false
            if shouldResetAfterCurrentOperation {
                shouldResetAfterCurrentOperation = false
                resetImmediately()
            }
        }

        do {
            switch pending.operation {
            case let .calendarSearch(request, afterSelection):
                calendarResults = try await service.searchCalendar(request)
                calendarAfterSelection = calendarResults.isEmpty ? .none : afterSelection
                statusMessage = Self.resultCountMessage(
                    calendarResults.count,
                    singular: "calendar event",
                    plural: "calendar events"
                )
            case let .calendarCreate(draft):
                lastReceipt = try await service.createCalendarEvent(draft)
            case let .calendarUpdate(current, patch, scope):
                lastReceipt = try await service.updateCalendarEvent(
                    token: current.id,
                    patch: patch,
                    scope: scope
                )
                calendarResults.removeAll { $0.id == current.id }
                calendarAfterSelection = .none
            case let .calendarDelete(current, scope):
                lastReceipt = try await service.deleteCalendarEvent(
                    token: current.id,
                    scope: scope
                )
                calendarResults.removeAll { $0.id == current.id }
                calendarAfterSelection = .none
            case let .reminderSearch(request, afterSelection):
                reminderResults = try await service.searchReminders(request)
                reminderAfterSelection = reminderResults.isEmpty ? .none : afterSelection
                statusMessage = Self.resultCountMessage(
                    reminderResults.count,
                    singular: "reminder",
                    plural: "reminders"
                )
            case let .reminderCreate(draft):
                lastReceipt = try await service.createReminder(draft)
            case let .reminderUpdate(current, patch):
                lastReceipt = try await service.updateReminder(
                    token: current.id,
                    patch: patch
                )
                reminderResults.removeAll { $0.id == current.id }
                reminderAfterSelection = .none
            case let .reminderCompletion(current, completed):
                lastReceipt = try await service.setReminderCompletion(
                    token: current.id,
                    completed: completed
                )
                reminderResults.removeAll { $0.id == current.id }
                reminderAfterSelection = .none
            case let .reminderDelete(current):
                lastReceipt = try await service.deleteReminder(token: current.id)
                reminderResults.removeAll { $0.id == current.id }
                reminderAfterSelection = .none
            }
            pendingRequest = nil
        } catch {
            discardConsumedSelection(for: pending.operation)
            pendingRequest = nil
            errorMessage = error.localizedDescription
        }
    }

    private static func resultCountMessage(
        _ count: Int,
        singular: String,
        plural: String
    ) -> String {
        count == 1 ? "Found 1 \(singular) locally." : "Found \(count) \(plural) locally."
    }

    fileprivate func calendarSelectionButtonTitle() -> String? {
        switch calendarAfterSelection {
        case .none: nil
        case .update: "Choose for update"
        case .delete: "Choose to delete"
        }
    }

    fileprivate func reminderSelectionButtonTitle() -> String? {
        switch reminderAfterSelection {
        case .none: nil
        case .update: "Choose for update"
        case let .complete(completed): completed ? "Choose to complete" : "Choose to reopen"
        case .delete: "Choose to delete"
        }
    }

    fileprivate var calendarSelectionIsDestructive: Bool {
        if case .delete = calendarAfterSelection { return true }
        return false
    }

    fileprivate var reminderSelectionIsDestructive: Bool {
        if case .delete = reminderAfterSelection { return true }
        return false
    }

    private func discardConsumedSelection(for operation: EventKitAgentStagedOperation) {
        switch operation {
        case let .calendarUpdate(current, _, _), let .calendarDelete(current, _):
            calendarResults.removeAll { $0.id == current.id }
            calendarAfterSelection = .none
        case let .reminderUpdate(current, _),
             let .reminderCompletion(current, _),
             let .reminderDelete(current):
            reminderResults.removeAll { $0.id == current.id }
            reminderAfterSelection = .none
        default:
            break
        }
    }

    private func resetImmediately() {
        pendingRequest = nil
        service.invalidateLocalSelections()
        calendarResults.removeAll()
        reminderResults.removeAll()
        calendarAfterSelection = .none
        reminderAfterSelection = .none
        statusMessage = nil
        lastReceipt = nil
        errorMessage = nil
    }
}

struct EventKitAgentCard: View {
    @ObservedObject var session: EventKitAgentSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if session.hasVisibleContent {
            VStack(alignment: .leading, spacing: 14) {
                if let pending = session.pendingRequest {
                    pendingReview(pending)
                } else {
                    feedback
                    localResults
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(cardStroke, lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var cardStroke: Color {
        if session.pendingRequest?.operation.isDestructive == true { return .red.opacity(0.45) }
        if session.pendingRequest != nil { return .orange.opacity(0.45) }
        return .indigo.opacity(0.2)
    }

    private func pendingReview(_ pending: EventKitAgentPendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: pending.operation.systemImage)
                    .font(.title2)
                    .foregroundStyle(pending.operation.isDestructive ? .red : .orange)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review on this iPhone")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(pending.operation.isDestructive ? .red : .orange)
                        .textCase(.uppercase)
                    Text(pending.operation.title)
                        .font(.headline)
                    Text(pending.operation.privacyExplanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(EventKitAgentReviewFormatter.sections(for: pending.operation)) { section in
                reviewSection(section)
            }

            if session.isPerforming {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(pending.operation.isRead ? "Reading after approval…" : "Applying approved change…")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else {
                approvalButtons(pending)
            }
        }
    }

    private func reviewSection(_ section: EventKitAgentReviewSection) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
            ForEach(section.fields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let current = field.current {
                        reviewValue(label: "Current", value: current, color: .secondary)
                    }
                    if let proposed = field.proposed {
                        reviewValue(
                            label: field.current == nil ? "Requested" : "Proposed",
                            value: proposed,
                            color: .primary
                        )
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func reviewValue(label: String, value: String, color: Color) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption2.weight(.bold))
                    Text(value).font(.subheadline)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .frame(width: 58, alignment: .leading)
                    Text(value)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundStyle(color)
        .textSelection(.enabled)
    }

    private func approvalButtons(_ pending: EventKitAgentPendingRequest) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                cancelButton
                Spacer(minLength: 4)
                approveButton(pending)
            }
            VStack(spacing: 10) {
                approveButton(pending)
                    .frame(maxWidth: .infinity)
                cancelButton
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel) {
            session.cancelPending()
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityHint("Dismisses this request without reading or changing Calendar or Reminders")
    }

    private func approveButton(_ pending: EventKitAgentPendingRequest) -> some View {
        Button(role: pending.operation.isDestructive ? .destructive : nil) {
            let approval = EventKitAgentLocalApproval(
                requestID: pending.id,
                nonce: pending.approvalNonce
            )
            Task { await session.perform(approval) }
        } label: {
            Label(pending.operation.approvalTitle, systemImage: pending.operation.systemImage)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(pending.operation.isDestructive ? .red : .indigo)
        .accessibilityHint(
            pending.operation.isRead
                ? "Approves this one local data read"
                : "Approves exactly the proposed change shown above"
        )
    }

    @ViewBuilder
    private var feedback: some View {
        if let errorMessage = session.errorMessage {
            feedbackRow(
                title: "Calendar or Reminders action failed",
                detail: errorMessage,
                systemImage: "exclamationmark.triangle.fill",
                color: .red
            )
        } else if let receipt = session.lastReceipt {
            feedbackRow(
                title: EventKitAgentReviewFormatter.receiptTitle(receipt),
                detail: "\(receipt.title) · \(receipt.containerTitle)",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        } else if let statusMessage = session.statusMessage {
            feedbackRow(
                title: "Local result",
                detail: statusMessage,
                systemImage: "checkmark.shield.fill",
                color: .indigo
            )
        }
    }

    private func feedbackRow(
        title: String,
        detail: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button {
                session.dismissFeedback()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss result")
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var localResults: some View {
        if !session.calendarResults.isEmpty || !session.reminderResults.isEmpty {
            Divider()
            HStack {
                Label("Private local results", systemImage: "lock.shield")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Clear") { session.clearLocalResults() }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHint("Removes these results and invalidates their local action tokens")
            }
            Text("These details are displayed on-device and are not model-encodable.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(session.calendarResults) { candidate in
                calendarResult(candidate)
            }
            ForEach(session.reminderResults) { candidate in
                reminderResult(candidate)
            }
        }
    }

    private func calendarResult(_ candidate: EventKitCalendarEventCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup {
                resultRows(EventKitAgentReviewFormatter.calendarCurrentFields(candidate))
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title).font(.subheadline.weight(.semibold))
                    Text(EventKitAgentReviewFormatter.calendarSchedule(candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let title = session.calendarSelectionButtonTitle() {
                Button(role: session.calendarSelectionIsDestructive ? .destructive : nil) {
                    session.select(candidate)
                } label: {
                    Label(title, systemImage: "hand.tap")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(session.calendarSelectionIsDestructive ? .red : .indigo)
                .accessibilityHint(
                    "Selects this private result and opens a second exact review; it does not change Calendar yet"
                )
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private func reminderResult(_ candidate: EventKitReminderCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup {
                resultRows(EventKitAgentReviewFormatter.reminderCurrentFields(candidate))
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title).font(.subheadline.weight(.semibold))
                    Text(EventKitAgentReviewFormatter.reminderSchedule(candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let title = session.reminderSelectionButtonTitle() {
                Button(role: session.reminderSelectionIsDestructive ? .destructive : nil) {
                    session.select(candidate)
                } label: {
                    Label(title, systemImage: "hand.tap")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(session.reminderSelectionIsDestructive ? .red : .indigo)
                .accessibilityHint(
                    "Selects this private result and opens a second exact review; it does not change Reminders yet"
                )
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private func resultRows(_ fields: [EventKitAgentReviewField]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(field.current ?? field.proposed ?? "None")
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 8)
    }
}

struct EventKitAgentReviewSection: Identifiable, Equatable {
    let id: String
    let title: String
    let fields: [EventKitAgentReviewField]

    init(title: String, fields: [EventKitAgentReviewField]) {
        id = title
        self.title = title
        self.fields = fields
    }
}

struct EventKitAgentReviewField: Identifiable, Equatable {
    let id: String
    let label: String
    let current: String?
    let proposed: String?

    init(label: String, current: String? = nil, proposed: String? = nil) {
        id = label
        self.label = label
        self.current = current
        self.proposed = proposed
    }
}

enum EventKitAgentReviewFormatter {
    static func sections(for operation: EventKitAgentStagedOperation) -> [EventKitAgentReviewSection] {
        switch operation {
        case let .calendarSearch(request, afterSelection):
            return [
                EventKitAgentReviewSection(
                    title: "Calendar read",
                    fields: [
                        .init(label: "Access", current: "Not read", proposed: "Read matching events once"),
                        .init(label: "Search", proposed: request.query.isEmpty ? "All titles" : request.query),
                        .init(label: "Range", proposed: dateRange(request.rangeStart, request.rangeEnd)),
                        .init(label: "Calendar", proposed: request.calendarName ?? "All calendars"),
                        .init(label: "Maximum results", proposed: String(request.limit)),
                        .init(
                            label: "After results",
                            proposed: calendarSelectionPlan(afterSelection)
                        ),
                    ]
                ),
            ]
        case let .calendarCreate(draft):
            return [
                EventKitAgentReviewSection(
                    title: "New event",
                    fields: calendarDraftFields(draft).map {
                        .init(label: $0.label, current: "No event", proposed: $0.proposed)
                    }
                ),
            ]
        case let .calendarUpdate(current, patch, scope):
            return [
                .init(title: "Current and proposed", fields: calendarUpdateFields(current, patch)),
                .init(
                    title: "Recurring-event scope",
                    fields: [
                        .init(
                            label: "Apply to",
                            current: current.hasRecurrence ? "Repeating event" : "Single event",
                            proposed: scope == .futureEvents ? "This and future events" : "This event only"
                        ),
                    ]
                ),
            ]
        case let .calendarDelete(current, scope):
            return [
                .init(
                    title: "Deletion",
                    fields: [
                        .init(
                            label: "Action",
                            current: "Event exists",
                            proposed: scope == .futureEvents ? "Delete this and future events" : "Delete this event"
                        ),
                    ] + calendarCurrentFields(current)
                ),
            ]
        case let .reminderSearch(request, afterSelection):
            return [
                .init(
                    title: "Reminders read",
                    fields: [
                        .init(label: "Access", current: "Not read", proposed: "Read matching reminders once"),
                        .init(label: "Search", proposed: request.query.isEmpty ? "All titles" : request.query),
                        .init(label: "Status", proposed: reminderSearchStatus(request.status)),
                        .init(
                            label: "Due range",
                            proposed: request.dueStart.flatMap { start in
                                request.dueEnd.map { dateRange(start, $0) }
                            } ?? "Any due date"
                        ),
                        .init(label: "List", proposed: request.listName ?? "All lists"),
                        .init(label: "Maximum results", proposed: String(request.limit)),
                        .init(
                            label: "After results",
                            proposed: reminderSelectionPlan(afterSelection)
                        ),
                    ]
                ),
            ]
        case let .reminderCreate(draft):
            return [
                .init(
                    title: "New reminder",
                    fields: reminderDraftFields(draft).map {
                        .init(label: $0.label, current: "No reminder", proposed: $0.proposed)
                    }
                ),
            ]
        case let .reminderUpdate(current, patch):
            return [
                .init(title: "Current and proposed", fields: reminderUpdateFields(current, patch)),
            ]
        case let .reminderCompletion(current, completed):
            return [
                .init(
                    title: "Status change",
                    fields: [
                        .init(label: "Title", current: current.title, proposed: "Unchanged"),
                        .init(label: "List", current: current.listTitle, proposed: "Unchanged"),
                        .init(
                            label: "Status",
                            current: current.isCompleted ? "Completed" : "Incomplete",
                            proposed: completed ? "Completed" : "Incomplete"
                        ),
                    ]
                ),
            ]
        case let .reminderDelete(current):
            return [
                .init(
                    title: "Deletion",
                    fields: [
                        .init(label: "Action", current: "Reminder exists", proposed: "Delete reminder"),
                    ] + reminderCurrentFields(current)
                ),
            ]
        }
    }

    static func calendarCurrentFields(
        _ candidate: EventKitCalendarEventCandidate
    ) -> [EventKitAgentReviewField] {
        var fields: [EventKitAgentReviewField] = [
            .init(label: "Title", current: candidate.title),
            .init(label: "Schedule", current: calendarSchedule(candidate)),
            .init(label: "Calendar", current: candidate.calendarTitle),
            .init(label: "Location", current: optional(candidate.location)),
            .init(label: "Notes", current: optional(candidate.notes)),
            .init(label: "URL", current: candidate.url?.absoluteString ?? "None"),
            .init(label: "Availability", current: availability(candidate.availability)),
            .init(label: "Alerts", current: alerts(candidate.alertMinutesBeforeStart)),
            .init(label: "Recurrence", current: candidate.hasRecurrence ? "Repeats" : "Does not repeat"),
            .init(label: "Writable", current: candidate.canModify ? "Yes" : "No"),
        ]
        if candidate.unsupportedAlarmCount > 0 {
            fields.append(
                .init(
                    label: "Alarm compatibility",
                    current: alarmCompatibility(candidate.unsupportedAlarmCount)
                )
            )
        }
        return fields
    }

    static func reminderCurrentFields(
        _ candidate: EventKitReminderCandidate
    ) -> [EventKitAgentReviewField] {
        var fields: [EventKitAgentReviewField] = [
            .init(label: "Title", current: candidate.title),
            .init(label: "List", current: candidate.listTitle),
            .init(label: "Start", current: reminderDate(candidate.start)),
            .init(label: "Due", current: reminderDate(candidate.due)),
            .init(label: "Notes", current: optional(candidate.notes)),
            .init(label: "URL", current: candidate.url?.absoluteString ?? "None"),
            .init(label: "Priority", current: priority(candidate.priority)),
            .init(label: "Alerts", current: alerts(candidate.alertMinutesBeforeDue)),
            .init(label: "Recurrence", current: candidate.hasRecurrence ? "Repeats" : "Does not repeat"),
            .init(label: "Status", current: candidate.isCompleted ? "Completed" : "Incomplete"),
            .init(label: "Writable", current: candidate.canModify ? "Yes" : "No"),
        ]
        if candidate.unsupportedAlarmCount > 0 {
            fields.append(
                .init(
                    label: "Alarm compatibility",
                    current: alarmCompatibility(candidate.unsupportedAlarmCount)
                )
            )
        }
        return fields
    }

    static func calendarSchedule(_ candidate: EventKitCalendarEventCandidate) -> String {
        if candidate.isAllDay {
            return "\(dateOnly(candidate.startDate)) – before \(dateOnly(candidate.endDate)) · All day"
        }
        let zone = candidate.timeZoneIdentifier.map { " · \($0)" } ?? ""
        return "\(dateTime(candidate.startDate, timeZoneIdentifier: candidate.timeZoneIdentifier)) – \(dateTime(candidate.endDate, timeZoneIdentifier: candidate.timeZoneIdentifier))\(zone)"
    }

    static func reminderSchedule(_ candidate: EventKitReminderCandidate) -> String {
        if candidate.start == nil, candidate.due == nil { return "No date" }
        let start = reminderDate(candidate.start)
        let due = reminderDate(candidate.due)
        return "Start: \(start) · Due: \(due)"
    }

    static func receiptTitle(_ receipt: EventKitAgentMutationReceipt) -> String {
        let noun = receipt.entity == .calendarEvent ? "Event" : "Reminder"
        switch receipt.operation {
        case .created: return "\(noun) created"
        case .updated: return "\(noun) updated"
        case .completed: return "Reminder completed"
        case .reopened: return "Reminder reopened"
        case .deleted: return "\(noun) deleted"
        }
    }
}

private extension EventKitAgentReviewFormatter {
    static func calendarSelectionPlan(_ value: EventKitCalendarAfterSelection) -> String {
        switch value {
        case .none:
            "Display local results only"
        case .update:
            "Choose one result locally, then review the exact update"
        case .delete:
            "Choose one result locally, then review deletion"
        }
    }

    static func reminderSelectionPlan(_ value: EventKitReminderAfterSelection) -> String {
        switch value {
        case .none:
            "Display local results only"
        case .update:
            "Choose one result locally, then review the exact update"
        case let .complete(completed):
            completed
                ? "Choose one result locally, then review completion"
                : "Choose one result locally, then review reopening"
        case .delete:
            "Choose one result locally, then review deletion"
        }
    }

    static func calendarDraftFields(
        _ draft: EventKitCalendarEventDraft
    ) -> [EventKitAgentReviewField] {
        [
            .init(label: "Title", proposed: draft.title),
            .init(label: "Schedule", proposed: calendarSchedule(draft.schedule)),
            .init(label: "Calendar", proposed: draft.calendarName ?? "Default calendar"),
            .init(label: "Location", proposed: optional(draft.location)),
            .init(label: "Notes", proposed: optional(draft.notes)),
            .init(label: "URL", proposed: draft.url?.absoluteString ?? "None"),
            .init(label: "Availability", proposed: availability(draft.availability)),
            .init(label: "Alerts", proposed: alerts(draft.alertMinutesBeforeStart)),
            .init(label: "Recurrence", proposed: recurrence(draft.recurrence)),
        ]
    }

    static func calendarUpdateFields(
        _ current: EventKitCalendarEventCandidate,
        _ patch: EventKitCalendarEventPatch
    ) -> [EventKitAgentReviewField] {
        [
            .init(label: "Title", current: current.title, proposed: changed(patch.title) { $0 }),
            .init(
                label: "Schedule",
                current: calendarSchedule(current),
                proposed: changed(patch.schedule, cleared: "Cannot clear", format: calendarSchedule)
            ),
            .init(
                label: "Calendar",
                current: current.calendarTitle,
                proposed: changed(patch.calendarName, cleared: "Default calendar") { $0 }
            ),
            .init(
                label: "Location",
                current: optional(current.location),
                proposed: changed(patch.location, cleared: "None") { optional($0) }
            ),
            .init(
                label: "Notes",
                current: optional(current.notes),
                proposed: changed(patch.notes, cleared: "None") { optional($0) }
            ),
            .init(
                label: "URL",
                current: current.url?.absoluteString ?? "None",
                proposed: changed(patch.url, cleared: "None") { $0.absoluteString }
            ),
            .init(
                label: "Availability",
                current: availability(current.availability),
                proposed: changed(patch.availability, cleared: "System default", format: availability)
            ),
            .init(
                label: "Alerts",
                current: alerts(current.alertMinutesBeforeStart),
                proposed: changed(patch.alertMinutesBeforeStart, cleared: "No alerts", format: alerts)
            ),
            .init(
                label: "Recurrence",
                current: current.hasRecurrence ? "Repeats" : "Does not repeat",
                proposed: changed(patch.recurrence, cleared: "Does not repeat") { recurrence($0) }
            ),
        ]
    }

    static func reminderDraftFields(_ draft: EventKitReminderDraft) -> [EventKitAgentReviewField] {
        [
            .init(label: "Title", proposed: draft.title),
            .init(label: "List", proposed: draft.listName ?? "Default list"),
            .init(label: "Start", proposed: reminderDate(draft.schedule.start)),
            .init(label: "Due", proposed: reminderDate(draft.schedule.due)),
            .init(label: "Notes", proposed: optional(draft.notes)),
            .init(label: "URL", proposed: draft.url?.absoluteString ?? "None"),
            .init(label: "Priority", proposed: priority(draft.priority)),
            .init(label: "Alerts", proposed: alerts(draft.alertMinutesBeforeDue)),
            .init(label: "Recurrence", proposed: recurrence(draft.recurrence)),
        ]
    }

    static func reminderUpdateFields(
        _ current: EventKitReminderCandidate,
        _ patch: EventKitReminderPatch
    ) -> [EventKitAgentReviewField] {
        [
            .init(label: "Title", current: current.title, proposed: changed(patch.title) { $0 }),
            .init(
                label: "List",
                current: current.listTitle,
                proposed: changed(patch.listName, cleared: "Default list") { $0 }
            ),
            .init(
                label: "Schedule",
                current: reminderSchedule(current),
                proposed: changed(patch.schedule, cleared: "No start or due date", format: reminderSchedule)
            ),
            .init(
                label: "Notes",
                current: optional(current.notes),
                proposed: changed(patch.notes, cleared: "None") { optional($0) }
            ),
            .init(
                label: "URL",
                current: current.url?.absoluteString ?? "None",
                proposed: changed(patch.url, cleared: "None") { $0.absoluteString }
            ),
            .init(
                label: "Priority",
                current: priority(current.priority),
                proposed: changed(patch.priority, cleared: "None", format: priority)
            ),
            .init(
                label: "Alerts",
                current: alerts(current.alertMinutesBeforeDue),
                proposed: changed(patch.alertMinutesBeforeDue, cleared: "No alerts", format: alerts)
            ),
            .init(
                label: "Recurrence",
                current: current.hasRecurrence ? "Repeats" : "Does not repeat",
                proposed: changed(patch.recurrence, cleared: "Does not repeat") { recurrence($0) }
            ),
            .init(
                label: "Status",
                current: current.isCompleted ? "Completed" : "Incomplete",
                proposed: "Unchanged"
            ),
        ]
    }

    static func changed<Value>(
        _ change: EventKitFieldChange<Value>,
        cleared: String = "Removed",
        format: (Value) -> String
    ) -> String where Value: Equatable & Sendable {
        switch change {
        case .keep: "Unchanged"
        case let .set(value): format(value)
        case .clear: cleared
        }
    }

    static func calendarSchedule(_ schedule: EventKitCalendarSchedule) -> String {
        switch schedule {
        case let .timed(start, end, timeZoneIdentifier):
            "\(dateTime(start, timeZoneIdentifier: timeZoneIdentifier)) – \(dateTime(end, timeZoneIdentifier: timeZoneIdentifier)) · \(timeZoneIdentifier)"
        case let .allDay(start, endExclusive):
            "\(localDate(start)) – before \(localDate(endExclusive)) · All day"
        }
    }

    static func reminderSchedule(_ schedule: EventKitReminderSchedule) -> String {
        "Start: \(reminderDate(schedule.start)) · Due: \(reminderDate(schedule.due))"
    }

    static func reminderDate(_ value: EventKitReminderDateValue?) -> String {
        guard let value else { return "None" }
        switch value {
        case let .timed(date, timeZoneIdentifier):
            return "\(dateTime(date, timeZoneIdentifier: timeZoneIdentifier)) · \(timeZoneIdentifier)"
        case let .allDay(local):
            return "\(localDate(local)) · All day"
        }
    }

    static func recurrence(_ spec: EventKitRecurrenceSpec?) -> String {
        guard let spec else { return "Does not repeat" }
        let unit: String
        switch spec.frequency {
        case .daily: unit = spec.interval == 1 ? "day" : "days"
        case .weekly: unit = spec.interval == 1 ? "week" : "weeks"
        case .monthly: unit = spec.interval == 1 ? "month" : "months"
        case .yearly: unit = spec.interval == 1 ? "year" : "years"
        }
        var value = "Every \(spec.interval) \(unit)"
        if !spec.weekdays.isEmpty {
            value += " on " + spec.weekdays.map(weekday).joined(separator: ", ")
        }
        switch spec.end {
        case .never: value += " · No end"
        case let .onDate(date): value += " · Until \(dateOnly(date))"
        case let .afterOccurrences(count): value += " · \(count) occurrences"
        }
        return value
    }

    static func alerts(_ offsets: [Int]) -> String {
        guard !offsets.isEmpty else { return "No alerts" }
        return offsets.map { minutes in
            switch minutes {
            case 0: "At time"
            case 1: "1 minute before"
            default: "\(minutes) minutes before"
            }
        }.joined(separator: ", ")
    }

    static func availability(_ value: EventKitEventAvailability) -> String {
        switch value {
        case .systemDefault: "System default"
        case .busy: "Busy"
        case .free: "Free"
        case .tentative: "Tentative"
        case .unavailable: "Unavailable"
        }
    }

    static func priority(_ value: EventKitReminderPriority) -> String {
        switch value {
        case .none: "None"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    static func reminderSearchStatus(_ value: EventKitReminderSearchStatus) -> String {
        switch value {
        case .incomplete: "Incomplete"
        case .completed: "Completed"
        case .all: "All"
        }
    }

    static func weekday(_ value: EventKitWeekday) -> String {
        switch value {
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        }
    }

    static func optional(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "None" }
        return value
    }

    static func alarmCompatibility(_ unsupportedAlarmCount: Int) -> String {
        let noun = unsupportedAlarmCount == 1 ? "alarm" : "alarms"
        return "\(unsupportedAlarmCount) absolute or unsupported \(noun); edits are blocked to preserve \(unsupportedAlarmCount == 1 ? "it" : "them")"
    }

    static func dateRange(_ start: Date, _ end: Date) -> String {
        "\(dateTime(start)) – \(dateTime(end))"
    }

    static func dateTime(
        _ date: Date,
        timeZoneIdentifier: String? = nil
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if let timeZoneIdentifier,
           let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            formatter.timeZone = timeZone
        }
        return formatter.string(from: date)
    }

    static func dateOnly(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func localDate(_ date: EventKitLocalDate) -> String {
        String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }
}
