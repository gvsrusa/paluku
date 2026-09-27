# Todo

## Phase 1 — Foundation
- [x] T1 Scaffold PalukuCore package + XcodeGen app shell (menu bar). Verify: `swift build`, `xcodebuild build`.
- [x] T2 Store (JSON files) for settings/history/vocab/memory. Verify: tests round-trip.
- [x] T3 OllamaClient (chat, stream, tools, images) + LLM protocol. Verify: fake tests + live `PALUKU_LIVE=1`.
- [x] T4 Prompts + Polisher (raw/light/polished, vocab). Verify: tests.

## Phase 2 — Dictation
- [x] T5 AudioRecorder (AVAudioEngine 16 kHz mono) + ducking.
- [x] T6 Transcriber (WhisperKit, vocab prompt).
- [x] T7 HotkeyMonitor (fn hold/double-tap, Right ⌥, Esc) — state machine tested.
- [x] T8 Paster (clipboard save/restore, ⌘V) + SelectionReader (AX + ⌘C fallback).
- [x] T9 DictationPipeline + pill overlay. Verify: manual dictation into TextEdit.

## Phase 3 — Edit, History, Settings
- [x] T10 Edit mode (selection + instruction → replace).
- [x] T11 History window (search, copy). Vocabulary editor. Settings. Onboarding permissions.

## Phase 4 — Agent
- [x] T12 Tool protocol, ToolRegistry, AgentLoop w/ confirmation policy — tested with fake LLM.
- [x] T13 Screen context (ScreenCaptureKit window under cursor), draw trail.
- [x] T14 Agent notch panel: streaming answer, confirmation cards, reply draft Insert.
- [x] T15 TTS (AVSpeechSynthesizer), barge-in.

## Phase 5 — Native tools
- [x] T16 Calendar + Reminders (EventKit)
- [x] T17 Finder (Spotlight) + open app/URL
- [x] T18 Notes, Mail, Messages, Music/Spotify (AppleScript)
- [x] T19 Contacts, Maps, web search (DDG), fetch page, weather (Open-Meteo)

## Phase 6 — MCP + Scheduler
- [x] T20 MCPHub: stdio + HTTP servers → tools; settings UI; Gmail/GCal presets
- [x] T21 Scheduler: reminders/scheduled agent actions + notch cards

## Phase 7 — Finish
- [x] T22 Model benchmark script; set default
- [x] T23 README, manual QA checklist, final build

# v1.1 — Release readiness
## A. Models
- [x] T24 OpenAICompatibleClient (chat, stream SSE, tools, images, /v1/models) — tests first
- [x] T25 Ollama pull with progress + recommended open models catalog
- [x] T26 Model pickers: menu bar, agent panel, Models settings tab (provider, URL, key, pull)
## B. Platform
- [x] T27 Keychain for MCP env secrets + provider API key
- [x] T28 os.Logger categories + Copy diagnostics
- [x] T29 Version in UI + GitHub Releases update check
## C. Pipeline
- [x] T30 scripts: build.sh, test.sh, dmg.sh, notarize.sh, release.sh; CHANGELOG.md
- [x] T31 .github/workflows ci.yml + release.yml; verify green on GitHub
## D. Quality
- [x] T32 code review → security → performance → simplification; fix findings
## E. Docs & ship
- [x] T33 README, docs/ARCHITECTURE, RELEASING, MODELS, PRIVACY, ADRs 0001-0003
- [x] T34 Tag v1.1.0 → GitHub Release with DMG; verify download installs

## Quality log (v1.1)
- [x] Five-axis code review + security audit (independent reviewers) → all Critical/High fixed with tests
- [x] Doubt-driven: 3 adversarial cycles on the agent security boundary (cycle 2 findings reproduced on-device, fixed)
- [x] Performance: measured, fixed hidden reasoning + render loop, budgets asserted by PerfTests
- [x] Simplification: dead code removed in a separate commit
- [ ] Follow-up: unit-test target for App/Coordinator (confirmation queue, flows) — currently covered by Agent tests + manual QA
- [ ] Follow-up: DNS-rebinding TOCTOU (connect to pinned IP) — accepted trade-off, see docs/SECURITY.md
# v1.2 — Polish pass
- [x] T35 5-axis code review → fix Critical/High test-first
- [x] T36 Security audit → abuse-case tests + fixes
- [x] T37 Model-switch UX check (pickers, empty/unreachable states)
- [x] T38 Homebrew cask generation in release pipeline
- [x] T39 Simplify + perf spot-check
- [x] T40 Docs + CHANGELOG 1.2.0
- [ ] T41 Release v1.2.0 and verify artifacts
## Quality log (v1.2)
- [x] Fresh 5-axis review (14 findings) + security audit (12) → fixed test-first (ReviewV12Tests, SecurityTests)
- [x] Doubt-driven cycle on the fixes → 5 more (cask rollback, home/iCloud regressions, honest tool results) fixed
- [x] Simplification pass; perf budgets (PALUKU_PERF) green: key-up→text p50 1.03 s, agent first token 0.12 s
- [x] Follow-up: Esc cancels a stuck transcription (bounded by the 20/40 s polish timeouts today)
- [x] Follow-up: memories remember their origin (see docs/SECURITY.md accepted trade-offs)
