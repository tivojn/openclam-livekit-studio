import Contacts
import CryptoKit
import Foundation

/// Contact fields that the local Contacts boundary understands. Notes remain
/// visible as an unavailable capability so callers can explain the limitation
/// without ever attempting to fetch `CNContactNoteKey`.
enum LocalContactFieldKind: String, CaseIterable, Hashable, Sendable {
    case name
    case organization
    case department
    case jobTitle
    case phone
    case email
    case postalAddress
    case birthday
    case url
    case relationship
    case note

    static let noteUnavailableReason =
        "Contact notes require Apple’s com.apple.developer.contacts.notes entitlement and approval before public distribution. This build does not request or read notes."

    var availability: LocalContactFieldAvailability {
        switch self {
        case .note:
            return .unavailable(reason: Self.noteUnavailableReason)
        default:
            return .available
        }
    }

    fileprivate var propertyKey: LocalContactPropertyKey? {
        switch self {
        case .name: .name
        case .organization: .organization
        case .department: .department
        case .jobTitle: .jobTitle
        case .phone: .phone
        case .email: .email
        case .postalAddress: .postalAddress
        case .birthday: .birthday
        case .url: .url
        case .relationship: .relationship
        case .note: nil
        }
    }
}

enum LocalContactFieldAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

enum LocalContactAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case limited
}

enum LocalContactAccessScope: Equatable, Sendable {
    case full
    case limited

    var completenessNotice: String? {
        switch self {
        case .full:
            return nil
        case .limited:
            return "Results include only contacts currently shared with this app. A missing result does not mean the contact is absent from the device."
        }
    }
}

enum LocalContactStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidQuery
    case invalidLimit
    case noFields
    case unavailableField(LocalContactFieldKind, reason: String)
    case permissionDenied
    case permissionRestricted
    case contactUnavailable
    case contactsChangedDuringRead
    case storeUnavailable
    case invalidFieldValue

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            "Enter a contact search of 2 to 160 characters without control characters."
        case .invalidLimit:
            "The local Contacts search limit is outside the supported bounded range."
        case .noFields:
            "Choose at least one contact field to search or review."
        case let .unavailableField(_, reason):
            reason
        case .permissionDenied:
            "Contacts access is off. Results may become available after access is enabled or a contact is shared with this app."
        case .permissionRestricted:
            "Contacts access is restricted on this device."
        case .contactUnavailable:
            "That contact is no longer available to this app. Choose it again."
        case .contactsChangedDuringRead:
            "Contacts changed while the local review was being prepared. Search again before sharing anything."
        case .storeUnavailable:
            "Contacts could not be searched on this device right now."
        case .invalidFieldValue:
            "A selected contact field could not be represented safely."
        }
    }
}

/// These are the only keys the Apple store adapter can fetch. There is
/// intentionally no Notes case.
enum LocalContactPropertyKey: String, Hashable, Sendable {
    case name
    case organization
    case department
    case jobTitle
    case phone
    case email
    case postalAddress
    case birthday
    case url
    case relationship
}

enum LocalContactStorePredicate: Equatable, Sendable {
    case allAccessibleContacts
    case name(String)
    case email(String)
    case phone(String)
    case identifiers([String])
}

struct LocalContactSearchRequest: Equatable, Sendable {
    static let defaultCandidateLimit = 20
    static let maximumCandidateLimit = 25
    static let defaultInspectionLimit = 500
    static let maximumInspectionLimit = 2_000

    let query: String
    let fields: Set<LocalContactFieldKind>
    let maximumCandidates: Int
    let maximumContactsToInspect: Int

