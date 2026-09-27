# ADR-0004: Scripts-first CI/CD on GitHub Actions, tag-driven releases

## Status
Accepted

## Date
2026-09-27

## Context
The repository lives on GitHub. We need quality gates on every change and a reproducible release that produces a signed, notarized DMG. macOS builds need macOS runners with a recent Xcode.

## Decision
- All logic in `scripts/` (`lint`, `test`, `build`, `package`, `release`, `changelog-section`); workflows only call them, so a laptop run == a CI run.
- `ci.yml` on push/PR to `main`: swift-format lint → unit tests → Debug app build → UI snapshot artifacts.
- `release.yml` on tag `vX.Y.Z`: verifies the tag equals `MARKETING_VERSION`, re-runs gates, signs/notarizes if secrets exist, publishes DMG + SHA-256 with notes from `CHANGELOG.md`.
- `scripts/release.sh X.Y.Z` bumps version + build number, stamps the changelog, runs gates, tags.
- Dependabot for SwiftPM and Actions.

## Alternatives Considered
- **GitLab CI** — no free hosted macOS runners for this project; the remote is GitHub.
- **Fastlane** — Ruby toolchain for what ~60 lines of shell do.
- **Xcode Cloud** — tied to App Store Connect; doesn't fit a DMG-only distribution (ADR-0001).

## Consequences
- Signing needs repository secrets (see docs/RELEASING.md); without them releases are ad-hoc signed and labeled.
- Live model tests (Ollama/Whisper) do not run in CI (no GPU models on runners); they run locally with `PALUKU_LIVE=1`.
