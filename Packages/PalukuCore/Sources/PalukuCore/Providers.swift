import Foundation

public enum ModelProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case ollama, openAICompatible
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-compatible (LM Studio, llama.cpp, MLX, Jan, vLLM)"
        }
    }
}

/// Anything that can list its models.
public protocol ModelLister: Sendable {
    func models() async throws -> [String]
}

extension OllamaClient: ModelLister {}

public enum LLMFactory {
    public static func make(_ s: Settings, apiKey: String? = nil) -> any LLM & ModelLister {
        switch s.provider {
        case .ollama:
            OllamaClient(baseURL: URL(string: s.ollamaURL) ?? URL(string: "http://127.0.0.1:11434")!)
        case .openAICompatible:
            OpenAICompatibleClient(baseURL: URL(string: s.openAIBaseURL) ?? URL(string: "http://127.0.0.1:1234/v1")!, apiKey: apiKey)
        }
    }
}

/// OpenAI Chat Completions client for local open-model servers (LM Studio, llama.cpp server, MLX-LM, Jan, vLLM, Ollama /v1).
/// Spec: https://platform.openai.com/docs/api-reference/chat/create
public struct OpenAICompatibleClient: LLM, ModelLister {
    public var baseURL: URL  // e.g. http://127.0.0.1:1234/v1
    public var apiKey: String?

    public init(baseURL: URL, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    static func requestBody(model: String, messages: [ChatMessage], tools: [ToolSpec], temperature: Double) -> [String: Any] {
        // Tool-call ids: our ChatMessage has none, so derive them per assistant message and hand them
        // to the following tool messages in order (the Agent always appends results in call order).
        var pendingIDs: [String] = []
        var out: [[String: Any]] = []
        for (i, m) in messages.enumerated() {
            var d: [String: Any] = ["role": m.role.rawValue]
            if m.images.isEmpty {
                d["content"] = m.content
            } else {
                d["content"] =
                    [["type": "text", "text": m.content]]
                    + m.images.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]] }
            }
            if !m.toolCalls.isEmpty {
                pendingIDs = m.toolCalls.indices.map { "call_\(i)_\($0)" }
                d["tool_calls"] = zip(pendingIDs, m.toolCalls).map { id, tc in
                    ["id": id, "type": "function", "function": ["name": tc.name, "arguments": tc.arguments.description]]
                }
            }
            if m.role == .tool {
                d["tool_call_id"] = pendingIDs.isEmpty ? "call_unknown" : pendingIDs.removeFirst()
                if let n = m.toolName { d["name"] = n }
            }
            out.append(d)
        }
        var body: [String: Any] = ["model": model, "messages": out, "stream": true, "temperature": temperature]
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                ["type": "function", "function": ["name": t.name, "description": t.description, "parameters": jsonObject(t.parameters)]]
            }
        }
        return body
    }

    /// Folds Server-Sent-Event lines into a reply; returns any new text delta.
    struct StreamAccumulator {
        var content = ""
        var calls: [Int: (name: String, args: String)] = [:]
        var ids: [String: Int] = [:]
        var done = false

        mutating func consume(_ line: String) throws -> String? {
            guard line.hasPrefix("data:") else { return nil }  // comments / keep-alives
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                done = true
                return nil
            }
            guard let obj = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
            if let err = obj["error"] {
                throw LLMError(message: ((err as? [String: Any])?["message"] as? String) ?? String(describing: err))
            }
            guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return nil }
            if choice["finish_reason"] is String { done = true }
            let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] ?? [:]
            for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                // Some servers omit `index`; a new `id` then starts a new call instead of merging into slot 0.
                let id = tc["id"] as? String
                let idx: Int
                if let i = tc["index"] as? Int {
                    idx = i
                } else if let id, !id.isEmpty {
                    idx = ids[id] ?? calls.count
                } else {
                    idx = max(0, calls.count - 1)
                }
                if let id, !id.isEmpty { ids[id] = idx }
                let fn = tc["function"] as? [String: Any] ?? [:]
                var cur = calls[idx] ?? ("", "")
                if let n = fn["name"] as? String { cur.name += n }
                if let a = fn["arguments"] as? String { cur.args += a }
                calls[idx] = cur
            }
            if let text = delta["content"] as? String, !text.isEmpty {
                content += text
                return text
            }
            return nil
        }

        var reply: ChatReply {
            let tcs = calls.keys.sorted().compactMap { k -> ToolCall? in
                guard let c = calls[k], !c.name.isEmpty else { return nil }
                let obj = (try? JSONSerialization.jsonObject(with: Data(c.args.utf8))) ?? [String: Any]()
                return ToolCall(name: c.name, arguments: JSONValue(any: obj))
            }
            return ChatReply(content: OllamaClient.stripThinking(content), toolCalls: tcs)
        }
    }

    func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return req
    }

    public func chat(
        model: String, messages: [ChatMessage], tools: [ToolSpec], temperature: Double,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> ChatReply {
        var req = request("chat/completions")
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(model: model, messages: messages, tools: tools, temperature: temperature))
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw LLMError(message: "Server \(http.statusCode): \(text.prefix(300))")
        }
        var acc = StreamAccumulator()
        for try await line in bytes.lines {
            if let t = try acc.consume(line) { onToken?(t) }
            if acc.done { break }
        }
        return acc.reply
    }

    public func models() async throws -> [String] {
        let (data, resp) = try await URLSession.shared.data(for: request("models"))
        try requireOK(resp, "Server")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
    }
}

