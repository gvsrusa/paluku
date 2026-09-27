# Model benchmark (2026-09-27, M4 Max 36 GB)

`PALUKU_LIVE=1 PALUKU_BENCH=1 swift test --package-path Packages/PalukuCore --filter Benchmark`

12 agent prompts, real tool catalogue (~45 tools, side effects stubbed); correct = first tool called.

| Model | Tool accuracy | Avg turn (tool + answer) | Notes |
|---|---|---|---|
| **gemma4:latest** | **12/12** | ~6.6 s* | Vision + tools; default |
| qwen3:30b-a3b | 10/12 | much slower (run contended) | Chose contacts_search before messages_send; `think:false` sent |

Polish (dictation cleanup), gemma4: correct on all fixtures ("by today… actually tomorrow" → "by tomorrow";
"Thursday no wait Friday" → "Friday"; does not answer questions). ~0.35 s warm single request; 3 s avg when
measured concurrently with other live tests.*

Whisper large-v3 turbo (CoreML): 5 s utterance → exact transcript in 0.6 s.

\* Timings taken while other live tests shared the GPU; single-user numbers are lower.

## Latency & resource budgets (2026-09-27, after v1.1 performance pass)

`PALUKU_LIVE=1 PALUKU_PERF=1 swift test --package-path Packages/PalukuCore --filter Perf` (asserts the budgets)

| Metric | Before | After | Budget |
|---|---|---|---|
| Dictation key-up → text, 9.9 s of speech (STT + polish) | 4.99 s | **1.04 s** (0.64 + 0.40) | < 1.5 s |
| Agent first token, simple question (p50) | 6.90 s | **0.12 s** | < 2 s |
| Idle CPU (Setup window open) | 1–20 % | **0.1–0.2 %** | < 1 % |
| Idle memory (physical footprint) | 134 MB | **106 MB** | < 300 MB |

Root causes found by profiling:
1. **Hidden reasoning tokens.** gemma4 was spending ~4 s "thinking" before its first visible token on every request (TTFT 4.0 s vs 0.3 s of generation). Ollama `think: false` is now sent for every model (non-thinking models accept it — verified with smollm2).
2. **Setup view rebuilding every 1.5 s** via `.id(tick)` and polling the model server each time. Now polls cheap permission checks every 2 s, re-renders only on change, and checks the server every ~10 s.

Agent tool accuracy after the security changes (split `schedule_reminder` / `schedule_task`): 11/12 → mail subject fix (compose one when none given).
