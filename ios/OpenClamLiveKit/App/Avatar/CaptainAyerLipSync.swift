import Combine
import Foundation

/// The nine mouth plates bundled with Captain Ayer. These are deliberately
/// independent of the speech implementation: a lifecycle supplies only text,
/// an optional duration, and start/finish events.
enum CaptainAyerViseme: String, CaseIterable, Codable, Sendable {
    case silence = "sil"
    case labiodental = "FF"
    case dental = "TH"
    case alveolar = "nn"
    case rhotic = "RR"
    case open = "aa"
    case wide = "E"
    case narrow = "ih"
    case rounded = "ou"

    var assetName: String {
        switch self {
        case .silence: "CaptainAyerVisemeSil"
        case .labiodental: "CaptainAyerVisemeFF"
        case .dental: "CaptainAyerVisemeTH"
        case .alveolar: "CaptainAyerVisemeNN"
        case .rhotic: "CaptainAyerVisemeRR"
        case .open: "CaptainAyerVisemeAA"
        case .wide: "CaptainAyerVisemeE"
        case .narrow: "CaptainAyerVisemeIH"
        case .rounded: "CaptainAyerVisemeOU"
        }
    }
}

struct CaptainAyerLipSyncCue: Equatable, Sendable {
    let offset: TimeInterval
    let viseme: CaptainAyerViseme
}

struct CaptainAyerAvatarRenderState: Equatable, Sendable {
    let previous: CaptainAyerViseme
    let current: CaptainAyerViseme
    /// Zero draws the previous plate, one draws the current plate.
    let blend: Double

    static let idle = CaptainAyerAvatarRenderState(
        previous: .silence,
        current: .silence,
        blend: 1
    )
}

struct CaptainAyerLipSyncTimeline: Equatable, Sendable {
    let duration: TimeInterval
    let cues: [CaptainAyerLipSyncCue]

    static let idle = CaptainAyerLipSyncTimeline(
        duration: 0,
        cues: [.init(offset: 0, viseme: .silence)]
    )

    func renderState(at elapsed: TimeInterval) -> CaptainAyerAvatarRenderState {
        guard duration > 0, elapsed >= 0, elapsed < duration, !cues.isEmpty else {
            return .idle
        }

        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cues[middle].offset <= elapsed {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        let index = max(0, lower - 1)
        let currentCue = cues[index]
        let previousViseme = index > 0 ? cues[index - 1].viseme : currentCue.viseme
        let requestedFadeDuration = Self.fadeDuration(
            from: previousViseme,
            to: currentCue.viseme
        )
        // The final synthetic silence must finish at the audio boundary. A
        // very short supplied duration can leave less than the normal 75 ms
        // closing window, so compress only that last fade instead of snapping
        // the remaining mouth motion when `elapsed` reaches `duration`.
        let fadeDuration: TimeInterval
        if index == cues.count - 1, currentCue.viseme == .silence {
            fadeDuration = min(
                requestedFadeDuration,
                max(0.000_001, duration - currentCue.offset)
            )
        } else {
            fadeDuration = requestedFadeDuration
        }
        let blend = min(1, max(0, (elapsed - currentCue.offset) / fadeDuration))
        return CaptainAyerAvatarRenderState(
            previous: previousViseme,
            current: currentCue.viseme,
            blend: blend
        )
    }

    static func fadeDuration(
        from: CaptainAyerViseme,
        to: CaptainAyerViseme
    ) -> TimeInterval {
        if to == .labiodental { return 0.045 }
        let vowels: Set<CaptainAyerViseme> = [.open, .wide, .narrow, .rounded]
        if vowels.contains(from), vowels.contains(to) { return 0.105 }
        if from == .silence || to == .silence { return 0.075 }
        return 0.065
    }
}

/// A small, deterministic letter-class planner used when a TTS engine does
/// not provide phoneme timestamps. Durations and pause weights match the
/// avatar's original local fallback, then richer mouth classes are folded
/// onto Captain Ayer's nine bundled plates by shape similarity.
struct CaptainAyerLipSyncPlanner: Sendable {
    private struct Item: Sendable {
        let viseme: CaptainAyerViseme?
        let weight: TimeInterval
    }

