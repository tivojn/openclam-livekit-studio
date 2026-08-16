import Foundation

struct ProviderModelCatalog: Equatable, Sendable {
    let provider: AIProviderID
    let capability: AICapability
    let modelIDs: [String]
    let refreshedAt: Date
}

protocol ProviderAPITransport: Sendable {
    func send(_ request: URLRequest) async throws -> OpenAITransportResponse
}

extension URLSessionOpenAIResponsesTransport: ProviderAPITransport {}

struct ProviderAPIClient: Sendable {
    private static let maximumResponseBytes = 1_000_000
    private static let maximumCatalogPages = 8
    private static let maximumCatalogModels = 5_000
    private static let maximumCursorCharacters = 1_024
    private static let requestTimeout: TimeInterval = 20

    private let transport: ProviderAPITransport
    private let now: @Sendable () -> Date

    init(
        transport: ProviderAPITransport = URLSessionOpenAIResponsesTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.now = now
    }

    func validateCredential(_ rawCredential: String, for provider: AIProviderID) async throws {
        let credential = try AgentCredentialValidator.normalizedAPIKey(rawCredential)
        if provider == .openRouter || provider == .kieAI || provider == .deepgram {
            _ = try await successfulData(
                for: try credentialValidationRequest(
                    provider: provider,
                    credential: credential
                )
            )
            return
        }
        if AIProviderRegistry.descriptor(for: provider).modelListEndpoint != nil {
            if provider == .soniox {
                do {
                    _ = try await fetchModels(
                        credential: credential,
                        provider: provider,
                        capability: .speechToText
                    )
                } catch {
                    // Soniox can issue capability-restricted keys. Its TTS catalog is a
                    // separate endpoint, so an STT rejection does not prove the key invalid.
                    _ = try await fetchModels(
                        credential: credential,
                        provider: provider,
                        capability: .textToSpeech
                    )
                }
            } else {
                _ = try await fetchModels(credential: credential, provider: provider)
            }
            return
        }
        let request = try validationSearchRequest(provider: provider, credential: credential)
        _ = try await successfulData(for: request)
    }

    func fetchModels(
        credential rawCredential: String,
        provider: AIProviderID
    ) async throws -> ProviderModelCatalog {
        try await fetchModels(
            credential: rawCredential,
            provider: provider,
            capability: preferredCatalogCapability(for: provider)
        )
    }

    func fetchModels(
        credential rawCredential: String,
        provider: AIProviderID,
        capability: AICapability
    ) async throws -> ProviderModelCatalog {
        let credential = try AgentCredentialValidator.normalizedAPIKey(rawCredential)
        guard AIProviderRegistry.descriptor(for: provider).supports(capability) else {
            throw ProviderAPIClientError.modelRefreshUnavailable
        }

        var identifiers: [String] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        var finished = false

        for _ in 0..<Self.maximumCatalogPages {
            let request = try modelListRequest(
                provider: provider,
                capability: capability,
                credential: credential,
                cursor: cursor
            )
            let data = try await successfulData(for: request)
            let page = try decodeModelPage(
                data,
                provider: provider,
                capability: capability
            )
            identifiers.append(contentsOf: page.identifiers)
            guard Set(identifiers).count <= Self.maximumCatalogModels else {
                throw ProviderAPIClientError.catalogLimitExceeded
            }

            guard let nextCursor = page.nextCursor else {
                finished = true
                break
            }
            let normalizedCursor = try validatedCursor(nextCursor)
            guard seenCursors.insert(normalizedCursor).inserted else {
                throw ProviderAPIClientError.invalidPagination
            }
            cursor = normalizedCursor
        }

        guard finished else { throw ProviderAPIClientError.catalogLimitExceeded }
        guard !identifiers.isEmpty else { throw ProviderAPIClientError.emptyModelCatalog }
        return .init(
            provider: provider,
            capability: capability,
            modelIDs: Array(Set(identifiers)).sorted(),
            refreshedAt: now()
        )
    }

    private func modelListRequest(
        provider: AIProviderID,
        capability: AICapability,
        credential: String,
        cursor: String?
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: try modelListEndpoint(provider: provider, capability: capability),
            resolvingAgainstBaseURL: false
        ) else {
            throw ProviderAPIClientError.modelRefreshUnavailable
        }
        switch provider {
        case .anthropic:
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let cursor {
                components.queryItems?.append(.init(name: "after_id", value: cursor))
            }
        case .gemini:
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
            if let cursor {
                components.queryItems?.append(.init(name: "pageToken", value: cursor))
            }
        case .openRouter:
            guard cursor == nil else { throw ProviderAPIClientError.invalidPagination }
            if capability != .imageGeneration, capability != .videoGeneration {
                components.queryItems = [
                    URLQueryItem(
                        name: "output_modalities",
                        value: openRouterOutputModality(for: capability)
                    ),
                ]
            }
        default:
            guard cursor == nil else { throw ProviderAPIClientError.invalidPagination }
        }
        guard let endpoint = components.url else {
            throw ProviderAPIClientError.modelRefreshUnavailable
        }

