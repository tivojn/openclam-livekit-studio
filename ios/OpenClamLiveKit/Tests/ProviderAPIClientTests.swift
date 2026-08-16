import XCTest
@testable import OpenClamLiveKit

final class ProviderAPIClientTests: XCTestCase {
    func testOpenAIModelRefreshUsesOfficialHostBearerHeaderAndBounds() async throws {
        let transport = RecordingProviderTransport(
            status: 200,
            body: #"{"data":[{"id":"gpt-5.6-luna"},{"id":"tts-1"}],"object":"list"}"#
        )
        let client = ProviderAPIClient(transport: transport, now: { Date(timeIntervalSince1970: 42) })

        let catalog = try await client.fetchModels(credential: "secret-test-key", provider: .openAI)

        XCTAssertEqual(catalog.modelIDs, ["gpt-5.6-luna", "tts-1"])
        XCTAssertEqual(catalog.capability, .llm)
        XCTAssertEqual(catalog.refreshedAt, Date(timeIntervalSince1970: 42))
        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test-key")
        XCTAssertLessThanOrEqual(request.timeoutInterval, 20)
    }

    func testAnthropicAndGeminiModelRefreshFollowBoundedPagination() async throws {
        let anthropicTransport = QueueProviderTransport(responses: [
            .init(status: 200, body: #"{"data":[{"id":"claude-a"}],"has_more":true,"last_id":"cursor-a"}"#),
            .init(status: 200, body: #"{"data":[{"id":"claude-b"}],"has_more":false}"#),
        ])
        let anthropic = try await ProviderAPIClient(transport: anthropicTransport).fetchModels(
            credential: "secret",
            provider: .anthropic,
            capability: .llm
        )
        XCTAssertEqual(anthropic.modelIDs, ["claude-a", "claude-b"])
        let anthropicRequests = await anthropicTransport.recordedRequests()
        XCTAssertEqual(anthropicRequests.count, 2)
        XCTAssertEqual(queryValue("limit", in: anthropicRequests[0]), "1000")
        XCTAssertNil(queryValue("after_id", in: anthropicRequests[0]))
        XCTAssertEqual(queryValue("after_id", in: anthropicRequests[1]), "cursor-a")

        let geminiTransport = QueueProviderTransport(responses: [
            .init(status: 200, body: #"{"models":[{"name":"models/gemini-a"}],"nextPageToken":"page-two"}"#),
            .init(status: 200, body: #"{"models":[{"name":"models/gemini-b"}]}"#),
        ])
        let gemini = try await ProviderAPIClient(transport: geminiTransport).fetchModels(
            credential: "secret",
            provider: .gemini,
            capability: .llm
        )
        XCTAssertEqual(gemini.modelIDs, ["gemini-a", "gemini-b"])
        let geminiRequests = await geminiTransport.recordedRequests()
        XCTAssertEqual(geminiRequests.count, 2)
        XCTAssertEqual(queryValue("pageSize", in: geminiRequests[0]), "1000")
        XCTAssertNil(queryValue("pageToken", in: geminiRequests[0]))
        XCTAssertEqual(queryValue("pageToken", in: geminiRequests[1]), "page-two")
    }

    func testXAIRefreshUsesLanguageModelsAndExcludesNonTextOutput() async throws {
        let transport = QueueProviderTransport(responses: [
            .init(
                status: 200,
                body: #"{"models":[{"id":"grok-4.5","output_modalities":["text"]},{"id":"image-only","output_modalities":["image"]}]}"#
            ),
        ])
        let catalog = try await ProviderAPIClient(transport: transport).fetchModels(
            credential: "xai-secret",
            provider: .xAI,
            capability: .llm
        )

        XCTAssertEqual(catalog.modelIDs, ["grok-4.5"])
        let request = await transport.recordedRequests().first
        XCTAssertEqual(request?.url?.absoluteString, "https://api.x.ai/v1/language-models")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer xai-secret")
    }

    func testOpenRouterRefreshUsesOutputModalityAndRejectsMismatchedModels() async throws {
        let cases: [(AICapability, String, String)] = [
            (.llm, "text", "vendor/text-model"),
            (.textToSpeech, "speech", "vendor/speech-model"),
            (.speechToText, "transcription", "vendor/transcription-model"),
            (.imageGeneration, "image", "vendor/image-model"),
            (.videoGeneration, "video", "vendor/video-model"),
        ]

        for (capability, modality, expectedModel) in cases {
            let usesDedicatedMediaCatalog = capability == .imageGeneration
                || capability == .videoGeneration
            let transport = RecordingProviderTransport(
                status: 200,
                body: usesDedicatedMediaCatalog
                    ? #"{"data":[{"id":"\#(expectedModel)"}]}"#
                    : #"{"data":[{"id":"\#(expectedModel)","architecture":{"output_modalities":["\#(modality)"]}},{"id":"vendor/wrong-model","architecture":{"output_modalities":["wrong"]}}]}"#
            )

            let catalog = try await ProviderAPIClient(transport: transport).fetchModels(
                credential: "openrouter-secret",
                provider: .openRouter,
                capability: capability
            )

            XCTAssertEqual(catalog.modelIDs, [expectedModel])
            let recordedRequest = await transport.lastRequest()
            let request = try XCTUnwrap(recordedRequest)
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "openrouter.ai")
            switch capability {
            case .imageGeneration:
                XCTAssertEqual(request.url?.path, "/api/v1/images/models")
                XCTAssertNil(queryValue("output_modalities", in: request))
            case .videoGeneration:
                XCTAssertEqual(request.url?.path, "/api/v1/videos/models")
                XCTAssertNil(queryValue("output_modalities", in: request))
            default:
                XCTAssertEqual(request.url?.path, "/api/v1/models")
                XCTAssertEqual(queryValue("output_modalities", in: request), modality)
            }
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer openrouter-secret"
            )
        }
    }

    func testOpenRouterAndKIECredentialValidationUseReadOnlyOfficialEndpoints() async throws {
        let openRouterTransport = RecordingProviderTransport(status: 200, body: #"{"data":{"label":"test"}}"#)
        try await ProviderAPIClient(transport: openRouterTransport).validateCredential(
            "openrouter-secret",
            for: .openRouter
        )
        let recordedOpenRouterRequest = await openRouterTransport.lastRequest()
        let openRouterRequest = try XCTUnwrap(recordedOpenRouterRequest)
        XCTAssertEqual(openRouterRequest.url?.absoluteString, "https://openrouter.ai/api/v1/key")
        XCTAssertEqual(openRouterRequest.httpMethod, "GET")
        XCTAssertEqual(
            openRouterRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer openrouter-secret"
        )

        let kieTransport = RecordingProviderTransport(status: 200, body: #"{"code":200,"data":100}"#)
        try await ProviderAPIClient(transport: kieTransport).validateCredential(
            "kie-secret",
            for: .kieAI
        )
        let recordedKIERequest = await kieTransport.lastRequest()
        let kieRequest = try XCTUnwrap(recordedKIERequest)
        XCTAssertEqual(kieRequest.url?.absoluteString, "https://api.kie.ai/api/v1/chat/credit")
        XCTAssertEqual(kieRequest.httpMethod, "GET")
        XCTAssertEqual(
            kieRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer kie-secret"
        )
    }

    func testDeepgramCredentialValidationUsesOfficialReadOnlyEndpoint() async throws {
        let transport = RecordingProviderTransport(status: 200, body: #"{"projects":[]}"#)

        try await ProviderAPIClient(transport: transport).validateCredential(
            "deepgram-secret",
            for: .deepgram
        )

        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepgram.com/v1/projects")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Token deepgram-secret"
        )
    }

    func testRepeatedPaginationCursorFailsClosed() async {
        let transport = QueueProviderTransport(responses: [
            .init(status: 200, body: #"{"data":[{"id":"claude-a"}],"has_more":true,"last_id":"repeat"}"#),
            .init(status: 200, body: #"{"data":[{"id":"claude-b"}],"has_more":true,"last_id":"repeat"}"#),
        ])

        await XCTAssertThrowsAsyncError(
            try await ProviderAPIClient(transport: transport).fetchModels(
                credential: "secret",
                provider: .anthropic,
                capability: .llm
            )
        ) { error in
            XCTAssertEqual(error as? ProviderAPIClientError, .invalidPagination)
        }
    }

    func testSonioxTTSUsesSeparateCatalogAndCredentialValidationFallsBackToIt() async throws {
        let catalogTransport = QueueProviderTransport(responses: [
            .init(status: 200, body: #"{"models":[{"id":"tts-rt-v1"}]}"#),
        ])
        let catalog = try await ProviderAPIClient(transport: catalogTransport).fetchModels(
            credential: "tts-restricted-key",
            provider: .soniox,
            capability: .textToSpeech
        )
        XCTAssertEqual(catalog.modelIDs, ["tts-rt-v1"])
        let catalogRequest = await catalogTransport.recordedRequests().first
        XCTAssertEqual(
            catalogRequest?.url?.absoluteString,
            "https://api.soniox.com/v1/tts-models"
        )

        let validationTransport = QueueProviderTransport(responses: [
            .init(status: 403, body: #"{"message":"STT not allowed"}"#),
            .init(status: 200, body: #"{"models":[{"id":"tts-rt-v1"}]}"#),
        ])
        try await ProviderAPIClient(transport: validationTransport).validateCredential(
            "tts-restricted-key",
            for: .soniox
        )
        let validationRequests = await validationTransport.recordedRequests()
        XCTAssertEqual(validationRequests.map { $0.url?.path }, ["/v1/models", "/v1/tts-models"])
    }

    func testProviderSpecificAuthenticationHeaders() async throws {
        let cases: [(AIProviderID, String, String)] = [
            (.anthropic, "x-api-key", "secret"),
            (.gemini, "x-goog-api-key", "secret"),
            (.elevenLabs, "xi-api-key", "secret"),
            (.soniox, "Authorization", "Bearer secret"),
        ]

        for (provider, header, value) in cases {
            let transport = RecordingProviderTransport(status: 200, body: validBody(for: provider))
            let client = ProviderAPIClient(transport: transport)
            _ = try await client.fetchModels(credential: "secret", provider: provider)
            let recordedHeader = await transport.lastRequest()?.value(forHTTPHeaderField: header)
            XCTAssertEqual(recordedHeader, value)
        }
    }

    func testSearchValidationUsesPinnedEndpointsAndMinimalQueries() async throws {
        for provider in [AIProviderID.tavily, .brave, .exa] {
            let transport = RecordingProviderTransport(status: 200, body: #"{"results":[]}"#)
            let client = ProviderAPIClient(transport: transport)
            try await client.validateCredential("search-secret", for: provider)
            let recordedRequest = await transport.lastRequest()
            let request = try XCTUnwrap(recordedRequest)
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertTrue(["api.tavily.com", "api.search.brave.com", "api.exa.ai"].contains(request.url?.host ?? ""))
            XCTAssertLessThanOrEqual(request.timeoutInterval, 20)
        }
    }

    func testOversizedAndMalformedResponsesAreRejected() async {
        let oversized = RecordingProviderTransport(
            status: 200,
            data: Data(repeating: 65, count: 1_000_001)
        )
        await XCTAssertThrowsAsyncError(
            try await ProviderAPIClient(transport: oversized)
                .fetchModels(credential: "secret", provider: .openAI)
        ) { error in
            XCTAssertEqual(error as? ProviderAPIClientError, .responseTooLarge)
        }

        let malformed = RecordingProviderTransport(status: 200, body: #"{"unexpected":true}"#)
        await XCTAssertThrowsAsyncError(
            try await ProviderAPIClient(transport: malformed)
                .fetchModels(credential: "secret", provider: .openAI)
        ) { error in
            XCTAssertEqual(error as? ProviderAPIClientError, .malformedResponse)
        }
    }

    private func validBody(for provider: AIProviderID) -> String {
        switch provider {
        case .anthropic: #"{"data":[{"id":"claude-sonnet-5"}]}"#
        case .gemini: #"{"models":[{"name":"models/gemini-3.6-flash"}]}"#
        case .elevenLabs: #"[{"model_id":"eleven_flash_v2_5"}]"#
        case .soniox: #"{"models":[{"id":"tts-rt-v1"}]}"#
        default: #"{"data":[{"id":"model"}]}"#
        }
    }
}

private struct ProviderStubResponse: Sendable {
    let status: Int
    let data: Data

    init(status: Int, body: String) {
        self.status = status
        data = Data(body.utf8)
    }
}

private actor QueueProviderTransport: ProviderAPITransport {
    private var responses: [ProviderStubResponse]
    private var requests: [URLRequest] = []

    init(responses: [ProviderStubResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> OpenAITransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let stub = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return .init(data: stub.data, response: response)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private func queryValue(_ name: String, in request: URLRequest) -> String? {
    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
        .queryItems?
        .first(where: { $0.name == name })?
        .value
}

private actor RecordingProviderTransport: ProviderAPITransport {
    private let status: Int
    private let data: Data
    private var request: URLRequest?

    init(status: Int, body: String) {
        self.status = status
        data = Data(body.utf8)
    }

    init(status: Int, data: Data) {
        self.status = status
        self.data = data
    }

    func send(_ request: URLRequest) async throws -> OpenAITransportResponse {
        self.request = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return .init(data: data, response: response)
    }

    func lastRequest() -> URLRequest? { request }
}

private func XCTAssertThrowsAsyncError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
