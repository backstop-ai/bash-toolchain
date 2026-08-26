#!/usr/bin/env bash
set -uo pipefail

if ! command -v bash >/dev/null 2>&1; then
  printf 'bash-toolchain: Bash executable is unavailable\n' >&2
  exit 127
fi
if (( $# != 1 )); then
  printf 'bash-toolchain: exactly one optional verifier path is required\n' >&2
  exit 64
fi
if [[ ! -f "$1" ]]; then
  printf 'bash-toolchain: optional verifier absent: %s\n' "$1"
  printf 'BACKSTOP_BASH_TEST_EXIT_STATUS=0\n'
  exit 0
fi

bash "$1" 2>&1
status=$?
printf 'BACKSTOP_BASH_TEST_EXIT_STATUS=%s\n' "$status"
exit "$status"
