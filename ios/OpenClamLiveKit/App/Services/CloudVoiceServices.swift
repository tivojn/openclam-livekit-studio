import Foundation

struct CloudSpeechSynthesisRequest: Equatable, Sendable {
    let text: String
    let model: String
    let voice: String
    let languageCode: String?

    init(text: String, model: String, voice: String, languageCode: String? = nil) {
        self.text = text
        self.model = model
        self.voice = voice
        self.languageCode = languageCode
    }
}

struct CloudSpeechAudio: Equatable, Sendable {
    let data: Data
    let mimeType: String
}

struct CloudTranscriptionRequest: Equatable, Sendable {
    let audioData: Data
    let filename: String
    let mimeType: String
    let model: String
    let languageCode: String?

    init(
        audioData: Data,
        filename: String,
        mimeType: String,
        model: String,
        languageCode: String? = nil
    ) {
        self.audioData = audioData
        self.filename = filename
        self.mimeType = mimeType
        self.model = model
        self.languageCode = languageCode
    }
}

struct CloudTranscription: Equatable, Sendable {
    let text: String
}

/// Describes only the request-level control exercised by this app. It does not replace a
/// provider's account policy, abuse-monitoring policy, or legal retention terms.
enum CloudVoiceRequestStorageBehavior: String, Equatable, Sendable {
    case storeFalse
    case providerDefaultNoRequestFlag
    case providerDefaultLogging
    case deletesRemoteResourcesAfterCompletion
}

protocol CloudTextToSpeechServicing: Sendable {
    var provider: AIProviderID { get }
    var requestStorageBehavior: CloudVoiceRequestStorageBehavior { get }
    func synthesize(_ request: CloudSpeechSynthesisRequest) async throws -> CloudSpeechAudio
}

protocol CloudSpeechToTextServicing: Sendable {
    var provider: AIProviderID { get }
    var requestStorageBehavior: CloudVoiceRequestStorageBehavior { get }
    func transcribe(_ request: CloudTranscriptionRequest) async throws -> CloudTranscription
}

struct RealtimeTranscriptionUpdate: Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let endpointDetected: Bool
    let isFinished: Bool
}

protocol RealtimeSpeechToTextSession: Sendable {
    func sendPCM(_ data: Data) async throws
    func finishAudio() async throws
    func receiveUpdate() async throws -> RealtimeTranscriptionUpdate?
    func cancel() async
}

protocol RealtimeSpeechToTextServicing: Sendable {
    var provider: AIProviderID { get }
    var requestStorageBehavior: CloudVoiceRequestStorageBehavior { get }

    func startSession(
        model: String,
        languageCode: String?
    ) async throws -> any RealtimeSpeechToTextSession
}

enum CloudVoiceWebSocketMessage: Equatable, Sendable {
    case data(Data)
    case string(String)
}

protocol CloudVoiceWebSocketTask: Sendable {
    func resume()
    func send(_ message: CloudVoiceWebSocketMessage) async throws
    func receive() async throws -> CloudVoiceWebSocketMessage
    func cancel()
}

protocol CloudVoiceWebSocketTaskFactory: Sendable {
    func makeTask(for request: URLRequest) -> any CloudVoiceWebSocketTask
}

/// WebSocket handshakes must never follow a redirect: `URLSessionWebSocketTask.send` may queue the
/// first frame while the handshake is in flight, and that frame contains the Soniox credential.
/// An ephemeral session also prevents cookies or cached authentication from joining the request.
final class CloudVoiceNoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate {
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

private final class URLSessionCloudVoiceWebSocketTaskFactory: CloudVoiceWebSocketTaskFactory,
                                                               @unchecked Sendable {
    private let session: URLSession
    private let redirectDelegate: CloudVoiceNoRedirectURLSessionDelegate

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false

        let delegate = CloudVoiceNoRedirectURLSessionDelegate()
        redirectDelegate = delegate
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    func makeTask(for request: URLRequest) -> any CloudVoiceWebSocketTask {
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = SonioxRealtimeSpeechToTextSession.maximumResponseBytes
        return URLSessionCloudVoiceWebSocketTask(
            task: task,
            session: session
        )
    }
}

private final class URLSessionCloudVoiceWebSocketTask: CloudVoiceWebSocketTask, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    func resume() {
        task.resume()
    }

    func send(_ message: CloudVoiceWebSocketMessage) async throws {
        switch message {
        case .data(let data):
            try await task.send(.data(data))
        case .string(let string):
            try await task.send(.string(string))
        }
    }

