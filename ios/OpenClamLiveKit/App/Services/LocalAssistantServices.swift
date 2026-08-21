import AVFoundation
import Contacts
import Foundation
import ImageIO
import MapKit
import NaturalLanguage
import Speech
import UniformTypeIdentifiers
import Vision

enum LocalAssistantServiceError: LocalizedError, Equatable {
    case invalidImage
    case noText
    case speechUnavailable
    case appleSpeechLocaleUnavailable
    case appleSpeechServiceUnavailable
    case speechPermissionDenied
    case microphonePermissionDenied
    case noSpeechRecognized
    case cloudSpeechCredentialMissing
    case cloudSpeechAdapterUnavailable
    case credentialStoreUnavailable
    case speechConfigurationChanged
    case contactsPermissionDenied

    var errorDescription: String? {
        switch self {
        case .invalidImage: "That image could not be read. Try a different screenshot."
        case .noText: "No readable text was found in that screenshot."
        case .speechUnavailable: "Speech recognition is unavailable right now."
        case .appleSpeechLocaleUnavailable:
            "Apple Speech does not support the selected language on this iPhone. Choose another recognition language or a cloud speech provider in Settings."
        case .appleSpeechServiceUnavailable:
            "Apple Speech is temporarily unavailable. Check your connection and try again, or choose a cloud speech provider in Settings."
        case .speechPermissionDenied: "Speech Recognition access is off. You can enable it in Settings."
        case .microphonePermissionDenied: "Microphone access is off. You can enable it in Settings."
        case .noSpeechRecognized:
            "I didn’t catch any speech. Tap the microphone, speak, then tap Stop to send."
        case .cloudSpeechCredentialMissing:
            "Add and validate this speech provider's API key in Settings before recording."
        case .cloudSpeechAdapterUnavailable:
            "The selected speech provider is not available in this build. Choose another provider in Settings."
        case .credentialStoreUnavailable:
            "OpenClam could not read the saved speech credential. Unlock the iPhone and try again."
        case .speechConfigurationChanged:
            "Speech settings changed while dictation was starting. Tap the microphone again."
        case .contactsPermissionDenied: "Contacts access is unavailable. You can still type a phone number into the draft."
        }
    }
}

enum ScreenshotOCRService {
    static let maximumImageBytes = 15_000_000
    static let maximumImageDimension = 12_000
    static let maximumImagePixels = 40_000_000

    struct ValidatedImage {
        let cgImage: CGImage
        let orientation: CGImagePropertyOrientation
    }

    static func recognizeText(in data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let image = try validatedImage(in: data)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(
                cgImage: image.cgImage,
                orientation: image.orientation
            )
            try handler.perform([request])

            let lines = (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LocalAssistantServiceError.noText }
            return text
        }.value
    }

    /// Parses only bounded, single-frame raster images. The ImageIO source and final image are
    /// explicitly cache-disabled, and dimensions are checked before ImageIO can create a CGImage.
    static func validatedImage(in data: Data) throws -> ValidatedImage {
        guard !data.isEmpty, data.count <= maximumImageBytes else {
            throw LocalAssistantServiceError.invalidImage
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) == 1,
              let rawType = CGImageSourceGetType(source),
              let type = UTType(rawType as String),
              isSupportedRasterType(type),
              let rawProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions),
              let properties = rawProperties as? [CFString: Any],
              let width = positiveInteger(properties[kCGImagePropertyPixelWidth]),
              let height = positiveInteger(properties[kCGImagePropertyPixelHeight]),
              width <= maximumImageDimension,
              height <= maximumImageDimension,
              width <= maximumImagePixels / height else {
            throw LocalAssistantServiceError.invalidImage
        }

        let imageOptions = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, imageOptions),
              cgImage.width > 0,
              cgImage.height > 0,
              cgImage.width <= maximumImageDimension,
              cgImage.height <= maximumImageDimension,
              cgImage.width <= maximumImagePixels / cgImage.height else {
            throw LocalAssistantServiceError.invalidImage
        }

        let orientationValue = positiveInteger(properties[kCGImagePropertyOrientation]) ?? 1
        return ValidatedImage(
            cgImage: cgImage,
            orientation: CGImagePropertyOrientation(rawValue: UInt32(orientationValue)) ?? .up
        )
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              number.int64Value > 0,
              number.int64Value <= Int64(Int.max) else { return nil }
        return number.intValue
    }

    private static func isSupportedRasterType(_ type: UTType) -> Bool {
        [UTType.jpeg, .png, .heic, .heif, .tiff, .bmp, .gif, .webP]
            .contains { type.conforms(to: $0) }
    }
}

enum PronunciationService {
    static func analyze(_ rawText: String) -> PronunciationResult {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = NLLanguageRecognizer.dominantLanguage(for: text)
        let languageCode = language?.rawValue
        let languageName = languageCode.flatMap {
            Locale.current.localizedString(forLanguageCode: $0)
        } ?? "an uncertain language"

        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let transliterated = (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
        let approximation = transliterated.isEmpty ? text : transliterated

        return .init(
            text: text,
            languageCode: languageCode,
            languageName: languageName,
            approximation: approximation
        )
    }
}

struct VenueSearchOutcome {
    let candidates: [VenueCandidate]
    let targetedCount: Int
    let nameMatchCount: Int
    let usedFallback: Bool
    let fallbackLookupFailed: Bool
}

enum MapSearchService {
    static func restaurants(cuisine: String?, location: String?) async throws -> VenueSearchOutcome {
        try await restaurants(cuisine: cuisine, location: location, searchProvider: search)
    }

