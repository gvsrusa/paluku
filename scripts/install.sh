#!/bin/zsh
# Build Release and install to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh Release
pkill -x Paluku 2>/dev/null || true
rm -rf /Applications/Paluku.app
cp -R build/dd/Build/Products/Release/Paluku.app /Applications/
open /Applications/Paluku.app
echo "Installed /Applications/Paluku.app"
