import Foundation
import UIKit

@MainActor
final class OpenClamAvatarAssetStore {
    static let shared = OpenClamAvatarAssetStore()

    private let mainBundle: Bundle
    private let cache = NSCache<NSString, UIImage>()
    private lazy var catalogBundle: Bundle? = Self.findCatalogBundle(in: mainBundle)

    init(mainBundle: Bundle = .main) {
        self.mainBundle = mainBundle
        cache.countLimit = 28
    }

    func image(
        for avatar: OpenClamAvatarDescriptor,
        role: OpenClamAvatarAssetRole
    ) -> UIImage? {
        guard let reference = avatar.asset(role) else { return nil }
        return image(reference)
    }

    func image(_ reference: OpenClamAvatarAssetReference) -> UIImage? {
        let key = cacheKey(reference) as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let loaded: UIImage?
        switch reference {
        case let .assetCatalog(name):
            loaded = UIImage(named: name, in: mainBundle, compatibleWith: nil)
        case let .catalogBundle(directory, filename):
            guard let url = resourceURL(directory: directory, filename: filename) else {
                return nil
            }
            loaded = UIImage(contentsOfFile: url.path)
        case let .installedFile(url):
            loaded = UIImage(contentsOfFile: url.path)
        }

        if let loaded {
            cache.setObject(loaded, forKey: key)
        }
        return loaded
    }

    func resourceURL(
        for avatar: OpenClamAvatarDescriptor,
        role: OpenClamAvatarAssetRole
    ) -> URL? {
        guard let reference = avatar.asset(role) else { return nil }
        switch reference {
        case let .catalogBundle(directory, filename):
            return resourceURL(directory: directory, filename: filename)
        case let .installedFile(url):
            return url
        case .assetCatalog:
            return nil
        }
    }

    func resourceURL(for motion: OpenClamAvatarMotionAsset) -> URL? {
        switch motion.reference {
        case let .catalogBundle(directory, filename):
            return resourceURL(directory: directory, filename: filename)
        case let .installedFile(url):
            return url
        }
    }

    func removeCachedImages() {
        cache.removeAllObjects()
    }

    static func findCatalogBundle(in mainBundle: Bundle) -> Bundle? {
        if let url = mainBundle.url(
            forResource: "AvatarCatalogAssets",
            withExtension: "bundle"
        ), let bundle = Bundle(url: url) {
            return bundle
        }

        // This fallback supports a folder reference copied without the `.bundle`
        // wrapper being registered as a nested Bundle by older Xcode projects.
        if let url = mainBundle.resourceURL?
            .appendingPathComponent("AvatarCatalogAssets.bundle", isDirectory: true),
           FileManager.default.fileExists(atPath: url.path),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return nil
    }

    private func resourceURL(directory: String, filename: String) -> URL? {
        guard let catalogBundle else { return nil }
        let fileURL = catalogBundle.bundleURL
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    private func cacheKey(_ reference: OpenClamAvatarAssetReference) -> String {
        switch reference {
        case let .assetCatalog(name):
            "asset:\(name)"
        case let .catalogBundle(directory, filename):
            "bundle:\(directory)/\(filename)"
        case let .installedFile(url):
            "installed:\(url.standardizedFileURL.path)"
        }
    }
}
