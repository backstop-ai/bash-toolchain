#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_valid_sarif_count() {
  local file=$1 expected=$2
  python3 - "$file" "$expected" <<'PY' || return 1
import json,sys
data=json.load(open(sys.argv[1], encoding='utf-8'))
assert data['version']=='2.1.0'
assert len(data['runs'])==1
assert len(data['runs'][0]['results'])==int(sys.argv[2])
PY
}

TestBashToolchainCanonicalVerifierSingleExecutionAndSARIF() {
  local producer="$repo_root/scripts/test-produce.sh"
  local converter="$repo_root/scripts/test-to-sarif.sh"
  [[ -f "$producer" ]] || { fail 'test producer is absent'; return; }
  [[ -f "$converter" ]] || { fail 'SARIF converter is absent'; return; }
  local work count output sarif status
  work=$(mktemp -d)
  count="$work/count"
  output="$work/output"
  sarif="$work/result.sarif"
  (
    cd "$repo_root/testdata/execution/pass"
    INVOCATION_COUNT_FILE="$count" bash "$producer" scripts/verify-public-product-model.sh
  ) >"$output" 2>&1
  status=$?
  [[ $status -eq 0 ]] || fail "passing producer exited $status"
  [[ $(cat "$count" 2>/dev/null) == 1 ]] || fail 'canonical verifier was not invoked exactly once'
  grep -q 'canonical-verifier stdout' "$output" || fail 'stdout diagnostic was not preserved'
  grep -q 'canonical-verifier stderr' "$output" || fail 'stderr diagnostic was not preserved'
  grep -q 'suite-process:' "$output" || fail 'self-executing suite did not run as a process'
  bash "$converter" <"$output" >"$sarif" || fail 'converter rejected passing producer output'
  assert_valid_sarif_count "$sarif" 0 || fail 'passing command did not yield empty valid SARIF'
}

