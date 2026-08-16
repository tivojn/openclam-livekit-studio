import Foundation
import UIKit
import XCTest
@testable import OpenClamLiveKit

final class ScreenContextIntakeTests: XCTestCase {
    @MainActor
    func testTestFlightFallbackOmitsLiveCaptureAndDeclaresReviewedPrivacyReasons() throws {
        XCTAssertFalse(ScreenContextFeatureModel.liveCaptureCompiledIn)

        let feature = ScreenContextFeatureModel.make()
        XCTAssertNil(feature.captureManager)

        let appBundle = Bundle(for: ScreenContextFeatureModel.self)
        XCTAssertNil(appBundle.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription"))
        let backgroundModes = try XCTUnwrap(
            appBundle.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        )
        XCTAssertEqual(backgroundModes, ["audio"])
        XCTAssertFalse(backgroundModes.contains("screen-capture"))

        let manifestURL = try XCTUnwrap(
            appBundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: manifestData, format: nil)
                as? [String: Any]
        )
        let accessedAPIs = try XCTUnwrap(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        )
        let reasonsByType: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: accessedAPIs.compactMap { entry in
                guard let type = entry["NSPrivacyAccessedAPIType"] as? String,
                      let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] else {
                    return nil
                }
                return (type, Set(reasons))
            }
        )
        XCTAssertEqual(
            reasonsByType["NSPrivacyAccessedAPICategoryUserDefaults"],
            ["CA92.1", "1C8F.1"]
        )
        XCTAssertEqual(
            reasonsByType["NSPrivacyAccessedAPICategorySystemBootTime"],
            ["35F9.1"]
        )
        XCTAssertEqual(reasonsByType.count, 2)
    }

    @MainActor
    func testKeyboardExtensionBundlesAppGroupUserDefaultsPrivacyReason() throws {
        let appBundle = Bundle(for: ScreenContextFeatureModel.self)
        let plugInsURL = try XCTUnwrap(appBundle.builtInPlugInsURL)
        let keyboardBundle = try XCTUnwrap(
            Bundle(
                url: plugInsURL.appendingPathComponent(
                    "OpenClamLiveKitKeyboard.appex",
                    isDirectory: true
                )
            )
        )
        let manifestURL = try XCTUnwrap(
            keyboardBundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: manifestData, format: nil)
                as? [String: Any]
        )
        let accessedAPIs = try XCTUnwrap(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        )

        XCTAssertEqual(accessedAPIs.count, 1)
        XCTAssertEqual(
            accessedAPIs.first?["NSPrivacyAccessedAPIType"] as? String,
            "NSPrivacyAccessedAPICategoryUserDefaults"
        )
        XCTAssertEqual(
            Set(accessedAPIs.first?["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []),
            ["1C8F.1"]
        )
    }

    @MainActor
    func testInboxStoresOneBoundedIntakeAndTakeRemovesPrivateFiles() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ScreenContextInbox(containerURL: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let image = makeImageData(format: .jpeg)

        let staged = try await inbox.stage(
            .init(
                source: .shareExtension,
                instruction: "Tell me what I should reply.",
                sharedText: "A message explicitly shared by the user.",
                sharedURL: URL(string: "https://www.apple.com/support"),
                imageData: image,
                imageTypeIdentifier: "public.jpeg"
            ),
            now: now
        )
        XCTAssertEqual(staged.imageData, image)
        XCTAssertEqual(staged.expiresAt, now.addingTimeInterval(ScreenContextInbox.intakeLifetime))

        let peeked = try await inbox.peek(now: now.addingTimeInterval(10))
        XCTAssertEqual(peeked, staged)
        let taken = try await inbox.take(now: now.addingTimeInterval(20))
        XCTAssertEqual(taken, staged)
        let afterTake = try await inbox.peek(now: now.addingTimeInterval(21))
        XCTAssertNil(afterTake)

        let directory = await inbox.directory
        let remaining = try payloadItems(in: directory)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testInboxRequiresFollowUpInstructionAndBoundsEveryInput() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ScreenContextInbox(containerURL: root)

        await assertStageFails(
            .init(source: .shareExtension, sharedText: "Hello"),
            in: inbox,
            expected: .instructionRequired
        )
        await assertStageFails(
            .init(
                source: .shortcut,
                instruction: String(
                    repeating: "x",
                    count: ScreenContextInbox.maximumInstructionCharacters + 1
                ),
                imageData: Data([0x01]),
                imageTypeIdentifier: "public.png"
            ),
            in: inbox,
            expected: .instructionTooLong
        )
        await assertStageFails(
            .init(
                source: .selectedScreenshot,
                instruction: "Describe",
                imageData: Data("not an image".utf8),
                imageTypeIdentifier: "public.png"
            ),
            in: inbox,
            expected: .invalidImageMetadata
        )
        await assertStageFails(
            .init(
                source: .shareExtension,
                instruction: "Summarize",
                sharedText: String(repeating: "x", count: ScreenContextInbox.maximumTextCharacters + 1)
            ),
            in: inbox,
            expected: .textTooLong
        )
        await assertStageFails(
            .init(
                source: .selectedScreenshot,
                instruction: "Describe",
                imageData: Data(repeating: 0x5A, count: ScreenContextInbox.maximumImageBytes + 1),
                imageTypeIdentifier: "public.jpeg"
            ),
            in: inbox,
            expected: .imageTooLarge
        )
        await assertStageFails(
            .init(
                source: .shortcut,
                instruction: "Explain",
                sharedURL: URL(string: "file:///private/var/mobile/example")
            ),
            in: inbox,
            expected: .unsupportedURL
        )

        XCTAssertThrowsError(
            try ScreenContextInbox.validatedShortcutInstruction("   \n")
        ) { error in
            XCTAssertEqual(error as? ScreenContextError, .instructionRequired)
        }
        XCTAssertThrowsError(
            try ScreenContextInbox.validatedShortcutInstruction(
                String(repeating: "👨‍👩‍👧‍👦", count: 400)
            )
        ) { error in
            XCTAssertEqual(error as? ScreenContextError, .instructionTooLong)
        }
    }

    @MainActor
    func testShortcutScreenshotValidatorAcceptsOnlyMatchingJPEGAndPNG() throws {
        let png = makeImageData(format: .png)
        let jpeg = makeImageData(format: .jpeg)

        XCTAssertEqual(
            try ScreenContextInbox.validatedShortcutScreenshot(
                data: png,
                declaredTypeIdentifier: "public.png"
            ),
            "public.png"
        )
        XCTAssertEqual(
            try ScreenContextInbox.validatedShortcutScreenshot(
                data: jpeg,
                declaredTypeIdentifier: "public.jpeg"
            ),
            "public.jpeg"
        )
        XCTAssertThrowsError(
            try ScreenContextInbox.validatedShortcutScreenshot(
                data: jpeg,
                declaredTypeIdentifier: "public.png"
            )
        ) { error in
            XCTAssertEqual(error as? ScreenContextError, .invalidImageMetadata)
        }
        XCTAssertThrowsError(
            try ScreenContextInbox.validatedShortcutScreenshot(
                data: Data("GIF89a".utf8),
                declaredTypeIdentifier: "com.compuserve.gif"
            )
        ) { error in
            XCTAssertTrue(
                [ScreenContextError.invalidShortcutImage, .unsupportedShortcutImage]
                    .contains(error as? ScreenContextError)
            )
        }
        XCTAssertThrowsError(
            try ScreenContextInbox.validatedShortcutScreenshot(
                data: Data(repeating: 0x00, count: ScreenContextInbox.maximumImageBytes + 1),
                declaredTypeIdentifier: "public.png"
            )
        ) { error in
            XCTAssertEqual(error as? ScreenContextError, .imageTooLarge)
        }
        let tooWidePNG = makeImageData(
            format: .png,
            width: ScreenContextInbox.maximumShortcutImageDimension + 1,
            height: 1
        )
        XCTAssertThrowsError(
            try ScreenContextInbox.validatedShortcutScreenshot(
                data: tooWidePNG,
                declaredTypeIdentifier: "public.png"
            )
        ) { error in
            XCTAssertEqual(error as? ScreenContextError, .shortcutImageDimensionsTooLarge)
        }

        let hostilePixelMetadata = jpegDeclaringDimensions(
            from: jpeg,
            width: 8_000,
            height: 8_000
        )
        XCTAssertThrowsError(
            try ScreenContextInbox.validatedShortcutScreenshot(
                data: hostilePixelMetadata,
                declaredTypeIdentifier: "public.jpeg"
            )
        ) { error in
            XCTAssertEqual(error as? ScreenContextError, .shortcutImageDimensionsTooLarge)
        }
    }

    @MainActor
    func testShortcutScreenshotIsOneShotAndRunsNoAutomaticOCR() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ScreenContextInbox(containerURL: root)
        let png = makeImageData(format: .png)
        let typeIdentifier = try ScreenContextInbox.validatedShortcutScreenshot(
            data: png,
            declaredTypeIdentifier: "public.png"
        )

        let first = try await inbox.stage(
            .init(
                source: .shortcut,
                instruction: "Describe the first screenshot.",
                imageData: png,
                imageTypeIdentifier: typeIdentifier
            )
        )
        let second = try await inbox.stage(
            .init(
                source: .shortcut,
                instruction: "What should I tap next?",
                imageData: png,
                imageTypeIdentifier: typeIdentifier
            )
        )
        XCTAssertNotEqual(first.id, second.id)

        let session = ScreenContextReviewSession(inbox: inbox)
        let recognizer = RecordingScreenContextRecognizer(result: "Must not run")
        let didRestore = try await session.restorePendingIntake()
        let recognitionCallCount = await recognizer.callCount
        let remainingIntake = try await inbox.peek()
        XCTAssertTrue(didRestore)
        XCTAssertEqual(session.review?.id, second.id)
        XCTAssertEqual(session.review?.originalInstruction, "What should I tap next?")
        XCTAssertNil(session.review?.locallyExtractedText)
        XCTAssertEqual(recognitionCallCount, 0)
        XCTAssertNil(remainingIntake, "Restoring the review must consume the one-shot intake.")
    }

    @MainActor
    func testAttachmentImageStagingRejectsMalformedAndHostilePixelMetadataBeforeReturning() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AttachmentPreparationService(temporaryRoot: root)

        do {
            _ = try await service.stageImage(
                data: Data("not an image".utf8),
                filename: "spoofed.png",
                sourceMIMEType: "image/png"
            )
            XCTFail("Malformed image data must not enter the composer tray.")
        } catch let error as AttachmentPreparationError {
            XCTAssertEqual(error, .invalidImage)
        }

        let hostilePixelMetadata = jpegDeclaringDimensions(
            from: makeImageData(format: .jpeg),
            width: 8_000,
            height: 8_000
        )
        do {
            _ = try await service.stageImage(
                data: hostilePixelMetadata,
                filename: "oversized.jpg",
                sourceMIMEType: "image/jpeg"
            )
            XCTFail("Over-pixel metadata must be rejected during staging, not later at Send.")
        } catch let error as AttachmentPreparationError {
            XCTAssertEqual(
                error,
                .imagePixelLimitExceeded(
                    maximumPixels: AttachmentPreparationLimits.standard.maximumImagePixelCount
                )
            )
        }
    }

    func testScreenshotAndDictationIntentMetadataCompiles() {
        XCTAssertEqual(
            String(localized: ReviewScreenshotAndDictationIntent.title),
            "Review Screenshot and Dictation"
        )
        XCTAssertTrue(ReviewScreenshotAndDictationIntent.openAppWhenRun)
        _ = ReviewScreenshotAndDictationIntent()
    }

    @MainActor
    func testInboxRejectsChangedImageArtifactAndPurgesIt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ScreenContextInbox(containerURL: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let image = makeImageData(format: .png)
        _ = try await inbox.stage(
            .init(
                source: .selectedScreenshot,
                instruction: "Explain this image",
                imageData: image,
                imageTypeIdentifier: "public.png"
            ),
            now: now
        )

        let directory = await inbox.directory
        let imageURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "image" })
        )
        try (image + Data([0x45])).write(to: imageURL)

        do {
            _ = try await inbox.peek(now: now.addingTimeInterval(1))
            XCTFail("Expected a changed private artifact to fail closed.")
        } catch let error as ScreenContextError {
            XCTAssertEqual(error, .invalidStoredItem)
        }
        let remaining = try payloadItems(in: directory)
        XCTAssertTrue(remaining.isEmpty)
    }

    @MainActor
    func testTransientPeekReadFailurePreservesIdenticalIntakeForRetry() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ScreenContextInbox(containerURL: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let image = makeImageData(format: .png)
        let staged = try await writer.stage(
            .init(
                source: .selectedScreenshot,
                instruction: "Describe this screenshot",
                imageData: image,
                imageTypeIdentifier: "public.png"
            ),
            now: now
        )
        let directory = await writer.directory
        let originalPayloadNames = try payloadItems(in: directory).map(\.lastPathComponent).sorted()

        let retryingReader = ScreenContextInbox(
            containerURL: root,
            fileManager: OneShotReadFailureFileManager()
        )
        do {
            _ = try await retryingReader.peek(now: now.addingTimeInterval(1))
            XCTFail("The injected file-protection read failure should be surfaced as retryable.")
        } catch let error as ScreenContextError {
            XCTAssertEqual(error, .temporaryStorageUnavailable)
        }
        XCTAssertEqual(
            try payloadItems(in: directory).map(\.lastPathComponent).sorted(),
            originalPayloadNames,
            "A transient read failure must not purge the pending generation."
        )

        let retried = try await retryingReader.peek(now: now.addingTimeInterval(2))
        XCTAssertEqual(retried, staged)
    }

    @MainActor
    func testSelectedScreenshotRunsNoOCRUntilExplicitTapAndSubmissionIsOneShot() async throws {
        let session = ScreenContextReviewSession()
        let image = makeImageData(format: .jpeg)
        try session.stageSelectedScreenshot(
            data: image,
            typeIdentifier: "public.jpeg",
            instruction: "What should I reply?"
        )
        let reviewID = try XCTUnwrap(session.review?.id)
        let recognizer = RecordingScreenContextRecognizer(result: "Extracted local text")
        let callsBeforeConfirmation = await recognizer.callCount
        XCTAssertEqual(callsBeforeConfirmation, 0)

        try await session.extractTextAfterUserConfirmation(
            reviewID: reviewID,
            recognizer: recognizer
        )
        let callsAfterConfirmation = await recognizer.callCount
        XCTAssertEqual(callsAfterConfirmation, 1)
        XCTAssertEqual(session.review?.locallyExtractedText, "Extracted local text")

        let submission = try session.consumeForOneRequest(
            reviewID: reviewID,
            editedInstruction: "Give me two concise reply options.",
            includeText: true,
            includeURL: false,
            includeImage: false
        )
        XCTAssertEqual(submission.includedText, "Extracted local text")
        XCTAssertNil(submission.includedImageData)
        XCTAssertNil(session.review)

        XCTAssertThrowsError(
            try session.consumeForOneRequest(
                reviewID: reviewID,
                editedInstruction: "Try again",
                includeText: true,
                includeURL: false,
                includeImage: false
            )
        ) { error in
            XCTAssertEqual(error as? ScreenContextError, .noPendingIntake)
        }
    }

    func testActionButtonMarkerContainsNoClaimedScreenData() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ScreenContextInbox(containerURL: root)

        let marker = try await inbox.stage(.init(source: .actionButton))
        XCTAssertEqual(marker.source, .actionButton)
        XCTAssertNil(marker.sharedText)
        XCTAssertNil(marker.sharedURL)
        XCTAssertNil(marker.imageData)
    }

    func testQuestionInboxIsOneSlotExpiringAndContainsNoProviderSecret() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ScreenContextQuestionInbox(containerURL: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try await inbox.stage("What is on this screen?", now: now)
        let second = try await inbox.stage("What should I tap next?", now: now.addingTimeInterval(1))
        XCTAssertNotEqual(first.id, second.id)
        let waiting = try await inbox.peek(now: now.addingTimeInterval(2))
        XCTAssertEqual(
            waiting,
            second,
            "A new explicit Shortcut run must replace, not archive, the previous question."
        )

        let directory = await inbox.directory
        let storedData = try Data(
            contentsOf: try XCTUnwrap(
                payloadItems(in: directory).first
            )
        )
        let storedText = try XCTUnwrap(String(data: storedData, encoding: .utf8))
        XCTAssertFalse(storedText.localizedCaseInsensitiveContains("api_key"))
        XCTAssertFalse(storedText.localizedCaseInsensitiveContains("bearer"))

        let expired = try await inbox.take(now: second.expiresAt)
        XCTAssertNil(expired)
        XCTAssertTrue(try payloadItems(in: directory).isEmpty)
    }

    @MainActor
    func testTwoScreenContextInboxInstancesCannotPublishMixedGenerations() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstInbox = ScreenContextInbox(containerURL: root)
        let secondInbox = ScreenContextInbox(containerURL: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let generationImages = (0 ..< 32).map { makeImageData(format: .png, colorSeed: $0) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 32 {
                let inbox = index.isMultiple(of: 2) ? firstInbox : secondInbox
                group.addTask {
                    _ = try await inbox.stage(
                        .init(
                            source: .selectedScreenshot,
                            instruction: "Generation \(index)",
                            imageData: generationImages[index],
                            imageTypeIdentifier: "public.png"
                        ),
                        now: now.addingTimeInterval(TimeInterval(index) / 100)
                    )
                }
            }
            try await group.waitForAll()
        }

        let finalIntake = try await firstInbox.peek(now: now.addingTimeInterval(1))
        let intake = try XCTUnwrap(finalIntake)
        let indexText = try XCTUnwrap(intake.instruction.split(separator: " ").last)
        let generation = try XCTUnwrap(Int(indexText))
        XCTAssertEqual(intake.imageData, generationImages[generation])

        let directory = await firstInbox.directory
        let payloadNames = Set(try payloadItems(in: directory).map(\.lastPathComponent))
        XCTAssertEqual(
            payloadNames,
            ["\(intake.id.uuidString).json", "\(intake.id.uuidString).image"]
        )
    }

    func testTwoQuestionInboxInstancesSerializeTheSharedOneSlot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstInbox = ScreenContextQuestionInbox(containerURL: root)
        let secondInbox = ScreenContextQuestionInbox(containerURL: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 40 {
                let inbox = index.isMultiple(of: 2) ? firstInbox : secondInbox
                group.addTask {
                    _ = try await inbox.stage(
                        "Question \(index)",
                        now: now.addingTimeInterval(TimeInterval(index) / 100)
                    )
                }
            }
            try await group.waitForAll()
        }

        let finalQuestion = try await secondInbox.peek(now: now.addingTimeInterval(1))
        let question = try XCTUnwrap(finalQuestion)
        XCTAssertTrue(question.question.hasPrefix("Question "))

        let directory = await secondInbox.directory
        XCTAssertEqual(
            try payloadItems(in: directory).map(\.lastPathComponent),
            ["pending-question-\(question.id.uuidString).json"]
        )
    }

    @MainActor
    func testCaptureSessionKeepsLatestFrameOnlyAndPairsOneExplicitQuestion() throws {
        let session = ScreenContextCaptureSession()
        XCTAssertThrowsError(
            try session.replaceLatestFrame(makeFrame(byte: 0x10, capturedAt: Date()))
        ) { error in
            XCTAssertEqual(error as? ScreenContextCaptureError, .disclosureRequired)
        }

        session.acceptDisclosure()
        let first = makeFrame(byte: 0x11, capturedAt: Date(timeIntervalSince1970: 10))
        let latest = makeFrame(byte: 0x22, capturedAt: Date(timeIntervalSince1970: 11))
        try session.replaceLatestFrame(first)
        try session.replaceLatestFrame(latest)
        XCTAssertEqual(session.latestFrame, latest)

        let queued = QueuedScreenContextQuestion(
            id: UUID(),
            question: "What should I reply?",
            createdAt: Date(timeIntervalSince1970: 11),
            expiresAt: Date(timeIntervalSince1970: 100)
        )
        let paired = try session.pair(queued, now: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(paired.question, queued.question)
        XCTAssertEqual(paired.latestFrame, latest)

        XCTAssertThrowsError(
            try session.consumeForOneRequest(questionID: UUID())
        ) { error in
            XCTAssertEqual(error as? ScreenContextCaptureError, .questionMismatch)
        }
        XCTAssertNil(session.pendingQuestion, "A mismatched review must burn the pair fail-closed.")
    }

    @MainActor
    func testCaptureSessionConsumesQuestionPairedBeforeLiveViewAppears() throws {
        let session = ScreenContextCaptureSession()
        session.acceptDisclosure()
        let latest = makeFrame(byte: 0x33, capturedAt: Date(timeIntervalSince1970: 11))
        try session.replaceLatestFrame(latest)
        let queued = QueuedScreenContextQuestion(
            id: UUID(),
            question: "Summarize the screen",
            createdAt: Date(timeIntervalSince1970: 11),
            expiresAt: Date(timeIntervalSince1970: 100)
        )
        let paired = try session.pair(queued, now: Date(timeIntervalSince1970: 12))

        let consumed = try session.consumePendingForOneRequestIfAvailable()

        XCTAssertEqual(consumed, paired)
        XCTAssertNil(session.pendingQuestion)
        XCTAssertNil(try session.consumePendingForOneRequestIfAvailable())
    }

    @MainActor
    func testCaptureSessionRejectsStaleAndFutureFramesFailClosed() throws {
        let session = ScreenContextCaptureSession()
        session.acceptDisclosure()
        let now = Date(timeIntervalSince1970: 100)
        let queued = QueuedScreenContextQuestion(
            id: UUID(),
            question: "What is on the current screen?",
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )

        let stale = makeFrame(
            byte: 0x41,
            capturedAt: now.addingTimeInterval(-ScreenContextCapturePolicy.maximumFrameAge - 0.001)
        )
        try session.replaceLatestFrame(stale)
        XCTAssertThrowsError(try session.pair(queued, now: now)) { error in
            XCTAssertEqual(error as? ScreenContextCaptureError, .staleFrame)
        }
        XCTAssertNil(session.latestFrame)
        XCTAssertNil(session.pendingQuestion)

        let future = makeFrame(byte: 0x42, capturedAt: now.addingTimeInterval(0.001))
        try session.replaceLatestFrame(future)
        XCTAssertThrowsError(try session.pair(queued, now: now)) { error in
            XCTAssertEqual(error as? ScreenContextCaptureError, .staleFrame)
        }
        XCTAssertNil(session.latestFrame)
        XCTAssertNil(session.pendingQuestion)
    }

    @MainActor
    func testCaptureSessionRejectsOversizedFrameAndDiscardsEverythingOnStop() throws {
        let session = ScreenContextCaptureSession()
        session.acceptDisclosure()
        let oversized = ScreenContextFrame(
            id: UUID(),
            jpegData: Data(repeating: 0x44, count: ScreenContextCapturePolicy.maximumFrameBytes + 1),
            pixelWidth: 1_000,
            pixelHeight: 1_000,
            capturedAt: Date()
        )
        XCTAssertThrowsError(try session.replaceLatestFrame(oversized)) { error in
            XCTAssertEqual(error as? ScreenContextCaptureError, .frameTooLarge)
        }
        XCTAssertNil(session.latestFrame)

        try session.replaceLatestFrame(makeFrame(byte: 0x55, capturedAt: Date()))
        session.endSession()
        XCTAssertFalse(session.disclosureAccepted)
        XCTAssertNil(session.latestFrame)
        XCTAssertNil(session.pendingQuestion)
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func makeImageData(
        format: TestImageFormat,
        width: Int = 8,
        height: Int = 8,
        colorSeed: Int = 1
    ) -> Data {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let color = UIColor(
            red: CGFloat((colorSeed * 53) % 255) / 255,
            green: CGFloat((colorSeed * 97) % 255) / 255,
            blue: CGFloat((colorSeed * 193) % 255) / 255,
            alpha: 1
        )
        switch format {
        case .png:
            return renderer.pngData { context in
                color.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        case .jpeg:
            return renderer.jpegData(withCompressionQuality: 0.8) { context in
                color.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }
    }

    private func jpegDeclaringDimensions(
        from source: Data,
        width: UInt16,
        height: UInt16
    ) -> Data {
        var bytes = [UInt8](source)
        let startOfFrameMarkers: Set<UInt8> = [
            0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
            0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
        ]
        for index in 0 ..< max(0, bytes.count - 8) where bytes[index] == 0xFF {
            guard startOfFrameMarkers.contains(bytes[index + 1]) else { continue }
            bytes[index + 5] = UInt8((height >> 8) & 0xFF)
            bytes[index + 6] = UInt8(height & 0xFF)
            bytes[index + 7] = UInt8((width >> 8) & 0xFF)
            bytes[index + 8] = UInt8(width & 0xFF)
            return Data(bytes)
        }
        preconditionFailure("The test JPEG did not contain a start-of-frame marker.")
    }

    private func payloadItems(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent != AppGroupTransactionLock.fileName }
    }

    private func assertStageFails(
        _ draft: ScreenContextDraft,
        in inbox: ScreenContextInbox,
        expected: ScreenContextError
    ) async {
        do {
            _ = try await inbox.stage(draft)
            XCTFail("Expected staging to fail with \(expected).")
        } catch let error as ScreenContextError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeFrame(byte: UInt8, capturedAt: Date) -> ScreenContextFrame {
        ScreenContextFrame(
            id: UUID(),
            jpegData: Data(repeating: byte, count: 1_024),
            pixelWidth: 320,
            pixelHeight: 640,
            capturedAt: capturedAt
        )
    }
}

private enum TestImageFormat {
    case jpeg
    case png
}

private actor RecordingScreenContextRecognizer: ScreenContextTextRecognizing {
    private(set) var callCount = 0
    private let result: String

    init(result: String) {
        self.result = result
    }

    func recognizeText(in imageData: Data) async throws -> String {
        callCount += 1
        return result
    }
}

private final class OneShotReadFailureFileManager: FileManager, @unchecked Sendable {
    private var shouldFailNextAttributesRead = true

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if shouldFailNextAttributesRead {
            shouldFailNextAttributesRead = false
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.attributesOfItem(atPath: path)
    }
}
