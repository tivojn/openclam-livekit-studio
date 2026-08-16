import Foundation

enum AgentAttachmentKind: String, Equatable, Sendable {
    case image
    case file
    case video
}

enum OpenAIImageDetail: String, Encodable, Equatable, Sendable {
    case auto
    case low
    case high
}

/// A typed content part accepted by a Responses API input message.
///
/// Attachment preparation is responsible for producing bounded data URLs. Keeping the encoded
/// representation here lets conversation integration combine text and prepared attachments
/// without teaching the UI about request JSON.
enum OpenAIInputContentPart: Encodable, Equatable, Sendable {
    case inputText(String)
    case inputImage(imageURL: String, detail: OpenAIImageDetail)
    case inputFile(filename: String, fileData: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
        case detail
        case filename
        case fileData = "file_data"
    }

    static func inputImage(imageURL: String) -> Self {
        .inputImage(imageURL: imageURL, detail: .auto)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inputText(let text):
            try container.encode("input_text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .inputImage(let imageURL, let detail):
            try container.encode("input_image", forKey: .type)
            try container.encode(imageURL, forKey: .imageURL)
            try container.encode(detail, forKey: .detail)
        case .inputFile(let filename, let fileData):
            try container.encode("input_file", forKey: .type)
            try container.encode(filename, forKey: .filename)
            try container.encode(fileData, forKey: .fileData)
        }
    }

    var validationFailure: String? {
        switch self {
        case .inputText(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "An input_text content part cannot be empty."
                : nil
        case .inputImage(let imageURL, _):
            guard Self.isValidImageURL(imageURL) else {
                return "An input_image content part needs an HTTPS URL or a base64 image data URL."
            }
            return nil
        case .inputFile(let filename, let fileData):
            guard Self.isValidFilename(filename) else {
                return "An input_file content part needs a valid filename."
            }
            guard Self.isValidBase64DataURL(fileData, requiredMIMEPrefix: nil) else {
                return "An input_file content part needs base64 file data."
            }
            return nil
        }
    }

    private static func isValidImageURL(_ value: String) -> Bool {
        if isValidBase64DataURL(value, requiredMIMEPrefix: "image/") {
            return true
        }
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }

    private static func isValidFilename(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 255,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        return true
    }

    private static func isValidBase64DataURL(
        _ value: String,
        requiredMIMEPrefix: String?
    ) -> Bool {
        guard value.hasPrefix("data:"),
              let comma = value.firstIndex(of: ",") else {
            return false
        }

        let headerStart = value.index(value.startIndex, offsetBy: 5)
        let header = String(value[headerStart ..< comma]).lowercased()
        guard header.hasSuffix(";base64") else { return false }
        let mimeType = String(header.dropLast(";base64".count))
        guard mimeType.contains("/"),
              !mimeType.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }
        if let requiredMIMEPrefix, !mimeType.hasPrefix(requiredMIMEPrefix) {
            return false
        }

        let payload = value[value.index(after: comma)...]
        guard !payload.isEmpty, payload.utf8.count.isMultiple(of: 4) else { return false }
        return payload.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 43, 47, 48 ... 57, 61, 65 ... 90, 97 ... 122:
                return true
            default:
                return false
            }
        }
    }
}

enum AgentAttachmentSource: Equatable, Sendable {
    case imageData(Data, sourceMIMEType: String?)
    case stagedFile(URL, mimeType: String)
    case stagedVideo(URL, mimeType: String)
}

/// A locally staged attachment. File and video URLs always point inside the preparation
/// service's private temporary directory; callers remove them through that service.
struct StagedAgentAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: AgentAttachmentKind
    let displayName: String
    let sourceByteCount: Int
    let source: AgentAttachmentSource

    init(
        id: UUID = UUID(),
        kind: AgentAttachmentKind,
        displayName: String,
        sourceByteCount: Int,
        source: AgentAttachmentSource
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.sourceByteCount = sourceByteCount
        self.source = source
    }

    var localFileURL: URL? {
        switch source {
        case .imageData:
            return nil
        case .stagedFile(let url, _), .stagedVideo(let url, _):
            return url
        }
    }
}

/// The bounded, request-ready representation of one user-selected attachment. A video becomes
/// several representative JPEG image parts and never contributes an audio part.
struct PreparedAgentAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: AgentAttachmentKind
    let displayName: String
    let sourceByteCount: Int
    let payloadByteCount: Int
    let contentParts: [OpenAIInputContentPart]
}

