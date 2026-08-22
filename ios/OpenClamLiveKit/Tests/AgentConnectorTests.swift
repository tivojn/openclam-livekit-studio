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
            [.accepted, .cumulativeText("Hel"), .cumulativeText("Hello"), .completed("Hello")]
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
            [.accepted, .cumulativeText("Hel"), .completed("Hello")]
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

        XCTAssertEqual(events, [.accepted, .completed("Stored once")])
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

        XCTAssertEqual(events, [.accepted, .completed("Completed")])
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

        XCTAssertEqual(events, [.accepted, .completed("Recovered")])
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

        XCTAssertEqual(events, [.accepted, .completed("Ran once")])
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

    func testCancellationReconnectsAndReplaysExactCancelUntilPersisted() async throws {
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
            [.persistenceReceiptForLastCancel],
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

        XCTAssertNil(try outbox.load(connectionID: connectionID, turnID: turnID))
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
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertNil(try outbox.load(connectionID: connectionID, turnID: turnID))
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
            continuation.yield(.accepted)
            continuation.yield(.cumulativeText("Hel"))
            continuation.yield(.cumulativeText("Hello"))
            continuation.yield(.completed("Hello"))
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
    case waitForCancellation
}

private final class ScriptedSocketConnector: AgentConnectorSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[ScriptedSocketStep]]
    private var sockets: [ScriptedSocket] = []
    private var capturedRequests: [URLRequest] = []

    init(scripts: [[ScriptedSocketStep]]) {
        self.scripts = scripts
    }

    var connectionCount: Int { lock.withLock { sockets.count } }
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
            let socket = ScriptedSocket(steps: scripts.removeFirst())
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

    init(steps: [ScriptedSocketStep]) {
        self.steps = steps
    }

    var sentTexts: [String] { lock.withLock { sent } }

    func send(text: String) async throws {
        try lock.withLock {
            guard !isClosed else {
                throw AgentConnectorError.connectionUnavailable
            }
            sent.append(text)
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
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(30))
            throw AgentConnectorError.connectionUnavailable
        }
    }

    private func persistenceReceipt(for kind: String) throws -> String {
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
            let receipt: [String: Any] = [
                "v": 1,
                "kind": "relay.persisted",
                "connectionId": frame.connectionID,
                "payload": [
                    "senderSeq": frame.seq,
                    "messageId": frame.messageID,
                ],
            ]
            let receiptData = try JSONSerialization.data(withJSONObject: receipt)
            guard let receiptText = String(data: receiptData, encoding: .utf8) else {
                throw AgentConnectorError.invalidFrame
            }
            return receiptText
    }

    func close() {
        lock.withLock { isClosed = true }
    }
}
