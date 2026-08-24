import Foundation

struct OpenAITransportResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

struct OpenAITransportStream: Sendable {
    let lines: AsyncThrowingStream<String, Error>
    let response: HTTPURLResponse
}

protocol OpenAIResponsesTransport: Sendable {
    func send(_ request: URLRequest) async throws -> OpenAITransportResponse
    func stream(_ request: URLRequest) async throws -> OpenAITransportStream
}

extension OpenAIResponsesTransport {
    func stream(_ request: URLRequest) async throws -> OpenAITransportStream {
        let result = try await send(request)
        guard let text = String(data: result.data, encoding: .utf8) else {
            throw OpenAIResponsesTransportError.invalidStreamEncoding
        }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            text.enumerateLines { line, _ in continuation.yield(line) }
            continuation.finish()
        }
        return .init(lines: lines, response: result.response)
    }
}

enum OpenAIResponsesTransportError: Error, Equatable, LocalizedError {
    case nonHTTPResponse
    case invalidStreamEncoding

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            "The model service returned an invalid network response."
        case .invalidStreamEncoding:
            "The model service returned an unreadable stream."
        }
    }
}

final class URLSessionOpenAIResponsesTransport: OpenAIResponsesTransport, @unchecked Sendable {
    private let session: URLSession
    private let redirectDelegate: NoRedirectURLSessionDelegate?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            redirectDelegate = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpShouldSetCookies = false
            configuration.waitsForConnectivity = true

            let delegate = NoRedirectURLSessionDelegate()
            redirectDelegate = delegate
            self.session = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )
        }
    }

    func send(_ request: URLRequest) async throws -> OpenAITransportResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIResponsesTransportError.nonHTTPResponse
        }
        return .init(data: data, response: httpResponse)
    }

    func stream(_ request: URLRequest) async throws -> OpenAITransportStream {
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIResponsesTransportError.nonHTTPResponse
        }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return .init(lines: lines, response: httpResponse)
    }
}

