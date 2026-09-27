import Foundation

/// Something the UI can render under an agent answer.
public struct Card: Sendable, Equatable, Identifiable {
    public struct Row: Sendable, Equatable, Hashable {
        public var title: String
        public var detail: String?
        public var url: URL?
        public init(_ title: String, detail: String? = nil, url: URL? = nil) {
            self.title = title
            self.detail = detail
            self.url = url
        }
    }
    public var id = UUID()
    public var icon: String  // SF Symbol
    public var title: String
    public var rows: [Row]
    public var imageData: Data? = nil
    public init(icon: String, title: String, rows: [Row] = [], imageData: Data? = nil) {
        self.icon = icon
        self.title = title
        self.rows = rows
        self.imageData = imageData
    }
}

public struct ToolResult: Sendable {
    /// What the model sees.
    public var text: String
    public var card: Card?
    public init(_ text: String, card: Card? = nil) {
        self.text = text
        self.card = card
    }
}

/// A capability the agent can call. One concrete type for native, web and MCP tools.
public struct Tool: Sendable {
    public var spec: ToolSpec
    /// Integration id used for confirmation bypass & UI grouping, e.g. "reminders", "mcp.google".
    public var integration: String
    /// Writes (send/create/modify/delete) require confirmation unless bypassed.
    public var isWrite: Bool
    /// Can deliver data to an attacker-reachable destination or persist beyond this conversation (arbitrary URLs,
    /// other apps, MCP servers, messages, schedules). Confirmed once the conversation contains untrusted content,
    /// so injected instructions can't exfiltrate or plant anything silently. Fixed-host lookups (search, weather) aren't egress.
    public var egress: Bool
    /// Output may contain third-party text (web pages, email, files, messages, MCP results) → taints the conversation.
    public var untrusted: Bool
    /// False for actions that must always be confirmed, even if the user bypassed the integration.
    public var allowBypass: Bool
    public var run: @Sendable (JSONValue) async throws -> ToolResult
    /// Human-readable description of what will happen, for the confirmation card.
    public var preview: @Sendable (JSONValue) -> String

    public init(
        name: String, description: String, parameters: JSONValue = Schema.object([:]), integration: String,
        isWrite: Bool = false, egress: Bool = false, untrusted: Bool = false, allowBypass: Bool = true,
        preview: (@Sendable (JSONValue) -> String)? = nil,
        run: @escaping @Sendable (JSONValue) async throws -> ToolResult
    ) {
        self.egress = egress
        self.untrusted = untrusted
        self.allowBypass = allowBypass
        self.spec = ToolSpec(name: name, description: description, parameters: parameters)
        self.integration = integration
        self.isWrite = isWrite
        self.run = run
        self.preview = preview ?? { args in Tool.defaultPreview(name: name, args: args) }
    }

    public var name: String { spec.name }

    static func defaultPreview(name: String, args: JSONValue) -> String {
        guard case .object(let o) = args, !o.isEmpty else { return name }
        return o.keys.sorted().map { k in "\(k): \(o[k]!.stringValue ?? o[k]!.description)" }.joined(separator: "\n")
    }
}

/// Tiny JSON-Schema builder for tool parameters.
public enum Schema {
    public static func object(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) })])
    }
    public static func string(_ d: String) -> JSONValue { ["type": "string", "description": .string(d)] }
    public static func integer(_ d: String) -> JSONValue { ["type": "integer", "description": .string(d)] }
    public static func number(_ d: String) -> JSONValue { ["type": "number", "description": .string(d)] }
    public static func boolean(_ d: String) -> JSONValue { ["type": "boolean", "description": .string(d)] }
    public static func enumeration(_ d: String, _ values: [String]) -> JSONValue {
        ["type": "string", "description": .string(d), "enum": .array(values.map { .string($0) })]
    }
    public static func array(_ d: String, of item: JSONValue = ["type": "string"]) -> JSONValue {
        ["type": "array", "description": .string(d), "items": item]
    }
}

public struct ConfirmRequest: Sendable, Identifiable {
    public var id = UUID()
    public var toolName: String
    public var integration: String
    public var summary: String
    /// False when "Always allow" must not be offered (non-bypassable tools, egress after untrusted content).
    public var canAlwaysAllow = true
    public init(toolName: String, integration: String, summary: String, canAlwaysAllow: Bool = true) {
        self.canAlwaysAllow = canAlwaysAllow
        self.toolName = toolName
        self.integration = integration
        self.summary = summary
    }
}

public enum AgentEvent: Sendable {
    case token(String)
    case toolStarted(String)
    case card(Card)
}

