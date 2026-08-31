import AVFoundation
import CryptoKit
import Photos
import UIKit
import XCTest
@testable import OpenClamLiveKit

@MainActor
final class AgentConnectorTests: XCTestCase {
    func testOriginRequiresAnExactHTTPSOriginAndDerivesExactWSSPath() throws {
        let connectionID = try XCTUnwrap(
            UUID(uuidString: "123e4567-e89b-42d3-a456-426614174000")
        )
        let origin = try AgentConnectorOrigin("https://bridge.example.com:8443")
        XCTAssertEqual(origin.canonicalString, "https://bridge.example.com:8443")
        XCTAssertEqual(
            origin.eventsURL(connectionID: connectionID).absoluteString,
            "wss://bridge.example.com:8443/v1/connectors/123e4567-e89b-42d3-a456-426614174000/events"
        )
        XCTAssertThrowsError(try AgentConnectorOrigin("http://bridge.example.com"))
        XCTAssertThrowsError(try AgentConnectorOrigin("https://bridge.example.com/path"))
        XCTAssertThrowsError(try AgentConnectorOrigin("https://user@bridge.example.com"))
        XCTAssertThrowsError(try AgentConnectorOrigin("https://bridge.example.com?token=secret"))
    }

    func testPairingCodeNormalizesButRejectsIncompleteOrAmbiguousCode() throws {
        XCTAssertEqual(AgentConnectorPairingCode.normalized(""), "")
        XCTAssertEqual(AgentConnectorPairingCode.normalized("o"), "O")
        XCTAssertEqual(AgentConnectorPairingCode.normalized("oc"), "OC")
        XCTAssertEqual(
            AgentConnectorPairingCode.normalized("oc-abcd-efgh-jkmn"),
            "OC-ABCD-EFGH-JKMN"
        )
        XCTAssertEqual(
            try AgentConnectorPairingCode.validated("oc-abcd-efgh-jkmn"),
            "OC-ABCD-EFGH-JKMN"
        )
        XCTAssertThrowsError(try AgentConnectorPairingCode.validated("OC-ABCD"))
        XCTAssertThrowsError(
            try AgentConnectorPairingCode.validated("OC-ABCD-EFGH-IJKL")
        )
        XCTAssertTrue(
            AgentConnectorPairingRetryPolicy.shouldRetainCode(
                after: AgentConnectorError.connectionUnavailable
            )
        )
        XCTAssertFalse(
            AgentConnectorPairingRetryPolicy.shouldRetainCode(
                after: AgentConnectorError.remote(
                    code: "pairing_expired",
                    message: "Expired"
                )
            )
        )
    }

    func testPermanentWebSocketStatusesRequirePairingInsteadOfRetryingForever() {
        for statusCode in [401, 403, 404, 410] {
            XCTAssertEqual(
                AgentConnectorTransportErrorMapper.error(
                    forHTTPStatusCode: statusCode
                ),
                .pairingRequired
            )
        }
        XCTAssertNil(
            AgentConnectorTransportErrorMapper.error(forHTTPStatusCode: 500)
        )
        XCTAssertEqual(
            AgentConnectorTransportErrorMapper.statusURL(
                forEventsURL: URL(
                    string: "wss://bridge.example/v1/connectors/11111111-1111-4111-8111-111111111111/events"
                )!
            )?.absoluteString,
            "https://bridge.example/v1/connectors/11111111-1111-4111-8111-111111111111/status"
        )
        XCTAssertNil(
            AgentConnectorTransportErrorMapper.statusURL(
                forEventsURL: URL(string: "wss://bridge.example/not-the-connector")!
            )
        )
    }

