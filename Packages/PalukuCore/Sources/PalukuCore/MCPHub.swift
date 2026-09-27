import Foundation
import MCP
import System

/// Connects to configured MCP servers (stdio or streamable HTTP) and exposes their tools to the agent.
public actor MCPHub {
    public enum Status: Sendable, Equatable { case off, connecting, connected(tools: Int), failed(String) }

    struct Connection {
        var config: MCPServerConfig
        var client: Client
        var process: Process?
        var tools: [Tool]
    }

    private var connections: [String: Connection] = [:]
    public private(set) var status: [String: Status] = [:]
    /// All mutations run one after another; otherwise a stop during a slow connect, or two syncs, spawn duplicates/orphans.
    private var chain: Task<Void, Never>?

    private func serialized(_ op: @escaping () async -> Void) async {
        let previous = chain
        let next = Task {
            await previous?.value; await op()
        }
        chain = next
        await next.value
    }

    public init() {}

    /// Tools from all connected servers, names prefixed `<serverId>__`.
    public var tools: [Tool] {
        var seen = Set<String>()  // names must be unique across servers after sanitising/truncation
        return connections.keys.sorted().flatMap { connections[$0]!.tools }.filter { seen.insert($0.name).inserted }
    }

    /// Reconcile running servers with config: start new/changed, stop removed/disabled.
    public func sync(_ configs: [MCPServerConfig]) async {
        await serialized { await self.syncNow(configs) }
    }

    private func syncNow(_ configs: [MCPServerConfig]) async {
        // First wins on duplicate IDs: bad data on disk must not trap at launch.
        let wanted = Dictionary(configs.filter(\.enabled).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Stop removed/disabled servers and ones whose config changed (e.g. trust turned off), then start what's missing.
        for (id, c) in connections where wanted[id] != c.config { await stopNow(id) }
        for (id, cfg) in wanted where connections[id] == nil { await start(cfg) }
    }

    public func restart(_ cfg: MCPServerConfig) async {
        await serialized {
            await self.stopNow(cfg.id)
            if cfg.enabled { await self.start(cfg) }
        }
    }

    public func stop(_ id: String) async { await serialized { await self.stopNow(id) } }

    private func stopNow(_ id: String) async {
        if let c = connections.removeValue(forKey: id) {
            await c.client.disconnect()
            if let p = c.process { Shell.killTree(p) }
        }
        status[id] = .off
    }

    public func stopAll() async {
        await serialized { for id in self.connections.keys { await self.stopNow(id) } }
    }

    func start(_ stored: MCPServerConfig) async {
        let cfg = Keychain.resolve(stored)
        status[cfg.id] = .connecting
        let client = Client(name: "Paluku", version: "1.0")
        var process: Process?
        do {
            if let urlString = cfg.url, let url = URL(string: urlString) {
                guard MCPServerConfig.isAllowedURL(url) else { throw Shell.Failure(message: "Remote MCP servers need an https:// URL") }
                let auth = cfg.authorizationHeader
                let transport = HTTPClientTransport(
                    endpoint: url,
                    requestModifier: { req in
                        var r = req
                        if let auth, !auth.isEmpty { r.setValue(auth, forHTTPHeaderField: "Authorization") }
                        return r
                    })
                _ = try await withTimeout(30) { try await client.connect(transport: transport) }
            } else if let command = cfg.command {
                let (p, transport) = try Self.spawn(command: command, args: cfg.args, env: cfg.env)
                process = p
                _ = try await withTimeout(120, onTimeout: { Shell.killTree(p) }) { try await client.connect(transport: transport) }
            } else {
                throw Shell.Failure(message: "No command or URL configured")
            }
            var all: [MCP.Tool] = []
            var cursor: String? = nil
            repeat {
                let page = try await client.listTools(cursor: cursor)
                all += page.tools
                cursor = page.nextCursor
            } while cursor != nil
            var seen = Set<String>()
            let tools = all.map { Self.bridge($0, server: cfg, client: client) }.filter { seen.insert($0.name).inserted }  // drop 64-char name collisions
            connections[cfg.id] = Connection(config: stored, client: client, process: process, tools: tools)
            status[cfg.id] = .connected(tools: tools.count)
            Telemetry.shared.event(.mcp, "mcp_connected", ["server": cfg.id, "tools": String(tools.count)])
        } catch {
            if let process { Shell.killTree(process) }
            // Keep the message short and URL-free: it shows up in the UI and in diagnostics.
            status[cfg.id] = .failed(Self.redact(error.localizedDescription))
            Telemetry.shared.event(.mcp, "mcp_failed", level: .error, ["server": cfg.id, "error": String(describing: type(of: error))])
        }
    }

    /// Launch through the login shell so npx/uvx from nvm/homebrew resolve like in Terminal.
    static func spawn(command: String, args: [String], env: [String: String]) throws -> (Process, StdioTransport) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", ([command] + args).map(Shell.quote).joined(separator: " ")]
        p.environment = ProcessInfo.processInfo.environment.merging(env.filter { !$0.value.isEmpty }) { $1 }
        let toChild = Pipe(), fromChild = Pipe()
        p.standardInput = toChild
        p.standardOutput = fromChild
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try p.run()
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fromChild.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toChild.fileHandleForWriting.fileDescriptor))
        return (p, transport)
    }

    static func redact(_ s: String) -> String {
        String(s.replacingOccurrences(of: #"[a-z]+://\S+"#, with: "<url>", options: .regularExpression).prefix(160))
    }

    static let writeWords: Set<String> = [
        "delete", "remove", "send", "create", "update", "write", "post", "put", "patch", "move", "archive", "set", "add", "modify", "upload",
        "download", "share", "trash", "cancel", "reply", "forward", "draft", "insert", "edit", "rename", "copy", "run", "execute", "invite",
        "and", "or", "purge", "mark", "clear", "reset", "submit", "publish", "merge", "approve", "drop", "save", "sync", "commit", "push",
        "close", "open", "assign", "transfer", "pay", "buy", "order", "book", "grant", "revoke", "block", "mute", "star", "label", "tag",
    ]

    /// Splits snake_case, kebab-case, dotted and camelCase names into lowercase words.
    static func words(_ name: String) -> [String] {
        name.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)  // HTTPDelete → HTTP Delete
            .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Read-only (no confirmation) only when the user listed the tool, or the user trusts the server and it marks the
    /// tool read-only. Names containing a write word never auto-qualify (ADR-0006, docs/SECURITY.md).
    static func isReadOnly(name: String, hint: Bool?, cfg: MCPServerConfig) -> Bool {
        if cfg.readOnlyTools.contains(name) { return true }
        if words(name).contains(where: writeWords.contains) { return false }
        return cfg.trustReadOnlyHints && hint == true
    }

    static func bridge(_ t: MCP.Tool, server cfg: MCPServerConfig, client: Client) -> Tool {
        let schema = (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(t.inputSchema))) ?? Schema.object([:])
        let name = "\(MCPServerConfig.sanitizedID(cfg.id))__\(t.name)".replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return Tool(
            name: String(name.prefix(64)), description: "[\(cfg.name)] \(t.description ?? t.name)", parameters: schema,
            // MCP servers talk to the network and return third-party content.
            integration: "mcp.\(cfg.id)", isWrite: !isReadOnly(name: t.name, hint: t.annotations.readOnlyHint, cfg: cfg), egress: true, untrusted: true,
            // Show the real tool name: the server controls `title` and could label a delete as "List issues".
            preview: { args in "\(cfg.name) › \(t.name)\n" + Tool.defaultPreview(name: t.name, args: args) }
        ) { args in
            let mcpArgs: [String: Value]? = {
                guard case .object = args else { return nil }
                return try? JSONDecoder().decode([String: Value].self, from: JSONEncoder().encode(args))
            }()
            let (content, isError) = try await client.callTool(name: t.name, arguments: mcpArgs)
            var text: [String] = []
            var image: Data?
            for c in content {
                switch c {
                case .text(let s, _, _): text.append(s)
                case .image(let d, _, _, _): image = image ?? Data(base64Encoded: d)
                case .resource(let r, _, _): text.append(r.text ?? r.uri)
                case .resourceLink(let uri, let n, _, _, _, _): text.append("\(n): \(uri)")
                case .audio: text.append("[audio]")
                }
            }
            let joined = text.joined(separator: "\n")
            if isError == true { throw Shell.Failure(message: joined.isEmpty ? "Tool failed" : joined) }
            return ToolResult(
                joined.isEmpty ? "Done." : joined,
                card: Card(
                    icon: "puzzlepiece.extension", title: "\(cfg.name) · \(t.title ?? t.name)",
                    rows: joined.isEmpty ? [] : [Card.Row(String(joined.prefix(280)))], imageData: image))
        }
    }
}

/// Races `op` against a timer. Unlike a task group, returns on timeout even if `op` ignores cancellation.
func withTimeout<T: Sendable>(_ seconds: Double, onTimeout: @escaping @Sendable () -> Void = {}, _ op: @escaping @Sendable () async throws -> T) async throws
    -> T
{
    let once = OnceFlag()
    return try await withCheckedThrowingContinuation { cont in
        let work = Task {
            do {
                let r = try await op()
                if once.claim() { cont.resume(returning: r) }
            } catch {
                if once.claim() { cont.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if once.claim() {
                work.cancel()
                onTimeout()
                cont.resume(throwing: Shell.Failure(message: "Timed out after \(Int(seconds))s"))
            }
        }
    }
}

/// Thread-safe "first caller wins" flag.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

extension MCPServerConfig {
    /// Remote MCP servers get an Authorization header: https only, except on this Mac.
    public static func isAllowedURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": true
        case "http": ["127.0.0.1", "localhost", "::1"].contains(url.host()?.lowercased() ?? "")
        default: false
        }
    }
}
