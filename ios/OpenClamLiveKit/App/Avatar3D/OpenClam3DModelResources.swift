import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// A read-only view of the installed GLB. WebKit receives individual buffers
/// and screen-sized images instead of retaining several copies of the whole
/// model plus every full-resolution decoded texture. Geometry, materials,
/// rig, poses, and the installed file are unchanged.
final class OpenClam3DModelResources: @unchecked Sendable {
    struct Span: Sendable {
        let offset: UInt64
        let length: Int
    }

    let document: Data
    let textureLimit: Int
    let decodedTextureBytes: Int
    let originalTextureBytes: Int
    let catalogue: [String: Any]
    private let handle: FileHandle
    private let lock = NSLock()
    private let views: [Span]
    private let images: [Span]
    let cacheDirectory: URL?

    init(url: URL, maximumTextureSize: Int = 2048, textureBudget: Int = 256 * 1024 * 1024, cacheRoot: URL? = nil) throws {
        let file = try FileHandle(forReadingFrom: url)
        do {
            let length = try file.seekToEnd()
            try file.seek(toOffset: 0)
            guard let header = try file.read(upToCount: 20), header.count == 20 else {
                throw OpenClam3DModelError.notGLB
            }
            func word(_ data: Data, _ offset: Int) -> UInt32 {
                data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
            }
            guard word(header, 0) == OpenClam3DGLBReader.magic, word(header, 4) == 2,
                  word(header, 8) == length, word(header, 16) == OpenClam3DGLBReader.jsonChunk else {
                throw OpenClam3DModelError.notGLB
            }
            let jsonLength = Int(word(header, 12))
            guard jsonLength > 0, jsonLength <= 16 * 1024 * 1024,
                  let json = try file.read(upToCount: jsonLength), json.count == jsonLength,
                  var model = try JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let binHeader = try file.read(upToCount: 8), binHeader.count == 8,
                  word(binHeader, 4) == 0x004E4942 else { throw OpenClam3DModelError.invalidJSON }
            let binStart = UInt64(28 + jsonLength), binLength = UInt64(word(binHeader, 0))
            guard binStart + binLength <= length,
                  let buffers = model["buffers"] as? [[String: Any]], buffers.count == 1,
                  buffers[0]["uri"] == nil,
                  let bufferLength = buffers[0]["byteLength"] as? Int,
                  bufferLength >= 0, bufferLength <= binLength,
                  var bufferViews = model["bufferViews"] as? [[String: Any]] else {
                throw OpenClam3DModelError.externalResources
            }
            var spans: [Span] = []
            for (index, view) in bufferViews.enumerated() {
                guard (view["buffer"] as? Int) == 0,
                      let count = view["byteLength"] as? Int, count > 0,
                      let offset = (view["byteOffset"] ?? 0) as? Int,
                      offset >= 0, count <= bufferLength, offset <= bufferLength - count else {
                    throw OpenClam3DModelError.invalidJSON
                }
                spans.append(Span(offset: binStart + UInt64(offset), length: count))
                bufferViews[index]["buffer"] = index
                bufferViews[index]["byteOffset"] = 0
            }
            var sourceImages = model["images"] as? [[String: Any]] ?? []
            var imageSpans: [Span] = [], dimensions: [(Int, Int)] = []
            for (index, image) in sourceImages.enumerated() {
                guard let view = image["bufferView"] as? Int, spans.indices.contains(view),
                      image["uri"] == nil else { throw OpenClam3DModelError.externalResources }
                let span = spans[view]
                imageSpans.append(span)
                let size: (Int, Int) = try autoreleasepool {
                    try file.seek(toOffset: span.offset)
                    guard let bytes = try file.read(upToCount: span.length), bytes.count == span.length,
                          let source = CGImageSourceCreateWithData(bytes as CFData,
                              [kCGImageSourceShouldCache: false] as CFDictionary),
                          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let w = props[kCGImagePropertyPixelWidth] as? Int,
                          let h = props[kCGImagePropertyPixelHeight] as? Int,
                          w > 0, h > 0, w <= 32768, h <= 32768 else {
                        throw OpenClam3DModelError.invalidJSON
                    }
                    return (w, h)
                }
                dimensions.append(size)
                sourceImages[index]["bufferView"] = nil
                sourceImages[index]["mimeType"] = "image/png"
                sourceImages[index]["uri"] = "images/\(index).png"
            }
            let cap = Self.textureSize(for: dimensions, maximum: maximumTextureSize, budget: textureBudget)
            textureLimit = cap
            originalTextureBytes = Self.textureBytes(dimensions, limit: 32768)
            decodedTextureBytes = Self.textureBytes(dimensions, limit: cap)
            // ImageIO serves PNG, including original alpha. A WebP extension
            // is no longer necessary for this transport representation.
            var textures = model["textures"] as? [[String: Any]] ?? []
            for index in textures.indices {
                var extensions = textures[index]["extensions"] as? [String: Any] ?? [:]
                if let webp = extensions.removeValue(forKey: "EXT_texture_webp") as? [String: Any] {
                    textures[index]["source"] = webp["source"]
                }
                textures[index]["extensions"] = extensions.isEmpty ? nil : extensions
            }
            for key in ["extensionsUsed", "extensionsRequired"] {
                if let extensions = model[key] as? [String] {
                    model[key] = extensions.filter { $0 != "EXT_texture_webp" }
                }
            }
            model["textures"] = textures
            model["images"] = sourceImages
            model["bufferViews"] = bufferViews
            model["buffers"] = spans.enumerated().map { ["byteLength": $0.element.length, "uri": "buffers/\($0.offset).bin"] as [String: Any] }
            document = try JSONSerialization.data(withJSONObject: model)
            let library = (model["extras"] as? [String: Any])?["openclamAvatar"] as? [String: Any] ?? [:]
            catalogue = ["poses": Self.choices(library["poses"]), "outfits": Self.choices(library["outfits"]),
                         "props": Self.choices(library["props"])]
            views = spans
            images = imageSpans
            if let cacheRoot {
                try file.seek(toOffset: 0)
                var hash = SHA256()
                while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                let folder = cacheRoot.appendingPathComponent("\(digest)-\(cap)-v1", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
                cacheDirectory = folder
                Self.trimCache(at: cacheRoot, keeping: folder)
            } else { cacheDirectory = nil }
            handle = file
        } catch {
            try? file.close()
            throw error
        }
    }

    deinit { try? handle.close() }

    private static func trimCache(at root: URL, keeping current: URL) {
        // Retain two prior decoded variants; this cache never owns the model.
        let files = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let owned = files.filter {
            $0 != current && $0.lastPathComponent.range(of: "^[a-f0-9]{64}-[0-9]+-v1$", options: .regularExpression) != nil
        }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for stale in owned.dropFirst(2) { try? FileManager.default.removeItem(at: stale) }
    }

    private static func choices(_ value: Any?) -> [[String: String]] {
        ((value as? [[String: Any]]) ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            var choice = ["id": id, "label": String((item["label"] as? String ?? id).prefix(80))]
            for key in ["group", "pose"] { choice[key] = item[key] as? String }
            return choice
        }
    }

    static func textureBytes(_ sizes: [(Int, Int)], limit: Int) -> Int {
        sizes.reduce(0) { total, size in
            let factor = min(1, Double(limit) / Double(max(size.0, size.1)))
            return total + max(1, Int(ceil(Double(size.0) * factor)))
                * max(1, Int(ceil(Double(size.1) * factor))) * 4
        }
    }

    static func textureSize(for sizes: [(Int, Int)], maximum: Int, budget: Int) -> Int {
        var limit = max(256, min(4096, maximum))
        while limit > 256 && textureBytes(sizes, limit: limit) > budget { limit /= 2 }
        return limit
    }

    private func read(_ span: Span) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: span.offset)
        guard let data = try handle.read(upToCount: span.length), data.count == span.length else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    func buffer(at index: Int) throws -> Data {
        guard views.indices.contains(index) else { throw URLError(.fileDoesNotExist) }
        return try read(views[index])
    }

    func image(at index: Int) throws -> Data {
        guard images.indices.contains(index) else { throw URLError(.fileDoesNotExist) }
        return try autoreleasepool {
            let cached = cacheDirectory?.appendingPathComponent("\(index).png")
            if let cached, let size = try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 0, size < 32 * 1024 * 1024,
               let bytes = try? Data(contentsOf: cached),
               let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = properties[kCGImagePropertyPixelWidth] as? Int,
               let h = properties[kCGImagePropertyPixelHeight] as? Int,
               w > 0, h > 0, max(w, h) <= textureLimit { return bytes }
            let data = try read(images[index])
            guard let source = CGImageSourceCreateWithData(data as CFData,
                      [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: textureLimit,
                    kCGImageSourceShouldCacheImmediately: true,
                    // UV orientation is authored in the model, not EXIF.
                    kCGImageSourceCreateThumbnailWithTransform: false,
                  ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(destination, thumbnail, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            let bytes = output as Data
            if let cached { try? bytes.write(to: cached, options: .atomic) }
            return bytes
        }
    }
}
