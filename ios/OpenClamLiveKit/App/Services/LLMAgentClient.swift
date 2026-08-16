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
}

extension LLMAgentClient {
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
