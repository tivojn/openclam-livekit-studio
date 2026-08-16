import SwiftUI

struct ContactAgentCard: View {
    @ObservedObject var session: ContactAgentSession

    let providerID: AIProviderID
    let providerModel: String
    var onSharedReply: @MainActor (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var transientError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            privacyBoundary

            ForEach(session.unavailableFields) { notice in
                unavailableNotice(notice)
            }

            if !session.searchNotices.isEmpty {
                ForEach(Array(session.searchNotices.enumerated()), id: \.offset) { _, notice in
                    Label(notice, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            phaseContent

            if let error = transientError ?? session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Contacts error: \(error)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review contact details")
                    .font(.headline)
                if let query = session.stagedRequest?.query {
                    Text("Local search: \(query)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button("Close", systemImage: "xmark") {
                Task {
                    await session.invalidate()
                    onDismiss()
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityHint("Clears this local Contacts request")
        }
    }

    private var privacyBoundary: some View {
        Label {
            Text(privacyBoundaryText)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var privacyBoundaryText: String {
        switch session.status {
        case .reviewingShare, .sharing:
            "Only the checked values can leave this device after the final Share Once tap."
        case .completed:
            "The one-time approval was consumed. Contact data was cleared from this card."
        default:
            "Search results stay on this device. Every field starts unchecked."
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch session.status {
        case .idle:
            Text("No contact request is staged.")
                .foregroundStyle(.secondary)
        case .staged:
            searchButton
        case .searching:
            progress("Searching Contacts on this device…")
        case .showingCandidates:
            candidateList
        case .loadingContact:
            progress("Loading the fields you requested…")
        case .selectingFields:
            fieldPicker
        case .reviewingShare:
            shareReview
        case .sharing:
            progress("Sharing the reviewed values once…")
        case .completed:
            completion
        }
    }

    private var searchButton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing has been read yet. Search only when you are ready.")
                .font(.subheadline)
            primaryButton("Search Contacts on This Device", systemImage: "magnifyingglass") {
                try await session.searchLocally()
            }
            .disabled(session.stagedRequest?.availableSearchFields.isEmpty != false)
            .accessibilityHint("Reads only the listed contact fields after Contacts permission")
        }
    }

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a contact")
                .font(.subheadline.weight(.semibold))

            if session.candidates.isEmpty {
                ContentUnavailableView(
                    "No local matches",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Try a more specific contact search.")
                )
            } else {
                ForEach(session.candidates) { candidate in
                    Button {
                        perform {
                            try await session.chooseCandidate(id: candidate.id)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.displayName)
                                    .font(.body.weight(.semibold))
                                    .multilineTextAlignment(.leading)
                                ForEach(candidate.matchedFields.prefix(3)) { field in
                                    Text("\(field.kind.contactAgentTitle): \(field.value)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Choose \(candidate.displayName)")
                    .accessibilityHint("Loads only the requested fields and leaves them unchecked")
                }
            }

            Button("Search Again", systemImage: "arrow.clockwise") {
                perform { try await session.searchLocally() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var fieldPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let name = session.selectedContactName {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Text("Turn on only the exact values the selected AI provider may receive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if session.selectedContactFieldsWereTruncated {
                Label(
                    "This contact has more values than the local review limit. Nothing hidden is selected or shared.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            if session.fieldSelections.isEmpty {
                Text("This contact has no values for the requested fields.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.fieldSelections) { selection in
                    Toggle(isOn: Binding(
                        get: { selection.isSelected },
                        set: { newValue in
                            perform {
                                try await session.setFieldSelected(
                                    id: selection.id,
                                    isSelected: newValue
                                )
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(selection.field.kind.contactAgentTitle) · \(selection.field.label)")
                                .font(.subheadline.weight(.semibold))
                            Text(selection.field.value)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(session.isBusy)
                    .accessibilityHint(
                        selection.isSelected
                            ? "This exact value is selected for the one-time review"
                            : "This value stays only on this device"
                    )
                    Divider()
                }
            }

            adaptiveActions {
                Button("Back to Results", systemImage: "chevron.left") {
                    perform { await session.returnToCandidates() }
                }
                .buttonStyle(.bordered)

                primaryButton(
                    "Review \(session.selectedFieldCount) Selected",
                    systemImage: "checkmark.shield"
                ) {
                    try await session.prepareShareReview(
                        providerID: providerID,
                        providerModel: providerModel
                    )
                }
                .disabled(session.selectedFieldCount == 0 || session.isBusy)
            }
        }
    }

    @ViewBuilder
    private var shareReview: some View {
        if let review = session.shareReview {
            VStack(alignment: .leading, spacing: 12) {
                Text("Final one-time share review")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Local contact: \(review.contactDisplayName)")
                    .font(.subheadline.weight(.semibold))
                Text("This local identity is not shared unless a checked Name value appears below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(review.selectedFields) { field in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(field.kind.contactAgentTitle) · \(field.label)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(field.value)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }

                Divider()
                LabeledContent("Endpoint") {
                    Text(review.provider.endpoint.absoluteString)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                LabeledContent("Model", value: review.provider.model)
                Text("Approval expires at \(review.expiresAt.formatted(date: .omitted, time: .standard)). Any attempt—including a failure—uses it up.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                adaptiveActions {
                    Button("Change Selection", systemImage: "pencil") {
                        perform { await session.cancelShareReview() }
                    }
                    .buttonStyle(.bordered)

                    primaryButton("Share These Values Once", systemImage: "arrow.up.circle.fill") {
                        let reply = try await session.shareReviewedFields()
                        onSharedReply(reply)
                    }
                    .accessibilityHint("Consumes this approval before contacting the displayed AI provider")
                }
            }
        } else {
            Text("The one-time review is no longer available.")
                .foregroundStyle(.secondary)
        }
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Shared once", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            if let reply = session.lastReply {
                Text(reply)
                    .textSelection(.enabled)
            }
        }
    }

    private func unavailableNotice(
        _ notice: ContactAgentUnavailableFieldNotice
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(notice.field.contactAgentTitle) unavailable")
                    .font(.subheadline.weight(.semibold))
                Text(notice.reason)
                    .font(.footnote)
            }
        } icon: {
            Image(systemName: "lock.slash")
                .foregroundStyle(.orange)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(label)
                .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
    }

    private func primaryButton(
        _ title: String,
        systemImage: String,
        action: @escaping @MainActor () async throws -> Void
    ) -> some View {
        Button(title, systemImage: systemImage) {
            perform(action)
        }
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)
    }

    @ViewBuilder
    private func adaptiveActions<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10, content: content)
                VStack(alignment: .leading, spacing: 10, content: content)
            }
        }
    }

    private func perform(
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        transientError = nil
        Task { @MainActor in
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                transientError = (error as? LocalizedError)?.errorDescription
                    ?? "The Contacts request could not be completed."
            }
        }
    }
}

private extension LocalContactFieldKind {
    var contactAgentTitle: String {
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
        case .note: "Notes"
        }
    }
}
