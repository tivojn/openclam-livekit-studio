import UIKit
import SwiftUI
import XCTest
@testable import OpenClamLiveKit

final class MarkdownAndReplyDeliveryTests: XCTestCase {
    func testHistoryTransitionsNeverEmitAssistantReplyDelivery() {
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let restoredAssistant = message(.assistant, "Private restored answer")
        var boundary = AssistantReplyDeliveryBoundary()

        boundary.prime(
            with: snapshot(
                threadID: firstThreadID,
                messages: [message(.assistant, "Welcome")]
            )
        )

        XCTAssertNil(
            boundary.observe(
                snapshot(threadID: secondThreadID, messages: [restoredAssistant])
            )
        )
        XCTAssertNil(
            boundary.observe(
                snapshot(
                    threadID: firstThreadID,
                    messages: [message(.assistant, "Welcome")]
                )
            )
        )
    }

    func testOnlyNewlyAppendedAssistantReplyIsDeliveredOnce() throws {
        let threadID = UUID()
        let welcome = message(.assistant, "Welcome")
        let user = message(.user, "Question")
        let assistant = message(.assistant, "New answer")
        var boundary = AssistantReplyDeliveryBoundary()

        boundary.prime(with: snapshot(threadID: threadID, messages: [welcome]))
        XCTAssertNil(
            boundary.observe(snapshot(threadID: threadID, messages: [welcome, user]))
        )
        XCTAssertEqual(
            boundary.observe(snapshot(threadID: threadID, messages: [welcome, user, assistant])),
            assistant.id
        )
        XCTAssertNil(
            boundary.observe(snapshot(threadID: threadID, messages: [welcome, user, assistant]))
        )

        let replacement = message(.assistant, "Loaded replacement")
        XCTAssertNil(
            boundary.observe(snapshot(threadID: threadID, messages: [replacement]))
        )
    }

    func testCoalescedUserAndAssistantAppendDeliversTheNewAssistant() {
        let threadID = UUID()
        let welcome = message(.assistant, "Welcome")
        let user = message(.user, "Question")
        let assistant = message(.assistant, "Immediate local answer")
        var boundary = AssistantReplyDeliveryBoundary()
        boundary.prime(with: snapshot(threadID: threadID, messages: [welcome]))

        XCTAssertEqual(
            boundary.observe(snapshot(threadID: threadID, messages: [welcome, user, assistant])),
            assistant.id
        )
    }

    func testBlockParserPreservesNativeMarkdownStructure() {
        let source = """
        # Heading

        Paragraph with **bold** and *emphasis*.

        - First
          - Nested
        3. Ordered

        > A quoted **thought**.

        ```swift
        let value = 42
        ```
        """

        XCTAssertEqual(
            SafeMarkdownParser.blocks(from: source),
            [
                .heading(level: 1, text: "Heading"),
                .paragraph("Paragraph with **bold** and *emphasis*."),
                .listItem(ordered: false, ordinal: nil, level: 0, text: "First"),
                .listItem(ordered: false, ordinal: nil, level: 1, text: "Nested"),
                .listItem(ordered: true, ordinal: 3, level: 0, text: "Ordered"),
                .blockQuote("A quoted **thought**."),
                .code(language: "swift", text: "let value = 42"),
            ]
        )
    }

    func testInlineMarkdownKeepsOnlyHTTPSLinksAndNeverRepresentsRemoteImages() {
        let rendered = SafeMarkdownParser.safeInlineMarkdown(
            from: """
            [Secure](https://example.com) [Mail](mailto:test@example.com) \
            [Script](javascript:alert(1)) [Relative](/private) \
            ![Remote preview](https://images.example.com/private.png)
            """
        )
        let links = rendered.runs.compactMap(\.link)
        let text = String(rendered.characters)

        XCTAssertEqual(links, [URL(string: "https://example.com")!])
        XCTAssertTrue(text.contains("Remote preview"))
        XCTAssertFalse(text.contains("images.example.com"))
    }

    func testLocalImagePreviewIsPixelBounded() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 1_200, height: 600),
            format: format
        ).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 600))
        }
        let data = try XCTUnwrap(source.jpegData(compressionQuality: 0.85))
        let preview = try XCTUnwrap(LocalAttachmentPreviewFactory.makePreview(from: data))

        XCTAssertLessThanOrEqual(preview.size.width, 384)
        XCTAssertLessThanOrEqual(preview.size.height, 384)
        XCTAssertEqual(preview.scale, 1)
    }

    @MainActor
    func testRendererLaysOutInDarkModeAtAccessibilityDynamicType() {
        let message = ConversationMessage(
            role: .assistant,
            text: """
            ## Accessible heading
            - A list item with an [HTTPS link](https://example.com)
            > A quoted paragraph
            ```
            bounded code
            ```
            """,
            attachments: [
                .init(kind: .image, displayName: "Persisted image metadata"),
            ]
        )
        let view = MarkdownMessageView(message: message)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, .accessibility3)
        let host = UIHostingController(rootView: view)
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 2_000))

        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertTrue(size.width.isFinite)
        XCTAssertTrue(size.height.isFinite)
    }

    private func message(
        _ role: ConversationMessage.Role,
        _ text: String
    ) -> ConversationMessage {
        ConversationMessage(role: role, text: text)
    }

    private func snapshot(
        threadID: UUID?,
        messages: [ConversationMessage]
    ) -> AssistantReplyDeliverySnapshot {
        AssistantReplyDeliverySnapshot(threadID: threadID, messages: messages)
    }
}
