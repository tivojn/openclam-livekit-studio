import Contacts
import Foundation

@MainActor
final class ContactEmailToolService {
    nonisolated static let candidateLimit = 12
    private static let fetchedContactLimit = 50

    private let store: CNContactStore

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    func lookup(name rawName: String) async throws -> ContactEmailLookupOutcome {
        let name = try AgentToolInputValidator.singleLine(
            rawName,
            field: "contact name",
            minimumLength: 2,
            maximumLength: 120
        )
        try await requestAccessIfNeeded()

        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]

        let fetchResult: (contacts: [CNContact], wasTruncated: Bool)
        do {
            fetchResult = try fetchContacts(matching: name, keysToFetch: keys)
        } catch {
            throw AgentToolServiceError.contactLookupUnavailable
        }

        var candidates: [ContactEmailCandidate] = []
        for contact in fetchResult.contacts {
            let formattedName = CNContactFormatter.string(from: contact, style: .fullName)
            let displayName = formattedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = displayName?.isEmpty == false ? displayName! : (fallbackName.isEmpty ? name : fallbackName)

            for labeledAddress in contact.emailAddresses {
                let label = labeledAddress.label.map(CNLabeledValue<NSString>.localizedString(forLabel:)) ?? "Email"
                guard let candidate = try? ContactEmailCandidate(
                    displayName: resolvedName,
                    label: label,
                    emailAddress: labeledAddress.value as String
                ) else { continue }
                candidates.append(candidate)
            }
        }

        return try Self.resolve(
            query: name,
            candidates: candidates,
            matchedContactCount: fetchResult.contacts.count,
            sourceWasTruncated: fetchResult.wasTruncated
        )
    }

    nonisolated static func resolve(
        query rawQuery: String,
        candidates rawCandidates: [ContactEmailCandidate],
        matchedContactCount: Int,
        sourceWasTruncated: Bool = false
    ) throws -> ContactEmailLookupOutcome {
        let query = try AgentToolInputValidator.singleLine(
            rawQuery,
            field: "contact name",
            minimumLength: 2,
            maximumLength: 120
        )

        var seen = Set<String>()
        let candidates = rawCandidates
            .filter { candidate in
                let key = "\(normalizedName(candidate.displayName))|\(candidate.emailAddress.lowercased())"
                return seen.insert(key).inserted
            }
            .sorted { left, right in
                let leftExact = isExactNameMatch(query: query, displayName: left.displayName)
                let rightExact = isExactNameMatch(query: query, displayName: right.displayName)
                if leftExact != rightExact { return leftExact }
                let nameOrder = left.displayName.localizedCaseInsensitiveCompare(right.displayName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return left.label.localizedCaseInsensitiveCompare(right.label) == .orderedAscending
            }

        guard !candidates.isEmpty else {
            return ContactEmailLookupOutcome(
                query: query,
                status: sourceWasTruncated ? .ambiguous : (matchedContactCount > 0 ? .noEmail : .notFound),
                candidates: [],
                hasMoreCandidates: sourceWasTruncated
            )
        }

        let exactCandidates = candidates.filter {
            isExactNameMatch(query: query, displayName: $0.displayName)
        }
        if exactCandidates.count == 1, !sourceWasTruncated {
            return ContactEmailLookupOutcome(
                query: query,
                status: .exact,
                candidates: [exactCandidates[0]],
                hasMoreCandidates: false
            )
        }

        return ContactEmailLookupOutcome(
            query: query,
            status: .ambiguous,
            candidates: Array(candidates.prefix(candidateLimit)),
            hasMoreCandidates: sourceWasTruncated || candidates.count > candidateLimit
        )
    }

    nonisolated static func isExactNameMatch(query: String, displayName: String) -> Bool {
        normalizedName(query) == normalizedName(displayName)
    }

    private func requestAccessIfNeeded() async throws {
        let initialStatus = CNContactStore.authorizationStatus(for: .contacts)
        if initialStatus == .notDetermined {
            let granted = try await store.requestAccess(for: .contacts)
            guard granted else {
                throw AgentToolServiceError.contactsPermissionDenied
            }
        }

        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return
        case .limited where isLimitedContactsAvailable:
            return
        case .restricted:
            throw AgentToolServiceError.contactsPermissionRestricted
        case .denied, .notDetermined, .limited:
            throw AgentToolServiceError.contactsPermissionDenied
        @unknown default:
            throw AgentToolServiceError.contactsPermissionDenied
        }
    }

    private func fetchContacts(
        matching name: String,
        keysToFetch: [CNKeyDescriptor]
    ) throws -> (contacts: [CNContact], wasTruncated: Bool) {
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        request.predicate = CNContact.predicateForContacts(matchingName: name)
        request.unifyResults = true

        var contacts: [CNContact] = []
        var wasTruncated = false
        try store.enumerateContacts(with: request) { contact, stop in
            guard contacts.count < Self.fetchedContactLimit else {
                wasTruncated = true
                stop.pointee = true
                return
            }
            contacts.append(contact)
        }
        return (contacts, wasTruncated)
    }

    private var isLimitedContactsAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    nonisolated private static func normalizedName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
