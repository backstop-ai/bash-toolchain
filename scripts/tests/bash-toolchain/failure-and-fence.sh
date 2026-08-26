#!/usr/bin/env bash
set -uo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
failures=0
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures+1)); }

TestBashToolchainAbsentOrIncompletePackIsLoud() {
  local acceptance="$repo_root/scripts/release-acceptance.sh" receipt mutation
  [[ -f "$acceptance" ]] || { fail 'release acceptance harness is absent'; return; }
  while read -r mutation; do
    [[ -n "$mutation" ]] || continue
    receipt=$(mktemp)
    bash "$acceptance" incomplete-pack "$mutation" >"$receipt" || { fail "$mutation acceptance harness errored"; continue; }
    if grep -Fxq 'blocking_stage=pack_add' "$receipt"; then
      grep -Fxq 'operation_expected=fail' "$receipt" || fail "$mutation did not expect add failure"
      grep -Fxq 'operation_observed=fail' "$receipt" || fail "$mutation did not fail during real add"
      grep -Fxq 'expected_class=manifest_engine_construction' "$receipt" || fail "$mutation lacked its construction class"
      grep -Fxq 'observed_class=manifest_engine_construction' "$receipt" || fail "$mutation did not observe its construction class"
    else
      grep -Fxq 'gate_expected=fail' "$receipt" || fail "$mutation did not expect gate failure"
      grep -Fxq 'gate_observed=fail' "$receipt" || fail "$mutation did not fail in the assembled gate"
      grep -Eq '^expected_class=(declared_pack_lock_or_install|absent_mandated_tests)$' "$receipt" || fail "$mutation lacked a specific expected class"
      grep -Eq '^observed_class=(declared_pack_lock_or_install|absent_mandated_tests)$' "$receipt" || fail "$mutation lacked a specific observed class"
      grep -Eq '^affected_names=(none|TestBashToolchain)' "$receipt" || fail "$mutation lacked affected-name evidence"
    fi
  done < <(sed -n 's/^[[:space:]]*- //p' "$repo_root/testdata/consumer/mutations/matrix.yml")
}

TestBashToolchainChangeFence() {
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      .gitignore|backstop.yml|backstop.lock|pack.yml|scripts/*|testdata/*|.github/workflows/ci.yml|.github/workflows/tag-integrity.yml) ;;
      *) fail "implementation escaped the Bash pack allowlist: $path" ;;
    esac
  done < <(
    {
      git -C "$repo_root" diff --name-only 39e010d682e55601ed0ef42d6335ee072a46acbb..HEAD
      git -C "$repo_root" diff --name-only
      git -C "$repo_root" ls-files --others --exclude-standard
    } | sort -u
  )
}

TestBashToolchainAbsentOrIncompletePackIsLoud
TestBashToolchainChangeFence
if (( failures > 0 )); then exit 1; fi
printf 'PASS: failure and fence contract\n'
