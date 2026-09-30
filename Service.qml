import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
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
  // Which wallpaper-picker style is on show (1-3) while 0 picks between them.
  property int pickerVersionIntent: 2

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
  // Global "Auto Launch Ask": when on, an empty workspace's panes wait for a
  // Y/N answer instead of launching on focus. A workspace can also ask on
  // its own (wsConfig().autoLaunchAsk); either one is enough. Off by default.
  readonly property bool autoLaunchAsk: settings && settings.autoLaunchAsk === true

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
      autoLaunchAsk: !!w && w.autoLaunchAsk === true,
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
    // mode that ever actively resolves/caches a random pick -- and even then
    // falls back to the theme default rather than blank when nothing's
    // cached yet. randomCache is in-memory only, so it's empty on every
    // restart until a workspace is actually visited or re-randomized; a
    // blank thumbnail in the meantime is exactly the "dark space" this
    // fallback exists to rule out.
    // Omarchy Default mode ignores every workspace setting: the override if
    // there is one, else the system/theme background.
    if (!service.masterEnabled) return service.globalOverride || service.themeBackground
    var cfg = service.wsConfig(id)
    if (cfg.background.mode === "custom" && cfg.background.path) return cfg.background.path
    if (service.masterEnabled && cfg.background.mode === "random") return service.randomCache[String(id)] || service.themeBackground
    return service.themeBackground
  }

  function workspaceById(id) {
    var vs = Hyprland.workspaces.values
    for (var i = 0; i < vs.length; i++) if (vs[i].id === id) return vs[i]
    return null
  }

  // ---- live background tracking ---------------------------------------

  Process {
    id: readThemeBg
    command: ["readlink", "-f", service.home + "/.local/state/omarchy/current/background"]
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
        }
        if (service._randomProcApply) service.setInstant(pick || service.themeBackground)
      }
    }
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
    if (!service.masterEnabled) { service.setInstant(service.globalOverride || service.themeBackground); return }
    var cfg = service.wsConfig(id)
    if (cfg.background.mode === "custom" && cfg.background.path) { service.setInstant(cfg.background.path); return }
    if (service.masterEnabled && cfg.background.mode === "random") { service.resolveRandom(id, false); return }
    service.setInstant(service.themeBackground)  // "default" (or Omarchy Default mode): live-mirror
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

  onPoolFolderRawChanged: service.fetchRepoIfUrl()

  // ---- auto-launch -----------------------------------------------------

  readonly property string scriptPath: {
    var u = Qt.resolvedUrl("scripts/workspace-autolaunch.sh").toString()
    return decodeURIComponent(u.replace(/^file:\/\//, ""))
  }

  // Workspace id currently waiting on the Y/N prompt (LaunchPrompt.qml);
  // 0 = no prompt showing. Lives here, not in Panel.qml, because a settings
  // write recreates the panel and the prompt has to survive that.
  property int askingWs: 0

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

  function maybeAutoLaunch(id) {
    if (!service.launchablePanes(id)) return
    // ASK IS OFF (0: "1 off", answering whether the Y/N prompt should survive
    // the hard rule). The rule is: focus an EMPTY workspace and its launchers
    // fire; focus one with anything on it and NOTHING happens. A prompt window
    // on focus is something happening, so it never opens. The prompt itself
    // (LaunchPrompt.qml) and the two `autoLaunchAsk` settings are left in
    // place but dormant -- nothing reads them to decide any more.
    var ask = false
    console.log("silverstone: workspace " + id + " is empty with panes to launch, ask=" + ask)
    if (ask) {
      service.askingWs = id
      return
    }
    service.launchWorkspace(id)
  }

  function launchWorkspace(id) {
    var active = service.launchablePanes(id)  // re-check: config/windows may have changed while the prompt was up
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

  // The prompt's answer. "just go without goodness" (no) simply drops it;
  // the workspace is asked again the next time it's focused while empty.
  function answerLaunch(yes) {
    var id = service.askingWs
    service.askingWs = 0
    if (yes) service.launchWorkspace(id)
  }

  // "default" checkbox on the Custom Actions tile (Panel.startupCustom): once
  // per shell start, if it's ticked and the saved mode isn't Custom, switch
  // to Custom. Runs when BarWidget installs writeSettings (right after it
  // pushes settings), gated so later re-pushes never re-apply it.
  // Set the first time a randomize control is used in Custom mode; the panel
  // then shows "Change Again" on it. Lives here because every shuffle writes
  // settings, which rebuilds the panel. Cleared by Panel.onOpenedChanged when
  // the panel is closed -- one panel-open is one "session".
  property bool randomizedOnce: false

  // Walkthru audit tags on every control. Default OFF -- 0 turns them on only
  // for an audit chunk and wants them gone otherwise. Lives here so it survives
  // the panel rebuild every settings write causes. Flip with the debug IPC
  // `debugAuditTags true|false`.
  property bool auditTags: false

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

  // "turn the nag off": clears THIS workspace's own Ask (never the global one),
  // then launches this time. Service only reads settings, so the write goes
  // through `writeSettings`, which BarWidget (the one thing with shell access
  // for the plugin's whole life) installs alongside `settings`.
  property var writeSettings: null
  function turnOffAskAndLaunch() {
    var id = service.askingWs
    service.askingWs = 0
    if (id < 1) return
    if (service.writeSettings) {
      var next = JSON.parse(JSON.stringify(service.settings || {}))
      var cfg = service.wsConfig(id)
      if (!next.workspaces) next.workspaces = {}
      var w = next.workspaces[String(id)] || {}
      w.background = w.background || { mode: cfg.background.mode, path: cfg.background.path, poolFolder: cfg.background.poolFolder }
      w.panes = w.panes || cfg.panes
      w.autoLaunchEnabled = cfg.autoLaunchEnabled
      w.autoLaunchAsk = false
      next.workspaces[String(id)] = w
      service.writeSettings(next)
    }
    service.launchWorkspace(id)
  }

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

  // The prompt is only meaningful for the workspace it was raised on, and
  // only while that workspace is still empty -- drop it if focus moves on or
  // a window shows up (checked shortly after the openwindow event, once the
  // toplevel model has caught up).
  Timer {
    id: askRecheck
    interval: 200
    onTriggered: {
      if (service.askingWs === 0) return
      var ws = service.workspaceById(service.askingWs)
      if (!ws || ws.toplevels.values.length !== 0) service.askingWs = 0
    }
  }
  onAutoLaunchEnabledChanged: if (!service.autoLaunchEnabled) service.askingWs = 0

  readonly property var promptScreen: {
    var m = Hyprland.focusedMonitor
    var ss = Quickshell.screens
    for (var i = 0; i < ss.length; i++) if (m && ss[i].name === m.name) return ss[i]
    return ss.length ? ss[0] : null
  }

  LaunchPrompt {
    workspaceId: service.askingWs
    canTurnOff: !service.autoLaunchAsk
    screen: service.promptScreen
    onAnswered: function(launch) { service.answerLaunch(launch) }
    onTurnOffRequested: service.turnOffAskAndLaunch()
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
    if (service.askingWs !== 0) askRecheck.restart()
    var parts = event.parse ? event.parse(4) : String(event && event.data ? event.data : "").split(",")
    if (String(parts[2] || "") === "org.omarchy.screensaver") service.screensaverActivated()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { service.handleHyprlandEvent(event) }
  }

  onFocusedIdChanged: {
    if (service.askingWs !== 0 && service.askingWs !== focusedId) service.askingWs = 0
    evaluateWorkspace(focusedId)
  }
  // Apply immediately on a mode switch, not just on the next focus change.
  onMasterEnabledChanged: applyBackground(service.focusedId)
  onGlobalOverrideChanged: if (!service.masterEnabled) applyBackground(service.focusedId)
  Component.onCompleted: {
    console.log("silverstone: Service.qml instantiated")
    // Handle the case of a cold shell start landing directly on a configured
    // workspace, where onFocusedIdChanged never fires because nothing changed.
    Qt.callLater(function() { evaluateWorkspace(service.focusedId) })
    Qt.callLater(service.fetchRepoIfUrl)
  }
}
