import UIKit
import XCTest
@testable import OpenClamLiveKit

final class CaptainAyerFaceReactionTests: XCTestCase {
    func testNormalizedHitMapPreservesAllFaceRegions() {
        XCTAssertEqual(CaptainAyerFaceHitMap.region(at: CGPoint(x: 0.5, y: 0.2)), .brow)
        XCTAssertEqual(CaptainAyerFaceHitMap.region(at: CGPoint(x: 0.2, y: 0.5)), .leftEye)
        XCTAssertEqual(CaptainAyerFaceHitMap.region(at: CGPoint(x: 0.8, y: 0.5)), .rightEye)
        XCTAssertEqual(CaptainAyerFaceHitMap.region(at: CGPoint(x: 0.2, y: 0.7)), .leftCheek)
        XCTAssertEqual(CaptainAyerFaceHitMap.region(at: CGPoint(x: 0.5, y: 0.7)), .nose)
        XCTAssertEqual(CaptainAyerFaceHitMap.region(at: CGPoint(x: 0.8, y: 0.7)), .rightCheek)
        XCTAssertEqual(CaptainAyerFaceHitMap.region(at: CGPoint(x: 0.5, y: 0.9)), .mouth)
        XCTAssertNil(CaptainAyerFaceHitMap.region(at: CGPoint(x: 1.2, y: 0.5)))
    }

    func testFullBodyHitMapIncludesHandsAndMeaningfulZones() {
        XCTAssertEqual(
            CaptainAyerBodyHitMap.region(at: CGPoint(x: 0.50, y: 0.10)),
            .head
        )
        XCTAssertEqual(
            CaptainAyerBodyHitMap.region(at: CGPoint(x: 0.30, y: 0.53)),
            .leadingHand
        )
        XCTAssertEqual(
            CaptainAyerBodyHitMap.region(at: CGPoint(x: 0.70, y: 0.53)),
            .trailingHand
        )
        XCTAssertEqual(
            CaptainAyerBodyHitMap.region(at: CGPoint(x: 0.44, y: 0.275)),
            .heart
        )
        XCTAssertEqual(
            CaptainAyerBodyHitMap.region(at: CGPoint(x: 0.50, y: 0.45)),
            .torso
        )
        XCTAssertEqual(
            CaptainAyerBodyHitMap.region(at: CGPoint(x: 0.50, y: 0.72)),
            .lowerBody
        )
        XCTAssertEqual(
            CaptainAyerBodyHitMap.region(at: CGPoint(x: 0.50, y: 0.94)),
            .feet
        )
        XCTAssertNil(CaptainAyerBodyHitMap.region(at: CGPoint(x: 0.05, y: 0.80)))
    }

    func testAmbientBlinkPlansArePairedAsymmetricAndSometimesPartial() {
        let partialPlan = CaptainAyerAmbientMotionPlanner.blinkPlan(
            delaySample: 0,
            durationSample: 0.5,
            offsetSample: 0.5,
            characterSample: 0.10,
            leadingEyeSample: 0.2,
            asymmetrySample: 0.5
        )
        XCTAssertEqual(partialPlan.leadingEye, .left)
        XCTAssertGreaterThanOrEqual(partialPlan.delay, 2.8)
        XCTAssertGreaterThan(partialPlan.followingEyeDelay, 0)
        XCTAssertLessThan(partialPlan.leftPeakClosure, 0.80)
        XCTAssertLessThan(partialPlan.rightPeakClosure, 0.80)

        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let event = partialPlan.event(startingAt: start)
        XCTAssertNotEqual(event.leftStart, event.rightStart)
        let overlap = start.addingTimeInterval(partialPlan.duration * 0.39)
        let leftClosure = event.closure(for: .left, at: overlap)
        let rightClosure = event.closure(for: .right, at: overlap)
        XCTAssertGreaterThan(leftClosure, 0.50)
        XCTAssertGreaterThan(rightClosure, 0.40)
        XCTAssertNotEqual(leftClosure, rightClosure, accuracy: 0.0001)

        let fullPlan = CaptainAyerAmbientMotionPlanner.blinkPlan(
            delaySample: 1,
            durationSample: 1,
            offsetSample: 1,
            characterSample: 0.8,
            leadingEyeSample: 0.8,
            asymmetrySample: 0.8
        )
        XCTAssertEqual(fullPlan.leadingEye, .right)
        XCTAssertGreaterThanOrEqual(fullPlan.leftPeakClosure, 0.92)
        XCTAssertGreaterThanOrEqual(fullPlan.rightPeakClosure, 0.94)
        XCTAssertLessThanOrEqual(fullPlan.followingEyeDelay, 0.034)
    }

