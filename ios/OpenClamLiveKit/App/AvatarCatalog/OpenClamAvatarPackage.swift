import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

extension UTType {
    static let openClamAvatarPackage = UTType(
        importedAs: "com.openclam.avatar-package",
        conformingTo: .zip
    )
}

struct OpenClamAvatarPackageAsset: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
    let byteCount: Int
    let mediaType: String
    let width: Int
    let height: Int
}

struct OpenClamAvatarPackageManifest: Codable, Equatable, Sendable {
    let format: String
    let version: Int
    let variant: String
    let id: String
    let displayName: String
    let rig: OpenClamAvatarRigGeometry
    let assets: [String: OpenClamAvatarPackageAsset]
}

enum OpenClamAvatarArchiveEntryKind: Equatable, Sendable {
    case file
    case directory
    case symbolicLink
}

struct OpenClamAvatarArchiveEntryMetadata: Equatable, Sendable {
    let path: String
    let kind: OpenClamAvatarArchiveEntryKind
    let compressedSize: UInt64
    let uncompressedSize: UInt64
}

enum OpenClamAvatarPackageError: LocalizedError, Equatable {
    case invalidFileExtension
    case sourceIsNotARegularFile
    case archiveTooLarge
    case invalidArchive
    case invalidArchiveEntry(String)
    case duplicateArchivePath(String)
    case unexpectedArchivePath(String)
    case tooManyFiles
    case packageContentsTooLarge
    case manifestTooLarge
    case invalidManifest
    case privateMetadataNotAllowed
    case unsupportedFormat(String)
    case unsupportedVersion(Int)
    case unsupportedVariant(String)
    case invalidIdentifier
    case catalogIdentityMismatch
    case bundledIdentifierCollision
    case avatarAlreadyInstalled
    case invalidDisplayName
    case invalidRig
    case missingAsset(String)
    case invalidAssetPath(String)
    case invalidAssetSize(String)
    case hashMismatch(String)
    case invalidAssetImage(String)
    case mimeTypeMismatch(String)
    case dimensionMismatch(String)
    case installationFailed
    case deletionFailed

    var errorDescription: String? {
        switch self {
        case .invalidFileExtension:
            "Choose an OpenClam avatar file ending in .avtr."
        case .sourceIsNotARegularFile:
            "That item is not a regular avatar file."
        case .archiveTooLarge:
            "This avatar package is too large for the iPhone light format."
        case .invalidArchive:
            "This file is damaged or is not a valid avatar package."
        case .invalidArchiveEntry:
            "This avatar contains an unsafe file entry."
        case .duplicateArchivePath:
            "This avatar contains duplicate files and cannot be imported safely."
        case .unexpectedArchivePath:
            "This is not an iPhone-light avatar package because it contains extra files."
        case .tooManyFiles:
            "This avatar contains an unexpected number of files."
        case .packageContentsTooLarge:
            "The expanded avatar is too large for the iPhone light format."
        case .manifestTooLarge, .invalidManifest:
            "The avatar manifest is invalid."
        case .privateMetadataNotAllowed:
            "This package contains unsupported private or authoring metadata. Export the iPhone-light version instead."
        case let .unsupportedFormat(format):
            "Avatar format “\(format)” is not supported. Export an OpenClam iPhone-light avatar."
        case let .unsupportedVersion(version):
            "Avatar version \(version) is not supported. Export version 2 for iPhone."
        case let .unsupportedVariant(variant):
            "Avatar variant “\(variant)” is not supported. Export the ios-light variant."
        case .invalidIdentifier:
            "This avatar has an invalid identifier."
        case .catalogIdentityMismatch:
            "This download does not match the avatar selected in the Store."
        case .bundledIdentifierCollision:
            "This avatar uses the name of a built-in avatar and cannot replace it."
        case .avatarAlreadyInstalled:
            "An avatar with this identifier is already installed. Delete it before importing a replacement."
        case .invalidDisplayName:
            "Use an avatar name between 1 and 64 characters."
        case .invalidRig:
            "This avatar’s face rig is not compatible with OpenClam on iPhone."
        case let .missingAsset(role):
            "The avatar is missing its \(role) image."
        case let .invalidAssetPath(role):
            "The \(role) image is stored in an unsupported location."
        case let .invalidAssetSize(role):
            "The \(role) image is too large or has an invalid file size."
        case let .hashMismatch(role):
            "The \(role) image failed its integrity check."
        case let .invalidAssetImage(role):
            "The \(role) image is damaged or cannot be decoded."
        case let .mimeTypeMismatch(role):
            "The \(role) image type does not match the manifest."
        case let .dimensionMismatch(role):
            "The \(role) image dimensions do not match the avatar rig."
        case .installationFailed:
            "OpenClam could not install this avatar. Your existing avatars were left unchanged."
        case .deletionFailed:
            "OpenClam could not delete this avatar. It remains available."
        }
    }
}

