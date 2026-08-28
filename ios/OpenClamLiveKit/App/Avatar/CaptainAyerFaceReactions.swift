import Combine
import CoreGraphics
import Foundation

enum CaptainAyerFaceRegion: Equatable, Sendable {
    case brow
    case leftEye
    case rightEye
    case leftCheek
    case nose
    case rightCheek
    case mouth
}

/// Captain Ayer's original face hit map, expressed in normalized coordinates
/// inside the bundled face bounds. Keeping the map independent of SwiftUI
/// makes it deterministic and reusable by every avatar presentation.
enum CaptainAyerFaceHitMap {
    static func region(at point: CGPoint) -> CaptainAyerFaceRegion? {
        let u = point.x
        let v = point.y
        guard u >= -0.15, u <= 1.15, v >= -0.35, v <= 1.30 else {
            return nil
        }

        if v < 0.42 { return .brow }
        if v < 0.62 { return u < 0.5 ? .leftEye : .rightEye }
        if v < 0.80 {
            if u > 0.34, u < 0.66 { return .nose }
            return u <= 0.34 ? .leftCheek : .rightCheek
        }
        if u > 0.30, u < 0.70 { return .mouth }
        return u <= 0.30 ? .leftCheek : .rightCheek
    }
}

enum CaptainAyerBodyRegion: Equatable, Sendable {
    case head
    case leadingHand
    case trailingHand
    case heart
    case torso
    case lowerBody
    case feet
}

/// Broad, forgiving hit zones in normalized full-body coordinates. The hand
/// ellipses are intentionally larger than the visible fingers so a tap still
/// feels direct on a phone-sized avatar without stealing vertical drags.
enum CaptainAyerBodyHitMap {
    static func region(at point: CGPoint) -> CaptainAyerBodyRegion? {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.x <= 1,
              point.y >= 0, point.y <= 1 else { return nil }

        if point.x >= 0.28, point.x <= 0.72, point.y <= 0.20 {
            return .head
        }
        if ellipseContains(point, center: CGPoint(x: 0.30, y: 0.53), radii: CGSize(width: 0.105, height: 0.105)) {
            return .leadingHand
        }
        if ellipseContains(point, center: CGPoint(x: 0.70, y: 0.53), radii: CGSize(width: 0.105, height: 0.105)) {
            return .trailingHand
        }
        if ellipseContains(point, center: CGPoint(x: 0.44, y: 0.275), radii: CGSize(width: 0.11, height: 0.085)) {
            return .heart
        }
        if point.x >= 0.30, point.x <= 0.70,
           point.y >= 0.18, point.y < 0.58 {
            return .torso
        }
        if point.x >= 0.31, point.x <= 0.69,
           point.y >= 0.58, point.y < 0.88 {
            return .lowerBody
        }
        if point.x >= 0.31, point.x <= 0.69, point.y >= 0.88 {
            return .feet
        }
        return nil
    }

    private static func ellipseContains(
        _ point: CGPoint,
        center: CGPoint,
        radii: CGSize
    ) -> Bool {
        let x = (point.x - center.x) / radii.width
        let y = (point.y - center.y) / radii.height
        return x * x + y * y <= 1
    }
}

enum CaptainAyerAvatarDragIntent: Equatable, Sendable {
    case pending
    case gaze
    case opacity
    case position
}

/// One intent classifier is shared by the stage and its tests so the
/// zero-distance gaze gesture cannot consume a deliberate opacity swipe.
enum CaptainAyerAvatarGesturePolicy {
    static let tapSlop: CGFloat = 8
    static let opacityThreshold: CGFloat = 18
    static let verticalDominance: CGFloat = 1.18

    static func dragIntent(
        translation: CGSize,
        supportsOpacity: Bool,
        supportsPosition: Bool = false
    ) -> CaptainAyerAvatarDragIntent {
        guard translation.width.isFinite, translation.height.isFinite else {
            return .pending
        }
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        if supportsPosition,
           hypot(horizontal, vertical) > tapSlop {
            // Standby is the one direct-manipulation mode: a drag moves the
            // companion in both axes. Opacity remains available from its rail
            // slider (and as a vertical swipe in Close-up), so it must not
            // steal a deliberate vertical repositioning gesture here.
            return .position
        }
        if supportsOpacity,
           vertical >= horizontal * verticalDominance {
            // Keep a vertically dominant touch undecided until it clears the
            // opacity threshold. This prevents a slow opacity swipe from
            // briefly steering the irises before the user's intent resolves.
            return vertical >= opacityThreshold ? .opacity : .pending
        }
        if hypot(horizontal, vertical) > tapSlop {
            return .gaze
        }
        return .pending
    }
}

enum CaptainAyerAvatarDragCompletion: Equatable, Sendable {
    case tap
    case gaze
    case opacity
    case position
}

struct CaptainAyerAvatarDragSession: Equatable, Sendable {
    private(set) var intent: CaptainAyerAvatarDragIntent = .pending
    private(set) var exceededTapSlop = false

