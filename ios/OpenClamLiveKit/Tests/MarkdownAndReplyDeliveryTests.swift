import UIKit
import SwiftUI
import XCTest
@testable import OpenClamLiveKit

final class MarkdownAndReplyDeliveryTests: XCTestCase {
    func testRemoteConversationTitleUsesBoundOpenClawAgentIdentityWhenIdle() {
        XCTAssertEqual(
            ConversationNavigationTitlePresentation.title(
                threadTitle: "hi",
                remoteAgentDisplayName: "Main",
                isRemoteTurnActive: false
            ),
            "OpenClaw - Main"
        )
        XCTAssertEqual(
            ConversationNavigationTitlePresentation.title(
                threadTitle: "Old title",
                remoteAgentDisplayName: "  Researcher  ",
                isRemoteTurnActive: false
            ),
            "OpenClaw - Researcher"
        )
    }

    func testRemoteConversationTitleTracksRealTurnActivity() {
        XCTAssertEqual(
            ConversationNavigationTitlePresentation.title(
                threadTitle: "hi",
                remoteAgentDisplayName: "Main",
                isRemoteTurnActive: true
            ),
            "Typing..."
        )
        XCTAssertEqual(
            ConversationNavigationTitlePresentation.title(
                threadTitle: "hi",
                remoteAgentDisplayName: "Main",
                isRemoteTurnActive: false
            ),
            "OpenClaw - Main"
        )
    }

    func testRemoteConversationTitleDistinguishesTransferAndCancellationFromTyping() {
        XCTAssertEqual(
            ConversationNavigationTitlePresentation.title(
                threadTitle: "hi",
                remoteAgentDisplayName: "Main",
                isRemoteTurnActive: true,
                remoteActivityPhase: .downloading
            ),
            "Receiving file…"
        )
        XCTAssertEqual(
            ConversationNavigationTitlePresentation.title(
                threadTitle: "hi",
                remoteAgentDisplayName: "Main",
                isRemoteTurnActive: true,
                remoteActivityPhase: .cancelling
            ),
            "Cancelling…"
        )
        XCTAssertEqual(
            ConversationNavigationTitlePresentation.title(
                threadTitle: "hi",
                remoteAgentDisplayName: "Main",
                isRemoteTurnActive: false,
                remoteActivityPhase: .downloading
            ),
            "OpenClaw - Main",
            "A completed turn must not retain an old file-transfer title."
        )
        XCTAssertEqual(
            ConversationNavigationTitlePresentation.title(
                threadTitle: "Local chat",
                remoteAgentDisplayName: nil,
                isRemoteTurnActive: true,
                remoteActivityPhase: .downloading
            ),
            "Local chat"
        )
    }

    func testLocalConversationTitleRemainsTheThreadTitle() {
        XCTAssertEqual(
            ConversationNavigationTitlePresentation.title(
                threadTitle: "Weekend plans",
                remoteAgentDisplayName: nil,
                isRemoteTurnActive: true
            ),
            "Weekend plans"
        )
        XCTAssertEqual(
            ConversationNavigationTitlePresentation.title(
                threadTitle: "New chat",
                remoteAgentDisplayName: "  ",
                isRemoteTurnActive: false
            ),
            "New chat"
        )
    }

    func testXAIListeningStatusMakesLiveAndBatchBehaviorExplicit() {
        XCTAssertEqual(
            ConversationSpeechStatusCopy.listening(
                selection: .init(
                    provider: .xAI,
                    model: AIProviderRegistry.xAILiveSpeechToTextModel
                ),
                providerName: "xAI"
            ),
            "Live text with xAI · words appear as you speak · tap Stop"
        )
        XCTAssertEqual(
            ConversationSpeechStatusCopy.listening(
                selection: .init(
                    provider: .xAI,
                    model: AIProviderRegistry.xAIBatchSpeechToTextModel
                ),
                providerName: "xAI"
            ),
            "Recording with xAI Batch · transcript appears after Stop"
        )
    }

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

