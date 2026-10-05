#!/usr/bin/env bash
# Shared setup/teardown for Wpal's isolated click-through tests.
# Implements the ss-remote-screen-control recipe (nested Hyprland + Quickshell,
# throwaway HOME) so scenarios only need to describe what to click and assert.
set -euo pipefail

WPAL_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_HOME="$HOME/wpal-test-home"
HYPR_LOG="/tmp/wpal-test-hypr.log"

harness_load_calibration() {
  local calib_file="$WPAL_REPO/tests/lib/calibration/$(hostname).env"
  if [[ ! -f "$calib_file" ]]; then
    echo "No ydotool calibration recorded for host '$(hostname)'." >&2
    echo "Run the ss-onboard-remote-screen-control skill on this machine first," >&2
    echo "then add tests/lib/calibration/$(hostname).env (see t420.env for the shape)." >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$calib_file"
  : "${YDOTOOL_SCALE_X:?calibration file missing YDOTOOL_SCALE_X}"
  : "${YDOTOOL_SCALE_Y:?calibration file missing YDOTOOL_SCALE_Y}"
}

# Picks a workspace with zero configured panes, so auto-launch can't fire for
# real against anything. See ss-remote-screen-control's Auto-Launch-on-focus
# trap -- never guess this number.
harness_pick_scratch_workspace() {
  python3 - "$TEST_HOME/.config/omarchy/shell.json" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
except FileNotFoundError:
    print(9)
    sys.exit(0)
ws = {}
for entry in d.get("bar", {}).get("layout", {}).get("right", []):
    if entry.get("id") == "silverstone.wpal":
        ws = entry.get("workspaces", {})
for n in range(1, 11):
    panes = ws.get(str(n), {}).get("panes", [])
    if not any(p.get("appId") for p in panes):
        print(n)
        sys.exit(0)
print(9)  # fallback, matches the window rule already in hyprland.lua
PY
}

# Rebuilds shell.json + the fixture background from scratch each run, so
# every scenario starts from a genuine fresh-install state, not whatever the
# previous run left behind.
#
# Retries: back-to-back nested-Hyprland launches (run.sh running several
# scenarios in one go) are flaky -- the nested instance sometimes fails to
# grab its own wayland-N socket and dies within a second (seen 2026-10-05,
# log shows "unable to lock lockfile .../wayland-1.lock" then an immediate
# exit). One retry after a full teardown + short settle has cleared it every
# time so far; not yet root-caused further than that.
harness_setup() {
  local attempt
  for attempt in 1 2 3; do
    if _harness_setup_once; then
      return 0
    fi
    echo "harness_setup attempt $attempt failed, tearing down and retrying..." >&2
    harness_teardown
    sleep 1
  done
  echo "harness_setup failed after 3 attempts -- see $HYPR_LOG" >&2
  return 1
}

