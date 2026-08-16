import ActivityKit
import Foundation

actor ScreenVoicePTTActivityController: ScreenVoicePTTActivityPresenting {
    private var activity: Activity<ScreenVoicePTTActivityAttributes>?

    func start(turnID: UUID, phase: ScreenVoicePTTPhase) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw ScreenVoicePTTError.liveActivitiesDisabled
        }
        // ActivityKit can preserve an activity after the app process is killed. End every
        // matching orphan before starting a new turn so repeated Action Button presses never
        // accumulate stale Dynamic Island sessions across process launches.
        for existingActivity in Activity<ScreenVoicePTTActivityAttributes>.activities {
            await existingActivity.end(
                .init(
                    state: .init(phase: .cancelled, updatedAt: Date()),
                    staleDate: nil
                ),
                dismissalPolicy: .immediate
            )
        }
        activity = nil

        let now = Date()
        activity = try Activity.request(
            attributes: .init(turnID: turnID, startedAt: now),
            content: .init(
                state: .init(phase: phase, updatedAt: now),
                staleDate: now.addingTimeInterval(60)
            ),
            pushType: nil
        )
    }

    func update(_ phase: ScreenVoicePTTPhase) async {
        guard let activity else { return }
        let now = Date()
        await activity.update(
            .init(
                state: .init(phase: phase, updatedAt: now),
                staleDate: now.addingTimeInterval(60)
            )
        )
    }

    func end(_ phase: ScreenVoicePTTPhase) async {
        guard let activity else { return }
        self.activity = nil
        let now = Date()
        let dismissal: ActivityUIDismissalPolicy = switch phase {
        case .completed:
            .after(now.addingTimeInterval(8))
        case .cancelled, .failed:
            .after(now.addingTimeInterval(4))
        default:
            .immediate
        }
        await activity.end(
            .init(
                state: .init(phase: phase, updatedAt: now),
                staleDate: nil
            ),
            dismissalPolicy: dismissal
        )
    }
}
