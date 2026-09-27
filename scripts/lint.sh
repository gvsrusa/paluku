#!/bin/zsh
# Format check (fails on any swift-format warning). Fix with: swift format format -i -r App Packages/PalukuCore
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(swift format lint -r App Packages/PalukuCore/Sources Packages/PalukuCore/Tests 2>&1 || true)
if [[ -n "$out" ]]; then echo "$out"; echo "✗ swift-format found issues"; exit 1; fi
echo "✓ lint clean"
