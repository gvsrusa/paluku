# Security model

Paluku can act on your Mac, which makes the agent a target for **prompt injection**: instructions hidden in a web page, email, file or tool result. Defenses are enforced in code, not in the prompt ([ADR-0006](decisions/0006-agent-confirmation-policy.md)).

## Confirmation policy (`Agent.needsConfirmation`)

| Tool flag | Meaning | Rule |
|---|---|---|
| `isWrite` | Sends, creates, changes or deletes | Asks first, unless you chose "Skip confirmation" for that integration **and** the tool allows it |
| `allowBypass: false` | Sending mail or messages, writing or trashing files, scheduled agent tasks, coding tasks | **Always** asks |
| `untrusted` | Output can contain third-party text (web, mail, notes, files, messages, MCP) | Marks the conversation *tainted* |
| `egress` | Can move data off the Mac or to another app or URL (web, URLs, maps, MCP, send) | After taint, **always** asks, with a warning on the card |

Scheduled agent tasks start tainted. After taint, model output that merely *looks* like a JSON tool call is never executed.

## Hard limits (independent of confirmation) — allowlists, not denylists

Three adversarial review cycles showed that denylists keep leaking (aliases, new file types, `..` through symlinks), so the file rules are allowlists:

- **Reads and writes** only touch *your own files*: inside the home folder, outside `~/Library` and any hidden (dot) path. Nothing else, not system config, `/Volumes`, or other users. Paths containing `..` are refused. Checks are case-insensitive (APFS) and resolve symlinks, including a symlinked parent of a file that doesn't exist yet.
- **Opening files:**
  - Only known document types open: PDF, images, audio and video, plain text/Markdown/CSV, rich text, Word, Pages/Numbers/Keynote, Excel, PowerPoint.
  - Scripts, HTML/XML/SVG, archives, disk images, apps, installers, certificates, profiles, link files and Finder aliases never open. Unknown types don't either.
  - Folders open in Finder. `files_open` always uses the default app.
  - Result-card links pass the same check off the main thread.
- **Web:**
  - `open_url` and `web_fetch` reach only public http(s) hosts. Loopback, private, link-local, CGNAT, NAT64 and v4-mapped addresses are blocked after the system resolver parses the host, compared by bytes.
  - Refused: ambiguous numeric forms (`0177.0.0.1`), percent-encoded or non-ASCII hosts, unresolvable hosts.
  - Redirects are re-checked. Browsers are allowlisted by name.
- **Coding agents:** run only inside a git repo in your home folder (not hidden folders, ~/Library or ~/Downloads), with `--` before the task.
- **Links in answers:** Markdown links the model writes go through the same allowlist as result cards (public web, Maps, Calendar, harmless files in your home folder). Custom app schemes are never opened.
- **Files:** listing, searching, opening and revealing use the same home-folder allowlist as reading.
- **Memories:** a fact saved while outside content was in the conversation is marked (orange shield in Memory & Schedule). Until you click **Trust**, every conversation starts as containing outside content, so nothing can quietly send data out on its say-so.
- **Scheduled tasks:** their cards are labelled and need a click; a spoken "yes" never approves them.
- **Remote MCP servers:** https only (plain http only on this Mac). The Google and Notion presets are pinned to reviewed versions.
- **AppleScript:** every value is passed as `argv`, never interpolated. The music player name is allowlisted.
- **SQL (Messages):** only digits or validated email addresses reach the query.
- **MCP:** tools are treated as writes unless the name is clearly a read or you listed them. A server's own read-only labels are trusted only if you mark that server trusted. Any enabled server taints the conversation, since its tool descriptions are text it controls.
- **Updates:** “Install and restart” only downloads this repository's release assets from github.com. The DMG must match the release's SHA-256. The new app must have a valid code signature (strict, nested code), the same bundle ID, and the version the release names. When the running app is Developer ID–signed, the update must be signed by the same team. Self-signed releases (the default until a Developer ID is set up) require the update to match the running app's designated requirement: same identifier and same certificate. Ad-hoc builds can only check that the signature is valid, so for them the trust root is the GitHub release itself. The app is swapped in one rename. If Paluku runs from the DMG or a translocated copy, it opens the release page instead.
- **Messages:** a contact name must match exactly one contact; the card shows the resolved number, which is the one used.
- **MCP config changes** (e.g. turning trust off) restart the server so old permissions don't linger. Settings saved by pre-v2 builds have preset trust reset.

## Accepted trade-offs

- **DNS rebinding (TOCTOU).** A hostname could resolve publicly at check time and privately when URLSession connects. Mitigations: redirects are re-checked, fetches are read-only GETs, and anything that *sends* data needs confirmation once tainted. The full fix is connecting to the pinned IP.
- **Media controls** (play/pause/volume) run without confirmation even when tainted. The worst case is an annoyance.
- **Build-plugin validation** is skipped in `scripts/build.sh` so headless CI can build; exact pins (`-onlyUsePackageVersionsFromResolvedFile`) and building before the signing key is imported limit what a dependency could do.
- **`messages_recent`** reads the Messages database by design, through a dedicated tool that requires Full Disk Access. `files_read` can never read it.

## Supply chain & CI

- GitHub Actions are pinned to commit SHAs, and Dependabot proposes bumps.
- The release job checks out without a persisted token and builds the app *before* the signing key exists on the runner. The key is imported non-extractable (`-x`) into an ephemeral keychain whose partition list allows only `codesign`, and the keychain is deleted afterwards. Signing secrets live in the protected `release` environment.
- Dependencies are WhisperKit (MIT) and the MCP Swift SDK (MIT/Apache-2). Both `swift test` and the app build use the committed `Packages/PalukuCore/Package.resolved` exactly.
- Every build (signed or ad-hoc) uses the hardened runtime, so `DYLD_INSERT_LIBRARIES` can't borrow Paluku's privacy permissions.

## Reporting

Please open a private security advisory on the GitHub repository rather than a public issue.
