import Combine
import CryptoKit
import Foundation
import ImageIO
import UIKit

struct OpenClamAvatarStoreCatalogDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let entries: [OpenClamAvatarStoreEntry]
}

struct OpenClamAvatarStoreEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let author: String
    let version: Int
    let thumbnail: OpenClamAvatarStoreThumbnail
    let variants: OpenClamAvatarStoreVariants

    var iosLight: OpenClamAvatarStoreVariant { variants.iosLight }
}

struct OpenClamAvatarStoreThumbnail: Codable, Equatable, Sendable {
    let url: URL
    let sha256: String
    let bytes: Int
    let mime: String
    let width: Int
    let height: Int
}

struct OpenClamAvatarStoreVariants: Codable, Equatable, Sendable {
    let iosLight: OpenClamAvatarStoreVariant
    let macOSFull: OpenClamAvatarStoreVariant?

    enum CodingKeys: String, CodingKey {
        case iosLight = "ios-light"
        case macOSFull = "macos-full"
    }
}

struct OpenClamAvatarStoreVariant: Codable, Equatable, Sendable {
    let url: URL
    let sha256: String
    let bytes: Int
    let format: String
    let profile: String
}

enum OpenClamAvatarStoreCatalogError: LocalizedError, Equatable {
    case catalogTooLarge
    case invalidJSON
    case unsupportedSchema
    case invalidShape
    case emptyCatalog
    case tooManyEntries
    case duplicateIdentifier
    case invalidEntry(String)
    case invalidURL
    case invalidHash
    case unsupportedMediaType
    case unsupportedPackage

    var errorDescription: String? {
        switch self {
        case .catalogTooLarge:
            "The Avatar Store catalog is larger than OpenClam allows."
        case .invalidJSON, .invalidShape:
            "The Avatar Store catalog is damaged or has an unsupported structure."
        case .unsupportedSchema:
            "This Avatar Store catalog requires a newer version of OpenClam."
        case .emptyCatalog:
            "The Avatar Store catalog is currently empty."
        case .tooManyEntries:
            "The Avatar Store catalog contains too many entries."
        case .duplicateIdentifier:
            "The Avatar Store catalog contains a duplicate avatar."
        case let .invalidEntry(id):
            "The Avatar Store entry “\(id)” is invalid."
        case .invalidURL:
            "The Avatar Store returned an untrusted download address."
        case .invalidHash:
            "The Avatar Store returned an invalid integrity value."
        case .unsupportedMediaType:
            "The Avatar Store thumbnail type is not supported."
        case .unsupportedPackage:
            "The Avatar Store package is not an OpenClam iPhone avatar."
        }
    }
}

/// The endpoint stays nil until the matching catalog and hash-pinned release
/// assets are publicly reachable. Publication and client enablement are two
/// separate release steps so a shipped build can never point at a placeholder.
enum OpenClamAvatarStoreReleasePolicy {
    static let productionCatalogURL = URL(
        string: "https://raw.githubusercontent.com/tivojn/openclam-livekit-studio/avatar-store-v1.0.0/shared/avatar-store-v1/catalog/v1/catalog.json"
    )!
    static let catalogURL: URL? = nil
    static let unavailableMessage =
        "Avatar Store isn’t available in this release. You can still import .avtr files from Files."

    static var isAvailable: Bool { catalogURL != nil }
}

struct OpenClamAvatarStoreRemoteAccess: Sendable {
    fileprivate let catalogURL: URL?

    static let release = Self(catalogURL: OpenClamAvatarStoreReleasePolicy.catalogURL)

#if DEBUG
    /// Unit tests exercise the dormant generic store engine against synthetic
    /// endpoints and an injected transfer client. Release UI always uses
    /// `release`, whose endpoint is nil.
    static func testing(catalogURL: URL) -> Self {
        Self(catalogURL: catalogURL)
    }
#endif

    var isEnabled: Bool { catalogURL != nil }
}

enum OpenClamAvatarStoreURLPolicy {
    static let productionCatalogURL = OpenClamAvatarStoreReleasePolicy.productionCatalogURL

    private static let owner = "tivojn"
    private static let repository = "openclam-livekit-studio"

    static func allowsCatalogURL(_ url: URL) -> Bool {
        guard hasSafeHTTPSComponents(url),
              url.host?.lowercased() == "raw.githubusercontent.com",
              url.path == "/\(owner)/\(repository)/avatar-store-v1.0.0/shared/avatar-store-v1/catalog/v1/catalog.json" else {
            return false
        }
        return true
    }

    static func allowsThumbnailURL(_ url: URL) -> Bool {
        guard hasSafeHTTPSComponents(url) else { return false }
        switch url.host?.lowercased() {
        case "raw.githubusercontent.com":
            return url.path.hasPrefix("/\(owner)/\(repository)/")
        case "github.com":
            return url.path.hasPrefix("/\(owner)/\(repository)/releases/download/")
        default:
            return false
        }
    }

