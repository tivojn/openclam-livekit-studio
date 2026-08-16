import AppIntents
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import OpenClamLiveKit

final class ScreenVoicePTTCoordinatorTests: XCTestCase {
    func testVADFinishesOnlyAfterSpeechAndTrailingSilence() {
        var vad = ScreenVoicePTTVAD(
            configuration: .init(
                speechThreshold: 0.02,
                silenceThreshold: 0.01,
                minimumSpeechDuration: 0.1,
                trailingSilenceDuration: 0.3,
                noSpeechTimeout: 2,
                hardTimeout: 3
            )
        )

        XCTAssertEqual(vad.ingest(rms: 0.03, duration: 0.05), .continueListening)
        XCTAssertEqual(vad.ingest(rms: 0.03, duration: 0.05), .continueListening)
        XCTAssertTrue(vad.hasSpeech)
        XCTAssertEqual(vad.ingest(rms: 0, duration: 0.1), .continueListening)
        XCTAssertEqual(vad.ingest(rms: 0, duration: 0.1), .continueListening)
        XCTAssertEqual(vad.ingest(rms: 0, duration: 0.1), .finishAfterSpeech)
    }

    func testVADNoSpeechAndHardTimeoutsAreBounded() {
        var silentVAD = ScreenVoicePTTVAD(
            configuration: .init(
                speechThreshold: 0.02,
                silenceThreshold: 0.01,
                minimumSpeechDuration: 0.1,
                trailingSilenceDuration: 1,
                noSpeechTimeout: 1,
                hardTimeout: 3
            )
        )
        var silentDecision = ScreenVoicePTTVAD.Decision.continueListening
        for _ in 0..<12 where silentDecision == .continueListening {
            silentDecision = silentVAD.ingest(rms: 0, duration: 0.1)
        }
        XCTAssertEqual(silentDecision, .noSpeechTimeout)
        XCTAssertLessThanOrEqual(silentVAD.elapsed, 1.2)

        var longSpeechVAD = ScreenVoicePTTVAD(
            configuration: .init(
                speechThreshold: 0.02,
                silenceThreshold: 0.01,
                minimumSpeechDuration: 0.1,
                trailingSilenceDuration: 1,
                noSpeechTimeout: 1,
                hardTimeout: 1.5
            )
        )
        var longSpeechDecision = ScreenVoicePTTVAD.Decision.continueListening
        for _ in 0..<17 where longSpeechDecision == .continueListening {
            longSpeechDecision = longSpeechVAD.ingest(rms: 0.1, duration: 0.1)
        }
        XCTAssertEqual(longSpeechDecision, .hardTimeout)
        XCTAssertLessThanOrEqual(longSpeechVAD.elapsed, 1.7)
    }