    func testNewUserTurnPlacementFindsTheNewestAppendInALongHistory() throws {
        let threadID = UUID()
        let history = (0..<120).map { index in
            message(index.isMultiple(of: 2) ? .assistant : .user, "History \(index)")
        }
        let newestUser = message(.user, "Newest submitted turn")
        let immediateReply = message(.assistant, "Immediate local reply")
        var boundary = ConversationUserTurnPlacementBoundary()
        boundary.prime(with: snapshot(threadID: threadID, messages: history))

        XCTAssertEqual(
            boundary.observe(
                snapshot(
                    threadID: threadID,
                    messages: history + [newestUser, immediateReply]
                )
            ),
            newestUser.id,
            "A coalesced local reply must not hide the user turn that owns top placement."
        )
        XCTAssertNil(
            boundary.observe(
                snapshot(
                    threadID: threadID,
                    messages: history + [newestUser, immediateReply]
                )
            )
        )
    }

    func testUserTurnPlacementDoesNotTreatRestoredHistoryAsANewSend() {
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let welcome = message(.assistant, "Welcome")
        var boundary = ConversationUserTurnPlacementBoundary()
        boundary.prime(with: snapshot(threadID: firstThreadID, messages: [welcome]))

        XCTAssertNil(
            boundary.observe(
                snapshot(
                    threadID: secondThreadID,
                    messages: [welcome, message(.user, "Restored user turn")]
                )
            )
        )
    }

    func testManualScrollSuspendsAutomaticFollowingUntilTheNextUserTurn() {
        var state = ConversationThreadPositioningState()
        XCTAssertTrue(state.shouldFollowLatest)

        let firstUser = UUID()
        state.beginUserTurn(messageID: firstUser)
        XCTAssertEqual(state.anchoredUserMessageID, firstUser)
        XCTAssertFalse(state.shouldFollowLatest)

        state.noteManualScroll()
        XCTAssertTrue(state.hasManualScrollSincePlacement)
        XCTAssertFalse(state.shouldFollowLatest)

        let nextUser = UUID()
        state.beginUserTurn(messageID: nextUser)
        XCTAssertEqual(state.anchoredUserMessageID, nextUser)
        XCTAssertFalse(state.hasManualScrollSincePlacement)
        XCTAssertFalse(state.shouldFollowLatest)

        state.resetForThreadChange()
        XCTAssertNil(state.anchoredUserMessageID)
        XCTAssertTrue(state.shouldFollowLatest)
    }

    func testLatestMessageAffordanceRestoresStreamingAutoFollow() {
        var state = ConversationThreadPositioningState()

        state.noteManualScroll()
        state.noteLatestVisibility(false)
        XCTAssertTrue(state.isAwayFromLatest)
        XCTAssertFalse(state.shouldFollowLatest)

        state.resumeFollowingLatest()
        XCTAssertFalse(state.isAwayFromLatest)
        XCTAssertTrue(state.shouldFollowLatest)

        state.noteManualScroll()
        state.noteLatestVisibility(false)
        state.noteLatestVisibility(true)
        XCTAssertFalse(state.isAwayFromLatest)
        XCTAssertTrue(
            state.shouldFollowLatest,
            "Manually returning to the bottom must resume following real streamed events."
        )
    }

    func testAssistantReplyPreservesUserTurnAnchorWhenReadingPositionIsUntouched() {
        var state = ConversationThreadPositioningState()
        let userMessageID = UUID()
        let assistantMessageID = UUID()
        state.beginUserTurn(messageID: userMessageID)

        XCTAssertEqual(
            state.receiveAppendedMessages(
                userMessageID: nil,
                assistantMessageID: assistantMessageID
            ),
            .preservePosition
        )
        XCTAssertEqual(state.anchoredUserMessageID, userMessageID)
        XCTAssertFalse(state.shouldFollowLatest)
    }