    static func restaurants(
        cuisine: String?,
        location: String?,
        searchProvider: (String) async throws -> [MKMapItem]
    ) async throws -> VenueSearchOutcome {
        let cuisineText = cuisine?.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationText = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetedQuery = [cuisineText, "restaurant", locationText.map { "in \($0)" }]
            .compactMap { $0 }
            .joined(separator: " ")

        let targetedItems = try await searchProvider(targetedQuery)
        let cuisineNeedle = normalized(cuisineText ?? "")
        var candidates = targetedItems.map { item in
            venue(
                from: item,
                kind: !cuisineNeedle.isEmpty && normalized(item.name ?? "").contains(cuisineNeedle)
                    ? .nameMatch
                    : .targetedUnverified
            )
        }

        let nameMatchCount = candidates.filter { $0.matchKind == .nameMatch }.count
        var usedFallback = false
        var fallbackLookupFailed = false
        if nameMatchCount == 0 {
            var existing = Set(candidates.map(\.id))

            for relatedCuisine in relatedCuisineQueries(for: cuisineText) {
                let query = [relatedCuisine, "restaurant", locationText.map { "in \($0)" }]
                    .compactMap { $0 }
                    .joined(separator: " ")
                do {
                    let relatedItems = try await searchProvider(query)
                    let related = relatedItems
                        .map { venue(from: $0, kind: .relatedQueryUnverified) }
                        .filter { !existing.contains($0.id) }
                    candidates.append(contentsOf: related)
                    existing.formUnion(related.map(\.id))
                    usedFallback = usedFallback || !related.isEmpty
                } catch {
                    fallbackLookupFailed = true
                }
            }

            if candidates.isEmpty {
                let fallbackQuery = ["restaurant", locationText.map { "in \($0)" }]
                    .compactMap { $0 }
                    .joined(separator: " ")
                let fallbackItems = try await searchProvider(fallbackQuery)
                let fallbacks = fallbackItems
                    .map { venue(from: $0, kind: .nearbyFallback) }
                    .filter { !existing.contains($0.id) }
                candidates.append(contentsOf: fallbacks)
                usedFallback = usedFallback || !fallbacks.isEmpty
            }
        }

        let ranked = candidates.sorted { left, right in
            left.matchKind.searchPriority < right.matchKind.searchPriority
        }
        return .init(
            candidates: Array(ranked.prefix(6)),
            targetedCount: targetedItems.count,
            nameMatchCount: nameMatchCount,
            usedFallback: usedFallback,
            fallbackLookupFailed: fallbackLookupFailed
        )
    }

    static func destination(_ query: String) async throws -> RideDestination? {
        guard let item = try await search(query).first else { return nil }
        let coordinate = item.placemark.coordinate
        return .init(
            id: identifier(for: item),
            name: item.name ?? query,
            address: address(for: item),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    static func relatedCuisineQueries(for cuisine: String?) -> [String] {
        let value = (cuisine ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        switch value {
        case "icelandic", "faroese", "greenlandic":
            return ["Nordic", "Scandinavian"]
        default:
            return []
        }
    }

    private static func search(_ query: String) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        return try await MKLocalSearch(request: request).start().mapItems
    }

    private static func venue(from item: MKMapItem, kind: VenueCandidate.MatchKind) -> VenueCandidate {
        let coordinate = item.placemark.coordinate
        return .init(
            id: identifier(for: item),
            name: item.name ?? "Unnamed Maps result",
            address: address(for: item),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            matchKind: kind
        )
    }

    private static func identifier(for item: MKMapItem) -> String {
        let coordinate = item.placemark.coordinate
        return "\(item.name ?? "place")|\(coordinate.latitude)|\(coordinate.longitude)"
    }

    private static func address(for item: MKMapItem) -> String {
        let title = item.placemark.title ?? ""
        guard let name = item.name, title.hasPrefix(name + ", ") else { return title }
        return String(title.dropFirst(name.count + 2))
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

}

enum ContactPhoneResolver {
    static func resolve(name: String) async throws -> [ContactPhoneCandidate] {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined, try await !store.requestAccess(for: .contacts) {
            throw LocalAssistantServiceError.contactsPermissionDenied
        }
        let current = CNContactStore.authorizationStatus(for: .contacts)
        let hasAccess: Bool
        if #available(iOS 18.0, *), current == .limited {
            hasAccess = true
        } else {
            hasAccess = current == .authorized
        }
        guard hasAccess else {
            throw LocalAssistantServiceError.contactsPermissionDenied
        }

        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let contacts = try store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: name),
            keysToFetch: keys
        )

        return contacts.flatMap { contact in
            let displayName = CNContactFormatter.string(from: contact, style: .fullName) ?? name
            return contact.phoneNumbers.map { labeled in
                let label = labeled.label.map(CNLabeledValue<NSString>.localizedString(forLabel:)) ?? "Phone"
                let number = labeled.value.stringValue
                return ContactPhoneCandidate(
                    id: "\(contact.identifier)|\(number)",
                    displayName: displayName,
                    label: label,
                    phoneNumber: number
                )
            }
        }
    }

    static func isExactNameMatch(query: String, displayName: String) -> Bool {
        normalizedName(query) == normalizedName(displayName)
    }

    private static func normalizedName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// Removes only abandoned cloud-dictation files owned by this app. The instance is process-scoped:
/// a later SwiftUI/controller recreation cannot mistake the current recording for a launch orphan.
final class CloudDictationTemporaryFileScrubber: @unchecked Sendable {
    static let fileNamePrefix = "CodexCloudDictation-"
    static let fileNameSuffix = ".wav"
    static let uploadFilename = "openclam-dictation.wav"
    static let uploadMIMEType = "audio/wav"
    static let maximumRecordingDuration: TimeInterval = 60
    static let maximumFilesToRemove = 64
    static let recordingFileProtection = FileProtectionType.complete

    static func recorderSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private let lock = NSLock()
    private var didScrub = false

    func scrubOnce(in directory: URL, fileManager: FileManager = .default) {
        lock.lock()
        guard !didScrub else {
            lock.unlock()
            return
        }
        didScrub = true
        lock.unlock()

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var removalAttempts = 0
        for candidate in contents {
            guard removalAttempts < Self.maximumFilesToRemove else { break }
            guard Self.isOwnedRecording(candidate, directlyIn: directory) else { continue }
            guard let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            removalAttempts += 1
            try? fileManager.removeItem(at: candidate)
        }
    }

    static func recordingURL(in directory: URL, id: UUID = UUID()) -> URL {
        directory.appendingPathComponent(
            "\(fileNamePrefix)\(id.uuidString)\(fileNameSuffix)",
            isDirectory: false
        )
    }

    static func protectRecording(at url: URL, fileManager: FileManager = .default) throws {
        try fileManager.setAttributes(
            [.protectionKey: recordingFileProtection],
            ofItemAtPath: url.path
        )
    }