    init(
        query rawQuery: String,
        fields: Set<LocalContactFieldKind>,
        maximumCandidates: Int = Self.defaultCandidateLimit,
        maximumContactsToInspect: Int = Self.defaultInspectionLimit
    ) throws {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2 ... 160).contains(query.count),
              !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LocalContactStoreError.invalidQuery
        }
        try Self.validate(fields: fields)
        guard (1 ... Self.maximumCandidateLimit).contains(maximumCandidates),
              (1 ... Self.maximumInspectionLimit).contains(maximumContactsToInspect) else {
            throw LocalContactStoreError.invalidLimit
        }

        self.query = query
        self.fields = fields
        self.maximumCandidates = maximumCandidates
        self.maximumContactsToInspect = maximumContactsToInspect
    }

    static func validate(fields: Set<LocalContactFieldKind>) throws {
        guard !fields.isEmpty else { throw LocalContactStoreError.noFields }
        for field in fields {
            if case let .unavailable(reason) = field.availability {
                throw LocalContactStoreError.unavailableField(field, reason: reason)
            }
        }
    }
}

struct LocalContactSnapshotRequest: Equatable, Sendable {
    static let defaultMaximumValues = 48
    static let maximumValueLimit = 96

    let contactIdentifier: String
    let fields: Set<LocalContactFieldKind>
    let maximumValues: Int

    init(
        contactIdentifier rawIdentifier: String,
        fields: Set<LocalContactFieldKind>,
        maximumValues: Int = Self.defaultMaximumValues
    ) throws {
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, identifier.count <= 512,
              !identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LocalContactStoreError.contactUnavailable
        }
        try LocalContactSearchRequest.validate(fields: fields)
        guard (1 ... Self.maximumValueLimit).contains(maximumValues) else {
            throw LocalContactStoreError.invalidLimit
        }
        contactIdentifier = identifier
        self.fields = fields
        self.maximumValues = maximumValues
    }
}

struct LocalContactFetchPlan: Equatable, Sendable {
    let predicate: LocalContactStorePredicate
    let requestedFields: Set<LocalContactFieldKind>
    let requiredPropertyKeys: Set<LocalContactPropertyKey>
    let maximumContactsToInspect: Int
    let maximumValuesPerContact: Int

    static func search(_ request: LocalContactSearchRequest) -> Self {
        let predicate: LocalContactStorePredicate
        if request.fields.count == 1, let field = request.fields.first {
            switch field {
            case .name:
                predicate = .name(request.query)
            case .email:
                predicate = .email(request.query)
            case .phone:
                predicate = .phone(request.query)
            default:
                predicate = .allAccessibleContacts
            }
        } else {
            // Contacts does not support compound predicates. Enumerate only
            // after local approval and filter the explicitly selected keys.
            predicate = .allAccessibleContacts
        }

        return .init(
            predicate: predicate,
            requestedFields: request.fields,
            requiredPropertyKeys: requiredKeys(for: request.fields),
            maximumContactsToInspect: request.maximumContactsToInspect,
            maximumValuesPerContact: LocalContactSnapshotRequest.defaultMaximumValues
        )
    }

    static func snapshot(_ request: LocalContactSnapshotRequest) -> Self {
        .init(
            predicate: .identifiers([request.contactIdentifier]),
            requestedFields: request.fields,
            requiredPropertyKeys: requiredKeys(for: request.fields),
            maximumContactsToInspect: 1,
            maximumValuesPerContact: request.maximumValues
        )
    }

    private static func requiredKeys(
        for fields: Set<LocalContactFieldKind>
    ) -> Set<LocalContactPropertyKey> {
        var keys: Set<LocalContactPropertyKey> = [.name]
        for field in fields {
            if let key = field.propertyKey {
                keys.insert(key)
            }
        }
        return keys
    }
}

struct LocalContactIdentifierDigest: Hashable, Sendable {
    fileprivate let value: String

    fileprivate init(contactIdentifier: String) {
        value = LocalContactHash.digest(parts: ["contact", contactIdentifier])
    }
}

struct LocalContactFieldID: Hashable, Sendable {
    fileprivate let value: String

    fileprivate init(
        contactIdentifier: String,
        kind: LocalContactFieldKind,
        sourceIdentifier: String
    ) {
        value = LocalContactHash.digest(
            parts: ["field-id", contactIdentifier, kind.rawValue, sourceIdentifier]
        )
    }
}

struct LocalContactFieldDigest: Hashable, Sendable {
    fileprivate let value: String

