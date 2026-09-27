#!/bin/zsh
# Build Paluku.app. Usage: scripts/build.sh [Debug|Release]  → build/dd/Build/Products/<config>/Paluku.app
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-Debug}
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate -q
mkdir -p build && touch build/.metadata_never_index  # keep dev builds out of Spotlight/Finder app lists
# The app build must use the committed pins (Xcode ignores a local package's Package.resolved).
PINS=Paluku.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p $PINS && cp Packages/PalukuCore/Package.resolved $PINS/Package.resolved
xcodebuild -project Paluku.xcodeproj -scheme Paluku -configuration "$CONFIG" -derivedDataPath build/dd \
  -onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation -skipMacroValidation build 2>&1 | grep -E "error:|warning: .*App/|BUILD (SUCCEEDED|FAILED)" | grep -vE "DVTPlugIn|CoreSimulator"
test -d "build/dd/Build/Products/$CONFIG/Paluku.app"