enum OpenClamAvatarPackageContract {
    static let canonicalFormat = "openclam-avatar"
    static let version = 2
    static let variant = "ios-light"
    static let manifestPath = "manifest.json"

    static let maximumArchiveByteCount: UInt64 = 32 * 1_024 * 1_024
    static let maximumExpandedByteCount: UInt64 = 64 * 1_024 * 1_024
    static let maximumAssetByteCount: UInt64 = 16 * 1_024 * 1_024
    static let maximumManifestByteCount: UInt64 = 128 * 1_024
    static let maximumImageDimension = 8_192
    static let maximumDecodedPixelCount: UInt64 = 16 * 1_024 * 1_024
    static let expectedFileCount = 19

    struct AssetSpecification: Sendable {
        let key: String
        let role: OpenClamAvatarAssetRole
        let baseFilename: String
        let allowsJPEG: Bool

        var allowedPaths: Set<String> {
            var paths = ["assets/\(baseFilename).png"]
            if allowsJPEG {
                paths.append("assets/\(baseFilename).jpg")
                paths.append("assets/\(baseFilename).jpeg")
            }
            return Set(paths)
        }
    }

    static let assetSpecifications: [AssetSpecification] = {
        var values: [AssetSpecification] = [
            .init(key: "thumbnail", role: .thumbnail, baseFilename: "thumbnail", allowsJPEG: true),
            .init(key: "body", role: .body, baseFilename: "body", allowsJPEG: false),
            .init(key: "head-mask", role: .headMask, baseFilename: "head-mask", allowsJPEG: false),
            .init(key: "eye-left", role: .eyeLeft, baseFilename: "eye-left", allowsJPEG: false),
            .init(key: "eye-right", role: .eyeRight, baseFilename: "eye-right", allowsJPEG: false),
            .init(key: "brow-left", role: .browLeft, baseFilename: "brow-left", allowsJPEG: false),
            .init(key: "brow-right", role: .browRight, baseFilename: "brow-right", allowsJPEG: false),
            .init(key: "gaze-left-atlas", role: .gazeLeftAtlas, baseFilename: "gaze-left-atlas", allowsJPEG: false),
            .init(key: "gaze-right-atlas", role: .gazeRightAtlas, baseFilename: "gaze-right-atlas", allowsJPEG: false),
        ]
        values.append(contentsOf: OpenClamAvatarViseme.allCases.map { viseme in
            .init(
                key: "viseme-\(viseme.rawValue)",
                role: .viseme(viseme),
                baseFilename: "viseme-\(viseme.rawValue)",
                allowsJPEG: true
            )
        })
        return values
    }()

    static let assetSpecificationsByKey = Dictionary(
        uniqueKeysWithValues: assetSpecifications.map { ($0.key, $0) }
    )

    static let allowedArchivePaths: Set<String> = {
        var paths = Set([manifestPath])
        for specification in assetSpecifications {
            paths.formUnion(specification.allowedPaths)
        }
        return paths
    }()

    static var defaultStorageRoot: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("OpenClam", isDirectory: true)
            .appendingPathComponent("Avatars", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
    }

    static func validateArchiveMetadata(
        _ entries: [OpenClamAvatarArchiveEntryMetadata],
        archiveByteCount: UInt64
    ) throws {
        guard archiveByteCount <= maximumArchiveByteCount else {
            throw OpenClamAvatarPackageError.archiveTooLarge
        }
        guard entries.count == expectedFileCount else {
            throw OpenClamAvatarPackageError.tooManyFiles
        }

        var seen = Set<String>()
        var totalCompressed: UInt64 = 0
        var totalExpanded: UInt64 = 0

        for entry in entries {
            guard entry.kind == .file else {
                throw OpenClamAvatarPackageError.invalidArchiveEntry(entry.path)
            }
            guard isSafeArchivePath(entry.path) else {
                throw OpenClamAvatarPackageError.invalidArchiveEntry(entry.path)
            }
            guard allowedArchivePaths.contains(entry.path) else {
                throw OpenClamAvatarPackageError.unexpectedArchivePath(entry.path)
            }
            guard seen.insert(entry.path).inserted else {
                throw OpenClamAvatarPackageError.duplicateArchivePath(entry.path)
            }

            let perFileLimit = entry.path == manifestPath
                ? maximumManifestByteCount
                : maximumAssetByteCount
            guard entry.uncompressedSize > 0,
                  entry.uncompressedSize <= perFileLimit,
                  entry.compressedSize <= maximumAssetByteCount else {
                throw entry.path == manifestPath
                    ? OpenClamAvatarPackageError.manifestTooLarge
                    : OpenClamAvatarPackageError.packageContentsTooLarge
            }

            let compressedResult = totalCompressed.addingReportingOverflow(
                entry.compressedSize
            )
            let expandedResult = totalExpanded.addingReportingOverflow(
                entry.uncompressedSize
            )
            guard !compressedResult.overflow, !expandedResult.overflow else {
                throw OpenClamAvatarPackageError.packageContentsTooLarge
            }
            totalCompressed = compressedResult.partialValue
            totalExpanded = expandedResult.partialValue
        }

        guard totalCompressed <= maximumArchiveByteCount,
              totalExpanded <= maximumExpandedByteCount,
              seen.contains(manifestPath) else {
            throw OpenClamAvatarPackageError.packageContentsTooLarge
        }
    }

