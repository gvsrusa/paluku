# ADR-0002: Local-first open models (WhisperKit + Ollama), gemma4 by default

## Status
Accepted

## Date
2026-09-27

## Context
Requirement: everything free and open source, audio never leaves the Mac. Needs: fast multilingual speech-to-text, a model that cleans dictation reliably, and an agent model with tool calling (and ideally vision for screen questions).

## Decision
- Speech-to-text: **WhisperKit** (MIT) running Whisper large-v3 turbo in CoreML on the Neural Engine.
- LLM runtime: **Ollama** by default, one model for both roles: **gemma4** (tools + vision).
- Model choice made by benchmark (`docs/benchmark.md`): gemma4 12/12 tool-selection accuracy vs qwen3:30b-a3b 10/12 and much slower on this hardware.

## Alternatives Considered
- **whisper.cpp** — equally good accuracy; WhisperKit integrates natively in Swift with CoreML/ANE acceleration and no C bridging.
- **Apple SFSpeechRecognizer** — no custom vocabulary prompt, weaker on names/jargon, server-side for some languages.
- **MLX-LM embedded** — fastest on Apple Silicon but adds model management UI we'd have to build; supported instead through the OpenAI-compatible provider (ADR-0003).

## Consequences
- First launch downloads ~630 MB (Whisper) and the user must install Ollama + pull a model.
- Quality/speed scales with the user's hardware; the Models tab lets them pick smaller models.
