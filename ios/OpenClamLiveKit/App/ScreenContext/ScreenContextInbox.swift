import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct BoundedImageMetadata: Equatable, Sendable {
    let typeIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let frameCount: Int
}

enum BoundedImageValidationError: Error, Equatable {
    case invalidImage
    case unsupportedType
    case declaredTypeMismatch
    case dimensionsExceeded
}

/// Cache-disabled ImageIO boundary shared by Screen Context, attachment staging, and local
/// previews. Metadata and pixel limits are checked before ImageIO is allowed to decode even a
/// thumbnail, preventing compressed images with hostile dimensions from reaching UIKit decoders.
enum BoundedImageData {
    static let maximumInputDimension = 12_000
    static let maximumInputPixels = 40_000_000
    static let JPEGAndPNGTypeIdentifiers: Set<String> = [
        UTType.jpeg.identifier,
        UTType.png.identifier,
    ]

    static func validate(
        _ data: Data,
        declaredTypeIdentifier: String? = nil,
        allowedTypeIdentifiers: Set<String>? = nil,
        maximumDimension: Int = maximumInputDimension,
        maximumPixelCount: Int = maximumInputPixels,
        verifiesDecoding: Bool = true
    ) throws -> BoundedImageMetadata {
        guard !data.isEmpty,
              maximumDimension > 0,
              maximumPixelCount > 0,
              let source = imageSource(for: data),
              CGImageSourceGetCount(source) == 1,
              let rawTypeIdentifier = CGImageSourceGetType(source) else {
            throw BoundedImageValidationError.invalidImage
        }

        let typeIdentifier = rawTypeIdentifier as String
        guard let actualType = UTType(typeIdentifier), actualType.conforms(to: .image) else {
            throw BoundedImageValidationError.unsupportedType
        }
        if let allowedTypeIdentifiers,
           !allowedTypeIdentifiers.contains(typeIdentifier) {
            throw BoundedImageValidationError.unsupportedType
        }

        if let declared = declaredTypeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !declared.isEmpty {
            guard isValidTypeIdentifier(declared),
                  let declaredType = UTType(declared),
                  declaredType.conforms(to: .image),
                  actualType.conforms(to: declaredType)
                    || declaredType.conforms(to: actualType) else {
                throw BoundedImageValidationError.declaredTypeMismatch
            }
        }

        guard let rawProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
              let properties = rawProperties as? [CFString: Any],
              let pixelWidth = positiveInteger(properties[kCGImagePropertyPixelWidth]),
              let pixelHeight = positiveInteger(properties[kCGImagePropertyPixelHeight]) else {
            throw BoundedImageValidationError.invalidImage
        }
        let (pixelCount, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflow,
              pixelWidth <= maximumDimension,
              pixelHeight <= maximumDimension,
              pixelCount <= maximumPixelCount else {
            throw BoundedImageValidationError.dimensionsExceeded
        }

        if verifiesDecoding {
            let verificationOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
            guard CGImageSourceCreateThumbnailAtIndex(source, 0, verificationOptions) != nil else {
                throw BoundedImageValidationError.invalidImage
            }
        }

        return BoundedImageMetadata(
            typeIdentifier: typeIdentifier,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            frameCount: 1
        )
    }

    static func makeThumbnail(
        from data: Data,
        maximumThumbnailDimension: Int,
        declaredTypeIdentifier: String? = nil,
        allowedTypeIdentifiers: Set<String>? = nil,
        maximumInputDimension: Int = BoundedImageData.maximumInputDimension,
        maximumInputPixelCount: Int = BoundedImageData.maximumInputPixels
    ) throws -> CGImage {
        guard maximumThumbnailDimension > 0 else {
            throw BoundedImageValidationError.dimensionsExceeded
        }
        _ = try validate(
            data,
            declaredTypeIdentifier: declaredTypeIdentifier,
            allowedTypeIdentifiers: allowedTypeIdentifiers,
            maximumDimension: maximumInputDimension,
            maximumPixelCount: maximumInputPixelCount,
            verifiesDecoding: false
        )
        guard let source = imageSource(for: data) else {
            throw BoundedImageValidationError.invalidImage
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumThumbnailDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              thumbnail.width > 0,
              thumbnail.height > 0,
              thumbnail.width <= maximumThumbnailDimension,
              thumbnail.height <= maximumThumbnailDimension else {
            throw BoundedImageValidationError.invalidImage
        }
        return thumbnail
    }

    private static func imageSource(for data: Data) -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateWithData(data as CFData, options)
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              number.int64Value > 0,
              number.int64Value <= Int64(Int.max) else {
            return nil
        }
        return number.intValue
    }

    private static func isValidTypeIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            })
    }
}

