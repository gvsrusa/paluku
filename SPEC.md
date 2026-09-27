# Spec: Paluku — a local voice assistant for macOS


## Assumptions
1. Single user, single machine: Apple M4 Max, 36 GB RAM, macOS 27, Xcode 27, Swift 6.4.
2. Mac only. Windows, iOS, billing, teams, SSO, referrals: out of scope.
3. All AI runs locally with open-weight models. No paid APIs. Network only for cloud integrations (Gmail, Slack…) and web search.
4. App is not sandboxed and **cannot ship on the Mac App Store** (sandbox forbids Accessibility-based typing, active CGEvent taps, AppleScript to other apps, spawning MCP/coding CLIs). Distributed as a Developer ID–signed, notarized DMG on GitHub Releases (ADR 0001).
5. Ollama (already installed at `/usr/local/bin/ollama`) is the LLM runtime.

## Objective

A menu-bar + notch-overlay Mac app that turns voice into text **and** actions, in any app:

| Mode | Trigger | What happens |
|---|---|---|
| **Dictation** | Hold `fn` (push-to-talk) or double-tap `fn` (hands-free, tap again to stop) | Speech → transcript → polished text (fillers removed, self-corrections applied, grammar/punctuation, list formatting) → pasted at cursor in the frontmost app |
| **Edit** | Select text, hold `fn`, speak an instruction | Selected text rewritten per instruction ("make concise", "translate to Japanese") and replaces the selection |
| **Agent** | Hold **Right ⌥** (configurable) or double-tap for hands-free | Voice request + screen context (screenshot of the window under the cursor, selected text, clipboard, optional circled region) → LLM with tools → answer streamed into notch (and spoken) or action proposed on a confirmation card → executed on approval |

Success = I stop typing emails/messages/prompts and stop opening apps for routine actions.

### Feature inventory (prioritised)

**P0 — core loop**
- Global trigger key: `fn` hold / double-tap hands-free, Escape cancels. Custom key choice.
- Warm mic capture, start/stop sounds, media ducking while recording.
- Local streaming STT, 100 languages (Whisper), max session 20 min with 19-min warning.
- Polish styles: **Raw / Light / Polished**. Filler removal, self-correction ("by today, actually tomorrow" → "by tomorrow"), lists only when clearly asked, prose by default.
- Custom vocabulary / spelling dictionary (names, jargon) fed to STT prompt + polish prompt. Bulk add.
- Paste into any app via clipboard + synthetic ⌘V, restoring the previous clipboard (all types). Detect Secure Keyboard Entry and explain.
- Edit Mode on selected text (read via Accessibility, fallback ⌘C).
- History: every dictation/agent session stored locally (SQLite), searchable, copyable.
- Floating "pill"/notch overlay: recording state, live waveform, transcript, streaming answers.
- Settings: trigger keys, mic, polish style, languages, vocabulary, per-integration confirmation bypass, appearance (light/dark/system), launch at login.
- Onboarding: permission walkthrough (Mic, Accessibility, Screen Recording, Automation, Calendars, Reminders, Contacts).

**P1 — Agent Mode**
- Screen context: screenshot of active window per turn (ScreenCaptureKit), selected text, clipboard, dragged-in files/images.
- Point-and-ask: hold-to-draw trail/circle on screen while talking; captured into screenshot.
- Tool-calling agent loop with multi-step chaining ("check weather Saturday and email Jake").
- **Confirmation cards** for every write action (send, create, delete, move); reads run immediately. Per-integration "don't ask" bypass.
- Spoken replies (TTS) with voice choice + speed; word-by-word reveal in notch.
- Conversation follow-ups within idle timeout; barge-in cancels speech.
- Reply drafting: screen-aware draft card with Insert / Enter buttons.
- Web search + page fetch; weather; maps/nearby places (Apple Maps).
- Rich result cards: files, calendar events, emails, map, weather, media player.
- Memory: lockable core preferences/personal details the agent always sees.

**P1 — Native Mac integrations** (no OAuth; macOS permissions)
| App | Actions | API |
|---|---|---|
| Finder | search (Spotlight), open, reveal, move, rename, create folder, trash (confirm), read file text | `NSMetadataQuery`, `FileManager`, `NSWorkspace` |
| Apple Calendar | list, find free time, create/move/delete event (confirm) | EventKit |
| Reminders | list, create, complete, delete | EventKit |
| Notes | search, read, create, append | AppleScript |
| iMessage | read recent, send (confirm) | AppleScript + `chat.db` read (Full Disk Access) |
| Apple Mail | search, read, draft, reply, send (confirm) | AppleScript |
| Apple Music / Spotify | play, pause, skip, search, volume | AppleScript |
| Apple Maps | search place, directions, nearby | MapKit (`MKLocalSearch`) |
| Contacts | resolve names → email/phone | Contacts.framework |
| Open app / URL | launch app, open URL in named browser | `NSWorkspace` |