        var request = boundedRequest(url: endpoint)
        switch provider {
        case .openAI, .xAI, .openRouter, .soniox:
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(credential, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.setValue(credential, forHTTPHeaderField: "x-goog-api-key")
        case .elevenLabs:
            request.setValue(credential, forHTTPHeaderField: "xi-api-key")
        default:
            throw ProviderAPIClientError.modelRefreshUnavailable
        }
        return request
    }

    private func modelListEndpoint(
        provider: AIProviderID,
        capability: AICapability
    ) throws -> URL {
        if provider == .openRouter, capability == .imageGeneration {
            return URL(string: "https://openrouter.ai/api/v1/images/models")!
        }
        if provider == .openRouter, capability == .videoGeneration {
            return URL(string: "https://openrouter.ai/api/v1/videos/models")!
        }
        if provider == .xAI, capability == .llm {
            return URL(string: "https://api.x.ai/v1/language-models")!
        }
        if provider == .xAI {
            throw ProviderAPIClientError.modelRefreshUnavailable
        }
        if provider == .soniox, capability == .textToSpeech {
            return URL(string: "https://api.soniox.com/v1/tts-models")!
        }
        guard let endpoint = AIProviderRegistry.descriptor(for: provider).modelListEndpoint else {
            throw ProviderAPIClientError.modelRefreshUnavailable
        }
        return endpoint
    }

    private func preferredCatalogCapability(for provider: AIProviderID) throws -> AICapability {
        let descriptor = AIProviderRegistry.descriptor(for: provider)
        for capability in [
            AICapability.llm,
            .textToSpeech,
            .speechToText,
            .imageGeneration,
            .videoGeneration,
            .webSearch,
        ] where descriptor.supports(capability) {
            return capability
        }
        throw ProviderAPIClientError.modelRefreshUnavailable
    }