    func testPCMLevelCalculationUsesSignedLittleEndianSamples() {
        let samples: [Int16] = [Int16.max, Int16.min + 1, 0, 0]
        var data = Data()
        for sample in samples {
            var value = sample.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        XCTAssertEqual(
            ScreenVoicePTTVAD.rms(ofPCM16LittleEndian: data),
            sqrt(0.5),
            accuracy: 0.001
        )
    }

    @MainActor
    func testMicrophoneAudioSessionUsesValidCaptureCategoryAndActivationOptions() throws {
        let audioSession = RecordingScreenVoicePTTAudioSession()
        let microphone = ScreenVoicePTTMicrophoneSource(audioSession: audioSession)

        try microphone.configureAudioSessionForCapture()

        XCTAssertEqual(audioSession.categoryCalls.count, 1)
        XCTAssertEqual(audioSession.categoryCalls.first?.category, .playAndRecord)
        XCTAssertEqual(audioSession.categoryCalls.first?.mode, .measurement)
        XCTAssertEqual(
            audioSession.categoryCalls.first?.options.rawValue,
            AVAudioSession.CategoryOptions.duckOthers.rawValue
        )
        XCTAssertEqual(audioSession.activeCalls.count, 1)
        XCTAssertTrue(audioSession.activeCalls[0].active)
        XCTAssertTrue(audioSession.activeCalls[0].options.isEmpty)

        microphone.deactivateAudioSession()
        XCTAssertEqual(audioSession.activeCalls.count, 2)
        XCTAssertFalse(audioSession.activeCalls[1].active)
        XCTAssertEqual(
            audioSession.activeCalls[1].options,
            .notifyOthersOnDeactivation
        )
    }

    @MainActor
    func testAnswerSpeakerUsesDeactivationOptionOnlyWhileDeactivating() throws {
        let audioSession = RecordingScreenVoicePTTAudioSession()
        let speaker = ScreenVoicePTTAnswerSpeaker(audioSession: audioSession)

        try speaker.activatePlaybackSession()

        XCTAssertEqual(audioSession.categoryCalls.count, 1)
        XCTAssertEqual(audioSession.categoryCalls.first?.category, .playback)
        XCTAssertEqual(audioSession.categoryCalls.first?.mode, .spokenAudio)
        XCTAssertEqual(
            audioSession.categoryCalls.first?.options.rawValue,
            AVAudioSession.CategoryOptions.duckOthers.rawValue
        )
        XCTAssertEqual(audioSession.activeCalls.count, 1)
        XCTAssertTrue(audioSession.activeCalls[0].active)
        XCTAssertTrue(audioSession.activeCalls[0].options.isEmpty)

        speaker.deactivatePlaybackSession()
        XCTAssertEqual(audioSession.activeCalls.count, 2)
        XCTAssertFalse(audioSession.activeCalls[1].active)
        XCTAssertEqual(
            audioSession.activeCalls[1].options,
            .notifyOthersOnDeactivation
        )
    }

    func testCoordinatorRejectsConcurrentTurnAndCompletesFirst() async throws {
        let coordinator = ScreenVoicePTTCoordinator()
        let transcriber = GateQuestionTranscriber()
        let analyzer = RecordingAnalyzer(answer: "Answer")
        let speaker = RecordingSpeaker()
        let activity = RecordingActivityPresenter()
        let progress = RecordingProgressReporter()
        let dependencies = ScreenVoicePTTDependencies(
            transcriber: transcriber,
            analyzer: analyzer,
            speaker: speaker,
            activity: activity,
            progress: progress
        )

        let first = Task {
            try await coordinator.run(Self.request, dependencies: dependencies)
        }
        await transcriber.waitUntilStarted()

        do {
            _ = try await coordinator.run(Self.request, dependencies: dependencies)
            XCTFail("A concurrent turn must be rejected")
        } catch let error as ScreenVoicePTTError {
            XCTAssertEqual(error, .busy)
        }

        await transcriber.release(with: "What is shown?")
        let result = try await first.value
        XCTAssertEqual(result, "Answer")
        let questions = await analyzer.questions
        XCTAssertEqual(questions, ["What is shown?"])
        let spoken = await speaker.spoken
        XCTAssertEqual(spoken, ["Answer"])
        let phases = await activity.phases
        XCTAssertEqual(
            phases,
            [.preparing, .listening, .thinking, .speaking, .completed]
        )
        let progressPhases = await progress.phases
        XCTAssertEqual(
            progressPhases,
            [.preparing, .listening, .thinking, .speaking, .completed]
        )
    }

    func testCancellationStopsCaptureAndEndsVisibleActivity() async throws {
        let coordinator = ScreenVoicePTTCoordinator()
        let transcriber = GateQuestionTranscriber()
        let analyzer = RecordingAnalyzer(answer: "unused")
        let speaker = RecordingSpeaker()
        let activity = RecordingActivityPresenter()
        let progress = RecordingProgressReporter()
        let dependencies = ScreenVoicePTTDependencies(
            transcriber: transcriber,
            analyzer: analyzer,
            speaker: speaker,
            activity: activity,
            progress: progress
        )

        let task = Task {
            try await coordinator.run(Self.request, dependencies: dependencies)
        }
        await transcriber.waitUntilStarted()
        await coordinator.cancelCurrent()

        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            // Expected.
        }
        let cancelCount = await transcriber.cancelCount
        XCTAssertGreaterThanOrEqual(cancelCount, 1)
        let questionCount = await analyzer.questions.count
        XCTAssertEqual(questionCount, 0)
        let phases = await activity.phases
        XCTAssertTrue(phases.contains(.cancelled))
        let progressPhases = await progress.phases
        XCTAssertTrue(progressPhases.contains(.cancelled))
    }

