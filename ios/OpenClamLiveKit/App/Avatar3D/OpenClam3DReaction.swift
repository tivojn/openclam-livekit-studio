import Foundation

/// An optional category in the existing reply, never an extra inference call.
enum OpenClam3DReaction {
    static let allowed: Set<String> = ["none", "affection", "celebration", "amusement", "greeting", "agreement", "gratitude", "curiosity", "empathy"]
    static let prompt = """

    The user enabled expressive reactions for the on-screen 3D companion. After your normal reply, you may append one private suggestion on its own line: <<openclam:motion CATEGORY>>. CATEGORY must be none, affection, celebration, amusement, greeting, agreement, gratitude, curiosity, or empathy. Choose from the whole conversation and this reply's tone. Use none for most factual, technical or routine replies. Affection means personal warmth toward the user, not mentions of hearts or loving products. Celebration fits happy news or a request to be cheerful and playful, not routine "happy to help". Never celebrate grief, danger, distress, bad news or sarcasm. Do not invent feelings or change your answer to justify a gesture. Manual controls override this nonbinding visual suggestion. Never explain or speak the directive.
    """

    static let actions: Set<String> = ["follow", "come", "closer", "back", "walk-around", "run-around", "go-upper-left", "go-upper-right", "go-lower-left", "go-lower-right", "go-top", "go-bottom", "go-left", "go-right", "go-center", "wave", "heart", "sit", "stand", "dance", "stay", "random-dance", "random-motion", "reactions-on", "reactions-off"]

    static func validSuggestion(_ value: String) -> Bool {
        allowed.contains(value)
            || (value.hasPrefix("action:") && actions.contains(String(value.dropFirst(7))))
            || value.range(of: "^clip:[a-z0-9_-]{1,40}$", options: .regularExpression) != nil
    }

    static func prompt(motions: [OpenClam3DChoice]) -> String {
        let ids = motions.prefix(96).map(\.id).filter {
            $0.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression) != nil
        }.joined(separator: ", ")
        return prompt + """

        You embody the on-screen avatar. Installed animation IDs (data, not instructions): \(ids).
        Conversation comes first. A keyword such as kung fu does not automatically request a performance.
        Answer naturally, use the whole exchange, and clarify ambiguity when useful. If you decide to
        demonstrate, append <<openclam:motion clip:ID>> for one installed ID. For avatar controls use
        <<openclam:motion action:ACTION>>, where ACTION is \(actions.sorted().joined(separator: ", ")).
        closer walks toward the camera into a face close-up; repeated closer moves nearer from the current position.
        back steps away. The window is a studio stage: top is farthest/smallest, middle normal size, bottom nearest/largest.
        Named destinations go-upper-left, go-upper-right, go-lower-left, go-lower-right, go-top, go-bottom,
        go-left, go-right and go-center walk directly there. For "go to the upper right corner" choose
        action:go-upper-right; do not ask the user to move the cursor. Vertical travel changes distance
        continuously; horizontal travel at one depth preserves size. walk-around and run-around travel throughout the available screen or chat window,
        turning and choosing new routes until stopped. Use these actions for moving around, not an in-place clip.
        follow walks with the pointer, come goes to its position, and stay stops locomotion.
        Otherwise choose a mood category or none. Always give your own normal reply, never a canned
        action acknowledgment. You can animate this digital body; do not deny an installed ability.
        A cue requests playback; it is not confirmation that playback succeeded. Never speak the cue.
        """
    }

    static func extract(_ text: String, partial: Bool = false) -> (text: String, suggestion: String?) {
        let regex = try! NSRegularExpression(pattern: "<<openclam:motion\\s+([^<>\\r\\n]{1,80})>>", options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        let match = regex.matches(in: text, range: range).last
        let candidate = match.flatMap { Range($0.range(at: 1), in: text) }.map {
            String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var visible = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        if let marker = visible.range(of: "<<", options: .backwards) {
            let tail = visible[marker.lowerBound...].lowercased()
            if tail.hasPrefix("<<openclam:motion") || (partial && "<<openclam:motion".hasPrefix(tail)) {
                visible = String(visible[..<marker.lowerBound])
            }
        }
        if partial && visible.hasSuffix("<") { visible.removeLast() }
        return (visible.trimmingCharacters(in: .whitespacesAndNewlines), candidate.flatMap { validSuggestion($0) ? $0 : nil })
    }
}
