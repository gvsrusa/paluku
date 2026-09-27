import Foundation
import Testing

@testable import PalukuCore

@Suite struct OpenAICompatibleTests {
    @Test func encodesToolsImagesAndToolCallIds() throws {
        let msgs: [ChatMessage] = [
            .system("s"),
            .user("look", images: [Data([0xff])]),
            .assistant("", toolCalls: [ToolCall(name: "a", arguments: ["x": 1]), ToolCall(name: "b", arguments: [:])]),
            .tool("a", "ra"), .tool("b", "rb"),
        ]
        let body = OpenAICompatibleClient.requestBody(
            model: "m", messages: msgs, tools: [ToolSpec(name: "a", description: "d", parameters: Schema.object([:]))], temperature: 0.2)
        #expect(JSONSerialization.isValidJSONObject(body))
        let m = body["messages"] as! [[String: Any]]
        let parts = m[1]["content"] as! [[String: Any]]
        #expect(parts[0]["type"] as? String == "text")
        #expect((parts[1]["image_url"] as! [String: Any])["url"] as? String == "data:image/jpeg;base64,/w==")
        let calls = m[2]["tool_calls"] as! [[String: Any]]
        let ids = calls.map { $0["id"] as! String }
        #expect(ids.count == 2 && Set(ids).count == 2)
        #expect((calls[0]["function"] as! [String: Any])["arguments"] as? String == #"{"x":1}"#)
        #expect(m[3]["tool_call_id"] as? String == ids[0])
        #expect(m[4]["tool_call_id"] as? String == ids[1])
        #expect((body["tools"] as! [[String: Any]]).count == 1)
        #expect(body["stream"] as? Bool == true)
    }

    @Test func accumulatesStreamedToolCallFragments() throws {
        var acc = OpenAICompatibleClient.StreamAccumulator()
        let lines = [
            #"data: {"choices":[{"delta":{"role":"assistant","content":"Hi"}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"weather","arguments":"{\"loc"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ation\":\"Paris\"}"}}]}}]}"#,
            ": keep-alive",
            "data: [DONE]",
        ]
        var tokens: [String] = []
        for l in lines { if let t = try acc.consume(l) { tokens.append(t) } }
        #expect(tokens == ["Hi"])
        #expect(acc.done)
        #expect(acc.reply.toolCalls == [ToolCall(name: "weather", arguments: ["location": "Paris"])])
    }

    @Test func surfacesServerErrors() {
        var acc = OpenAICompatibleClient.StreamAccumulator()
        #expect(throws: LLMError.self) { try acc.consume(#"data: {"error":{"message":"model not found"}}"#) }
    }
}

@Suite struct ModelCatalogTests {
    @Test func pullProgressParsing() throws {
        let p = try OllamaClient.parsePull(#"{"status":"pulling abc","digest":"abc","total":200,"completed":50}"#)
        #expect(p.status == "pulling abc" && p.fraction == 0.25)
        let done = try OllamaClient.parsePull(#"{"status":"success"}"#)
        #expect(done.isSuccess)
        #expect(throws: LLMError.self) { try OllamaClient.parsePull(#"{"error":"pull model manifest: file does not exist"}"#) }
    }

    @Test func recommendedModelsAreWellFormed() {
        #expect(ModelCatalog.recommended.count >= 5)
        #expect(ModelCatalog.recommended.allSatisfy { !$0.id.isEmpty && !$0.summary.isEmpty })
    }

    @Test func providerFactoryPicksImplementation() {
        var s = Settings()
        s.provider = .ollama
        #expect(LLMFactory.make(s) is OllamaClient)
        s.provider = .openAICompatible
        s.openAIBaseURL = "http://localhost:1234/v1"
        #expect(LLMFactory.make(s) is OpenAICompatibleClient)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil)) struct KeychainTests {  // CI runners have no unlocked login keychain
    @Test func externalizeAndResolveRoundTrip() {
        let id = "test\(UUID().uuidString.prefix(6))"
        let cfg = MCPServerConfig(id: id, name: "t", command: "x", env: ["TOKEN": "s3cret", "EMPTY": ""], authorizationHeader: "Bearer abc")
        let stored = Keychain.externalize([cfg])[0]
        #expect(stored.env["TOKEN"] == Keychain.placeholder)
        #expect(stored.env["EMPTY"] == "")
        #expect(stored.authorizationHeader == Keychain.placeholder)
        let back = Keychain.resolve(stored)
        #expect(back.env["TOKEN"] == "s3cret")
        #expect(back.authorizationHeader == "Bearer abc")
        Keychain.set(nil, for: "mcp.\(id).env.TOKEN")
        Keychain.set(nil, for: "mcp.\(id).auth")
    }
}

@Suite struct TelemetryTests {
    @Test func percentiles() {
        let s = Telemetry.stat((1...100).map(Double.init))
        #expect(s.count == 100 && s.p50 == 50 && s.p95 == 95)
        #expect(Telemetry.stat([]).count == 0)
    }

    @Test func eventsAreStructuredAndRingIsBounded() {
        let t = Telemetry()
        for i in 0..<350 { t.event(.app, "tick", session: "abc", ["i": String(i)]) }
        #expect(t.recentEvents.count == 300)
        #expect(t.recentEvents.last!.hasSuffix("[app] event=tick session=abc i=349"))
        t.timing(.stt, "stt_done", seconds: 0.25)
        #expect(t.stats()["stt_done"]?.p50 == 0.25)
    }
}

@Suite struct UpdateCheckerTests {
    @Test func semverComparison() {
        #expect(UpdateChecker.isNewer("v1.2.0", than: "1.1.9"))
        #expect(UpdateChecker.isNewer("1.10.0", than: "1.9.9"))
        #expect(!UpdateChecker.isNewer("1.1.0", than: "1.1.0"))
        #expect(!UpdateChecker.isNewer("1.0.9", than: "1.1"))
        #expect(!UpdateChecker.isNewer("1.2.0-beta.1", than: "1.2.0"))
    }

    @Test func parsesReleaseAndSkipsPrereleases() {
        let ok = Data(#"{"tag_name":"v1.2.0","html_url":"https://github.com/o/r/releases/tag/v1.2.0","body":"notes","draft":false,"prerelease":false}"#.utf8)
        #expect(UpdateChecker.parse(ok, repo: "o/r")?.version == "1.2.0")
        let pre = Data(#"{"tag_name":"v1.3.0-rc1","html_url":"https://x","prerelease":true}"#.utf8)
        #expect(UpdateChecker.parse(pre) == nil)
    }
}
