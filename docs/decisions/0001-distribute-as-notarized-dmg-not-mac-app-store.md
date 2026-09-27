# ADR-0001: Distribute as a notarized DMG, not through the Mac App Store

## Status
Accepted

## Date
2026-09-27

## Context
Paluku must type into any app, react to a held `fn`/Right ⌥ key system-wide, drive Mail/Messages/Notes via AppleScript, and launch helper processes (MCP servers via `npx`/`uvx`, `claude`/`codex`). The Mac App Store requires the App Sandbox, and App Review guideline 2.4.5 restricts Accessibility use by sandboxed apps. Inside the sandbox:
- Synthetic keystrokes via Accessibility (paste into the frontmost app) are not permitted.
- Active `CGEventTap`s that can consume events are not available; `fn` detection needs one.
- Apple Events to arbitrary apps need temporary-exception entitlements that App Review rejects.
- Executing binaries outside the bundle (`npx`, `uvx`, `mdfind`, `sqlite3`) is blocked.

Other voice and automation tools for the Mac ship as direct downloads for the same reasons.

## Decision
Ship outside the App Store: Developer ID–signed, hardened-runtime, notarized and stapled DMG, published on GitHub Releases by CI (ADR-0004). The app checks GitHub Releases for newer versions and installs them in place on request (`Updater`: checksum, signature and team check, atomic swap, relaunch).

## Alternatives Considered
- **Mac App Store, sandboxed "lite" build** — dictation would have to copy to clipboard instead of typing; no agent actions on Apple apps; no MCP servers. Rejected: loses the core value; two builds to maintain.
- **Sparkle auto-updates** — delta updates and an EdDSA-signed appcast, but adds a dependency and key management. Deferred: the built-in updater reuses the release DMG plus Developer ID team pinning. Revisit if updates become large or need to work without a Developer ID.
- **Homebrew cask** — added in v1.2 as a second channel over the same DMG (`Casks/paluku.rb`, updated by the release workflow); not a replacement for it.

## Consequences
- Users install by dragging to /Applications; Gatekeeper is satisfied only when the release was signed with a Developer ID and notarized (secrets in CI).
- Unsigned builds (no Apple credentials) still work but need one-time approval (System Settings › Privacy & Security › Open Anyway, or `xattr -dr com.apple.quarantine`) — documented in README.
- No App Store review delays; we own update delivery.
