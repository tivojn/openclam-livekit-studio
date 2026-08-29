import Combine
import Foundation

/// The canonical fifteen production mouth shapes. Legacy bundled avatars map
/// the six added phonetic classes onto their nearest nine-plate artwork;
/// ios-light v4 avatars render every class from its own photographic plate.
enum CaptainAyerViseme: String, CaseIterable, Codable, Sendable {
    case silence = "sil"
    case bilabial = "PP"
    case labiodental = "FF"
    case dental = "TH"
    case alveolar = "DD"
    case velar = "kk"
    case postalveolar = "CH"
    case sibilant = "SS"
    case nasal = "nn"
    case rhotic = "RR"
    case open = "aa"
    case wide = "E"
    case narrow = "ih"
    case openRounded = "oh"
    case rounded = "ou"

    var assetName: String {
        switch self {
        case .silence: "CaptainAyerVisemeSil"
        case .bilabial: "CaptainAyerVisemeFF"
        case .labiodental: "CaptainAyerVisemeFF"
        case .dental: "CaptainAyerVisemeTH"
        case .alveolar: "CaptainAyerVisemeNN"
        case .velar: "CaptainAyerVisemeNN"
        case .postalveolar: "CaptainAyerVisemeIH"
        case .sibilant: "CaptainAyerVisemeIH"
        case .nasal: "CaptainAyerVisemeNN"
        case .rhotic: "CaptainAyerVisemeRR"
        case .open: "CaptainAyerVisemeAA"
        case .wide: "CaptainAyerVisemeE"
        case .narrow: "CaptainAyerVisemeIH"
        case .openRounded: "CaptainAyerVisemeOU"
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
        let vowels: Set<CaptainAyerViseme> = [
            .open, .wide, .narrow, .openRounded, .rounded,
        ]
        if vowels.contains(from), vowels.contains(to) { return 0.105 }
        if from == .silence || to == .silence { return 0.075 }
        return 0.065
    }
}

/// A Live Talk-only mouth clock. LiveKit 2.16 publishes participant audio
/// levels but does not expose phoneme timestamps, so the fallback deliberately
/// uses a few stable articulation bands instead of changing plates at the
/// audio-meter cadence. A provider-supplied timeline always takes precedence.
struct CaptainAyerLiveTalkMouthDriver: Equatable, Sendable {
    static let minimumVisemeHold: TimeInterval = 0.105
    static let speechEnterLevel = 0.018
    static let speechExitLevel = 0.010

    private static let wideEnterLevel = 0.060
    private static let wideExitLevel = 0.040
    private static let openEnterLevel = 0.135
    private static let openExitLevel = 0.090
    private static let attackTimeConstant: TimeInterval = 0.060
    private static let releaseTimeConstant: TimeInterval = 0.140

    private enum Band: Equatable, Sendable {
        case silence
        case narrow
        case wide
        case open

        var viseme: CaptainAyerViseme {
            switch self {
            case .silence: .silence
            case .narrow: .narrow
            case .wide: .wide
            case .open: .open
            }
        }
    }

    private let startedAt: TimeInterval
    private let timedTimeline: CaptainAyerLipSyncTimeline?
    private var smoothedLevel = 0.0
    private var lastSampleAt: TimeInterval?
    private var band = Band.silence
    private var previousViseme = CaptainAyerViseme.silence
    private var currentViseme = CaptainAyerViseme.silence
    private var transitionedAt: TimeInterval

    init(
        startedAt: TimeInterval,
        timedTimeline: CaptainAyerLipSyncTimeline? = nil
    ) {
        self.startedAt = startedAt
        self.timedTimeline = timedTimeline
        transitionedAt = startedAt - Self.minimumVisemeHold
    }

    mutating func update(audioLevel: Float, at sampleTime: TimeInterval) {
        guard timedTimeline == nil else { return }
        let rawLevel = Double(audioLevel.isFinite ? min(1, max(0, audioLevel)) : 0)
        if let lastSampleAt {
            let elapsed = min(0.5, max(0, sampleTime - lastSampleAt))
            let timeConstant = rawLevel > smoothedLevel
                ? Self.attackTimeConstant
                : Self.releaseTimeConstant
            let coefficient = 1 - exp(-elapsed / timeConstant)
            smoothedLevel += (rawLevel - smoothedLevel) * coefficient
        } else {
            smoothedLevel = rawLevel
        }
        lastSampleAt = sampleTime

        let candidate = nextBand(for: smoothedLevel)
        guard candidate != band,
              sampleTime - transitionedAt >= Self.minimumVisemeHold else { return }
        previousViseme = currentViseme
        currentViseme = candidate.viseme
        band = candidate
        transitionedAt = sampleTime
    }

    func renderState(at sampleTime: TimeInterval) -> CaptainAyerAvatarRenderState {
        if let timedTimeline {
            return timedTimeline.renderState(at: max(0, sampleTime - startedAt))
        }
        guard previousViseme != currentViseme else {
            return .init(previous: currentViseme, current: currentViseme, blend: 1)
        }
        let fade = CaptainAyerLipSyncTimeline.fadeDuration(
            from: previousViseme,
            to: currentViseme
        )
        let blend = min(1, max(0, (sampleTime - transitionedAt) / fade))
        return .init(previous: previousViseme, current: currentViseme, blend: blend)
    }