TestBashToolchainExecutionFailureMatrixIsLoud() {
  local producer="$repo_root/scripts/test-produce.sh"
  local converter="$repo_root/scripts/test-to-sarif.sh"
  local stage="$repo_root/scripts/stage-local-candidate.sh"
  [[ -f "$producer" ]] || { fail 'test producer is absent'; return; }
  [[ -f "$converter" ]] || { fail 'SARIF converter is absent'; return; }
  [[ -f "$stage" ]] || { fail 'safe local-candidate staging is absent'; return; }
  local work output sarif status
  work=$(mktemp -d)
  output="$work/output"
  sarif="$work/result.sarif"
  (
    cd "$repo_root/testdata/execution/fail"
    bash "$producer" scripts/verify-public-product-model.sh
  ) >"$output" 2>&1
  status=$?
  [[ $status -eq 7 ]] || fail "failing verifier status was $status instead of 7"
  bash "$converter" <"$output" >"$sarif" || fail 'converter rejected an observed verifier failure'
  assert_valid_sarif_count "$sarif" 1 || fail 'failing verifier did not yield one SARIF result'
  grep -q 'deliberate failure' "$sarif" || fail 'failure diagnostic was not preserved in SARIF'

  : > "$output"
  if bash "$converter" <"$output" >"$sarif" 2>/dev/null; then
    fail 'converter accepted malformed empty input'
  fi
  printf 'not producer output\n' > "$output"
  if bash "$converter" <"$output" >"$sarif" 2>/dev/null; then
    fail 'converter accepted input without a status record'
  fi

  local empty_path="$work/empty-path"
  mkdir "$empty_path"
  if PATH="$empty_path" /usr/bin/env bash "$producer" scripts/verify-public-product-model.sh >"$output" 2>&1; then
    fail 'producer accepted an environment without Bash'
  fi

  if (cd "$work" && bash "$producer" scripts/verify-public-product-model.sh >"$output" 2>&1); then
    fail 'producer accepted a missing canonical verifier'
  fi

  if [[ ${BACKSTOP_EXECUTION_MATRIX_CHILD:-0} != 1 ]]; then
    local harness="$repo_root/scripts/create-disposable-consumer.sh"
    local staged=${BACKSTOP_EXECUTION_MATRIX_STAGE:-}
    local commit=${BACKSTOP_EXECUTION_MATRIX_COMMIT:-}
    local tree=${BACKSTOP_EXECUTION_MATRIX_TREE:-}
    local digest=${BACKSTOP_EXECUTION_MATRIX_DIGEST:-}
    local function_file=${BACKSTOP_EXECUTION_MATRIX_FUNCTION_FILE:-}
    [[ -x "$harness" && -d "$staged" && -f "$function_file" ]] || {
      fail 'assembled failure-matrix harness inputs are absent'
      return
    }
    local mutation receipt expected_class expected_rule expected_diagnostic
    for mutation in missing-bash missing-verifier failing-verifier producer-failure converter-failure malformed-converter-output; do
      receipt="$work/$mutation.receipt"
      BACKSTOP_EXECUTION_MATRIX_CHILD=1 BACKSTOP_BIN="${BACKSTOP_BIN:-backstop}" \
        bash "$harness" execution-contract "$mutation" "$commit" "$tree" "$digest" "$function_file" "$staged" >"$receipt" 2>&1 || {
          cat "$receipt" >&2
          fail "$mutation assembled consumer harness errored"
          continue
        }
      grep -Fxq "mutation=$mutation" "$receipt" || fail "$mutation receipt named the wrong mutation"
      grep -Fxq 'pack_lock_verification=pass' "$receipt" || fail "$mutation did not pass lock verification before engine dispatch"
      grep -Fxq 'gate_expected=fail' "$receipt" || fail "$mutation did not expect a blocking assembled gate"
      grep -Fxq 'gate_observed=fail' "$receipt" || fail "$mutation did not observe a blocking assembled gate"
      grep -Fq 'expected_diagnostic=' "$receipt" || fail "$mutation lacked its mode-specific diagnostic receipt"
      grep -Fxq 'observed_step=pack_engines' "$receipt" || fail "$mutation was not derived from the structured pack_engines step"
      case "$mutation" in
        missing-bash)
          expected_class=tool_absence; expected_rule=pack_engines
          expected_diagnostic='required tool "bash" not found on PATH'
          ;;
        missing-verifier)
          expected_class=canonical_verifier_absent; expected_rule=backstop-ai/bash-toolchain/bash-test
          expected_diagnostic='bash: scripts/verify-public-product-model.sh: No such file or directory'
          ;;
        failing-verifier)
          expected_class=canonical_verifier_nonzero; expected_rule=backstop-ai/bash-toolchain/bash-test
          expected_diagnostic='public-product-model suite: deliberate failure'
          ;;
        producer-failure)
          expected_class=producer_crash; expected_rule=backstop-ai/bash-toolchain/bash-test
          expected_diagnostic='deterministic producer crash'
          ;;
        converter-failure)
          expected_class=converter_crash; expected_rule=pack_engines
          expected_diagnostic='convert step (scripts/test-to-sarif.sh) failed: exit status 72'
          ;;
        malformed-converter-output)
          expected_class=malformed_converter_output; expected_rule=pack_engines
          expected_diagnostic='convert/parse to SARIF failed: parsing SARIF output: invalid character'
          ;;
      esac
      grep -Fxq "observed_rule=$expected_rule" "$receipt" || fail "$mutation carried the wrong structured rule"
      grep '^observed_diagnostic=' "$receipt" | grep -Fq "$expected_diagnostic" || fail "$mutation lacked its exact structured diagnostic"
      grep -Fxq "expected_class=$expected_class" "$receipt" || fail "$mutation expected the wrong diagnostic class"
      grep -Fxq "observed_class=$expected_class" "$receipt" || fail "$mutation observed the wrong diagnostic class"
      grep -Fxq 'consumer_cleanup=pass' "$receipt" || fail "$mutation did not prove cleanup"
      case "$mutation" in
        producer-failure|converter-failure|malformed-converter-output)
          grep -Fxq 'negative_first_install=true' "$receipt" || fail "$mutation did not use a fresh negative first install"
          grep -Eq '^negative_digest=[0-9a-f]{64}$' "$receipt" || fail "$mutation lacked a Backstop-generated negative digest"
          ;;
      esac
    done
  fi
}

TestBashToolchainCanonicalVerifierSingleExecutionAndSARIF
TestBashToolchainExecutionFailureMatrixIsLoud

if (( failures > 0 )); then
  exit 1
fi
printf 'PASS: execution contract\n'
