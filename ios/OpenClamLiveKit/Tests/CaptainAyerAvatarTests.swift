import AVFoundation
import UIKit
import XCTest
@testable import OpenClamLiveKit

final class CaptainAyerAvatarTests: XCTestCase {
    func testPlannerNormalizesReducedVisemesToRequestedDuration() throws {
        let timeline = CaptainAyerLipSyncPlanner().timeline(
            for: "Photo, queen!",
            duration: 3.2
        )

        XCTAssertEqual(timeline.duration, 3.2, accuracy: 0.0001)
        XCTAssertTrue(timeline.cues.contains { $0.viseme == .labiodental })
        XCTAssertTrue(timeline.cues.contains { $0.viseme == .alveolar })
        XCTAssertEqual(timeline.cues.last?.viseme, .silence)
        XCTAssertLessThanOrEqual(timeline.cues.last?.offset ?? 0, 3.2)
        XCTAssertTrue(timeline.cues.allSatisfy {
            CaptainAyerViseme.allCases.contains($0.viseme)
        })
    }

    func testPlannerUsesPauseWeightsAndReturnsIdleForEmptyText() {
        let planner = CaptainAyerLipSyncPlanner()
        let plain = planner.timeline(for: "aye")
        let punctuated = planner.timeline(for: "aye…")

        XCTAssertGreaterThan(punctuated.duration, plain.duration)
        XCTAssertEqual(planner.timeline(for: "").cues, [.init(offset: 0, viseme: .silence)])
    }

    func testUTF16ProgressHandlesEmojiBeforeSpeechBoundary() {
        let planner = CaptainAyerLipSyncPlanner()
        let text = "🙂 hello world"
        let location = (text as NSString).range(of: "world").location
        let progress = planner.progress(forUTF16Location: location, in: text)

        XCTAssertGreaterThan(progress, 0.35)
        XCTAssertLessThan(progress, 1)
    }

    func testTimelineCrossfadesWithoutPublishingFrames() throws {
        let timeline = CaptainAyerLipSyncTimeline(
            duration: 1,
            cues: [
                .init(offset: 0, viseme: .silence),
                .init(offset: 0.2, viseme: .open),
                .init(offset: 0.6, viseme: .wide),
                .init(offset: 0.98, viseme: .silence),
            ]
        )

        let entering = timeline.renderState(at: 0.22)
        XCTAssertEqual(entering.previous, .silence)
        XCTAssertEqual(entering.current, .open)
        XCTAssertGreaterThan(entering.blend, 0)
        XCTAssertLessThan(entering.blend, 1)
        XCTAssertEqual(timeline.renderState(at: 1), .idle)
    }

