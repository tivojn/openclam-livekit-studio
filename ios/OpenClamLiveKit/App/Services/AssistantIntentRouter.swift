import Foundation

enum ConversationIntent: Equatable {
    case pronounce(text: String?)
    case restaurantSearch(cuisine: String?, location: String?)
    case openSelectedPlace
    case reviewsOrMenu
    case draftMessage(recipient: String, requestedBody: String?)
    case reviseMessage(body: String)
    case requestRide(destination: String)
    case thanks
    case unknown
}

struct AssistantIntentRouter {
    func route(_ input: String) -> ConversationIntent {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if let revision = messageRevision(in: trimmed) {
            return .reviseMessage(body: revision)
        }

        if lower.contains("review") || lower.contains("menu") || lower.contains("what should i get") || lower.contains("what should i order") {
            return .reviewsOrMenu
        }

        if lower.contains("uber") || lower.contains("ride to") || lower.contains("head to the airport") {
            let destination = rideDestination(in: trimmed) ?? "airport"
            return .requestRide(destination: destination)
        }

        if let message = messageRequest(in: trimmed) {
            return .draftMessage(recipient: message.recipient, requestedBody: message.body)
        }

        if lower.contains("google maps") || lower.contains("pull it up") || lower.contains("open maps") || lower.contains("check it out") {
            return .openSelectedPlace
        }

        if lower.contains("restaurant") || lower.contains("cafe") || lower.contains("where should i eat") || lower.contains("somewhere to eat") {
            return .restaurantSearch(
                cuisine: cuisine(in: trimmed),
                location: location(in: trimmed)
            )
        }

        if lower.contains("pronounce") || lower.contains("pronunciation") || lower.contains("how do you say") || lower.contains("how is this said") {
            return .pronounce(text: quotedText(in: trimmed))
        }

        if lower == "thanks" || lower.contains("thank you") || lower.contains("awesome, thank") {
            return .thanks
        }

        return .unknown
    }

    private func quotedText(in input: String) -> String? {
        let patterns = [#"[“\"]([^”\"]+)[”\"]"#, #"[‘']([^’']+)[’']"#]
        for pattern in patterns {
            if let capture = firstCapture(pattern, in: input) {
                return capture.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func cuisine(in input: String) -> String? {
        let patterns = [
            #"(?i)(?:good|any|some)\s+([\p{L}-]+)\s+(?:restaurants?|cafes?)"#,
            #"(?i)looking for\s+([\p{L}-]+)\s+(?:food|restaurants?|cafes?)"#,
            #"(?i)^\s*([\p{L}-]+)\s+(?:restaurants?|cafes?)"#,
        ]
        return patterns.lazy.compactMap { firstCapture($0, in: input) }.first
    }

    private func location(in input: String) -> String? {
        firstCapture(#"(?i)\bin\s+([\p{L} .'-]+?)(?:[?.!,]|$)"#, in: input)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rideDestination(in input: String) -> String? {
        let patterns = [
            #"(?i)(?:uber|ride)\s+(?:me\s+)?to\s+(.+?)(?:[?.!]|$)"#,
            #"(?i)head(?:ing)?\s+to\s+(.+?)(?:[?.!]|$)"#,
        ]
        return patterns.lazy.compactMap { firstCapture($0, in: input) }.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func messageRequest(in input: String) -> (recipient: String, body: String?)? {
        guard let values = captures(
            #"(?i)(?:can you\s+|please\s+)?(?:ask|text|message)\s+([\p{L}][\p{L} .'-]*?)(?:\s+(?:and\s+)?(?:say|that|if)\s+(.+?))?[?.!]?$"#,
            in: input
        ), let recipient = values.first else {
            return nil
        }

        let body = values.count > 1 ? normalizedMessageClause(values[1]) : nil
        return (
            recipient.trimmingCharacters(in: .whitespacesAndNewlines),
            body?.isEmpty == false ? body : nil
        )
    }

    private func normalizedMessageClause(_ clause: String) -> String {
        var value = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: #"(?i)\bhe's\b"#, with: "you're", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\bshe's\b"#, with: "you're", options: .regularExpression)
        if value.lowercased().hasPrefix("you're down to ") {
            value = "Are you " + String(value.dropFirst("you're ".count))
        } else if value.lowercased().hasPrefix("down to ") {
            value = "Are you \(value)"
        } else if let first = value.first {
            value.replaceSubrange(value.startIndex ... value.startIndex, with: String(first).uppercased())
        }
        if !value.hasSuffix("?") && !value.hasSuffix("!") && !value.hasSuffix(".") {
            value += "?"
        }
        return value
    }

    private func messageRevision(in input: String) -> String? {
        let lower = input.lowercased()
        let looksLikeRevision = lower.contains("instead") || lower.contains("shorter") || lower.contains("too long") || lower.contains("replace it") || lower.contains("change it")
        guard looksLikeRevision else { return nil }

        if let quoted = quotedText(in: input), !quoted.isEmpty {
            return quoted
        }

        let patterns = [
            #"(?i)(?:just\s+)?say\s+(.+?)(?:\s+instead)?[?.!]?$"#,
            #"(?i)(?:replace|change)\s+(?:it|that|the draft)\s+(?:with|to)\s+(.+?)[?.!]?$"#,
        ]
        return patterns.lazy.compactMap { firstCapture($0, in: input) }.first?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "\"“”")))
    }

    private func firstCapture(_ pattern: String, in input: String) -> String? {
        captures(pattern, in: input)?.first
    }

    private func captures(_ pattern: String, in input: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(input.startIndex..., in: input)
        guard let match = expression.firstMatch(in: input, range: range) else { return nil }
        return (1 ..< match.numberOfRanges).compactMap { index in
            let captureRange = match.range(at: index)
            guard captureRange.location != NSNotFound, let range = Range(captureRange, in: input) else { return nil }
            return String(input[range])
        }
    }
}