    func receive() async throws -> CloudVoiceWebSocketMessage {
        switch try await task.receive() {
        case .data(let data):
            return .data(data)
        case .string(let string):
            return .string(string)
        @unknown default:
            throw CloudVoiceServiceError.malformedResponse
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

struct OpenAICloudVoiceService: CloudTextToSpeechServicing, CloudSpeechToTextServicing, Sendable {
    static let speechEndpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
    static let transcriptionEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    let provider = AIProviderID.openAI
    let requestStorageBehavior = CloudVoiceRequestStorageBehavior.providerDefaultNoRequestFlag

    private let credentialStore: AgentCredentialStore
    private let transport: OpenAIResponsesTransport

    init(
        credentialStore: AgentCredentialStore,
        transport: OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport()
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
    }

    func synthesize(_ request: CloudSpeechSynthesisRequest) async throws -> CloudSpeechAudio {
        let text = try CloudVoiceRequestSupport.text(request.text, maximumBytes: 4_096)
        let model = try CloudVoiceRequestSupport.identifier(request.model, maximumBytes: 128)
        let voice = try CloudVoiceRequestSupport.identifier(request.voice, maximumBytes: 64)
        let key = try CloudVoiceRequestSupport.credential(from: credentialStore)
        let body = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "mp3",
        ], options: [.sortedKeys])
        var urlRequest = CloudVoiceRequestSupport.request(
            url: Self.speechEndpoint,
            method: "POST",
            timeout: 60
        )
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let response = try await transport.send(urlRequest)
        let audio = try CloudVoiceRequestSupport.successData(
            response,
            maximumBytes: CloudVoiceRequestSupport.maximumAudioOutputBytes
        )
        guard !audio.isEmpty else { throw CloudVoiceServiceError.missingAudio }
        return .init(data: audio, mimeType: "audio/mpeg")
    }

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> CloudTranscription {
        let validated = try CloudVoiceRequestSupport.audioRequest(request)
        let key = try CloudVoiceRequestSupport.credential(from: credentialStore)
        var fields = [
            "model": try CloudVoiceRequestSupport.identifier(request.model, maximumBytes: 128),
            "response_format": "json",
        ]
        if let language = try CloudVoiceRequestSupport.language(request.languageCode) {
            fields["language"] = language
        }
        let multipart = try CloudVoiceRequestSupport.multipart(
            fields: fields,
            file: validated
        )
        var urlRequest = CloudVoiceRequestSupport.request(
            url: Self.transcriptionEndpoint,
            method: "POST",
            timeout: 60
        )
        urlRequest.httpBody = multipart.data
        urlRequest.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let response = try await transport.send(urlRequest)
        return try CloudVoiceRequestSupport.transcription(from: response)
    }
}

/// OpenRouter's dedicated speech and transcription APIs intentionally mirror the bounded
/// OpenAI-shaped requests already used by OpenClam, while keeping a separate provider-scoped key.
struct OpenRouterCloudVoiceService: CloudTextToSpeechServicing,
    CloudSpeechToTextServicing, Sendable {
    static let speechEndpoint = URL(string: "https://openrouter.ai/api/v1/audio/speech")!
    static let transcriptionEndpoint = URL(
        string: "https://openrouter.ai/api/v1/audio/transcriptions"
    )!

    let provider = AIProviderID.openRouter
    let requestStorageBehavior = CloudVoiceRequestStorageBehavior.providerDefaultLogging

    private let credentialStore: AgentCredentialStore
    private let transport: OpenAIResponsesTransport

    init(
        credentialStore: AgentCredentialStore,
        transport: OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport()
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
    }

    func synthesize(_ request: CloudSpeechSynthesisRequest) async throws -> CloudSpeechAudio {
        let text = try CloudVoiceRequestSupport.text(request.text, maximumBytes: 4_096)
        let model = try CloudVoiceRequestSupport.identifier(request.model, maximumBytes: 128)
        let voice = try CloudVoiceRequestSupport.identifier(request.voice, maximumBytes: 64)
        let key = try CloudVoiceRequestSupport.credential(from: credentialStore)
        let body = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "mp3",
        ], options: [.sortedKeys])
        var urlRequest = CloudVoiceRequestSupport.request(
            url: Self.speechEndpoint,
            method: "POST",
            timeout: 60
        )
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let response = try await transport.send(urlRequest)
        let audio = try CloudVoiceRequestSupport.successData(
            response,
            maximumBytes: CloudVoiceRequestSupport.maximumAudioOutputBytes
        )
        guard !audio.isEmpty else { throw CloudVoiceServiceError.missingAudio }
        return .init(data: audio, mimeType: "audio/mpeg")
    }

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> CloudTranscription {
        let file = try CloudVoiceRequestSupport.audioRequest(request)
        let model = try CloudVoiceRequestSupport.identifier(request.model, maximumBytes: 128)
        let key = try CloudVoiceRequestSupport.credential(from: credentialStore)
        var body: [String: Any] = [
            "model": model,
            "input_audio": [
                "data": file.data.base64EncodedString(),
                "format": try Self.audioFormat(filename: file.filename, mimeType: file.mimeType),
            ],
        ]
        if let language = try CloudVoiceRequestSupport.language(request.languageCode) {
            body["language"] = language
        }
        var urlRequest = CloudVoiceRequestSupport.request(
            url: Self.transcriptionEndpoint,
            method: "POST",
            timeout: 60
        )
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        return try CloudVoiceRequestSupport.transcription(from: await transport.send(urlRequest))
    }

    private static func audioFormat(filename: String, mimeType: String) throws -> String {
        let extensionValue = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let supported = ["wav", "mp3", "flac", "m4a", "ogg", "webm", "aac"]
        if supported.contains(extensionValue) { return extensionValue }
        switch mimeType {
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/aac": return "aac"
        case "audio/flac": return "flac"
        case "audio/ogg": return "ogg"
        case "audio/webm": return "webm"
        default: throw CloudVoiceServiceError.invalidMIMEType
        }
    }
}

/// Bounded adapters for xAI's REST speech endpoints. These are deliberately separate from
/// the realtime Voice Agent API: the app submits one reviewed text or recorded file and receives
/// one audio result or transcript.
struct XAICloudVoiceService: CloudTextToSpeechServicing, CloudSpeechToTextServicing, Sendable {
    static let speechEndpoint = URL(string: "https://api.x.ai/v1/tts")!
    static let transcriptionEndpoint = URL(string: "https://api.x.ai/v1/stt")!
    static let textToSpeechServiceID = "xai-tts"
    static let speechToTextServiceID = "grok-transcribe"

