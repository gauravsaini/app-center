#!/usr/bin/env bash
# Repo-local pre-push gate for libreapp-center.
# Standing rule: local CI is the source of truth; GitHub Actions is secondary.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.pub-cache/bin:$HOME/fvm/default/bin:$PATH"
if ! command -v melos >/dev/null 2>&1; then
  echo ".hooks/verify.sh: melos not on PATH - push allowed (install melos to enforce)"
  exit 0
fi
echo ".hooks/verify.sh: melos analyze --fatal-infos"
melos analyze --fatal-infos
