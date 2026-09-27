import AppKit

/// Tools that act on Paluku itself or the desktop: insert text, open apps/URLs, memory, scheduling, coding agents.
public enum SystemTools {
    /// Callbacks into the app. All async so the app can hop to the main actor safely from the Agent actor.
    public struct Hooks: Sendable {
        public var insert: @Sendable (String) async -> Void
        /// Second argument: the conversation had outside content when the fact was saved.
        public var remember: @Sendable (String, Bool) async -> Void
        public var schedule: @Sendable (ScheduledTask) async -> Void
        public var listScheduled: @Sendable () async -> [ScheduledTask]
        public var cancelScheduled: @Sendable (UUID) async -> Bool
        public init(
            insert: @escaping @Sendable (String) async -> Void, remember: @escaping @Sendable (String, Bool) async -> Void,
            schedule: @escaping @Sendable (ScheduledTask) async -> Void, listScheduled: @escaping @Sendable () async -> [ScheduledTask],
            cancelScheduled: @escaping @Sendable (UUID) async -> Bool
        ) {
            self.insert = insert
            self.remember = remember
            self.schedule = schedule
            self.listScheduled = listScheduled
            self.cancelScheduled = cancelScheduled
        }
    }

    /// http(s) only — `file:`, custom schemes and `javascript:` can launch code or apps.
    public static func safeWebURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let withScheme = s.contains("://") ? s : (s.contains(":") ? s : "https://" + s)
        guard let u = URL(string: withScheme), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", u.host() != nil else { return nil }
        return u
    }

    static let knownBrowsers: Set<String> = [
        "Safari", "Google Chrome", "Arc", "Firefox", "Microsoft Edge", "Brave Browser", "Dia", "Orion", "Opera", "Vivaldi", "Chromium",
    ]

    static let repeatIntervals: [String: Double] = ["hourly": 3600, "daily": 86400, "weekly": 604800, "weekdays": 86400]

    static func makeTask(_ kind: ScheduledTask.Kind, _ args: JSONValue) throws -> ScheduledTask {
        guard let at = args.date("at") else { throw ToolArgumentError(message: "Invalid 'at' time") }
        let rep = args.optString("repeat") ?? "none"
        var t = ScheduledTask(kind: kind, instruction: try args.string("text"), fireDate: at, repeatInterval: repeatIntervals[rep])
        t.weekdaysOnly = rep == "weekdays"
        return t
    }

    static func scheduledCard(_ t: ScheduledTask) -> ToolResult {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d 'at' h:mm a"
        return ToolResult(
            "Scheduled for \(f.string(from: t.fireDate)).",
            card: Card(icon: t.kind == .agent ? "sparkles" : "alarm", title: "Scheduled", rows: [Card.Row(t.instruction, detail: f.string(from: t.fireDate))]))
    }

    static let scheduleParams = Schema.object(
        [
            "text": Schema.string("reminder message / instruction"), "at": Schema.string("ISO local date-time"),
            "repeat": Schema.enumeration("repeat interval", ["none", "hourly", "daily", "weekdays", "weekly"]),
        ], required: ["text", "at"])

    public static func all(_ hooks: Hooks) -> [Tool] {
        [
            Tool(
                name: "insert_text", description: "Type text into the app/field the user is currently in (replies, drafts, prompts, code).",
                parameters: Schema.object(["text": Schema.string("final text to insert")], required: ["text"]), integration: "paluku"
            ) { args in
                // Only stages a draft; the user presses Insert, so no confirmation needed here.
                await hooks.insert(try args.string("text"))
                return ToolResult("Draft shown to the user with Insert/Enter buttons.")
            },
            Tool(
                name: "open_app", description: "Launch or switch to a Mac app by name.",
                parameters: Schema.object(["name": Schema.string("app name, e.g. Slack")], required: ["name"]), integration: "apps", isWrite: true,
                preview: { a in "Open \(a.optString("name") ?? "")" }
            ) { args in
                let name = try args.string("name")
                guard !name.contains("/") else { throw ToolArgumentError(message: "Give an app name, not a path.") }
                try await Shell.run("/usr/bin/open", ["-a", name])
                return ToolResult("Opened \(name).")
            },
            Tool(
                name: "open_url", description: "Open a web page (http/https) in the browser, optionally a specific browser.",
                parameters: Schema.object(["url": Schema.string("URL"), "browser": Schema.string("e.g. Safari, Google Chrome, Arc")], required: ["url"]),
                integration: "paluku", egress: true,
                preview: { a in "Open \(a.optString("url") ?? "")" }
            ) { args in
                guard let u = safeWebURL(try args.string("url")) else { throw ToolArgumentError(message: "Only http(s) web addresses can be opened.") }
                try NetGuard.check(u)
                if let b = args.optString("browser"), !knownBrowsers.contains(b) { throw ToolArgumentError(message: "Unknown browser '\(b)'.") }
                if let b = args.optString("browser") {
                    try await Shell.run("/usr/bin/open", ["-a", b, u.absoluteString])
                } else {
                    try await Shell.run("/usr/bin/open", [u.absoluteString])
                }
                return ToolResult("Opened \(u.absoluteString).")
            },
            Tool(
                name: "remember", description: "Save a lasting fact/preference about the user to memory (e.g. 'My manager is Priya').",
                parameters: Schema.object(["fact": Schema.string("fact to remember")], required: ["fact"]), integration: "paluku", isWrite: true,
                allowBypass: false,
                preview: { a in "🧠 Remember: \(a.optString("fact") ?? "")" }
            ) { args in
                await hooks.remember(try args.string("fact"), Agent.runTainted)
                return ToolResult("Saved to memory.")
            },
            Tool(
                name: "schedule_reminder", description: "Show the user a reminder message at a time (optionally repeating). Use for 'remind me …'.",
                // Persists beyond this conversation (spoken + shown later): a write, bypassable only for "schedule".
                parameters: scheduleParams, integration: "schedule", isWrite: true, egress: true,
                preview: { a in "⏰ \(a.optString("at") ?? "")\n\(a.optString("text") ?? "")" }
            ) { args in
                let t = try makeTask(.reminder, args)
                await hooks.schedule(t)
                return scheduledCard(t)
            },
            Tool(
                name: "schedule_task",
                description:
                    "Run an instruction through the assistant at a later time (e.g. 'every weekday at 9 check my inbox for emails from Sam'). The result is shown then.",
                parameters: scheduleParams, integration: "schedule", isWrite: true, allowBypass: false,
                preview: { a in
                    "✨ At \(a.optString("at") ?? "")\(a.optString("repeat").map { $0 == "none" ? "" : " (\($0))" } ?? ""):\n\(a.optString("text") ?? "")"
                }
            ) { args in
                let t = try makeTask(.agent, args)
                await hooks.schedule(t)
                return scheduledCard(t)
            },
            Tool(
                name: "scheduled_list", description: "List Paluku's scheduled reminders/tasks.", integration: "schedule", untrusted: true
            ) { _ in
                let items = await hooks.listScheduled()
                if items.isEmpty { return ToolResult("Nothing scheduled.") }
                return ToolResult(items.map { "[\($0.id)] \(DateParsing.iso($0.fireDate)) \($0.kind.rawValue): \($0.instruction)" }.joined(separator: "\n"))
            },
            Tool(
                name: "scheduled_cancel", description: "Cancel a scheduled item by id.",
                parameters: Schema.object(["id": Schema.string("id from scheduled_list")], required: ["id"]), integration: "schedule", isWrite: true
            ) { args in
                guard let id = UUID(uuidString: try args.string("id")), await hooks.cancelScheduled(id) else { throw ToolArgumentError(message: "Not found") }
                return ToolResult("Cancelled.")
            },
            Tool(
                name: "coding_agent",
                description: "Run a coding task with a local coding agent CLI (Claude Code or Codex) in a git project folder. Returns its final output.",
                parameters: Schema.object(
                    [
                        "agent": Schema.enumeration("which CLI", ["claude", "codex"]),
                        "task": Schema.string("what to do"), "directory": Schema.string("project folder path (a git repo in your home folder)"),
                    ], required: ["task", "directory"]), integration: "coding", isWrite: true, egress: true, untrusted: true, allowBypass: false,
                preview: { a in "🧑‍💻 \(a.optString("agent") ?? "claude") in \(a.optString("directory") ?? "")\n\(a.optString("task") ?? "")" }
            ) { args in
                let dir = try codingDirectory(try args.string("directory"))
                let task = try args.string("task")
                // `--` ends option parsing so a task starting with "-" can't become a CLI flag.
                let cmd =
                    args.optString("agent") == "codex"
                    ? "codex exec --full-auto -- \(Shell.quote(task))" : "claude --permission-mode acceptEdits -p -- \(Shell.quote(task))"
                let out = try await Shell.loginShell(cmd, cwd: dir, timeout: 1800)
                return ToolResult(
                    String(out.suffix(6000)),
                    card: Card(icon: "chevron.left.forwardslash.chevron.right", title: "Coding task finished", rows: [Card.Row(task, detail: dir.path)]))
            },
        ]
    }

    /// Coding agents may only run inside a git repository under the user's home folder.
    static func codingDirectory(_ raw: String) throws -> URL {
        let dir = FinderTools.expand(raw).standardizedFileURL.resolvingSymlinksInPath()
        // Not hidden/Library repos (dotfiles run in every shell) nor Downloads (untrusted code with its own agent hooks).
        guard let rel = try FinderTools.homeRelative(dir.path.lowercased()), !FinderTools.isPrivateArea(rel), !rel.hasPrefix("downloads"),
            FileManager.default.fileExists(atPath: dir.appending(path: ".git").path)
        else {
            throw ToolArgumentError(message: "Coding tasks run only in a git project inside your home folder.")
        }
        return dir
    }
}