    private struct Shape: Sendable {
        let viseme: CaptainAyerViseme
        let weight: TimeInterval
    }

    private static let digraphs: [String: Shape] = [
        "th": .init(viseme: .dental, weight: 0.095),
        "ch": .init(viseme: .narrow, weight: 0.095),
        "sh": .init(viseme: .narrow, weight: 0.095),
        "ph": .init(viseme: .labiodental, weight: 0.095),
        "wh": .init(viseme: .rounded, weight: 0.105),
        "ck": .init(viseme: .alveolar, weight: 0.058),
        "qu": .init(viseme: .alveolar, weight: 0.058),
        "ee": .init(viseme: .narrow, weight: 0.105),
        "oo": .init(viseme: .rounded, weight: 0.105),
        "ea": .init(viseme: .narrow, weight: 0.105),
        "ai": .init(viseme: .wide, weight: 0.105),
        "ay": .init(viseme: .wide, weight: 0.105),
        "ou": .init(viseme: .rounded, weight: 0.105),
        "ow": .init(viseme: .rounded, weight: 0.105),
        "oa": .init(viseme: .rounded, weight: 0.105),
    ]

    private static let letters: [Character: Shape] = [
        "a": .init(viseme: .open, weight: 0.105),
        "e": .init(viseme: .wide, weight: 0.105),
        "i": .init(viseme: .narrow, weight: 0.105),
        "o": .init(viseme: .rounded, weight: 0.105),
        "u": .init(viseme: .rounded, weight: 0.105),
        "y": .init(viseme: .narrow, weight: 0.105),
        "w": .init(viseme: .rounded, weight: 0.105),
        "m": .init(viseme: .labiodental, weight: 0.058),
        "b": .init(viseme: .labiodental, weight: 0.058),
        "p": .init(viseme: .labiodental, weight: 0.058),
        "f": .init(viseme: .labiodental, weight: 0.095),
        "v": .init(viseme: .labiodental, weight: 0.095),
        "t": .init(viseme: .alveolar, weight: 0.058),
        "d": .init(viseme: .alveolar, weight: 0.058),
        "n": .init(viseme: .alveolar, weight: 0.068),
        "l": .init(viseme: .alveolar, weight: 0.068),
        "k": .init(viseme: .alveolar, weight: 0.058),
        "g": .init(viseme: .alveolar, weight: 0.058),
        "c": .init(viseme: .alveolar, weight: 0.058),
        "q": .init(viseme: .alveolar, weight: 0.058),
        "h": .init(viseme: .alveolar, weight: 0.058),
        "j": .init(viseme: .narrow, weight: 0.095),
        "s": .init(viseme: .narrow, weight: 0.095),
        "z": .init(viseme: .narrow, weight: 0.095),
        "x": .init(viseme: .narrow, weight: 0.095),
        "r": .init(viseme: .rhotic, weight: 0.068),
    ]

    private static let pauses: [Character: TimeInterval] = [
        ",": 0.20,
        ";": 0.24,
        ":": 0.24,
        ".": 0.34,
        "!": 0.34,
        "?": 0.34,
        "—": 0.26,
        "…": 0.40,
    ]

    func timeline(
        for text: String,
        duration suppliedDuration: TimeInterval? = nil
    ) -> CaptainAyerLipSyncTimeline {
        let items = Self.items(for: text)
        let naturalDuration = items.reduce(0) { $0 + $1.weight }
        let requestedDuration = suppliedDuration.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        let duration = requestedDuration ?? naturalDuration
        guard !items.isEmpty, naturalDuration > 0, duration > 0 else { return .idle }

        var cues = [CaptainAyerLipSyncCue(offset: 0, viseme: .silence)]
        var offset: TimeInterval = 0
        for item in items {
            if let viseme = item.viseme {
                cues.append(.init(offset: offset, viseme: viseme))
            }
            offset += item.weight / naturalDuration * duration
        }
        var compactedCues = Self.compact(cues)
        if let lastCue = compactedCues.last, lastCue.viseme != .silence {
            let closingFadeDuration = CaptainAyerLipSyncTimeline.fadeDuration(
                from: lastCue.viseme,
                to: .silence
            )
            let closingOffset = min(
                duration,
                max(lastCue.offset, duration - closingFadeDuration)
            )
            compactedCues.append(
                .init(offset: closingOffset, viseme: .silence)
            )
        }

        return CaptainAyerLipSyncTimeline(
            duration: duration,
            cues: compactedCues
        )
    }

