import Foundation
import SwiftUI
import UIKit

/// Renders only local text, bounded in-memory previews, and persisted attachment metadata.
/// It intentionally has no network-backed image view, so Markdown image destinations can never
/// trigger a fetch.
struct MarkdownMessageView: View {
    let message: ConversationMessage
    let localImagePreviews: [UUID: UIImage]

    init(
        message: ConversationMessage,
        localImagePreviews: [UUID: UIImage] = [:]
    ) {
        self.message = message
        self.localImagePreviews = localImagePreviews
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.text.isEmpty {
                ForEach(
                    Array(SafeMarkdownParser.blocks(from: message.text).enumerated()),
                    id: \.offset
                ) { _, block in
                    blockView(block)
                }
            }

            if !message.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(message.attachments) { attachment in
                        attachmentCard(attachment)
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        // Keep the message context and every interactive child (especially HTTPS links) as
        // separate VoiceOver elements. `.combine` would turn links into inert bubble text.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? "Your message" : "Assistant message")
    }

    @ViewBuilder
    private func blockView(_ block: SafeMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let source):
            Text(SafeMarkdownParser.safeInlineMarkdown(from: source))
                .font(headingFont(level: level))
                .fontWeight(.semibold)
                .tint(.blue)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let source):
            Text(SafeMarkdownParser.safeInlineMarkdown(from: source))
                .font(.body)
                .tint(.blue)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .listItem(let ordered, let ordinal, let level, let source):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ordered ? "\(ordinal ?? 1)." : "•")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20, alignment: .trailing)

                Text(SafeMarkdownParser.safeInlineMarkdown(from: source))
                    .font(.body)
                    .tint(.blue)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(min(level, 6)) * 18)

        case .blockQuote(let source):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.secondary.opacity(0.55))
                    .frame(width: 3)
                    .accessibilityHidden(true)

                Text(SafeMarkdownParser.safeInlineMarkdown(from: source))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .tint(.blue)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let language, let source):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: source)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(language.map { "\($0) code block" } ?? "Code block")
        }
    }

    private func attachmentCard(_ attachment: ConversationAttachmentDescriptor) -> some View {
        let localPreview = attachment.kind == .image
            ? localImagePreviews[attachment.id]
            : nil

        return HStack(alignment: .top, spacing: 10) {
            if let localPreview {
                Image(uiImage: localPreview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: attachment.kind.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                if let detail = attachment.detailText {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if attachment.kind == .image, localPreview == nil {
                    Text("Image preview isn’t stored; metadata only.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            attachment.accessibilityDescription
                + (localPreview == nil || attachment.kind != .image
                    ? ""
                    : ". Local image preview available for this app session")
        )
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
    }
}

enum SafeMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(ordered: Bool, ordinal: Int?, level: Int, text: String)
    case blockQuote(String)
    case code(language: String?, text: String)
}

enum SafeMarkdownParser {
    private static let imagePattern = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\](?:\([^\n)]*\)|\[[^\]\n]*\])"#
    )

    static func blocks(from source: String) -> [SafeMarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var result: [SafeMarkdownBlock] = []
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            result.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = fence(in: trimmed) {
                flushParagraph()
                let languageValue = String(trimmed.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let language = languageValue.isEmpty ? nil : languageValue
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                result.append(.code(language: language, text: codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = heading(in: trimmed) {
                flushParagraph()
                result.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoteLines.append(
                        String(candidate.dropFirst())
                            .trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                result.append(.blockQuote(quoteLines.joined(separator: "\n")))
                continue
            }

            if let item = listItem(in: line) {
                flushParagraph()
                result.append(
                    .listItem(
                        ordered: item.ordered,
                        ordinal: item.ordinal,
                        level: item.level,
                        text: item.text
                    )
                )
                index += 1
                continue
            }

            let indentation = indentationColumns(in: line)
            if indentation > 0,
               paragraphLines.isEmpty,
               let last = result.indices.last,
               case .listItem(let ordered, let ordinal, let level, let existing) = result[last] {
                result[last] = .listItem(
                    ordered: ordered,
                    ordinal: ordinal,
                    level: level,
                    text: existing + " " + trimmed
                )
            } else {
                paragraphLines.append(trimmed)
            }
            index += 1
        }

        flushParagraph()
        return result
    }

    static func safeInlineMarkdown(from source: String) -> AttributedString {
        let withoutImages = removingMarkdownImages(from: source)
        var rendered = (try? AttributedString(
            markdown: withoutImages,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(withoutImages)

        let unsafeLinkRanges = rendered.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let link = run.link,
                  link.scheme?.lowercased() != "https" else { return nil }
            return run.range
        }
        for range in unsafeLinkRanges {
            rendered[range].link = nil
        }
        return rendered
    }

    private static func removingMarkdownImages(from source: String) -> String {
        let range = NSRange(source.startIndex ..< source.endIndex, in: source)
        return imagePattern.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "$1"
        )
    }

    private static func fence(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let prefix = line.prefix { $0 == "#" }
        guard (1 ... 6).contains(prefix.count),
              line.count > prefix.count else { return nil }
        let contentStart = line.index(line.startIndex, offsetBy: prefix.count)
        guard line[contentStart].isWhitespace else { return nil }
        let text = String(line[contentStart...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (prefix.count, text)
    }

    private static func listItem(
        in line: String
    ) -> (ordered: Bool, ordinal: Int?, level: Int, text: String)? {
        let indentation = indentationColumns(in: line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let level = min(indentation / 2, 6)

        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let text = String(trimmed.dropFirst(marker.count))
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return (false, nil, level, text)
        }

        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty,
              let ordinal = Int(digits) else { return nil }
        let delimiterIndex = trimmed.index(trimmed.startIndex, offsetBy: digits.count)
        guard delimiterIndex < trimmed.endIndex,
              trimmed[delimiterIndex] == "." || trimmed[delimiterIndex] == ")" else {
            return nil
        }
        let textStart = trimmed.index(after: delimiterIndex)
        guard textStart < trimmed.endIndex,
              trimmed[textStart].isWhitespace else { return nil }
        let text = String(trimmed[textStart...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (true, ordinal, level, text)
    }

    private static func indentationColumns(in line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(into: 0) { result, character in
            result += character == "\t" ? 4 : 1
        }
    }
}

private extension ConversationAttachmentDescriptor.Kind {
    var systemImage: String {
        switch self {
        case .image: "photo"
        case .video: "video"
        case .file: "doc"
        case .unknown: "paperclip"
        }
    }

    var displayName: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .file: "File"
        case .unknown: "Attachment"
        }
    }
}

private extension ConversationAttachmentDescriptor {
    var detailText: String? {
        var values: [String] = [kind.displayName]
        if let mimeType, !mimeType.isEmpty {
            values.append(mimeType)
        }
        if let sourceByteCount {
            values.append(
                ByteCountFormatter.string(
                    fromByteCount: Int64(sourceByteCount),
                    countStyle: .file
                )
            )
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    var accessibilityDescription: String {
        if let detailText {
            return "Attachment: \(displayName). \(detailText)"
        }
        return "Attachment: \(displayName)"
    }
}
