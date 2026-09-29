.pragma library

// Static option lists for the panel's dropdowns. Kept out of the QML files
// so PaneRow stays focused on layout and wiring.

function paneTypeOptions() {
  return [
    { value: "app", label: "App" },
    { value: "webapp", label: "Web App" },
    { value: "terminal", label: "Terminal" },
    { value: "command", label: "Command" }
  ]
}

function paneValuePlaceholder(type) {
  switch (type) {
    case "app": return "app desktop id, e.g. org.gnome.Nautilus"
    case "webapp": return "https://..."
    case "command": return "shell command, e.g. ssh -t silverstone 'bash -lc claude'"
    default: return ""
  }
}

// The global source folder setting is one raw string that can be empty, an
// http(s) URL, or a local folder path -- this is the single place that
// decides which of those it is and where the actual randomize source folder
// lives for each case.

function repoKind(raw) {
  if (!raw) return "unset"
  return /^https?:\/\//i.test(raw) ? "url" : "folder"
}

// Where a URL source's downloaded images are cached.
function repoCacheDir(home) {
  return home + "/.cache/silverstone/repo-cache"
}

// Omarchy's own current-theme wallpapers -- the fallback source when no
// source folder is configured at all, so SilverStone has something to
// randomize from out of the box.
function defaultWallpapersDir(home) {
  return home + "/.local/state/omarchy/current/theme/backgrounds"
}

function resolveWallpaperFolder(raw, home) {
  var kind = repoKind(raw)
  if (kind === "url") return repoCacheDir(home)
  if (kind === "folder") return raw
  return defaultWallpapersDir(home)
}

// Auto-launch panes: a variable-length list again (0-4 entries), added one
// at a time with the "+" button and removed with a slot's "Remove Auto
// Launcher" button (which also shifts every later slot's number down by
// one, not always-4-fixed-slots like the previous design. No more per-slot
// on/off (0: "there shouldn't be slots, the window opens or not") -- a slot
// existing with data IS it being in the launch set; the only way to pause
// one is to remove it or pause the whole workspace.
//
// Just two fields per slot, not three: `args` is dual-purpose -- when appId
// is set it's extra launch args for that app; when appId is empty, `args`
// IS the command/URL to run. Collapsed from an earlier appId+command+
// modifier design that turned out to have one field too many.
function emptyPane() {
  return { appId: "", args: "" }
}

function paneIsSet(p) {
  return !!p && ((p.appId || "") !== "" || String(p.args || "").trim() !== "")
}

// Which raw slot indices survive normalization, in order. Slots are
// STRICTLY PROGRESSIVE by design ("can't have slot 3 without 1 and 2"), but
// saved data can still hold a gap -- clearing a slot's fields in the editor
// empties it in place without removing it. A gap silently broke everything
// that indexes rects/labels/clicks by slot (the preview grid draws one tile
// per CONFIGURED pane, so tile N stopped lining up with slot N), so leading
// and interior empties are dropped here. Trailing empties are KEPT: that's
// the freshly-added slot the popup editor is filling in.
function keptPaneIndices(raw) {
  var kept = []
  if (!raw || !raw.length) return kept
  var last = -1
  for (var i = 0; i < raw.length && i < 4; i++) if (paneIsSet(raw[i])) last = i
  for (var j = 0; j < raw.length && j < 4; j++) {
    if (j > last || paneIsSet(raw[j])) kept.push(j)
  }
  return kept
}

function normalizePanes(raw) {
  if (!raw || !raw.length) return []
  var kept = keptPaneIndices(raw)
  var out = []
  for (var i = 0; i < kept.length; i++) {
    var p = raw[kept[i]] || {}
    out.push({
      appId: p.appId || "",
      args: p.args || ""
    })
  }
  return out
}

// The saved full-screen pick is a slot index into the RAW array, so it has
// to move with the slots normalizePanes drops. -1 when it pointed at one of
// them (that launcher is gone, so nothing is full screen any more).
function normalizeFullScreenIndex(raw, fsIndex) {
  if (typeof fsIndex !== "number" || fsIndex < 0) return -1
  var kept = keptPaneIndices(raw)
  for (var i = 0; i < kept.length; i++) if (kept[i] === fsIndex) return i
  return -1
}

