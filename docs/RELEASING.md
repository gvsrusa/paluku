# Releasing Paluku

Releases are tag-driven ([ADR-0004](decisions/0004-scripts-first-ci-cd-on-github-actions.md)).

## Cut a release

```bash
# 1. Move finished items under "## [Unreleased]" in CHANGELOG.md (Added / Changed / Fixed / Security).
# 2. Bump, stamp, test, tag, push:
scripts/release.sh 1.2.0 --push
```

`release.yml` then:
1. Checks that the tag `v1.2.0` equals `MARKETING_VERSION` in `project.yml`.
2. Runs lint and unit tests.
3. Builds Release and signs it with the hardened runtime. It notarizes and staples the build if the Apple secrets are present.
4. Publishes `Paluku-1.2.0.dmg` and its `.sha256` to GitHub Releases, with notes taken from the CHANGELOG.

Installed copies of Paluku see the new version via the menu's update check. Versions follow SemVer:
- **MAJOR:** settings or data become incompatible, or a mode is removed.
- **MINOR:** new features.
- **PATCH:** fixes.

## Signing levels

macOS remembers each permission (Accessibility, Microphone, Screen Recording…) together with the app's
*designated requirement*, and apps can't copy or restore permissions themselves. So the signature decides
whether users must re-allow Paluku after every update:

| Build | Designated requirement | Permissions after update | First launch |
|---|---|---|---|
| Ad-hoc (no secrets) | `cdhash H"…"` (this exact binary) | reset every update | Gatekeeper: Open Anyway |
| **Self-signed** (current) | `identifier "com.gvsrusa.Paluku" and certificate root = H"…"` | **kept** | Gatekeeper: Open Anyway |
| Developer ID + notarized | identifier + Developer ID team | kept | opens normally |

The updater pins updates to the running build's requirement: self-signed builds only accept updates signed by
the same certificate, and Developer ID builds only accept updates signed by the same team.

### Self-signed certificate (free)

The certificate lives in `~/.paluku-signing/` on the release machine (`paluku-selfsign.p12` plus `p12-password`) and in
the `release` environment secrets `MACOS_SELFSIGN_P12_BASE64` / `MACOS_SELFSIGN_PASSWORD`. **Back up
`~/.paluku-signing/` somewhere safe.** If you lose it, the next release has a new identity. Installed copies then
refuse the in-app update, so users have to download once by hand, and every permission resets.

To sign locally, import the .p12 into a keychain and run
`PALUKU_SELF_SIGN_IDENTITY="Paluku Self-Signed Code Signing" [PALUKU_SIGN_KEYCHAIN=…] scripts/package.sh`.

### Moving from self-signed to Developer ID

Ship one last self-signed release with `PalukuNextTeamID: "<TEAMID>"` in `project.yml` (Info.plist). That build
accepts updates signed by either the old certificate or your Developer ID team. After that, add the Developer ID
secrets below. The Developer ID secrets take precedence over the self-signed ones.

## One-time: signing & notarization

Without this setup, releases are ad-hoc signed and the release notes tell users how to open them. To ship Gatekeeper-clean builds:

1. Enroll in the Apple Developer Program. Create a **Developer ID Application** certificate and export it with its key as a `.p12`.
2. Create an app-specific password at appleid.apple.com.
3. Run `scripts/signing-secrets.sh DeveloperID.p12`. It creates the `release` environment and prompts for the values below (nothing is echoed). Then add yourself as a required reviewer under Settings › Environments › release.

Or set them by hand in the `release` environment:

| Secret | Value |
|---|---|
| `MACOS_CERT_P12_BASE64` | `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | the .p12 export password |
| `DEVELOPER_ID_APPLICATION` | e.g. `Developer ID Application: Your Name (TEAMID1234)` |
| `APPLE_ID` | your Apple ID email |
| `APPLE_TEAM_ID` | 10-character team id |
| `APPLE_APP_PASSWORD` | the app-specific password |

To sign locally, export the same variables (without the p12 ones; use your login keychain) and run `scripts/package.sh`.

## Homebrew cask

The release workflow renders `Casks/paluku.rb` (version + DMG SHA-256) with `scripts/cask.sh` and pushes it to `main`, so this repo doubles as a tap:

```bash
brew tap gvsrusa/paluku https://github.com/gvsrusa/paluku
brew install --cask paluku
```

If `main` is protected the step only warns; run `scripts/cask.sh X.Y.Z <sha256>` and commit the file yourself. Check it with `brew style Casks/paluku.rb`.

## Public downloads

GitHub Releases on a **private** repository are only downloadable by collaborators, and the in-app update check can't see them. For public distribution, make the repository public or publish releases to a separate public repo. For the latter, set `PalukuUpdateRepo` in `project.yml` accordingly.

## Rollback

Releases are immutable tags. To pull a bad release:
1. Mark it as a pre-release or delete it in GitHub. The update checker ignores pre-releases.
2. Ship a PATCH with the fix, via `scripts/release.sh X.Y.Z+1`.

Users can always reinstall an older DMG from the Releases page.

## Checklist before tagging
- [ ] CI green on `main`
- [ ] `PALUKU_LIVE=1` live tests and `PALUKU_PERF=1` budgets pass locally
- [ ] [manual-qa.md](manual-qa.md) smoke-tested on the Release build (`scripts/install.sh`)
- [ ] CHANGELOG entry written for users, not as a commit dump
