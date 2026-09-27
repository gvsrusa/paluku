# ADR-0003: One `LLM` protocol, two providers (Ollama native, OpenAI-compatible)

## Status
Accepted

## Date
2026-09-27

## Context
Users want to switch models quickly and use other open-model runtimes (LM Studio, llama.cpp `llama-server`, MLX-LM, Jan, vLLM). All of these expose the OpenAI Chat Completions API; Ollama also does (`/v1`), but its native `/api/chat` gives us `keep_alive`, `num_ctx` and pull/delete.

## Decision
Keep the existing `LLM` protocol and add `OpenAICompatibleClient` as a second implementation. `LLMFactory.make(settings)` picks the provider. Model management (pull/delete) is Ollama-only. Tool-call ids required by the OpenAI format are synthesized per assistant message and matched to tool results in order.

## Alternatives Considered
- **Only OpenAI-compatible (use Ollama's /v1)** — would lose pull progress and context-length control.
- **Plugin system for providers** — no third implementation exists; YAGNI.

## Consequences
- Adding a runtime = typing its base URL. Verified live against Ollama `/v1` in `LiveProviderTests`.
- Features that need Ollama (downloads) are hidden for other providers.
