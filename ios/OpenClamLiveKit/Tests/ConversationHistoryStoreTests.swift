import Foundation
import XCTest
@testable import OpenClamLiveKit

final class ConversationHistoryStoreTests: XCTestCase {
    func testCreateAppendAndRelaunchPreserveStableChatAndMessageIDs() async throws {
        let fixture = try makeFixture()
        let threadID: UUID
        let messageID = UUID()
        do {
            let store = ConversationHistoryStore(fileURL: fixture.fileURL)
            let started = try await store.bootstrap(now: date(1))
            threadID = try XCTUnwrap(started.selectedThreadID)
            let saved = try await store.append(
                .init(id: messageID, role: .user, text: "Plan my Sunday"),
                to: threadID,
                now: date(2)
            )
            XCTAssertEqual(saved.selectedThread?.title, "Plan my Sunday")
        }

        let relaunched = try await ConversationHistoryStore(fileURL: fixture.fileURL).load()
        XCTAssertEqual(relaunched.selectedThreadID, threadID)
        XCTAssertEqual(relaunched.selectedThread?.messages.map(\.id), [messageID])
        XCTAssertEqual(relaunched.selectedThread?.messages.first?.text, "Plan my Sunday")
    }

    func testCreateSelectAndAppendKeepIndependentChats() async throws {
        let fixture = try makeFixture()
        let store = ConversationHistoryStore(fileURL: fixture.fileURL)
        let first = try await store.createThread(title: "First", now: date(1))
        let firstID = try XCTUnwrap(first.selectedThreadID)
        let second = try await store.createThread(title: "Second", now: date(2))
        let secondID = try XCTUnwrap(second.selectedThreadID)

        let selected = try await store.selectThread(id: firstID)
        XCTAssertEqual(selected.selectedThreadID, firstID)
        let updated = try await store.append(
            .init(role: .assistant, text: "Only in first"),
            to: firstID,
            now: date(3)
        )

        XCTAssertEqual(updated.selectedThread?.messages.map(\.text), ["Only in first"])
        XCTAssertTrue(updated.threads.first(where: { $0.id == secondID })?.messages.isEmpty == true)
    }

    func testRenameAndDeleteChooseNewestRemainingChat() async throws {
        let fixture = try makeFixture()
        let store = ConversationHistoryStore(fileURL: fixture.fileURL)
        let first = try await store.createThread(title: "First", now: date(1))
        let firstID = try XCTUnwrap(first.selectedThreadID)
        let second = try await store.createThread(title: "Second", now: date(2))
        let secondID = try XCTUnwrap(second.selectedThreadID)

        let renamed = try await store.renameThread(id: firstID, title: "  Holiday ideas  ", now: date(4))
        XCTAssertEqual(renamed.threads.first?.title, "Holiday ideas")
        XCTAssertEqual(renamed.threads.first?.id, firstID)

        _ = try await store.selectThread(id: firstID)
        let afterDelete = try await store.deleteThread(id: firstID)
        XCTAssertEqual(afterDelete.selectedThreadID, secondID)
        XCTAssertEqual(afterDelete.threads.map(\.id), [secondID])
    }

    func testHistoryIsSortedByLastUpdateNotSelection() async throws {
        let fixture = try makeFixture()
        let store = ConversationHistoryStore(fileURL: fixture.fileURL)
        let old = try await store.createThread(title: "Old", now: date(1))
        let oldID = try XCTUnwrap(old.selectedThreadID)
        let recent = try await store.createThread(title: "Recent", now: date(3))
        let recentID = try XCTUnwrap(recent.selectedThreadID)

        let selectedOld = try await store.selectThread(id: oldID)
        XCTAssertEqual(selectedOld.threads.map(\.id), [recentID, oldID])
        let bumped = try await store.append(
            .init(role: .user, text: "Bump old"),
            to: oldID,
            now: date(5)
        )
        XCTAssertEqual(bumped.threads.map(\.id), [oldID, recentID])
    }

