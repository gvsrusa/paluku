# Changelog

All notable changes to Paluku are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **Dictation anywhere:** hold fn, speak, release. Filler words and false starts are removed, self-corrections applied, and the text is typed where your cursor is. Double-tap for hands-free; Esc cancels.
- **Edit by voice:** select text, hold fn and say what to change; the selection is rewritten in place.
- **Agent:** hold Right ⌥ and ask. Calendar, Reminders, Finder, Notes, Mail, Messages, Music/Spotify, Maps, web search, weather, scheduled tasks, Claude Code/Codex, and any MCP server (Gmail, Google Calendar, Drive, Notion…). Anything that sends, creates, moves or deletes asks first.
- **Local models:** speech-to-text with WhisperKit on the Neural Engine; language models via Ollama or any OpenAI-compatible server (LM Studio, llama.cpp, MLX-LM, Jan, vLLM). Separate agent and dictation models, switchable from the menu bar.
- **Security:** prompt-injection taint tracking, egress confirmation, home-folder file allowlist, link allowlist, SSRF guard, Keychain-stored secrets. See docs/SECURITY.md.
- **One-click updates** with checksum and code-signature verification; signed releases keep macOS permissions across updates.
- DMG with drag-to-Applications layout, Homebrew cask, website with a screenshot tour.