    static func allowsPackageURL(_ url: URL) -> Bool {
        guard hasSafeHTTPSComponents(url),
              url.host?.lowercased() == "github.com" else {
            return false
        }
        return url.path.hasPrefix("/\(owner)/\(repository)/releases/download/")
            && url.path.hasSuffix(".avtr")
    }

    /// Every redirect and the final response are checked independently. GitHub
    /// release downloads may move to its opaque object host, but catalog data
    /// can never nominate that host directly.
    static func allowsRedirectOrFinalURL(_ url: URL, for requestURL: URL) -> Bool {
        guard allowsCatalogURL(requestURL)
                || allowsThumbnailURL(requestURL)
                || allowsPackageURL(requestURL) else {
            return false
        }

        if allowsCatalogURL(requestURL) {
            return allowsCatalogURL(url)
        }

        if allowsPackageURL(requestURL) {
            if allowsPackageURL(url) {
                return true
            }
        } else if allowsThumbnailURL(requestURL) {
            if allowsThumbnailURL(url) {
                return true
            }
            // Opaque GitHub object hosts are permitted only when the catalog's
            // approved thumbnail itself starts at this repository's release
            // download path. A raw catalog/thumbnail request can never opt in.
            guard isRepositoryReleaseDownload(requestURL) else { return false }
        }

        let redirectHosts = [
            "objects.githubusercontent.com",
            "release-assets.githubusercontent.com",
        ]
        return redirectHosts.contains(url.host?.lowercased() ?? "")
            && hasSafeHTTPSComponents(url, allowsOpaqueQuery: true)
    }

    private static func isRepositoryReleaseDownload(_ url: URL) -> Bool {
        hasSafeHTTPSComponents(url)
            && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix("/\(owner)/\(repository)/releases/download/")
    }

    private static func hasSafeHTTPSComponents(
        _ url: URL,
        allowsOpaqueQuery: Bool = false
    ) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              (allowsOpaqueQuery || components.query == nil),
              components.fragment == nil,
              !components.percentEncodedPath.localizedCaseInsensitiveContains("%2f"),
              !components.percentEncodedPath.localizedCaseInsensitiveContains("%5c") else {
            return false
        }
        return true
    }
}

enum OpenClamAvatarStoreCatalogParser {
    static let maximumCatalogBytes = 256 * 1_024
    static let maximumEntryCount = 100
    static let maximumThumbnailBytes = 5 * 1_024 * 1_024

    static func decode(_ data: Data) throws -> OpenClamAvatarStoreCatalogDocument {
        guard !data.isEmpty, data.count <= maximumCatalogBytes else {
            throw OpenClamAvatarStoreCatalogError.catalogTooLarge
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OpenClamAvatarStoreCatalogError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw OpenClamAvatarStoreCatalogError.invalidShape
        }
        try exactKeys(root, ["schemaVersion", "entries"])
        guard let rawEntries = root["entries"] as? [[String: Any]] else {
            throw OpenClamAvatarStoreCatalogError.invalidShape
        }
        for entry in rawEntries {
            try exactKeys(
                entry,
                ["id", "name", "author", "version", "thumbnail", "variants"]
            )
            guard let thumbnail = entry["thumbnail"] as? [String: Any],
                  let variants = entry["variants"] as? [String: Any],
                  let iosLight = variants["ios-light"] as? [String: Any] else {
                throw OpenClamAvatarStoreCatalogError.invalidShape
            }
            try exactKeys(
                thumbnail,
                ["url", "sha256", "bytes", "mime", "width", "height"]
            )
            let macOSFull = variants["macos-full"] as? [String: Any]
            let expectedVariantKeys: Set<String> = macOSFull == nil
                ? ["ios-light"]
                : ["ios-light", "macos-full"]
            try exactKeys(variants, expectedVariantKeys)
            try exactKeys(
                iosLight,
                ["url", "sha256", "bytes", "format", "profile"]
            )
            if let macOSFull {
                try exactKeys(
                    macOSFull,
                    ["url", "sha256", "bytes", "format", "profile"]
                )
            }
        }

        let document: OpenClamAvatarStoreCatalogDocument
        do {
            document = try JSONDecoder().decode(
                OpenClamAvatarStoreCatalogDocument.self,
                from: data
            )
        } catch {
            throw OpenClamAvatarStoreCatalogError.invalidShape
        }
        try validate(document)
        return document
    }

    static func validate(_ document: OpenClamAvatarStoreCatalogDocument) throws {
        guard document.schemaVersion == 1 else {
            throw OpenClamAvatarStoreCatalogError.unsupportedSchema
        }
        guard !document.entries.isEmpty else {
            throw OpenClamAvatarStoreCatalogError.emptyCatalog
        }
        guard document.entries.count <= maximumEntryCount else {
            throw OpenClamAvatarStoreCatalogError.tooManyEntries
        }
        var identifiers = Set<String>()
        for entry in document.entries {
            guard identifiers.insert(entry.id).inserted else {
                throw OpenClamAvatarStoreCatalogError.duplicateIdentifier
            }
            try validate(entry)
        }
    }

