import ActivityKit
import Foundation

/// Public Live Activity payload for one explicitly invoked Screen Voice PTT turn.
///
/// Privacy invariant: the activity carries only a coarse phase. Screen pixels, recognized
/// speech, model answers, provider names, and credentials never enter ActivityKit state.
struct ScreenVoicePTTActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var phase: ScreenVoicePTTPhase
        var updatedAt: Date
    }

    let turnID: UUID
    let startedAt: Date
}
enum ScreenVoicePTTPhase: String, Codable, Hashable, Sendable {
    case preparing
    case listening
    case transcribing
    case thinking
    case speaking
    case completed
    case cancelled
    case failed
}