private final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate {
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

struct OpenAIResponsesClient: Sendable {
    let configuration: OpenAIResponsesConfiguration
    private let credentialStore: AgentCredentialStore
    private let transport: OpenAIResponsesTransport
    private let enablesXSearch: Bool

    init(
        configuration: OpenAIResponsesConfiguration,
        credentialStore: AgentCredentialStore,
        transport: OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport(),
        enablesXSearch: Bool = false
    ) {
        self.configuration = configuration
        self.credentialStore = credentialStore
        self.transport = transport
        self.enablesXSearch = enablesXSearch
            && configuration.endpoint == URL(string: "https://api.x.ai/v1/responses")
    }

    func respond(
        input: [OpenAIInputItem],
        instructions: String? = nil,
        tools: [OpenAIFunctionTool] = [],
        executor: OpenAIToolExecutor? = nil
    ) async throws -> OpenAIResponsesResult {
        try validate(input: input, instructions: instructions, tools: tools, executor: executor)

        guard let savedKey = try credentialStore.loadAPIKey() else {
            throw OpenAIResponsesClientError.missingAPIKey
        }
        let apiKey = try AgentCredentialValidator.normalizedAPIKey(savedKey)

        var workingInput = input
        var toolRoundCount = 0
        var requestCount = 0
        var seenToolCallIDs = Set<String>()
        let allowedToolNames = Set(tools.map(\.name))

        while true {
            try Task.checkCancellation()
            try validateInputLimits(workingInput, instructions: instructions)
            let request = try makeRequest(
                apiKey: apiKey,
                input: workingInput,
                instructions: instructions,
                tools: tools
            )
            let transportResponse = try await transport.send(request)
            requestCount += 1
            let apiResponse = try decodeResponse(transportResponse, redacting: apiKey)
            let parsed = try parseOutput(apiResponse.output)

            guard !parsed.calls.isEmpty else {
                let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw OpenAIResponsesClientError.missingAssistantOutput
                }
                return .init(
                    text: text,
                    responseID: apiResponse.id,
                    toolRoundCount: toolRoundCount,
                    requestCount: requestCount
                )
            }

            let callIDs = parsed.calls.map(\.callID)
            guard callIDs.count == Set(callIDs).count else {
                throw OpenAIResponsesClientError.duplicateToolCallID
            }
            guard callIDs.allSatisfy({ seenToolCallIDs.insert($0).inserted }) else {
                throw OpenAIResponsesClientError.duplicateToolCallID
            }
            guard parsed.calls.count <= configuration.maxToolCallsPerRound else {
                throw OpenAIResponsesClientError.toolCallLimitExceeded(
                    configuration.maxToolCallsPerRound
                )
            }
            if let unknownName = parsed.calls.map(\.name).first(where: {
                !allowedToolNames.contains($0)
            }) {
                throw OpenAIResponsesClientError.unknownTool(unknownName)
            }
            guard toolRoundCount < configuration.maxToolRounds else {
                throw OpenAIResponsesClientError.toolRoundLimitExceeded(
                    configuration.maxToolRounds
                )
            }
            guard let executor else {
                throw OpenAIResponsesClientError.missingToolExecutor
            }

            workingInput.append(contentsOf: apiResponse.output.map(OpenAIInputItem.responseOutput))
            for call in parsed.calls {
                try Task.checkCancellation()
                let result: AgentJSONValue
                do {
                    result = try await executor.execute(call)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw OpenAIResponsesClientError.toolExecutionFailed(call.name)
                }

                let output = try serializedToolOutput(result, toolName: call.name)
                workingInput.append(.functionCallOutput(callID: call.callID, output: output))
            }
            toolRoundCount += 1
        }
    }

    func respondStreaming(
        input: [OpenAIInputItem],
        instructions: String?,
        tools: [OpenAIFunctionTool],
        executor: OpenAIToolExecutor?,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> OpenAIResponsesResult {
        try validate(input: input, instructions: instructions, tools: tools, executor: executor)
        guard let savedKey = try credentialStore.loadAPIKey() else {
            throw OpenAIResponsesClientError.missingAPIKey
        }
        let apiKey = try AgentCredentialValidator.normalizedAPIKey(savedKey)
        var workingInput = input
        var toolRoundCount = 0
        var requestCount = 0
        var seenToolCallIDs = Set<String>()
        let allowedToolNames = Set(tools.map(\.name))

        while true {
            try Task.checkCancellation()
            try validateInputLimits(workingInput, instructions: instructions)
            let request = try makeRequest(
                apiKey: apiKey,
                input: workingInput,
                instructions: instructions,
                tools: tools,
                streaming: true
            )
            let transportStream = try await transport.stream(request)
            requestCount += 1
            let apiResponse = try await decodeStream(
                transportStream,
                redacting: apiKey,
                onPartialText: onPartialText
            )
            let parsed = try parseOutput(apiResponse.output)

            guard !parsed.calls.isEmpty else {
                let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw OpenAIResponsesClientError.missingAssistantOutput
                }
                await onPartialText(text)
                return .init(
                    text: text,
                    responseID: apiResponse.id,
                    toolRoundCount: toolRoundCount,
                    requestCount: requestCount
                )
            }

            await onPartialText("")
            let callIDs = parsed.calls.map(\.callID)
            guard callIDs.count == Set(callIDs).count,
                  callIDs.allSatisfy({ seenToolCallIDs.insert($0).inserted }) else {
                throw OpenAIResponsesClientError.duplicateToolCallID
            }
            guard parsed.calls.count <= configuration.maxToolCallsPerRound else {
                throw OpenAIResponsesClientError.toolCallLimitExceeded(
                    configuration.maxToolCallsPerRound
                )
            }
            if let unknownName = parsed.calls.map(\.name).first(where: {
                !allowedToolNames.contains($0)
            }) {
                throw OpenAIResponsesClientError.unknownTool(unknownName)
            }
            guard toolRoundCount < configuration.maxToolRounds else {
                throw OpenAIResponsesClientError.toolRoundLimitExceeded(
                    configuration.maxToolRounds
                )
            }
            guard let executor else {
                throw OpenAIResponsesClientError.missingToolExecutor
            }

            workingInput.append(contentsOf: apiResponse.output.map(OpenAIInputItem.responseOutput))
            for call in parsed.calls {
                try Task.checkCancellation()
                let result: AgentJSONValue
                do {
                    result = try await executor.execute(call)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw OpenAIResponsesClientError.toolExecutionFailed(call.name)
                }
                let output = try serializedToolOutput(result, toolName: call.name)
                workingInput.append(.functionCallOutput(callID: call.callID, output: output))
            }
            toolRoundCount += 1
        }
    }

    private func validate(
        input: [OpenAIInputItem],
        instructions: String?,
        tools: [OpenAIFunctionTool],
        executor: OpenAIToolExecutor?
    ) throws {
        guard !input.isEmpty else {
            throw OpenAIResponsesClientError.invalidInput("At least one input item is required.")
        }
        try validateInputLimits(input, instructions: instructions)

        let names = tools.map(\.name)
        guard names.count == Set(names).count else {
            throw OpenAIResponsesClientError.duplicateToolName
        }
        guard tools.isEmpty || executor != nil else {
            throw OpenAIResponsesClientError.missingToolExecutor
        }
    }

    private func validateInputLimits(
        _ input: [OpenAIInputItem],
        instructions: String?
    ) throws {
        guard input.count <= configuration.maxInputItems else {
            throw OpenAIResponsesClientError.inputLimitExceeded
        }
        guard !input.contains(where: {
            if case .responseOutput(let value) = $0 {
                return value.objectValue == nil
            }
            return false
        }) else {
            throw OpenAIResponsesClientError.invalidInput(
                "A preserved response output item must be a JSON object."
            )
        }
        for item in input {
            guard case .contentMessage(_, let contentParts) = item else { continue }
            guard !contentParts.isEmpty else {
                throw OpenAIResponsesClientError.invalidInput(
                    "A typed input message needs at least one content part."
                )
            }
            guard contentParts.count <= 16 else {
                throw OpenAIResponsesClientError.invalidInput(
                    "A typed input message may contain no more than 16 content parts."
                )
            }
            if let failure = contentParts.lazy.compactMap(\.validationFailure).first {
                throw OpenAIResponsesClientError.invalidInput(failure)
            }
        }

        let encoder = makeEncoder()
        var encodedInputBytes = 0
        for item in input {
            let itemBytes = try encoder.encode(item).count
            guard itemBytes <= configuration.maxInputCharacters - encodedInputBytes else {
                throw OpenAIResponsesClientError.inputLimitExceeded
            }
            encodedInputBytes += itemBytes
        }
        let instructionBytes = instructions?.utf8.count ?? 0
        guard instructionBytes <= configuration.maxInputCharacters - encodedInputBytes else {
            throw OpenAIResponsesClientError.inputLimitExceeded
        }
    }

    private func makeRequest(
        apiKey: String,
        input: [OpenAIInputItem],
        instructions: String?,
        tools: [OpenAIFunctionTool],
        streaming: Bool = false
    ) throws -> URLRequest {
        let body = RequestBody(
            model: configuration.model,
            maxOutputTokens: configuration.maxOutputTokens,
            instructions: instructions?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            input: input,
            tools: requestTools(from: tools),
            toolChoice: tools.isEmpty && !enablesXSearch ? nil : "auto",
            stream: streaming
        )

        var request = URLRequest(
            url: configuration.endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = try makeEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            streaming ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func requestTools(from functionTools: [OpenAIFunctionTool]) -> [ResponsesTool]? {
        var result = functionTools.map(ResponsesTool.function)
        if enablesXSearch {
            result.append(.xSearch)
        }
        return result.isEmpty ? nil : result
    }

    private func decodeResponse(
        _ transportResponse: OpenAITransportResponse,
        redacting apiKey: String
    ) throws -> ResponseBody {
        guard transportResponse.data.count <= configuration.maxResponseBytes else {
            throw OpenAIResponsesClientError.responseTooLarge
        }

        let statusCode = transportResponse.response.statusCode
        let requestID = redactedBoundedServerText(
            transportResponse.response.value(forHTTPHeaderField: "x-request-id"),
            apiKey: apiKey
        )
        guard (200..<300).contains(statusCode) else {
            let errorBody = try? makeDecoder().decode(
                ErrorEnvelope.self,
                from: transportResponse.data
            )
            let message = redactedBoundedServerText(
                errorBody?.error.message,
                apiKey: apiKey
            )
            throw OpenAIResponsesClientError.httpError(
                statusCode: statusCode,
                requestID: requestID,
                message: message
            )
        }

        let response: ResponseBody
        do {
            response = try makeDecoder().decode(ResponseBody.self, from: transportResponse.data)
        } catch {
            throw OpenAIResponsesClientError.malformedResponse
        }

        return try validatedResponse(response, httpResponse: transportResponse.response, apiKey: apiKey)
    }

    private func decodeStream(
        _ transportStream: OpenAITransportStream,
        redacting apiKey: String,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> ResponseBody {
        let statusCode = transportStream.response.statusCode
        let requestID = redactedBoundedServerText(
            transportStream.response.value(forHTTPHeaderField: "x-request-id"),
            apiKey: apiKey
        )
        guard (200..<300).contains(statusCode) else {
            throw OpenAIResponsesClientError.httpError(
                statusCode: statusCode,
                requestID: requestID,
                message: nil
            )
        }
        var consumedBytes = 0
        var cumulativeText = ""
        var completed: ResponseBody?
        for try await rawLine in transportStream.lines {
            try Task.checkCancellation()
            consumedBytes += rawLine.utf8.count + 1
            guard consumedBytes <= configuration.maxResponseBytes else {
                throw OpenAIResponsesClientError.responseTooLarge
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let data = payload.data(using: .utf8) else { continue }
            let event: ResponsesStreamEvent
            do {
                event = try makeDecoder().decode(ResponsesStreamEvent.self, from: data)
            } catch {
                throw OpenAIResponsesClientError.malformedResponse
            }
            switch event.type {
            case "response.output_text.delta", "response.refusal.delta":
                if let delta = event.delta {
                    cumulativeText += delta
                    guard cumulativeText.utf8.count <= configuration.maxResponseBytes else {
                        throw OpenAIResponsesClientError.responseTooLarge
                    }
                    await onPartialText(cumulativeText)
                }
            case "response.completed", "response.failed", "response.incomplete":
                completed = event.response
            case "error":
                throw OpenAIResponsesClientError.apiFailure(
                    redactedBoundedServerText(event.error?.message, apiKey: apiKey)
                )
            default:
                continue
            }
        }
        guard let completed else {
            throw OpenAIResponsesClientError.malformedResponse
        }
        return try validatedResponse(
            completed,
            httpResponse: transportStream.response,
            apiKey: apiKey
        )
    }

    private func validatedResponse(
        _ response: ResponseBody,
        httpResponse: HTTPURLResponse,
        apiKey: String
    ) throws -> ResponseBody {
        if let apiError = response.error {
            throw OpenAIResponsesClientError.apiFailure(
                redactedBoundedServerText(apiError.message, apiKey: apiKey)
            )
        }
        switch response.status {
        case "completed":
            break
        case "failed":
            throw OpenAIResponsesClientError.apiFailure(nil)
        case "incomplete":
            throw OpenAIResponsesClientError.incompleteResponse(
                redactedBoundedServerText(
                    response.incompleteDetails?.reason,
                    apiKey: apiKey
                )
            )
        case "queued", "in_progress", "requires_action":
            throw OpenAIResponsesClientError.incompleteResponse(
                "provider response is not complete"
            )
        case "cancelled":
            throw OpenAIResponsesClientError.apiFailure("The model response was cancelled.")
        default:
            // This client uses the synchronous Responses function-call loop, where both a final
            // message and a function_call output arrive in an exact `completed` response. Never
            // parse residual calls from a missing, unknown, queued, or contradictory status.
            throw OpenAIResponsesClientError.malformedResponse
        }
        return response
    }

    private func redactedBoundedServerText(
        _ text: String?,
        apiKey: String
    ) -> String? {
        guard let text else { return nil }
        let redacted = text.replacingOccurrences(of: apiKey, with: "[REDACTED]")
        return String(redacted.prefix(1_000))
    }

    private func parseOutput(_ output: [AgentJSONValue]) throws -> ParsedOutput {
        var textFragments: [String] = []
        var calls: [OpenAIToolCall] = []

        for item in output {
            guard let object = item.objectValue,
                  let type = object["type"]?.stringValue else {
                continue
            }

            switch type {
            case "message":
                let content = object["content"]?.arrayValue ?? []
                for contentItem in content {
                    guard let contentObject = contentItem.objectValue,
                          let contentType = contentObject["type"]?.stringValue else {
                        continue
                    }
                    if contentType == "output_text",
                       let text = contentObject["text"]?.stringValue {
                        textFragments.append(text)
                    } else if contentType == "refusal",
                              let refusal = contentObject["refusal"]?.stringValue {
                        textFragments.append(refusal)
                    }
                }
            case "function_call":
                guard let callID = object["call_id"]?.stringValue?.nonEmpty,
                      let name = object["name"]?.stringValue?.nonEmpty,
                      let rawArguments = object["arguments"]?.stringValue,
                      let argumentsData = rawArguments.data(using: .utf8),
                      let decodedArguments = try? makeDecoder().decode(
                          AgentJSONValue.self,
                          from: argumentsData
                      ),
                      let arguments = decodedArguments.objectValue else {
                    throw OpenAIResponsesClientError.malformedToolCall
                }
                calls.append(
                    .init(
                        callID: callID,
                        name: name,
                        arguments: arguments,
                        rawArguments: rawArguments
                    )
                )
            default:
                continue
            }
        }

        return .init(text: textFragments.joined(separator: "\n"), calls: calls)
    }

    private func serializedToolOutput(
        _ value: AgentJSONValue,
        toolName: String
    ) throws -> String {
        let output: String
        if case .string(let string) = value {
            output = string
        } else {
            let data = try makeEncoder().encode(value)
            guard let string = String(data: data, encoding: .utf8) else {
                throw OpenAIResponsesClientError.toolExecutionFailed(toolName)
            }
            output = string
        }

        guard output.utf8.count <= configuration.maxToolOutputBytes else {
            throw OpenAIResponsesClientError.toolOutputTooLarge(toolName)
        }
        return output
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

enum OpenAIResponsesClientError: Error, Equatable {
    case missingAPIKey
    case invalidInput(String)
    case inputLimitExceeded
    case duplicateToolName
    case missingToolExecutor
    case responseTooLarge
    case malformedResponse
    case httpError(statusCode: Int, requestID: String?, message: String?)
    case apiFailure(String?)
    case incompleteResponse(String?)
    case malformedToolCall
    case duplicateToolCallID
    case toolCallLimitExceeded(Int)
    case unknownTool(String)
    case toolExecutionFailed(String)
    case toolOutputTooLarge(String)
    case toolRoundLimitExceeded(Int)
    case missingAssistantOutput
}

extension OpenAIResponsesClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an AI provider access key in the AI tab before asking the agent."
        case .invalidInput(let message):
            return message
        case .inputLimitExceeded:
            return "This request is too large. Remove attachments or older conversation content and try again."
        case .duplicateToolName:
            return "The agent has two tools with the same name."
        case .missingToolExecutor:
            return "The agent tools are not connected."
        case .responseTooLarge:
            return "The model response exceeded the app safety limit."
        case .malformedResponse:
            return "The model service returned an unreadable response."
        case .httpError(let statusCode, let requestID, let message):
            var result = "The model service returned HTTP \(statusCode)."
            if let requestID, !requestID.isEmpty {
                result += " Request ID: \(requestID)."
            }
            if let message, !message.isEmpty {
                result += " \(message)"
            }
            return result
        case .apiFailure(let message):
            return message?.nonEmpty ?? "The model could not complete this request."
        case .incompleteResponse(let reason):
            if let reason = reason?.nonEmpty {
                return "The model response was incomplete: \(reason)."
            }
            return "The model response was incomplete."
        case .malformedToolCall:
            return "The model returned an invalid tool request."
        case .duplicateToolCallID:
            return "The model returned duplicate tool call identifiers."
        case .toolCallLimitExceeded(let limit):
            return "The model requested more than \(limit) tools in one round. No tool was run."
        case .unknownTool(let name):
            return "The model requested an unavailable tool named \(name)."
        case .toolExecutionFailed(let name):
            return "The \(name) tool could not complete. No later tool was run."
        case .toolOutputTooLarge(let name):
            return "The \(name) tool returned too much data."
        case .toolRoundLimitExceeded(let limit):
            return "The agent stopped after \(limit) tool rounds."
        case .missingAssistantOutput:
            return "The model returned no answer."
        }
    }
}

private struct RequestBody: Encodable {
    let model: String
    let maxOutputTokens: Int
    let instructions: String?
    let input: [OpenAIInputItem]
    let tools: [ResponsesTool]?
    let toolChoice: String?
    let stream: Bool
    let store = false
    let parallelToolCalls = false

    enum CodingKeys: String, CodingKey {
        case model
        case maxOutputTokens = "max_output_tokens"
        case instructions
        case input
        case tools
        case toolChoice = "tool_choice"
        case stream
        case store
        case parallelToolCalls = "parallel_tool_calls"
    }
}

private enum ResponsesTool: Encodable {
    case function(OpenAIFunctionTool)
    case xSearch

    func encode(to encoder: Encoder) throws {
        switch self {
        case .function(let tool):
            try tool.encode(to: encoder)
        case .xSearch:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("x_search", forKey: .type)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }
}

private struct ResponseBody: Decodable {
    let id: String?
    let status: String?
    let output: [AgentJSONValue]
    let error: APIErrorBody?
    let incompleteDetails: IncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case output
        case error
        case incompleteDetails = "incomplete_details"
    }
}

private struct APIErrorBody: Decodable {
    let message: String
}

private struct ResponsesStreamEvent: Decodable {
    let type: String
    let delta: String?
    let response: ResponseBody?
    let error: APIErrorBody?
}

private struct ErrorEnvelope: Decodable {
    let error: APIErrorBody
}

private struct IncompleteDetails: Decodable {
    let reason: String?
}

private struct ParsedOutput {
    let text: String
    let calls: [OpenAIToolCall]
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
