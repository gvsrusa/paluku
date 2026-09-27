# Contributing

1. **Spec first** for anything non-trivial: add or adjust the requirement in `SPEC.md`, and write an ADR in `docs/decisions/` for decisions that are expensive to reverse.
2. **Small vertical slices**, one logical change per commit, using [Conventional Commits](https://www.conventionalcommits.org) (`feat:`, `fix:`, `refactor:`, `docs:`, `ci:`, `chore:`). Keep refactors separate from features.
3. **Tests first** for logic in `Packages/PalukuCore`: write a failing test, make it pass. Security-relevant behavior gets an abuse-case test in `SecurityTests.swift`.
4. **New agent tools:**
   - Set `isWrite`, `egress`, `untrusted` and `allowBypass` honestly (see docs/SECURITY.md).
   - Never interpolate arguments into AppleScript, shell or SQL.
   - Add the tool to the benchmark if it's commonly used.
5. **Before pushing:** `scripts/lint.sh && scripts/test.sh && scripts/build.sh Debug`. For model or latency changes, also run the `PALUKU_LIVE`/`PALUKU_PERF` suites.
6. **User-visible changes** get a line in `CHANGELOG.md` under `[Unreleased]`.
7. **UI changes:** attach `Paluku --snapshot` PNGs. Every icon-only button needs an `accessibilityLabel`.

Code style is enforced by `.swift-format`. Keep logic in PalukuCore and views thin, and don't add dependencies without discussion.
