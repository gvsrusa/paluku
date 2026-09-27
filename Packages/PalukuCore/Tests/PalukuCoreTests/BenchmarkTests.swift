import Foundation
import Testing

@testable import PalukuCore

/// PALUKU_LIVE=1 PALUKU_BENCH=1 swift test --filter Benchmark
/// Measures tool-selection accuracy + latency across models using the real tool catalogue (side effects stubbed).
@Suite(.enabled(if: live && ProcessInfo.processInfo.environment["PALUKU_BENCH"] == "1"), .serialized)
struct BenchmarkTests {
    static let cases: [(String, String)] = [
        ("What's on my calendar tomorrow?", "calendar_list_events"),
        ("Remind me to send Maya the deck at 4pm today", "schedule_reminder"),
        ("Find last year's tax return PDF", "files_search"),
        ("What's the weather in Seattle this weekend?", "weather"),
        ("Text Mom that I'll be late", "messages_send"),
        ("Search the web for the latest Swift release notes", "web_search"),
        ("Create a note called groceries with milk, eggs and bread", "notes_create"),
        ("Play some jazz on Spotify", "media_control"),
        ("Find a coffee shop near me", "maps_search"),
        ("Open Slack", "open_app"),
        ("Every weekday at 9am check my inbox for emails from the investor", "schedule_task"),
        ("Email jake@example.com saying let's go surfing Saturday", "mail_send"),
    ]

    static func stubbedTools(_ record: Box<[String]>) -> [Tool] {
        let hooks = SystemTools.Hooks(insert: { _ in }, remember: { _, _ in }, schedule: { _ in }, listScheduled: { [] }, cancelScheduled: { _ in false })
        let real = SystemTools.all(hooks) + WebTools.all() + CalendarTools.all + FinderTools.all + AppleAppTools.all
        return real.map { t in
            var s = t
            let name = t.name
            s.run = { _ in
                record.value.append(name); return ToolResult("OK (\(name) succeeded)")
            }
            return s
        }
    }

    @Test(arguments: (ProcessInfo.processInfo.environment["PALUKU_BENCH_MODELS"] ?? "gemma4:latest,qwen3:30b-a3b").split(separator: ",").map(String.init))
    func agentToolSelection(model: String) async throws {
        let llm = OllamaClient()
        try await llm.warmUp(model: model)
        var correct = 0
        var total: Double = 0
        for (prompt, expected) in Self.cases {
            let calls = Box<[String]>([])
            let agent = Agent(llm: llm, model: model, tools: Self.stubbedTools(calls))
            let start = Date()
            let answer = try await agent.send(
                Prompts.agentMessage(prompt, appName: "Finder"), system: Prompts.agentSystem(userName: "Sam", memory: []), confirm: { _ in true },
                emit: { _ in })
            let dt = Date().timeIntervalSince(start)
            total += dt
            let ok = calls.value.first == expected
            if ok { correct += 1 }
            print(
                String(
                    format: "BENCH %@ | %@ | %.2fs | %@ → %@ | %@", model, ok ? "✓" : "✗", dt, prompt, calls.value.joined(separator: ","),
                    String(answer.prefix(60)).replacingOccurrences(of: "\n", with: " ")))
        }
        print(String(format: "BENCH-SUMMARY %@ accuracy %d/%d avg %.2fs", model, correct, Self.cases.count, total / Double(Self.cases.count)))
    }

    @Test(arguments: (ProcessInfo.processInfo.environment["PALUKU_POLISH_MODELS"] ?? "gemma4:latest,qwen3:4b").split(separator: ",").map(String.init))
    func polishLatency(model: String) async throws {
        let llm = OllamaClient()
        try await llm.warmUp(model: model)
        let p = Polisher(llm: llm, model: model)
        let inputs = [
            "um so can you send me that form by today uh actually I mean tomorrow",
            "hey team so the build is uh green now and um we can ship on thursday no wait friday",
            "okay so three things first buy milk second call the dentist and third finish the report",
        ]
        var total: Double = 0
        for i in inputs {
            let s = Date()
            let out = await p.polish(i, style: .polished, vocabulary: [], appName: "Slack")
            total += Date().timeIntervalSince(s)
            print("POLISH-BENCH \(model) | \(out.replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
        print(String(format: "POLISH-SUMMARY %@ avg %.2fs", model, total / Double(inputs.count)))
    }
}