    private func nextBand(for level: Double) -> Band {
        switch band {
        case .silence:
            if level >= Self.openEnterLevel { return .open }
            if level >= Self.wideEnterLevel { return .wide }
            return level >= Self.speechEnterLevel ? .narrow : .silence
        case .narrow:
            if level < Self.speechExitLevel { return .silence }
            if level >= Self.openEnterLevel { return .open }
            return level >= Self.wideEnterLevel ? .wide : .narrow
        case .wide:
            if level < Self.speechExitLevel { return .silence }
            if level >= Self.openEnterLevel { return .open }
            return level < Self.wideExitLevel ? .narrow : .wide
        case .open:
            if level < Self.speechExitLevel { return .silence }
            return level < Self.openExitLevel ? .wide : .open
        }
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
        "ch": .init(viseme: .postalveolar, weight: 0.095),
        "sh": .init(viseme: .postalveolar, weight: 0.095),
        "ph": .init(viseme: .labiodental, weight: 0.095),
        "wh": .init(viseme: .rounded, weight: 0.105),
        "ck": .init(viseme: .velar, weight: 0.058),
        "qu": .init(viseme: .velar, weight: 0.058),
        "ee": .init(viseme: .narrow, weight: 0.105),
        "oo": .init(viseme: .rounded, weight: 0.105),
        "ea": .init(viseme: .narrow, weight: 0.105),
        "ai": .init(viseme: .wide, weight: 0.105),
        "ay": .init(viseme: .wide, weight: 0.105),
        "ou": .init(viseme: .rounded, weight: 0.105),
        "ow": .init(viseme: .rounded, weight: 0.105),
        "oa": .init(viseme: .openRounded, weight: 0.105),
    ]

    private static let letters: [Character: Shape] = [
        "a": .init(viseme: .open, weight: 0.105),
        "e": .init(viseme: .wide, weight: 0.105),
        "i": .init(viseme: .narrow, weight: 0.105),
        "o": .init(viseme: .openRounded, weight: 0.105),
        "u": .init(viseme: .rounded, weight: 0.105),
        "y": .init(viseme: .narrow, weight: 0.105),
        "w": .init(viseme: .rounded, weight: 0.105),
        "m": .init(viseme: .bilabial, weight: 0.058),
        "b": .init(viseme: .bilabial, weight: 0.058),
        "p": .init(viseme: .bilabial, weight: 0.058),
        "f": .init(viseme: .labiodental, weight: 0.095),
        "v": .init(viseme: .labiodental, weight: 0.095),
        "t": .init(viseme: .alveolar, weight: 0.058),
        "d": .init(viseme: .alveolar, weight: 0.058),
        "n": .init(viseme: .nasal, weight: 0.068),
        "l": .init(viseme: .alveolar, weight: 0.068),
        "k": .init(viseme: .velar, weight: 0.058),
        "g": .init(viseme: .velar, weight: 0.058),
        "c": .init(viseme: .velar, weight: 0.058),
        "q": .init(viseme: .velar, weight: 0.058),
        "h": .init(viseme: .alveolar, weight: 0.058),
        "j": .init(viseme: .postalveolar, weight: 0.095),
        "s": .init(viseme: .sibilant, weight: 0.095),
        "z": .init(viseme: .sibilant, weight: 0.095),
        "x": .init(viseme: .sibilant, weight: 0.095),
        "r": .init(viseme: .rhotic, weight: 0.068),
    ]

    private static let pauses: [Character: TimeInterval] = [
        ",": 0.20,
        "，": 0.20,
        ";": 0.24,
        "；": 0.24,
        ":": 0.24,
        "：": 0.24,
        ".": 0.34,
        "。": 0.34,
        "!": 0.34,
        "！": 0.34,
        "?": 0.34,
        "？": 0.34,
        "—": 0.26,
        "…": 0.40,
    ]

    /// TTS engines do not expose portable phoneme timings for every language.
    /// Keep non-Latin and numeric speech visibly alive with a bounded,
    /// deterministic articulation cycle instead of leaving the mouth closed.
    /// Providers that do supply timed visemes still replace this fallback.
    private static let unsupportedSpeechFallbackVisemes: [CaptainAyerViseme] = [
        .open, .alveolar, .narrow, .rounded, .wide, .velar,
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
            } else if character.unicodeScalars.contains(where: {
                CharacterSet.alphanumerics.contains($0)
            }) {
                let viseme = unsupportedSpeechFallbackVisemes[
                    result.count % unsupportedSpeechFallbackVisemes.count
                ]
                result.append(.init(viseme: viseme, weight: 0.085))
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
    let humor: Double
    let laughter: Double
    let sadness: Double
    let fear: Double
    let anger: Double
    let surprise: Double
    let energy: Double
    let seed: Double

    static let neutral = CaptainAyerSpeechExpressionPlan(
        warmth: 0.16,
        empathy: 0,
        curiosity: 0,
        gravity: 0,
        brightness: 0,
        humor: 0,
        laughter: 0,
        sadness: 0,
        fear: 0,
        anger: 0,
        surprise: 0,
        energy: 0.22,
        seed: 0.5
    )
}

struct CaptainAyerSpeechExpressionCue: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let plan: CaptainAyerSpeechExpressionPlan
}

struct CaptainAyerSpeechExpressionTimeline: Equatable, Sendable {
    let cues: [CaptainAyerSpeechExpressionCue]

    static let neutral = Self(cues: [])

    func state(at elapsed: TimeInterval) -> (
        plan: CaptainAyerSpeechExpressionPlan,
        progress: Double,
        localElapsed: TimeInterval
    ) {
        guard let cue = cues.first(where: { elapsed >= $0.start && elapsed < $0.end })
                ?? cues.last else {
            return (.neutral, 0, 0)
        }
        let span = max(0.000_001, cue.end - cue.start)
        let local = max(0, elapsed - cue.start)
        return (cue.plan, min(1, local / span), local)
    }
}

/// Stateful desktop-parity transition for phrase-local expression targets.
/// A target change captures the face that is actually on screen, then eases
/// from that captured state for 360 ms. Retargeting mid-transition therefore
/// remains continuous instead of dropping through a neutral face.
enum CaptainAyerSpeechExpressionTransitionPolicy {
    static let duration: TimeInterval = 0.36

