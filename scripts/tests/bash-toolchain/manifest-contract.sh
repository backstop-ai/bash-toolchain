#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_contains() {
  local needle=$1
  local file=$2
  grep -Fq -- "$needle" "$file" || fail "$file does not contain: $needle"
}

TestBashToolchainManifestUsesExistingCoreSurfaces() {
  local manifest="$repo_root/pack.yml"
  [[ -f "$manifest" ]] || { fail "pack.yml is absent"; return; }
  assert_contains 'name: backstop-ai/bash-toolchain' "$manifest"
  assert_contains 'classification:' "$manifest"
  assert_contains 'test_name_patterns:' "$manifest"
  assert_contains 'gate_type: test' "$manifest"
  assert_contains 'scope_kind: project-wide' "$manifest"
  assert_contains 'crash_guard: true' "$manifest"
  if grep -Eq '^[[:space:]]*(source|coverage|substantiveness):' "$manifest"; then
    fail 'manifest declares an out-of-scope source, coverage, or substantiveness surface'
  fi
}

TestBashToolchainClassificationIsNarrowAndComplete() {
  local manifest="$repo_root/pack.yml"
  [[ -f "$manifest" ]] || { fail "pack.yml is absent"; return; }
  assert_contains '"scripts/tests/**/*.sh"' "$manifest"
  assert_contains '"scripts/verify-public-product-model.sh"' "$manifest"
  local expectation path accepted
  while IFS='|' read -r expectation path; do
    accepted=false
    if [[ "$path" == scripts/tests/*.sh || "$path" == scripts/tests/**/*.sh || "$path" == scripts/verify-public-product-model.sh ]]; then
      accepted=true
    fi
    [[ "$accepted" == "$([[ "$expectation" == accept ]] && printf true || printf false)" ]] || fail "classification mismatch for $path"
  done < "$repo_root/testdata/classification/path-matrix.txt"
}

TestBashToolchainNamePatternsDeclarationMatrix() {
  local manifest="$repo_root/pack.yml"
  [[ -f "$manifest" ]] || { fail "pack.yml is absent"; return; }
  assert_contains '([A-Za-z_][A-Za-z0-9_]*)' "$manifest"
  python3 - "$manifest" "$repo_root/testdata/name-patterns/positive.txt" "$repo_root/testdata/name-patterns/negative.txt" <<'PY' || {
import pathlib,re,sys,yaml
patterns=yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())['test_name_patterns']
if len(patterns) != 9: raise SystemExit(f'expected nine declared name patterns, got {len(patterns)}')
def compile_go_compatible(pattern):
 pattern=(pattern.replace('[[:space:]]', r'\s').replace('[[:blank:]]', r'[ \t]')
                 .replace('[:space:]', r'\s').replace('[:blank:]', r' \t'))
 compiled=re.compile(pattern)
 if compiled.groups != 1: raise SystemExit(f'pattern must expose only capture group 1: {pattern}')
 return compiled
compiled=[compile_go_compatible(pattern) for pattern in patterns]
for row in pathlib.Path(sys.argv[2]).read_text().splitlines():
 expected,line=row.split('|',1)
 actual=[match.group(1) for pattern in compiled for match in pattern.finditer(line)]
 if actual != expected.split(','): raise SystemExit(f'expected {expected}, got {actual or ["none"]}: {line}')
for line in pathlib.Path(sys.argv[3]).read_text().splitlines():
 expected=[]
 if '|' in line:
  expected_text,line=line.split('|',1)
  expected=expected_text.split(',') if expected_text else []
 actual=[match.group(1) for pattern in compiled for match in pattern.finditer(line)]
 if actual != expected: raise SystemExit(f'false declaration capture: expected {expected}, got {actual}: {line}')
PY
    fail 'actual pack.yml declaration patterns failed their matrix'
  }
}

TestBashToolchainManifestUsesExistingCoreSurfaces
TestBashToolchainClassificationIsNarrowAndComplete
TestBashToolchainNamePatternsDeclarationMatrix

if (( failures > 0 )); then
  exit 1
fi
printf 'PASS: manifest contract\n'
