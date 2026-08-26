#!/usr/bin/env bash
set -euo pipefail

count_file=${DOCUMENTATION_INVOCATION_COUNT_FILE:?DOCUMENTATION_INVOCATION_COUNT_FILE is required}
count=0
[[ ! -f "$count_file" ]] || read -r count < "$count_file"
printf '%s\n' "$((count + 1))" > "$count_file"
printf 'documentation-verifier stdout\n'
