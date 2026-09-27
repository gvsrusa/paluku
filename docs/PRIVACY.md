# Privacy

- **Audio** stays in memory while you hold the key and is discarded after transcription. It is never written to disk and never uploaded.
- **Speech-to-text** runs on your Mac (WhisperKit/CoreML).
- **Language model** runs on your Mac (Ollama, or the local server you configure). If you point Paluku at a remote server, text and screenshots go there. That is your choice.
- **Screen context:** Agent mode captures the window you're in for that one request, only while Screen Recording is allowed and "Use screen context" is on. Screenshots are kept in memory for the conversation and are never saved.
- **Stored locally:** history, dictionary, memory and schedule, as JSON in `~/Library/Application Support/Paluku/`. Delete that folder to erase everything. History can be cleared from the History tab.
- **Secrets:** API keys and MCP tokens are stored in the macOS Keychain.
- **Network access** happens only when:
  - you use web search, weather or maps (DuckDuckGo, Open-Meteo, Apple Maps)
  - you connect cloud integrations (MCP servers)
  - the app checks GitHub for updates (can be turned off)
  - models are downloaded (Hugging Face for Whisper, Ollama's registry)
- **Telemetry:** none is sent anywhere. Local diagnostics (event names, durations, error types, never content) exist only in memory and in the macOS unified log. **Copy Diagnostics** puts them on your clipboard when you choose to share them.