    @MainActor
    func testControllerRejectsStaleGenerationAndResetsOnFinish() {
        let controller = CaptainAyerLipSyncController()
        controller.prepare(text: "Aye", generation: 7)

        controller.begin(generation: 6, duration: 1)
        XCTAssertEqual(controller.phase, .prepared)

        controller.begin(generation: 7, duration: 1)
        XCTAssertTrue(controller.isSpeaking)
        controller.finish(generation: 6)
        XCTAssertTrue(controller.isSpeaking)

        controller.finish(generation: 7)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.generation)
        XCTAssertEqual(controller.renderState(), .idle)
    }

    @MainActor
    func testAppleSpeechDelegateForwardsOnlyRegisteredGeneration() {
        let proxy = SpeechOutputDelegateProxy()
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "Aye, captain")
        var startedGeneration: Int?
        var spokenRange: NSRange?
        var spokenText: String?

        proxy.onAppleSpeechStarted = { startedGeneration = $0 }
        proxy.onAppleSpeechRange = { _, range, text in
            spokenRange = range
            spokenText = text
        }
        proxy.register(utterance, generation: 42)
        proxy.speechSynthesizer(synthesizer, didStart: utterance)
        proxy.speechSynthesizer(
            synthesizer,
            willSpeakRangeOfSpeechString: NSRange(location: 5, length: 7),
            utterance: utterance
        )

        XCTAssertEqual(startedGeneration, 42)
        XCTAssertEqual(spokenRange, NSRange(location: 5, length: 7))
        XCTAssertEqual(spokenText, "Aye, captain")

        proxy.invalidateAll()
        startedGeneration = nil
        proxy.speechSynthesizer(synthesizer, didStart: utterance)
        XCTAssertNil(startedGeneration)
    }

    @MainActor
    func testEveryPublicGuideFrameIsBundledAndDecodable() throws {
        let guide = try XCTUnwrap(OpenClamAvatarCatalog.avatar(id: "captain-ayer"))
        let roles: [OpenClamAvatarAssetRole] = [
            .thumbnail,
            .body,
            .headMask,
        ] + OpenClamAvatarViseme.allCases.map(OpenClamAvatarAssetRole.viseme)

        for role in roles {
            XCTAssertNotNil(
                OpenClamAvatarAssetStore.shared.image(for: guide, role: role),
                "Missing public guide asset: \(role)"
            )
        }
    }

    func testOverlayOpacitySwipeBrightensUpAndNeverDisappears() {
        XCTAssertEqual(
            CaptainAyerOverlayTuning.opacity(
                from: CaptainAyerOverlayTuning.initialOpacity,
                verticalTranslation: -300
            ),
            1.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            CaptainAyerOverlayTuning.opacity(
                from: CaptainAyerOverlayTuning.initialOpacity,
                verticalTranslation: 300
            ),
            CaptainAyerOverlayTuning.minimumOpacity,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(CaptainAyerOverlayTuning.minimumOpacity, 0)
    }

    func testOpeningWhisperOpacityIsVisibleButSubtle() {
        XCTAssertGreaterThan(
            CaptainAyerOverlayTuning.initialOpacity,
            CaptainAyerOverlayTuning.minimumOpacity
        )
        XCTAssertLessThanOrEqual(CaptainAyerOverlayTuning.initialOpacity, 0.15)
    }

    func testOverlayPinchScaleClampsAtUsefulLimits() {
        XCTAssertEqual(
            CaptainAyerOverlayTuning.clampedScale(0.01),
            CaptainAyerOverlayTuning.minimumScale,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            CaptainAyerOverlayTuning.clampedScale(20),
            CaptainAyerOverlayTuning.maximumScale,
            accuracy: 0.0001
        )
    }

    func testOverlayRailFadeDelayLeavesTimeToChooseATool() {
        XCTAssertEqual(
            CaptainAyerOverlayTuning.railFadeDelay,
            4.0,
            accuracy: 0.0001
        )
    }

    func testOverlayRailIdleAppearanceRemainsClearlyVisible() {
        XCTAssertGreaterThanOrEqual(
            CaptainAyerOverlayTuning.railIdleOpacity,
            0.65
        )
        XCTAssertLessThan(
            CaptainAyerOverlayTuning.railIdleOpacity,
            1
        )
    }

    @MainActor
    func testThreadInteractionRelayOnlyForwardsWhileOverlayIsConnected() {
        let relay = CaptainAyerOverlayInteractionRelay()
        var interactionCount = 0

        relay.noteThreadInteraction()
        XCTAssertEqual(interactionCount, 0)

        relay.connect { interactionCount += 1 }
        relay.noteThreadInteraction()
        XCTAssertEqual(interactionCount, 1)

        relay.disconnect()
        relay.noteThreadInteraction()
        XCTAssertEqual(interactionCount, 1)
    }

    func testConnectionSignatureStartsOnlyWhenEnteringStarting() {
        XCTAssertEqual(
            LiveTalkConnectionFeedbackPolicy.soundAction(from: .idle, to: .starting),
            .start
        )

        let silentPhases: [LiveTalkConnectionPhase] = [
            .idle,
            .connected,
            .reconnecting,
            .ending,
            .failed("offline"),
        ]
        for phase in silentPhases {
            XCTAssertEqual(
                LiveTalkConnectionFeedbackPolicy.soundAction(from: .starting, to: phase),
                .stop,
                "Connection signature must stop during \(phase)"
            )
        }
    }

    func testRepeatedStartingNotificationDoesNotStackConnectionPlayers() {
        XCTAssertEqual(
            LiveTalkConnectionFeedbackPolicy.soundAction(from: .starting, to: .starting),
            .none
        )
    }

    func testConnectionRailMotionHonorsReduceMotion() {
        XCTAssertTrue(
            LiveTalkConnectionFeedbackPolicy.showsAnimatedRailFeedback(
                during: .starting,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            LiveTalkConnectionFeedbackPolicy.showsAnimatedRailFeedback(
                during: .starting,
                reduceMotion: true
            )
        )
        XCTAssertFalse(
            LiveTalkConnectionFeedbackPolicy.showsAnimatedRailFeedback(
                during: .connected,
                reduceMotion: false
            )
        )
    }

    @MainActor
    func testConnectionSignatureIsPresentInAvatarResourceBundle() {
        let url = LiveTalkConnectionSoundAsset.url()

        XCTAssertEqual(url?.lastPathComponent, "live-talk-connection.wav")
        XCTAssertTrue(url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }

    @MainActor
    func testConnectionControllerAuditionsLocallyAndStopsOnConnected() async {
        let controller = LiveTalkConnectionFeedbackController()

        controller.synchronize(with: .starting)
        let didStartLocally = await waitForConnectionSignature(controller, toPlay: true)
        let didStartRemotely = await controller.isPlaying(destination: .remote)
        XCTAssertTrue(didStartLocally)
        XCTAssertFalse(didStartRemotely)

        controller.synchronize(with: .starting)
        let remainsPlayingLocally = await controller.isPlaying(destination: .local)
        XCTAssertTrue(remainsPlayingLocally)
        try? await Task.sleep(for: .milliseconds(1_500))

        controller.synchronize(with: .connected)
        let didStopOnConnected = await waitForConnectionSignature(controller, toPlay: false)
        XCTAssertTrue(didStopOnConnected)
    }

    @MainActor
    private func waitForConnectionSignature(
        _ controller: LiveTalkConnectionFeedbackController,
        toPlay expectedValue: Bool
    ) async -> Bool {
        for _ in 0 ..< 80 {
            if await controller.isPlaying(destination: .local) == expectedValue {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}