    mutating func update(
        translation: CGSize,
        supportsOpacity: Bool,
        supportsPosition: Bool = false
    ) {
        let proposed = CaptainAyerAvatarGesturePolicy.dragIntent(
            translation: translation,
            supportsOpacity: supportsOpacity,
            supportsPosition: supportsPosition
        )
        if proposed == .opacity {
            intent = .opacity
        } else if proposed == .position, intent != .opacity {
            intent = .position
        } else if intent == .pending, proposed == .gaze {
            intent = .gaze
        }
        if hypot(translation.width, translation.height)
            > CaptainAyerAvatarGesturePolicy.tapSlop {
            exceededTapSlop = true
        }
    }

    var completion: CaptainAyerAvatarDragCompletion {
        if intent == .opacity { return .opacity }
        if intent == .position { return .position }
        return exceededTapSlop ? .gaze : .tap
    }
}

enum CaptainAyerEyeSide: Equatable, Sendable {
    case left
    case right
}

struct CaptainAyerAmbientBlinkPlan: Equatable, Sendable {
    let delay: TimeInterval
    let duration: TimeInterval
    let followingEyeDelay: TimeInterval
    let leadingEye: CaptainAyerEyeSide
    let leftPeakClosure: Double
    let rightPeakClosure: Double

    var totalDuration: TimeInterval { duration + followingEyeDelay }

    func event(startingAt date: Date) -> CaptainAyerAmbientBlinkEvent {
        let leftDelay = leadingEye == .left ? 0 : followingEyeDelay
        let rightDelay = leadingEye == .right ? 0 : followingEyeDelay
        // Slightly different durations keep the lids coordinated without
        // making their extrema land on the same frame.
        return CaptainAyerAmbientBlinkEvent(
            leftStart: date.addingTimeInterval(leftDelay),
            rightStart: date.addingTimeInterval(rightDelay),
            leftDuration: duration * (leadingEye == .left ? 1 : 0.96),
            rightDuration: duration * (leadingEye == .right ? 1 : 0.96),
            leftPeakClosure: leftPeakClosure,
            rightPeakClosure: rightPeakClosure
        )
    }
}

struct CaptainAyerAmbientBlinkEvent: Equatable, Sendable {
    let leftStart: Date
    let rightStart: Date
    let leftDuration: TimeInterval
    let rightDuration: TimeInterval
    let leftPeakClosure: Double
    let rightPeakClosure: Double

    func closure(for eye: CaptainAyerEyeSide, at date: Date) -> Double {
        switch eye {
        case .left:
            return Self.closure(
                at: date,
                start: leftStart,
                duration: leftDuration,
                peak: leftPeakClosure
            )
        case .right:
            return Self.closure(
                at: date,
                start: rightStart,
                duration: rightDuration,
                peak: rightPeakClosure
            )
        }
    }

    private static func closure(
        at date: Date,
        start: Date,
        duration: TimeInterval,
        peak: Double
    ) -> Double {
        guard duration > 0 else { return 0 }
        let progress = date.timeIntervalSince(start) / duration
        guard progress >= 0, progress < 1 else { return 0 }

        // Eyelids close quickly, pause only briefly, then reopen more softly.
        let amount: Double
        if progress < 0.34 {
            amount = smoothStep(progress / 0.34)
        } else if progress < 0.42 {
            amount = 1
        } else {
            amount = 1 - smoothStep((progress - 0.42) / 0.58)
        }
        return min(1, max(0, peak * amount))
    }

    private static func smoothStep(_ value: Double) -> Double {
        let amount = min(1, max(0, value))
        return amount * amount * (3 - 2 * amount)
    }
}

struct CaptainAyerAmbientGazePlan: Equatable, Sendable {
    let delay: TimeInterval
    /// A deliberately small fraction of the rig's already-bounded gaze bank.
    let target: CGPoint
    let acquireDuration: TimeInterval
    let dwellDuration: TimeInterval
    let returnDuration: TimeInterval

    var totalDuration: TimeInterval {
        acquireDuration + dwellDuration + returnDuration
    }

    /// Fraction of one complete idle cycle spent moving the irises. Keeping
    /// this independently testable prevents subtle idle motion from drifting
    /// into near-continuous animation as timing ranges evolve.
    var activeDutyCycle: Double {
        let cycleDuration = delay + totalDuration
        guard cycleDuration > 0 else { return 0 }
        return totalDuration / cycleDuration
    }

    func event(startingAt date: Date) -> CaptainAyerAmbientGazeEvent {
        CaptainAyerAmbientGazeEvent(plan: self, start: date)
    }
}

struct CaptainAyerAmbientGazeEvent: Equatable, Sendable {
    let plan: CaptainAyerAmbientGazePlan
    let start: Date

    func direction(at date: Date) -> CGPoint? {
        let elapsed = date.timeIntervalSince(start)
        // Date arithmetic can round an exact `start + totalDuration` boundary
        // a fraction of a nanosecond below the requested value. Treat that
        // representational sliver as finished so the idle planner returns to
        // its true nil/home state instead of publishing a zero-length gaze.
        guard elapsed >= 0,
              elapsed + 1e-9 < plan.totalDuration else { return nil }

        let amount: Double
        if elapsed < plan.acquireDuration {
            amount = smoothStep(elapsed / plan.acquireDuration)
        } else if elapsed < plan.acquireDuration + plan.dwellDuration {
            amount = 1
        } else {
            let returnElapsed = elapsed - plan.acquireDuration - plan.dwellDuration
            amount = 1 - smoothStep(returnElapsed / plan.returnDuration)
        }
        let progress = CGFloat(amount)
        return CGPoint(
            x: plan.target.x * progress,
            y: plan.target.y * progress
        )
    }

