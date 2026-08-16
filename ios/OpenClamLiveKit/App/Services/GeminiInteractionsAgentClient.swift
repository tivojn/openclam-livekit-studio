import Foundation

/// Stateless Gemini Interactions adapter. The complete step history is sent with `store=false`;
/// provider-side conversation retention is never required for the local iPhone agent loop.
struct GeminiInteractionsAgentClient: LLMAgentClient, Sendable {
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!

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
        var steps = try initialSteps(from: input)
        let system = try systemInstruction(from: input, explicit: instructions)
        let allowedToolNames = Set(tools.map(\.name))
        var seenCallIDs = Set<String>()
        var requestCount = 0
        var toolRoundCount = 0

        while true {
            try Task.checkCancellation()
            let request = try makeRequest(
                apiKey: apiKey,
                steps: steps,
                system: system,
                tools: tools
            )
            let transportResponse = try await transport.send(request)
            requestCount += 1
            let response = try decode(transportResponse)
            let parsed = try parse(response.steps)

            guard !parsed.calls.isEmpty else {
                guard response.status == "completed" else {
                    throw statusFailure(response.status)
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

            // A synchronous Interactions response authorizes client function execution only in
            // `requires_action`. Never execute residual/partial calls from a failed, cancelled,
            // incomplete, budget-exceeded, in-progress, or otherwise malformed response.
            guard response.status == "requires_action" else {
                throw statusFailure(response.status)
            }
            try validateCalls(
                parsed.calls,
                allowedToolNames: allowedToolNames,
                seenCallIDs: &seenCallIDs,
                toolRoundCount: toolRoundCount
            )
            guard let executor else { throw OpenAIResponsesClientError.missingToolExecutor }

            // Stateless continuation requires every model-generated step exactly as returned,
            // including signatures, followed by matching function_result steps.
            steps.append(contentsOf: response.steps)
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
                steps.append(.object([
                    "type": .string("function_result"),
                    "name": .string(call.name),
                    "call_id": .string(call.callID),
                    "result": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string(output),
                        ]),
                    ]),
                ]))
            }
            toolRoundCount += 1
        }
    }

    private func statusFailure(_ rawStatus: String?) -> OpenAIResponsesClientError {
        let boundedStatus = rawStatus.map { String($0.prefix(128)) }
        switch rawStatus {
        case "failed", "cancelled":
            return .apiFailure(boundedStatus)
        case "incomplete", "budget_exceeded", "in_progress":
            return .incompleteResponse(boundedStatus)
        default:
            // Missing, unknown, or structurally contradictory status values are protocol errors;
            // do not echo arbitrary provider-controlled text into the UI.
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

    private func initialSteps(from input: [OpenAIInputItem]) throws -> [AgentJSONValue] {
        try input.compactMap { item in
            switch item {
            case .message(let role, let text):
                guard role == .user || role == .assistant else { return nil }
                return try textStep(role: role, texts: [text])
            case .contentMessage(let role, let content):
                guard role == .user || role == .assistant else { return nil }
                var texts: [String] = []
                for part in content {
                    switch part {
                    case .inputText(let text):
                        texts.append(text)
                    case .inputImage, .inputFile:
                        throw OpenAIResponsesClientError.invalidInput(
                            "This Gemini agent adapter supports text turns in this build. Choose OpenAI or xAI for this attachment request."
                        )
                    }
                }
                return try textStep(role: role, texts: texts)
            case .responseOutput, .functionCallOutput:
                throw OpenAIResponsesClientError.invalidInput(
                    "Provider-native continuation items cannot be supplied by the conversation."
                )
            }
        }
    }

    private func textStep(role: OpenAIRole, texts: [String]) throws -> AgentJSONValue {
        let content = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { AgentJSONValue.object(["type": .string("text"), "text": .string($0)]) }
        guard !content.isEmpty else {
            throw OpenAIResponsesClientError.invalidInput("A message cannot be empty.")
        }
        return .object([
            "type": .string(role == .assistant ? "model_output" : "user_input"),
            "content": .array(content),
        ])
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
        steps: [AgentJSONValue],
        system: String?,
        tools: [OpenAIFunctionTool]
    ) throws -> URLRequest {
        var body: [String: AgentJSONValue] = [
            "model": .string(model),
            "input": .array(steps),
            "store": .bool(false),
            "generation_config": .object([
                "max_output_tokens": .integer(limits.maxOutputTokens),
                "tool_choice": .string(tools.isEmpty ? "none" : "auto"),
            ]),
        ]
        if let system { body["system_instruction"] = .string(system) }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object([
                    "type": .string("function"),
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.parameters,
                ])
            })
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
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    private func decode(_ transportResponse: OpenAITransportResponse) throws -> Response {
        guard transportResponse.data.count <= limits.maxResponseBytes else {
            throw OpenAIResponsesClientError.responseTooLarge
        }
        guard (200..<300).contains(transportResponse.response.statusCode) else {
            throw OpenAIResponsesClientError.httpError(
                statusCode: transportResponse.response.statusCode,
                requestID: transportResponse.response
                    .value(forHTTPHeaderField: "x-request-id")
                    .map { String($0.prefix(256)) },
                message: nil
            )
        }
        do {
            return try JSONDecoder().decode(Response.self, from: transportResponse.data)
        } catch {
            throw OpenAIResponsesClientError.malformedResponse
        }
    }

    private func parse(_ steps: [AgentJSONValue]) throws -> Parsed {
        var texts: [String] = []
        var calls: [OpenAIToolCall] = []
        for step in steps {
            guard let object = step.objectValue,
                  let type = object["type"]?.stringValue else { continue }
            if type == "model_output" {
                for content in object["content"]?.arrayValue ?? [] {
                    guard let contentObject = content.objectValue,
                          contentObject["type"]?.stringValue == "text",
                          let text = contentObject["text"]?.stringValue else { continue }
                    texts.append(text)
                }
            } else if type == "function_call" {
                guard let id = object["id"]?.stringValue?.nonEmptyGeminiValue,
                      let name = object["name"]?.stringValue?.nonEmptyGeminiValue,
                      let arguments = object["arguments"]?.objectValue else {
                    throw OpenAIResponsesClientError.malformedToolCall
                }
                let raw = try jsonString(.object(arguments))
                calls.append(.init(callID: id, name: name, arguments: arguments, rawArguments: raw))
            }
        }
        return .init(text: texts.joined(separator: "\n"), calls: calls)
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
}

private extension GeminiInteractionsAgentClient {
    struct Response: Decodable {
        let id: String?
        let status: String?
        let steps: [AgentJSONValue]
    }

    struct Parsed {
        let text: String
        let calls: [OpenAIToolCall]
    }
}

private extension String {
    var nonEmptyGeminiValue: String? { isEmpty ? nil : self }
}