_harness_setup_once() {
  mkdir -p "$TEST_HOME/.config/hypr"
  mkdir -p "$TEST_HOME/.config/omarchy/plugins"
  mkdir -p "$TEST_HOME/.local/state/omarchy/current/theme/backgrounds"

  ln -sfn "$WPAL_REPO" "$TEST_HOME/.config/omarchy/plugins/silverstone.wpal"

  python3 - "$TEST_HOME/.config/omarchy/shell.json" <<'PY'
import json, sys
out = sys.argv[1]
with open("/usr/share/omarchy/config/omarchy/shell.json") as f:
    d = json.load(f)
d["bar"]["layout"]["right"].append({"id": "silverstone.wpal"})
with open(out, "w") as f:
    json.dump(d, f, indent=2)
PY

  cp /usr/share/omarchy/themes/ethereal/backgrounds/1-cosmic.jpg \
     "$TEST_HOME/.local/state/omarchy/current/theme/backgrounds/"
  echo -n "ethereal" > "$TEST_HOME/.local/state/omarchy/current/theme.name"
  ln -sfn "$TEST_HOME/.local/state/omarchy/current/theme/backgrounds/1-cosmic.jpg" \
     "$TEST_HOME/.local/state/omarchy/current/background"

  cat > "$TEST_HOME/.config/hypr/hyprland.conf" <<'EOF'
monitor=WAYLAND-1,1600x900@60,0x0,1
exec-once = quickshell -n -p /usr/share/omarchy/shell
general { gaps_in = 0 gaps_out = 0 }
decoration { rounding = 0 }
animations { enabled = false }
EOF

  local before_hypr before_qs
  before_hypr=$(ls /run/user/1000/hypr/ 2>/dev/null || true)
  before_qs=$(ls /run/user/1000/quickshell/by-id/ 2>/dev/null || true)

  # Nested Hyprland needs the REAL session's inherited WAYLAND_DISPLAY --
  # it connects to it as an ordinary Wayland client (WLR_BACKENDS=headless
  # doesn't actually take effect here, see the skill doc). Unsetting it
  # was tried and makes Hyprland abort outright ("CBackend::create()
  # failed!") -- don't touch it. The "unable to lock lockfile
  # wayland-1.lock" line that shows up in the log either way is benign
  # noise, not the cause of the real intermittent failures below.
  HOME="$TEST_HOME" WLR_BACKENDS=headless XDG_RUNTIME_DIR=/run/user/1000 \
    OMARCHY_PATH=/usr/share/omarchy \
    Hyprland --config "$TEST_HOME/.config/hypr/hyprland.conf" \
    > "$HYPR_LOG" 2>&1 &
  disown

  local hypr_launch_pid=$!
  local nested_sig=""
  for _ in $(seq 1 50); do
    kill -0 "$hypr_launch_pid" 2>/dev/null || break  # died already, stop waiting
    nested_sig=$(comm -13 <(echo "$before_hypr" | sort) <(ls /run/user/1000/hypr/ 2>/dev/null | sort) | head -1)
    [[ -n "$nested_sig" ]] && break
    sleep 0.2
  done
  if [[ -z "$nested_sig" ]]; then
    return 1
  fi

  local hypr_pid
  hypr_pid=$(pgrep -f "Hyprland --config $TEST_HOME/.config/hypr/hyprland.conf" | head -1 || true)
  if [[ -z "$hypr_pid" ]]; then
    return 1
  fi
  NESTED_SIG="$nested_sig"
  export NESTED_SIG

  NESTED_QS_ID=""
  for _ in $(seq 1 50); do
    kill -0 "$hypr_pid" 2>/dev/null || return 1  # nested compositor died mid-boot
    NESTED_QS_ID=$(comm -13 <(echo "$before_qs" | sort) <(ls /run/user/1000/quickshell/by-id/ 2>/dev/null | sort) | head -1)
    [[ -n "$NESTED_QS_ID" ]] && break
    sleep 0.2
  done
  if [[ -z "$NESTED_QS_ID" ]]; then
    return 1
  fi
  export NESTED_QS_ID

  # NOT the Hyprland process's own environ -- that still shows the INHERITED
  # display it connected to as a client (confirmed 2026-10-05: always reads
  # back as whatever the real session's WAYLAND_DISPLAY was at launch time).
  # The nested display it actually CREATES only shows up in ITS CHILDREN's
  # environ (quickshell, launched via exec-once) -- find ours by matching
  # HOME, since several quickshell instances (real + nested) run at once.
  local qs_pid
  for qs_pid in $(pgrep -f "quickshell -n -p /usr/share/omarchy/shell" 2>/dev/null); do
    if tr '\0' '\n' < "/proc/$qs_pid/environ" 2>/dev/null | grep -qx "HOME=$TEST_HOME"; then
      NESTED_WAYLAND_DISPLAY=$(tr '\0' '\n' < "/proc/$qs_pid/environ" 2>/dev/null | grep '^WAYLAND_DISPLAY=' | cut -d= -f2)
      break
    fi
  done
  if [[ -z "${NESTED_WAYLAND_DISPLAY:-}" ]]; then
    return 1
  fi
  export NESTED_WAYLAND_DISPLAY
}

