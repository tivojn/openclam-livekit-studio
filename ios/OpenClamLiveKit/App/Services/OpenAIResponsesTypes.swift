import Foundation

indirect enum AgentJSONValue: Codable, Equatable, Sendable {
    case object([String: AgentJSONValue])
    case array([AgentJSONValue])
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AgentJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AgentJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var objectValue: [String: AgentJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [AgentJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}

enum OpenAIRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case developer
    case system
}

enum OpenAIInputItem: Encodable, Equatable, Sendable {
    case message(role: OpenAIRole, content: String)
    case contentMessage(role: OpenAIRole, content: [OpenAIInputContentPart])
    case responseOutput(AgentJSONValue)
    case functionCallOutput(callID: String, output: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case role
        case content
        case callID = "call_id"
        case output
    }

    static func message(
        role: OpenAIRole,
        contentParts: [OpenAIInputContentPart]
    ) -> Self {
        .contentMessage(role: role, content: contentParts)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .message(let role, let content):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
        case .contentMessage(let role, let content):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
        case .responseOutput(let value):
            try value.encode(to: encoder)
        case .functionCallOutput(let callID, let output):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("function_call_output", forKey: .type)
            try container.encode(callID, forKey: .callID)
            try container.encode(output, forKey: .output)
        }
    }
}

struct OpenAIFunctionTool: Encodable, Equatable, Sendable {
    let type = "function"
    let name: String
    let description: String
    let parameters: AgentJSONValue
    let strict = true

    init(name: String, description: String, parameters: AgentJSONValue) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedNameCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        )
        guard (1...64).contains(trimmedName.count),
              trimmedName.unicodeScalars.allSatisfy({
                  allowedNameCharacters.contains($0)
              }) else {
            throw OpenAIToolDefinitionError.invalidName
        }
        guard !trimmedDescription.isEmpty else {
            throw OpenAIToolDefinitionError.emptyDescription
        }
        try OpenAIToolSchemaValidator.validate(parameters)
        self.name = trimmedName
        self.description = trimmedDescription
        self.parameters = parameters
    }
}

enum OpenAIToolDefinitionError: Error, Equatable {
    case invalidName
    case emptyDescription
    case rootMustBeObject
    case missingProperties(path: String)
    case additionalPropertiesMustBeFalse(path: String)
    case requiredMustContainEveryProperty(path: String)
    case arrayItemsMissing(path: String)
}

extension OpenAIToolDefinitionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Tool names may contain only letters, numbers, underscores, and hyphens."
        case .emptyDescription:
            return "Every tool needs a description."
        case .rootMustBeObject:
            return "A strict tool schema must have an object at its root."
        case .missingProperties(let path):
            return "The object schema at \(path) is missing properties."
        case .additionalPropertiesMustBeFalse(let path):
            return "The object schema at \(path) must disable additional properties."
        case .requiredMustContainEveryProperty(let path):
            return "Every property in the strict object schema at \(path) must be required."
        case .arrayItemsMissing(let path):
            return "The array schema at \(path) is missing its item schema."
        }
    }
}

struct OpenAIToolCall: Equatable, Sendable {
    let callID: String
    let name: String
    let arguments: [String: AgentJSONValue]
    let rawArguments: String
}

/// Tool implementations should stage consequential work for user review instead of silently
/// sending messages, placing orders, or committing another irreversible action.
protocol OpenAIToolExecutor: Sendable {
    func execute(_ call: OpenAIToolCall) async throws -> AgentJSONValue
}

struct ClosureOpenAIToolExecutor: OpenAIToolExecutor, Sendable {
    private let handler: @Sendable (OpenAIToolCall) async throws -> AgentJSONValue

    init(_ handler: @escaping @Sendable (OpenAIToolCall) async throws -> AgentJSONValue) {
        self.handler = handler
    }

    func execute(_ call: OpenAIToolCall) async throws -> AgentJSONValue {
        try await handler(call)
    }
}

struct OpenAIResponsesResult: Equatable, Sendable {
    let text: String
    let responseID: String?
    let toolRoundCount: Int
    let requestCount: Int
}

struct OpenAIResponsesConfiguration: Equatable, Sendable {
    static let defaultEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let defaultModel = "gpt-5.6-luna"
    static let defaultMaxInputBytes = 8_000_000
    static let maximumMaxInputBytes = 12_000_000

    let endpoint: URL
    let model: String
    let requestTimeout: TimeInterval
    let maxOutputTokens: Int
    let maxToolRounds: Int
    let maxToolCallsPerRound: Int
    let maxResponseBytes: Int
    let maxToolOutputBytes: Int
    let maxInputItems: Int
    let maxInputCharacters: Int