    fileprivate init(
        id: LocalContactFieldID,
        kind: LocalContactFieldKind,
        label: String,
        value: String
    ) {
        self.value = LocalContactHash.digest(
            parts: ["field-value", id.value, kind.rawValue, label, value]
        )
    }
}

/// A local review value. It is intentionally not Codable. The raw contact
/// identifier is converted to a digest and is not retained here.
struct LocalContactFieldValue: Identifiable, Hashable, Sendable {
    static let maximumLabelLength = 80
    static let maximumValueLength = 4_096

    let id: LocalContactFieldID
    let contactDigest: LocalContactIdentifierDigest
    let kind: LocalContactFieldKind
    let label: String
    let value: String
    let digest: LocalContactFieldDigest
    let wasTruncated: Bool

    init(
        contactIdentifier: String,
        kind: LocalContactFieldKind,
        label rawLabel: String,
        value rawValue: String,
        sourceIdentifier: String
    ) throws {
        guard kind.availability == .available else {
            if case let .unavailable(reason) = kind.availability {
                throw LocalContactStoreError.unavailableField(kind, reason: reason)
            }
            throw LocalContactStoreError.invalidFieldValue
        }

        let labelResult = LocalContactText.bounded(
            rawLabel,
            maximumLength: Self.maximumLabelLength,
            allowNewlines: false
        )
        let valueResult = LocalContactText.bounded(
            rawValue,
            maximumLength: Self.maximumValueLength,
            allowNewlines: true
        )
        let source = LocalContactText.bounded(
            sourceIdentifier,
            maximumLength: 512,
            allowNewlines: false
        ).value
        let identifier = contactIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !source.isEmpty, !valueResult.value.isEmpty else {
            throw LocalContactStoreError.invalidFieldValue
        }

        let id = LocalContactFieldID(
            contactIdentifier: identifier,
            kind: kind,
            sourceIdentifier: source
        )
        self.id = id
        contactDigest = LocalContactIdentifierDigest(contactIdentifier: identifier)
        self.kind = kind
        label = labelResult.value.isEmpty ? kind.defaultLabel : labelResult.value
        value = valueResult.value
        digest = LocalContactFieldDigest(
            id: id,
            kind: kind,
            label: label,
            value: value
        )
        wasTruncated = labelResult.wasTruncated || valueResult.wasTruncated
    }
}

private extension LocalContactFieldKind {
    var defaultLabel: String {
        switch self {
        case .name: "Name"
        case .organization: "Organization"
        case .department: "Department"
        case .jobTitle: "Job title"
        case .phone: "Phone"
        case .email: "Email"
        case .postalAddress: "Address"
        case .birthday: "Birthday"
        case .url: "Website"
        case .relationship: "Relationship"
        case .note: "Note"
        }
    }
}

/// Store-adapter output. It remains local and deliberately does not conform to
/// Codable, Encodable, NSSecureCoding, or Transferable.
struct LocalContactRecord: Equatable, Sendable {
    let contactIdentifier: String
    let displayName: String
    let fields: [LocalContactFieldValue]
    let fieldsWereTruncated: Bool
}

struct LocalContactStoreBatch: Equatable, Sendable {
    let records: [LocalContactRecord]
    let inspectedContactCount: Int
    let wasTruncated: Bool
}

struct LocalContactSearchCandidate: Identifiable, Equatable, Sendable {
    var id: String { contactIdentifier }

    let contactIdentifier: String
    let displayName: String
    let matchedFields: [LocalContactFieldValue]
    let fieldsWereTruncated: Bool
}

struct LocalContactSearchResult: Equatable, Sendable {
    let query: String
    let searchedFields: Set<LocalContactFieldKind>
    let candidates: [LocalContactSearchCandidate]
    let accessScope: LocalContactAccessScope
    let inspectedContactCount: Int
    let hasMoreCandidates: Bool
    let contactStoreGeneration: UInt64

    var completenessNotices: [String] {
        var notices: [String] = []
        if let notice = accessScope.completenessNotice {
            notices.append(notice)
        }
        if hasMoreCandidates {
            notices.append("The bounded local search was truncated. Refine the query before concluding that no other match exists.")
        }
        return notices
    }
}

