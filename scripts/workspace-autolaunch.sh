#!/bin/bash
# Auto-launch panes for one workspace, in a fixed layout keyed by pane count.
# Invoked by Service.qml (chad.silverstone) whenever a configured workspace
# is focused while empty. Generalizes the old omarchy-workspace-6-autolaunch
# script: this one takes an arbitrary pane list (app/webapp/terminal/command)
# instead of two hardcoded foot+ssh commands, and identifies new windows by
# diffing client addresses instead of a hardcoded --app-id, so it works for
# pane types that can't be given a custom window class.
#
# Errors from the launched programs (and the "no window appeared" notice
# below) are left on stderr on purpose -- Service.qml logs them to the
# journal rather than hiding a failing launch.
#
# Args: $1 = workspace id, $2 = base64-encoded JSON array of
#            {"type":"app|webapp|terminal|command","value":"...","args":"..."},
#            1-4 entries. args is optional extra shell args tacked onto an
#            app/command launch (see Model.js classifyPane).
#       $3 = layout index for this pane count (optional, default 0 = the
#            original arrangement). Keep in step with Model.js launchLayouts.
#       $4 = which pane (0-based, in the same order as $2) opens FULL SCREEN
#            once everything is tiled; -1 or absent for none. The others stay
#            in their own tiles behind it (0: "they will open in thier
#            assigned tile slot, or full screen for one, with the others open
#            behind").
set -u

ws="${1:-}"
panes_b64="${2:-}"
layout="${3:-0}"
fs_index="${4:--1}"
[[ $layout =~ ^[0-9]+$ ]] || layout=0
[[ $fs_index =~ ^-?[0-9]+$ ]] || fs_index=-1
[[ -n $ws && -n $panes_b64 ]] || exit 0

# How long to wait for ONE pane's window to map, in 0.1s ticks. This was 50
# (5s), which is simply not enough on a T420: chromium, OBS and vlc all took
# longer, the wait timed out, and -- because a timeout used to abort the whole
# run -- every pane after the slow one never launched at all (0: "theyre
# opening on top of each other or not at all"). A timeout no longer aborts
# anything (see the plan loop below), so a generous budget costs nothing but
# patience on a genuinely broken launcher.
wait_ticks="${WPAL_WAIT_TICKS:-200}"
[[ $wait_ticks =~ ^[0-9]+$ ]] || wait_ticks=200

# Re-check emptiness right before acting -- closes the race between the
# reactive trigger in Service.qml and this script actually running.
[[ $(hyprctl clients -j 2>/dev/null | jq --argjson w "$ws" '[.[]|select(.workspace.id==$w)]|length') == 0 ]] || exit 0

panes_json=$(base64 -d <<<"$panes_b64" 2>/dev/null) || exit 0
count=$(jq 'length' <<<"$panes_json" 2>/dev/null) || exit 0
[[ $count =~ ^[0-9]+$ ]] || exit 0
(( count > 0 )) || exit 0
(( count > 4 )) && count=4

pane_type() { jq -r ".[$1].type // \"\"" <<<"$panes_json"; }
pane_value() { jq -r ".[$1].value // \"\"" <<<"$panes_json"; }
pane_args() { jq -r ".[$1].args // \"\"" <<<"$panes_json"; }

snapshot() { hyprctl clients -j 2>/dev/null | jq -c --argjson w "$ws" '[.[]|select(.workspace.id==$w)|.address]'; }

