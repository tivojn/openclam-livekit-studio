import Foundation
import XCTest
@testable import OpenClamLiveKit

final class ContactAgentSessionTests: XCTestCase {
    @MainActor
    func testStageDoesNotReadContactsOrCallProviderUntilExplicitSearch() async throws {
        let fixture = try makeFixture()
        let store = ContactAgentStoreSpy(
            searchResult: fixture.searchResult,
            snapshots: [fixture.snapshot]
        )
        let responder = ContactAgentResponderSpy(reply: "Draft ready")
        let session = ContactAgentSession(localStore: store, responder: responder)

        try await session.stage(
            turnID: UUID(),
            originalUserRequest: "Write an email to Emma saying I will be late.",
            query: "Emma",
            searchFields: [.name],
            requestedFields: [.email]
        )

        XCTAssertEqual(session.status, .staged)
        XCTAssertTrue(session.candidates.isEmpty)
        var searchCount = await store.searchCount()
        var snapshotCount = await store.snapshotCount()
        var responderCount = await responder.callCount()
        XCTAssertEqual(searchCount, 0)
        XCTAssertEqual(snapshotCount, 0)
        XCTAssertEqual(responderCount, 0)

        try await session.searchLocally()

        XCTAssertEqual(session.status, .showingCandidates)
        XCTAssertEqual(session.candidates.map(\.displayName), ["Emma Chen"])
        searchCount = await store.searchCount()
        snapshotCount = await store.snapshotCount()
        responderCount = await responder.callCount()
        XCTAssertEqual(searchCount, 1)
        XCTAssertEqual(snapshotCount, 0)
        XCTAssertEqual(responderCount, 0)
    }

    @MainActor
    func testCandidateFieldsDefaultOffAndNotesStayUnavailable() async throws {
        let fixture = try makeFixture()
        let store = ContactAgentStoreSpy(
            searchResult: fixture.searchResult,
            snapshots: [fixture.snapshot]
        )
        let responder = ContactAgentResponderSpy(reply: "Unused")
        let session = ContactAgentSession(localStore: store, responder: responder)

        try await session.stage(
            turnID: UUID(),
            originalUserRequest: "Help me contact Emma.",
            query: "Emma",
            searchFields: [.name],
            requestedFields: [.email, .phone, .note]
        )
        try await session.searchLocally()
        try await session.chooseCandidate(id: fixture.candidate.id)

        XCTAssertEqual(session.status, .selectingFields)
        XCTAssertEqual(Set(session.fieldSelections.map(\.field.kind)), [.email, .phone])
        XCTAssertTrue(session.fieldSelections.allSatisfy { !$0.isSelected })
        XCTAssertEqual(session.selectedFieldCount, 0)
        let notes = try XCTUnwrap(session.unavailableFields.first(where: { $0.field == .note }))
        XCTAssertTrue(notes.reason.contains("com.apple.developer.contacts.notes"))
        let snapshotRequests = await store.snapshotRequests()
        let request = try XCTUnwrap(snapshotRequests.first)
        XCTAssertFalse(request.fields.contains(.note))
        let responderCount = await responder.callCount()
        XCTAssertEqual(responderCount, 0)
    }

