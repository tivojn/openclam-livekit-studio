#if DEBUG
import CryptoKit
import Foundation
import ImageIO

/// A launch-only fixture for the delete-avatar UI audit. It creates no new
/// media: every image is copied at runtime from Ara's already bundled,
/// user-authorized ios-light records. Release builds compile this file out.
@MainActor
enum OpenClamAvatarUITestFixture {
    static let seedArgument = "-OpenClamUITestSeedDeletableAvatar"
    static let cleanupArgument = "-OpenClamUITestCleanDeletableAvatar"
    static let avatarID = "ui-test-deletable-avatar"
    static let displayName = "UI Test Imported Avatar"

    static func prepareIfRequested(
        packageStore: OpenClamAvatarPackageStore,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        let shouldSeed = arguments.contains(seedArgument)
        let shouldClean = arguments.contains(cleanupArgument)
        guard shouldSeed || shouldClean else { return }

        do {
            try cleanExactFixtureArtifacts(at: packageStore.storageRoot)
            if shouldSeed {
                try materializeFixture(packageStore: packageStore)
            }
        } catch {
            preconditionFailure("The deterministic avatar delete UI fixture could not be prepared.")
        }
    }

    private static func materializeFixture(
        packageStore: OpenClamAvatarPackageStore
    ) throws {
        guard let ara = OpenClamAvatarCatalog.avatar(id: OpenClamAvatarID.ara.rawValue),
              let fixtureID = OpenClamAvatarID(rawValue: avatarID) else {
            throw OpenClamAvatarPackageError.installationFailed
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: packageStore.storageRoot,
            withIntermediateDirectories: true
        )
        let staging = packageStore.storageRoot.appendingPathComponent(
            ".ui-test-fixture-\(avatarID).\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let assetsDirectory = staging.appendingPathComponent("assets", isDirectory: true)
        try fileManager.createDirectory(
            at: assetsDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        var assets: [String: OpenClamAvatarPackageAsset] = [:]
        for specification in OpenClamAvatarPackageContract.assetSpecifications {
            guard let source = OpenClamAvatarAssetStore.shared.resourceURL(
                for: ara,
                role: specification.role
            ) else {
                throw OpenClamAvatarPackageError.installationFailed
            }
            let fileExtension = source.pathExtension.lowercased()
            let relativePath = "assets/\(specification.baseFilename).\(fileExtension)"
            guard specification.allowedPaths.contains(relativePath) else {
                throw OpenClamAvatarPackageError.installationFailed
            }

            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(
                    imageSource,
                    0,
                    nil
                  ) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                throw OpenClamAvatarPackageError.installationFailed
            }
            let destination = staging.appendingPathComponent(
                relativePath,
                isDirectory: false
            )
            try data.write(to: destination, options: [.atomic])
            assets[specification.key] = OpenClamAvatarPackageAsset(
                path: relativePath,
                sha256: SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined(),
                byteCount: data.count,
                mediaType: fileExtension == "png" ? "image/png" : "image/jpeg",
                width: width,
                height: height
            )
        }

        let manifest = OpenClamAvatarPackageManifest(
            format: OpenClamAvatarPackageContract.canonicalFormat,
            version: OpenClamAvatarPackageContract.legacyVersion,
            variant: OpenClamAvatarPackageContract.variant,
            id: fixtureID.rawValue,
            displayName: displayName,
            rig: ara.geometry,
            assets: assets,
            motions: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: staging.appendingPathComponent(
                OpenClamAvatarPackageContract.manifestPath,
                isDirectory: false
            ),
            options: [.atomic]
        )

        let validated = try packageStore.validatedDescriptor(in: staging)
        guard validated.id == avatarID,
              validated.displayName == displayName,
              !packageStore.loadInstalledDescriptors().contains(where: {
                $0.id == avatarID
              }) else {
            throw OpenClamAvatarPackageError.installationFailed
        }
        let destination = packageStore.storageRoot.appendingPathComponent(
            avatarID,
            isDirectory: true
        )
        try fileManager.moveItem(at: staging, to: destination)
    }

    private static func cleanExactFixtureArtifacts(at storageRoot: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storageRoot.path) else { return }
        let exactDirectory = storageRoot.appendingPathComponent(
            avatarID,
            isDirectory: true
        )
        try? fileManager.removeItem(at: exactDirectory)

        let prefixes = [
            ".delete-\(avatarID).",
            ".delete-receipt-\(avatarID).",
            ".replace-\(avatarID).",
            ".ui-test-fixture-\(avatarID).",
        ]
        let entries = try fileManager.contentsOfDirectory(
            at: storageRoot,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries where prefixes.contains(where: {
            entry.lastPathComponent.hasPrefix($0)
        }) {
            try? fileManager.removeItem(at: entry)
        }
    }
}
#endif
