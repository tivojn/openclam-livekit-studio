import Foundation
import LiveKit

enum LiveTalkBrokerRedirectPolicy {
    /// The session POST can contain user-owned provider credentials. Never allow
    /// Foundation to replay that body to a redirect target, even on 307/308.
    static func requestToFollow(
        response _: HTTPURLResponse,
        proposedRequest _: URLRequest
    ) -> URLRequest? {
        nil
    }
}

final class LiveTalkBrokerNoRedirectSessionDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            LiveTalkBrokerRedirectPolicy.requestToFollow(
                response: response,
                proposedRequest: request
            )
        )
    }
}

typealias LiveTalkBrokerRequestPerformer = @Sendable (URLRequest) async throws -> (
    Data,
    URLResponse
)

struct LiveTalkAppConfiguration: Equatable, Sendable {
    static let brokerInfoKey = "OPENCLAM_LIVETALK_BROKER_URL"
    static let appTokenInfoKey = "OPENCLAM_LIVETALK_APP_TOKEN"
    static let expectedServerHostInfoKey = "OPENCLAM_LIVETALK_EXPECTED_SERVER_HOST"

    let sessionEndpoint: URL
    let appToken: String
    let expectedServerHost: String

    static func load(bundle: Bundle = .main) throws -> Self {
        try validated(
            rawURL: bundle.object(forInfoDictionaryKey: brokerInfoKey),
            rawToken: bundle.object(forInfoDictionaryKey: appTokenInfoKey),
            rawExpectedServerHost: bundle.object(
                forInfoDictionaryKey: expectedServerHostInfoKey
            )
        )
    }

    static func validated(
        rawURL: Any?,
        rawToken: Any?,
        rawExpectedServerHost: Any?
    ) throws -> Self {
        let rawURL = normalized(rawURL)
        let token = normalized(rawToken)
        let expectedServerHost = normalized(rawExpectedServerHost)
        guard let endpoint = URL(string: rawURL),
              endpoint.scheme?.lowercased() == "https",
              endpoint.host?.isEmpty == false,
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil,
              endpoint.path == "/v1/live-talk/sessions" else {
            throw LiveTalkBrokerError.notConfigured
        }
        guard token.utf8.count >= 32,
              token.utf8.count <= 4_096,
              !token.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw LiveTalkBrokerError.notConfigured
        }
        guard isValidLowercaseDNSHost(expectedServerHost) else {
            throw LiveTalkBrokerError.notConfigured
        }
        return .init(
            sessionEndpoint: endpoint,
            appToken: token,
            expectedServerHost: expectedServerHost
        )
    }

    private static func normalized(_ value: Any?) -> String {
        guard let value = value as? String else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("$(") else { return "" }
        return trimmed
    }

    private static func isValidLowercaseDNSHost(_ value: String) -> Bool {
        guard value == value.lowercased(), value.utf8.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { byte in
                (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
            }
        }
    }
}

struct LiveTalkBrokerStageSelection: Encodable, Equatable, Sendable {
    let source: LiveTalkCredentialSource
    let provider: String
    let model: String
    let voice: String?
    let language: String?

    init(_ selection: LiveTalkStageSelection) {
        source = selection.source
        provider = selection.provider
        model = selection.model
        voice = selection.voice
        language = selection.language
    }
}

struct LiveTalkBrokerPersona: Encodable, Equatable, Sendable {
    static let maximumNameUTF8Bytes = 80
    static let maximumInstructionsUTF8Bytes = 4_096

    let name: String
    let instructions: String

    init(profile: AvatarAgentProfile) {
        name = LiveTalkBrokerText.utf8Prefix(
            profile.displayName,
            maximumBytes: Self.maximumNameUTF8Bytes
        )
        var sections = [
            "Have a warm, natural, concise voice conversation. Reply in the language the user is speaking unless they ask you to switch. Live Talk can only ask foreground OpenClam to prepare a visible, editable, unsent email draft from a new explicit spoken email request. It cannot read Contacts, confirm, open Mail, send, or access ordinary chat history, so never claim that it can.",
        ]
        if !profile.systemPrompt.isEmpty {
            sections.append(profile.systemPrompt)
        }
        if !profile.userPrompt.isEmpty {
            sections.append("User preference: \(profile.userPrompt)")
        }
        instructions = LiveTalkBrokerText.utf8Prefix(
            sections.joined(separator: "\n\n"),
            maximumBytes: Self.maximumInstructionsUTF8Bytes
        )
    }
}

