import CoreLocation
import MapKit
import XCTest
@testable import OpenClamLiveKit

final class AgentToolServicesTests: XCTestCase {
    func testContactLookupSelectsOneExactNormalizedName() throws {
        let exact = try ContactEmailCandidate(
            displayName: "José Alvarez",
            label: "Work",
            emailAddress: "jose@example.com"
        )
        let partial = try ContactEmailCandidate(
            displayName: "Jose Alvarez-Smith",
            label: "Home",
            emailAddress: "other@example.com"
        )

        let outcome = try ContactEmailToolService.resolve(
            query: "  Jose   Alvarez ",
            candidates: [partial, exact],
            matchedContactCount: 2
        )

        XCTAssertEqual(outcome.status, .exact)
        XCTAssertEqual(outcome.exactCandidate, exact)
    }

    func testContactLookupDoesNotAutoSelectPartialMatch() throws {
        let candidate = try ContactEmailCandidate(
            displayName: "Emma Thompson",
            label: "Work",
            emailAddress: "emma@example.com"
        )

        let outcome = try ContactEmailToolService.resolve(
            query: "Emma",
            candidates: [candidate],
            matchedContactCount: 1
        )

        XCTAssertEqual(outcome.status, .ambiguous)
        XCTAssertNil(outcome.exactCandidate)
        XCTAssertEqual(outcome.candidates, [candidate])
    }

    func testContactWithTwoEmailsRequiresAChoice() throws {
        let candidates = try [
            ContactEmailCandidate(displayName: "Emma", label: "Work", emailAddress: "emma@work.example"),
            ContactEmailCandidate(displayName: "Emma", label: "Home", emailAddress: "emma@home.example"),
        ]

        let outcome = try ContactEmailToolService.resolve(
            query: "Emma",
            candidates: candidates,
            matchedContactCount: 1
        )

        XCTAssertEqual(outcome.status, .ambiguous)
        XCTAssertEqual(outcome.candidates.count, 2)
    }

    func testContactMatchWithoutEmailIsReportedWithoutReturningContactData() throws {
        let outcome = try ContactEmailToolService.resolve(
            query: "Emma",
            candidates: [],
            matchedContactCount: 1
        )

        XCTAssertEqual(outcome.status, .noEmail)
        XCTAssertTrue(outcome.candidates.isEmpty)
    }

    func testContactLookupResultHasNoModelEncodingSurface() throws {
        let candidate = try ContactEmailCandidate(
            displayName: "Emma",
            label: "Work",
            emailAddress: "private-address@example.com"
        )
        let outcome = try ContactEmailToolService.resolve(
            query: "Emma",
            candidates: [candidate],
            matchedContactCount: 1
        )

        XCTAssertFalse(isEncodable(candidate))
        XCTAssertFalse(isEncodable(outcome))
    }

    func testLocalContactFetchPlansUseOnlyExplicitMinimalKeys() throws {
        let nameRequest = try LocalContactSearchRequest(query: "Emma", fields: [.name])
        let namePlan = LocalContactFetchPlan.search(nameRequest)
        XCTAssertEqual(namePlan.predicate, .name("Emma"))
        XCTAssertEqual(namePlan.requiredPropertyKeys, [.name])

        let workRequest = try LocalContactSearchRequest(
            query: "Acme",
            fields: [.organization, .department, .jobTitle]
        )
        let workPlan = LocalContactFetchPlan.search(workRequest)
        XCTAssertEqual(workPlan.predicate, .allAccessibleContacts)
        XCTAssertEqual(
            workPlan.requiredPropertyKeys,
            [.name, .organization, .department, .jobTitle]
        )

        let addressRequest = try LocalContactSnapshotRequest(
            contactIdentifier: "contact-1",
            fields: [.phone, .email, .postalAddress, .birthday, .url, .relationship]
        )
        let addressPlan = LocalContactFetchPlan.snapshot(addressRequest)
        XCTAssertEqual(addressPlan.predicate, .identifiers(["contact-1"]))
        XCTAssertEqual(
            addressPlan.requiredPropertyKeys,
            [.name, .phone, .email, .postalAddress, .birthday, .url, .relationship]
        )
        XCTAssertFalse(addressPlan.requiredPropertyKeys.map(\.rawValue).contains("note"))
    }