    private static func validate(_ entry: OpenClamAvatarStoreEntry) throws {
        guard OpenClamAvatarID.isValid(entry.id),
              isSafeCatalogText(entry.name, maximumCount: 64),
              isSafeCatalogText(entry.author, maximumCount: 64),
              entry.version >= 1,
              entry.version <= 1_000_000 else {
            throw OpenClamAvatarStoreCatalogError.invalidEntry(entry.id)
        }

        let thumbnail = entry.thumbnail
        guard OpenClamAvatarStoreURLPolicy.allowsThumbnailURL(thumbnail.url) else {
            throw OpenClamAvatarStoreCatalogError.invalidURL
        }
        guard isSHA256(thumbnail.sha256),
              isSHA256(entry.iosLight.sha256),
              entry.variants.macOSFull.map({ isSHA256($0.sha256) }) ?? true else {
            throw OpenClamAvatarStoreCatalogError.invalidHash
        }
        guard thumbnail.bytes > 0,
              thumbnail.bytes <= maximumThumbnailBytes,
              thumbnail.width > 0,
              thumbnail.height > 0,
              thumbnail.width <= OpenClamAvatarPackageContract.maximumImageDimension,
              thumbnail.height <= OpenClamAvatarPackageContract.maximumImageDimension,
              UInt64(thumbnail.width) * UInt64(thumbnail.height)
                <= OpenClamAvatarPackageContract.maximumDecodedPixelCount else {
            throw OpenClamAvatarStoreCatalogError.invalidEntry(entry.id)
        }
        guard ["image/png", "image/jpeg"].contains(thumbnail.mime.lowercased()) else {
            throw OpenClamAvatarStoreCatalogError.unsupportedMediaType
        }

        let variant = entry.iosLight
        guard OpenClamAvatarStoreURLPolicy.allowsPackageURL(variant.url) else {
            throw OpenClamAvatarStoreCatalogError.invalidURL
        }
        guard variant.bytes > 0,
              UInt64(variant.bytes) <= OpenClamAvatarPackageContract.maximumArchiveByteCount,
              variant.format == OpenClamAvatarPackageContract.canonicalFormat,
              variant.profile == OpenClamAvatarPackageContract.variant else {
            throw OpenClamAvatarStoreCatalogError.unsupportedPackage
        }

        if let macVariant = entry.variants.macOSFull {
            guard OpenClamAvatarStoreURLPolicy.allowsPackageURL(macVariant.url) else {
                throw OpenClamAvatarStoreCatalogError.invalidURL
            }
            guard macVariant.bytes > 0,
                  macVariant.bytes <= 2_000_000_000,
                  macVariant.format == OpenClamAvatarPackageContract.canonicalFormat,
                  macVariant.profile == "macos-full" else {
                throw OpenClamAvatarStoreCatalogError.unsupportedPackage
            }
        }
    }

    private static func exactKeys(_ object: [String: Any], _ keys: Set<String>) throws {
        guard Set(object.keys) == keys else {
            throw OpenClamAvatarStoreCatalogError.invalidShape
        }
    }

    static func isValidPersistedRecord(hash: String, version: Int) -> Bool {
        isSHA256(hash) && version >= 1 && version <= 1_000_000
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func isSafeCatalogText(_ value: String, maximumCount: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == value
            && !trimmed.isEmpty
            && trimmed.count <= maximumCount
            && !trimmed.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }
}

struct OpenClamAvatarStoreTransferResult: Sendable {
    let data: Data
    let responseURL: URL
    let mimeType: String?
}

protocol OpenClamAvatarStoreTransferring: Sendable {
    func fetch(
        _ url: URL,
        maximumBytes: Int,
        expectedBytes: Int?,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> OpenClamAvatarStoreTransferResult
}

enum OpenClamAvatarStoreTransferError: LocalizedError, Equatable {
    case storeUnavailable
    case cancelled
    case untrustedRedirect
    case invalidResponse
    case HTTPStatus(Int)
    case responseTooLarge
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            OpenClamAvatarStoreReleasePolicy.unavailableMessage
        case .cancelled:
            "Download cancelled."
        case .untrustedRedirect:
            "The download was redirected to an untrusted server."
        case .invalidResponse:
            "The Avatar Store server returned an invalid response."
        case let .HTTPStatus(status):
            "The Avatar Store server returned status \(status)."
        case .responseTooLarge:
            "The download is larger than the catalog allows."
        case .emptyResponse:
            "The Avatar Store returned an empty download."
        }
    }
}