    private func smoothStep(_ value: Double) -> Double {
        let amount = min(1, max(0, value))
        return amount * amount * (3 - 2 * amount)
    }
}

/// Turns injected unit samples into bounded plans. Tests pass fixed samples;
/// production passes system randomness, so behavior stays natural without
/// making timing-dependent tests flaky.
enum CaptainAyerAmbientMotionPlanner {
    static func blinkPlan(
        delaySample: Double,
        durationSample: Double,
        offsetSample: Double,
        characterSample: Double,
        leadingEyeSample: Double,
        asymmetrySample: Double
    ) -> CaptainAyerAmbientBlinkPlan {
        let character = unit(characterSample)
        let isPartial = character < 0.22
        let basePeak = isPartial
            ? 0.56 + 0.22 * (character / 0.22)
            : 0.94 + 0.06 * unit(asymmetrySample)
        let asymmetry = 0.006 + 0.012 * unit(asymmetrySample)
        let leadingEye: CaptainAyerEyeSide = unit(leadingEyeSample) < 0.5
            ? .left : .right
        let leftPeak = leadingEye == .left ? basePeak : basePeak - asymmetry
        let rightPeak = leadingEye == .right ? basePeak : basePeak - asymmetry

        return CaptainAyerAmbientBlinkPlan(
            delay: 2.8 + 3.4 * unit(delaySample),
            duration: 0.22 + 0.10 * unit(durationSample),
            followingEyeDelay: 0.012 + 0.022 * unit(offsetSample),
            leadingEye: leadingEye,
            leftPeakClosure: min(1, max(0, leftPeak)),
            rightPeakClosure: min(1, max(0, rightPeak))
        )
    }

    static func gazePlan(
        delaySample: Double,
        horizontalSample: Double,
        verticalSample: Double,
        paceSample: Double,
        dwellSample: Double
    ) -> CaptainAyerAmbientGazePlan {
        var horizontal = (unit(horizontalSample) * 2 - 1) * 0.22
        if abs(horizontal) < 0.055 {
            horizontal = horizontal < 0 ? -0.055 : 0.055
        }
        return CaptainAyerAmbientGazePlan(
            delay: 5.0 + 4.0 * unit(delaySample),
            target: CGPoint(
                x: horizontal,
                y: (unit(verticalSample) * 2 - 1) * 0.28
            ),
            acquireDuration: 0.28 + 0.14 * unit(paceSample),
            dwellDuration: 0.34 + 0.46 * unit(dwellSample),
            returnDuration: 0.38 + 0.12 * (1 - unit(paceSample))
        )
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }
}

enum CaptainAyerSpriteSheet {
    static func clampedFrame(_ frame: Int, frameCount: Int) -> Int {
        min(max(0, frame), max(0, frameCount - 1))
    }

    static func verticalOffsetInFrames(_ frame: Int, frameCount: Int) -> CGFloat {
        -CGFloat(clampedFrame(frame, frameCount: frameCount))
    }
}

struct CaptainAyerEyeReactionState: Equatable, Sendable {
    /// The underlying plate remains visible when this is nil.
    let lowerFrame: Int?
    let upperFrame: Int
    let upperOpacity: Double
}

struct CaptainAyerExpressionLayerRenderState: Equatable, Sendable {
    let smile: Double
    let sorrowMouth: Double
    let horrorMouth: Double
    let angerMouth: Double
    let cheek: Double
    let underEye: Double
    let asymmetry: Double

    init(
        smile: Double,
        sorrowMouth: Double,
        horrorMouth: Double,
        angerMouth: Double,
        cheek: Double,
        underEye: Double,
        asymmetry: Double = 0
    ) {
        self.smile = smile
        self.sorrowMouth = sorrowMouth
        self.horrorMouth = horrorMouth
        self.angerMouth = angerMouth
        self.cheek = cheek
        self.underEye = underEye
        self.asymmetry = asymmetry
    }

    static let neutral = Self(
        smile: 0,
        sorrowMouth: 0,
        horrorMouth: 0,
        angerMouth: 0,
        cheek: 0,
        underEye: 0,
        asymmetry: 0
    )
}

struct CaptainAyerFaceReactionRenderState: Equatable, Sendable {
    let gazeFrame: Int?
    let leftEye: CaptainAyerEyeReactionState?
    let rightEye: CaptainAyerEyeReactionState?
    let leftBrowFrame: Int?
    let rightBrowFrame: Int?
    let wideMouthOpacity: Double
    let headPose: CaptainAyerFaceMirrorHeadPose
    let expressionLayers: CaptainAyerExpressionLayerRenderState
    /// Continuous speech-brow intent in atlas-authored pixel offsets. These
    /// values let the renderer select frames against either the legacy
    /// 9-viseme rig or the v4 full-expression geometry without changing the
    /// perceived movement of already-installed avatars.
    let leftBrowOffset: Double?
    let rightBrowOffset: Double?
    let browSqueezeOffset: Double?
    /// Semantic fear/surprise/anger can keep the approved open-eye landscape
    /// even when an independent ambient blink is active. Nil keeps normal
    /// blinking for smile, laughter, and sorrow.
    let maximumEyeClosure: Double?

