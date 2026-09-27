import AVFoundation
import Foundation
import Testing

@testable import PalukuCore

/// PALUKU_LIVE=1 PALUKU_PERF=1 swift test --filter Perf — latency budget checks (SPEC § Performance Targets).
@Suite(.enabled(if: live && ProcessInfo.processInfo.environment["PALUKU_PERF"] == "1"), .serialized)
struct PerfTests {
    func speech(_ text: String) async throws -> [Float] {
        let wav = FileManager.default.temporaryDirectory.appending(path: "paluku-perf.wav")
        try await Shell.run("/usr/bin/say", ["-o", wav.path, "--data-format=LEF32@16000", text])
        let f = try AVAudioFile(forReading: wav)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: b)
        return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
    }

    func p50(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

    @Test func dictationKeyUpToTextUnderBudget() async throws {
        let samples = try await speech(
            "Um so I wanted to follow up on the proposal we discussed yesterday, uh, can you send me the updated numbers by Friday, actually make that Thursday, thanks."
        )
        print(String(format: "PERF audio length %.1fs", Double(samples.count) / 16000))
        let t = Transcriber(
            modelsDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Paluku/models"))
        await t.load(model: Settings().whisperModel)
        let p = Polisher(llm: OllamaClient(), model: liveModel)
        try await OllamaClient().warmUp(model: liveModel)
        var stt: [Double] = [], polish: [Double] = []
        for _ in 0..<5 {
            var s = Date()
            let text = try await t.transcribe(samples, language: "en", vocabulary: [])
            stt.append(Date().timeIntervalSince(s))
            s = Date()
            _ = await p.polish(text, style: .polished, vocabulary: [], appName: "Mail")
            polish.append(Date().timeIntervalSince(s))
        }
        let total = p50(stt) + p50(polish)
        print(String(format: "PERF stt p50 %.2fs · polish p50 %.2fs · key-up→text p50 %.2fs (budget 1.5s)", p50(stt), p50(polish), total))
        #expect(total < 1.5)
    }

    @Test func agentFirstTokenForSimpleQuestion() async throws {
        let hooks = SystemTools.Hooks(insert: { _ in }, remember: { _, _ in }, schedule: { _ in }, listScheduled: { [] }, cancelScheduled: { _ in false })
        let tools = SystemTools.all(hooks) + WebTools.all() + CalendarTools.all + FinderTools.all + AppleAppTools.all
        try await OllamaClient().warmUp(model: liveModel)
        var ttft: [Double] = []
        for q in ["What's 17 times 23?", "Give me a one-line tip for focus.", "How many days are in a leap year?", "Say hi.", "What is the capital of Japan?"] {
            let agent = Agent(llm: OllamaClient(), model: liveModel, tools: tools)
            let start = Date()
            let first = Box<Double?>(nil)
            _ = try await agent.send(Prompts.agentMessage(q), system: Prompts.agentSystem(userName: "", memory: []), confirm: { _ in true }) { ev in
                if case .token = ev, first.value == nil { first.value = Date().timeIntervalSince(start) }
            }
            ttft.append(first.value ?? Date().timeIntervalSince(start))
        }
        print(String(format: "PERF agent first token p50 %.2fs (budget 2s) all=%@", p50(ttft), ttft.map { String(format: "%.2f", $0) }.joined(separator: ",")))
        #expect(p50(ttft) < 2)
    }
}
