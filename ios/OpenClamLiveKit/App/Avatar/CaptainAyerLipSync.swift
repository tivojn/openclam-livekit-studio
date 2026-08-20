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
    private var anchor: Date?

    init(planner: CaptainAyerLipSyncPlanner = .init()) {
        self.planner = planner
    }

    func prepare(text: String, generation: Int) {
        self.text = text
        self.generation = generation
        timeline = planner.timeline(for: text)
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

    private func reset() {
        phase = .idle
        generation = nil
        text = ""
        timeline = .idle
        anchor = nil
    }
}
