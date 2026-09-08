import Foundation

/// An optional category in the existing reply, never an extra inference call.
enum OpenClam3DReaction {
    static let allowed: Set<String> = ["none", "affection", "celebration", "amusement", "greeting", "agreement", "gratitude", "curiosity", "empathy"]
    static let prompt = """

    The user enabled expressive reactions for the on-screen 3D companion. After your normal reply, you may append one private suggestion on its own line: <<openclam:motion CATEGORY>>. CATEGORY must be none, affection, celebration, amusement, greeting, agreement, gratitude, curiosity, or empathy. Choose from the whole conversation and this reply's tone. Use none for most factual, technical or routine replies. Affection means personal warmth toward the user, not mentions of hearts or loving products. Celebration fits happy news or a request to be cheerful and playful, not routine "happy to help". Never celebrate grief, danger, distress, bad news or sarcasm. Do not invent feelings or change your answer to justify a gesture. Manual controls override this nonbinding visual suggestion. Never explain or speak the directive.
    """

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
        return (visible.trimmingCharacters(in: .whitespacesAndNewlines), candidate.flatMap { allowed.contains($0) ? $0 : nil })
    }
}