    static func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= 128,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains(":"),
              path == path.precomposedStringWithCanonicalMapping else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}

struct OpenClamAvatarPackageStore: Sendable {
    let storageRoot: URL

    init(storageRoot: URL = OpenClamAvatarPackageContract.defaultStorageRoot) {
        self.storageRoot = storageRoot.standardizedFileURL
        recoverInterruptedReplacements()
    }

    func installArchive(
        at sourceURL: URL,
        expectedID: String? = nil,
        replacingExisting: Bool = false
    ) throws -> OpenClamAvatarDescriptor {
        if let expectedID, !OpenClamAvatarID.isValid(expectedID) {
            throw OpenClamAvatarPackageError.invalidIdentifier
        }
        guard sourceURL.pathExtension.caseInsensitiveCompare("avtr") == .orderedSame else {
            throw OpenClamAvatarPackageError.invalidFileExtension
        }

        let didAccessSecurityScopedResource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceValues: URLResourceValues
        do {
            sourceValues = try sourceURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
        } catch {
            throw OpenClamAvatarPackageError.sourceIsNotARegularFile
        }
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true else {
            throw OpenClamAvatarPackageError.sourceIsNotARegularFile
        }
        guard let sourceByteCount = sourceValues.fileSize,
              sourceByteCount > 0 else {
            throw OpenClamAvatarPackageError.sourceIsNotARegularFile
        }
        guard UInt64(sourceByteCount)
                <= OpenClamAvatarPackageContract.maximumArchiveByteCount else {
            throw OpenClamAvatarPackageError.archiveTooLarge
        }

        // Parse only a bounded snapshot in our private temporary directory. A
        // Files provider can otherwise change the security-scoped file between
        // metadata validation and ZIP extraction.
        let snapshot = try makePrivateArchiveSnapshot(from: sourceURL)
        defer { try? FileManager.default.removeItem(at: snapshot.url) }

        let archive: ZIPFoundation.Archive
        do {
            archive = try ZIPFoundation.Archive(url: snapshot.url, accessMode: .read)
        } catch {
            throw OpenClamAvatarPackageError.invalidArchive
        }

        let entries = Array(archive)
        let metadata = entries.map { entry in
            OpenClamAvatarArchiveEntryMetadata(
                path: entry.path,
                kind: entryKind(entry.type),
                compressedSize: entry.compressedSize,
                uncompressedSize: entry.uncompressedSize
            )
        }
        try OpenClamAvatarPackageContract.validateArchiveMetadata(
            metadata,
            archiveByteCount: snapshot.byteCount
        )

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: storageRoot,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        } catch {
            throw OpenClamAvatarPackageError.installationFailed
        }

        let stagingURL = storageRoot.appendingPathComponent(
            ".import-\(UUID().uuidString)",
            isDirectory: true
        )
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        do {
            try fileManager.createDirectory(
                at: stagingURL.appendingPathComponent("assets", isDirectory: true),
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            for entry in entries {
                let destination = stagingURL.appendingPathComponent(
                    entry.path,
                    isDirectory: false
                )
                _ = try archive.extract(entry, to: destination)
            }
        } catch {
            throw OpenClamAvatarPackageError.invalidArchive
        }

        let staged = try validatedDescriptor(in: stagingURL)
        if let expectedID, staged.id != expectedID {
            throw OpenClamAvatarPackageError.catalogIdentityMismatch
        }
        guard !OpenClamAvatarCatalog.avatars.contains(where: { $0.id == staged.id }) else {
            throw OpenClamAvatarPackageError.bundledIdentifierCollision
        }

        let destination = storageRoot.appendingPathComponent(staged.id, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            guard replacingExisting else {
                throw OpenClamAvatarPackageError.avatarAlreadyInstalled
            }
            let replacement = try replaceInstalledAvatar(
                at: destination,
                with: stagingURL,
                expectedID: staged.id
            )
            committed = true
            return replacement
        }

        do {
            try fileManager.moveItem(at: stagingURL, to: destination)
        } catch {
            throw fileManager.fileExists(atPath: destination.path)
                ? OpenClamAvatarPackageError.avatarAlreadyInstalled
                : OpenClamAvatarPackageError.installationFailed
        }
        do {
            let installed = try validatedDescriptor(in: destination)
            committed = true
            return installed
        } catch {
            // The same files were validated in staging. A failure here means the
            // move did not preserve the package; remove only this new destination
            // so a reported failure can never leave a half-installed avatar.
            try? fileManager.removeItem(at: destination)
            throw OpenClamAvatarPackageError.installationFailed
        }
    }

