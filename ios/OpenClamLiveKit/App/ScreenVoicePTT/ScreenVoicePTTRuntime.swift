import Foundation

struct ScreenVoicePTTServiceAnalyzer: ScreenVoicePTTAnalyzing {
    let service: ScreenPTTService

    func analyze(screen: ScreenVoicePTTRequest, question: String) async throws -> String {
        let answer = try await service.ask(
            .init(
                screenshotData: screen.screenshotData,
                screenshotTypeIdentifier: screen.screenshotTypeIdentifier,
                visibleText: screen.visibleText,
                question: question
            )
        )
        return ScreenVoicePTTSpokenAnswerLimiter.limit(answer)
    }
}

enum ScreenVoicePTTSpokenAnswerLimiter {
    static let maximumWords = 72
    static let maximumCJKCharacters = 140
    static let maximumCharacters = 420

    static func limit(_ answer: String) -> String {
        let normalized = answer
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return normalized }

        var prefix = ""
        var wordCount = 0
        var cjkCharacterCount = 0
        var inWord = false

        for character in normalized {
            let isWhitespace = character.isWhitespace
            let nextWordCount = wordCount + ((!isWhitespace && !inWord) ? 1 : 0)
            let nextCJKCount = cjkCharacterCount + (isCJK(character) ? 1 : 0)
            guard nextWordCount <= maximumWords,
                  nextCJKCount <= maximumCJKCharacters,
                  prefix.count < maximumCharacters else {
                return finishTruncated(prefix)
            }
            prefix.append(character)
            wordCount = nextWordCount
            cjkCharacterCount = nextCJKCount
            inWord = !isWhitespace
        }
        return prefix
    }

    private static func finishTruncated(_ prefix: String) -> String {
        var trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if let boundary = trimmed.lastIndex(where: { $0.isWhitespace }) {
            let candidate = String(trimmed[..<boundary])
            if candidate.count >= trimmed.count / 2 {
                trimmed = candidate
            }
        }
        return trimmed.isEmpty ? "" : trimmed + "…"
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2FA1F, 0x3040...0x30FF, 0xAC00...0xD7AF:
                true
            default:
                false
            }
        }
    }
}

@available(iOS 27.0, *)
enum ScreenVoicePTTRuntime {
    static let coordinator = ScreenVoicePTTCoordinator()
    static let activity = ScreenVoicePTTActivityController()

    @MainActor
    static func makeDependencies(
        progress: any ScreenVoicePTTProgressReporting = NoopScreenVoicePTTProgressReporter()
    ) throws -> ScreenVoicePTTDependencies {
        let vault = KeychainProviderCredentialVault()
        return .init(
            transcriber: ScreenVoicePTTQuestionTranscriber(
                credentialVault: vault,
                activity: activity
            ),
            analyzer: ScreenVoicePTTServiceAnalyzer(service: try ScreenPTTRuntime.makeService()),
            speaker: ScreenVoicePTTAnswerSpeaker(credentialVault: vault),
            activity: activity,
            progress: progress
        )
    }
}