    /// Maps an Apple speech UTF-16 boundary to the same weighted clock used by
    /// the fallback planner, letting word-boundary callbacks correct drift.
    func progress(forUTF16Location location: Int, in text: String) -> Double {
        let value = text as NSString
        let clampedLocation = min(max(0, location), value.length)
        let allItems = Self.items(for: text)
        let total = allItems.reduce(0) { $0 + $1.weight }
        guard total > 0 else {
            return value.length > 0 ? Double(clampedLocation) / Double(value.length) : 0
        }
        let prefix = value.substring(to: clampedLocation)
        let prefixWeight = Self.items(for: prefix).reduce(0) { $0 + $1.weight }
        return min(1, max(0, prefixWeight / total))
    }

    private static func items(for text: String) -> [Item] {
        let characters = Array(text.lowercased())
        var result: [Item] = []
        var index = 0
        while index < characters.count {
            if index + 1 < characters.count {
                let pair = String(characters[index...index + 1])
                if let shape = digraphs[pair] {
                    result.append(.init(viseme: shape.viseme, weight: shape.weight))
                    index += 2
                    continue
                }
            }

            let character = characters[index]
            if let shape = letters[character] {
                result.append(.init(viseme: shape.viseme, weight: shape.weight))
            } else if let pause = pauses[character] {
                result.append(.init(viseme: .silence, weight: pause))
            } else if character.isWhitespace {
                result.append(.init(viseme: nil, weight: 0.03))
            }
            index += 1
        }
        return result
    }

    private static func compact(_ cues: [CaptainAyerLipSyncCue]) -> [CaptainAyerLipSyncCue] {
        var result: [CaptainAyerLipSyncCue] = []
        for cue in cues {
            if let last = result.last, abs(last.offset - cue.offset) < 0.0001 {
                // Retain the opening silence and first viseme at offset zero.
                // The timeline's upper-bound lookup then selects the first
                // viseme with `previous == .silence` and `blend == 0`, giving
                // speech a real crossfade instead of a one-frame mouth pop.
                let isOpeningBoundary = result.count == 1
                    && abs(last.offset) < 0.0001
                    && last.viseme == .silence
                    && cue.viseme != .silence
                if isOpeningBoundary {
                    result.append(cue)
                } else {
                    result[result.count - 1] = cue
                }
            } else if result.last?.viseme != cue.viseme {
                result.append(cue)
            }
        }
        return result
    }
}

/// A compact, local expression plan derived from the words that are already
/// being spoken. It deliberately carries continuous intent rather than a
/// single emotion label, allowing warmth, empathy, curiosity, and seriousness
/// to coexist without another model, network request, or camera session.
struct CaptainAyerSpeechExpressionPlan: Equatable, Sendable {
    let warmth: Double
    let empathy: Double
    let curiosity: Double
    let gravity: Double
    let brightness: Double
    let energy: Double
    let seed: Double

    static let neutral = CaptainAyerSpeechExpressionPlan(
        warmth: 0.16,
        empathy: 0,
        curiosity: 0,
        gravity: 0,
        brightness: 0,
        energy: 0.22,
        seed: 0.5
    )
}

/// Maps semantic speech intent onto the bounded face banks that every current
/// AVTR avatar already carries. The result is intentionally restrained: the
/// photographic head can feel attentive and expressive without stretching or
/// inventing identity-bearing pixels.
enum CaptainAyerSpeechExpressionPlanner {
    private static let browOffsets = [
        -3.0, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0,
        1.75, 2.5, 3.5, 5.0, 6.5, 8.0, 9.5,
    ]
    private static let gazeXOffsets = [
        -9.0, -7.5, -6.0, -4.8, -3.6, -2.4, -1.5, -1.25, -1.0, -0.75,
        -0.5, -0.25, 0.0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.4,
        3.6, 4.8, 6.0, 7.5, 9.0,
    ]
    private static let gazeYOffsets = [
        -3.5, -2.5, -1.5, -0.75, -0.375, 0.0,
        0.375, 0.75, 1.5, 2.5, 3.5,
    ]
    private static let eyeStates = [0.125, 0.250, 0.375, 0.500, 0.625, 0.750, 0.875, 1.000]

