import Foundation

/// Claude Messages adapter for the same typed, locally authorized tool loop used by the
/// Responses client. Tool execution remains sequential and bounded so a provider switch cannot
/// turn a reviewed iPhone proposal into an unreviewed side effect.
struct AnthropicMessagesAgentClient: LLMAgentClient, Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private let model: String
    private let credentialStore: AgentCredentialStore
    private let transport: OpenAIResponsesTransport
    private let limits: OpenAIResponsesConfiguration

    init(
        model: String,
        credentialStore: AgentCredentialStore,
        transport: OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport(),
        limits: OpenAIResponsesConfiguration? = nil
    ) throws {
        let runtimeLimits = try limits ?? OpenAIResponsesConfiguration(
            endpoint: Self.endpoint,
            model: model
        )
        guard runtimeLimits.endpoint == Self.endpoint else {
            throw OpenAIResponsesConfigurationError.insecureEndpoint
        }
        self.model = runtimeLimits.model
        self.credentialStore = credentialStore
        self.transport = transport
        self.limits = runtimeLimits
    }

    func respond(
        input: [OpenAIInputItem],
        instructions: String?,
        tools: [OpenAIFunctionTool],
        executor: OpenAIToolExecutor?
    ) async throws -> OpenAIResponsesResult {
        try validate(input: input, instructions: instructions, tools: tools, executor: executor)
        guard let savedKey = try credentialStore.loadAPIKey() else {
            throw OpenAIResponsesClientError.missingAPIKey
        }
        let apiKey = try AgentCredentialValidator.normalizedAPIKey(savedKey)
        var messages = try initialMessages(from: input)
        let system = try systemInstruction(from: input, explicit: instructions)
        var seenCallIDs = Set<String>()
        let allowedToolNames = Set(tools.map(\.name))
        var requestCount = 0
        var toolRoundCount = 0

        while true {
            try Task.checkCancellation()
            let request = try makeRequest(
                apiKey: apiKey,
                messages: messages,
                system: system,
                tools: tools
            )
            let transportResponse = try await transport.send(request)
            requestCount += 1
            let response = try decode(transportResponse)
            let parsed = try parse(response.content)

            guard !parsed.calls.isEmpty else {
                if response.stopReason == "max_tokens" {
                    throw OpenAIResponsesClientError.incompleteResponse("output token limit")
                }
                let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw OpenAIResponsesClientError.missingAssistantOutput
                }
                return .init(
                    text: text,
                    responseID: response.id,
                    toolRoundCount: toolRoundCount,
                    requestCount: requestCount
                )
            }

            // Anthropic marks a client-side tool handoff with the exact `tool_use` stop reason.
            // Never execute a residual or truncated tool block from any other response state.
            guard response.stopReason == "tool_use" else {
                throw toolStopFailure(response.stopReason)
            }
            try validateCalls(
                parsed.calls,
                allowedToolNames: allowedToolNames,
                seenCallIDs: &seenCallIDs,
                toolRoundCount: toolRoundCount
            )
            guard let executor else { throw OpenAIResponsesClientError.missingToolExecutor }

            // Claude requires the preserved assistant tool_use blocks to be followed immediately
            // by a user message whose tool_result blocks come first. This message contains only
            // results, which is the strictest valid form documented by Anthropic.
            messages.append(.object([
                "role": .string("assistant"),
                "content": .array(response.content),
            ]))
            var results: [AgentJSONValue] = []
            for call in parsed.calls {
                let value: AgentJSONValue
                do {
                    value = try await executor.execute(call)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw OpenAIResponsesClientError.toolExecutionFailed(call.name)
                }
                let output = try serializedToolOutput(value, toolName: call.name)
                results.append(.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(call.callID),
                    "content": .string(output),
                ]))
            }
            messages.append(.object([
                "role": .string("user"),
                "content": .array(results),
            ]))
            toolRoundCount += 1
        }
    }

    private func toolStopFailure(_ stopReason: String?) -> OpenAIResponsesClientError {
        switch stopReason {
        case "max_tokens":
            return .incompleteResponse("output token limit")
        case "model_context_window_exceeded":
            return .incompleteResponse("model context window limit")
        case "pause_turn":
            return .incompleteResponse("provider paused the turn")
        case "refusal":
            return .apiFailure("The model refused the tool request.")
        default:
            // Missing, unknown, or contradictory stop reasons are protocol errors. Avoid echoing
            // arbitrary provider-controlled text into the UI.
            return .malformedResponse
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
        guard input.count <= limits.maxInputItems else {
            throw OpenAIResponsesClientError.inputLimitExceeded
        }
        let names = tools.map(\.name)
        guard names.count == Set(names).count else {
            throw OpenAIResponsesClientError.duplicateToolName
        }
        guard tools.isEmpty || executor != nil else {
            throw OpenAIResponsesClientError.missingToolExecutor
        }
        var totalBytes = instructions?.utf8.count ?? 0
        for item in input {
            let count = try JSONEncoder().encode(item).count
            guard count <= limits.maxInputCharacters - totalBytes else {
                throw OpenAIResponsesClientError.inputLimitExceeded
            }
            totalBytes += count
        }
    }

    private func initialMessages(from input: [OpenAIInputItem]) throws -> [AgentJSONValue] {
        try input.compactMap { item in
            switch item {
            case .message(let role, let text):
                guard role == .user || role == .assistant else { return nil }
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else {
                    throw OpenAIResponsesClientError.invalidInput("A message cannot be empty.")
                }
                return .object([
                    "role": .string(role == .assistant ? "assistant" : "user"),
                    "content": .string(normalized),
                ])
            case .contentMessage(let role, let parts):
                guard role == .user || role == .assistant else { return nil }
                var textParts: [String] = []
                for part in parts {
                    switch part {
                    case .inputText(let text):
                        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !normalized.isEmpty { textParts.append(normalized) }
                    case .inputImage, .inputFile:
                        throw OpenAIResponsesClientError.invalidInput(
                            "This Claude adapter supports agent text turns in this build. Choose OpenAI or xAI for this attachment request."
                        )
                    }
                }
                guard !textParts.isEmpty else {
                    throw OpenAIResponsesClientError.invalidInput("A message cannot be empty.")
                }
                return .object([
                    "role": .string(role == .assistant ? "assistant" : "user"),
                    "content": .string(textParts.joined(separator: "\n")),
                ])
            case .responseOutput, .functionCallOutput:
                throw OpenAIResponsesClientError.invalidInput(
                    "Provider-native continuation items cannot be supplied by the conversation."
                )
            }
        }
    }

    private func systemInstruction(
        from input: [OpenAIInputItem],
        explicit: String?
    ) throws -> String? {
        var parts: [String] = []
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            parts.append(explicit)
        }
        for item in input {
            switch item {
            case .message(let role, let text) where role == .system || role == .developer:
                parts.append(text)
            case .contentMessage(let role, let content) where role == .system || role == .developer:
                for part in content {
                    guard case .inputText(let text) = part else {
                        throw OpenAIResponsesClientError.invalidInput(
                            "System instructions must contain text only."
                        )
                    }
                    parts.append(text)
                }
            default:
                break
            }
        }
        let result = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return result.isEmpty ? nil : result
    }

    private func makeRequest(
        apiKey: String,
        messages: [AgentJSONValue],
        system: String?,
        tools: [OpenAIFunctionTool]
    ) throws -> URLRequest {
        var body: [String: AgentJSONValue] = [
            "model": .string(model),
            "max_tokens": .integer(limits.maxOutputTokens),
            "messages": .array(messages),
        ]
        if let system { body["system"] = .string(system) }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.parameters,
                ])
            })
            body["tool_choice"] = .object([
                "type": .string("auto"),
                "disable_parallel_tool_use": .bool(true),
            ])
        }
        let data = try JSONEncoder().encode(AgentJSONValue.object(body))
        guard data.count <= limits.maxInputCharacters else {
            throw OpenAIResponsesClientError.inputLimitExceeded
        }
        var request = URLRequest(
            url: Self.endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: limits.requestTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    private func decode(_ transportResponse: OpenAITransportResponse) throws -> Response {
        guard transportResponse.data.count <= limits.maxResponseBytes else {
            throw OpenAIResponsesClientError.responseTooLarge
        }
        guard (200..<300).contains(transportResponse.response.statusCode) else {
            throw OpenAIResponsesClientError.httpError(
                statusCode: transportResponse.response.statusCode,
                requestID: boundedHeader("request-id", in: transportResponse.response)
                    ?? boundedHeader("x-request-id", in: transportResponse.response),
                message: nil
            )
        }
        do {
            return try JSONDecoder().decode(Response.self, from: transportResponse.data)
        } catch {
            throw OpenAIResponsesClientError.malformedResponse
        }
    }

    private func parse(_ content: [AgentJSONValue]) throws -> Parsed {
        var text: [String] = []
        var calls: [OpenAIToolCall] = []
        for block in content {
            guard let object = block.objectValue,
                  let type = object["type"]?.stringValue else { continue }
            if type == "text", let value = object["text"]?.stringValue {
                text.append(value)
            } else if type == "tool_use" {
                guard let id = object["id"]?.stringValue?.nonEmptyProviderValue,
                      let name = object["name"]?.stringValue?.nonEmptyProviderValue,
                      let arguments = object["input"]?.objectValue else {
                    throw OpenAIResponsesClientError.malformedToolCall
                }
                let raw = try jsonString(.object(arguments))
                calls.append(.init(callID: id, name: name, arguments: arguments, rawArguments: raw))
            }
        }
        return .init(text: text.joined(separator: "\n"), calls: calls)
    }

    private func validateCalls(
        _ calls: [OpenAIToolCall],
        allowedToolNames: Set<String>,
        seenCallIDs: inout Set<String>,
        toolRoundCount: Int
    ) throws {
        let ids = calls.map(\.callID)
        guard ids.count == Set(ids).count,
              ids.allSatisfy({ seenCallIDs.insert($0).inserted }) else {
            throw OpenAIResponsesClientError.duplicateToolCallID
        }
        guard calls.count <= limits.maxToolCallsPerRound else {
            throw OpenAIResponsesClientError.toolCallLimitExceeded(limits.maxToolCallsPerRound)
        }
        if let unknown = calls.map(\.name).first(where: { !allowedToolNames.contains($0) }) {
            throw OpenAIResponsesClientError.unknownTool(unknown)
        }
        guard toolRoundCount < limits.maxToolRounds else {
            throw OpenAIResponsesClientError.toolRoundLimitExceeded(limits.maxToolRounds)
        }
    }

    private func serializedToolOutput(
        _ value: AgentJSONValue,
        toolName: String
    ) throws -> String {
        let result: String
        if case .string(let text) = value {
            result = text
        } else {
            result = try jsonString(value)
        }
        guard result.utf8.count <= limits.maxToolOutputBytes else {
            throw OpenAIResponsesClientError.toolOutputTooLarge(toolName)
        }
        return result
    }

    private func jsonString(_ value: AgentJSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let result = String(data: data, encoding: .utf8) else {
            throw OpenAIResponsesClientError.malformedResponse
        }
        return result
    }

    private func boundedHeader(_ name: String, in response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: name).map { String($0.prefix(256)) }
    }
}

private extension AnthropicMessagesAgentClient {
    struct Response: Decodable {
        let id: String?
        let stopReason: String?
        let content: [AgentJSONValue]

        enum CodingKeys: String, CodingKey {
            case id
            case stopReason = "stop_reason"
            case content
        }
    }

    struct Parsed {
        let text: String
        let calls: [OpenAIToolCall]
    }
}

private extension String {
    var nonEmptyProviderValue: String? { isEmpty ? nil : self }
}
