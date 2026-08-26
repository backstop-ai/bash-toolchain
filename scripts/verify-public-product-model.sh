#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
status=0
while IFS= read -r suite; do
  bash "$suite" || status=1
done < <(find "$repo_root/scripts/tests" -type f -name '*.sh' | sort)
exit "$status"
