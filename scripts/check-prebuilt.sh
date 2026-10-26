#!/bin/bash
# Checks that a packaged prebuilt app runs and loads its models, as the ./mmm launcher runs it.
# Used by publish-prebuilt.sh. Usage: scripts/check-prebuilt.sh mmm-<commit>.tar.gz
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$(mktemp -d)"
trap 'rm -rf "$app"' EXIT
tar -xzf "$1" -C "$app"
# Permissions on a CI runner don't matter here, only that the models check out and load.
report="$(MMM_MODELS_DIR="$root/Models" "$app/mmm" doctor --full || true)"
echo "$report"
if grep -q "✗ Model" <<<"$report" || ! grep -q "✓ Models load" <<<"$report"; then
  exit 1
fi
