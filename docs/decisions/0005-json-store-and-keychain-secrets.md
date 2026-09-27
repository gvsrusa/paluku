# ADR-0005: JSON files for app data, Keychain for secrets

## Status
Accepted

## Date
2026-09-27

## Context
Data is per-user and small (settings, history, dictionary, memory, schedule). MCP servers and OpenAI-compatible providers may need API keys/tokens.

## Decision
Store data as JSON under `~/Library/Application Support/Paluku/`. Store secrets in the login Keychain (service `com.gvsrusa.Paluku`); `settings.json` keeps a placeholder, resolved only when a server starts.

## Alternatives Considered
- **SQLite/GRDB** — FTS and scale we don't need yet; a dependency. Upgrade path if history exceeds ~50k entries.
- **Secrets in settings.json** — readable by any process running as the user and easy to leak in backups/bug reports.

## Consequences
- Whole-file rewrites on save (fine at this scale).
- Diagnostics and settings can be shared without exposing tokens.