    func testAudioInterruptionNeverReachesAnalysisOrPlayback() async throws {
        let coordinator = ScreenVoicePTTCoordinator()
        let transcriber = FailingQuestionTranscriber(error: .interrupted)
        let analyzer = RecordingAnalyzer(answer: "unused")
        let speaker = RecordingSpeaker()
        let activity = RecordingActivityPresenter()

        do {
            _ = try await coordinator.run(
                Self.request,
                dependencies: .init(
                    transcriber: transcriber,
                    analyzer: analyzer,
                    speaker: speaker,
                    activity: activity
                )
            )
            XCTFail("The interruption must fail the turn")
        } catch let error as ScreenVoicePTTError {
            XCTAssertEqual(error, .interrupted)
        }

        let questionCount = await analyzer.questions.count
        XCTAssertEqual(questionCount, 0)
        let spokenCount = await speaker.spoken.count
        XCTAssertEqual(spokenCount, 0)
        let phases = await activity.phases
        XCTAssertEqual(phases, [.preparing, .listening, .failed])
    }

    func testPlaybackTimeoutCancelsSpeakerAndEndsProgress() async throws {
        let coordinator = ScreenVoicePTTCoordinator()
        let speaker = SlowRecordingSpeaker()
        let activity = RecordingActivityPresenter()
        let progress = RecordingProgressReporter()

        do {
            _ = try await coordinator.run(
                Self.request,
                dependencies: .init(
                    transcriber: ImmediateQuestionTranscriber(value: "Question"),
                    analyzer: RecordingAnalyzer(answer: "Answer"),
                    speaker: speaker,
                    activity: activity,
                    progress: progress
                ),
                playbackTimeout: 0.02
            )
            XCTFail("Playback must have a hard deadline")
        } catch let error as ScreenVoicePTTError {
            XCTAssertEqual(error, .playbackTimedOut)
        }

        let cancelCount = await speaker.cancelCount
        XCTAssertGreaterThanOrEqual(cancelCount, 1)
        let phases = await activity.phases
        XCTAssertTrue(phases.contains(.failed))
        let progressPhases = await progress.phases
        XCTAssertTrue(progressPhases.contains(.failed))
    }

    func testFoundationProgressHeartbeatsAndCancellationAreTerminal() async {
        let value = Progress(totalUnitCount: 1)
        let reporter = FoundationScreenVoicePTTProgressReporter(progress: value)
        await reporter.update(.thinking)
        XCTAssertEqual(value.completedUnitCount, 55)
        await reporter.heartbeat()
        XCTAssertEqual(value.completedUnitCount, 56)
        await reporter.update(.cancelled)
        XCTAssertTrue(value.isCancelled)
        XCTAssertEqual(value.completedUnitCount, 100)
        await reporter.heartbeat()
        XCTAssertEqual(value.completedUnitCount, 100)
    }

