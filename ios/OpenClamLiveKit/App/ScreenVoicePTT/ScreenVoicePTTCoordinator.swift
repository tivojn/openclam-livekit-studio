import Foundation

protocol ScreenVoicePTTQuestionTranscribing: Sendable {
    func transcribeBoundedQuestion() async throws -> String
    func cancel() async
}

protocol ScreenVoicePTTAnalyzing: Sendable {
    func analyze(screen: ScreenVoicePTTRequest, question: String) async throws -> String
}

protocol ScreenVoicePTTSpeaking: Sendable {
    func speak(_ text: String) async throws
    func cancel() async
    func audiblePlaybackDuration() async -> TimeInterval
}

extension ScreenVoicePTTSpeaking {
    func audiblePlaybackDuration() async -> TimeInterval { 0 }
}

protocol ScreenVoicePTTActivityPresenting: Sendable {
    func start(turnID: UUID, phase: ScreenVoicePTTPhase) async throws
    func update(_ phase: ScreenVoicePTTPhase) async
    func end(_ phase: ScreenVoicePTTPhase) async
}

protocol ScreenVoicePTTProgressReporting: Sendable {
    func update(_ phase: ScreenVoicePTTPhase) async
    func heartbeat() async
}

struct NoopScreenVoicePTTProgressReporter: ScreenVoicePTTProgressReporting {
    func update(_ phase: ScreenVoicePTTPhase) async {}
    func heartbeat() async {}
}

struct ScreenVoicePTTDependencies: Sendable {
    let transcriber: any ScreenVoicePTTQuestionTranscribing
    let analyzer: any ScreenVoicePTTAnalyzing
    let speaker: any ScreenVoicePTTSpeaking
    let activity: any ScreenVoicePTTActivityPresenting
    let progress: any ScreenVoicePTTProgressReporting

    init(
        transcriber: any ScreenVoicePTTQuestionTranscribing,
        analyzer: any ScreenVoicePTTAnalyzing,
        speaker: any ScreenVoicePTTSpeaking,
        activity: any ScreenVoicePTTActivityPresenting,
        progress: any ScreenVoicePTTProgressReporting = NoopScreenVoicePTTProgressReporter()
    ) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.speaker = speaker
        self.activity = activity
        self.progress = progress
    }
}

/// Owns exactly one user-initiated bounded turn. It intentionally has no loop, wake word,
/// background observer, or retained media. A new Action Button press creates a new turn.
actor ScreenVoicePTTCoordinator {
    static let minimumAudiblePlaybackForGracefulCutoff: TimeInterval = 5

    private struct ActiveTurn {
        let id: UUID
        let task: Task<String, Error>
    }

    private var activeTurn: ActiveTurn?

    func run(
        _ request: ScreenVoicePTTRequest,
        dependencies: ScreenVoicePTTDependencies,
        playbackTimeout: TimeInterval = 60
    ) async throws -> String {
        guard activeTurn == nil else { throw ScreenVoicePTTError.busy }
        let turnID = UUID()
        let task = Task {
            try await Self.execute(
                turnID: turnID,
                request: request,
                dependencies: dependencies,
                playbackTimeout: playbackTimeout
            )
        }
        activeTurn = .init(id: turnID, task: task)
        defer {
            if activeTurn?.id == turnID {
                activeTurn = nil
            }
        }
        return try await task.value
    }

    func cancelCurrent() {
        activeTurn?.task.cancel()
    }

    var isRunning: Bool { activeTurn != nil }

    private static func execute(
        turnID: UUID,
        request: ScreenVoicePTTRequest,
        dependencies: ScreenVoicePTTDependencies,
        playbackTimeout: TimeInterval
    ) async throws -> String {
        await dependencies.progress.update(.preparing)
        try await dependencies.activity.start(turnID: turnID, phase: .preparing)
        let heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await dependencies.progress.heartbeat()
            }
        }
        defer { heartbeatTask.cancel() }

        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                await dependencies.progress.update(.listening)
                await dependencies.activity.update(.listening)
                let question = try await dependencies.transcriber.transcribeBoundedQuestion()
                try Task.checkCancellation()

                await dependencies.progress.update(.thinking)
                await dependencies.activity.update(.thinking)
                let answer = try await dependencies.analyzer.analyze(
                    screen: request,
                    question: question
                )
                try Task.checkCancellation()

                await dependencies.progress.update(.speaking)
                await dependencies.activity.update(.speaking)
                try await speak(
                    answer,
                    using: dependencies.speaker,
                    timeout: playbackTimeout
                )
                try Task.checkCancellation()

                await dependencies.progress.update(.completed)
                await dependencies.activity.end(.completed)
                return answer
            } onCancel: {
                Task {
                    await dependencies.transcriber.cancel()
                    await dependencies.speaker.cancel()
                    await dependencies.progress.update(.cancelled)
                    await dependencies.activity.end(.cancelled)
                }
            }
        } catch is CancellationError {
            await dependencies.transcriber.cancel()
            await dependencies.speaker.cancel()
            await dependencies.progress.update(.cancelled)
            await dependencies.activity.end(.cancelled)
            throw CancellationError()
        } catch {
            await dependencies.transcriber.cancel()
            await dependencies.speaker.cancel()
            await dependencies.progress.update(.failed)
            await dependencies.activity.end(.failed)
            throw error
        }
    }

    private static func speak(
        _ answer: String,
        using speaker: any ScreenVoicePTTSpeaking,
        timeout: TimeInterval
    ) async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await speaker.speak(answer) }
                group.addTask {
                    let bounded = max(0.01, min(60, timeout))
                    try await Task.sleep(nanoseconds: UInt64(bounded * 1_000_000_000))
                    throw ScreenVoicePTTError.playbackTimedOut
                }
                guard let first = try await group.next() else {
                    throw ScreenVoicePTTError.playbackFailed
                }
                group.cancelAll()
                return first
            }
        } catch let error as ScreenVoicePTTError {
            guard error == .playbackTimedOut else { throw error }
            let audibleDuration = await speaker.audiblePlaybackDuration()
            await speaker.cancel()
            guard audibleDuration >= minimumAudiblePlaybackForGracefulCutoff else {
                throw error
            }
            // The safety deadline still stops playback. Once the person has already heard a
            // meaningful portion, reaching that cutoff is a graceful bounded completion rather
            // than a second failure notification after an otherwise useful answer.
        }
    }
}
