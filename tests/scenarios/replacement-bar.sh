#!/usr/bin/env bash
# Regression test for the SilverAsus blank-wallpaper-preview bug: a bar.id
# pointing at a replacement bar (`omarchy plugin clone omarchy.bar --edit`,
# same as SilverAsus's real chad.bar) gets a service-less shell facade from
# the host, so serviceFor() always returns null there. Before the
# hostService/effectiveService fallback in BarWidget.qml, that meant
# Panel.qml's root.service never resolved, globalOverride never seeded, and
# Default mode showed nothing. Same assertion as fresh-install, but under
# WPAL_TEST_REPLACEMENT_BAR=1 (see harness.sh) so it actually exercises the
# private Service.qml fallback instead of the host-managed singleton.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

run_replacement_bar() {
  WPAL_TEST_REPLACEMENT_BAR=1 harness_setup

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

  harness_screenshot "replacement-bar"

  if [[ -z "$seeded" ]]; then
    echo "FAIL replacement-bar: globalOverride never seeded under a replacement bar -- see $HYPR_LOG and tests/screenshots/replacement-bar.png" >&2
    return 1
  fi
  if [[ "$seeded" != *"1-cosmic.jpg"* ]]; then
    echo "FAIL replacement-bar: globalOverride seeded with unexpected path: $seeded" >&2
    return 1
  fi

  local log_hit
  log_hit=$(harness_log_grep "TypeError")
  if [[ -n "$log_hit" ]]; then
    echo "FAIL replacement-bar: TypeError in live log: $log_hit" >&2
    return 1
  fi

  echo "PASS replacement-bar: globalOverride seeded with $seeded under a replacement bar (private Service.qml fallback confirmed live)"
}