enum LiveTalkBrokerText {
    static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard value.utf8.count > maximumBytes else { return value }

        var result = ""
        var byteCount = 0
        for character in value {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= maximumBytes else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }
}

struct LiveTalkBrokerProfile: Encodable, Equatable, Sendable {
    let llm: LiveTalkBrokerStageSelection
    let stt: LiveTalkBrokerStageSelection
    let tts: LiveTalkBrokerStageSelection
    let persona: LiveTalkBrokerPersona

    init(configuration: LiveTalkConfiguration, avatar: AvatarAgentProfile) {
        llm = .init(configuration.llm)
        stt = .init(configuration.stt)
        tts = .init(configuration.tts)
        persona = .init(profile: avatar)
    }
}

/// Encoding-only by design: secrets can be serialized only for the one HTTPS request and cannot
/// be decoded into the app's persistent settings model.
struct LiveTalkBrokerCredential: Encodable, Sendable {
    let apiKey: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
    }
}

struct LiveTalkBrokerCredentials: Encodable, Sendable {
    let llm: LiveTalkBrokerCredential?
    let stt: LiveTalkBrokerCredential?
    let tts: LiveTalkBrokerCredential?
}

struct LiveTalkSessionStartPayload: Encodable, Sendable {
    let participantName: String
    let profile: LiveTalkBrokerProfile
    let credentials: LiveTalkBrokerCredentials

    enum CodingKeys: String, CodingKey {
        case participantName = "participant_name"
        case profile
        case credentials
    }
}

struct LiveTalkSessionRequestBuilder: Sendable {
    let credentialVault: ProviderCredentialVault

    func validateCredentialAvailability(for configuration: LiveTalkConfiguration) throws {
        let configuration = try configuration.validated()
        for stage in LiveTalkStage.allCases {
            let selection = configuration[stage]
            guard selection.source == .byok else { continue }
            guard let option = LiveTalkCatalog.option(matching: selection, for: stage),
                  let provider = option.credentialProvider else {
                throw LiveTalkBrokerError.invalidProfile
            }
            guard try credentialVault.containsCredential(for: provider) else {
                throw LiveTalkBrokerError.missingCredential(stage, provider)
            }
        }
    }

    func makePayload(
        avatar: AvatarAgentProfile,
        configuration: LiveTalkConfiguration,
        participantName: String = "OpenClam User"
    ) throws -> LiveTalkSessionStartPayload {
        let avatar = try avatar.validated()
        let configuration = try configuration.validated()
        let normalizedParticipantName = participantName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedParticipantName.isEmpty,
              normalizedParticipantName.count <= 80,
              normalizedParticipantName.utf8.count <= 80 else {
            throw LiveTalkBrokerError.invalidProfile
        }

        return .init(
            participantName: normalizedParticipantName,
            profile: .init(configuration: configuration, avatar: avatar),
            credentials: .init(
                llm: try credential(for: .llm, selection: configuration.llm),
                stt: try credential(for: .stt, selection: configuration.stt),
                tts: try credential(for: .tts, selection: configuration.tts)
            )
        )
    }

    private func credential(
        for stage: LiveTalkStage,
        selection: LiveTalkStageSelection
    ) throws -> LiveTalkBrokerCredential? {
        guard selection.source == .byok else { return nil }
        guard let option = LiveTalkCatalog.option(matching: selection, for: stage),
              let provider = option.credentialProvider else {
            throw LiveTalkBrokerError.invalidProfile
        }
        guard let apiKey = try credentialVault.loadCredential(for: provider) else {
            throw LiveTalkBrokerError.missingCredential(stage, provider)
        }
        return .init(apiKey: apiKey)
    }
}

final class LiveTalkBrokerTokenSource: TokenSourceFixed, @unchecked Sendable {
    private let configuration: LiveTalkAppConfiguration
    private let avatar: AvatarAgentProfile
    private let liveTalkConfiguration: LiveTalkConfiguration
    private let requestBuilder: LiveTalkSessionRequestBuilder
    private let requestPerformer: LiveTalkBrokerRequestPerformer
    private let lock = NSLock()
    private var consumed = false

    init(
        configuration: LiveTalkAppConfiguration,
        avatar: AvatarAgentProfile,
        liveTalkConfiguration: LiveTalkConfiguration,
        credentialVault: ProviderCredentialVault,
        requestPerformer: @escaping LiveTalkBrokerRequestPerformer =
            LiveTalkBrokerTokenSource.performRequest
    ) {
        self.configuration = configuration
        self.avatar = avatar
        self.liveTalkConfiguration = liveTalkConfiguration
        self.requestPerformer = requestPerformer
        requestBuilder = .init(credentialVault: credentialVault)
    }