    private static func isOwnedRecording(_ candidate: URL, directlyIn directory: URL) -> Bool {
        guard candidate.deletingLastPathComponent().standardizedFileURL
            == directory.standardizedFileURL else { return false }
        let name = candidate.lastPathComponent
        guard name.hasPrefix(fileNamePrefix), name.hasSuffix(fileNameSuffix) else { return false }
        let start = name.index(name.startIndex, offsetBy: fileNamePrefix.count)
        let end = name.index(name.endIndex, offsetBy: -fileNameSuffix.count)
        guard start < end else { return false }
        return UUID(uuidString: String(name[start ..< end])) != nil
    }
}

/// Shares the first cloud-recording finalization operation with every later trigger. A manual
/// stop and `AVAudioRecorder`'s duration-limit callback may arrive in either order; both must
/// observe one upload and the same result instead of racing to consume the temporary URL.
@MainActor
final class CloudRecordingFinalizationCoordinator {
    enum Phase: Equatable {
        case idle
        case finalizingOrFinished
    }

    private var sharedTask: Task<String, Never>?

    var phase: Phase {
        sharedTask == nil ? .idle : .finalizingOrFinished
    }

    func task(
        starting operation: @escaping @MainActor () async -> String
    ) -> Task<String, Never> {
        if let sharedTask { return sharedTask }
        let task = Task { @MainActor in await operation() }
        sharedTask = task
        return task
    }

    func existingTask() -> Task<String, Never>? {
        sharedTask
    }

    func reset(cancelExisting: Bool) {
        if cancelExisting {
            sharedTask?.cancel()
        }
        sharedTask = nil
    }
}

/// Keeps the recorder open for a few final microphone buffers after the user taps Stop. This
/// captures only the natural end of the utterance; it never appends synthetic silence or audio.
@MainActor
enum CloudRecordingManualStopTailCapture {
    static let graceNanoseconds: UInt64 = 320_000_000

    static func waitThenStop(
        stop: @MainActor () -> Void
    ) async -> Bool {
        await waitThenStop(
            sleep: { try await Task.sleep(nanoseconds: $0) },
            stop: stop
        )
    }

    static func waitThenStop(
        sleep: @MainActor (UInt64) async throws -> Void,
        stop: @MainActor () -> Void
    ) async -> Bool {
        do {
            try await sleep(graceNanoseconds)
        } catch {
            stop()
            return false
        }
        stop()
        return !Task.isCancelled
    }
}

/// Keeps partial and finalized Apple Speech segments stable across recognizer restarts.
/// Apple may finalize a short segment while the user is still holding the mic; that is a segment
/// boundary, not permission for the app to end a user-controlled recording.
struct AppleDictationTranscriptState: Equatable {
    enum FinalResultAction: Equatable {
        case none
        case restartRecognition
        case finishRequestedStop
    }

    private(set) var committedSegments: [String] = []
    private(set) var partialSegment = ""
    private(set) var stopRequested = false

    var text: String {
        (committedSegments + (partialSegment.isEmpty ? [] : [partialSegment]))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func requestStop() {
        stopRequested = true
    }

    mutating func receive(_ rawText: String, isFinal: Bool) -> FinalResultAction {
        partialSegment = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFinal else { return .none }

        if !partialSegment.isEmpty, committedSegments.last != partialSegment {
            committedSegments.append(partialSegment)
        }
        partialSegment = ""
        return stopRequested ? .finishRequestedStop : .restartRecognition
    }
}

private final class AppleSpeechAudioBufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func replaceRequest(with request: SFSpeechAudioBufferRecognitionRequest) {
        lock.withLock { self.request = request }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }

    func endAudioAndClear() {
        let previous = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            defer { request = nil }
            return request
        }
        previous?.endAudio()
    }
}

/// A finite bridge from the real-time audio callback to the serial WebSocket sender. Overflow is
/// terminal and visible: silently dropping old or new PCM would produce a plausible but corrupted
/// transcript, so the stream is closed and the owner is told to cancel the recognition session.
final class BoundedRealtimePCMStreamSink: @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let onOverflow: @Sendable () -> Void
    private let lock = NSLock()
    private var hasReportedOverflow = false

    init(
        continuation: AsyncStream<Data>.Continuation,
        onOverflow: @escaping @Sendable () -> Void
    ) {
        self.continuation = continuation
        self.onOverflow = onOverflow
    }

    @discardableResult
    func enqueue(_ data: Data) -> Bool {
        switch continuation.yield(data) {
        case .enqueued:
            return true
        case .dropped:
            reportOverflowOnce()
            return false
        case .terminated:
            return false
        @unknown default:
            reportOverflowOnce()
            return false
        }
    }

    func finish() {
        continuation.finish()
    }

    private func reportOverflowOnce() {
        let shouldReport = lock.withLock {
            guard !hasReportedOverflow else { return false }
            hasReportedOverflow = true
            return true
        }
        guard shouldReport else { return }
        continuation.finish()
        onOverflow()
    }
}

/// Converts the device microphone's native format to the raw 16 kHz mono PCM format declared by
/// the real-time speech services. It is owned and called only by one AVAudioEngine tap.
private final class RealtimeSpeechPCMConverter: @unchecked Sendable {
    private static let sampleRate = 16_000.0
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: Self.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func convert(_ input: AVAudioPCMBuffer) -> Data? {
        let ratio = Self.sampleRate / input.format.sampleRate
        let estimatedFrames = max(1, Int(ceil(Double(input.frameLength) * ratio)) + 32)
        guard estimatedFrames <= Int(UInt32.max),
              let output = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(estimatedFrames)
              ) else {
            return nil
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil,
              status != .error,
              output.frameLength > 0,
              let samples = output.int16ChannelData?.pointee else {
            return nil
        }
        return Data(
            bytes: samples,
            count: Int(output.frameLength) * MemoryLayout<Int16>.size
        )
    }
}

@MainActor
final class SpeechInputAudioSessionOwnership {
    private var isClaimed = false
    private let deactivateAudioSession: @MainActor () -> Void

    init(deactivateAudioSession: @escaping @MainActor () -> Void) {
        self.deactivateAudioSession = deactivateAudioSession
    }

    func claim() {
        isClaimed = true
    }