/// Advisory lock shared by the main app, App Intents process, and share extension. Swift actors
/// serialize only one process, so every one-slot file transaction also takes this filesystem lock.
struct AppGroupTransactionLock: Sendable {
    static let fileName = ".transaction.lock"

    private let lockURL: URL

    init(directory: URL) {
        lockURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    func withExclusiveLock<Result>(_ operation: () throws -> Result) throws -> Result {
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = Darwin.close(descriptor) }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: lockURL.path
        )

        var lockResult: Int32
        repeat {
            lockResult = flock(descriptor, LOCK_EX)
        } while lockResult != 0 && errno == EINTR
        guard lockResult == 0 else { throw CocoaError(.fileLocking) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

actor ScreenContextInbox {
    static let appGroupIdentifier = "group.com.lionheart.openclam.livekitpilot.shared"
    static let maximumInstructionCharacters = 2_000
    static let maximumInstructionBytes = 8_000
    static let maximumTextCharacters = 8_000
    static let maximumTextBytes = 32_000
    static let maximumURLBytes = 2_048
    static let maximumImageBytes = 15_000_000
    static let maximumShortcutImageDimension = BoundedImageData.maximumInputDimension
    static let maximumShortcutImagePixels = BoundedImageData.maximumInputPixels
    static let maximumManifestBytes = 64_000
    static let intakeLifetime: TimeInterval = 30 * 60

    let directory: URL

    private let fileManager: FileManager
    private let transactionLock: AppGroupTransactionLock

    init(containerURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        directory = containerURL.appendingPathComponent("ScreenContextInbox", isDirectory: true)
        transactionLock = AppGroupTransactionLock(directory: directory)
    }

    static func appGroup(fileManager: FileManager = .default) throws -> ScreenContextInbox {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ScreenContextError.appGroupUnavailable
        }
        return ScreenContextInbox(containerURL: containerURL, fileManager: fileManager)
    }

    @discardableResult
    func stage(
        _ draft: ScreenContextDraft,
        now: Date = Date()
    ) throws -> ScreenContextIntake {
        let validated = try Self.validated(draft)
        let id = UUID()
        let imageFileName = validated.imageData.map { _ in "\(id.uuidString).image" }
        let record = StoredRecord(
            id: id,
            source: draft.source,
            instruction: validated.instruction,
            sharedText: validated.sharedText,
            sharedURL: validated.sharedURL?.absoluteString,
            imageFileName: imageFileName,
            imageByteCount: validated.imageData?.count,
            imageTypeIdentifier: validated.imageTypeIdentifier,
            createdAt: now,
            expiresAt: now.addingTimeInterval(Self.intakeLifetime)
        )

        do {
            try ensureDirectory()
            try transactionLock.withExclusiveLock {
                try purgePayloads()
                do {
                    if let imageData = validated.imageData,
                       let imageFileName {
                        let imageURL = directory.appendingPathComponent(imageFileName, isDirectory: false)
                        try imageData.write(to: imageURL, options: [.atomic])
                        try protectFile(at: imageURL)
                    }
                    let manifest = try JSONEncoder().encode(record)
                    guard manifest.count <= Self.maximumManifestBytes else {
                        throw ScreenContextError.invalidStoredItem
                    }
                    let manifestURL = self.manifestURL(for: id)
                    try manifest.write(to: manifestURL, options: [.atomic])
                    try protectFile(at: manifestURL)
                } catch {
                    try? purgePayloads()
                    throw error
                }
            }
        } catch let error as ScreenContextError {
            throw error
        } catch {
            throw ScreenContextError.temporaryStorageUnavailable
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .pendingScreenContextDidChange, object: nil)
        }
        return Self.intake(from: record, imageData: validated.imageData)
    }