**P2 — Cloud integrations via MCP** (cloud apps sign in once)
- Built-in MCP client (stdio + streamable HTTP, Authorization header).
- **First:** Gmail + Google Calendar via open-source MCP servers (Google OAuth, tokens in Keychain).
- Later: Google Drive/Docs/Sheets, Slack, Notion, Linear, Jira, Outlook (MS Graph), Obsidian (local vault = plain files, can be native), X, Canvas.
- Custom integrations: add any MCP server by command or URL; tools appear as voice actions; per-tool confirm toggle.

**P2 — Background & scheduled**
- Reminders/scheduled actions from natural language ("remind me to send Maya the deck at 4", "check inbox for investor email every morning") — stored locally, fired by in-app scheduler, surfaced as notch cards.
- Long agent tasks dispatch to background with side-notch progress and completion notification.
- Claude Code / Codex CLI dispatch as tools (run task in a chosen repo, stream status).

**P3 — Nice to have**
- Create Prompt: talk + circle regions → ready-to-paste prompt with numbered screenshots.
- Insights (words dictated, WPM, time saved).
- Auto-learn vocabulary from Edit-mode corrections.

**Explicitly out of scope:** Windows, iOS/keyboard, subscriptions/checkout, cloud sync, "Studio" AI app builder, App Store publishing, telemetry.

## v1.1 — Release readiness (2026-09-27)

Goal: anyone can download a DMG, install, and run Paluku; models are switchable from the UI; every change is gated by CI.

| # | Requirement | Acceptance |
|---|---|---|
| R1 | **Quick model switch** | Menu bar and agent panel list installed models; picking one applies to the next request (no restart). Separate polish vs agent model. |
| R2 | **Pull models from UI** | Enter e.g. `qwen3:8b` → Pull → progress bar → appears in pickers. Curated list of recommended open models with one-click pull. |
| R3 | **Other open-source runtimes** | Provider = Ollama or OpenAI-compatible (LM Studio, llama.cpp `llama-server`, MLX-LM, Jan, vLLM) with base URL + optional API key; models listed from `/v1/models`; tools + images work. |
| R4 | **Versioning** | SemVer in `project.yml` (`MARKETING_VERSION`); `CHANGELOG.md` (Keep a Changelog); `scripts/release.sh X.Y.Z` bumps, tags `vX.Y.Z`. Version shown in UI. |
| R5 | **CI** | GitHub Actions on push/PR: unit tests, app build, UI snapshot artifact. Red CI blocks merge. |
| R6 | **CD** | Tag `v*` → build Release → sign + notarize + staple when Apple secrets exist (unsigned otherwise, clearly labeled) → DMG + SHA-256 → GitHub Release with changelog notes. |
| R7 | **Update check** | App checks GitHub Releases (daily, opt-out) and shows "Update available vX" in the menu. |
| R8 | **Observability** | `os.Logger` categories (hotkeys, audio, stt, llm, agent, mcp); no transcript/audio content in logs; "Copy diagnostics" in Settings. |
| R9 | **Docs** | README (install/run/dev), docs/: ARCHITECTURE, RELEASING, MODELS, PRIVACY, ADRs, manual QA, CHANGELOG. |
| R10 | **Hardening** | Secrets (MCP env values / API keys) in Keychain not JSON; MCP stdio env not logged; path & URL inputs validated. |

Out of scope for v1.1: Mac App Store build, Sparkle auto-install, Windows.

## Tech Stack (all free / open source)

