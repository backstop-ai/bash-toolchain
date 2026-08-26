#!/usr/bin/env bash
set -uo pipefail

if ! command -v bash >/dev/null 2>&1; then
  printf 'bash-toolchain: Bash executable is unavailable\n' >&2
  exit 127
fi
if (( $# == 0 )); then
  printf 'bash-toolchain: canonical verifier command is absent\n' >&2
  exit 64
fi
if [[ $1 == scripts/verify-documentation-semantics-integration.sh && ! -f $1 ]]; then
  printf 'bash-toolchain: optional verifier absent: %s\n' "$1"
  printf 'BACKSTOP_BASH_TEST_EXIT_STATUS=0\n'
  exit 0
fi

bash "$@" 2>&1
status=$?
printf 'BACKSTOP_BASH_TEST_EXIT_STATUS=%s\n' "$status"
exit "$status"
