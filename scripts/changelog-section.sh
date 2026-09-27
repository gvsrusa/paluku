#!/bin/zsh
# Prints the CHANGELOG.md section for a version (used as GitHub Release notes). Usage: scripts/changelog-section.sh 1.2.0
set -euo pipefail
awk -v v="$1" '$0 ~ "^## \\[" v "\\]" {f=1; next} f && /^## \[/ {exit} f {print}' "$(dirname "$0")/../CHANGELOG.md"