    func testBoundedStoreKeepsNewestThreadsAndNewestMessages() async throws {
        let fixture = try makeFixture()
        var limits = ConversationHistoryStore.Limits.standard
        limits.maximumThreads = 2
        limits.maximumMessagesPerThread = 2
        let store = ConversationHistoryStore(fileURL: fixture.fileURL, limits: limits)
        let first = try await store.createThread(title: "One", now: date(1))
        let firstID = try XCTUnwrap(first.selectedThreadID)
        _ = try await store.append(.init(role: .user, text: "1"), to: firstID, now: date(2))
        _ = try await store.append(.init(role: .assistant, text: "2"), to: firstID, now: date(3))
        _ = try await store.append(.init(role: .user, text: "3"), to: firstID, now: date(4))
        _ = try await store.createThread(title: "Two", now: date(5))
        _ = try await store.createThread(title: "Three", now: date(6))

        let state = try await store.load()
        XCTAssertEqual(state.threads.map(\.title), ["Three", "Two"])

        let messageFixture = try makeFixture()
        let messageStore = ConversationHistoryStore(fileURL: messageFixture.fileURL, limits: limits)
        let chat = try await messageStore.createThread(now: date(1))
        let chatID = try XCTUnwrap(chat.selectedThreadID)
        _ = try await messageStore.replaceMessages(
            [
                .init(role: .user, text: "old"),
                .init(role: .assistant, text: "middle"),
                .init(role: .user, text: "new"),
            ],
            in: chatID,
            now: date(2)
        )
        let boundedState = try await messageStore.load()
        XCTAssertEqual(boundedState.selectedThread?.messages.map(\.text), ["middle", "new"])
    }

