import Combine
import Foundation

@MainActor
final class OpenClamAvatarLibrary: ObservableObject {
    static let shared = OpenClamAvatarLibrary()

    @Published private(set) var importedAvatars: [OpenClamAvatarDescriptor]
    @Published private(set) var skippedInvalidInstallCount = 0

    private let packageStore: OpenClamAvatarPackageStore

    init(
        storageRoot: URL = OpenClamAvatarPackageContract.defaultStorageRoot
    ) {
        packageStore = OpenClamAvatarPackageStore(storageRoot: storageRoot)
        importedAvatars = packageStore.loadInstalledDescriptors()
        skippedInvalidInstallCount = Self.invalidDirectoryCount(
            at: storageRoot,
            loadedCount: importedAvatars.count
        )
    }

    var avatars: [OpenClamAvatarDescriptor] {
        OpenClamAvatarCatalog.avatars + importedAvatars
    }

    var identities: [AvatarAgentIdentity] {
        avatars.map { .init(id: $0.id, displayName: $0.displayName) }
    }

    func avatar(id: String) -> OpenClamAvatarDescriptor? {
        OpenClamAvatarCatalog.avatar(id: id)
            ?? importedAvatars.first(where: { $0.id == id })
    }

    func isImported(id: String) -> Bool {
        importedAvatars.contains(where: { $0.id == id })
    }

    func importAvatar(
        from sourceURL: URL,
        expectedID: String? = nil,
        replacingExisting: Bool = false
    ) async throws -> OpenClamAvatarDescriptor {
        let store = packageStore
        let descriptor = try await Task.detached(priority: .userInitiated) {
            try store.installArchive(
                at: sourceURL,
                expectedID: expectedID,
                replacingExisting: replacingExisting
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
        guard isImported(id: id) else {
            throw OpenClamAvatarPackageError.deletionFailed
        }
        let store = packageStore
        try await Task.detached(priority: .userInitiated) {
            try store.deleteInstalledAvatar(id: id)
        }.value
        importedAvatars.removeAll(where: { $0.id == id })
        OpenClamAvatarAssetStore.shared.removeCachedImages()
    }

    func reload() {
        importedAvatars = packageStore.loadInstalledDescriptors()
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