struct LocalContactSnapshot: Equatable, Sendable {
    let contactIdentifier: String
    let displayName: String
    let fields: [LocalContactFieldValue]
    let fieldsWereTruncated: Bool
    let accessScope: LocalContactAccessScope
    let contactStoreGeneration: UInt64
}

protocol LocalContactStoreBackend: Sendable {
    func authorizationStatus() async -> LocalContactAuthorizationStatus
    func requestAccess() async throws -> LocalContactAuthorizationStatus
    func fetchRecords(plan: LocalContactFetchPlan) async throws -> LocalContactStoreBatch
    func contactStoreGeneration() async -> UInt64
}

/// The sole facade intended for expanded local Contacts operations. It is not
/// MainActor-isolated; synchronous Contacts framework reads happen behind the
/// backend actor, away from the UI actor.
actor LocalContactStoreFacade {
    private let backend: any LocalContactStoreBackend

    init(backend: any LocalContactStoreBackend = AppleLocalContactStoreBackend()) {
        self.backend = backend
    }

    func search(_ request: LocalContactSearchRequest) async throws -> LocalContactSearchResult {
        let scope = try await authorizedScope()
        let generationBefore = await backend.contactStoreGeneration()
        let plan = LocalContactFetchPlan.search(request)
        let batch: LocalContactStoreBatch
        do {
            batch = try await backend.fetchRecords(plan: plan)
        } catch let error as LocalContactStoreError {
            throw error
        } catch {
            throw LocalContactStoreError.storeUnavailable
        }
        let generationAfter = await backend.contactStoreGeneration()
        guard generationBefore == generationAfter else {
            throw LocalContactStoreError.contactsChangedDuringRead
        }

        var candidates: [LocalContactSearchCandidate] = []
        var matchedRecordCount = 0
        for record in batch.records {
            let matchedFields = Self.matchingFields(
                in: record,
                query: request.query,
                predicate: plan.predicate
            )
            guard !matchedFields.isEmpty else { continue }
            matchedRecordCount += 1
            guard candidates.count < request.maximumCandidates else { continue }
            candidates.append(
                .init(
                    contactIdentifier: record.contactIdentifier,
                    displayName: record.displayName,
                    matchedFields: matchedFields,
                    fieldsWereTruncated: record.fieldsWereTruncated
                )
            )
        }

        return .init(
            query: request.query,
            searchedFields: request.fields,
            candidates: candidates,
            accessScope: scope,
            inspectedContactCount: batch.inspectedContactCount,
            hasMoreCandidates: batch.wasTruncated || matchedRecordCount > request.maximumCandidates,
            contactStoreGeneration: generationAfter
        )
    }

    func snapshot(_ request: LocalContactSnapshotRequest) async throws -> LocalContactSnapshot {
        let scope = try await authorizedScope()
        let generationBefore = await backend.contactStoreGeneration()
        let batch: LocalContactStoreBatch
        do {
            batch = try await backend.fetchRecords(plan: .snapshot(request))
        } catch let error as LocalContactStoreError {
            throw error
        } catch {
            throw LocalContactStoreError.storeUnavailable
        }
        let generationAfter = await backend.contactStoreGeneration()
        guard generationBefore == generationAfter else {
            throw LocalContactStoreError.contactsChangedDuringRead
        }
        guard let record = batch.records.first else {
            throw LocalContactStoreError.contactUnavailable
        }
        return .init(
            contactIdentifier: record.contactIdentifier,
            displayName: record.displayName,
            fields: record.fields,
            fieldsWereTruncated: record.fieldsWereTruncated || batch.wasTruncated,
            accessScope: scope,
            contactStoreGeneration: generationAfter
        )
    }

    func isCurrent(contactStoreGeneration generation: UInt64) async -> Bool {
        await backend.contactStoreGeneration() == generation
    }

    private func authorizedScope() async throws -> LocalContactAccessScope {
        var status = await backend.authorizationStatus()
        if status == .notDetermined {
            do {
                status = try await backend.requestAccess()
            } catch {
                throw LocalContactStoreError.permissionDenied
            }
        }
        switch status {
        case .authorized:
            return .full
        case .limited:
            return .limited
        case .restricted:
            throw LocalContactStoreError.permissionRestricted
        case .denied, .notDetermined:
            throw LocalContactStoreError.permissionDenied
        }
    }

    private static func matchingFields(
        in record: LocalContactRecord,
        query: String,
        predicate: LocalContactStorePredicate
    ) -> [LocalContactFieldValue] {
        record.fields.filter { field in
            switch predicate {
            case .name where field.kind == .name:
                // Apple performed the supported name match; formatted names do
                // not necessarily contain nicknames or phonetic matches.
                return true
            case .email where field.kind == .email:
                return LocalContactText.normalized(field.value)
                    == LocalContactText.normalized(query)
            case .phone where field.kind == .phone:
                return LocalContactText.phoneMatches(field.value, query)
            default:
                return LocalContactText.matches(field.value, query: query)
            }
        }
    }
}

