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
    func testPublicGuideSpriteSheetsAreBundledAtExactFrameDimensions() throws {
        let guide = try XCTUnwrap(OpenClamAvatarCatalog.avatar(id: "captain-ayer"))
        let expected: [(OpenClamAvatarAssetRole, (Int, Int))] = [
            (.eyeLeft, (4, 32)),
            (.eyeRight, (4, 32)),
            (.browLeft, (4, 126)),
            (.browRight, (4, 126)),
            (.gazeLeftAtlas, (100, 44)),
            (.gazeRightAtlas, (100, 44)),
        ]

        for (role, dimensions) in expected {
            let image = try XCTUnwrap(
                OpenClamAvatarAssetStore.shared.image(for: guide, role: role),
                "Missing public guide sprite: \(role)"
            )
            let cgImage = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(cgImage.width, dimensions.0)
            XCTAssertEqual(cgImage.height, dimensions.1)
        }
    }
}
