# ADR-0006: Confirm every side-effecting agent action by default

## Status
Accepted

## Date
2026-09-27

## Context
The agent reads untrusted content (web pages, emails, files, MCP results, screenshots) and can act (send, create, delete, open, run code). Local models are susceptible to prompt injection.

## Decision
The `Agent` loop — not individual tools — enforces confirmation: any tool with `isWrite == true` shows a confirmation card with a human-readable preview before running. Users may bypass per integration. MCP tools are writes unless the server marks them `readOnlyHint` or their name starts with a read verb. See docs/SECURITY.md for which read tools can still reach the network.

## Alternatives Considered
- **Confirm nothing (fastest)** — unacceptable with injection-prone models.
- **Confirm everything** — makes simple questions tedious.

## Consequences
- One code path to audit. New tools must set `isWrite` correctly; reviewed in code review.
