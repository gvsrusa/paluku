import Foundation
import Testing

@testable import PalukuCore

/// Scripted LLM: returns queued replies in order and records requests.
final class FakeLLM: LLM, @unchecked Sendable {
    var replies: [ChatReply]
    var requests: [[ChatMessage]] = []
    init(_ replies: [ChatReply]) { self.replies = replies }
    func chat(model: String, messages: [ChatMessage], tools: [ToolSpec], temperature: Double, onToken: (@Sendable (String) -> Void)?) async throws -> ChatReply
    {
        requests.append(messages)
        let r = replies.isEmpty ? ChatReply(content: "") : replies.removeFirst()
        if !r.content.isEmpty { onToken?(r.content) }
        return r
    }
}

struct FailingLLM: LLM {
    func chat(model: String, messages: [ChatMessage], tools: [ToolSpec], temperature: Double, onToken: (@Sendable (String) -> Void)?) async throws -> ChatReply
    {
        throw LLMError(message: "down")
    }
}

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

@Suite struct PolisherTests {
    @Test func vocabularyReplacesMishearings() {
        let v = [VocabEntry(term: "Kubernetes", soundsLike: ["cooper netties"])]
        #expect(Polisher.applyVocabulary("deploy to Cooper Netties now", v) == "deploy to Kubernetes now")
    }

    @Test func hallucinationsProduceEmptyText() async {
        let p = Polisher(llm: FakeLLM([]), model: "m")
        #expect(await p.polish(" Thank you. ", style: .polished, vocabulary: [], appName: nil) == "")
        #expect(await p.polish("[BLANK_AUDIO]", style: .polished, vocabulary: [], appName: nil) == "")
    }

    @Test func rawSkipsLLM() async {
        let llm = FakeLLM([ChatReply(content: "SHOULD NOT BE USED")])
        let out = await Polisher(llm: llm, model: "m").polish("um hello", style: .raw, vocabulary: [], appName: nil)
        #expect(out == "um hello")
        #expect(llm.requests.isEmpty)
    }

    @Test func polishedUsesLLMAndStripsQuotes() async {
        let llm = FakeLLM([ChatReply(content: "\"Can you send me that form by tomorrow?\"")])
        let out = await Polisher(llm: llm, model: "m").polish(
            "um can you send me that form by today actually I mean tomorrow", style: .polished, vocabulary: [], appName: "Slack")
        #expect(out == "Can you send me that form by tomorrow?")
        #expect(llm.requests[0][0].content.contains("Slack"))
    }

    @Test func llmFailureFallsBackToTranscript() async {
        let out = await Polisher(llm: FailingLLM(), model: "m").polish("hello there", style: .polished, vocabulary: [], appName: nil)
        #expect(out == "hello there")
    }

    @Test func runawayAnswerFallsBackToTranscript() async {
        let llm = FakeLLM([ChatReply(content: String(repeating: "The capital of France is Paris. ", count: 20))])
        let out = await Polisher(llm: llm, model: "m").polish("what is the capital of France", style: .polished, vocabulary: [], appName: nil)
        #expect(out == "what is the capital of France")
    }
}

@Suite struct AgentTests {
    func makeTool(write: Bool, ran: Box<Int>) -> Tool {
        Tool(name: "reminders_create", description: "d", integration: "reminders", isWrite: write) { args in
            ran.value += 1
            return ToolResult("created \(try args.string("title"))", card: Card(icon: "checklist", title: "Reminder"))
        }
    }

    @Test func readToolRunsWithoutConfirmation() async throws {
        let ran = Box(0)
        let llm = FakeLLM([
            ChatReply(content: "", toolCalls: [ToolCall(name: "reminders_create", arguments: ["title": "x"])]),
            ChatReply(content: "Done."),
        ])
        let agent = Agent(llm: llm, model: "m", tools: [makeTool(write: false, ran: ran)])
        let asked = Box(0)
        let out = try await agent.send(
            "hi", system: "s",
            confirm: { _ in
                asked.value += 1; return true
            }, emit: { _ in })
        #expect(out == "Done.")
        #expect(ran.value == 1)
        #expect(asked.value == 0)
        #expect(llm.requests[1].last?.role == .tool)
        #expect(llm.requests[1].last?.content == "created x")
    }

    @Test func writeToolDeclinedDoesNotRun() async throws {
        let ran = Box(0)
        let llm = FakeLLM([
            ChatReply(content: "", toolCalls: [ToolCall(name: "reminders_create", arguments: ["title": "x"])]),
            ChatReply(content: "OK, cancelled."),
        ])
        let agent = Agent(llm: llm, model: "m", tools: [makeTool(write: true, ran: ran)])
        let seen = Box<ConfirmRequest?>(nil)
        _ = try await agent.send(
            "hi", system: "s",
            confirm: { c in
                seen.value = c; return false
            }, emit: { _ in })
        #expect(ran.value == 0)
        #expect(seen.value?.summary == "title: x")
        #expect(llm.requests[1].last?.content.contains("declined") == true)
    }

    @Test func bypassSkipsConfirmation() async throws {
        let ran = Box(0)
        let llm = FakeLLM([
            ChatReply(content: "", toolCalls: [ToolCall(name: "reminders_create", arguments: ["title": "x"])]),
            ChatReply(content: "Done."),
        ])
        let agent = Agent(llm: llm, model: "m", tools: [makeTool(write: true, ran: ran)], bypass: ["reminders"])
        _ = try await agent.send("hi", system: "s", confirm: { _ in false }, emit: { _ in })
        #expect(ran.value == 1)
    }