    @discardableResult
    func releaseIfNeeded() -> Bool {
        guard isClaimed else { return false }
        isClaimed = false
        deactivateAudioSession()
        return true
    }
}

enum SpeechInputCaptureRoute: Equatable, Sendable {
    case none
    case apple
    case realtime(AIServiceSelection)
    case cloudRecording(AIServiceSelection)
}

struct SpeechInputCaptureRouteState: Equatable, Sendable {
    private(set) var active: SpeechInputCaptureRoute = .none

    mutating func begin(_ route: SpeechInputCaptureRoute) {
        active = route
    }

    mutating func end() {
        active = .none
    }
}

struct SpeechInputCompletion: Equatable, Sendable {
    let transcript: String
    let errorMessage: String?

    static func resolve(
        _ rawTranscript: String,
        existingError: String?
    ) -> SpeechInputCompletion {
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return .init(
                transcript: "",
                errorMessage: existingError
                    ?? LocalAssistantServiceError.noSpeechRecognized.localizedDescription
            )
        }
        return .init(transcript: transcript, errorMessage: existingError)
    }
}

private final class SpeechInputOperationError: @unchecked Sendable {
    let underlying: Error

    init(_ underlying: Error) {
        self.underlying = underlying
    }
}

private enum SpeechInputRealtimeRaceOutcome: Sendable {
    case completed
    case failed(SpeechInputOperationError)
    case timedOut
    case cancelled
}

struct AppleSpeechRecognitionAvailabilitySnapshot: Equatable, Sendable {
    let isAvailable: Bool
    let supportsOnDeviceRecognition: Bool
}

enum AppleSpeechRecognitionAvailabilityOutcome: Equatable, Sendable {
    case available(requiresOnDeviceRecognition: Bool)
    case unavailable
    case cancelled
}

enum AppleSpeechRecognitionAvailabilityWaiter {
    static let defaultMaximumChecks = 6
    static let defaultRetryDelayNanoseconds: UInt64 = 250_000_000

    @MainActor
    static func wait(
        maximumChecks: Int = defaultMaximumChecks,
        retryDelayNanoseconds: UInt64 = defaultRetryDelayNanoseconds,
        snapshot: @escaping @MainActor () -> AppleSpeechRecognitionAvailabilitySnapshot,
        isCancelled: @escaping @MainActor () -> Bool = { Task.isCancelled },
        sleep: @escaping @MainActor (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) async -> AppleSpeechRecognitionAvailabilityOutcome {
        let boundedMaximumChecks = max(1, maximumChecks)
        for checkIndex in 0..<boundedMaximumChecks {
            guard !Task.isCancelled, !isCancelled() else { return .cancelled }

            let current = snapshot()
            if current.isAvailable {
                return .available(
                    requiresOnDeviceRecognition: current.supportsOnDeviceRecognition
                )
            }

            guard checkIndex + 1 < boundedMaximumChecks else { return .unavailable }
            do {
                try await sleep(retryDelayNanoseconds)
            } catch {
                return .cancelled
            }
        }
        return .unavailable
    }
}

enum AppleSpeechRecognitionTaskGate {
    static func startIfAvailable<Task>(
        snapshot: AppleSpeechRecognitionAvailabilitySnapshot,
        onUnavailable: () -> Void = {},
        start: (_ requiresOnDeviceRecognition: Bool) -> Task
    ) -> Task? {
        guard snapshot.isAvailable else {
            onUnavailable()
            return nil
        }
        return start(snapshot.supportsOnDeviceRecognition)
    }
}

@MainActor
final class SpeechInputController: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate {
    @Published private(set) var isListening = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let appleAudioSink = AppleSpeechAudioBufferSink()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionSegmentID = 0
    private var appleTranscriptState = AppleDictationTranscriptState()
    private var appleStopReceivedFinal = false
    private var appleStopContinuation: CheckedContinuation<Void, Never>?
    private var appleStopTimeoutTask: Task<Void, Never>?
    private var hasInstalledTap = false
    private var cloudRecorder: AVAudioRecorder?
    private var cloudRecordingURL: URL?
    private var cloudSpeechToTextService: (any CloudSpeechToTextServicing)?
    private var cloudSpeechToTextSelection: AIServiceSelection?
    private var cloudTranscriptionTask: Task<CloudTranscription, Error>?
    private var cloudTranscriptionGeneration: Int?
    private let cloudFinalization = CloudRecordingFinalizationCoordinator()
    private var realtimeSession: (any RealtimeSpeechToTextSession)?
    private var realtimePCMContinuation: AsyncStream<Data>.Continuation?
    private var realtimeSendTask: Task<Void, Never>?
    private var realtimeReceiveTask: Task<Void, Never>?
    private var realtimeFinishedGeneration: Int?
    private var captureRouteState = SpeechInputCaptureRouteState()
    private let audioSessionOwnership: SpeechInputAudioSessionOwnership
    private var sessionGeneration = 0

    private static let appleFinalTranscriptTimeoutNanoseconds: UInt64 = 1_500_000_000
    private static let realtimeStopOperationTimeoutNanoseconds: UInt64 = 3_000_000_000
    private static let cloudDictationStartupScrubber = CloudDictationTemporaryFileScrubber()

    override convenience init() {
        self.init(audioSessionOwnership: SpeechInputAudioSessionOwnership {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        })
    }

    init(audioSessionOwnership: SpeechInputAudioSessionOwnership) {
        self.audioSessionOwnership = audioSessionOwnership
        super.init()
        Self.cloudDictationStartupScrubber.scrubOnce(in: FileManager.default.temporaryDirectory)
    }