    static func progress(
        startedAt: TimeInterval,
        sampledAt: TimeInterval
    ) -> Double {
        let raw = (sampledAt - startedAt) / duration
        let clamped = min(1, max(0, raw.isFinite ? raw : 0))
        return clamped * clamped * (3 - 2 * clamped)
    }

    static func interpolate(
        from: CaptainAyerSpeechExpressionPlan,
        to: CaptainAyerSpeechExpressionPlan,
        progress: Double
    ) -> CaptainAyerSpeechExpressionPlan {
        let amount = min(1, max(0, progress.isFinite ? progress : 0))
        func blend(_ first: Double, _ second: Double) -> Double {
            first + (second - first) * amount
        }
        return .init(
            warmth: blend(from.warmth, to.warmth),
            empathy: blend(from.empathy, to.empathy),
            curiosity: blend(from.curiosity, to.curiosity),
            gravity: blend(from.gravity, to.gravity),
            brightness: blend(from.brightness, to.brightness),
            humor: blend(from.humor, to.humor),
            laughter: blend(from.laughter, to.laughter),
            sadness: blend(from.sadness, to.sadness),
            fear: blend(from.fear, to.fear),
            anger: blend(from.anger, to.anger),
            surprise: blend(from.surprise, to.surprise),
            energy: blend(from.energy, to.energy),
            seed: blend(from.seed, to.seed)
        )
    }
}

struct CaptainAyerSpeechExpressionTransitionState: Equatable, Sendable {
    private(set) var from: CaptainAyerSpeechExpressionPlan
    private(set) var target: CaptainAyerSpeechExpressionPlan
    private(set) var startedAt: TimeInterval

    init(
        initial: CaptainAyerSpeechExpressionPlan = .neutral,
        at time: TimeInterval = 0
    ) {
        from = initial
        target = initial
        startedAt = time.isFinite ? time : 0
    }

    mutating func retarget(
        to newTarget: CaptainAyerSpeechExpressionPlan,
        at time: TimeInterval
    ) {
        guard newTarget != target else { return }
        let sampled = value(at: time)
        from = sampled
        target = newTarget
        startedAt = time.isFinite ? time : startedAt
    }

    mutating func sample(
        target newTarget: CaptainAyerSpeechExpressionPlan,
        at time: TimeInterval
    ) -> CaptainAyerSpeechExpressionPlan {
        retarget(to: newTarget, at: time)
        return value(at: time)
    }

    func value(at time: TimeInterval) -> CaptainAyerSpeechExpressionPlan {
        CaptainAyerSpeechExpressionTransitionPolicy.interpolate(
            from: from,
            to: target,
            progress: CaptainAyerSpeechExpressionTransitionPolicy.progress(
                startedAt: startedAt,
                sampledAt: time
            )
        )
    }
}

/// Maps semantic speech intent onto the bounded face banks that every current
/// AVTR avatar already carries. The result is intentionally restrained: the
/// photographic head can feel attentive and expressive without stretching or
/// inventing identity-bearing pixels.
enum CaptainAyerSpeechExpressionPlanner {
    private static let browOffsets =
        OpenClamAvatarExpressionGeometry.canonicalBrowOffsets
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
        let humorTerms = [
            "haha", "hehe", "lol", "funny", "joke", "joking", "kidding",
            "playful", "laugh", "smile", "哈哈", "呵呵", "好笑", "玩笑", "开玩笑", "笑",
        ]
        let laughterTerms = [
            "haha", "hehe", "lol", "hilarious", "laughing", "laughter", "laughed",
            "giggle", "giggling", "chuckle", "grinning", "delighted", "joyful",
            "哈哈", "呵呵", "大笑", "笑出声", "咯咯笑", "喜悦", "欢乐",
        ]
        let sadnessTerms = [
            "sad", "sadness", "sorrow", "sorrowful", "grief", "grieving",
            "heartbroken", "mourning", "mourn", "crying", "tears", "devastated",
            "despair", "lonely", "tragic", "悲伤", "悲痛", "伤心", "难过", "哀伤", "哭泣", "绝望",
        ]
        let fearTerms = [
            "horrified", "horror", "terrified", "terror", "fearful", "fear",
            "frightened", "frightening", "scared", "afraid", "panic", "nightmare",
            "alarmed", "惊恐", "恐怖", "害怕", "吓坏", "恐惧", "噩梦",
        ]
        let angerTerms = [
            "angry", "anger", "furious", "rage", "outraged", "annoyed", "disgusted",
            "infuriating", "愤怒", "生气", "暴怒", "恼火", "厌恶",
        ]
        let surpriseTerms = [
            "surprised", "surprise", "astonished", "amazed", "shocked", "gasp",
            "whoa", "unbelievable", "惊讶", "震惊", "吃惊", "没想到",
        ]

