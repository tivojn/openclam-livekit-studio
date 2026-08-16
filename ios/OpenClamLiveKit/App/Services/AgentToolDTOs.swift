import Foundation

enum AgentToolServiceError: LocalizedError, Equatable, Sendable {
    case invalidInput(field: String, reason: String)
    case missingLocationUsageDescription
    case locationPermissionDenied
    case locationPermissionRestricted
    case locationUnavailable
    case locationRequestInProgress
    case locationRequestCancelled
    case locationRequestTimedOut
    case nearbySearchUnavailable
    case contactsPermissionDenied
    case contactsPermissionRestricted
    case contactLookupUnavailable

    var errorDescription: String? {
        switch self {
        case let .invalidInput(field, reason):
            "Invalid \(field): \(reason)"
        case .missingLocationUsageDescription:
            "Location access is not configured in this build."
        case .locationPermissionDenied:
            "Location access is off. Enable While Using the App access in Settings to search nearby."
        case .locationPermissionRestricted:
            "Location access is restricted on this device."
        case .locationUnavailable:
            "Your current location is unavailable. Try again where the device has a clearer location signal."
        case .locationRequestInProgress:
            "Another location request is already in progress."
        case .locationRequestCancelled:
            "The location request was cancelled."
        case .locationRequestTimedOut:
            "The current-location request timed out."
        case .nearbySearchUnavailable:
            "Nearby place search is unavailable right now."
        case .contactsPermissionDenied:
            "Contacts access is off. Enable it in Settings or enter an email address manually."
        case .contactsPermissionRestricted:
            "Contacts access is restricted on this device."
        case .contactLookupUnavailable:
            "Contacts could not be searched right now."
        }
    }
}

enum AgentToolInputValidator {
    static func singleLine(
        _ rawValue: String,
        field: String,
        minimumLength: Int = 1,
        maximumLength: Int
    ) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= minimumLength else {
            throw AgentToolServiceError.invalidInput(field: field, reason: "enter at least \(minimumLength) characters")
        }
        guard value.count <= maximumLength else {
            throw AgentToolServiceError.invalidInput(field: field, reason: "keep it under \(maximumLength) characters")
        }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentToolServiceError.invalidInput(field: field, reason: "control characters are not allowed")
        }
        return value
    }

    static func optionalSingleLine(
        _ rawValue: String?,
        field: String,
        maximumLength: Int
    ) throws -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try singleLine(trimmed, field: field, maximumLength: maximumLength)
    }

    static func multiline(_ rawValue: String, field: String, maximumLength: Int) throws -> String {
        guard rawValue.count <= maximumLength else {
            throw AgentToolServiceError.invalidInput(field: field, reason: "keep it under \(maximumLength) characters")
        }
        let disallowedControls = rawValue.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) && scalar != "\n" && scalar != "\r" && scalar != "\t"
        }
        guard !disallowedControls else {
            throw AgentToolServiceError.invalidInput(field: field, reason: "unsupported control characters are not allowed")
        }
        return rawValue
    }

    static func emailAddress(_ rawValue: String) throws -> String {
        let value = try singleLine(rawValue, field: "email address", maximumLength: 320)
        guard !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else {
            throw AgentToolServiceError.invalidInput(field: "email address", reason: "spaces are not allowed")
        }
        let pieces = value.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else {
            throw AgentToolServiceError.invalidInput(field: "email address", reason: "enter a complete address")
        }
        return value
    }
}

/// Local-only place data. Use `NearbyPlaceSearchOutcome.modelSafeToolResult`
/// before returning search data to a remote model.
struct NearbyPlaceCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let distanceMeters: Double
}

struct NearbyPlaceSearchOutcome: Equatable, Sendable {
    let query: String
    let radiusMeters: Double
    let candidates: [NearbyPlaceCandidate]
    let hasMoreCandidates: Bool

    var modelSafeToolResult: NearbyPlaceToolResult {
        NearbyPlaceToolResult(
            query: query,
            candidates: candidates.enumerated().map { index, candidate in
                NearbyPlaceToolCandidate(
                    rank: index + 1,
                    name: candidate.name,
                    distanceBand: Self.distanceBand(for: candidate.distanceMeters)
                )
            },
            hasMoreCandidates: hasMoreCandidates
        )
    }

    private static func distanceBand(for meters: Double) -> String {
        switch meters {
        case ..<500: "under 500 m"
        case ..<1_000: "500 m to 1 km"
        case ..<2_000: "1 to 2 km"
        case ..<5_000: "2 to 5 km"
        case ..<10_000: "5 to 10 km"
        default: "over 10 km"
        }
    }
}

/// The only nearby-place representation intended for model tool output. It
/// deliberately excludes the user's origin, place coordinates, addresses,
/// and meter-level distances. Exact details stay in the local result cards.
struct NearbyPlaceToolCandidate: Codable, Equatable, Sendable {
    let rank: Int
    let name: String
    let distanceBand: String
}

struct NearbyPlaceToolResult: Codable, Equatable, Sendable {
    let query: String
    let candidates: [NearbyPlaceToolCandidate]
    let hasMoreCandidates: Bool
}

/// Local-only contact data. This type is intentionally not Encodable so an
/// email address cannot be returned to a remote model by accident.
struct ContactEmailCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let label: String
    let emailAddress: String

    init(
        id: String = UUID().uuidString,
        displayName: String,
        label: String,
        emailAddress: String
    ) throws {
        self.id = id
        self.displayName = try AgentToolInputValidator.singleLine(
            displayName,
            field: "contact name",
            maximumLength: 160
        )
        self.label = try AgentToolInputValidator.singleLine(
            label,
            field: "email label",
            maximumLength: 80
        )
        self.emailAddress = try AgentToolInputValidator.emailAddress(emailAddress)
    }

}

struct ContactEmailLookupOutcome: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case exact
        case ambiguous
        case notFound
        case noEmail
    }

    let query: String
    let status: Status
    let candidates: [ContactEmailCandidate]
    let hasMoreCandidates: Bool

    var exactCandidate: ContactEmailCandidate? {
        status == .exact && candidates.count == 1 ? candidates[0] : nil
    }
}

/// Local presentation state. It is intentionally not Encodable because the
/// recipient address belongs at the Mail composer boundary, not in model I/O.
struct MailDraftContent: Identifiable, Equatable, Sendable {
    let id: UUID
    let recipientName: String?
    let recipient: String
    let subject: String
    let body: String

    init(
        id: UUID = UUID(),
        recipientName: String? = nil,
        recipient: String,
        subject: String,
        body: String
    ) throws {
        self.id = id
        self.recipientName = try AgentToolInputValidator.optionalSingleLine(
            recipientName,
            field: "recipient name",
            maximumLength: 160
        )
        self.recipient = try AgentToolInputValidator.emailAddress(recipient)
        self.subject = try AgentToolInputValidator.singleLine(
            subject,
            field: "email subject",
            minimumLength: 0,
            maximumLength: 240
        )
        self.body = try AgentToolInputValidator.multiline(body, field: "email body", maximumLength: 50_000)
    }

    var fallbackPlainText: String {
        let to = recipientName.map { "\($0) <\(recipient)>" } ?? recipient
        return "To: \(to)\nSubject: \(subject)\n\n\(body)"
    }
}
