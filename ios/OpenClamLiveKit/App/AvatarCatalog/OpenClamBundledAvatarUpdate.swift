import CryptoKit
import Foundation

/// Optional, signed application resources can upgrade an exact earlier model.
/// Packages stay outside source control; an ordinary build has an empty index.
struct OpenClamBundledAvatarUpdate: Codable, Sendable {
    let id: String
    let file: String
    let packageSHA256: String
    let sourceModelSHA256: [String]
    let targetModelSHA256: String

    static var resourceRoot: URL? {
        Bundle.main.url(forResource: "AvatarUpdates", withExtension: "bundle")
    }

    static func load(at root: URL) throws -> [Self] {
        let local = root.appendingPathComponent("updates.local.json")
        let index = FileManager.default.fileExists(atPath: local.path)
            ? local : root.appendingPathComponent("updates.json")
        let data = try Data(contentsOf: index)
        guard data.count < 100_000 else { throw CocoaError(.fileReadCorruptFile) }
        let updates = try JSONDecoder().decode([Self].self, from: data)
        let hashPattern = "^[a-f0-9]{64}$"
        guard updates.count <= 64,
              Set(updates.map(\.id)).count == updates.count,
              updates.allSatisfy({ update in
                  OpenClamAvatarID.isValid(update.id)
                      && update.file == update.id + ".avtr"
                      && !update.sourceModelSHA256.isEmpty
                      && ([update.packageSHA256, update.targetModelSHA256] + update.sourceModelSHA256)
                          .allSatisfy { $0.range(of: hashPattern, options: .regularExpression) != nil }
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return updates
    }

    static func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func installIfMatching(
        modelURL: URL, resourceRoot: URL, store: OpenClamAvatarPackageStore
    ) throws -> OpenClamAvatarDescriptor? {
        let current = try Self.sha256(at: modelURL)
        // Do not recreate deleted avatars, overwrite custom models, or reinstall
        // an already updated package. Explicit appearance preferences live separately.
        guard current != targetModelSHA256, sourceModelSHA256.contains(current) else { return nil }
        let archive = resourceRoot.appendingPathComponent(file)
        guard try Self.sha256(at: archive) == packageSHA256 else {
            throw OpenClamAvatarPackageError.hashMismatch("wardrobe update")
        }
        return try store.installArchive(at: archive, expectedID: id, replacingExisting: true)
    }
}
