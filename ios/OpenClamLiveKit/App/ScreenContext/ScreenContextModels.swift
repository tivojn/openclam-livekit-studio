import Foundation

extension Notification.Name {
    static let pendingScreenContextDidChange = Notification.Name(
        "CodexCompanion.pendingScreenContextDidChange"
    )
}

enum ScreenContextSource: String, Codable, Equatable, Sendable {
    /// Opens the intake UI; it never represents a captured third-party screen.
    case actionButton
    /// Content the person explicitly passed through a host app's Share sheet.
    case shareExtension
    /// A screenshot the person explicitly chose in OpenClam.
    case selectedScreenshot
    /// Text or a URL explicitly passed from a user-created Shortcut.
    case shortcut
    /// Frames selected through the iOS 27 ScreenCaptureKit system picker.
    case systemScreenPicker
}

struct ScreenContextDraft: Equatable, Sendable {
    let source: ScreenContextSource
    let instruction: String
    let sharedText: String?
    let sharedURL: URL?
    let imageData: Data?
    let imageTypeIdentifier: String?

    init(
        source: ScreenContextSource,
        instruction: String = "",
        sharedText: String? = nil,
        sharedURL: URL? = nil,
        imageData: Data? = nil,
        imageTypeIdentifier: String? = nil
    ) {
        self.source = source
        self.instruction = instruction
        self.sharedText = sharedText
        self.sharedURL = sharedURL
        self.imageData = imageData
        self.imageTypeIdentifier = imageTypeIdentifier
    }
}

struct ScreenContextIntake: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: ScreenContextSource
    let instruction: String
    let sharedText: String?
    let sharedURL: URL?
    let imageData: Data?
    let imageTypeIdentifier: String?
    let createdAt: Date
    let expiresAt: Date
}

struct ScreenContextReview: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: ScreenContextSource
    let originalInstruction: String
    let sharedText: String?
    let sharedURL: URL?
    let imageData: Data?
    let imageTypeIdentifier: String?
    let createdAt: Date
    let expiresAt: Date
    var locallyExtractedText: String?
    var extractionWasTruncated: Bool

    init(intake: ScreenContextIntake) {
        id = intake.id
        source = intake.source
        originalInstruction = intake.instruction
        sharedText = intake.sharedText
        sharedURL = intake.sharedURL
        imageData = intake.imageData
        imageTypeIdentifier = intake.imageTypeIdentifier
        createdAt = intake.createdAt
        expiresAt = intake.expiresAt
        locallyExtractedText = nil
        extractionWasTruncated = false
    }
}

/// Exact, user-confirmed context for one subsequent request. Creating this value performs no
/// networking; the caller must route it through the existing explicit attachment/text send path.
struct ScreenContextSubmission: Equatable, Sendable {
    let reviewID: UUID
    let instruction: String
    let includedText: String?
    let includedURL: URL?
    let includedImageData: Data?
    let includedImageTypeIdentifier: String?
}

enum ScreenContextError: Error, Equatable, LocalizedError {
    case appGroupUnavailable
    case noContent
    case instructionRequired
    case instructionTooLong
    case textTooLong
    case URLTooLong
    case unsupportedURL
    case imageTooLarge
    case invalidImageMetadata
    case unsupportedShortcutImage
    case invalidShortcutImage
    case shortcutImageDimensionsTooLarge
    case temporaryStorageUnavailable
    case invalidStoredItem
    case noPendingIntake
    case noSelectedImage
    case OCRAlreadyRequested
    case noIncludedContext

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The shared Screen Context container isn't configured for this build."
        case .noContent:
            "Share text, a web link, or one image."
        case .instructionRequired:
            "Say what OpenClam should do with this context."
        case .instructionTooLong:
            "The instruction is longer than the 2,000-character limit."
        case .textTooLong:
            "The shared text is longer than the 8,000-character limit."
        case .URLTooLong:
            "The shared URL is longer than the 2,048-byte limit."
        case .unsupportedURL:
            "Only an HTTP or HTTPS page can be included as shared context."
        case .imageTooLarge:
            "The selected image is larger than the 15 MB intake limit."
        case .invalidImageMetadata:
            "The selected image metadata isn't valid."
        case .unsupportedShortcutImage:
            "The screenshot must be one JPEG or PNG image."
        case .invalidShortcutImage:
            "The screenshot could not be read as a valid image."
        case .shortcutImageDimensionsTooLarge:
            "The screenshot dimensions are larger than the safe intake limit."
        case .temporaryStorageUnavailable:
            "The shared context could not be stored securely."
        case .invalidStoredItem:
            "The pending shared context was invalid or changed and was discarded."
        case .noPendingIntake:
            "There is no pending screen context to review."
        case .noSelectedImage:
            "Choose an image before requesting local text extraction."
        case .OCRAlreadyRequested:
            "Text was already extracted from this image."
        case .noIncludedContext:
            "Choose at least one context item for this request."
        }
    }
}