    static func plan(for value: String) -> CaptainAyerSpeechExpressionPlan {
        let text = String(value.lowercased().prefix(12_000))
        let warmthTerms = [
            "thank", "glad", "welcome", "love", "happy", "wonderful", "great", "nice",
            "谢谢", "感激", "高兴", "开心", "欢迎", "喜欢",
        ]
        let empathyTerms = [
            "sorry", "understand", "difficult", "tough", "worry", "hope", "care",
            "抱歉", "对不起", "理解", "难过", "担心", "希望", "辛苦",
        ]
        let curiosityTerms = [
            "?", "？", "how ", "why ", "what ", "would you", "could you",
            "吗", "呢", "为什么", "怎么", "是否", "哪",
        ]
        let gravityTerms = [
            "warning", "careful", "danger", "urgent", "important", "must ", "cannot",
            "注意", "危险", "紧急", "重要", "必须", "不能",
        ]
        let brightTerms = [
            "!", "！", "congrat", "amazing", "excellent", "fantastic", "wow",
            "恭喜", "太棒", "好极", "真棒", "哇",
        ]

        let warmth = unit(0.16 + score(text, terms: warmthTerms) * 0.24)
        let empathy = unit(score(text, terms: empathyTerms) * 0.31)
        let curiosity = unit(score(text, terms: curiosityTerms) * 0.34)
        let gravity = unit(score(text, terms: gravityTerms) * 0.34)
        let brightness = unit(score(text, terms: brightTerms) * 0.30)
        let emphasis = min(0.20, Double(text.filter { "!！?？".contains($0) }.count) * 0.05)
        let energy = unit(0.22 + brightness * 0.54 + emphasis - gravity * 0.10)
        return CaptainAyerSpeechExpressionPlan(
            warmth: warmth,
            empathy: empathy,
            curiosity: curiosity,
            gravity: gravity,
            brightness: brightness,
            energy: energy,
            seed: stableSeed(text)
        )
    }

