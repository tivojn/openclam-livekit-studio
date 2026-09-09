import Foundation
import ImageIO
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
import ZIPFoundation

extension UTType {
    static let openClamAppearancePack = UTType(exportedAs: "com.openclam.appearance-pack", conformingTo: .zip)
}

struct OpenClamAppearancePack: Codable, Sendable {
    struct Asset: Codable, Sendable { let bytes: Int; let sha256: String }
    struct Item: Codable, Sendable {
        let id: String; let label: String; let kind: String
        var file: String?; var nodes: [String]?; var hideNodes: [String]?
        var material: String?; var slot: String?; var region: String?; var source: String?
    }
    struct Environment: Codable, Sendable { let file: String; let width: Int; let height: Int; var rotation: Double? }
    let format: String; let version: Int; let id: String; let label: String; let modelSHA256: String
    let files: [String: Asset]; let items: [Item]; var environment: Environment?; var directory: String?
    static let maximumBytes = 384 * 1024 * 1024
    static let maximumFileBytes = 32 * 1024 * 1024
    static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
    static func filename(_ value: String) -> Bool { matches(value, "^[a-z0-9][a-z0-9._-]{0,79}$") }
    static func identifier(_ value: String) -> Bool { matches(value, "^[a-z0-9][a-z0-9-]{0,47}$") }
    static func sha(_ value: String) -> Bool { matches(value, "^[a-f0-9]{64}$") }
    func validate() throws {
        guard format == "openclam-appearance", version == 1, Self.identifier(id), Self.sha(modelSHA256),
              (1...80).contains(label.count), (1...256).contains(files.count), items.count <= 256,
              Set(items.map(\.id)).count == items.count else { throw Failure.invalid }
        var total: Int64 = 0
        for (name, asset) in files {
            guard Self.filename(name), name != "appearance.json", ["png", "jpg", "json", "bin"].contains(URL(fileURLWithPath: name).pathExtension),
                  asset.bytes > 0, asset.bytes <= Self.maximumFileBytes, Self.sha(asset.sha256) else { throw Failure.invalid }
            total += Int64(asset.bytes)
        }
        guard total <= Self.maximumBytes else { throw Failure.tooLarge }
        for item in items {
            guard Self.identifier(item.id), (1...80).contains(item.label.count), ["clothes", "hair", "texture", "expression"].contains(item.kind),
                  item.file == nil || files[item.file!] != nil else { throw Failure.invalid }
            if let slot = item.slot, !Self.identifier(slot) { throw Failure.invalid }
            if let region = item.region, !["mouth", "eyes", "brows"].contains(region) { throw Failure.invalid }
            if ["texture", "expression"].contains(item.kind), item.file == nil { throw Failure.invalid }
            if item.kind == "texture", item.material == nil || !["png", "jpg"].contains(URL(fileURLWithPath: item.file!).pathExtension) { throw Failure.invalid }
            if item.kind == "expression", item.file?.hasSuffix(".json") != true { throw Failure.invalid }
            for names in [item.nodes, item.hideNodes].compactMap({ $0 }) {
                guard names.count <= 64, names.allSatisfy({ (1...160).contains($0.count) }) else { throw Failure.invalid }
            }
        }
        if let e = environment {
            guard (1...1024).contains(e.width), (1...1024).contains(e.height), files[e.file]?.bytes == e.width * e.height * 8,
                  e.rotation?.isFinite != false else { throw Failure.invalid }
        }
    }
    enum Failure: LocalizedError {
        case invalid, tooLarge, wrongModel, integrity, tooMany
        var errorDescription: String? {
            switch self {
            case .invalid: "Choose a valid OpenClam appearance pack (.oclook)."
            case .tooLarge: "This appearance pack exceeds the size limit."
            case .wrongModel: "This pack belongs to a different model. Import its matching avatar package first."
            case .integrity: "An appearance asset failed verification. Your installed avatar is unchanged."
            case .tooMany: "Remove an appearance pack before adding another."
            }
        }
    }
}