actor AppleLocalContactStoreBackend: LocalContactStoreBackend {
    private let store: CNContactStore
    private let changeMonitor: LocalContactStoreChangeMonitor

    init(
        store: CNContactStore = CNContactStore(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        changeMonitor = LocalContactStoreChangeMonitor(notificationCenter: notificationCenter)
    }

    func authorizationStatus() -> LocalContactAuthorizationStatus {
        Self.localStatus(CNContactStore.authorizationStatus(for: .contacts))
    }

    func requestAccess() async throws -> LocalContactAuthorizationStatus {
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try await store.requestAccess(for: .contacts)
        }
        return Self.localStatus(CNContactStore.authorizationStatus(for: .contacts))
    }

    func fetchRecords(plan: LocalContactFetchPlan) throws -> LocalContactStoreBatch {
        let request = CNContactFetchRequest(keysToFetch: Self.descriptors(for: plan.requiredPropertyKeys))
        request.predicate = Self.predicate(for: plan.predicate)
        request.unifyResults = true

        var records: [LocalContactRecord] = []
        var inspectedCount = 0
        var wasTruncated = false
        try store.enumerateContacts(with: request) { contact, stop in
            guard inspectedCount < plan.maximumContactsToInspect else {
                wasTruncated = true
                stop.pointee = true
                return
            }
            inspectedCount += 1
            records.append(
                Self.localRecord(
                    from: contact,
                    requestedFields: plan.requestedFields,
                    maximumValues: plan.maximumValuesPerContact
                )
            )
        }
        return .init(
            records: records,
            inspectedContactCount: inspectedCount,
            wasTruncated: wasTruncated
        )
    }

    func contactStoreGeneration() -> UInt64 {
        changeMonitor.currentGeneration()
    }

    private static func localStatus(_ status: CNAuthorizationStatus) -> LocalContactAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .limited:
            if #available(iOS 18.0, *) {
                return .limited
            }
            return .denied
        @unknown default:
            return .denied
        }
    }

    private static func descriptors(
        for keys: Set<LocalContactPropertyKey>
    ) -> [CNKeyDescriptor] {
        keys.sorted { $0.rawValue < $1.rawValue }.map { key in
            switch key {
            case .name:
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
            case .organization:
                CNContactOrganizationNameKey as CNKeyDescriptor
            case .department:
                CNContactDepartmentNameKey as CNKeyDescriptor
            case .jobTitle:
                CNContactJobTitleKey as CNKeyDescriptor
            case .phone:
                CNContactPhoneNumbersKey as CNKeyDescriptor
            case .email:
                CNContactEmailAddressesKey as CNKeyDescriptor
            case .postalAddress:
                CNContactPostalAddressesKey as CNKeyDescriptor
            case .birthday:
                CNContactBirthdayKey as CNKeyDescriptor
            case .url:
                CNContactUrlAddressesKey as CNKeyDescriptor
            case .relationship:
                CNContactRelationsKey as CNKeyDescriptor
            }
        }
    }

    private static func predicate(for predicate: LocalContactStorePredicate) -> NSPredicate? {
        switch predicate {
        case .allAccessibleContacts:
            return nil
        case let .name(query):
            return CNContact.predicateForContacts(matchingName: query)
        case let .email(query):
            return CNContact.predicateForContacts(matchingEmailAddress: query)
        case let .phone(query):
            return CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))
        case let .identifiers(identifiers):
            return CNContact.predicateForContacts(withIdentifiers: identifiers)
        }
    }

    private static func localRecord(
        from contact: CNContact,
        requestedFields: Set<LocalContactFieldKind>,
        maximumValues: Int
    ) -> LocalContactRecord {
        let formattedName = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = formattedName?.isEmpty == false ? formattedName! : "Unnamed contact"
        var fields: [LocalContactFieldValue] = []
        var fieldsWereTruncated = false

        func append(
            kind: LocalContactFieldKind,
            label: String,
            value: String,
            sourceIdentifier: String
        ) {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard fields.count < maximumValues else {
                fieldsWereTruncated = true
                return
            }
            guard let field = try? LocalContactFieldValue(
                contactIdentifier: contact.identifier,
                kind: kind,
                label: label,
                value: value,
                sourceIdentifier: sourceIdentifier
            ) else { return }
            fieldsWereTruncated = fieldsWereTruncated || field.wasTruncated
            fields.append(field)
        }

        for kind in requestedFields.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch kind {
            case .name:
                append(kind: .name, label: "Name", value: displayName, sourceIdentifier: "name")
            case .organization:
                append(
                    kind: .organization,
                    label: "Organization",
                    value: contact.organizationName,
                    sourceIdentifier: "organization"
                )
            case .department:
                append(
                    kind: .department,
                    label: "Department",
                    value: contact.departmentName,
                    sourceIdentifier: "department"
                )
            case .jobTitle:
                append(
                    kind: .jobTitle,
                    label: "Job title",
                    value: contact.jobTitle,
                    sourceIdentifier: "job-title"
                )
            case .phone:
                for labeled in contact.phoneNumbers {
                    append(
                        kind: .phone,
                        label: localizedLabel(labeled.label, fallback: "Phone"),
                        value: labeled.value.stringValue,
                        sourceIdentifier: labeled.identifier
                    )
                }
            case .email:
                for labeled in contact.emailAddresses {
                    append(
                        kind: .email,
                        label: localizedLabel(labeled.label, fallback: "Email"),
                        value: labeled.value as String,
                        sourceIdentifier: labeled.identifier
                    )
                }
            case .postalAddress:
                for labeled in contact.postalAddresses {
                    append(
                        kind: .postalAddress,
                        label: localizedLabel(labeled.label, fallback: "Address"),
                        value: CNPostalAddressFormatter.string(from: labeled.value, style: .mailingAddress),
                        sourceIdentifier: labeled.identifier
                    )
                }
            case .birthday:
                if let birthday = contact.birthday,
                   let month = birthday.month,
                   let day = birthday.day,
                   (1 ... 12).contains(month),
                   (1 ... 31).contains(day) {
                    let value: String
                    if let year = birthday.year {
                        value = String(format: "%04d-%02d-%02d", year, month, day)
                    } else {
                        value = String(format: "--%02d-%02d", month, day)
                    }
                    append(
                        kind: .birthday,
                        label: "Birthday",
                        value: value,
                        sourceIdentifier: "birthday"
                    )
                }
            case .url:
                for labeled in contact.urlAddresses {
                    append(
                        kind: .url,
                        label: localizedLabel(labeled.label, fallback: "Website"),
                        value: labeled.value as String,
                        sourceIdentifier: labeled.identifier
                    )
                }
            case .relationship:
                for labeled in contact.contactRelations {
                    append(
                        kind: .relationship,
                        label: localizedLabel(labeled.label, fallback: "Relationship"),
                        value: labeled.value.name,
                        sourceIdentifier: labeled.identifier
                    )
                }
            case .note:
                // Notes never reach the fetch plan, and no Notes key exists in
                // this adapter. Keep the switch explicit as a second fail-safe.
                continue
            }
        }

        return .init(
            contactIdentifier: contact.identifier,
            displayName: displayName,
            fields: fields,
            fieldsWereTruncated: fieldsWereTruncated
        )
    }

    private static func localizedLabel(_ label: String?, fallback: String) -> String {
        label.map(CNLabeledValue<NSString>.localizedString(forLabel:)) ?? fallback
    }
}

