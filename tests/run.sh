#!/usr/bin/env bash
# Entry point for Wpal's click-through test suite.
# Usage: tests/run.sh [scenario-name|all]
# No args = all. Requires ss-onboard-remote-screen-control to have been run
# on this machine (see lib/calibration/README.md).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source lib/harness.sh
harness_load_calibration

SCENARIOS=(fresh-install escape-cascade replacement-bar)
TARGET="${1:-all}"

run_one() {
  local name=$1
  source "scenarios/$name.sh"
  echo "--- running $name ---"
  local fn="run_${name//-/_}"
  trap harness_teardown EXIT
  if "$fn"; then
    trap - EXIT
    harness_teardown
    return 0
  else
    trap - EXIT
    harness_teardown
    return 1
  fi
}

failures=0
if [[ "$TARGET" == "all" ]]; then
  for s in "${SCENARIOS[@]}"; do
    run_one "$s" || failures=$((failures + 1))
  done
else
  run_one "$TARGET" || failures=1
fi

echo "---"
if [[ $failures -eq 0 ]]; then
  echo "all scenarios passed"
else
  echo "$failures scenario(s) failed"
fi
exit $failures
