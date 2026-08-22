import Foundation
import XCTest
@testable import OpenClamLiveKit

final class OpenClamKeyboardTests: XCTestCase {
    func testAppleKeyboardConstraintsRemainExplicit() {
        XCTAssertFalse(OpenClamKeyboardCapability.microphoneAvailableInExtension)
        XCTAssertTrue(OpenClamKeyboardCapability.requiresFullAccessForSharedHandoff)
        XCTAssertFalse(OpenClamKeyboardCapability.canLaunchContainingAppFromExtension)
        XCTAssertFalse(OpenClamKeyboardCapability.requiresVisibleContainingAppForVoiceInput)
        XCTAssertTrue(
            OpenClamKeyboardCapability.supportsBoundedForegroundStartedBackgroundCapture
        )
    }

    func testWarmEarReadinessRequiresEnabledLiveHeartbeatWithoutTimeExpiry() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(
            OpenClamKeyboardWarmEarState.isReady(
                enabled: true,
                heartbeat: now.addingTimeInterval(-1).timeIntervalSince1970,
                at: now
            )
        )
        XCTAssertFalse(
            OpenClamKeyboardWarmEarState.isReady(
                enabled: false,
                heartbeat: now.timeIntervalSince1970,
                at: now
            )
        )
        XCTAssertFalse(
            OpenClamKeyboardWarmEarState.isReady(
                enabled: true,
                heartbeat: now.addingTimeInterval(-4).timeIntervalSince1970,
                at: now
            )
        )
    }

    @MainActor
    func testWarmEarReadyStatePersistsUntilExplicitlyStopped() {
        XCTAssertEqual(
            OpenClamWarmEarPresentationState.ready.detail,
            "Ready for keyboard voice requests until you turn Quick Dictation off."
        )
    }

    func testHandoffURLRoundTripsOnlyOneExactRequestID() {
        let id = UUID()
        let url = OpenClamKeyboardHandoffURL.make(requestID: id)
        XCTAssertTrue(OpenClamKeyboardHandoffURL.isKeyboardHandoff(url))
        XCTAssertEqual(OpenClamKeyboardHandoffURL.requestID(from: url), id)
        XCTAssertNil(
            OpenClamKeyboardHandoffURL.requestID(
                from: URL(string: "https://example.com/keyboard-dictation?request=\(id)")!
            )
        )
        XCTAssertNil(
            OpenClamKeyboardHandoffURL.requestID(
                from: URL(
                    string: "openclam-livekit-pilot://keyboard-dictation?request=\(id)&request=\(UUID())"
                )!
            )
        )
    }

    func testInsertionPlanTrimsAndAddsOnlyNecessarySpace() {
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(
                for: "  hello world\n",
                contextBeforeInput: "Existing"
            ),
            " hello world"
        )
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(for: "hello", contextBeforeInput: "Existing "),
            "hello"
        )
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(for: ".", contextBeforeInput: "Existing"),
            "."
        )
        XCTAssertNil(
            OpenClamKeyboardInsertionPlan.text(for: " \n ", contextBeforeInput: "Existing")
        )
    }

    func testInsertionPlanPreservesMultilingualAndPunctuationBoundaries() {
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(for: "世界", contextBeforeInput: "你好"),
            "世界"
        )
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(for: "です", contextBeforeInput: "便利"),
            "です"
        )
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(for: "ไทย", contextBeforeInput: "ภาษา"),
            "ไทย"
        )
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(for: "'s ready", contextBeforeInput: "OpenClam"),
            "'s ready"
        )
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(for: "hello", contextBeforeInput: "（"),
            "hello"
        )
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(for: "مرحبا", contextBeforeInput: "OpenClam"),
            " مرحبا"
        )
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(for: "؟", contextBeforeInput: "مرحبا"),
            "؟"
        )
        XCTAssertEqual(
            OpenClamKeyboardInsertionPlan.text(for: "한국어", contextBeforeInput: "OpenClam"),
            " 한국어",
            "Korean normally uses spaces and must not inherit the CJK no-space rule."
        )
    }

    func testKeyboardUserCopyMatchesTheActualHandoffAndBoundedLease() {
        XCTAssertFalse(OpenClamKeyboardCapability.canLaunchContainingAppFromExtension)
        XCTAssertTrue(OpenClamKeyboardUserCopy.setupWorkflow.contains("Allow Full Access"))
        XCTAssertTrue(OpenClamKeyboardUserCopy.setupWorkflow.contains("speech provider"))
        XCTAssertTrue(OpenClamKeyboardUserCopy.setupWorkflow.contains("Quick Dictation"))
        XCTAssertTrue(OpenClamKeyboardUserCopy.setupWorkflow.contains("wait for Listening"))
        XCTAssertTrue(
            OpenClamKeyboardUserCopy.boundedMicrophoneDisclosure.contains("foreground-started")
        )
        XCTAssertTrue(
            OpenClamKeyboardUserCopy.boundedMicrophoneDisclosure.contains("until you turn it off")
        )
        XCTAssertTrue(
            OpenClamKeyboardUserCopy.boundedMicrophoneDisclosure.contains("standby audio is discarded")
        )
    }

    func testKeyboardKeepsOpenClamProviderVoiceAsItsPrimaryAction() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "KeyboardExtension/Extension/KeyboardViewController.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("get { true }"))
        XCTAssertFalse(source.contains("get { false }"))
    }

    func testKeyboardQueuesProviderRequestWhileWarmEarFinishesPreparing() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let keyboardSource = try String(
            contentsOf: project.appendingPathComponent(
                "KeyboardExtension/Extension/OpenClamKeyboardView.swift"
            ),
            encoding: .utf8
        )
        let hostSource = try String(
            contentsOf: project.appendingPathComponent(
                "KeyboardExtension/Host/OpenClamKeyboardDictationHost.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(
            keyboardSource.contains(
                "guard hasFullAccess,\n              OpenClamKeyboardWarmEarState.isReady()"
            )
        )
        XCTAssertTrue(keyboardSource.contains("let request = try availableStore.beginRequest()"))
        XCTAssertTrue(keyboardSource.contains("OpenClamKeyboardWarmEarSignal.postBeginRequest()"))
        XCTAssertTrue(hostSource.contains("warmEarLease.refreshReadinessIfArmed(at: date)"))
        XCTAssertTrue(hostSource.contains("markListening(requestID: request.id)"))
        XCTAssertFalse(hostSource.contains("foregroundLeaseDuration"))
        XCTAssertFalse(hostSource.contains("readyUntil()"))
        XCTAssertTrue(hostSource.contains("func finishTurnAndRearm() async -> Bool"))
    }

    func testWarmEarDoesNotReRequestAnAlreadyGrantedMicrophonePermission() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let hostSource = try String(
            contentsOf: project.appendingPathComponent(
                "KeyboardExtension/Host/OpenClamKeyboardDictationHost.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(hostSource.contains("switch AVAudioApplication.shared.recordPermission"))
        XCTAssertTrue(hostSource.contains("case .granted:"))
        XCTAssertTrue(hostSource.contains("return true"))
        XCTAssertTrue(hostSource.contains("recordPermissionRequestTimeout: Duration = .seconds(15)"))
    }

    func testSharedResultIsConsumedExactlyOnceAndDeleted() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let request = try fixture.store.beginRequest(at: start)

        XCTAssertEqual(try fixture.store.activeRequest(at: start), request)
        try fixture.store.write(
            .completed(requestID: request.id, transcript: "one private transcript", at: start),
            at: start
        )

        XCTAssertEqual(
            try fixture.store.takeActiveResult(at: start)?.transcript,
            "one private transcript"
        )
        XCTAssertNil(try fixture.store.takeActiveResult(at: start))
        XCTAssertNil(try fixture.store.activeRequest(at: start))

        let remainingNames = try FileManager.default.contentsOfDirectory(
            at: fixture.container.appendingPathComponent("OpenClamKeyboard"),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertFalse(remainingNames.contains { $0.contains(request.id.uuidString.lowercased()) })
    }

    func testSharedResultRemainsRecoverableUntilInsertionAcknowledgesIt() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let request = try fixture.store.beginRequest(at: now)
        try fixture.store.write(
            .completed(requestID: request.id, transcript: "recoverable", at: now),
            at: now
        )

        XCTAssertEqual(try fixture.store.peekActiveResult(at: now)?.transcript, "recoverable")
        XCTAssertEqual(try fixture.store.peekActiveResult(at: now)?.transcript, "recoverable")

        try fixture.store.acknowledgeActiveResult(requestID: request.id, at: now)
        XCTAssertNil(try fixture.store.activeRequest(at: now))
        XCTAssertNil(try fixture.store.result(for: request.id))
    }

    func testBeginningWhileARequestIsPendingReturnsTheSameRequest() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try fixture.store.beginRequest(at: now)
        let second = try fixture.store.beginRequest(at: now.addingTimeInterval(1))

        XCTAssertEqual(second, first)
        XCTAssertEqual(try fixture.store.activeRequest(at: now), first)
    }

    func testKeyboardCancelWritesOneTerminalResultForTheHostToObserve() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let request = try fixture.store.beginRequest(at: now)

        XCTAssertEqual(try fixture.store.cancelActiveRequest(at: now), request)
        XCTAssertEqual(try fixture.store.peekActiveResult(at: now)?.state, .cancelled)
        XCTAssertEqual(try fixture.store.cancelActiveRequest(at: now), request)
        XCTAssertEqual(try fixture.store.peekActiveResult(at: now)?.state, .cancelled)
    }

    func testDelayedCancellationKeepsItsExactIdentityUntilHostAcknowledges() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cancelled = try fixture.store.beginRequest(at: now)
        _ = try fixture.store.cancelActiveRequest(at: now)
        try fixture.store.acknowledgeActiveResult(requestID: cancelled.id, at: now)

        let next = try fixture.store.beginRequest(at: now.addingTimeInterval(1))

        XCTAssertNotEqual(next.id, cancelled.id)
        XCTAssertEqual(
            try fixture.store.pendingCancellationRequestIDs(at: now.addingTimeInterval(1)),
            [cancelled.id]
        )
        try fixture.store.acknowledgeCancellation(requestID: cancelled.id)
        XCTAssertTrue(
            try fixture.store.pendingCancellationRequestIDs(at: now.addingTimeInterval(1)).isEmpty
        )
        XCTAssertEqual(try fixture.store.activeRequest(at: now.addingTimeInterval(1)), next)
    }

    func testTerminalKeyboardResultIsFirstWriterWins() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let request = try fixture.store.beginRequest(at: now)

        XCTAssertTrue(
            try fixture.store.write(
                .cancelled(requestID: request.id, at: now),
                at: now
            )
        )
        XCTAssertFalse(
            try fixture.store.write(
                .completed(requestID: request.id, transcript: "must not overwrite", at: now),
                at: now
            )
        )
        XCTAssertEqual(try fixture.store.result(for: request.id)?.state, .cancelled)
    }

    func testTextMutationCommitsMarkedInputBeforeEditing() {
        var events: [String] = []

        OpenClamKeyboardTextMutation.commitMarkedTextThen(
            { events.append("insert") },
            unmarkText: { events.append("commit") }
        )

        XCTAssertEqual(events, ["commit", "insert"])
    }

    func testOversizedPrivateTranscriptIsRejectedBeforeDiskPersistence() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let request = try fixture.store.beginRequest(at: now)
        let oversized = String(
            repeating: "a",
            count: OpenClamKeyboardHandoffStore.maximumArtifactBytes + 1
        )

        XCTAssertThrowsError(
            try fixture.store.write(
                .completed(requestID: request.id, transcript: oversized, at: now),
                at: now
            )
        ) { error in
            XCTAssertEqual(error as? OpenClamKeyboardStoreError, .artifactTooLarge)
        }
        XCTAssertNil(try fixture.store.result(for: request.id))
    }

    func testCorruptOversizedActiveMetadataIsPrunedAndDoesNotBlockRecovery() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let keyboardDirectory = fixture.container.appendingPathComponent(
            "OpenClamKeyboard",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: keyboardDirectory,
            withIntermediateDirectories: true
        )
        try Data(
            repeating: 0x41,
            count: OpenClamKeyboardHandoffStore.maximumArtifactBytes + 1
        ).write(to: keyboardDirectory.appendingPathComponent("active.json"))

        let request = try fixture.store.beginRequest()

        XCTAssertEqual(try fixture.store.activeRequest(), request)
    }

    func testKeyboardAutomaticTurnTreatsXAILiveAsRealtimeButBatchAsFinalOnly() {
        XCTAssertTrue(
            OpenClamKeyboardAutomaticTurnPolicy.supportsSettledPartialTranscript(
                .init(
                    provider: .xAI,
                    model: AIProviderRegistry.xAILiveSpeechToTextModel
                )
            )
        )
        XCTAssertFalse(
            OpenClamKeyboardAutomaticTurnPolicy.supportsSettledPartialTranscript(
                .init(
                    provider: .xAI,
                    model: AIProviderRegistry.xAIBatchSpeechToTextModel
                )
            )
        )
    }

    func testExpiredRequestIsRejectedAndRemoved() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let request = try fixture.store.beginRequest(at: start)
        try fixture.store.write(
            .completed(requestID: request.id, transcript: "expired private transcript", at: start),
            at: start
        )

        XCTAssertThrowsError(
            try fixture.store.activeRequest(
                at: start.addingTimeInterval(OpenClamKeyboardRequest.maximumAge + 1)
            )
        ) { error in
            XCTAssertEqual(error as? OpenClamKeyboardStoreError, .staleRequest)
        }
        XCTAssertNil(try fixture.store.activeRequest(at: start))
        XCTAssertNil(try fixture.store.result(for: request.id))
    }

    @MainActor
    func testAppRouteAcceptsOnlyCurrentStoredKeyboardRequest() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let now = Date()
        let request = try fixture.store.beginRequest(at: now)
        let host = OpenClamKeyboardDictationHostController(store: fixture.store)

        XCTAssertTrue(host.handle(OpenClamKeyboardHandoffURL.make(requestID: request.id), at: now))
        XCTAssertEqual(host.activeRequest, request)
        XCTAssertFalse(host.handle(URL(string: "openclam-livekit-pilot://command?action=clipboard_read")!))

        try host.complete(request, transcript: "dictated text")
        XCTAssertEqual(try fixture.store.result(for: request.id)?.state, .completed)
    }

    @MainActor
    func testVisibleAppRestoresPendingRequestWithoutAnExtensionLaunchURL() throws {
        let fixture = try makeStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let now = Date()
        let request = try fixture.store.beginRequest(at: now)
        let host = OpenClamKeyboardDictationHostController(store: fixture.store)

        host.restorePendingRequest(at: now)

        XCTAssertEqual(host.activeRequest, request)
    }

    @MainActor
    func testIndependentAudioOwnersReleaseOnlyTheirOwnReservation() {
        let host = OpenClamKeyboardDictationHostController()

        host.setCompetingAppAudioActive(true, owner: .liveScreen)
        host.setCompetingAppAudioActive(true, owner: .speechOutput)
        host.setCompetingAppAudioActive(false, owner: .liveScreen)
        XCTAssertTrue(host.hasCompetingAppAudioActivity)

        host.setCompetingAppAudioActive(false, owner: .speechOutput)
        XCTAssertFalse(host.hasCompetingAppAudioActivity)
    }

    func testExtensionInfoRequestsSharedAccessWithoutClaimingMicrophoneCapture() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = project.appendingPathComponent("KeyboardExtension/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let extensionDictionary = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        let attributes = try XCTUnwrap(
            extensionDictionary["NSExtensionAttributes"] as? [String: Any]
        )

        XCTAssertEqual(
            extensionDictionary["NSExtensionPointIdentifier"] as? String,
            "com.apple.keyboard-service"
        )
        XCTAssertEqual(attributes["RequestsOpenAccess"] as? Bool, true)
        XCTAssertEqual(attributes["IsASCIICapable"] as? Bool, false)
        XCTAssertEqual(attributes["PrimaryLanguage"] as? String, "en-US")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "OpenClam LiveKit Keyboard")
        XCTAssertEqual(
            extensionDictionary["NSExtensionPrincipalClass"] as? String,
            "$(PRODUCT_MODULE_NAME).KeyboardViewController"
        )
        XCTAssertNil(info["NSMicrophoneUsageDescription"])
    }

    private func makeStoreFixture() throws -> (
        container: URL,
        store: OpenClamKeyboardHandoffStore
    ) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenClamKeyboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        return (container, OpenClamKeyboardHandoffStore(containerURL: container))
    }
}