    func testCorruptArchiveRecoversWithoutReusingUnknownBytes() async throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not-json:sk-should-not-survive}".utf8).write(to: fixture.fileURL)

        let store = ConversationHistoryStore(fileURL: fixture.fileURL)
        let emptyState = try await store.load()
        XCTAssertEqual(emptyState, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        let quarantinedFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("history.json.corrupt-") }
        XCTAssertEqual(quarantinedFiles.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(quarantinedFiles.first)),
            Data("{not-json:sk-should-not-survive}".utf8)
        )
        guard case .malformedArchiveQuarantined(let filename) = await store.takeRecoveryWarning() else {
            return XCTFail("Expected a recoverable quarantine warning")
        }
        XCTAssertEqual(filename, quarantinedFiles.first?.lastPathComponent)
        let recovered = try await store.bootstrap(now: date(1))
        XCTAssertEqual(recovered.threads.count, 1)
    }

    func testOrdinaryReadFailurePreservesArchiveForRetry() async throws {
        let fixture = try makeFixture()
        let initialStore = ConversationHistoryStore(fileURL: fixture.fileURL)
        let started = try await initialStore.bootstrap(now: date(1))
        let threadID = try XCTUnwrap(started.selectedThreadID)
        _ = try await initialStore.append(
            .init(role: .user, text: "Preserve me after read protection failure"),
            to: threadID,
            now: date(2)
        )
        let originalBytes = try Data(contentsOf: fixture.fileURL)
        let gate = HistoryFailureGate(operation: .read)
        let failingStore = ConversationHistoryStore(
            fileURL: fixture.fileURL,
            failureInjector: { try gate.check($0) }
        )

        do {
            _ = try await failingStore.load()
            XCTFail("Expected the injected read failure")
        } catch is InjectedHistoryFailure {
            // Expected: an I/O/protection failure is surfaced without altering the archive.
        }

        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), originalBytes)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                .contains { $0.hasPrefix("history.json.corrupt-") }
        )
        let retried = try await ConversationHistoryStore(fileURL: fixture.fileURL).load()
        XCTAssertEqual(retried.selectedThread?.messages.last?.text, "Preserve me after read protection failure")
    }

    func testFailedTransactionalDeleteLeavesSelectedChatAndDiskUnchanged() async throws {
        let fixture = try makeFixture()
        let gate = HistoryFailureGate()
        let store = ConversationHistoryStore(
            fileURL: fixture.fileURL,
            failureInjector: { try gate.check($0) }
        )
        let started = try await store.bootstrap(
            initialMessages: [.init(role: .assistant, text: "Original welcome")],
            now: date(1)
        )
        let originalThreadID = try XCTUnwrap(started.selectedThreadID)
        let originalBytes = try Data(contentsOf: fixture.fileURL)
        gate.operation = .persist

        do {
            _ = try await store.deleteThread(
                id: originalThreadID,
                replacementMessages: [.init(role: .assistant, text: "Replacement welcome")],
                now: date(2)
            )
            XCTFail("Expected the injected transactional write failure")
        } catch is InjectedHistoryFailure {
            // Expected.
        }

        let stateAfterFailure = try await store.load()
        XCTAssertEqual(stateAfterFailure, started)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), originalBytes)

        gate.operation = nil
        let replaced = try await store.deleteThread(
            id: originalThreadID,
            replacementMessages: [.init(role: .assistant, text: "Replacement welcome")],
            now: date(2)
        )
        XCTAssertEqual(replaced.threads.count, 1)
        XCTAssertNotEqual(replaced.selectedThreadID, originalThreadID)
        XCTAssertEqual(replaced.selectedThread?.messages.map(\.text), ["Replacement welcome"])
    }

    func testPersistenceOmitsEphemeralMessagesCredentialsAndRawAttachmentBytes() async throws {
        let fixture = try makeFixture()
        let store = ConversationHistoryStore(fileURL: fixture.fileURL)
        let started = try await store.bootstrap(now: date(1))
        let threadID = try XCTUnwrap(started.selectedThreadID)
        let secretLikeProviderKey = ["sk", "proj", "abcdefghijklmnop"].joined(separator: "-")
        let binary = String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo", count: 12)
        let providerPayload = "data:image/png;base64,\(binary)"
        let prepared = PreparedAgentAttachment(
            id: UUID(),
            kind: .image,
            displayName: "/private/tmp/chosen.png",
            sourceByteCount: 42,
            payloadByteCount: providerPayload.utf8.count,
            contentParts: [.inputImage(imageURL: providerPayload)]
        )
        let rendered = ConversationMessage(
            role: .user,
            text: "**Keep this Markdown.** Use api_key=ultra-secret \(secretLikeProviderKey) Bearer abcdefghijklmnop data:image/png;base64,QUJD and \(binary)",
            attachments: [.init(preparedAttachment: prepared)]
        )
        let ephemeral = ConversationMessage(
            role: .assistant,
            text: "private-contact-result",
            historyPersistence: .ephemeral
        )
        _ = try await store.replaceMessages([rendered, ephemeral], in: threadID, now: date(2))

        let bytes = try Data(contentsOf: fixture.fileURL)
        let archive = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(archive.contains("ultra-secret"))
        XCTAssertFalse(archive.contains(secretLikeProviderKey))
        XCTAssertFalse(archive.contains("abcdefghijklmnop"))
        XCTAssertFalse(archive.contains("data:image/png;base64"))
        XCTAssertFalse(archive.contains(binary))
        XCTAssertFalse(archive.contains(providerPayload))
        XCTAssertFalse(archive.contains("private-contact-result"))
        XCTAssertFalse(archive.contains("/private/tmp"))
        XCTAssertTrue(archive.contains("chosen.png"))

        let restored = try await ConversationHistoryStore(fileURL: fixture.fileURL).load()
        XCTAssertEqual(restored.selectedThread?.messages.count, 1)
        XCTAssertTrue(restored.selectedThread?.messages.first?.text.contains("**Keep this Markdown.**") == true)
        XCTAssertEqual(restored.selectedThread?.messages.first?.attachmentNames, ["chosen.png"])
    }

    func testLegacyMessageAttachmentNamesDecodeWithoutNewFields() async throws {
        let fixture = try makeFixture()
        let threadID = UUID()
        let messageID = UUID()
        let legacy = """
        {
          "selectedThreadID": "\(threadID.uuidString)",
          "threads": [{
            "id": "\(threadID.uuidString)",
            "title": "Legacy",
            "createdAt": 10,
            "updatedAt": 20,
            "messages": [{
              "id": "\(messageID.uuidString)",
              "role": "user",
              "text": "Old chat",
              "attachmentNames": ["photo.jpg"],
              "date": 15
            }]
          }]
        }
        """
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(legacy.utf8).write(to: fixture.fileURL)

        let state = try await ConversationHistoryStore(fileURL: fixture.fileURL).load()
        XCTAssertEqual(state.selectedThreadID, threadID)
        XCTAssertEqual(state.selectedThread?.messages.first?.id, messageID)
        XCTAssertEqual(state.selectedThread?.messages.first?.attachmentNames, ["photo.jpg"])
        XCTAssertEqual(state.selectedThread?.messages.first?.historyPersistence, .history)
    }

    func testUnknownFutureEnumsDecodeWithPrivacySafeFallbacks() throws {
        let encoded = """
        {
          "role": "future_role",
          "text": "Future message",
          "historyPersistence": "future_private_policy",
          "attachments": [{
            "kind": "future_media",
            "displayName": "item.bin"
          }]
        }
        """
        let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(encoded.utf8))
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.historyPersistence, .ephemeral)
        XCTAssertEqual(message.attachments.first?.kind, .unknown)
    }

    private struct Fixture {
        let root: URL
        let fileURL: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationHistoryStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            root: root,
            fileURL: root.appendingPathComponent("history.json")
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}

private struct InjectedHistoryFailure: Error, Sendable {}

private final class HistoryFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOperation: ConversationHistoryStore.IOOperation?

    init(operation: ConversationHistoryStore.IOOperation? = nil) {
        storedOperation = operation
    }

    var operation: ConversationHistoryStore.IOOperation? {
        get {
            lock.withLock { storedOperation }
        }
        set {
            lock.withLock { storedOperation = newValue }
        }
    }

    func check(_ operation: ConversationHistoryStore.IOOperation) throws {
        if lock.withLock({ storedOperation == operation }) {
            throw InjectedHistoryFailure()
        }
    }
}
