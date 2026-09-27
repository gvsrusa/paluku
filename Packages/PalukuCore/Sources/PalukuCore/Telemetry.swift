import Foundation
import os

/// Local-only observability: structured os.Logger events + an in-memory ring and latency stats for
/// "Copy diagnostics". Nothing leaves the Mac. Never pass transcript text, tool arguments or secrets as fields.
///
/// Questions this answers for a bug report:
/// 1. Did the hotkey fire?            → `recording_started|stopped|cancelled`
/// 2. Which stage failed / was slow?  → `stt_done`, `polish_done`, `paste_done|paste_failed` (+ ms)
/// 3. Which agent tool failed?        → `tool_done` (tool, ok, ms), `agent_turn_done|failed`
/// 4. Was the model server reachable? → `llm_unreachable`, `models_listed`
public final class Telemetry: @unchecked Sendable {
    public static let shared = Telemetry()
    static let subsystem = "com.gvsrusa.Paluku"

    public enum Category: String, CaseIterable, Sendable { case hotkeys, audio, stt, llm, agent, mcp, app }

    private let loggers = Dictionary(uniqueKeysWithValues: Category.allCases.map { ($0, Logger(subsystem: Telemetry.subsystem, category: $0.rawValue)) })
    private let lock = NSLock()
    private var ring: [String] = []
    private var timings: [String: [Double]] = [:]
    private let ringSize = 300

    /// Stable event name + small, non-sensitive fields. `session` correlates one voice interaction.
    public func event(_ category: Category, _ name: String, session: String? = nil, level: OSLogType = .info, _ fields: [String: String] = [:]) {
        var parts = ["event=\(name)"]
        if let session { parts.append("session=\(session)") }
        parts += fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }
        let line = parts.joined(separator: " ")
        loggers[category]!.log(level: level, "\(line, privacy: .public)")
        let stamp = ISO8601DateFormatter().string(from: Date())
        lock.withLock {
            ring.append("\(stamp) [\(category.rawValue)] \(line)")
            if ring.count > ringSize { ring.removeFirst(ring.count - ringSize) }
        }
    }

    /// Records a duration (seconds) and logs it as an event.
    public func timing(_ category: Category, _ name: String, seconds: Double, session: String? = nil, _ fields: [String: String] = [:]) {
        lock.withLock {
            timings[name, default: []].append(seconds)
            if timings[name]!.count > 200 { timings[name]!.removeFirst() }
        }
        event(category, name, session: session, fields.merging(["ms": String(Int(seconds * 1000))]) { $1 })
    }

    public struct Stat: Sendable, Equatable { public var count: Int; public var p50: Double; public var p95: Double }

    public func stats() -> [String: Stat] {
        lock.withLock { timings.mapValues(Self.stat) }
    }

    static func stat(_ xs: [Double]) -> Stat {
        let s = xs.sorted()
        func pct(_ p: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int((Double(s.count) * p).rounded(.up)) - 1)] }
        return Stat(count: s.count, p50: pct(0.5), p95: pct(0.95))
    }

    public var recentEvents: [String] { lock.withLock { ring } }

    public static func newSession() -> String { String(UUID().uuidString.prefix(8)).lowercased() }
}
