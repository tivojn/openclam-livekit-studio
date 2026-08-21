import Combine
import Foundation

enum OpenClamAvatarLibraryMutation: Equatable, Sendable {
    case importing
    case deleting(String)

    var deletingAvatarID: String? {
        guard case let .deleting(id) = self else { return nil }
        return id
    }
}

enum OpenClamAvatarDeletionDecision: Equatable, Sendable {
    case cancel
    case confirm
}

struct OpenClamAvatarDeletionResult: Equatable, Sendable {
    let deletedAvatarID: String
    let fallbackIdentity: AvatarAgentIdentity?
}

@MainActor
final class OpenClamAvatarLibrary: ObservableObject {
    static let shared = OpenClamAvatarLibrary()

    @Published private(set) var importedAvatars: [OpenClamAvatarDescriptor]
    @Published private(set) var skippedInvalidInstallCount = 0
    @Published private(set) var mutation: OpenClamAvatarLibraryMutation?
    @Published private(set) var pendingCommittedDeletionIDs: Set<String>

    private let packageStore: OpenClamAvatarPackageStore

    init(
        storageRoot: URL = OpenClamAvatarPackageContract.defaultStorageRoot,
        deletionMoveItem: @escaping @Sendable (URL, URL) throws -> Void = {
            try FileManager.default.moveItem(at: $0, to: $1)
        },
        deletionRemoveItem: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) {
        packageStore = OpenClamAvatarPackageStore(
            storageRoot: storageRoot,
            deletionMoveItem: deletionMoveItem,
            deletionRemoveItem: deletionRemoveItem
        )
#if DEBUG
        OpenClamAvatarUITestFixture.prepareIfRequested(packageStore: packageStore)
#endif
        importedAvatars = packageStore.loadInstalledDescriptors()
        mutation = nil
        pendingCommittedDeletionIDs = packageStore.committedDeletionIDs()
        skippedInvalidInstallCount = Self.invalidDirectoryCount(
            at: storageRoot,
            loadedCount: importedAvatars.count
        )
    }

    var avatars: [OpenClamAvatarDescriptor] {
        let bundledIDs = Set(OpenClamAvatarCatalog.avatars.map(\.id))
        let downloadedByID = Dictionary(
            uniqueKeysWithValues: importedAvatars
                .filter { bundledIDs.contains($0.id) }
                .map { ($0.id, $0) }
        )
        let bundledWithDownloadedUpdates = OpenClamAvatarCatalog.avatars.map {
            downloadedByID[$0.id] ?? $0
        }
        let additionalImports = importedAvatars.filter {
            !bundledIDs.contains($0.id)
        }
        return bundledWithDownloadedUpdates + additionalImports
    }

    var identities: [AvatarAgentIdentity] {
        avatars.map { .init(id: $0.id, displayName: $0.displayName) }
    }

    func avatar(id: String) -> OpenClamAvatarDescriptor? {
        importedAvatars.first(where: { $0.id == id })
            ?? OpenClamAvatarCatalog.avatar(id: id)
    }

    func isImported(id: String) -> Bool {
        importedAvatars.contains(where: { $0.id == id })
    }

    func isProtected(id: String) -> Bool {
        id == AvatarAgentIdentity.defaultID
            || OpenClamAvatarCatalog.avatar(id: id) != nil
    }

    var isMutating: Bool { mutation != nil }

    var deletingAvatarID: String? { mutation?.deletingAvatarID }

    func importAvatar(
        from sourceURL: URL,
        expectedID: String? = nil,
        replacingExisting: Bool = false
    ) async throws -> OpenClamAvatarDescriptor {
        try await installAvatar(
            from: sourceURL,
            expectedID: expectedID,
            replacingExisting: replacingExisting,
            allowsBundledStoreUpdate: false
        )
    }

    /// Store downloads reach this boundary only after the catalog URL, byte
    /// count, SHA-256, and AVTR identity have all been pinned and checked.
    /// Direct Files imports intentionally use `importAvatar` and remain unable
    /// to replace a bundled identity.
    func installStoreAvatar(
        from sourceURL: URL,
        expectedID: String,
        replacingExisting: Bool = false
    ) async throws -> OpenClamAvatarDescriptor {
        try await installAvatar(
            from: sourceURL,
            expectedID: expectedID,
            replacingExisting: replacingExisting,
            allowsBundledStoreUpdate: true
        )
    }

