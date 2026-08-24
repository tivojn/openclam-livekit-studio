import Foundation

/// Provider-neutral boundary used by the conversation agent.
///
/// Every implementation receives the same strictly validated tool definitions and the same
/// executor. Device tools still return reviewed proposals; switching a model provider cannot
/// bypass the app's local authorization or confirmation boundaries.
protocol LLMAgentClient: Sendable {
    func respond(
        input: [OpenAIInputItem],
        instructions: String?,
        tools: [OpenAIFunctionTool],
        executor: OpenAIToolExecutor?
    ) async throws -> OpenAIResponsesResult

    func respondStreaming(
        input: [OpenAIInputItem],
        instructions: String?,
        tools: [OpenAIFunctionTool],
        executor: OpenAIToolExecutor?,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> OpenAIResponsesResult
}

extension LLMAgentClient {
    func respondStreaming(
        input: [OpenAIInputItem],
        instructions: String?,
        tools: [OpenAIFunctionTool],
        executor: OpenAIToolExecutor?,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> OpenAIResponsesResult {
        let result = try await respond(
            input: input,
            instructions: instructions,
            tools: tools,
            executor: executor
        )
        await onPartialText(result.text)
        return result
    }

    func respond(
        input: [OpenAIInputItem],
        instructions: String? = nil
    ) async throws -> OpenAIResponsesResult {
        try await respond(
            input: input,
            instructions: instructions,
            tools: [],
            executor: nil
        )
    }
}

extension OpenAIResponsesClient: LLMAgentClient {}