    func testAssistantReplyDoesNotMoveAnIntentionallyScrolledThread() {
        var state = ConversationThreadPositioningState()
        let userMessageID = UUID()
        state.beginUserTurn(messageID: userMessageID)
        state.noteManualScroll()

        XCTAssertEqual(
            state.receiveAppendedMessages(
                userMessageID: nil,
                assistantMessageID: UUID()
            ),
            .preservePosition
        )
        XCTAssertEqual(state.anchoredUserMessageID, userMessageID)
        XCTAssertFalse(state.shouldFollowLatest)
    }

    func testCoalescedUserAndAssistantAppendAlwaysPlacesTheUserTurn() {
        var state = ConversationThreadPositioningState()
        state.noteManualScroll()
        let userMessageID = UUID()

        XCTAssertEqual(
            state.receiveAppendedMessages(
                userMessageID: userMessageID,
                assistantMessageID: UUID()
            ),
            .placeUserTurn(userMessageID)
        )
        XCTAssertEqual(state.anchoredUserMessageID, userMessageID)
        XCTAssertFalse(state.hasManualScrollSincePlacement)
    }

    func testUserTurnResponseReserveAdaptsToViewportAndAccessibilityType() {
        let phone = ConversationThreadLayout.responseReserveHeight(
            viewportHeight: 700,
            usesAccessibilityType: false
        )
        let tallPhone = ConversationThreadLayout.responseReserveHeight(
            viewportHeight: 900,
            usesAccessibilityType: false
        )
        let accessibility = ConversationThreadLayout.responseReserveHeight(
            viewportHeight: 360,
            usesAccessibilityType: true
        )

        XCTAssertEqual(phone, 660, accuracy: 0.001)
        XCTAssertEqual(tallPhone, 860, accuracy: 0.001)
        XCTAssertEqual(
            accessibility,
            ConversationThreadLayout.minimumAccessibilityResponseReserve,
            accuracy: 0.001,
            "Large Dynamic Type must retain enough response room even with a short keyboard viewport."
        )
        XCTAssertGreaterThan(tallPhone, phone)
    }

    func testAnchoredUserTurnClearsTheCompactHeader() {
        XCTAssertEqual(
            ConversationThreadLayout.anchoredTurnTopClearance(
                usesAccessibilityType: false
            ),
            ConversationThreadLayout.standardAnchoredTurnTopClearance
        )
        XCTAssertGreaterThan(
            ConversationThreadLayout.anchoredTurnTopClearance(
                usesAccessibilityType: true
            ),
            ConversationThreadLayout.standardAnchoredTurnTopClearance
        )
    }

    func testUserBubbleWidthIsCompactAndCappedOnNarrowAndWideScreens() {
        XCTAssertEqual(
            ConversationThreadLayout.userBubbleWidth(
                viewportWidth: 320,
                naturalTextWidth: 20,
                hasAttachments: false,
                isRailFolded: false
            ),
            64,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ConversationThreadLayout.userBubbleWidth(
                viewportWidth: 320,
                naturalTextWidth: 1_000,
                hasAttachments: false,
                isRailFolded: false
            ),
            205.7,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ConversationThreadLayout.userBubbleWidth(
                viewportWidth: 1_024,
                naturalTextWidth: 1_000,
                hasAttachments: true,
                isRailFolded: false
            ),
            ConversationThreadLayout.userBubbleMaximumWidth,
            accuracy: 0.001
        )
    }

    func testMessageLaneClearsTheExpandedAvatarRail() {
        let viewportWidth: CGFloat = 390
        let messageTrailingEdge = viewportWidth
            - ConversationThreadLayout.trailingMessageInset(isRailFolded: false)
        let railLeadingEdge = viewportWidth
            - ConversationThreadLayout.avatarRailOccupiedWidth

        XCTAssertEqual(
            ConversationThreadLayout.messageLaneWidth(
                viewportWidth: viewportWidth,
                isRailFolded: false
            ),
            312,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ConversationThreadLayout.additionalContentTrailingPadding(isRailFolded: false),
            46,
            accuracy: 0.001
        )
        XCTAssertEqual(
            railLeadingEdge - messageTrailingEdge,
            ConversationThreadLayout.avatarRailTextClearance,
            accuracy: 0.001,
            "The saved message text must end before the expanded avatar rail begins."
        )
    }