    func testPairingRequiredDuringSubmitIsNotDowngradedOrRetried() async throws {
        let suite = "AgentConnectorTests.pairing-required-send.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sockets = PairingRequiredOnSendSocketConnector()
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: AgentConnectorCursorStore(
                defaults: defaults,
                storagePrefix: "cursor.\(UUID().uuidString)"
            ),
            outboxVault: InMemoryAgentConnectorOutboxVault(),
            socketConnector: sockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 2,
                baseDelayMilliseconds: 0
            )
        )
        var events: [AgentConnectorStreamEvent] = []

        do {
            for try await event in connector.streamTurn(
                .init(
                    connectionID: UUID(),
                    conversationID: UUID(),
                    turnID: UUID(),
                    accountID: "ara",
                    text: "Hello"
                ),
                clientToken: String(repeating: "t", count: 48)
            ) {
                events.append(event)
            }
            XCTFail("Expected the revoked pairing to require repair.")
        } catch let error as AgentConnectorError {
            XCTAssertEqual(error, .pairingRequired)
        }

        XCTAssertEqual(events, [.submissionSaved])
        XCTAssertEqual(sockets.connectionCount, 1)
    }

    func testLegacyProfileAndThreadMapDecodeAsOnDevice() throws {
        let profileData = try JSONSerialization.data(withJSONObject: [
            "id": "ara",
            "displayName": "Ara",
            "systemPrompt": "",
            "userPrompt": "",
        ])
        let profile = try JSONDecoder().decode(AvatarAgentProfile.self, from: profileData)
        XCTAssertNil(profile.agentConnectorBinding)
        XCTAssertEqual(profile.preferredConversationRoute, .onDevice)

        let threadID = UUID()
        let legacyMap = AvatarAgentThreadMap(
            activeThreadByAvatar: ["ara": threadID],
            avatarByThread: [threadID: "ara"]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyMap)) as? [String: Any]
        )
        object.removeValue(forKey: "routeByThread")
        let decoded = try JSONDecoder().decode(
            AvatarAgentThreadMap.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertTrue(decoded.routeByThread.isEmpty)
    }

    func testExistingThreadRetainsRemoteRouteWhenAvatarDefaultChanges() throws {
        let suite = "AgentConnectorTests.routes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: "settings.\(UUID().uuidString)",
            providerVault: InMemoryProviderCredentialVault()
        )
        let binding = makeBinding()
        var profile = configuration.profile(for: "ara")
        profile.agentConnectorBinding = binding
        try configuration.updateAvatarProfile(profile)
        let remoteThread = UUID()
        configuration.registerThread(remoteThread, for: "ara")

        profile.agentConnectorBinding = nil
        try configuration.updateAvatarProfile(profile)
        configuration.registerThread(remoteThread, for: "ara")
        XCTAssertEqual(
            configuration.conversationRoute(for: remoteThread),
            .remote(binding)
        )

        configuration.requireNewThreadForRouteChange(avatarID: "ara")
        let localThread = UUID()
        configuration.registerThread(localThread, for: "ara")
        XCTAssertEqual(configuration.conversationRoute(for: localThread), .onDevice)
        XCTAssertEqual(
            configuration.conversationRoute(for: remoteThread),
            .remote(binding)
        )
    }

    func testRemovedAvatarLeavesRouteTombstoneForItsOldChat() throws {
        let suite = "AgentConnectorTests.tombstone.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: "settings.\(UUID().uuidString)",
            providerVault: InMemoryProviderCredentialVault()
        )
        let importedID = "imported-agent"
        configuration.activateAvatar(id: importedID, displayName: "Imported")
        var profile = configuration.profile(for: importedID)
        let binding = makeBinding()
        profile.agentConnectorBinding = binding
        try configuration.updateAvatarProfile(profile)
        let oldThread = UUID()
        configuration.registerThread(oldThread, for: importedID)

        _ = configuration.removeImportedAvatarProfile(id: importedID)
        XCTAssertNil(configuration.avatarID(for: oldThread))
        XCTAssertEqual(configuration.conversationRoute(for: oldThread), .remote(binding))

        configuration.registerThread(oldThread, for: configuration.activeAvatarID)
        XCTAssertEqual(configuration.conversationRoute(for: oldThread), .remote(binding))
        let newThread = UUID()
        configuration.registerThread(newThread, for: configuration.activeAvatarID)
        XCTAssertEqual(configuration.conversationRoute(for: newThread), .onDevice)
    }

    func testRemoteV1PolicyFailsClosedForLocalModelToolsAndAttachments() {
        let route = AgentConversationRoute.remote(makeBinding())
        XCTAssertFalse(AgentConnectorV1Policy.permitsLocalLanguageModel(for: route))
        XCTAssertFalse(AgentConnectorV1Policy.permitsLocalTools(for: route))
        XCTAssertFalse(AgentConnectorV1Policy.permitsAttachments(for: route))
        XCTAssertTrue(AgentConnectorV1Policy.permitsAttachments(for: .onDevice))
    }

    func testPairingPersistsDescriptorAndDeviceOnlyVaultTokenThenStreamsCumulativeText() async throws {
        let suite = "AgentConnectorTests.connection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher"
        )
        let response = AgentConnectorPairingRedeemResponse(
            connectionID: connectionID,
            gatewayLabel: "My OpenClaw",
            accounts: [account],
            clientToken: String(repeating: "t", count: 48)
        )
        let vault = InMemoryAgentConnectorTokenVault()
        let model = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID().uuidString)",
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            pairingService: StubPairingService(response: response),
            connector: StubAgentConnector(),
            tokenVault: vault,
            outboxVault: InMemoryAgentConnectorOutboxVault()
        )
        let paired = try await model.redeemPairingCode("OC-ABCD-EFGH-JKMN")
        XCTAssertEqual(paired.connectionID, connectionID)
        XCTAssertEqual(
            try vault.loadClientToken(for: connectionID),
            String(repeating: "t", count: 48)
        )

        let stream = try model.streamTurn(
            binding: paired.binding(for: account),
            conversationID: UUID(),
            turnID: UUID(),
            text: "Hello"
        )
        var events: [AgentConnectorStreamEvent] = []
        for try await event in stream { events.append(event) }
        XCTAssertEqual(
            events,
            [
                .submissionSaved, .accepted, .cumulativeText("Hel"),
                .cumulativeText("Hello"), .completed("Hello"),
            ]
        )
    }

    func testConversationPublishesOpenClawWorkAndTextBeforeCompletion() async throws {
        let suite = "AgentConnectorTests.progressive-conversation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let history = ConversationHistoryController(
            store: .init(fileURL: directory.appendingPathComponent("history.json"))
        )
        let conversation = ConversationModel(
            preferences: defaults,
            historyController: history
        )
        let historyIsReady = await conversation.ensureHistoryReady()
        XCTAssertTrue(historyIsReady)
        let threadID = try XCTUnwrap(history.selectedThreadID)
        let connectionID = UUID()
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "main",
            displayName: "Main"
        )
        let controlledConnector = ControlledStreamingAgentConnector()
        let connections = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID().uuidString)",
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            pairingService: StubPairingService(response: .init(
                connectionID: connectionID,
                gatewayLabel: "My OpenClaw",
                accounts: [account],
                clientToken: String(repeating: "t", count: 48)
            )),
            connector: controlledConnector,
            tokenVault: InMemoryAgentConnectorTokenVault(),
            outboxVault: InMemoryAgentConnectorOutboxVault()
        )
        let paired = try await connections.redeemPairingCode("OC-ABCD-EFGH-JKMN")
        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: "settings.\(UUID().uuidString)",
            providerVault: InMemoryProviderCredentialVault()
        )
        configuration.registerThread(
            threadID,
            for: configuration.activeAvatarID,
            route: .remote(paired.binding(for: account))
        )

        let submission = Task { @MainActor in
            await conversation.submit(
                "Build the report",
                aiConfiguration: configuration,
                agentConnections: connections
            )
        }
        for _ in 0 ..< 100 where !controlledConnector.hasSubscriber {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(controlledConnector.hasSubscriber)

        let runningStep = AgentConnectorWorkStep(
            revision: 1,
            stepID: "tool:report",
            category: .tool,
            state: .running,
            title: "Building report",
            detail: "Drafting the first section",
            tool: "report",
            command: nil,
            path: nil,
            output: nil
        )
        controlledConnector.yield(.accepted)
        controlledConnector.yield(.work(runningStep))
        controlledConnector.yield(.cumulativeText("First streamed paragraph"))

        for _ in 0 ..< 100
        where conversation.streamingAssistantReply != "First streamed paragraph" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(conversation.isWorking)
        XCTAssertEqual(conversation.streamingAssistantReply, "First streamed paragraph")
        XCTAssertEqual(conversation.remoteAgentWorkSteps, [runningStep])
        XCTAssertFalse(
            conversation.messages.contains {
                $0.role == .assistant && $0.text == "Final response"
            },
            "A bridge delta must be visible before the durable completion arrives."
        )

        let metadata = makeAttachmentMetadata(
            connectionID: connectionID,
            turnID: UUID(),
            expiresAt: 60_000
        )
        controlledConnector.yield(.attachmentTransfer(metadata))
        for _ in 0 ..< 100 where conversation.remoteAgentActivity?.phase != .downloading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(conversation.isWorking, "A file transfer is not a completed turn.")
        XCTAssertEqual(conversation.remoteAgentActivity?.title, "Receiving file…")
        XCTAssertEqual(conversation.remoteAgentActivity?.detail, metadata.fileName)
        XCTAssertEqual(conversation.remoteAgentActivity?.allowsCancel, true)
        XCTAssertEqual(conversation.streamingAssistantReply, "First streamed paragraph")

        controlledConnector.yield(.completed("Final response"))
        controlledConnector.finish()
        await submission.value

        XCTAssertFalse(conversation.isWorking)
        XCTAssertNil(conversation.streamingAssistantReply)
        XCTAssertTrue(conversation.remoteAgentWorkSteps.isEmpty)
        XCTAssertEqual(
            conversation.messages.last(where: { $0.role == .assistant })?.text,
            "Final response"
        )
        XCTAssertEqual(
            conversation.messages.last(where: { $0.role == .assistant })?.workSteps,
            [runningStep]
        )
    }

    func testPairedLiveTalkAgentTurnTraversesConnectorAndKeepsOneVisibleResult() async throws {
        let suite = "AgentConnectorTests.live-talk.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let history = ConversationHistoryController(
            store: .init(fileURL: directory.appendingPathComponent("history.json"))
        )
        let conversation = ConversationModel(
            preferences: defaults,
            historyController: history
        )
        let historyIsReady = await conversation.ensureHistoryReady()
        XCTAssertTrue(historyIsReady)
        let connectionID = UUID()
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher"
        )
        let connections = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID().uuidString)",
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            pairingService: StubPairingService(response: .init(
                connectionID: connectionID,
                gatewayLabel: "My OpenClaw",
                accounts: [account],
                clientToken: String(repeating: "t", count: 48)
            )),
            connector: LiveTalkAgentStubConnector(),
            tokenVault: InMemoryAgentConnectorTokenVault(),
            outboxVault: InMemoryAgentConnectorOutboxVault()
        )
        let paired = try await connections.redeemPairingCode("OC-ABCD-EFGH-JKMN")
        XCTAssertTrue(conversation.beginLiveTalkTranscriptSession())
        conversation.ingestLiveTalkTranscripts([
            .init(
                id: "live-user-segment-1",
                role: .user,
                text: "Search for",
                isFinal: true
            ),
            .init(
                id: "live-user-segment-2",
                role: .user,
                text: "McDonald's nearby",
                isFinal: true
            ),
        ])

        let result = await conversation.submitLiveTalkAgentTurn(
            "Search for McDonald's nearby",
            binding: paired.binding(for: account),
            agentConnections: connections
        )

        XCTAssertEqual(result, .completed("The nearest result is on Main Street."))
        XCTAssertEqual(
            conversation.messages.filter {
                $0.role == .user
                    && ($0.text == "Search for" || $0.text == "McDonald's nearby")
            }.count,
            2
        )
        let assistantResults = conversation.messages.filter {
            $0.role == .assistant && $0.text.contains("nearest result")
        }
        XCTAssertEqual(assistantResults.count, 1)
        XCTAssertEqual(
            assistantResults.first?.text,
            "[laughing] The [nearest result](https://example.com) is on Main Street."
        )
        XCTAssertEqual(assistantResults.first?.workSteps.first?.category, .approval)
        XCTAssertEqual(assistantResults.first?.workSteps.first?.state, .waiting)

        // The voice agent echoes this exact terminal result through LiveKit for
        // TTS. Even if a new user utterance arrives first, that late exact echo
        // drives the avatar/transcript but must not add a second bubble.
        conversation.ingestLiveTalkTranscripts([
            .init(
                id: "live-user-segment-1",
                role: .user,
                text: "Search for",
                isFinal: true
            ),
            .init(
                id: "live-user-segment-2",
                role: .user,
                text: "McDonald's nearby",
                isFinal: true
            ),
            .init(
                id: "next-live-user-turn",
                role: .user,
                text: "Thanks",
                isFinal: true
            ),
        ])
        conversation.ingestLiveTalkTranscripts([
            .init(
                id: "live-user-segment-1",
                role: .user,
                text: "Search for",
                isFinal: true
            ),
            .init(
                id: "live-user-segment-2",
                role: .user,
                text: "McDonald's nearby",
                isFinal: true
            ),
            .init(
                id: "next-live-user-turn",
                role: .user,
                text: "Thanks",
                isFinal: true
            ),
            .init(
                id: "delegated-agent-echo",
                role: .agent,
                text: "The nearest result is on Main Street.",
                isFinal: true
            ),
        ])
        XCTAssertEqual(
            conversation.messages.filter {
                $0.role == .assistant && $0.text.contains("nearest result")
            }.count,
            1
        )
    }

    func testLiveTalkAgentTurnBargeInPersistsCancellationAndKeepsTranscript() async throws {
        let suite = "AgentConnectorTests.live-talk-cancel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let history = ConversationHistoryController(
            store: .init(fileURL: directory.appendingPathComponent("history.json"))
        )
        let conversation = ConversationModel(
            preferences: defaults,
            historyController: history
        )
        let historyIsReady = await conversation.ensureHistoryReady()
        XCTAssertTrue(historyIsReady)
        let connectionID = UUID()
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher"
        )
        let outbox = InMemoryAgentConnectorOutboxVault()
        let sockets = ScriptedSocketConnector(scripts: [
            [.waitForCancellation],
            [.persistenceReceiptForLastCancel, .workerCancelledTerminalForLastCancel(seq: 1)],
        ])
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: AgentConnectorCursorStore(
                defaults: defaults,
                storagePrefix: "cursor.\(UUID().uuidString)"
            ),
            outboxVault: outbox,
            socketConnector: sockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 0,
                baseDelayMilliseconds: 0
            )
        )
        let connections = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID().uuidString)",
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            pairingService: StubPairingService(response: .init(
                connectionID: connectionID,
                gatewayLabel: "My OpenClaw",
                accounts: [account],
                clientToken: String(repeating: "t", count: 48)
            )),
            connector: connector,
            tokenVault: InMemoryAgentConnectorTokenVault(),
            outboxVault: outbox
        )
        let paired = try await connections.redeemPairingCode("OC-ABCD-EFGH-JKMN")
        XCTAssertTrue(conversation.beginLiveTalkTranscriptSession())
        conversation.ingestLiveTalkTranscripts([
            .init(
                id: "cancelled-live-user",
                role: .user,
                text: "Search for a nearby pharmacy",
                isFinal: true
            ),
        ])

        let submission = Task { @MainActor in
            await conversation.submitLiveTalkAgentTurn(
                "Search for a nearby pharmacy",
                binding: paired.binding(for: account),
                agentConnections: connections
            )
        }
        for _ in 0 ..< 100
            where sockets.sentFrames.contains(where: { $0.kind == "turn.submit" }) == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sockets.sentFrames.contains(where: { $0.kind == "turn.submit" }))
        submission.cancel()
        let disposition = await submission.value
        XCTAssertEqual(disposition, .failed)

        XCTAssertTrue(
            conversation.messages.contains {
                $0.role == .user && $0.text == "Search for a nearby pharmacy"
            }
        )
        XCTAssertTrue(try outbox.loadAll().isEmpty)
        XCTAssertEqual(
            sockets.sentFrames.filter { $0.kind == "turn.cancel" }.count,
            1
        )
    }

    func testLiveTalkPreSaveCancellationKeepsAuthoritativeTranscript() async throws {
        let suite = "AgentConnectorTests.live-talk-pre-save-cancel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let history = ConversationHistoryController(
            store: .init(fileURL: directory.appendingPathComponent("history.json"))
        )
        let conversation = ConversationModel(
            preferences: defaults,
            historyController: history
        )
        let historyIsReady = await conversation.ensureHistoryReady()
        XCTAssertTrue(historyIsReady)
        let connectionID = UUID()
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher"
        )
        let connections = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID().uuidString)",
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            pairingService: StubPairingService(response: .init(
                connectionID: connectionID,
                gatewayLabel: "My OpenClaw",
                accounts: [account],
                clientToken: String(repeating: "t", count: 48)
            )),
            connector: HangingStubAgentConnector(),
            tokenVault: InMemoryAgentConnectorTokenVault(),
            outboxVault: InMemoryAgentConnectorOutboxVault()
        )
        let paired = try await connections.redeemPairingCode("OC-ABCD-EFGH-JKMN")
        XCTAssertTrue(conversation.beginLiveTalkTranscriptSession())
        conversation.ingestLiveTalkTranscripts([
            .init(
                id: "pre-save-live-user",
                role: .user,
                text: "Email Emma about lunch",
                isFinal: true
            ),
        ])

        let submission = Task { @MainActor in
            await conversation.submitLiveTalkAgentTurn(
                "Email Emma about lunch",
                binding: paired.binding(for: account),
                agentConnections: connections
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        submission.cancel()
        let disposition = await submission.value
        XCTAssertEqual(disposition, .failed)
        XCTAssertTrue(
            conversation.messages.contains {
                $0.role == .user && $0.text == "Email Emma about lunch"
            }
        )
    }

    func testDisconnectRevokesRemotelyBeforeDeletingLocalCredential() async throws {
        let suite = "AgentConnectorTests.revoke.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher"
        )
        let token = String(repeating: "t", count: 48)
        let vault = InMemoryAgentConnectorTokenVault()
        let revocation = StubRevocationService(shouldFail: true)
        let model = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID().uuidString)",
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            pairingService: StubPairingService(response: .init(
                connectionID: connectionID,
                gatewayLabel: "My OpenClaw",
                accounts: [account],
                clientToken: token
            )),
            revocationService: revocation,
            connector: StubAgentConnector(),
            tokenVault: vault,
            outboxVault: InMemoryAgentConnectorOutboxVault()
        )
        _ = try await model.redeemPairingCode("OC-ABCD-EFGH-JKMN")

        do {
            try await model.disconnect(connectionID)
            XCTFail("A failed remote revocation must not forget the local connection")
        } catch {
            XCTAssertEqual(error as? AgentConnectorError, .revocationUnavailable)
        }
        XCTAssertNotNil(model.connections.first { $0.connectionID == connectionID })
        XCTAssertEqual(try vault.loadClientToken(for: connectionID), token)

        revocation.setShouldFail(false)
        try await model.disconnect(connectionID)
        XCTAssertNil(model.connections.first { $0.connectionID == connectionID })
        XCTAssertNil(try vault.loadClientToken(for: connectionID))
        XCTAssertEqual(revocation.lastToken, token)
    }

    func testExplicitPairingRemovalDiscardsOnlyItsSavedTurnAndArtifacts() async throws {
        let suite = "AgentConnectorTests.remove-pairing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let turnID = UUID()
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher"
        )
        let token = String(repeating: "t", count: 48)
        let outbox = InMemoryAgentConnectorOutboxVault()
        let artifacts = RecordingArtifactService()
        var pending = try makePendingTurn(
            connectionID: connectionID,
            conversationID: UUID(),
            turnID: turnID,
            createdAt: 1_000
        )
        let metadata = makeAttachmentMetadata(
            connectionID: connectionID,
            turnID: turnID,
            expiresAt: 2_000_000
        )
        pending.attachments = [try artifacts.storedAttachment(for: metadata)]
        try outbox.save(pending)
        let vault = InMemoryAgentConnectorTokenVault()
        let model = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID().uuidString)",
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            pairingService: StubPairingService(response: .init(
                connectionID: connectionID,
                gatewayLabel: "My OpenClaw",
                accounts: [account],
                clientToken: token
            )),
            revocationService: StubRevocationService(shouldFail: false),
            connector: StubAgentConnector(),
            artifactService: artifacts,
            tokenVault: vault,
            outboxVault: outbox
        )
        _ = try await model.redeemPairingCode("OC-ABCD-EFGH-JKMN")

        do {
            try await model.disconnect(connectionID)
            XCTFail("Normal disconnect must protect a saved turn")
        } catch {
            XCTAssertEqual(error as? AgentConnectorError, .recoveryPending)
        }

        try await model.disconnect(connectionID, discardPendingTurns: true)
        XCTAssertTrue(try outbox.loadAll().isEmpty)
        XCTAssertEqual(artifacts.deletedReferences, [metadata.conversationReference])
        XCTAssertNil(try vault.loadClientToken(for: connectionID))
        XCTAssertTrue(model.connections.isEmpty)
    }

    func testRevokedPairingBecomesRepairableTerminalOutcomeWithoutRetryTrap() async throws {
        let suite = "AgentConnectorTests.pairing-required.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let history = ConversationHistoryController(
            store: .init(fileURL: directory.appendingPathComponent("history.json"))
        )
        let conversation = ConversationModel(
            preferences: defaults,
            historyController: history
        )
        let historyIsReady = await conversation.ensureHistoryReady()
        XCTAssertTrue(historyIsReady)
        let threadID = try XCTUnwrap(history.selectedThreadID)
        let connectionID = UUID()
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "researcher",
            displayName: "Ara"
        )
        let connections = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID().uuidString)",
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            pairingService: StubPairingService(response: .init(
                connectionID: connectionID,
                gatewayLabel: "Home Mac",
                accounts: [account],
                clientToken: String(repeating: "t", count: 48)
            )),
            connector: PairingRequiredStubAgentConnector(),
            tokenVault: InMemoryAgentConnectorTokenVault(),
            outboxVault: InMemoryAgentConnectorOutboxVault()
        )
        let paired = try await connections.redeemPairingCode("OC-ABCD-EFGH-JKMN")
        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: "settings.\(UUID().uuidString)",
            providerVault: InMemoryProviderCredentialVault()
        )
        configuration.registerThread(
            threadID,
            for: configuration.activeAvatarID,
            route: .remote(paired.binding(for: account))
        )

        await conversation.submit(
            "Hello",
            aiConfiguration: configuration,
            agentConnections: connections
        )

        XCTAssertTrue(conversation.messages.contains {
            $0.role == .assistant && $0.text.contains("pairing was replaced")
        })
        XCTAssertEqual(conversation.remoteAgentActivity?.title, "Pair OpenClaw again")
        XCTAssertEqual(conversation.remoteAgentActivity?.allowsRepair, true)
        XCTAssertEqual(conversation.remoteAgentActivity?.allowsRetry, false)
    }

    func testOneConnectionCannotRunTwoConversationTurnsConcurrently() async throws {
        let suite = "AgentConnectorTests.connection-busy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher"
        )
        let model = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID().uuidString)",
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            pairingService: StubPairingService(response: .init(
                connectionID: connectionID,
                gatewayLabel: "My OpenClaw",
                accounts: [account],
                clientToken: String(repeating: "t", count: 48)
            )),
            connector: HangingStubAgentConnector(),
            tokenVault: InMemoryAgentConnectorTokenVault(),
            outboxVault: InMemoryAgentConnectorOutboxVault()
        )
        let paired = try await model.redeemPairingCode("OC-ABCD-EFGH-JKMN")
        let first = try model.streamTurn(
            binding: paired.binding(for: account),
            conversationID: UUID(),
            turnID: UUID(),
            text: "First"
        )
        XCTAssertThrowsError(
            try model.streamTurn(
                binding: paired.binding(for: account),
                conversationID: UUID(),
                turnID: UUID(),
                text: "Second"
            )
        ) { error in
            XCTAssertEqual(error as? AgentConnectorError, .conversationBusy)
        }
        _ = first
    }

    func testReconnectReplayAcknowledgesConsumedOldTerminalBeforeTurnIdentityCheck() throws {
        let suite = "AgentConnectorTests.replay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let cursorStore = AgentConnectorCursorStore(
            defaults: defaults,
            storagePrefix: "cursor.\(UUID().uuidString)"
        )
        cursorStore.acknowledgeInbound(10, connectionID: connectionID)
        var validator = AgentConnectorInboundValidator(
            connectionID: connectionID,
            conversationID: UUID(),
            turnID: UUID(),
            cursorStore: cursorStore
        )
        let oldConversationID = UUID()
        let oldTurnID = UUID()
        let consumed = makeCompletedFrame(
            seq: 10,
            connectionID: connectionID,
            conversationID: oldConversationID,
            turnID: oldTurnID
        )
        XCTAssertEqual(try validator.validate(consumed), .alreadyAcknowledged)

        let unconsumed = makeCompletedFrame(
            seq: 11,
            connectionID: connectionID,
            conversationID: oldConversationID,
            turnID: oldTurnID
        )
        XCTAssertEqual(try validator.validate(unconsumed), .unrelated)
    }

    func testSocketDisconnectReconnectsSameTurnReplaysThenCompletesOnce() async throws {
        let suite = "AgentConnectorTests.socket-reconnect.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let replayMessageID = UUID()
        let accepted = try encodedFrame(
            kind: "turn.accepted",
            seq: 1,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(turnID: turnID.uuidString.lowercased())
        )
        let delta = try encodedFrame(
            kind: "assistant.delta",
            seq: 2,
            connectionID: connectionID,
            conversationID: conversationID,
            messageID: replayMessageID,
            payload: .init(
                turnID: turnID.uuidString.lowercased(),
                revision: 1,
                text: "Hel"
            )
        )
        let completed = try encodedFrame(
            kind: "assistant.completed",
            seq: 3,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(
                turnID: turnID.uuidString.lowercased(),
                text: "Hello"
            )
        )
        let sockets = ScriptedSocketConnector(scripts: [
            [.text(accepted), .text(delta), .disconnect],
            [.text(delta), .text(completed)],
        ])
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: AgentConnectorCursorStore(
                defaults: defaults,
                storagePrefix: "cursor.\(UUID().uuidString)"
            ),
            outboxVault: InMemoryAgentConnectorOutboxVault(),
            socketConnector: sockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 2,
                baseDelayMilliseconds: 0
            )
        )
        let stream = connector.streamTurn(
            .init(
                connectionID: connectionID,
                conversationID: conversationID,
                turnID: turnID,
                accountID: "primary",
                text: "Hello"
            ),
            clientToken: String(repeating: "t", count: 48)
        )
        var events: [AgentConnectorStreamEvent] = []
        for try await event in stream { events.append(event) }

        XCTAssertEqual(
            events,
            [.submissionSaved, .accepted, .cumulativeText("Hel"), .completed("Hello")]
        )
        XCTAssertEqual(sockets.connectionCount, 2)
        let sent = sockets.sentFrames
        XCTAssertEqual(sent.filter { $0.kind == "turn.submit" }.count, 1)
        XCTAssertEqual(
            sent.filter { $0.kind == "ack" }.compactMap(\.payload.ackSeq),
            [1, 2, 2, 3]
        )
        XCTAssertTrue(sockets.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization")
                == "Bearer \(String(repeating: "t", count: 48))"
                && $0.url?.query == nil
        })
    }

    func testDisconnectBeforePersistenceReceiptReplaysExactSubmitThenCompletes() async throws {
        let suite = "AgentConnectorTests.submit-loss.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let accepted = try encodedFrame(
            kind: "turn.accepted",
            seq: 1,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(turnID: turnID.uuidString.lowercased())
        )
        let completed = try encodedFrame(
            kind: "assistant.completed",
            seq: 2,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(
                turnID: turnID.uuidString.lowercased(),
                text: "Stored once"
            )
        )
        let sockets = ScriptedSocketConnector(scripts: [
            [.disconnect],
            [.persistenceReceiptForLastSubmit, .text(accepted), .text(completed)],
        ])
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: AgentConnectorCursorStore(
                defaults: defaults,
                storagePrefix: "cursor.\(UUID().uuidString)"
            ),
            outboxVault: InMemoryAgentConnectorOutboxVault(),
            socketConnector: sockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 2,
                baseDelayMilliseconds: 0
            )
        )

        var events: [AgentConnectorStreamEvent] = []
        for try await event in connector.streamTurn(
            .init(
                connectionID: connectionID,
                conversationID: conversationID,
                turnID: turnID,
                accountID: "primary",
                text: "Store this exactly once"
            ),
            clientToken: String(repeating: "t", count: 48)
        ) {
            events.append(event)
        }

        XCTAssertEqual(events, [.submissionSaved, .accepted, .completed("Stored once")])
        XCTAssertEqual(sockets.connectionCount, 2)
        let submitTexts = sockets.sentTexts.filter { text in
            guard let data = text.data(using: .utf8),
                  let frame = try? JSONDecoder().decode(
                    AgentConnectorWireFrame.self,
                    from: data
                  ) else { return false }
            return frame.kind == "turn.submit"
        }
        XCTAssertEqual(submitTexts.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(submitTexts.first),
            try XCTUnwrap(submitTexts.last)
        )
        let submits = sockets.sentFrames.filter { $0.kind == "turn.submit" }
        let firstSubmit = try XCTUnwrap(submits.first)
        XCTAssertEqual(submits.map(\.seq), [firstSubmit.seq, firstSubmit.seq])
        XCTAssertEqual(
            submits.map(\.messageID),
            [firstSubmit.messageID, firstSubmit.messageID]
        )
        XCTAssertEqual(submits.map(\.payload.turnID), [
            turnID.uuidString.lowercased(),
            turnID.uuidString.lowercased(),
        ])
    }

    func testPersistenceReceiptBeforeDisconnectSuppressesSubmitReplay() async throws {
        let suite = "AgentConnectorTests.persisted-submit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let accepted = try encodedFrame(
            kind: "turn.accepted",
            seq: 1,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(turnID: turnID.uuidString.lowercased())
        )
        let completed = try encodedFrame(
            kind: "assistant.completed",
            seq: 2,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(
                turnID: turnID.uuidString.lowercased(),
                text: "Completed"
            )
        )
        let sockets = ScriptedSocketConnector(scripts: [
            [.persistenceReceiptForLastSubmit, .disconnect],
            [.text(accepted), .text(completed)],
        ])
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: AgentConnectorCursorStore(
                defaults: defaults,
                storagePrefix: "cursor.\(UUID().uuidString)"
            ),
            outboxVault: InMemoryAgentConnectorOutboxVault(),
            socketConnector: sockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 2,
                baseDelayMilliseconds: 0
            )
        )

        var events: [AgentConnectorStreamEvent] = []
        for try await event in connector.streamTurn(
            .init(
                connectionID: connectionID,
                conversationID: conversationID,
                turnID: turnID,
                accountID: "primary",
                text: "Do not dispatch twice"
            ),
            clientToken: String(repeating: "t", count: 48)
        ) {
            events.append(event)
        }

        XCTAssertEqual(events, [.submissionSaved, .accepted, .completed("Completed")])
        XCTAssertEqual(sockets.connectionCount, 2)
        XCTAssertEqual(
            sockets.sentFrames.filter { $0.kind == "turn.submit" }.count,
            1
        )
    }

    func testMalformedPersistenceReceiptFailsClosedWithoutAcknowledgement() async throws {
        let suite = "AgentConnectorTests.bad-receipt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let malformedObject: [String: Any] = [
            "v": 1,
            "kind": "relay.persisted",
            "connectionId": connectionID.uuidString.lowercased(),
            "payload": [
                "senderSeq": 1,
                "messageId": UUID().uuidString.lowercased(),
                "unexpected": true,
            ],
        ]
        let malformedData = try JSONSerialization.data(withJSONObject: malformedObject)
        let malformedText = try XCTUnwrap(
            String(data: malformedData, encoding: .utf8)
        )
        let sockets = ScriptedSocketConnector(scripts: [[.text(malformedText)]])
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: AgentConnectorCursorStore(
                defaults: defaults,
                storagePrefix: "cursor.\(UUID().uuidString)"
            ),
            outboxVault: InMemoryAgentConnectorOutboxVault(),
            socketConnector: sockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 0,
                baseDelayMilliseconds: 0
            )
        )

        do {
            for try await _ in connector.streamTurn(
                .init(
                    connectionID: connectionID,
                    conversationID: UUID(),
                    turnID: UUID(),
                    accountID: "primary",
                    text: "Hello"
                ),
                clientToken: String(repeating: "t", count: 48)
            ) {}
            XCTFail("A malformed persistence receipt must fail closed")
        } catch {
            XCTAssertEqual(error as? AgentConnectorError, .invalidFrame)
        }
        XCTAssertTrue(sockets.sentFrames.filter { $0.kind == "ack" }.isEmpty)
    }

    func testAbandonedOldTurnReplayIsAcknowledgedAndDiscardedBeforeNewTurn() async throws {
        let suite = "AgentConnectorTests.old-turn-replay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let oldConversationID = UUID()
        let oldTurnID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let script = try [
            encodedFrame(
                kind: "turn.accepted",
                seq: 1,
                connectionID: connectionID,
                conversationID: oldConversationID,
                payload: .init(turnID: oldTurnID.uuidString.lowercased())
            ),
            encodedFrame(
                kind: "assistant.delta",
                seq: 2,
                connectionID: connectionID,
                conversationID: oldConversationID,
                payload: .init(
                    turnID: oldTurnID.uuidString.lowercased(),
                    revision: 1,
                    text: "Retired partial"
                )
            ),
            encodedFrame(
                kind: "assistant.completed",
                seq: 3,
                connectionID: connectionID,
                conversationID: oldConversationID,
                payload: .init(
                    turnID: oldTurnID.uuidString.lowercased(),
                    text: "Retired final"
                )
            ),
            encodedFrame(
                kind: "turn.accepted",
                seq: 4,
                connectionID: connectionID,
                conversationID: conversationID,
                payload: .init(turnID: turnID.uuidString.lowercased())
            ),
            encodedFrame(
                kind: "assistant.delta",
                seq: 5,
                connectionID: connectionID,
                conversationID: conversationID,
                payload: .init(
                    turnID: turnID.uuidString.lowercased(),
                    revision: 1,
                    text: "Current partial"
                )
            ),
            encodedFrame(
                kind: "assistant.completed",
                seq: 6,
                connectionID: connectionID,
                conversationID: conversationID,
                payload: .init(
                    turnID: turnID.uuidString.lowercased(),
                    text: "Current final"
                )
            ),
        ]
        let sockets = ScriptedSocketConnector(
            scripts: [script.map(ScriptedSocketStep.text)]
        )
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: AgentConnectorCursorStore(
                defaults: defaults,
                storagePrefix: "cursor.\(UUID().uuidString)"
            ),
            outboxVault: InMemoryAgentConnectorOutboxVault(),
            socketConnector: sockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 2,
                baseDelayMilliseconds: 0
            )
        )
        var events: [AgentConnectorStreamEvent] = []
        for try await event in connector.streamTurn(
            .init(
                connectionID: connectionID,
                conversationID: conversationID,
                turnID: turnID,
                accountID: "primary",
                text: "Current question"
            ),
            clientToken: String(repeating: "t", count: 48)
        ) {
            events.append(event)
        }

        XCTAssertEqual(
            events,
            [
                .submissionSaved,
                .accepted,
                .cumulativeText("Current partial"),
                .completed("Current final"),
            ]
        )
        XCTAssertEqual(
            sockets.sentFrames.filter { $0.kind == "ack" }.compactMap(\.payload.ackSeq),
            [1, 2, 3, 4, 5, 6]
        )
        XCTAssertEqual(
            sockets.sentFrames.filter { $0.kind == "turn.submit" }.count,
            1
        )
    }

    func testMalformedOrWrongConnectionReplayIsRejectedBeforeAcknowledgement() async throws {
        let suite = "AgentConnectorTests.bad-replay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let malformed = try encodedFrame(
            kind: "assistant.delta",
            seq: 1,
            connectionID: connectionID,
            conversationID: UUID(),
            payload: .init(
                turnID: UUID().uuidString.lowercased(),
                revision: 0,
                text: "Malformed"
            )
        )
        let sockets = ScriptedSocketConnector(scripts: [[.text(malformed)]])
        let cursorStore = AgentConnectorCursorStore(
            defaults: defaults,
            storagePrefix: "cursor.\(UUID().uuidString)"
        )
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: cursorStore,
            outboxVault: InMemoryAgentConnectorOutboxVault(),
            socketConnector: sockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 0,
                baseDelayMilliseconds: 0
            )
        )
        do {
            for try await _ in connector.streamTurn(
                .init(
                    connectionID: connectionID,
                    conversationID: conversationID,
                    turnID: turnID,
                    accountID: "primary",
                    text: "Current question"
                ),
                clientToken: String(repeating: "t", count: 48)
            ) {}
            XCTFail("A malformed retired-turn frame must fail closed")
        } catch {
            XCTAssertEqual(error as? AgentConnectorError, .invalidFrame)
        }
        XCTAssertTrue(sockets.sentFrames.filter { $0.kind == "ack" }.isEmpty)
        XCTAssertEqual(cursorStore.lastAcknowledgedInbound(connectionID: connectionID), 0)

        var validator = AgentConnectorInboundValidator(
            connectionID: connectionID,
            conversationID: conversationID,
            turnID: turnID,
            cursorStore: cursorStore
        )
        let wrongConnection = AgentConnectorWireFrame(
            v: 1,
            kind: "turn.accepted",
            connectionID: UUID().uuidString.lowercased(),
            conversationID: UUID().uuidString.lowercased(),
            messageID: UUID().uuidString.lowercased(),
            seq: 2,
            replyTo: nil,
            sentAt: 1,
            payload: .init(turnID: UUID().uuidString.lowercased())
        )
        XCTAssertThrowsError(try validator.validate(wrongConnection)) { error in
            XCTAssertEqual(error as? AgentConnectorError, .invalidFrame)
        }
        XCTAssertEqual(cursorStore.lastAcknowledgedInbound(connectionID: connectionID), 0)
    }

    func testSocketReconnectExhaustionReplaysExactSubmitWithinBound() async throws {
        let suite = "AgentConnectorTests.socket-exhausted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sockets = ScriptedSocketConnector(scripts: [
            [.disconnect],
            [.disconnect],
            [.disconnect],
        ])
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: AgentConnectorCursorStore(
                defaults: defaults,
                storagePrefix: "cursor.\(UUID().uuidString)"
            ),
            outboxVault: InMemoryAgentConnectorOutboxVault(),
            socketConnector: sockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 2,
                baseDelayMilliseconds: 0
            )
        )
        let stream = connector.streamTurn(
            .init(
                connectionID: UUID(),
                conversationID: UUID(),
                turnID: UUID(),
                accountID: "primary",
                text: "Hello"
            ),
            clientToken: String(repeating: "t", count: 48)
        )
        do {
            for try await _ in stream {}
            XCTFail("A turn must fail closed after the bounded reconnect budget")
        } catch {
            XCTAssertEqual(error as? AgentConnectorError, .connectionUnavailable)
        }
        XCTAssertEqual(sockets.connectionCount, 3)
        let submitTexts = sockets.sentTexts.filter { text in
            guard let data = text.data(using: .utf8),
                  let frame = try? JSONDecoder().decode(
                    AgentConnectorWireFrame.self,
                    from: data
                  ) else { return false }
            return frame.kind == "turn.submit"
        }
        XCTAssertEqual(submitTexts.count, 3)
        XCTAssertEqual(Set(submitTexts).count, 1)
    }

    func testRetiredLowerSequenceReceiptIsDiscardedBeforeCurrentReceipt() async throws {
        let suite = "AgentConnectorTests.stale-receipt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let cursorStore = AgentConnectorCursorStore(
            defaults: defaults,
            storagePrefix: "cursor.\(UUID().uuidString)"
        )
        XCTAssertEqual(cursorStore.nextOutbound(connectionID: connectionID), 1)
        let retiredReceipt = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: [
                "v": 1,
                "kind": "relay.persisted",
                "connectionId": connectionID.uuidString.lowercased(),
                "payload": [
                    "senderSeq": 1,
                    "messageId": UUID().uuidString.lowercased(),
                ],
            ]),
            encoding: .utf8
        ))
        let accepted = try encodedFrame(
            kind: "turn.accepted",
            seq: 1,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(turnID: turnID.uuidString.lowercased())
        )
        let completed = try encodedFrame(
            kind: "assistant.completed",
            seq: 2,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(
                turnID: turnID.uuidString.lowercased(),
                text: "Recovered"
            )
        )
        let sockets = ScriptedSocketConnector(scripts: [[
            .text(retiredReceipt),
            .persistenceReceiptForLastSubmit,
            .text(accepted),
            .text(completed),
        ]])
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: cursorStore,
            outboxVault: InMemoryAgentConnectorOutboxVault(),
            socketConnector: sockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 0,
                baseDelayMilliseconds: 0
            )
        )

        var events: [AgentConnectorStreamEvent] = []
        for try await event in connector.streamTurn(
            .init(
                connectionID: connectionID,
                conversationID: conversationID,
                turnID: turnID,
                accountID: "primary",
                text: "Resume safely"
            ),
            clientToken: String(repeating: "t", count: 48)
        ) {
            events.append(event)
        }

        XCTAssertEqual(events, [.submissionSaved, .accepted, .completed("Recovered")])
        XCTAssertEqual(
            sockets.sentFrames.filter { $0.kind == "turn.submit" }.map(\.seq),
            [2]
        )
    }

    func testProcessRestartReplaysExactSavedSubmitAndReconcilesTerminal() async throws {
        let suite = "AgentConnectorTests.process-restart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let request = AgentConnectorTurnRequest(
            connectionID: connectionID,
            conversationID: conversationID,
            turnID: turnID,
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher",
            userMessageID: UUID(),
            assistantMessageID: UUID(),
            text: "Run once"
        )
        let cursorStore = AgentConnectorCursorStore(
            defaults: defaults,
            storagePrefix: "cursor.\(UUID().uuidString)"
        )
        let outbox = InMemoryAgentConnectorOutboxVault()
        let firstSockets = ScriptedSocketConnector(scripts: [
            [.disconnect], [.disconnect], [.disconnect],
        ])
        let firstConnector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: cursorStore,
            outboxVault: outbox,
            socketConnector: firstSockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 2,
                baseDelayMilliseconds: 0
            )
        )
        do {
            for try await _ in firstConnector.streamTurn(
                request,
                clientToken: String(repeating: "t", count: 48)
            ) {}
            XCTFail("The first process must leave the exact turn pending")
        } catch {
            XCTAssertEqual(error as? AgentConnectorError, .connectionUnavailable)
        }
        let saved = try XCTUnwrap(
            outbox.load(connectionID: connectionID, turnID: turnID)
        )
        XCTAssertEqual(saved.request, request)

        let accepted = try encodedFrame(
            kind: "turn.accepted",
            seq: 1,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(turnID: turnID.uuidString.lowercased())
        )
        let completed = try encodedFrame(
            kind: "assistant.completed",
            seq: 2,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(
                turnID: turnID.uuidString.lowercased(),
                text: "Ran once"
            )
        )
        let secondSockets = ScriptedSocketConnector(scripts: [[
            .persistenceReceiptForLastSubmit,
            .text(accepted),
            .text(completed),
        ]])
        let relaunchedConnector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: cursorStore,
            outboxVault: outbox,
            socketConnector: secondSockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 0,
                baseDelayMilliseconds: 0
            )
        )
        var events: [AgentConnectorStreamEvent] = []
        for try await event in relaunchedConnector.streamTurn(
            request,
            clientToken: String(repeating: "t", count: 48)
        ) {
            events.append(event)
        }

        XCTAssertEqual(events, [.submissionSaved, .accepted, .completed("Ran once")])
        let firstSubmit = try XCTUnwrap(firstSockets.sentTexts.first)
        let replayedSubmit = try XCTUnwrap(secondSockets.sentTexts.first)
        XCTAssertEqual(firstSubmit, replayedSubmit)
        XCTAssertEqual(
            try outbox.load(connectionID: connectionID, turnID: turnID)?.terminal,
            .completed("Ran once")
        )
    }

    func testRelaunchRestoresOriginalChatAndCommitsRecoveredReplyOnce() async throws {
        let suite = "AgentConnectorTests.history-recovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let historyURL = directory.appendingPathComponent("history.json")
        let connectionID = UUID()
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher"
        )
        let pairingResponse = AgentConnectorPairingRedeemResponse(
            connectionID: connectionID,
            gatewayLabel: "My OpenClaw",
            accounts: [account],
            clientToken: String(repeating: "t", count: 48)
        )
        let origin = try AgentConnectorOrigin("https://bridge.example.com")
        let connectorStorageKey = "connector.\(UUID().uuidString)"
        let configurationStorageKey = "settings.\(UUID().uuidString)"
        let tokenVault = InMemoryAgentConnectorTokenVault()
        let outbox = InMemoryAgentConnectorOutboxVault()
        let cursorStore = AgentConnectorCursorStore(
            defaults: defaults,
            storagePrefix: "cursor.\(UUID().uuidString)"
        )
        let firstSockets = ScriptedSocketConnector(scripts: [
            [.disconnect], [.disconnect], [.disconnect],
        ])
        let firstConnector = OpenClawAgentConnector(
            origin: origin,
            cursorStore: cursorStore,
            outboxVault: outbox,
            socketConnector: firstSockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 2,
                baseDelayMilliseconds: 0
            )
        )
        let firstConnections = AgentConnectionModel(
            defaults: defaults,
            storageKey: connectorStorageKey,
            origin: origin,
            pairingService: StubPairingService(response: pairingResponse),
            connector: firstConnector,
            tokenVault: tokenVault,
            outboxVault: outbox
        )
        let paired = try await firstConnections.redeemPairingCode(
            "OC-ABCD-EFGH-JKMN"
        )
        let firstHistory = ConversationHistoryController(
            store: ConversationHistoryStore(fileURL: historyURL)
        )
        let firstConversation = ConversationModel(
            preferences: defaults,
            historyController: firstHistory
        )
        let firstHistoryReady = await firstConversation.ensureHistoryReady()
        XCTAssertTrue(firstHistoryReady)
        let threadID = try XCTUnwrap(firstHistory.selectedThreadID)
        let firstConfiguration = AIConfigurationModel(
            defaults: defaults,
            storageKey: configurationStorageKey,
            providerVault: InMemoryProviderCredentialVault()
        )
        firstConfiguration.registerThread(
            threadID,
            for: firstConfiguration.activeAvatarID,
            route: .remote(paired.binding(for: account))
        )
        await firstConversation.submit(
            "Please do this once",
            aiConfiguration: firstConfiguration,
            agentConnections: firstConnections
        )
        let pending = try XCTUnwrap(outbox.loadAll().first)
        XCTAssertEqual(pending.conversationID, threadID)
        XCTAssertEqual(
            firstHistory.selectedMessages.filter {
                $0.id == pending.userMessageID && $0.role == .user
            }.count,
            1
        )

        let accepted = try encodedFrame(
            kind: "turn.accepted",
            seq: 1,
            connectionID: connectionID,
            conversationID: threadID,
            payload: .init(turnID: pending.turnID.uuidString.lowercased())
        )
        let completed = try encodedFrame(
            kind: "assistant.completed",
            seq: 2,
            connectionID: connectionID,
            conversationID: threadID,
            payload: .init(
                turnID: pending.turnID.uuidString.lowercased(),
                text: "Done once"
            )
        )
        let relaunchedSockets = ScriptedSocketConnector(scripts: [[
            .persistenceReceiptForLastSubmit,
            .text(accepted),
            .text(completed),
        ]])
        let relaunchedConnections = AgentConnectionModel(
            defaults: defaults,
            storageKey: connectorStorageKey,
            origin: origin,
            pairingService: StubPairingService(response: pairingResponse),
            connector: OpenClawAgentConnector(
                origin: origin,
                cursorStore: cursorStore,
                outboxVault: outbox,
                socketConnector: relaunchedSockets,
                reconnectPolicy: .init(
                    maximumReconnectAttempts: 0,
                    baseDelayMilliseconds: 0
                )
            ),
            tokenVault: tokenVault,
            outboxVault: outbox
        )
        let relaunchedConfiguration = AIConfigurationModel(
            defaults: defaults,
            storageKey: configurationStorageKey,
            providerVault: InMemoryProviderCredentialVault()
        )
        let relaunchedHistory = ConversationHistoryController(
            store: ConversationHistoryStore(fileURL: historyURL)
        )
        let relaunchedConversation = ConversationModel(
            preferences: defaults,
            historyController: relaunchedHistory
        )
        let relaunchedHistoryReady = await relaunchedConversation.ensureHistoryReady()
        XCTAssertTrue(relaunchedHistoryReady)
        await relaunchedConversation.recoverPendingRemoteTurnIfNeeded(
            aiConfiguration: relaunchedConfiguration,
            agentConnections: relaunchedConnections
        )
        await relaunchedConversation.recoverPendingRemoteTurnIfNeeded(
            aiConfiguration: relaunchedConfiguration,
            agentConnections: relaunchedConnections
        )

        XCTAssertNil(try outbox.load(
            connectionID: pending.connectionID,
            turnID: pending.turnID
        ))
        XCTAssertEqual(
            relaunchedConversation.messages.filter {
                $0.id == pending.userMessageID && $0.text == "Please do this once"
            }.count,
            1
        )
        XCTAssertEqual(
            relaunchedConversation.messages.filter {
                $0.id == pending.assistantMessageID && $0.text == "Done once"
            }.count,
            1
        )
        let diskHistory = ConversationHistoryController(
            store: ConversationHistoryStore(fileURL: historyURL)
        )
        _ = await diskHistory.start()
        XCTAssertEqual(
            diskHistory.selectedMessages.filter {
                $0.id == pending.assistantMessageID && $0.text == "Done once"
            }.count,
            1
        )
    }

    func testCancellationReconnectsAndReplaysExactCancelUntilWorkerTerminal() async throws {
        let suite = "AgentConnectorTests.cancel-replay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let outbox = InMemoryAgentConnectorOutboxVault()
        let sockets = ScriptedSocketConnector(scripts: [
            [.waitForCancellation],
            [.disconnect],
            [.persistenceReceiptForLastCancel, .workerCancelledTerminalForLastCancel(seq: 1)],
        ])
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: AgentConnectorCursorStore(
                defaults: defaults,
                storagePrefix: "cursor.\(UUID().uuidString)"
            ),
            outboxVault: outbox,
            socketConnector: sockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 2,
                baseDelayMilliseconds: 0
            )
        )
        let request = AgentConnectorTurnRequest(
            connectionID: connectionID,
            conversationID: conversationID,
            turnID: turnID,
            accountID: "primary",
            text: "Cancel me"
        )
        let token = String(repeating: "t", count: 48)
        let stream = connector.streamTurn(
            request,
            clientToken: token
        )
        let consumer = Task {
            for try await _ in stream {}
        }
        for _ in 0 ..< 100
            where sockets.sentFrames.contains(where: { $0.kind == "turn.submit" }) == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        consumer.cancel()
        _ = await consumer.result
        try await connector.cancelTurn(request, clientToken: token)

        XCTAssertEqual(
            try outbox.load(connectionID: connectionID, turnID: turnID)?.terminal,
            .failed(code: "cancelled", message: "The turn was cancelled."),
            "The actual worker terminal must remain durable until conversation history commits it."
        )
        let cancelTexts = sockets.sentTexts.filter { text in
            guard let data = text.data(using: .utf8),
                  let frame = try? JSONDecoder().decode(
                    AgentConnectorWireFrame.self,
                    from: data
                  ) else { return false }
            return frame.kind == "turn.cancel"
        }
        XCTAssertEqual(cancelTexts.count, 2)
        XCTAssertEqual(Set(cancelTexts).count, 1)
    }

    func testSavedCancellationResumesAfterProcessRestart() async throws {
        let suite = "AgentConnectorTests.cancel-restart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let turnID = UUID()
        let request = AgentConnectorTurnRequest(
            connectionID: connectionID,
            conversationID: UUID(),
            turnID: turnID,
            accountID: "primary",
            text: "Cancel after restart"
        )
        let token = String(repeating: "t", count: 48)
        let outbox = InMemoryAgentConnectorOutboxVault()
        let cursorStore = AgentConnectorCursorStore(
            defaults: defaults,
            storagePrefix: "cursor.\(UUID().uuidString)"
        )
        let firstSockets = ScriptedSocketConnector(scripts: [
            [.waitForCancellation],
            [.disconnect], [.disconnect], [.disconnect],
        ])
        let firstConnector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: cursorStore,
            outboxVault: outbox,
            socketConnector: firstSockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 2,
                baseDelayMilliseconds: 0
            )
        )
        let stream = firstConnector.streamTurn(request, clientToken: token)
        let consumer = Task {
            for try await _ in stream {}
        }
        for _ in 0 ..< 100
            where firstSockets.sentFrames.contains(where: {
                $0.kind == "turn.submit"
            }) == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        consumer.cancel()
        _ = await consumer.result
        do {
            try await firstConnector.cancelTurn(request, clientToken: token)
            XCTFail("The first process must retain the saved cancellation")
        } catch {
            XCTAssertEqual(error as? AgentConnectorError, .connectionUnavailable)
        }
        let saved = try XCTUnwrap(
            outbox.load(connectionID: connectionID, turnID: turnID)
        )
        let savedCancel = try XCTUnwrap(saved.cancelFrame)

        let relaunchedSockets = ScriptedSocketConnector(scripts: [[
            .persistenceReceiptForLastCancel,
            .workerCancelledTerminalForLastCancel(seq: 1),
        ]])
        let relaunchedConnector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: cursorStore,
            outboxVault: outbox,
            socketConnector: relaunchedSockets,
            reconnectPolicy: .init(
                maximumReconnectAttempts: 0,
                baseDelayMilliseconds: 0
            )
        )
        do {
            for try await _ in relaunchedConnector.streamTurn(
                request,
                clientToken: token
            ) {}
            XCTFail("A recovered cancellation must finish as cancelled")
        } catch {
            XCTAssertEqual(
                error as? AgentConnectorError,
                .remote(code: "cancelled", message: "The turn was cancelled.")
            )
        }

        XCTAssertEqual(
            try outbox.load(connectionID: connectionID, turnID: turnID)?.terminal,
            .failed(code: "cancelled", message: "The turn was cancelled.")
        )
        let replayedCancel = try XCTUnwrap(
            relaunchedSockets.sentTexts.first(where: { text in
                guard let data = text.data(using: .utf8),
                      let frame = try? JSONDecoder().decode(
                        AgentConnectorWireFrame.self,
                        from: data
                      ) else { return false }
                return frame.kind == "turn.cancel"
            })
        )
        XCTAssertEqual(replayedCancel, savedCancel.text)
    }

    func testStrictPairingResponseRejectsUnknownFieldsAndNonBase64URLToken() throws {
        let connectionID = UUID().uuidString.lowercased()
        let object: [String: Any] = [
            "v": 1,
            "connectionId": connectionID,
            "gatewayLabel": "My OpenClaw",
            "accounts": [[
                "accountId": "primary",
                "agentId": "researcher",
                "displayName": "Researcher",
            ]],
            "clientToken": String(repeating: "t", count: 48),
            "unexpected": true,
        ]
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AgentConnectorPairingRedeemResponse.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
        XCTAssertThrowsError(
            try AgentConnectorTokenValidator.normalized(String(repeating: "+", count: 48))
        )

        let attachmentWithSensitivity: [String: Any] = [
            "v": 1,
            "kind": "assistant.attachment",
            "connectionId": UUID().uuidString.lowercased(),
            "conversationId": UUID().uuidString.lowercased(),
            "messageId": UUID().uuidString.lowercased(),
            "seq": 1,
            "sentAt": 1,
            "payload": [
                "turnId": UUID().uuidString.lowercased(),
                "attachmentId": UUID().uuidString.lowercased(),
                "fileName": "private.png",
                "mediaType": "image/png",
                "byteCount": 1,
                "sha256": String(repeating: "a", count: 64),
                "downloadPath": "/v1/connectors/x/attachments/y",
                "expiresAt": 2,
                "sensitiveMedia": true,
            ],
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(
            AgentConnectorWireFrame.self,
            from: JSONSerialization.data(withJSONObject: attachmentWithSensitivity)
        ))
    }

    func testRemoteConversationRoutesPronunciationAndMapsTextOnlyToConnector() async throws {
        let suite = "AgentConnectorTests.conversation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let history = ConversationHistoryController(
            store: ConversationHistoryStore(
                fileURL: directory.appendingPathComponent("history.json")
            )
        )
        let conversation = ConversationModel(
            preferences: defaults,
            historyController: history
        )
        for _ in 0 ..< 100 where !conversation.isHistoryReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(conversation.isHistoryReady)
        let threadID = try XCTUnwrap(history.selectedThreadID)
        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: "settings.\(UUID().uuidString)",
            providerVault: InMemoryProviderCredentialVault()
        )
        let connectionID = UUID()
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher"
        )
        let vault = InMemoryAgentConnectorTokenVault()
        let connections = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID().uuidString)",
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            pairingService: StubPairingService(response: .init(
                connectionID: connectionID,
                gatewayLabel: "My OpenClaw",
                accounts: [account],
                clientToken: String(repeating: "t", count: 48)
            )),
            connector: StubAgentConnector(),
            tokenVault: vault,
            outboxVault: InMemoryAgentConnectorOutboxVault()
        )
        let paired = try await connections.redeemPairingCode("OC-ABCD-EFGH-JKMN")
        let binding = paired.binding(for: account)
        configuration.registerThread(
            threadID,
            for: configuration.activeAvatarID,
            route: .remote(binding)
        )

        await conversation.submit(
            "How do you pronounce “hello”?",
            aiConfiguration: configuration,
            agentConnections: connections
        )

        XCTAssertNil(conversation.pronunciation)
        XCTAssertEqual(
            conversation.messages.filter { $0.role == .assistant && $0.text == "Hello" }.count,
            1
        )

        await conversation.submit(
            "Open Maps for that place",
            aiConfiguration: configuration,
            agentConnections: connections
        )

        XCTAssertTrue(conversation.nearbyPlaceResults.isEmpty)
        XCTAssertTrue(conversation.venueResults.isEmpty)
        XCTAssertNil(conversation.streamingAssistantReply)
        XCTAssertEqual(
            conversation.messages.filter { $0.role == .assistant && $0.text == "Hello" }.count,
            2
        )
        XCTAssertFalse(
            conversation.messages.contains {
                $0.role == .assistant && $0.text.contains("selected place")
            }
        )
        let submitted = try XCTUnwrap(
            conversation.messages.last(where: { $0.role == .user })
        )
        XCTAssertFalse(submitted.isEligibleForAIContext)
    }

    func testNewSubmitAdvertisesActivityAttachmentAndSafeWorkCapabilities() async throws {
        let suite = "AgentConnectorTests.capabilities.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let accepted = try encodedFrame(
            kind: "turn.accepted",
            seq: 1,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(turnID: turnID.uuidString.lowercased())
        )
        let activity = try encodedFrame(
            kind: "assistant.activity.upsert",
            seq: 2,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(
                turnID: turnID.uuidString.lowercased(),
                revision: 1,
                status: AgentConnectorActivityStatus.preparingFiles.rawValue
            )
        )
        let clear = try encodedFrame(
            kind: "assistant.activity.clear",
            seq: 3,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(turnID: turnID.uuidString.lowercased(), revision: 2)
        )
        let work = try encodedFrame(
            kind: "assistant.work.upsert",
            seq: 4,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(
                turnID: turnID.uuidString.lowercased(),
                revision: 1,
                stepID: "tool:portrait",
                category: AgentConnectorWorkCategory.tool.rawValue,
                workState: AgentConnectorWorkState.running.rawValue,
                title: "Preparing portrait",
                detail: "Checking the generated image",
                tool: "image"
            )
        )
        let completed = try encodedFrame(
            kind: "assistant.completed",
            seq: 5,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(turnID: turnID.uuidString.lowercased(), text: "Ready")
        )
        let sockets = ScriptedSocketConnector(scripts: [[
            .text(accepted), .text(activity), .text(clear), .text(work),
            .text(completed),
        ]])
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: .init(defaults: defaults, storagePrefix: "cursor.\(UUID())"),
            outboxVault: InMemoryAgentConnectorOutboxVault(),
            socketConnector: sockets,
            reconnectPolicy: .init(maximumReconnectAttempts: 0, baseDelayMilliseconds: 0)
        )
        var events: [AgentConnectorStreamEvent] = []
        for try await event in connector.streamTurn(
            .init(
                connectionID: connectionID,
                conversationID: conversationID,
                turnID: turnID,
                accountID: "primary",
                text: "Create the report"
            ),
            clientToken: String(repeating: "t", count: 48)
        ) {
            events.append(event)
        }
        XCTAssertEqual(
            sockets.sentFrames.first(where: { $0.kind == "turn.submit" })?.payload.capabilities,
            ["activity-v1", "attachments-v1", "work-v1"]
        )
        XCTAssertEqual(events, [
            .submissionSaved,
            .accepted,
            .activity(.init(revision: 1, status: .preparingFiles)),
            .activityCleared(revision: 2),
            .work(.init(
                revision: 1,
                stepID: "tool:portrait",
                category: .tool,
                state: .running,
                title: "Preparing portrait",
                detail: "Checking the generated image",
                tool: "image",
                command: nil,
                path: nil,
                output: nil
            )),
            .completed("Ready"),
        ])
    }

    func testWorkStepValidationRejectsPrivatePathsAndSecretOutput() throws {
        let safe = AgentConnectorWorkStep(
            revision: 1,
            stepID: "file:portrait",
            category: .file,
            state: .completed,
            title: "Created portrait",
            detail: "The generated image is ready.",
            tool: nil,
            command: nil,
            path: "outputs/portrait.png",
            output: "Image verified"
        )
        let projected = try safe.validated()
        XCTAssertNil(projected.command)
        XCTAssertNil(projected.path)
        XCTAssertNil(projected.output)

        let privatePath = AgentConnectorWorkStep(
            revision: 2,
            stepID: "file:private",
            category: .file,
            state: .running,
            title: "Reading file",
            detail: nil,
            tool: nil,
            command: nil,
            path: "/srv/openclaw/private.txt",
            output: nil
        )
        XCTAssertThrowsError(try privatePath.validated())

        let secretOutput = AgentConnectorWorkStep(
            revision: 3,
            stepID: "tool:secret",
            category: .tool,
            state: .completed,
            title: "Tool finished",
            detail: nil,
            tool: "network",
            command: nil,
            path: nil,
            output: "Authorization: Bearer not-for-display"
        )
        XCTAssertThrowsError(try secretOutput.validated())
    }

    func testAcceptedSavedBeforeAckRelaunchAcknowledgesReplayAndCompletes() async throws {
        let suite = "AgentConnectorTests.accepted-before-ack.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let outbox = InMemoryAgentConnectorOutboxVault()
        var pending = try makePendingTurn(
            connectionID: connectionID,
            conversationID: conversationID,
            turnID: turnID,
            createdAt: 1_000
        )
        pending.turnAccepted = true
        try outbox.save(pending)
        let accepted = try encodedFrame(
            kind: "turn.accepted",
            seq: 1,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(turnID: turnID.uuidString.lowercased())
        )
        let completed = try encodedFrame(
            kind: "assistant.completed",
            seq: 2,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(turnID: turnID.uuidString.lowercased(), text: "Recovered")
        )
        let sockets = ScriptedSocketConnector(scripts: [[
            .text(accepted), .text(completed),
        ]])
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: .init(defaults: defaults, storagePrefix: "cursor.\(UUID())"),
            outboxVault: outbox,
            socketConnector: sockets,
            reconnectPolicy: .init(maximumReconnectAttempts: 0, baseDelayMilliseconds: 0),
            nowMilliseconds: { 1_000 }
        )
        var events: [AgentConnectorStreamEvent] = []
        for try await event in connector.streamTurn(
            pending.request,
            clientToken: String(repeating: "t", count: 48)
        ) {
            events.append(event)
        }
        XCTAssertEqual(events, [.submissionSaved, .completed("Recovered")])
        XCTAssertEqual(
            sockets.sentFrames.compactMap { $0.kind == "ack" ? $0.payload.ackSeq : nil },
            [1, 2]
        )
    }

    func testActivitySavedBeforeAckRelaunchAcknowledgesMatchingReplayOnce() async throws {
        let suite = "AgentConnectorTests.activity-before-ack.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let outbox = InMemoryAgentConnectorOutboxVault()
        let persistedActivity = try AgentConnectorActivityUpdate(
            revision: 1,
            status: .preparingFiles
        ).validated()
        var pending = try makePendingTurn(
            connectionID: connectionID,
            conversationID: conversationID,
            turnID: turnID,
            createdAt: 1_000
        )
        pending.turnAccepted = true
        pending.activity = persistedActivity
        try outbox.save(pending)
        let cursor = AgentConnectorCursorStore(
            defaults: defaults,
            storagePrefix: "cursor.\(UUID())"
        )
        cursor.acknowledgeInbound(1, connectionID: connectionID)
        let replayedActivity = try encodedFrame(
            kind: "assistant.activity.upsert",
            seq: 2,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(
                turnID: turnID.uuidString.lowercased(),
                revision: 1,
                status: AgentConnectorActivityStatus.preparingFiles.rawValue
            )
        )
        let completed = try encodedFrame(
            kind: "assistant.completed",
            seq: 3,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(turnID: turnID.uuidString.lowercased(), text: "Recovered")
        )
        let sockets = ScriptedSocketConnector(scripts: [[
            .text(replayedActivity), .text(completed),
        ]])
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: cursor,
            outboxVault: outbox,
            socketConnector: sockets,
            reconnectPolicy: .init(maximumReconnectAttempts: 0, baseDelayMilliseconds: 0),
            nowMilliseconds: { 1_000 }
        )
        var events: [AgentConnectorStreamEvent] = []
        for try await event in connector.streamTurn(
            pending.request,
            clientToken: String(repeating: "t", count: 48)
        ) {
            events.append(event)
        }
        XCTAssertEqual(events, [
            .submissionSaved, .activity(persistedActivity), .completed("Recovered"),
        ])
        XCTAssertEqual(
            sockets.sentFrames.compactMap { $0.kind == "ack" ? $0.payload.ackSeq : nil },
            [2, 3]
        )
    }

    func testPersistedActivityReplayWithSameRevisionDifferentStatusFailsClosed() async throws {
        let suite = "AgentConnectorTests.activity-replay-mismatch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connectionID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let outbox = InMemoryAgentConnectorOutboxVault()
        var pending = try makePendingTurn(
            connectionID: connectionID,
            conversationID: conversationID,
            turnID: turnID,
            createdAt: 1_000
        )
        pending.turnAccepted = true
        pending.activity = try AgentConnectorActivityUpdate(
            revision: 1,
            status: .planning
        ).validated()
        try outbox.save(pending)
        let mismatch = try encodedFrame(
            kind: "assistant.activity.upsert",
            seq: 1,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(
                turnID: turnID.uuidString.lowercased(),
                revision: 1,
                status: AgentConnectorActivityStatus.searching.rawValue
            )
        )
        let sockets = ScriptedSocketConnector(scripts: [[.text(mismatch)]])
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: .init(defaults: defaults, storagePrefix: "cursor.\(UUID())"),
            outboxVault: outbox,
            socketConnector: sockets,
            reconnectPolicy: .init(maximumReconnectAttempts: 0, baseDelayMilliseconds: 0),
            nowMilliseconds: { 1_000 }
        )
        var events: [AgentConnectorStreamEvent] = []
        do {
            for try await event in connector.streamTurn(
                pending.request,
                clientToken: String(repeating: "t", count: 48)
            ) {
                events.append(event)
            }
            XCTFail("A same-revision activity with different state must fail closed")
        } catch {
            XCTAssertEqual(error as? AgentConnectorError, .invalidFrame)
        }
        XCTAssertEqual(events, [.submissionSaved, .activity(pending.activity!)])
        XCTAssertFalse(sockets.sentFrames.contains { $0.kind == "ack" })
    }

    func testAttachmentPersistsBeforeAckAndSurvivesRelaunchToCompletion() async throws {
        let suite = "AgentConnectorTests.attachment-relaunch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now: Int64 = 1_000
        let connectionID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let metadata = makeAttachmentMetadata(
            connectionID: connectionID,
            turnID: turnID,
            expiresAt: now + 60_000
        )
        let accepted = try encodedFrame(
            kind: "turn.accepted",
            seq: 1,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(turnID: turnID.uuidString.lowercased())
        )
        let attachment = try makeAttachmentFrame(
            seq: 2,
            conversationID: conversationID,
            metadata: metadata
        )
        let recorder = ConnectorTestRecorder()
        let outbox = RecordingAgentConnectorOutboxVault(recorder: recorder)
        let artifacts = RecordingArtifactService(recorder: recorder)
        let cursor = AgentConnectorCursorStore(
            defaults: defaults,
            storagePrefix: "cursor.\(UUID())"
        )
        let request = AgentConnectorTurnRequest(
            connectionID: connectionID,
            conversationID: conversationID,
            turnID: turnID,
            accountID: "primary",
            text: "Create an image"
        )
        let firstSockets = ScriptedSocketConnector(
            scripts: [[.text(accepted), .text(attachment), .disconnect]],
            recorder: recorder
        )
        let firstConnector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: cursor,
            outboxVault: outbox,
            socketConnector: firstSockets,
            artifactService: artifacts,
            reconnectPolicy: .init(maximumReconnectAttempts: 0, baseDelayMilliseconds: 0),
            nowMilliseconds: { now }
        )
        var firstEvents: [AgentConnectorStreamEvent] = []
        do {
            for try await event in firstConnector.streamTurn(
                request,
                clientToken: String(repeating: "t", count: 48)
            ) {
                firstEvents.append(event)
            }
            XCTFail("The first process should stop after the verified attachment")
        } catch {
            XCTAssertEqual(error as? AgentConnectorError, .connectionUnavailable)
        }
        XCTAssertEqual(firstEvents, [
            .submissionSaved, .accepted,
            .attachmentTransfer(metadata),
            .attachment(try artifacts.storedAttachment(for: metadata)),
        ])
        let operations = recorder.operations
        let downloadIndex = try XCTUnwrap(operations.firstIndex(of: "download"))
        let persistIndex = try XCTUnwrap(operations.firstIndex(of: "persist-attachment"))
        let ackIndex = try XCTUnwrap(operations.firstIndex(of: "ack-2"))
        XCTAssertLessThan(downloadIndex, persistIndex)
        XCTAssertLessThan(persistIndex, ackIndex)
        XCTAssertEqual(
            try outbox.load(connectionID: connectionID, turnID: turnID)?.attachments?.count,
            1
        )

        let completed = try encodedFrame(
            kind: "assistant.completed",
            seq: 3,
            connectionID: connectionID,
            conversationID: conversationID,
            payload: .init(turnID: turnID.uuidString.lowercased(), text: "Created 1 file.")
        )
        let relaunched = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: cursor,
            outboxVault: outbox,
            socketConnector: ScriptedSocketConnector(scripts: [[.text(completed)]]),
            artifactService: artifacts,
            reconnectPolicy: .init(maximumReconnectAttempts: 0, baseDelayMilliseconds: 0),
            nowMilliseconds: { now }
        )
        var relaunchedEvents: [AgentConnectorStreamEvent] = []
        for try await event in relaunched.streamTurn(
            request,
            clientToken: String(repeating: "t", count: 48)
        ) {
            relaunchedEvents.append(event)
        }
        XCTAssertEqual(relaunchedEvents, [
            .submissionSaved,
            .attachment(try artifacts.storedAttachment(for: metadata)),
            .completed("Created 1 file."),
        ])
        XCTAssertEqual(artifacts.downloadCount, 1)
        XCTAssertEqual(
            try outbox.load(connectionID: connectionID, turnID: turnID)?.terminal,
            .completed("Created 1 file.")
        )
    }

    func testCancellationRacePreservesAttachmentWhenCompletionWins() async throws {
        let fixture = try makeCancellationAttachmentFixture(terminalKind: .completed)
        try await fixture.connector.cancelTurn(fixture.request, clientToken: fixture.token)
        let pending = try XCTUnwrap(
            fixture.outbox.load(
                connectionID: fixture.request.connectionID,
                turnID: fixture.request.turnID
            )
        )
        XCTAssertEqual(pending.attachments?.count, 1)
        XCTAssertEqual(pending.terminal, .completed("Created 1 file."))
        XCTAssertEqual(fixture.artifacts.downloadCount, 1)
        XCTAssertTrue(fixture.artifacts.deletedReferences.isEmpty)
        XCTAssertEqual(fixture.sockets.closedSocketCount, 1)
    }

    func testCancellationRaceDeletesAttachmentWhenTerminalErrorWins() async throws {
        let fixture = try makeCancellationAttachmentFixture(terminalKind: .failed)
        try await fixture.connector.cancelTurn(fixture.request, clientToken: fixture.token)
        let pending = try XCTUnwrap(
            fixture.outbox.load(
                connectionID: fixture.request.connectionID,
                turnID: fixture.request.turnID
            )
        )
        XCTAssertNil(pending.attachments)
        XCTAssertEqual(
            pending.terminal,
            .failed(code: "generation_failed", message: "File generation failed.")
        )
        XCTAssertEqual(fixture.artifacts.downloadCount, 1)
        XCTAssertEqual(fixture.artifacts.deletedReferences.count, 1)
    }

    func testCancellationReceiptWaitsForTrueWorkerCancelledTerminal() async throws {
        let fixture = try makeCancellationAttachmentFixture(terminalKind: .cancelled)
        try await fixture.connector.cancelTurn(fixture.request, clientToken: fixture.token)
        let pending = try XCTUnwrap(fixture.outbox.load(
            connectionID: fixture.request.connectionID,
            turnID: fixture.request.turnID
        ))
        XCTAssertNotNil(pending.cancelFrame)
        XCTAssertEqual(
            pending.terminal,
            .failed(code: "cancelled", message: "The turn was cancelled.")
        )
        XCTAssertNil(pending.attachments)
        XCTAssertEqual(fixture.artifacts.downloadCount, 1)
        XCTAssertEqual(fixture.artifacts.deletedReferences.count, 1)
        XCTAssertEqual(fixture.sockets.closedSocketCount, 1)
    }

    func testCancellationReceiptAndDisconnectPreserveFileUntilCompletionAfterRelaunch() async throws {
        let fixture = try makeCancellationAttachmentFixture(
            terminalKind: .completed,
            disconnectAfterAttachment: true
        )
        do {
            try await fixture.connector.cancelTurn(fixture.request, clientToken: fixture.token)
            XCTFail("The relay receipt alone must not finish cancellation.")
        } catch {
            XCTAssertEqual(error as? AgentConnectorError, .connectionUnavailable)
        }
        let pending = try XCTUnwrap(fixture.outbox.load(
            connectionID: fixture.request.connectionID,
            turnID: fixture.request.turnID
        ))
        let cancel = try XCTUnwrap(pending.cancelFrame)
        XCTAssertNil(pending.terminal)
        XCTAssertEqual(pending.attachments?.count, 1)
        XCTAssertTrue(fixture.artifacts.deletedReferences.isEmpty)

        let sockets = ScriptedSocketConnector(scripts: [[
            .persistenceReceiptForLastCancel, .text(fixture.terminalFrame),
        ]])
        let relaunched = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: fixture.cursor,
            outboxVault: fixture.outbox,
            socketConnector: sockets,
            artifactService: fixture.artifacts,
            reconnectPolicy: .init(maximumReconnectAttempts: 0, baseDelayMilliseconds: 0),
            nowMilliseconds: { 1_000 }
        )
        var events: [AgentConnectorStreamEvent] = []
        for try await event in relaunched.streamTurn(fixture.request, clientToken: fixture.token) {
            events.append(event)
        }
        XCTAssertEqual(events, [
            .submissionSaved,
            .attachment(try XCTUnwrap(pending.attachments?.first)),
            .completed("Created 1 file."),
        ])
        XCTAssertEqual(sockets.sentTexts.first, cancel.text)
        XCTAssertEqual(sockets.closedSocketCount, 1)
        XCTAssertEqual(fixture.artifacts.downloadCount, 1)
        XCTAssertTrue(fixture.artifacts.deletedReferences.isEmpty)
        XCTAssertEqual(
            try fixture.outbox.load(
                connectionID: fixture.request.connectionID,
                turnID: fixture.request.turnID
            )?.terminal,
            .completed("Created 1 file.")
        )
    }

    func testDelayedAttachmentShowsTransferBeforeVerifiedSaveAndAcknowledgement() async throws {
        let gate = ConnectorDownloadGate()
        let fixture = try makeCancellationAttachmentFixture(
            terminalKind: .completed,
            savedCancellation: true,
            downloadGate: gate
        )
        var events: [AgentConnectorStreamEvent] = []
        let consumer = Task { @MainActor in
            for try await event in fixture.connector.streamTurn(
                fixture.request,
                clientToken: fixture.token
            ) {
                events.append(event)
            }
        }
        for _ in 0 ..< 100 {
            if events.contains(.attachmentTransfer(fixture.metadata)),
               fixture.artifacts.downloadCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(events, [.submissionSaved, .attachmentTransfer(fixture.metadata)])
        let waiting = try XCTUnwrap(fixture.outbox.load(
            connectionID: fixture.request.connectionID,
            turnID: fixture.request.turnID
        ))
        XCTAssertNil(waiting.attachments)
        XCTAssertNil(waiting.terminal)
        XCTAssertFalse(
            fixture.sockets.sentFrames.contains { $0.kind == "ack" },
            "The relay must retain the blob until download, verification and local persistence finish."
        )

        await gate.release()
        try await consumer.value
        let stored = try fixture.artifacts.storedAttachment(for: fixture.metadata)
        XCTAssertEqual(events, [
            .submissionSaved, .attachmentTransfer(fixture.metadata),
            .attachment(stored), .completed("Created 1 file."),
        ])
        XCTAssertEqual(
            fixture.sockets.sentFrames.filter { $0.kind == "ack" }.compactMap(\.payload.ackSeq),
            [1, 2]
        )
        XCTAssertEqual(
            try fixture.outbox.load(
                connectionID: fixture.request.connectionID,
                turnID: fixture.request.turnID
            )?.attachments,
            [stored]
        )
    }

    func testCancelledAttachmentDownloadNeverAcknowledgesOrLosesPendingTurn() async throws {
        let gate = ConnectorDownloadGate()
        let fixture = try makeCancellationAttachmentFixture(
            terminalKind: .completed,
            savedCancellation: true,
            downloadGate: gate
        )
        var events: [AgentConnectorStreamEvent] = []
        let consumer = Task { @MainActor in
            for try await event in fixture.connector.streamTurn(
                fixture.request,
                clientToken: fixture.token
            ) {
                events.append(event)
            }
        }
        for _ in 0 ..< 100 where fixture.artifacts.downloadCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.artifacts.downloadCount, 1)
        consumer.cancel()
        _ = await consumer.result
        for _ in 0 ..< 100 {
            if await gate.wasCancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let downloadWasCancelled = await gate.wasCancelled
        XCTAssertTrue(downloadWasCancelled)
        let pending = try XCTUnwrap(fixture.outbox.load(
            connectionID: fixture.request.connectionID,
            turnID: fixture.request.turnID
        ))
        XCTAssertNotNil(pending.cancelFrame)
        XCTAssertNil(pending.terminal)
        XCTAssertNil(pending.attachments)
        XCTAssertFalse(fixture.sockets.sentFrames.contains { $0.kind == "ack" })
        XCTAssertFalse(events.contains(.completed("Created 1 file.")))
        XCTAssertTrue(fixture.artifacts.deletedReferences.isEmpty)
        await gate.release()
    }

    func testPreOutboxHistoryFailureRetainsDraftAndLeavesNoUserBubble() async throws {
        let suite = "AgentConnectorTests.pre-outbox-history.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let gate = ConnectorHistoryFailureGate()
        let history = ConversationHistoryController(store: .init(
            fileURL: directory.appendingPathComponent("history.json"),
            failureInjector: { try gate.check($0) }
        ))
        let conversation = ConversationModel(preferences: defaults, historyController: history)
        let historyIsReady = await conversation.ensureHistoryReady()
        XCTAssertTrue(historyIsReady)
        let threadID = try XCTUnwrap(history.selectedThreadID)
        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: "settings.\(UUID())",
            providerVault: InMemoryProviderCredentialVault()
        )
        let binding = makeBinding()
        configuration.registerThread(
            threadID,
            for: configuration.activeAvatarID,
            route: .remote(binding)
        )
        let outbox = InMemoryAgentConnectorOutboxVault()
        let connections = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID())",
            origin: nil,
            connector: StubAgentConnector(),
            outboxVault: outbox
        )
        gate.operation = .persist
        var submissionWasSaved = false
        await conversation.submit(
            "Keep this draft",
            aiConfiguration: configuration,
            agentConnections: connections,
            onSubmissionSaved: { submissionWasSaved = true }
        )
        XCTAssertFalse(submissionWasSaved)
        XCTAssertFalse(conversation.messages.contains { $0.text == "Keep this draft" })
        XCTAssertTrue(try outbox.loadAll().isEmpty)
        XCTAssertEqual(conversation.remoteAgentActivity?.title, "Message not sent")
    }

    func testPendingTurnBlocksNewDraftAndThreadDeletionWithoutDroppingOutbox() async throws {
        let suite = "AgentConnectorTests.pending-delete.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let history = ConversationHistoryController(
            store: .init(fileURL: directory.appendingPathComponent("history.json"))
        )
        let conversation = ConversationModel(preferences: defaults, historyController: history)
        let historyIsReady = await conversation.ensureHistoryReady()
        XCTAssertTrue(historyIsReady)
        let threadID = try XCTUnwrap(history.selectedThreadID)
        let binding = makeBinding()
        let pending = try makePendingTurn(
            connectionID: binding.connectionID,
            conversationID: threadID,
            turnID: UUID(),
            createdAt: 1_000
        )
        let outbox = InMemoryAgentConnectorOutboxVault()
        try outbox.save(pending)
        let connections = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID())",
            origin: nil,
            outboxVault: outbox
        )
        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: "settings.\(UUID())",
            providerVault: InMemoryProviderCredentialVault()
        )
        configuration.registerThread(
            threadID,
            for: configuration.activeAvatarID,
            route: .remote(binding)
        )
        var submissionWasSaved = false
        await conversation.submit(
            "Do not erase this draft",
            aiConfiguration: configuration,
            agentConnections: connections,
            onSubmissionSaved: { submissionWasSaved = true }
        )
        XCTAssertFalse(submissionWasSaved)
        XCTAssertFalse(conversation.messages.contains { $0.text == "Do not erase this draft" })
        XCTAssertNotNil(try connections.threadDeletionBlockReason(for: threadID))
        XCTAssertNotNil(try outbox.load(
            connectionID: pending.connectionID,
            turnID: pending.turnID
        ))
    }

    func testRelaunchCommitsDurableTerminalWithVerifiedAttachmentIntoOriginalChat() async throws {
        let suite = "AgentConnectorTests.terminal-attachment-history.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let historyURL = directory.appendingPathComponent("history.json")
        let history = ConversationHistoryController(store: .init(fileURL: historyURL))
        let conversation = ConversationModel(preferences: defaults, historyController: history)
        let ready = await conversation.ensureHistoryReady()
        XCTAssertTrue(ready)
        let threadID = try XCTUnwrap(history.selectedThreadID)
        let connectionID = UUID()
        let turnID = UUID()
        let metadata = makeAttachmentMetadata(
            connectionID: connectionID,
            turnID: turnID,
            expiresAt: 60_000
        )
        let artifacts = RecordingArtifactService()
        var pending = try makePendingTurn(
            connectionID: connectionID,
            conversationID: threadID,
            turnID: turnID,
            createdAt: 1_000
        )
        pending.turnAccepted = true
        pending.attachments = [try artifacts.storedAttachment(for: metadata)]
        pending.terminal = .completed("Created 1 file.")
        let outbox = InMemoryAgentConnectorOutboxVault()
        try outbox.save(pending)
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher"
        )
        let tokenVault = InMemoryAgentConnectorTokenVault()
        let origin = try AgentConnectorOrigin("https://bridge.example.com")
        let connections = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID())",
            origin: origin,
            pairingService: StubPairingService(response: .init(
                connectionID: connectionID,
                gatewayLabel: "My OpenClaw",
                accounts: [account],
                clientToken: String(repeating: "t", count: 48)
            )),
            connector: OpenClawAgentConnector(
                origin: origin,
                outboxVault: outbox,
                socketConnector: ScriptedSocketConnector(scripts: []),
                artifactService: artifacts,
                nowMilliseconds: { 1_000 }
            ),
            artifactService: artifacts,
            tokenVault: tokenVault,
            outboxVault: outbox
        )
        let paired = try await connections.redeemPairingCode("OC-ABCD-EFGH-JKMN")
        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: "settings.\(UUID())",
            providerVault: InMemoryProviderCredentialVault()
        )
        configuration.registerThread(
            threadID,
            for: configuration.activeAvatarID,
            route: .remote(paired.binding(for: account))
        )
        await conversation.recoverPendingRemoteTurnIfNeeded(
            aiConfiguration: configuration,
            agentConnections: connections
        )
        XCTAssertNil(try outbox.load(connectionID: connectionID, turnID: turnID))
        let reply = try XCTUnwrap(conversation.messages.first(where: {
            $0.id == pending.assistantMessageID
        }))
        XCTAssertEqual(reply.text, "Created 1 file.")
        XCTAssertEqual(reply.attachments.first?.connectorArtifact, metadata.conversationReference)
        let disk = ConversationHistoryController(store: .init(fileURL: historyURL))
        _ = await disk.start()
        XCTAssertEqual(
            disk.selectedMessages.first(where: { $0.id == pending.assistantMessageID })?
                .attachments.first?.connectorArtifact,
            metadata.conversationReference
        )
    }

    func testExpiredRecoveryDeletesVerifiedPendingArtifactsBeforeClearingOutbox() async throws {
        let suite = "AgentConnectorTests.expired-artifacts.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let history = ConversationHistoryController(
            store: .init(fileURL: directory.appendingPathComponent("history.json"))
        )
        let conversation = ConversationModel(preferences: defaults, historyController: history)
        let ready = await conversation.ensureHistoryReady()
        XCTAssertTrue(ready)
        let threadID = try XCTUnwrap(history.selectedThreadID)
        let connectionID = UUID()
        let turnID = UUID()
        let artifacts = RecordingArtifactService()
        let metadata = makeAttachmentMetadata(
            connectionID: connectionID,
            turnID: turnID,
            expiresAt: 2_000_000
        )
        var pending = try makePendingTurn(
            connectionID: connectionID,
            conversationID: threadID,
            turnID: turnID,
            createdAt: 1_000
        )
        pending.attachments = [try artifacts.storedAttachment(for: metadata)]
        let outbox = InMemoryAgentConnectorOutboxVault()
        try outbox.save(pending)
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher"
        )
        let origin = try AgentConnectorOrigin("https://bridge.example.com")
        let connections = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID())",
            origin: origin,
            pairingService: StubPairingService(response: .init(
                connectionID: connectionID,
                gatewayLabel: "My OpenClaw",
                accounts: [account],
                clientToken: String(repeating: "t", count: 48)
            )),
            connector: OpenClawAgentConnector(
                origin: origin,
                outboxVault: outbox,
                socketConnector: ScriptedSocketConnector(scripts: []),
                artifactService: artifacts,
                nowMilliseconds: {
                    1_000 + AgentConnectorPendingTurn.maximumLifetimeMilliseconds
                }
            ),
            artifactService: artifacts,
            tokenVault: InMemoryAgentConnectorTokenVault(),
            outboxVault: outbox
        )
        let paired = try await connections.redeemPairingCode("OC-ABCD-EFGH-JKMN")
        let configuration = AIConfigurationModel(
            defaults: defaults,
            storageKey: "settings.\(UUID())",
            providerVault: InMemoryProviderCredentialVault()
        )
        configuration.registerThread(
            threadID,
            for: configuration.activeAvatarID,
            route: .remote(paired.binding(for: account))
        )
        await conversation.recoverPendingRemoteTurnIfNeeded(
            aiConfiguration: configuration,
            agentConnections: connections
        )
        XCTAssertNil(try outbox.load(connectionID: connectionID, turnID: turnID))
        XCTAssertEqual(artifacts.deletedReferences, [metadata.conversationReference])
        XCTAssertTrue(conversation.messages.contains {
            $0.id == pending.assistantMessageID
                && $0.text.contains("recovery window expired")
        })
    }

    func testDeliveredArtifactsSurviveAgeDisconnectAndAllThreadReconciliation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentConnectorArtifactStore(rootURL: directory)
        let connectionID = UUID()
        let first = try persistTestArtifact(
            store: store,
            connectionID: connectionID,
            attachmentID: UUID(),
            bytes: Data("first".utf8),
            storedAt: 1
        )
        let second = try persistTestArtifact(
            store: store,
            connectionID: connectionID,
            attachmentID: UUID(),
            bytes: Data("second".utf8),
            storedAt: 1
        )
        let service = OpenClawAgentConnectorArtifactService(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            store: store
        )
        let firstMessage = ConversationMessage(
            role: .assistant,
            text: "First thread",
            attachments: [conversationDescriptor(first)]
        )
        let secondMessage = ConversationMessage(
            role: .assistant,
            text: "Second thread",
            attachments: [conversationDescriptor(second)]
        )
        let defaults = UserDefaults(suiteName: "AgentConnectorTests.artifacts.\(UUID())")!
        let account = AgentConnectorAccount(
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher"
        )
        let model = AgentConnectionModel(
            defaults: defaults,
            storageKey: "connector.\(UUID())",
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            pairingService: StubPairingService(response: .init(
                connectionID: connectionID,
                gatewayLabel: "My OpenClaw",
                accounts: [account],
                clientToken: String(repeating: "t", count: 48)
            )),
            revocationService: StubRevocationService(shouldFail: false),
            connector: StubAgentConnector(),
            artifactService: service,
            tokenVault: InMemoryAgentConnectorTokenVault(),
            outboxVault: InMemoryAgentConnectorOutboxVault()
        )
        _ = try await model.redeemPairingCode("OC-ABCD-EFGH-JKMN")
        await model.reconcileArtifacts(referencedBy: [firstMessage, secondMessage])
        var firstURL = await service.storedURL(for: first.metadata.conversationReference)
        var secondURL = await service.storedURL(for: second.metadata.conversationReference)
        XCTAssertNotNil(firstURL)
        XCTAssertNotNil(secondURL)
        await service.pruneInvalidArtifacts()
        firstURL = await service.storedURL(for: first.metadata.conversationReference)
        XCTAssertNotNil(firstURL)
        await model.deleteArtifacts(referencedBy: [firstMessage])
        firstURL = await service.storedURL(for: first.metadata.conversationReference)
        secondURL = await service.storedURL(for: second.metadata.conversationReference)
        XCTAssertNil(firstURL)
        XCTAssertNotNil(secondURL)
        try await model.disconnect(connectionID)
        secondURL = await service.storedURL(for: second.metadata.conversationReference)
        XCTAssertNotNil(secondURL)
    }

    func testArtifactDownloadWithoutContentLengthUsesExactFileVerification() async throws {
        let fixture = try makeArtifactDownloadFixture(contentLengthOffset: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let stored = try await fixture.service.downloadAndStore(
            fixture.metadata,
            clientToken: String(repeating: "t", count: 48)
        )

        let storedURLValue = await fixture.service.storedURL(
            for: stored.metadata.conversationReference
        )
        let storedURL = try XCTUnwrap(storedURLValue)
        XCTAssertEqual(try Data(contentsOf: storedURL), fixture.bytes)
    }

    func testArtifactDownloadRejectsPresentMismatchedContentLength() async throws {
        let fixture = try makeArtifactDownloadFixture(contentLengthOffset: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await fixture.service.downloadAndStore(
                fixture.metadata,
                clientToken: String(repeating: "t", count: 48)
            )
            XCTFail("A present mismatched Content-Length must fail closed")
        } catch {
            XCTAssertEqual(error as? AgentConnectorError, .attachmentIntegrityFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.artifactsRoot.path))
    }

    func testArtifactDownloadPreservesTransportCancellation() async throws {
        let artifactsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: artifactsRoot) }
        let service = OpenClawAgentConnectorArtifactService(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            transport: CancelledArtifactTransport(),
            store: AgentConnectorArtifactStore(rootURL: artifactsRoot),
            nowMilliseconds: { 1_000 }
        )
        let metadata = makeAttachmentMetadata(
            connectionID: UUID(),
            turnID: UUID(),
            expiresAt: 61_000
        )
        do {
            _ = try await service.downloadAndStore(
                metadata,
                clientToken: String(repeating: "t", count: 48)
            )
            XCTFail("An interrupted GET must remain cancellation, not a retryable network failure.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactsRoot.path))
    }

    func testPersistedGeneratedImageGetsBoundedRelaunchThumbnail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("large.jpg")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2_400, height: 1_200))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_400, height: 1_200))
        }
        let sourceData = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        try sourceData.write(to: source)
        let firstCache = AgentConnectorArtifactThumbnailCache()
        let firstData = await firstCache.thumbnailData(
            for: source,
            cacheKey: "relaunch-thumbnail"
        )
        let first = try XCTUnwrap(firstData)
        let relaunchedCache = AgentConnectorArtifactThumbnailCache()
        let relaunchedData = await relaunchedCache.thumbnailData(
            for: source,
            cacheKey: "relaunch-thumbnail"
        )
        let relaunched = try XCTUnwrap(relaunchedData)
        let thumbnail = try XCTUnwrap(UIImage(data: relaunched))
        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 320)
        XCTAssertLessThan(relaunched.count, 2 * 1_024 * 1_024)
        XCTAssertEqual(first, relaunched)
    }

    func testPersistedGeneratedVideoGetsBoundedPosterThumbnail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("poster-source.mp4")
        try await makeSingleFrameVideo(at: source)

        let cache = AgentConnectorArtifactThumbnailCache()
        let thumbnailData = await cache.thumbnailData(
            for: source,
            cacheKey: "video-poster-thumbnail",
            kind: .video
        )
        let data = try XCTUnwrap(thumbnailData)
        let thumbnail = try XCTUnwrap(UIImage(data: data))

        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 320)
        XCTAssertLessThan(data.count, 2 * 1_024 * 1_024)
        XCTAssertGreaterThan(thumbnail.size.width, thumbnail.size.height)
    }

    func testConnectorArtifactFilesExportStagesUserNamedLocalCopyAndCleansIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("content.mp4")
        let sourceData = Data((0 ..< 4_096).map { UInt8($0 % 251) })
        try sourceData.write(to: source)

        let staged = try ConnectorArtifactExportStager.stageCopy(
            of: source,
            displayName: "Finished movie.mp4",
            temporaryRoot: directory
        )

        XCTAssertEqual(staged.lastPathComponent, "Finished movie.mp4")
        XCTAssertEqual(try Data(contentsOf: staged), sourceData)
        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        XCTAssertNotEqual(staged.standardizedFileURL, source.standardizedFileURL)

        let stagedDirectory = staged.deletingLastPathComponent()
        ConnectorArtifactExportStager.removeStagedCopy(at: staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testConnectorArtifactFilesExportSanitizesLegacyNameAndKeepsExtension() {
        let source = URL(fileURLWithPath: "/private/content.mp4")

        XCTAssertEqual(
            ConnectorArtifactExportStager.sanitizedFilename(
                displayName: "../Movie: Final",
                sourceURL: source
            ),
            "Movie- Final.mp4"
        )
        let longName = String(repeating: "a", count: 240) + ".mp4"
        let bounded = ConnectorArtifactExportStager.sanitizedFilename(
            displayName: longName,
            sourceURL: source
        )
        XCTAssertLessThanOrEqual(bounded.count, 160)
        XCTAssertEqual((bounded as NSString).pathExtension, "mp4")
    }

    func testConnectorArtifactPhotoSaveMapsOnlyVisualMediaResources() {
        XCTAssertEqual(
            ConnectorArtifactPhotoLibrarySaver.resourceType(for: .image),
            .photo
        )
        XCTAssertEqual(
            ConnectorArtifactPhotoLibrarySaver.resourceType(for: .video),
            .video
        )
        XCTAssertNil(ConnectorArtifactPhotoLibrarySaver.resourceType(for: .file))
        XCTAssertNil(ConnectorArtifactPhotoLibrarySaver.resourceType(for: .unknown))
    }

    func testConnectorArtifactPhotoSaveAuthorizationPolicyIsAddOnlyAndFailClosed() {
        XCTAssertEqual(
            ConnectorArtifactPhotoLibrarySaver.authorizationDecision(for: .notDetermined),
            .request
        )
        XCTAssertEqual(
            ConnectorArtifactPhotoLibrarySaver.authorizationDecision(for: .authorized),
            .save
        )
        XCTAssertEqual(
            ConnectorArtifactPhotoLibrarySaver.authorizationDecision(for: .limited),
            .save
        )
        XCTAssertEqual(
            ConnectorArtifactPhotoLibrarySaver.authorizationDecision(for: .denied),
            .deny
        )
        XCTAssertEqual(
            ConnectorArtifactPhotoLibrarySaver.authorizationDecision(for: .restricted),
            .deny
        )
    }

    func testConnectorArtifactPhotoSaveShipsAddOnlyUsageDisclosureAndValidSymbols() throws {
        let disclosure = try XCTUnwrap(
            Bundle.main.object(
                forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription"
            ) as? String
        )
        XCTAssertTrue(disclosure.localizedCaseInsensitiveContains("Save to Photos"))
        XCTAssertNotNil(UIImage(systemName: "photo.badge.arrow.down"))
        XCTAssertNotNil(UIImage(systemName: "folder.badge.plus"))
    }

    private func makeSingleFrameVideo(at url: URL) async throws {
        let width = 96
        let height = 54
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferPoolCreatePixelBuffer(
                nil,
                try XCTUnwrap(adaptor.pixelBufferPool),
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            memset(baseAddress, 0x7F, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: .zero))
        input.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    private enum CancellationAttachmentTerminalKind {
        case completed
        case failed
        case cancelled
    }

    private struct CancellationAttachmentFixture {
        let connector: OpenClawAgentConnector
        let request: AgentConnectorTurnRequest
        let token: String
        let outbox: InMemoryAgentConnectorOutboxVault
        let artifacts: RecordingArtifactService
        let cursor: AgentConnectorCursorStore
        let sockets: ScriptedSocketConnector
        let terminalFrame: String
        let metadata: AgentConnectorAttachmentMetadata
    }

    private func makeCancellationAttachmentFixture(
        terminalKind: CancellationAttachmentTerminalKind,
        disconnectAfterAttachment: Bool = false,
        savedCancellation: Bool = false,
        downloadGate: ConnectorDownloadGate? = nil
    ) throws -> CancellationAttachmentFixture {
        let now: Int64 = 1_000
        let connectionID = UUID()
        let conversationID = UUID()
        let turnID = UUID()
        let metadata = makeAttachmentMetadata(
            connectionID: connectionID,
            turnID: turnID,
            expiresAt: now + 60_000
        )
        var pending = try makePendingTurn(
            connectionID: connectionID,
            conversationID: conversationID,
            turnID: turnID,
            createdAt: now
        )
        pending.turnAccepted = true
        if savedCancellation {
            let messageID = UUID()
            pending.cancelFrame = .init(
                sequence: 2,
                messageID: messageID,
                text: try encodedFrame(
                    kind: "turn.cancel",
                    seq: 2,
                    connectionID: connectionID,
                    conversationID: conversationID,
                    messageID: messageID,
                    payload: .init(turnID: turnID.uuidString.lowercased())
                )
            )
        }
        let outbox = InMemoryAgentConnectorOutboxVault()
        try outbox.save(pending)
        let suite = "AgentConnectorTests.cancel-attachment.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let cursor = AgentConnectorCursorStore(
            defaults: defaults,
            storagePrefix: "cursor.\(UUID())"
        )
        XCTAssertEqual(cursor.nextOutbound(connectionID: connectionID), 1)
        if savedCancellation {
            XCTAssertEqual(cursor.nextOutbound(connectionID: connectionID), 2)
        }
        let attachment = try makeAttachmentFrame(
            seq: 1,
            conversationID: conversationID,
            metadata: metadata
        )
        let terminal: String
        switch terminalKind {
        case .completed:
            terminal = try encodedFrame(
                kind: "assistant.completed",
                seq: 2,
                connectionID: connectionID,
                conversationID: conversationID,
                payload: .init(
                    turnID: turnID.uuidString.lowercased(),
                    text: "Created 1 file."
                )
            )
        case .failed:
            terminal = try encodedFrame(
                kind: "turn.error",
                seq: 2,
                connectionID: connectionID,
                conversationID: conversationID,
                payload: .init(
                    turnID: turnID.uuidString.lowercased(),
                    code: "generation_failed",
                    message: "File generation failed.",
                    retryable: false
                )
            )
        case .cancelled:
            terminal = try encodedFrame(
                kind: "turn.error",
                seq: 2,
                connectionID: connectionID,
                conversationID: conversationID,
                payload: .init(
                    turnID: turnID.uuidString.lowercased(),
                    code: "cancelled",
                    message: "The turn was cancelled.",
                    retryable: false
                )
            )
        }
        let artifacts = RecordingArtifactService(downloadGate: downloadGate)
        let sockets = ScriptedSocketConnector(scripts: [[
            .persistenceReceiptForLastCancel,
            .text(attachment),
            disconnectAfterAttachment ? .disconnect : .text(terminal),
        ]])
        let connector = OpenClawAgentConnector(
            origin: try AgentConnectorOrigin("https://bridge.example.com"),
            cursorStore: cursor,
            outboxVault: outbox,
            socketConnector: sockets,
            artifactService: artifacts,
            reconnectPolicy: .init(maximumReconnectAttempts: 0, baseDelayMilliseconds: 0),
            nowMilliseconds: { now }
        )
        return .init(
            connector: connector,
            request: pending.request,
            token: String(repeating: "t", count: 48),
            outbox: outbox,
            artifacts: artifacts,
            cursor: cursor,
            sockets: sockets,
            terminalFrame: terminal,
            metadata: metadata
        )
    }

    private func makePendingTurn(
        connectionID: UUID,
        conversationID: UUID,
        turnID: UUID,
        createdAt: Int64
    ) throws -> AgentConnectorPendingTurn {
        let messageID = UUID()
        let userMessageID = UUID()
        let assistantMessageID = UUID()
        let userText = "Saved remote message"
        let encodedText = try encodedFrame(
            kind: "turn.submit",
            seq: 1,
            connectionID: connectionID,
            conversationID: conversationID,
            messageID: messageID,
            payload: .init(
                turnID: turnID.uuidString.lowercased(),
                accountID: "primary",
                capabilities: ["activity-v1", "attachments-v1", "work-v1"],
                text: userText
            )
        )
        return try AgentConnectorPendingTurn(
            v: 1,
            connectionID: connectionID,
            conversationID: conversationID,
            turnID: turnID,
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher",
            userMessageID: userMessageID,
            assistantMessageID: assistantMessageID,
            userText: userText,
            createdAtMilliseconds: createdAt,
            expiresAtMilliseconds: createdAt
                + AgentConnectorPendingTurn.maximumLifetimeMilliseconds,
            submitFrame: .init(sequence: 1, messageID: messageID, text: encodedText),
            submitDurablyPersisted: true,
            turnAccepted: false,
            cancelFrame: nil,
            terminal: nil
        ).validated()
    }

    private func makeAttachmentMetadata(
        connectionID: UUID,
        turnID: UUID,
        attachmentID: UUID = UUID(),
        expiresAt: Int64
    ) -> AgentConnectorAttachmentMetadata {
        .init(
            connectionID: connectionID,
            turnID: turnID,
            attachmentID: attachmentID,
            fileName: "generated.png",
            mediaType: "image/png",
            byteCount: 4,
            sha256: String(repeating: "a", count: 64),
            expiresAtMilliseconds: expiresAt
        )
    }

    private func makeAttachmentFrame(
        seq: Int,
        conversationID: UUID,
        metadata: AgentConnectorAttachmentMetadata
    ) throws -> String {
        try encodedFrame(
            kind: "assistant.attachment",
            seq: seq,
            connectionID: metadata.connectionID,
            conversationID: conversationID,
            payload: .init(
                turnID: metadata.turnID.uuidString.lowercased(),
                attachmentID: metadata.attachmentID.uuidString.lowercased(),
                fileName: metadata.fileName,
                mediaType: metadata.mediaType,
                byteCount: metadata.byteCount,
                sha256: metadata.sha256,
                downloadPath: metadata.downloadPath,
                expiresAt: metadata.expiresAtMilliseconds
            )
        )
    }

    private func makeArtifactDownloadFixture(
        contentLengthOffset: Int?
    ) throws -> ArtifactDownloadFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("download.jpeg")
        let bytes = Data("verified jpeg fixture".utf8)
        try bytes.write(to: source)
        let connectionID = UUID()
        let attachmentID = UUID()
        let metadata = AgentConnectorAttachmentMetadata(
            connectionID: connectionID,
            turnID: UUID(),
            attachmentID: attachmentID,
            fileName: "ara.jpeg",
            mediaType: "image/jpeg",
            byteCount: bytes.count,
            sha256: SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }
                .joined(),
            expiresAtMilliseconds: 60_000
        )
        let origin = try AgentConnectorOrigin("https://bridge.example.com")
        let artifactsRoot = directory.appendingPathComponent("artifacts", isDirectory: true)
        let contentLength = contentLengthOffset.map { Int64(bytes.count + $0) }
        let service = OpenClawAgentConnectorArtifactService(
            origin: origin,
            transport: FixedArtifactTransport(transfer: .init(
                temporaryURL: source,
                responseURL: origin.attachmentURL(
                    connectionID: connectionID,
                    attachmentID: attachmentID
                ),
                statusCode: 200,
                contentType: metadata.mediaType,
                contentLength: contentLength
            )),
            store: AgentConnectorArtifactStore(rootURL: artifactsRoot),
            nowMilliseconds: { 1_000 }
        )
        return .init(
            directory: directory,
            artifactsRoot: artifactsRoot,
            bytes: bytes,
            metadata: metadata,
            service: service
        )
    }

    private func persistTestArtifact(
        store: AgentConnectorArtifactStore,
        connectionID: UUID,
        attachmentID: UUID,
        bytes: Data,
        storedAt: Int64
    ) throws -> AgentConnectorStoredAttachment {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary)
        let sha = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let metadata = AgentConnectorAttachmentMetadata(
            connectionID: connectionID,
            turnID: UUID(),
            attachmentID: attachmentID,
            fileName: "result.bin",
            mediaType: "application/octet-stream",
            byteCount: bytes.count,
            sha256: sha,
            expiresAtMilliseconds: 10_000
        )
        return try store.persist(
            temporaryURL: temporary,
            metadata: metadata,
            storedAtMilliseconds: storedAt
        )
    }

    private func conversationDescriptor(
        _ stored: AgentConnectorStoredAttachment
    ) -> ConversationAttachmentDescriptor {
        .init(
            id: stored.metadata.attachmentID,
            kind: .file,
            displayName: stored.metadata.fileName,
            mimeType: stored.metadata.mediaType,
            sourceByteCount: stored.metadata.byteCount,
            connectorArtifact: stored.metadata.conversationReference
        )
    }

    private func makeBinding() -> AvatarAgentConnectorBinding {
        .init(
            connectorID: .openClaw,
            connectionID: UUID(),
            accountID: "primary",
            agentID: "researcher",
            displayName: "Researcher"
        )
    }

    private func makeCompletedFrame(
        seq: Int,
        connectionID: UUID,
        conversationID: UUID,
        turnID: UUID
    ) -> AgentConnectorWireFrame {
        .init(
            v: 1,
            kind: "assistant.completed",
            connectionID: connectionID.uuidString.lowercased(),
            conversationID: conversationID.uuidString.lowercased(),
            messageID: UUID().uuidString.lowercased(),
            seq: seq,
            replyTo: nil,
            sentAt: 1,
            payload: .init(
                turnID: turnID.uuidString.lowercased(),
                text: "Old reply"
            )
        )
    }

    private func encodedFrame(
        kind: String,
        seq: Int,
        connectionID: UUID,
        conversationID: UUID,
        messageID: UUID = UUID(),
        payload: AgentConnectorWirePayload
    ) throws -> String {
        let frame = AgentConnectorWireFrame(
            v: 1,
            kind: kind,
            connectionID: connectionID.uuidString.lowercased(),
            conversationID: conversationID.uuidString.lowercased(),
            messageID: messageID.uuidString.lowercased(),
            seq: seq,
            replyTo: nil,
            sentAt: 1,
            payload: payload
        )
        return try XCTUnwrap(String(data: JSONEncoder().encode(frame), encoding: .utf8))
    }
}