    static func renderState(
        for plan: CaptainAyerSpeechExpressionPlan,
        progress rawProgress: Double,
        elapsed rawElapsed: TimeInterval,
        reduceMotion: Bool = false
    ) -> CaptainAyerFaceReactionRenderState {
        let progress = unit(rawProgress)
        let elapsed = max(0, rawElapsed)
        let attack = smoothStep(elapsed / 0.28)
        let release = smoothStep((1 - progress) / 0.10)
        let envelope = min(attack, release)
        let beat = 0.5 + 0.5 * sin(
            elapsed * (2.1 + plan.energy * 0.9) + plan.seed * .pi * 2
        )
        let slow = sin(elapsed * 0.72 + plan.seed * 5.3)
        let questionLift = plan.curiosity * smoothStep((progress - 0.62) / 0.34)
        let warmth = unit(max(plan.warmth, plan.brightness * 0.68))
        let browAmount = unit((
            0.12 + plan.empathy * 0.24 + plan.curiosity * 0.34
                + questionLift * 0.32 + plan.energy * 0.10 + beat * 0.08
        ) * envelope)

        let squeezeRow: Int
        if plan.gravity > 0.45 {
            squeezeRow = 2
        } else if warmth > 0.58, plan.gravity < 0.2 {
            squeezeRow = 0
        } else {
            squeezeRow = 1
        }
        let browOffset = browAmount * 8.0
        let leftOffset = browOffset * (1 - (plan.seed - 0.5) * 0.10)
        let rightOffset = browOffset * (1 + (plan.seed - 0.5) * 0.10)
        let leftBrow = nearestIndex(in: browOffsets, to: leftOffset)
            + squeezeRow * browOffsets.count
        let rightBrow = nearestIndex(in: browOffsets, to: rightOffset)
            + squeezeRow * browOffsets.count

        if reduceMotion {
            return CaptainAyerFaceReactionRenderState(
                gazeFrame: nil,
                leftEye: nil,
                rightEye: nil,
                leftBrowFrame: browAmount > 0.035 ? leftBrow : nil,
                rightBrowFrame: browAmount > 0.035 ? rightBrow : nil,
                wideMouthOpacity: 0,
                headPose: .zero
            )
        }

        let gazeX = slow * (0.08 + plan.curiosity * 0.05)
        let gazeY = -questionLift * 0.12 + sin(elapsed * 0.43 + 1.7) * 0.025
        let gazeFrame = self.gazeFrame(x: gazeX, y: gazeY)
        let blink = blinkAmount(elapsed: elapsed, seed: plan.seed)
        let leftBlink = eyeState(amount: blink)
        let rightBlink = eyeState(amount: blink * (0.96 + plan.seed * 0.03))
        let tiltDirection = plan.seed < 0.5 ? -1.0 : 1.0
        return CaptainAyerFaceReactionRenderState(
            gazeFrame: gazeFrame,
            leftEye: leftBlink,
            rightEye: rightBlink,
            leftBrowFrame: browAmount > 0.025 ? leftBrow : nil,
            rightBrowFrame: browAmount > 0.025 ? rightBrow : nil,
            wideMouthOpacity: 0,
            headPose: CaptainAyerFaceMirrorHeadPose(
                yaw: slow * (0.10 + plan.energy * 0.03) * envelope,
                pitch: (
                    -questionLift * 0.14 + plan.empathy * 0.08
                        + sin(elapsed * 1.35) * 0.025
                ) * envelope,
                roll: (
                    (plan.empathy + plan.curiosity) * tiltDirection * 0.11
                        + slow * 0.018
                ) * envelope
            )
        )
    }

    private static func gazeFrame(x: Double, y: Double) -> Int {
        let column = nearestIndex(in: gazeXOffsets, to: x * 9.0 * 0.28)
        let row = nearestIndex(in: gazeYOffsets, to: y * 3.5 * 0.38)
        return row * gazeXOffsets.count + column
    }

    private static func blinkAmount(elapsed: TimeInterval, seed: Double) -> Double {
        let firstBlink = 1.45 + seed * 0.85
        guard elapsed >= firstBlink else { return 0 }
        let interval = 3.25 + seed * 1.15
        let local = (elapsed - firstBlink).truncatingRemainder(dividingBy: interval)
        guard local >= 0, local < 0.25 else { return 0 }
        if local < 0.085 { return smoothStep(local / 0.085) }
        if local < 0.115 { return 1 }
        return 1 - smoothStep((local - 0.115) / 0.135)
    }

    private static func eyeState(amount rawAmount: Double) -> CaptainAyerEyeReactionState? {
        let amount = unit(rawAmount)
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
            opacity = (amount - eyeStates[lower]) / (eyeStates[upper] - eyeStates[lower])
        }
        return CaptainAyerEyeReactionState(
            lowerFrame: lower >= 0 ? lower : nil,
            upperFrame: upper,
            upperOpacity: unit(opacity)
        )
    }