    init(
        gazeFrame: Int?,
        leftEye: CaptainAyerEyeReactionState?,
        rightEye: CaptainAyerEyeReactionState?,
        leftBrowFrame: Int?,
        rightBrowFrame: Int?,
        wideMouthOpacity: Double,
        headPose: CaptainAyerFaceMirrorHeadPose = .zero,
        expressionLayers: CaptainAyerExpressionLayerRenderState = .neutral,
        leftBrowOffset: Double? = nil,
        rightBrowOffset: Double? = nil,
        browSqueezeOffset: Double? = nil,
        maximumEyeClosure: Double? = nil
    ) {
        self.gazeFrame = gazeFrame
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.leftBrowFrame = leftBrowFrame
        self.rightBrowFrame = rightBrowFrame
        self.wideMouthOpacity = wideMouthOpacity
        self.headPose = headPose
        self.expressionLayers = expressionLayers
        self.leftBrowOffset = leftBrowOffset
        self.rightBrowOffset = rightBrowOffset
        self.browSqueezeOffset = browSqueezeOffset
        self.maximumEyeClosure = maximumEyeClosure
    }

    static let idle = CaptainAyerFaceReactionRenderState(
        gazeFrame: nil,
        leftEye: nil,
        rightEye: nil,
        leftBrowFrame: nil,
        rightBrowFrame: nil,
        wideMouthOpacity: 0,
        headPose: .zero,
        expressionLayers: .neutral,
        leftBrowOffset: nil,
        rightBrowOffset: nil,
        browSqueezeOffset: nil,
        maximumEyeClosure: nil
    )
}

/// Converts continuous local camera expressions onto the same sprite banks
/// used by taps and finger gaze. Mirror mode is an override; when it is off,
/// the existing reaction controller remains the sole owner of these layers.
enum CaptainAyerFaceMirrorRenderMapper {
    private static let eyeStates = [0.125, 0.250, 0.375, 0.500, 0.625, 0.750, 0.875, 1.000]
    private static let browOffsets = [-3.0, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 1.75, 2.5, 3.5, 5.0, 6.5, 8.0, 9.5]
    private static let neutralBrowSqueezeRow = 1
    private static let gazeXOffsets = [
        -9.0, -7.5, -6.0, -4.8, -3.6, -2.4, -1.5, -1.25, -1.0, -0.75,
        -0.5, -0.25, 0.0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.4,
        3.6, 4.8, 6.0, 7.5, 9.0,
    ]
    private static let gazeYOffsets = [
        -3.5, -2.5, -1.5, -0.75, -0.375, 0.0, 0.375, 0.75, 1.5, 2.5, 3.5,
    ]
    private static let gazeXRange = 9.0 * 0.28
    private static let gazeYRange = 3.5 * 0.38

    static func renderState(
        for expression: CaptainAyerFaceMirrorExpression,
        reduceMotion: Bool = false
    ) -> CaptainAyerFaceReactionRenderState {
        CaptainAyerFaceReactionRenderState(
            gazeFrame: reduceMotion ? nil : gazeFrame(for: expression.gaze),
            leftEye: eyeState(for: expression.leftBlink),
            rightEye: eyeState(for: expression.rightBlink),
            leftBrowFrame: browFrame(for: expression.leftBrowRaise),
            rightBrowFrame: browFrame(for: expression.rightBrowRaise),
            wideMouthOpacity: 0,
            headPose: reduceMotion ? .zero : expression.headPose
        )
    }

    private static func eyeState(
        for closure: Double
    ) -> CaptainAyerEyeReactionState? {
        let amount = min(1, max(0, closure))
        guard amount > 0.004 else { return nil }
        var upper = 0
        while upper < eyeStates.count - 1, eyeStates[upper] < amount {
            upper += 1
        }
        let lower = upper - 1
        let opacity: Double
        if lower < 0 {
            opacity = amount / eyeStates[0]
        } else {
            opacity = (amount - eyeStates[lower])
                / (eyeStates[upper] - eyeStates[lower])
        }
        return CaptainAyerEyeReactionState(
            lowerFrame: lower >= 0 ? lower : nil,
            upperFrame: upper,
            upperOpacity: min(1, max(0, opacity))
        )
    }

    private static func browFrame(for raise: Double) -> Int? {
        let amount = min(1, max(0, raise))
        guard amount > 0.012 else { return nil }
        let state = nearestIndex(in: browOffsets, to: amount * 8.0)
        return state + neutralBrowSqueezeRow * browOffsets.count
    }

    private static func gazeFrame(for direction: CGPoint) -> Int {
        let column = nearestIndex(
            in: gazeXOffsets,
            to: Double(direction.x) * gazeXRange
        )
        let row = nearestIndex(
            in: gazeYOffsets,
            to: Double(direction.y) * gazeYRange
        )
        return row * gazeXOffsets.count + column
    }