        let warmth = unit(0.16 + score(text, terms: warmthTerms) * 0.24)
        let empathy = unit(score(text, terms: empathyTerms) * 0.31)
        let curiosity = unit(score(text, terms: curiosityTerms) * 0.34)
        let gravity = unit(score(text, terms: gravityTerms) * 0.34)
        let brightness = unit(score(text, terms: brightTerms) * 0.30)
        let humor = unit(score(text, terms: humorTerms) * 0.34)
        let laughter = unit(score(text, terms: laughterTerms) * 0.52)
        let sadness = unit(score(text, terms: sadnessTerms) * 0.48)
        let fear = unit(score(text, terms: fearTerms) * 0.52)
        let anger = unit(score(text, terms: angerTerms) * 0.52)
        let surprise = unit(score(text, terms: surpriseTerms) * 0.50)
        let emphasis = min(0.20, Double(text.filter { "!！?？".contains($0) }.count) * 0.05)
        let energy = unit(
            0.22 + brightness * 0.44 + humor * 0.18 + laughter * 0.48
                + fear * 0.28 + anger * 0.34 + surprise * 0.46 + emphasis
                - sadness * 0.24 - gravity * 0.08
        )
        return CaptainAyerSpeechExpressionPlan(
            warmth: warmth,
            empathy: empathy,
            curiosity: curiosity,
            gravity: gravity,
            brightness: brightness,
            humor: humor,
            laughter: laughter,
            sadness: sadness,
            fear: fear,
            anger: anger,
            surprise: surprise,
            energy: energy,
            seed: stableSeed(text)
        )
    }

    static func timeline(
        for value: String,
        duration: TimeInterval
    ) -> CaptainAyerSpeechExpressionTimeline {
        let phrases = expressionPhrases(in: String(value.prefix(12_000)))
        guard !phrases.isEmpty, duration.isFinite, duration > 0 else {
            return .neutral
        }
        let weights = phrases.map(expressionPhraseWeight)
        let totalWeight = weights.reduce(0, +)
        var cursor = 0.0
        let cues = zip(phrases, weights).map { phrase, weight in
            let start = cursor / totalWeight * duration
            cursor += weight
            let end = cursor / totalWeight * duration
            return CaptainAyerSpeechExpressionCue(
                start: start,
                end: end,
                text: phrase,
                plan: plan(for: phrase)
            )
        }
        return .init(cues: cues)
    }