    func testAmbientIrisPlanStaysSubtleAndReturnsHome() throws {
        let plan = CaptainAyerAmbientMotionPlanner.gazePlan(
            delaySample: 0.4,
            horizontalSample: 1,
            verticalSample: 0,
            paceSample: 0.5,
            dwellSample: 0.5
        )
        XCTAssertLessThanOrEqual(abs(plan.target.x), 0.22)
        XCTAssertLessThanOrEqual(abs(plan.target.y), 0.28)
        XCTAssertGreaterThanOrEqual(plan.delay, 5.0)

        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        let event = plan.event(startingAt: start)
        let dwell = try XCTUnwrap(
            event.direction(
                at: start.addingTimeInterval(plan.acquireDuration + 0.1)
            )
        )
        XCTAssertEqual(dwell.x, plan.target.x, accuracy: 0.0001)
        XCTAssertEqual(dwell.y, plan.target.y, accuracy: 0.0001)
        XCTAssertNil(
            event.direction(at: start.addingTimeInterval(plan.totalDuration))
        )
    }

    func testAmbientIrisDutyCycleStaysLowAcrossDeterministicExtremes() {
        let samples = [0.0, 1.0]
        let plans = samples.flatMap { delay in
            samples.flatMap { pace in
                samples.map { dwell in
                    CaptainAyerAmbientMotionPlanner.gazePlan(
                        delaySample: delay,
                        horizontalSample: 1,
                        verticalSample: 0,
                        paceSample: pace,
                        dwellSample: dwell
                    )
                }
            }
        }
        let dutyCycles = plans.map(\.activeDutyCycle)
        let averageDutyCycle = dutyCycles.reduce(0, +) / Double(dutyCycles.count)

        XCTAssertLessThanOrEqual(dutyCycles.max() ?? 1, 0.25)
        XCTAssertGreaterThanOrEqual(averageDutyCycle, 0.15)
        XCTAssertLessThanOrEqual(averageDutyCycle, 0.25)
    }

    @MainActor
    func testExactReactionDurationsAndPeakPoses() {
        let start = Date()

        let wink = CaptainAyerFaceReactionController()
        XCTAssertTrue(wink.react(to: .leftEye, at: start))
        XCTAssertEqual(
            wink.renderState(at: start.addingTimeInterval(0.280)).leftEye?.upperFrame,
            7
        )
        XCTAssertNil(
            wink.renderState(
                at: start.addingTimeInterval(CaptainAyerFaceReactionController.winkDuration)
            ).leftEye
        )
        wink.cancelAll()

        let brow = CaptainAyerFaceReactionController()
        XCTAssertTrue(brow.react(to: .brow, at: start))
        XCTAssertNotNil(brow.renderState(at: start.addingTimeInterval(0.375)).leftBrowFrame)
        XCTAssertNil(
            brow.renderState(
                at: start.addingTimeInterval(CaptainAyerFaceReactionController.browDuration)
            ).leftBrowFrame
        )
        brow.cancelAll()

        let mouth = CaptainAyerFaceReactionController()
        XCTAssertTrue(mouth.react(to: .mouth, at: start))
        XCTAssertEqual(
            mouth.renderState(at: start.addingTimeInterval(0.475)).wideMouthOpacity,
            0.8,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            mouth.renderState(
                at: start.addingTimeInterval(CaptainAyerFaceReactionController.mouthDuration)
            ).wideMouthOpacity,
            0
        )
        mouth.cancelAll()
    }

    @MainActor
    func testFlourishAndReducedMotionSnapshotRemainVisible() {
        let controller = CaptainAyerFaceReactionController()
        let start = Date()
        controller.flourish(at: start)

        let animated = controller.renderState(at: start.addingTimeInterval(0.25))
        XCTAssertTrue(animated.leftEye != nil || animated.rightEye != nil)
        XCTAssertNotNil(animated.leftBrowFrame)
        XCTAssertGreaterThan(animated.wideMouthOpacity, 0)

        let reduced = controller.reducedMotionRenderState(at: start)
        XCTAssertTrue(reduced.leftEye != nil || reduced.rightEye != nil)
        XCTAssertNotNil(reduced.leftBrowFrame)
        XCTAssertEqual(reduced.wideMouthOpacity, 0.8)
        controller.cancelAll()
    }

