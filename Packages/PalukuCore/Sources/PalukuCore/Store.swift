import Foundation

public enum TriggerKey: String, Codable, Sendable, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl, rightShift
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .fn: "fn / 🌐"
        case .rightOption: "Right ⌥"
        case .rightCommand: "Right ⌘"
        case .rightControl: "Right ⌃"
        case .rightShift: "Right ⇧"
        }
    }
}

public enum PolishStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case raw, light, polished
    public var id: String { rawValue }
}

public struct MCPServerConfig: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String  // short slug, used as tool-name prefix
    public var name: String
    public var enabled: Bool = true
    /// Either a local command (stdio) …
    public var command: String? = nil
    public var args: [String] = []
    public var env: [String: String] = [:]
    /// … or a remote streamable-HTTP endpoint.
    public var url: String? = nil
    public var authorizationHeader: String? = nil
    /// Tool names (unprefixed) that run without confirmation.
    public var readOnlyTools: [String] = []
    /// Trust the server's own `readOnlyHint` annotations (only for servers you trust).
    public var trustReadOnlyHints = false

    public init(
        id: String, name: String, enabled: Bool = true, command: String? = nil, args: [String] = [],
        env: [String: String] = [:], url: String? = nil, authorizationHeader: String? = nil, readOnlyTools: [String] = [],
        trustReadOnlyHints: Bool = false
    ) {
        self.trustReadOnlyHints = trustReadOnlyHints
        self.id = id
        self.name = name
        self.enabled = enabled
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.authorizationHeader = authorizationHeader
        self.readOnlyTools = readOnlyTools
    }

    /// Server ids become tool-name prefixes (`id__tool`): lowercase letters, digits and single dashes only.
    public static func sanitizedID(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // Tolerant decoding: fields added in later versions must not wipe older configs.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        command = try c.decodeIfPresent(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        url = try c.decodeIfPresent(String.self, forKey: .url)
        authorizationHeader = try c.decodeIfPresent(String.self, forKey: .authorizationHeader)
        readOnlyTools = try c.decodeIfPresent([String].self, forKey: .readOnlyTools) ?? []
        trustReadOnlyHints = try c.decodeIfPresent(Bool.self, forKey: .trustReadOnlyHints) ?? false
    }
}

public struct Settings: Codable, Sendable, Equatable {
    public var dictationKey: TriggerKey = .fn
    public var agentKey: TriggerKey = .rightOption
    public var polishStyle: PolishStyle = .polished
    public var polishModel = "gemma4:latest"
    public var agentModel = "gemma4:latest"
    public var whisperModel = "openai_whisper-large-v3-v20240930_turbo"
    /// nil = auto-detect.
    public var language: String? = nil
    public var speakReplies = true
    public var voiceIdentifier: String? = nil
    public var speechRate: Float = 0.52
    public var duckMedia = true
    public var useScreenContext = true
    public var agentIdleResetSeconds: Double = 120
    /// Integration ids (e.g. "reminders", "mcp.gmail") whose write actions skip confirmation.
    public var confirmBypass: [String] = []
    public var mcpServers: [MCPServerConfig] = MCPPresets.all
    public var ollamaURL = "http://127.0.0.1:11434"
    public var provider: ModelProvider = .ollama
    public var openAIBaseURL = "http://127.0.0.1:1234/v1"
    public var checkForUpdates = true
    public var onboarded = false
    /// Bumped when stored data needs migrating (see `init(from:)`).
    public var settingsVersion = Settings.currentVersion
    public static let currentVersion = 2
    public var userName = ""

    public init() {}

    // Tolerate missing keys when the settings schema grows.
    public init(from decoder: Decoder) throws {
        let d = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        dictationKey = v(.dictationKey, d.dictationKey)
        agentKey = v(.agentKey, d.agentKey)
        polishStyle = v(.polishStyle, d.polishStyle)
        polishModel = v(.polishModel, d.polishModel)
        agentModel = v(.agentModel, d.agentModel)
        whisperModel = v(.whisperModel, d.whisperModel)
        language = v(.language, d.language)
        speakReplies = v(.speakReplies, d.speakReplies)
        voiceIdentifier = v(.voiceIdentifier, d.voiceIdentifier)
        speechRate = v(.speechRate, d.speechRate)
        duckMedia = v(.duckMedia, d.duckMedia)
        useScreenContext = v(.useScreenContext, d.useScreenContext)
        agentIdleResetSeconds = v(.agentIdleResetSeconds, d.agentIdleResetSeconds)
        confirmBypass = v(.confirmBypass, d.confirmBypass)
        mcpServers = v(.mcpServers, d.mcpServers)
        ollamaURL = v(.ollamaURL, d.ollamaURL)
        provider = v(.provider, d.provider)
        openAIBaseURL = v(.openAIBaseURL, d.openAIBaseURL)
        checkForUpdates = v(.checkForUpdates, d.checkForUpdates)
        onboarded = v(.onboarded, d.onboarded)
        userName = v(.userName, d.userName)
        settingsVersion = v(.settingsVersion, 1)
        if settingsVersion < 2 {
            // v1 dev builds shipped presets pre-trusted; trust must be an explicit user choice.
            let presetIDs = Set(MCPPresets.all.map(\.id))
            mcpServers = mcpServers.map {
                var s = $0; if presetIDs.contains(s.id) { s.trustReadOnlyHints = false }; return s
            }
        }
        settingsVersion = Settings.currentVersion
    }
}

public struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Mode: String, Codable, Sendable { case dictation, edit, agent }
    public var id = UUID()
    public var date = Date()
    public var mode: Mode
    public var transcript: String
    public var output: String
    public var app: String?
    public var durationSeconds: Double = 0

    public init(mode: Mode, transcript: String, output: String, app: String?, durationSeconds: Double = 0) {
        self.mode = mode
        self.transcript = transcript
        self.output = output
        self.app = app
        self.durationSeconds = durationSeconds
    }
}

public struct VocabEntry: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id = UUID()
    /// Correct spelling, e.g. "Kubernetes".
    public var term: String
    /// Optional mis-hearings to replace, e.g. ["cooper netties"].
    public var soundsLike: [String] = []
    public var enabled = true
    public init(term: String, soundsLike: [String] = []) {
        self.term = term
        self.soundsLike = soundsLike
    }
}

public struct MemoryItem: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var text: String
    public var locked = false
    public var created = Date()
    /// Saved while outside content (web, mail, screen…) was in the conversation: it may be injected, so a
    /// conversation that uses it starts tainted until the user trusts it.
    public var fromOutsideContent = false
    public init(text: String, locked: Bool = false, fromOutsideContent: Bool = false) {
        self.text = text
        self.locked = locked
        self.fromOutsideContent = fromOutsideContent
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        fromOutsideContent = try c.decodeIfPresent(Bool.self, forKey: .fromOutsideContent) ?? false
    }
}

public struct ScheduledTask: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case reminder  // show the message
        case agent  // run `instruction` through the agent, show the result
    }
    public var id = UUID()
    public var kind: Kind
    public var instruction: String
    public var fireDate: Date
    /// Seconds between repeats; nil = once.
    public var repeatInterval: Double? = nil
    public var weekdaysOnly = false
    public var created = Date()
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        instruction = try c.decode(String.self, forKey: .instruction)
        fireDate = try c.decode(Date.self, forKey: .fireDate)
        repeatInterval = try c.decodeIfPresent(Double.self, forKey: .repeatInterval)
        weekdaysOnly = try c.decodeIfPresent(Bool.self, forKey: .weekdaysOnly) ?? false
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }

    public init(kind: Kind, instruction: String, fireDate: Date, repeatInterval: Double? = nil) {
        self.kind = kind
        self.instruction = instruction
        self.fireDate = fireDate
        self.repeatInterval = repeatInterval
    }
}

/// JSON-file persistence under ~/Library/Application Support/Paluku.
/// ponytail: whole-file rewrite per save; fine at personal scale, move history to SQLite if it passes ~50k entries.
public final class Store: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Paluku", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func url(_ name: String) -> URL { directory.appending(path: "\(name).json") }

    public func load<T: Decodable>(_ name: String, default def: T) -> T {
        lock.lock()
        defer { lock.unlock() }
        let file = url(name)
        guard let data = try? Data(contentsOf: file) else { return def }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let v = try? dec.decode(T.self, from: data) { return v }
        // Keep the unreadable file: the next save would otherwise overwrite the user's data with the default.
        let backup = file.deletingLastPathComponent().appending(path: "\(name).corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: file, to: backup)
        Telemetry.shared.event(.app, "store_corrupt", level: .error, ["file": name, "backup": backup.lastPathComponent])
        return def
    }

    public func save<T: Encodable>(_ name: String, _ value: T) {
        lock.lock()
        defer { lock.unlock() }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    // Typed accessors
    public var settings: Settings {
        get { load("settings", default: Settings()) }
        set { save("settings", newValue) }
    }
    public var history: [HistoryEntry] {
        get { load("history", default: []) }
        set { save("history", newValue) }
    }
    public var vocabulary: [VocabEntry] {
        get { load("vocabulary", default: []) }
        set { save("vocabulary", newValue) }
    }
    public var memory: [MemoryItem] {
        get { load("memory", default: []) }
        set { save("memory", newValue) }
    }
    public var scheduled: [ScheduledTask] {
        get { load("scheduled", default: []) }
        set { save("scheduled", newValue) }
    }

}
