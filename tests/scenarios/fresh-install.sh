#!/usr/bin/env bash
# Replaces the manual "uninstall, clone fresh, click through" check: boots
# Wpal from a genuinely empty shell.json entry and asserts the one-time
# globalOverride seed lands correctly, with no clicks needed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

run_fresh_install() {
  harness_setup

  local seeded=""
  for _ in $(seq 1 25); do
    seeded=$(harness_shell_json | python3 -c "
import json, sys
try:
    e = json.loads(sys.stdin.read())
    print(e.get('globalOverride', ''))
except Exception:
    print('')
")
    [[ -n "$seeded" ]] && break
    sleep 0.4
  done

  harness_screenshot "fresh-install"

  if [[ -z "$seeded" ]]; then
    echo "FAIL fresh-install: globalOverride never seeded -- see $HYPR_LOG and tests/screenshots/fresh-install.png" >&2
    return 1
  fi
  if [[ "$seeded" != *"1-cosmic.jpg"* ]]; then
    echo "FAIL fresh-install: globalOverride seeded with unexpected path: $seeded" >&2
    return 1
  fi
  echo "PASS fresh-install: globalOverride seeded with $seeded"
}