    /// Replaces only an already-valid imported avatar. The candidate is fully
    /// validated in staging before this method, and the prior installation is
    /// retained as a same-volume backup until the moved candidate validates at
    /// its final path. A failed update restores the prior directory.
    private func replaceInstalledAvatar(
        at destination: URL,
        with stagingURL: URL,
        expectedID: String
    ) throws -> OpenClamAvatarDescriptor {
        let fileManager = FileManager.default
        guard let existing = try? validatedDescriptor(in: destination),
              existing.id == expectedID else {
            throw OpenClamAvatarPackageError.installationFailed
        }
        let backup = replacementBackupURL(for: expectedID)
        do {
            try fileManager.moveItem(at: destination, to: backup)
            do {
                try fileManager.moveItem(at: stagingURL, to: destination)
                let installed = try validatedDescriptor(in: destination)
                guard installed.id == expectedID else {
                    throw OpenClamAvatarPackageError.catalogIdentityMismatch
                }
                try? fileManager.removeItem(at: backup)
                return installed
            } catch {
                try? fileManager.removeItem(at: destination)
                do {
                    try fileManager.moveItem(at: backup, to: destination)
                } catch {
                    throw OpenClamAvatarPackageError.installationFailed
                }
                if let packageError = error as? OpenClamAvatarPackageError {
                    throw packageError
                }
                throw OpenClamAvatarPackageError.installationFailed
            }
        } catch let error as OpenClamAvatarPackageError {
            throw error
        } catch {
            throw OpenClamAvatarPackageError.installationFailed
        }
    }

    func loadInstalledDescriptors() -> [OpenClamAvatarDescriptor] {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: storageRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories.compactMap { directory in
            let values = try? directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true,
                  OpenClamAvatarID.isValid(directory.lastPathComponent),
                  let descriptor = try? validatedDescriptor(in: directory),
                  descriptor.id == directory.lastPathComponent,
                  !OpenClamAvatarCatalog.avatars.contains(where: { $0.id == descriptor.id }) else {
                return nil
            }
            return descriptor
        }
        .sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Completes the rollback side of an update transaction after an app or
    /// device termination. Directory moves on the same volume are atomic, so
    /// an interruption can leave either a valid canonical install or the valid
    /// prior install under our hidden backup name, never a partially moved
    /// directory. Backup names encode the validated manifest ID and a UUID so
    /// unrelated hidden directories are never considered for recovery.
    private func recoverInterruptedReplacements() {
        let fileManager = FileManager.default
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: storageRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return
        }

        for backup in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let expectedID = replacementBackupID(for: backup),
                  let values = try? backup.resourceValues(
                      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let prior = try? validatedDescriptor(in: backup),
                  prior.id == expectedID,
                  !OpenClamAvatarCatalog.avatars.contains(where: { $0.id == expectedID }) else {
                continue
            }

            let destination = storageRoot.appendingPathComponent(expectedID, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                // The candidate move completed and only backup cleanup was
                // interrupted. Delete the prior copy only after the canonical
                // package independently passes the full AVTR validation again.
                guard let installed = try? validatedDescriptor(in: destination),
                      installed.id == expectedID else {
                    continue
                }
                try? fileManager.removeItem(at: backup)
            } else {
                // The termination happened between the two directory moves.
                // Restore the prior validated package to its canonical path.
                try? fileManager.moveItem(at: backup, to: destination)
            }
        }
    }