    private static func nearestIndex(in values: [Double], to target: Double) -> Int {
        values.indices.min { left, right in
            abs(values[left] - target) < abs(values[right] - target)
        } ?? 0
    }
}

@MainActor
final class CaptainAyerFaceReactionController: ObservableObject {
    static let winkDuration: TimeInterval = 0.560
    static let browDuration: TimeInterval = 0.750
    static let mouthDuration: TimeInterval = 0.950
    static let tapThrottle: TimeInterval = 0.700
    static let gazeAcquireDuration: TimeInterval = 0.250
    static let gazeReturnDuration: TimeInterval = 0.320
    static let gazeSmoothing = 0.30
    static let bodyReactionDuration: TimeInterval = 0.900

    @Published private(set) var isAnimating = false
    @Published private(set) var isGazeAnimating = false
    @Published private(set) var isAmbientAnimating = false
    @Published private(set) var isTrackingGaze = false
    @Published private(set) var gazeTarget = CGPoint.zero

    private static let eyeStates = [0.125, 0.250, 0.375, 0.500, 0.625, 0.750, 0.875, 1.000]
    private static let browOffsets = [-3.0, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 1.75, 2.5, 3.5, 5.0, 6.5, 8.0, 9.5]
    private static let neutralBrowSqueezeRow = 1
    private static let gazeXOffsets = [
        -9.0, -7.5, -6.0, -4.8, -3.6, -2.4, -1.5, -1.25, -1.0, -0.75,
        -0.5, -0.25, 0.0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.4,
        3.6, 4.8, 6.0, 7.5, 9.0,
    ]
    private static let gazeYOffsets = [
        -3.5, -2.5, -1.5, -0.75, -0.375, 0.0, 0.375, 0.75, 1.5, 2.5, 3.5,
    ]
    private static let gazeXRange: CGFloat = 9.0 * 0.28
    private static let gazeYRange: CGFloat = 3.5 * 0.38

    private struct GazeTransition {
        let from: CGPoint
        let to: CGPoint
        let start: Date
        let duration: TimeInterval
    }

    private var leftWinkStart: Date?
    private var rightWinkStart: Date?
    private var browStart: Date?
    private var mouthStart: Date?
    private var bodyReactionStart: Date?
    private var bodyReaction: CaptainAyerBodyRegion?
    private var lastTap: Date?
    private var flourishUsesLeftEye = false
    private var completionTask: Task<Void, Never>?
    private var animationGeneration = 0
    private var gazeTransition: GazeTransition?
    private var gazeCompletionTask: Task<Void, Never>?
    private var gazeGeneration = 0
    private var ambientBlink: CaptainAyerAmbientBlinkEvent?
    private var ambientGaze: CaptainAyerAmbientGazeEvent?
    private var ambientBlinkTask: Task<Void, Never>?
    private var ambientGazeTask: Task<Void, Never>?
    private var ambientBlinkIsAnimating = false
    private var ambientGazeIsAnimating = false
    private let randomUnit: () -> Double
    private let now: () -> Date

    init(
        randomUnit: @escaping () -> Double = { Double.random(in: 0 ... 1) },
        now: @escaping () -> Date = Date.init
    ) {
        self.randomUnit = randomUnit
        self.now = now
    }

    @discardableResult
    func react(
        atNormalizedFacePoint point: CGPoint,
        at date: Date = Date()
    ) -> Bool {
        guard let region = CaptainAyerFaceHitMap.region(at: point) else { return false }
        return react(to: region, at: date)
    }

    @discardableResult
    func react(
        atNormalizedBodyPoint point: CGPoint,
        at date: Date = Date()
    ) -> Bool {
        guard let region = CaptainAyerBodyHitMap.region(at: point) else { return false }
        return react(to: region, at: date)
    }

    @discardableResult
    func react(to region: CaptainAyerFaceRegion, at date: Date = Date()) -> Bool {
        guard acceptsTap(at: date) else {
            return false
        }

        switch region {
        case .brow:
            browStart = date
        case .leftEye:
            leftWinkStart = date
        case .rightEye:
            rightWinkStart = date
        case .mouth:
            mouthStart = date
        case .leftCheek:
            leftWinkStart = date
            mouthStart = date
        case .rightCheek:
            rightWinkStart = date
            mouthStart = date
        case .nose:
            beginFlourish(at: date)
        }

        wakeAnimation(at: date)
        return true
    }

    @discardableResult
    func react(to region: CaptainAyerBodyRegion, at date: Date = Date()) -> Bool {
        guard acceptsTap(at: date) else { return false }
        bodyReaction = region
        bodyReactionStart = date

        switch region {
        case .head:
            beginFlourish(at: date)
        case .leadingHand:
            leftWinkStart = date
            mouthStart = date
        case .trailingHand:
            rightWinkStart = date
            mouthStart = date
        case .heart:
            browStart = date
            mouthStart = date
        case .torso:
            browStart = date
        case .lowerBody:
            browStart = date
        case .feet:
            mouthStart = date
        }

        wakeAnimation(at: date)
        return true
    }

    /// A rail-button reaction combines the three bundled local tissues. The
    /// wink alternates sides so repeated taps do not look like a loop.
    func flourish(at date: Date = Date()) {
        beginFlourish(at: date)
        wakeAnimation(at: date)
    }

