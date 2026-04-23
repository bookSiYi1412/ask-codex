#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"

bash -n "$repo_dir/scripts/ask_codex.sh"
bash -n "$repo_dir/scripts/codex_broker.sh"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$repo_dir/scripts/ask_codex.sh" "$repo_dir/scripts/codex_broker.sh" "$repo_dir/scripts/check.sh"
fi

echo "checks passed"
