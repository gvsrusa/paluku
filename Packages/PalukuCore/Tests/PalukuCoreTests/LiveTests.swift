import AVFoundation
import Foundation
import Testing

@testable import PalukuCore

/// Hits real Ollama / WhisperKit / MCP. Run with: PALUKU_LIVE=1 swift test --filter Live
let live = ProcessInfo.processInfo.environment["PALUKU_LIVE"] == "1"
let liveModel = ProcessInfo.processInfo.environment["PALUKU_MODEL"] ?? "gemma4:latest"

@Suite(.enabled(if: live), .serialized) struct LiveTests {
    @Test func polishRemovesFillersAndAppliesSelfCorrection() async {
        let p = Polisher(llm: OllamaClient(), model: liveModel)
        let out = await p.polish("um so can you send me that form by today uh actually I mean tomorrow", style: .polished, vocabulary: [], appName: "Slack")
        print("POLISH:", out)
        #expect(out.lowercased().contains("tomorrow"))
        #expect(!out.lowercased().contains("today"))
        #expect(!out.lowercased().contains("um "))
    }

    @Test func polishDoesNotAnswerQuestions() async {
        let p = Polisher(llm: OllamaClient(), model: liveModel)
        let out = await p.polish("what is the capital of france", style: .polished, vocabulary: [], appName: nil)
        print("POLISH-Q:", out)
        #expect(!out.lowercased().contains("paris"))
    }

    @Test func agentCallsToolThenAnswers() async throws {
        let called = Box(false)
        let tool = Tool(
            name: "weather", description: "Get weather for a city", parameters: Schema.object(["location": Schema.string("city")], required: ["location"]),
            integration: "web"
        ) { args in
            called.value = true
            return ToolResult("\(try args.string("location")): 21°C sunny")
        }
        let agent = Agent(llm: OllamaClient(), model: liveModel, tools: [tool])
        let out = try await agent.send(
            Prompts.agentMessage("What's the weather in Paris right now?"), system: Prompts.agentSystem(userName: "", memory: []), confirm: { _ in true },
            emit: { _ in })
        print("AGENT:", out)
        #expect(called.value)
        #expect(out.contains("21"))
    }

    @Test func whisperTranscribesSynthesizedSpeech() async throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "paluku-test.wav")
        try await Shell.run(
            "/usr/bin/say", ["-o", wav.path, "--data-format=LEF32@16000", "Please schedule a meeting with the design team tomorrow at two pm."])
        let file = try AVAudioFile(forReading: wav)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Paluku/models")
        let t = Transcriber(modelsDirectory: dir)
        let model = ProcessInfo.processInfo.environment["PALUKU_WHISPER"] ?? Settings().whisperModel
        await t.load(model: model) { s in if case .downloading(let p) = s, Int(p * 100) % 10 == 0 { print("download", p) } }
        #expect(await t.state == .ready)
        let clock = ContinuousClock()
        var text = ""
        let elapsed = try await clock.measure { text = try await t.transcribe(samples, language: "en", vocabulary: ["Paluku"]) }
        print("WHISPER:", text, elapsed)
        #expect(text.lowercased().contains("design team"))
    }

    @Test func mcpEverythingServerExposesTools() async throws {
        let hub = MCPHub()
        let cfg = MCPServerConfig(id: "everything", name: "Everything", command: "npx", args: ["-y", "@modelcontextprotocol/server-everything"])
        await hub.sync([cfg])
        print("MCP status:", await hub.status)
        let tools = await hub.tools
        #expect(!tools.isEmpty)
        guard let echo = tools.first(where: { $0.name == "everything__echo" }) else { Issue.record("no echo tool: \(tools.map(\.name))"); return }
        let r = try await echo.run(["message": "hi paluku"])
        #expect(r.text.contains("hi paluku"))
        await hub.stopAll()
    }
}

@Suite(.enabled(if: live), .serialized) struct LiveProviderTests {
    @Test func openAICompatibleAgainstOllamaV1() async throws {
        let client = OpenAICompatibleClient(baseURL: URL(string: "http://127.0.0.1:11434/v1")!)
        #expect(try await client.models().contains(liveModel))
        let called = Box(false)
        let tool = Tool(
            name: "weather", description: "Get weather for a city", parameters: Schema.object(["location": Schema.string("city")], required: ["location"]),
            integration: "web"
        ) { args in
            called.value = true
            return ToolResult("\(try args.string("location")): 18°C cloudy")
        }
        let agent = Agent(llm: client, model: liveModel, tools: [tool])
        let out = try await agent.send(
            Prompts.agentMessage("What's the weather in Berlin?"), system: Prompts.agentSystem(userName: "", memory: []), confirm: { _ in true }, emit: { _ in }
        )
        print("OPENAI-COMPAT:", out)
        #expect(called.value)
        #expect(out.contains("18"))
    }

    @Test func pullAndDeleteTinyModel() async throws {
        let ollama = OllamaClient()
        var last: PullProgress?
        for try await p in ollama.pull("smollm2:135m") { last = p }
        #expect(last?.isSuccess == true)
        #expect(try await ollama.models().contains { $0.hasPrefix("smollm2:135m") })
        try await ollama.delete("smollm2:135m")
        #expect(try await !ollama.models().contains { $0.hasPrefix("smollm2:135m") })
    }
}
