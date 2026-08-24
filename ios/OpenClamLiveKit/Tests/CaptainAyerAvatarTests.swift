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

    func testUnpunctuatedTimelineCrossfadesFromSilenceAtOnsetAtSixtyHertz() {
        let timeline = CaptainAyerLipSyncPlanner().timeline(
            for: "Photo",
            duration: 1
        )

        let onset = timeline.renderState(at: 0)
        XCTAssertEqual(onset.previous, .silence)
        XCTAssertEqual(onset.current, .labiodental)
        XCTAssertEqual(onset.blend, 0, accuracy: 0.0001)

        let firstDisplayTick = timeline.renderState(at: 1.0 / 60.0)
        XCTAssertEqual(firstDisplayTick.previous, .silence)
        XCTAssertEqual(firstDisplayTick.current, onset.current)
        XCTAssertGreaterThan(firstDisplayTick.blend, 0)
        XCTAssertLessThan(
            firstDisplayTick.blend,
            0.38,
            "Even the shortest opening fade must have multiple 60 Hz frames"
        )
    }

    func testUnpunctuatedTimelineClosesContinuouslyAtSixtyHertz() throws {
        let timeline = CaptainAyerLipSyncPlanner().timeline(
            for: "Hello",
            duration: 1
        )
        let closingCue = try XCTUnwrap(timeline.cues.last)
        let precedingCue = try XCTUnwrap(timeline.cues.dropLast().last)
        let expectedClosingOffset = max(
            precedingCue.offset,
            timeline.duration - CaptainAyerLipSyncTimeline.fadeDuration(
                from: precedingCue.viseme,
                to: .silence
            )
        )

        XCTAssertEqual(closingCue.viseme, .silence)
        XCTAssertEqual(closingCue.offset, expectedClosingOffset, accuracy: 0.0001)

        let lastDisplayTick = timeline.renderState(
            at: timeline.duration - 1.0 / 60.0
        )
        XCTAssertEqual(lastDisplayTick.previous, precedingCue.viseme)
        XCTAssertEqual(lastDisplayTick.current, .silence)
        XCTAssertGreaterThan(lastDisplayTick.blend, 0.75)
        XCTAssertLessThanOrEqual(
            1 - lastDisplayTick.blend,
            0.23,
            "The endpoint must be no larger than one normal 60 Hz fade step"
        )

        let limit = timeline.renderState(at: timeline.duration - 0.000_001)
        XCTAssertEqual(limit.current, .silence)
        XCTAssertGreaterThan(limit.blend, 0.999)
        XCTAssertEqual(timeline.renderState(at: timeline.duration), .idle)
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
    func testEveryCaptainAyerFrameIsBundledAndDecodable() {
        let names = [
            "CaptainAyerBody",
            "CaptainAyerHeadMask",
            "CaptainAyerKeyframe",
        ] + CaptainAyerViseme.allCases.map(\.assetName)

        for name in names {
            XCTAssertNotNil(UIImage(named: name), "Missing avatar asset: \(name)")
        }
    }

    func testOverlayOpacitySwipeCoversFullyTransparentThroughFullyOpaque() {
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
        XCTAssertEqual(CaptainAyerOverlayTuning.minimumOpacity, 0)
        XCTAssertEqual(CaptainAyerOverlayTuning.maximumOpacity, 1)
        XCTAssertEqual(CaptainAyerInteractionLayer.allCases, [.avatar, .thread])
        XCTAssertTrue(CaptainAyerInteractionLayer.avatar.allowsAvatarGestures)
        XCTAssertFalse(CaptainAyerInteractionLayer.thread.allowsAvatarGestures)
    }

    func testFullyTransparentAvatarCanRecoverWithUpwardOpacitySwipe() throws {
        var state = CaptainAyerOverlayGestureState()
        let preview = try XCTUnwrap(
            state.updateOpacityDrag(
                startingOpacity: CaptainAyerOverlayTuning.minimumOpacity,
                verticalTranslation: -90
            )
        )

        XCTAssertEqual(preview, 0.30, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(state.completeOpacityDrag()),
            preview,
            accuracy: 0.0001
        )
    }

    func testStageDragIntentGivesVerticalOpacityExclusivePrecedence() {
        XCTAssertEqual(
            CaptainAyerAvatarGesturePolicy.dragIntent(
                translation: CGSize(width: 2, height: 6),
                supportsOpacity: true
            ),
            .pending
        )
        XCTAssertEqual(
            CaptainAyerAvatarGesturePolicy.dragIntent(
                translation: CGSize(width: 28, height: 5),
                supportsOpacity: true
            ),
            .gaze
        )
        XCTAssertEqual(
            CaptainAyerAvatarGesturePolicy.dragIntent(
                translation: CGSize(width: 4, height: 19),
                supportsOpacity: true
            ),
            .opacity
        )
        XCTAssertEqual(
            CaptainAyerAvatarGesturePolicy.dragIntent(
                translation: CGSize(width: 4, height: 30),
                supportsOpacity: false
            ),
            .gaze
        )
        XCTAssertNotEqual(
            CaptainAyerAvatarGesturePolicy.dragIntent(
                translation: CGSize(width: 25, height: 20),
                supportsOpacity: true
            ),
            .opacity
        )

        var vertical = CaptainAyerAvatarDragSession()
        vertical.update(
            translation: CGSize(width: 2, height: 6),
            supportsOpacity: true
        )
        XCTAssertEqual(vertical.intent, .pending)
        vertical.update(
            translation: CGSize(width: 2, height: 12),
            supportsOpacity: true
        )
        XCTAssertEqual(vertical.intent, .pending)
        vertical.update(
            translation: CGSize(width: 2, height: 32),
            supportsOpacity: true
        )
        XCTAssertEqual(vertical.intent, .opacity)
        XCTAssertEqual(vertical.completion, .opacity)
        XCTAssertNotEqual(vertical.completion, .tap)
        XCTAssertNotEqual(vertical.completion, .gaze)

        var horizontal = CaptainAyerAvatarDragSession()
        horizontal.update(
            translation: CGSize(width: 32, height: 2),
            supportsOpacity: true
        )
        XCTAssertEqual(horizontal.intent, .gaze)
        XCTAssertEqual(horizontal.completion, .gaze)

        var shortTouch = CaptainAyerAvatarDragSession()
        shortTouch.update(
            translation: CGSize(width: 4, height: 4),
            supportsOpacity: true
        )
        XCTAssertEqual(shortTouch.intent, .pending)
        XCTAssertEqual(shortTouch.completion, .tap)
    }

    func testOpacityDragDoesNotExposeAPersistedValueUntilCompletion() {
        var session = CaptainAyerOpacityDragSession(startingOpacity: 0.50)
        session.update(verticalTranslation: -120)

        XCTAssertEqual(session.startingOpacity, 0.50, accuracy: 0.0001)
        XCTAssertEqual(session.previewOpacity, 0.90, accuracy: 0.0001)
        XCTAssertNil(session.persistedValue)

        let completedValue = session.complete()
        XCTAssertEqual(completedValue, 0.90, accuracy: 0.0001)
        XCTAssertEqual(session.persistedValue, 0.90)
    }

    func testSubtleVisibleAvatarCanStillCompleteAnOpacitySwipe() throws {
        // The visual avatar begins almost transparent. The gesture path must
        // nevertheless retain its full 10–100% range and commit only once the
        // visible stage's drag ends.
        var state = CaptainAyerOverlayGestureState()
        let preview = try XCTUnwrap(
            state.updateOpacityDrag(
                startingOpacity: CaptainAyerOverlayTuning.initialOpacity,
                verticalTranslation: -240
            )
        )

        XCTAssertGreaterThan(preview, 0.90)
        XCTAssertTrue(state.hasOpacityDrag)

        let committed = try XCTUnwrap(state.completeOpacityDrag())
        XCTAssertEqual(committed, preview, accuracy: 0.0001)
        XCTAssertFalse(state.hasOpacityDrag)
    }

    func testPinchAtomicallyRevertsAndInvalidatesThresholdedOpacityDrag() throws {
        var drag = CaptainAyerAvatarDragSession()
        drag.update(
            translation: CGSize(width: 2, height: -19),
            supportsOpacity: true
        )
        XCTAssertEqual(drag.intent, .opacity)

        var state = CaptainAyerOverlayGestureState()
        let preview = try XCTUnwrap(
            state.updateOpacityDrag(
                startingOpacity: 0.50,
                verticalTranslation: -120
            )
        )

        XCTAssertEqual(preview, 0.90, accuracy: 0.0001)
        XCTAssertTrue(state.hasOpacityDrag)
        XCTAssertFalse(state.isPinching)

        let revertedOpacity = try XCTUnwrap(state.beginPinch())
        XCTAssertEqual(revertedOpacity, 0.50, accuracy: 0.0001)
        XCTAssertTrue(state.isPinching)
        XCTAssertFalse(state.hasOpacityDrag)
        XCTAssertTrue(state.suppressesOpacityUntilDragEnd)

        // Even if pinch ends first, the stale inner drag cannot re-arm the
        // preview before its delayed onEnded callback arrives.
        state.endPinch()
        XCTAssertFalse(state.isPinching)
        XCTAssertEqual(drag.completion, .opacity)
        XCTAssertNil(
            state.updateOpacityDrag(
                startingOpacity: 0.50,
                verticalTranslation: -150
            )
        )
        XCTAssertNil(state.completeOpacityDrag())
        XCTAssertFalse(state.suppressesOpacityUntilDragEnd)

        let nextDragPreview = try XCTUnwrap(
            state.updateOpacityDrag(
                startingOpacity: 0.50,
                verticalTranslation: -30
            )
        )
        XCTAssertEqual(nextDragPreview, 0.60, accuracy: 0.0001)
        XCTAssertTrue(state.hasOpacityDrag)
        let nextCompletedOpacity = try XCTUnwrap(state.completeOpacityDrag())
        XCTAssertEqual(nextCompletedOpacity, 0.60, accuracy: 0.0001)
        XCTAssertFalse(state.hasOpacityDrag)
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

    func testOptionalMotionAvailabilityReportsEveryRuntimeBlocker() {
        let ready = OpenClamAvatarMotionRuntimeContext(
            hasAsset: true,
            reduceMotion: false,
            isSpeaking: false,
            isLiveTalkActive: false,
            isAvatarHidden: false,
            isFaceMirrorActive: false
        )
        XCTAssertNil(OpenClamAvatarMotionAvailabilityPolicy.disabledReason(for: ready))

        let blocked: [(OpenClamAvatarMotionRuntimeContext, String)] = [
            (
                .init(
                    hasAsset: false, reduceMotion: false, isSpeaking: false,
                    isLiveTalkActive: false, isAvatarHidden: false,
                    isFaceMirrorActive: false
                ),
                "Not included in this avatar"
            ),
            (
                .init(
                    hasAsset: true, reduceMotion: true, isSpeaking: false,
                    isLiveTalkActive: false, isAvatarHidden: false,
                    isFaceMirrorActive: false
                ),
                "Unavailable with Reduce Motion"
            ),
            (
                .init(
                    hasAsset: true, reduceMotion: false, isSpeaking: false,
                    isLiveTalkActive: true, isAvatarHidden: false,
                    isFaceMirrorActive: false
                ),
                "Unavailable during Live Talk"
            ),
            (
                .init(
                    hasAsset: true, reduceMotion: false, isSpeaking: true,
                    isLiveTalkActive: false, isAvatarHidden: false,
                    isFaceMirrorActive: false
                ),
                "Unavailable while speaking"
            ),
            (
                .init(
                    hasAsset: true, reduceMotion: false, isSpeaking: false,
                    isLiveTalkActive: false, isAvatarHidden: true,
                    isFaceMirrorActive: false
                ),
                "Unavailable while avatar is hidden"
            ),
            (
                .init(
                    hasAsset: true, reduceMotion: false, isSpeaking: false,
                    isLiveTalkActive: false, isAvatarHidden: false,
                    isFaceMirrorActive: true
                ),
                "Unavailable during face mirroring"
            ),
        ]

        for (context, expectedReason) in blocked {
            XCTAssertEqual(
                OpenClamAvatarMotionAvailabilityPolicy.disabledReason(for: context),
                expectedReason
            )
        }
    }

    func testMotionSessionArbitratesWalkIdleMovesAndInteractions() {
        var session = OpenClamAvatarMotionSessionState()

        XCTAssertEqual(session.request(.walk, canStart: false), .none)
        XCTAssertNil(session.activeKind)
        XCTAssertEqual(session.request(.walk, canStart: true), .start(.walk))
        XCTAssertEqual(session.activeKind, .walk)
        XCTAssertEqual(
            session.request(.edgeIdle, canStart: true),
            .replace(.walk, .edgeIdle)
        )
        XCTAssertEqual(session.activeKind, .edgeIdle)
        XCTAssertEqual(session.complete(.walk), .none, "Stale completion cannot stop a replacement")
        XCTAssertEqual(session.activeKind, .edgeIdle)
        XCTAssertEqual(
            session.request(.moves, canStart: true),
            .replace(.edgeIdle, .moves)
        )
        XCTAssertEqual(session.complete(.edgeIdle), .none)
        XCTAssertEqual(session.complete(.moves), .stop(.moves))
        XCTAssertNil(session.activeKind)

        XCTAssertEqual(session.request(.edgeIdle, canStart: true), .start(.edgeIdle))
        XCTAssertEqual(session.request(.edgeIdle, canStart: true), .stop(.edgeIdle))
        XCTAssertNil(session.activeKind)

        for _ in 0 ..< 4 {
            XCTAssertEqual(session.request(.moves, canStart: true), .start(.moves))
            XCTAssertEqual(session.interrupt(), .stop(.moves))
            XCTAssertNil(session.activeKind)
        }
        XCTAssertEqual(session.interrupt(), .none)
    }

    func testMotionPlaybackModeIsKeyDerivedAndNotPackageControlled() {
        XCTAssertTrue(OpenClamAvatarMotionKind.walk.loops)
        XCTAssertTrue(OpenClamAvatarMotionKind.edgeIdle.loops)
        XCTAssertFalse(OpenClamAvatarMotionKind.moves.loops)
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
