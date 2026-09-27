import AVFoundation
import Contacts
import EventKit
import PalukuCore
import ServiceManagement
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case history = "History", general = "General", models = "Models", vocabulary = "Dictionary", integrations = "Integrations", memory = "Memory & Schedule",
        setup = "Setup"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .history: "clock"
        case .general: "gearshape"
        case .models: "cpu"
        case .vocabulary: "character.book.closed"
        case .integrations: "puzzlepiece.extension"
        case .memory: "brain"
        case .setup: "checkmark.shield"
        }
    }
}

struct MainWindow: View {
    @Bindable var c = Coordinator.shared
    var tab: MainTab { c.mainTab }

    var body: some View {
        NavigationSplitView {
            List(MainTab.allCases, selection: $c.mainTab) { t in
                Label(t.rawValue, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Self.detail(tab)
        }
    }

    @ViewBuilder static func detail(_ tab: MainTab) -> some View {
        switch tab {
        case .history: HistoryView()
        case .general: GeneralView()
        case .models: ModelsView()
        case .vocabulary: VocabularyView()
        case .integrations: IntegrationsView()
        case .memory: MemoryView()
        case .setup: SetupView()
        }
    }

    @MainActor static var window: NSWindow?

    @MainActor static func show(tab: MainTab = .history) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Coordinator.shared.mainTab = tab
        if let w = window {  // switch tabs in place: rebuilding the hosting view would drop scroll and search state
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Paluku"
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 720, height: 480)
        w.contentView = NSHostingView(rootView: MainWindow())
        w.center()
        w.setFrameAutosaveName("PalukuMainWindow")
        w.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            NSApp.setActivationPolicy(.accessory)
        }
        window = w
    }
}

// MARK: History + Insights

struct HistoryView: View {
    @Bindable var c = Coordinator.shared
    @State var query = ""
    @State var confirmClear = false

