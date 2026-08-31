import CryptoKit
import Foundation

struct AgentConnectorArtifactTransfer: Sendable {
    let temporaryURL: URL
    let responseURL: URL
    let statusCode: Int
    let contentType: String?
    let contentLength: Int64?
}

protocol AgentConnectorArtifactTransporting: Sendable {
    func download(_ request: URLRequest) async throws -> AgentConnectorArtifactTransfer
}

final class URLSessionAgentConnectorArtifactTransport:
    AgentConnectorArtifactTransporting,
    @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        session = URLSession(
            configuration: configuration,
            delegate: AgentConnectorNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func download(_ request: URLRequest) async throws -> AgentConnectorArtifactTransfer {
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse,
              let responseURL = http.url else {
            throw AgentConnectorError.attachmentUnavailable
        }
        let headerLength = http.value(forHTTPHeaderField: "Content-Length")
            .flatMap(Int64.init)
        return .init(
            temporaryURL: temporaryURL,
            responseURL: responseURL,
            statusCode: http.statusCode,
            contentType: http.mimeType?.lowercased(),
            contentLength: headerLength
        )
    }
}

protocol AgentConnectorArtifactServicing: Sendable {
    func downloadAndStore(
        _ metadata: AgentConnectorAttachmentMetadata,
        clientToken: String
    ) async throws -> AgentConnectorStoredAttachment
    func storedURL(for reference: ConversationConnectorArtifactReference) async -> URL?
    func deleteArtifacts(_ references: [ConversationConnectorArtifactReference]) async
    func deleteArtifacts(connectionID: UUID) async
    func pruneInvalidArtifacts() async
    func reconcileArtifacts(
        retaining references: [ConversationConnectorArtifactReference]
    ) async
}