    func peek(now: Date = Date()) throws -> ScreenContextIntake? {
        try load(now: now, consumes: false)
    }

    func take(now: Date = Date()) throws -> ScreenContextIntake? {
        try load(now: now, consumes: true)
    }

    func discard() throws {
        do {
            try ensureDirectory()
            try transactionLock.withExclusiveLock {
                try purgePayloads()
            }
        } catch {
            throw ScreenContextError.temporaryStorageUnavailable
        }
    }

    private func load(now: Date, consumes: Bool) throws -> ScreenContextIntake? {
        do {
            try ensureDirectory()
            return try transactionLock.withExclusiveLock {
                try loadLocked(now: now, consumes: consumes)
            }
        } catch let error as ScreenContextError {
            throw error
        } catch {
            throw ScreenContextError.temporaryStorageUnavailable
        }
    }

    private func loadLocked(now: Date, consumes: Bool) throws -> ScreenContextIntake? {
        do {
            let payloads: [URL]
            do {
                payloads = try payloadURLs()
            } catch {
                throw StoredItemReadFailure.transient
            }
            guard !payloads.isEmpty else { return nil }
            let manifests = payloads.filter { $0.pathExtension == "json" }
            guard manifests.count == 1, let manifestURL = manifests.first else {
                throw StoredItemReadFailure.confirmedInvalid
            }
            let manifestByteCount = try byteCount(at: manifestURL)
            guard (1 ... Self.maximumManifestBytes).contains(manifestByteCount) else {
                throw StoredItemReadFailure.confirmedInvalid
            }
            let manifest = try readData(at: manifestURL)
            guard manifest.count == manifestByteCount else {
                throw StoredItemReadFailure.confirmedInvalid
            }
            let record: StoredRecord
            do {
                record = try JSONDecoder().decode(StoredRecord.self, from: manifest)
            } catch {
                throw StoredItemReadFailure.confirmedInvalid
            }
            guard manifestURL.lastPathComponent == "\(record.id.uuidString).json" else {
                throw StoredItemReadFailure.confirmedInvalid
            }
            guard record.expiresAt > record.createdAt,
                  record.expiresAt.timeIntervalSince(record.createdAt) <= Self.intakeLifetime,
                  record.expiresAt > now else {
                do {
                    try purgePayloads()
                } catch {
                    throw StoredItemReadFailure.transient
                }
                return nil
            }
            var expectedNames: Set<String> = [manifestURL.lastPathComponent]
            if let imageFileName = record.imageFileName {
                expectedNames.insert(imageFileName)
            }
            guard Set(payloads.map(\.lastPathComponent)) == expectedNames else {
                throw StoredItemReadFailure.confirmedInvalid
            }
            let sharedURL = record.sharedURL.flatMap(URL.init(string:))
            guard record.sharedURL == nil || sharedURL != nil else {
                throw StoredItemReadFailure.confirmedInvalid
            }
            let draft = ScreenContextDraft(
                source: record.source,
                instruction: record.instruction,
                sharedText: record.sharedText,
                sharedURL: sharedURL,
                imageData: try loadImage(for: record),
                imageTypeIdentifier: record.imageTypeIdentifier
            )
            let validated: ScreenContextDraft
            do {
                validated = try Self.validated(draft)
            } catch {
                throw StoredItemReadFailure.confirmedInvalid
            }
            guard validated.imageData?.count == record.imageByteCount,
                  validated.imageTypeIdentifier == record.imageTypeIdentifier else {
                throw StoredItemReadFailure.confirmedInvalid
            }
            let intake = Self.intake(from: record, imageData: validated.imageData)
            if consumes {
                do {
                    try purgePayloads()
                } catch {
                    throw StoredItemReadFailure.transient
                }
            }
            return intake
        } catch StoredItemReadFailure.transient {
            // File protection and temporary I/O errors are retryable. Keep the exact generation
            // intact so a later foreground read can return the same intake.
            throw ScreenContextError.temporaryStorageUnavailable
        } catch StoredItemReadFailure.confirmedInvalid {
            do {
                try purgePayloads()
            } catch {
                throw ScreenContextError.temporaryStorageUnavailable
            }
            throw ScreenContextError.invalidStoredItem
        } catch let error as ScreenContextError {
            throw error
        } catch {
            throw ScreenContextError.temporaryStorageUnavailable
        }
    }