private struct InjectedConnectorHistoryFailure: Error {}

private struct ArtifactDownloadFixture {
    let directory: URL
    let artifactsRoot: URL
    let bytes: Data
    let metadata: AgentConnectorAttachmentMetadata
    let service: OpenClawAgentConnectorArtifactService
}

private struct FixedArtifactTransport: AgentConnectorArtifactTransporting {
    let transfer: AgentConnectorArtifactTransfer

    func download(_ request: URLRequest) async throws -> AgentConnectorArtifactTransfer {
        transfer
    }
}

private struct CancelledArtifactTransport: AgentConnectorArtifactTransporting {
    func download(_ request: URLRequest) async throws -> AgentConnectorArtifactTransfer {
        throw CancellationError()
    }
}

private actor ConnectorDownloadGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var released = false
    private(set) var wasCancelled = false

    func wait() async throws {
        try Task.checkCancellation()
        if released { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    wasCancelled = true
                    pending.resume(throwing: CancellationError())
                } else {
                    continuation = pending
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        wasCancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private final class ConnectorHistoryFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOperation: ConversationHistoryStore.IOOperation?

    var operation: ConversationHistoryStore.IOOperation? {
        get { lock.withLock { storedOperation } }
        set { lock.withLock { storedOperation = newValue } }
    }

    func check(_ operation: ConversationHistoryStore.IOOperation) throws {
        if lock.withLock({ storedOperation == operation }) {
            throw InjectedConnectorHistoryFailure()
        }
    }
}

private final class ConnectorTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var operations: [String] { lock.withLock { values } }

    func record(_ value: String) {
        lock.withLock { values.append(value) }
    }
}