| Concern | Choice | Why |
|---|---|---|
| App | Swift 6.4 compiler in Swift 5 language mode, SwiftUI + AppKit (`NSPanel` overlays), macOS 15+ target | Native hotkeys, AX, paste, ScreenCaptureKit; strict-concurrency fights C APIs (CGEventTap, AX) |
| STT | **WhisperKit** (MIT, Argmax) with `openai_whisper-large-v3-v20240930_turbo` CoreML; fallback `small` for speed | Best open ASR on Apple Silicon, streaming, 100 langs, prompt biasing for vocab |
| VAD | WhisperKit energy VAD | built in |
| LLM (polish, edit, agent) | **Ollama** HTTP API (`/api/chat`, tools, images). Default picked by Phase-1 benchmark: `gemma4:latest` (installed, vision + tools) vs `qwen3:30b-a3b` — latency + tool-call accuracy. Model name configurable per role (polish / agent) | Local, free, swappable |
| Vision / screen Q&A | Same Ollama model with `images` (gemma4 is multimodal); alt `qwen2.5vl:7b` | |
| TTS | `AVSpeechSynthesizer` (Premium/Siri voices) v1; **Kokoro-82M** (Apache-2.0) via local runner v2 | Native first, upgrade for quality |
| Web search | **DuckDuckGo HTML** endpoint; page text via `URLSession` + tag stripping; weather via Open-Meteo; places via MapKit | No API key, no Docker |
| MCP | `modelcontextprotocol/swift-sdk` (official) | Standard |
| Storage | JSON files in `~/Library/Application Support/Paluku` (history, vocab, memory, schedule, settings) | Personal scale; move history to SQLite past ~50k entries |
| Secrets | Keychain (`Security.framework`) for OAuth tokens / MCP env | Never plaintext |
| Hotkeys | `CGEventTap` on `flagsChanged` (`.maskSecondaryFn`) | `fn` isn't bindable via Carbon |
| Project gen | **XcodeGen** (`project.yml`) — keeps `.xcodeproj` out of git | Diffable config |
| Tests | Swift Testing (`import Testing`) | Ships with Xcode |

Dependencies (SPM): WhisperKit, MCP swift-sdk. Nothing else without asking.

## Commands

```bash
scripts/lint.sh                      # swift-format check
scripts/test.sh                      # unit tests (CI)
scripts/build.sh [Debug|Release]     # xcodegen + xcodebuild → build/dd/Build/Products/<cfg>/Paluku.app
scripts/install.sh                   # Release build → /Applications
scripts/package.sh                   # DMG (+ sign/notarize when Apple creds set) → dist/
scripts/release.sh X.Y.Z --push      # bump, changelog, tag → release.yml publishes
PALUKU_LIVE=1 [PALUKU_PERF=1|PALUKU_BENCH=1] swift test --package-path Packages/PalukuCore --filter <Live|Perf|Benchmark>
```

## Project Structure

```
project.yml                  → XcodeGen config (app target, Info.plist keys, entitlements)
App/                         → Paluku.app: thin SwiftUI/AppKit shell
  PalukuApp.swift               → @main, MenuBarExtra, AppDelegate
  Coordinator.swift          → owns subsystems; dictation / edit / agent / scheduler flows
  Overlay.swift              → notch panel (pill, agent conversation, cards, confirm, draft), pointing trail
  MainWindow.swift           → History+Insights, General, Dictionary, Integrations, Memory & Schedule, Setup
  Snapshot.swift             → `--snapshot <dir>` renders UI states to PNG
Packages/PalukuCore/            → Swift package, all logic, unit-testable
  Sources/PalukuCore/
    AudioRecorder.swift      → mic → 16 kHz mono, ducking
    Transcriber.swift        → WhisperKit
    Hotkeys.swift            → TriggerStateMachine (pure) + CGEventTap monitor
    TextIO.swift             → paste with clipboard restore, selection read, active app
    LLM.swift                → LLM protocol + Ollama client
    Prompts.swift, Polisher.swift
    Agent.swift              → Tool, Card, Schema, Agent loop with confirmation
    ScreenContext.swift, Speaker.swift, Scheduler.swift, Store.swift
    MCPHub.swift, MCPPresets.swift
    Tools/                   → Calendar/Reminders, Finder, Apple apps, Web/Maps/Weather, System, Shell
  Tests/PalukuCoreTests/        → unit, live (PALUKU_LIVE=1), benchmark (PALUKU_BENCH=1)
scripts/                     → lint, test, build, install, package, release, make-icon
docs/                        → ARCHITECTURE, RELEASING, MODELS, PRIVACY, SECURITY, decisions/ (ADRs), manual QA, benchmark
.github/workflows/            → ci.yml, release.yml
tasks/                       → plan.md, todo.md
```

## Code Style

Swift 5 language mode, `async/await`, actors for shared mutable state, no Combine unless SwiftUI requires it. Value types for data; protocols only where there are ≥2 real implementations (e.g. `LLM`: Ollama + test fakes). 4-space indent, `swift-format` defaults. Errors are typed enums, surfaced to the user as a notch message — never swallowed.

