#!/usr/bin/env bash
set -euo pipefail

count_file=${INVOCATION_COUNT_FILE:?INVOCATION_COUNT_FILE is required}
count=0
[[ ! -f "$count_file" ]] || read -r count < "$count_file"
printf '%s\n' "$((count + 1))" > "$count_file"
fixture_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
printf 'canonical-verifier stdout\n'
printf 'canonical-verifier stderr\n' >&2
bash "$fixture_root/scripts/tests/suite.sh"