    let provider = AIProviderID.xAI
    let requestStorageBehavior = CloudVoiceRequestStorageBehavior.providerDefaultNoRequestFlag

    private let credentialStore: AgentCredentialStore
    private let transport: OpenAIResponsesTransport

    init(
        credentialStore: AgentCredentialStore,
        transport: OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport()
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
    }

    func synthesize(_ request: CloudSpeechSynthesisRequest) async throws -> CloudSpeechAudio {
        let text = try CloudVoiceRequestSupport.text(request.text, maximumBytes: 15_000)
        let serviceID = try CloudVoiceRequestSupport.identifier(request.model, maximumBytes: 128)
        guard serviceID == Self.textToSpeechServiceID else {
            throw CloudVoiceServiceError.invalidIdentifier
        }
        let voice = try CloudVoiceRequestSupport.identifier(request.voice, maximumBytes: 64)
        let language = try CloudVoiceRequestSupport.language(request.languageCode) ?? "auto"
        let key = try CloudVoiceRequestSupport.credential(from: credentialStore)
        let body = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "voice_id": voice,
            "language": language,
            "output_format": [
                "codec": "mp3",
                "sample_rate": 24_000,
                "bit_rate": 128_000,
            ],
        ], options: [.sortedKeys])
        var urlRequest = CloudVoiceRequestSupport.request(
            url: Self.speechEndpoint,
            method: "POST",
            timeout: 60
        )
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let audio = try CloudVoiceRequestSupport.successData(
            await transport.send(urlRequest),
            maximumBytes: CloudVoiceRequestSupport.maximumAudioOutputBytes
        )
        guard !audio.isEmpty else { throw CloudVoiceServiceError.missingAudio }
        return .init(data: audio, mimeType: "audio/mpeg")
    }

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> CloudTranscription {
        let file = try CloudVoiceRequestSupport.audioRequest(request)
        let serviceID = try CloudVoiceRequestSupport.identifier(request.model, maximumBytes: 128)
        guard serviceID == Self.speechToTextServiceID else {
            throw CloudVoiceServiceError.invalidIdentifier
        }
        let key = try CloudVoiceRequestSupport.credential(from: credentialStore)
        var fields: [String: String] = [:]
        if let language = try CloudVoiceRequestSupport.language(request.languageCode) {
            fields["language"] = language
            fields["format"] = "true"
        }
        let multipart = try CloudVoiceRequestSupport.multipart(fields: fields, file: file)
        var urlRequest = CloudVoiceRequestSupport.request(
            url: Self.transcriptionEndpoint,
            method: "POST",
            timeout: 60
        )
        urlRequest.httpBody = multipart.data
        urlRequest.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        return try CloudVoiceRequestSupport.transcription(from: await transport.send(urlRequest))
    }
}

struct GeminiCloudTextToSpeechService: CloudTextToSpeechServicing, Sendable {
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!

    let provider = AIProviderID.gemini
    let requestStorageBehavior = CloudVoiceRequestStorageBehavior.storeFalse

    private let credentialStore: AgentCredentialStore
    private let transport: OpenAIResponsesTransport

    init(
        credentialStore: AgentCredentialStore,
        transport: OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport()
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
    }

    func synthesize(_ request: CloudSpeechSynthesisRequest) async throws -> CloudSpeechAudio {
        let text = try CloudVoiceRequestSupport.text(request.text, maximumBytes: 8_000)
        let model = try CloudVoiceRequestSupport.identifier(request.model, maximumBytes: 128)
        let voice = try CloudVoiceRequestSupport.identifier(request.voice, maximumBytes: 64)
        let key = try CloudVoiceRequestSupport.credential(from: credentialStore)
        var speechConfiguration: [String: Any] = ["voice": voice]
        if let language = try CloudVoiceRequestSupport.language(request.languageCode) {
            speechConfiguration["language"] = language
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": text,
            "response_format": ["type": "audio"],
            "generation_config": [
                "speech_config": [speechConfiguration],
            ],
            "store": false,
        ], options: [.sortedKeys])
        var urlRequest = CloudVoiceRequestSupport.request(
            url: Self.endpoint,
            method: "POST",
            timeout: 60
        )
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        let response = try await transport.send(urlRequest)
        let data = try CloudVoiceRequestSupport.successData(
            response,
            maximumBytes: CloudVoiceRequestSupport.maximumBase64ResponseBytes
        )
        let envelope: GeminiAudioEnvelope
        do {
            envelope = try JSONDecoder().decode(GeminiAudioEnvelope.self, from: data)
        } catch {
            throw CloudVoiceServiceError.malformedResponse
        }
        guard let audio = Data(base64Encoded: envelope.outputAudio.data),
              !audio.isEmpty else {
            throw CloudVoiceServiceError.missingAudio
        }
        guard audio.count <= CloudVoiceRequestSupport.maximumAudioOutputBytes else {
            throw CloudVoiceServiceError.responseTooLarge
        }
        // The official Interactions TTS response is mono 16-bit PCM at 24 kHz. Consumers must
        // wrap it in a WAV container or configure an audio engine with this exact format.
        return .init(data: audio, mimeType: "audio/L16;rate=24000;channels=1")
    }
}

