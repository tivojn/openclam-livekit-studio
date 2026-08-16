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

struct CaptainAyerFaceReactionRenderState: Equatable, Sendable {
    let gazeFrame: Int?
    let leftEye: CaptainAyerEyeReactionState?
    let rightEye: CaptainAyerEyeReactionState?
    let leftBrowFrame: Int?
    let rightBrowFrame: Int?
    let wideMouthOpacity: Double
    let headPose: CaptainAyerFaceMirrorHeadPose

    init(
        gazeFrame: Int?,
        leftEye: CaptainAyerEyeReactionState?,
        rightEye: CaptainAyerEyeReactionState?,
        leftBrowFrame: Int?,
        rightBrowFrame: Int?,
        wideMouthOpacity: Double,
        headPose: CaptainAyerFaceMirrorHeadPose = .zero
    ) {
        self.gazeFrame = gazeFrame
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.leftBrowFrame = leftBrowFrame
        self.rightBrowFrame = rightBrowFrame
        self.wideMouthOpacity = wideMouthOpacity
        self.headPose = headPose
    }

    static let idle = CaptainAyerFaceReactionRenderState(
        gazeFrame: nil,
        leftEye: nil,
        rightEye: nil,
        leftBrowFrame: nil,
        rightBrowFrame: nil,
        wideMouthOpacity: 0,
        headPose: .zero
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

    @Published private(set) var isAnimating = false
    @Published private(set) var isGazeAnimating = false
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
    private var lastFaceTap: Date?
    private var flourishUsesLeftEye = false
    private var completionTask: Task<Void, Never>?
    private var animationGeneration = 0
    private var gazeTransition: GazeTransition?
    private var gazeCompletionTask: Task<Void, Never>?
    private var gazeGeneration = 0

    @discardableResult
    func react(
        atNormalizedFacePoint point: CGPoint,
        at date: Date = Date()
    ) -> Bool {
        guard let region = CaptainAyerFaceHitMap.region(at: point) else { return false }
        return react(to: region, at: date)
    }

    @discardableResult
    func react(to region: CaptainAyerFaceRegion, at date: Date = Date()) -> Bool {
        if let lastFaceTap,
           date.timeIntervalSince(lastFaceTap) >= 0,
           date.timeIntervalSince(lastFaceTap) < Self.tapThrottle {
            return false
        }
        lastFaceTap = date

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

    /// A rail-button reaction combines the three bundled local tissues. The
    /// wink alternates sides so repeated taps do not look like a loop.
    func flourish(at date: Date = Date()) {
        beginFlourish(at: date)
        wakeAnimation(at: date)
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
        lastFaceTap = nil
        animationGeneration += 1
        isAnimating = false
        cancelGaze()
    }

    func renderState(at date: Date = Date()) -> CaptainAyerFaceReactionRenderState {
        let leftEye = eyeState(startedAt: leftWinkStart, at: date)
        let rightEye = eyeState(startedAt: rightWinkStart, at: date)

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
            wideMouthOpacity: mouthOpacity
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
        guard isTrackingGaze || isGazeAnimating else { return nil }
        return gazeFrame(for: gazePosition(at: date))
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

    private func eyeState(
        startedAt start: Date?,
        at date: Date
    ) -> CaptainAyerEyeReactionState? {
        guard let progress = envelope(
            startedAt: start,
            duration: Self.winkDuration,
            at: date
        ), progress > 0.004 else { return nil }

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