    private func loadImage(for record: StoredRecord) throws -> Data? {
        switch (record.imageFileName, record.imageByteCount, record.imageTypeIdentifier) {
        case (nil, nil, nil):
            return nil
        case let (.some(fileName), .some(expectedByteCount), .some(typeIdentifier)):
            guard fileName == "\(record.id.uuidString).image",
                  (1 ... Self.maximumImageBytes).contains(expectedByteCount),
                  Self.isValidTypeIdentifier(typeIdentifier) else {
                throw StoredItemReadFailure.confirmedInvalid
            }
            let imageURL = directory.appendingPathComponent(fileName, isDirectory: false)
            guard imageURL.deletingLastPathComponent().standardizedFileURL
                == directory.standardizedFileURL,
                  try byteCount(at: imageURL) == expectedByteCount else {
                throw StoredItemReadFailure.confirmedInvalid
            }
            let data = try readData(at: imageURL)
            guard data.count == expectedByteCount else {
                throw StoredItemReadFailure.confirmedInvalid
            }
            return data
        default:
            throw StoredItemReadFailure.confirmedInvalid
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
    }

    private func manifestURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func payloadURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.lastPathComponent != AppGroupTransactionLock.fileName }
    }

    private func purgePayloads() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for item in try payloadURLs() {
            guard item.deletingLastPathComponent().standardizedFileURL
                == directory.standardizedFileURL else { continue }
            try fileManager.removeItem(at: item)
        }
    }

    private func protectFile(at url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func byteCount(at url: URL) throws -> Int {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw storedReadFailure(for: error)
        }
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value > 0,
              size.int64Value <= Int64(Int.max) else {
            throw StoredItemReadFailure.confirmedInvalid
        }
        return size.intValue
    }

    private func readData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw storedReadFailure(for: error)
        }
    }

    private func storedReadFailure(for error: Error) -> StoredItemReadFailure {
        guard let cocoaError = error as? CocoaError else { return .transient }
        switch cocoaError.code {
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return .confirmedInvalid
        default:
            return .transient
        }
    }

    static func validated(_ draft: ScreenContextDraft) throws -> ScreenContextDraft {
        let instruction = try validatedInstruction(
            draft.instruction,
            required: draft.source != .actionButton
        )
        let sharedText = draft.sharedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let sharedText,
           sharedText.count > maximumTextCharacters || sharedText.utf8.count > maximumTextBytes {
            throw ScreenContextError.textTooLong
        }

        if let sharedURL = draft.sharedURL {
            guard sharedURL.absoluteString.utf8.count <= maximumURLBytes else {
                throw ScreenContextError.URLTooLong
            }
            guard let scheme = sharedURL.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  sharedURL.host?.isEmpty == false,
                  sharedURL.user == nil,
                  sharedURL.password == nil else {
                throw ScreenContextError.unsupportedURL
            }
        }

        var canonicalImageTypeIdentifier: String?
        if let imageData = draft.imageData {
            guard !imageData.isEmpty, imageData.count <= maximumImageBytes else {
                throw ScreenContextError.imageTooLarge
            }
            guard let typeIdentifier = draft.imageTypeIdentifier,
                  isValidTypeIdentifier(typeIdentifier) else {
                throw ScreenContextError.invalidImageMetadata
            }
            canonicalImageTypeIdentifier = try validatedImageMetadata(
                data: imageData,
                declaredTypeIdentifier: typeIdentifier,
                requiresJPEGOrPNG: draft.source == .shortcut
            ).typeIdentifier
        } else if draft.imageTypeIdentifier != nil {
            throw ScreenContextError.invalidImageMetadata
        }

        let hasText = sharedText?.isEmpty == false
        let hasContent = hasText || draft.sharedURL != nil || draft.imageData != nil
        if draft.source != .actionButton {
            guard hasContent else { throw ScreenContextError.noContent }
        }
        return ScreenContextDraft(
            source: draft.source,
            instruction: instruction,
            sharedText: hasText ? sharedText : nil,
            sharedURL: draft.sharedURL,
            imageData: draft.imageData,
            imageTypeIdentifier: canonicalImageTypeIdentifier
        )
    }

    static func validatedShortcutInstruction(_ rawValue: String) throws -> String {
        try validatedInstruction(rawValue, required: true)
    }

    /// Validates the stricter image boundary used by the screenshot-and-dictate App Intent.
    ///
    /// Shortcuts can attach arbitrary files to an `IntentFile`, so its filename and declared
    /// content type are treated only as hints. ImageIO identifies and parses the actual bytes,
    /// the type is limited to one JPEG or PNG, and pixel dimensions are bounded before the bytes
    /// enter the App Group inbox. This performs no OCR and has no network path.
    static func validatedShortcutScreenshot(
        data: Data,
        declaredTypeIdentifier: String?
    ) throws -> String {
        guard !data.isEmpty, data.count <= maximumImageBytes else {
            throw ScreenContextError.imageTooLarge
        }
        return try validatedImageMetadata(
            data: data,
            declaredTypeIdentifier: declaredTypeIdentifier,
            requiresJPEGOrPNG: true
        ).typeIdentifier
    }

    private static func validatedImageMetadata(
        data: Data,
        declaredTypeIdentifier: String?,
        requiresJPEGOrPNG: Bool
    ) throws -> BoundedImageMetadata {
        do {
            return try BoundedImageData.validate(
                data,
                declaredTypeIdentifier: declaredTypeIdentifier,
                allowedTypeIdentifiers: requiresJPEGOrPNG
                    ? BoundedImageData.JPEGAndPNGTypeIdentifiers
                    : nil,
                maximumDimension: maximumShortcutImageDimension,
                maximumPixelCount: maximumShortcutImagePixels
            )
        } catch BoundedImageValidationError.dimensionsExceeded {
            throw ScreenContextError.shortcutImageDimensionsTooLarge
        } catch BoundedImageValidationError.declaredTypeMismatch {
            throw ScreenContextError.invalidImageMetadata
        } catch BoundedImageValidationError.unsupportedType {
            throw requiresJPEGOrPNG
                ? ScreenContextError.unsupportedShortcutImage
                : ScreenContextError.invalidImageMetadata
        } catch {
            throw requiresJPEGOrPNG
                ? ScreenContextError.invalidShortcutImage
                : ScreenContextError.invalidImageMetadata
        }
    }

    private static func validatedInstruction(
        _ rawValue: String,
        required: Bool
    ) throws -> String {
        let instruction = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if required, instruction.isEmpty {
            throw ScreenContextError.instructionRequired
        }
        guard instruction.count <= maximumInstructionCharacters,
              instruction.utf8.count <= maximumInstructionBytes else {
            throw ScreenContextError.instructionTooLong
        }
        return instruction
    }

    private static func isValidTypeIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.utf8.count <= 128
            && !trimmed.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func intake(from record: StoredRecord, imageData: Data?) -> ScreenContextIntake {
        .init(
            id: record.id,
            source: record.source,
            instruction: record.instruction,
            sharedText: record.sharedText,
            sharedURL: record.sharedURL.flatMap(URL.init(string:)),
            imageData: imageData,
            imageTypeIdentifier: record.imageTypeIdentifier,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt
        )
    }
}

private struct StoredRecord: Codable, Equatable {
    let id: UUID
    let source: ScreenContextSource
    let instruction: String
    let sharedText: String?
    let sharedURL: String?
    let imageFileName: String?
    let imageByteCount: Int?
    let imageTypeIdentifier: String?
    let createdAt: Date
    let expiresAt: Date
}

private enum StoredItemReadFailure: Error {
    case confirmedInvalid
    case transient
}
