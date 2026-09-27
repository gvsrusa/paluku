import AVFoundation
import AppKit
import Observation
import PalukuCore
import ServiceManagement

/// One agent exchange shown in the notch panel.
struct Turn: Identifiable, Equatable {
    let id = UUID()
    var user: String
    var answer = ""
    var cards: [Card] = []
    var activity: String? = nil
    var hasScreenshot = false
}

struct Notice: Identifiable, Equatable {
    let id = UUID()
    var icon: String
    var title: String
    var body: String
}

enum Phase: Equatable {
    case idle
    case recording(VoiceMode, handsFree: Bool)
    case transcribing(VoiceMode)
    case thinking
}

/// Owns every subsystem and runs the dictation / edit / agent flows.
@MainActor @Observable
final class Coordinator {
    static let shared = Coordinator()

    /// `--snapshot` renders demo data into a throwaway store, never the user's files.
    let store = Store(
        directory: CommandLine.arguments.contains("--snapshot")
            ? FileManager.default.temporaryDirectory.appending(path: "paluku-snapshot-\(UUID().uuidString)") : nil)
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            let raw = settings.mcpServers
            settings.mcpServers = Keychain.externalize(raw)  // secrets never hit settings.json
            store.settings = settings
            applySettings(old: oldValue, rawServers: raw)
        }
    }
    var vocabulary: [VocabEntry] { didSet { store.vocabulary = vocabulary } }
    var memory: [MemoryItem] { didSet { store.memory = memory } }
    var scheduled: [ScheduledTask] { didSet { store.scheduled = scheduled } }
    var history: [HistoryEntry] = []

    // UI state
    var phase: Phase = .idle
    var level: Float = 0
    var turns: [Turn] = []
    var panelVisible = false
    var mainTab: MainTab = .history
    /// Confirmation cards waiting for the user, oldest first. Each has its own continuation (no overwrites).
    var confirmQueue: [ConfirmRequest] = []
    var pendingConfirm: ConfirmRequest? { confirmQueue.first }
    var draft: String?
    var notices: [Notice] = []
    var toast: String?
    var speechModelState: Transcriber.State = .idle
    var mcpStatus: [String: MCPHub.Status] = [:]
    var trail: [CGPoint] = []  // CG global coords
    var recordingStarted: Date?

    // Subsystems
    @ObservationIgnored let recorder = AudioRecorder()
    @ObservationIgnored let transcriber: Transcriber
    @ObservationIgnored let hub = MCPHub()
    @ObservationIgnored let speaker = Speaker()
    @ObservationIgnored var hotkeys: HotkeyMonitor!
    @ObservationIgnored var agent: Agent!
    @ObservationIgnored var llm: any LLM & ModelLister
    var availableModels: [String] = []
    var modelsError: String?
    var pulls: [String: PullProgress] = [:]
    @ObservationIgnored private var confirmWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// Which agent run asked (agentGeneration), so a superseded run's cards can be declined. Background tasks use -1.
    @ObservationIgnored private var confirmOwner: [UUID: Int] = [:]
    @ObservationIgnored private var targetApp: ActiveApp?
    @ObservationIgnored private var selection: String?
    @ObservationIgnored private var lastAgentActivity = Date.distantPast
    @ObservationIgnored private var agentTask: Task<Void, Never>?
    @ObservationIgnored private var agentGeneration = 0
    @ObservationIgnored private var mouseMonitor: Any?
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var maxLengthWarned = false
    @ObservationIgnored private var session = ""
    var update: UpdateChecker.Release?
    /// Progress text while an update installs ("Downloading…", "Verifying…"); nil when idle.
    var updateStatus: String?

    static let maxRecordingSeconds: Double = 20 * 60

    private init() {
        settings = store.settings
        vocabulary = store.vocabulary
        memory = store.memory
        scheduled = store.scheduled
        history = store.history
        llm = LLMFactory.make(store.settings, apiKey: Keychain.get("provider.apiKey"))
        transcriber = Transcriber(modelsDirectory: store.directory.appending(path: "models"))
    }

    // MARK: Lifecycle

    func start() {
        hotkeys = HotkeyMonitor(dictationKey: settings.dictationKey, agentKey: settings.agentKey)
        // Out of the event-tap callback: AX/audio/AppleScript work there stalls every keystroke and can get the tap disabled.
        hotkeys.onEffect = { [weak self] e in DispatchQueue.main.async { self?.handle(e) } }
        hotkeys.swallowEscape = { [weak self] in
            guard let self else { return false }
            if case .transcribing = self.phase {
                self.cancelTranscription()
                return true
            }
            guard self.panelVisible, self.phase == .idle else { return false }
            self.closePanel()
            return true
        }
        startHotkeysWhenTrusted()

        recorder.onLevel = { [weak self] l in Task { @MainActor in self?.level = l } }
        agent = Agent(llm: llm, model: settings.agentModel, tools: [], bypass: Set(settings.confirmBypass))
        speaker.rate = settings.speechRate
        speaker.voiceIdentifier = settings.voiceIdentifier

        loadSpeechModel()
        Task {
            await hub.sync(settings.mcpServers); await refreshMCP()
        }
        Task {
            await refreshModels()
            if let ollama = llm as? OllamaClient { try? await ollama.warmUp(model: settings.polishModel) }
        }

        timers.append(Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.tickScheduler() } })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } })
        tickScheduler()
        Telemetry.shared.event(.app, "app_started", ["version": AppInfo.version])
        Updater.removeLeftovers(near: Bundle.main.bundleURL)
        afterUpdateCheck()
        if CommandLine.arguments.contains("--update") {
            // `open -a Paluku --args --update`: same path as the menu's "Install … and restart" (scripted updates, QA).
            Task {
                update = await UpdateChecker.latestNewer(than: AppInfo.version)
                if update == nil { flash("Paluku \(AppInfo.version) is up to date.") } else { installUpdate() }
            }
        } else {
            checkForUpdates()
        }
    }

    /// Unsigned (ad-hoc) builds: macOS ties permissions to the exact build, so after an update the toggles look on but
    /// no longer apply. Say so and open Setup instead of letting hotkeys silently stop working.
    private func afterUpdateCheck() {
        let key = "paluku.updatedFrom"
        guard let from = UserDefaults.standard.string(forKey: key) else { return }
        UserDefaults.standard.removeObject(forKey: key)
        Telemetry.shared.event(.app, "updated", ["from": from, "to": AppInfo.version, "accessibility": String(TextIO.hasAccessibility)])
        if TextIO.hasAccessibility {
            flash("Updated from \(from) to Paluku \(AppInfo.version).")
        } else {
            MainWindow.show(tab: .setup)
            post(
                Notice(
                    icon: "checkmark.shield", title: "Paluku \(AppInfo.version) installed",
                    body:
                        "macOS needs you to allow Paluku again: in Privacy & Security, turn Paluku off and on under Accessibility (and Microphone or Screen Recording if asked)."
                ))
        }
    }

    func checkForUpdates(manual: Bool = false) {
        guard settings.checkForUpdates || manual else { return }
        Task {
            update = await UpdateChecker.latestNewer(than: AppInfo.version)
            if manual && update == nil { flash("Paluku \(AppInfo.version) is up to date.") }
        }
    }

    /// Downloads, verifies and installs `update` over this app, then relaunches. Falls back to the release page when the
    /// app can't be replaced in place (running from the DMG, translocated, or not writable).
    func installUpdate() {
        guard let u = update, updateStatus == nil else { return }
        let app = Bundle.main.bundleURL
        let requirement: String?
        switch Updater.readiness(u, app: app) {
        case .ready(let r): requirement = r
        case .manual(let reason):
            flash("\(reason) Opening the download page.")
            NSWorkspace.shared.open(u.url)
            return
        }
        updateStatus = "Preparing update…"
        Task {
            do {
                try await Updater.install(u, over: app, requirement: requirement) { s in Task { @MainActor in Coordinator.shared.updateStatus = s } }
                updateStatus = "Restarting…"
                UserDefaults.standard.set(AppInfo.version, forKey: "paluku.updatedFrom")
                Updater.relaunch(app)
                NSApp.terminate(nil)
            } catch {
                updateStatus = nil
                Telemetry.shared.event(.app, "update_failed", level: .error, ["error": String(describing: type(of: error))])
                flash("Update failed: \(error.localizedDescription)")
            }
        }
    }

    /// Plain-text report for bug reports: versions, config (no secrets), permissions, latency stats, recent events.
    func diagnostics() -> String {
        var lines = ["Paluku \(AppInfo.version) (\(AppInfo.build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        lines.append(
            "provider=\(settings.provider.rawValue) agent=\(settings.agentModel) polish=\(settings.polishModel) whisper=\(settings.whisperModel) style=\(settings.polishStyle.rawValue)"
        )
        lines.append(
            "speech_model=\(speechModelState) models_available=\(availableModels.count) mcp=\(mcpStatus.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ","))"
        )
        lines.append("accessibility=\(TextIO.hasAccessibility) screen=\(ScreenContext.hasPermission)")
        lines.append("\n# latency (p50 / p95 ms, n)")
        for (k, v) in Telemetry.shared.stats().sorted(by: { $0.key < $1.key }) {
            lines.append("\(k): \(Int(v.p50 * 1000)) / \(Int(v.p95 * 1000)) ms (n=\(v.count))")
        }
        lines.append("\n# recent events")
        lines += Telemetry.shared.recentEvents.suffix(120)
        return lines.joined(separator: "\n")
    }

    /// Accessibility may be granted after launch; retry until the event tap starts.
    private func startHotkeysWhenTrusted() {
        if hotkeys.start() { return }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { return t.invalidate() }
                if self.hotkeys.start() { t.invalidate() }
            }
        }
    }

    func loadSpeechModel() {
        let model = settings.whisperModel
        Task {
            await transcriber.load(model: model) { s in Task { @MainActor in self.speechModelState = s } }
            speechModelState = await transcriber.state
        }
    }

    private func applySettings(old: Settings, rawServers: [MCPServerConfig]) {
        hotkeys?.dictationKey = settings.dictationKey
        hotkeys?.agentKey = settings.agentKey
        speaker.rate = settings.speechRate
        speaker.voiceIdentifier = settings.voiceIdentifier
        if settings.whisperModel != old.whisperModel { loadSpeechModel() }
        if settings.provider != old.provider || settings.ollamaURL != old.ollamaURL || settings.openAIBaseURL != old.openAIBaseURL {
            rebuildLLM()
        }
        if rawServers != old.mcpServers {
            let changed = settings.mcpServers.filter { s in rawServers.first { $0.id == s.id } != old.mcpServers.first { $0.id == s.id } }
            Task {
                await hub.sync(settings.mcpServers)
                for c in changed { await hub.restart(c) }
                await refreshMCP()
            }
        }
    }

    /// Polled by the Integrations tab; assign only on change so the view (and its scroll position) is left alone.
    func refreshMCP() async {
        let s = await hub.status
        if s != mcpStatus { mcpStatus = s }
    }

    /// Removes an MCP server and its Keychain secrets.
    func removeServer(_ id: String) {
        if let s = settings.mcpServers.first(where: { $0.id == id }) { Keychain.purge(s) }
        settings.mcpServers.removeAll { $0.id == id }
    }

    // MARK: Models

    func rebuildLLM() {
        resetConversation()  // the new Agent starts empty; keep the panel in sync
        llm = LLMFactory.make(settings, apiKey: Keychain.get("provider.apiKey"))
        agent = Agent(llm: llm, model: settings.agentModel, tools: [], bypass: Set(settings.confirmBypass))
        Task { await refreshModels() }
    }

    func setAPIKey(_ key: String) {
        guard key != (Keychain.get("provider.apiKey") ?? "") else { return }
        Keychain.set(key, for: "provider.apiKey")
        rebuildLLM()
    }

    func refreshModels() async {
        modelsGeneration += 1
        let gen = modelsGeneration, llm = llm
        do {
            let models = try await llm.models()
            guard gen == modelsGeneration else { return }  // a newer refresh (e.g. URL changed) owns the result
            availableModels = models
            modelsError = nil
            Telemetry.shared.event(.llm, "models_listed", ["provider": settings.provider.rawValue, "count": String(availableModels.count)])
        } catch {
            guard gen == modelsGeneration else { return }
            availableModels = []
            Telemetry.shared.event(.llm, "llm_unreachable", level: .error, ["provider": settings.provider.rawValue])
            modelsError =
                settings.provider == .ollama
                ? "Can't reach Ollama at \(settings.ollamaURL). Install it from ollama.com and make sure it's running."
                : "Can't reach \(settings.openAIBaseURL): \(error.localizedDescription)"
        }
    }
    private var modelsGeneration = 0

    /// Downloads an Ollama model with live progress in `pulls`.
    func pull(_ model: String) {
        let name = model.trimmingCharacters(in: .whitespaces)
        guard let ollama = llm as? OllamaClient, !name.isEmpty, pulls[name] == nil else { return }
        pulls[name] = PullProgress(status: "starting")
        Task {
            do {
                for try await p in ollama.pull(name) { pulls[name] = p }
                pulls[name] = nil
                await refreshModels()
                flash("Downloaded \(name)")
            } catch {
                pulls[name] = nil
                flash("Couldn't download \(name): \(error.localizedDescription)")
            }
        }
    }

    func deleteModel(_ model: String) {
        guard let ollama = llm as? OllamaClient else { return }
        Task {
            do { try await ollama.delete(model) } catch { flash(error.localizedDescription) }
            await refreshModels()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { flash(error.localizedDescription) }
    }

    // MARK: Hotkey effects

    private func handle(_ effect: TriggerStateMachine.Effect) {
        switch effect {
        case .start(let mode): beginRecording(mode)
        case .handsFree(let mode): if case .recording = phase { phase = .recording(mode, handsFree: true) }
        case .stop(let mode): if case .recording = phase { finishRecording(mode) }
        case .cancel: cancelRecording()
        case .scheduleTimeout: break
        }
    }

    private func beginRecording(_ mode: VoiceMode) {
        guard phase == .idle || phase == .thinking else {  // agent may be barged-in on while thinking
            hotkeys.resetState()
            return
        }
        speaker.stop()  // barge-in
        targetApp = ActiveApp.current
        selection = TextIO.axSelectedText().flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        do {
            try recorder.start()
        } catch {
            hotkeys.resetState()
            flash(error.localizedDescription)
            return
        }
        if settings.duckMedia { Ducker.duck() }
        Sounds.start()
        session = Telemetry.newSession()
        Telemetry.shared.event(.hotkeys, "recording_started", session: session, ["mode": mode.rawValue, "edit": String(selection != nil)])
        recordingStarted = Date()
        maxLengthWarned = false
        phase = .recording(mode, handsFree: false)
        if mode == .agent {
            // Never reset under a live run or open card (it would drop the run's taint mid-flight).
            if agentTask == nil, confirmQueue.isEmpty, Date().timeIntervalSince(lastAgentActivity) > settings.agentIdleResetSeconds {
                resetConversation()
            }
            panelVisible = true
            startTrail()
        }
    }

    private func cancelRecording() {
        Telemetry.shared.event(.hotkeys, "recording_cancelled", session: session)
        recorder.stop()
        Ducker.restore()
        stopTrail()
        phase = agentTask == nil ? .idle : .thinking
        if turns.isEmpty && draft == nil && pendingConfirm == nil { panelVisible = false }
    }

    private func finishRecording(_ mode: VoiceMode) {
        let samples = recorder.stop()
        Ducker.restore()
        Sounds.stop()
        stopTrail()
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        phase = .transcribing(mode)
        let app = targetApp, sel = selection, points = trail, sid = session
        Telemetry.shared.event(.hotkeys, "recording_stopped", session: sid, ["audio_s": String(format: "%.1f", duration)])
        transcribeTask = Task {
            let text: String
            let sttStart = Date()
            do {
                text = try await transcriber.transcribe(samples, language: settings.language, vocabulary: vocabulary.filter(\.enabled).map(\.term))
                Telemetry.shared.timing(.stt, "stt_done", seconds: Date().timeIntervalSince(sttStart), session: sid, ["chars": String(text.count)])
            } catch {
                if Task.isCancelled { return }
                Telemetry.shared.event(.stt, "stt_failed", session: sid, level: .error, ["error": String(describing: type(of: error))])
                phase = agentTask == nil ? .idle : .thinking
                flash(error.localizedDescription)
                return
            }
            guard !text.isEmpty, !Polisher.isHallucination(text) else {
                phase = agentTask == nil ? .idle : .thinking
                if mode == .agent && turns.isEmpty { panelVisible = false }
                return
            }
            guard !Task.isCancelled else { return }  // Esc while transcribing
            switch mode {
            case .dictation: await dictate(text, app: app, selection: sel, duration: duration)
            case .agent: runAgent(text, app: app, selection: sel, trail: points)
            }
        }
    }

    /// Transcription + polish of the last recording; Esc cancels it (a stalled model can't hold the pill).
    private var transcribeTask: Task<Void, Never>?

    private func cancelTranscription() {
        transcribeTask?.cancel()
        transcribeTask = nil
        phase = agentTask == nil ? .idle : .thinking
        Telemetry.shared.event(.hotkeys, "transcription_cancelled", session: session)
    }

    // MARK: Dictation & Edit

    private var polisher: Polisher { Polisher(llm: llm, model: settings.polishModel) }

    private func dictate(_ transcript: String, app: ActiveApp?, selection: String?, duration: Double) async {
        let output: String
        let mode: HistoryEntry.Mode
        let sid = session, polishStart = Date()
        if let selection {
            mode = .edit
            do { output = try await polisher.edit(selection: selection, instruction: transcript) } catch {
                if Task.isCancelled { return }
                phase = agentTask == nil ? .idle : .thinking
                flash("Edit failed: \(error.localizedDescription)")
                return
            }
        } else {
            mode = .dictation
            output = await polisher.polish(transcript, style: settings.polishStyle, vocabulary: vocabulary, appName: app?.name)
        }
        Telemetry.shared.timing(
            .llm, "polish_done", seconds: Date().timeIntervalSince(polishStart), session: sid,
            ["mode": mode.rawValue, "model": settings.polishModel])
        guard !Task.isCancelled else { return }  // Esc pressed while the model was polishing
        phase = agentTask == nil ? .idle : .thinking
        guard !output.isEmpty else { return }
        if await returnFocus(to: app) {
            do {
                try await TextIO.insert(output)
                Telemetry.shared.event(.app, "paste_done", session: sid, ["app": app?.bundleID ?? "?"])
            } catch {
                Telemetry.shared.event(
                    .app, "paste_failed", session: sid, level: .error, ["app": app?.bundleID ?? "?", "error": String(describing: type(of: error))])
                flash(error.localizedDescription)
            }
        } else {
            // The user switched apps while we were transcribing; don't type into the wrong window.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
            Telemetry.shared.event(.app, "paste_redirected_to_clipboard", session: sid)
            flash("You switched apps, so the text is on the clipboard — press ⌘V to paste.")
        }
        let entry = HistoryEntry(mode: mode, transcript: transcript, output: output, app: app?.name, durationSeconds: duration)
        history.insert(entry, at: 0)
        persistHistory()
        if mode == .edit { learnVocabulary(from: selection ?? "", to: output, spoken: transcript) }
    }

    /// Edit-mode corrections of proper nouns feed the dictionary.
    /// Only words the user actually said count: the selection and model output may be untrusted.
    private func learnVocabulary(from old: String, to new: String, spoken: String) {
        guard old.split(separator: " ").count <= 4 else { return }  // only short spelling fixes
        let newWords = Set(new.split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) })
        let oldWords = Set(old.split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) })
        for w in newWords.subtracting(oldWords)
        where w.first?.isUppercase == true && w.count > 2 && spoken.localizedCaseInsensitiveContains(w)
            && !vocabulary.contains(where: { $0.term == w })
        {
            vocabulary.append(VocabEntry(term: w, soundsLike: Array(oldWords.subtracting(newWords)).filter { !$0.isEmpty }))
        }
    }

    /// Makes sure the app that had focus when recording started is frontmost again. False if it can't be.
    private func returnFocus(to app: ActiveApp?) async -> Bool {
        guard let app, ActiveApp.current?.pid != app.pid else { return true }
        guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated else { return false }
        running.activate()
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(30))
            if ActiveApp.current?.pid == app.pid { return true }
        }
        return false
    }

    /// Writes history off the main thread (JSON encode of the whole list).
    func persistHistory() {
        let snapshot = history, store = store
        Self.historyQueue.async { store.history = snapshot }
    }
    /// Serial, so an older snapshot can never land after a newer one.
    private static let historyQueue = DispatchQueue(label: "paluku.history", qos: .utility)

    // MARK: Agent

    func tools() async -> [Tool] {
        let hooks = SystemTools.Hooks(
            insert: { text in
                await MainActor.run {
                    Coordinator.shared.draft = text; Coordinator.shared.panelVisible = true
                }
            },
            // Tools run on the Agent actor, never on main: hop explicitly (assumeIsolated would trap).
            remember: { fact, outside in await MainActor.run { Coordinator.shared.memory.append(MemoryItem(text: fact, fromOutsideContent: outside)) } },
            schedule: { t in await MainActor.run { Coordinator.shared.scheduled.append(t) } },
            listScheduled: { await MainActor.run { Coordinator.shared.scheduled } },
            cancelScheduled: { id in
                await MainActor.run {
                    let c = Coordinator.shared
                    let before = c.scheduled.count
                    c.scheduled.removeAll { $0.id == id }
                    return c.scheduled.count != before
                }
            })
        return SystemTools.all(hooks) + WebTools.all() + CalendarTools.all + FinderTools.all
            + AppleAppTools.all + (await hub.tools)
    }

    private func systemPrompt() -> String {
        Prompts.agentSystem(userName: settings.userName, memory: memory.map(\.text))
    }

    private func runAgent(_ text: String, app: ActiveApp?, selection: String?, trail: [CGPoint]) {
        // Voice answer to a pending confirmation card.
        if pendingConfirm != nil, let yes = VoiceConfirmation.parse(text) {
            // Answers the card that is on screen (the queue's first), never one hidden behind it.
            if let first = confirmQueue.first, confirmOwner[first.id] == -1, yes {
                flash("Scheduled-task actions need a click to approve.")
            } else {
                resolveConfirm(id: confirmQueue.first?.id, yes)
            }
            phase = agentTask == nil ? .idle : .thinking
            return
        }
        // Supersede the running request: decline its open cards, cancel its task (Agent.send checks cancellation).
        cancelConfirms(owner: agentGeneration)
        agentTask?.cancel()
        panelVisible = true
        draft = nil
        turns.append(Turn(user: text))
        let idx = turns.count - 1
        phase = .thinking
        lastAgentActivity = Date()
        agentGeneration += 1
        let generation = agentGeneration

        let sid = session, turnStart = Date()
        let agent: Agent = self.agent  // stay on one Agent even if settings rebuild it mid-run
        agentTask = Task {
            var shot: Data?
            if settings.useScreenContext { shot = await ScreenContext.captureFrontWindow(pid: app?.pid, trail: trail) }
            if shot != nil, turns.indices.contains(idx) { turns[idx].hasScreenshot = true }
            let tools = await tools()
            await agent.configure(model: settings.agentModel, tools: tools, bypass: Set(settings.confirmBypass))
            // Screen, selected text, MCP tool descriptions and untrusted memories are outside content, like tool results.
            // "Trust read-only labels" only skips cards for reads; it doesn't make the server's descriptions trusted.
            if shot != nil || selection != nil || settings.mcpServers.contains(where: \.enabled) || memory.contains(where: \.fromOutsideContent) {
                await agent.markTainted()
            }
            do {
                let answer = try await agent.send(
                    Prompts.agentMessage(text, appName: app?.name, selectedText: selection), images: shot.map { [$0] } ?? [], system: systemPrompt(),
                    confirm: { req in await Coordinator.shared.askConfirmation(req, owner: generation) },
                    emit: { ev in Task { @MainActor in Coordinator.shared.apply(ev, turn: idx, generation: generation) } })
                guard generation == agentGeneration else { return }  // stopped or superseded: leave the UI alone
                if turns.indices.contains(idx) {
                    turns[idx].answer = answer
                    turns[idx].activity = nil
                }
                Telemetry.shared.timing(
                    .agent, "agent_turn_done", seconds: Date().timeIntervalSince(turnStart), session: sid,
                    ["model": settings.agentModel, "screenshot": String(shot != nil)])
                if settings.speakReplies, !answer.isEmpty, !Task.isCancelled, generation == agentGeneration { speaker.speak(answer) }
                history.insert(HistoryEntry(mode: .agent, transcript: text, output: answer, app: app?.name), at: 0)
                persistHistory()
            } catch {
                guard generation == agentGeneration else { return }
                Telemetry.shared.event(
                    .agent, "agent_turn_failed", session: sid, level: .error, ["model": settings.agentModel, "error": String(describing: type(of: error))])
                if turns.indices.contains(idx) {
                    turns[idx].answer = "⚠️ \(error.localizedDescription)"
                    turns[idx].activity = nil
                }
                if (error as? URLError)?.code == .cannotConnectToHost, turns.indices.contains(idx) {
                    turns[idx].answer =
                        settings.provider == .ollama
                        ? "⚠️ Ollama isn't running. Start it with `ollama serve`."
                        : "⚠️ Can't reach the model server at \(settings.openAIBaseURL). Is it running?"
                }
            }
            lastAgentActivity = Date()
            guard generation == agentGeneration else { return }  // superseded by a newer request
            agentTask = nil
            if phase == .thinking { phase = .idle }
        }
    }

    private func apply(_ ev: AgentEvent, turn idx: Int, generation: Int) {
        guard generation == agentGeneration else { return }
        guard turns.indices.contains(idx) else { return }
        switch ev {
        case .token(let t): turns[idx].answer += t; turns[idx].activity = nil
        case .toolStarted(let name): turns[idx].activity = Self.activityLabel(name); turns[idx].answer = ""
        case .card(let c): turns[idx].cards.append(c)
        }
    }

    static func activityLabel(_ tool: String) -> String {
        let t = tool.components(separatedBy: "__").last ?? tool
        return t.replacingOccurrences(of: "_", with: " ").capitalized + "…"
    }

    func askConfirmation(_ req: ConfirmRequest, owner: Int) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                if Task.isCancelled { return c.resume(returning: false) }
                confirmQueue.append(req)
                confirmWaiters[req.id] = c
                confirmOwner[req.id] = owner
                panelVisible = true
            }
        } onCancel: {
            Task { @MainActor in Coordinator.shared.resolveConfirm(id: req.id, false) }
        }
    }

    /// Answers a card (the oldest when `id` is nil). Each continuation is resumed exactly once.
    func resolveConfirm(id: UUID? = nil, _ ok: Bool, always: Bool = false) {
        guard let id = id ?? confirmQueue.first?.id, let waiter = confirmWaiters.removeValue(forKey: id) else { return }
        if always, let req = confirmQueue.first(where: { $0.id == id }), req.canAlwaysAllow, !settings.confirmBypass.contains(req.integration) {
            settings.confirmBypass.append(req.integration)
        }
        confirmQueue.removeAll { $0.id == id }
        confirmOwner[id] = nil
        waiter.resume(returning: ok)
    }

    private func cancelConfirms(owner: Int) {
        for (id, o) in confirmOwner where o == owner { resolveConfirm(id: id, false) }
    }

    func insertDraft(pressReturn: Bool) {
        guard let d = draft else { return }
        draft = nil
        panelVisible = !turns.isEmpty && pendingConfirm != nil
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            do {
                try await TextIO.insert(d)
                if pressReturn { try? await Task.sleep(for: .milliseconds(150)); TextIO.pressReturn() }
            } catch { flash(error.localizedDescription) }
        }
    }

    func stopAgent() {
        cancelConfirms(owner: agentGeneration)
        agentGeneration += 1  // any late result from the stopped run is ignored
        agentTask?.cancel()
        speaker.stop()
        agentTask = nil
        if phase == .thinking { phase = .idle }  // never hide a live recording
    }

    func resetConversation() {
        if agentTask != nil || !confirmQueue.isEmpty { stopAgent() }  // never reset under a live run (keeps taint honest)
        Task { await agent.reset() }
        turns = []
        draft = nil
    }

    func closePanel() {
        if case .recording = phase {  // hands-free: closing the panel must also turn the mic off
            cancelRecording()
            hotkeys.resetState()
        }
        stopAgent()
        for req in confirmQueue { resolveConfirm(id: req.id, false) }  // incl. background tasks' cards
        panelVisible = false
        notices = []
    }

    // MARK: Pointing trail

    private func startTrail() {
        trail = []
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .recording(.agent, _) = self.phase else { return }
                let p = ScreenContext.cgPoint(fromAppKit: NSEvent.mouseLocation)
                if let last = self.trail.last, hypot(last.x - p.x, last.y - p.y) < 3 { return }
                self.trail.append(p)
                if self.trail.count > 600 { self.trail.removeFirst(100) }
            }
        }
    }

    private func stopTrail() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        // keep `trail` until the screenshot is taken; clear shortly after for the on-screen overlay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.trail = [] }
    }

    // MARK: Timers

    private func tick() {
        if case .recording(let mode, _) = phase, let s = recordingStarted {
            let elapsed = Date().timeIntervalSince(s)
            if elapsed > Self.maxRecordingSeconds - 60, !maxLengthWarned {
                maxLengthWarned = true
                flash("1 minute left in this recording")
            }
            if elapsed >= Self.maxRecordingSeconds {
                hotkeys.resetState()
                finishRecording(mode)
            }
        }
        if panelVisible, phase == .idle, pendingConfirm == nil, draft == nil, agentTask == nil, !speaker.isSpeaking,
            Date().timeIntervalSince(lastAgentActivity) > max(30, settings.agentIdleResetSeconds), notices.isEmpty
        {
            panelVisible = false
        }
    }

    private func tickScheduler() {
        let (fire, remaining) = Scheduler.due(scheduled, now: Date())
        guard !fire.isEmpty else { return }
        scheduled = remaining
        for t in fire {
            switch t.kind {
            case .reminder:
                post(Notice(icon: "alarm", title: "Reminder", body: t.instruction))
                if settings.speakReplies { speaker.speak(t.instruction) }
            case .agent:
                Task { await runBackground(t.instruction) }
            }
        }
    }

    /// Scheduled agent tasks run on a fresh conversation; writes still need confirmation.
    private func runBackground(_ instruction: String) async {
        // Starts tainted: the instruction may have been planted by untrusted content, so egress always asks.
        let bg = Agent(llm: llm, model: settings.agentModel, tools: await tools(), bypass: Set(settings.confirmBypass), tainted: true)
        do {
            let answer = try await bg.send(
                Prompts.agentMessage(instruction), system: systemPrompt(),
                confirm: { req in
                    var r = req
                    r.summary = "⏰ Scheduled task wants to:\n" + r.summary
                    return await Coordinator.shared.askConfirmation(r, owner: -1)
                }, emit: { _ in })
            post(Notice(icon: "sparkles", title: "Scheduled task", body: answer))
        } catch {
            post(Notice(icon: "exclamationmark.triangle", title: "Scheduled task failed", body: error.localizedDescription))
        }
    }

    func post(_ n: Notice) {
        notices.append(n)
        panelVisible = true
        Sounds.notify()
    }

    func flash(_ message: String) {
        toast = message
        panelVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in if self?.toast == message { self?.toast = nil } }
    }
}

enum Sounds {
    static func start() { NSSound(named: "Tink")?.play() }
    static func stop() { NSSound(named: "Pop")?.play() }
    static func notify() { NSSound(named: "Glass")?.play() }
}