private final class LocalContactStoreChangeMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var observer: NSObjectProtocol?
    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
        observer = notificationCenter.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.increment()
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func increment() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }
}

struct LocalContactProviderFingerprint: Hashable, Sendable {
    fileprivate let value: String

    init(endpoint: URL, model: String) {
        value = LocalContactHash.digest(
            parts: ["provider", endpoint.absoluteString, model]
        )
    }
}

struct ContactShareFieldBinding: Hashable, Sendable {
    let fieldID: LocalContactFieldID
    let fieldDigest: LocalContactFieldDigest

    init(_ field: LocalContactFieldValue) {
        fieldID = field.id
        fieldDigest = field.digest
    }
}

/// One-shot authorization metadata only. It contains hashes and local tokens,
/// never the contact identifier or any raw contact field value, and is
/// intentionally not Codable.
struct ContactShareGrant: Identifiable, Equatable, Sendable {
    let id: UUID
    let turnID: UUID
    let contactDigest: LocalContactIdentifierDigest
    let selectedFields: Set<ContactShareFieldBinding>
    let providerFingerprint: LocalContactProviderFingerprint
    let contactStoreGeneration: UInt64
    let expiresAt: Date
}

struct ContactShareGrantReceipt: Equatable, Sendable {
    let grantID: UUID
    let turnID: UUID
    let selectedFields: Set<ContactShareFieldBinding>
    let providerFingerprint: LocalContactProviderFingerprint
    let contactStoreGeneration: UInt64
}