final class OpenClamAvatarStoreURLSessionClient: OpenClamAvatarStoreTransferring,
    @unchecked Sendable
{
    private let configuration: URLSessionConfiguration
    private let remoteAccess: OpenClamAvatarStoreRemoteAccess

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        remoteAccess: OpenClamAvatarStoreRemoteAccess = .release
    ) {
        self.remoteAccess = remoteAccess
        self.configuration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        self.configuration.urlCache = nil
        self.configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration.timeoutIntervalForRequest = 45
        self.configuration.timeoutIntervalForResource = 180
        self.configuration.waitsForConnectivity = false
        self.configuration.httpMaximumConnectionsPerHost = 2
    }

    func fetch(
        _ url: URL,
        maximumBytes: Int,
        expectedBytes: Int?,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> OpenClamAvatarStoreTransferResult {
        guard remoteAccess.isEnabled else {
            throw OpenClamAvatarStoreTransferError.storeUnavailable
        }
        guard OpenClamAvatarStoreURLPolicy.allowsCatalogURL(url)
                || OpenClamAvatarStoreURLPolicy.allowsThumbnailURL(url)
                || OpenClamAvatarStoreURLPolicy.allowsPackageURL(url) else {
            throw OpenClamAvatarStoreTransferError.invalidResponse
        }
        let operation = OpenClamAvatarStoreTransferOperation(
            configuration: configuration,
            url: url,
            maximumBytes: maximumBytes,
            expectedBytes: expectedBytes,
            progress: progress
        )
        return try await operation.start()
    }
}