    @MainActor
    func testHandTapCreatesRestrainedCoordinatedReaction() {
        let controller = CaptainAyerFaceReactionController()
        let start = Date()
        XCTAssertTrue(controller.react(to: .leadingHand, at: start))

        let state = controller.renderState(at: start.addingTimeInterval(0.28))
        XCTAssertNotNil(state.leftEye)
        XCTAssertGreaterThan(state.wideMouthOpacity, 0)
        XCTAssertNotNil(state.gazeFrame)
        XCTAssertLessThan(abs(state.headPose.yaw), 0.13)
        XCTAssertLessThan(abs(state.headPose.roll), 0.19)
        controller.cancelAll()
    }

    @MainActor
    func testTapThrottleRejectsOnlyRapidRepeat() {
        let controller = CaptainAyerFaceReactionController()
        let start = Date()
        XCTAssertTrue(controller.react(to: .leftEye, at: start))
        XCTAssertFalse(controller.react(to: .rightEye, at: start.addingTimeInterval(0.699)))
        XCTAssertTrue(controller.react(to: .rightEye, at: start.addingTimeInterval(0.700)))
        controller.cancelAll()
    }

    @MainActor
    func testGazeFollowsTouchAndReturnsToNeutralAfterRelease() {
        let controller = CaptainAyerFaceReactionController()
        let start = Date()
        controller.updateGaze(toward: CGPoint(x: 1, y: 1), at: start)

        XCTAssertTrue(controller.isTrackingGaze)
        XCTAssertTrue(controller.isGazeAnimating)
        XCTAssertEqual(
            controller.renderState(
                at: start.addingTimeInterval(
                    CaptainAyerFaceReactionController.gazeAcquireDuration
                )
            ).gazeFrame,
            219
        )

        let release = start.addingTimeInterval(
            CaptainAyerFaceReactionController.gazeAcquireDuration
        )
        controller.releaseGaze(at: release)
        XCTAssertFalse(controller.isTrackingGaze)
        XCTAssertTrue(controller.isGazeAnimating)
        XCTAssertNotEqual(
            controller.renderState(at: release.addingTimeInterval(0.08)).gazeFrame,
            137
        )
        XCTAssertEqual(
            controller.renderState(
                at: release.addingTimeInterval(
                    CaptainAyerFaceReactionController.gazeReturnDuration
                )
            ).gazeFrame,
            137
        )
        controller.cancelGaze()
        XCTAssertNil(controller.renderState().gazeFrame)
    }

    @MainActor
    func testReducedMotionGazeTracksDirectlyAndSnapsHome() {
        let controller = CaptainAyerFaceReactionController()
        let start = Date()
        controller.updateGaze(toward: CGPoint(x: -1, y: -1), at: start)

        XCTAssertEqual(controller.reducedMotionRenderState(at: start).gazeFrame, 55)
        controller.releaseGaze(at: start, reduceMotion: true)
        XCTAssertFalse(controller.isGazeAnimating)
        XCTAssertNil(controller.reducedMotionRenderState(at: start).gazeFrame)
    }

    func testSpriteFrameOffsetsClampToBundledBanks() {
        XCTAssertEqual(CaptainAyerSpriteSheet.verticalOffsetInFrames(0, frameCount: 8), 0)
        XCTAssertEqual(CaptainAyerSpriteSheet.verticalOffsetInFrames(7, frameCount: 8), -7)
        XCTAssertEqual(CaptainAyerSpriteSheet.verticalOffsetInFrames(99, frameCount: 8), -7)
        XCTAssertEqual(CaptainAyerSpriteSheet.verticalOffsetInFrames(-2, frameCount: 42), 0)
    }

    @MainActor
    func testEyeAndBrowSpriteSheetsAreBundledAtExactFrameDimensions() throws {
        let expected = [
            "CaptainAyerEyeLeft": (182, 832),
            "CaptainAyerEyeRight": (176, 840),
            "CaptainAyerBrowLeft": (213, 4_368),
            "CaptainAyerBrowRight": (214, 4_284),
            "CaptainAyerGazeLeftAtlas": (2_875, 649),
            "CaptainAyerGazeRightAtlas": (2_875, 671),
        ]

        for (name, dimensions) in expected {
            let image = try XCTUnwrap(UIImage(named: name), "Missing sprite asset: \(name)")
            let cgImage = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(cgImage.width, dimensions.0, name)
            XCTAssertEqual(cgImage.height, dimensions.1, name)
        }
    }
}