    func start(using aiConfiguration: AIConfigurationModel) async {
        let requestedSelection = aiConfiguration.effectiveSettings.speechToText
        if requestedSelection.provider == .apple {
            await startApple(
                languageCode: AIProviderRegistry.speechRecognitionRequestLanguage(
                    for: requestedSelection
                )
            )
            return
        }

        let readiness = await aiConfiguration.runtimeReadiness(for: .speechToText)
        guard aiConfiguration.effectiveSettings.speechToText == requestedSelection else {
            errorMessage = LocalAssistantServiceError.speechConfigurationChanged.localizedDescription
            return
        }
        switch readiness {
        case .ready:
            do {
                if AIProviderRegistry.usesRealtimeSpeechRecognition(requestedSelection) {
                    let service = try aiConfiguration.makeRealtimeSpeechToTextService()
                    await startRealtime(
                        service: service,
                        selection: requestedSelection
                    )
                } else {
                    let service = try aiConfiguration.makeCloudSpeechToTextService()
                    await startCloudRecording(
                        service: service,
                        selection: requestedSelection
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        case .missingCredential:
            errorMessage = LocalAssistantServiceError.cloudSpeechCredentialMissing.localizedDescription
        case .adapterUnavailable:
            errorMessage = LocalAssistantServiceError.cloudSpeechAdapterUnavailable.localizedDescription
        case .credentialStoreUnavailable:
            errorMessage = LocalAssistantServiceError.credentialStoreUnavailable.localizedDescription
        }
    }

    func start() async {
        await startApple(languageCode: Locale.current.identifier)
    }

    private func startApple(languageCode: String?) async {
        sessionGeneration += 1
        let generation = sessionGeneration
        errorMessage = nil
        transcript = ""
        isTranscribing = false

#if DEBUG
        // Keeps the physical UI hit test deterministic without granting private
        // speech services to a simulator. Production builds never take this path.
        if ProcessInfo.processInfo.arguments.contains("-OpenClamUITestSpeechInputReady") {
            stopCapture(cancelRecognition: true)
            appleTranscriptState = AppleDictationTranscriptState()
            captureRouteState.begin(.apple)
            isListening = true
            return
        }
#endif

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == sessionGeneration else { return }
        guard speechStatus == .authorized else {
            errorMessage = LocalAssistantServiceError.speechPermissionDenied.localizedDescription
            return
        }

        let microphoneGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard generation == sessionGeneration else { return }
        guard microphoneGranted else {
            errorMessage = LocalAssistantServiceError.microphonePermissionDenied.localizedDescription
            return
        }

        let supportedLocaleIdentifiers = Set(
            SFSpeechRecognizer.supportedLocales().map(\.identifier)
        )
        guard let resolvedLocaleIdentifier =
            AIProviderRegistry.resolvedAppleSpeechRecognitionLocaleIdentifier(
                requestedLanguageCode: languageCode,
                supportedLocaleIdentifiers: supportedLocaleIdentifiers
            ),
            let recognizer = SFSpeechRecognizer(
                locale: Locale(identifier: resolvedLocaleIdentifier)
            ) else {
            errorMessage = LocalAssistantServiceError.appleSpeechLocaleUnavailable
                .localizedDescription
            return
        }
        let availabilityOutcome = await AppleSpeechRecognitionAvailabilityWaiter.wait(
            snapshot: {
                .init(
                    isAvailable: recognizer.isAvailable,
                    supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition
                )
            },
            isCancelled: { [weak self] in
                guard let self else { return true }
                return generation != self.sessionGeneration
            }
        )
        switch availabilityOutcome {
        case .available:
            break
        case .unavailable:
            errorMessage = LocalAssistantServiceError.appleSpeechServiceUnavailable
                .localizedDescription
            return
        case .cancelled:
            return
        }
        guard generation == sessionGeneration, !Task.isCancelled else { return }

        stopCapture(cancelRecognition: true)
        speechRecognizer = recognizer
        appleTranscriptState = AppleDictationTranscriptState()
        appleStopReceivedFinal = false

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            audioSessionOwnership.claim()

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw LocalAssistantServiceError.speechUnavailable
            }
            isListening = true
            guard beginAppleRecognitionSegment(generation: generation) else { return }
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [appleAudioSink] buffer, _ in
                appleAudioSink.append(buffer)
            }
            hasInstalledTap = true
            audioEngine.prepare()
            try audioEngine.start()
            captureRouteState.begin(.apple)
        } catch {
            errorMessage = error.localizedDescription
            stopCapture(cancelRecognition: true)
        }
    }

    func stop() async -> String {
        guard recognitionTask != nil || isListening else {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let generation = sessionGeneration
        appleTranscriptState.requestStop()
        appleStopReceivedFinal = false
        isListening = false
        isTranscribing = true
        stopAppleAudioFeeding()

        if recognitionTask != nil {
            await waitForAppleFinalTranscript(generation: generation)
        }
        guard generation == sessionGeneration else { return "" }

        let value = publishFinishedTranscript(appleTranscriptState.text)
        stopCapture(cancelRecognition: false)
        isTranscribing = false
        return value
    }

    func stop(using _: AIConfigurationModel) async -> String {
        switch captureRouteState.active {
        case .apple:
            return await stop()
        case .realtime:
            return await stopRealtime()
        case .cloudRecording:
            return await stopCloudRecording()
        case .none:
            // Defensive resource checks cover the brief transition between a provider finishing
            // automatically and its shared finalization task publishing the result.
            if realtimeSession != nil {
                return await stopRealtime()
            }
            if cloudRecorder != nil || cloudFinalization.existingTask() != nil {
                return await stopCloudRecording()
            }
            return await stop()
        }
    }

    func cancel() {
        sessionGeneration += 1
        cloudTranscriptionTask?.cancel()
        cloudTranscriptionTask = nil
        cloudTranscriptionGeneration = nil
        isTranscribing = false
        stopCapture(cancelRecognition: true)
    }

    @discardableResult
    func publishFinishedTranscript(_ rawTranscript: String) -> String {
        let completion = SpeechInputCompletion.resolve(
            rawTranscript,
            existingError: errorMessage
        )
        transcript = completion.transcript
        errorMessage = completion.errorMessage
        return completion.transcript
    }

    /// Most stale transcription results are discarded after cancellation. A failed Soniox remote
    /// deletion is different: retain that warning so it is visible when the app becomes active
    /// again instead of implying the uploaded resource was verified removed.
    static func shouldSurfaceCloudTranscriptionError(
        _ error: Error,
        generationMatches: Bool
    ) -> Bool {
        generationMatches || (error as? CloudVoiceServiceError) == .remoteCleanupFailed
    }

    /// Draining queued microphone frames is finite. On timeout the producer task and provider
    /// session are both cancelled so a stalled WebSocket cannot retain the microphone indefinitely.
    static func awaitRealtimeSendDrain(
        _ task: Task<Void, Never>,
        session: any RealtimeSpeechToTextSession,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        let outcome = await withTaskGroup(
            of: SpeechInputRealtimeRaceOutcome.self
        ) { group in
            group.addTask {
                await task.value
                return .completed
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return .cancelled
                }
                guard !Task.isCancelled else { return .cancelled }
                return .timedOut
            }
            let first = await group.next() ?? .cancelled
            switch first {
            case .timedOut, .cancelled:
                // Select the race result before cancelling the operation. If
                // cancellation happens first, the waiter can otherwise report
                // a false successful drain and silently drop the PTT result.
                task.cancel()
                await session.cancel()
            case .completed, .failed:
                break
            }
            group.cancelAll()
            return first
        }
        if case .completed = outcome { return true }
        return false
    }

