import Foundation

final class FoundationScreenVoicePTTProgressReporter: ScreenVoicePTTProgressReporting,
    @unchecked Sendable {
    private let progress: Progress
    private let lock = NSLock()
    private var phase: ScreenVoicePTTPhase = .preparing
    private var heartbeatCeiling: Int64 = 9

    init(progress: Progress) {
        self.progress = progress
        progress.totalUnitCount = 100
        progress.completedUnitCount = 0
    }

    func update(_ phase: ScreenVoicePTTPhase) async {
        lock.withLock {
            self.phase = phase
            switch phase {
            case .preparing:
                progress.completedUnitCount = 5
                heartbeatCeiling = 9
            case .listening:
                progress.completedUnitCount = 20
                heartbeatCeiling = 39
            case .transcribing:
                progress.completedUnitCount = 40
                heartbeatCeiling = 54
            case .thinking:
                progress.completedUnitCount = 55
                heartbeatCeiling = 79
            case .speaking:
                progress.completedUnitCount = 80
                heartbeatCeiling = 99
            case .completed:
                progress.completedUnitCount = 100
                heartbeatCeiling = 100
            case .cancelled:
                progress.cancel()
                progress.completedUnitCount = 100
                heartbeatCeiling = 100
            case .failed:
                progress.completedUnitCount = 100
                heartbeatCeiling = 100
            }
        }
    }

    func heartbeat() async {
        lock.withLock {
            guard phase != .completed, phase != .cancelled, phase != .failed else { return }
            progress.completedUnitCount = min(
                heartbeatCeiling,
                progress.completedUnitCount + 1
            )
        }
    }
}