# Still looking at the workspace we are furnishing? Windows are spawned onto
# whatever is FOCUSED, so if the user walks away mid-run the rest of the panes
# would land on top of whatever they walked to. Nothing is more important than
# not touching another workspace (the hard rule), so the run stops instead.
on_target() { [[ $(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id') == "$ws" ]]; }

# Opens the user's default terminal (whatever xdg-terminal-exec resolves),
# optionally running a command. Called directly instead of through
# omarchy-launch-terminal: that wrapper inspects the focused terminal's cwd
# via pgrep, which prints a usage error when the workspace is empty (as it
# always is here) -- and an empty workspace resolves to $HOME regardless.
launch_terminal() {
  setsid -f uwsm-app -- xdg-terminal-exec --dir="$HOME" "$@" </dev/null >/dev/null
}

# The .desktop file for an app id, searched the same places gtk-launch looks
# (nested dirs included, for flatpak-style ids).
desktop_file() {
  local id=$1 dir hit
  local -a dirs=("${XDG_DATA_HOME:-$HOME/.local/share}/applications")
  local -a xdirs
  IFS=: read -ra xdirs <<<"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  for dir in "${xdirs[@]}"; do dirs+=("$dir/applications"); done
  for dir in "${dirs[@]}"; do
    [[ -f "$dir/$id.desktop" ]] && { printf '%s' "$dir/$id.desktop"; return 0; }
  done
  for dir in "${dirs[@]}"; do
    [[ -d $dir ]] || continue
    hit=$(find "$dir" -maxdepth 3 -name "$id.desktop" -print -quit 2>/dev/null)
    [[ -n $hit ]] && { printf '%s' "$hit"; return 0; }
  done
  return 1
}

# That file's Exec line, field codes (%f %U ...) stripped, so real arguments
# can be appended to it.
desktop_exec() {
  awk '/^\[Desktop Entry\]/{g=1;next} /^\[/{g=0} g && /^Exec=/{sub(/^Exec=/,""); print; exit}' "$1" \
    | sed -E 's/%[a-zA-Z]//g; s/[[:space:]]+$//'
}

# A webapp .desktop's own URL, pulled out with a plain regex instead of
# word-splitting its Exec line -- the Exec value may quote the URL
# ("https://...") to protect it, and quotes inside an already-expanded shell
# variable are just literal characters, not re-parsed as quoting. Re-using
# desktop_exec's unquoted-word-splitting trick (below) on a quoted Exec line
# would pass the literal quote characters through as part of the URL.
webapp_url_for() {
  desktop_exec "$1" | grep -oE 'https?://[^"'"'"' ]+' | head -1
}

# Chromium is a singleton per profile: `--app=URL` sent to an ALREADY-RUNNING
# chromium (e.g. the real browser pane on WS1) gets forwarded to it instead of
# opening its own app-mode window, which is slow/unreliable once that session
# has a lot of tabs/extensions loaded -- this is what "the webapp opens in
# Chrome instead" turned out to be (0, WS0/WS10 SilverStone Camera, verified
# by testing: forwarded opens eventually land as a real app window, but only
# after the main session's singleton gets around to it). A dedicated
# `--user-data-dir` per (app, workspace) sidesteps the singleton entirely --
# always its own process, always its own window -- and keys it by workspace
# so the same webapp configured on two different workspaces gets two
# independent instances, while relaunching it on the SAME workspace reuses
# the same one (0: "a different instance of the same program on any WS, or
# the same"). Each webapp .desktop also carries its own non-workspace-keyed
# `--user-data-dir` as a baseline, so a manual launch from the app menu
# (outside this script) gets the same isolation; the one built here, keyed by
# workspace, simply overrides it (Chromium takes the last `--user-data-dir`).
webapp_profile_dir() {
  local id=$1 slug
  slug=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '-' | tr -s '-')
  slug=${slug#-}; slug=${slug%-}
  printf '%s/.local/share/omarchy-webapps/%s-ws%s' "$HOME" "$slug" "$ws"
}

# An app pane's args are SHELL ARGS for the app ("claude", "ssh T420",
# "--incognito"), and `gtk-launch app.desktop <args>` cannot deliver them:
# GLib treats every trailing word as a FILE, resolves it against the cwd and
# launches the app once per word. `foot` + `claude` came out as
# `foot /home/chad/.../claude`, which foot refuses -- so no window ever
# appeared, the wait timed out, and the rest of the panes were abandoned.
# Verified on this machine with a logging .desktop file, not guessed.
#
# gtk-launch is also wrong for a SECOND pane of a DBusActivatable app that's
# already running (e.g. org.gnome.Nautilus, two Files panes on one
# workspace): it does a bare Activate() D-Bus call with no way to ask for a
# new window, so the app just raises its existing one and the second pane's
# window never appears. Running the desktop entry's own Exec line instead
# (nautilus --new-window, baked into the .desktop by GNOME itself) goes
# through GApplication's normal argv-forwarding to the running instance,
# which DOES honor --new-window. Same fix shape as the Chromium webapp
# singleton problem (see webapp_profile_dir above), different app family.
# So: always run the desktop entry's own Exec line, with the pane's args (if
# any) appended -- gtk-launch is only the fallback when no Exec could be
# parsed at all.
launch_app() {
  local id=$1 args=$2 file exec_line url profile_dir
  file=$(desktop_file "$id") && exec_line=$(desktop_exec "$file")
  if [[ -n ${exec_line:-} && $exec_line == *omarchy-launch-webapp* ]] \
    && url=$(webapp_url_for "$file") && [[ -n $url ]]; then
    profile_dir=$(webapp_profile_dir "$id")
    mkdir -p "$profile_dir"
    setsid -f uwsm-app -- omarchy-launch-webapp "$url" --user-data-dir="$profile_dir" $args </dev/null >/dev/null
    return
  fi
  if [[ -n ${exec_line:-} ]]; then
    # Unquoted on purpose, both of them: the Exec line and the user's args are
    # meant as words (this is the user's own local config, not external input).
    setsid -f uwsm-app -- $exec_line $args </dev/null >/dev/null
  else
    echo "workspace-autolaunch: no Exec for $id.desktop, launching without args" >&2
    setsid -f uwsm-app -- gtk-launch "${id}.desktop" </dev/null >/dev/null
  fi
}

launch_pane() {
  local idx=$1 type value args
  type=$(pane_type "$idx")
  value=$(pane_value "$idx")
  args=$(pane_args "$idx")
  case "$type" in
  app)      launch_app "$value" "$args" ;;
  webapp)   setsid -f omarchy-launch-webapp "$value" </dev/null >/dev/null ;;
  terminal) launch_terminal ;;
  # `command` needs its own terminal window -- bash alone has nothing to
  # paint a window with. `exec bash -l` afterward keeps the window open if
  # the command exits/fails (e.g. an SSH connection dropping), matching the
  # original ws6 script's "quitting drops to a bash prompt" behavior.
  command)  launch_terminal bash -lc "$value $args; exec bash -l" ;;
  *) return 1 ;;
  esac
}