/// Multi-turn tool-calling loop. Holds the conversation until `reset()`.
public actor Agent {
    /// Whether the calling run had outside content, readable by tools (e.g. `remember` records it).
    @TaskLocal public static var runTainted = false
    public let llm: any LLM
    public var model: String
    public var tools: [Tool]
    public var bypass: Set<String>
    public var maxRounds = 8
    private(set) public var messages: [ChatMessage] = []
    /// Bumped by each send/cancel; a run stops as soon as it is no longer the latest.
    private var runID = 0
    /// True once untrusted content entered the conversation (see `Tool.untrusted`); cleared by `reset()`.
    private(set) public var tainted: Bool

    public typealias Confirm = @Sendable (ConfirmRequest) async -> Bool
    public typealias Emit = @Sendable (AgentEvent) -> Void

    /// `tainted: true` for unattended runs (scheduled tasks), whose instructions may come from untrusted content.
    public init(llm: any LLM, model: String, tools: [Tool], bypass: Set<String> = [], tainted: Bool = false) {
        self.tainted = tainted
        self.llm = llm
        self.model = model
        self.tools = tools
        self.bypass = bypass
    }

    public func configure(model: String, tools: [Tool], bypass: Set<String>) {
        self.model = model
        self.tools = tools
        self.bypass = bypass
    }

    /// Starts a fresh conversation. Also supersedes any run still in flight, so it can't keep going untainted.
    public func reset() {
        runID += 1
        messages = []
        tainted = false
    }

    /// Untrusted content entered the context outside a tool (screenshot, selected text, MCP tool descriptions).
    public func markTainted() { tainted = true }

    /// Runs one user turn to completion. Returns the final assistant text.
    public func send(_ text: String, images: [Data] = [], system: String, confirm: @escaping Confirm, emit: @escaping Emit) async throws -> String {
        runID += 1
        let myRun = runID
        // Old screenshots are stale context and cost tokens; keep only the newest.
        messages = messages.map {
            var m = $0; m.images = []; return m
        }
        if messages.first?.role == .system { messages[0] = .system(system) } else { messages.insert(.system(system), at: 0) }
        // A stopped run can leave tool calls without results; strict OpenAI-compatible servers reject that history.
        if let i = messages.lastIndex(where: { !$0.toolCalls.isEmpty }) {
            let answered = messages[(i + 1)...].prefix { $0.role == .tool }.count
            let missing = messages[i].toolCalls.dropFirst(answered)
            messages.insert(
                contentsOf: missing.map { .tool($0.name, "Stopped by the user; this may not have run. Don't retry without asking.") }, at: i + 1 + answered)
        }
        messages.append(.user(text, images: images))

        let specs = tools.map(\.spec)
        for _ in 0..<maxRounds {
            if myRun != runID || Task.isCancelled { return "" }
            var reply = try await llm.chat(model: model, messages: messages, tools: specs, temperature: 0.3) { t in emit(.token(t)) }
            // Never after untrusted content: an echoed injected JSON blob must not become a tool call.
            if reply.toolCalls.isEmpty, !tainted, let inline = Self.inlineToolCall(reply.content, known: Set(tools.map(\.name))) {
                reply = ChatReply(content: "", toolCalls: [inline])
            }
            if myRun != runID || Task.isCancelled { return "" }
            messages.append(.assistant(reply.content, toolCalls: reply.toolCalls))
            if reply.toolCalls.isEmpty { return reply.content }

            for call in reply.toolCalls {
                if myRun != runID || Task.isCancelled { return "" }
                let result = await execute(call, confirm: confirm, isCurrent: { myRun == self.runID }, emit: emit)
                // A newer send may have started while this tool ran; appending now would interleave conversations.
                if myRun != runID { return "" }
                messages.append(.tool(call.name, result))  // even after Stop: the action may have happened
                if Task.isCancelled { return "" }
            }
        }
        return "I stopped after too many steps."
    }

    /// Confirmation policy (ADR-0006): writes unless bypassed (and bypass allowed); egress once tainted.
    func needsConfirmation(_ tool: Tool) -> Bool {
        // Bypass is honored only in clean conversations: injected instructions must never ride on "don't ask".
        (tool.isWrite && !(tool.allowBypass && !tainted && bypass.contains(tool.integration))) || (tool.egress && tainted)
    }

    func execute(_ call: ToolCall, confirm: Confirm, isCurrent: () -> Bool, emit: Emit) async -> String {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            return "Error: unknown tool '\(call.name)'. Available: \(tools.map(\.name).joined(separator: ", "))"
        }
        if needsConfirmation(tool) {
            var summary = tool.preview(call.arguments)
            if !tool.isWrite { summary += "\n\n⚠︎ Asked after reading outside content — check this is what you want." }
            let ok = await confirm(
                ConfirmRequest(
                    toolName: tool.name, integration: tool.integration, summary: summary, canAlwaysAllow: tool.isWrite && tool.allowBypass && !tool.egress))
            // Approval of a superseded run must not execute its action.
            guard ok, isCurrent(), !Task.isCancelled else { return "The user declined this action. Do not retry it; acknowledge briefly." }
        }
        defer { if tool.untrusted { tainted = true } }
        emit(.toolStarted(tool.name))
        let start = Date()
        do {
            let result = try await Agent.$runTainted.withValue(tainted) { try await tool.run(call.arguments) }
            Telemetry.shared.timing(.agent, "tool_done", seconds: Date().timeIntervalSince(start), ["tool": tool.name, "ok": "true"])
            if let card = result.card { emit(.card(card)) }
            return String(result.text.prefix(12_000))
        } catch {
            // Error *type* only — messages can echo user data.
            Telemetry.shared.timing(
                .agent, "tool_done", seconds: Date().timeIntervalSince(start), ["tool": tool.name, "ok": "false", "error": String(describing: type(of: error))])
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Some models print `{"name": ..., "arguments": {...}}` as text instead of a native tool call.
    static func inlineToolCall(_ content: String, known: Set<String>) -> ToolCall? {
        var s = content.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "^```(json)?|```$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "</?tool_call>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("{"), s.hasSuffix("}"),
            let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
            let name = obj["name"] as? String, known.contains(name)
        else { return nil }
        return ToolCall(name: name, arguments: JSONValue(any: obj["arguments"] ?? obj["parameters"] ?? [:]))
    }
}
