import Foundation

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var content: String
    public var images: [Data] = []  // PNG/JPEG bytes
    public var toolCalls: [ToolCall] = []
    public var toolName: String? = nil

    public init(role: Role, content: String, images: [Data] = [], toolCalls: [ToolCall] = [], toolName: String? = nil) {
        self.role = role
        self.content = content
        self.images = images
        self.toolCalls = toolCalls
        self.toolName = toolName
    }

    public static func system(_ s: String) -> Self { .init(role: .system, content: s) }
    public static func user(_ s: String, images: [Data] = []) -> Self { .init(role: .user, content: s, images: images) }
    public static func assistant(_ s: String, toolCalls: [ToolCall] = []) -> Self {
        .init(role: .assistant, content: s, toolCalls: toolCalls)
    }
    public static func tool(_ name: String, _ s: String) -> Self { .init(role: .tool, content: s, toolName: name) }
}

public struct ToolCall: Sendable, Equatable {
    public var name: String
    public var arguments: JSONValue
    public init(name: String, arguments: JSONValue) {
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONValue  // JSON Schema object
    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ChatReply: Sendable, Equatable {
    public var content: String
    public var toolCalls: [ToolCall]
    public init(content: String, toolCalls: [ToolCall] = []) {
        self.content = content
        self.toolCalls = toolCalls
    }
}

/// Chat completion backend. Two implementations: Ollama (live) and scripted fakes in tests.
public protocol LLM: Sendable {
    /// `onToken` receives streamed assistant text deltas (never tool-call JSON).
    func chat(
        model: String, messages: [ChatMessage], tools: [ToolSpec], temperature: Double,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> ChatReply
}

extension LLM {
    public func complete(model: String, system: String, user: String, temperature: Double = 0.2) async throws -> String {
        try await chat(model: model, messages: [.system(system), .user(user)], tools: [], temperature: temperature, onToken: nil)
            .content
    }
}

public struct LLMError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Ollama `/api/chat` client (streaming NDJSON).
public struct OllamaClient: LLM {
    public var baseURL: URL
    public var keepAlive: String
    public static let contextLength = 16384

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, keepAlive: String = "10m") {
        self.baseURL = baseURL
        self.keepAlive = keepAlive
    }

    func requestBody(model: String, messages: [ChatMessage], tools: [ToolSpec], temperature: Double) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "keep_alive": keepAlive,
            "options": ["temperature": temperature, "num_ctx": Self.contextLength],
            "messages": messages.map { m -> [String: Any] in
                var d: [String: Any] = ["role": m.role.rawValue, "content": m.content]
                if !m.images.isEmpty { d["images"] = m.images.map { $0.base64EncodedString() } }
                if !m.toolCalls.isEmpty {
                    d["tool_calls"] = m.toolCalls.map { tc in
                        ["function": ["name": tc.name, "arguments": jsonObject(tc.arguments)]]
                    }
                }
                if let n = m.toolName { d["tool_name"] = n }
                return d
            },
        ]
        // Hidden reasoning costs ~4 s before the first token (measured: gemma4 polish 4.35 s → 0.33 s).
        // Voice UX needs fast answers; non-thinking models accept the flag too (verified).
        body["think"] = false
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                [
                    "type": "function",
                    "function": ["name": t.name, "description": t.description, "parameters": jsonObject(t.parameters)],
                ]
            }
        }
        return body
    }

    public func chat(
        model: String, messages: [ChatMessage], tools: [ToolSpec], temperature: Double,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> ChatReply {
        var req = URLRequest(url: baseURL.appending(path: "api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(model: model, messages: messages, tools: tools, temperature: temperature))

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw LLMError(message: "Ollama \(http.statusCode): \(text.prefix(300))")
        }
        var content = ""
        var calls: [ToolCall] = []
        for try await line in bytes.lines {
            let chunk = try Self.parseChunk(line)
            if let err = chunk.error { throw LLMError(message: "Ollama: \(err)") }
            if !chunk.delta.isEmpty {
                content += chunk.delta
                onToken?(chunk.delta)
            }
            calls += chunk.toolCalls
            if chunk.done { break }
        }
        return ChatReply(content: Self.stripThinking(content), toolCalls: calls)
    }

    struct Chunk { var delta = ""; var toolCalls: [ToolCall] = []; var done = false; var error: String? }

    static func parseChunk(_ line: String) throws -> Chunk {
        guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return Chunk() }
        var c = Chunk()
        c.error = obj["error"] as? String
        c.done = obj["done"] as? Bool ?? false
        if let msg = obj["message"] as? [String: Any] {
            c.delta = msg["content"] as? String ?? ""
            for tc in msg["tool_calls"] as? [[String: Any]] ?? [] {
                guard let fn = tc["function"] as? [String: Any], let name = fn["name"] as? String else { continue }
                var args = JSONValue(any: fn["arguments"])
                // Some models emit arguments as a JSON string.
                if case .string(let s) = args, let d = s.data(using: .utf8),
                    let o = try? JSONSerialization.jsonObject(with: d)
                {
                    args = JSONValue(any: o)
                }
                c.toolCalls.append(ToolCall(name: name, arguments: args))
            }
        }
        return c
    }

    /// Remove `<think>…</think>` blocks some models inline in content.
    static func stripThinking(_ s: String) -> String {
        guard let r = s.range(of: "</think>") else { return s }
        return String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Loads a model into memory so the first real request is fast.
    public func warmUp(model: String) async throws {
        var req = URLRequest(url: baseURL.appending(path: "api/generate"))
        req.httpMethod = "POST"
        // Same num_ctx as chat requests, otherwise Ollama reloads the model on the first real call.
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": keepAlive, "options": ["num_ctx": Self.contextLength]])
        _ = try await URLSession.shared.data(for: req)
    }

    /// Returns installed model names.
    public func models() async throws -> [String] {
        let (data, resp) = try await URLSession.shared.data(from: baseURL.appending(path: "api/tags"))
        try requireOK(resp, "Ollama")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }
}

func jsonObject(_ v: JSONValue) -> Any {
    switch v {
    case .string(let s): s
    case .number(let n): n
    case .bool(let b): b
    case .null: NSNull()
    case .array(let a): a.map(jsonObject)
    case .object(let o): o.mapValues(jsonObject)
    }
}

/// Throws on a non-2xx HTTP response, so errors (401, 404) don't read as empty results.
func requireOK(_ response: URLResponse, _ what: String) throws {
    guard let code = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) else { return }
    throw LLMError(message: code == 401 || code == 403 ? "\(what) rejected the API key (\(code))." : "\(what) returned HTTP \(code). Check the URL.")
}
