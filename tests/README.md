# Wpal click-through tests

Automated replacement for manually uninstalling/reinstalling and clicking
through Wpal to check it still behaves. Runs the real plugin inside a
throwaway, isolated Hyprland+Quickshell instance (the
`ss-remote-screen-control` recipe in SilverStone-Hub) — nothing touches your
real desktop, settings, or wallpaper.

## Run it

```
./tests/run.sh            # all scenarios
./tests/run.sh fresh-install
./tests/run.sh escape-cascade
./tests/run.sh replacement-bar
```

## Requirements

- `ss-onboard-remote-screen-control` has been run on this machine at least
  once (ydotool + `/dev/uinput` access).
- A calibration file at `tests/lib/calibration/<hostname>.env` — see
  `T420.env`. Missing file = clear error pointing at onboarding, not a
  silent wrong-coordinate click.

## Layout

- `run.sh` — entry point, runs one scenario or all.
- `lib/harness.sh` — shared setup (fresh throwaway HOME + shell.json each
  run, nested Hyprland launch) / teardown / ydotool+IPC helpers.
- `lib/calibration/` — per-machine ydotool scale, one file per hostname.
- `scenarios/` — one file per behavior being checked.
- `screenshots/` — left behind after each run for a human to glance at;
  not asserted on by the scripts themselves.

## Scenarios so far

- `fresh-install` — boots from a bare `{"id": "silverstone.wpal"}` entry,
  confirms `globalOverride` seeds correctly with no clicks needed.
- `escape-cascade` — opens the per-workspace editor, double-taps Escape,
  confirms the panel closes in exactly 2 presses (regression test for the
  2026-10-05 bug where a fast double-tap needed a 3rd press — see
  `Panel.qml`'s `escapeGuardUntil`).
- `replacement-bar` — same as `fresh-install`, but boots under a cloned
  bar.id (`WPAL_TEST_REPLACEMENT_BAR=1` in `harness.sh`), reproducing
  SilverAsus's real `chad.bar` setup where `serviceFor()` always returns
  null. Regression test for the blank-wallpaper-preview bug fixed by
  `BarWidget.qml`'s `hostService`/`effectiveService` fallback.

## Adding a scenario

Drop a `scenarios/<name>.sh` defining `run_<name_with_underscores>`, source
`lib/harness.sh`, and add it to `SCENARIOS` in `run.sh`. Drive the panel via
its own IPC handler (`harness_ipc open|close|toggle|isOpen`, target
`silverstone` in `BarWidget.qml`) and keyboard nav where possible —
coordinate-clicking (`harness_click`) is the fallback, not the default, since
it breaks the moment a layout shifts.

## Not yet covered

- `duplicate-pane` (the auto-launch `gtk-launch` dedup bug, fixed in
  `5c77557`) — needs a way to count real windows inside the nested
  instance's own compositor (`hyprctl --instance <nested-sig> clients -j`),
  not yet wired up here.
- Anything on SilverAsus — this machine's calibration doesn't exist yet;
  onboard it first, then add `tests/lib/calibration/SilverAsus.env`.
