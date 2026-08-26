#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
stage="$repo_root/scripts/stage-local-candidate.sh"
consumer="$repo_root/scripts/create-disposable-consumer.sh"
candidate_commit=${BACKSTOP_CANDIDATE_COMMIT:-}
candidate_tree=${BACKSTOP_CANDIDATE_TREE:-}
candidate_digest=${BACKSTOP_CANDIDATE_DIGEST:-}
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

run_mode() {
  local mode=$1 mutation=$2 functions=$3 receipt=$4
  BACKSTOP_BIN=${BACKSTOP_BIN:-/workspace/scratch/1d6aa3e9c498/backstop-core/bin/backstop} \
    bash "$stage" "$candidate_commit" "$candidate_tree" -- \
    bash "$consumer" "$mode" "$mutation" "$candidate_commit" "$candidate_tree" \
    "$candidate_digest" "$functions" >"$receipt"
}

TestDisposableConsumerHarnessContract() {
  [[ -f "$consumer" ]] || { fail 'disposable consumer harness is absent'; return; }
  [[ "$candidate_commit" =~ ^[0-9a-f]{40}$ && "$candidate_tree" =~ ^[0-9a-f]{40}$ && "$candidate_digest" =~ ^[0-9a-f]{64}$ ]] || {
    fail 'candidate identity must be recomputed from the reviewed committed bytes'
    return
  }
  local work mode functions receipt consumer_path stage_path
  work=$(mktemp -d)
  for mode in manifest-contract execution-contract; do
    functions="$repo_root/testdata/consumer/harness/${mode%%-contract}-functions.txt"
    receipt="$work/$mode.receipt"
    run_mode "$mode" none "$functions" "$receipt" || { fail "$mode consumer failed"; continue; }
    for required in artifact_validation=pass pack_engines=pass test_verification=pass candidate_identity=pass external_sandbox_opt_out=true consumer_cleanup=pass stage_cleanup=pass; do
      grep -Fxq "$required" "$receipt" || fail "$mode receipt lacks $required"
    done
    consumer_path=$(sed -n 's/^consumer_path=//p' "$receipt" | head -n1)
    stage_path=$(sed -n 's/^stage_path=//p' "$receipt" | head -n1)
    [[ -n "$consumer_path" && "$consumer_path" != "$repo_root"/* && ! -e "$consumer_path" ]] || fail "$mode consumer was not cleaned outside repository"
    [[ -n "$stage_path" && "$stage_path" != "$repo_root"/* && ! -e "$stage_path" ]] || fail "$mode stage was not cleaned outside repository"
  done

  if run_mode unknown none "$repo_root/testdata/consumer/harness/manifest-functions.txt" "$work/unknown" 2>/dev/null; then
    fail 'unknown mode was accepted'
  fi
  if run_mode manifest-contract none "$repo_root/testdata/consumer/harness/invalid-functions.txt" "$work/invalid" 2>/dev/null; then
    fail 'malformed or duplicate function data was accepted'
  fi
  local mutation expected_class
  for mutation in missing-bash missing-verifier failing-verifier producer-failure converter-failure malformed-converter-output; do
    receipt="$work/$mutation.receipt"
    run_mode execution-contract "$mutation" "$repo_root/testdata/consumer/harness/execution-functions.txt" "$receipt" || { fail "$mutation harness failed"; continue; }
    grep -Fxq "mutation=$mutation" "$receipt" || fail "$mutation receipt lacks mutation identity"
    grep -Fxq 'gate_expected=fail' "$receipt" || fail "$mutation receipt lacks expected failure"
    grep -Fxq 'gate_observed=fail' "$receipt" || fail "$mutation receipt lacks observed failure"
    grep -Fxq 'pack_lock_verification=pass' "$receipt" || fail "$mutation engine evidence lacks preceding lock pass"
    case "$mutation" in
      missing-bash) expected_class=tool_absence ;;
      missing-verifier) expected_class=canonical_verifier_absent ;;
      failing-verifier) expected_class=canonical_verifier_nonzero ;;
      producer-failure) expected_class=producer_crash ;;
      converter-failure) expected_class=converter_crash ;;
      malformed-converter-output) expected_class=malformed_converter_output ;;
    esac
    grep -Fxq "expected_class=$expected_class" "$receipt" || fail "$mutation expected the wrong diagnostic class"
    grep -Fxq "observed_class=$expected_class" "$receipt" || fail "$mutation observed the wrong diagnostic class"
    grep -Fxq 'consumer_cleanup=pass' "$receipt" || fail "$mutation consumer cleanup absent"
    grep -Fxq 'stage_cleanup=pass' "$receipt" || fail "$mutation stage cleanup absent"
    if [[ "$mutation" == *converter* || "$mutation" == producer-failure ]]; then
      grep -Eq '^negative_digest=[0-9a-f]{64}$' "$receipt" || fail "$mutation negative digest absent"
      if grep -Fxq "negative_digest=$candidate_digest" "$receipt"; then fail "$mutation reused accepted digest"; fi
      grep -Fxq 'negative_first_install=true' "$receipt" || fail "$mutation was not a fresh first install"
    fi
  done
  if run_mode execution-contract 'producer-failure;touch PWNED' "$repo_root/testdata/consumer/harness/execution-functions.txt" "$work/metachar" 2>/dev/null; then
    fail 'mutation metacharacters were accepted'
  fi
  if grep -Eq '(^|[^[:alnum:]_])(eval|sh[[:space:]]+-c)([^[:alnum:]_]|$)' "$stage" "$consumer"; then
    fail 'harness contains command-string execution'
  fi
}

TestDisposableConsumerHarnessContract
if (( failures > 0 )); then exit 1; fi
printf 'PASS: disposable consumer harness contract\n'