struct OpenClamAppearanceIndex: Codable, Sendable {
    private static let mutationLock = NSLock()
    var version = 1
    var packs: [OpenClamAppearancePack] = []
    static func root(for hash: String) throws -> URL {
        guard OpenClamAppearancePack.sha(hash) else { throw OpenClamAppearancePack.Failure.invalid }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OpenClam/Appearance/\(hash)", isDirectory: true)
    }
    static func read(at root: URL) throws -> Self {
        let url = root.appendingPathComponent("index.json")
        if !FileManager.default.fileExists(atPath: url.path) { return Self() }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2 * 1024 * 1024 else { throw OpenClamAppearancePack.Failure.invalid }
        let index = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard index.version == 1, index.packs.count <= 16 else { throw OpenClamAppearancePack.Failure.invalid }
        for pack in index.packs {
            try pack.validate()
            guard let directory = pack.directory, OpenClamAppearancePack.filename(directory) else { throw OpenClamAppearancePack.Failure.invalid }
        }
        return index
    }
    static func install(from source: URL, model: URL) throws -> OpenClamAppearancePack {
        let manager = FileManager.default
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= OpenClamAppearancePack.maximumBytes else { throw OpenClamAppearancePack.Failure.tooLarge }
        let scratch = manager.temporaryDirectory.appendingPathComponent("appearance-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }
        let snapshot = scratch.appendingPathComponent("download.oclook")
        manager.createFile(atPath: snapshot.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: snapshot)
        defer { try? input.close(); try? output.close() }
        var copied = 0
        while let part = try input.read(upToCount: 1024 * 1024), !part.isEmpty {
            copied += part.count
            guard copied <= OpenClamAppearancePack.maximumBytes else { throw OpenClamAppearancePack.Failure.tooLarge }
            try output.write(contentsOf: part)
        }
        try output.close()
        guard (try snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= OpenClamAppearancePack.maximumBytes else { throw OpenClamAppearancePack.Failure.tooLarge }
        let archive = try Archive(url: snapshot, accessMode: .read)
        let entries = Array(archive)
        guard (2...257).contains(entries.count), Set(entries.map(\.path)).count == entries.count,
              entries.allSatisfy({ $0.type == .file && OpenClamAppearancePack.filename($0.path) && $0.uncompressedSize > 0 && $0.uncompressedSize <= OpenClamAppearancePack.maximumFileBytes }),
              entries.reduce(UInt64(0), { $0 + UInt64($1.uncompressedSize) }) <= OpenClamAppearancePack.maximumBytes,
              let metadata = archive["appearance.json"], metadata.uncompressedSize <= 512 * 1024 else { throw OpenClamAppearancePack.Failure.invalid }
        var data = Data()
        _ = try archive.extract(metadata) { part in
            guard data.count + part.count <= 512 * 1024 else { throw OpenClamAppearancePack.Failure.invalid }
            data.append(part)
        }
        var pack = try JSONDecoder().decode(OpenClamAppearancePack.self, from: data)
        try pack.validate()
        guard Set(pack.files.keys).union(["appearance.json"]) == Set(entries.map(\.path)) else { throw OpenClamAppearancePack.Failure.invalid }
        let hash = try OpenClamBundledAvatarUpdate.sha256(at: model)
        guard hash == pack.modelSHA256 else { throw OpenClamAppearancePack.Failure.wrongModel }
        let unpacked = scratch.appendingPathComponent("assets", isDirectory: true)
        try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        for (name, asset) in pack.files {
            guard let entry = archive[name], entry.uncompressedSize == asset.bytes else { throw OpenClamAppearancePack.Failure.invalid }
            let target = unpacked.appendingPathComponent(name)
            _ = try archive.extract(entry, to: target)
            guard (try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == asset.bytes,
                  try OpenClamBundledAvatarUpdate.sha256(at: target) == asset.sha256 else { throw OpenClamAppearancePack.Failure.integrity }
            if ["png", "jpg"].contains(target.pathExtension) {
                guard let image = CGImageSourceCreateWithURL(target as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (1...2048).contains(width), (1...2048).contains(height) else { throw OpenClamAppearancePack.Failure.invalid }
            }
        }
        mutationLock.lock(); defer { mutationLock.unlock() }
        let root = try root(for: hash)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var current = try read(at: root)
        let previous = current.packs.filter { $0.id == pack.id }.compactMap(\.directory)
        current.packs.removeAll { $0.id == pack.id }
        guard current.packs.count < 16 else { throw OpenClamAppearancePack.Failure.tooMany }
        let revision = String(try OpenClamBundledAvatarUpdate.sha256(at: snapshot).prefix(20))
        pack.directory = "\(pack.id)-\(revision)"
        var target = root.appendingPathComponent(pack.directory!, isDirectory: true)
        if manager.fileExists(atPath: target.path) {
            let valid = pack.files.allSatisfy { name, file in
                let url = target.appendingPathComponent(name)
                return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
                    && (try? OpenClamBundledAvatarUpdate.sha256(at: url)) == file.sha256
            }
            if !valid {
                pack.directory! += "-" + UUID().uuidString.prefix(8).lowercased()
                target = root.appendingPathComponent(pack.directory!, isDirectory: true)
            }
        }
        current.packs.append(pack)
        let encoded = try JSONEncoder().encode(current)
        guard encoded.count <= 2 * 1024 * 1024 else { throw OpenClamAppearancePack.Failure.tooLarge }
        if !manager.fileExists(atPath: target.path) { try manager.moveItem(at: unpacked, to: target) }
        try encoded.write(to: root.appendingPathComponent("index.json"), options: .atomic)
        for old in previous where old != pack.directory && OpenClamAppearancePack.filename(old) { try? manager.removeItem(at: root.appendingPathComponent(old)) }
        return pack
    }
    static func resource(path: String, modelHash: String) throws -> (Data, String) {
        let root = try root(for: modelHash), index = try read(at: root)
        if path == "/appearance/index.json" {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(index)) as! [String: Any]
            json["baseURL"] = "/appearance/"
            return (try JSONSerialization.data(withJSONObject: json), "application/json")
        }
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "appearance", let pack = index.packs.first(where: { $0.directory == String(parts[1]) }),
              let file = pack.files[String(parts[2])] else { throw URLError(.fileDoesNotExist) }
        let url = root.appendingPathComponent(String(parts[1])).appendingPathComponent(String(parts[2]))
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, values.fileSize == file.bytes,
              try OpenClamBundledAvatarUpdate.sha256(at: url) == file.sha256 else { throw OpenClamAppearancePack.Failure.integrity }
        let type = url.pathExtension == "png" ? "image/png" : url.pathExtension == "jpg" ? "image/jpeg" : url.pathExtension == "json" ? "application/json" : "application/octet-stream"
        return (try Data(contentsOf: url, options: .mappedIfSafe), type)
    }
    static func remove(_ id: String, model: URL) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let root = try root(for: OpenClamBundledAvatarUpdate.sha256(at: model))
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        var current = try read(at: root)
        let removed = current.packs.filter { $0.id == id }
        current.packs.removeAll { $0.id == id }
        try JSONEncoder().encode(current).write(to: root.appendingPathComponent("index.json"), options: .atomic)
        for pack in removed { if let folder = pack.directory, OpenClamAppearancePack.filename(folder) { try? FileManager.default.removeItem(at: root.appendingPathComponent(folder)) } }
    }
}

/// URLSession downloads to a temporary file, never to a full in-memory Data.
private final class AppearanceDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var cancelled = false
    private let progress: @Sendable (Int64, Int64) -> Void
    init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }
    static func allowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.fragment == nil
    }
    func download(_ url: URL) async throws -> URL {
        guard Self.allowed(url) else { throw URLError(.unsupportedURL) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                if cancelled { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
                config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url); self.task = task; task.resume()
            }
        } onCancel: { self.cancel() }
    }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    private func finish(_ result: Result<URL, Error>) {
        lock.lock(); let callback = continuation; continuation = nil; let session = session; self.session = nil; lock.unlock()
        callback?.resume(with: result); session?.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allowed(request.url) ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > OpenClamAppearancePack.maximumBytes || totalBytesExpectedToWrite > OpenClamAppearancePack.maximumBytes { downloadTask.cancel(); return }
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode), Self.allowed(response.url),
                  (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= OpenClamAppearancePack.maximumBytes else { throw URLError(.badServerResponse) }
            let saved = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-\(UUID().uuidString).oclook")
            try FileManager.default.moveItem(at: location, to: saved)
            finish(.success(saved))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if let error { finish(.failure(error)) } }
}

