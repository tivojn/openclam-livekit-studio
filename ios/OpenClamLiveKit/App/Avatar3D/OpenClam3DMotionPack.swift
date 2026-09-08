import Foundation

/// Optional private motion resources in the signed app. A pack is usable only
/// with its exact, verified GLB; no model geometry is replaced by this layer.
struct OpenClam3DMotionPack {
    struct Index: Codable {
        let modelSHA256: String
        let files: [String: File]
    }
    struct File: Codable {
        let sha256: String
        let byteCount: Int
    }
    let root: URL
    let index: Index
    let library: Data
    let choices: [[String: Any]]

    static func load(modelSHA256: String, root: URL? = Bundle.main.url(forResource: "MotionUpdates", withExtension: "bundle")) throws -> Self? {
        guard let root else { return nil }
        let indexURL = root.appendingPathComponent("index.local.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let data = try Data(contentsOf: indexURL)
        guard data.count <= 100_000 else { throw CocoaError(.fileReadCorruptFile) }
        let index = try JSONDecoder().decode(Index.self, from: data)
        guard index.modelSHA256 == modelSHA256 else { return nil }
        guard index.files.count <= 97,
              index.files.allSatisfy({ name, file in
                  name.range(of: "^[a-z0-9_-]{1,40}\\.json$", options: .regularExpression) != nil
                    && file.byteCount > 0 && file.byteCount <= 32 * 1024 * 1024
                    && file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
              }), index.files.values.reduce(0, { $0 + Int64($1.byteCount) }) <= 512 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let library = try read("library.json", root: root, index: index)
        guard library.count <= 100_000,
              let json = try JSONSerialization.jsonObject(with: library) as? [String: Any],
              json["version"] as? Int == 1, let clips = json["clips"] as? [[String: Any]], clips.count <= 96,
              clips.allSatisfy({ clip in
                  guard let id = clip["id"] as? String, let file = clip["file"] as? String else { return false }
                  return file == id + ".json" && index.files[file] != nil
              }), Set(clips.compactMap { $0["id"] as? String }).count == clips.count
        else { throw CocoaError(.fileReadCorruptFile) }
        return Self(root: root, index: index, library: library, choices: clips)
    }

    func resource(path: String) throws -> Data {
        guard path.hasPrefix("/motions/") else { throw URLError(.fileDoesNotExist) }
        let name = String(path.dropFirst("/motions/".count))
        if name == "library.json" { return library }
        return try Self.read(name, root: root, index: index)
    }

    private static func read(_ name: String, root: URL, index: Index) throws -> Data {
        guard let file = index.files[name] else { throw URLError(.fileDoesNotExist) }
        let url = root.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.fileSize == file.byteCount,
              try OpenClamBundledAvatarUpdate.sha256(at: url) == file.sha256
        else { throw CocoaError(.fileReadCorruptFile) }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