    @Test func inlineJSONToolCallIsExecuted() async throws {
        let ran = Box(0)
        let llm = FakeLLM([
            ChatReply(content: "```json\n{\"name\": \"reminders_create\", \"arguments\": {\"title\": \"y\"}}\n```"),
            ChatReply(content: "Done."),
        ])
        let agent = Agent(llm: llm, model: "m", tools: [makeTool(write: false, ran: ran)])
        _ = try await agent.send("hi", system: "s", confirm: { _ in true }, emit: { _ in })
        #expect(ran.value == 1)
    }

    @Test func conversationKeepsOnlyLatestScreenshot() async throws {
        let llm = FakeLLM([ChatReply(content: "a"), ChatReply(content: "b")])
        let agent = Agent(llm: llm, model: "m", tools: [])
        _ = try await agent.send("one", images: [Data([1])], system: "s", confirm: { _ in true }, emit: { _ in })
        _ = try await agent.send("two", images: [Data([2])], system: "s2", confirm: { _ in true }, emit: { _ in })
        let msgs = llm.requests[1]
        #expect(msgs[0].content == "s2")
        #expect(msgs.filter { !$0.images.isEmpty }.count == 1)
        #expect(msgs.last?.images == [Data([2])])
    }

    @Test func unknownToolReportsError() async throws {
        let llm = FakeLLM([ChatReply(content: "", toolCalls: [ToolCall(name: "nope", arguments: [:])]), ChatReply(content: "x")])
        let agent = Agent(llm: llm, model: "m", tools: [])
        _ = try await agent.send("hi", system: "s", confirm: { _ in true }, emit: { _ in })
        #expect(llm.requests[1].last?.content.hasPrefix("Error: unknown tool") == true)
    }
}

@Suite struct OllamaParsingTests {
    @Test func parsesToolCallsWithObjectAndStringArguments() throws {
        let a = try OllamaClient.parseChunk(
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"f","arguments":{"x":1}}}]},"done":false}"#)
        #expect(a.toolCalls == [ToolCall(name: "f", arguments: ["x": 1])])
        let b = try OllamaClient.parseChunk(
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"f","arguments":"{\"x\":\"y\"}"}}]},"done":true}"#)
        #expect(b.toolCalls == [ToolCall(name: "f", arguments: ["x": "y"])])
        #expect(b.done)
    }

    @Test func stripsThinkBlocks() {
        #expect(OllamaClient.stripThinking("<think>hmm</think>\nHello") == "Hello")
    }

    @Test func requestBodyEncodesToolsAndImages() throws {
        let body = OllamaClient().requestBody(
            model: "qwen3:4b", messages: [.user("hi", images: [Data([0xff])])],
            tools: [ToolSpec(name: "t", description: "d", parameters: Schema.object([:]))], temperature: 0)
        #expect(body["think"] as? Bool == false)
        let msgs = body["messages"] as! [[String: Any]]
        #expect((msgs[0]["images"] as! [String]) == ["/w=="])
        #expect((body["tools"] as! [[String: Any]]).count == 1)
        #expect(JSONSerialization.isValidJSONObject(body))
    }
}

@Suite struct StoreTests {
    @Test func roundTripsAndToleratesMissingKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = Store(directory: dir)
        var s = store.settings
        s.polishStyle = .light
        store.settings = s
        #expect(Store(directory: dir).settings.polishStyle == .light)

        try Data(#"{"agentKey":"rightCommand"}"#.utf8).write(to: dir.appending(path: "settings.json"))
        let loaded = store.settings
        #expect(loaded.agentKey == .rightCommand)
        #expect(loaded.dictationKey == .fn)

        store.history = [
            HistoryEntry(mode: .dictation, transcript: "b", output: "B", app: nil), HistoryEntry(mode: .dictation, transcript: "a", output: "A", app: nil),
        ]
        #expect(Store(directory: dir).history.map(\.output) == ["B", "A"])
    }

    @Test func dateParsingAcceptsCommonForms() {
        #expect(DateParsing.parse("2026-09-27T16:00") != nil)
        #expect(DateParsing.parse("2026-09-27T16:00:00-05:00") != nil)
        #expect(DateParsing.parse("2026-09-27") != nil)
        #expect(DateParsing.parse("tomorrow") == nil)
    }
}

@Suite struct AgentCancelTests {
    /// LLM that waits until released, to simulate a slow turn being superseded.
    final class SlowLLM: LLM, @unchecked Sendable {
        func chat(model: String, messages: [ChatMessage], tools: [ToolSpec], temperature: Double, onToken: (@Sendable (String) -> Void)?) async throws
            -> ChatReply
        {
            let last = messages.last?.content ?? ""
            if last == "slow" { try await Task.sleep(for: .milliseconds(200)) }
            return ChatReply(content: "answer to \(last)")
        }
    }

    @Test func supersededRunReturnsEmptyAndDoesNotPolluteHistory() async throws {
        let agent = Agent(llm: SlowLLM(), model: "m", tools: [])
        async let first = agent.send("slow", system: "s", confirm: { _ in true }, emit: { _ in })
        try await Task.sleep(for: .milliseconds(50))
        let second = try await agent.send("fast", system: "s", confirm: { _ in true }, emit: { _ in })
        #expect(second == "answer to fast")
        #expect(try await first == "")
        let assistant = await agent.messages.filter { $0.role == .assistant }.map(\.content)
        #expect(assistant == ["answer to fast"])
    }
}
