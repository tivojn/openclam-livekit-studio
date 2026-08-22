import Foundation
import UIKit

enum AgentConnectorApplicationConfiguration {
    static func origin(bundle: Bundle = .main) -> AgentConnectorOrigin? {
        guard let rawValue = bundle.object(
            forInfoDictionaryKey: "OPENCLAM_AGENT_CONNECTOR_ORIGIN"
        ) as? String else { return nil }
        return try? AgentConnectorOrigin(rawValue)
    }
}

@MainActor
final class AgentConnectionModel: ObservableObject {
    @Published private(set) var connections: [AgentConnectorConnection]
    @Published private(set) var isPairing = false
    @Published private(set) var revokingConnectionIDs: Set<UUID> = []

    private let defaults: UserDefaults
    private let connectionsKey: String
    private let installationIDKey: String
    private let origin: AgentConnectorOrigin?
    private let pairingService: (any AgentConnectorPairingServicing)?
    private let revocationService: (any AgentConnectorRevocationServicing)?
    private let connector: (any AgentConnector)?
    private let tokenVault: any AgentConnectorTokenVault
    private let outboxVault: any AgentConnectorOutboxVault
    private var activeConnectionIDs: Set<UUID> = []

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "agent.connector.v1",
        origin: AgentConnectorOrigin? = AgentConnectorApplicationConfiguration.origin(),
        pairingService injectedPairingService: (any AgentConnectorPairingServicing)? = nil,
        revocationService injectedRevocationService: (any AgentConnectorRevocationServicing)? = nil,
        connector injectedConnector: (any AgentConnector)? = nil,
        tokenVault injectedTokenVault: (any AgentConnectorTokenVault)? = nil,
        outboxVault injectedOutboxVault: (any AgentConnectorOutboxVault)? = nil
    ) {
        self.defaults = defaults
        connectionsKey = storageKey + ".connections"
        installationIDKey = storageKey + ".installation-id"
        self.origin = origin
        if let origin {
            let resolvedOutbox = injectedOutboxVault
                ?? KeychainAgentConnectorOutboxVault(
                    gatewayOrigin: origin.canonicalString
                )
            pairingService = injectedPairingService ?? OpenClawPairingClient(origin: origin)
            revocationService = injectedRevocationService ?? OpenClawRevocationClient(origin: origin)
            connector = injectedConnector ?? OpenClawAgentConnector(
                origin: origin,
                outboxVault: resolvedOutbox
            )
            tokenVault = injectedTokenVault ?? KeychainAgentConnectorTokenVault(
                gatewayOrigin: origin.canonicalString
            )
            outboxVault = resolvedOutbox
        } else {
            pairingService = injectedPairingService
            revocationService = injectedRevocationService
            connector = injectedConnector
            tokenVault = injectedTokenVault ?? KeychainAgentConnectorTokenVault(
                gatewayOrigin: "unconfigured"
            )
            outboxVault = injectedOutboxVault
                ?? KeychainAgentConnectorOutboxVault(
                    gatewayOrigin: "unconfigured"
                )
        }
        if let data = defaults.data(forKey: connectionsKey),
           let decoded = try? JSONDecoder().decode([AgentConnectorConnection].self, from: data) {
            connections = decoded.compactMap { try? $0.validated() }
        } else {
            connections = []
        }
    }

    var isConfigured: Bool { origin != nil && pairingService != nil && connector != nil }

    var availableBindings: [AvatarAgentConnectorBinding] {
        connections.flatMap { connection in
            connection.accounts.map { connection.binding(for: $0) }
        }
    }

    func connection(for binding: AvatarAgentConnectorBinding) -> AgentConnectorConnection? {
        guard binding.connectorID == .openClaw else { return nil }
        return connections.first { connection in
            connection.connectionID == binding.connectionID
                && connection.connectorID == binding.connectorID
                && connection.accounts.contains {
                    $0.accountID == binding.accountID
                        && $0.agentID == binding.agentID
                }
        }
    }

    @discardableResult
    func redeemPairingCode(_ rawCode: String) async throws -> AgentConnectorConnection {
        guard !isPairing else { throw AgentConnectorError.conversationBusy }
        guard let pairingService else { throw AgentConnectorError.notConfigured }
        isPairing = true
        defer { isPairing = false }
        let response = try await pairingService.redeem(
            code: try AgentConnectorPairingCode.validated(rawCode),
            installationID: installationID(),
            deviceLabel: Self.deviceLabel()
        )
        let result = try response.validated()
        try tokenVault.saveClientToken(
            result.clientToken,
            for: result.connection.connectionID
        )
        connections.removeAll { $0.connectionID == result.connection.connectionID }
        connections.append(result.connection)
        connections.sort {
            if $0.gatewayLabel == $1.gatewayLabel {
                return $0.connectionID.uuidString < $1.connectionID.uuidString
            }
            return $0.gatewayLabel.localizedCaseInsensitiveCompare($1.gatewayLabel) == .orderedAscending
        }
        persistConnections()
        return result.connection
    }

    func disconnect(_ connectionID: UUID) async throws {
        guard !revokingConnectionIDs.contains(connectionID),
              !activeConnectionIDs.contains(connectionID) else {
            throw AgentConnectorError.conversationBusy
        }
        guard try !outboxVault.loadAll().contains(where: {
            $0.connectionID == connectionID
        }) else {
            throw AgentConnectorError.recoveryPending
        }
        guard connections.contains(where: { $0.connectionID == connectionID }) else {
            throw AgentConnectorError.missingConnection
        }
        guard let revocationService else { throw AgentConnectorError.notConfigured }
        guard let clientToken = try tokenVault.loadClientToken(for: connectionID) else {
            throw AgentConnectorError.missingClientToken
        }
        revokingConnectionIDs.insert(connectionID)
        defer { revokingConnectionIDs.remove(connectionID) }
        try await revocationService.revoke(
            connectionID: connectionID,
            clientToken: clientToken
        )
        try tokenVault.deleteClientToken(for: connectionID)
        connections.removeAll { $0.connectionID == connectionID }
        persistConnections()
    }

    func streamTurn(
        binding rawBinding: AvatarAgentConnectorBinding,
        conversationID: UUID,
        turnID: UUID,
        userMessageID: UUID = UUID(),
        assistantMessageID: UUID = UUID(),
        text: String
    ) throws -> AsyncThrowingStream<AgentConnectorStreamEvent, Error> {
        let binding = try rawBinding.validated()
        let request = AgentConnectorTurnRequest(
            connectionID: binding.connectionID,
            conversationID: conversationID,
            turnID: turnID,
            accountID: binding.accountID,
            agentID: binding.agentID,
            displayName: binding.displayName,
            userMessageID: userMessageID,
            assistantMessageID: assistantMessageID,
            text: text
        )
        return try beginStream(
            binding: binding,
            request: request,
            isRecovery: false
        )
    }

    func pendingTurn(for conversationID: UUID) throws -> AgentConnectorPendingTurn? {
        let matches = try outboxVault.loadAll().filter {
            $0.conversationID == conversationID
        }
        guard matches.count <= 1 else {
            throw AgentConnectorError.invalidFrame
        }
        return matches.first
    }

    func pendingTurn(
        connectionID: UUID,
        turnID: UUID
    ) throws -> AgentConnectorPendingTurn? {
        try outboxVault.load(connectionID: connectionID, turnID: turnID)
    }

    func resumePendingTurn(
        _ rawTurn: AgentConnectorPendingTurn
    ) throws -> AsyncThrowingStream<AgentConnectorStreamEvent, Error> {
        let turn = try rawTurn.validated()
        return try beginStream(
            binding: turn.binding,
            request: turn.request,
            isRecovery: true
        )
    }

    func finishPendingTurn(connectionID: UUID, turnID: UUID) throws {
        try outboxVault.delete(connectionID: connectionID, turnID: turnID)
    }

    func cancelPendingTurn(connectionID: UUID, turnID: UUID) async throws {
        guard let turn = try outboxVault.load(
            connectionID: connectionID,
            turnID: turnID
        ) else {
            return
        }
        guard connection(for: turn.binding) != nil else {
            throw AgentConnectorError.missingConnection
        }
        guard let cancellation = connector
            as? any AgentConnectorPersistentCancellation else {
            throw AgentConnectorError.notConfigured
        }
        guard let token = try tokenVault.loadClientToken(
            for: connectionID
        ) else {
            throw AgentConnectorError.missingClientToken
        }
        try await cancellation.cancelTurn(turn.request, clientToken: token)
    }

    private func beginStream(
        binding: AvatarAgentConnectorBinding,
        request: AgentConnectorTurnRequest,
        isRecovery: Bool
    ) throws -> AsyncThrowingStream<AgentConnectorStreamEvent, Error> {
        guard connection(for: binding) != nil else {
            throw AgentConnectorError.missingConnection
        }
        guard !activeConnectionIDs.contains(binding.connectionID) else {
            throw AgentConnectorError.conversationBusy
        }
        let pendingForConnection = try outboxVault.loadAll().filter {
            $0.connectionID == binding.connectionID
        }
        if isRecovery {
            guard pendingForConnection.count == 1,
                  pendingForConnection[0].request == request else {
                throw AgentConnectorError.invalidFrame
            }
        } else if !pendingForConnection.isEmpty {
            throw AgentConnectorError.recoveryPending
        }
        guard let connector else { throw AgentConnectorError.notConfigured }
        guard let token = try tokenVault.loadClientToken(for: binding.connectionID) else {
            throw AgentConnectorError.missingClientToken
        }
        activeConnectionIDs.insert(binding.connectionID)
        let upstream = connector.streamTurn(
            request,
            clientToken: token
        )
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                defer { self?.activeConnectionIDs.remove(binding.connectionID) }
                do {
                    for try await event in upstream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func installationID() -> UUID {
        if let value = defaults.string(forKey: installationIDKey),
           let id = UUID(uuidString: value) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString.lowercased(), forKey: installationIDKey)
        return id
    }

    private func persistConnections() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: connectionsKey)
    }

    private static func deviceLabel() -> String {
        let value = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "iPhone" : String(value.prefix(80))
    }
}
