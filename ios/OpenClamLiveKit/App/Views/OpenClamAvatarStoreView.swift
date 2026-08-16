import SwiftUI

@MainActor
struct OpenClamAvatarStoreView: View {
    @EnvironmentObject private var avatarLibrary: OpenClamAvatarLibrary
    @ObservedObject var configuration: AIConfigurationModel
    let onActivate: (String, String) -> Void

    @StateObject private var store: OpenClamAvatarStore

    init(
        configuration: AIConfigurationModel,
        store: OpenClamAvatarStore? = nil,
        onActivate: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.configuration = configuration
        self.onActivate = onActivate
        _store = StateObject(wrappedValue: store ?? OpenClamAvatarStore())
    }

    var body: some View {
        List {
            statusSection

            if store.entries.isEmpty {
                emptySection
            } else {
                Section {
                    ForEach(store.entries) { entry in
                        avatarCard(entry)
                    }
                } header: {
                    Text("Avatars")
                } footer: {
                    Text("Downloads are checked against the Store’s file size and SHA-256 fingerprint, then validated again as an OpenClam iPhone avatar before installation.")
                }
            }
        }
        .navigationTitle("Avatar Store")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            store.load(library: avatarLibrary)
        }
        .onAppear {
            store.refreshInstalledState(library: avatarLibrary)
        }
        .refreshable {
            store.load(library: avatarLibrary)
        }
        .accessibilityIdentifier("openclam-avatar-store")
    }

    @ViewBuilder
    private var statusSection: some View {
        switch store.catalogStatus {
        case .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking the Avatar Store…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Checking the Avatar Store")
            }
        case .current:
            EmptyView()
        case let .cachedOffline(message):
            Section {
                Label(message, systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("openclam-avatar-store-offline")
            }
        case let .unavailable(message):
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Store unavailable", systemImage: "exclamationmark.triangle")
                        .font(.body.weight(.semibold))
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") {
                        store.load(library: avatarLibrary)
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("openclam-avatar-store-retry-catalog")
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        if case .loading = store.catalogStatus {
            Section {
                avatarSkeleton
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
            }
        } else if case .cachedOffline = store.catalogStatus {
            Section {
                ContentUnavailableView(
                    "No cached avatars",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Connect to the internet once to load the Avatar Store catalog.")
                )
            }
        }
    }

    private var avatarSkeleton: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.16))
                .frame(width: 104, height: 104)
            VStack(alignment: .leading, spacing: 9) {
                Text("Avatar name")
                    .font(.headline)
                Text("By OpenClam")
                Text("Ready to download")
            }
        }
        .padding(.vertical, 8)
    }

    private func avatarCard(_ entry: OpenClamAvatarStoreEntry) -> some View {
        let phase = store.phases[entry.id] ?? .available
        let isInstalled = phase == .installed
        let isBusy = isBusy(phase)

        return VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    thumbnail(entry)
                    avatarDetails(entry, phase: phase)
                }
                VStack(alignment: .leading, spacing: 12) {
                    thumbnail(entry)
                    avatarDetails(entry, phase: phase)
                }
            }

            if let fraction = phase.fractionCompleted,
               let percentage = phase.percentage {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction)
                        .tint(.accentColor)
                    Text("\(percentage)% downloaded")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Downloading \(entry.name)")
                .accessibilityValue("\(percentage) percent")
                .accessibilityIdentifier("openclam-avatar-store-progress-\(entry.id)")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    primaryButton(entry, phase: phase, isInstalled: isInstalled, isBusy: isBusy)
                    installedAction(entry, isInstalled: isInstalled)
                }
                VStack(alignment: .leading, spacing: 10) {
                    primaryButton(entry, phase: phase, isInstalled: isInstalled, isBusy: isBusy)
                    installedAction(entry, isInstalled: isInstalled)
                }
            }

            if isInstalled {
                Button {
                    store.redownload(entry, library: avatarLibrary)
                } label: {
                    Label("Download again", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isBusy)
                .accessibilityIdentifier("openclam-avatar-store-redownload-\(entry.id)")
                .accessibilityHint("Checks and safely replaces the installed copy")
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openclam-avatar-store-card-\(entry.id)")
    }

    private func avatarDetails(
        _ entry: OpenClamAvatarStoreEntry,
        phase: OpenClamAvatarStoreItemPhase
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.name)
                .font(.headline)
                .lineLimit(2)
            Text("By \(entry.author)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("Version \(entry.version) · \(formattedSize(entry.iosLight.bytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
            statusLabel(for: phase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func primaryButton(
        _ entry: OpenClamAvatarStoreEntry,
        phase: OpenClamAvatarStoreItemPhase,
        isInstalled: Bool,
        isBusy: Bool
    ) -> some View {
        Button {
            store.primaryAction(for: entry, library: avatarLibrary)
        } label: {
            Text(store.buttonTitle(for: entry))
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isInstalled || (isBusy && phase.fractionCompleted == nil))
        .accessibilityIdentifier("openclam-avatar-store-primary-\(entry.id)")
        .accessibilityHint(primaryHint(for: phase, entry: entry))
    }

    @ViewBuilder
    private func installedAction(
        _ entry: OpenClamAvatarStoreEntry,
        isInstalled: Bool
    ) -> some View {
        if isInstalled {
            if configuration.activeAvatarID == entry.id {
                Label("In use", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("openclam-avatar-store-active-\(entry.id)")
            } else {
                Button("Use Avatar") {
                    onActivate(entry.id, entry.name)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("openclam-avatar-store-use-\(entry.id)")
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ entry: OpenClamAvatarStoreEntry) -> some View {
        Group {
            if let image = store.thumbnails[entry.id] {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 42, weight: .thin))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name) preview")
    }

    @ViewBuilder
    private func statusLabel(for phase: OpenClamAvatarStoreItemPhase) -> some View {
        switch phase {
        case .available:
            Label("Available", systemImage: "icloud.and.arrow.down")
                .foregroundStyle(.secondary)
        case .readyOffline:
            Label("Ready to install offline", systemImage: "checkmark.icloud")
                .foregroundStyle(.green)
        case .downloading:
            Label("Downloading", systemImage: "arrow.down.circle")
                .foregroundStyle(Color.accentColor)
        case .verifying:
            Label("Checking integrity", systemImage: "checkmark.shield")
                .foregroundStyle(.secondary)
        case .installing:
            Label("Installing", systemImage: "shippingbox")
                .foregroundStyle(.secondary)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .updateAvailable:
            Label("Update available", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func isBusy(_ phase: OpenClamAvatarStoreItemPhase) -> Bool {
        switch phase {
        case .downloading, .verifying, .installing:
            true
        default:
            false
        }
    }

    private func primaryHint(
        for phase: OpenClamAvatarStoreItemPhase,
        entry: OpenClamAvatarStoreEntry
    ) -> String {
        switch phase {
        case .downloading:
            "Cancels the download and keeps any installed avatar unchanged"
        case .readyOffline:
            "Installs the verified cached copy without downloading it again"
        case .updateAvailable:
            "Downloads and safely updates \(entry.name)"
        case .failed:
            "Retries the download"
        default:
            "Downloads and installs \(entry.name)"
        }
    }

    private func formattedSize(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}