    /// Sends Soniox's graceful empty finish frame with a wall timeout. Cancelling both the child
    /// operation and socket ensures the task group itself can unwind even when the network stalls.
    static func finishRealtimeSession(
        _ session: any RealtimeSpeechToTextSession,
        timeoutNanoseconds: UInt64
    ) async throws {
        let finishTask = Task { try await session.finishAudio() }
        defer { finishTask.cancel() }
        let outcome = await withTaskGroup(
            of: SpeechInputRealtimeRaceOutcome.self
        ) { group in
            group.addTask {
                do {
                    try await finishTask.value
                    return .completed
                } catch {
                    return .failed(SpeechInputOperationError(error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return .cancelled
                }
                guard !Task.isCancelled else { return .cancelled }
                return .timedOut
            }
            let first = await group.next() ?? .cancelled
            switch first {
            case .timedOut, .cancelled:
                // Fix the timeout outcome before cancellation reaches the
                // sibling awaiting finishTask.value. A stalled provider now
                // deterministically reports processingTimedOut instead of a
                // scheduler-dependent CancellationError/empty transcript.
                finishTask.cancel()
                await session.cancel()
            case .completed, .failed:
                break
            }
            group.cancelAll()
            return first
        }

        switch outcome {
        case .completed:
            return
        case let .failed(error):
            throw error.underlying
        case .timedOut:
            throw CloudVoiceServiceError.processingTimedOut
        case .cancelled:
            throw CancellationError()
        }
    }

    @discardableResult
    private func beginAppleRecognitionSegment(generation: Int) -> Bool {
        guard let speechRecognizer else { return false }
        recognitionSegmentID += 1
        let segmentID = recognitionSegmentID
        let availability = AppleSpeechRecognitionAvailabilitySnapshot(
            isAvailable: speechRecognizer.isAvailable,
            supportsOnDeviceRecognition: speechRecognizer.supportsOnDeviceRecognition
        )
        let task = AppleSpeechRecognitionTaskGate.startIfAvailable(
            snapshot: availability,
            onUnavailable: { [weak self] in
                guard let self else { return }
                self.errorMessage = LocalAssistantServiceError.appleSpeechServiceUnavailable
                    .localizedDescription
                self.stopCapture(cancelRecognition: true)
            }
        ) { [appleAudioSink] requiresOnDeviceRecognition in
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            // Deliberately keep supported recognition on device, but only after
            // the availability gate permits creation of a recognition task.
            request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
            recognitionRequest = request
            appleAudioSink.replaceRequest(with: request)

            return speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self,
                          generation == self.sessionGeneration,
                          segmentID == self.recognitionSegmentID else { return }

                    if let result {
                        let action = self.appleTranscriptState.receive(
                            result.bestTranscription.formattedString,
                            isFinal: result.isFinal
                        )
                        self.transcript = self.appleTranscriptState.text
                        if result.isFinal {
                            switch action {
                            case .none:
                                break
                            case .restartRecognition:
                                guard self.isListening else { return }
                                self.recognitionTask = nil
                                self.recognitionRequest = nil
                                self.beginAppleRecognitionSegment(generation: generation)
                            case .finishRequestedStop:
                                self.appleStopReceivedFinal = true
                                self.completeAppleStopWait()
                            }
                            return
                        }
                    }

                    guard let error else { return }
                    if self.appleTranscriptState.stopRequested {
                        if self.appleTranscriptState.text.isEmpty {
                            self.errorMessage = error.localizedDescription
                        }
                        self.completeAppleStopWait()
                    } else if self.isListening {
                        self.errorMessage = error.localizedDescription
                        self.stopCapture(cancelRecognition: true)
                    }
                }
            }
        }
        guard let task else { return false }
        recognitionTask = task
        return true
    }