struct ElevenLabsCloudVoiceService: CloudTextToSpeechServicing, CloudSpeechToTextServicing, Sendable {
    static let speechBaseURL = URL(string: "https://api.elevenlabs.io/v1/text-to-speech")!
    static let transcriptionEndpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    let provider = AIProviderID.elevenLabs
    let requestStorageBehavior = CloudVoiceRequestStorageBehavior.providerDefaultLogging

    private let credentialStore: AgentCredentialStore
    private let transport: OpenAIResponsesTransport

    init(
        credentialStore: AgentCredentialStore,
        transport: OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport()
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
    }

    func synthesize(_ request: CloudSpeechSynthesisRequest) async throws -> CloudSpeechAudio {
        let text = try CloudVoiceRequestSupport.text(request.text, maximumBytes: 5_000)
        let model = try CloudVoiceRequestSupport.identifier(request.model, maximumBytes: 128)
        let voice = try CloudVoiceRequestSupport.safePathSegment(request.voice, maximumBytes: 128)
        let key = try CloudVoiceRequestSupport.credential(from: credentialStore)
        var body: [String: Any] = ["text": text, "model_id": model]
        if let language = try CloudVoiceRequestSupport.language(request.languageCode) {
            body["language_code"] = language
        }
        var components = URLComponents(
            url: Self.speechBaseURL.appendingPathComponent(voice, isDirectory: false),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [.init(name: "output_format", value: "mp3_44100_128")]
        var urlRequest = CloudVoiceRequestSupport.request(
            url: components.url!,
            method: "POST",
            timeout: 60
        )
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        urlRequest.setValue(key, forHTTPHeaderField: "xi-api-key")

        let response = try await transport.send(urlRequest)
        let audio = try CloudVoiceRequestSupport.successData(
            response,
            maximumBytes: CloudVoiceRequestSupport.maximumAudioOutputBytes
        )
        guard !audio.isEmpty else { throw CloudVoiceServiceError.missingAudio }
        return .init(data: audio, mimeType: "audio/mpeg")
    }

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> CloudTranscription {
        let validated = try CloudVoiceRequestSupport.audioRequest(request)
        let key = try CloudVoiceRequestSupport.credential(from: credentialStore)
        var fields = [
            "model_id": try CloudVoiceRequestSupport.identifier(request.model, maximumBytes: 128),
            "tag_audio_events": "false",
            "diarize": "false",
        ]
        if let language = try CloudVoiceRequestSupport.language(request.languageCode) {
            fields["language_code"] = language
        }
        let multipart = try CloudVoiceRequestSupport.multipart(fields: fields, file: validated)
        var urlRequest = CloudVoiceRequestSupport.request(
            url: Self.transcriptionEndpoint,
            method: "POST",
            timeout: 60
        )
        urlRequest.httpBody = multipart.data
        urlRequest.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(key, forHTTPHeaderField: "xi-api-key")

        let response = try await transport.send(urlRequest)
        return try CloudVoiceRequestSupport.transcription(from: response)
    }
}

struct SonioxCloudTextToSpeechService: CloudTextToSpeechServicing, Sendable {
    static let endpoint = URL(string: "https://tts-rt.soniox.com/tts")!

    let provider = AIProviderID.soniox
    let requestStorageBehavior = CloudVoiceRequestStorageBehavior.providerDefaultNoRequestFlag

    private let credentialStore: AgentCredentialStore
    private let transport: OpenAIResponsesTransport

    init(
        credentialStore: AgentCredentialStore,
        transport: OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport()
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
    }

    func synthesize(_ request: CloudSpeechSynthesisRequest) async throws -> CloudSpeechAudio {
        let text = try CloudVoiceRequestSupport.text(request.text, maximumBytes: 5_000)
        let model = try CloudVoiceRequestSupport.identifier(request.model, maximumBytes: 50)
        let voice = try CloudVoiceRequestSupport.identifier(request.voice, maximumBytes: 50)
        guard let language = try CloudVoiceRequestSupport.language(request.languageCode) else {
            throw CloudVoiceServiceError.missingLanguage
        }
        let key = try CloudVoiceRequestSupport.credential(from: credentialStore)
        let body = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "language": language,
            "voice": voice,
            "audio_format": "mp3",
            "text": text,
        ], options: [.sortedKeys])
        var urlRequest = CloudVoiceRequestSupport.request(
            url: Self.endpoint,
            method: "POST",
            timeout: 60
        )
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let response = try await transport.send(urlRequest)
        let audio = try CloudVoiceRequestSupport.successData(
            response,
            maximumBytes: CloudVoiceRequestSupport.maximumAudioOutputBytes
        )
        guard !audio.isEmpty else { throw CloudVoiceServiceError.missingAudio }
        return .init(data: audio, mimeType: "audio/mpeg")
    }
}

/// Soniox's low-latency microphone path. The long-lived API key is placed only in the first
/// encrypted WebSocket configuration frame, as required by Soniox, and is never included in the
/// URL, headers, errors, analytics, or logs. Callers stream bounded 16-bit/16-kHz/mono PCM frames.
struct SonioxRealtimeSpeechToTextService: RealtimeSpeechToTextServicing, Sendable {
    static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    static let model = "stt-rt-v5"

    let provider = AIProviderID.soniox
    let requestStorageBehavior = CloudVoiceRequestStorageBehavior.providerDefaultNoRequestFlag

    private let credentialStore: AgentCredentialStore
    private let socketFactory: CloudVoiceWebSocketTaskFactory