    private func replacementBackupURL(for id: String) -> URL {
        storageRoot.appendingPathComponent(
            ".replace-\(id).\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
    }

    private func replacementBackupID(for url: URL) -> String? {
        let prefix = ".replace-"
        let name = url.lastPathComponent
        guard name.hasPrefix(prefix) else { return nil }
        let components = name.dropFirst(prefix.count).split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2 else { return nil }
        let id = String(components[0])
        guard OpenClamAvatarID.isValid(id),
              UUID(uuidString: String(components[1])) != nil else {
            return nil
        }
        return id
    }

    func deleteInstalledAvatar(id: String) throws {
        guard OpenClamAvatarID.isValid(id),
              !OpenClamAvatarCatalog.avatars.contains(where: { $0.id == id }) else {
            throw OpenClamAvatarPackageError.deletionFailed
        }
        let fileManager = FileManager.default
        let target = storageRoot.appendingPathComponent(id, isDirectory: true)
        guard fileManager.fileExists(atPath: target.path) else {
            throw OpenClamAvatarPackageError.deletionFailed
        }

        let tombstone = storageRoot.appendingPathComponent(
            ".delete-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.moveItem(at: target, to: tombstone)
            do {
                try fileManager.removeItem(at: tombstone)
            } catch {
                try? fileManager.moveItem(at: tombstone, to: target)
                throw OpenClamAvatarPackageError.deletionFailed
            }
        } catch let error as OpenClamAvatarPackageError {
            throw error
        } catch {
            throw OpenClamAvatarPackageError.deletionFailed
        }
    }

    func validatedDescriptor(in directory: URL) throws -> OpenClamAvatarDescriptor {
        let installedAssetPaths = try validateInstalledFileLayout(in: directory)
        let manifestURL = directory.appendingPathComponent(
            OpenClamAvatarPackageContract.manifestPath,
            isDirectory: false
        )
        let manifestData: Data
        do {
            let values = try manifestURL.resourceValues(forKeys: [.fileSizeKey])
            guard UInt64(values.fileSize ?? 0)
                    <= OpenClamAvatarPackageContract.maximumManifestByteCount else {
                throw OpenClamAvatarPackageError.manifestTooLarge
            }
            manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        } catch let error as OpenClamAvatarPackageError {
            throw error
        } catch {
            throw OpenClamAvatarPackageError.invalidManifest
        }

        try validateStrictManifestShape(manifestData)
        let manifest: OpenClamAvatarPackageManifest
        do {
            manifest = try JSONDecoder().decode(
                OpenClamAvatarPackageManifest.self,
                from: manifestData
            )
        } catch {
            throw OpenClamAvatarPackageError.invalidManifest
        }
        try validateManifestContract(manifest)
        guard installedAssetPaths == Set(manifest.assets.values.map(\.path)) else {
            throw OpenClamAvatarPackageError.privateMetadataNotAllowed
        }

        var references: [OpenClamAvatarAssetRole: OpenClamAvatarAssetReference] = [:]
        var includedByteCount = 0
        for specification in OpenClamAvatarPackageContract.assetSpecifications {
            guard let asset = manifest.assets[specification.key] else {
                throw OpenClamAvatarPackageError.missingAsset(specification.key)
            }
            let fileURL = directory.appendingPathComponent(asset.path, isDirectory: false)
            try validateAsset(
                asset,
                roleKey: specification.key,
                role: specification.role,
                rig: manifest.rig,
                fileURL: fileURL
            )
            let sum = includedByteCount.addingReportingOverflow(asset.byteCount)
            guard !sum.overflow else {
                throw OpenClamAvatarPackageError.packageContentsTooLarge
            }
            includedByteCount = sum.partialValue
            references[specification.role] = .installedFile(fileURL)
        }

        guard let avatarID = OpenClamAvatarID(rawValue: manifest.id) else {
            throw OpenClamAvatarPackageError.invalidIdentifier
        }
        return OpenClamAvatarDescriptor(
            avatarID: avatarID,
            displayName: manifest.displayName,
            sourceSlug: manifest.id,
            sourceRelativeRuntimePath: "Application Support/OpenClam/Avatars/v2/\(manifest.id)",
            includedByteCount: includedByteCount,
            geometry: manifest.rig,
            compatibility: .iosLight,
            assets: references
        )
    }

    private func validateInstalledFileLayout(in directory: URL) throws -> Set<String> {
        let fileManager = FileManager.default
        let rootItems: [URL]
        do {
            rootItems = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw OpenClamAvatarPackageError.invalidManifest
        }
        guard Set(rootItems.map(\.lastPathComponent)) == Set(["manifest.json", "assets"]) else {
            throw OpenClamAvatarPackageError.privateMetadataNotAllowed
        }

        let manifestURL = directory.appendingPathComponent("manifest.json")
        let assetsURL = directory.appendingPathComponent("assets", isDirectory: true)
        let manifestValues = try? manifestURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let assetsValues = try? assetsURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard manifestValues?.isRegularFile == true,
              manifestValues?.isSymbolicLink != true,
              assetsValues?.isDirectory == true,
              assetsValues?.isSymbolicLink != true else {
            throw OpenClamAvatarPackageError.invalidManifest
        }

        let assetItems = try fileManager.contentsOfDirectory(
            at: assetsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        guard assetItems.count == OpenClamAvatarPackageContract.assetSpecifications.count else {
            throw OpenClamAvatarPackageError.tooManyFiles
        }
        for item in assetItems {
            let values = try item.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw OpenClamAvatarPackageError.invalidArchiveEntry(item.lastPathComponent)
            }
        }
        return Set(assetItems.map { "assets/\($0.lastPathComponent)" })
    }

    private func validateStrictManifestShape(_ data: Data) throws {
        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OpenClamAvatarPackageError.invalidManifest
        }
        guard let root = rawObject as? [String: Any] else {
            throw OpenClamAvatarPackageError.invalidManifest
        }

        try requireExactKeys(
            root,
            ["format", "version", "variant", "id", "displayName", "rig", "assets"]
        )
        guard let assets = root["assets"] as? [String: Any],
              Set(assets.keys) == Set(OpenClamAvatarPackageContract.assetSpecificationsByKey.keys),
              let rig = root["rig"] as? [String: Any] else {
            throw OpenClamAvatarPackageError.privateMetadataNotAllowed
        }
        for value in assets.values {
            guard let asset = value as? [String: Any] else {
                throw OpenClamAvatarPackageError.invalidManifest
            }
            try requireExactKeys(
                asset,
                ["path", "sha256", "byteCount", "mediaType", "width", "height"]
            )
        }
        try requireExactKeys(
            rig,
            [
                "bodySize", "faceTransform", "faceBoundsInBody",
                "leftEye", "rightEye", "leftBrow", "rightBrow",
                "leftGaze", "rightGaze",
            ]
        )
        try requireExactKeys(try object(rig, "bodySize"), ["width", "height"])
        try requireExactKeys(
            try object(rig, "faceTransform"),
            ["a", "b", "c", "d", "tx", "ty"]
        )
        try requireExactKeys(
            try object(rig, "faceBoundsInBody"),
            ["x", "y", "width", "height"]
        )
        for key in ["leftEye", "rightEye", "leftBrow", "rightBrow", "leftGaze", "rightGaze"] {
            let sprite = try object(rig, key)
            try requireExactKeys(sprite, ["box", "columns", "rows", "storage"])
            try requireExactKeys(
                try object(sprite, "box"),
                ["x", "y", "width", "height"]
            )
        }
    }

