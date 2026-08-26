#!/usr/bin/env bash
set -euo pipefail

payload=$(mktemp)
cleanup() {
  rm -f "$payload"
}
trap cleanup EXIT HUP INT TERM
cat > "$payload"

status_line=$(grep '^BACKSTOP_BASH_TEST_EXIT_STATUS=[0-9][0-9]*$' "$payload" || true)
if [[ -z "$status_line" ]] || [[ $(printf '%s\n' "$status_line" | wc -l | tr -d ' ') != 1 ]]; then
  printf 'bash-toolchain: malformed producer output: exactly one exit-status record is required\n' >&2
  exit 65
fi
status=${status_line#*=}
if [[ "$status" == 0 ]]; then
  printf '{"version":"2.1.0","runs":[{"results":[]}]}\n'
  exit 0
fi

message=$(grep -v '^BACKSTOP_BASH_TEST_EXIT_STATUS=' "$payload" | sed '/^[[:space:]]*$/d' | tail -n 1)
if [[ -z "$message" ]]; then
  message="canonical Bash verifier exited $status"
fi
python3 - "$message" <<'PY'
import json,sys
print(json.dumps({
    "version": "2.1.0",
    "runs": [{"results": [{
        "ruleId": "bash-test",
        "level": "error",
        "message": {"text": sys.argv[1]},
    }]}],
}, separators=(",", ":")))
PY