private final class RecordingAgentConnectorOutboxVault:
    AgentConnectorOutboxVault,
    @unchecked Sendable {
    private let storage = InMemoryAgentConnectorOutboxVault()
    private let recorder: ConnectorTestRecorder

    init(recorder: ConnectorTestRecorder) {
        self.recorder = recorder
    }

    func save(_ turn: AgentConnectorPendingTurn) throws {
        try storage.save(turn)
        if turn.attachments?.isEmpty == false {
            recorder.record("persist-attachment")
        }
    }

    func load(connectionID: UUID, turnID: UUID) throws -> AgentConnectorPendingTurn? {
        try storage.load(connectionID: connectionID, turnID: turnID)
    }

    func loadAll() throws -> [AgentConnectorPendingTurn] {
        try storage.loadAll()
    }

    func delete(connectionID: UUID, turnID: UUID) throws {
        try storage.delete(connectionID: connectionID, turnID: turnID)
    }
}

private final class RecordingArtifactService:
    AgentConnectorArtifactServicing,
    @unchecked Sendable {
    private let lock = NSLock()
    private let recorder: ConnectorTestRecorder?
    private let downloadGate: ConnectorDownloadGate?
    private var downloads = 0
    private var deleted: [ConversationConnectorArtifactReference] = []

    init(
        recorder: ConnectorTestRecorder? = nil,
        downloadGate: ConnectorDownloadGate? = nil
    ) {
        self.recorder = recorder
        self.downloadGate = downloadGate
    }

    var downloadCount: Int { lock.withLock { downloads } }
    var deletedReferences: [ConversationConnectorArtifactReference] {
        lock.withLock { deleted }
    }

    func storedAttachment(
        for metadata: AgentConnectorAttachmentMetadata
    ) throws -> AgentConnectorStoredAttachment {
        try AgentConnectorStoredAttachment(
            metadata: metadata,
            assetKey: metadata.connectionID.uuidString.lowercased()
                + "/" + metadata.attachmentID.uuidString.lowercased()
                + "/content.png"
        ).validated()
    }

    func downloadAndStore(
        _ metadata: AgentConnectorAttachmentMetadata,
        clientToken: String
    ) async throws -> AgentConnectorStoredAttachment {
        _ = try AgentConnectorTokenValidator.normalized(clientToken)
        lock.withLock { downloads += 1 }
        recorder?.record("download")
        try await downloadGate?.wait()
        try Task.checkCancellation()
        return try storedAttachment(for: metadata)
    }

    func storedURL(for reference: ConversationConnectorArtifactReference) async -> URL? {
        nil
    }

    func deleteArtifacts(_ references: [ConversationConnectorArtifactReference]) async {
        lock.withLock { deleted.append(contentsOf: references) }
    }

    func deleteArtifacts(connectionID: UUID) async {}
    func pruneInvalidArtifacts() async {}
    func reconcileArtifacts(
        retaining references: [ConversationConnectorArtifactReference]
    ) async {}
}