    init(
        credentialStore: AgentCredentialStore,
        socketFactory: CloudVoiceWebSocketTaskFactory = URLSessionCloudVoiceWebSocketTaskFactory()
    ) {
        self.credentialStore = credentialStore
        self.socketFactory = socketFactory
    }

    func startSession(
        model: String,
        languageCode: String?
    ) async throws -> any RealtimeSpeechToTextSession {
        let selectedModel = try CloudVoiceRequestSupport.identifier(model, maximumBytes: 32)
        guard selectedModel == Self.model else {
            throw CloudVoiceServiceError.invalidIdentifier
        }
        let language = try CloudVoiceRequestSupport.language(languageCode)
        let key = try CloudVoiceRequestSupport.credential(from: credentialStore)

        var request = CloudVoiceRequestSupport.request(
            url: Self.endpoint,
            method: "GET",
            timeout: 15
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard Self.isTrustedEndpoint(request.url) else {
            throw CloudVoiceServiceError.untrustedEndpoint
        }
        let socket = socketFactory.makeTask(for: request)

        var configuration: [String: Any] = [
            "api_key": key,
            "model": selectedModel,
            "audio_format": "pcm_s16le",
            "sample_rate": 16_000,
            "num_channels": 1,
            "enable_endpoint_detection": true,
            "endpoint_latency_adjustment_level": 2,
            "endpoint_sensitivity": 0.3,
            "max_endpoint_delay_ms": 1_500,
        ]
        if let language {
            configuration["language_hints"] = [language]
        }
        let configurationData = try JSONSerialization.data(
            withJSONObject: configuration,
            options: [.sortedKeys]
        )
        guard configurationData.count <= SonioxRealtimeSpeechToTextSession.maximumConfigurationBytes,
              let configurationText = String(data: configurationData, encoding: .utf8) else {
            socket.cancel()
            throw CloudVoiceServiceError.requestTooLarge
        }

        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                socket.resume()
                try Task.checkCancellation()
                try await socket.send(.string(configurationText))
                try Task.checkCancellation()
                return SonioxRealtimeSpeechToTextSession(socket: socket)
            } catch {
                socket.cancel()
                throw error
            }
        } onCancel: {
            // The socket is still local until this method returns, so cancellation during a
            // handshake/configuration send must abort it here rather than relying on a caller's
            // not-yet-assigned session reference.
            socket.cancel()
        }
    }

    static func isTrustedEndpoint(_ url: URL?) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "wss"
            && components.host == "stt-rt.soniox.com"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.path == "/transcribe-websocket"
            && components.query == nil
            && components.fragment == nil
    }
}

private actor SonioxRealtimeSpeechToTextSession: RealtimeSpeechToTextSession {
    static let maximumConfigurationBytes = 8_192
    static let maximumPCMChunkBytes = 64 * 1_024
    static let maximumPCMSessionBytes = 4_000_000
    static let maximumResponseBytes = 256_000
    static let maximumTranscriptBytes = 200_000
    static let maximumTokensPerResponse = 4_096
    static let maximumTokenBytes = 1_024

    private let socket: CloudVoiceWebSocketTask
    private var totalPCMBytes = 0
    private var finalizedText = ""
    private var provisionalText = ""
    private var didSendFinish = false
    private var didReceiveFinished = false
    private var isCancelled = false

    init(socket: CloudVoiceWebSocketTask) {
        self.socket = socket
    }

    func sendPCM(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !isCancelled, !didSendFinish else { throw CancellationError() }
        guard !data.isEmpty,
              data.count <= Self.maximumPCMChunkBytes,
              data.count.isMultiple(of: MemoryLayout<Int16>.size),
              totalPCMBytes <= Self.maximumPCMSessionBytes - data.count else {
            throw CloudVoiceServiceError.invalidAudio
        }
        totalPCMBytes += data.count
        try await socket.send(.data(data))
    }

    func finishAudio() async throws {
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        guard !didSendFinish else { return }
        didSendFinish = true
        // Soniox defines an empty binary or text frame as graceful end-of-stream. Use the empty
        // text form because it is consistently forwarded by both URLSession and WHATWG-style
        // WebSocket stacks; some client implementations elide zero-length binary frames.
        try await socket.send(.string(""))
    }

    func receiveUpdate() async throws -> RealtimeTranscriptionUpdate? {
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        guard !didReceiveFinished else { return nil }

        let message = try await socket.receive()
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            data = Data(value.utf8)
        }
        guard !data.isEmpty, data.count <= Self.maximumResponseBytes else {
            throw CloudVoiceServiceError.malformedResponse
        }

        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            throw CloudVoiceServiceError.malformedResponse
        }
        if let errorType = envelope.errorType {
            throw Self.providerError(type: errorType, code: envelope.errorCode)
        }
        guard envelope.tokens.count <= Self.maximumTokensPerResponse else {
            throw CloudVoiceServiceError.responseTooLarge
        }

        var nextProvisionalText = ""
        var receivedFinalToken = false
        var endpointDetected = false
        for token in envelope.tokens {
            guard token.text.utf8.count <= Self.maximumTokenBytes else {
                throw CloudVoiceServiceError.responseTooLarge
            }
            if token.text == "<end>" || token.text == "<fin>" {
                guard token.isFinal else { throw CloudVoiceServiceError.malformedResponse }
                endpointDetected = true
                continue
            }
            if token.isFinal {
                finalizedText += token.text
                receivedFinalToken = true
            } else {
                nextProvisionalText += token.text
            }
        }
        provisionalText = nextProvisionalText
        guard finalizedText.utf8.count + provisionalText.utf8.count
                <= Self.maximumTranscriptBytes else {
            throw CloudVoiceServiceError.responseTooLarge
        }

        didReceiveFinished = envelope.finished == true
        if didReceiveFinished {
            provisionalText = ""
        }
        let currentText = (finalizedText + provisionalText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            text: currentText,
            isFinal: didReceiveFinished || endpointDetected
                || (receivedFinalToken && provisionalText.isEmpty),
            endpointDetected: endpointDetected,
            isFinished: didReceiveFinished
        )
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        socket.cancel()
    }

    private static func providerError(type: String, code: Int?) -> CloudVoiceServiceError {
        let normalized = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["unauthenticated", "permission_denied", "forbidden"].contains(normalized)
            || code == 401 || code == 403 {
            return .credentialRejected
        }
        if let code, (400...599).contains(code) {
            return .httpError(code)
        }
        return .providerProcessingFailed
    }

    private struct ResponseEnvelope: Decodable {
        let tokens: [Token]
        let finished: Bool?
        let errorCode: Int?
        let errorType: String?

        enum CodingKeys: String, CodingKey {
            case tokens
            case finished
            case errorCode = "error_code"
            case errorType = "error_type"
        }
    }

    private struct Token: Decodable {
        let text: String
        let isFinal: Bool

        enum CodingKeys: String, CodingKey {
            case text
            case isFinal = "is_final"
        }
    }
}