private final class OpenClamAvatarStoreTransferOperation: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let requestURL: URL
    private let maximumBytes: Int
    private let expectedBytes: Int?
    private let progress: @Sendable (Int, Int) -> Void
    private var buffer = Data()
    private var responseURL: URL?
    private var mimeType: String?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<OpenClamAvatarStoreTransferResult, Error>?
    private var terminalError: Error?
    private var finished = false
    private var cancelled = false
    private var session: URLSession!

    init(
        configuration: URLSessionConfiguration,
        url: URL,
        maximumBytes: Int,
        expectedBytes: Int?,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) {
        requestURL = url
        self.maximumBytes = maximumBytes
        self.expectedBytes = expectedBytes
        self.progress = progress
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func start() async throws -> OpenClamAvatarStoreTransferResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: OpenClamAvatarStoreTransferError.cancelled)
                    return
                }
                self.continuation = continuation
                var request = URLRequest(url: requestURL)
                request.httpMethod = "GET"
                request.setValue("application/json, application/zip, image/*", forHTTPHeaderField: "Accept")
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              OpenClamAvatarStoreURLPolicy.allowsRedirectOrFinalURL(
                  url,
                  for: requestURL
              ) else {
            setTerminalError(OpenClamAvatarStoreTransferError.untrustedRedirect)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              let finalURL = response.url,
              OpenClamAvatarStoreURLPolicy.allowsRedirectOrFinalURL(
                  finalURL,
                  for: requestURL
              ) else {
            setTerminalError(OpenClamAvatarStoreTransferError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        guard response.statusCode == 200 else {
            setTerminalError(OpenClamAvatarStoreTransferError.HTTPStatus(response.statusCode))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= 0
                || response.expectedContentLength <= Int64(maximumBytes) else {
            setTerminalError(OpenClamAvatarStoreTransferError.responseTooLarge)
            completionHandler(.cancel)
            return
        }

        lock.lock()
        responseURL = finalURL
        mimeType = response.mimeType?.lowercased()
        if response.expectedContentLength > 0 {
            buffer.reserveCapacity(Int(response.expectedContentLength))
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        let prospectiveSize = buffer.count + data.count
        guard prospectiveSize <= maximumBytes else {
            terminalError = OpenClamAvatarStoreTransferError.responseTooLarge
            let task = self.task
            lock.unlock()
            task?.cancel()
            return
        }
        buffer.append(data)
        let currentCount = buffer.count
        let total = expectedBytes ?? max(currentCount, 1)
        lock.unlock()
        progress(currentCount, total)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let terminalError = self.terminalError
        let wasCancelled = cancelled || (error as? URLError)?.code == .cancelled
        let data = buffer
        let responseURL = self.responseURL
        let mimeType = self.mimeType
        lock.unlock()

        if let terminalError {
            finish(.failure(terminalError))
        } else if wasCancelled {
            finish(.failure(OpenClamAvatarStoreTransferError.cancelled))
        } else if let error {
            finish(.failure(error))
        } else if data.isEmpty {
            finish(.failure(OpenClamAvatarStoreTransferError.emptyResponse))
        } else if let responseURL {
            finish(.success(.init(data: data, responseURL: responseURL, mimeType: mimeType)))
        } else {
            finish(.failure(OpenClamAvatarStoreTransferError.invalidResponse))
        }
    }

    private func setTerminalError(_ error: Error) {
        lock.lock()
        terminalError = error
        lock.unlock()
    }

    private func finish(_ result: Result<OpenClamAvatarStoreTransferResult, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        task = nil
        lock.unlock()

        continuation?.resume(with: result)
        session.finishTasksAndInvalidate()
    }
}

enum OpenClamAvatarStoreFileVerifier {
    static func verify(data: Data, bytes: Int, sha256: String) -> Bool {
        guard data.count == bytes else { return false }
        return SHA256.hash(data: data).hexDigest == sha256
    }

    static func verifiedThumbnail(
        data: Data,
        specification: OpenClamAvatarStoreThumbnail
    ) -> UIImage? {
        guard verify(data: data, bytes: specification.bytes, sha256: specification.sha256),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == specification.width,
              properties[kCGImagePropertyPixelHeight] as? Int == specification.height,
              let type = CGImageSourceGetType(source) as String?,
              UTTypeMIME(type) == specification.mime.lowercased(),
              let image = UIImage(data: data, scale: UIScreen.main.scale) else {
            return nil
        }
        return image
    }

    private static func UTTypeMIME(_ imageType: String) -> String? {
        switch imageType {
        case "public.png": "image/png"
        case "public.jpeg": "image/jpeg"
        default: nil
        }
    }
}

private extension Digest {
    var hexDigest: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

struct OpenClamAvatarStoreCache: Sendable {
    let root: URL

    init(root: URL = Self.defaultRoot) {
        self.root = root.standardizedFileURL
    }

    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("OpenClam", isDirectory: true)
            .appendingPathComponent("AvatarStore", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    var catalogURL: URL { root.appendingPathComponent("catalog.json") }

    func archiveURL(for entry: OpenClamAvatarStoreEntry) -> URL {
        itemDirectory(for: entry.id)
            .appendingPathComponent("\(entry.iosLight.sha256).avtr")
    }

    func thumbnailURL(for entry: OpenClamAvatarStoreEntry) -> URL {
        let suffix = entry.thumbnail.mime.lowercased() == "image/png" ? "png" : "jpg"
        return itemDirectory(for: entry.id)
            .appendingPathComponent("\(entry.thumbnail.sha256).\(suffix)")
    }

    func loadCatalogData() -> Data? {
        loadBounded(catalogURL, maximumBytes: OpenClamAvatarStoreCatalogParser.maximumCatalogBytes)
    }

    func loadArchiveData(for entry: OpenClamAvatarStoreEntry) -> Data? {
        loadBounded(archiveURL(for: entry), maximumBytes: entry.iosLight.bytes)
    }

    func loadThumbnailData(for entry: OpenClamAvatarStoreEntry) -> Data? {
        loadBounded(thumbnailURL(for: entry), maximumBytes: entry.thumbnail.bytes)
    }

    func storeCatalog(_ data: Data) throws {
        try store(data, at: catalogURL)
    }

    func storeArchive(_ data: Data, for entry: OpenClamAvatarStoreEntry) throws {
        try store(data, at: archiveURL(for: entry))
    }

    func storeThumbnail(_ data: Data, for entry: OpenClamAvatarStoreEntry) throws {
        try store(data, at: thumbnailURL(for: entry))
    }

    func removeArchive(for entry: OpenClamAvatarStoreEntry) {
        try? FileManager.default.removeItem(at: archiveURL(for: entry))
    }

    private func itemDirectory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private func loadBounded(_ url: URL, maximumBytes: Int) -> Data? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ), values.isRegularFile == true,
           values.isSymbolicLink != true,
           let count = values.fileSize,
           count > 0,
           count <= maximumBytes else {
            return nil
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func store(_ data: Data, at url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum OpenClamAvatarStoreCatalogStatus: Equatable, Sendable {
    case loading
    case current
    case cachedOffline(String)
    case unavailable(String)
}

enum OpenClamAvatarStoreItemPhase: Equatable, Sendable {
    case available
    case readyOffline
    case downloading(received: Int, total: Int)
    case verifying
    case installing
    case installed
    case updateAvailable
    case failed(String)

    var fractionCompleted: Double? {
        guard case let .downloading(received, total) = self, total > 0 else { return nil }
        // Network byte delivery is not success: EOF, the pinned outer hash,
        // and the AVTR contract still have to pass. Keep the download UI at
        // 99% until the phase advances to integrity checking.
        return min(max(Double(received) / Double(total), 0), 0.99)
    }

    var percentage: Int? {
        fractionCompleted.map { Int(($0 * 100).rounded(.down)) }
    }
}

enum OpenClamAvatarStorePresentation {
    static func buttonTitle(for phase: OpenClamAvatarStoreItemPhase) -> String {
        switch phase {
        case .available: "Download"
        case .readyOffline: "Install"
        case .downloading:
            "Cancel \(phase.percentage ?? 0)%"
        case .verifying: "Checking…"
        case .installing: "Installing…"
        case .installed: "Installed"
        case .updateAvailable: "Update"
        case .failed: "Try Again"
        }
    }
}

enum OpenClamAvatarStoreVersionPolicy {
    static func phase(
        installedVersion: Int,
        installedHash: String,
        catalogVersion: Int,
        catalogHash: String
    ) -> OpenClamAvatarStoreItemPhase {
        guard catalogVersion > installedVersion else { return .installed }
        return .updateAvailable
    }

    static func allowsInstall(
        installedVersion: Int,
        installedHash: String,
        catalogVersion: Int,
        catalogHash: String
    ) -> Bool {
        catalogVersion > installedVersion
            || (catalogVersion == installedVersion && catalogHash == installedHash)
    }
}

private struct OpenClamAvatarStoreInstalledRecord {
    let hash: String
    let version: Int
}

@MainActor
final class OpenClamAvatarStore: ObservableObject {
    @Published private(set) var entries: [OpenClamAvatarStoreEntry] = []
    @Published private(set) var catalogStatus: OpenClamAvatarStoreCatalogStatus = .loading
    @Published private(set) var phases: [String: OpenClamAvatarStoreItemPhase] = [:]
    @Published private(set) var thumbnails: [String: UIImage] = [:]

    private let transferClient: any OpenClamAvatarStoreTransferring
    private let cache: OpenClamAvatarStoreCache
    private let defaults: UserDefaults
    private let installedHashesKey: String
    private let remoteAccess: OpenClamAvatarStoreRemoteAccess
    private var catalogTask: Task<Void, Never>?
    private var thumbnailTasks: [String: Task<Void, Never>] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloadGenerations: [String: UUID] = [:]
    private var phasesBeforeDownload: [String: OpenClamAvatarStoreItemPhase] = [:]

    init(
        transferClient: any OpenClamAvatarStoreTransferring = OpenClamAvatarStoreURLSessionClient(),
        cache: OpenClamAvatarStoreCache = .init(),
        defaults: UserDefaults = .standard,
        installedHashesKey: String = "openclam.avatar-store.installed-hashes.v1",
        remoteAccess: OpenClamAvatarStoreRemoteAccess = .release
    ) {
        self.transferClient = transferClient
        self.cache = cache
        self.defaults = defaults
        self.installedHashesKey = installedHashesKey
        self.remoteAccess = remoteAccess
        if !remoteAccess.isEnabled {
            catalogStatus = .unavailable(OpenClamAvatarStoreReleasePolicy.unavailableMessage)
        }
    }

    deinit {
        catalogTask?.cancel()
        thumbnailTasks.values.forEach { $0.cancel() }
        downloadTasks.values.forEach { $0.cancel() }
    }

    func load(library: OpenClamAvatarLibrary) {
        catalogTask?.cancel()
        guard let catalogURL = remoteAccess.catalogURL else {
            thumbnailTasks.values.forEach { $0.cancel() }
            downloadTasks.values.forEach { $0.cancel() }
            thumbnailTasks.removeAll()
            downloadTasks.removeAll()
            downloadGenerations.removeAll()
            phasesBeforeDownload.removeAll()
            entries = []
            phases = [:]
            thumbnails = [:]
            catalogStatus = .unavailable(OpenClamAvatarStoreReleasePolicy.unavailableMessage)
            return
        }
        if let cachedData = cache.loadCatalogData(),
           let cached = try? OpenClamAvatarStoreCatalogParser.decode(cachedData) {
            apply(cached, library: library)
            catalogStatus = .cachedOffline("Showing the last verified catalog while checking for updates.")
        } else {
            catalogStatus = .loading
        }

        catalogTask = Task { [weak self, transferClient, cache] in
            do {
                let result = try await transferClient.fetch(
                    catalogURL,
                    maximumBytes: OpenClamAvatarStoreCatalogParser.maximumCatalogBytes,
                    expectedBytes: nil,
                    progress: { _, _ in }
                )
                try Task.checkCancellation()
                guard OpenClamAvatarStoreURLPolicy.allowsRedirectOrFinalURL(
                    result.responseURL,
                    for: catalogURL
                ) else {
                    throw OpenClamAvatarStoreTransferError.untrustedRedirect
                }
                let document = try OpenClamAvatarStoreCatalogParser.decode(result.data)
                try cache.storeCatalog(result.data)
                guard let self, !Task.isCancelled else { return }
                apply(document, library: library)
                catalogStatus = .current
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                if entries.isEmpty {
                    catalogStatus = .unavailable(Self.friendly(error))
                } else {
                    catalogStatus = .cachedOffline(
                        "Offline — showing the last verified Avatar Store catalog."
                    )
                }
            }
        }
    }

    func refreshInstalledState(library: OpenClamAvatarLibrary) {
        for entry in entries where downloadTasks[entry.id] == nil {
            phases[entry.id] = restingPhase(for: entry, library: library)
        }
    }

    func primaryAction(for entry: OpenClamAvatarStoreEntry, library: OpenClamAvatarLibrary) {
        guard remoteAccess.isEnabled else { return }
        switch phases[entry.id] ?? restingPhase(for: entry, library: library) {
        case .downloading:
            cancel(entry)
        case .verifying, .installing:
            break
        case .installed:
            break
        case .available, .readyOffline, .updateAvailable, .failed:
            downloadAndInstall(entry, library: library, forceDownload: false)
        }
    }

    func redownload(_ entry: OpenClamAvatarStoreEntry, library: OpenClamAvatarLibrary) {
        guard remoteAccess.isEnabled else { return }
        downloadAndInstall(entry, library: library, forceDownload: true)
    }

    func cancel(_ entry: OpenClamAvatarStoreEntry) {
        guard case .downloading = phases[entry.id] else { return }
        downloadTasks[entry.id]?.cancel()
        downloadTasks[entry.id] = nil
        downloadGenerations[entry.id] = nil
        phases[entry.id] = phasesBeforeDownload.removeValue(forKey: entry.id) ?? .available
    }

    func buttonTitle(for entry: OpenClamAvatarStoreEntry) -> String {
        OpenClamAvatarStorePresentation.buttonTitle(for: phases[entry.id] ?? .available)
    }

    private func apply(
        _ document: OpenClamAvatarStoreCatalogDocument,
        library: OpenClamAvatarLibrary
    ) {
        entries = document.entries
        let activeIDs = Set(entries.map(\.id))
        thumbnailTasks.keys.filter { !activeIDs.contains($0) }.forEach {
            thumbnailTasks[$0]?.cancel()
            thumbnailTasks[$0] = nil
        }
        for entry in entries {
            if downloadTasks[entry.id] == nil {
                phases[entry.id] = restingPhase(for: entry, library: library)
            }
            loadThumbnail(for: entry)
        }
    }

    private func loadThumbnail(for entry: OpenClamAvatarStoreEntry) {
        guard remoteAccess.isEnabled else { return }
        thumbnailTasks[entry.id]?.cancel()
        if let data = cache.loadThumbnailData(for: entry),
           let image = OpenClamAvatarStoreFileVerifier.verifiedThumbnail(
               data: data,
               specification: entry.thumbnail
           ) {
            thumbnails[entry.id] = image
            return
        }

        thumbnailTasks[entry.id] = Task { [weak self, transferClient, cache] in
            do {
                let result = try await transferClient.fetch(
                    entry.thumbnail.url,
                    maximumBytes: entry.thumbnail.bytes,
                    expectedBytes: entry.thumbnail.bytes,
                    progress: { _, _ in }
                )
                try Task.checkCancellation()
                guard OpenClamAvatarStoreURLPolicy.allowsRedirectOrFinalURL(
                    result.responseURL,
                    for: entry.thumbnail.url
                ),
                      let image = OpenClamAvatarStoreFileVerifier.verifiedThumbnail(
                          data: result.data,
                          specification: entry.thumbnail
                      ) else {
                    throw OpenClamAvatarStoreCatalogError.invalidEntry(entry.id)
                }
                try cache.storeThumbnail(result.data, for: entry)
                guard let self, !Task.isCancelled else { return }
                thumbnails[entry.id] = image
                thumbnailTasks[entry.id] = nil
            } catch {
                guard let self else { return }
                thumbnailTasks[entry.id] = nil
            }
        }
    }

    private func downloadAndInstall(
        _ entry: OpenClamAvatarStoreEntry,
        library: OpenClamAvatarLibrary,
        forceDownload: Bool
    ) {
        guard remoteAccess.isEnabled else { return }
        guard downloadTasks[entry.id] == nil else { return }
        if library.isImported(id: entry.id),
           let installed = installedRecord(for: entry),
           !OpenClamAvatarStoreVersionPolicy.allowsInstall(
               installedVersion: installed.version,
               installedHash: installed.hash,
               catalogVersion: entry.version,
               catalogHash: entry.iosLight.sha256
           ) {
            phases[entry.id] = .installed
            return
        }
        let baseline = restingPhase(for: entry, library: library)
        let generation = UUID()
        downloadGenerations[entry.id] = generation
        phasesBeforeDownload[entry.id] = baseline

        downloadTasks[entry.id] = Task { [weak self, transferClient, cache] in
            guard let self else { return }
            var candidateWasCached = false
            do {
                let data: Data
                if !forceDownload,
                   let cached = cache.loadArchiveData(for: entry),
                   OpenClamAvatarStoreFileVerifier.verify(
                       data: cached,
                       bytes: entry.iosLight.bytes,
                       sha256: entry.iosLight.sha256
                   ) {
                    data = cached
                    phases[entry.id] = .verifying
                } else {
                    phases[entry.id] = .downloading(received: 0, total: entry.iosLight.bytes)
                    let result = try await transferClient.fetch(
                        entry.iosLight.url,
                        maximumBytes: entry.iosLight.bytes,
                        expectedBytes: entry.iosLight.bytes
                    ) { [weak self] received, total in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  downloadGenerations[entry.id] == generation else { return }
                            phases[entry.id] = .downloading(
                                received: min(received, entry.iosLight.bytes),
                                total: total
                            )
                        }
                    }
                    try Task.checkCancellation()
                    guard OpenClamAvatarStoreURLPolicy.allowsRedirectOrFinalURL(
                        result.responseURL,
                        for: entry.iosLight.url
                    ) else {
                        throw OpenClamAvatarStoreTransferError.untrustedRedirect
                    }
                    data = result.data
                    phases[entry.id] = .verifying
                }

                guard OpenClamAvatarStoreFileVerifier.verify(
                    data: data,
                    bytes: entry.iosLight.bytes,
                    sha256: entry.iosLight.sha256
                ) else {
                    throw OpenClamAvatarStoreCatalogError.invalidHash
                }
                try cache.storeArchive(data, for: entry)
                candidateWasCached = true
                try Task.checkCancellation()
                phases[entry.id] = .installing

                let descriptor = try await library.installStoreAvatar(
                    from: cache.archiveURL(for: entry),
                    expectedID: entry.id,
                    replacingExisting: library.isImported(id: entry.id)
                )
                guard descriptor.id == entry.id else {
                    throw OpenClamAvatarStoreCatalogError.invalidEntry(entry.id)
                }
                try Task.checkCancellation()
                guard downloadGenerations[entry.id] == generation else { return }
                setInstalledRecord(
                    .init(hash: entry.iosLight.sha256, version: entry.version),
                    for: entry.id
                )
                phases[entry.id] = .installed
                phasesBeforeDownload[entry.id] = nil
                downloadTasks[entry.id] = nil
                downloadGenerations[entry.id] = nil
            } catch is CancellationError {
                guard downloadGenerations[entry.id] == generation else { return }
                if candidateWasCached {
                    cache.removeArchive(for: entry)
                }
                phases[entry.id] = baseline
                phasesBeforeDownload[entry.id] = nil
                downloadTasks[entry.id] = nil
                downloadGenerations[entry.id] = nil
            } catch let error as OpenClamAvatarStoreTransferError where error == .cancelled {
                guard downloadGenerations[entry.id] == generation else { return }
                if candidateWasCached {
                    cache.removeArchive(for: entry)
                }
                phases[entry.id] = baseline
                phasesBeforeDownload[entry.id] = nil
                downloadTasks[entry.id] = nil
                downloadGenerations[entry.id] = nil
            } catch {
                guard downloadGenerations[entry.id] == generation else { return }
                if candidateWasCached {
                    // A pinned outer checksum is necessary but not sufficient:
                    // never retain an archive that the AVTR pipeline failed to
                    // validate and install, or Retry would poison itself offline.
                    cache.removeArchive(for: entry)
                }
                phases[entry.id] = .failed(Self.friendly(error))
                phasesBeforeDownload[entry.id] = nil
                downloadTasks[entry.id] = nil
                downloadGenerations[entry.id] = nil
            }
        }
    }

    private func restingPhase(
        for entry: OpenClamAvatarStoreEntry,
        library: OpenClamAvatarLibrary
    ) -> OpenClamAvatarStoreItemPhase {
        if library.isImported(id: entry.id) {
            guard let installed = installedRecord(for: entry) else {
                return .installed
            }
            return OpenClamAvatarStoreVersionPolicy.phase(
                installedVersion: installed.version,
                installedHash: installed.hash,
                catalogVersion: entry.version,
                catalogHash: entry.iosLight.sha256
            )
        }
        if let data = cache.loadArchiveData(for: entry),
           OpenClamAvatarStoreFileVerifier.verify(
               data: data,
               bytes: entry.iosLight.bytes,
               sha256: entry.iosLight.sha256
           ) {
            return .readyOffline
        }
        return .available
    }

    private func installedRecord(
        for entry: OpenClamAvatarStoreEntry
    ) -> OpenClamAvatarStoreInstalledRecord? {
        let values = defaults.dictionary(forKey: installedHashesKey) ?? [:]
        if let raw = values[entry.id] as? [String: Any],
           let hash = raw["hash"] as? String,
           let version = raw["version"] as? Int,
           OpenClamAvatarStoreCatalogParser.isValidPersistedRecord(
               hash: hash,
               version: version
           ) {
            return .init(hash: hash, version: version)
        }

        // Migrate the short-lived hash-only beta record only when it exactly
        // matches this immutable catalog artifact. A mismatched legacy record
        // has no trustworthy version and is never treated as update authority.
        if let legacyHash = values[entry.id] as? String,
           legacyHash == entry.iosLight.sha256 {
            let migrated = OpenClamAvatarStoreInstalledRecord(
                hash: legacyHash,
                version: entry.version
            )
            setInstalledRecord(migrated, for: entry.id)
            return migrated
        }
        return nil
    }

    private func setInstalledRecord(
        _ record: OpenClamAvatarStoreInstalledRecord,
        for id: String
    ) {
        var values = defaults.dictionary(forKey: installedHashesKey) ?? [:]
        values[id] = ["hash": record.hash, "version": record.version]
        defaults.set(values, forKey: installedHashesKey)
    }

    private static func friendly(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "You appear to be offline. Try again when you’re connected."
            case .timedOut:
                return "The download timed out. Try again."
            default:
                break
            }
        }
        return "The Avatar Store couldn’t finish this request. Try again."
    }
}