    init(
        endpoint: URL = OpenAIResponsesConfiguration.defaultEndpoint,
        model: String = OpenAIResponsesConfiguration.defaultModel,
        requestTimeout: TimeInterval = 60,
        maxOutputTokens: Int = 4_096,
        maxToolRounds: Int = 4,
        maxToolCallsPerRound: Int = 4,
        maxResponseBytes: Int = 2_000_000,
        maxToolOutputBytes: Int = 64_000,
        maxInputItems: Int = 128,
        maxInputCharacters: Int = OpenAIResponsesConfiguration.defaultMaxInputBytes
    ) throws {
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.host?.isEmpty == false,
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil else {
            throw OpenAIResponsesConfigurationError.insecureEndpoint
        }

        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty,
              normalizedModel.count <= 128,
              !normalizedModel.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw OpenAIResponsesConfigurationError.invalidModel
        }
        guard (5...180).contains(requestTimeout) else {
            throw OpenAIResponsesConfigurationError.invalidRequestTimeout
        }
        guard (64...16_384).contains(maxOutputTokens) else {
            throw OpenAIResponsesConfigurationError.invalidOutputTokenLimit
        }
        guard (0...8).contains(maxToolRounds) else {
            throw OpenAIResponsesConfigurationError.invalidToolRoundLimit
        }
        guard (1...8).contains(maxToolCallsPerRound) else {
            throw OpenAIResponsesConfigurationError.invalidToolCallLimit
        }
        guard (1_024...10_000_000).contains(maxResponseBytes),
              (256...1_000_000).contains(maxToolOutputBytes),
              (1...256).contains(maxInputItems),
              (1_000...OpenAIResponsesConfiguration.maximumMaxInputBytes)
                  .contains(maxInputCharacters) else {
            throw OpenAIResponsesConfigurationError.invalidSizeLimit
        }

        self.endpoint = endpoint
        self.model = normalizedModel
        self.requestTimeout = requestTimeout
        self.maxOutputTokens = maxOutputTokens
        self.maxToolRounds = maxToolRounds
        self.maxToolCallsPerRound = maxToolCallsPerRound
        self.maxResponseBytes = maxResponseBytes
        self.maxToolOutputBytes = maxToolOutputBytes
        self.maxInputItems = maxInputItems
        self.maxInputCharacters = maxInputCharacters
    }
}

enum OpenAIResponsesConfigurationError: Error, Equatable {
    case insecureEndpoint
    case invalidModel
    case invalidRequestTimeout
    case invalidOutputTokenLimit
    case invalidToolRoundLimit
    case invalidToolCallLimit
    case invalidSizeLimit
}

extension OpenAIResponsesConfigurationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .insecureEndpoint:
            return "The Responses endpoint must be an HTTPS URL without credentials, a query, or a fragment."
        case .invalidModel:
            return "Enter a valid model name."
        case .invalidRequestTimeout:
            return "The request timeout must be between 5 and 180 seconds."
        case .invalidOutputTokenLimit:
            return "The output token limit must be between 64 and 16,384."
        case .invalidToolRoundLimit:
            return "The tool round limit must be between 0 and 8."
        case .invalidToolCallLimit:
            return "The per-round tool call limit must be between 1 and 8."
        case .invalidSizeLimit:
            return "One or more response, tool-output, or input limits are invalid."
        }
    }
}

private enum OpenAIToolSchemaValidator {
    static func validate(_ schema: AgentJSONValue) throws {
        guard let root = schema.objectValue,
              root["type"]?.stringValue == "object" else {
            throw OpenAIToolDefinitionError.rootMustBeObject
        }
        try validateNode(schema, path: "parameters")
    }

    private static func validateNode(_ node: AgentJSONValue, path: String) throws {
        guard let object = node.objectValue else { return }

        if schema(object, includesType: "object") {
            guard let properties = object["properties"]?.objectValue else {
                throw OpenAIToolDefinitionError.missingProperties(path: path)
            }
            guard object["additionalProperties"]?.boolValue == false else {
                throw OpenAIToolDefinitionError.additionalPropertiesMustBeFalse(path: path)
            }
            let required = object["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard required.count == Set(required).count,
                  Set(required) == Set(properties.keys) else {
                throw OpenAIToolDefinitionError.requiredMustContainEveryProperty(path: path)
            }
            for (name, propertySchema) in properties {
                try validateNode(propertySchema, path: "\(path).properties.\(name)")
            }
        }

        if schema(object, includesType: "array") {
            guard let items = object["items"] else {
                throw OpenAIToolDefinitionError.arrayItemsMissing(path: path)
            }
            try validateNode(items, path: "\(path).items")
        }

        if let alternatives = object["anyOf"]?.arrayValue {
            for (index, alternative) in alternatives.enumerated() {
                try validateNode(alternative, path: "\(path).anyOf[\(index)]")
            }
        }
    }

    private static func schema(
        _ object: [String: AgentJSONValue],
        includesType expectedType: String
    ) -> Bool {
        if object["type"]?.stringValue == expectedType {
            return true
        }
        return object["type"]?.arrayValue?.contains(.string(expectedType)) == true
    }
}
