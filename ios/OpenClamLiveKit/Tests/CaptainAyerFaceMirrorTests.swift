import XCTest
@testable import OpenClamLiveKit

final class CaptainAyerFaceMirrorTests: XCTestCase {
    func testMouthMappingKeepsVivieensLocalFaceThresholds() {
        let open = CaptainAyerFaceMirrorMapper.expression(
            for: CaptainAyerFaceMirrorRawSample(jawOpen: 0.60)
        )
        XCTAssertEqual(open.mouthViseme, .open)
        XCTAssertGreaterThan(open.mouthBlend, 0.80)

        let rounded = CaptainAyerFaceMirrorMapper.expression(
            for: CaptainAyerFaceMirrorRawSample(
                jawOpen: 0.40,
                mouthPucker: 0.65
            )
        )
        XCTAssertEqual(rounded.mouthViseme, .rounded)

        let smiling = CaptainAyerFaceMirrorMapper.expression(
            for: CaptainAyerFaceMirrorRawSample(
                smileLeft: 0.75,
                smileRight: 0.70
            )
        )
        XCTAssertEqual(smiling.mouthViseme, .narrow)

        XCTAssertEqual(
            CaptainAyerFaceMirrorMapper.expression(for: .neutral),
            .idle
        )
    }

    func testMapperBoundsBlinkBrowGazeAndHeadPose() {
        let expression = CaptainAyerFaceMirrorMapper.expression(
            for: CaptainAyerFaceMirrorRawSample(
                blinkLeft: 2,
                blinkRight: -1,
                browInnerUp: 0.80,
                browOuterUpLeft: 0.95,
                browOuterUpRight: 0.20,
                eyeGaze: CGPoint(x: 8, y: -8),
                headYaw: 4,
                headPitch: -4,
                headRoll: 4
            )
        )

        XCTAssertEqual(expression.leftBlink, 1, accuracy: 0.0001)
        XCTAssertEqual(expression.rightBlink, 0, accuracy: 0.0001)
        XCTAssertEqual(expression.leftBrowRaise, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(expression.rightBrowRaise, 0.9)
        XCTAssertEqual(expression.gaze.x, 1, accuracy: 0.0001)
        XCTAssertEqual(expression.gaze.y, -1, accuracy: 0.0001)
        XCTAssertEqual(expression.headPose.yaw, 1, accuracy: 0.0001)
        XCTAssertEqual(expression.headPose.pitch, -1, accuracy: 0.0001)
        XCTAssertEqual(expression.headPose.roll, 1, accuracy: 0.0001)
    }

    func testSmootherAcquiresBlinkQuicklyWithoutOvershoot() {
        var smoother = CaptainAyerFaceMirrorSmoother()
        _ = smoother.update(with: .neutral)
        let filtered = smoother.update(
            with: CaptainAyerFaceMirrorRawSample(
                blinkLeft: 1,
                eyeGaze: CGPoint(x: 1, y: -1),
                headYaw: 0.45
            )
        )

        XCTAssertGreaterThan(filtered.leftBlink, 0.5)
        XCTAssertLessThan(filtered.leftBlink, 1)
        XCTAssertGreaterThan(filtered.gaze.x, 0)
        XCTAssertLessThan(filtered.gaze.x, 1)
        XCTAssertGreaterThan(filtered.headPose.yaw, 0)
        XCTAssertLessThan(filtered.headPose.yaw, 1)

        smoother.reset()
        let reacquired = smoother.update(
            with: CaptainAyerFaceMirrorRawSample(blinkLeft: 1)
        )
        XCTAssertEqual(reacquired.leftBlink, 1, accuracy: 0.0001)
    }

    func testMirrorRenderMapperDrivesEveryBundledFaceChannel() {
        let pose = CaptainAyerFaceMirrorHeadPose(
            yaw: 0.7,
            pitch: -0.5,
            roll: 0.3
        )
        let expression = CaptainAyerFaceMirrorExpression(
            mouthViseme: .open,
            mouthBlend: 0.8,
            leftBlink: 1,
            rightBlink: 0.55,
            leftBrowRaise: 0.8,
            rightBrowRaise: 0.6,
            gaze: CGPoint(x: 0.7, y: -0.5),
            headPose: pose
        )

        let render = CaptainAyerFaceMirrorRenderMapper.renderState(
            for: expression
        )
        XCTAssertNotNil(render.gazeFrame)
        XCTAssertNotNil(render.leftEye)
        XCTAssertNotNil(render.rightEye)
        XCTAssertNotNil(render.leftBrowFrame)
        XCTAssertNotNil(render.rightBrowFrame)
        XCTAssertEqual(render.headPose, pose)
        XCTAssertEqual(expression.mouthRenderState.current, .open)
        XCTAssertEqual(expression.mouthRenderState.blend, 0.8, accuracy: 0.0001)

        let reduced = CaptainAyerFaceMirrorRenderMapper.renderState(
            for: expression,
            reduceMotion: true
        )
        XCTAssertNil(reduced.gazeFrame)
        XCTAssertEqual(reduced.headPose, .zero)
        XCTAssertNotNil(reduced.leftEye)
        XCTAssertNotNil(reduced.leftBrowFrame)
    }
}