// Turns one enabled pane slot into the {type,value,args} shape
// workspace-autolaunch.sh understands. An http(s)-looking args value (with
// no app picked) is treated as a webapp instead of a literal shell command;
// an enabled slot with neither set falls back to a plain terminal rather
// than launching nothing (which would silently throw off the script's
// fixed-count layout).
function classifyPane(p) {
  var v = (p.args || "").trim()
  if (p.appId) return { type: "app", value: p.appId, args: v }
  if (/^https?:\/\//i.test(v)) return { type: "webapp", value: v, args: "" }
  if (v) return { type: "command", value: v, args: "" }
  return { type: "terminal", value: "", args: "" }
}

// ---- per-workspace wallpaper source -------------------------------------
// A workspace's wallpaper comes from either the global pool ("pool": random,
// or one pinned pool image = poolPath) or from a file outside it ("outside" =
// outsidePath). Both picks are remembered so the radio can flip between them
// without a picker. `mode`/`path` stay the values the rest of the plugin
// reads; effectiveBackground() derives them from the choice.

function inFolder(path, folder) {
  var f = String(folder || "").replace(/\/+$/, "")
  return f !== "" && String(path).indexOf(f + "/") === 0
}

// Fills in source/poolPath/outsidePath, deriving them from the old
// mode/path for configs saved before these fields existed.
function normalizeBackground(bg, defaultFolder) {
  bg = bg || {}
  var mode = bg.mode || "default"
  var path = bg.path || ""
  // `sourceFolder` is what this key was called before the rename to
  // `poolFolder` (see migrateSettings). Drop the fallback once the migration
  // has run everywhere -- it is only here so a workspace keeps its pool if
  // the one-shot write ever fails.
  var folder = (bg.poolFolder !== undefined ? bg.poolFolder : bg.sourceFolder) || defaultFolder
  var legacyCustom = mode === "custom" && path !== ""
  var legacyOutside = legacyCustom && !inFolder(path, folder)
  var legacyPool = legacyCustom && inFolder(path, folder)
  return {
    mode: mode,
    path: path,
    poolFolder: folder,
    source: (bg.source === "outside" || bg.source === "pool") ? bg.source : (legacyOutside ? "outside" : "pool"),
    poolPath: bg.poolPath !== undefined ? String(bg.poolPath) : (legacyPool ? path : ""),
    outsidePath: bg.outsidePath !== undefined ? String(bg.outsidePath) : (legacyOutside ? path : "")
  }
}

// The mode/path that follow from the source choice. Outside with nothing
// picked falls back to the pool; a pool with nothing pinned is random (an
// untouched "default" workspace stays default).
function effectiveBackground(bg) {
  if (bg.source === "outside" && bg.outsidePath) return { mode: "custom", path: bg.outsidePath }
  if (bg.poolPath) return { mode: "custom", path: bg.poolPath }
  return { mode: bg.mode === "default" ? "default" : "random", path: "" }
}

// ---- launch layouts ------------------------------------------------------
// How N auto-launched windows tile on an empty workspace (Hyprland dwindle).
// Each option lists one rect per pane, in pane order, as [x, y, w, h] in 0..1
// -- what the thumbnails draw. Option 0 is always the original/default
// arrangement. The matching launch steps live in
// scripts/workspace-autolaunch.sh (keyed by count:index) -- keep both in step.
// Only right/down splits are used (the same preselects the script already
// proved out), so a later split halves the window it splits, e.g. "main left,
// three right" is 1/2, 1/4, 1/4 down the right side.
function launchLayouts(n) {
  if (n === 2) return [
    { name: "Side by side", rects: [[0, 0, 0.5, 1], [0.5, 0, 0.5, 1]] },
    { name: "Stacked", rects: [[0, 0, 1, 0.5], [0, 0.5, 1, 0.5]] }
  ]
  if (n === 3) return [
    { name: "Two on top, one below", rects: [[0, 0, 0.5, 0.5], [0.5, 0, 0.5, 0.5], [0, 0.5, 1, 0.5]] },
    { name: "One left, two right", rects: [[0, 0, 0.5, 1], [0.5, 0, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]] },
    { name: "One on top, two below", rects: [[0, 0, 1, 0.5], [0, 0.5, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]] }
  ]
  if (n === 4) return [
    { name: "Main left, three right", rects: [[0, 0, 0.5, 1], [0.5, 0, 0.5, 0.5], [0.5, 0.5, 0.5, 0.25], [0.5, 0.75, 0.5, 0.25]] },
    { name: "Grid", rects: [[0, 0, 0.5, 0.5], [0.5, 0, 0.5, 0.5], [0, 0.5, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]] },
    { name: "One on top, three below", rects: [[0, 0, 1, 0.5], [0, 0.5, 0.5, 0.5], [0.5, 0.5, 0.25, 0.5], [0.75, 0.5, 0.25, 0.5]] },
    { name: "Three on top, one below", rects: [[0, 0, 0.5, 0.5], [0.5, 0, 0.25, 0.5], [0.75, 0, 0.25, 0.5], [0, 0.5, 1, 0.5]] }
  ]
  return []
}

// The saved layout index, clamped to what exists for this window count (the
// count changes as launchers are toggled; the saved index just wraps).
function launchLayoutIndex(n, saved) {
  var c = launchLayouts(n).length
  if (c === 0) return 0
  return (((saved | 0) % c) + c) % c
}

// Best-effort app display name for an appId, from a
// DesktopEntries.applications.values-shaped array; falls back to the raw id.
function appLabel(apps, id) {
  if (!id) return id
  for (var i = 0; i < (apps ? apps.length : 0); i++) {
    var e = apps[i]
    if (e && String(e.id) === id) return String(e.name || e.id)
  }
  return id
}

// One pane's inline description: the app's display name if one's picked, with
// its args after it, else the args value itself (the command/URL in that
// case). The args are part of the label (0: "If a AL has args, show it on the
// lie and the main preview") -- without them two panes on the same app read
// identically on the main panel's card hover.
function paneLabel(apps, p) {
  if (!p) return "(not set)"
  var args = String(p.args || "").trim()
  if (p.appId) {
    var name = appLabel(apps, p.appId)
    return args !== "" ? (name + " " + args) : name
  }
  return args !== "" ? args : "(not set)"
}

// Panes with any data set -- "how many are configured" under the strictly-
// progressive 1 / 1-2 / 1-2-3 rule. There's no separate per-slot on/off any
// more (0: "there shouldn't be slots, the window opens or not ... if an auto
// launch is set and auto launch is on, then it launches as normal") --
// configured IS the launch set, so this single count drives both what's
// shown live and what actually fires.
function configuredCount(panes) {
  var n = 0
  for (var i = 0; i < (panes ? panes.length : 0); i++) {
    var p = panes[i]
    if (p && (p.appId !== "" || String(p.args || "").trim() !== "")) n++
  }
  return n
}

// The configured panes themselves, in slot order -- what launches when Auto
// Launch fires. Parallel to configuredCount above, but returns the objects.
function configuredPanes(panes) {
  var out = []
  for (var i = 0; i < (panes ? panes.length : 0); i++) {
    var p = panes[i]
    if (p && (p.appId !== "" || String(p.args || "").trim() !== "")) out.push(p)
  }
  return out
}

// ---- one-shot settings migration -----------------------------------------
// The two pool settings keys were renamed to match what the UI already called
// them: the top-level `wallpaperRepository` is now `poolFolder`, and a
// workspace's `background.sourceFolder` is now `background.poolFolder`. Both
// are read here so a pool saved under the old names survives the rename; what
// gets written back is new-vocabulary only.
function settingsNeedMigration(raw) {
  if (!raw || typeof raw !== "object") return false
  if (raw.wallpaperRepository !== undefined && raw.poolFolder === undefined) return true
  var ws = raw.workspaces
  if (!ws || typeof ws !== "object") return false
  for (var k in ws) {
    if (!Object.prototype.hasOwnProperty.call(ws, k)) continue
    var bg = ws[k] && ws[k].background
    if (bg && typeof bg === "object" && bg.sourceFolder !== undefined && bg.poolFolder === undefined) return true
  }
  return false
}

// A NEW object -- the caller's settings are never touched, so the write this
// feeds can't be a self-assignment. A key already carrying the new name wins
// over the old one, so a half-migrated config converges instead of flapping.
// Idempotent by construction: a second pass over its own output finds nothing
// left to move, which is what lets the caller fire it once on load.
function migrateSettings(raw) {
  var next = JSON.parse(JSON.stringify(raw || {}))
  if (next.wallpaperRepository !== undefined && next.poolFolder === undefined) {
    next.poolFolder = next.wallpaperRepository
  }
  delete next.wallpaperRepository
  if (next.workspaces && typeof next.workspaces === "object") {
    for (var k in next.workspaces) {
      if (!Object.prototype.hasOwnProperty.call(next.workspaces, k)) continue
      var w = next.workspaces[k]
      if (!w || typeof w !== "object") continue
      var bg = w.background
      if (!bg || typeof bg !== "object") continue
      if (bg.sourceFolder !== undefined && bg.poolFolder === undefined) bg.poolFolder = bg.sourceFolder
      delete bg.sourceFolder
    }
  }
  return next
}