    func fetch() async throws -> TokenSourceResponse {
        let mayProceed = lock.withLock {
            guard !consumed else { return false }
            consumed = true
            return true
        }
        guard mayProceed else { throw LiveTalkBrokerError.requestAlreadyUsed }

        let payload = try requestBuilder.makePayload(
            avatar: avatar,
            configuration: liveTalkConfiguration
        )
        var request = URLRequest(
            url: configuration.sessionEndpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(
            "Bearer \(configuration.appToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestPerformer(request)
        } catch {
            throw LiveTalkBrokerError.connectionFailed
        }
        guard data.count <= 16_384,
              let http = response as? HTTPURLResponse else {
            throw LiveTalkBrokerError.invalidResponse
        }
        guard http.statusCode == 201 else {
            switch http.statusCode {
            case 401, 403:
                throw LiveTalkBrokerError.accessRejected
            case 429:
                throw LiveTalkBrokerError.rateLimited
            case 500 ... 599:
                throw LiveTalkBrokerError.serviceUnavailable
            default:
                throw LiveTalkBrokerError.sessionRejected
            }
        }
        do {
            let value = try JSONDecoder().decode(SessionResponse.self, from: data)
            let serverURL = try Self.validatedServerURL(
                value.serverURL,
                expectedHost: configuration.expectedServerHost
            )
            guard !value.participantToken.isEmpty,
                  value.participantToken.utf8.count <= 16_000 else {
                throw LiveTalkBrokerError.invalidResponse
            }
            return .init(
                serverURL: serverURL,
                participantToken: value.participantToken
            )
        } catch let error as LiveTalkBrokerError {
            throw error
        } catch {
            throw LiveTalkBrokerError.invalidResponse
        }
    }

    static func performRequest(_ request: URLRequest) async throws -> (
        Data,
        URLResponse
    ) {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: LiveTalkBrokerNoRedirectSessionDelegate(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    static func validatedServerURL(
        _ rawValue: String,
        expectedHost: String
    ) throws -> URL {
        let securePrefix = "wss://"
        let authority = rawValue.dropFirst(securePrefix.count).prefix { character in
            character != "/" && character != "?" && character != "#"
        }
        guard rawValue.hasPrefix(securePrefix),
              authority == expectedHost || authority == "\(expectedHost):443",
              let components = URLComponents(string: rawValue),
              components.scheme == "wss",
              components.host == expectedHost,
              components.host == components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port == nil || components.port == 443,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              let url = components.url else {
            throw LiveTalkBrokerError.invalidResponse
        }
        return url
    }

    private struct SessionResponse: Decodable {
        let serverURL: String
        let participantToken: String

        enum CodingKeys: String, CodingKey {
            case serverURL = "server_url"
            case participantToken = "participant_token"
        }
    }
}

enum LiveTalkBrokerError: LocalizedError, Equatable {
    case notConfigured
    case invalidProfile
    case missingCredential(LiveTalkStage, AIProviderID)
    case requestAlreadyUsed
    case connectionFailed
    case accessRejected
    case rateLimited
    case serviceUnavailable
    case sessionRejected
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "This build is missing its Live Talk access setup. Install a newer pilot build or contact the pilot owner."
        case .invalidProfile:
            "This avatar's Live Talk choices are invalid. Choose them again."
        case let .missingCredential(stage, provider):
            "Save a \(AIProviderRegistry.descriptor(for: provider).displayName) API key before using it for \(stage.title.lowercased())."
        case .requestAlreadyUsed:
            "This one-time Live Talk request has already been used. Start a new session."
        case .connectionFailed:
            "OpenClam could not reach the Live Talk service. Check your internet connection and try again."
        case .accessRejected:
            "This build's Live Talk access was rejected. Install the current pilot build or contact the pilot owner."
        case .rateLimited:
            "Live Talk is temporarily busy. Wait a moment, then try again."
        case .serviceUnavailable:
            "The Live Talk service is temporarily unavailable. Try again shortly."
        case .sessionRejected:
            "The Live Talk service could not start this session. Check the avatar's Live Talk choices and try again."
        case .invalidResponse:
            "The Live Talk service returned an invalid connection response."
        }
    }
}