    @MainActor
    func testReviewedShareIsOneShotRefetchesExactValuesAndCallsBack() async throws {
        let fixture = try makeFixture()
        let events = ContactAgentEventRecorder()
        let store = ContactAgentStoreSpy(
            searchResult: fixture.searchResult,
            snapshots: [fixture.snapshot, fixture.snapshot],
            events: events
        )
        let grants = RecordingContactAgentGrantValidator(events: events)
        let responder = ContactAgentResponderSpy(reply: "Subject: Running late\n\nI’ll arrive at 7:30.", events: events)
        let callback = ContactAgentReplyBox()
        let session = ContactAgentSession(
            localStore: store,
            grantValidator: grants,
            responder: responder,
            onReply: { callback.value = $0 }
        )

        try await stageAndChoose(session, fixture: fixture)
        let email = try XCTUnwrap(
            session.fieldSelections.first(where: { $0.field.kind == .email })
        )
        try await session.setFieldSelected(id: email.id, isSelected: true)
        try await session.prepareShareReview(
            providerEndpoint: "https://api.openai.com/v1/responses",
            providerModel: "gpt-5.6-luna"
        )

        let review = try XCTUnwrap(session.shareReview)
        XCTAssertEqual(review.selectedFields.map(\.value), ["emma.private@example.com"])
        XCTAssertEqual(review.provider.endpoint.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(review.provider.model, "gpt-5.6-luna")
        let callsBeforeShare = await responder.callCount()
        XCTAssertEqual(callsBeforeShare, 0)

        await events.clear()
        let reply = try await session.shareReviewedFields()

        XCTAssertEqual(reply, "Subject: Running late\n\nI’ll arrive at 7:30.")
        XCTAssertEqual(callback.value, reply)
        let finalEvents = await events.values()
        let snapshotCount = await store.snapshotCount()
        XCTAssertEqual(finalEvents, ["consume-grant", "snapshot", "respond"])
        XCTAssertEqual(snapshotCount, 2)

        let responderRequests = await responder.requests()
        let request = try XCTUnwrap(responderRequests.first)
        XCTAssertEqual(request.originalUserRequest, "Write an email to Emma saying I will be late.")
        XCTAssertEqual(request.fields.map(\.kind), [.email])
        XCTAssertEqual(request.fields.map(\.value), ["emma.private@example.com"])
        XCTAssertFalse(request.fields.map(\.kind).contains(.name))
        XCTAssertFalse(request.fields.map(\.value).contains("Emma Chen"))
        XCTAssertFalse(request.fields.map(\.value).contains("+1 415 555 0100"))

        XCTAssertEqual(session.status, .completed)
        XCTAssertNil(session.stagedRequest)
        XCTAssertTrue(session.candidates.isEmpty)
        XCTAssertTrue(session.fieldSelections.isEmpty)
        XCTAssertNil(session.shareReview)

        do {
            _ = try await session.shareReviewedFields()
            XCTFail("A second share must require a new local review")
        } catch let error as ContactAgentSessionError {
            XCTAssertEqual(error, .reviewUnavailable)
        }
    }

    @MainActor
    func testChangedSelectedValueBurnsGrantBeforeAnyProviderCall() async throws {
        let fixture = try makeFixture()
        let changedEmail = try field(
            kind: .email,
            value: "new-address@example.com",
            sourceIdentifier: "email-work"
        )
        let changedSnapshot = LocalContactSnapshot(
            contactIdentifier: fixture.snapshot.contactIdentifier,
            displayName: fixture.snapshot.displayName,
            fields: [changedEmail, fixture.phone],
            fieldsWereTruncated: false,
            accessScope: .full,
            contactStoreGeneration: fixture.snapshot.contactStoreGeneration
        )
        let store = ContactAgentStoreSpy(
            searchResult: fixture.searchResult,
            snapshots: [fixture.snapshot, changedSnapshot]
        )
        let responder = ContactAgentResponderSpy(reply: "Must not run")
        let session = ContactAgentSession(localStore: store, responder: responder)

        try await stageAndChoose(session, fixture: fixture)
        let email = try XCTUnwrap(
            session.fieldSelections.first(where: { $0.field.kind == .email })
        )
        try await session.setFieldSelected(id: email.id, isSelected: true)
        try await session.prepareShareReview(
            providerEndpoint: "https://api.openai.com/v1/responses",
            providerModel: "gpt-5.6-luna"
        )

        do {
            _ = try await session.shareReviewedFields()
            XCTFail("A changed value must fail closed")
        } catch let error as ContactAgentSessionError {
            XCTAssertEqual(error, .selectionChanged)
        }
        let responderCount = await responder.callCount()
        XCTAssertEqual(responderCount, 0)
        XCTAssertNil(session.shareReview)
        XCTAssertTrue(session.fieldSelections.isEmpty)
        XCTAssertEqual(session.status, .showingCandidates)

        do {
            _ = try await session.shareReviewedFields()
            XCTFail("The failed attempt must burn the one-time grant")
        } catch let error as ContactAgentSessionError {
            XCTAssertEqual(error, .reviewUnavailable)
        }
    }

    func testProductionResponderSendsOneHistoryFreeInputWithNoTools() async throws {
        let transport = ContactAgentTransportSpy(
            responseJSON: """
            {
              "id": "resp_contact",
              "status": "completed",
              "output": [
                {
                  "type": "message",
                  "role": "assistant",
                  "content": [
                    {"type": "output_text", "text": "Draft ready"}
                  ]
                }
              ]
            }
            """
        )
        let responder = OpenAIContactAgentResponder(
            credentialStore: ContactAgentMemoryCredentialStore(apiKey: "sk-test"),
            transport: transport
        )
        let provider = try ContactAgentProvider(
            endpoint: "https://api.openai.com/v1/responses",
            model: "gpt-5.6-luna"
        )
        let request = ContactAgentIsolatedRequest(
            originalUserRequest: "Draft a short email.",
            fields: [
                .init(kind: .email, label: "Work", value: "emma.private@example.com"),
            ]
        )

        let reply = try await responder.respond(to: request, provider: provider)

        XCTAssertEqual(reply, "Draft ready")
        let sentRequests = await transport.requests()
        let sentRequest = try XCTUnwrap(sentRequests.first)
        let bodyData = try XCTUnwrap(sentRequest.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["tool_choice"])
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? String)
        XCTAssertTrue(content.contains("Draft a short email."))
        XCTAssertTrue(content.contains("emma.private@example.com"))
        XCTAssertFalse(content.contains("Emma Chen"))
        XCTAssertFalse(content.contains("reviewed_contact_name"))
        XCTAssertFalse(content.contains("conversation_history"))
        XCTAssertTrue((body["instructions"] as? String)?.contains("untrusted data") == true)
        XCTAssertFalse(isEncodable(request))
    }