    func testFoldedAvatarRailRestoresSymmetricThreadMargins() {
        for viewportWidth: CGFloat in [320, 390, 430, 768, 1_024] {
            let expandedWidth = ConversationThreadLayout.messageLaneWidth(
                viewportWidth: viewportWidth,
                isRailFolded: false
            )
            let foldedWidth = ConversationThreadLayout.messageLaneWidth(
                viewportWidth: viewportWidth,
                isRailFolded: true
            )
            XCTAssertEqual(
                foldedWidth,
                viewportWidth - 2 * ConversationThreadLayout.horizontalContentInset,
                accuracy: 0.001
            )
            XCTAssertEqual(foldedWidth - expandedWidth, 46, accuracy: 0.001)
            XCTAssertEqual(
                ConversationThreadLayout.additionalContentTrailingPadding(isRailFolded: true),
                0
            )
        }
    }

    func testUserBubblesUseTheCurrentRailLaneWithoutClipping() {
        for viewportWidth: CGFloat in [0, 64, 320, 390, 768, 1_024] {
            for isRailFolded in [false, true] {
                let availableWidth = ConversationThreadLayout.messageLaneWidth(
                    viewportWidth: viewportWidth,
                    isRailFolded: isRailFolded
                )
                for hasAttachments in [false, true] {
                    let bubbleWidth = ConversationThreadLayout.userBubbleWidth(
                        viewportWidth: viewportWidth,
                        naturalTextWidth: 2_000,
                        hasAttachments: hasAttachments,
                        isRailFolded: isRailFolded
                    )
                    XCTAssertGreaterThanOrEqual(bubbleWidth, 0)
                    XCTAssertLessThanOrEqual(bubbleWidth, availableWidth)
                    XCTAssertLessThanOrEqual(
                        bubbleWidth,
                        ConversationThreadLayout.userBubbleMaximumWidth
                    )
                }
            }
        }
        XCTAssertEqual(
            ConversationThreadLayout.userBubbleWidth(
                viewportWidth: 320,
                naturalTextWidth: 1_000,
                hasAttachments: false,
                isRailFolded: true
            ),
            244.8,
            accuracy: 0.001
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

    func testWholeEntryActionsAreAssistantOnlyAndPreserveInternationalText() {
        let assistant = ConversationMessage(
            role: .assistant,
            text: "  你好，世界 🌏\nمرحبا بالعالم  "
        )
        let user = ConversationMessage(role: .user, text: assistant.text)
        let blank = ConversationMessage(role: .assistant, text: " \n ")

        XCTAssertTrue(
            ConversationMessageInteractionPolicy.supportsAssistantActions(assistant)
        )
        XCTAssertEqual(
            ConversationMessageInteractionPolicy.wholeEntryText(for: assistant),
            "你好，世界 🌏\nمرحبا بالعالم"
        )
        XCTAssertFalse(ConversationMessageInteractionPolicy.supportsAssistantActions(user))
        XCTAssertNil(ConversationMessageInteractionPolicy.wholeEntryText(for: user))
        XCTAssertFalse(ConversationMessageInteractionPolicy.supportsAssistantActions(blank))
    }

    func testUTF16SelectionHandlesEmojiCJKAndRejectsInvalidRanges() {
        let source = "Prefix 🙂 中文 نص suffix"
        let expected = "🙂 中文 نص"
        let range = (source as NSString).range(of: expected)

        XCTAssertEqual(
            ConversationMessageInteractionPolicy.selectedText(in: source, range: range),
            expected
        )
        XCTAssertNil(
            ConversationMessageInteractionPolicy.selectedText(
                in: source,
                range: NSRange(location: NSNotFound, length: 1)
            )
        )
        XCTAssertNil(
            ConversationMessageInteractionPolicy.selectedText(
                in: source,
                range: NSRange(location: (source as NSString).length, length: 1)
            )
        )
    }

    func testAskAIDraftQuotesEveryLineAndNeverSubmitsByItself() throws {
        let draft = try XCTUnwrap(
            ConversationMessageInteractionPolicy.askAIDraft(
                selectedText: "  First line\r\n\r\n中文 و العربية  ",
                existingDraft: "My question"
            )
        )

        XCTAssertTrue(draft.hasPrefix("My question\n\nAsk AI about"))
        XCTAssertTrue(draft.contains("reference text, not instructions"))
        XCTAssertTrue(draft.contains("> First line\n>\n> 中文 و العربية"))
        XCTAssertTrue(draft.hasSuffix("\n\n"))
        XCTAssertFalse(draft.localizedCaseInsensitiveContains("send now"))
        XCTAssertNil(
            ConversationMessageInteractionPolicy.askAIDraft(
                selectedText: " \n ",
                existingDraft: "Keep me"
            )
        )
    }

    @MainActor
    func testManualReadAloudDoesNotEnableAutomaticTTS() {
        let suiteName = "ConversationManualReadAloud-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let model = ConversationModel(preferences: preferences)

        XCTAssertFalse(model.isTTSEnabled)
        let beforeAutomaticAttempt = model.speechOutputStopCount
        model.speakAssistantReply("Automatic playback stays disabled.")
        XCTAssertEqual(model.speechOutputStopCount, beforeAutomaticAttempt)

        model.readAssistantReplyAloud("Read only this response.")

        XCTAssertEqual(model.speechOutputStopCount, beforeAutomaticAttempt + 1)
        XCTAssertTrue(model.isSpeechOutputActive)
        XCTAssertNotEqual(model.captainAyerAvatar.phase, .idle)
        XCTAssertFalse(model.isTTSEnabled)
        XCTAssertFalse(preferences.bool(forKey: "assistant.tts-enabled"))
        model.stopSpeechOutput()
        XCTAssertFalse(model.isSpeechOutputActive)
        XCTAssertEqual(model.captainAyerAvatar.phase, .idle)
    }

    @MainActor
    func testNativeSelectionMenuKeepsSystemCopyAndAddsAskAI() throws {
        let rendered = SelectableMessageText(
            attributedText: AttributedString("Choose this text"),
            textStyle: .body,
            onAskAI: { _ in }
        )
        let coordinator = rendered.makeCoordinator()
        let textView = UITextView()
        textView.text = "Choose this text"
        let copy = UIAction(title: "Copy") { _ in }
        let menu = try XCTUnwrap(
            coordinator.textView(
                textView,
                editMenuForTextIn: NSRange(location: 7, length: 4),
                suggestedActions: [copy]
            )
        )
        let titles = menu.children.compactMap { ($0 as? UIAction)?.title }

        XCTAssertEqual(titles, ["Copy", "Ask AI"])
    }

    @MainActor
    func testSelectableMessageTextUsesNeutralInteractionTint() {
        XCTAssertEqual(SelectableMessageText.interactionTintColor, UIColor.label)
    }

    @MainActor
    func testPhotoSaveGlyphStaysWhiteOnGraphiteUnderInheritedMessageStyle() throws {
        for scheme in [ColorScheme.light, .dark] {
            // This is the production button, under the same foreground style
            // applied by ConversationView.messageBubbleContent.
            let image = try renderPhotoSaveContrastProbe(
                AttachmentPhotoSaveButton(action: {}),
                scheme: scheme
            )
            let pixels = try photoSaveGlyphPixels(image)
            let whitePixels = pixels.filter { $0.allSatisfy { $0 >= 235 } }.count
            let graphitePixels = pixels.filter { $0.allSatisfy { $0 <= 150 } }.count

            XCTAssertGreaterThan(whitePixels, 20, "\(scheme): missing white Save to Photos glyph")
            XCTAssertGreaterThan(graphitePixels, 60, "\(scheme): missing dark primary background")
            XCTAssertTrue(
                pixels.allSatisfy { ($0.max() ?? 0) - ($0.min() ?? 0) <= 2 },
                "\(scheme): keep the action achromatic, not a blue accent"
            )

            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "Save to Photos – \(scheme) – production button"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testPhotoSaveContrastProbeReproducesOldInheritedBlackGlyph() throws {
        // The former label had no own foreground color. Keep this negative
        // control so a blank/background-only snapshot cannot pass the test.
        let oldButton = Button(action: {}) {
            Image(systemName: "photo.badge.arrow.down")
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(Color("AccentColor"))
        let image = try renderPhotoSaveContrastProbe(oldButton, scheme: .light)
        let pixels = try photoSaveGlyphPixels(image)

        XCTAssertEqual(
            pixels.filter { $0.allSatisfy { $0 >= 235 } }.count,
            0,
            "The old light-theme button must reproduce the missing white glyph."
        )
    }

    @MainActor
    private func renderPhotoSaveContrastProbe<Content: View>(
        _ content: Content,
        scheme: ColorScheme
    ) throws -> CGImage {
        let probe = content
            .foregroundStyle(.primary)
            .frame(width: 96, height: 64)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: probe)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    private func photoSaveGlyphPixels(_ image: CGImage) throws -> [[UInt8]] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // The central 24×24 points lie fully inside the 30×30 label and the
        // pill, avoiding white page pixels outside the rounded button edges.
        return ((height / 2 - 24)..<(height / 2 + 24)).flatMap { y in
            ((width / 2 - 24)..<(width / 2 + 24)).map { x in
                let offset = (y * width + x) * 4
                return Array(bytes[offset..<(offset + 3)])
            }
        }
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

    @MainActor
    func testComposerTextInsetsStayBalancedAtLargeDynamicTypeSizes() {
        XCTAssertEqual(ConversationComposerLayout.textHorizontalInset, 12)
        XCTAssertEqual(ConversationComposerLayout.textVerticalInset, 8)
        XCTAssertEqual(ConversationComposerLayout.minimumExpandedTextHeight, 62)

        for size in [DynamicTypeSize.large, .accessibility3] {
            let unpadded = hostedComposerProbeSize(
                dynamicTypeSize: size,
                appliesInsets: false
            )
            let padded = hostedComposerProbeSize(
                dynamicTypeSize: size,
                appliesInsets: true
            )

            XCTAssertEqual(
                padded.width - unpadded.width,
                ConversationComposerLayout.textHorizontalInset * 2,
                accuracy: 1
            )
            XCTAssertEqual(
                padded.height - unpadded.height,
                ConversationComposerLayout.textVerticalInset * 2,
                accuracy: 1
            )
        }

        let standard = hostedComposerTextFieldSize(
            dynamicTypeSize: .large,
            width: 240
        )
        let accessibility = hostedComposerTextFieldSize(
            dynamicTypeSize: .accessibility3,
            width: 240
        )
        XCTAssertEqual(standard.width, 240, accuracy: 1)
        XCTAssertEqual(accessibility.width, 240, accuracy: 1)
        XCTAssertTrue(standard.height.isFinite)
        XCTAssertTrue(accessibility.height.isFinite)
        XCTAssertGreaterThan(
            accessibility.height,
            standard.height,
            "Dynamic Type must grow the editor itself while preserving its own padding."
        )
    }

    @MainActor
    private func hostedComposerProbeSize(
        dynamicTypeSize: DynamicTypeSize,
        appliesInsets: Bool
    ) -> CGSize {
        let probe = Text("Composer inset probe")
            .font(.body)
        let view = Group {
            if appliesInsets {
                probe.modifier(ConversationComposerTextInsets())
            } else {
                probe
            }
        }
        .fixedSize()
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: 1_000, height: 1_000))
    }

    @MainActor
    private func hostedComposerTextFieldSize(
        dynamicTypeSize: DynamicTypeSize,
        width: CGFloat
    ) -> CGSize {
        let view = TextField(
            "Ask a follow-up",
            text: .constant("First line\nSecond line"),
            axis: .vertical
        )
            .lineLimit(2 ... 5)
            .textFieldStyle(.plain)
            .modifier(ConversationComposerTextInsets())
            .frame(width: width, alignment: .leading)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: width, height: 1_000))
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
