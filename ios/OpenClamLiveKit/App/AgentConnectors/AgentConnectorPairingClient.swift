import Foundation

protocol AgentConnectorPairingServicing: Sendable {
    func redeem(
        code: String,
        installationID: UUID,
        deviceLabel: String
    ) async throws -> AgentConnectorPairingRedeemResponse
}

protocol AgentConnectorRevocationServicing: Sendable {
    func revoke(connectionID: UUID, clientToken: String) async throws
}

final class AgentConnectorNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct OpenClawPairingClient: AgentConnectorPairingServicing, Sendable {
    static let maximumResponseBytes = 64 * 1_024

    let origin: AgentConnectorOrigin

    func redeem(
        code: String,
        installationID: UUID,
        deviceLabel rawDeviceLabel: String
    ) async throws -> AgentConnectorPairingRedeemResponse {
        let pairingCode = try AgentConnectorPairingCode.validated(code)
        let deviceLabel = rawDeviceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceLabel.isEmpty, deviceLabel.count <= 80,
              !deviceLabel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentConnectorError.invalidPairingResponse
        }
        let requestBody = AgentConnectorPairingRedeemRequest(
            code: pairingCode,
            installationID: installationID,
            deviceLabel: deviceLabel
        )
        var request = URLRequest(url: origin.pairingRedeemURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        let delegate = AgentConnectorNoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url == origin.pairingRedeemURL else {
            throw AgentConnectorError.redirected
        }
        if (300 ... 399).contains(http.statusCode) {
            throw AgentConnectorError.redirected
        }
        if let expectedLength = http.value(forHTTPHeaderField: "Content-Length"),
           let count = Int(expectedLength), count > Self.maximumResponseBytes {
            throw AgentConnectorError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(Self.maximumResponseBytes, 4_096))
        for try await byte in bytes {
            guard data.count < Self.maximumResponseBytes else {
                throw AgentConnectorError.responseTooLarge
            }
            data.append(byte)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(AgentConnectorErrorEnvelope.self, from: data),
               !envelope.error.message.isEmpty,
               envelope.error.message.count <= 160 {
                throw AgentConnectorError.remote(
                    code: envelope.error.code,
                    message: envelope.error.message
                )
            }
            throw AgentConnectorError.connectionUnavailable
        }
        return try JSONDecoder().decode(AgentConnectorPairingRedeemResponse.self, from: data)
    }
}

struct OpenClawRevocationClient: AgentConnectorRevocationServicing, Sendable {
    static let maximumResponseBytes = 64 * 1_024

    let origin: AgentConnectorOrigin

    func revoke(connectionID: UUID, clientToken rawClientToken: String) async throws {
        let clientToken = try AgentConnectorTokenValidator.normalized(rawClientToken)
        let expectedURL = origin.connectorURL(connectionID: connectionID)
        var request = URLRequest(url: expectedURL)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(clientToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        let delegate = AgentConnectorNoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url == expectedURL else {
            throw AgentConnectorError.redirected
        }
        if (300 ... 399).contains(http.statusCode) {
            throw AgentConnectorError.redirected
        }
        if let expectedLength = http.value(forHTTPHeaderField: "Content-Length"),
           let count = Int(expectedLength), count > Self.maximumResponseBytes {
            throw AgentConnectorError.responseTooLarge
        }
        var count = 0
        for try await _ in bytes {
            count += 1
            guard count <= Self.maximumResponseBytes else {
                throw AgentConnectorError.responseTooLarge
            }
        }
        guard http.statusCode == 204 || http.statusCode == 404 else {
            throw AgentConnectorError.revocationUnavailable
        }
    }
}
