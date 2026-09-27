import Foundation
@preconcurrency import WhisperKit

/// Local speech-to-text via WhisperKit (CoreML, runs on the Neural Engine).
public actor Transcriber {
    public enum State: Sendable, Equatable { case idle, downloading(Double), loading, ready, failed(String) }

    private var kit: WhisperKit?
    private var loadedModel: String?
    public private(set) var state: State = .idle
    public let modelsDirectory: URL

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    /// Downloads (first run) and loads the model. Safe to call repeatedly.
    private var loadGeneration = 0

    public func load(model: String, onState: (@Sendable (State) -> Void)? = nil) async {
        if loadedModel == model, kit != nil { return }
        // Switching models quickly: only the newest load may install its result.
        loadGeneration += 1
        let generation = loadGeneration
        func set(_ s: State) {
            state = s
            onState?(s)
        }
        do {
            set(.downloading(0))
            let folder = try await WhisperKit.download(variant: model, downloadBase: modelsDirectory, token: "") { p in
                onState?(.downloading(p.fractionCompleted))
            }
            set(.loading)
            try await Self.ensureTokenizer(in: folder, variant: model)
            let config = WhisperKitConfig(
                model: model, downloadBase: modelsDirectory, modelToken: "", modelFolder: folder.path, tokenizerFolder: folder, verbose: false,
                logLevel: .error, prewarm: true, load: true, download: false)
            let loaded = try await WhisperKit(config)
            guard generation == loadGeneration else { return }
            kit = loaded
            loadedModel = model
            set(.ready)
        } catch {
            set(.failed(error.localizedDescription))
        }
    }

    /// WhisperKit's tokenizer loader reads ~/.cache/huggingface/token and fails on a stale one, so fetch the
    /// public tokenizer anonymously next to the model where the loader looks first.
    static func ensureTokenizer(in folder: URL, variant: String) async throws {
        guard !FileManager.default.fileExists(atPath: folder.appending(path: "tokenizer.json").path) else { return }
        let repo = tokenizerRepo(for: variant)
        for file in ["tokenizer.json", "tokenizer_config.json"] {
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LLMError(message: "Tokenizer download failed (\(repo)/\(file))") }
            try data.write(to: folder.appending(path: file))
        }
    }

    static func tokenizerRepo(for variant: String) -> String {
        let v = variant.lowercased()
        if v.contains("large-v3") || v.contains("distil") { return "openai/whisper-large-v3" }
        let base = v.replacingOccurrences(of: "openai_whisper-", with: "").components(separatedBy: "_")[0]
        return "openai/whisper-\(base)"
    }

    /// Transcribe 16 kHz mono float samples.
    public func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        guard let kit else { throw LLMError(message: "Speech model not loaded yet (\(state))") }
        guard samples.count > 16_000 / 4 else { return "" }  // <250 ms: accidental tap

        var prompt: [Int]? = nil
        if !vocabulary.isEmpty, let tok = kit.tokenizer {
            // Whisper "initial prompt" biases spelling toward these terms.
            let ids = tok.encode(text: " " + vocabulary.prefix(80).joined(separator: ", "))
                .filter { $0 < tok.specialTokens.specialTokenBegin }
            prompt = Array(ids.suffix(200))
        }
        let options = DecodingOptions(
            language: language, usePrefillPrompt: language != nil || prompt != nil, detectLanguage: language == nil,
            skipSpecialTokens: true, withoutTimestamps: true, promptTokens: prompt, chunkingStrategy: .vad)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
