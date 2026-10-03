import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Qt.labs.folderlistmodel
import qs.Commons
import "Model.js" as Model

// SilverStone's headless brain. Lives for the life of the shell process
// (kind: "service"), watching the focused workspace and reacting to it:
//   - background: mirrors/sets the wallpaper per workspace via the existing
//     omarchy.background plugin's IPC (shelled out, not called in-process --
//     a third-party plugin can only reach its own service).
//   - autoLaunch: spawns the configured panes the first time a workspace with
//     panes configured is visited while it has zero windows.
//
// A "service" entry point is never handed `settings` by the host -- only
// bar-widget/panel instances get that. BarWidget.qml (always mounted for the
// life of the bar) pushes its settings down here on every change; see
// BarWidget.qml's pushSettings().
Item {
  id: service

  property var settings: ({})

  readonly property var focusedWorkspace: Hyprland.focusedWorkspace
  readonly property int focusedId: focusedWorkspace ? focusedWorkspace.id : -1

  readonly property string home: Quickshell.env("HOME")
  // The global source folder, configurable from the config card's dialog:
  // empty, a local folder, or an http(s) URL (fetched once into a local
  // cache -- see fetchRepoIfUrl below). Model.resolveWallpaperFolder picks
  // the actual randomize source folder for each case, falling back to
  // Omarchy's current theme wallpapers when nothing is configured.
  // `wallpaperRepository` is the pre-rename key, read here only as a fallback
  // for a failed migration write -- see Model.migrateSettings.
  readonly property string poolFolderRaw: (settings && settings.poolFolder !== undefined)
    ? settings.poolFolder
    : ((settings && settings.wallpaperRepository) || "")
  readonly property string poolFolder: Model.resolveWallpaperFolder(service.poolFolderRaw, service.home)

  property string themeBackground: ""

  // themeBackground only fills in once the async `readlink` below finishes
  // (see readThemeBg/currentBackgroundLink), so the first ever panel open on
  // a fresh install -- before that completes, or if the live symlink is ever
  // missing -- previously had no "default wallpaper" to fall back on at all:
  // previewPath()/applyBackground() returned/applied "" and every untouched
  // card (Omarchy mode's lone card, every one of Custom mode's ten li items)
  // sat blank with nothing actually drawn to the desktop either. This scans
  // Omarchy's own current-theme backgrounds folder -- the same one the
  // Omarchy Default pool already randomizes from -- so there's always a real
  // image on disk to show/apply, independent of whether the live symlink has
  // resolved yet.
  FolderListModel {
    id: defaultWallpapersModel
    folder: Util.fileUrl(Model.defaultWallpapersDir(service.home))
    showDirs: false
    showDotAndDotDot: false
    caseSensitive: false
    nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp", "*.bmp", "*.gif"]
    sortField: FolderListModel.Name
  }
  readonly property string defaultWallpaperFallback: defaultWallpapersModel.count > 0
    ? String(defaultWallpapersModel.get(0, "filePath") || "") : ""

  // What "the default wallpaper" actually resolves to: the live theme
  // background once it's loaded, else the fallback above. Every read/apply
  // site that means "show/use the default wallpaper" goes through this, not
  // the raw themeBackground, so there is always something to show.
  readonly property string resolvedThemeBackground: service.themeBackground || service.defaultWallpaperFallback

  property var randomCache: ({})   // { "3": "/abs/path.jpg" } -- cleared on theme change
  property var lastLaunchAt: ({})  // { "3": <ms epoch> } -- debounce

  // Whether the panel is meant to be open right now, mirrored here (not on
  // the bar widget) because a settings write that the bar host can't patch
  // in place destroys and recreates the bar-widget/panel instance -- this
  // Item, being a kept service, survives that and lets a fresh instance
  // restore itself. Panel.qml keeps this in sync with its own `opened`.
  property bool panelOpenIntent: false

  // Same story as panelOpenIntent, for which dialog is open: -1 none, 0
  // config, 1-10 a workspace. Without this, picking an image (any settings
  // write recreates the panel) would silently close the dialog the picker
  // was opened from -- the pick lands in settings fine, but the dialog
  // vanishes out from under the user instead of showing the result.
  property int activeWorkspaceIntent: -1
  property real dialogAnchorYIntent: 0
  // Same again for li's child panels. Without these, the settings write that
  // every edit performs rebuilt the panel, reset expandedSlot to -1 and left
  // the Pane config writing to slot -1 -- which is exactly 0's "the AL Editor
  // is not saving after a change, it keep its original".
  property int expandedSlotIntent: -1
  property bool cloneOpenIntent: false

  // Same story again for the panel's Global settings block, which a mode
  // switch (a settings write) would otherwise collapse the instant it was
  // opened. Never open at the same time as a workspace editor -- see
  // Panel.openWorkspace.

  // Defaults to Omarchy Default (false) on a fresh install with no "enabled"
  // key saved yet -- matches Panel.qml's masterEnabled.
  readonly property bool masterEnabled: settings && settings.enabled === true
  // Omarchy-mode wallpaper the user picked/shuffled on the single card; kept
  // as its own key so it never touches the ten Custom workspace configs.
  // Empty = no override: Omarchy mode just follows the system/theme
  // background.
  readonly property string globalOverride: (settings && settings.globalOverride) || ""
  // Independent of masterEnabled (wallpaper mode) -- a global kill switch
  // for every workspace's auto-launch panes, without discarding what's
  // configured on each one.
  readonly property bool autoLaunchEnabled: settings && settings.autoLaunchEnabled !== false

  // Normalized per-workspace config with every field defaulted, so callers
  // never have to null-check. There's no separate "customize" gate: a
  // workspace with mode "default" and no panes is already a no-op at
  // runtime (default mirrors the theme either way; zero panes never
  // launches anything), so an untouched workspace stays inert without
  // needing its own flag.
  function wsConfig(id) {
    var w = (settings && settings.workspaces) ? settings.workspaces[String(id)] : null
    var bg = (w && w.background) || {}
    // `Array.isArray` is unreliable here: settings pushed down from
    // BarWidget cross the C++/JS boundary as array-LIKE QJSValue-wrapped
    // sequences that JSON.stringify handles fine but Array.isArray reports
    // false for. Round-tripping through JSON gives back a genuine array.
    var panesRaw = w && w.panes
    return {
      background: {
        mode: bg.mode || "default",
        path: bg.path || "",
        // `sourceFolder` is this key's pre-rename name; same fallback (and
        // same "drop it once the migration has run" note) as the one in
        // Model.normalizeBackground. Read raw here rather than through
        // normalizeBackground because "" means "inherit the global pool" and
        // has to survive as "".
        poolFolder: ((bg.poolFolder !== undefined ? bg.poolFolder : bg.sourceFolder) || service.poolFolder)
      },
      panes: Model.normalizePanes(panesRaw ? JSON.parse(JSON.stringify(panesRaw)) : null),
      autoLaunchEnabled: !w || w.autoLaunchEnabled !== false,
      launchLayout: (w && w.launchLayout) | 0,
      // Which pane opens FULL SCREEN, remapped past any empty slot exactly
      // the way Panel.wsSetting does it. It was missing here, so the launch
      // path never even saw the pick -- the setting saved, drew its glyph in
      // li, and then nothing on screen ever opened full screen (0: "or full
      // screen for one, with the others open behind").
      fullScreenIndex: Model.normalizeFullScreenIndex(
        panesRaw ? JSON.parse(JSON.stringify(panesRaw)) : null,
        (w && typeof w.fullScreenIndex === "number") ? w.fullScreenIndex : -1)
    }
  }

  // Read-only preview of "what image represents this workspace right now",
  // for the panel's thumbnails. Never triggers a resolve as a side effect --
  // opening the dropdown shouldn't itself pick a random image.
  function previewPath(id) {
    // Custom always wins regardless of mode -- the Omarchy Default card's
    // simple picker writes a real "custom" path into every workspace (see
    // Panel.qml's applyWallpaperToAllWorkspaces), not a separate override,
    // so it needs to show up here the same way any other custom pick does.
    // Random is only consulted in SilverStone Custom, since that's the only
    // mode that ever actively resolves/caches a random pick. randomCache is
    // in-memory only and empty on every restart, but the last resolved pick
    // is now persisted at background.path too (see persistRandomPicks), so
    // that's the second fallback -- only an untouched-since-ever workspace
    // (never visited, never randomized, nothing persisted) falls all the way
    // to the theme default rather than showing blank.
    // Omarchy Default mode ignores every workspace setting: the override if
    // there is one, else the system/theme background.
    if (!service.masterEnabled) return service.globalOverride || service.resolvedThemeBackground
    var cfg = service.wsConfig(id)
    if (cfg.background.mode === "custom" && cfg.background.path) return cfg.background.path
    if (service.masterEnabled && cfg.background.mode === "random") return service.randomCache[String(id)] || cfg.background.path || service.resolvedThemeBackground
    return service.resolvedThemeBackground
  }

  function workspaceById(id) {
    var vs = Hyprland.workspaces.values
    for (var i = 0; i < vs.length; i++) if (vs[i].id === id) return vs[i]
    return null
  }

  // ---- live background tracking ---------------------------------------

  Process {
    id: readThemeBg
    // -e (not -f): -f canonicalizes best-effort and returns a path even when
    // the final target is missing, so a dangling symlink silently poisons
    // themeBackground with a bogus-but-truthy value and resolvedThemeBackground's
    // `||` never falls through to defaultWallpaperFallback. -e requires the
    // final target to actually exist, failing (empty stdout) on a dangling
    // symlink -- see the SilverAsus theme-state-inconsistency bug referenced
    // in Panel.qml's _seedDefaultSnapshotOnce comment.
    command: ["readlink", "-e", service.home + "/.local/state/omarchy/current/background"]
    stdout: StdioCollector {
      onStreamFinished: {
        var p = String(text || "").trim()
        if (p) service.themeBackground = p
      }
    }
  }

  FileView {
    id: currentBackgroundLink
    path: service.home + "/.local/state/omarchy/current/background"
    watchChanges: true
    printErrors: false
    onFileChanged: readThemeBg.running = true
    onLoaded: readThemeBg.running = true
  }

  function setInstant(path) {
    if (!path) return
    // Cross-plugin calls are shelled out, not in-process -- a plugin can only
    // reach its own service via shell.serviceFor(ownId). Every first-party
    // example of driving omarchy.background's IPC (e.g. omarchy-theme-bg-set)
    // does it the same way.
    Quickshell.execDetached(["omarchy-shell", "-q", "background", "setInstant", path])
  }

  property int _randomProcTargetId: -1
  // Whether the resolved pick should be pushed to the visible background.
  // False for a reroll on a workspace that isn't currently focused -- that
  // reroll should update the cache (so the panel's thumbnail reflects it and
  // the next visit uses it) without yanking the wallpaper out from under
  // whatever workspace IS focused right now.
  property bool _randomProcApply: true

  Process {
    id: randomPickProc
    stdout: StdioCollector {
      onStreamFinished: {
        var id = service._randomProcTargetId
        var lines = String(text || "").split("\n").filter(function(l) { return l.length > 0 })
        var pick = lines.length > 0 ? lines[Math.floor(Math.random() * lines.length)] : ""
        if (pick) {
          // A fresh object, not a same-reference mutation: reassigning
          // `property var` to the identical object it already held doesn't
          // fire randomCacheChanged, which is what the panel's thumbnail
          // binding depends on to update live.
          var cache = Object.assign({}, service.randomCache)
          cache[String(id)] = pick
          service.randomCache = cache
          // Persist the pick so a reboot shows this SAME image instead of
          // rerolling -- 0, 2026-09-30: "set wallpapers should survive a
          // reboot" applies to a random draw too, not just an explicit Set.
          // See resolveRandom's persisted-path fallback, which is what
          // actually reads this back on the next cold start.
          var picks = {}
          picks[String(id)] = pick
          service.persistRandomPicks(picks)
        }
        if (service._randomProcApply) service.setInstant(pick || service.resolvedThemeBackground)
      }
    }
  }

  // Writes one or more workspaces' resolved random pick into settings,
  // touching only each workspace's background.path -- mode/poolFolder/panes/
  // etc. are left exactly as they already are, since whatever wrote those
  // (randomizeWorkspace, randomizeAllWorkspaces) already ran first. `picks`
  // is `{ "3": "/abs/path.jpg", ... }`.
  function persistRandomPicks(picks) {
    if (!service.writeSettings) return
    var keys = Object.keys(picks || {})
    if (keys.length === 0) return
    var next = JSON.parse(JSON.stringify(service.settings || {}))
    if (!next.workspaces) next.workspaces = {}
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      var existing = next.workspaces[key] || {}
      var bg = existing.background || {}
      existing.background = Object.assign({}, bg, { path: picks[key] })
      next.workspaces[key] = existing
    }
    service.writeSettings(next)
  }

  function findImagesCommandFor(dir) {
    var q = Util.shellQuote(dir)
    return ["bash", "-lc",
      "find -L " + q + " -maxdepth 1 -type f " +
      "\\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.gif' \\) 2>/dev/null"]
  }

  function findImagesCommand(id) {
    return service.findImagesCommandFor(service.wsConfig(id).background.poolFolder)
  }

  // Global Rando Wallpaper (the config card's checkbox/shuffle button):
  // every workspace gets its own fresh random pick -- from ITS OWN resolved
  // pool if it has a custom one, else the shared source folder (0: "setting
  // a custom background pool for a WS... overrides the global pool for a
  // rendomizer push"). This used to list ONE shared folder and spray those
  // same results across all ten workspaces, ignoring any custom pool
  // entirely -- a real bug, not a missing feature.
  //
  // Grouped by resolved folder (wsConfig's poolFolder, custom-or-global
  // fallback already built in) so a shared global pool still costs one
  // `find`, not ten -- only workspaces with their OWN distinct custom pool
  // add an extra lookup each. The global folder always runs first in the
  // queue (even if no workspace resolves to it directly) so its results are
  // ready as the fallback the moment anything else needs them: a custom pool
  // that comes back with 0 images falls back to the global pick for that
  // workspace; a custom pool with exactly 1 image stays pinned to it every
  // time (0, asked directly: "use that one image every time") -- nothing to
  // vary, but still drawn from its own pool, not overridden.
  property var _shuffleQueue: []
  property string _shuffleGlobalFolder: ""
  property var _shuffleGlobalLines: []
  property var _shuffleCache: ({})
  property var _shuffleCurrentIds: []

  Process {
    id: globalRandomAllProc
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = String(text || "").split("\n").filter(function(l) { return l.length > 0 })
        if (service._shuffleCurrentFolder === service._shuffleGlobalFolder) {
          service._shuffleGlobalLines = lines
        }
        var useLines = lines.length > 0 ? lines : service._shuffleGlobalLines
        var ids = service._shuffleCurrentIds
        for (var i = 0; i < ids.length; i++) {
          if (useLines.length > 0) service._shuffleCache[String(ids[i])] = useLines[Math.floor(Math.random() * useLines.length)]
        }
        service._shuffleStep()
      }
    }
  }

  function randomizeAllWorkspacesOnce() {
    var globalFolder = service.poolFolder
    var byFolder = {}
    for (var id = 1; id <= 10; id++) {
      var folder = service.wsConfig(id).background.poolFolder
      if (!byFolder[folder]) byFolder[folder] = []
      byFolder[folder].push(id)
    }
    // Global first, always, even with an empty id list -- guarantees
    // _shuffleGlobalLines is populated before any custom pool needs it as a
    // fallback.
    var queue = [{ folder: globalFolder, ids: byFolder[globalFolder] || [] }]
    delete byFolder[globalFolder]
    for (var f in byFolder) queue.push({ folder: f, ids: byFolder[f] })
    service._shuffleQueue = queue
    service._shuffleGlobalFolder = globalFolder
    service._shuffleGlobalLines = []
    service._shuffleCache = {}
    service._shuffleStep()
  }

  // One folder at a time -- Quickshell's Process is one command in flight at
  // once, and there's no benefit to true parallelism for a handful of quick
  // local `find`s.
  property string _shuffleCurrentFolder: ""
  function _shuffleStep() {
    if (service._shuffleQueue.length === 0) {
      var cache = Object.assign({}, service.randomCache, service._shuffleCache)
      service.randomCache = cache
      // One batched write for all ten picks, not ten -- same reasoning as
      // Panel.randomizeAllWorkspaces' own settings write: ten writes would
      // rebuild the panel ten times over.
      service.persistRandomPicks(service._shuffleCache)
      service.applyBackground(service.focusedId)
      return
    }
    var next = service._shuffleQueue.shift()
    service._shuffleCurrentFolder = next.folder
    service._shuffleCurrentIds = next.ids
    globalRandomAllProc.command = service.findImagesCommandFor(next.folder)
    globalRandomAllProc.running = true
  }

  // Randomize draws from a single folder the user picks per workspace
  // (defaulting to the shared source folder), not an automatic union with
  // the theme's own backgrounds -- Chad asked to choose the source
  // explicitly rather than have it decided for him.
  function resolveRandom(id, force, apply) {
    if (apply === undefined) apply = true
    if (!force) {
      var cached = service.randomCache[String(id)]
      // Cold boot: randomCache is empty (in-memory only), but the last
      // resolved pick is now persisted at wsConfig(id).background.path (see
      // persistRandomPicks) -- use that instead of drawing a new image, so a
      // random-mode workspace shows the SAME picture after a reboot. Seed
      // the cache with it too, so previewPath/subsequent calls don't keep
      // re-reading settings.
      if (!cached) {
        var persisted = service.wsConfig(id).background.path
        if (persisted) {
          var seeded = Object.assign({}, service.randomCache)
          seeded[String(id)] = persisted
          service.randomCache = seeded
          cached = persisted
        }
      }
      if (cached) { if (apply) service.setInstant(cached); return }
    }
    service._randomProcTargetId = id
    service._randomProcApply = apply
    randomPickProc.command = service.findImagesCommand(id)
    randomPickProc.running = true
  }

  // Clone takes the picture with it. A clone copies the source's settings --
  // including its POOL -- but random mode resolves a pick PER WORKSPACE, so
  // the clone came up showing a different image from the one being cloned
  // (0: "when you clone a workspace, clone the wallpaper too"). Copying the
  // source's current pick into each target makes them match now; a later
  // shuffle still rerolls them independently, which is what the pool is for.
  function mirrorRandomPick(fromId, targets) {
    var src = service.randomCache[String(fromId)]
    if (!src || !targets || targets.length === 0) return
    var cache = Object.assign({}, service.randomCache)
    for (var i = 0; i < targets.length; i++) cache[String(targets[i])] = src
    service.randomCache = cache
  }

  function applyBackground(id) {
    if (id < 1) return
    // Omarchy Default mode hands off to the system: the global override if
    // one is set, else the live theme/system background -- saved workspace
    // settings are ignored, so switching back from Custom always reverts.
    // Custom applies each workspace's own custom/random setting.
    if (!service.masterEnabled) { service.setInstant(service.globalOverride || service.resolvedThemeBackground); return }
    var cfg = service.wsConfig(id)
    if (cfg.background.mode === "custom" && cfg.background.path) { service.setInstant(cfg.background.path); return }
    if (service.masterEnabled && cfg.background.mode === "random") { service.resolveRandom(id, false); return }
    service.setInstant(service.resolvedThemeBackground)  // "default" (or Omarchy Default mode): live-mirror
  }

  // ---- wallpaper source folder (url case) -------------------------------

  readonly property string fetchRepoScriptPath: {
    var u = Qt.resolvedUrl("scripts/fetch-wallpaper-repo.sh").toString()
    return decodeURIComponent(u.replace(/^file:\/\//, ""))
  }

  // Downloads once into the cache dir when the source is set to a URL --
  // "download once, cache locally" per how Chad wants this to behave. Nothing
  // re-triggers this beyond the setting itself changing, so a
  // stale/rearranged remote listing needs the setting re-saved to pick up.
  function fetchRepoIfUrl() {
    if (Model.repoKind(service.poolFolderRaw) !== "url") return
    fetchRepoProc.command = ["bash", service.fetchRepoScriptPath,
      service.poolFolderRaw, Model.repoCacheDir(service.home)]
    fetchRepoProc.running = true
  }
  Process { id: fetchRepoProc }

  // A pool-folder change is pure state -- it never redraws any workspace's
  // wallpaper by itself (0, repeatedly, emphatically: "it only sets the
  // global pool, the user sets the actual bg, or clicks shuffle, that's when
  // the wallpapers change"). No reroll here. The new pool is picked up for
  // free, with zero extra code, the next time anything actually draws: a
  // real Shuffle (randomizeAllWorkspacesOnce / a single workspace's shuffle,
  // both read the live-resolved pool per workspace at shuffle time) or an
  // explicit BG set. resolveRandom(id, false) already prefers the
  // cached/persisted pick and never redraws unless force=true -- that's
  // exactly the "leave existing pictures alone" behavior this relies on.
  onPoolFolderRawChanged: service.fetchRepoIfUrl()

  // ---- auto-launch -----------------------------------------------------

  readonly property string scriptPath: {
    var u = Qt.resolvedUrl("scripts/workspace-autolaunch.sh").toString()
    return decodeURIComponent(u.replace(/^file:\/\//, ""))
  }

  // The configured panes that would launch on `id` right now, or null when
  // nothing should: global switch off, this workspace paused, nothing
  // configured, or ANY window already open there. No more per-slot on/off --
  // a slot with data in it IS in the launch set (0: "if an auto launch is
  // set and auto launch is on, then it launches as normal").
  function launchablePanes(id) {
    if (id < 1) return null
    if (!service.autoLaunchEnabled) return null  // global kill switch always wins
    var cfg = service.wsConfig(id)
    if (!cfg.autoLaunchEnabled) return null  // this workspace's own pause, independent of the global one
    var active = Model.configuredPanes(cfg.panes)
    if (active.length === 0) return null
    var ws = service.workspaceById(id)
    if (!ws || ws.toplevels.values.length !== 0) return null  // never touch a non-empty workspace
    return active
  }

  // The hard rule: focus an EMPTY workspace and its launchers fire; focus one
  // with anything on it and NOTHING happens. No prompt in between -- a prompt
  // window on focus would itself be "something happening."
  function maybeAutoLaunch(id) {
    if (!service.launchablePanes(id)) return
    console.log("silverstone: workspace " + id + " is empty with panes to launch")
    service.launchWorkspace(id)
  }

  function launchWorkspace(id) {
    var active = service.launchablePanes(id)  // re-check: config/windows may have changed since evaluateWorkspace
    if (!active) return

    var now = Date.now()
    var last = service.lastLaunchAt[String(id)] || 0
    if (now - last < 3000) return  // debounce while the panes are still mapping

    var stamped = Object.assign({}, service.lastLaunchAt)
    stamped[String(id)] = now
    service.lastLaunchAt = stamped

    var payload = Qt.btoa(JSON.stringify(active.map(Model.classifyPane)))
    console.log("silverstone: launching " + active.length + " pane(s) on workspace " + id)
    var cfg = service.wsConfig(id)
    var layout = Model.launchLayoutIndex(active.length, cfg.launchLayout)
    // The full-screen pick, as an index into `active` (the panes actually
    // being launched). configuredPanes keeps slot order and normalizePanes
    // only ever drops empties, so the two index spaces line up; anything
    // past the end means the pick pointed at a launcher that is gone.
    var fs = cfg.fullScreenIndex
    if (fs >= active.length) fs = -1
    launchProc.command = ["bash", service.scriptPath, String(id), payload, String(layout), String(fs)]
    launchProc.running = true
  }

  // "Launch now" from a workspace's li dialog. The launch script arranges the
  // windows on whatever workspace is focused, so this only launches the
  // focused one: for another workspace it switches there first, and arriving
  // on an empty workspace triggers its normal auto-launch. Never touches a
  // workspace that already has windows (launchablePanes checks).
  function launchNow(id) {
    if (id < 1) return
    if (id !== service.focusedId) {
      switchProc.command = ["hyprctl", "dispatch", "hl.dsp.focus({workspace=" + id + "})"]
      switchProc.running = true
      return
    }
    service.launchWorkspace(id)
  }
  Process { id: switchProc }

  // "default" checkbox on the Custom Actions tile (Panel.startupCustom): once
  // per shell start, if it's ticked and the saved mode isn't Custom, switch
  // to Custom. Runs when BarWidget installs writeSettings (right after it
  // pushes settings), gated so later re-pushes never re-apply it.
  // Set the first time a randomize control is used in Custom mode; the panel
  // then shows "Change Again" on it. Lives here because every shuffle writes
  // settings, which rebuilds the panel. Cleared by Panel.onOpenedChanged when
  // the panel is closed -- one panel-open is one "session".
  property bool randomizedOnce: false

  // The randomize cluster reveals itself on hover and then stays put for the
  // rest of the panel-open (0: "11a sits there waiting, 11b and 11c are hidden,
  // ON HOVER fire 11b and 11c ... they stay the rest of the session, resets on
  // session open"). Here, not in Panel, so a settings write doesn't hide them
  // again; Panel clears both when the panel closes.
  property bool randomizeRevealed: false
  // Timestamp of the last shuffle. The cards' staggered fade is for THAT and
  // nothing else -- see Panel.shuffleJustRan.
  property double shuffleAt: 0
  // li's clone line plays once per panel-open and then stays put; this is
  // what remembers it across li being closed and reopened (0: "only fires
  // once now, and stays till panel close"). Cleared in Panel.onOpenedChanged
  // beside randomizeRevealed.
  property bool cloneRevealed: false
  property bool randomizeArmed: false


  property bool startupApplied: false
  function applyStartupMode() {
    if (service.startupApplied || !service.writeSettings) return
    service.startupApplied = true
    var s = service.settings || {}
    if (s.startupCustom === true && s.enabled !== true) {
      var next = JSON.parse(JSON.stringify(s))
      next.enabled = true
      console.log("silverstone: startup default -> Custom Actions")
      service.writeSettings(next)
    }
  }
  onWriteSettingsChanged: Qt.callLater(service.applyStartupMode)

  // Service only reads settings; BarWidget (the one thing with shell access
  // for the plugin's whole life) installs this alongside `settings` for the
  // few writes Service itself needs to make.
  property var writeSettings: null

  // Panes' own stderr is passed through to the journal instead of being
  // swallowed, so a failing launch is visible (journalctl --user).
  Process {
    id: launchProc
    stderr: StdioCollector {
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t) console.warn("silverstone: launch stderr: " + t)
      }
    }
  }

  function evaluateWorkspace(id) {
    if (id < 1) return
    applyBackground(id)
    maybeAutoLaunch(id)
  }

  // ---- close quietly when the screensaver comes up ---------------------

  // Fires when Hyprland reports the first-party idle plugin's screensaver
  // window mapping (window class "org.omarchy.screensaver") -- the same
  // signal that plugin itself watches for
  // (plugins/services/idle/Service.qml's handleHyprlandEvent). Panel.qml
  // listens for this and just calls close(); nothing here decides idle
  // policy, only reacts to the screensaver actually appearing.
  signal screensaverActivated()

  function handleHyprlandEvent(event) {
    var name = String(event && event.name ? event.name : "")
    if (name !== "openwindow") return
    var parts = event.parse ? event.parse(4) : String(event && event.data ? event.data : "").split(",")
    if (String(parts[2] || "") === "org.omarchy.screensaver") service.screensaverActivated()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { service.handleHyprlandEvent(event) }
  }

  onFocusedIdChanged: {
    // Same cold-start race _applyBootBackgroundOnce guards below: a focus
    // change can fire before BarWidget's deferred pushSettings() lands, which
    // would otherwise run this against the still-default `settings: {}` and
    // cache a wrong random pick that never gets retried. Once the first real
    // settings push has landed, _applyBootBackgroundOnce has already done
    // today's first evaluate, so later focus changes are free to run here.
    if (service._bootBackgroundApplied) evaluateWorkspace(focusedId)
  }
  // Apply immediately on a mode switch, not just on the next focus change.
  onMasterEnabledChanged: applyBackground(service.focusedId)
  onGlobalOverrideChanged: if (!service.masterEnabled) applyBackground(service.focusedId)

  // Cold-start race, found 2026-09-30: this Item and BarWidget.qml (which
  // holds the real shell.json data) are separate instances with no
  // constructor ordering between them. BarWidget only hands this Item real
  // settings via its own deferred pushSettings() -- see BarWidget.qml's
  // "settings" comment. If Component.onCompleted below fired its boot
  // evaluate unconditionally (the old code), it could win that race and run
  // evaluateWorkspace/applyBackground while `settings` was still its default
  // `{}`, resolving poolFolder to Model.resolveWallpaperFolder's fallback --
  // Omarchy's theme backgrounds dir, not the configured custom pool. Random
  // mode then CACHES that wrong pick in randomCache, which resolveRandom
  // never retries once cached, so the workspace stayed on a theme-default
  // image for the whole session -- exactly the "some did, some didn't,
  // artifacted out to the default pool" 0 reported after a reboot, confirmed
  // against shell.json: the affected workspaces' last-resolved `path` sat
  // inside .local/state/omarchy/current/theme/backgrounds/ while working
  // ones sat inside the real pool folder. Gate the boot evaluate on the
  // FIRST real settings push instead of guessing with a bare Qt.callLater.
  property bool _bootBackgroundApplied: false
  function _applyBootBackgroundOnce() {
    if (service._bootBackgroundApplied) return
    service._bootBackgroundApplied = true
    evaluateWorkspace(service.focusedId)
  }
  onSettingsChanged: service._applyBootBackgroundOnce()

  Component.onCompleted: {
    console.log("silverstone: Service.qml instantiated")
    Qt.callLater(service.fetchRepoIfUrl)
  }
}