/// Bounded Soniox asynchronous file transcription. The adapter explicitly deletes the
/// transcription and uploaded file after fetching the result. Cleanup is also attempted on
/// cancellation and failure, although Soniox can reject deletion while a job is processing.
struct SonioxCloudSpeechToTextService: CloudSpeechToTextServicing, Sendable {
    static let filesEndpoint = URL(string: "https://api.soniox.com/v1/files")!
    static let transcriptionsEndpoint = URL(string: "https://api.soniox.com/v1/transcriptions")!

    let provider = AIProviderID.soniox
    let requestStorageBehavior = CloudVoiceRequestStorageBehavior.deletesRemoteResourcesAfterCompletion

    private static let maximumPolls = 60
    private static let pollDelayNanoseconds: UInt64 = 1_000_000_000

    private let credentialStore: AgentCredentialStore
    private let transport: OpenAIResponsesTransport

    init(
        credentialStore: AgentCredentialStore,
        transport: OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport()
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
    }

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> CloudTranscription {
        let file = try CloudVoiceRequestSupport.audioRequest(request)
        let model = try CloudVoiceRequestSupport.identifier(request.model, maximumBytes: 32)
        let language = try CloudVoiceRequestSupport.language(request.languageCode)
        let key = try CloudVoiceRequestSupport.credential(from: credentialStore)
        var fileID: String?
        var transcriptionID: String?

        let result: CloudTranscription
        do {
            let upload = try await uploadFile(file, key: key)
            fileID = upload
            let created = try await createTranscription(
                fileID: upload,
                model: model,
                language: language,
                key: key
            )
            transcriptionID = created.id
            try await waitUntilCompleted(
                transcriptionID: created.id,
                initialStatus: created.status,
                key: key
            )
            result = try await fetchTranscript(transcriptionID: created.id, key: key)
        } catch {
            let cleaned = await cleanupInFreshTask(
                transcriptionID: transcriptionID,
                fileID: fileID,
                key: key
            )
            guard cleaned else { throw CloudVoiceServiceError.remoteCleanupFailed }
            if error is CancellationError { throw CancellationError() }
            throw error
        }

        let cleaned = await cleanupInFreshTask(
            transcriptionID: transcriptionID,
            fileID: fileID,
            key: key
        )
        guard cleaned else { throw CloudVoiceServiceError.remoteCleanupFailed }
        return result
    }

    /// Cleanup must not inherit cancellation from the transcription task. Each DELETE still has
    /// its own short URL-request timeout, so this detached cleanup is finite even when the caller
    /// has already cancelled while the provider job is processing.
    private func cleanupInFreshTask(
        transcriptionID: String?,
        fileID: String?,
        key: String
    ) async -> Bool {
        let service = self
        return await Task.detached(priority: .utility) {
            await service.cleanup(
                transcriptionID: transcriptionID,
                fileID: fileID,
                key: key
            )
        }.value
    }

    private func uploadFile(_ file: CloudVoiceRequestSupport.AudioFile, key: String) async throws -> String {
        let multipart = try CloudVoiceRequestSupport.multipart(fields: [:], file: file)
        var request = CloudVoiceRequestSupport.request(
            url: Self.filesEndpoint,
            method: "POST",
            timeout: 60
        )
        request.httpBody = multipart.data
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data = try CloudVoiceRequestSupport.successData(
            await transport.send(request),
            maximumBytes: CloudVoiceRequestSupport.maximumJSONResponseBytes
        )
        let envelope: IdentifierEnvelope
        do {
            envelope = try JSONDecoder().decode(IdentifierEnvelope.self, from: data)
        } catch {
            throw CloudVoiceServiceError.malformedResponse
        }
        return try CloudVoiceRequestSupport.uuid(envelope.id)
    }

