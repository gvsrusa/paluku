#!/bin/zsh
# Cut a release: bump version, stamp CHANGELOG, commit, tag. Pushing the tag triggers .github/workflows/release.yml.
# Usage: scripts/release.sh 1.2.0 [--push]
set -euo pipefail
cd "$(dirname "$0")/.."
V=${1:?usage: scripts/release.sh X.Y.Z [--push]}
[[ $V =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z"; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "working tree not clean"; exit 1; }
git rev-parse "v$V" >/dev/null 2>&1 && { echo "tag v$V exists"; exit 1; }
grep -q "## \[Unreleased\]" CHANGELOG.md || { echo "CHANGELOG.md needs an [Unreleased] section"; exit 1; }

BUILD=$(( $(grep -E 'CURRENT_PROJECT_VERSION:' project.yml | grep -oE '[0-9]+') + 1 ))
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"$V\"/; s/CURRENT_PROJECT_VERSION: \"[^\"]+\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
sed -i '' "s/## \[Unreleased\]/## [Unreleased]\n\n## [$V] - $(date +%Y-%m-%d)/" CHANGELOG.md

scripts/lint.sh && scripts/test.sh
git commit -am "chore(release): v$V" -q
git tag -a "v$V" -m "Paluku $V"
echo "✓ tagged v$V (build $BUILD)"
if [[ ${2:-} == --push ]]; then git push origin HEAD "v$V"; else echo "push with: git push origin HEAD v$V"; fi