/// Curated open-weight models that work well with Paluku (tool calling; vision where noted).
public enum ModelCatalog {
    public struct Entry: Sendable, Identifiable, Hashable {
        public var id: String  // ollama tag
        public var summary: String
        public var sizeGB: Double
        public var vision: Bool
    }

    public static let recommended: [Entry] = [
        Entry(id: "gemma4:latest", summary: "Google Gemma 4 — default; tools + vision, 12/12 on Paluku bench", sizeGB: 9.6, vision: true),
        Entry(id: "qwen3:8b", summary: "Alibaba Qwen 3 8B — fast, strong tool calling", sizeGB: 5.2, vision: false),
        Entry(id: "qwen3:30b-a3b", summary: "Qwen 3 MoE 30B — smarter, needs ~20 GB RAM", sizeGB: 18.6, vision: false),
        Entry(id: "qwen2.5vl:7b", summary: "Qwen 2.5 VL — vision for screen questions", sizeGB: 6.0, vision: true),
        Entry(id: "llama3.2:3b", summary: "Meta Llama 3.2 3B — tiny, quick dictation polish", sizeGB: 2.0, vision: false),
        Entry(id: "mistral-small3.2:24b", summary: "Mistral Small 3.2 — tools + vision, needs ~16 GB", sizeGB: 15.0, vision: true),
        Entry(id: "gpt-oss:20b", summary: "OpenAI gpt-oss 20B open-weight — strong reasoning + tools", sizeGB: 13.0, vision: false),
    ]
}

// MARK: - Ollama model management

public struct PullProgress: Sendable, Equatable {
    public var status: String
    public var total: Int64?
    public var completed: Int64?
    public var fraction: Double? {
        guard let total, total > 0, let completed else { return nil }
        return Double(completed) / Double(total)
    }
    public var isSuccess: Bool { status == "success" }
    public init(status: String, total: Int64? = nil, completed: Int64? = nil) {
        self.status = status
        self.total = total
        self.completed = completed
    }
}

extension OllamaClient {
    static func parsePull(_ line: String) throws -> PullProgress {
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] ?? [:]
        if let e = obj["error"] as? String { throw LLMError(message: e) }
        return PullProgress(
            status: obj["status"] as? String ?? "", total: (obj["total"] as? NSNumber)?.int64Value, completed: (obj["completed"] as? NSNumber)?.int64Value)
    }

    /// Streams `ollama pull` progress. https://docs.ollama.com/api/pull
    public func pull(_ model: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appending(path: "api/pull"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 3600
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines where !line.isEmpty {
                        cont.yield(try Self.parsePull(line))
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Deletes a local model. https://docs.ollama.com/api/delete
    public func delete(_ model: String) async throws {
        var req = URLRequest(url: baseURL.appending(path: "api/delete"))
        req.httpMethod = "DELETE"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
        let (_, r) = try await URLSession.shared.data(for: req)
        if let http = r as? HTTPURLResponse, http.statusCode != 200 { throw LLMError(message: "Delete failed (\(http.statusCode))") }
    }
}