    func testContactNotesAreRejectedBeforeAnyStoreRead() async throws {
        guard case let .unavailable(reason) = LocalContactFieldKind.note.availability else {
            return XCTFail("Notes must remain unavailable in this build")
        }
        XCTAssertTrue(reason.contains("com.apple.developer.contacts.notes"))
        XCTAssertTrue(reason.contains("Apple"))

        let backend = StubLocalContactStoreBackend(status: .authorized, records: [])
        let facade = LocalContactStoreFacade(backend: backend)
        XCTAssertThrowsError(
            try LocalContactSearchRequest(query: "private", fields: [.note])
        ) { error in
            guard case let LocalContactStoreError.unavailableField(field, unavailableReason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(field, .note)
            XCTAssertEqual(unavailableReason, reason)
        }
        let fetchCount = await backend.fetchCount
        XCTAssertEqual(fetchCount, 0)
        _ = facade
    }

    func testLocalContactSearchIsBoundedLocalAndTruthfulForLimitedAccess() async throws {
        let records = try (1 ... 5).map { index in
            try localRecord(
                identifier: "contact-\(index)",
                displayName: "Person \(index)",
                kind: .organization,
                value: "Acme Research \(index)"
            )
        }
        let backend = StubLocalContactStoreBackend(status: .limited, records: records)
        let facade = LocalContactStoreFacade(backend: backend)
        let request = try LocalContactSearchRequest(
            query: "Acme",
            fields: [.organization],
            maximumCandidates: 2,
            maximumContactsToInspect: 3
        )

        let result = try await facade.search(request)

        XCTAssertEqual(result.accessScope, .limited)
        XCTAssertEqual(result.inspectedContactCount, 3)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertTrue(result.hasMoreCandidates)
        XCTAssertTrue(result.completenessNotices.joined().contains("only contacts currently shared"))
        XCTAssertTrue(result.completenessNotices.joined().contains("truncated"))
        XCTAssertFalse(isEncodable(result))
        let fetchedPlan = await backend.lastPlan
        let plan = try XCTUnwrap(fetchedPlan)
        XCTAssertEqual(plan.requiredPropertyKeys, [.name, .organization])
        XCTAssertEqual(plan.maximumContactsToInspect, 3)
    }

    func testContactStoreChangeInvalidatesAnInFlightSnapshot() async throws {
        let record = try localRecord(
            identifier: "contact-1",
            displayName: "Emma",
            kind: .email,
            value: "emma@example.com"
        )
        let backend = StubLocalContactStoreBackend(
            status: .authorized,
            records: [record],
            advanceGenerationAfterFetch: true
        )
        let facade = LocalContactStoreFacade(backend: backend)
        let request = try LocalContactSnapshotRequest(
            contactIdentifier: "contact-1",
            fields: [.email]
        )

        do {
            _ = try await facade.snapshot(request)
            XCTFail("Expected a changed Contacts store to invalidate the snapshot")
        } catch let error as LocalContactStoreError {
            XCTAssertEqual(error, .contactsChangedDuringRead)
        }
    }

    func testPerValueContactFieldIDsAndDigestsBindIdentityAndContent() throws {
        let first = try localField(
            contactIdentifier: "contact-1",
            kind: .email,
            label: "Work",
            value: "emma@example.com",
            sourceIdentifier: "email-work"
        )
        let same = try localField(
            contactIdentifier: "contact-1",
            kind: .email,
            label: "Work",
            value: "emma@example.com",
            sourceIdentifier: "email-work"
        )
        let changedValue = try localField(
            contactIdentifier: "contact-1",
            kind: .email,
            label: "Work",
            value: "new@example.com",
            sourceIdentifier: "email-work"
        )
        let secondLabel = try localField(
            contactIdentifier: "contact-1",
            kind: .email,
            label: "Home",
            value: "emma@example.com",
            sourceIdentifier: "email-home"
        )

        XCTAssertEqual(first.id, same.id)
        XCTAssertEqual(first.digest, same.digest)
        XCTAssertEqual(first.id, changedValue.id)
        XCTAssertNotEqual(first.digest, changedValue.digest)
        XCTAssertNotEqual(first.id, secondLabel.id)
        XCTAssertFalse(isEncodable(first))
    }

    func testContactShareGrantConsumesExactlyOnceAndStoresNoRawContactData() async throws {
        let validator = ContactShareGrantValidator()
        let turnID = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let field = try localField(
            contactIdentifier: "raw-contact-id",
            kind: .email,
            label: "Work",
            value: "private-address@example.com",
            sourceIdentifier: "email-work"
        )
        let provider = LocalContactProviderFingerprint(
            endpoint: try XCTUnwrap(URL(string: "https://api.openai.com/v1/responses")),
            model: "gpt-5.6-luna"
        )
        let grant = try await validator.issue(
            turnID: turnID,
            contactIdentifier: "raw-contact-id",
            selectedFields: [field],
            providerFingerprint: provider,
            contactStoreGeneration: 7,
            now: now
        )

        XCTAssertFalse(isEncodable(grant))
        let reflected = String(reflecting: grant)
        XCTAssertFalse(reflected.contains("raw-contact-id"))
        XCTAssertFalse(reflected.contains("private-address@example.com"))
        XCTAssertFalse(reflected.contains("api.openai.com"))
        XCTAssertFalse(reflected.contains("gpt-5.6-luna"))

        let receipt = try await validator.consume(
            grantID: grant.id,
            turnID: turnID,
            contactIdentifier: "raw-contact-id",
            selectedFields: [field],
            providerFingerprint: provider,
            contactStoreGeneration: 7,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(receipt.grantID, grant.id)
        let pendingGrantCount = await validator.pendingGrantCount
        XCTAssertEqual(pendingGrantCount, 0)

        do {
            _ = try await validator.consume(
                grantID: grant.id,
                turnID: turnID,
                contactIdentifier: "raw-contact-id",
                selectedFields: [field],
                providerFingerprint: provider,
                contactStoreGeneration: 7,
                now: now.addingTimeInterval(2)
            )
            XCTFail("Expected a second consume to fail")
        } catch let error as ContactShareGrantError {
            XCTAssertEqual(error, .missingOrConsumed)
        }
    }

    func testContactShareGrantMismatchBurnsGrantAndExpiryFailsClosed() async throws {
        let validator = ContactShareGrantValidator()
        let turnID = UUID()
        let now = Date(timeIntervalSince1970: 2_000)
        let field = try localField(
            contactIdentifier: "contact-1",
            kind: .phone,
            label: "Mobile",
            value: "+1 415 555 0100",
            sourceIdentifier: "phone-mobile"
        )
        let provider = LocalContactProviderFingerprint(
            endpoint: try XCTUnwrap(URL(string: "https://api.openai.com/v1/responses")),
            model: "gpt-5.6-luna"
        )
        let wrongProvider = LocalContactProviderFingerprint(
            endpoint: try XCTUnwrap(URL(string: "https://provider.example.net/v1/responses")),
            model: "other-model"
        )
        let mismatched = try await validator.issue(
            turnID: turnID,
            contactIdentifier: "contact-1",
            selectedFields: [field],
            providerFingerprint: provider,
            contactStoreGeneration: 3,
            now: now
        )

        do {
            _ = try await validator.consume(
                grantID: mismatched.id,
                turnID: turnID,
                contactIdentifier: "contact-1",
                selectedFields: [field],
                providerFingerprint: wrongProvider,
                contactStoreGeneration: 3,
                now: now.addingTimeInterval(1)
            )
            XCTFail("Expected provider mismatch")
        } catch let error as ContactShareGrantError {
            XCTAssertEqual(error, .providerMismatch)
        }

        do {
            _ = try await validator.consume(
                grantID: mismatched.id,
                turnID: turnID,
                contactIdentifier: "contact-1",
                selectedFields: [field],
                providerFingerprint: provider,
                contactStoreGeneration: 3,
                now: now.addingTimeInterval(2)
            )
            XCTFail("A mismatch must burn the grant")
        } catch let error as ContactShareGrantError {
            XCTAssertEqual(error, .missingOrConsumed)
        }

        let expiring = try await validator.issue(
            turnID: turnID,
            contactIdentifier: "contact-1",
            selectedFields: [field],
            providerFingerprint: provider,
            contactStoreGeneration: 3,
            now: now,
            lifetime: 1
        )
        do {
            _ = try await validator.consume(
                grantID: expiring.id,
                turnID: turnID,
                contactIdentifier: "contact-1",
                selectedFields: [field],
                providerFingerprint: provider,
                contactStoreGeneration: 3,
                now: now.addingTimeInterval(1)
            )
            XCTFail("Expected expiry")
        } catch let error as ContactShareGrantError {
            XCTAssertEqual(error, .expired)
        }
    }

    func testMailDraftRejectsHeaderInjection() {
        XCTAssertThrowsError(
            try MailDraftContent(
                recipient: "emma@example.com\nBcc: someone@example.com",
                subject: "Running late",
                body: "I'll be there soon."
            )
        )
        XCTAssertThrowsError(
            try MailDraftContent(
                recipient: "emma@example.com",
                subject: "Running late\nBcc: someone@example.com",
                body: "I'll be there soon."
            )
        )
    }

    @MainActor
    func testNearbySearchUsesDeviceCenteredRegionAndSortsByDistance() async throws {
        let origin = CLLocation(latitude: 37.7749, longitude: -122.4194)
        let locationProvider = StubLocationProvider(location: origin)
        let mapSearcher = StubNearbyMapSearcher(items: [
            mapItem(name: "Far", latitude: 37.7949, longitude: -122.4194),
            mapItem(name: "Near", latitude: 37.7754, longitude: -122.4194),
            mapItem(name: "Outside", latitude: 38.7749, longitude: -122.4194),
        ])
        let service = NearbyPlaceToolService(
            locationProvider: locationProvider,
            mapSearcher: mapSearcher
        )

        let outcome = try await service.searchNearby(
            query: "McDonald's",
            radiusMeters: 5_000,
            limit: 8
        )

        XCTAssertEqual(mapSearcher.receivedQuery, "McDonald's")
        let receivedRegion = try XCTUnwrap(mapSearcher.receivedRegion)
        XCTAssertEqual(receivedRegion.center.latitude, origin.coordinate.latitude, accuracy: 0.000_001)
        XCTAssertEqual(receivedRegion.center.longitude, origin.coordinate.longitude, accuracy: 0.000_001)
        XCTAssertEqual(outcome.candidates.map(\.name), ["Near", "Far"])
        XCTAssertLessThan(outcome.candidates[0].distanceMeters, outcome.candidates[1].distanceMeters)
    }

    @MainActor
    func testModelSafeNearbyResultCannotEncodePreciseLocationOrDistance() async throws {
        let locationProvider = StubLocationProvider(
            location: CLLocation(latitude: 37.7749, longitude: -122.4194)
        )
        let service = NearbyPlaceToolService(
            locationProvider: locationProvider,
            mapSearcher: StubNearbyMapSearcher(items: [
                mapItem(name: "Nearby Cafe", latitude: 37.7754, longitude: -122.4194),
            ])
        )

        let outcome = try await service.searchNearby(query: "coffee")
        let encoded = try JSONEncoder().encode(outcome.modelSafeToolResult)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(json.contains("latitude"))
        XCTAssertFalse(json.contains("longitude"))
        XCTAssertFalse(json.contains("address"))
        XCTAssertFalse(json.contains("distanceMeters"))
        XCTAssertFalse(json.contains("37.7754"))
        XCTAssertFalse(json.contains(String(outcome.candidates[0].distanceMeters)))
        XCTAssertTrue(json.contains("under 500 m"))
        XCTAssertTrue(json.contains("Nearby Cafe"))
    }

    @MainActor
    func testNearbySearchRejectsAnUnboundedRadiusBeforeReadingLocation() async {
        let locationProvider = StubLocationProvider(location: CLLocation(latitude: 0, longitude: 0))
        let service = NearbyPlaceToolService(
            locationProvider: locationProvider,
            mapSearcher: StubNearbyMapSearcher(items: [])
        )

        do {
            _ = try await service.searchNearby(query: "coffee", radiusMeters: 100_000)
            XCTFail("Expected radius validation to fail")
        } catch let error as AgentToolServiceError {
            guard case .invalidInput(field: "search radius", reason: _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(locationProvider.requestCount, 0)
    }

    private func mapItem(name: String, latitude: Double, longitude: Double) -> MKMapItem {
        let item = MKMapItem(
            placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        )
        item.name = name
        return item
    }

    private func isEncodable(_ value: Any) -> Bool {
        value is any Encodable
    }

    private func localField(
        contactIdentifier: String,
        kind: LocalContactFieldKind,
        label: String,
        value: String,
        sourceIdentifier: String = "value"
    ) throws -> LocalContactFieldValue {
        try LocalContactFieldValue(
            contactIdentifier: contactIdentifier,
            kind: kind,
            label: label,
            value: value,
            sourceIdentifier: sourceIdentifier
        )
    }

    private func localRecord(
        identifier: String,
        displayName: String,
        kind: LocalContactFieldKind,
        value: String
    ) throws -> LocalContactRecord {
        .init(
            contactIdentifier: identifier,
            displayName: displayName,
            fields: [
                try localField(
                    contactIdentifier: identifier,
                    kind: kind,
                    label: kind.rawValue,
                    value: value
                ),
            ],
            fieldsWereTruncated: false
        )
    }
}

private actor StubLocalContactStoreBackend: LocalContactStoreBackend {
    let status: LocalContactAuthorizationStatus
    let records: [LocalContactRecord]
    let advanceGenerationAfterFetch: Bool
    private(set) var fetchCount = 0
    private(set) var lastPlan: LocalContactFetchPlan?
    private var generation: UInt64 = 0

    init(
        status: LocalContactAuthorizationStatus,
        records: [LocalContactRecord],
        advanceGenerationAfterFetch: Bool = false
    ) {
        self.status = status
        self.records = records
        self.advanceGenerationAfterFetch = advanceGenerationAfterFetch
    }

    func authorizationStatus() -> LocalContactAuthorizationStatus {
        status
    }

    func requestAccess() -> LocalContactAuthorizationStatus {
        status
    }

    func fetchRecords(plan: LocalContactFetchPlan) -> LocalContactStoreBatch {
        fetchCount += 1
        lastPlan = plan
        let bounded = Array(records.prefix(plan.maximumContactsToInspect))
        let result = LocalContactStoreBatch(
            records: bounded,
            inspectedContactCount: bounded.count,
            wasTruncated: records.count > bounded.count
        )
        if advanceGenerationAfterFetch {
            generation &+= 1
        }
        return result
    }

    func contactStoreGeneration() -> UInt64 {
        generation
    }
}

@MainActor
private final class StubLocationProvider: AgentLocationProviding {
    let location: CLLocation
    private(set) var requestCount = 0

    init(location: CLLocation) {
        self.location = location
    }

    func currentLocation() async throws -> CLLocation {
        requestCount += 1
        return location
    }
}

@MainActor
private final class StubNearbyMapSearcher: AgentNearbyMapSearching {
    let items: [MKMapItem]
    private(set) var receivedQuery: String?
    private(set) var receivedRegion: MKCoordinateRegion?

    init(items: [MKMapItem]) {
        self.items = items
    }

    func mapItems(matching query: String, in region: MKCoordinateRegion) async throws -> [MKMapItem] {
        receivedQuery = query
        receivedRegion = region
        return items
    }
}
