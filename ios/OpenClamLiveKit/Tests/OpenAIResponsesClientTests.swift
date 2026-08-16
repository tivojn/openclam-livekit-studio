import Foundation
import UIKit
import XCTest
@testable import OpenClamLiveKit

final class OpenAIResponsesClientTests: XCTestCase {
    func testTypedMessageEncodesResponsesContentPartsAndKeepsStringAPI() throws {
        let imageDataURL = "data:image/jpeg;base64,\(Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString())"
        let fileDataURL = "data:application/pdf;base64,\(Data("%PDF".utf8).base64EncodedString())"
        let item = OpenAIInputItem.message(
            role: .user,
            contentParts: [
                .inputText("Compare these inputs."),
                .inputImage(imageURL: imageDataURL, detail: .high),
                .inputFile(filename: "notes.pdf", fileData: fileDataURL),
            ]
        )

        let object = try jsonObject(JSONEncoder().encode(item))
        XCTAssertEqual(object["role"] as? String, "user")
        let content = try XCTUnwrap(object["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[0]["text"] as? String, "Compare these inputs.")
        XCTAssertEqual(content[1]["type"] as? String, "input_image")
        XCTAssertEqual(content[1]["image_url"] as? String, imageDataURL)
        XCTAssertEqual(content[1]["detail"] as? String, "high")
        XCTAssertEqual(content[2]["type"] as? String, "input_file")
        XCTAssertEqual(content[2]["filename"] as? String, "notes.pdf")
        XCTAssertEqual(content[2]["file_data"] as? String, fileDataURL)

        let legacy = try jsonObject(
            JSONEncoder().encode(OpenAIInputItem.message(role: .user, content: "Still text"))
        )
        XCTAssertEqual(legacy["content"] as? String, "Still text")
    }

    @MainActor
    func testToolFreeAttachmentTurnSendsMediaExactlyOnce() async throws {
        let transport = StubResponsesTransport(
            responses: [
                .json(
                    """
                    {
                      "id": "resp_attachment",
                      "status": "completed",
                      "output": [{
                        "type": "message",
                        "role": "assistant",
                        "content": [{"type": "output_text", "text": "Attachment analyzed."}]
                      }]
                    }
                    """
                ),
            ]
        )
        let client = try makeClient(apiKey: "sk-test", transport: transport)
        let mediaURL = "data:image/jpeg;base64,\(Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString())"

        let result = try await client.respond(
            input: [
                .message(
                    role: .user,
                    contentParts: [
                        .inputText("Describe this image."),
                        .inputImage(imageURL: mediaURL),
                    ]
                ),
            ],
            tools: ConversationModel.attachmentTools,
            executor: nil
        )

        XCTAssertEqual(result.requestCount, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.first?.httpBody)
        let object = try jsonObject(body)
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(
            content.filter { $0["image_url"] as? String == mediaURL }.count,
            1
        )
        XCTAssertTrue((object["tools"] as? [[String: Any]])?.isEmpty ?? true)
    }

    func testTypedMessageRejectsMalformedPartsBeforeTransport() async throws {
        let transport = StubResponsesTransport(responses: [])
        let client = OpenAIResponsesClient(
            configuration: try .init(maxInputCharacters: 1_000),
            credentialStore: MemoryAgentCredentialStore(apiKey: "sk-test"),
            transport: transport
        )

        do {
            _ = try await client.respond(
                input: [
                    .message(
                        role: .user,
                        contentParts: [.inputImage(imageURL: "file:///private/image.jpg")]
                    ),
                ]
            )
            XCTFail("Expected malformed image input to be rejected.")
        } catch let error as OpenAIResponsesClientError {
            guard case .invalidInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let malformedRequests = await transport.recordedRequests()
        XCTAssertTrue(malformedRequests.isEmpty)
    }

    func testTypedMessageBase64PayloadIsBoundedBeforeTransport() async throws {
        let transport = StubResponsesTransport(responses: [])
        let client = OpenAIResponsesClient(
            configuration: try .init(maxInputCharacters: 1_000),
            credentialStore: MemoryAgentCredentialStore(apiKey: "sk-test"),
            transport: transport
        )
        let oversized = "data:application/pdf;base64,"
            + Data(repeating: 0x61, count: 900).base64EncodedString()

        do {
            _ = try await client.respond(
                input: [
                    .message(
                        role: .user,
                        contentParts: [
                            .inputText("Read this."),
                            .inputFile(filename: "large.pdf", fileData: oversized),
                        ]
                    ),
                ]
            )
            XCTFail("Expected the encoded request limit to reject this payload.")
        } catch let error as OpenAIResponsesClientError {
            XCTAssertEqual(error, .inputLimitExceeded)
        }
        let oversizedRequests = await transport.recordedRequests()
        XCTAssertTrue(oversizedRequests.isEmpty)
    }

    @MainActor
    func testAttachmentPreparationSupportsImageAndExplicitFileThenCleansUp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFile = root.appendingPathComponent("notes.pdf")
        try Data("%PDF-1.7\nattachment test".utf8).write(to: sourceFile)
        let service = try AttachmentPreparationService(temporaryRoot: root)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).jpegData(
            withCompressionQuality: 0.8
        ) { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        }

        let stagedImage = try await service.stageImage(
            data: image,
            filename: "photo.heic",
            sourceMIMEType: "image/heic"
        )
        let stagedFile = try await service.stageFile(
            at: sourceFile,
            mimeType: "application/pdf"
        )
        let stagedCopy = try XCTUnwrap(stagedFile.localFileURL)
        XCTAssertNotEqual(stagedCopy, sourceFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedCopy.path))

        let prepared = try await service.prepare([stagedImage, stagedFile])
        XCTAssertEqual(prepared.map(\.kind), [.image, .file])
        XCTAssertEqual(prepared[0].contentParts.count, 1)
        if case .inputImage(let dataURL, let detail) = prepared[0].contentParts[0] {
            XCTAssertTrue(dataURL.hasPrefix("data:image/jpeg;base64,"))
            XCTAssertEqual(detail, .auto)
        } else {
            XCTFail("Expected a prepared image input.")
        }
        if case .inputFile(let filename, let fileData) = prepared[1].contentParts[0] {
            XCTAssertEqual(filename, "notes.pdf")
            XCTAssertTrue(fileData.hasPrefix("data:application/pdf;base64,"))
        } else {
            XCTFail("Expected a prepared file input.")
        }

        await service.remove(stagedFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedCopy.path))
    }

    @MainActor
    func testVideoPreparationProducesOnlyRepresentativeJPEGFrames() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceVideo = root.appendingPathComponent("clip.mov")
        try Data(repeating: 0x5A, count: 1_024).write(to: sourceVideo)
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).jpegData(
            withCompressionQuality: 0.75
        ) { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let extractor = StubAgentVideoFrameExtractor(
            extraction: .init(duration: 12, jpegFrames: [frame, frame])
        )
        let service = try AttachmentPreparationService(
            temporaryRoot: root,
            videoFrameExtractor: extractor
        )
        let staged = try await service.stageVideo(
            at: sourceVideo,
            mimeType: "video/quicktime"
        )

        let prepared = try await service.prepare([staged])
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared[0].kind, .video)
        XCTAssertEqual(prepared[0].contentParts.count, 2)
        XCTAssertTrue(prepared[0].contentParts.allSatisfy { part in
            guard case .inputImage(let dataURL, _) = part else { return false }
            return dataURL.hasPrefix("data:image/jpeg;base64,")
        })
        await service.remove(staged)
    }

    @MainActor
    func testFileStagingRejectsOversizedPrivateCopyAndRemovesIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFile = root.appendingPathComponent("provider-document.pdf")
        try Data("%PDF-small-preflight".utf8).write(to: sourceFile)
        var limits = AttachmentPreparationLimits.standard
        limits.maximumFileBytes = 100_000
        let service = try AttachmentPreparationService(
            limits: limits,
            temporaryRoot: root,
            fileManager: CopyReplacingFileManager(copiedByteCount: 100_001)
        )

        do {
            _ = try await service.stageFile(
                at: sourceFile,
                mimeType: "application/pdf"
            )
            XCTFail("Expected the actual private copy to be rejected as oversized.")
        } catch let error as AttachmentPreparationError {
            XCTAssertEqual(error, .fileTooLarge(maximumBytes: 100_000))
        }

        let stagingDirectory = await service.stagingDirectory
        let stagedItems = try FileManager.default.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(stagedItems.isEmpty, "An oversized private copy must not remain on disk.")
    }

    @MainActor
    func testVideoStagingRejectsOversizedPrivateCopyAndRemovesIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceVideo = root.appendingPathComponent("provider-video.mov")
        try Data(repeating: 0x45, count: 32).write(to: sourceVideo)
        var limits = AttachmentPreparationLimits.standard
        limits.maximumVideoSourceBytes = 1_000_000
        let service = try AttachmentPreparationService(
            limits: limits,
            temporaryRoot: root,
            fileManager: CopyReplacingFileManager(copiedByteCount: 1_000_001)
        )

        do {
            _ = try await service.stageVideo(
                at: sourceVideo,
                mimeType: "video/quicktime"
            )
            XCTFail("Expected the actual private video copy to be rejected as oversized.")
        } catch let error as AttachmentPreparationError {
            XCTAssertEqual(error, .videoTooLarge(maximumBytes: 1_000_000))
        }

        let stagingDirectory = await service.stagingDirectory
        let stagedItems = try FileManager.default.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(stagedItems.isEmpty, "An oversized private video must not remain on disk.")
    }

    @MainActor
    func testFileStagingRejectsCopiedMetadataMismatchAndRemovesIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFile = root.appendingPathComponent("changing-document.txt")
        let sourceData = Data("initial provider bytes".utf8)
        try sourceData.write(to: sourceFile)
        let service = try AttachmentPreparationService(
            temporaryRoot: root,
            fileManager: CopyReplacingFileManager(copiedByteCount: sourceData.count + 1)
        )

        do {
            _ = try await service.stageFile(at: sourceFile, mimeType: "text/plain")
            XCTFail("Expected copied byte-count mismatch to be rejected.")
        } catch let error as AttachmentPreparationError {
            XCTAssertEqual(error, .invalidFile)
        }

        let stagingDirectory = await service.stagingDirectory
        let stagedItems = try FileManager.default.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(stagedItems.isEmpty, "A mismatched private copy must not remain on disk.")
    }

    func testToolLoopUsesFlatSchemaPreservesOutputAndDisablesStorage() async throws {
        let apiKey = "sk-test-secret-value"
        let transport = StubResponsesTransport(
            responses: [
                .json(
                    #"""
                    {
                      "id": "resp_tool",
                      "status": "completed",
                      "output": [
                        {
                          "type": "function_call",
                          "call_id": "call_1",
                          "name": "search_nearby_places",
                          "arguments": "{\"query\":\"McDonald's\"}"
                        }
                      ]
                    }
                    """#
                ),
                .json(
                    """
                    {
                      "id": "resp_final",
                      "status": "completed",
                      "output": [
                        {
                          "type": "message",
                          "role": "assistant",
                          "content": [
                            {"type": "output_text", "text": "The nearest one is two blocks away."}
                          ]
                        }
                      ]
                    }
                    """
                ),
            ]
        )
        let executor = RecordingToolExecutor(
            result: .object([
                "name": .string("McDonald's"),
                "distance_meters": .integer(240),
            ])
        )
        let client = try makeClient(
            apiKey: apiKey,
            transport: transport
        )

        let result = try await client.respond(
            input: [.message(role: .user, content: "Find the nearest McDonald's")],
            instructions: "Use a tool only when it is needed.",
            tools: [try nearbyTool()],
            executor: executor
        )

        XCTAssertEqual(result.text, "The nearest one is two blocks away.")
        XCTAssertEqual(result.responseID, "resp_final")
        XCTAssertEqual(result.toolRoundCount, 1)
        XCTAssertEqual(result.requestCount, 2)

        let calls = await executor.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "search_nearby_places")
        XCTAssertEqual(calls.first?.arguments["query"], .string("McDonald's"))

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        let firstRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(firstRequest.url, OpenAIResponsesConfiguration.defaultEndpoint)
        XCTAssertEqual(firstRequest.httpMethod, "POST")
        XCTAssertEqual(
            firstRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(apiKey)"
        )
        let firstBodyData = try XCTUnwrap(firstRequest.httpBody)
        let firstBodyText = try XCTUnwrap(String(data: firstBodyData, encoding: .utf8))
        XCTAssertFalse(firstBodyText.contains(apiKey))

        let firstBody = try jsonObject(firstBodyData)
        XCTAssertEqual(firstBody["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(firstBody["store"] as? Bool, false)
        XCTAssertEqual(firstBody["parallel_tool_calls"] as? Bool, false)
        let tools = try XCTUnwrap(firstBody["tools"] as? [[String: Any]])
        let encodedTool = try XCTUnwrap(tools.first)
        XCTAssertEqual(encodedTool["type"] as? String, "function")
        XCTAssertEqual(encodedTool["name"] as? String, "search_nearby_places")
        XCTAssertNil(encodedTool["function"])
        XCTAssertEqual(encodedTool["strict"] as? Bool, true)

        let secondRequest = requests[1]
        let secondBody = try jsonObject(try XCTUnwrap(secondRequest.httpBody))
        let secondInput = try XCTUnwrap(secondBody["input"] as? [[String: Any]])
        XCTAssertEqual(secondInput.count, 3)
        XCTAssertEqual(secondInput[1]["type"] as? String, "function_call")
        XCTAssertEqual(secondInput[1]["call_id"] as? String, "call_1")
        XCTAssertEqual(secondInput[2]["type"] as? String, "function_call_output")
        XCTAssertEqual(secondInput[2]["call_id"] as? String, "call_1")
        XCTAssertNotNil(secondInput[2]["output"] as? String)
    }

    func testUnknownToolFailsClosedBeforeAnyExecutorRuns() async throws {
        let transport = StubResponsesTransport(
            responses: [
                .json(
                    """
                    {
                      "id": "resp_unknown",
                      "status": "completed",
                      "output": [
                        {
                          "type": "function_call",
                          "call_id": "call_unknown",
                          "name": "delete_everything",
                          "arguments": "{}"
                        }
                      ]
                    }
                    """
                ),
            ]
        )
        let executor = RecordingToolExecutor(result: .string("unused"))
        let client = try makeClient(apiKey: "sk-test", transport: transport)

        do {
            _ = try await client.respond(
                input: [.message(role: .user, content: "Do something")],
                tools: [try nearbyTool()],
                executor: executor
            )
            XCTFail("Expected the unknown tool to be rejected.")
        } catch let error as OpenAIResponsesClientError {
            XCTAssertEqual(error, .unknownTool("delete_everything"))
        }

        let calls = await executor.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testResidualToolCallsRequireExactCompletedResponseStatus() async throws {
        let nonCompletedStatuses: [String?] = [
            "failed",
            "incomplete",
            "queued",
            "in_progress",
            "requires_action",
            "cancelled",
            "unknown_future_status",
            nil,
        ]

        for status in nonCompletedStatuses {
            let statusField = status.map { #""status":"\#($0)","# } ?? ""
            let transport = StubResponsesTransport(responses: [
                .json(
                    #"""
                    {
                      "id":"resp_nonterminal",
                      \#(statusField)
                      "output":[{
                        "type":"function_call",
                        "call_id":"call_must_not_run",
                        "name":"search_nearby_places",
                        "arguments":"{\"query\":\"coffee\"}"
                      }]
                    }
                    """#
                ),
            ])
            let executor = RecordingToolExecutor(result: .string("unexpected"))
            let client = try makeClient(apiKey: "sk-test", transport: transport)

            do {
                _ = try await client.respond(
                    input: [.message(role: .user, content: "Find coffee")],
                    tools: [try nearbyTool()],
                    executor: executor
                )
                XCTFail("Expected status \(status ?? "missing") to fail closed")
            } catch let error as OpenAIResponsesClientError {
                XCTAssertLessThanOrEqual(error.localizedDescription.utf8.count, 256)
            }

            let calls = await executor.recordedCalls()
            XCTAssertTrue(calls.isEmpty, "Status \(status ?? "missing") must execute no tools")
        }
    }

    func testToolRoundLimitBoundsRequestsAndExecutions() async throws {
        let transport = StubResponsesTransport(
            responses: [
                .json(toolCallResponse(id: "resp_1", callID: "call_1")),
                .json(toolCallResponse(id: "resp_2", callID: "call_2")),
            ]
        )
        let executor = RecordingToolExecutor(result: .object(["ok": .bool(true)]))
        let configuration = try OpenAIResponsesConfiguration(maxToolRounds: 1)
        let client = OpenAIResponsesClient(
            configuration: configuration,
            credentialStore: MemoryAgentCredentialStore(apiKey: "sk-test"),
            transport: transport
        )

        do {
            _ = try await client.respond(
                input: [.message(role: .user, content: "Find one")],
                tools: [try nearbyTool()],
                executor: executor
            )
            XCTFail("Expected the bounded tool loop to stop.")
        } catch let error as OpenAIResponsesClientError {
            XCTAssertEqual(error, .toolRoundLimitExceeded(1))
        }

        let calls = await executor.recordedCalls()
        let requests = await transport.recordedRequests()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(requests.count, 2)
    }

    func testToolCallIDCannotBeReusedAcrossRounds() async throws {
        let transport = StubResponsesTransport(
            responses: [
                .json(toolCallResponse(id: "resp_1", callID: "reused_call")),
                .json(toolCallResponse(id: "resp_2", callID: "reused_call")),
            ]
        )
        let executor = RecordingToolExecutor(result: .object(["ok": .bool(true)]))
        let client = try makeClient(apiKey: "sk-test", transport: transport)

        do {
            _ = try await client.respond(
                input: [.message(role: .user, content: "Find coffee")],
                tools: [try nearbyTool()],
                executor: executor
            )
            XCTFail("Expected the reused call identifier to be rejected.")
        } catch let error as OpenAIResponsesClientError {
            XCTAssertEqual(error, .duplicateToolCallID)
        }

        let calls = await executor.recordedCalls()
        XCTAssertEqual(calls.count, 1)
    }

    func testHTTPErrorRedactsCredential() async throws {
        let apiKey = "sk-sensitive-test-key"
        let body = try JSONSerialization.data(
            withJSONObject: ["error": ["message": "Bad key: \(apiKey)"]]
        )
        let transport = StubResponsesTransport(
            responses: [.init(data: body, statusCode: 401, headers: ["x-request-id": "req_1"])]
        )
        let client = try makeClient(apiKey: apiKey, transport: transport)

        do {
            _ = try await client.respond(
                input: [.message(role: .user, content: "Hello")]
            )
            XCTFail("Expected an HTTP error.")
        } catch let error as OpenAIResponsesClientError {
            guard case .httpError(let status, let requestID, let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(requestID, "req_1")
            XCTAssertEqual(message, "Bad key: [REDACTED]")
            XCTAssertFalse(error.localizedDescription.contains(apiKey))
        }
    }

    func testServerControlledErrorFieldsAreRedactedAndBounded() async throws {
        let apiKey = "test-sensitive-server-echo"
        let oversizedReason = "Reason \(apiKey) " + String(repeating: "x", count: 2_000)
        let transport = StubResponsesTransport(
            responses: [
                .init(
                    data: Data(#"{"error":{"message":"Request failed"}}"#.utf8),
                    statusCode: 429,
                    headers: [
                        "x-request-id": "echo-\(apiKey)-" + String(repeating: "r", count: 2_000),
                    ]
                ),
                .json(
                    """
                    {
                      "id": "resp_incomplete",
                      "status": "incomplete",
                      "incomplete_details": {"reason": \(try jsonString(oversizedReason))},
                      "output": []
                    }
                    """
                ),
            ]
        )
        let client = try makeClient(apiKey: apiKey, transport: transport)

        do {
            _ = try await client.respond(input: [.message(role: .user, content: "Hello")])
            XCTFail("Expected an HTTP error.")
        } catch let error as OpenAIResponsesClientError {
            guard case .httpError(_, let requestID, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(try XCTUnwrap(requestID).contains(apiKey))
            XCTAssertLessThanOrEqual(try XCTUnwrap(requestID).count, 1_000)
            XCTAssertFalse(error.localizedDescription.contains(apiKey))
        }

        do {
            _ = try await client.respond(input: [.message(role: .user, content: "Hello again")])
            XCTFail("Expected an incomplete response.")
        } catch let error as OpenAIResponsesClientError {
            guard case .incompleteResponse(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(try XCTUnwrap(reason).contains(apiKey))
            XCTAssertLessThanOrEqual(try XCTUnwrap(reason).count, 1_000)
            XCTAssertFalse(error.localizedDescription.contains(apiKey))
        }
    }

    func testStrictToolSchemaRejectsAdditionalProperties() {
        let invalidSchema = AgentJSONValue.object([
            "type": .string("object"),
            "properties": .object(["query": .object(["type": .string("string")])]),
            "required": .array([.string("query")]),
        ])

        XCTAssertThrowsError(
            try OpenAIFunctionTool(
                name: "search",
                description: "Search for a place.",
                parameters: invalidSchema
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenAIToolDefinitionError,
                .additionalPropertiesMustBeFalse(path: "parameters")
            )
        }
    }

    func testConfigurationRejectsAnEndpointThatCouldExposeTheKey() throws {
        let insecureURL = try XCTUnwrap(URL(string: "http://example.com/v1/responses"))
        XCTAssertThrowsError(try OpenAIResponsesConfiguration(endpoint: insecureURL)) { error in
            XCTAssertEqual(
                error as? OpenAIResponsesConfigurationError,
                .insecureEndpoint
            )
        }
    }

    func testCredentialValidationNeverIncludesTheCredentialInErrors() {
        let invalidKey = "sk-secret with-space"
        XCTAssertThrowsError(try AgentCredentialValidator.normalizedAPIKey(invalidKey)) { error in
            XCTAssertEqual(error as? AgentCredentialStoreError, .invalidAPIKey)
            XCTAssertFalse(error.localizedDescription.contains(invalidKey))
        }
    }

    private func makeClient(
        apiKey: String,
        transport: StubResponsesTransport
    ) throws -> OpenAIResponsesClient {
        OpenAIResponsesClient(
            configuration: try .init(),
            credentialStore: MemoryAgentCredentialStore(apiKey: apiKey),
            transport: transport
        )
    }

    private func nearbyTool() throws -> OpenAIFunctionTool {
        try .init(
            name: "search_nearby_places",
            description: "Search for nearby places only after location permission is available.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("The business or place to find."),
                    ]),
                ]),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func toolCallResponse(id: String, callID: String) -> String {
        #"""
        {
          "id": "\#(id)",
          "status": "completed",
          "output": [
            {
              "type": "function_call",
              "call_id": "\#(callID)",
              "name": "search_nearby_places",
              "arguments": "{\"query\":\"coffee\"}"
            }
          ]
        }
        """#
    }
}

private struct MemoryAgentCredentialStore: AgentCredentialStore {
    let apiKey: String?

    func saveAPIKey(_ apiKey: String) throws {}

    func loadAPIKey() throws -> String? {
        apiKey
    }

    func deleteAPIKey() throws {}
}

private actor RecordingToolExecutor: OpenAIToolExecutor {
    private var calls: [OpenAIToolCall] = []
    private let result: AgentJSONValue

    init(result: AgentJSONValue) {
        self.result = result
    }

    func execute(_ call: OpenAIToolCall) async throws -> AgentJSONValue {
        calls.append(call)
        return result
    }

    func recordedCalls() -> [OpenAIToolCall] {
        calls
    }
}

private actor StubResponsesTransport: OpenAIResponsesTransport {
    struct Stub: Sendable {
        let data: Data
        let statusCode: Int
        let headers: [String: String]

        static func json(_ value: String) -> Stub {
            .init(
                data: Data(value.utf8),
                statusCode: 200,
                headers: [:]
            )
        }
    }

    private var responses: [Stub]
    private var requests: [URLRequest] = []

    init(responses: [Stub]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> OpenAITransportResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw StubError.missingResponse
        }
        let stub = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        return .init(data: stub.data, response: response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    enum StubError: Error {
        case missingResponse
    }
}

private struct StubAgentVideoFrameExtractor: AgentVideoFrameExtracting {
    let extraction: AgentVideoFrameExtraction

    func extractRepresentativeJPEGFrames(
        from url: URL,
        limits: AttachmentPreparationLimits
    ) async throws -> AgentVideoFrameExtraction {
        extraction
    }
}

private final class CopyReplacingFileManager: FileManager, @unchecked Sendable {
    private let copiedByteCount: Int

    init(copiedByteCount: Int) {
        self.copiedByteCount = copiedByteCount
        super.init()
    }

    override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try super.copyItem(at: sourceURL, to: destinationURL)
        try Data(repeating: 0x58, count: copiedByteCount).write(to: destinationURL)
    }
}