    private func installAvatar(
        from sourceURL: URL,
        expectedID: String?,
        replacingExisting: Bool,
        allowsBundledStoreUpdate: Bool
    ) async throws -> OpenClamAvatarDescriptor {
        guard mutation == nil else {
            throw OpenClamAvatarPackageError.avatarOperationInProgress
        }
        mutation = .importing
        defer { mutation = nil }

        let store = packageStore
        let descriptor = try await Task.detached(priority: .userInitiated) {
            try store.installArchive(
                at: sourceURL,
                expectedID: expectedID,
                replacingExisting: replacingExisting,
                allowsBundledStoreUpdate: allowsBundledStoreUpdate
            )
        }.value
        importedAvatars.removeAll(where: { $0.id == descriptor.id })
        importedAvatars.append(descriptor)
        importedAvatars.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        OpenClamAvatarAssetStore.shared.removeCachedImages()
        return descriptor
    }

    func deleteImportedAvatar(id: String) async throws {
        guard !isProtected(id: id) else {
            throw OpenClamAvatarPackageError.protectedAvatar
        }
        guard isImported(id: id) else {
            throw OpenClamAvatarPackageError.deletionFailed
        }
        guard mutation == nil else {
            throw OpenClamAvatarPackageError.avatarOperationInProgress
        }
        mutation = .deleting(id)
        defer { mutation = nil }

        let store = packageStore
        try await Task.detached(priority: .userInitiated) {
            try store.deleteInstalledAvatar(id: id)
        }.value
        importedAvatars.removeAll(where: { $0.id == id })
        pendingCommittedDeletionIDs.insert(id)
        OpenClamAvatarAssetStore.shared.removeCachedImages()
    }

    /// Consumes durable receipts left when the process ended after the package
    /// rename but before profile/thread cleanup. UserDefaults writes performed
    /// by the configuration model are synchronous; acknowledge only afterward.
    func reconcileCommittedDeletions(
        configuration: AIConfigurationModel
    ) {
        let identityMigrations = packageStore.quarantineOwnedLegacyDuplicates()
        if !identityMigrations.isEmpty {
            importedAvatars = packageStore.loadInstalledDescriptors()
            skippedInvalidInstallCount = Self.invalidDirectoryCount(
                at: packageStore.storageRoot,
                loadedCount: importedAvatars.count
            )
            for migration in identityMigrations {
                configuration.migrateAvatarIdentity(
                    from: migration.sourceID,
                    to: AvatarAgentIdentity(
                        id: migration.targetID,
                        displayName: migration.targetDisplayName
                    )
                )
            }
            OpenClamAvatarAssetStore.shared.removeCachedImages()
        }

        for id in pendingCommittedDeletionIDs.sorted() {
            configuration.removeImportedAvatarProfile(
                id: id,
                availableIdentities: identities
            )
            acknowledgeCommittedDeletion(id: id)
        }
    }

    func acknowledgeCommittedDeletion(id: String) {
        guard pendingCommittedDeletionIDs.contains(id) else { return }
        packageStore.acknowledgeCommittedDeletion(id: id)
        pendingCommittedDeletionIDs.remove(id)
    }

    func reload() {
        guard mutation == nil else { return }
        importedAvatars = packageStore.loadInstalledDescriptors()
        pendingCommittedDeletionIDs = packageStore.committedDeletionIDs()
        skippedInvalidInstallCount = Self.invalidDirectoryCount(
            at: packageStore.storageRoot,
            loadedCount: importedAvatars.count
        )
        OpenClamAvatarAssetStore.shared.removeCachedImages()
    }

    private static func invalidDirectoryCount(at root: URL, loadedCount: Int) -> Int {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        let visibleDirectoryCount = directories.reduce(into: 0) { count, url in
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                count += 1
            }
        }
        return max(0, visibleDirectoryCount - loadedCount)
    }
}

@MainActor
enum OpenClamAvatarDeletionCoordinator {
    /// The confirmation decision is part of this testable boundary so Cancel
    /// is guaranteed to be a no-op. A confirmed deletion updates the package
    /// library first; profile and thread references are reconciled immediately
    /// afterward on the same main-actor turn.
    static func perform(
        decision: OpenClamAvatarDeletionDecision,
        avatar: OpenClamAvatarDescriptor,
        library: OpenClamAvatarLibrary,
        configuration: AIConfigurationModel
    ) async throws -> OpenClamAvatarDeletionResult? {
        guard decision == .confirm else { return nil }
        guard !library.isProtected(id: avatar.id) else {
            throw OpenClamAvatarPackageError.protectedAvatar
        }

        try await library.deleteImportedAvatar(id: avatar.id)
        let fallback = configuration.removeImportedAvatarProfile(
            id: avatar.id,
            availableIdentities: library.identities
        )
        library.acknowledgeCommittedDeletion(id: avatar.id)
        return .init(
            deletedAvatarID: avatar.id,
            fallbackIdentity: fallback
        )
    }
}