    var filtered: [HistoryEntry] {
        query.isEmpty
            ? c.history : c.history.filter { $0.output.localizedCaseInsensitiveContains(query) || $0.transcript.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Insights(history: c.history).padding()
            List(filtered) { e in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: e.mode == .agent ? "sparkles" : e.mode == .edit ? "pencil" : "waveform")
                        Text(e.date, format: .relative(presentation: .named)).font(.caption)
                        if let app = e.app { Text("· \(app)").font(.caption) }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.output, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless).help("Copy").accessibilityLabel("Copy")
                    }.foregroundStyle(.secondary)
                    Text(e.output).textSelection(.enabled)
                    if e.transcript != e.output {
                        Text(e.transcript).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
                .contextMenu {
                    Button("Delete") {
                        c.history.removeAll { $0.id == e.id }; c.persistHistory()
                    }
                }
            }
            .searchable(text: $query)
            .overlay {
                if c.history.isEmpty {
                    ContentUnavailableView(
                        "No history yet", systemImage: "waveform",
                        description: Text("Hold \(c.settings.dictationKey.label) and speak. Everything you dictate shows up here."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            Button("Clear All", role: .destructive) { confirmClear = true }.disabled(c.history.isEmpty)
        }
        .confirmationDialog("Delete all history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) {
                c.history = []; c.persistHistory()
            }
        } message: {
            Text("This can't be undone.")
        }
    }
}

struct Insights: View {
    var history: [HistoryEntry]
    var body: some View {
        let dict = history.filter { $0.mode != .agent }
        let words = dict.reduce(0) { $0 + $1.output.split(separator: " ").count }
        let secs = dict.reduce(0) { $0 + $1.durationSeconds }
        let wpm = secs > 10 ? Int(Double(words) / (secs / 60)) : 0
        let savedMin = max(0, Double(words) / 40 - secs / 60)  // vs ~40 wpm typing
        HStack(spacing: 24) {
            stat("\(words)", "words dictated")
            stat(wpm > 0 ? "\(wpm)" : "–", "words / min")
            stat(String(format: "%.0f min", savedMin), "time saved")
            stat("\(history.filter { $0.mode == .agent }.count)", "agent requests")
        }
    }
    func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading) {
            Text(v).font(.title2.weight(.semibold).monospacedDigit())
            Text(l).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: General

struct GeneralView: View {
    @Bindable var c = Coordinator.shared
    @State var launchAtLogin = SMAppService.mainApp.status == .enabled

    static let whisperModels = [
        "openai_whisper-large-v3-v20240930_turbo", "openai_whisper-large-v3-v20240930_626MB",
        "distil-whisper_distil-large-v3_turbo", "openai_whisper-small", "openai_whisper-base",
    ]
    static let languages: [(String, String?)] = [
        ("Auto-detect", nil), ("English", "en"), ("Spanish", "es"), ("French", "fr"), ("German", "de"), ("Hindi", "hi"),
        ("Telugu", "te"), ("Tamil", "ta"), ("Japanese", "ja"), ("Chinese", "zh"), ("Korean", "ko"), ("Portuguese", "pt"),
        ("Italian", "it"), ("Russian", "ru"), ("Arabic", "ar"),
    ]

    var body: some View {
        Form {
            Section("Keys") {
                Picker("Dictation key", selection: $c.settings.dictationKey) { ForEach(TriggerKey.allCases) { Text($0.label).tag($0) } }
                Picker("Agent key", selection: $c.settings.agentKey) { ForEach(TriggerKey.allCases) { Text($0.label).tag($0) } }
                Text("Hold to talk, release to finish. Double-tap for hands-free, tap again to stop. Esc cancels. Select text first to edit it by voice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dictation") {
                Picker("Polish", selection: $c.settings.polishStyle) {
                    Text("Raw — exactly what you said").tag(PolishStyle.raw)
                    Text("Light — remove fillers, punctuate").tag(PolishStyle.light)
                    Text("Polished — clean, corrected, formatted").tag(PolishStyle.polished)
                }
                Picker("Language", selection: $c.settings.language) { ForEach(Self.languages, id: \.0) { Text($0.0).tag($0.1) } }
                Picker("Speech model", selection: $c.settings.whisperModel) { ForEach(Self.whisperModels, id: \.self) { Text($0).tag($0) } }
                LabeledContent("Model status") { Text(statusText(c.speechModelState)).foregroundStyle(.secondary) }
                Toggle("Lower other audio while recording", isOn: $c.settings.duckMedia)
            }
            Section("Models") {
                LabeledContent("Agent", value: c.settings.agentModel)
                LabeledContent("Dictation & edit", value: c.settings.polishModel)
                Button("Change models…") { MainWindow.show(tab: .models) }
            }
            Section("Agent") {
                TextField("Your name", text: $c.settings.userName)
                Toggle("Speak replies", isOn: $c.settings.speakReplies)
                Picker("Voice", selection: $c.settings.voiceIdentifier) {
                    Text("Automatic (best installed)").tag(String?.none)
                    ForEach(Speaker.availableVoices.filter { $0.language.hasPrefix("en") }, id: \.identifier) { v in
                        Text("\(v.name) (\(v.language))\(v.quality == .premium ? " ★" : v.quality == .enhanced ? " +" : "")").tag(Optional(v.identifier))
                    }
                }
                Slider(value: $c.settings.speechRate, in: 0.35...0.65) { Text("Speech rate") }
                Toggle("Attach screenshot of the current window", isOn: $c.settings.useScreenContext)
                Stepper(
                    "New conversation after \(Int(c.settings.agentIdleResetSeconds)) s idle", value: $c.settings.agentIdleResetSeconds, in: 30...1800, step: 30)
                Text("Download better voices: System Settings › Accessibility › Spoken Content › System Voice › Manage Voices.").font(.caption).foregroundStyle(
                    .secondary)
            }
            Section("App") {
                Toggle("Launch at login", isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, v in c.setLaunchAtLogin(v) }
                Toggle("Check for updates automatically", isOn: $c.settings.checkForUpdates)
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                if let u = c.update {
                    Button("Download Paluku \(u.version)") { NSWorkspace.shared.open(u.url) }
                } else {
                    Button("Check for Updates") { c.checkForUpdates(manual: true) }
                }
            }
            Section {
                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c.diagnostics(), forType: .string)
                    c.flash("Diagnostics copied — paste into a bug report.")
                }
                Text("Includes versions, settings (no secrets), permission status, latency stats and recent events. Never includes what you said.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Troubleshooting")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    func statusText(_ s: Transcriber.State) -> String {
        switch s {
        case .idle: "Not loaded"
        case .downloading(let p): "Downloading \(Int(p * 100))%"
        case .loading: "Loading…"
        case .ready: "Ready"
        case .failed(let e): "Error: \(e)"
        }
    }
}

// MARK: Vocabulary

struct VocabularyView: View {
    @Bindable var c = Coordinator.shared
    @State var term = ""
    @State var soundsLike = ""
    @State var bulk = ""

    var body: some View {
        Form {
            Section("Add word") {
                TextField("Correct spelling (e.g. Kubernetes)", text: $term).onSubmit(addTerm)
                TextField("Often misheard as (comma-separated, optional)", text: $soundsLike).onSubmit(addTerm)
                Button("Add", action: addTerm).disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section("Bulk add (one per line or comma-separated)") {
                TextEditor(text: $bulk).frame(height: 70).font(.body)
                Button("Add all") {
                    let words = bulk.components(separatedBy: CharacterSet(charactersIn: ",\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
                        !$0.isEmpty
                    }
                    c.vocabulary += words.filter { w in !c.vocabulary.contains { $0.term.caseInsensitiveCompare(w) == .orderedSame } }.map {
                        VocabEntry(term: $0)
                    }
                    bulk = ""
                }.disabled(bulk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Dictionary (\(c.vocabulary.count))") {
                if c.vocabulary.isEmpty { Text("No words yet. Add names, jargon and acronyms Whisper gets wrong.").foregroundStyle(.secondary) }
                ForEach($c.vocabulary) { $v in
                    HStack {
                        Toggle("", isOn: $v.enabled).labelsHidden()
                        Text(v.term).bold()
                        if !v.soundsLike.isEmpty { Text("← " + v.soundsLike.joined(separator: ", ")).foregroundStyle(.secondary) }
                        Spacer()
                        Button {
                            c.vocabulary.removeAll { $0.id == v.id }
                        } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless).accessibilityLabel("Delete")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dictionary")
    }

    func addTerm() {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let sounds = soundsLike.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let i = c.vocabulary.firstIndex(where: { $0.term.caseInsensitiveCompare(t) == .orderedSame }) {
            c.vocabulary[i].soundsLike += sounds.filter { !c.vocabulary[i].soundsLike.contains($0) }  // merge, don't drop input
        } else {
            c.vocabulary.append(VocabEntry(term: t, soundsLike: sounds))
        }
        term = ""; soundsLike = ""
    }
}

// MARK: Integrations

struct IntegrationsView: View {
    @Bindable var c = Coordinator.shared
    @State var editing: MCPServerConfig?

    static let native: [(String, String, String)] = [
        ("calendar", "Calendar", "calendar"), ("reminders", "Reminders", "checklist"), ("finder", "Finder", "folder"),
        ("notes", "Notes", "note.text"), ("mail", "Apple Mail", "envelope"), ("messages", "Messages", "message"),
        ("media", "Music / Spotify", "music.note"), ("contacts", "Contacts", "person.crop.circle"), ("maps", "Maps", "map"),
        ("web", "Web search & weather", "globe"), ("coding", "Claude Code / Codex", "chevron.left.forwardslash.chevron.right"),
        ("paluku", "Paluku (insert, schedule, memory)", "waveform"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.native, id: \.0) { id, name, icon in
                    HStack {
                        Label(name, systemImage: icon)
                        Spacer()
                        Text("Skip confirmation").font(.caption).foregroundStyle(.secondary)
                        Toggle("Skip confirmation", isOn: bypass(id)).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                }
            } header: {
                Text("Built-in")
            } footer: {
                Text("Actions that send, create, change or delete show a confirmation card unless you skip it here.").font(.caption)
            }
            Section {
                ForEach($c.settings.mcpServers) { $s in
                    HStack {
                        Toggle("", isOn: $s.enabled).labelsHidden()
                        VStack(alignment: .leading) {
                            Text(s.name)
                            Text(status(s.id)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Skip confirmation", isOn: bypass("mcp.\(s.id)")).toggleStyle(.switch).controlSize(.small).labelsHidden().help(
                            "Skip confirmation")
                        Button("Edit") { editing = s }
                        Button {
                            c.removeServer(s.id)
                        } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless).accessibilityLabel("Delete")
                    }
                }
                Button("Add MCP server…") {
                    let taken = Set(c.settings.mcpServers.map(\.id))
                    let id = (1...).lazy.map { "custom\($0)" }.first { !taken.contains($0) }!
                    editing = MCPServerConfig(id: id, name: "My server", command: "npx", args: ["-y", "package-name"])
                }
            } header: {
                Text("MCP servers (Gmail, Google Calendar, Drive, Notion, anything)")
            } footer: {
                Text(
                    "Google Workspace: create an OAuth “Desktop app” client at console.cloud.google.com (enable Gmail + Calendar + Drive APIs), paste its client ID and secret into the Google server's environment, enable it, then ask the agent something — your browser opens once for consent. Turn on “Trust this server's read-only labels” in Edit if you want Gmail/Calendar reads to skip confirmation."
                ).font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Integrations")
        .sheet(item: $editing) { s in
            MCPEditor(server: s, isExisting: c.settings.mcpServers.contains { $0.id == s.id }, takenIDs: Set(c.settings.mcpServers.map(\.id))) { saved in
                if let i = c.settings.mcpServers.firstIndex(where: { $0.id == s.id }) {
                    c.settings.mcpServers[i] = saved
                } else {
                    c.settings.mcpServers.append(saved)
                }
                editing = nil
            } cancel: {
                editing = nil
            }
        }
        .task { while !Task.isCancelled { await c.refreshMCP(); try? await Task.sleep(for: .seconds(2)) } }
    }

    func bypass(_ id: String) -> Binding<Bool> {
        Binding(
            get: { c.settings.confirmBypass.contains(id) },
            set: { on in
                c.settings.confirmBypass.removeAll { $0 == id }
                if on { c.settings.confirmBypass.append(id) }
            })
    }

    func status(_ id: String) -> String {
        switch c.mcpStatus[id] {
        case .connected(let n): "Connected · \(n) tools"
        case .connecting: "Connecting…"
        case .failed(let e): "Error: \(e)"
        default: "Off"
        }
    }
}

struct MCPEditor: View {
    @State var server: MCPServerConfig
    var isExisting = false
    var takenIDs: Set<String> = []
    var save: (MCPServerConfig) -> Void
    var cancel: () -> Void
    @State var envText = ""
    @State var argsText = ""

    /// Duplicate IDs would make two servers fight over one tool prefix and Keychain entry.
    var idProblem: String? {
        if isExisting { return nil }
        let id = MCPServerConfig.sanitizedID(server.id)
        if id.isEmpty { return "ID must contain letters or digits." }
        return takenIDs.contains(id) ? "A server with ID “\(id)” already exists." : nil
    }

    var body: some View {
        Form {
            TextField("Name", text: $server.name)
            TextField("ID (tool prefix)", text: $server.id).disabled(isExisting)
                .help(isExisting ? "Remove and re-add the server to change its ID (secrets are stored per ID)." : "")
            if let idProblem { Text(idProblem).font(.caption).foregroundStyle(.red) }
            Toggle("Trust this server's read-only labels (skip confirmation for tools it marks read-only)", isOn: $server.trustReadOnlyHints)
            Section("Local server (stdio)") {
                TextField("Command", text: Binding(get: { server.command ?? "" }, set: { server.command = $0.isEmpty ? nil : $0 }))
                TextField("Arguments (space-separated)", text: $argsText)
                Text("Environment (KEY=value per line)").font(.caption)
                TextEditor(text: $envText).font(.system(.body, design: .monospaced)).frame(height: 90)
            }
            Section("Or remote server (streamable HTTP)") {
                TextField("URL", text: Binding(get: { server.url ?? "" }, set: { server.url = $0.isEmpty ? nil : $0 }))
                SecureField(
                    "Authorization header (e.g. Bearer …)",
                    text: Binding(get: { server.authorizationHeader ?? "" }, set: { server.authorizationHeader = $0.isEmpty ? nil : $0 }))
            }
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Button("Save") {
                    server.id = MCPServerConfig.sanitizedID(server.id)
                    server.args = argsText.split(separator: " ").map(String.init)
                    server.env = Dictionary(
                        envText.split(separator: "\n").compactMap { line -> (String, String)? in
                            let p = line.split(separator: "=", maxSplits: 1).map(String.init)
                            return p.count == 2 ? (p[0].trimmingCharacters(in: .whitespaces), p[1].trimmingCharacters(in: .whitespaces)) : nil
                        }, uniquingKeysWith: { $1 })
                    save(server)
                }.buttonStyle(.borderedProminent).disabled(idProblem != nil)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .onAppear {
            argsText = server.args.joined(separator: " ")
            envText = server.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        }
    }
}

// MARK: Memory & schedule

struct MemoryView: View {
    @Bindable var c = Coordinator.shared
    @State var newFact = ""
    var body: some View {
        Form {
            Section("Memory — the agent always knows these") {
                ForEach($c.memory) { $m in
                    HStack {
                        Button {
                            m.locked.toggle()
                        } label: {
                            Image(systemName: m.locked ? "lock.fill" : "lock.open")
                        }.buttonStyle(.borderless).help("Locked items can't be removed by the agent")
                        TextField("Fact", text: $m.text).labelsHidden().multilineTextAlignment(.leading)
                        if m.fromOutsideContent {
                            Button("Trust") { m.fromOutsideContent = false }
                                .help(
                                    "Saved while the agent was reading outside content (web, mail, screen), so it may have been planted. Until you trust it, conversations are treated as containing outside content: sending data out always asks."
                                )
                            Image(systemName: "exclamationmark.shield").foregroundStyle(.orange).accessibilityLabel("From outside content")
                        }
                        Button {
                            c.memory.removeAll { $0.id == m.id }
                        } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless).accessibilityLabel("Delete")
                    }
                }
                HStack {
                    TextField("New fact", text: $newFact, prompt: Text(verbatim: "Add a fact, e.g. “My manager is Priya”")).labelsHidden().onSubmit(addFact)
                    Button("Add", action: addFact).disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Scheduled") {
                if c.scheduled.isEmpty { Text("Nothing scheduled. Try: “remind me to send Maya the deck at 4pm”.").foregroundStyle(.secondary) }
                ForEach(c.scheduled) { t in
                    HStack {
                        Image(systemName: t.kind == .agent ? "sparkles" : "alarm")
                        VStack(alignment: .leading) {
                            Text(t.instruction)
                            Text(t.fireDate.formatted(date: .abbreviated, time: .shortened) + (t.repeatInterval != nil ? " · repeats" : "")).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            c.scheduled.removeAll { $0.id == t.id }
                        } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless).accessibilityLabel("Delete")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Memory & Schedule")
    }

    func addFact() {
        let f = newFact.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return }
        if !c.memory.contains(where: { $0.text.caseInsensitiveCompare(f) == .orderedSame }) { c.memory.append(MemoryItem(text: f, locked: true)) }
        newFact = ""
    }
}

// MARK: Setup / permissions

struct SetupView: View {
    @Bindable var c = Coordinator.shared
    /// Polled every 2 s; assigned only when a value changes so the Form isn't re-rendered (and scroll kept) needlessly.
    struct Status: Equatable {
        var mic = false, ax = false, screen = false, calendars = false, reminders = false, contacts = false, fullDisk = false, server = false
    }
    @State var status = Status()

    var requiredReady: Int { [status.mic, status.ax, c.speechModelState == .ready, status.server].filter { $0 }.count }

    var body: some View {
        Form {
            Section {
                Text("Paluku runs fully on this Mac: Whisper for speech, Ollama for the language model. Grant the permissions below once.")
                    .foregroundStyle(.secondary)
            }
            Section {
                row("Microphone", "mic", status.mic) {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    open("Privacy_Microphone")
                }
                row("Accessibility (hotkeys + typing)", "accessibility", status.ax) {
                    TextIO.requestAccessibility()
                    open("Privacy_Accessibility")
                }
                speechModelRow
                row(c.settings.provider == .ollama ? "Ollama running" : "Model server reachable", "cpu", status.server, button: "Install") {
                    NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                }
            } header: {
                HStack {
                    Text("Required")
                    Spacer()
                    Text("\(requiredReady) of 4 ready").foregroundStyle(requiredReady == 4 ? .green : .secondary)
                }
            }
            Section("For Agent Mode") {
                row("Screen Recording (point & ask)", "macwindow", status.screen) {
                    ScreenContext.requestPermission()
                    open("Privacy_ScreenCapture")
                }
                row("Calendars", "calendar", status.calendars) {
                    Task { _ = try? await EKEventStore().requestFullAccessToEvents() }
                }
                row("Reminders", "checklist", status.reminders) {
                    Task { _ = try? await EKEventStore().requestFullAccessToReminders() }
                }
                row("Contacts", "person.crop.circle", status.contacts) {
                    CNContactStore().requestAccess(for: .contacts) { _, _ in }
                }
                row(
                    "Full Disk Access (read iMessages)", "externaldrive",
                    status.fullDisk
                ) {
                    open("Privacy_AllFiles")
                }
                Text("Notes, Mail, Messages and Music ask for Automation permission the first time the agent uses them.").font(.caption).foregroundStyle(
                    .secondary)
            }
            Section("Tip: the 🌐 / fn key") {
                Text("Set System Settings › Keyboard › “Press 🌐 key to” → **Do Nothing**, so holding fn doesn't open the emoji picker or Apple dictation.")
                Button("Open Keyboard settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
            }
            Section {
                Button("Done") {
                    c.settings.onboarded = true; MainWindow.window?.close()
                }.buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .task {
            // Cancelled automatically when the tab closes; the network check runs every 5th poll (~10 s).
            for poll in 0... {
                await refresh(checkServer: poll % 5 == 0)
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
            }
        }
    }

    @ViewBuilder var speechModelRow: some View {
        switch c.speechModelState {
        case .ready: row("Speech model", "waveform", true) {}
        case .downloading(let p):
            LabeledContent {
                ProgressView(value: p).frame(width: 120)
            } label: {
                Label("Speech model · downloading \(Int(p * 100))%", systemImage: "waveform")
            }
        case .loading:
            LabeledContent {
                ProgressView().controlSize(.small)
            } label: {
                Label("Speech model · loading", systemImage: "waveform")
            }
        case .failed(let e): row("Speech model failed to load", "waveform", false, button: "Retry") { c.loadSpeechModel() }.help(e)
        case .idle: row("Speech model", "waveform", false, button: "Load") { c.loadSpeechModel() }
        }
    }

    func refresh(checkServer: Bool) async {
        var s = status
        s.mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        s.ax = TextIO.hasAccessibility
        s.screen = ScreenContext.hasPermission
        s.calendars = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        s.reminders = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        s.contacts = CNContactStore.authorizationStatus(for: .contacts) == .authorized
        s.fullDisk = FileManager.default.isReadableFile(atPath: NSHomeDirectory() + "/Library/Messages/chat.db")
        if checkServer { s.server = (try? await c.llm.models()) != nil }
        if s != status { status = s }
    }

    func row(_ title: String, _ icon: String, _ ok: Bool, button: String = "Grant", fix: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if ok {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Ready")
            } else {
                Button(button, action: fix)
            }
        }
    }

    func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