    private func createTranscription(
        fileID: String,
        model: String,
        language: String?,
        key: String
    ) async throws -> JobEnvelope {
        var body: [String: Any] = ["model": model, "file_id": fileID]
        if let language { body["language_hints"] = [language] }
        var request = CloudVoiceRequestSupport.request(
            url: Self.transcriptionsEndpoint,
            method: "POST",
            timeout: 30
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data = try CloudVoiceRequestSupport.successData(
            await transport.send(request),
            maximumBytes: CloudVoiceRequestSupport.maximumJSONResponseBytes
        )
        let envelope: JobEnvelope
        do {
            envelope = try JSONDecoder().decode(JobEnvelope.self, from: data)
        } catch {
            throw CloudVoiceServiceError.malformedResponse
        }
        return .init(id: try CloudVoiceRequestSupport.uuid(envelope.id), status: envelope.status)
    }

    private func waitUntilCompleted(
        transcriptionID: String,
        initialStatus: String,
        key: String
    ) async throws {
        var status = initialStatus.lowercased()
        var pollCount = 0
        while status != "completed" {
            try Task.checkCancellation()
            if ["error", "failed"].contains(status) {
                throw CloudVoiceServiceError.providerProcessingFailed
            }
            guard ["queued", "processing", "downloading", "transcribing"].contains(status) else {
                throw CloudVoiceServiceError.malformedResponse
            }
            guard pollCount < Self.maximumPolls else {
                throw CloudVoiceServiceError.processingTimedOut
            }
            pollCount += 1
            try await Task.sleep(nanoseconds: Self.pollDelayNanoseconds)
            let endpoint = try transcriptionURL(id: transcriptionID)
            var request = CloudVoiceRequestSupport.request(url: endpoint, method: "GET", timeout: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let data = try CloudVoiceRequestSupport.successData(
                await transport.send(request),
                maximumBytes: CloudVoiceRequestSupport.maximumJSONResponseBytes
            )
            do {
                status = try JSONDecoder().decode(JobEnvelope.self, from: data).status.lowercased()
            } catch {
                throw CloudVoiceServiceError.malformedResponse
            }
        }
    }

    private func fetchTranscript(transcriptionID: String, key: String) async throws -> CloudTranscription {
        let endpoint = try transcriptionURL(id: transcriptionID)
            .appendingPathComponent("transcript", isDirectory: false)
        var request = CloudVoiceRequestSupport.request(url: endpoint, method: "GET", timeout: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request)
        return try CloudVoiceRequestSupport.transcription(from: response)
    }

    private func cleanup(transcriptionID: String?, fileID: String?, key: String) async -> Bool {
        var succeeded = true
        if let transcriptionID,
           let endpoint = try? transcriptionURL(id: transcriptionID) {
            succeeded = await delete(endpoint: endpoint, key: key) && succeeded
        }
        if let fileID,
           let safeID = try? CloudVoiceRequestSupport.uuid(fileID) {
            let endpoint = Self.filesEndpoint.appendingPathComponent(safeID, isDirectory: false)
            succeeded = await delete(endpoint: endpoint, key: key) && succeeded
        }
        return succeeded
    }

    private func delete(endpoint: URL, key: String) async -> Bool {
        var request = CloudVoiceRequestSupport.request(url: endpoint, method: "DELETE", timeout: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let response = try await transport.send(request)
            return (200..<300).contains(response.response.statusCode)
                || response.response.statusCode == 404
        } catch {
            return false
        }
    }

    private func transcriptionURL(id: String) throws -> URL {
        Self.transcriptionsEndpoint.appendingPathComponent(
            try CloudVoiceRequestSupport.uuid(id),
            isDirectory: false
        )
    }
}

enum CloudVoiceServiceError: Error, Equatable, LocalizedError {
    case missingCredential
    case invalidText
    case invalidIdentifier
    case invalidAudio
    case invalidFilename
    case invalidMIMEType
    case invalidLanguage
    case missingLanguage
    case untrustedEndpoint
    case credentialRejected
    case audioStreamOverflow
    case requestTooLarge
    case responseTooLarge
    case httpError(Int)
    case malformedResponse
    case missingAudio
    case missingTranscript
    case providerProcessingFailed
    case processingTimedOut
    case remoteCleanupFailed

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            "Add and validate this provider's API key in the AI tab first."
        case .invalidText:
            "Speech text is empty, contains control characters, or exceeds the provider limit."
        case .invalidIdentifier:
            "The selected model or voice identifier is invalid."
        case .invalidAudio:
            "The audio input was empty, malformed, or exceeded the app safety limit."
        case .invalidFilename:
            "The audio filename is invalid."
        case .invalidMIMEType:
            "The selected file does not have a supported audio or video media type."
        case .invalidLanguage:
            "Use a short ISO or BCP-47 language code."
        case .missingLanguage:
            "This provider requires a language for speech generation."
        case .untrustedEndpoint:
            "The live speech connection did not match the trusted provider endpoint."
        case .credentialRejected:
            "The voice provider rejected the saved API key or its speech permission. Validate a key with speech access in AI settings."
        case .audioStreamOverflow:
            "Live speech could not keep up with the microphone stream. Check the connection and try again."
        case .requestTooLarge:
            "The voice request exceeded the app safety limit."
        case .responseTooLarge:
            "The voice provider response exceeded the app safety limit."
        case .httpError(let status):
            "The voice provider rejected the request (HTTP \(status)). Check the saved key, billing, model, and voice access."
        case .malformedResponse:
            "The voice provider returned an unreadable response."
        case .missingAudio:
            "The voice provider returned no audio."
        case .missingTranscript:
            "The voice provider returned no transcript."
        case .providerProcessingFailed:
            "The provider could not finish the transcription."
        case .processingTimedOut:
            "The voice provider did not finish the transcription within the app's allowed time."
        case .remoteCleanupFailed:
            "The app could not verify deletion of the provider's remote transcription resources. Check the provider console."
        }
    }
}

