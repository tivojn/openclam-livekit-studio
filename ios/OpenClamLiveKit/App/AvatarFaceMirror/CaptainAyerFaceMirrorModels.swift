import CoreGraphics
import Foundation

/// The bounded subset of ARKit face data that Captain Ayer can actually
/// render. No image, depth map, or camera frame leaves the capture session.
struct CaptainAyerFaceMirrorRawSample: Equatable, Sendable {
    var jawOpen: Double = 0
    var mouthPucker: Double = 0
    var mouthFunnel: Double = 0
    var smileLeft: Double = 0
    var smileRight: Double = 0
    var blinkLeft: Double = 0
    var blinkRight: Double = 0
    var browInnerUp: Double = 0
    var browOuterUpLeft: Double = 0
    var browOuterUpRight: Double = 0
    /// Eye direction normalized around the camera: -1...1 on each axis.
    var eyeGaze = CGPoint.zero
    /// Face-anchor rotations in radians.
    var headYaw: Double = 0
    var headPitch: Double = 0
    var headRoll: Double = 0

    static let neutral = CaptainAyerFaceMirrorRawSample()
}

/// A deliberately restrained pose. Captain Ayer's rig is a layered 2D
/// portrait, so a small motion reads as a head turn without tearing the mask.
struct CaptainAyerFaceMirrorHeadPose: Equatable, Sendable {
    let yaw: Double
    let pitch: Double
    let roll: Double

    static let zero = CaptainAyerFaceMirrorHeadPose(yaw: 0, pitch: 0, roll: 0)
}

struct CaptainAyerFaceMirrorExpression: Equatable, Sendable {
    let mouthViseme: CaptainAyerViseme
    let mouthBlend: Double
    let leftBlink: Double
    let rightBlink: Double
    let leftBrowRaise: Double
    let rightBrowRaise: Double
    let gaze: CGPoint
    let headPose: CaptainAyerFaceMirrorHeadPose

    static let idle = CaptainAyerFaceMirrorExpression(
        mouthViseme: .silence,
        mouthBlend: 1,
        leftBlink: 0,
        rightBlink: 0,
        leftBrowRaise: 0,
        rightBrowRaise: 0,
        gaze: .zero,
        headPose: .zero
    )

    var mouthRenderState: CaptainAyerAvatarRenderState {
        guard mouthViseme != .silence else { return .idle }
        return CaptainAyerAvatarRenderState(
            previous: .silence,
            current: mouthViseme,
            blend: mouthBlend
        )
    }
}

/// Vivieen's original mouth thresholds, extended to the blink, brow, gaze,
/// and head channels already present in Captain Ayer's local sprite rig.
enum CaptainAyerFaceMirrorMapper {
    static func expression(
        for sample: CaptainAyerFaceMirrorRawSample
    ) -> CaptainAyerFaceMirrorExpression {
        let jaw = unit(sample.jawOpen)
        let pucker = unit(sample.mouthPucker)
        let funnel = unit(sample.mouthFunnel)
        let smile = max(unit(sample.smileLeft), unit(sample.smileRight))

        let viseme: CaptainAyerViseme
        if jaw > 0.32 {
            viseme = pucker > 0.30 ? .rounded : .open
        } else if pucker > 0.42 {
            viseme = .rounded
        } else if jaw > 0.12 {
            viseme = smile > 0.35 ? .wide : (funnel > 0.25 ? .rounded : .narrow)
        } else if smile > 0.55 {
            viseme = .narrow
        } else {
            viseme = .silence
        }

        let mouthBlend: Double
        if viseme == .silence {
            mouthBlend = 1
        } else {
            mouthBlend = max(
                smoothStep(jaw, from: 0.06, through: 0.62),
                smoothStep(pucker, from: 0.24, through: 0.88),
                smoothStep(funnel, from: 0.18, through: 0.82),
                smoothStep(smile, from: 0.32, through: 0.90)
            )
        }

        let leftBrow = max(
            unit(sample.browInnerUp),
            unit(sample.browOuterUpLeft)
        )
        let rightBrow = max(
            unit(sample.browInnerUp),
            unit(sample.browOuterUpRight)
        )

        return CaptainAyerFaceMirrorExpression(
            mouthViseme: viseme,
            mouthBlend: mouthBlend,
            leftBlink: smoothStep(unit(sample.blinkLeft), from: 0.06, through: 0.88),
            rightBlink: smoothStep(unit(sample.blinkRight), from: 0.06, through: 0.88),
            leftBrowRaise: smoothStep(leftBrow, from: 0.04, through: 0.72),
            rightBrowRaise: smoothStep(rightBrow, from: 0.04, through: 0.72),
            gaze: CGPoint(
                x: signedUnit(sample.eyeGaze.x),
                y: signedUnit(sample.eyeGaze.y)
            ),
            headPose: CaptainAyerFaceMirrorHeadPose(
                yaw: signedUnit(sample.headYaw / 0.45),
                pitch: signedUnit(sample.headPitch / 0.35),
                roll: signedUnit(sample.headRoll / 0.40)
            )
        )
    }