    /// Starts the low-duty-cycle idle behavior. The stage calls this only
    /// while visible and while Reduce Motion is off.
    func startAmbientMotion() {
        guard ambientBlinkTask == nil, ambientGazeTask == nil else { return }

        ambientBlinkTask = Task { @MainActor [weak self] in
            await self?.runAmbientBlinkLoop()
        }
        ambientGazeTask = Task { @MainActor [weak self] in
            await self?.runAmbientGazeLoop()
        }
    }

    func stopAmbientMotion() {
        ambientBlinkTask?.cancel()
        ambientGazeTask?.cancel()
        ambientBlinkTask = nil
        ambientGazeTask = nil
        ambientBlink = nil
        ambientGaze = nil
        ambientBlinkIsAnimating = false
        ambientGazeIsAnimating = false
        refreshAmbientAnimationFlag()
    }

    /// `direction` is normalized to -1...1 around the avatar's eye line.
    /// The baked grid is intentionally used only near its centre so finger
    /// tracking remains a glance instead of an exaggerated eye roll.
    func updateGaze(
        toward direction: CGPoint,
        at date: Date = Date()
    ) {
        gazeCompletionTask?.cancel()
        gazeCompletionTask = nil
        gazeGeneration += 1

        let current = gazePosition(at: date)
        let clamped = CGPoint(
            x: min(1, max(-1, direction.x)),
            y: min(1, max(-1, direction.y))
        )
        let target = CGPoint(
            x: clamped.x * Self.gazeXRange,
            y: clamped.y * Self.gazeYRange
        )
        gazeTransition = GazeTransition(
            from: current,
            to: target,
            start: date,
            duration: Self.gazeAcquireDuration
        )
        gazeTarget = target
        isTrackingGaze = true
        isGazeAnimating = true
    }