    private static func expressionPhrases(in value: String) -> [String] {
        let punctuation = CharacterSet(charactersIn: ".!?;:。！？；：\n")
        var sentences: [String] = []
        var current = ""
        for scalar in value.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if punctuation.contains(scalar) {
                let phrase = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !phrase.isEmpty { sentences.append(phrase) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }

        let transitions = [
            " but ", " however ", " yet ", " then ", " afterwards ", " after ",
            " meanwhile ", " finally ", " next ", "但是", "不过", "然而", "然后",
            "随后", "与此同时", "最后",
        ]
        return sentences.flatMap { sentence -> [String] in
            var parts = [sentence]
            for transition in transitions {
                parts = parts.flatMap { part in
                    guard let range = part.range(
                        of: transition,
                        options: [.caseInsensitive]
                    ) else { return [part] }
                    let before = String(part[..<range.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let after = String(part[range.lowerBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return [before, after].filter { !$0.isEmpty }
                }
            }
            return parts
        }
    }

    private static func expressionPhraseWeight(_ phrase: String) -> Double {
        let spoken = phrase.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.count
        let pauses = phrase.unicodeScalars.filter {
            CharacterSet(charactersIn: ",.!?;:，。！？；：\n").contains($0)
        }.count
        return Double(max(12, spoken + pauses * 8))
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
        // Speech stays expressive through the final spoken sample. A fixed
        // 280 ms post-audio release is owned by the controller; tying release
        // to a percentage of utterance duration made long answers fade for
        // several seconds while the voice was still talking.
        let envelope = attack
        let beat = 0.5 + 0.5 * sin(
            elapsed * (2.1 + plan.energy * 0.9) + plan.seed * .pi * 2
        )
        let slow = sin(elapsed * 0.72 + plan.seed * 5.3)
        let questionLift = plan.curiosity * smoothStep((progress - 0.62) / 0.34)
        let warmth = unit(max(plan.warmth, plan.brightness * 0.68))
        let mouthSmileIntent = unit(max(plan.laughter, plan.humor))
        let dramaticIntent = unit(
            [plan.sadness, plan.fear, plan.anger, plan.surprise].max() ?? 0
        )
        let mouthOnlySmile = mouthSmileIntent > 0.25
            && mouthSmileIntent > dramaticIntent
        // Keep the approved mouth-only smile landscape, but ease into upper
        // face emotion instead of flipping all layers at the exact phrase
        // crossover where laughter and a dramatic expression trade places.
        let smileDominance = unit(
            (mouthSmileIntent - dramaticIntent + 0.08) / 0.24
        )
        let upperFaceGain = 1 - smileDominance
        let explicitEmotion = max(
            mouthSmileIntent,
            dramaticIntent
        )
        let tremor = sin(elapsed * 9.1 + plan.seed * 11.3)
        let asymmetry = max(-0.18, min(0.18,
            (
                (plan.seed - 0.5) * 0.12
                    + slow * (0.03 + plan.energy * 0.02)
                    + plan.sadness * (plan.seed < 0.5 ? -0.045 : 0.045)
            ) * upperFaceGain
        ))
        let browIntent = max(-1, min(1,
            0.18 + plan.empathy * 0.24 + plan.curiosity * 0.46
                + questionLift * 0.34 + plan.sadness * 0.20 + plan.fear * 0.96
                + plan.surprise * 0.92 + plan.energy * 0.08 + beat * 0.08
                + plan.anger * 1.34 - plan.gravity * 0.46
        )) * envelope * upperFaceGain * (1 + explicitEmotion * 0.48)
        let squeezeIntent = max(-3, min(4,
            plan.gravity * 1.42 + plan.anger * 3.90 + plan.sadness * 1.55
                + plan.fear * 2.35 - plan.surprise * 2.62 - warmth * 0.34
        )) * upperFaceGain * (1 + explicitEmotion * 0.12)
        let squeezeOffsets = [-3.0, 0.0, 4.0]
        let squeezeRow = nearestIndex(in: squeezeOffsets, to: squeezeIntent)
        let browOffset = browIntent >= 0 ? browIntent * 14.0 : browIntent * 5.0
        let leftOffset = browOffset * (1 - asymmetry)
        let rightOffset = browOffset * (1 + asymmetry)
        let leftBrow = nearestIndex(in: browOffsets, to: leftOffset)
            + squeezeRow * browOffsets.count
        let rightBrow = nearestIndex(in: browOffsets, to: rightOffset)
            + squeezeRow * browOffsets.count

        if reduceMotion {
            return CaptainAyerFaceReactionRenderState(
                gazeFrame: nil,
                leftEye: nil,
                rightEye: nil,
                leftBrowFrame: abs(browIntent) > 0.035 ? leftBrow : nil,
                rightBrowFrame: abs(browIntent) > 0.035 ? rightBrow : nil,
                wideMouthOpacity: 0,
                headPose: .zero,
                expressionLayers: .init(
                    smile: mouthSmileIntent > 0.25 ? 0.18 * envelope : 0,
                    sorrowMouth: unit(plan.sadness * 0.55 * envelope),
                    horrorMouth: unit(plan.fear * 0.40 * envelope),
                    angerMouth: unit(plan.anger * 0.98 * envelope),
                    cheek: 0,
                    underEye: 0,
                    asymmetry: asymmetry
                ),
                leftBrowOffset: abs(browIntent) > 0.035 ? leftOffset : nil,
                rightBrowOffset: abs(browIntent) > 0.035 ? rightOffset : nil,
                browSqueezeOffset: abs(browIntent) > 0.035 ? squeezeIntent : nil,
                maximumEyeClosure: nil
            )
        }

        let gazeX = slow * (0.18 + plan.curiosity * 0.12)
            + tremor * plan.fear * 0.08
        let gazeY = -questionLift * 0.20 + plan.sadness * 0.32
            - plan.fear * 0.18 - plan.surprise * 0.16
            + sin(elapsed * 0.43 + 1.7) * 0.045
        let gazeFrame = self.gazeFrame(x: gazeX, y: gazeY)
        let semanticEyeOpen = [plan.fear, plan.surprise, plan.anger * 0.86].max() ?? 0
        let semanticClosureCap = semanticEyeOpen > 0.004
            ? unit(1 - semanticEyeOpen * 0.92)
            : nil
        let speechBlink = blinkAmounts(elapsed: elapsed, seed: plan.seed)
        let blinkScale = 1 - semanticEyeOpen * 0.92
        let leftBlinkAmount = speechBlink.left * blinkScale
        let rightBlinkAmount = speechBlink.right * blinkScale
        let eyeSquint = unit(warmth * 0.035 - plan.fear * 0.35 - plan.surprise * 0.32)
            * envelope * upperFaceGain
        let leftEyelidClosure = max(leftBlinkAmount, eyeSquint)
        let rightEyelidClosure = max(rightBlinkAmount, eyeSquint)
        let leftBlink = eyeState(amount: leftEyelidClosure)
        let rightBlink = eyeState(amount: rightEyelidClosure)
        let tiltDirection = plan.seed < 0.5 ? -1.0 : 1.0
        let baseUnderEye = 0.08 + warmth * 0.32 + plan.empathy * 0.12
            + plan.sadness * 0.56 + plan.anger * 0.18
        let underEye = max(
            max(leftEyelidClosure, rightEyelidClosure) * 0.30,
            mouthOnlySmile ? 0 : baseUnderEye * envelope * upperFaceGain
        )
        return CaptainAyerFaceReactionRenderState(
            gazeFrame: gazeFrame,
            leftEye: leftBlink,
            rightEye: rightBlink,
            leftBrowFrame: abs(browIntent) > 0.025 ? leftBrow : nil,
            rightBrowFrame: abs(browIntent) > 0.025 ? rightBrow : nil,
            wideMouthOpacity: 0,
            headPose: CaptainAyerFaceMirrorHeadPose(
                yaw: (
                    slow * (0.20 + plan.energy * 0.07)
                        + tremor * plan.fear * 0.09
                ) * envelope * upperFaceGain,
                pitch: (
                    -questionLift * 0.24 + plan.empathy * 0.10
                        + plan.sadness * 0.24 + plan.anger * 0.22
                        - plan.fear * 0.36 - plan.surprise * 0.28
                ) * envelope * upperFaceGain,
                roll: (
                    (plan.empathy + plan.curiosity + plan.sadness * 0.55)
                        * tiltDirection * 0.20 + slow * 0.05
                ) * envelope * upperFaceGain
            ),
            expressionLayers: .init(
                // Owner-approved macOS behavior: smile and laughter are the
                // same mouth-only AU12 plate at the exact 0.18 atlas state.
                smile: mouthSmileIntent > 0.25 ? 0.18 * envelope : 0,
                sorrowMouth: unit(plan.sadness * 0.55 * envelope),
                horrorMouth: unit(plan.fear * 0.40 * envelope),
                angerMouth: unit(plan.anger * 0.98 * envelope),
                cheek: unit((
                    0.05 + warmth * 0.34 + plan.energy * 0.08
                        - plan.sadness * 0.32 - plan.fear * 0.25 - plan.anger * 0.26
                ) * envelope * upperFaceGain),
                underEye: unit(underEye),
                asymmetry: asymmetry
            ),
            leftBrowOffset: abs(browIntent) > 0.025 ? leftOffset : nil,
            rightBrowOffset: abs(browIntent) > 0.025 ? rightOffset : nil,
            browSqueezeOffset: abs(browIntent) > 0.025 ? squeezeIntent : nil,
            maximumEyeClosure: semanticClosureCap
        )
    }

    private static func gazeFrame(x: Double, y: Double) -> Int {
        let column = nearestIndex(in: gazeXOffsets, to: x * 9.0 * 0.46)
        let row = nearestIndex(in: gazeYOffsets, to: y * 3.5 * 0.44)
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

    /// Speech and ambient motion use independent clocks, so speech still needs
    /// its own blink. Offset the following eye by 24-50 ms: visibly organic at
    /// 60 Hz, but short enough to read as one paired blink rather than a wink.
    private static func blinkAmounts(
        elapsed: TimeInterval,
        seed: Double
    ) -> (left: Double, right: Double) {
        let followingEyeDelay = 0.024 + 0.026 * unit(seed)
        let leftLeads = seed < 0.5
        let leftElapsed = elapsed - (leftLeads ? 0 : followingEyeDelay)
        let rightElapsed = elapsed - (leftLeads ? followingEyeDelay : 0)
        return (
            left: blinkAmount(elapsed: leftElapsed, seed: seed),
            right: blinkAmount(elapsed: rightElapsed, seed: seed)
        )
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

enum CaptainAyerEyeClosurePolicy {
    static let states = [0.125, 0.250, 0.375, 0.500, 0.625, 0.750, 0.875, 1.000]

    static func amount(_ eye: CaptainAyerEyeReactionState?) -> Double {
        guard let eye else { return 0 }
        let upper = states[min(max(0, eye.upperFrame), states.count - 1)]
        let lower = eye.lowerFrame.map {
            states[min(max(0, $0), states.count - 1)]
        } ?? 0
        return min(1, max(0, lower + (upper - lower) * eye.upperOpacity))
    }

    static func state(amount rawAmount: Double) -> CaptainAyerEyeReactionState? {
        let amount = min(1, max(0, rawAmount.isFinite ? rawAmount : 0))
        guard amount > 0.004 else { return nil }
        let upper = states.firstIndex(where: { $0 >= amount }) ?? states.count - 1
        let lower = upper - 1
        let lowerValue = lower >= 0 ? states[lower] : 0
        let span = max(0.000_001, states[upper] - lowerValue)
        return .init(
            lowerFrame: lower >= 0 ? lower : nil,
            upperFrame: upper,
            upperOpacity: min(1, max(0, (amount - lowerValue) / span))
        )
    }

    static func capped(
        _ eye: CaptainAyerEyeReactionState?,
        maximum: Double?
    ) -> CaptainAyerEyeReactionState? {
        guard let maximum else { return eye }
        return state(amount: min(amount(eye), min(1, max(0, maximum))))
    }
}

extension CaptainAyerFaceReactionRenderState {
    /// User gestures and ambient eyelid motion keep priority; speech fills the
    /// remaining channels and contributes only a small additive head pose.
    func mergingSpeech(_ speech: CaptainAyerFaceReactionRenderState) -> Self {
        let mergedLeftEye = CaptainAyerEyeClosurePolicy.capped(
            leftEye ?? speech.leftEye,
            maximum: speech.maximumEyeClosure
        )
        let mergedRightEye = CaptainAyerEyeClosurePolicy.capped(
            rightEye ?? speech.rightEye,
            maximum: speech.maximumEyeClosure
        )
        return Self(
            gazeFrame: gazeFrame ?? speech.gazeFrame,
            leftEye: mergedLeftEye,
            rightEye: mergedRightEye,
            leftBrowFrame: leftBrowFrame ?? speech.leftBrowFrame,
            rightBrowFrame: rightBrowFrame ?? speech.rightBrowFrame,
            wideMouthOpacity: max(wideMouthOpacity, speech.wideMouthOpacity),
            headPose: CaptainAyerFaceMirrorHeadPose(
                yaw: min(1, max(-1, headPose.yaw + speech.headPose.yaw)),
                pitch: min(1, max(-1, headPose.pitch + speech.headPose.pitch)),
                roll: min(1, max(-1, headPose.roll + speech.headPose.roll))
            ),
            expressionLayers: speech.expressionLayers,
            leftBrowOffset: leftBrowFrame == nil ? speech.leftBrowOffset : nil,
            rightBrowOffset: rightBrowFrame == nil ? speech.rightBrowOffset : nil,
            browSqueezeOffset: leftBrowFrame == nil && rightBrowFrame == nil
                ? speech.browSqueezeOffset
                : nil,
            maximumEyeClosure: speech.maximumEyeClosure
        )
    }
}

enum CaptainAyerSpeechExpressionReleasePolicy {
    static let duration: TimeInterval = 0.28

    static func progress(
        startedAt: Date,
        sampledAt: Date
    ) -> Double {
        let raw = sampledAt.timeIntervalSince(startedAt) / duration
        let amount = min(1, max(0, raw.isFinite ? raw : 0))
        return amount * amount * (3 - 2 * amount)
    }

    static func value(
        from state: CaptainAyerFaceReactionRenderState,
        progress rawProgress: Double
    ) -> CaptainAyerFaceReactionRenderState {
        let progress = min(1, max(0, rawProgress.isFinite ? rawProgress : 0))
        guard progress > 0 else { return state }
        guard progress < 1 else { return .idle }
        let remaining = 1 - progress
        func scaled(_ value: Double) -> Double { value * remaining }
        return .init(
            gazeFrame: CaptainAyerDiscreteFaceReleasePolicy.frame(
                from: state.gazeFrame,
                columns: 25,
                rows: 11,
                neutralColumn: 12,
                neutralRow: 5,
                progress: progress
            ),
            leftEye: CaptainAyerEyeClosurePolicy.state(
                amount: CaptainAyerEyeClosurePolicy.amount(state.leftEye) * remaining
            ),
            rightEye: CaptainAyerEyeClosurePolicy.state(
                amount: CaptainAyerEyeClosurePolicy.amount(state.rightEye) * remaining
            ),
            leftBrowFrame: CaptainAyerDiscreteFaceReleasePolicy.frame(
                from: state.leftBrowFrame,
                columns: 14,
                rows: 3,
                neutralColumn: 4,
                neutralRow: 1,
                progress: progress
            ),
            rightBrowFrame: CaptainAyerDiscreteFaceReleasePolicy.frame(
                from: state.rightBrowFrame,
                columns: 14,
                rows: 3,
                neutralColumn: 4,
                neutralRow: 1,
                progress: progress
            ),
            wideMouthOpacity: scaled(state.wideMouthOpacity),
            headPose: .init(
                yaw: scaled(state.headPose.yaw),
                pitch: scaled(state.headPose.pitch),
                roll: scaled(state.headPose.roll)
            ),
            expressionLayers: .init(
                smile: scaled(state.expressionLayers.smile),
                sorrowMouth: scaled(state.expressionLayers.sorrowMouth),
                horrorMouth: scaled(state.expressionLayers.horrorMouth),
                angerMouth: scaled(state.expressionLayers.angerMouth),
                cheek: scaled(state.expressionLayers.cheek),
                underEye: scaled(state.expressionLayers.underEye),
                asymmetry: scaled(state.expressionLayers.asymmetry)
            ),
            leftBrowOffset: state.leftBrowOffset.map(scaled),
            rightBrowOffset: state.rightBrowOffset.map(scaled),
            browSqueezeOffset: state.browSqueezeOffset.map(scaled),
            // A semantic open-eye cap is a maximum closure, so releasing it
            // means easing upward toward an unrestricted value of 1. Scaling
            // the cap toward zero would incorrectly force the lashes even
            // wider before snapping back to ambient blinking.
            maximumEyeClosure: state.maximumEyeClosure.map {
                $0 + (1 - $0) * progress
            }
        )
    }
}

enum CaptainAyerDiscreteFaceReleasePolicy {
    static func frame(
        from source: Int?,
        columns: Int,
        rows: Int,
        neutralColumn: Int,
        neutralRow: Int,
        progress rawProgress: Double
    ) -> Int? {
        guard let source, columns > 0, rows > 0,
              (0 ..< columns * rows).contains(source) else { return source }
        let progress = min(1, max(0, rawProgress.isFinite ? rawProgress : 0))
        let sourceColumn = source % columns
        let sourceRow = source / columns
        let targetColumn = min(columns - 1, max(0, neutralColumn))
        let targetRow = min(rows - 1, max(0, neutralRow))
        let column = Int(
            (Double(sourceColumn) + Double(targetColumn - sourceColumn) * progress)
                .rounded()
        )
        let row = Int(
            (Double(sourceRow) + Double(targetRow - sourceRow) * progress)
                .rounded()
        )
        return row * columns + column
    }
}

@MainActor
final class CaptainAyerLipSyncController: ObservableObject {
    enum Phase: Equatable, Sendable {
        case idle
        case prepared
        case speaking
        case releasing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var generation: Int?

    var isSpeaking: Bool { phase == .speaking }
    var isExpressionAnimating: Bool { phase == .speaking || phase == .releasing }
    var preparedText: String? { generation == nil ? nil : text }

    private let planner: CaptainAyerLipSyncPlanner
    private var text = ""
    private var timeline: CaptainAyerLipSyncTimeline = .idle
    private var expressionPlan = CaptainAyerSpeechExpressionPlan.neutral
    private var expressionTimeline = CaptainAyerSpeechExpressionTimeline.neutral
    private var expressionDuration: TimeInterval = 0
    private var expressionTransition = CaptainAyerSpeechExpressionTransitionState()
    private var anchor: Date?
    private var releaseAnchor: Date?
    private var releaseState: CaptainAyerFaceReactionRenderState = .idle
    private var releaseTask: Task<Void, Never>?
    private var liveTalkMouthDriver: CaptainAyerLiveTalkMouthDriver?

    init(planner: CaptainAyerLipSyncPlanner = .init()) {
        self.planner = planner
    }

    func prepare(text: String, generation: Int) {
        self.text = text
        self.generation = generation
        timeline = planner.timeline(for: text)
        expressionPlan = CaptainAyerSpeechExpressionPlanner.plan(for: text)
        expressionTimeline = CaptainAyerSpeechExpressionPlanner.timeline(
            for: text,
            duration: timeline.duration
        )
        expressionDuration = timeline.duration
        expressionTransition = .init()
        anchor = nil
        releaseAnchor = nil
        releaseState = .idle
        releaseTask?.cancel()
        releaseTask = nil
        liveTalkMouthDriver = nil
        phase = .prepared
    }

    /// Starts the prepared generation. Cloud speech should pass its exact
    /// player duration; Apple speech can omit it and use the local estimate.
    func begin(
        generation: Int,
        duration: TimeInterval? = nil,
        at date: Date = Date()
    ) {
        guard self.generation == generation else { return }
        timeline = planner.timeline(for: text, duration: duration)
        expressionTimeline = CaptainAyerSpeechExpressionPlanner.timeline(
            for: text,
            duration: timeline.duration
        )
        expressionDuration = timeline.duration
        let now = date
        anchor = now
        expressionTransition = .init(at: now.timeIntervalSinceReferenceDate)
        expressionTransition.retarget(
            to: expressionTimeline.cues.first?.plan ?? expressionPlan,
            at: now.timeIntervalSinceReferenceDate
        )
        releaseAnchor = nil
        releaseState = .idle
        releaseTask?.cancel()
        releaseTask = nil
        phase = .speaking
    }

    /// Starts a Live Talk generation without changing the regular TTS path.
    /// Exact provider viseme timing wins when present; current LiveKit sessions
    /// pass nil and use the smoothed audio-level fallback instead.
    func beginLiveTalk(
        text: String,
        generation: Int,
        timedVisemeTimeline: CaptainAyerLipSyncTimeline? = nil,
        at date: Date = Date()
    ) {
        prepare(text: text, generation: generation)
        begin(
            generation: generation,
            duration: timedVisemeTimeline?.duration,
            at: date
        )
        guard self.generation == generation, phase == .speaking else { return }
        liveTalkMouthDriver = CaptainAyerLiveTalkMouthDriver(
            startedAt: date.timeIntervalSinceReferenceDate,
            timedTimeline: timedVisemeTimeline
        )
    }

    func updateLiveTalkAudioLevel(_ level: Float, at date: Date = Date()) {
        guard phase == .speaking, var driver = liveTalkMouthDriver else { return }
        driver.update(
            audioLevel: level,
            at: date.timeIntervalSinceReferenceDate
        )
        liveTalkMouthDriver = driver
    }

    /// Updates only the semantic expression plan while a Live Talk answer is
    /// streaming. The active audio-level/timed-viseme mouth driver, generation,
    /// and speech clock remain untouched, so transcript growth cannot make the
    /// lips restart or flutter back to the opening plate.
    func retargetLiveTalkExpression(
        text updatedText: String,
        generation: Int,
        at date: Date = Date()
    ) {
        let normalized = updatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.generation == generation,
              phase == .speaking,
              liveTalkMouthDriver != nil,
              !normalized.isEmpty,
              normalized != text,
              let anchor else { return }
        text = normalized
        expressionPlan = CaptainAyerSpeechExpressionPlanner.plan(for: normalized)
        let elapsed = max(0, date.timeIntervalSince(anchor))
        let estimated = planner.timeline(for: normalized).duration
        expressionDuration = max(estimated, elapsed + 0.5)
        expressionTimeline = CaptainAyerSpeechExpressionPlanner.timeline(
            for: normalized,
            duration: expressionDuration
        )
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
            expressionTimeline = CaptainAyerSpeechExpressionPlanner.timeline(
                for: fullText,
                duration: timeline.duration
            )
            expressionDuration = timeline.duration
        }
        let progress = planner.progress(forUTF16Location: spokenRange.location, in: fullText)
        anchor = Date().addingTimeInterval(-(timeline.duration * progress))
    }

    func finish(generation: Int, at date: Date = Date()) {
        guard self.generation == generation else { return }
        releaseState = expressionRenderState(at: date)
        releaseAnchor = date
        self.generation = nil
        phase = .releasing
        releaseTask?.cancel()
        liveTalkMouthDriver = nil
        releaseTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(
                    CaptainAyerSpeechExpressionReleasePolicy.duration
                        * 1_000_000_000
                )
            )
            guard !Task.isCancelled, self?.phase == .releasing else { return }
            self?.reset()
        }
    }

    func cancelAll() {
        reset()
    }

    func renderState(at date: Date = Date()) -> CaptainAyerAvatarRenderState {
        guard phase == .speaking, let anchor else { return .idle }
        if let liveTalkMouthDriver {
            return liveTalkMouthDriver.renderState(
                at: date.timeIntervalSinceReferenceDate
            )
        }
        return timeline.renderState(at: date.timeIntervalSince(anchor))
    }

    func expressionRenderState(
        at date: Date = Date(),
        reduceMotion: Bool = false
    ) -> CaptainAyerFaceReactionRenderState {
        if phase == .releasing, let releaseAnchor {
            let progress = CaptainAyerSpeechExpressionReleasePolicy.progress(
                startedAt: releaseAnchor,
                sampledAt: date
            )
            let state = CaptainAyerSpeechExpressionReleasePolicy.value(
                from: releaseState,
                progress: progress
            )
            return state
        }
        guard phase == .speaking, let anchor, expressionDuration > 0 else { return .idle }
        let elapsed = max(0, date.timeIntervalSince(anchor))
        let phrase = expressionTimeline.state(at: elapsed)
        let target = expressionTimeline.cues.isEmpty ? expressionPlan : phrase.plan
        let transitioned = expressionTransition.sample(
            target: target,
            at: date.timeIntervalSinceReferenceDate
        )
        return CaptainAyerSpeechExpressionPlanner.renderState(
            for: transitioned,
            // Attack and release belong to the whole utterance. Phrase-local
            // envelopes would hit zero at every cue boundary and visibly pop
            // even while the semantic plan itself crossfades correctly.
            progress: elapsed / expressionDuration,
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
        expressionTimeline = .neutral
        expressionDuration = 0
        expressionTransition = .init()
        anchor = nil
        releaseAnchor = nil
        releaseState = .idle
        releaseTask?.cancel()
        releaseTask = nil
        liveTalkMouthDriver = nil
    }
}