private struct StubPairingService: AgentConnectorPairingServicing {
    let response: AgentConnectorPairingRedeemResponse

    func redeem(
        code: String,
        installationID: UUID,
        deviceLabel: String
    ) async throws -> AgentConnectorPairingRedeemResponse {
        response
    }
}

private struct StubAgentConnector: AgentConnector {
    func streamTurn(
        _ request: AgentConnectorTurnRequest,
        clientToken: String
    ) -> AsyncThrowingStream<AgentConnectorStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.submissionSaved)
            continuation.yield(.accepted)
            continuation.yield(.cumulativeText("Hel"))
            continuation.yield(.cumulativeText("Hello"))
            continuation.yield(.completed("Hello"))
            continuation.finish()
        }
    }
}

private final class ControlledStreamingAgentConnector:
    AgentConnector,
    @unchecked Sendable {
    private typealias StreamContinuation =
        AsyncThrowingStream<AgentConnectorStreamEvent, Error>.Continuation

    private let lock = NSLock()
    private var continuation: StreamContinuation?

    var hasSubscriber: Bool {
        lock.withLock { continuation != nil }
    }

    func streamTurn(
        _ request: AgentConnectorTurnRequest,
        clientToken: String
    ) -> AsyncThrowingStream<AgentConnectorStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            continuation.yield(.submissionSaved)
        }
    }

    func yield(_ event: AgentConnectorStreamEvent) {
        lock.withLock { continuation }?.yield(event)
    }

    func finish() {
        let continuation: StreamContinuation? = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }
}