    private func validateManifestContract(_ manifest: OpenClamAvatarPackageManifest) throws {
        guard manifest.format == OpenClamAvatarPackageContract.canonicalFormat else {
            throw OpenClamAvatarPackageError.unsupportedFormat(manifest.format)
        }
        guard manifest.version == OpenClamAvatarPackageContract.version else {
            throw OpenClamAvatarPackageError.unsupportedVersion(manifest.version)
        }
        guard manifest.variant == OpenClamAvatarPackageContract.variant else {
            throw OpenClamAvatarPackageError.unsupportedVariant(manifest.variant)
        }
        guard OpenClamAvatarID.isValid(manifest.id) else {
            throw OpenClamAvatarPackageError.invalidIdentifier
        }
        let normalizedName = manifest.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalizedName == manifest.displayName,
              !normalizedName.isEmpty,
              normalizedName.count <= 64,
              !normalizedName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw OpenClamAvatarPackageError.invalidDisplayName
        }
        guard Set(manifest.assets.keys)
                == Set(OpenClamAvatarPackageContract.assetSpecificationsByKey.keys) else {
            throw OpenClamAvatarPackageError.privateMetadataNotAllowed
        }
        try validateRig(manifest.rig)

        var paths = Set<String>()
        var declaredTotal: UInt64 = 0
        for specification in OpenClamAvatarPackageContract.assetSpecifications {
            guard let asset = manifest.assets[specification.key] else {
                throw OpenClamAvatarPackageError.missingAsset(specification.key)
            }
            guard specification.allowedPaths.contains(asset.path),
                  OpenClamAvatarPackageContract.isSafeArchivePath(asset.path),
                  paths.insert(asset.path).inserted else {
                throw OpenClamAvatarPackageError.invalidAssetPath(specification.key)
            }
            guard asset.byteCount > 0,
                  UInt64(asset.byteCount)
                    <= OpenClamAvatarPackageContract.maximumAssetByteCount else {
                throw OpenClamAvatarPackageError.invalidAssetSize(specification.key)
            }
            guard asset.sha256.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
            ) != nil else {
                throw OpenClamAvatarPackageError.hashMismatch(specification.key)
            }
            guard let expectedMediaType = mediaType(forPath: asset.path),
                  asset.mediaType == expectedMediaType else {
                throw OpenClamAvatarPackageError.mimeTypeMismatch(specification.key)
            }
            let addition = declaredTotal.addingReportingOverflow(UInt64(asset.byteCount))
            guard !addition.overflow else {
                throw OpenClamAvatarPackageError.packageContentsTooLarge
            }
            declaredTotal = addition.partialValue
        }
        guard declaredTotal <= OpenClamAvatarPackageContract.maximumExpandedByteCount else {
            throw OpenClamAvatarPackageError.packageContentsTooLarge
        }
    }

    private func validateRig(_ rig: OpenClamAvatarRigGeometry) throws {
        let body = rig.bodySize
        guard validInteger(body.width, range: 64 ... 4_096),
              validInteger(body.height, range: 64 ... 4_096),
              validRect(rig.faceBoundsInBody, containingSize: body),
              validFaceTransform(rig.faceTransform) else {
            throw OpenClamAvatarPackageError.invalidRig
        }

        let expectedSprites: [(OpenClamAvatarSpriteGeometry, Int, Int, OpenClamAvatarSpriteStorage)] = [
            (rig.leftEye, 1, 8, .verticalStrip),
            (rig.rightEye, 1, 8, .verticalStrip),
            (rig.leftBrow, 14, 3, .verticalStrip),
            (rig.rightBrow, 14, 3, .verticalStrip),
            (rig.leftGaze, 25, 11, .gridAtlas),
            (rig.rightGaze, 25, 11, .gridAtlas),
        ]
        for (sprite, columns, rows, storage) in expectedSprites {
            guard sprite.columns == columns,
                  sprite.rows == rows,
                  sprite.storage == storage,
                  validRect(sprite.box, containingSize: .faceSource) else {
                throw OpenClamAvatarPackageError.invalidRig
            }
            let spriteSize = try spritePixelSize(sprite)
            guard validDecodedImageSize(
                width: spriteSize.width,
                height: spriteSize.height
            ) else {
                throw OpenClamAvatarPackageError.invalidRig
            }
        }

        let faceCenter = rig.faceCenterInBody
        let eyeAnchor = rig.eyeAnchorInBody
        guard finitePoint(faceCenter), finitePoint(eyeAnchor),
              CGRect(origin: .zero, size: body.cgSize).contains(faceCenter.cgPoint),
              rig.faceBoundsInBody.cgRect.insetBy(dx: -2, dy: -2)
                .contains(eyeAnchor.cgPoint) else {
            throw OpenClamAvatarPackageError.invalidRig
        }
    }

    private func validateAsset(
        _ asset: OpenClamAvatarPackageAsset,
        roleKey: String,
        role: OpenClamAvatarAssetRole,
        rig: OpenClamAvatarRigGeometry,
        fileURL: URL
    ) throws {
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
        } catch {
            throw OpenClamAvatarPackageError.missingAsset(roleKey)
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw OpenClamAvatarPackageError.missingAsset(roleKey)
        }
        guard values.fileSize == asset.byteCount else {
            throw OpenClamAvatarPackageError.invalidAssetSize(roleKey)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw OpenClamAvatarPackageError.missingAsset(roleKey)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256 else {
            throw OpenClamAvatarPackageError.hashMismatch(roleKey)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let sourceType = CGImageSourceGetType(source) as String?,
              let actualType = UTType(sourceType),
              let declaredType = UTType(mimeType: asset.mediaType) else {
            throw OpenClamAvatarPackageError.invalidAssetImage(roleKey)
        }
        guard actualType == declaredType else {
            throw OpenClamAvatarPackageError.mimeTypeMismatch(roleKey)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw OpenClamAvatarPackageError.invalidAssetImage(roleKey)
        }
        guard validDecodedImageSize(width: width, height: height),
              width == asset.width,
              height == asset.height else {
            throw OpenClamAvatarPackageError.dimensionMismatch(roleKey)
        }
        if role == .thumbnail {
            guard (64 ... 2_048).contains(width),
                  (64 ... 2_048).contains(height),
                  UInt64(width) * UInt64(height) <= 4_194_304 else {
                throw OpenClamAvatarPackageError.dimensionMismatch(roleKey)
            }
        } else {
            let expected = try expectedPixelSize(for: role, rig: rig)
            guard width == expected.width, height == expected.height else {
                throw OpenClamAvatarPackageError.dimensionMismatch(roleKey)
            }
        }
        guard CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) != nil else {
            throw OpenClamAvatarPackageError.invalidAssetImage(roleKey)
        }
    }

    private func expectedPixelSize(
        for role: OpenClamAvatarAssetRole,
        rig: OpenClamAvatarRigGeometry
    ) throws -> (width: Int, height: Int) {
        switch role {
        case .thumbnail:
            throw OpenClamAvatarPackageError.invalidRig
        case .body:
            return (try pixel(rig.bodySize.width), try pixel(rig.bodySize.height))
        case .headMask, .viseme(_):
            return (1_024, 1_024)
        case .eyeLeft:
            return try spritePixelSize(rig.leftEye)
        case .eyeRight:
            return try spritePixelSize(rig.rightEye)
        case .browLeft:
            return try spritePixelSize(rig.leftBrow)
        case .browRight:
            return try spritePixelSize(rig.rightBrow)
        case .gazeLeftAtlas:
            return try spritePixelSize(rig.leftGaze)
        case .gazeRightAtlas:
            return try spritePixelSize(rig.rightGaze)
        }
    }

    private func spritePixelSize(
        _ sprite: OpenClamAvatarSpriteGeometry
    ) throws -> (width: Int, height: Int) {
        let frameWidth = try pixel(sprite.box.width)
        let frameHeight = try pixel(sprite.box.height)
        switch sprite.storage {
        case .verticalStrip:
            return (frameWidth, frameHeight * sprite.frameCount)
        case .gridAtlas:
            return (frameWidth * sprite.columns, frameHeight * sprite.rows)
        }
    }

    private func pixel(_ value: Double) throws -> Int {
        guard value.isFinite,
              value.rounded() == value,
              (1 ... 8_192).contains(value) else {
            throw OpenClamAvatarPackageError.invalidRig
        }
        return Int(value)
    }

    private func validInteger(_ value: Double, range: ClosedRange<Double>) -> Bool {
        value.isFinite && value.rounded() == value && range.contains(value)
    }

    private func validRect(
        _ rect: OpenClamAvatarRect,
        containingSize: OpenClamAvatarSize
    ) -> Bool {
        let values = [rect.x, rect.y, rect.width, rect.height]
        guard values.allSatisfy(\.isFinite),
              rect.x >= 0,
              rect.y >= 0,
              validInteger(rect.width, range: 1 ... 4_096),
              validInteger(rect.height, range: 1 ... 8_192) else {
            return false
        }
        return rect.x + rect.width <= containingSize.width
            && rect.y + rect.height <= containingSize.height
    }

    private func validFaceTransform(_ value: OpenClamAvatarFaceTransform) -> Bool {
        guard [value.a, value.b, value.c, value.d, value.tx, value.ty].allSatisfy({
            $0.isFinite && abs($0) <= 8_192
        }) else {
            return false
        }

        let scaleX = hypot(value.a, value.b)
        let scaleY = hypot(value.c, value.d)
        let maximumScale = max(scaleX, scaleY)
        let dotProduct = value.a * value.c + value.b * value.d
        let determinant = value.a * value.d - value.b * value.c
        return (0.01 ... 2).contains(scaleX)
            && (0.01 ... 2).contains(scaleY)
            && abs(scaleX - scaleY) <= maximumScale * 0.05
            && abs(dotProduct) <= scaleX * scaleY * 0.05
            && determinant > 0
    }

    private func validDecodedImageSize(width: Int, height: Int) -> Bool {
        guard (1 ... OpenClamAvatarPackageContract.maximumImageDimension).contains(width),
              (1 ... OpenClamAvatarPackageContract.maximumImageDimension).contains(height) else {
            return false
        }
        return UInt64(width) * UInt64(height)
            <= OpenClamAvatarPackageContract.maximumDecodedPixelCount
    }

    private func finitePoint(_ value: OpenClamAvatarPoint) -> Bool {
        value.x.isFinite && value.y.isFinite
    }

    private func mediaType(forPath path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        default: nil
        }
    }

    private func requireExactKeys(
        _ object: [String: Any],
        _ expected: Set<String>
    ) throws {
        guard Set(object.keys) == expected else {
            throw OpenClamAvatarPackageError.privateMetadataNotAllowed
        }
    }

    private func object(_ parent: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = parent[key] as? [String: Any] else {
            throw OpenClamAvatarPackageError.invalidManifest
        }
        return value
    }

    private func entryKind(
        _ type: ZIPFoundation.Entry.EntryType
    ) -> OpenClamAvatarArchiveEntryKind {
        switch type {
        case .file: .file
        case .directory: .directory
        case .symlink: .symbolicLink
        }
    }

    private func makePrivateArchiveSnapshot(
        from sourceURL: URL
    ) throws -> (url: URL, byteCount: UInt64) {
        let fileManager = FileManager.default
        let snapshotDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "OpenClamAvatarImports",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: snapshotDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        } catch {
            throw OpenClamAvatarPackageError.invalidArchive
        }

        let snapshotURL = snapshotDirectory.appendingPathComponent(
            "\(UUID().uuidString).avtr",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: snapshotURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        ) else {
            throw OpenClamAvatarPackageError.invalidArchive
        }

        var shouldKeepSnapshot = false
        defer {
            if !shouldKeepSnapshot {
                try? fileManager.removeItem(at: snapshotURL)
            }
        }

        do {
            let input = try FileHandle(forReadingFrom: sourceURL)
            let output = try FileHandle(forWritingTo: snapshotURL)
            defer {
                try? input.close()
                try? output.close()
            }

            var byteCount: UInt64 = 0
            while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                let addition = byteCount.addingReportingOverflow(UInt64(chunk.count))
                guard !addition.overflow,
                      addition.partialValue
                        <= OpenClamAvatarPackageContract.maximumArchiveByteCount else {
                    throw OpenClamAvatarPackageError.archiveTooLarge
                }
                try output.write(contentsOf: chunk)
                byteCount = addition.partialValue
            }
            guard byteCount > 0 else {
                throw OpenClamAvatarPackageError.invalidArchive
            }
            shouldKeepSnapshot = true
            return (snapshotURL, byteCount)
        } catch let error as OpenClamAvatarPackageError {
            throw error
        } catch {
            throw OpenClamAvatarPackageError.invalidArchive
        }
    }
}

private extension OpenClamAvatarRigCompatibility {
    static let iosLight = Self(
        canonicalVisemeCount: OpenClamAvatarViseme.allCases.count,
        eyeStateCount: 8,
        browVerticalStateCount: 14,
        browSqueezeStateCount: 3,
        gazeHorizontalStateCount: 25,
        gazeVerticalStateCount: 11
    )
}

private extension OpenClamAvatarSize {
    static let faceSource = Self(width: 1_024, height: 1_024)
}
