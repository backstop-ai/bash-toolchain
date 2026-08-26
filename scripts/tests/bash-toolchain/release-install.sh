#!/usr/bin/env bash
set -uo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

TestBashToolchainImmutableReleaseInstallAcceptance() {
  local acceptance="$repo_root/scripts/release-acceptance.sh" receipt
  [[ -f "$acceptance" ]] || { printf 'FAIL: release acceptance harness is absent\n' >&2; return 1; }
  receipt=$(mktemp)
  bash "$acceptance" remote-release >"$receipt" || return 1
  grep -Fxq 'remote_install=pass' "$receipt"
  grep -Fxq 'candidate_remote_identity=equal' "$receipt"
  grep -Fxq 'post_tag_acceptance=pass' "$receipt"
}

TestBashToolchainImmutableReleaseInstallAcceptance || exit 1
printf 'PASS: immutable release install contract\n'