enum ContactShareGrantError: Error, Equatable, LocalizedError, Sendable {
    case invalidLifetime
    case noSelectedFields
    case fieldContactMismatch
    case missingOrConsumed
    case expired
    case turnMismatch
    case contactMismatch
    case selectedFieldsMismatch
    case providerMismatch
    case contactStoreChanged

    var errorDescription: String? {
        switch self {
        case .invalidLifetime:
            "The one-shot Contacts approval lifetime is invalid."
        case .noSelectedFields:
            "Choose at least one exact contact field before creating a share approval."
        case .fieldContactMismatch:
            "The selected fields do not all belong to the reviewed contact."
        case .missingOrConsumed:
            "That one-shot Contacts approval is unavailable or has already been used. Review the fields again."
        case .expired:
            "That one-shot Contacts approval expired. Review the fields again."
        case .turnMismatch:
            "That Contacts approval belongs to a different conversation turn."
        case .contactMismatch:
            "That Contacts approval belongs to a different contact."
        case .selectedFieldsMismatch:
            "The selected contact fields changed after review."
        case .providerMismatch:
            "The AI endpoint or model changed after review."
        case .contactStoreChanged:
            "Contacts changed after review. Search and review the fields again."
        }
    }
}

/// In-memory, fail-closed grant storage. Every consume attempt removes the
/// grant before validation, so mismatch, expiry, cancellation, and double taps
/// require a fresh local review.
actor ContactShareGrantValidator {
    static let defaultLifetime: TimeInterval = 120
    static let maximumLifetime: TimeInterval = 300
    static let maximumSelectedFields = 32

    private var grants: [UUID: ContactShareGrant] = [:]

    func issue(
        turnID: UUID,
        contactIdentifier: String,
        selectedFields: [LocalContactFieldValue],
        providerFingerprint: LocalContactProviderFingerprint,
        contactStoreGeneration: UInt64,
        now: Date = Date(),
        lifetime: TimeInterval = ContactShareGrantValidator.defaultLifetime
    ) throws -> ContactShareGrant {
        guard lifetime > 0, lifetime <= Self.maximumLifetime else {
            throw ContactShareGrantError.invalidLifetime
        }
        let bindings = Set(selectedFields.map(ContactShareFieldBinding.init))
        guard !bindings.isEmpty, bindings.count <= Self.maximumSelectedFields else {
            throw ContactShareGrantError.noSelectedFields
        }
        let contactDigest = LocalContactIdentifierDigest(contactIdentifier: contactIdentifier)
        guard selectedFields.allSatisfy({ $0.contactDigest == contactDigest }) else {
            throw ContactShareGrantError.fieldContactMismatch
        }

        let grant = ContactShareGrant(
            id: UUID(),
            turnID: turnID,
            contactDigest: contactDigest,
            selectedFields: bindings,
            providerFingerprint: providerFingerprint,
            contactStoreGeneration: contactStoreGeneration,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        grants[grant.id] = grant
        return grant
    }

    func consume(
        grantID: UUID,
        turnID: UUID,
        contactIdentifier: String,
        selectedFields: [LocalContactFieldValue],
        providerFingerprint: LocalContactProviderFingerprint,
        contactStoreGeneration: UInt64,
        now: Date = Date()
    ) throws -> ContactShareGrantReceipt {
        guard let grant = grants.removeValue(forKey: grantID) else {
            throw ContactShareGrantError.missingOrConsumed
        }
        guard now < grant.expiresAt else {
            throw ContactShareGrantError.expired
        }
        guard turnID == grant.turnID else {
            throw ContactShareGrantError.turnMismatch
        }
        let contactDigest = LocalContactIdentifierDigest(contactIdentifier: contactIdentifier)
        guard contactDigest == grant.contactDigest,
              selectedFields.allSatisfy({ $0.contactDigest == contactDigest }) else {
            throw ContactShareGrantError.contactMismatch
        }
        let bindings = Set(selectedFields.map(ContactShareFieldBinding.init))
        guard bindings == grant.selectedFields else {
            throw ContactShareGrantError.selectedFieldsMismatch
        }
        guard providerFingerprint == grant.providerFingerprint else {
            throw ContactShareGrantError.providerMismatch
        }
        guard contactStoreGeneration == grant.contactStoreGeneration else {
            throw ContactShareGrantError.contactStoreChanged
        }

        return .init(
            grantID: grant.id,
            turnID: grant.turnID,
            selectedFields: grant.selectedFields,
            providerFingerprint: grant.providerFingerprint,
            contactStoreGeneration: grant.contactStoreGeneration
        )
    }

    func invalidateAll() {
        grants.removeAll(keepingCapacity: false)
    }

    func invalidateAfterContactStoreChange(currentGeneration: UInt64) {
        grants = grants.filter { $0.value.contactStoreGeneration == currentGeneration }
    }

    var pendingGrantCount: Int {
        grants.count
    }
}

private enum LocalContactHash {
    static func digest(parts: [String]) -> String {
        var data = Data()
        for part in parts {
            let bytes = Data(part.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum LocalContactText {
    struct BoundedValue {
        let value: String
        let wasTruncated: Bool
    }

    static func bounded(
        _ rawValue: String,
        maximumLength: Int,
        allowNewlines: Bool
    ) -> BoundedValue {
        let allowedControls: Set<Unicode.Scalar> = allowNewlines ? ["\n", "\r", "\t"] : []
        let scalars = rawValue.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) || allowedControls.contains(scalar)
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            value: String(cleaned.prefix(maximumLength)),
            wasTruncated: cleaned.count > maximumLength
        )
    }

    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    static func matches(_ value: String, query: String) -> Bool {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return false }
        if normalized(value).contains(normalizedQuery) {
            return true
        }
        let queryDigits = query.filter(\.isNumber)
        let valueDigits = value.filter(\.isNumber)
        return queryDigits.count >= 3 && valueDigits.contains(queryDigits)
    }

    static func phoneMatches(_ left: String, _ right: String) -> Bool {
        let leftDigits = left.filter(\.isNumber)
        let rightDigits = right.filter(\.isNumber)
        guard min(leftDigits.count, rightDigits.count) >= 3 else { return false }
        return leftDigits == rightDigits
            || leftDigits.hasSuffix(rightDigits)
            || rightDigits.hasSuffix(leftDigits)
    }
}
