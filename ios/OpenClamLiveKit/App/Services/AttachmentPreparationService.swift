import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

struct AVFoundationAgentVideoFrameExtractor: AgentVideoFrameExtracting {
    func extractRepresentativeJPEGFrames(
        from url: URL,
        limits: AttachmentPreparationLimits
    ) async throws -> AgentVideoFrameExtraction {
        let asset = AVURLAsset(url: url)
        let durationTime: CMTime
        let videoTracks: [AVAssetTrack]
        do {
            durationTime = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw AttachmentPreparationError.invalidVideo
        }

        guard !videoTracks.isEmpty else {
            throw AttachmentPreparationError.videoHasNoVisualTrack
        }
        let duration = durationTime.seconds
        guard duration.isFinite, duration > 0 else {
            throw AttachmentPreparationError.invalidVideo
        }
        guard duration <= limits.maximumVideoDuration else {
            throw AttachmentPreparationError.videoDurationExceeded(
                maximumSeconds: Int(limits.maximumVideoDuration.rounded(.down))
            )
        }

        let frameCount = min(
            limits.maximumVideoFrameCount,
            max(1, Int(ceil(duration / 10)))
        )
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: limits.maximumImageDimension,
            height: limits.maximumImageDimension
        )

        var frames: [Data] = []
        frames.reserveCapacity(frameCount)
        for index in 0 ..< frameCount {
            try Task.checkCancellation()
            let fraction = Double(index + 1) / Double(frameCount + 1)
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            do {
                let generated = try await generator.image(at: time)
                frames.append(
                    try Self.encodeJPEG(
                        generated.image,
                        preferredQuality: limits.jpegCompressionQuality,
                        maximumBytes: limits.maximumPreparedImageBytes
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AttachmentPreparationError {
                throw error
            } catch {
                throw AttachmentPreparationError.videoFrameExtractionFailed
            }
        }

        guard !frames.isEmpty else {
            throw AttachmentPreparationError.videoFrameExtractionFailed
        }
        return .init(duration: duration, jpegFrames: frames)
    }

    private static func encodeJPEG(
        _ image: CGImage,
        preferredQuality: Double,
        maximumBytes: Int
    ) throws -> Data {
        let qualities = [
            preferredQuality,
            max(0.62, preferredQuality - 0.16),
            max(0.48, preferredQuality - 0.30),
            0.38,
        ]
        let uiImage = UIImage(cgImage: image)
        for quality in qualities {
            if let data = uiImage.jpegData(compressionQuality: quality),
               data.count <= maximumBytes {
                return data
            }
        }
        throw AttachmentPreparationError.preparedImageTooLarge(maximumBytes: maximumBytes)
    }
}

/// Owns bounded temporary copies of selected files and turns staged inputs into typed Responses
/// content parts. It never performs OCR, pronunciation analysis, audio extraction, or networking.
actor AttachmentPreparationService {
    let limits: AttachmentPreparationLimits
    let stagingDirectory: URL

    private let fileManager: FileManager
    private let videoFrameExtractor: any AgentVideoFrameExtracting

    init(
        limits: AttachmentPreparationLimits = .standard,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        videoFrameExtractor: any AgentVideoFrameExtracting = AVFoundationAgentVideoFrameExtractor()
    ) throws {
        guard limits.isValid else {
            throw AttachmentPreparationError.invalidLimits
        }
        self.limits = limits
        self.fileManager = fileManager
        self.videoFrameExtractor = videoFrameExtractor
        stagingDirectory = temporaryRoot
            .appendingPathComponent("CodexAgentAttachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw AttachmentPreparationError.temporaryFileUnavailable
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    func stageImage(
        data: Data,
        filename: String = "image.jpg",
        sourceMIMEType: String? = nil
    ) throws -> StagedAgentAttachment {
        guard !data.isEmpty else { throw AttachmentPreparationError.emptyImage }
        guard data.count <= limits.maximumImageSourceBytes else {
            throw AttachmentPreparationError.imageSourceTooLarge(
                maximumBytes: limits.maximumImageSourceBytes
            )
        }
        let metadata: BoundedImageMetadata
        do {
            metadata = try BoundedImageData.validate(
                data,
                maximumDimension: BoundedImageData.maximumInputDimension,
                maximumPixelCount: limits.maximumImagePixelCount
            )
        } catch BoundedImageValidationError.dimensionsExceeded {
            throw AttachmentPreparationError.imagePixelLimitExceeded(
                maximumPixels: limits.maximumImagePixelCount
            )
        } catch {
            throw AttachmentPreparationError.invalidImage
        }
        let detectedMIMEType = UTType(metadata.typeIdentifier)?.preferredMIMEType
        return .init(
            kind: .image,
            displayName: sanitizedFilename(filename, fallback: "image.jpg"),
            sourceByteCount: data.count,
            source: .imageData(
                data,
                sourceMIMEType: detectedMIMEType ?? normalizedMIMEType(sourceMIMEType)
            )
        )
    }

    func stageFile(
        at sourceURL: URL,
        displayName: String? = nil,
        mimeType: String? = nil
    ) throws -> StagedAgentAttachment {
        try stageExternalFile(
            at: sourceURL,
            kind: .file,
            displayName: displayName,
            declaredMIMEType: mimeType
        )
    }

    func stageVideo(
        at sourceURL: URL,
        displayName: String? = nil,
        mimeType: String? = nil
    ) throws -> StagedAgentAttachment {
        try stageExternalFile(
            at: sourceURL,
            kind: .video,
            displayName: displayName,
            declaredMIMEType: mimeType
        )
    }

    func prepare(
        _ attachments: [StagedAgentAttachment]
    ) async throws -> [PreparedAgentAttachment] {
        guard attachments.count <= limits.maximumAttachmentCount else {
            throw AttachmentPreparationError.tooManyAttachments(
                maximum: limits.maximumAttachmentCount
            )
        }
        guard Set(attachments.map(\.id)).count == attachments.count else {
            throw AttachmentPreparationError.invalidFile
        }

        var prepared: [PreparedAgentAttachment] = []
        prepared.reserveCapacity(attachments.count)
        var totalPayloadBytes = 0
        for attachment in attachments {
            try Task.checkCancellation()
            let result = try await prepare(attachment)
            let (nextTotal, overflow) = totalPayloadBytes.addingReportingOverflow(
                result.payloadByteCount
            )
            guard !overflow, nextTotal <= limits.maximumPreparedPayloadBytes else {
                throw AttachmentPreparationError.preparedPayloadTooLarge(
                    maximumBytes: limits.maximumPreparedPayloadBytes
                )
            }
            totalPayloadBytes = nextTotal
            prepared.append(result)
        }
        return prepared
    }

    func remove(_ attachment: StagedAgentAttachment) {
        guard let url = attachment.localFileURL, ownsTemporaryFile(url) else { return }
        try? fileManager.removeItem(at: url)
    }

    func remove(_ attachments: [StagedAgentAttachment]) {
        for attachment in attachments {
            remove(attachment)
        }
    }

    func removeAllTemporaryFiles() throws {
        do {
            if fileManager.fileExists(atPath: stagingDirectory.path) {
                try fileManager.removeItem(at: stagingDirectory)
            }
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw AttachmentPreparationError.temporaryFileUnavailable
        }
    }

    private func prepare(
        _ attachment: StagedAgentAttachment
    ) async throws -> PreparedAgentAttachment {
        switch (attachment.kind, attachment.source) {
        case (.image, .imageData(let data, _)):
            let jpeg = try preparedJPEG(from: data)
            return .init(
                id: attachment.id,
                kind: .image,
                displayName: attachment.displayName,
                sourceByteCount: attachment.sourceByteCount,
                payloadByteCount: jpeg.count,
                contentParts: [
                    .inputImage(
                        imageURL: dataURL(mimeType: "image/jpeg", data: jpeg),
                        detail: .auto
                    ),
                ]
            )

        case (.file, .stagedFile(let url, let mimeType)):
            guard ownsTemporaryFile(url) else {
                throw AttachmentPreparationError.invalidFile
            }
            let data: Data
            do {
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                throw AttachmentPreparationError.invalidFile
            }
            guard !data.isEmpty else { throw AttachmentPreparationError.invalidFile }
            guard data.count <= limits.maximumFileBytes else {
                throw AttachmentPreparationError.fileTooLarge(
                    maximumBytes: limits.maximumFileBytes
                )
            }
            return .init(
                id: attachment.id,
                kind: .file,
                displayName: attachment.displayName,
                sourceByteCount: attachment.sourceByteCount,
                payloadByteCount: data.count,
                contentParts: [
                    .inputFile(
                        filename: attachment.displayName,
                        fileData: dataURL(mimeType: mimeType, data: data)
                    ),
                ]
            )

        case (.video, .stagedVideo(let url, _)):
            guard ownsTemporaryFile(url) else {
                throw AttachmentPreparationError.invalidVideo
            }
            let extraction: AgentVideoFrameExtraction
            do {
                extraction = try await videoFrameExtractor.extractRepresentativeJPEGFrames(
                    from: url,
                    limits: limits
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AttachmentPreparationError {
                throw error
            } catch {
                throw AttachmentPreparationError.videoFrameExtractionFailed
            }

            guard extraction.duration.isFinite, extraction.duration > 0 else {
                throw AttachmentPreparationError.invalidVideo
            }
            guard extraction.duration <= limits.maximumVideoDuration else {
                throw AttachmentPreparationError.videoDurationExceeded(
                    maximumSeconds: Int(limits.maximumVideoDuration.rounded(.down))
                )
            }
            guard !extraction.jpegFrames.isEmpty,
                  extraction.jpegFrames.count <= limits.maximumVideoFrameCount else {
                throw AttachmentPreparationError.videoFrameExtractionFailed
            }

            var payloadByteCount = 0
            var parts: [OpenAIInputContentPart] = []
            parts.reserveCapacity(extraction.jpegFrames.count)
            for frame in extraction.jpegFrames {
                guard isJPEG(frame) else {
                    throw AttachmentPreparationError.videoFrameExtractionFailed
                }
                guard frame.count <= limits.maximumPreparedImageBytes else {
                    throw AttachmentPreparationError.preparedImageTooLarge(
                        maximumBytes: limits.maximumPreparedImageBytes
                    )
                }
                let (nextCount, overflow) = payloadByteCount.addingReportingOverflow(frame.count)
                guard !overflow else {
                    throw AttachmentPreparationError.preparedPayloadTooLarge(
                        maximumBytes: limits.maximumPreparedPayloadBytes
                    )
                }
                payloadByteCount = nextCount
                parts.append(
                    .inputImage(
                        imageURL: dataURL(mimeType: "image/jpeg", data: frame),
                        detail: .auto
                    )
                )
            }
            return .init(
                id: attachment.id,
                kind: .video,
                displayName: attachment.displayName,
                sourceByteCount: attachment.sourceByteCount,
                payloadByteCount: payloadByteCount,
                contentParts: parts
            )

        default:
            switch attachment.kind {
            case .image: throw AttachmentPreparationError.invalidImage
            case .file: throw AttachmentPreparationError.invalidFile
            case .video: throw AttachmentPreparationError.invalidVideo
            }
        }
    }

    private func preparedJPEG(from sourceData: Data) throws -> Data {
        do {
            _ = try BoundedImageData.validate(
                sourceData,
                maximumDimension: BoundedImageData.maximumInputDimension,
                maximumPixelCount: limits.maximumImagePixelCount,
                verifiesDecoding: false
            )
        } catch BoundedImageValidationError.dimensionsExceeded {
            throw AttachmentPreparationError.imagePixelLimitExceeded(
                maximumPixels: limits.maximumImagePixelCount
            )
        } catch {
            throw AttachmentPreparationError.invalidImage
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, sourceOptions) else {
            throw AttachmentPreparationError.invalidImage
        }

        let dimensions = [
            limits.maximumImageDimension,
            max(768, Int(Double(limits.maximumImageDimension) * 0.75)),
            max(640, Int(Double(limits.maximumImageDimension) * 0.50)),
        ]
        let qualities = [
            limits.jpegCompressionQuality,
            max(0.62, limits.jpegCompressionQuality - 0.16),
            max(0.48, limits.jpegCompressionQuality - 0.30),
            0.38,
        ]

        for dimension in Array(Set(dimensions)).sorted(by: >) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                continue
            }
            let uiImage = UIImage(cgImage: image)
            for quality in qualities {
                if let data = uiImage.jpegData(compressionQuality: quality),
                   data.count <= limits.maximumPreparedImageBytes {
                    return data
                }
            }
        }
        throw AttachmentPreparationError.preparedImageTooLarge(
            maximumBytes: limits.maximumPreparedImageBytes
        )
    }

    private func stageExternalFile(
        at sourceURL: URL,
        kind: AgentAttachmentKind,
        displayName: String?,
        declaredMIMEType: String?
    ) throws -> StagedAgentAttachment {
        let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try sourceURL.resourceValues(
                forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey]
            )
        } catch {
            throw kind == .video
                ? AttachmentPreparationError.invalidVideo
                : AttachmentPreparationError.invalidFile
        }
        guard resourceValues.isRegularFile != false else {
            throw kind == .video
                ? AttachmentPreparationError.invalidVideo
                : AttachmentPreparationError.invalidFile
        }

        let fileSize = resourceValues.fileSize ?? fileSizeAtPath(sourceURL)
        guard fileSize > 0 else {
            throw kind == .video
                ? AttachmentPreparationError.invalidVideo
                : AttachmentPreparationError.invalidFile
        }
        let inferredMIMEType = resourceValues.contentType?.preferredMIMEType
            ?? UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType
        guard let mimeType = normalizedMIMEType(declaredMIMEType ?? inferredMIMEType) else {
            throw AttachmentPreparationError.unsupportedFileType
        }

        switch kind {
        case .file:
            guard limits.allowedFileMIMETypes.contains(mimeType) else {
                throw AttachmentPreparationError.unsupportedFileType
            }
            guard fileSize <= limits.maximumFileBytes else {
                throw AttachmentPreparationError.fileTooLarge(
                    maximumBytes: limits.maximumFileBytes
                )
            }
        case .video:
            guard mimeType.hasPrefix("video/") else {
                throw AttachmentPreparationError.invalidVideo
            }
            guard fileSize <= limits.maximumVideoSourceBytes else {
                throw AttachmentPreparationError.videoTooLarge(
                    maximumBytes: limits.maximumVideoSourceBytes
                )
            }
        case .image:
            throw AttachmentPreparationError.invalidImage
        }

        let fallbackName = kind == .video ? "video.mov" : "attachment"
        let name = sanitizedFilename(
            displayName ?? sourceURL.lastPathComponent,
            fallback: fallbackName
        )
        let destination = stagingDirectory.appendingPathComponent(
            "\(UUID().uuidString)-\(name)",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw AttachmentPreparationError.temporaryFileUnavailable
        }

        // File-provider metadata is only a preflight hint: the selected item can change while it
        // is copied, and a provider can report stale sizes. Validate the private artifact itself
        // before exposing its URL. This is intentionally fail-closed and removes a rejected copy,
        // including one that grew beyond its kind-specific limit during the copy.
        do {
            try validateCopiedArtifact(
                at: destination,
                kind: kind,
                expectedSourceByteCount: fileSize
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        return .init(
            kind: kind,
            displayName: name,
            sourceByteCount: fileSize,
            source: kind == .video
                ? .stagedVideo(destination, mimeType: mimeType)
                : .stagedFile(destination, mimeType: mimeType)
        )
    }

    private func validateCopiedArtifact(
        at destination: URL,
        kind: AgentAttachmentKind,
        expectedSourceByteCount: Int
    ) throws {
        let invalidError: AttachmentPreparationError = kind == .video
            ? .invalidVideo
            : .invalidFile
        let copiedValues: URLResourceValues
        do {
            copiedValues = try destination.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
        } catch {
            throw invalidError
        }
        guard copiedValues.isRegularFile == true else {
            throw invalidError
        }

        let copiedByteCount = copiedValues.fileSize ?? fileSizeAtPath(destination)
        guard copiedByteCount > 0 else {
            throw invalidError
        }
        switch kind {
        case .file:
            guard copiedByteCount <= limits.maximumFileBytes else {
                throw AttachmentPreparationError.fileTooLarge(
                    maximumBytes: limits.maximumFileBytes
                )
            }
        case .video:
            guard copiedByteCount <= limits.maximumVideoSourceBytes else {
                throw AttachmentPreparationError.videoTooLarge(
                    maximumBytes: limits.maximumVideoSourceBytes
                )
            }
        case .image:
            throw AttachmentPreparationError.invalidImage
        }

        guard copiedByteCount == expectedSourceByteCount else {
            throw invalidError
        }
    }

    private func fileSizeAtPath(_ url: URL) -> Int {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else {
            return 0
        }
        return number.intValue
    }

    private func sanitizedFilename(_ value: String, fallback: String) -> String {
        let prohibited = CharacterSet.controlCharacters.union(
            CharacterSet(charactersIn: "/\\:")
        )
        let components = value.unicodeScalars.map { scalar in
            prohibited.contains(scalar) ? "_" : String(scalar)
        }
        let sanitized = components.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = sanitized.isEmpty ? fallback : sanitized
        var bounded = ""
        bounded.reserveCapacity(min(candidate.count, 120))
        for character in candidate {
            let next = String(character)
            guard bounded.utf8.count + next.utf8.count <= 120 else { break }
            bounded.append(character)
        }
        return bounded.isEmpty ? fallback : bounded
    }

    private func normalizedMIMEType(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("/"),
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return normalized
    }

    private func dataURL(mimeType: String, data: Data) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private func isJPEG(_ data: Data) -> Bool {
        guard data.count >= 4,
              data[data.startIndex] == 0xFF,
              data[data.index(after: data.startIndex)] == 0xD8,
              data[data.index(data.endIndex, offsetBy: -2)] == 0xFF,
              data[data.index(before: data.endIndex)] == 0xD9 else {
            return false
        }
        return (try? BoundedImageData.validate(
            data,
            allowedTypeIdentifiers: [UTType.jpeg.identifier],
            maximumDimension: limits.maximumImageDimension,
            maximumPixelCount: limits.maximumImagePixelCount
        )) != nil
    }

    private func ownsTemporaryFile(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        let parent = candidate.deletingLastPathComponent()
        let expectedParent = stagingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        return parent == expectedParent
    }
}
