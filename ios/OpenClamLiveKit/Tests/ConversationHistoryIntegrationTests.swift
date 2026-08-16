import XCTest
@testable import OpenClamLiveKit

@MainActor
final class ConversationHistoryIntegrationTests: XCTestCase {
    func testConversationModelCreatesAndReopensLocalChats() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("history.json")
        let history = ConversationHistoryController(
            store: ConversationHistoryStore(fileURL: fileURL)
        )
        let suiteName = "ConversationHistoryIntegrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let model = ConversationModel(
            preferences: preferences,
            historyController: history
        )
        await waitUntil { model.isHistoryReady }
        let firstThreadID = try XCTUnwrap(history.selectedThreadID)

        await model.submit("Remember this local chat", aiConfiguration: nil)
        await model.newChat()

        XCTAssertNotEqual(history.selectedThreadID, firstThreadID)
        XCTAssertFalse(model.messages.contains { $0.text == "Remember this local chat" })

        await model.selectChat(id: firstThreadID)
        XCTAssertTrue(model.messages.contains { $0.text == "Remember this local chat" })
        XCTAssertEqual(history.selectedThreadID, firstThreadID)
    }

    func testChangingChatsClearsOneShotContextPromptAndAppHandoffState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let history = ConversationHistoryController(
            store: ConversationHistoryStore(
                fileURL: directory.appendingPathComponent("history.json")
            )
        )
        let suiteName = "ConversationHistoryTransientStateTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let model = ConversationModel(
            preferences: preferences,
            historyController: history
        )
        await waitUntil { model.isHistoryReady }
        model.stageScreenContextSubmission(
            .init(
                reviewID: UUID(),
                instruction: "Describe this screen",
                includedText: nil,
                includedURL: nil,
                includedImageData: Data([0x01]),
                includedImageTypeIdentifier: "public.png"
            )
        )
        try PendingAgentPromptStore.save("Pending Siri question", defaults: preferences)
        model.restorePendingShortcutPrompt(defaults: preferences)
        _ = try model.appHandoffSession.stage(
            rawURL: "https://example.com/menu",
            latestUserText: "Open https://example.com/menu",
            origin: .exactUserEntry
        )

        await model.newChat()

        XCTAssertNil(model.pendingScreenContextSubmission)
        XCTAssertNil(model.pendingShortcutPrompt)
        XCTAssertNil(model.pendingAppHandoffProposal)
        XCTAssertNil(model.appHandoffSession.proposal)
    }

    func testRapidNewChatRequestsCreateOnlyOneAdditionalChat() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let history = ConversationHistoryController(
            store: ConversationHistoryStore(
                fileURL: directory.appendingPathComponent("history.json")
            )
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationModel(historyController: history)
        await waitUntil { model.isHistoryReady }
        let initialCount = history.summaries.count

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { @MainActor in await model.newChat() }
            }
        }

        XCTAssertEqual(history.summaries.count, initialCount + 1)
    }

    func testContactAgentReplyIsVisibleOnlyForCurrentSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "Contact-only note: home email is private-\(UUID().uuidString)@example.test"
        let firstHistory = ConversationHistoryController(
            store: ConversationHistoryStore(fileURL: fileURL)
        )
        let firstModel = ConversationModel(historyController: firstHistory)
        await waitUntil { firstModel.isHistoryReady }

        firstModel.recordFeatureReply(marker)

        XCTAssertEqual(firstModel.messages.last?.text, marker)
        XCTAssertEqual(firstModel.messages.last?.historyPersistence, .ephemeral)
        let persisted = await firstModel.persistConversationHistory()
        XCTAssertTrue(persisted)
        XCTAssertFalse(
            try XCTUnwrap(String(data: Data(contentsOf: fileURL), encoding: .utf8))
                .contains(marker)
        )

        let relaunchedHistory = ConversationHistoryController(
            store: ConversationHistoryStore(fileURL: fileURL)
        )
        let relaunchedModel = ConversationModel(historyController: relaunchedHistory)
        await waitUntil { relaunchedModel.isHistoryReady }
        XCTAssertFalse(relaunchedModel.messages.contains { $0.text == marker })
    }

    func testDeletingUnrelatedChatKeepsSelectedSessionMessagesAndTransientState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let history = ConversationHistoryController(
            store: ConversationHistoryStore(
                fileURL: directory.appendingPathComponent("history.json")
            )
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationModel(historyController: history)
        await waitUntil { model.isHistoryReady }
        let selectedThreadID = try XCTUnwrap(history.selectedThreadID)
        await model.newChat()
        let unrelatedThreadID = try XCTUnwrap(history.selectedThreadID)
        await model.selectChat(id: selectedThreadID)
        let ephemeralMarker = "Current-session contact result \(UUID().uuidString)"
        let reviewID = UUID()
        model.recordFeatureReply(ephemeralMarker)
        model.stageScreenContextSubmission(
            .init(
                reviewID: reviewID,
                instruction: "Keep this staged",
                includedText: nil,
                includedURL: nil,
                includedImageData: Data([0x01]),
                includedImageTypeIdentifier: "public.png"
            )
        )
        let messageIDsBeforeDelete = model.messages.map(\.id)

        await model.deleteChat(id: unrelatedThreadID)

        XCTAssertEqual(history.selectedThreadID, selectedThreadID)
        XCTAssertEqual(model.messages.map(\.id), messageIDsBeforeDelete)
        XCTAssertTrue(model.messages.contains { $0.text == ephemeralMarker })
        XCTAssertEqual(model.pendingScreenContextSubmission?.reviewID, reviewID)
        XCTAssertFalse(history.summaries.contains { $0.id == unrelatedThreadID })
    }

    func testFailedSelectedChatDeleteDoesNotResetModelOrDivergeFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("history.json")
        let gate = ModelHistoryFailureGate()
        let history = ConversationHistoryController(
            store: ConversationHistoryStore(
                fileURL: fileURL,
                failureInjector: { try gate.check($0) }
            )
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationModel(historyController: history)
        await waitUntil { model.isHistoryReady }
        let selectedThreadID = try XCTUnwrap(history.selectedThreadID)
        let controllerStateBeforeDelete = history.state
        let originalBytes = try Data(contentsOf: fileURL)
        let marker = "Visible until delete succeeds \(UUID().uuidString)"
        model.recordFeatureReply(marker)
        gate.operation = .persist

        await model.deleteChat(id: selectedThreadID)

        XCTAssertEqual(history.selectedThreadID, selectedThreadID)
        XCTAssertEqual(history.state, controllerStateBeforeDelete)
        XCTAssertTrue(model.messages.contains { $0.text == marker })
        XCTAssertNotNil(history.errorMessage)
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
        let diskState = try await ConversationHistoryStore(fileURL: fileURL).load()
        XCTAssertEqual(diskState.selectedThreadID, selectedThreadID)
    }

    func testModelDoesNotAcceptTurnsOrConsumeStartupPromptBeforeHistoryIsReady() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("history.json")
        let gate = ModelHistoryFailureGate(operation: .persist)
        let history = ConversationHistoryController(
            store: ConversationHistoryStore(
                fileURL: fileURL,
                failureInjector: { try gate.check($0) }
            )
        )
        let suiteName = "ConversationHistoryStartupGateTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        try PendingAgentPromptStore.save("Do not consume before history", defaults: preferences)
        let model = ConversationModel(
            preferences: preferences,
            historyController: history
        )
        await waitUntil { history.errorMessage != nil }
        XCTAssertFalse(model.isHistoryReady)
        let initialMessages = model.messages

        model.restorePendingShortcutPrompt(defaults: preferences)
        await model.submit("Must not become a turn", aiConfiguration: nil)
        model.recordFeatureReply("Must not become a contact reply")
        model.analyzePronunciation("hello")

        XCTAssertEqual(model.messages, initialMessages)
        XCTAssertNil(model.pendingShortcutPrompt)
        XCTAssertNil(model.pronunciation)
        XCTAssertEqual(
            PendingAgentPromptStore.take(defaults: preferences),
            "Do not consume before history"
        )
    }

    func testHistoryStartupRetriesWithoutLosingArchiveOrDeferredPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("history.json")
        let marker = "Persisted before a protected-file retry \(UUID().uuidString)"
        let initialStore = ConversationHistoryStore(fileURL: fileURL)
        let initialState = try await initialStore.bootstrap(
            initialMessages: [.init(role: .assistant, text: marker)]
        )
        let originalBytes = try Data(contentsOf: fileURL)

        let gate = ModelHistoryFailureGate(operation: .read)
        let history = ConversationHistoryController(
            store: ConversationHistoryStore(
                fileURL: fileURL,
                failureInjector: { try gate.check($0) }
            )
        )
        let suiteName = "ConversationHistoryRetryTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let deferredPrompt = "Ask after history unlock \(UUID().uuidString)"
        try PendingAgentPromptStore.save(deferredPrompt, defaults: preferences)
        let model = ConversationModel(
            preferences: preferences,
            historyController: history
        )
        model.restorePendingShortcutPrompt(defaults: preferences)

        await waitUntil { history.errorMessage != nil }
        XCTAssertFalse(model.isHistoryReady)
        XCTAssertNil(model.pendingShortcutPrompt)
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)

        gate.operation = nil
        async let firstRetry = model.ensureHistoryReady()
        async let secondRetry = model.ensureHistoryReady()
        let firstRetrySucceeded = await firstRetry
        let secondRetrySucceeded = await secondRetry
        XCTAssertTrue(firstRetrySucceeded)
        XCTAssertTrue(secondRetrySucceeded)

        XCTAssertTrue(model.isHistoryReady)
        XCTAssertEqual(history.selectedThreadID, initialState.selectedThreadID)
        XCTAssertEqual(model.messages.map(\.text), [marker])
        XCTAssertEqual(model.pendingShortcutPrompt, deferredPrompt)
        XCTAssertNil(PendingAgentPromptStore.take(defaults: preferences))

        model.clearPendingShortcutPrompt()
        let alreadyReady = await model.ensureHistoryReady()
        XCTAssertTrue(alreadyReady)
        XCTAssertNil(model.pendingShortcutPrompt)
    }

    func testControllerSurfacesMalformedArchiveRecoveryWithoutBlockingStartup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not valid history".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = ConversationHistoryController(
            store: ConversationHistoryStore(fileURL: fileURL)
        )

        let recovered = await controller.start(
            initialMessages: [.init(role: .assistant, text: "Recovered welcome")]
        )

        XCTAssertEqual(recovered?.threads.count, 1)
        XCTAssertEqual(controller.selectedMessages.map(\.text), ["Recovered welcome"])
        XCTAssertTrue(controller.errorMessage?.contains("preserved") == true)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}

private struct InjectedModelHistoryFailure: Error, Sendable {}

private final class ModelHistoryFailureGate: @unchecked Sendable {
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
            throw InjectedModelHistoryFailure()
        }
    }
}