    func testProductionResponderUsesOnlyTheReviewedProvidersCredentialSlot() async throws {
        let transport = ContactAgentTransportSpy(
            responseJSON: """
            {
              "id": "resp_contact_xai",
              "status": "completed",
              "output": [
                {
                  "type": "message",
                  "role": "assistant",
                  "content": [
                    {"type": "output_text", "text": "Draft ready"}
                  ]
                }
              ]
            }
            """
        )
        let vault = InMemoryProviderCredentialVault()
        try vault.saveCredential("sk-openai-only", for: .openAI)
        try vault.saveCredential("xai-reviewed-key", for: .xAI)
        let responder = ProviderContactAgentResponder(vault: vault, transport: transport)
        let provider = try ContactAgentProvider(provider: .xAI, model: "grok-4.5")
        let request = ContactAgentIsolatedRequest(
            originalUserRequest: "Draft a short email.",
            fields: [
                .init(kind: .email, label: "Work", value: "emma.private@example.com"),
            ]
        )

        _ = try await responder.respond(to: request, provider: provider)

        let sentRequests = await transport.requests()
        let sent = try XCTUnwrap(sentRequests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.x.ai/v1/responses")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer xai-reviewed-key")
        XCTAssertFalse(sent.allHTTPHeaderFields?.values.contains("Bearer sk-openai-only") == true)
    }

    @MainActor
    private func stageAndChoose(
        _ session: ContactAgentSession,
        fixture: ContactAgentFixture
    ) async throws {
        try await session.stage(
            turnID: UUID(),
            originalUserRequest: "Write an email to Emma saying I will be late.",
            query: "Emma",
            searchFields: [.name],
            requestedFields: [.email, .phone]
        )
        try await session.searchLocally()
        try await session.chooseCandidate(id: fixture.candidate.id)
    }

    private func makeFixture() throws -> ContactAgentFixture {
        let name = try field(kind: .name, label: "Name", value: "Emma Chen", sourceIdentifier: "name")
        let email = try field(
            kind: .email,
            value: "emma.private@example.com",
            sourceIdentifier: "email-work"
        )
        let phone = try field(
            kind: .phone,
            label: "Mobile",
            value: "+1 415 555 0100",
            sourceIdentifier: "phone-mobile"
        )
        let candidate = LocalContactSearchCandidate(
            contactIdentifier: "contact-emma",
            displayName: "Emma Chen",
            matchedFields: [name],
            fieldsWereTruncated: false
        )
        let result = LocalContactSearchResult(
            query: "Emma",
            searchedFields: [.name],
            candidates: [candidate],
            accessScope: .limited,
            inspectedContactCount: 1,
            hasMoreCandidates: false,
            contactStoreGeneration: 7
        )
        let snapshot = LocalContactSnapshot(
            contactIdentifier: candidate.contactIdentifier,
            displayName: candidate.displayName,
            fields: [email, phone],
            fieldsWereTruncated: false,
            accessScope: .limited,
            contactStoreGeneration: 7
        )
        return .init(
            candidate: candidate,
            searchResult: result,
            snapshot: snapshot,
            email: email,
            phone: phone
        )
    }

    private func field(
        kind: LocalContactFieldKind,
        label: String = "Work",
        value: String,
        sourceIdentifier: String
    ) throws -> LocalContactFieldValue {
        try .init(
            contactIdentifier: "contact-emma",
            kind: kind,
            label: label,
            value: value,
            sourceIdentifier: sourceIdentifier
        )
    }

    private func isEncodable(_ value: Any) -> Bool {
        value is any Encodable
    }
}

private struct ContactAgentFixture {
    let candidate: LocalContactSearchCandidate
    let searchResult: LocalContactSearchResult
    let snapshot: LocalContactSnapshot
    let email: LocalContactFieldValue
    let phone: LocalContactFieldValue
}

