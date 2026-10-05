#!/usr/bin/env bash
# Regression test for the "needs 3 Escapes, should need 2" bug (2026-10-05,
# Panel.qml's escapeGuardUntil): opens li on workspace 1, presses Escape
# exactly twice with no pause in between (the real-world fast-double-tap
# case), and asserts the panel is closed. If it takes a 3rd press, the
# 400ms guard is eating the second real keypress.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

run_escape_cascade() {
  harness_setup
  sleep 1  # let quickshell finish booting before IPC/keys land

  harness_ipc open
  sleep 0.3
  harness_key_down   # cursorWs 0 -> 1, see Panel.qml moveCursor
  sleep 0.1
  harness_enter       # activateCursor() -> openWorkspace(1): li now open
  sleep 0.3

  harness_escape       # closes li, arms the 400ms strip-focus guard
  harness_escape       # should close the panel -- no pause, as a human double-tap

  sleep 0.2
  local open_after_two
  open_after_two=$(harness_ipc isOpen)
  harness_screenshot "escape-cascade-after-two"

  if [[ "$open_after_two" == "false" ]]; then
    echo "PASS escape-cascade: panel closed after exactly 2 presses"
    return 0
  fi

  harness_escape
  sleep 0.2
  local open_after_three
  open_after_three=$(harness_ipc isOpen)
  if [[ "$open_after_three" == "false" ]]; then
    echo "FAIL escape-cascade: took 3 presses to close (guard swallowed the 2nd) -- see tests/screenshots/escape-cascade-after-two.png" >&2
    return 1
  fi

  echo "FAIL escape-cascade: panel still open after 3 presses -- unexpected, investigate" >&2
  return 1
}