private struct LiveTalkAgentStubConnector: AgentConnector {
    func streamTurn(
        _ request: AgentConnectorTurnRequest,
        clientToken: String
    ) -> AsyncThrowingStream<AgentConnectorStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.submissionSaved)
            continuation.yield(.accepted)
            continuation.yield(.work(.init(
                revision: 1,
                stepID: "approval:nearby-search",
                category: .approval,
                state: .waiting,
                title: "Review nearby search",
                detail: "Approval remains visible on the OpenClaw host.",
                tool: nil,
                command: nil,
                path: nil,
                output: nil
            )))
            continuation.yield(.completed(
                "[laughing] The [nearest result](https://example.com) is on Main Street."
            ))
            continuation.finish()
        }
    }
}

private struct HangingStubAgentConnector: AgentConnector {
    func streamTurn(
        _ request: AgentConnectorTurnRequest,
        clientToken: String
    ) -> AsyncThrowingStream<AgentConnectorStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                continuation.finish()
            }
        }
    }
}

private struct PairingRequiredStubAgentConnector: AgentConnector {
    func streamTurn(
        _ request: AgentConnectorTurnRequest,
        clientToken: String
    ) -> AsyncThrowingStream<AgentConnectorStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.submissionSaved)
            continuation.finish(throwing: AgentConnectorError.pairingRequired)
        }
    }
}