@MainActor
struct OpenClamAppearanceAssetsView: View {
    let avatarID: String
    let model: URL
    @ObservedObject private var options = OpenClam3DOptionsStore.shared
    @State private var showsImporter = false
    @State private var link = ""
    @State private var status = ""
    @State private var progress: Double?
    @State private var busy = false
    @State private var downloading = false
    @State private var error: String?
    @State private var packs: [OpenClamAppearancePack] = []
    @State private var operation: Task<Void, Never>?
    var body: some View {
        Form {
            Section {
                Button("Import from Files…", systemImage: "folder") { showsImporter = true }.disabled(busy)
                    .accessibilityIdentifier("openclam-appearance-import")
                TextField("Direct HTTPS download link", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).disabled(busy)
                Button("Download appearance pack", systemImage: "arrow.down.circle") { download() }.disabled(busy || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("openclam-appearance-download")
                if busy {
                    if let progress { ProgressView(value: progress) } else { ProgressView() }
                    Text(status).font(.footnote)
                    if downloading { Button("Cancel download", role: .cancel) { operation?.cancel() } }
                }
            } header: { Text("Add clothes, hair, colors & expressions") }
            footer: { Text("Appearance packs add choices to your installed model. Only selected textures and expressions are loaded. Use an .oclook pack; complete .avtr avatars can still be imported from Wardrobe & Poses.") }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section("Installed packs") {
                if packs.isEmpty { Text("No optional appearance packs installed.") }
                ForEach(packs, id: \.id) { pack in
                    VStack(alignment: .leading) {
                        Text(pack.label)
                        Text("\(pack.items.count) choices · \(ByteCountFormatter.string(fromByteCount: Int64(pack.files.values.reduce(0) { $0 + $1.bytes }), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                        Button("Remove pack", role: .destructive) { remove(pack.id) }.disabled(busy)
                    }
                }
            }
        }.navigationTitle("Appearance assets")
        .task { await refresh() }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.openClamAppearancePack, .zip], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first { install(url, temporary: false) }
            else if case let .failure(failure) = result, (failure as NSError).code != NSUserCancelledError { error = failure.localizedDescription }
        }
        .onDisappear { if downloading { operation?.cancel() } }
    }
    private func refresh() async {
        do { packs = try await Task.detached { try OpenClamAppearanceIndex.read(at: OpenClamAppearanceIndex.root(for: OpenClamBundledAvatarUpdate.sha256(at: model))).packs }.value }
        catch { self.error = error.localizedDescription }
    }
    private func finishInstall(_ url: URL, temporary: Bool) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() }; if temporary { try? FileManager.default.removeItem(at: url) } }
        do {
            try Task.checkCancellation()
            downloading = false; status = "Verifying and installing…"; progress = nil
            _ = try await Task.detached { try OpenClamAppearanceIndex.install(from: url, model: model) }.value
            options.retry(avatarID); await refresh(); status = "Appearance pack installed."
        } catch is CancellationError { status = "Download cancelled." }
        catch { self.error = error.localizedDescription }
    }
    private func install(_ url: URL, temporary: Bool) {
        guard !busy else { return }; busy = true; error = nil
        operation = Task { await finishInstall(url, temporary: temporary); busy = false; downloading = false }
    }
    private func download() {
        guard !busy, let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), AppearanceDownloader.allowed(url) else { error = "Enter a direct HTTPS link to an appearance pack."; return }
        busy = true; downloading = true; error = nil; progress = nil; status = "Downloading…"
        operation = Task {
            defer { busy = false; downloading = false }
            do {
                let client = AppearanceDownloader { received, total in Task { @MainActor in progress = total > 0 ? min(0.99, Double(received) / Double(total)) : nil; status = "Downloaded \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))" } }
                let url = try await client.download(url)
                await finishInstall(url, temporary: true)
            } catch is CancellationError { status = "Download cancelled." }
            catch { if Task.isCancelled { status = "Download cancelled." } else { self.error = error.localizedDescription } }
        }
    }
    private func remove(_ id: String) {
        guard !busy else { return }; busy = true
        operation = Task {
            defer { busy = false }
            do { try await Task.detached { try OpenClamAppearanceIndex.remove(id, model: model) }.value; options.retry(avatarID); await refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
}