    private static func unit(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }

    private static func signedUnit(_ value: Double) -> Double {
        min(1, max(-1, value.isFinite ? value : 0))
    }

    private static func signedUnit(_ value: CGFloat) -> CGFloat {
        min(1, max(-1, value.isFinite ? value : 0))
    }

    private static func smoothStep(
        _ value: Double,
        from lower: Double,
        through upper: Double
    ) -> Double {
        guard upper > lower else { return value >= upper ? 1 : 0 }
        let amount = min(1, max(0, (value - lower) / (upper - lower)))
        return amount * amount * (3 - 2 * amount)
    }
}

/// A one-pole filter keeps 30 Hz face data alive without letting sensor
/// shimmer make the sprite banks flicker. Blinks acquire faster than pose so
/// they still feel immediate; everything returns without bounce or overshoot.
struct CaptainAyerFaceMirrorSmoother: Sendable {
    private var filtered: CaptainAyerFaceMirrorRawSample?

    mutating func update(
        with target: CaptainAyerFaceMirrorRawSample
    ) -> CaptainAyerFaceMirrorExpression {
        guard var current = filtered else {
            filtered = target
            return CaptainAyerFaceMirrorMapper.expression(for: target)
        }

        current.jawOpen = mix(current.jawOpen, target.jawOpen, amount: 0.48)
        current.mouthPucker = mix(current.mouthPucker, target.mouthPucker, amount: 0.48)
        current.mouthFunnel = mix(current.mouthFunnel, target.mouthFunnel, amount: 0.48)
        current.smileLeft = mix(current.smileLeft, target.smileLeft, amount: 0.42)
        current.smileRight = mix(current.smileRight, target.smileRight, amount: 0.42)
        current.blinkLeft = mix(
            current.blinkLeft,
            target.blinkLeft,
            amount: target.blinkLeft > current.blinkLeft ? 0.76 : 0.52
        )
        current.blinkRight = mix(
            current.blinkRight,
            target.blinkRight,
            amount: target.blinkRight > current.blinkRight ? 0.76 : 0.52
        )
        current.browInnerUp = mix(current.browInnerUp, target.browInnerUp, amount: 0.36)
        current.browOuterUpLeft = mix(
            current.browOuterUpLeft,
            target.browOuterUpLeft,
            amount: 0.36
        )
        current.browOuterUpRight = mix(
            current.browOuterUpRight,
            target.browOuterUpRight,
            amount: 0.36
        )
        current.eyeGaze = CGPoint(
            x: mix(current.eyeGaze.x, target.eyeGaze.x, amount: 0.32),
            y: mix(current.eyeGaze.y, target.eyeGaze.y, amount: 0.32)
        )
        current.headYaw = mix(current.headYaw, target.headYaw, amount: 0.26)
        current.headPitch = mix(current.headPitch, target.headPitch, amount: 0.26)
        current.headRoll = mix(current.headRoll, target.headRoll, amount: 0.26)

        filtered = current
        return CaptainAyerFaceMirrorMapper.expression(for: current)
    }

    mutating func reset() {
        filtered = nil
    }

    private func mix(_ from: Double, _ to: Double, amount: Double) -> Double {
        from + (to - from) * amount
    }

    private func mix(_ from: CGFloat, _ to: CGFloat, amount: CGFloat) -> CGFloat {
        from + (to - from) * amount
    }
}
