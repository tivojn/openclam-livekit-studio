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

    func testPlannerCanPublishAllFifteenProductionVisemes() {
        let timeline = CaptainAyerLipSyncPlanner().timeline(
            for: "mbp f th t k ch s n r a e i o oa u",
            duration: 6
        )
        let rendered = Set(timeline.cues.map(\.viseme))
        XCTAssertEqual(rendered, Set(CaptainAyerViseme.allCases))
        XCTAssertEqual(CaptainAyerViseme.allCases.count, 15)
    }

    func testPlannerKeepsChineseAndOtherNonLatinSpeechArticulating() {
        let timeline = CaptainAyerLipSyncPlanner().timeline(
            for: "你好，今天过得怎么样？",
            duration: 3
        )
        let spoken = Set(timeline.cues.map(\.viseme)).subtracting([.silence])

        XCTAssertEqual(timeline.duration, 3, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(spoken.count, 3)
        XCTAssertEqual(timeline.cues.last?.viseme, .silence)
        XCTAssertTrue(spoken.isSubset(of: Set(CaptainAyerViseme.allCases)))
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

    func testSpeechExpressionPlannerUnderstandsIntentWithoutAnotherModel() {
        let curious = CaptainAyerSpeechExpressionPlanner.plan(
            for: "Would you like to try this?"
        )
        let warm = CaptainAyerSpeechExpressionPlanner.plan(
            for: "Thank you! I am very glad this worked."
        )
        let serious = CaptainAyerSpeechExpressionPlanner.plan(
            for: "Important warning: you must be careful."
        )
        let chineseEmpathy = CaptainAyerSpeechExpressionPlanner.plan(
            for: "抱歉，这确实很难。我理解你的担心。"
        )

        XCTAssertGreaterThan(curious.curiosity, 0.5)
        XCTAssertGreaterThan(warm.warmth, 0.5)
        XCTAssertGreaterThan(warm.energy, curious.energy)
        XCTAssertGreaterThan(serious.gravity, 0.5)
        XCTAssertGreaterThan(chineseEmpathy.empathy, 0.5)
    }

    func testSpeechExpressionUsesExistingRigAndHonorsReducedMotion() {
        let plan = CaptainAyerSpeechExpressionPlanner.plan(
            for: "Thank you! Would you like to continue?"
        )
        let animated = CaptainAyerSpeechExpressionPlanner.renderState(
            for: plan,
            progress: 0.72,
            elapsed: 1.8
        )
        XCTAssertNotNil(animated.leftBrowFrame)
        XCTAssertNotNil(animated.rightBrowFrame)
        XCTAssertNotNil(animated.gazeFrame)
        XCTAssertLessThanOrEqual(abs(animated.headPose.yaw), 1)
        XCTAssertLessThanOrEqual(abs(animated.headPose.pitch), 1)
        XCTAssertLessThanOrEqual(abs(animated.headPose.roll), 1)

        let reduced = CaptainAyerSpeechExpressionPlanner.renderState(
            for: plan,
            progress: 0.72,
            elapsed: 1.8,
            reduceMotion: true
        )
        XCTAssertNil(reduced.gazeFrame)
        XCTAssertNil(reduced.leftEye)
        XCTAssertNil(reduced.rightEye)
        XCTAssertEqual(reduced.headPose, .zero)
        XCTAssertNotNil(reduced.leftBrowFrame)
    }

    func testSpeechExpressionTimelineSwitchesIntentAtPhraseBoundaries() throws {
        let timeline = CaptainAyerSpeechExpressionPlanner.timeline(
            for: "Haha, this is hilarious! But I am horrified and afraid. Finally I am furious.",
            duration: 9
        )
        XCTAssertGreaterThanOrEqual(timeline.cues.count, 3)
        let laugh = timeline.state(at: 0.2).plan
        let horrorCue = try XCTUnwrap(timeline.cues.first { $0.plan.fear > 0 })
        let angerCue = try XCTUnwrap(timeline.cues.first { $0.plan.anger > 0 })
        XCTAssertGreaterThan(laugh.laughter, 0.5)
        XCTAssertGreaterThan(
            timeline.state(at: horrorCue.start + 0.05).plan.fear,
            0.5
        )
        XCTAssertGreaterThan(
            timeline.state(at: angerCue.start + 0.05).plan.anger,
            0.5
        )
    }

    func testPhraseExpressionRetargetCrossfadesForDesktopParityWithoutNeutralPop() {
        let laughter = CaptainAyerSpeechExpressionPlanner.plan(
            for: "Haha, this is hilarious laughter."
        )
        let horror = CaptainAyerSpeechExpressionPlanner.plan(
            for: "I am horrified, terrified, and afraid."
        )
        var transition = CaptainAyerSpeechExpressionTransitionState(
            initial: laughter,
            at: 10
        )

        let boundary = transition.sample(target: horror, at: 10)
        XCTAssertEqual(
            boundary,
            laughter,
            "A phrase boundary must retain the exact face already on screen"
        )

        let midpoint = transition.sample(target: horror, at: 10.18)
        XCTAssertEqual(midpoint.laughter, laughter.laughter * 0.5, accuracy: 0.0001)
        XCTAssertEqual(midpoint.fear, horror.fear * 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(midpoint.laughter, 0)
        XCTAssertGreaterThan(midpoint.fear, 0)

        let settled = transition.sample(target: horror, at: 10.36)
        XCTAssertEqual(settled, horror)
        XCTAssertEqual(
            CaptainAyerSpeechExpressionTransitionPolicy.duration,
            0.36,
            accuracy: 0.0001
        )
    }

    func testExpressionRetargetDuringCrossfadeStartsFromDisplayedFace() {
        let laughter = CaptainAyerSpeechExpressionPlanner.plan(for: "Haha, hilarious.")
        let sorrow = CaptainAyerSpeechExpressionPlanner.plan(for: "I feel tragic sorrow.")
        let anger = CaptainAyerSpeechExpressionPlanner.plan(for: "I am furious and angry.")
        var transition = CaptainAyerSpeechExpressionTransitionState(
            initial: laughter,
            at: 2
        )
        _ = transition.sample(target: sorrow, at: 2)
        let displayed = transition.sample(target: sorrow, at: 2.12)
        let retargeted = transition.sample(target: anger, at: 2.12)

        XCTAssertEqual(retargeted, displayed)
        let afterOneFrame = transition.sample(target: anger, at: 2.12 + 1.0 / 60.0)
        XCTAssertLessThan(afterOneFrame.sadness, displayed.sadness)
        XCTAssertGreaterThan(afterOneFrame.anger, displayed.anger)
    }

    func testApprovedEmotionMouthTuningMatchesDesktopV22() {
        let laughter = CaptainAyerSpeechExpressionPlanner.renderState(
            for: CaptainAyerSpeechExpressionPlanner.plan(for: "Haha, hilarious laughter!"),
            progress: 0.5,
            elapsed: 1
        )
        XCTAssertEqual(laughter.expressionLayers.smile, 0.18, accuracy: 0.0001)
        XCTAssertNil(laughter.leftBrowFrame, "Approved laughter is mouth-only")
        XCTAssertEqual(laughter.expressionLayers.cheek, 0, accuracy: 0.0001)

        let sorrow = CaptainAyerSpeechExpressionPlanner.renderState(
            for: CaptainAyerSpeechExpressionPlanner.plan(for: "I am heartbroken with sorrow."),
            progress: 0.5,
            elapsed: 1
        )
        let horror = CaptainAyerSpeechExpressionPlanner.renderState(
            for: CaptainAyerSpeechExpressionPlanner.plan(for: "I am horrified and terrified."),
            progress: 0.5,
            elapsed: 1
        )
        let anger = CaptainAyerSpeechExpressionPlanner.renderState(
            for: CaptainAyerSpeechExpressionPlanner.plan(for: "I am furious and angry."),
            progress: 0.5,
            elapsed: 1
        )
        XCTAssertGreaterThan(sorrow.expressionLayers.sorrowMouth, 0)
        XCTAssertGreaterThan(horror.expressionLayers.horrorMouth, 0)
        XCTAssertGreaterThan(anger.expressionLayers.angerMouth, 0)
        XCTAssertGreaterThan(anger.expressionLayers.angerMouth, horror.expressionLayers.horrorMouth)
    }

    func testLongUtteranceKeepsExpressionUntilAudioActuallyFinishes() {
        let plan = CaptainAyerSpeechExpressionPlanner.plan(
            for: "Haha, this hilarious laughter makes me joyful."
        )
        let middle = CaptainAyerSpeechExpressionPlanner.renderState(
            for: plan,
            progress: 0.50,
            elapsed: 30
        )
        let finalFivePercent = CaptainAyerSpeechExpressionPlanner.renderState(
            for: plan,
            progress: 0.95,
            elapsed: 57
        )

        XCTAssertEqual(finalFivePercent.expressionLayers.smile, 0.18, accuracy: 0.0001)
        XCTAssertEqual(
            finalFivePercent.expressionLayers.smile,
            middle.expressionLayers.smile,
            accuracy: 0.0001,
            "A 60-second answer must not spend its final six seconds fading neutral"
        )
    }

    func testSemanticOpenEyesCapAmbientBlinkForFearAndAngerOnly() {
        let fullBlink = CaptainAyerEyeClosurePolicy.state(amount: 1)
        let ambient = CaptainAyerFaceReactionRenderState(
            gazeFrame: nil,
            leftEye: fullBlink,
            rightEye: fullBlink,
            leftBrowFrame: nil,
            rightBrowFrame: nil,
            wideMouthOpacity: 0
        )
        for words in [
            "I am horrified and terrified with fear.",
            "I am furious, outraged, and angry.",
        ] {
            let speech = CaptainAyerSpeechExpressionPlanner.renderState(
                for: CaptainAyerSpeechExpressionPlanner.plan(for: words),
                progress: 0.5,
                elapsed: 1
            )
            let merged = ambient.mergingSpeech(speech)
            let maximum = try? XCTUnwrap(speech.maximumEyeClosure)
            XCTAssertLessThan(CaptainAyerEyeClosurePolicy.amount(merged.leftEye), 1)
            XCTAssertLessThanOrEqual(
                CaptainAyerEyeClosurePolicy.amount(merged.leftEye),
                (maximum ?? 1) + 0.0001
            )
        }

        let laughter = CaptainAyerSpeechExpressionPlanner.renderState(
            for: CaptainAyerSpeechExpressionPlanner.plan(for: "Haha, joyful laughter."),
            progress: 0.5,
            elapsed: 1
        )
        XCTAssertNil(laughter.maximumEyeClosure)
        XCTAssertEqual(ambient.mergingSpeech(laughter).leftEye, fullBlink)
    }

    func testSpeechExpressionReleaseStartsFromDisplayedFaceAndSettlesIn280ms() {
        let spoken = CaptainAyerSpeechExpressionPlanner.renderState(
            for: CaptainAyerSpeechExpressionPlanner.plan(for: "I am horrified and afraid."),
            progress: 1,
            elapsed: 2
        )
        XCTAssertEqual(
            CaptainAyerSpeechExpressionReleasePolicy.value(from: spoken, progress: 0),
            spoken
        )
        let halfway = CaptainAyerSpeechExpressionReleasePolicy.value(
            from: spoken,
            progress: 0.5
        )
        XCTAssertEqual(
            halfway.expressionLayers.horrorMouth,
            spoken.expressionLayers.horrorMouth * 0.5,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(
            halfway.maximumEyeClosure ?? -1,
            spoken.maximumEyeClosure ?? -1,
            "Releasing horror must relax the open-eye cap toward normal blinking."
        )
        XCTAssertEqual(
            CaptainAyerSpeechExpressionReleasePolicy.value(from: spoken, progress: 1),
            .idle
        )
        XCTAssertEqual(
            CaptainAyerSpeechExpressionReleasePolicy.duration,
            0.28,
            accuracy: 0.0001
        )
    }

    func testSpeechExpressionReleaseReturnsGazeAndBrowsTowardNeutral() {
        XCTAssertEqual(
            CaptainAyerDiscreteFaceReleasePolicy.frame(
                from: 0,
                columns: 25,
                rows: 11,
                neutralColumn: 12,
                neutralRow: 5,
                progress: 0
            ),
            0
        )
        XCTAssertEqual(
            CaptainAyerDiscreteFaceReleasePolicy.frame(
                from: 0,
                columns: 25,
                rows: 11,
                neutralColumn: 12,
                neutralRow: 5,
                progress: 0.5
            ),
            3 * 25 + 6
        )
        XCTAssertEqual(
            CaptainAyerDiscreteFaceReleasePolicy.frame(
                from: 0,
                columns: 25,
                rows: 11,
                neutralColumn: 12,
                neutralRow: 5,
                progress: 1
            ),
            5 * 25 + 12
        )
        XCTAssertEqual(
            CaptainAyerDiscreteFaceReleasePolicy.frame(
                from: 41,
                columns: 14,
                rows: 3,
                neutralColumn: 4,
                neutralRow: 1,
                progress: 1
            ),
            18
        )
    }

    func testInteractiveReactionKeepsPriorityOverSpeechExpression() throws {
        let eye = CaptainAyerEyeReactionState(
            lowerFrame: nil,
            upperFrame: 7,
            upperOpacity: 1
        )
        let interaction = CaptainAyerFaceReactionRenderState(
            gazeFrame: 42,
            leftEye: eye,
            rightEye: nil,
            leftBrowFrame: nil,
            rightBrowFrame: nil,
            wideMouthOpacity: 0,
            headPose: .zero
        )
        let speech = CaptainAyerSpeechExpressionPlanner.renderState(
            for: CaptainAyerSpeechExpressionPlanner.plan(for: "Wonderful!"),
            progress: 0.5,
            elapsed: 1
        )
        let merged = interaction.mergingSpeech(speech)

        XCTAssertEqual(merged.gazeFrame, 42)
        XCTAssertEqual(merged.leftEye, eye)
        XCTAssertNotNil(merged.leftBrowFrame)
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
    func testControllerRejectsStaleGenerationAndReleasesOnFinish() {
        let controller = CaptainAyerLipSyncController()
        controller.prepare(text: "Aye", generation: 7)

        controller.begin(generation: 6, duration: 1)
        XCTAssertEqual(controller.phase, .prepared)

        controller.begin(generation: 7, duration: 1)
        XCTAssertTrue(controller.isSpeaking)
        controller.finish(generation: 6)
        XCTAssertTrue(controller.isSpeaking)

        let finishDate = Date().addingTimeInterval(1)
        controller.finish(generation: 7, at: finishDate)
        XCTAssertEqual(controller.phase, .releasing)
        XCTAssertNil(controller.generation)
        XCTAssertEqual(controller.renderState(), .idle)
        XCTAssertNotEqual(controller.expressionRenderState(at: finishDate), .idle)
        XCTAssertEqual(
            controller.expressionRenderState(
                at: finishDate.addingTimeInterval(0.28)
                    .addingTimeInterval(0.001)
            ),
            .idle
        )
        controller.cancelAll()
        XCTAssertEqual(controller.phase, .idle)
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
        XCTAssertEqual(CaptainAyerInteractionLayer.avatar.toggled, .thread)
        XCTAssertEqual(CaptainAyerInteractionLayer.thread.toggled, .avatar)
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
        XCTAssertEqual(session.request(.edgeIdle, canStart: true), .none)
        XCTAssertEqual(
            session.activeKind,
            .edgeIdle,
            "Re-selecting a display mode must be idempotent, not a hidden toggle"
        )
        XCTAssertEqual(session.interrupt(), .stop(.edgeIdle))
        XCTAssertNil(session.activeKind)

        for _ in 0 ..< 4 {
            XCTAssertEqual(session.request(.moves, canStart: true), .start(.moves))
            XCTAssertEqual(session.interrupt(), .stop(.moves))
            XCTAssertNil(session.activeKind)
        }
        XCTAssertEqual(session.interrupt(), .none)
    }

    func testFiveAvatarModesMapToOneStandbyCloseupAndThreeMotionKinds() {
        XCTAssertEqual(
            OpenClamAvatarDisplayMode.allCases,
            [.standby, .closeUp, .horizonWalk, .edgeIdle, .moves]
        )
        XCTAssertNil(OpenClamAvatarDisplayMode.standby.motionKind)
        XCTAssertNil(OpenClamAvatarDisplayMode.closeUp.motionKind)
        XCTAssertEqual(OpenClamAvatarDisplayMode.horizonWalk.motionKind, .walk)
        XCTAssertEqual(OpenClamAvatarDisplayMode.edgeIdle.motionKind, .edgeIdle)
        XCTAssertEqual(OpenClamAvatarDisplayMode.moves.motionKind, .moves)
        XCTAssertEqual(
            OpenClamAvatarDisplayMode(motionKind: .walk),
            .horizonWalk
        )
    }

    func testAvatarOrThreadActivityReturnsOnlyTransientMotionToStandby() {
        XCTAssertEqual(OpenClamAvatarDisplayMode.horizonWalk.afterUserActivity, .standby)
        XCTAssertEqual(OpenClamAvatarDisplayMode.edgeIdle.afterUserActivity, .standby)
        XCTAssertEqual(OpenClamAvatarDisplayMode.moves.afterUserActivity, .standby)
        XCTAssertEqual(OpenClamAvatarDisplayMode.standby.afterUserActivity, .standby)
        XCTAssertEqual(OpenClamAvatarDisplayMode.closeUp.afterUserActivity, .closeUp)
    }

    func testStandbyTransformPersistsScaleAndNormalizedPositionDefensively() {
        let moved = OpenClamAvatarStandbyTransformPolicy.translated(
            from: CGPoint(x: 0.10, y: -0.20),
            by: CGSize(width: 80, height: 120),
            in: CGSize(width: 400, height: 800)
        )
        XCTAssertEqual(moved.x, 0.30, accuracy: 0.0001)
        XCTAssertEqual(moved.y, -0.05, accuracy: 0.0001)

        let sanitized = OpenClamAvatarStandbyTransformPolicy.sanitized(
            scale: 99,
            normalizedOffset: CGPoint(x: 4, y: -4)
        )
        XCTAssertEqual(
            sanitized.scale,
            CaptainAyerOverlayTuning.maximumScale,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            sanitized.normalizedOffset.x,
            OpenClamAvatarStandbyTransformPolicy.maximumNormalizedOffset,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            sanitized.normalizedOffset.y,
            -OpenClamAvatarStandbyTransformPolicy.maximumNormalizedOffset,
            accuracy: 0.0001
        )
    }

    func testFactoryStandbyResetMatchesDefaultSizeAndLocation() {
        XCTAssertEqual(OpenClamAvatarStandbyTransform.factory.scale, 1)
        XCTAssertEqual(
            OpenClamAvatarStandbyTransform.factory.normalizedOffset,
            .zero
        )
    }

    func testStandbyDragUsesPositionWhileCloseupRetainsGaze() {
        XCTAssertEqual(
            CaptainAyerAvatarGesturePolicy.dragIntent(
                translation: CGSize(width: 30, height: 8),
                supportsOpacity: true,
                supportsPosition: true
            ),
            .position
        )
        XCTAssertEqual(
            CaptainAyerAvatarGesturePolicy.dragIntent(
                translation: CGSize(width: 30, height: 8),
                supportsOpacity: true,
                supportsPosition: false
            ),
            .gaze
        )
        XCTAssertEqual(
            CaptainAyerAvatarGesturePolicy.dragIntent(
                translation: CGSize(width: 2, height: 30),
                supportsOpacity: true,
                supportsPosition: true
            ),
            .position
        )
        XCTAssertEqual(
            CaptainAyerAvatarGesturePolicy.dragIntent(
                translation: CGSize(width: 2, height: 30),
                supportsOpacity: true,
                supportsPosition: false
            ),
            .opacity
        )
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
