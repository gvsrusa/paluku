#!/bin/zsh
# One-time: store Developer ID signing + notarization secrets in the GitHub "release" environment.
# Usage: scripts/signing-secrets.sh path/to/DeveloperID.p12
# Prompts for the rest (nothing is echoed or written to disk). Needs `gh auth login` with repo admin rights.
set -euo pipefail
cd "$(dirname "$0")/.."
P12=${1:?usage: scripts/signing-secrets.sh DeveloperID.p12}
[[ -f $P12 ]] || { echo "no such file: $P12"; exit 1; }
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
gh api -X PUT "repos/$REPO/environments/release" >/dev/null  # create if missing

read -rs "PASS?.p12 export password: "; echo
IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
read -r "IDENTITY_IN?Signing identity [${IDENTITY:-Developer ID Application: Name (TEAMID)}]: "
IDENTITY=${IDENTITY_IN:-$IDENTITY}
read -r "APPLE_ID?Apple ID email: "
read -r "TEAM?Team ID (10 chars): "
read -rs "APP_PW?App-specific password (appleid.apple.com): "; echo

set_secret() { gh secret set "$1" --env release --repo "$REPO" --body "$2"; }
set_secret MACOS_CERT_P12_BASE64 "$(base64 -i "$P12")"
set_secret MACOS_CERT_PASSWORD "$PASS"
set_secret DEVELOPER_ID_APPLICATION "$IDENTITY"
set_secret APPLE_ID "$APPLE_ID"
set_secret APPLE_TEAM_ID "$TEAM"
set_secret APPLE_APP_PASSWORD "$APP_PW"
echo "✓ release environment configured. Next tag builds a signed + notarized DMG (re-run an old one: gh workflow run Release -f tag=vX.Y.Z)."
