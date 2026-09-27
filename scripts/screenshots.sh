#!/bin/zsh
# Regenerate the website/README screenshots (demo data, dark + light) into site/screenshots.
# Offscreen render: needs no Screen Recording permission and never reads your own history or memory.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh Debug
rm -rf site/screenshots && mkdir -p site/screenshots
build/dd/Build/Products/Debug/Paluku.app/Contents/MacOS/Paluku --snapshot "$PWD/site/screenshots"
ls site/screenshots | wc -l | xargs echo "✓ screenshots:"
