# Choosing models

Paluku uses two model roles:

| Role | Needs | Default |
|---|---|---|
| **Dictation & edit** | Fast, follows the "only clean the text" instruction | `gemma4:latest` |
| **Agent** | Tool calling; vision for screen questions | `gemma4:latest` |

Switch either model from the menu bar, the agent panel, or **Models** (downloads and deletions happen there too).

## Recommendations by Mac

| Memory | Dictation | Agent |
|---|---|---|
| 8 GB | `llama3.2:3b` | `qwen3:8b` (no vision) |
| 16 GB | `qwen3:8b` | `gemma4` |
| 32 GB+ | `gemma4` | `gemma4`, or `qwen3:30b-a3b`/`gpt-oss:20b` for harder reasoning |

Measured on an M4 Max 36 GB ([benchmark.md](benchmark.md)):

| Model | Tool-choice accuracy | First token | Polish (30 words) |
|---|---|---|---|
| gemma4 | 12/12 | 0.12 s | 0.40 s |
| qwen3:30b-a3b | 10/12 | slower | — |

## Other runtimes (OpenAI-compatible)

Models › Runtime › *OpenAI-compatible*, then set the base URL:

| Runtime | Base URL |
|---|---|
| LM Studio | `http://127.0.0.1:1234/v1` |
| llama.cpp `llama-server` | `http://127.0.0.1:8080/v1` |
| MLX-LM `mlx_lm.server` | `http://127.0.0.1:8080/v1` |
| Jan | `http://127.0.0.1:1337/v1` |
| vLLM | `http://127.0.0.1:8000/v1` |
| Ollama (OpenAI mode) | `http://127.0.0.1:11434/v1` |

The server must support `tools` for Agent mode. The model list comes from `/v1/models`. Downloading and deleting models is only available with Ollama.

## Speech model

General › Speech model. The default is `openai_whisper-large-v3-v20240930_turbo` (~630 MB, 100 languages). Use `openai_whisper-small` on slower Macs.