private final class StubRevocationService: AgentConnectorRevocationServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail: Bool
    private var capturedToken: String?

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    var lastToken: String? { lock.withLock { capturedToken } }

    func setShouldFail(_ value: Bool) {
        lock.withLock { shouldFail = value }
    }

    func revoke(connectionID: UUID, clientToken: String) async throws {
        let fails = lock.withLock {
            capturedToken = clientToken
            return shouldFail
        }
        if fails { throw AgentConnectorError.revocationUnavailable }
    }
}

private enum ScriptedSocketStep {
    case text(String)
    case disconnect
    case persistenceReceiptForLastSubmit
    case persistenceReceiptForLastCancel
    case workerCancelledTerminalForLastCancel(seq: Int)
    case waitForCancellation
}

private final class PairingRequiredOnSendSocketConnector:
    AgentConnectorSocketConnecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var count = 0

    var connectionCount: Int { lock.withLock { count } }

    func connect(
        request: URLRequest,
        maximumMessageBytes: Int
    ) throws -> any AgentConnectorSocket {
        lock.withLock { count += 1 }
        return PairingRequiredOnSendSocket()
    }
}

private final class PairingRequiredOnSendSocket: AgentConnectorSocket, @unchecked Sendable {
    func send(text: String) async throws {
        throw AgentConnectorError.pairingRequired
    }