    private static func score(_ text: String, terms: [String]) -> Double {
        Double(terms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) })
    }

    private static func stableSeed(_ text: String) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for scalar in text.unicodeScalars.prefix(2_048) {
            hash ^= UInt64(scalar.value)
            hash &*= 1_099_511_628_211
        }
        return Double(hash & 0xffff_ffff) / Double(UInt32.max)
    }

    private static func nearestIndex(in values: [Double], to target: Double) -> Int {
        values.indices.min { left, right in
            abs(values[left] - target) < abs(values[right] - target)
        } ?? 0
    }

    private static func smoothStep(_ value: Double) -> Double {
        let amount = unit(value)
        return amount * amount * (3 - 2 * amount)
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

extension CaptainAyerFaceReactionRenderState {
    /// User gestures and ambient eyelid motion keep priority; speech fills the
    /// remaining channels and contributes only a small additive head pose.
    func mergingSpeech(_ speech: CaptainAyerFaceReactionRenderState) -> Self {
        Self(
            gazeFrame: gazeFrame ?? speech.gazeFrame,
            leftEye: leftEye ?? speech.leftEye,
            rightEye: rightEye ?? speech.rightEye,
            leftBrowFrame: leftBrowFrame ?? speech.leftBrowFrame,
            rightBrowFrame: rightBrowFrame ?? speech.rightBrowFrame,
            wideMouthOpacity: max(wideMouthOpacity, speech.wideMouthOpacity),
            headPose: CaptainAyerFaceMirrorHeadPose(
                yaw: min(1, max(-1, headPose.yaw + speech.headPose.yaw)),
                pitch: min(1, max(-1, headPose.pitch + speech.headPose.pitch)),
                roll: min(1, max(-1, headPose.roll + speech.headPose.roll))
            )
        )
    }
}

@MainActor
final class CaptainAyerLipSyncController: ObservableObject {
    enum Phase: Equatable, Sendable {
        case idle
        case prepared
        case speaking
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var generation: Int?

    var isSpeaking: Bool { phase == .speaking }
    var preparedText: String? { generation == nil ? nil : text }

    private let planner: CaptainAyerLipSyncPlanner
    private var text = ""
    private var timeline: CaptainAyerLipSyncTimeline = .idle
    private var expressionPlan = CaptainAyerSpeechExpressionPlan.neutral
    private var anchor: Date?

    init(planner: CaptainAyerLipSyncPlanner = .init()) {
        self.planner = planner
    }

    func prepare(text: String, generation: Int) {
        self.text = text
        self.generation = generation
        timeline = planner.timeline(for: text)
        expressionPlan = CaptainAyerSpeechExpressionPlanner.plan(for: text)
        anchor = nil
        phase = .prepared
    }

    /// Starts the prepared generation. Cloud speech should pass its exact
    /// player duration; Apple speech can omit it and use the local estimate.
    func begin(generation: Int, duration: TimeInterval? = nil) {
        guard self.generation == generation else { return }
        timeline = planner.timeline(for: text, duration: duration)
        anchor = Date()
        phase = .speaking
    }

    /// Reanchors estimated Apple speech at a word boundary without changing
    /// the audio session or synthesizer. `spokenRange` uses NSString/UTF-16
    /// coordinates, matching AVSpeechSynthesizerDelegate.
    func reanchorAppleSpeech(
        generation: Int,
        spokenRange: NSRange,
        fullText: String
    ) {
        guard self.generation == generation, phase == .speaking else { return }
        if text != fullText {
            text = fullText
            timeline = planner.timeline(for: fullText, duration: timeline.duration)
        }
        let progress = planner.progress(forUTF16Location: spokenRange.location, in: fullText)
        anchor = Date().addingTimeInterval(-(timeline.duration * progress))
    }

    func finish(generation: Int) {
        guard self.generation == generation else { return }
        reset()
    }

    func cancelAll() {
        reset()
    }

    func renderState(at date: Date = Date()) -> CaptainAyerAvatarRenderState {
        guard phase == .speaking, let anchor else { return .idle }
        return timeline.renderState(at: date.timeIntervalSince(anchor))
    }

    func expressionRenderState(
        at date: Date = Date(),
        reduceMotion: Bool = false
    ) -> CaptainAyerFaceReactionRenderState {
        guard phase == .speaking, let anchor, timeline.duration > 0 else { return .idle }
        let elapsed = max(0, date.timeIntervalSince(anchor))
        return CaptainAyerSpeechExpressionPlanner.renderState(
            for: expressionPlan,
            progress: elapsed / timeline.duration,
            elapsed: elapsed,
            reduceMotion: reduceMotion
        )
    }

    private func reset() {
        phase = .idle
        generation = nil
        text = ""
        timeline = .idle
        expressionPlan = .neutral
        anchor = nil
    }
}