enum CloudVoiceRequestSupport {
    static let maximumAudioInputBytes = 20_000_000
    static let maximumAudioOutputBytes = 20_000_000
    static let maximumBase64ResponseBytes = 28_000_000
    static let maximumJSONResponseBytes = 1_000_000
    private static let maximumTranscriptBytes = 200_000

    struct AudioFile: Sendable {
        let data: Data
        let filename: String
        let mimeType: String
    }

    struct Multipart: Sendable {
        let data: Data
        let contentType: String
    }

    static func credential(from store: AgentCredentialStore) throws -> String {
        guard let saved = try store.loadAPIKey() else {
            throw CloudVoiceServiceError.missingCredential
        }
        return try AgentCredentialValidator.normalizedAPIKey(saved)
    }

    static func text(_ raw: String, maximumBytes: Int) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CloudVoiceServiceError.invalidText
        }
        return value
    }

    static func identifier(_ raw: String, maximumBytes: Int) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CloudVoiceServiceError.invalidIdentifier
        }
        return value
    }

    static func safePathSegment(_ raw: String, maximumBytes: Int) throws -> String {
        let value = try identifier(raw, maximumBytes: maximumBytes)
        guard value.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "-" || scalar == "_"
            )
        }) else {
            throw CloudVoiceServiceError.invalidIdentifier
        }
        return value
    }

    static func language(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 16,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "-" || scalar == "_"
                  )
              }) else {
            throw CloudVoiceServiceError.invalidLanguage
        }
        return value
    }

    static func audioRequest(_ request: CloudTranscriptionRequest) throws -> AudioFile {
        guard !request.audioData.isEmpty,
              request.audioData.count <= maximumAudioInputBytes else {
            throw CloudVoiceServiceError.invalidAudio
        }
        let filename = sanitizedFilename(request.filename)
        guard !filename.isEmpty, filename.utf8.count <= 128 else {
            throw CloudVoiceServiceError.invalidFilename
        }
        let mimeType = request.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = mimeType.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              ["audio", "video"].contains(String(parts[0])),
              parts[1].count <= 64,
              parts[1].allSatisfy({ character in
                  character.isASCII && (
                      character.isLetter || character.isNumber
                          || character == "." || character == "+" || character == "-"
                  )
              }) else {
            throw CloudVoiceServiceError.invalidMIMEType
        }
        return .init(data: request.audioData, filename: filename, mimeType: mimeType)
    }

    static func request(url: URL, method: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = method
        return request
    }

    static func successData(
        _ response: OpenAITransportResponse,
        maximumBytes: Int
    ) throws -> Data {
        guard response.data.count <= maximumBytes else {
            throw CloudVoiceServiceError.responseTooLarge
        }
        guard (200..<300).contains(response.response.statusCode) else {
            throw CloudVoiceServiceError.httpError(response.response.statusCode)
        }
        return response.data
    }

    static func transcription(from response: OpenAITransportResponse) throws -> CloudTranscription {
        let data = try successData(response, maximumBytes: maximumJSONResponseBytes)
        let envelope: TextEnvelope
        do {
            envelope = try JSONDecoder().decode(TextEnvelope.self, from: data)
        } catch {
            throw CloudVoiceServiceError.malformedResponse
        }
        let value = envelope.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CloudVoiceServiceError.missingTranscript }
        guard value.utf8.count <= maximumTranscriptBytes else {
            throw CloudVoiceServiceError.responseTooLarge
        }
        return .init(text: value)
    }

    static func multipart(fields: [String: String], file: AudioFile) throws -> Multipart {
        let boundary = "CodexCompanion-\(UUID().uuidString)"
        var data = Data()
        func append(_ string: String) {
            data.append(Data(string.utf8))
        }
        for key in fields.keys.sorted() {
            guard let value = fields[key],
                  !key.isEmpty,
                  !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw CloudVoiceServiceError.invalidIdentifier
            }
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(file.filename)\"\r\n")
        append("Content-Type: \(file.mimeType)\r\n\r\n")
        data.append(file.data)
        append("\r\n--\(boundary)--\r\n")
        guard data.count <= maximumAudioInputBytes + 8_192 else {
            throw CloudVoiceServiceError.requestTooLarge
        }
        return .init(
            data: data,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    static func uuid(_ raw: String) throws -> String {
        guard UUID(uuidString: raw) != nil else {
            throw CloudVoiceServiceError.malformedResponse
        }
        return raw.lowercased()
    }

    private static func sanitizedFilename(_ raw: String) -> String {
        let component = (raw as NSString).lastPathComponent
        return String(component.unicodeScalars.map { scalar in
            if scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "." || scalar == "-" || scalar == "_"
            ) {
                return Character(scalar)
            }
            return "_"
        })
    }
}

private struct GeminiAudioEnvelope: Decodable {
    struct OutputAudio: Decodable { let data: String }
    let outputAudio: OutputAudio

    enum CodingKeys: String, CodingKey {
        case outputAudio = "output_audio"
    }
}

private struct TextEnvelope: Decodable {
    let text: String
}

private struct IdentifierEnvelope: Decodable {
    let id: String
}

private struct JobEnvelope: Decodable {
    let id: String
    let status: String
}