    private func waitForAppleFinalTranscript(generation: Int) async {
        guard generation == sessionGeneration, !appleStopReceivedFinal else { return }
        await withCheckedContinuation { continuation in
            guard generation == sessionGeneration, !appleStopReceivedFinal else {
                continuation.resume()
                return
            }
            appleStopContinuation = continuation
            appleStopTimeoutTask?.cancel()
            appleStopTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.appleFinalTranscriptTimeoutNanoseconds)
                guard !Task.isCancelled,
                      let self,
                      generation == self.sessionGeneration else { return }
                self.completeAppleStopWait()
            }
        }
    }

    private func completeAppleStopWait() {
        appleStopTimeoutTask?.cancel()
        appleStopTimeoutTask = nil
        let continuation = appleStopContinuation
        appleStopContinuation = nil
        continuation?.resume()
    }

    private func stopAppleAudioFeeding() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        appleAudioSink.endAudioAndClear()
        recognitionRequest = nil
    }

    private func startRealtime(
        service: any RealtimeSpeechToTextServicing,
        selection: AIServiceSelection
    ) async {
        sessionGeneration += 1
        let generation = sessionGeneration
        errorMessage = nil
        transcript = ""
        isTranscribing = false

        let microphoneGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard generation == sessionGeneration else { return }
        guard microphoneGranted else {
            errorMessage = LocalAssistantServiceError.microphonePermissionDenied.localizedDescription
            return
        }

        stopCapture(cancelRecognition: true)
        do {
            let session = try await service.startSession(
                model: selection.model,
                languageCode: AIProviderRegistry.speechRecognitionRequestLanguage(
                    for: selection
                )
            )
            guard generation == sessionGeneration else {
                await session.cancel()
                return
            }
            // Own the socket before configuring audio so every later setup failure closes it.
            realtimeSession = session

            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)
            audioSessionOwnership.claim()

            let input = audioEngine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard let converter = RealtimeSpeechPCMConverter(inputFormat: inputFormat) else {
                throw LocalAssistantServiceError.speechUnavailable
            }
            let (stream, continuation) = AsyncStream.makeStream(
                of: Data.self,
                bufferingPolicy: .bufferingOldest(32)
            )
            let pcmSink = BoundedRealtimePCMStreamSink(continuation: continuation) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleRealtimeFailure(
                        CloudVoiceServiceError.audioStreamOverflow,
                        generation: generation
                    )
                }
            }
            realtimePCMContinuation = continuation
            realtimeFinishedGeneration = nil

            realtimeSendTask = Task { @MainActor [weak self] in
                do {
                    for await pcm in stream {
                        try Task.checkCancellation()
                        try await session.sendPCM(pcm)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self?.handleRealtimeFailure(error, generation: generation)
                }
            }
            realtimeReceiveTask = Task { @MainActor [weak self] in
                do {
                    while let update = try await session.receiveUpdate() {
                        guard let self, generation == self.sessionGeneration else { return }
                        self.transcript = update.text
                        if update.isFinished {
                            self.realtimeFinishedGeneration = generation
                            return
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self?.handleRealtimeFailure(error, generation: generation)
                }
            }

            input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
                guard let pcm = converter.convert(buffer), !pcm.isEmpty else { return }
                pcmSink.enqueue(pcm)
            }
            hasInstalledTap = true
            audioEngine.prepare()
            try audioEngine.start()
            captureRouteState.begin(.realtime(selection))
            isListening = true
        } catch {
            guard generation == sessionGeneration else { return }
            errorMessage = error.localizedDescription
            stopCapture(cancelRecognition: true)
        }
    }

    private func stopRealtime() async -> String {
        guard let session = realtimeSession else {
            return publishFinishedTranscript(transcript)
        }
        let generation = sessionGeneration
        isListening = false
        isTranscribing = true
        let shouldFinalize = await CloudRecordingManualStopTailCapture.waitThenStop {
            guard generation == self.sessionGeneration else { return }
            self.stopAppleAudioFeeding()
        }
        guard generation == sessionGeneration else { return "" }
        guard shouldFinalize, realtimeSession != nil else {
            cleanupRealtimeCapture(cancelSession: true)
            audioSessionOwnership.releaseIfNeeded()
            isTranscribing = false
            return ""
        }
        realtimePCMContinuation?.finish()
        realtimePCMContinuation = nil

        if let realtimeSendTask {
            let drained = await Self.awaitRealtimeSendDrain(
                realtimeSendTask,
                session: session,
                timeoutNanoseconds: Self.realtimeStopOperationTimeoutNanoseconds
            )
            guard drained else {
                errorMessage = CloudVoiceServiceError.processingTimedOut.localizedDescription
                let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                cleanupRealtimeCapture(cancelSession: true)
                audioSessionOwnership.releaseIfNeeded()
                isTranscribing = false
                return value
            }
        }
        guard generation == sessionGeneration, realtimeSession != nil else {
            return ""
        }

        var shouldCancelSession = false
        do {
            try await Self.finishRealtimeSession(
                session,
                timeoutNanoseconds: Self.realtimeStopOperationTimeoutNanoseconds
            )
            for _ in 0..<60 {
                guard generation == sessionGeneration,
                      realtimeSession != nil,
                      realtimeFinishedGeneration != generation else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard generation == sessionGeneration, realtimeSession != nil else {
                return ""
            }
            if realtimeFinishedGeneration != generation {
                await session.cancel()
                errorMessage = CloudVoiceServiceError.processingTimedOut.localizedDescription
            } else {
                errorMessage = nil
            }
        } catch is CancellationError {
            cleanupRealtimeCapture(cancelSession: true)
            isTranscribing = false
            return ""
        } catch {
            errorMessage = error.localizedDescription
            shouldCancelSession = true
        }

        let value = publishFinishedTranscript(transcript)
        cleanupRealtimeCapture(cancelSession: shouldCancelSession)
        audioSessionOwnership.releaseIfNeeded()
        isTranscribing = false
        return value
    }

    private func handleRealtimeFailure(_ error: Error, generation: Int) {
        guard generation == sessionGeneration, realtimeSession != nil else { return }
        errorMessage = error.localizedDescription
        isListening = false
        isTranscribing = false
        stopAppleAudioFeeding()
        cleanupRealtimeCapture(cancelSession: true)
        audioSessionOwnership.releaseIfNeeded()
    }

    private func cleanupRealtimeCapture(cancelSession: Bool) {
        realtimePCMContinuation?.finish()
        realtimePCMContinuation = nil
        realtimeSendTask?.cancel()
        realtimeSendTask = nil
        realtimeReceiveTask?.cancel()
        realtimeReceiveTask = nil
        realtimeFinishedGeneration = nil
        let session = realtimeSession
        realtimeSession = nil
        captureRouteState.end()
        if cancelSession, let session {
            Task { await session.cancel() }
        }
    }

    private func startCloudRecording(
        service: any CloudSpeechToTextServicing,
        selection: AIServiceSelection
    ) async {
        sessionGeneration += 1
        let generation = sessionGeneration
        errorMessage = nil
        transcript = ""
        isTranscribing = false

        let microphoneGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard generation == sessionGeneration else { return }
        guard microphoneGranted else {
            errorMessage = LocalAssistantServiceError.microphonePermissionDenied.localizedDescription
            return
        }

        stopCapture(cancelRecognition: true)
        let url = CloudDictationTemporaryFileScrubber.recordingURL(
            in: FileManager.default.temporaryDirectory
        )
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            audioSessionOwnership.claim()
            let recorder = try AVAudioRecorder(
                url: url,
                settings: CloudDictationTemporaryFileScrubber.recorderSettings()
            )
            recorder.delegate = self
            guard recorder.prepareToRecord() else {
                throw LocalAssistantServiceError.speechUnavailable
            }
            try CloudDictationTemporaryFileScrubber.protectRecording(at: url)
            guard recorder.record(
                forDuration: CloudDictationTemporaryFileScrubber.maximumRecordingDuration
            ) else {
                throw LocalAssistantServiceError.speechUnavailable
            }
            cloudRecorder = recorder
            cloudRecordingURL = url
            cloudSpeechToTextService = service
            cloudSpeechToTextSelection = selection
            captureRouteState.begin(.cloudRecording(selection))
            isListening = true
        } catch {
            try? FileManager.default.removeItem(at: url)
            errorMessage = error.localizedDescription
            stopCapture(cancelRecognition: true)
        }
    }

    private func stopCloudRecording() async -> String {
        if let existingTask = cloudFinalization.existingTask() {
            return await existingTask.value
        }

        let task = beginCloudRecordingFinalization(
            recorderFinishedSuccessfully: true,
            failureMessage: nil,
            stopRecorder: true
        )
        return await task.value
    }

    private func beginCloudRecordingFinalization(
        recorderFinishedSuccessfully: Bool,
        failureMessage: String?,
        stopRecorder: Bool
    ) -> Task<String, Never> {
        if let existingTask = cloudFinalization.existingTask() {
            return existingTask
        }

        sessionGeneration += 1
        let generation = sessionGeneration
        isListening = false
        let recorder = cloudRecorder
        let url = cloudRecordingURL
        let service = cloudSpeechToTextService
        let selection = cloudSpeechToTextSelection
        let sessionOwnership = audioSessionOwnership
        cloudRecorder = nil
        cloudRecordingURL = nil
        cloudSpeechToTextService = nil
        cloudSpeechToTextSelection = nil
        captureRouteState.end()
        isTranscribing = recorderFinishedSuccessfully
            && url != nil && service != nil && selection != nil

        let task = cloudFinalization.task { @MainActor [weak self] in
            if stopRecorder {
                let shouldTranscribe = await CloudRecordingManualStopTailCapture.waitThenStop {
                    recorder?.stop()
                }
                guard shouldTranscribe else {
                    if let url { try? FileManager.default.removeItem(at: url) }
                    sessionOwnership.releaseIfNeeded()
                    return ""
                }
            }
            sessionOwnership.releaseIfNeeded()

            guard let self else {
                if let url { try? FileManager.default.removeItem(at: url) }
                return ""
            }

            guard generation == self.sessionGeneration else {
                if let url { try? FileManager.default.removeItem(at: url) }
                return ""
            }

            guard recorderFinishedSuccessfully else {
                if let url { try? FileManager.default.removeItem(at: url) }
                if generation == self.sessionGeneration {
                    self.isTranscribing = false
                    self.errorMessage = failureMessage
                        ?? "The cloud dictation recording ended before it could be saved."
                }
                return ""
            }

            guard let url, let service, let selection else {
                if let url { try? FileManager.default.removeItem(at: url) }
                if generation == self.sessionGeneration {
                    self.isTranscribing = false
                    self.errorMessage = "No cloud dictation recording was available."
                }
                return ""
            }

            return await self.transcribeCloudRecording(
                at: url,
                using: service,
                selection: selection,
                generation: generation
            )
        }
        return task
    }

    private func transcribeCloudRecording(
        at url: URL,
        using service: any CloudSpeechToTextServicing,
        selection: AIServiceSelection,
        generation: Int
    ) async -> String {
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let request = CloudTranscriptionRequest(
                audioData: data,
                filename: CloudDictationTemporaryFileScrubber.uploadFilename,
                mimeType: CloudDictationTemporaryFileScrubber.uploadMIMEType,
                model: selection.model,
                languageCode: AIProviderRegistry.speechRecognitionRequestLanguage(
                    for: selection
                )
            )
            isTranscribing = true
            let task = Task { try await service.transcribe(request) }
            cloudTranscriptionTask = task
            cloudTranscriptionGeneration = generation
            defer { clearCloudTranscriptionTask(for: generation) }
            let result = try await task.value
            guard generation == sessionGeneration else { return "" }
            errorMessage = nil
            let value = publishFinishedTranscript(result.text)
            isTranscribing = false
            return value
        } catch is CancellationError {
            if generation == sessionGeneration {
                isTranscribing = false
            }
            return ""
        } catch {
            let generationMatches = generation == sessionGeneration
            guard Self.shouldSurfaceCloudTranscriptionError(
                error,
                generationMatches: generationMatches
            ) else { return "" }
            if generationMatches {
                isTranscribing = false
            }
            errorMessage = error.localizedDescription
            return ""
        }
    }

    private func clearCloudTranscriptionTask(for generation: Int) {
        guard cloudTranscriptionGeneration == generation else { return }
        cloudTranscriptionTask = nil
        cloudTranscriptionGeneration = nil
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard recorder === cloudRecorder,
              isListening else { return }

        _ = beginCloudRecordingFinalization(
            recorderFinishedSuccessfully: flag,
            failureMessage: nil,
            stopRecorder: false
        )
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard recorder === cloudRecorder else { return }
        _ = beginCloudRecordingFinalization(
            recorderFinishedSuccessfully: false,
            failureMessage: error?.localizedDescription
                ?? "The cloud dictation recording could not be encoded.",
            stopRecorder: false
        )
    }

    private func stopCapture(cancelRecognition: Bool) {
        stopAppleAudioFeeding()
        cleanupRealtimeCapture(cancelSession: true)
        recognitionSegmentID += 1
        if cancelRecognition {
            recognitionTask?.cancel()
        } else {
            recognitionTask?.finish()
        }
        recognitionTask = nil
        speechRecognizer = nil
        completeAppleStopWait()

        isListening = false
        cloudSpeechToTextService = nil
        cloudSpeechToTextSelection = nil
        captureRouteState.end()
        cloudTranscriptionTask?.cancel()
        cloudTranscriptionTask = nil
        cloudTranscriptionGeneration = nil
        cloudFinalization.reset(cancelExisting: true)
        let recorder = cloudRecorder
        cloudRecorder = nil
        recorder?.stop()
        if let cloudRecordingURL {
            try? FileManager.default.removeItem(at: cloudRecordingURL)
        }
        cloudRecordingURL = nil
        audioSessionOwnership.releaseIfNeeded()
    }
}
