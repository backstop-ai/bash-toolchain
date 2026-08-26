#!/usr/bin/env bash
set -euo pipefail

fixture_suite_test() {
  [[ "${BASH_SOURCE[0]}" == "$0" ]] || {
    printf 'suite was sourced\n' >&2
    return 1
  }
  printf 'suite-process:%s\n' "$$"
}

fixture_suite_test