```swift
Tool(
    name: "reminders_create", description: "Create an Apple Reminder, optionally with a due date/time.",
    parameters: Schema.object(["title": Schema.string("reminder text"), "due": Schema.string("ISO due date/time")], required: ["title"]),
    integration: "reminders", isWrite: true,   // write → Agent shows a confirmation card first
    preview: { a in "☑︎ \(a.optString("title") ?? "")" }
) { args in
    try await requireReminders()
    let r = EKReminder(eventStore: store)
    r.title = try args.string("title")
    try store.save(r, commit: true)
    return ToolResult("Created reminder", card: Card(icon: "checklist", title: "Reminder added"))
}
```

Naming: types `UpperCamel`, tool names `app_verb` snake_case (LLM-facing). Prompts live in `Prompts.swift` as static strings with a comment on intent.

## Testing Strategy

- **Framework:** Swift Testing in `Packages/PalukuCore/Tests`. Runs via `swift test`, no UI host.
- **Unit (bulk):** polish prompt post-processing, vocabulary injection, confirmation policy, agent loop with a fake LLM + fake tools, MCP tool bridging with an in-process server, scheduler time parsing, clipboard save/restore.
- **Golden tests for polish:** `Tests/Fixtures/polish/*.json` — raw transcript → expected contains/not-contains assertions (not exact match; LLM output varies). Run against live Ollama behind `PALUKU_LIVE=1`.
- **Integration (manual/live, `PALUKU_LIVE=1`):** WhisperKit on recorded WAV fixtures (WER sanity), Ollama tool-call round-trip, EventKit create+delete in a test calendar.
- **Manual checklist** per release in `docs/manual-qa.md`: dictation into TextEdit/Slack/Chrome/Terminal/VS Code, edit mode, agent confirm/deny, permissions revoked.
- No coverage target; every non-trivial branch (policy, parsing, loop) has one test.

## Performance Targets

- Key-down → recording starts: < 100 ms (warm mic).
- Key-up → text pasted, 10 s utterance, Polished: < 1.5 s; Raw: < 0.6 s.
- Agent first token / first spoken word: < 2 s for simple questions.
- Idle CPU < 1 %, idle RAM (models unloaded after 5 min) < 300 MB app + Ollama's own.

## Boundaries

- **Always:** confirm before any write/send/delete action (unless user enabled bypass for that integration); keep audio in memory only (never write to disk unless debug flag); store transcripts locally only; restore clipboard after paste; run `swift test` before commit; secrets in Keychain.
- **Ask first:** adding any dependency beyond the three listed; changing default models; adding network calls to new hosts; enabling Full Disk Access–dependent features; changing DB schema after v1 data exists.
- **Never:** send audio/transcripts to any cloud service; commit tokens/OAuth secrets; use any other product's branding or assets; auto-send messages without confirmation by default; disable a failing test to get green.

## Success Criteria

1. Hold `fn`, say "um so can you send me that form by today actually I mean tomorrow", release → "Can you send me that form by tomorrow?" appears in TextEdit, Slack, Chrome and Terminal within 1.5 s; original clipboard intact.
2. Select a paragraph, hold `fn`, "make this more concise" → selection replaced with a shorter version.
3. Agent: "What's on my calendar tomorrow?" → spoken + card answer from Apple Calendar, no confirmation.
4. Agent: "Remind me to send Maya the deck at 4pm" → confirmation card → approve → reminder exists in Reminders.app.
5. Agent while viewing an email: "Draft a reply saying yes, Thursday works" → draft card with Insert → text inserted in the reply field.
6. Agent: "Find last year's tax return PDF" → Finder results card, click opens file.
7. Connect Gmail MCP → "check the weather for Saturday and email Jake saying let's go surfing, include the forecast" → confirmation card → email sent.
8. Airplane mode: dictation, edit, and native-app agent actions still work.
9. Nothing under `~/Library/Application Support/Paluku` contains audio.

## Decisions (2026-09-27)

- Agent trigger: Right ⌥ hold; double-tap = hands-free. Dictation: `fn`.
- First cloud integrations: Gmail + Google Calendar via MCP.
- Web search: DuckDuckGo HTML.
- Default LLM: decided by Phase-1 benchmark (gemma4 vs qwen3:30b-a3b) — see docs/benchmark.md.
- Tools are one concrete `Tool` struct (closure-based) shared by native, web and MCP tools; confirmation is enforced in `Agent`, not in tools.
- Google integrations use one open-source MCP server (taylorwilsdon/google_workspace_mcp via `uvx`) covering Gmail, Calendar, Drive, Docs, Sheets.
- App is ad-hoc signed (no Developer ID on this Mac); rebuilding may require re-granting Accessibility/Screen Recording.

- Distribution = notarized DMG via GitHub Releases, CI = GitHub Actions (remote is GitHub). See docs/adr.

## Open Questions

1. App name — keep "Paluku"?