    func receiveText() async throws -> String {
        throw AgentConnectorError.invalidFrame
    }

    func close() {}
}

private final class ScriptedSocketConnector: AgentConnectorSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[ScriptedSocketStep]]
    private let recorder: ConnectorTestRecorder?
    private var sockets: [ScriptedSocket] = []
    private var capturedRequests: [URLRequest] = []

    init(
        scripts: [[ScriptedSocketStep]],
        recorder: ConnectorTestRecorder? = nil
    ) {
        self.scripts = scripts
        self.recorder = recorder
    }

    var connectionCount: Int { lock.withLock { sockets.count } }
    var closedSocketCount: Int { lock.withLock { sockets.filter(\.closed).count } }
    var requests: [URLRequest] { lock.withLock { capturedRequests } }
    var sentTexts: [String] { lock.withLock { sockets.flatMap(\.sentTexts) } }
    var sentFrames: [AgentConnectorWireFrame] {
        sentTexts.compactMap { text in
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(AgentConnectorWireFrame.self, from: data)
        }
    }

    func connect(
        request: URLRequest,
        maximumMessageBytes: Int
    ) throws -> any AgentConnectorSocket {
        try lock.withLock {
            guard !scripts.isEmpty else {
                throw AgentConnectorError.connectionUnavailable
            }
            let socket = ScriptedSocket(
                steps: scripts.removeFirst(),
                recorder: recorder
            )
            capturedRequests.append(request)
            sockets.append(socket)
            return socket
        }
    }
}

private final class ScriptedSocket: AgentConnectorSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [ScriptedSocketStep]
    private var sent: [String] = []
    private var isClosed = false
    private let recorder: ConnectorTestRecorder?

    init(
        steps: [ScriptedSocketStep],
        recorder: ConnectorTestRecorder? = nil
    ) {
        self.steps = steps
        self.recorder = recorder
    }

    var sentTexts: [String] { lock.withLock { sent } }
    var closed: Bool { lock.withLock { isClosed } }

    func send(text: String) async throws {
        try lock.withLock {
            guard !isClosed else {
                throw AgentConnectorError.connectionUnavailable
            }
            sent.append(text)
        }
        if let data = text.data(using: .utf8),
           let frame = try? JSONDecoder().decode(AgentConnectorWireFrame.self, from: data),
           frame.kind == "ack",
           let sequence = frame.payload.ackSeq {
            recorder?.record("ack-\(sequence)")
        }
    }

    func receiveText() async throws -> String {
        let step: ScriptedSocketStep = try lock.withLock {
            guard !isClosed, !steps.isEmpty else {
                throw AgentConnectorError.connectionUnavailable
            }
            return steps.removeFirst()
        }
        switch step {
        case let .text(text):
            return text
        case .disconnect:
            throw AgentConnectorError.connectionUnavailable
        case .persistenceReceiptForLastSubmit:
            return try persistenceReceipt(for: "turn.submit")
        case .persistenceReceiptForLastCancel:
            return try persistenceReceipt(for: "turn.cancel")
        case let .workerCancelledTerminalForLastCancel(seq):
            let cancel = try lastSentFrame(for: "turn.cancel")
            let terminal = AgentConnectorWireFrame(
                v: 1,
                kind: "turn.error",
                connectionID: cancel.connectionID,
                conversationID: cancel.conversationID,
                messageID: UUID().uuidString.lowercased(),
                seq: seq,
                replyTo: nil,
                sentAt: cancel.sentAt,
                payload: .init(
                    turnID: cancel.payload.turnID,
                    code: "cancelled",
                    message: "The turn was cancelled.",
                    retryable: false
                )
            )
            return String(decoding: try JSONEncoder().encode(terminal), as: UTF8.self)
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(30))
            throw AgentConnectorError.connectionUnavailable
        }
    }

    private func persistenceReceipt(for kind: String) throws -> String {
        let frame = try lastSentFrame(for: kind)
        let receipt: [String: Any] = [
            "v": 1,
            "kind": "relay.persisted",
            "connectionId": frame.connectionID,
            "payload": [
                "senderSeq": frame.seq,
                "messageId": frame.messageID,
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: receipt), as: UTF8.self)
    }

    private func lastSentFrame(for kind: String) throws -> AgentConnectorWireFrame {
        let frameText = try lock.withLock {
                guard let frameText = sent.reversed().first(where: { text in
                    guard let data = text.data(using: .utf8),
                          let frame = try? JSONDecoder().decode(
                            AgentConnectorWireFrame.self,
                            from: data
                          ) else { return false }
                    return frame.kind == kind
                }) else {
                    throw AgentConnectorError.invalidFrame
                }
                return frameText
            }
            guard let data = frameText.data(using: .utf8),
                  let frame = try? JSONDecoder().decode(
                    AgentConnectorWireFrame.self,
                    from: data
                  ) else {
                throw AgentConnectorError.invalidFrame
            }
            return frame
    }

    func close() {
        lock.withLock { isClosed = true }
    }
}
