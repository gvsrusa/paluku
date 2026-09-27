import Foundation
import Testing

@testable import PalukuCore

/// Regressions from the v1.2 review (tasks/plan.md T35/T36).
@Suite struct ReviewV12Tests {
    @Test func nonFiniteOrHugeNumbersDoNotTrap() {
        for n in [Double.nan, .infinity, -.infinity, 1e20, -1e20] {
            _ = JSONValue.number(n).stringValue
            #expect(JSONValue.object(["n": .number(n)]).int("n") == nil)
        }
        #expect(JSONValue.number(42).stringValue == "42")
        #expect(JSONValue.object(["n": .number(7)]).int("n") == 7)
    }

    @Test func updateCheckerToleratesOddTags() {
        for tag in ["v", "", "-rc1", "V-"] { _ = UpdateChecker.isNewer(tag, than: "1.0.0") }
        #expect(UpdateChecker.isNewer("v1.2.0", than: "1.1.9"))
    }

    @Test func cancelledRunDoesNotLeaveDanglingToolCalls() async throws {
        let llm = FakeLLM([
            ChatReply(content: "", toolCalls: [ToolCall(name: "a", arguments: [:]), ToolCall(name: "a", arguments: [:])]),
            ChatReply(content: "fine"),
        ])
        let cancelSelf = Tool(name: "a", description: "d", integration: "web") { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return ToolResult("ok")
        }
        let agent = Agent(llm: llm, model: "m", tools: [cancelSelf])
        _ = try await Task { try await agent.send("go", system: "s", confirm: { _ in true }, emit: { _ in }) }.value
        _ = try await agent.send("again", system: "s", confirm: { _ in true }, emit: { _ in })
        let sent = try #require(llm.requests.last)
        let i = try #require(sent.firstIndex { !$0.toolCalls.isEmpty })
        let answered = sent[(i + 1)...].prefix { $0.role == .tool }.count
        #expect(answered == sent[i].toolCalls.count)
    }

    @Test func corruptStoreFileIsBackedUpNotLost() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = Store(directory: dir)
        try Data("{not json".utf8).write(to: dir.appending(path: "history.json"))
        #expect(store.history.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path())
        #expect(files.contains { $0.hasPrefix("history.corrupt-") })
    }

    @Test func modelListingFailsOnHTTPError() {
        func resp(_ code: Int) -> URLResponse { HTTPURLResponse(url: URL(string: "http://x")!, statusCode: code, httpVersion: nil, headerFields: nil)! }
        #expect(throws: Never.self) { try requireOK(resp(200), "Server") }
        #expect(throws: LLMError.self) { try requireOK(resp(401), "Server") }
    }
}

@Suite struct LinkPolicyTests {
    @Test func markdownLinksFromModelAreAllowlisted() {
        #expect(!LinkPolicy.isSafeToOpen(URL(string: "shortcuts://run-shortcut?name=x")!))
        #expect(!LinkPolicy.isSafeToOpen(URL(string: "http://127.0.0.1:8080/admin")!))
        #expect(!LinkPolicy.isSafeToOpen(URL(fileURLWithPath: "/bin/sh")))
        #expect(!LinkPolicy.isSafeToOpen(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        #expect(LinkPolicy.isSafeToOpen(URL(string: "maps://?q=coffee")!))
    }
}

struct StallingLLM: LLM {
    func chat(model: String, messages: [ChatMessage], tools: [ToolSpec], temperature: Double, onToken: (@Sendable (String) -> Void)?) async throws -> ChatReply
    {
        try await Task.sleep(for: .seconds(30))
        return ChatReply(content: "late")
    }
}

@Suite struct PolishTimeoutTests {
    @Test func stalledServerFallsBackToRawTextQuickly() async throws {
        var p = Polisher(llm: StallingLLM(), model: "m")
        p.timeout = 0.2
        let start = Date()
        let out = await p.polish("hello there world", style: .light, vocabulary: [], appName: nil)
        #expect(out == "hello there world")
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func stalledEditThrows() async {
        var p = Polisher(llm: StallingLLM(), model: "m")
        p.timeout = 0.2
        await #expect(throws: (any Error).self) { try await p.edit(selection: "a", instruction: "b") }
    }
}

@Suite struct MCPProcessTests {
    @Test func stoppingAServerKillsItsChildren() async throws {
        let secs = "7\(Int.random(in: 100...999)).25"  // unique, so ps can't match another process
        let (p, _) = try MCPHub.spawn(command: "/bin/sh", args: ["-c", "sleep \(secs); :"], env: [:])
        try await Task.sleep(for: .milliseconds(500))
        Shell.killTree(p)
        try await Task.sleep(for: .milliseconds(300))
        let out = try await Shell.run("/bin/ps", ["-axo", "command"], timeout: 5)
        #expect(!out.contains("sleep \(secs)"), "grandchild survived")
    }
}

@Suite struct DoubtCycleTests {
    @Test func homeFolderItselfIsReadableButNotWritable() throws {
        try FinderTools.checkReadable(FinderTools.expand("~"))
        #expect(throws: ToolArgumentError.self) { try FinderTools.checkWritable(FinderTools.expand("~")) }
    }

    @Test func iCloudDriveIsUserContent() throws {
        try FinderTools.checkReadable(FinderTools.home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/notes.txt"))
        #expect(throws: ToolArgumentError.self) {
            try FinderTools.checkReadable(FinderTools.home.appending(path: "Library/Mobile Documents/iCloud~com~app/secret.txt"))
        }
        #expect(throws: ToolArgumentError.self) {
            try FinderTools.checkReadable(FinderTools.home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/.ssh/id"))
        }
    }

    @Test func toolThatFinishedAfterStopKeepsItsRealResult() async throws {
        let llm = FakeLLM([ChatReply(content: "", toolCalls: [ToolCall(name: "send", arguments: [:])]), ChatReply(content: "ok")])
        let send = Tool(name: "send", description: "d", integration: "web") { _ in
            withUnsafeCurrentTask { $0?.cancel() }  // Stop pressed while the tool runs; it completes anyway
            return ToolResult("Sent.")
        }
        let agent = Agent(llm: llm, model: "m", tools: [send])
        _ = try await Task { try await agent.send("go", system: "s", confirm: { _ in true }, emit: { _ in }) }.value
        _ = try await agent.send("next", system: "s", confirm: { _ in true }, emit: { _ in })
        #expect(llm.requests.last?.contains { $0.role == .tool && $0.content == "Sent." } == true)
    }
}

@Suite struct ShellEOFTests {
    func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// Foundation keeps calling readabilityHandler with empty data after EOF; if Shell.run doesn't detach it, a child
    /// that closes its output before exiting pins a core (this starved the 3-core CI runner).
    @Test func closedOutputBeforeExitDoesNotSpin() async throws {
        let before = cpuSeconds()
        _ = try await Shell.run("/bin/sh", ["-c", "exec 1>&- 2>&-; sleep 1.5"], timeout: 10)
        #expect(cpuSeconds() - before < 0.5, "Shell.run burned CPU while the child had closed its output")
    }
}