    func releaseGaze(
        at date: Date = Date(),
        reduceMotion: Bool = false
    ) {
        gazeCompletionTask?.cancel()
        gazeCompletionTask = nil
        gazeGeneration += 1
        let generation = gazeGeneration
        let current = gazePosition(at: date)
        gazeTarget = .zero
        isTrackingGaze = false

        if reduceMotion || hypot(current.x, current.y) < 0.001 {
            gazeTransition = nil
            isGazeAnimating = false
            return
        }

        gazeTransition = GazeTransition(
            from: current,
            to: .zero,
            start: date,
            duration: Self.gazeReturnDuration
        )
        isGazeAnimating = true
        let delay = max(
            0,
            date.addingTimeInterval(Self.gazeReturnDuration).timeIntervalSinceNow
        )
        gazeCompletionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self,
                  self.gazeGeneration == generation else { return }
            self.gazeTransition = nil
            self.isGazeAnimating = false
            self.gazeCompletionTask = nil
        }
    }

    func cancelGaze() {
        gazeCompletionTask?.cancel()
        gazeCompletionTask = nil
        gazeGeneration += 1
        gazeTransition = nil
        gazeTarget = .zero
        isTrackingGaze = false
        isGazeAnimating = false
    }

    func cancelAll() {
        completionTask?.cancel()
        completionTask = nil
        leftWinkStart = nil
        rightWinkStart = nil
        browStart = nil
        mouthStart = nil
        bodyReactionStart = nil
        bodyReaction = nil
        lastTap = nil
        animationGeneration += 1
        isAnimating = false
        cancelGaze()
    }

    func renderState(at date: Date = Date()) -> CaptainAyerFaceReactionRenderState {
        let leftEye = eyeState(startedAt: leftWinkStart, at: date)
            ?? ambientEyeState(for: .left, at: date)
        let rightEye = eyeState(startedAt: rightWinkStart, at: date)
            ?? ambientEyeState(for: .right, at: date)

        let browEnvelope = envelope(
            startedAt: browStart,
            duration: Self.browDuration,
            at: date
        )
        let browFrame = browEnvelope.map { value in
            let offset = 0.6 * value
            let stateIndex = Self.nearestIndex(in: Self.browOffsets, to: offset)
            return stateIndex + Self.neutralBrowSqueezeRow * Self.browOffsets.count
        }

        let mouthOpacity = envelope(
            startedAt: mouthStart,
            duration: Self.mouthDuration,
            at: date
        ).map { 0.8 * $0 } ?? 0

        return CaptainAyerFaceReactionRenderState(
            gazeFrame: gazeFrame(at: date),
            leftEye: leftEye,
            rightEye: rightEye,
            leftBrowFrame: browFrame,
            rightBrowFrame: browFrame,
            wideMouthOpacity: mouthOpacity,
            headPose: bodyHeadPose(at: date)
        )
    }

    /// Reduce Motion keeps a single expressive pose visible for the same
    /// bounded reaction window instead of animating through the sprite bank.
    func reducedMotionRenderState(at date: Date = Date()) -> CaptainAyerFaceReactionRenderState {
        guard isAnimating || isTrackingGaze else { return .idle }
        let closedEye = CaptainAyerEyeReactionState(
            lowerFrame: nil,
            upperFrame: Self.eyeStates.count - 1,
            upperOpacity: 1
        )
        let raisedBrowFrame = Self.nearestIndex(in: Self.browOffsets, to: 0.6)
            + Self.neutralBrowSqueezeRow * Self.browOffsets.count
        let leftEye = isActive(leftWinkStart, duration: Self.winkDuration, at: date)
            ? closedEye : nil
        let rightEye = isActive(rightWinkStart, duration: Self.winkDuration, at: date)
            ? closedEye : nil
        let hasBrow = isActive(browStart, duration: Self.browDuration, at: date)
        let hasMouth = isActive(mouthStart, duration: Self.mouthDuration, at: date)
        return CaptainAyerFaceReactionRenderState(
            gazeFrame: isTrackingGaze ? gazeFrame(for: gazeTarget) : nil,
            leftEye: leftEye,
            rightEye: rightEye,
            leftBrowFrame: hasBrow ? raisedBrowFrame : nil,
            rightBrowFrame: hasBrow ? raisedBrowFrame : nil,
            wideMouthOpacity: hasMouth ? 0.8 : 0
        )
    }

    private func beginFlourish(at date: Date) {
        flourishUsesLeftEye.toggle()
        if flourishUsesLeftEye {
            leftWinkStart = date
        } else {
            rightWinkStart = date
        }
        browStart = date
        mouthStart = date
    }

    private func gazeFrame(at date: Date) -> Int? {
        if isTrackingGaze || isGazeAnimating {
            return gazeFrame(for: gazePosition(at: date))
        }
        if let bodyDirection = bodyGazeDirection(at: date) {
            return gazeFrame(
                for: CGPoint(
                    x: bodyDirection.x * Self.gazeXRange,
                    y: bodyDirection.y * Self.gazeYRange
                )
            )
        }
        if let ambientDirection = ambientGaze?.direction(at: date) {
            return gazeFrame(
                for: CGPoint(
                    x: ambientDirection.x * Self.gazeXRange,
                    y: ambientDirection.y * Self.gazeYRange
                )
            )
        }
        return nil
    }

    private func gazeFrame(for position: CGPoint) -> Int {
        let column = Self.nearestIndex(in: Self.gazeXOffsets, to: Double(position.x))
        let row = Self.nearestIndex(in: Self.gazeYOffsets, to: Double(position.y))
        return row * Self.gazeXOffsets.count + column
    }

    private func gazePosition(at date: Date) -> CGPoint {
        guard let transition = gazeTransition else { return .zero }
        guard transition.duration > 0 else { return transition.to }
        let linear = min(
            1,
            max(0, date.timeIntervalSince(transition.start) / transition.duration)
        )
        let eased: Double
        if transition.duration == Self.gazeAcquireDuration {
            // The source rig follows 30% of the remaining distance per
            // 60 Hz frame. Expressing it in elapsed time keeps that response
            // stable when SwiftUI renders at a different refresh rate.
            let frameCount = max(0, date.timeIntervalSince(transition.start) * 60)
            eased = linear >= 1
                ? 1
                : 1 - pow(1 - Self.gazeSmoothing, frameCount)
        } else {
            eased = linear * linear * (3 - 2 * linear)
        }
        let amount = CGFloat(eased)
        return CGPoint(
            x: transition.from.x + (transition.to.x - transition.from.x) * amount,
            y: transition.from.y + (transition.to.y - transition.from.y) * amount
        )
    }

    private func bodyGazeDirection(at date: Date) -> CGPoint? {
        guard let reaction = bodyReaction,
              let amount = envelope(
                startedAt: bodyReactionStart,
                duration: Self.bodyReactionDuration,
                at: date
              ) else { return nil }
        let target: CGPoint
        switch reaction {
        case .head:
            target = CGPoint(x: 0.08, y: -0.18)
        case .leadingHand:
            target = CGPoint(x: -0.62, y: 0.30)
        case .trailingHand:
            target = CGPoint(x: 0.62, y: 0.30)
        case .heart:
            target = CGPoint(x: -0.12, y: 0.18)
        case .torso:
            target = CGPoint(x: 0.08, y: 0.34)
        case .lowerBody:
            target = CGPoint(x: 0, y: 0.66)
        case .feet:
            target = CGPoint(x: 0, y: 0.82)
        }
        let progress = CGFloat(amount)
        return CGPoint(x: target.x * progress, y: target.y * progress)
    }

    private func bodyHeadPose(at date: Date) -> CaptainAyerFaceMirrorHeadPose {
        guard let reaction = bodyReaction,
              let amount = envelope(
                startedAt: bodyReactionStart,
                duration: Self.bodyReactionDuration,
                at: date
              ) else { return .zero }
        let yaw: Double
        let pitch: Double
        let roll: Double
        switch reaction {
        case .head:
            yaw = 0.04
            pitch = -0.06
            roll = -0.05
        case .leadingHand:
            yaw = -0.12
            pitch = 0.05
            roll = -0.18
        case .trailingHand:
            yaw = 0.12
            pitch = 0.05
            roll = 0.18
        case .heart:
            yaw = -0.04
            pitch = 0.12
            roll = -0.06
        case .torso:
            yaw = 0.03
            pitch = 0.10
            roll = 0
        case .lowerBody:
            yaw = 0
            pitch = 0.12
            roll = 0
        case .feet:
            yaw = 0
            pitch = 0.16
            roll = 0.04
        }
        return CaptainAyerFaceMirrorHeadPose(
            yaw: yaw * amount,
            pitch: pitch * amount,
            roll: roll * amount
        )
    }

    private func acceptsTap(at date: Date) -> Bool {
        if let lastTap,
           date.timeIntervalSince(lastTap) >= 0,
           date.timeIntervalSince(lastTap) < Self.tapThrottle {
            return false
        }
        lastTap = date
        return true
    }

    private func wakeAnimation(at date: Date) {
        animationGeneration += 1
        let generation = animationGeneration
        completionTask?.cancel()
        isAnimating = true

        let deadline = [
            leftWinkStart.map { $0.addingTimeInterval(Self.winkDuration) },
            rightWinkStart.map { $0.addingTimeInterval(Self.winkDuration) },
            browStart.map { $0.addingTimeInterval(Self.browDuration) },
            mouthStart.map { $0.addingTimeInterval(Self.mouthDuration) },
            bodyReactionStart.map { $0.addingTimeInterval(Self.bodyReactionDuration) },
        ]
        .compactMap { $0 }
        .max() ?? date
        let delay = max(0, deadline.timeIntervalSinceNow)

        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self,
                  self.animationGeneration == generation else { return }
            self.isAnimating = false
            self.completionTask = nil
        }
    }

    private func runAmbientBlinkLoop() async {
        while !Task.isCancelled {
            let plan = CaptainAyerAmbientMotionPlanner.blinkPlan(
                delaySample: randomUnit(),
                durationSample: randomUnit(),
                offsetSample: randomUnit(),
                characterSample: randomUnit(),
                leadingEyeSample: randomUnit(),
                asymmetrySample: randomUnit()
            )
            guard await wait(plan.delay) else { return }

            ambientBlink = plan.event(startingAt: now())
            ambientBlinkIsAnimating = true
            refreshAmbientAnimationFlag()
            guard await wait(plan.totalDuration) else { return }

            ambientBlink = nil
            ambientBlinkIsAnimating = false
            refreshAmbientAnimationFlag()
        }
    }

    private func runAmbientGazeLoop() async {
        while !Task.isCancelled {
            let plan = CaptainAyerAmbientMotionPlanner.gazePlan(
                delaySample: randomUnit(),
                horizontalSample: randomUnit(),
                verticalSample: randomUnit(),
                paceSample: randomUnit(),
                dwellSample: randomUnit()
            )
            guard await wait(plan.delay) else { return }

            ambientGaze = plan.event(startingAt: now())
            ambientGazeIsAnimating = true
            refreshAmbientAnimationFlag()
            guard await wait(plan.totalDuration) else { return }

            ambientGaze = nil
            ambientGazeIsAnimating = false
            refreshAmbientAnimationFlag()
        }
    }

    private func wait(_ duration: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(max(0, duration)))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func refreshAmbientAnimationFlag() {
        let isActive = ambientBlinkIsAnimating || ambientGazeIsAnimating
        if isAmbientAnimating != isActive {
            isAmbientAnimating = isActive
        }
    }

    private func ambientEyeState(
        for eye: CaptainAyerEyeSide,
        at date: Date
    ) -> CaptainAyerEyeReactionState? {
        guard let ambientBlink else { return nil }
        return eyeState(for: ambientBlink.closure(for: eye, at: date))
    }

    private func eyeState(
        startedAt start: Date?,
        at date: Date
    ) -> CaptainAyerEyeReactionState? {
        guard let progress = envelope(
            startedAt: start,
            duration: Self.winkDuration,
            at: date
        ) else { return nil }
        return eyeState(for: progress)
    }

    private func eyeState(
        for progress: Double
    ) -> CaptainAyerEyeReactionState? {
        guard progress > 0.004 else { return nil }

        var upper = 0
        while upper < Self.eyeStates.count - 1,
              Self.eyeStates[upper] < progress {
            upper += 1
        }
        let lower = upper - 1
        let opacity: Double
        if lower < 0 {
            opacity = progress / Self.eyeStates[0]
        } else {
            let lowerValue = Self.eyeStates[lower]
            let upperValue = Self.eyeStates[upper]
            opacity = (progress - lowerValue) / (upperValue - lowerValue)
        }

        return CaptainAyerEyeReactionState(
            lowerFrame: lower >= 0 ? lower : nil,
            upperFrame: upper,
            upperOpacity: min(1, max(0, opacity))
        )
    }

    private func envelope(
        startedAt start: Date?,
        duration: TimeInterval,
        at date: Date
    ) -> Double? {
        guard let start else { return nil }
        let elapsed = date.timeIntervalSince(start)
        guard elapsed >= 0, elapsed < duration else { return nil }
        return sin(.pi * elapsed / duration)
    }

    private func isActive(
        _ start: Date?,
        duration: TimeInterval,
        at date: Date
    ) -> Bool {
        guard let start else { return false }
        let elapsed = date.timeIntervalSince(start)
        return elapsed >= 0 && elapsed < duration
    }

    private static func nearestIndex(in values: [Double], to target: Double) -> Int {
        values.indices.min { left, right in
            abs(values[left] - target) < abs(values[right] - target)
        } ?? 0
    }
}
