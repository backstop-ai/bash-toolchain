#!/usr/bin/env bash
set -uo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

TestBashToolchainMixedGoBashDiscoveryDoesNotRegressGo() {
  local acceptance="$repo_root/scripts/release-acceptance.sh" receipt
  [[ -f "$acceptance" ]] || { printf 'FAIL: release acceptance harness is absent\n' >&2; return 1; }
  receipt=$(mktemp)
  bash "$acceptance" mixed-toolchain >"$receipt" || return 1
  grep -Fxq 'go_discovery_unchanged=pass' "$receipt"
  grep -Fxq 'go_verdict_unchanged=pass' "$receipt"
  grep -Fxq 'bash_discovery=pass' "$receipt"
  grep -Fxq 'bash_verifier_invocations=1' "$receipt"
}

TestBashToolchainMixedGoBashDiscoveryDoesNotRegressGo || exit 1
printf 'PASS: mixed toolchain contract\n'