    private func validatedCursor(_ rawCursor: String) throws -> String {
        guard !rawCursor.isEmpty,
              rawCursor.count <= Self.maximumCursorCharacters,
              rawCursor.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ProviderAPIClientError.invalidPagination
        }
        return rawCursor
    }

    private func validationSearchRequest(
        provider: AIProviderID,
        credential: String
    ) throws -> URLRequest {
        switch provider {
        case .tavily:
            var request = boundedRequest(url: URL(string: "https://api.tavily.com/search")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": "OpenClam connection test",
                "search_depth": "basic",
                "max_results": 1,
                "include_answer": false,
                "include_raw_content": false,
                "include_images": false,
            ], options: [.sortedKeys])
            return request
        case .brave:
            var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            components.queryItems = [
                .init(name: "q", value: "OpenClam connection test"),
                .init(name: "count", value: "1"),
                .init(name: "safesearch", value: "strict"),
            ]
            var request = boundedRequest(url: components.url!)
            request.setValue(credential, forHTTPHeaderField: "X-Subscription-Token")
            return request
        case .exa:
            var request = boundedRequest(url: URL(string: "https://api.exa.ai/search")!)
            request.httpMethod = "POST"
            request.setValue(credential, forHTTPHeaderField: "x-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": "OpenClam connection test",
                "numResults": 1,
                "moderation": true,
            ], options: [.sortedKeys])
            return request
        default:
            throw ProviderAPIClientError.validationUnavailable
        }
    }

    private func credentialValidationRequest(
        provider: AIProviderID,
        credential: String
    ) throws -> URLRequest {
        let endpoint: URL
        switch provider {
        case .openRouter:
            endpoint = URL(string: "https://openrouter.ai/api/v1/key")!
        case .kieAI:
            endpoint = URL(string: "https://api.kie.ai/api/v1/chat/credit")!
        case .deepgram:
            endpoint = URL(string: "https://api.deepgram.com/v1/projects")!
        default:
            throw ProviderAPIClientError.validationUnavailable
        }
        var request = boundedRequest(url: endpoint)
        request.setValue(
            provider == .deepgram ? "Token \(credential)" : "Bearer \(credential)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private func openRouterOutputModality(for capability: AICapability) -> String {
        switch capability {
        case .llm, .webSearch: "text"
        case .textToSpeech: "speech"
        case .speechToText: "transcription"
        case .imageGeneration: "image"
        case .videoGeneration: "video"
        }
    }

    private func boundedRequest(url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestTimeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func successfulData(for request: URLRequest) async throws -> Data {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              Self.allowedHosts.contains(url.host?.lowercased() ?? "") else {
            throw ProviderAPIClientError.untrustedEndpoint
        }
        let response = try await transport.send(request)
        guard response.data.count <= Self.maximumResponseBytes else {
            throw ProviderAPIClientError.responseTooLarge
        }
        guard (200..<300).contains(response.response.statusCode) else {
            throw ProviderAPIClientError.httpError(response.response.statusCode)
        }
        return response.data
    }

    private func decodeModelPage(
        _ data: Data,
        provider: AIProviderID,
        capability: AICapability
    ) throws -> DecodedModelPage {
        do {
            switch provider {
            case .openAI:
                return .init(
                    identifiers: try JSONDecoder().decode(ListEnvelope.self, from: data).data.map(\.id),
                    nextCursor: nil
                )
            case .xAI:
                guard capability == .llm else {
                    throw ProviderAPIClientError.modelRefreshUnavailable
                }
                return .init(
                    identifiers: try JSONDecoder().decode(XAILanguageModelsEnvelope.self, from: data)
                        .models
                        .filter { $0.outputModalities.contains("text") }
                        .map(\.id),
                    nextCursor: nil
                )
            case .anthropic:
                let envelope = try JSONDecoder().decode(AnthropicEnvelope.self, from: data)
                if envelope.hasMore == true, envelope.lastID == nil {
                    throw ProviderAPIClientError.invalidPagination
                }
                return .init(
                    identifiers: envelope.data.map(\.id),
                    nextCursor: envelope.hasMore == true ? envelope.lastID : nil
                )
            case .gemini:
                let envelope = try JSONDecoder().decode(GeminiEnvelope.self, from: data)
                return .init(
                    identifiers: envelope.models.compactMap {
                        $0.name.split(separator: "/").last.map(String.init)
                    },
                    nextCursor: envelope.nextPageToken
                )
            case .elevenLabs:
                return .init(
                    identifiers: try JSONDecoder().decode([ElevenLabsModel].self, from: data).map(\.modelID),
                    nextCursor: nil
                )
            case .soniox:
                return .init(
                    identifiers: try JSONDecoder().decode(SonioxEnvelope.self, from: data).models.map(\.id),
                    nextCursor: nil
                )
            case .openRouter:
                if capability == .imageGeneration || capability == .videoGeneration {
                    return .init(
                        identifiers: try JSONDecoder().decode(ListEnvelope.self, from: data)
                            .data.map(\.id),
                        nextCursor: nil
                    )
                }
                let models = try JSONDecoder().decode(OpenRouterEnvelope.self, from: data).data
                let expected = openRouterOutputModality(for: capability)
                return .init(
                    identifiers: models.filter {
                        $0.architecture.outputModalities.contains(expected)
                    }.map(\.id),
                    nextCursor: nil
                )
            default:
                throw ProviderAPIClientError.modelRefreshUnavailable
            }
        } catch let error as ProviderAPIClientError {
            throw error
        } catch {
            throw ProviderAPIClientError.malformedResponse
        }
    }

    private static let allowedHosts: Set<String> = [
        "api.openai.com",
        "api.anthropic.com",
        "generativelanguage.googleapis.com",
        "api.x.ai",
        "api.elevenlabs.io",
        "api.deepgram.com",
        "api.soniox.com",
        "api.tavily.com",
        "api.search.brave.com",
        "api.exa.ai",
        "api.kie.ai",
        "openrouter.ai",
    ]
}

enum ProviderAPIClientError: Error, Equatable, LocalizedError {
    case untrustedEndpoint
    case modelRefreshUnavailable
    case validationUnavailable
    case responseTooLarge
    case httpError(Int)
    case malformedResponse
    case emptyModelCatalog
    case invalidPagination
    case catalogLimitExceeded

    var errorDescription: String? {
        switch self {
        case .untrustedEndpoint:
            "The provider address is not an approved HTTPS endpoint."
        case .modelRefreshUnavailable:
            "This provider does not expose a compatible model-list endpoint."
        case .validationUnavailable:
            "This provider cannot be validated from the app."
        case .responseTooLarge:
            "The provider returned more data than the connection test accepts."
        case .httpError(let status):
            "The provider rejected the connection (HTTP \(status)). Check the key, permissions, billing, and account access."
        case .malformedResponse:
            "The provider returned an unreadable model list."
        case .emptyModelCatalog:
            "The key is valid, but no available models were returned for this account."
        case .invalidPagination:
            "The provider returned an invalid model-list cursor."
        case .catalogLimitExceeded:
            "The provider model catalog exceeded the app’s safe refresh limit."
        }
    }
}

private struct DecodedModelPage {
    let identifiers: [String]
    let nextCursor: String?
}

private struct ListEnvelope: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

private struct AnthropicEnvelope: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
    let hasMore: Bool?
    let lastID: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}

private struct XAILanguageModelsEnvelope: Decodable {
    struct Model: Decodable {
        let id: String
        let outputModalities: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case outputModalities = "output_modalities"
        }
    }
    let models: [Model]
}

private struct GeminiEnvelope: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
    let nextPageToken: String?
}

private struct ElevenLabsModel: Decodable {
    let modelID: String

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
    }
}

private struct SonioxEnvelope: Decodable {
    struct Model: Decodable { let id: String }
    let models: [Model]
}

private struct OpenRouterEnvelope: Decodable {
    struct Model: Decodable {
        struct Architecture: Decodable {
            let outputModalities: [String]

            enum CodingKeys: String, CodingKey {
                case outputModalities = "output_modalities"
            }
        }

        let id: String
        let architecture: Architecture
    }

    let data: [Model]
}