private actor ContactAgentStoreSpy: ContactAgentLocalStore {
    private let searchResult: LocalContactSearchResult
    private var snapshots: [LocalContactSnapshot]
    private let events: ContactAgentEventRecorder?
    private var recordedSearches: [LocalContactSearchRequest] = []
    private var recordedSnapshots: [LocalContactSnapshotRequest] = []

    init(
        searchResult: LocalContactSearchResult,
        snapshots: [LocalContactSnapshot],
        events: ContactAgentEventRecorder? = nil
    ) {
        self.searchResult = searchResult
        self.snapshots = snapshots
        self.events = events
    }

    func search(_ request: LocalContactSearchRequest) async throws -> LocalContactSearchResult {
        recordedSearches.append(request)
        await events?.append("search")
        return searchResult
    }

    func snapshot(_ request: LocalContactSnapshotRequest) async throws -> LocalContactSnapshot {
        recordedSnapshots.append(request)
        await events?.append("snapshot")
        guard !snapshots.isEmpty else { throw LocalContactStoreError.contactUnavailable }
        return snapshots.removeFirst()
    }

    func isCurrent(contactStoreGeneration: UInt64) async -> Bool {
        snapshots.first?.contactStoreGeneration == contactStoreGeneration
            || searchResult.contactStoreGeneration == contactStoreGeneration
    }

    func searchCount() -> Int { recordedSearches.count }
    func snapshotCount() -> Int { recordedSnapshots.count }
    func snapshotRequests() -> [LocalContactSnapshotRequest] { recordedSnapshots }
}

private actor ContactAgentResponderSpy: ContactAgentIsolatedResponding {
    private let reply: String
    private let events: ContactAgentEventRecorder?
    private var recordedRequests: [ContactAgentIsolatedRequest] = []

    init(reply: String, events: ContactAgentEventRecorder? = nil) {
        self.reply = reply
        self.events = events
    }

    func respond(
        to request: ContactAgentIsolatedRequest,
        provider: ContactAgentProvider
    ) async throws -> String {
        recordedRequests.append(request)
        await events?.append("respond")
        return reply
    }

    func callCount() -> Int { recordedRequests.count }
    func requests() -> [ContactAgentIsolatedRequest] { recordedRequests }
}

private actor RecordingContactAgentGrantValidator: ContactAgentGrantValidating {
    private let base = ContactShareGrantValidator()
    private let events: ContactAgentEventRecorder

    init(events: ContactAgentEventRecorder) {
        self.events = events
    }

    func issue(
        turnID: UUID,
        contactIdentifier: String,
        selectedFields: [LocalContactFieldValue],
        providerFingerprint: LocalContactProviderFingerprint,
        contactStoreGeneration: UInt64,
        now: Date,
        lifetime: TimeInterval
    ) async throws -> ContactShareGrant {
        try await base.issue(
            turnID: turnID,
            contactIdentifier: contactIdentifier,
            selectedFields: selectedFields,
            providerFingerprint: providerFingerprint,
            contactStoreGeneration: contactStoreGeneration,
            now: now,
            lifetime: lifetime
        )
    }

    func consume(
        grantID: UUID,
        turnID: UUID,
        contactIdentifier: String,
        selectedFields: [LocalContactFieldValue],
        providerFingerprint: LocalContactProviderFingerprint,
        contactStoreGeneration: UInt64,
        now: Date
    ) async throws -> ContactShareGrantReceipt {
        let receipt = try await base.consume(
            grantID: grantID,
            turnID: turnID,
            contactIdentifier: contactIdentifier,
            selectedFields: selectedFields,
            providerFingerprint: providerFingerprint,
            contactStoreGeneration: contactStoreGeneration,
            now: now
        )
        await events.append("consume-grant")
        return receipt
    }

    func invalidateAll() async {
        await base.invalidateAll()
    }
}

private actor ContactAgentEventRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func clear() {
        events = []
    }

    func values() -> [String] {
        events
    }
}

@MainActor
private final class ContactAgentReplyBox {
    var value: String?
}

private struct ContactAgentMemoryCredentialStore: AgentCredentialStore {
    let apiKey: String?

    func saveAPIKey(_ apiKey: String) throws {}
    func loadAPIKey() throws -> String? { apiKey }
    func deleteAPIKey() throws {}
}

private actor ContactAgentTransportSpy: OpenAIResponsesTransport {
    private let responseData: Data
    private var recordedRequests: [URLRequest] = []

    init(responseJSON: String) {
        responseData = Data(responseJSON.utf8)
    }

    func send(_ request: URLRequest) async throws -> OpenAITransportResponse {
        recordedRequests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return .init(data: responseData, response: response)
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}
