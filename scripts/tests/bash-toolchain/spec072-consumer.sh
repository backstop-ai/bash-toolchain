#!/usr/bin/env bash
set -uo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
failures=0
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures+1)); }

TestBashToolchainSPEC072Resolves47ReferencesTo44Functions() {
  local acceptance="$repo_root/scripts/release-acceptance.sh"
  [[ -f "$acceptance" ]] || { fail 'release acceptance harness is absent'; return; }
  local receipt
  receipt=$(mktemp)
  bash "$acceptance" spec072-cardinality >"$receipt" || { fail 'SPEC-072 cardinality acceptance failed'; return; }
  grep -Fxq 'spec072_references=47' "$receipt" || fail 'SPEC-072 reference count is not 47'
  grep -Fxq 'spec072_distinct_functions=44' "$receipt" || fail 'SPEC-072 distinct function count is not 44'
  grep -Fxq 'spec072_absent=0' "$receipt" || fail 'SPEC-072 has absent functions'
  grep -Fxq 'canonical_verifier_invocations=1' "$receipt" || fail 'canonical verifier was not invoked once'
  grep -Fxq 'bash_only_acceptance_profile=pass' "$receipt" || fail 'SPEC-072 fixture was not reduced to the supported Bash-only profile'
  grep -Fxq 'configuration_baseline=pass' "$receipt" || fail 'SPEC-072 fixture did not receipt its installed configuration baseline'
  grep -Fxq 'scoped_assembled_gate=pass' "$receipt" || fail 'SPEC-072 fixture did not pass its explicit-file assembled gate'
}

TestBashToolchainSPEC072TerminalPromotionClearsDiscoveryAndDrift() {
  local acceptance="$repo_root/scripts/release-acceptance.sh"
  [[ -f "$acceptance" ]] || { fail 'release acceptance harness is absent'; return; }
  local receipt
  receipt=$(mktemp)
  bash "$acceptance" spec072-terminal >"$receipt" || { fail 'SPEC-072 terminal acceptance failed'; return; }
  grep -Fxq 'test_verification_absent=0' "$receipt" || fail 'terminal fixture retained absent tests'
  grep -Fxq 'artifact_status_broken_promises=0' "$receipt" || fail 'terminal fixture retained broken promises'
  grep -Fxq 'pinned_core_identity=pass' "$receipt" || fail 'Core identity was not pinned'
  grep -Fxq 'status_only_diff=pass' "$receipt" || fail 'terminal fixture changed more than statuses'
}

TestBashToolchainSPEC072Resolves47ReferencesTo44Functions
TestBashToolchainSPEC072TerminalPromotionClearsDiscoveryAndDrift
if (( failures > 0 )); then exit 1; fi
printf 'PASS: SPEC-072 consumer contract\n'