actor OpenClawAgentConnectorArtifactService: AgentConnectorArtifactServicing {
    private let origin: AgentConnectorOrigin
    private let transport: any AgentConnectorArtifactTransporting
    private let store: AgentConnectorArtifactStore
    private let nowMilliseconds: @Sendable () -> Int64

    init(
        origin: AgentConnectorOrigin,
        transport: any AgentConnectorArtifactTransporting = URLSessionAgentConnectorArtifactTransport(),
        store: AgentConnectorArtifactStore = AgentConnectorArtifactStore(),
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.origin = origin
        self.transport = transport
        self.store = store
        self.nowMilliseconds = nowMilliseconds
    }

    func downloadAndStore(
        _ rawMetadata: AgentConnectorAttachmentMetadata,
        clientToken: String
    ) async throws -> AgentConnectorStoredAttachment {
        let now = nowMilliseconds()
        guard rawMetadata.expiresAtMilliseconds > now else {
            throw AgentConnectorError.attachmentExpired
        }
        let metadata = try rawMetadata.validated()
        let token = try AgentConnectorTokenValidator.normalized(clientToken)
        if let existing = try store.storedAttachment(for: metadata) {
            return existing
        }

        let expectedURL = origin.attachmentURL(
            connectionID: metadata.connectionID,
            attachmentID: metadata.attachmentID
        )
        guard expectedURL.path == metadata.downloadPath,
              expectedURL.query == nil,
              expectedURL.fragment == nil else {
            throw AgentConnectorError.invalidFrame
        }
        var request = URLRequest(url: expectedURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 300
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(metadata.mediaType, forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let transfer: AgentConnectorArtifactTransfer
        do {
            transfer = try await transport.download(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentConnectorError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw AgentConnectorError.connectionUnavailable
        }
        defer { try? FileManager.default.removeItem(at: transfer.temporaryURL) }
        try Task.checkCancellation()

        guard transfer.responseURL == expectedURL else {
            throw AgentConnectorError.redirected
        }
        if (300 ... 399).contains(transfer.statusCode) {
            throw AgentConnectorError.redirected
        }
        if transfer.statusCode == 404 || transfer.statusCode == 410 {
            throw AgentConnectorError.attachmentExpired
        }
        guard transfer.statusCode == 200 else {
            throw AgentConnectorError.attachmentUnavailable
        }
        guard transfer.contentType == metadata.mediaType,
              transfer.contentLength.map({ $0 == Int64(metadata.byteCount) }) ?? true else {
            throw AgentConnectorError.attachmentIntegrityFailed
        }
        let verified = try Self.verifyFile(
            at: transfer.temporaryURL,
            expectedByteCount: metadata.byteCount,
            expectedSHA256: metadata.sha256
        )
        guard verified else {
            throw AgentConnectorError.attachmentIntegrityFailed
        }
        return try store.persist(
            temporaryURL: transfer.temporaryURL,
            metadata: metadata,
            storedAtMilliseconds: now
        )
    }

    func storedURL(for reference: ConversationConnectorArtifactReference) async -> URL? {
        try? store.storedURL(for: reference)
    }

    func deleteArtifacts(connectionID: UUID) async {
        try? store.deleteArtifacts(connectionID: connectionID)
    }

    func deleteArtifacts(_ references: [ConversationConnectorArtifactReference]) async {
        for reference in references {
            try? store.deleteArtifact(
                connectionID: reference.connectionID,
                attachmentID: reference.attachmentID
            )
        }
    }

    func pruneInvalidArtifacts() async {
        try? store.prune(retaining: nil)
    }

    func reconcileArtifacts(
        retaining references: [ConversationConnectorArtifactReference]
    ) async {
        try? store.prune(retaining: Set(references.map(Self.identity)))
    }

    private static func identity(_ reference: ConversationConnectorArtifactReference) -> String {
        reference.connectionID.uuidString.lowercased()
            + "/" + reference.attachmentID.uuidString.lowercased()
            + "/" + reference.sha256
    }

    private static func verifyFile(
        at url: URL,
        expectedByteCount: Int,
        expectedSHA256: String
    ) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              values.fileSize == expectedByteCount else {
            return false
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            total += chunk.count
            guard total <= expectedByteCount else { return false }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return total == expectedByteCount && digest == expectedSHA256
    }
}

final class AgentConnectorArtifactStore: @unchecked Sendable {
    private struct Manifest: Codable {
        let v: Int
        let metadata: AgentConnectorAttachmentMetadata
        let assetKey: String
        let storedAtMilliseconds: Int64
    }

    private let lock = NSLock()
    private let fileManager: FileManager
    let rootURL: URL

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.rootURL = applicationSupport
                .appendingPathComponent("OpenClam", isDirectory: true)
                .appendingPathComponent("OpenClawArtifacts", isDirectory: true)
        }
    }

    func persist(
        temporaryURL: URL,
        metadata rawMetadata: AgentConnectorAttachmentMetadata,
        storedAtMilliseconds: Int64
    ) throws -> AgentConnectorStoredAttachment {
        let metadata = try rawMetadata.validated()
        return try lock.withLock {
            try ensureRoot()
            if let existing = try storedAttachmentUnlocked(for: metadata) {
                return existing
            }
            let directory = artifactDirectory(
                connectionID: metadata.connectionID,
                attachmentID: metadata.attachmentID
            )
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(directoryValues)

            let extensionSuffix = Self.safeExtension(from: metadata.fileName)
            let storedName = extensionSuffix.map { "content.\($0)" } ?? "content"
            let destination = directory.appendingPathComponent(storedName, isDirectory: false)
            let partial = directory.appendingPathComponent(
                ".partial-\(UUID().uuidString.lowercased())",
                isDirectory: false
            )
            defer { try? fileManager.removeItem(at: partial) }
            try fileManager.copyItem(at: temporaryURL, to: partial)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: partial.path
            )
            var fileValues = URLResourceValues()
            fileValues.isExcludedFromBackup = true
            var mutablePartial = partial
            try mutablePartial.setResourceValues(fileValues)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: partial, to: destination)

            let assetKey = try relativeAssetKey(for: destination)
            let stored = try AgentConnectorStoredAttachment(
                metadata: metadata,
                assetKey: assetKey
            ).validated()
            let manifest = Manifest(
                v: 1,
                metadata: metadata,
                assetKey: assetKey,
                storedAtMilliseconds: storedAtMilliseconds
            )
            let manifestData = try JSONEncoder().encode(manifest)
            let manifestURL = directory.appendingPathComponent("manifest.json")
            try manifestData.write(to: manifestURL, options: [.atomic, .completeFileProtection])
            var manifestValues = URLResourceValues()
            manifestValues.isExcludedFromBackup = true
            var mutableManifest = manifestURL
            try mutableManifest.setResourceValues(manifestValues)
            return stored
        }
    }

    func storedAttachment(
        for metadata: AgentConnectorAttachmentMetadata
    ) throws -> AgentConnectorStoredAttachment? {
        try lock.withLock { try storedAttachmentUnlocked(for: metadata) }
    }

    func storedURL(
        for rawReference: ConversationConnectorArtifactReference
    ) throws -> URL? {
        let reference = try rawReference.validated()
        return try lock.withLock {
            let manifest = try loadManifest(
                connectionID: reference.connectionID,
                attachmentID: reference.attachmentID
            )
            guard manifest.v == 1,
                  manifest.metadata.sha256 == reference.sha256,
                  manifest.metadata.expiresAtMilliseconds
                    == reference.expiresAtMilliseconds else {
                return nil
            }
            let url = try resolvedURL(for: manifest.assetKey)
            guard fileManager.fileExists(atPath: url.path),
                  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    == manifest.metadata.byteCount else {
                return nil
            }
            return url
        }
    }

    func deleteArtifacts(connectionID: UUID) throws {
        try lock.withLock {
            let directory = rootURL.appendingPathComponent(
                connectionID.uuidString.lowercased(),
                isDirectory: true
            )
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    func deleteArtifact(connectionID: UUID, attachmentID: UUID) throws {
        try lock.withLock {
            let directory = artifactDirectory(
                connectionID: connectionID,
                attachmentID: attachmentID
            )
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    /// With no retain set, only malformed records and partial files are removed. Once chat
    /// history is loaded, a retain set additionally removes true orphans. Delivered files do
    /// not expire merely because the relay download TTL elapsed.
    func prune(retaining identities: Set<String>?) throws {
        try lock.withLock {
            try ensureRoot()
            let connectionDirectories = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for connectionDirectory in connectionDirectories {
                let attachmentDirectories = (try? fileManager.contentsOfDirectory(
                    at: connectionDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for attachmentDirectory in attachmentDirectories {
                    let manifestURL = attachmentDirectory.appendingPathComponent("manifest.json")
                    guard let data = try? Data(contentsOf: manifestURL),
                          let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                          manifest.v == 1,
                          manifest.storedAtMilliseconds > 0,
                          (try? manifest.metadata.validated()) != nil,
                          (try? resolvedURL(for: manifest.assetKey)) != nil else {
                        try? fileManager.removeItem(at: attachmentDirectory)
                        continue
                    }
                    let identity = manifest.metadata.connectionID.uuidString.lowercased()
                        + "/" + manifest.metadata.attachmentID.uuidString.lowercased()
                        + "/" + manifest.metadata.sha256
                    if let identities, !identities.contains(identity) {
                        try? fileManager.removeItem(at: attachmentDirectory)
                        continue
                    }
                    let children = (try? fileManager.contentsOfDirectory(
                        at: attachmentDirectory,
                        includingPropertiesForKeys: nil
                    )) ?? []
                    for child in children where child.lastPathComponent.hasPrefix(".partial-") {
                        try? fileManager.removeItem(at: child)
                    }
                }
                if ((try? fileManager.contentsOfDirectory(atPath: connectionDirectory.path)) ?? []).isEmpty {
                    try? fileManager.removeItem(at: connectionDirectory)
                }
            }
        }
    }

    private func storedAttachmentUnlocked(
        for metadata: AgentConnectorAttachmentMetadata
    ) throws -> AgentConnectorStoredAttachment? {
        guard let manifest = try? loadManifest(
            connectionID: metadata.connectionID,
            attachmentID: metadata.attachmentID
        ), manifest.v == 1, manifest.metadata == metadata else {
            return nil
        }
        let stored = try AgentConnectorStoredAttachment(
            metadata: manifest.metadata,
            assetKey: manifest.assetKey
        ).validated()
        let url = try resolvedURL(for: stored.assetKey)
        guard fileManager.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                == metadata.byteCount else {
            return nil
        }
        return stored
    }

    private func ensureRoot() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try mutableRoot.setResourceValues(values)
    }

    private func artifactDirectory(connectionID: UUID, attachmentID: UUID) -> URL {
        rootURL
            .appendingPathComponent(connectionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(attachmentID.uuidString.lowercased(), isDirectory: true)
    }

    private func loadManifest(connectionID: UUID, attachmentID: UUID) throws -> Manifest {
        let url = artifactDirectory(connectionID: connectionID, attachmentID: attachmentID)
            .appendingPathComponent("manifest.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    private func relativeAssetKey(for url: URL) throws -> String {
        let root = rootURL.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { throw AgentConnectorError.invalidFrame }
        return String(path.dropFirst(root.count))
    }

    private func resolvedURL(for assetKey: String) throws -> URL {
        guard !assetKey.hasPrefix("/"),
              !assetKey.contains(".."),
              !assetKey.contains("\\") else {
            throw AgentConnectorError.invalidFrame
        }
        let candidate = rootURL.appendingPathComponent(assetKey).standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw AgentConnectorError.invalidFrame
        }
        return candidate
    }

    private static func safeExtension(from fileName: String) -> String? {
        let value = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard value.range(of: #"^[a-z0-9]{1,12}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }
}
