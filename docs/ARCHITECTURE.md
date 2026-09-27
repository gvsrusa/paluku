# Architecture

```
┌───────────────────────── App/ (SwiftUI + AppKit shell) ─────────────────────────┐
│ PalukuApp (menu bar) · Overlay (notch panel, pill, trail) · MainWindow (settings)  │
│ Coordinator — owns subsystems, runs the three flows, confirmation queue         │
└──────────────┬───────────────────────────────────────────────────────┬──────────┘
               │ uses                                                  │
┌──────────────▼──────────────── Packages/PalukuCore ──────────────────────▼─────────┐
│ Input     Hotkeys (TriggerStateMachine + CGEventTap) · AudioRecorder · Ducker   │
│ Speech    Transcriber (WhisperKit)                                              │
│ Language  LLM protocol → OllamaClient | OpenAICompatibleClient (LLMFactory)     │
│           Prompts · Polisher (dictation/edit)                                   │
│ Agent     Agent actor (tool loop, confirmation + taint policy) · Tool · Card    │
│ Tools     Calendar/Reminders · Finder · Apple apps · Web/Maps/Weather · System  │
│           MCPHub (stdio/HTTP MCP servers → Tools)                               │
│ Output    TextIO (paste + clipboard restore, selection) · Speaker · Screen      │
│ Platform  Store (JSON) · Keychain · Scheduler · Telemetry · UpdateChecker       │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Flows

**Dictation / Edit**
1. `fn` goes down. The `HotkeyMonitor` state machine decides whether this is hold (push-to-talk), double-tap (hands-free) or a cancel.
2. `AudioRecorder` captures 16 kHz mono audio.
3. When the key is released, `Transcriber` produces the transcript.
4. `Polisher` cleans it up, or edits the selected text if there was one.
5. `TextIO.insert` pastes the result with ⌘V into the app that had focus when recording started. If that app lost focus, the text goes to the clipboard instead. The previous clipboard is restored afterwards.

**Agent**
1. Right ⌥ goes down. Recording starts, and moving the mouse draws a pointing trail.
2. When the key is released, the audio is transcribed and a screenshot of the window under the cursor is taken.
3. `Agent.send` sends a stable system prompt plus a per-turn context message (time, app, selected text) to the model.
4. The model calls tools. Before running a write, or an egress call after untrusted content has been read, the agent shows a confirmation card and waits (`askConfirmation`, which is queued by request id).
5. Text streams into the notch panel, cards render, and the reply is spoken.

**Scheduled tasks.** `Scheduler.due` checks every 15 s. Reminders appear as notices. Agent tasks run on a fresh `Agent(tainted: true)`.

## Key invariants

- The **confirmation policy lives in one place**, `Agent.needsConfirmation` ([ADR-0006](decisions/0006-agent-confirmation-policy.md)). Tools only declare flags: `isWrite`, `egress`, `untrusted`, `allowBypass`.
- **Run supersession.** Each `send` bumps `runID`. A stale run stops at its next await and never appends to the conversation. The Coordinator's `agentGeneration` gates UI updates.
- **Secrets** exist only in the Keychain. `settings.json` holds placeholders ([ADR-0005](decisions/0005-json-store-and-keychain-secrets.md)).
- **Telemetry** logs event names, durations and error *types* only, never content.

## Data on disk

`~/Library/Application Support/Paluku/` holds:
- `settings.json`, `history.json`, `vocabulary.json`, `memory.json` and `scheduled.json`
- `models/`, the Whisper CoreML files

Audio is never written to disk.

## Testing

| Layer | Where | Runs in CI |
|---|---|---|
| Unit: agent loop, policy, parsing, scheduler, hotkeys, providers, security abuse cases | `Tests/PalukuCoreTests/*Tests.swift` | ✓ |
| Live: Ollama, Whisper, MCP server, OpenAI-compatible, model pull | `LiveTests.swift` (`PALUKU_LIVE=1`) | – (needs local models) |
| Performance budgets | `PerfTests.swift` (`PALUKU_PERF=1`) | – |
| Tool-selection benchmark | `BenchmarkTests.swift` (`PALUKU_BENCH=1`) | – |
| UI | `Paluku --snapshot <dir>` (CI uploads the PNGs as an artifact) | ✓ |
| Permissioned end-to-end (mic, typing, Apple apps) | [manual-qa.md](manual-qa.md) | – |
