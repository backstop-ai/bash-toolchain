#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
if (( $# < 4 )) || [[ "$3" != -- ]]; then
  printf 'usage: %s <candidate-commit> <candidate-tree> -- <callback> [args...]\n' "$0" >&2
  exit 64
fi
candidate_commit=$1
candidate_tree=$2
shift 3
callback=("$@")
if (( ${#callback[@]} == 0 )); then
  printf 'bash-toolchain: callback argv is empty\n' >&2
  exit 64
fi
resolved_commit=$(git -C "$repo_root" rev-parse "${candidate_commit}^{commit}") || exit 65
resolved_tree=$(git -C "$repo_root" rev-parse "${resolved_commit}^{tree}") || exit 65
if [[ "$resolved_commit" != "$candidate_commit" || "$resolved_tree" != "$candidate_tree" ]]; then
  printf 'bash-toolchain: candidate identity mismatch\n' >&2
  exit 65
fi

stage=$(mktemp -d /tmp/backstop-bash-toolchain.XXXXXX)
cleanup() {
  rm -rf -- "$stage"
}
trap cleanup EXIT HUP INT TERM

case "$stage" in
  "$repo_root"|"$repo_root"/*)
    printf 'bash-toolchain: staging directory is inside the source repository\n' >&2
    exit 65
    ;;
esac

git -C "$repo_root" archive --format=tar "$resolved_commit" | tar -xf - -C "$stage"
if [[ -e "$stage/.git" ]] || [[ -e "$stage/.backstop" ]]; then
  printf 'bash-toolchain: staged candidate contains repository/runtime metadata\n' >&2
  exit 65
fi

source_tree=$resolved_tree
check_repo=$(mktemp -d /tmp/backstop-bash-toolchain-tree.XXXXXX)
cleanup_tree() {
  rm -rf -- "$check_repo"
}
trap 'cleanup_tree; cleanup' EXIT HUP INT TERM
git -C "$check_repo" init -q
git -C "$check_repo" config core.autocrlf false
git -C "$check_repo" --work-tree="$stage" add -A
staged_tree=$(git -C "$check_repo" --work-tree="$stage" write-tree)
if [[ "$source_tree" != "$staged_tree" ]]; then
  printf 'bash-toolchain: staged tree %s differs from source tree %s\n' "$staged_tree" "$source_tree" >&2
  exit 65
fi

printf 'stage_path=%s\n' "$stage"
"${callback[@]}" "$stage"
status=$?
cleanup_tree
cleanup
trap - EXIT HUP INT TERM
printf 'stage_cleanup=pass\n'
exit "$status"