    func testTranscriptionTransportHasAHardDeadline() async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            _ = try await screenVoicePTTWithTimeout(seconds: 0.02) {
                let workerDeadline = clock.now.advanced(by: .milliseconds(300))
                while clock.now < workerDeadline {
                    // Deliberately ignore cancellation while yielding. A structured task-group
                    // race would wait for this worker and fail the wall-deadline contract.
                    await Task.yield()
                }
                return "late"
            }
            XCTFail("A stalled speech transport must not outlive the PTT turn")
        } catch let error as ScreenVoicePTTError {
            XCTAssertEqual(error, .transcriptionTimedOut)
            XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(150))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @available(iOS 27.0, *)
    @MainActor
    func testIntentMaterializesDataBackedPNG() async throws {
        let source = makePNG()
        let file = IntentFile(data: source, filename: "Image.png", type: .png)

        let payload = try await AskOpenClamWithVoiceIntent.materializeScreenshot(file)

        XCTAssertEqual(payload.data, source)
        XCTAssertEqual(payload.typeIdentifier, UTType.png.identifier)
    }

    @available(iOS 27.0, *)
    @MainActor
    func testIntentMaterializesPNGAdvertisedAsGenericImage() async throws {
        let source = makePNG()
        let file = IntentFile(data: source, filename: "Image", type: .image)

        let payload = try await AskOpenClamWithVoiceIntent.materializeScreenshot(file)

        XCTAssertEqual(payload.data, source)
        XCTAssertEqual(payload.typeIdentifier, UTType.png.identifier)
    }

    @available(iOS 27.0, *)
    @MainActor
    func testIntentMaterializesDataBackedJPEG() async throws {
        let source = makeJPEG()
        let file = IntentFile(data: source, filename: "Image.jpg", type: .jpeg)

        let payload = try await AskOpenClamWithVoiceIntent.materializeScreenshot(file)

        XCTAssertEqual(payload.data, source)
        XCTAssertEqual(payload.typeIdentifier, UTType.jpeg.identifier)
    }

    @available(iOS 27.0, *)
    @MainActor
    func testIntentMaterializationPreservesCancellation() async {
        let source = makePNG()
        let file = IntentFile(data: source, filename: "Image.png", type: .png)
        let task = Task {
            try await AskOpenClamWithVoiceIntent.materializeScreenshot(file)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled invocation must not materialize or analyze its screenshot")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @available(iOS 27.0, *)
    @MainActor
    func testIntentMaterializesFileBackedPNGThroughAppIntents() async throws {
        let source = makePNG()
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclam-screen-\(UUID().uuidString).png")
        try source.write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let file = IntentFile(fileURL: sourceURL, filename: "Image.png", type: .png)

        let payload = try await AskOpenClamWithVoiceIntent.materializeScreenshot(file)

        XCTAssertEqual(payload.data, source)
        XCTAssertEqual(payload.typeIdentifier, UTType.png.identifier)
    }

    @MainActor
    private func makePNG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    @MainActor
    private func makeJPEG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    private static let request = ScreenVoicePTTRequest(
        screenshotData: Data([1, 2, 3]),
        screenshotTypeIdentifier: "public.jpeg",
        visibleText: nil
    )
}

@MainActor
private final class RecordingScreenVoicePTTAudioSession:
    ScreenVoicePTTAudioSessionConfiguring {
    struct CategoryCall {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    struct ActiveCall {
        let active: Bool
        let options: AVAudioSession.SetActiveOptions
    }

    private(set) var categoryCalls: [CategoryCall] = []
    private(set) var activeCalls: [ActiveCall] = []

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        categoryCalls.append(.init(category: category, mode: mode, options: options))
    }

    func setActive(
        _ active: Bool,
        options: AVAudioSession.SetActiveOptions
    ) throws {
        activeCalls.append(.init(active: active, options: options))
    }
}

private actor GateQuestionTranscriber: ScreenVoicePTTQuestionTranscribing {
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var started = false
    private(set) var cancelCount = 0

    func transcribeBoundedQuestion() async throws -> String {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release(with value: String) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }

    func cancel() {
        cancelCount += 1
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}

private actor FailingQuestionTranscriber: ScreenVoicePTTQuestionTranscribing {
    let error: ScreenVoicePTTError

    init(error: ScreenVoicePTTError) {
        self.error = error
    }

    func transcribeBoundedQuestion() async throws -> String { throw error }
    func cancel() {}
}

private actor ImmediateQuestionTranscriber: ScreenVoicePTTQuestionTranscribing {
    let value: String

    init(value: String) {
        self.value = value
    }

    func transcribeBoundedQuestion() async throws -> String { value }
    func cancel() {}
}

private actor RecordingAnalyzer: ScreenVoicePTTAnalyzing {
    let answer: String
    private(set) var questions: [String] = []

    init(answer: String) {
        self.answer = answer
    }

    func analyze(screen: ScreenVoicePTTRequest, question: String) async throws -> String {
        questions.append(question)
        return answer
    }
}

private actor RecordingSpeaker: ScreenVoicePTTSpeaking {
    private(set) var spoken: [String] = []
    private(set) var cancelCount = 0

    func speak(_ text: String) async throws { spoken.append(text) }
    func cancel() { cancelCount += 1 }
}

private actor SlowRecordingSpeaker: ScreenVoicePTTSpeaking {
    private(set) var cancelCount = 0

    func speak(_ text: String) async throws {
        try await Task.sleep(nanoseconds: 10_000_000_000)
    }

    func cancel() {
        cancelCount += 1
    }
}

private actor RecordingActivityPresenter: ScreenVoicePTTActivityPresenting {
    private(set) var phases: [ScreenVoicePTTPhase] = []

    func start(turnID: UUID, phase: ScreenVoicePTTPhase) async throws {
        phases.append(phase)
    }

    func update(_ phase: ScreenVoicePTTPhase) { phases.append(phase) }
    func end(_ phase: ScreenVoicePTTPhase) { phases.append(phase) }
}

private actor RecordingProgressReporter: ScreenVoicePTTProgressReporting {
    private(set) var phases: [ScreenVoicePTTPhase] = []

    func update(_ phase: ScreenVoicePTTPhase) {
        phases.append(phase)
    }

    func heartbeat() {}
}