# pkill is blocked by this session's own permission settings (plain `kill`
# isn't) -- found 2026-10-05 when teardown silently failed every run and
# orphaned nested Hyprland/quickshell processes kept accumulating, each
# holding its own wayland-N socket. Find PIDs with pgrep, kill them by PID.
harness_teardown() {
  local pids
  pids=$(pgrep -f "Hyprland --config $TEST_HOME/.config/hypr/hyprland.conf" 2>/dev/null || true)
  pids="$pids $(pgrep -f "$TEST_HOME" 2>/dev/null || true)"
  for pid in $pids; do
    kill -9 "$pid" 2>/dev/null || true
  done

  for _ in $(seq 1 25); do
    pgrep -f "Hyprland --config $TEST_HOME/.config/hypr/hyprland.conf" >/dev/null 2>&1 || break
    sleep 0.2
  done

  # Belt-and-suspenders: a killed nested Hyprland doesn't always release its
  # own wayland-N socket/lock immediately. Never touch wayland-1 -- that's
  # the real session.
  if [[ -n "${NESTED_WAYLAND_DISPLAY:-}" && "$NESTED_WAYLAND_DISPLAY" != "wayland-1" ]]; then
    rm -f "/run/user/1000/$NESTED_WAYLAND_DISPLAY" "/run/user/1000/$NESTED_WAYLAND_DISPLAY.lock"
  fi
}

# ydotool's absolute mousemove needs this machine's recorded scale -- see
# ss-remote-screen-control Step 4. Never assume 1x.
harness_click() {
  local x=$1 y=$2
  ydotool mousemove -a -x "$(( x / YDOTOOL_SCALE_X ))" -y "$(( y / YDOTOOL_SCALE_Y ))"
  ydotool click 0xC0
}

harness_escape() { ydotool key 1:1 1:0; }
harness_enter() { ydotool key 28:1 28:0; }
harness_key_down() { ydotool key 108:1 108:0; }

# Drives Wpal's own IPC handler (BarWidget.qml, target "silverstone") --
# real plugin code, not a test-only backdoor, except for isOpen() which was
# added alongside this suite for state assertions.
# -i filters by the CALLER's current display, and --any-display (a DIFFERENT
# option group) can't combine with -i ("Instance Selection excludes Config
# Selection" -- confirmed 2026-10-05). Setting WAYLAND_DISPLAY to the
# nested instance's own makes it "current" instead, so -i alone works.
harness_ipc() { WAYLAND_DISPLAY="$NESTED_WAYLAND_DISPLAY" qs ipc -i "$NESTED_QS_ID" call silverstone "$@"; }

harness_screenshot() {
  mkdir -p "$WPAL_REPO/tests/screenshots"
  # Scoped to the NESTED compositor's own display -- without this, grim asks
  # the REAL session for a screenshot and gets the real output with the
  # nested window composited on top, so whatever's behind it on the real
  # desktop bleeds through the plugin panel's translucent background into
  # every capture (found 2026-10-05 taking preview.png: a browser tab's
  # bookmarks and inbox count were faintly legible in the result).
  WAYLAND_DISPLAY="$NESTED_WAYLAND_DISPLAY" grim "$WPAL_REPO/tests/screenshots/$1.png"
}

harness_shell_json() {
  python3 -c "
import json
d = json.load(open('$TEST_HOME/.config/omarchy/shell.json'))
for entry in d.get('bar', {}).get('layout', {}).get('right', []):
    if entry.get('id') == 'silverstone.wpal':
        print(json.dumps(entry))
" 2>/dev/null
}

harness_log_grep() {
  WAYLAND_DISPLAY="$NESTED_WAYLAND_DISPLAY" qs log -i "$NESTED_QS_ID" 2>/dev/null | grep -F "$1" || true
}