struct AttachmentPreparationLimits: Equatable, Sendable {
    static let standard = AttachmentPreparationLimits()

    var maximumAttachmentCount = 4
    var maximumImageSourceBytes = 15_000_000
    var maximumImagePixelCount = 40_000_000
    var maximumImageDimension = 2_048
    var maximumPreparedImageBytes = 1_000_000
    var jpegCompressionQuality = 0.82
    var maximumFileBytes = 4_000_000
    var maximumVideoSourceBytes = 80_000_000
    var maximumVideoDuration: TimeInterval = 60
    var maximumVideoFrameCount = 3
    var maximumPreparedPayloadBytes = 5_000_000
    var allowedFileMIMETypes: Set<String> = [
        "application/json",
        "application/pdf",
        "application/rtf",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "text/csv",
        "text/markdown",
        "text/plain",
    ]

    var isValid: Bool {
        (1 ... 8).contains(maximumAttachmentCount)
            && (1_000_000 ... 30_000_000).contains(maximumImageSourceBytes)
            && (1_000_000 ... 80_000_000).contains(maximumImagePixelCount)
            && (512 ... 4_096).contains(maximumImageDimension)
            && (100_000 ... 2_000_000).contains(maximumPreparedImageBytes)
            && (0.35 ... 0.95).contains(jpegCompressionQuality)
            && (100_000 ... 8_000_000).contains(maximumFileBytes)
            && (1_000_000 ... 200_000_000).contains(maximumVideoSourceBytes)
            && (1 ... 300).contains(maximumVideoDuration)
            && (1 ... 6).contains(maximumVideoFrameCount)
            && (maximumPreparedImageBytes ... 7_000_000).contains(maximumPreparedPayloadBytes)
            && !allowedFileMIMETypes.isEmpty
    }
}

struct AgentVideoFrameExtraction: Equatable, Sendable {
    let duration: TimeInterval
    let jpegFrames: [Data]
}

protocol AgentVideoFrameExtracting: Sendable {
    func extractRepresentativeJPEGFrames(
        from url: URL,
        limits: AttachmentPreparationLimits
    ) async throws -> AgentVideoFrameExtraction
}

enum AttachmentPreparationError: Error, Equatable {
    case invalidLimits
    case tooManyAttachments(maximum: Int)
    case emptyImage
    case imageSourceTooLarge(maximumBytes: Int)
    case invalidImage
    case imagePixelLimitExceeded(maximumPixels: Int)
    case preparedImageTooLarge(maximumBytes: Int)
    case invalidFile
    case unsupportedFileType
    case fileTooLarge(maximumBytes: Int)
    case invalidVideo
    case videoTooLarge(maximumBytes: Int)
    case videoDurationExceeded(maximumSeconds: Int)
    case videoHasNoVisualTrack
    case videoFrameExtractionFailed
    case preparedPayloadTooLarge(maximumBytes: Int)
    case temporaryFileUnavailable
}

extension AttachmentPreparationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidLimits:
            return "The attachment safety limits are invalid."
        case .tooManyAttachments(let maximum):
            return "Choose no more than \(maximum) attachments."
        case .emptyImage, .invalidImage:
            return "That image could not be prepared."
        case .imageSourceTooLarge(let maximumBytes):
            return "That image is larger than the \(maximumBytes) byte source limit."
        case .imagePixelLimitExceeded(let maximumPixels):
            return "That image exceeds the \(maximumPixels) pixel safety limit."
        case .preparedImageTooLarge(let maximumBytes):
            return "That image could not be reduced below \(maximumBytes) bytes."
        case .invalidFile:
            return "That file could not be prepared."
        case .unsupportedFileType:
            return "That file type is not supported for AI input."
        case .fileTooLarge(let maximumBytes):
            return "That file is larger than the \(maximumBytes) byte limit."
        case .invalidVideo:
            return "That video could not be prepared."
        case .videoTooLarge(let maximumBytes):
            return "That video is larger than the \(maximumBytes) byte source limit."
        case .videoDurationExceeded(let maximumSeconds):
            return "Choose a video no longer than \(maximumSeconds) seconds."
        case .videoHasNoVisualTrack:
            return "That file does not contain a readable video track."
        case .videoFrameExtractionFailed:
            return "Representative frames could not be extracted from that video."
        case .preparedPayloadTooLarge(let maximumBytes):
            return "The prepared attachments exceed the \(maximumBytes) byte request limit."
        case .temporaryFileUnavailable:
            return "A temporary attachment file could not be created."
        }
    }
}
