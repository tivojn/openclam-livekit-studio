import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps only bounded, downsampled bytes in memory. Source files are decoded off the main
/// actor, so a generated 32 MiB image never enters a SwiftUI body or a full-size UIImage.
actor AgentConnectorArtifactThumbnailCache {
    static let shared = AgentConnectorArtifactThumbnailCache()

    private let cache = NSCache<NSString, NSData>()

    init() {
        cache.countLimit = 48
        cache.totalCostLimit = 12 * 1_024 * 1_024
    }

    func thumbnailData(
        for sourceURL: URL,
        cacheKey: String,
        maximumPixelSize: Int = 320
    ) async -> Data? {
        let boundedPixelSize = min(max(maximumPixelSize, 96), 512)
        let key = "\(cacheKey):\(boundedPixelSize)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached as Data
        }
        let generated = await Task.detached(priority: .utility) {
            Self.makeThumbnailData(
                sourceURL: sourceURL,
                maximumPixelSize: boundedPixelSize
            )
        }.value
        guard let generated, generated.count <= 2 * 1_024 * 1_024 else {
            return nil
        }
        cache.setObject(generated as NSData, forKey: key, cost: generated.count)
        return generated
    }

    private nonisolated static func makeThumbnailData(
        sourceURL: URL,
        maximumPixelSize: Int
    ) -> Data? {
        autoreleasepool {
            let sourceOptions: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
            ]
            guard let source = CGImageSourceCreateWithURL(
                sourceURL as CFURL,
                sourceOptions as CFDictionary
            ) else { return nil }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { return nil }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }
    }
}