# Poll (bounded) for a new client address on this workspace, relative to a
# prior snapshot.
wait_new() {
  local before="$1" i after diff
  for ((i = 0; i < wait_ticks; i++)); do
    after=$(snapshot)
    diff=$(jq -rn --argjson a "$before" --argjson b "$after" '($b - $a)[0] // empty')
    if [[ -n $diff ]]; then printf '%s' "$diff"; return 0; fi
    sleep 0.1
  done
  echo "workspace-autolaunch: no new window appeared on workspace $ws within $((wait_ticks / 10))s" >&2
  return 1
}

focus_addr() {
  hyprctl dispatch "hl.dsp.focus({ window = \"address:$1\" })" >/dev/null 2>&1
}

# Dwindle preselect: forces the NEXT window opened to land in direction $1
# ("r"ight or "d"own) of the currently focused window's rectangle. This is
# what makes each pane count produce a fixed, predictable arrangement instead
# of whatever launch-order + force_split happens to produce.
preselect() {
  # hl.dsp.layout takes ONE string combining the classic dispatcher command
  # and its argument ("preselect d"), not two separate arguments -- the
  # two-argument form silently errors ("No direction for preselect").
  # Verified against this Hyprland build (0.56.2) by direct testing.
  hyprctl dispatch "hl.dsp.layout(\"preselect $1\")" >/dev/null 2>&1
}

# Opens pane $3 in direction $2 (r = right, d = down) of the window $1, and
# prints the new window's address.
spawn() {
  local from=$1 dir=$2 idx=$3 before
  before=$(snapshot); focus_addr "$from"; preselect "$dir"; launch_pane "$idx"
  wait_new "$before"
}

# Every pane after the first, in the order it has to be opened: each entry is
# "<pane>:<anchor pane>:<direction>", and a later split halves the window it
# splits. The picture of each layout is in Model.js launchLayouts.
plan=()
case "$count:$layout" in
1:*) ;;                                              # pane 0 alone already fills the workspace
2:0) plan=("1:0:r") ;;                               # side by side
2:1) plan=("1:0:d") ;;                               # stacked
3:0) plan=("2:0:d" "1:0:r") ;;                       # two on top, one below
3:1) plan=("1:0:r" "2:1:d") ;;                       # one left, two right
3:2) plan=("1:0:d" "2:1:r") ;;                       # one on top, two below
4:0) plan=("1:0:r" "2:1:d" "3:2:d") ;;               # main left, three stacked right
4:1) plan=("1:0:r" "2:0:d" "3:1:d") ;;               # grid
4:2) plan=("1:0:d" "2:1:r" "3:2:r") ;;               # one on top, three below
4:3) plan=("3:0:d" "1:0:r" "2:1:r") ;;               # three on top, one below
esac

# addrs[i] = the window pane i opened, "" if it never appeared.
declare -a addrs=()
for ((i = 0; i < count; i++)); do addrs[i]=""; done

before=$(snapshot)
launch_pane 0
addrs[0]=$(wait_new "$before") || addrs[0]=""

for step in "${plan[@]}"; do
  on_target || { echo "workspace-autolaunch: workspace $ws left the screen, stopping after $step" >&2; break; }
  IFS=: read -r idx anchor dir <<<"$step"
  if [[ -n ${addrs[$anchor]} ]]; then
    addrs[$idx]=$(spawn "${addrs[$anchor]}" "$dir" "$idx") || addrs[$idx]=""
  else
    # Its anchor never showed up. Open it anyway, wherever dwindle puts it:
    # a pane that exists in the wrong tile beats a pane that never launched
    # (0: "... or not at all").
    before=$(snapshot)
    launch_pane "$idx"
    addrs[$idx]=$(wait_new "$before") || addrs[$idx]=""
  fi
done

# One pane may be designated FULL SCREEN. Everything is tiled first and that
# one is blown up last, so the others are sitting in their own tiles behind it
# the moment it is dismissed.
if (( fs_index >= 0 && fs_index < count )) && [[ -n ${addrs[$fs_index]} ]] && on_target; then
  focus_addr "${addrs[$fs_index]}"
  hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "fullscreen" })' >/dev/null 2>&1
fi
