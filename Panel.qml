import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// SilverStone's popout: a compact strip of thumbnail+number cards (one per
// workspace, all ten visible at once) plus the master switch, docked to the
// right edge of the screen. Clicking a card swaps the strip for a second,
// also right-docked dialog with that workspace's full controls -- only one
// of the two is ever visible at a time. Both stay open until the bar icon
// is toggled off again, which also collapses any open dialog.
//
// Both surfaces use on-demand keyboard focus and an input mask covering only
// their own visible card -- Chad wants this to behave like a HUD, not a
// modal: it must not steal focus from whatever he's typing into, and clicks
// outside the card should reach the window underneath rather than being
// swallowed. That's also why neither surface reuses the shared
// KeyboardPanel.qml base (which deliberately grabs keyboard focus and
// dismisses on outside click for panels that need arrow-key navigation --
// the opposite of what's wanted here).
//
// All writes happen here (never in Service.qml) via shell.updateEntryInline
// -- Service.qml only reads.
Panel {
  id: root
  moduleName: "chad.silverstone"
  ipcTarget: "chad.silverstone"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Defaults to Omarchy Default (false) the very first time this ever runs,
  // with no "enabled" key saved yet -- SilverStone Custom only turns on once
  // the user actually picks it, and after that the saved value just
  // persists across restarts like everything else here.
  readonly property bool masterEnabled: settings && settings.enabled === true
  // This plugin only ever docks top/bottom (see stripWin.barAtBottom), so
  // the bar's own thickness is always its horizontal-orientation size --
  // used to keep the strip/dialog clear of the real bar instead of
  // overlapping it.
  readonly property real barThickness: Style.bar.sizeHorizontal

  // Panel CONTENT colour. The base's `barForeground` is the BAR's own
  // foreground: with a transparent bar it becomes a wallpaper-adaptive tone
  // (Bar.qml `useTransparentForeground`), which is right on the bar and wrong
  // inside a popup. 0's bar IS transparent, so every built-in panel was
  // drawing its content in the theme foreground while Wpal drifted with the
  // wallpaper (0: "Match the font size and Color on Wpal to the other
  // plugins"). Same definition the built-ins use for `contentForeground`.
  readonly property color contentForeground: root.bar ? root.bar.foreground : Color.foreground
  // Independent of wallpaper mode above -- a global kill switch for every
  // workspace's auto-launch panes, without discarding what's configured.
  readonly property bool autoLaunchEnabled: settings && settings.autoLaunchEnabled !== false
  // After the first randomize this shell run, the randomize control reads
  // "Change Again" (see the Randomize row) -- in both modes, on the panel
  // row and in li (one shared flag).
  readonly property bool randomizedOnce: root.service ? root.service.randomizedOnce === true : false
  readonly property bool randomizeRevealed: root.service ? root.service.randomizeRevealed === true : false
  readonly property bool randomizeArmed: root.service ? root.service.randomizeArmed === true : false
  // "default" checkbox on the Custom Actions tile: when on, the shell starts
  // in Custom (SS-Behaviour) regardless of the mode saved last -- applied once
  // per shell start by Service.applyStartupMode.
  readonly property bool startupCustom: settings && settings.startupCustom === true
  // Raw setting for display/editing in the config card (empty, a folder
  // path, or an http(s) URL); poolFolder is the resolved folder actually used
  // to randomize from -- see Model.resolveWallpaperFolder. The
  // `wallpaperRepository` half of the read is the pre-rename key, kept only
  // as a fallback for a failed migration write (Model.migrateSettings).
  readonly property string poolFolderRaw: (settings && settings.poolFolder !== undefined)
    ? settings.poolFolder
    : ((settings && settings.wallpaperRepository) || "")
  readonly property string poolFolder: Model.resolveWallpaperFolder(root.poolFolderRaw, Quickshell.env("HOME"))

  // Which dialog is open: -1 none, 0 the overall config dialog, 1-10 a
  // workspace's customize dialog.
  property int activeWorkspace: -1

  // Vertical midpoint of whichever card was clicked, in stripWin's content
  // coordinates -- which is also dialogWin's content coordinates, since both
  // windows fully overlay the same screen with no offset (see dialogFrame's
  // positioning below). Lets the dialog open beside the row that opened it
  // instead of centered on screen.
  property real dialogAnchorY: 0

  // Every way into li comes through here, so this is where Global settings
  // gets closed. They are never open at the same time (0: "if a line item
  // gets clicked, global settings closes"), and no future caller has to
  // remember to do it.
  function openWorkspace(id, y) {
    activeWorkspace = id
    if (y !== undefined) root.dialogAnchorY = y
    // The global pool picker is a popup now; opening a workspace drops it.
    if (root.pendingBrowse && root.pendingBrowse.kind === "pool") root.cancelBrowse()
    // Opening a different workspace starts clean: no stale launcher editor or
    // Clone panel from the last one.
    root.cloneDialogOpen = false
    workspaceContent.expandedSlot = -1
  }

  // Fixed width for the strip's always-visible mode row and (when
  // SilverStone Custom is on) the wallpaper-pool/auto-launch block beneath
  // it -- narrower than the old standalone Settings dialog (320) since this
  // now lives inline in the strip and Chad wants it kept compact.
  // Widened back from 160: narrower text wraps onto more lines, which
  // inflates the strip's total content height and pushes it toward (or
  // past) getting clipped against the screen -- fitting fully on screen
  // matters more than being as thin as possible.
  // Custom mode lays the ten cards out in two columns (1-5 | 6-0) and sizes
  // the panel from the screen height so the cards keep their natural 56:38
  // ratio and all fit without scrolling. The two square mode tiles are as
  // wide as one card column (minus glow room), so they take up vertical
  // space too: cardsOtherOverhead is everything above the card list EXCEPT
  // those tiles (title, global auto launch, wallpaper pool block,
  // separators) -- tune it if that block grows. Solving
  //   colW = cardW + numberW, 5 cardH + tile = avail, tile ~ colW
  // gives the closed form below.
  // NOTE: the height budget below still subtracts the OLD lg gutter even
  // though the columns are on sm now. That is deliberate: feeding the freed
  // height back in would just make the cards bigger and leave the panel the
  // same size, and 0 asked for a tighter PANEL (0: "tighten the panel as you
  // can"). Keeping the old figure turns the saving into lost height instead.
  readonly property real cardsOtherOverhead: Style.space(192)
  readonly property real modeGlowPad: Style.space(8)
  readonly property real cardAvail: Math.max(Style.space(160),
    stripWin.screenH - Style.gapsOut * 2 - root.barThickness - Style.spacing.panelPadding * 2
      - Style.spacing.lg * 4 - root.cardsOtherOverhead)
  readonly property real cardColK: 56 / 38 / 5
  // Widest column the screen HEIGHT allows (all ten cards fit without
  // scrolling) -- the old panel width. 0 wants the panel narrower than that,
  // so twoColColW is capped to panelTargetWidth; the height fit still wins on
  // a short screen.
  readonly property real twoColColWFit: Math.round((root.cardAvail * root.cardColK + Style.space(24)) / (1 + root.cardColK))
  readonly property real panelTargetWidth: Style.space(320)
  readonly property real twoColColW: Math.min(root.twoColColWFit, Math.floor((root.panelTargetWidth - Style.spacing.controlGap) / 2))
  // Same width in both modes so switching never resizes the panel.
  readonly property real settingsWidth: Math.max(Style.space(200), twoColColW * 2 + Style.spacing.controlGap)
  // Square mode tiles, still separate, spaced with equal gaps left / between /
  // right (which also leaves room for the glow). They used to fill a whole
  // card column (twoColColW - modeGlowPad); the padding around their two-line
  // label is now halved: side = label height + half the old padding. Panel
  // width and card size are still derived from the full-column figure above,
  // so shrinking the tiles only makes the panel a little shorter.
  FontMetrics { id: modeLabelMetrics; font.family: Style.font.family; font.pixelSize: Style.font.body }
  readonly property real modeTileFullSize: root.twoColColWFit - root.modeGlowPad
  readonly property real modeLabelHeight: modeLabelMetrics.height * 4
  // The tiles are pills now (0: "change the mode buttons to 'Omarchy' and
  // 'SilverStone Wpal' pill them so they fill") -- one line of label plus
  // padding, splitting the row's full width between them instead of two
  // centered squares. The width math above is deliberately left alone: it
  // still solves against the old full-column square, so the panel keeps its
  // width and simply gets shorter.
  readonly property real modeTileHeight: Math.round(modeLabelMetrics.height + Style.spacing.sm * 2)

  // Global settings sits behind the "..." under the SilverStone pill, in
  // The current Omarchy theme's own green (colors.toml `green`), for the
  // Omarchy tile's hover pulse; the fallback is only used until it loads.
  property color themeGreen: "#9ece6a"
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var m = /^\s*green\s*=\s*"(#[0-9a-fA-F]{6})"/m.exec(text())
      if (m) root.themeGreen = m[1]
    }
  }

  // Image count of the wallpaper pool (same extensions the randomizer scans),
  // shown as "(N available)" next to the Randomize row. Custom mode uses the
  // resolved pool; Omarchy Default always uses the theme's own backgrounds.
  FolderListModel {
    id: poolModel
    folder: Util.fileUrl(root.masterEnabled ? root.poolFolder : Model.defaultWallpapersDir(Quickshell.env("HOME")))
    showDirs: false
    showDotAndDotDot: false
    caseSensitive: false
    nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp", "*.bmp", "*.gif"]
  }

  // Mirror into the kept service the same way `opened`/panelOpenIntent do,
  // below -- so picking an image/folder (any settings write recreates this
  // Panel instance) reopens on the same dialog instead of silently closing.
  onActiveWorkspaceChanged: if (root.service) root.service.activeWorkspaceIntent = activeWorkspace
  onDialogAnchorYChanged: if (root.service) root.service.dialogAnchorYIntent = dialogAnchorY

  // viaEscape: when Escape closed the dialog (rather than its own close
  // button or the picker), prime the strip's keyboard focus so a second
  // Escape -- now landing on the strip -- closes the whole panel. Ordinary
  // mouse-driven closes never touch focus, keeping the strip's "never steal
  // focus" behavior for the common click-through flow.
  function closeDialog(viaEscape) {
    activeWorkspace = -1
    // Clear the mirrored intent too, or the next rebuild restores it and a
    // card stays marked as "being edited" with no editor open (0: "one is
    // always bordered, make it stop").
    if (root.service) {
      root.service.activeWorkspaceIntent = -1
      root.service.expandedSlotIntent = -1
      root.service.cloneOpenIntent = false
    }
    // li's two side panels belong to li: neither should outlive it.
    root.cloneDialogOpen = false
    workspaceContent.expandedSlot = -1
    if (viaEscape) root.primeStripEscape()
  }

  // Closing the Pane config panel, from Save, Enter, Escape or an outside
  // click. A
  // slot left with nothing in it is removed outright, so the launcher count
  // drops back and "+" is what adds it again (0). Focus returns to li, which
  // is what the next Escape should act on.
  function closeLauncherPanel() {
    var idx = workspaceContent.expandedSlot
    if (idx >= 0 && !workspaceContent.paneHasData(idx)) workspaceContent.removePane(idx)
    workspaceContent.expandedSlot = -1
    Qt.callLater(function() { dialogFrame.forceActiveFocus() })
  }

  // Save's own close. It judges "was anything set?" from the values Save
  // just committed rather than from root.cfg -- see AutoLaunchConfig's
  // saveRequested. Reading cfg here is what made Save look like it did
  // nothing: the slot was removed a frame before its own write arrived.
  function finishLauncherEdit(appId, args) {
    var idx = workspaceContent.expandedSlot
    if (idx >= 0 && appId === "" && String(args).trim() === "")
      workspaceContent.removePane(idx)
    workspaceContent.expandedSlot = -1
    if (root.service) root.service.expandedSlotIntent = -1
    Qt.callLater(function() { dialogFrame.forceActiveFocus() })
  }

  function closeClonePanel() {
    root.cloneDialogOpen = false
    Qt.callLater(function() { dialogFrame.forceActiveFocus() })
  }

  // The Escape that closes li also reaches the strip the moment the strip
  // takes keyboard focus, which closed li AND the whole panel on one press.
  // The strip ignores Escape until this passes, so the cascade really is one
  // level per press: Pane config -> li -> panel (0's sequence).
  property double escapeGuardUntil: 0

  function primeStripEscape() {
    root.escapeGuardUntil = Date.now() + 400
    stripWin.primeFocus()
  }

  // ---- keyboard navigation ------------------------------------------
  //
  // Every built-in panel is arrow-drivable (Ui/PanelKeyCatcher.qml); this one
  // was mouse-only. The ten cards are laid out in two columns, 1-5 then 6-10,
  // so Up/Down walks a column and Left/Right crosses between them. Running
  // off the outer edge hands over to the next bar panel, which is what the
  // built-ins do.
  //
  // 0 = no cursor. It only appears once a key is pressed, so opening with the
  // mouse doesn't plant a highlight nobody asked for.
  property int cursorWs: 0

  readonly property bool cursorActive: root.masterEnabled && root.cursorWs >= 1 && root.cursorWs <= 10

  function moveCursor(dx, dy) {
    if (!root.masterEnabled) return
    if (root.cursorWs < 1) { root.cursorWs = 1; return }
    // Column 0 holds 1-5, column 1 holds 6-10.
    var col = root.cursorWs <= 5 ? 0 : 1
    var rowIdx = root.cursorWs - (col === 0 ? 1 : 6)
    if (dy !== 0) rowIdx = Math.max(0, Math.min(4, rowIdx + dy))
    if (dx !== 0) {
      var next = col + dx
      if (next < 0 || next > 1) { root.switchPanel(dx); return }
      col = next
    }
    root.cursorWs = (col === 0 ? 1 : 6) + rowIdx
  }

  // Hand off to the neighbouring panel on the bar. The coordinator matches on
  // the item mounted in the bar slot -- the BAR WIDGET -- so barIdentity is
  // what goes in, not this panel (Ui/Panel.qml's own helper passes the panel
  // and would never match).
  function switchPanel(dx) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      root.bar.switchPanelFrom(root.barIdentity, dx > 0 ? 1 : -1)
  }

  function activateCursor() {
    if (!root.cursorActive) return
    root.openWorkspace(root.cursorWs, root.dialogAnchorY)
  }

  // ---- which way the children unfold ---------------------------------
  //
  // The strip opens under its bar icon. If that icon sits on the LEFT half of
  // the bar, li and everything hanging off it must unfold to the RIGHT, toward
  // the centre (0: "if the plugin is placed on the left side of the bar,
  // mirror its children to the right twords the centre") -- otherwise they
  // march off the edge of the screen.
  readonly property bool openRight:
    (stripWin.anchorScreenPos.x + stripWin.anchorW / 2) < (stripWin.screenW / 2)

  // Place a child beside a reference rect, on the unfolding side, ALWAYS
  // clamped inside the screen. The clamp is the other half of the fix: the
  // picker had none and simply ran off the left edge once li was far enough
  // over (0: "wallpaper picker is broken").
  function besideX(refX, refW, w) {
    var want = root.openRight ? (refX + refW + Style.gapsOut)
                              : (refX - w - Style.gapsOut)
    var maxX = Math.max(Style.gapsOut, dialogWin.screenW - w - Style.gapsOut)
    return Math.round(Math.max(Style.gapsOut, Math.min(want, maxX)))
  }

  // What an outside click does, wherever it lands: the same single step back
  // that Escape takes, so a click and a keypress never disagree about what
  // "back" means. Used by the strip's own dismiss area and by the twin
  // surfaces on every other monitor.
  // Anything of ours layered over the strip: picker, li, or either of li's
  // own side panels.
  readonly property bool anyChildOpen: root.pendingBrowse !== null
    || workspaceContent.expandedSlot >= 0 || root.cloneDialogOpen || root.activeWorkspace >= 0

  function dismissOneLevel() {
    if (root.pendingBrowse !== null || workspaceContent.expandedSlot >= 0
        || root.cloneDialogOpen || root.activeWorkspace >= 0) {
      root.escapePressed()
      return
    }
    root.close()
  }

  // Escape cascades one level at a time: browse picker, then dialog, then
  // (via primeStripEscape above) the whole panel -- never all at once, that
  // is what the toggle button is for.
  function escapePressed() {
    if (root.pendingBrowse) { root.cancelBrowse(true); return }
    // li's side panels are layers over it: Escape peels them off first, the
    // launcher editor before Clone (it's the one being typed into), handing
    // focus back to li each time so the next Escape lands there (0: "esc
    // closes it as well, puts focus on the li editor esc again closes it and
    // puts focus on the main panel, esc again closes it as well").
    if (workspaceContent.expandedSlot >= 0) { root.closeLauncherPanel(); return }
    if (root.cloneDialogOpen) { root.closeClonePanel(); return }
    if (root.activeWorkspace >= 0) { root.closeDialog(true); return }
  }

  // The live service, for read-only preview data (current wallpaper per
  // workspace, cached random picks) and to trigger an immediate reroll.
  // Not used for writes -- those always go through updateWorkspace below.
  //
  // Not a plain binding: serviceFor() is an ordinary function call, not a
  // bindable property read, so QML has no way to notice when the service
  // singleton comes up after this expression already evaluated once. A
  // settings write the bar host can't patch in place destroys and recreates
  // this panel instance (see onOpenedChanged below) -- if serviceFor() still
  // returns null at the instant the fresh instance evaluates this, the panel
  // never gets a live service reference again and panelOpenIntent below never
  // fires, leaving the panel invisible until manually reopened. serviceRetryTimer
  // polls at 150ms until it succeeds, then stops -- self-healing regardless of
  // which side wins the race.
  property var service: null
  function refreshService() {
    root.service = (root.bar && root.bar.shell) ? root.bar.shell.serviceFor(root.moduleName) : null
  }
  Component.onCompleted: root.refreshService()
  onBarChanged: root.refreshService()
  Timer {
    id: serviceRetryTimer
    interval: 150
    repeat: true
    running: !root.service
    onTriggered: root.refreshService()
  }

  // Keep the service's open-intent in sync with reality, and restore it the
  // moment a fresh instance gets a service reference -- a settings write the
  // bar host can't patch in place destroys and recreates the bar-widget/
  // panel instance, but the service (a kept instance) survives that.
  onOpenedChanged: {
    root.refreshService()
    if (root.service) root.service.panelOpenIntent = root.opened
    // Pressing the bar glyph while anything of ours is open shuts the lot and
    // resets to first-open state -- no picker, no li, no launcher editor, no
    // Clone waiting to reappear on the next press (0: "close the plugin and
    // reset it to a fresh state, dont keep open child windows on a re press").
    // closeDialog() clears li and its intents; the browse is ours to drop.
    if (!root.opened) { root.pendingBrowse = null; root.closeDialog() }
    // A "session" for Change Again is one panel-open: closing ends it. (A
    // settings write rebuilds the panel but keeps panelOpenIntent, so a shuffle
    // never counts as a close.)
    if (!root.opened && root.service) root.service.randomizedOnce = false
    // Same session rule as randomizeRevealed: the clone line stays drawn
    // until the panel closes, then starts clean.
    // The clone line's run is scoped to ONE panel-open (0: "no, it dies when
    // the panel does"). It runs once while the panel is up and the finished
    // line stays for as long as it is up; closing the panel spends it, and the
    // next open starts clean.
    if (!root.opened && root.service) root.service.cloneRevealed = false
    if (!root.opened) root.cursorWs = 0

    // Join the bar's one-popout-at-a-time model, like every built-in panel
    // (0 asked for it). The key is barIdentity -- the BAR WIDGET, not this
    // nested panel: the coordinator, the open-panel dot under the pill and
    // switchPanelFrom all identify a panel by the item mounted in the slot.
    // requestPopout closes whoever held it via closeForPopoutSwitch, which
    // BarWidget already forwards to us; we simply never registered before,
    // so Wpal and a built-in could sit open on top of each other.
    if (root.bar) {
      if (root.opened) root.bar.requestPopout(root.barIdentity)
      else if (root.bar.activePopout === root.barIdentity) root.bar.releasePopout(root.barIdentity)
    }
  }
  onServiceChanged: {
    if (root.service && root.service.panelOpenIntent && !root.opened) root.open()
    if (root.service && root.service.activeWorkspaceIntent !== -1) {
      root.activeWorkspace = root.service.activeWorkspaceIntent
      root.dialogAnchorY = root.service.dialogAnchorYIntent
      // ...including whichever child panel was open, so an edit's own
      // settings write doesn't close the editor out from under the next one.
      root.cloneDialogOpen = root.service.cloneOpenIntent
      workspaceContent.expandedSlot = root.service.expandedSlotIntent
    }
  }

  // Close quietly the moment the screensaver comes up, rather than leaving
  // the strip/dialog sitting open on top of (or behind) it.
  Connections {
    target: root.service
    function onScreensaverActivated() { root.close() }
  }

  // Normalized per-workspace config, matching Service.qml's shape.
  function wsSetting(id) {
    var w = (settings && settings.workspaces) ? settings.workspaces[String(id)] : null
    var bg = (w && w.background) || {}
    var panesRaw = w && w.panes
    return {
      background: Model.normalizeBackground(bg, root.poolFolder),
      panes: Model.normalizePanes(panesRaw ? JSON.parse(JSON.stringify(panesRaw)) : null),
      // Per-workspace pause, independent of the global kill switch --
      // temporarily stops this one workspace's panes from auto-launching
      // without touching what's configured (see Service.qml's
      // maybeAutoLaunch, which checks this after the global switch).
      autoLaunchEnabled: !w || w.autoLaunchEnabled !== false,
      // Which tiling option (Model.launchLayouts) the auto-launched windows use.
      launchLayout: (w && w.launchLayout) | 0,
      // Which configured slot (if any) opens full screen. -1 = none. Only
      // meaningful at 2+ configured launchers (a single one already fills
      // the workspace on its own). Remapped alongside the panes above, so it
      // still points at the same launcher after any empty slots are dropped.
      fullScreenIndex: Model.normalizeFullScreenIndex(
        panesRaw ? JSON.parse(JSON.stringify(panesRaw)) : null,
        (w && typeof w.fullScreenIndex === "number") ? w.fullScreenIndex : -1)
    }
  }

  // Windows that will auto-launch on a workspace right now: 0 unless Custom
  // mode, the global Auto Launch and this workspace's own are all on.
  function launchCountFor(id) {
    if (!root.masterEnabled || !root.autoLaunchEnabled) return 0
    var cfg = root.wsSetting(id)
    return cfg.autoLaunchEnabled ? Model.configuredCount(cfg.panes) : 0
  }

  // Tile rects for that workspace's chosen layout, [] when under 2 windows.
  // Counts what's CONFIGURED, not what's live: a workspace with Auto Launch
  // ticked off still shows its grid on the card, just in the disabled hue
  // (0: "it should cascade to the ones in the main panel when checked on and
  // off"). Omarchy Default's lone card has no per-workspace config to show,
  // so it stays bare.
  function launchRectsFor(id) {
    if (!root.masterEnabled) return []
    var n = Model.configuredCount(root.wsSetting(id).panes)
    if (n < 2) return []
    return Model.launchLayouts(n)[Model.launchLayoutIndex(n, root.wsSetting(id).launchLayout)].rects
  }

  // Whether that workspace's launchers would actually fire -- drives the
  // overlay hue on its card, not whether the overlay shows at all.
  function launchEnabledFor(id) {
    return root.masterEnabled && root.autoLaunchEnabled && root.wsSetting(id).autoLaunchEnabled
  }

  // That workspace's full-screen pick, saved for real now -- gated on how
  // many launchers are CONFIGURED (Model.configuredCount), not
  // launchCountFor's live-eligible count: this also has to read correctly
  // for the disabled-workspace hover list, where launchCountFor is always 0
  // by design.
  function launchFsIndexFor(id) {
    var cfg = root.wsSetting(id)
    // ONE launcher is enough, matching li's own fsEligible (0: "a single AL
    // should still show the Full screen option"). The old `< 2` gate meant a
    // single-launcher workspace could press the toggle, save the pick, and
    // read it straight back as -1 -- the glyph never stayed lit and the
    // launch never went full screen.
    if (Model.configuredCount(cfg.panes) < 1) return -1
    return cfg.fullScreenIndex
  }

  // Short hover-preview text for a workspace card -- what its dialog would
  // show, without opening it.
  function workspaceSummary(id) {
    var bg = root.wsSetting(id).background
    if (bg.mode === "custom") return "Custom: " + (bg.path ? bg.path.split("/").pop() : "(no image set)")
    if (bg.mode === "random") return "Random from: " + (bg.poolFolder ? bg.poolFolder.split("/").pop() : "")
    return "Default (theme Background)"
  }

  function updateWorkspace(id, patch) {
    var next = Util.cloneJson(root.settings || {})
    if (!Util.isPlainObject(next.workspaces)) next.workspaces = {}
    var cur = wsSetting(id)
    var merged = {
      background: Object.assign({}, cur.background, patch.background || {}),
      panes: patch.panes !== undefined ? patch.panes : cur.panes,
      autoLaunchEnabled: patch.autoLaunchEnabled !== undefined ? patch.autoLaunchEnabled : cur.autoLaunchEnabled,
      launchLayout: patch.launchLayout !== undefined ? patch.launchLayout : cur.launchLayout,
      fullScreenIndex: patch.fullScreenIndex !== undefined ? patch.fullScreenIndex : cur.fullScreenIndex
    }
    next.workspaces[String(id)] = merged
    // Customizing a workspace while "Omarchy Default" is active is a silent
    // trap: the edit saves fine, but neither the thumbnail nor the live
    // wallpaper can show it until SilverStone mode is on, which looks like
    // the picker/pane editor is just broken. Auto-switch modes right here,
    // in the same settings write, instead of letting someone hit that twice.
    if (!root.masterEnabled) next.enabled = true
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
    // The settings write above updates what previewFor()/the card thumbnail
    // show (they just read settings), but nothing else re-applies the live
    // desktop wallpaper -- that normally only happens on a focus change. If
    // the workspace just edited is the one currently on screen, push it live
    // immediately instead of leaving the old wallpaper up until the next
    // focus change.
    if (patch.background !== undefined && root.service && id === root.service.focusedId) {
      root.service.applyBackground(id)
    }
  }

  // "Clone this Workspace": copies one workspace's whole config (wallpaper
  // source + picks, launchers, Auto Launch pause) onto each target, in ONE
  // settings write -- separate updateWorkspace calls would each rebuild the
  // panel. The source is never a target.
  function cloneWorkspace(fromId, targets) {
    var next = Util.cloneJson(root.settings || {})
    if (!Util.isPlainObject(next.workspaces)) next.workspaces = {}
    var src = JSON.parse(JSON.stringify(root.wsSetting(fromId)))
    var done = []
    for (var i = 0; i < targets.length; i++) {
      var t = Number(targets[i])
      if (t === fromId || t < 1 || t > 10 || done.indexOf(t) >= 0) continue
      next.workspaces[String(t)] = JSON.parse(JSON.stringify(src))
      done.push(t)
    }
    if (done.length === 0) return
    // Same silent-trap guard as updateWorkspace: clones can't show in Omarchy Default.
    if (!root.masterEnabled) next.enabled = true
    root.cloneDialogOpen = false
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
    // The settings carry the pool; this carries the actual PICTURE, so the
    // clone shows what was cloned instead of its own random pick.
    if (root.service) root.service.mirrorRandomPick(fromId, done)
    if (root.service && done.indexOf(root.service.focusedId) >= 0) root.service.applyBackground(root.service.focusedId)
  }

  // The Clone panel (CloneDialog.qml) opens beside li's arrow button rather
  // than swapping itself in over li's card.
  property bool cloneDialogOpen: false

  // One of li's child panels (Pane config, Clone) is open. Two children can
  // never be open at once -- each opener closes the other -- and while either
  // is up, neither li nor the strip takes clicks (0).
  readonly property bool childPanelOpen: root.activeWorkspace > 0
    && (workspaceContent.expandedSlot >= 0 || root.cloneDialogOpen || root.pendingBrowse !== null)

  // Mirrored into the long-lived Service so a settings write can't lose it.
  onCloneDialogOpenChanged: if (root.service) root.service.cloneOpenIntent = root.cloneDialogOpen

  function setMasterEnabled(v) {
    // Switching modes dismisses whatever picker/dialog is open (e.g. the
    // Omarchy-mode wallpaper picker) -- before the write, since the write
    // recreates this panel and would otherwise restore the stale dialog.
    root.pendingBrowse = null
    root.closeDialog()
    var next = Util.cloneJson(root.settings || {})
    next.enabled = v
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  function setAutoLaunchEnabled(v) {
    var next = Util.cloneJson(root.settings || {})
    next.autoLaunchEnabled = v
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  function setStartupCustom(v) {
    var next = Util.cloneJson(root.settings || {})
    next.startupCustom = v
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  // Sets every workspace to "random" against the shared source folder (or
  // theme defaults, per Model.resolveWallpaperFolder) in one settings write
  // -- ten separate updateWorkspace calls would each trigger their own
  // widget-recreating settings write, flickering the panel ten times over.
  // poolFolder here is each WORKSPACE'S OWN RAW value (0: "setting a custom
  // background pool for a WS in the liE should be persistant... when I set
  // global pool, all wallpapers randomize from the global pool that is set,
  // NOT THE DEFAULT"). This used to hardcode root.poolFolder (the global
  // pool) for all ten -- silently overwrote every custom-pool assignment.
  // Fixed once already by preserving wsSetting()'s poolFolder instead --
  // WRONG, because wsSetting() routes through Model.normalizeBackground,
  // which does `bg.poolFolder || defaultFolder` and so NEVER returns empty.
  // That "fix" was writing back a resolved snapshot for every workspace,
  // every shuffle -- indistinguishable from a real custom pool afterward, so
  // a later change to the GLOBAL pool stopped reaching any workspace that
  // had ever been shuffled once. Reading the RAW stored value here (empty
  // when a workspace was never given its own pool) is what actually keeps
  // "no override" workspaces following the global pool live, forever, while
  // still preserving a genuine override -- matching what CustomizeDialog's
  // own poolOverridden check already treats as the "not customized" sentinel
  // (empty string) everywhere else in this file.
  // The raw stored poolFolder/sourceFolder for one workspace, "" when it has
  // never been given its own pool override -- unlike wsSetting()'s (always
  // resolved, never empty, see the comment above). Shared by
  // randomizeAllWorkspaces() below and by the "Use Global Pool" reset
  // button's visibility (there's nothing to reset to the global pool when
  // this is already empty).
  function wsPoolFolderRaw(id) {
    var rawWs = (root.settings && root.settings.workspaces) ? root.settings.workspaces[String(id)] : null
    var rawBg = (rawWs && rawWs.background) || {}
    return rawBg.poolFolder !== undefined ? rawBg.poolFolder
      : (rawBg.sourceFolder !== undefined ? rawBg.sourceFolder : "")
  }

  function randomizeAllWorkspaces() {
    var next = Util.cloneJson(root.settings || {})
    if (!Util.isPlainObject(next.workspaces)) next.workspaces = {}
    for (var id = 1; id <= 10; id++) {
      var cur = root.wsSetting(id)
      var rawPool = root.wsPoolFolderRaw(id)
      next.workspaces[String(id)] = {
        // path: "", not cur.background.path -- randomizeWorkspace() (the
        // per-workspace reroll) clears it for the same reason: Service's
        // cold-boot fallback in resolveRandom() treats a non-empty path as a
        // trustworthy last-known random pick once randomCache has no entry
        // yet. Carrying a workspace's old CUSTOM path through here let a
        // focus switch during the async reroll window re-apply that stale
        // custom image as if it were a valid random one.
        background: { mode: "random", path: "", poolFolder: rawPool,
          source: "pool", poolPath: "", outsidePath: cur.background.outsidePath },
        panes: cur.panes,
        autoLaunchEnabled: cur.autoLaunchEnabled,
        launchLayout: cur.launchLayout,
        // Carried through like the rest: a wallpaper reroll has no business
        // clearing which launcher opens full screen (it was being dropped).
        fullScreenIndex: cur.fullScreenIndex
      }
    }
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  function shuffleGlobalWallpaper() {
    root.randomizeAllWorkspaces()
    if (root.service) root.service.randomizeAllWorkspacesOnce()
  }

  // Omarchy Default has one wallpaper for the whole desktop: pick a random
  // theme-pool image and save it as the global override (same as the picker).
  function shuffleDefaultWallpaper() {
    var n = poolModel.count
    if (n <= 0) return
    var path = String(poolModel.get(Math.floor(Math.random() * n), "filePath") || "")
    if (path) root.setGlobalOverride(path)
  }

  // True only in the instant after a shuffle. The cards' fade-in cascade is
  // FOR the shuffle; on a mode switch every card is built from scratch and
  // the same onSourceChanged fired, so the whole list dribbled in over two
  // seconds (0: "in were switching from omarchy mode to wpal, no animation,
  // just write them all out at once"). The service outlives the settings
  // write that rebuilds this panel, so the stamp survives to be read here.
  readonly property bool shuffleJustRan: root.service
    && (Date.now() - root.service.shuffleAt) < 1500

  // Omarchy's own background switcher (omarchy-theme-bg-switcher -> the
  // menu-images picker over the theme's backgrounds plus the user's own).
  // Detached: it draws its own window and outlives this panel.
  //
  // 0: "the omarchy wallpaper picker does not change the wallpaper." Root
  // cause: this just fired the external picker and threw away its result --
  // omarchy-theme-bg-switcher only PRINTS the chosen path to stdout, it
  // never applies anything itself (confirmed by reading it: it's a thin
  // wrapper around omarchy-menu-images, which also just prints a selection).
  // Omarchy's own built-in Background plugin wires this exact chain
  // correctly (bgSwitchProc in
  // /usr/share/omarchy/shell/plugins/background/Background.qml): capture
  // the printed path and feed it into omarchy-theme-bg-set, which does the
  // symlink + live-apply IPC. shuffleDefaultWallpaper() above already does
  // the equivalent for the shuffle action ("pick ... and save it as the
  // global override (same as the picker)") -- this was the missing half.
  function openOmarchyBackgroundPicker() {
    root.close()
    omarchyBgPicker.running = true
  }

  Process {
    id: omarchyBgPicker
    command: ["omarchy-theme-bg-switcher"]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(text || "").trim()
        if (path) root.setGlobalOverride(path)
      }
    }
  }

  // Is there a single launcher configured anywhere? Gates the Clear button,
  // so the row only carries it when it would do something.
  readonly property bool anyLaunchersSet: {
    for (var i = 1; i <= 10; i++) {
      if (Model.configuredCount(root.wsSetting(i).panes) > 0) return true
    }
    return false
  }

  // Empties every workspace's panes in ONE settings write -- ten writes would
  // rebuild the panel ten times. Auto Launch's own switches are left alone.
  function clearAllLaunchers() {
    var next = Util.cloneJson(root.settings || {})
    if (!Util.isPlainObject(next.workspaces)) next.workspaces = {}
    for (var i = 1; i <= 10; i++) {
      var key = String(i)
      var cur = root.wsSetting(i)
      next.workspaces[key] = Object.assign({}, cur, { panes: [], fullScreenIndex: -1 })
    }
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  function shuffleWallpaper() {
    if (root.service) root.service.shuffleAt = Date.now()
    if (root.service) root.service.randomizedOnce = true
    if (root.masterEnabled) root.shuffleGlobalWallpaper()
    else root.shuffleDefaultWallpaper()
  }

  // Single-workspace version of shuffleGlobalWallpaper -- CustomizeDialog's
  // "use random from pool" button. Switches just this one workspace to
  // random mode against the shared pool and forces an immediate fresh pick
  // (force: true -- a stale cached pick from before would otherwise win),
  // applying it live only if this workspace is the one currently on screen.
  function randomizeWorkspace(id) {
    if (root.service) root.service.randomizedOnce = true
    // Draws from this workspace's own pool when it has one, else the global.
    root.updateWorkspace(id, { background: { mode: "random", path: "", poolFolder: root.wsPoolFolder(id), source: "pool", poolPath: "" } })
    if (root.service) root.service.resolveRandom(id, true, id === root.service.focusedId)
  }

  // This workspace's own pool if it has one, else the global pool -- what
  // "Set" browses and what a reroll draws from (0: "select a pool just for
  // this workspace ... set opens the folder that the ...").
  function wsPoolFolder(id) {
    var f = root.wsSetting(id).background.poolFolder
    return f ? f : root.poolFolder
  }

  // Trade two launchers' positions on the grid, full-screen pick included
  // (0: "they just replace each other one for one and keep theyre full
  // screen status").
  function swapPanes(id, from, to) {
    var cur = root.wsSetting(id)
    var panes = cur.panes.map(function(p) { return Object.assign({}, p) })
    // A drop onto an EMPTY tile used to fall through here and do nothing at
    // all -- the layout can show four tiles while only two are configured, so
    // `to` was routinely past the end (0: "a click and drag will move swap
    // launch tile positions"). Dropping past the last configured launcher now
    // means "put it last"; the slots stay strictly progressive either way.
    if (from < 0 || to < 0 || from >= panes.length) return
    if (to >= panes.length) to = panes.length - 1
    if (from === to) return
    // The Pane config panel is bound to `expandedSlot`, so a swap made while
    // an editor is open would leave it pointing at the OTHER launcher's slot:
    // the command being edited moves away and Save lands on whatever took its
    // place. Carry the open slot with the pane, the way fullScreenIndex is
    // carried just below.
    var openSlot = workspaceContent.expandedSlot
    if (openSlot === from) workspaceContent.expandedSlot = to
    else if (openSlot === to) workspaceContent.expandedSlot = from
    var tmp = panes[from]
    panes[from] = panes[to]
    panes[to] = tmp
    var fs = cur.fullScreenIndex
    if (fs === from) fs = to
    else if (fs === to) fs = from
    root.updateWorkspace(id, { panes: panes, fullScreenIndex: fs })
  }

  function setPoolFolder(path) {
    var next = Util.cloneJson(root.settings || {})
    next.poolFolder = path
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  function previewFor(id) {
    return root.service ? root.service.previewPath(id) : ""
  }

  // Omarchy Default mode's single wallpaper pick/shuffle is one global
  // override saved on its own key -- never written into the ten Custom
  // workspace configs -- so it survives mode switches. Service applies it
  // live when the setting changes. Set by shuffleDefaultWallpaper() and by
  // openOmarchyBackgroundPicker()'s onStreamFinished; there is currently no
  // UI path that clears it back to following the live theme.
  readonly property string globalOverride: (settings && settings.globalOverride) || ""

  function setGlobalOverride(path) {
    var next = Util.cloneJson(root.settings || {})
    next.globalOverride = path
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  // Local browsing goes through WallpaperPicker.qml's own FolderListModel,
  // never QtQuick.Dialogs' native File/FolderDialog -- that reproducibly
  // crashes the whole Quickshell process on this system (a dconf-worker/GLib
  // heap corruption when the native GTK portal picker opens: "glib/gmem.c:106:
  // failed to allocate 4 bytes", confirmed via two matching coredumps). Typed
  // text in the source field is for http(s) URLs; local paths come from here.
  //
  // kind: "pool" | "wsPool" | "image" (per-workspace specific wallpaper).
  // null when no browse is in progress.
  property var pendingBrowse: null
  // Keyboard focus follows the browse cascade: picker frame while a browse
  // is pending, li's frame once it closes (so a second Escape hits li next,
  // not a now-invisible picker frame still holding focus).
  onPendingBrowseChanged: {
    if (dialogWin.visible) Qt.callLater(function() { (root.pendingBrowse !== null ? pickerFrame : dialogFrame).forceActiveFocus() })
  }

  function beginBrowsePool() {
    pendingBrowse = { kind: "pool" }
    browsePicker.currentPath = ""
    browsePicker.folder = root.poolFolder
  }

  // Folder picker for ONE workspace's pool -- the per-workspace half of the
  // global pool setting, opened from li's "..." settings block.
  function beginBrowseWsPool(id) {
    workspaceContent.expandedSlot = -1
    root.cloneDialogOpen = false
    pendingBrowse = { kind: "wsPool", workspaceId: id }
    browsePicker.currentPath = ""
    browsePicker.folder = root.wsPoolFolder(id)
  }

  // Back to the shared pool for this workspace.
  function clearWsPool(id) {
    root.updateWorkspace(id, { background: { poolFolder: "" } })
  }

  function beginBrowseImage(id, fromPool) {
    // The picker is a child of li like the other two, so it replaces them
    // rather than stacking on top (0: "two children CANNOT BE OPEN").
    workspaceContent.expandedSlot = -1
    root.cloneDialogOpen = false
    pendingBrowse = { kind: "image", workspaceId: id, fromPool: fromPool === true }
    browsePicker.currentPath = root.previewFor(id)
    // This workspace's pool when it has overridden the global one.
    var repo = root.wsPoolFolder(id)
    // "Select Wallpaper From Pool" always opens on the pool itself.
    if (fromPool) { browsePicker.folder = repo; return }
    // "Outside Of Pool": open beside the current outside pick, else one level
    // above the pool (not inside it), never bare $HOME -- $HOME usually has
    // no images in it, so the picker would open onto an empty, useless view.
    var cur = root.wsSetting(id).background.outsidePath
    var lastSlash = cur.lastIndexOf("/")
    var repoParent = repo.charAt(0) === "/" ? repo.substring(0, repo.lastIndexOf("/")) : ""
    browsePicker.folder = lastSlash > 0 ? cur.substring(0, lastSlash) : (repoParent !== "" ? repoParent : repo)
  }

  // viaEscape: the picker was the only thing open, so closing it hands the
  // keyboard straight back to the strip -- and the SAME Escape then closed the
  // whole panel (0: "esc on a GWP falls to all panes closed, it should send
  // focus to the main panel, not close the main panel"). primeStripEscape
  // gives the strip focus behind a 400ms guard, exactly as closing li does; if
  // li is still open underneath, focus goes back to li instead.
  function cancelBrowse(viaEscape) {
    pendingBrowse = null
    if (!viaEscape) return
    if (root.activeWorkspace >= 0)
      Qt.callLater(function() { dialogFrame.forceActiveFocus() })
    else
      root.primeStripEscape()
  }

  function finishBrowse(path) {
    var req = root.pendingBrowse
    root.pendingBrowse = null
    if (!req) return
    if (req.kind === "pool") root.setPoolFolder(path)
    else if (req.kind === "wsPool") root.updateWorkspace(req.workspaceId, { background: { poolFolder: path } })
    else if (req.kind === "image") {
      // The pick goes to whichever row's Select opened the picker, and that
      // row becomes the active source.
      var cur = root.wsSetting(req.workspaceId).background
      var pick = req.fromPool ? { source: "pool", poolPath: path } : { source: "outside", outsidePath: path }
      var eff = Model.effectiveBackground(Object.assign({}, cur, pick))
      root.updateWorkspace(req.workspaceId, { background: Object.assign(pick, eff) })
    }
  }

  // A layer surface only spans ONE output, and the compositor hit-tests the
  // pointer per output -- so the strip's own dismiss area can never see a
  // click on another monitor. Every other screen gets a transparent twin
  // whose only job is to catch that click. Straight out of
  // KeyboardPanel.qml, and it started to matter the day DP-1 was plugged in:
  // until now a click over there dismissed every built-in panel but not this
  // one. Keyboard focus is None -- they must never take focus from the strip
  // when the cursor merely crosses onto their output.
  Variants {
    model: root.opened ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        required property var modelData

        screen: modelData
        // Compared by output NAME: the strip's own screen must be known
        // before any twin maps, or a twin would cover the strip itself.
        visible: root.opened && !!stripWin.screen && modelData.name !== stripWin.screen.name
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "silverstone-dismiss"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: root.dismissOneLevel()
        }
      }
    }
  }

  // ---- the strip: master toggle + ten thumbnail/number cards ---------

  PanelWindow {
    id: stripWin
    // Outlives `opened` by the length of the fade, so the card has something
    // to animate out in (same trick as KeyboardPanel.qml). Keyboard focus and
    // the dismiss area still follow `opened`, never `visible` -- otherwise the
    // user stays locked out for the duration of the fade.
    visible: root.opened || cardFrame.opacity > 0
    screen: root.anchorItem && root.anchorItem.QsWindow ? root.anchorItem.QsWindow.window.screen : null
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "silverstone-strip"
    WlrLayershell.layer: WlrLayer.Overlay
    // Prime with a brief Exclusive pulse on every open, then settle on
    // OnDemand -- the same pattern dialogWin below and the shared
    // KeyboardPanel.qml base use, and the reason every other Omarchy panel
    // closes on Escape (0: "I want it to have the same behaviour to existing
    // plugins"). Without the prime the strip never held keyboard focus unless
    // Escape had just closed li, so Escape on the strip alone did nothing and
    // the ✕ was the only way out. The ✕s are gone now, so Escape and the
    // outside click below ARE the way out -- don't regress this.
    //
    // This does take focus from whatever is being typed into when the panel
    // opens -- the deliberate trade for a keyboard exit, and what every
    // built-in panel already does.
    //
    // OnDemand only KEEPS focus on a layer surface whose input region the
    // pointer is actually inside. That is why the mask below is the whole
    // screen now: with the old card-only mask, focus dropped the instant the
    // prime settled and Escape had nothing to land on. Full-screen mask +
    // OnDemand + outside-click dismissal is the shared KeyboardPanel.qml
    // bargain, and 0 chose it over card-only click-through.
    property bool focusPrimed: false
    WlrLayershell.keyboardFocus: !root.opened
      ? WlrKeyboardFocus.None
      : (focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)

    // Both the open path and primeStripEscape (after Escape closed li) come
    // through here, so there is exactly one way the strip takes focus.
    function primeFocus() {
      stripWin.focusPrimed = false
      stripFocusPrimeTimer.restart()
      Qt.callLater(function() { cardFrame.forceActiveFocus() })
    }

    onVisibleChanged: {
      if (visible) stripWin.primeFocus()
      else {
        stripFocusPrimeTimer.stop()
        stripWin.focusPrimed = false
      }
    }

    // The shared base primes off backingWindowVisible, not visible -- that is
    // the signal that fires once the surface has actually mapped.
    onBackingWindowVisibleChanged: if (backingWindowVisible && root.opened) stripWin.primeFocus()

    Timer {
      id: stripFocusPrimeTimer
      interval: 75
      onTriggered: stripWin.focusPrimed = true
    }

    readonly property string barPos: root.bar ? root.bar.position : "top"
    readonly property bool barAtBottom: barPos === "bottom"
    readonly property real screenH: screen ? screen.height : 0

    // Where the bar button actually sits, so the card can open under it the
    // way every built-in panel does (0: "make it open where it is, like
    // omarchy") instead of being flush to the screen's right edge.
    //
    // mapToItem alone is a one-shot -- TransformWatcher re-evaluates it
    // whenever anything between the bar's contentItem and the button moves
    // or resizes, which is what makes the binding below reactive. Same
    // approach as Ui/KeyboardPanel.qml.
    readonly property var anchorWindow: root.anchorItem && root.anchorItem.QsWindow
      ? root.anchorItem.QsWindow.window : null
    readonly property real barW: anchorWindow ? anchorWindow.width : screenW
    readonly property real barH: anchorWindow ? anchorWindow.height : 0
    readonly property real anchorW: root.anchorItem ? root.anchorItem.width : 0

    TransformWatcher {
      id: anchorWatcher
      a: stripWin.anchorWindow ? stripWin.anchorWindow.contentItem : null
      b: root.anchorItem
    }

    readonly property point anchorScreenPos: {
      anchorWatcher.transform  // reactive dependency, do not remove
      if (!root.anchorItem || !anchorWindow) return Qt.point(0, 0)
      return root.anchorItem.mapToItem(anchorWindow.contentItem, 0, 0)
    }

    // Full height (not just sized to content) -- the visible card below
    // stretches from just clear of the real bar to the bottom of the
    // screen, like a proper docked sidebar rather than a shrink-wrapped
    // floating box.
    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true

    // Whole screen, like KeyboardPanel.qml. Two jobs: it keeps OnDemand
    // keyboard focus alive wherever the pointer is (so Escape always works),
    // and it gives stripDismiss below something to catch outside clicks with.
    // Clicks landing on the bar strip are forwarded to the real bar buttons
    // so switching straight to another bar panel still takes one click.
    readonly property real screenW: screen ? screen.width : 0
    mask: Region {
      width: stripWin.screenW
      height: stripWin.screenH
    }

    // Outside-click dismissal, the same bargain every built-in panel makes
    // (0 chose "full Omarchy parity" over card-only click-through). Declared
    // before cardFrame so the card and its content always get the click
    // first; only what the card doesn't take reaches here.
    //
    // Clicks in the bar strip are forwarded to the real bar buttons instead
    // of just dismissing, so clicking a different bar icon switches straight
    // to that panel in one press -- lifted from KeyboardPanel.qml, which
    // solves exactly this.
    MouseArea {
      id: stripDismiss
      anchors.fill: parent
      enabled: root.opened
      acceptedButtons: Qt.AllButtons
      hoverEnabled: true
      property bool hoveringBar: false
      cursorShape: hoveringBar ? Qt.PointingHandCursor : Qt.ArrowCursor

      readonly property var anchorWindow: stripWin.anchorWindow
      readonly property real barW: stripWin.barW
      readonly property real barH: stripWin.barH
      readonly property real barStrip: {
        if (!root.bar) return 0
        var actual = (stripWin.barPos === "top" || stripWin.barPos === "bottom") ? barH : barW
        return Math.max(root.bar.barSize, actual) + Style.gapsOut
      }

      function inBarRegion(px, py) {
        if (stripWin.barPos === "bottom") return py >= stripWin.screenH - barStrip
        if (stripWin.barPos === "left") return px <= barStrip
        if (stripWin.barPos === "right") return px >= stripWin.screenW - barStrip
        return py <= barStrip
      }

      function barPoint(px, py) {
        if (stripWin.barPos === "bottom") return Qt.point(px, py - (stripWin.screenH - barH))
        if (stripWin.barPos === "right") return Qt.point(px - (stripWin.screenW - barW), py)
        return Qt.point(px, py)
      }

      function pressTargetAt(px, py) {
        if (!anchorWindow || !anchorWindow.contentItem || !root.bar || !root.bar.clickTargets) return null
        var p = barPoint(px, py)
        var targets = root.bar.clickTargets
        for (var i = targets.length - 1; i >= 0; i--) {
          var t = targets[i]
          if (!t || !t.triggerPress || t.visible === false || t.opacity === 0 || !t.mapToItem) continue
          if (root.bar.targetBelongsToWindow && !root.bar.targetBelongsToWindow(t, anchorWindow)) continue
          var pos = anchorWindow.itemPosition(t)
          if (p.x >= pos.x && p.x <= pos.x + t.width && p.y >= pos.y && p.y <= pos.y + t.height) return t
        }
        return null
      }

      onPositionChanged: function(mouse) { hoveringBar = inBarRegion(mouse.x, mouse.y) }
      onExited: hoveringBar = false
      onClicked: function(mouse) {
        if (inBarRegion(mouse.x, mouse.y)) {
          var t = pressTargetAt(mouse.x, mouse.y)
          if (t) { t.triggerPress(mouse.button); return }
        }
        // dialogWin sits above this window and masks its own frames, so a
        // click on li never reaches here; and the strip card's own content
        // (plus its swallow MouseArea) takes clicks on the strip, so picking
        // another workspace card while li is open still just re-targets li.
        root.dismissOneLevel()
      }
    }

    BorderSurface {
      id: cardFrame
      // Every tooltip inside this frame clamps itself to it -- SsToolTip
      // walks up to this objectName (0: "CONSTRAIN ALL HOVERS TO THIER
      // RESPECTIVE PANEL").
      objectName: "ssPanelFrame"
      // Centred under the bar button and clamped inside the screen, exactly
      // the way KeyboardPanel.qml places its card. A vertical bar keeps the
      // old edge placement -- the anchor's x means nothing there, and 0's
      // bar is horizontal.
      x: {
        if (stripWin.barPos === "left") return stripWin.barW + Style.gapsOut
        if (stripWin.barPos === "right") return stripWin.screenW - stripWin.barW - width - Style.gapsOut
        var want = stripWin.anchorScreenPos.x + stripWin.anchorW / 2 - width / 2
        return Math.round(Math.max(Style.gapsOut,
          Math.min(want, stripWin.screenW - width - Style.gapsOut)))
      }
      // Clear the real bar's own thickness on whichever edge it's docked to
      // -- otherwise the strip's overlay layer draws right on top of it.
      readonly property real topClear: Style.gapsOut + (!stripWin.barAtBottom ? root.barThickness : 0)
      readonly property real bottomClear: Style.gapsOut + (stripWin.barAtBottom ? root.barThickness : 0)
      anchors.top: parent.top
      anchors.topMargin: topClear
      // Height computed straight off the screen, not off the window's own
      // (anchor-stretched) height -- the same reliable pattern dialogFrame
      // below already uses for its own screen-relative math. This is what
      // stops the card from running taller than the actual visible screen.
      // Tallest the frame may be (screen minus clearances). The cards are
      // sized from THIS, not from the live frame height, so shrink-wrapping
      // the frame below can't feed back into the card size.
      readonly property real maxHeight: stripWin.screenH - topClear - bottomClear
      // Shrink-wraps the content (no dead space under the cards) but never
      // runs past maxHeight.
      height: Math.min(maxHeight, stripColumn.implicitHeight + Style.spacing.panelPadding * 2)
      width: stripColumn.implicitWidth + Style.spacing.panelPadding * 2
      // Safety net: if content is ever taller than the computed height, it
      // gets clipped at the card's own edge instead of spilling past the
      // screen the way it did before height was screen-relative.
      clip: true
      color: Color.popups.background
      radius: Style.cornerRadius
      // 140ms OutCubic, the same fade every built-in panel uses (0).
      opacity: root.opened ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      focus: true
      Keys.onUpPressed: root.moveCursor(0, -1)
      Keys.onDownPressed: root.moveCursor(0, 1)
      Keys.onLeftPressed: root.moveCursor(-1, 0)
      Keys.onRightPressed: root.moveCursor(1, 0)
      // Card navigation only while the strip is what you are looking at. The
      // strip holds keyboard focus whenever the pointer is over it, so with a
      // child open Return was landing here and toggling li shut instead of
      // reaching the panel being typed into (same trap as Escape).
      Keys.onReturnPressed: if (!root.anyChildOpen) root.activateCursor()
      Keys.onEnterPressed: if (!root.anyChildOpen) root.activateCursor()
      Keys.onEscapePressed: {
        // Not the press that just closed li (see escapeGuardUntil).
        if (Date.now() < root.escapeGuardUntil) return
        // The strip holds keyboard focus whenever the pointer is over it,
        // even with a picker open on top -- so Escape often landed HERE and
        // closed the lot (0: "esc on the WP closes the Whole stach"). Peel
        // one level from the strip too: same cascade, same order, whichever
        // surface the key reaches.
        root.dismissOneLevel()
      }

      // Swallows anything the card's own content didn't take, so a click on
      // the card's padding or background never reaches stripDismiss behind
      // it and closes the panel. z below everything else in the card.
      MouseArea {
        anchors.fill: parent
        z: -1
        acceptedButtons: Qt.AllButtons
      }

      // Content can be taller than the screen-clamped height above (many
      // workspace cards + everything expanded) -- this makes it scroll
      // instead of getting clipped off and lost (clip: true above was only
      // ever a last-resort safety net, not the real fix for that).
      // While one of li's child panels is open, a click on the strip closes
      // it (0: "if I click on a parent panel, it should close a child") --
      // supersedes the old rule where this just ate the click and did
      // nothing ("a user cant click on the main panel if a line item child
      // is open as well"). Declared before the Flickable so it can sit above
      // it, below.
      MouseArea {
        anchors.fill: parent
        z: 10
        visible: root.childPanelOpen
        enabled: root.childPanelOpen
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        onClicked: root.dismissOneLevel()
      }

      Flickable {
        id: stripFlick
        x: Style.spacing.panelPadding
        y: Style.spacing.panelPadding
        width: cardFrame.width - Style.spacing.panelPadding * 2
        height: cardFrame.height - Style.spacing.panelPadding * 2
        contentWidth: stripColumn.implicitWidth
        contentHeight: stripColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

      Column {
        id: stripColumn
        // Double the normal gap here specifically, to visually separate the
        // global config card from the per-workspace list above it.
        // One step tighter between sections, same reason.
        spacing: Style.spacing.sm

        Item {
          width: root.settingsWidth
          implicitHeight: childrenRect.height
          // Tag 1 retired: the title row sits against the frame, so its badge
          // was clipped down to a stray dash above the glyph (0: "above the
          // first glyph theres an artifact lose it"). 1a/1b carry the row.
          RowLayout {
            width: root.settingsWidth
            spacing: Style.spacing.sm

            // Double-sized SilverStone mark left of the title (0: "add a double
            // sizid silverstone icon to beside the main panel title bar on the
            // left"). Same glyph as the bar icon; li and the launcher-config
            // panel carry it too, so every panel title reads the same way.
            Text {
              Layout.alignment: Qt.AlignVCenter
              textFormat: Text.PlainText
              text: ""
              color: root.contentForeground
              font.family: Style.font.family
              font.pixelSize: Math.round(Style.font.body * 2)
            }

            Text {
              textFormat: Text.PlainText
              text: "Wpal"
              color: root.contentForeground
              font.family: Style.font.family
              // Same heading size as li, the picker and the launcher panel (0).
              font.pixelSize: Style.font.heading
              font.bold: true
              Layout.fillWidth: true
            }
          }
        }

        PanelSeparator {
          width: root.settingsWidth
          foreground: root.contentForeground
        }

        // Section title, left-aligned above the buttons (0: "add a Title
        // above left \"Mode\""). PanelSectionHeader is the same component the
        // built-in panels label a section with, so it comes out dimmed and
        // bold at the native size rather than as another big heading.
        PanelSectionHeader {
          text: "Mode"
          // One step up the scale from PanelSectionHeader's caption default
          // (0: "inc font for workspaces and mode +1").
          fontSize: Style.font.bodySmall
          foreground: root.contentForeground
          // below: 1a's own below-badge owns the band above this, and the
          // header is too short for atRight to clear it.
        }

        // Mode buttons: two rounded rects filling the row. Selected one is
        // filled; the other switches modes.
        Item {
          width: root.settingsWidth
          implicitHeight: childrenRect.height
          RowLayout {
            width: root.settingsWidth
            spacing: Style.spacing.sm

            // The shared Ui/Button, configured exactly like the agents
            // panel's provider pair (0: "make the Mode Buttons act exactly
            // like the CC buttons. clicks and all") -- so press/hover/selected
            // states, focus ring and click feel are the built-in ones rather
            // than a hand-rolled lookalike. The old Rectangles carried their
            // own MouseArea, fill maths and a TileGlow pulse; CC's buttons
            // have no glow, so that went with them.
            //
            // Equal halves, like the agents Repeater's cellWidth.
            Button {
              id: defaultModeButton
              // HALF THE ROW EACH (0: "mode buttons should share the panel,
              // they can centre in thier pill"). `fillWidth` alone hands each
              // button its own text width first and only shares out the
              // SURPLUS, so "Omarchy" came out wider than "Wpal". Zeroing the
              // preferred width makes the split even and lets each label
              // centre in its own half.
              Layout.fillWidth: true
              Layout.preferredWidth: 0
              text: "Omarchy"
              selected: !root.masterEnabled
              bordered: true
              foreground: root.contentForeground
              fontFamily: Style.font.family
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              // No hover text on the mode you are already in (0: "if the mode
              // is in a state, remove its hover") -- it would only describe
              // where you already are.
              // SsToolTip everywhere now, so every hover is clamped to its
              // own panel (0: "CONSTRAIN ALL HOVERS TO THIER RESPECTIVE
              // PANEL"). Still nothing on the mode you are already in.
              SsToolTip {
                visible: defaultModeButton.hot && !defaultModeButton.selected
                text: "Hand the Background back\nto your Omarchy theme"
              }
              onClicked: root.setMasterEnabled(false)
            }

            Button {
              id: silverstoneModeButton
              // The other half -- see its twin above.
              Layout.fillWidth: true
              Layout.preferredWidth: 0
              text: "Wpal"
              selected: root.masterEnabled
              bordered: true
              foreground: root.contentForeground
              fontFamily: Style.font.family
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              // Back to the original rule, same as "Omarchy" above (0: "remove
              // the goodness hover over on the mode button Wpal") -- no hover
              // text on the mode you're already in.
              SsToolTip {
                visible: silverstoneModeButton.hot && !silverstoneModeButton.selected
                text: "Per-WorkSpace Backgrounds\nand AutoLaunch"
              }
              onClicked: root.setMasterEnabled(true)
            }

          }
        }

        // The old inline "Global Wallpaper Pool" block (separator, header,
        // path TextField + Browse -- tags 6/7/8a/8b) lived here and is GONE:
        // opening it grew the strip downward. The "..." opens the picker as a
        // popup instead. Those four tags are retired. It used to have its own
        // row here, right-justified above the shuffle button; now it sits
        // beside the shuffle button in the WorkSpaces heading row below,
        // just to its left (0: "drop the ... on main to just left of the
        // recycle button").

        // Heading for the card list (0: "add a Label to Above the list items:
        // 'WorkSpaces'"), with the Randomize cluster directly under it and the
        // cards below that (0: "place randomize all at the top of the ... below
        // that the Randomize cluster").
        // The heading and the shuffle button share ONE row now -- heading
        // left, button hard right (0: "put 11c right justified In the
        // Workspaces row"). The standalone randomize row that used to sit
        // under it is gone, and with it tag 11: the row's two members carry
        // their own tags (10 and 11c), and a container badge here would land
        // on top of 11c's at the right edge.
        Item {
          visible: root.masterEnabled
          width: root.settingsWidth
          implicitHeight: workspacesHeadingRow.implicitHeight

          RowLayout {
            id: workspacesHeadingRow
            width: root.settingsWidth
            spacing: Style.spacing.sm

            // Was a heading-size bold Text; now the same PanelSectionHeader
            // that labels "Mode" and "Global Wallpaper Pool:" (0: "change the
            // inconsistencies"). This supersedes the earlier "bump WorkSpaces
            // to heading size" ask -- one idiom for section labels won.
            PanelSectionHeader {
              Layout.alignment: Qt.AlignVCenter
              text: "WorkSpaces"
              fontSize: Style.font.bodySmall
              foreground: root.contentForeground
            }

            Item { Layout.fillWidth: true }

            // The global pool control, moved in beside the shuffle button
            // (0: "drop the ... on main to just left of the recycle
            // button") -- used to sit right-justified in its own row above.
            Text {
              id: globalDots
              Layout.alignment: Qt.AlignVCenter
              visible: root.masterEnabled
              textFormat: Text.PlainText
              text: "..."
              color: root.contentForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true

              MouseArea {
                id: globalDotsMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // Opens the global pool picker as a popup; second click closes
                // it. Blocked while li is open -- a global change shouldn't
                // land in the middle of a per-workspace edit.
                onClicked: {
                  if (root.activeWorkspace > 0) return
                  if (root.pendingBrowse && root.pendingBrowse.kind === "pool") root.cancelBrowse()
                  else root.beginBrowsePool()
                }

                SsToolTip {
                  visible: globalDotsMouse.containsMouse
                  text: "Set Global Pool"
                  fontSize: Style.font.body
                }
              }
            }

            PanelActionButton {
              id: shuffleButton
              Layout.alignment: Qt.AlignVCenter
              // Omarchy's own bar update icon, same glyph the SystemUpdate bar
              // widget uses (0: "change to omarchys update icon on the bar").
              iconText: "\uf021"
              foreground: root.contentForeground
              // No hover tint (0: "not change color on mousover") -- the spin
              // is the only feedback.
              hoverColor: root.contentForeground
              property bool tipOn: false
              onHovered: function(isHovered) { shuffleButton.tipOn = isHovered }
              SsToolTip { visible: shuffleButton.tipOn; text: "Shuffle Backgrounds" }
              onClicked: {
                root.shuffleWallpaper()
                shuffleSpin.restart()
              }

              // One turn per press (0: "run only once").
              RotationAnimation {
                id: shuffleSpin
                target: shuffleButton
                from: 0
                to: 360
                duration: 1200
                easing.type: Easing.OutCubic
              }
            }
          }
        }

        // A little extra room before workspace 1, beyond the section's
        // normal double-gap spacing above.
        Item {
          width: 1
          height: Style.spacing.sm
        }

        // Omarchy Default has nothing per-workspace to show, so the list
        // collapses to a single card (workspace 1, previewing the current
        // theme wallpaper via the same previewFor() fallback every card
        // already uses) rather than showing ten cards that would all just
        // show that same image. SilverStone Custom always shows all ten,
        // each falling back to that same theme-wallpaper preview until it's
        // actually customized. Wrapped in a fixed-width Item so the Column
        // (narrower than settingsWidth) can be centered within it rather
        // than sitting flush-left under the wider settings block above.
        Item {
          id: cardsHost
          visible: true
          width: root.settingsWidth
          implicitHeight: cardColumn.implicitHeight
          // Height left for the cards below everything above them, split
          // across however many are showing, so the whole list fits on the
          // screen (cards shrink instead of running off the bottom).
          readonly property int cardRows: root.masterEnabled ? 5 : 1
          readonly property int cardCols: root.masterEnabled ? 2 : 1
          readonly property int fitCardH: Math.max(24, Math.floor(
            (cardFrame.maxHeight - Style.spacing.panelPadding * 2 - cardsHost.y - (cardRows - 1) * Style.spacing.lg) / cardRows))

          // One card per workspace id: Default mode shows just ws1 across
          // the full width; Custom mode splits 1-5 | 6-0 into two columns.
          Component {
            id: cardDelegate
            WorkspaceCard {
              id: card
              required property int modelData
              workspaceId: modelData
              selected: root.cursorActive && root.cursorWs === modelData
              // ~2s spread across the ten cards, in list order.
              staggerMs: root.shuffleJustRan ? (modelData === 10 ? 9 : modelData - 1) * 200 : 0
              // Omarchy Default's lone card stands for the whole desktop's
              // wallpaper, not workspace 1's -- so it carries no number
              // (0: "lose the 1 for workspace 1 on the default mode").
              showNumber: root.masterEnabled
              fullWidth: Math.floor((root.settingsWidth - (cardsHost.cardCols - 1) * Style.spacing.controlGap) / cardsHost.cardCols)
              maxCardH: cardsHost.fitCardH
              previewPath: root.previewFor(modelData)
              clampTarget: cardFrame
              launchActive: root.launchCountFor(modelData) > 0
              launchRects: root.launchRectsFor(modelData)
              launchEnabled: root.launchEnabledFor(modelData)
              launchFsIndex: root.launchFsIndexFor(modelData)
              // Omarchy Default has no auto-launch at all, so its lone card
              // gets no tiles and no hover (0: "the Default Mode has a
              // border, lose it, its got no AL assigned"). Custom mode passes
              // the real panes.
              panes: root.masterEnabled ? root.wsSetting(modelData).panes : []
              active: root.activeWorkspace === modelData
              summaryText: root.workspaceSummary(modelData)
              foreground: root.contentForeground
              onClicked: {
                var y = card.mapToItem(null, 0, card.height / 2).y
                // The single ws1 card shown in Omarchy Default mode stands
                // for the whole desktop's wallpaper, not workspace 1's own
                // (irrelevant, in this mode) settings -- it opens the simple
                // picker directly instead of the full per-workspace dialog.
                // A second click on the card that's already open closes it
                // again with no changes -- a toggle, not a fresh re-open
                // (same pattern as the Standard-mode preview click).
                if (root.masterEnabled) {
                  if (root.activeWorkspace === modelData) { root.closeDialog(); return }
                  root.openWorkspace(modelData, y)
                  return
                }
                // Omarchy Default mode is Omarchy's wallpaper, so the click
                // hands over to OMARCHY'S OWN picker rather than ours (0:
                // "open the omarchy system background picker on click of the
                // preview"). Our picker is for Wpal's per-workspace
                // backgrounds.
                if (root.pendingBrowse) root.cancelBrowse()
                root.openOmarchyBackgroundPicker()
              }
            }
          }

          Row {
            id: cardColumn
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.spacing.sm

            Column {
              // Tightened from lg (0: "tighten the panel as you can") -- the
              // cards carry their own borders, so the wide gutter between
              // them was pure height.
              spacing: Style.spacing.sm
              Repeater {
                model: root.masterEnabled ? [1, 2, 3, 4, 5] : [1]
                delegate: cardDelegate
              }
            }
            Column {
              spacing: Style.spacing.sm
              Repeater {
                model: root.masterEnabled ? [6, 7, 8, 9, 10] : []
                delegate: cardDelegate
              }
            }
          }
        }

        // Global Auto Launch, delimited off on its own (0).
        PanelSeparator {
          visible: root.masterEnabled
          width: root.settingsWidth
          foreground: root.contentForeground
        }

        Item {
          visible: root.masterEnabled
          width: root.settingsWidth
          implicitHeight: childrenRect.height
          RowLayout {
            id: globalAlRow
            visible: root.masterEnabled
            width: root.settingsWidth
            // Tighter than controlGap: at the glyph's new toggle-matched size
            // the row ran past the panel's right border on the standard gap
            // (screenshot-checked). The cluster still reads as a cluster.
            spacing: Style.spacing.sm

            // Label and toggle are ONE cluster on the left; the glyph is on
            // its own at the right edge (0: "Cluster the Fucking text and the
            // toggle together, and put them on the left, put the glyph to the
            // right"). No fillWidth on the label any more -- that is what was
            // stretching it into a wrapped block between the two.
            Text {
              Layout.alignment: Qt.AlignVCenter
              textFormat: Text.PlainText
              // "Global" is back, on its own line, so the string is narrow
              // enough not to push the Clear glyph past the panel border --
              // which is why it was dropped in the first place (0: "the label
              // on the auto launch should read 'Global\n AutoLaunch'"). The
              // enabled/disabled words are gone with it: the toggle beside it
              // says that, in its own red.
              horizontalAlignment: Text.AlignLeft
              text: "Global\nAutoLaunch"
              // Soft tint when on, soft red when off (0).
              // Same treatment as li's (0: "do global too") -- white on,
              // greyed off, never red; the toggle keeps its red.
              color: root.autoLaunchEnabled ? root.contentForeground : Qt.darker(root.contentForeground, 1.9)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            // Wipes every workspace's launchers in one write (0: "we need a
            // Clear all Launchers button ... put it down with the glolbal
            // launcher same line"). Only offered while there is something to
            // clear, and it leaves the Auto Launch switches exactly as they
            // are -- it empties the slots, it does not turn anything off.
            ToggleSwitch {
              id: autoLaunchToggle
              checked: root.autoLaunchEnabled
              // Off reads in the same red the tiles use when auto launch is
              // blocked (0: "color the auto launch toggle buttons the same red as
              // the tile outline when blocking"); on is untouched.
              foreground: root.autoLaunchEnabled ? Color.foreground : "#e08a8a"
              onToggled: root.setAutoLaunchEnabled(!root.autoLaunchEnabled)
            }

            // One spacer now: the label+toggle cluster sits left, the glyph
            // right, and the rule is NOT in this row any more -- it is drawn
            // over it, on the row's own centre line (0: "place the divider in
            // the middle"). Two fillWidth spacers put it in the middle of the
            // LEFTOVER space, which is not the middle of the row once the
            // cluster is wider than the glyph.
            Item { Layout.fillWidth: true }

            // Wipes every workspace's launchers in one write (0: "we need a
            // Clear all Launchers button ... put it down with the glolbal
            // launcher same line"). A GLYPH, not the words: the text button
            // wrapped the label into four lines. In the theme accent at rest
            // (0: "change it to a theme color"), red only on hover, like every
            // destructive control in the shell.
            PanelActionButton {
              id: clearLaunchersButton
              Layout.alignment: Qt.AlignVCenter
              // Never let the row squeeze it to nothing.
              Layout.minimumWidth: implicitWidth
              Layout.preferredWidth: implicitWidth
              // Always on the row, not only when something is set (0: "the
              // glyph is gone, place it in the bottom right corner"). It sits
              // in the panel's bottom-right corner, which is where this row
              // ends. Dimmed when there is nothing to clear.
              enabled: root.anyLaunchersSet
              opacity: root.anyLaunchersSet ? 1 : 0.45
              // As tall as the toggle it shares the row with (0: "inc size of
              // the main panel clear launchers glyph to match the height of
              // the toggle bar"); the glyph itself grows with it.
              size: autoLaunchToggle.implicitHeight
              fontSize: Style.font.iconLarge
              iconText: "\uf1f8"
              // Armed (red, held) after one click -- a second click within the
              // window actually wipes all 10 workspaces. No popup: a confirm
              // dialog here would be new panel chrome for a glyph button that
              // was deliberately kept chrome-free (see the comment above), and
              // would have to reserve its own space to avoid thrashing the
              // panel. Arm-then-confirm costs nothing but a second click.
              property bool armed: false
              foreground: clearLaunchersButton.armed ? Color.urgent : Color.accent
              hoverColor: Color.urgent
              property bool tipOn: false
              onHovered: function(isHovered) { clearLaunchersButton.tipOn = isHovered }
              SsToolTip {
                visible: clearLaunchersButton.tipOn
                text: clearLaunchersButton.armed ? "Click again to confirm" : "Clear all launchers"
              }
              Timer { id: disarmTimer; interval: 3000; onTriggered: clearLaunchersButton.armed = false }
              onClicked: {
                if (clearLaunchersButton.armed) {
                  clearLaunchersButton.armed = false
                  root.clearAllLaunchers()
                } else {
                  clearLaunchersButton.armed = true
                  disarmTimer.restart()
                }
              }
            }
          }

          // The divider, on the ROW's centre line rather than inside it: a
          // vertical twin of PanelSeparator, 1px, three quarters of the
          // toggle's height (0: "shorten the last delimiter to 75% still
          // centered"), drawn over the row so the layout's spacing maths does
          // not get a say in where it lands.
          Rectangle {
            x: Math.round(globalAlRow.width / 2)
            y: globalAlRow.y + Math.round((globalAlRow.height - height) / 2)
            visible: root.masterEnabled
            width: 1
            height: Math.round(autoLaunchToggle.implicitHeight * 0.75)
            color: Qt.rgba(root.contentForeground.r, root.contentForeground.g,
                           root.contentForeground.b, 0.12)
          }
        }

        // The closing separator under Global Auto Launch is GONE (0: "remove
        // the delmiter from the bottom of the MP") -- the panel's own border
        // is the bottom edge, so it was a line drawn against a line. Tag 15
        // is retired with it; don't renumber around the gap.
      }
      } // end Flickable (stripFlick)
    }
  }

  // ---- the dialog: opens beside whichever card was clicked, either the
  //      config card or one workspace. The strip stays open behind it (the
  //      selector doesn't disappear). ----------------------------------

  PanelWindow {
    id: dialogWin
    // The overall Settings dialog moved inline into the strip -- this popup
    // is only for the per-workspace customize dialog and the browse picker
    // now. pendingBrowse is checked independently of activeWorkspace because
    // the global pool browse (beginBrowsePool) opens with no workspace active
    // at all.
    visible: root.opened && (root.activeWorkspace > 0 || root.pendingBrowse !== null)
    // The launcher-config panel sits to LI's LEFT (0: "the config for the AL
    // will popup to the LEFT of its parent the li editor") -- the same side
    // the browse picker uses, so li itself no longer has to move.
    readonly property bool launcherOpen: root.activeWorkspace > 0 && workspaceContent.expandedSlot >= 0
    screen: stripWin.screen
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "silverstone-dialog"
    WlrLayershell.layer: WlrLayer.Overlay
    // Unlike the strip, this dialog is meant to be typed and tabbed into --
    // editing settings already needs the keyboard. Prime with a brief
    // Exclusive pulse every time it opens (same pattern as the shared
    // KeyboardPanel.qml base) so Tab/Escape work immediately, without
    // requiring an extra click into a field first.
    property bool focusPrimed: false
    WlrLayershell.keyboardFocus: focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive

    onVisibleChanged: {
      if (visible) {
        focusPrimed = false
        dialogFocusPrimeTimer.restart()
        Qt.callLater(function() { (root.pendingBrowse !== null ? pickerFrame : dialogFrame).forceActiveFocus() })
      } else {
        dialogFocusPrimeTimer.stop()
        focusPrimed = false
      }
    }

    Timer {
      id: dialogFocusPrimeTimer
      interval: 75
      onTriggered: dialogWin.focusPrimed = true
    }

    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true

    // One bounding mask over whichever of the two frames are actually
    // showing -- li alone, picker alone (the global pool browse, no li to
    // sit beside), or both side by side (picker opened from li: it sits to
    // LI's left rather than covering it, per 0 -- covering it was confusing).
    readonly property real maskLeft: Math.min(dialogFrame.visible ? dialogFrame.x : Infinity, pickerFrame.visible ? pickerFrame.x : Infinity,
      launcherFrame.visible ? launcherFrame.x : Infinity, cloneFrame.visible ? cloneFrame.x : Infinity)
    readonly property real maskTop: Math.min(dialogFrame.visible ? dialogFrame.y : Infinity, pickerFrame.visible ? pickerFrame.y : Infinity,
      launcherFrame.visible ? launcherFrame.y : Infinity, cloneFrame.visible ? cloneFrame.y : Infinity)
    readonly property real maskRight: Math.max(dialogFrame.visible ? dialogFrame.x + dialogFrame.width : 0, pickerFrame.visible ? pickerFrame.x + pickerFrame.width : 0,
      launcherFrame.visible ? launcherFrame.x + launcherFrame.width : 0, cloneFrame.visible ? cloneFrame.x + cloneFrame.width : 0)
    readonly property real maskBottom: Math.max(dialogFrame.visible ? dialogFrame.y + dialogFrame.height : 0, pickerFrame.visible ? pickerFrame.y + pickerFrame.height : 0,
      launcherFrame.visible ? launcherFrame.y + launcherFrame.height : 0, cloneFrame.visible ? cloneFrame.y + cloneFrame.height : 0)

    mask: Region {
      x: dialogWin.maskLeft
      y: dialogWin.maskTop
      width: dialogWin.maskRight - dialogWin.maskLeft
      height: dialogWin.maskBottom - dialogWin.maskTop
    }

    // Left of the strip, stuck to the top: level with the strip's own top
    // edge (same bar clearance). cardFrame is right-anchored in stripWin,
    // which (like dialogWin) fully overlays the screen, so its left edge is
    // just screen width minus its own margin and width -- no cross-window
    // mapping needed.
    readonly property real screenW: screen ? screen.width : 0
    readonly property real screenH: screen ? screen.height : 0
    // The card is no longer pinned to the right edge, so li has to follow
    // wherever it actually landed under the bar button.

    BorderSurface {
      id: dialogFrame
      // Every tooltip inside this frame clamps itself to it -- SsToolTip
      // walks up to this objectName (0: "CONSTRAIN ALL HOVERS TO THIER
      // RESPECTIVE PANEL").
      objectName: "ssPanelFrame"
      visible: root.activeWorkspace > 0
      // It does not depend on the content height, so toggling Auto Launch or
      // adding a launcher only grows it downward.
      x: root.besideX(cardFrame.x, cardFrame.width, width)
      // ALWAYS vertically centred on the main panel, whichever card opened it
      // (0: "just have the li editor open in the midddle vertically of the
      // main panel every time, no more close to the li item"). It used to
      // track the clicked card's midpoint via `root.dialogAnchorY`, and
      // re-anchor whenever a different card was picked; both are gone. The
      // anchor value is still carried by openWorkspace() for the cursor work
      // that reads it, it just no longer places this panel.
      //
      // Still PINNED on open: the centring maths depends on `height`, so
      // anything that changed li's height would slide the whole panel
      // (0: "theres a panel thrash when a second AL is added"). The y is
      // taken once, when li opens, and growth runs downward off a fixed top
      // edge. Clamped so it never rides over the bar or off the bottom.
      readonly property real wantY: Math.max(cardFrame.topClear,
        Math.min(cardFrame.y + cardFrame.height / 2 - height / 2,
          dialogWin.screenH - Style.gapsOut - height))
      property real pinnedY: -1
      y: dialogFrame.pinnedY < 0 ? dialogFrame.wantY
        : Math.max(cardFrame.topClear,
          Math.min(dialogFrame.pinnedY, dialogWin.screenH - Style.gapsOut - height))
      // ONE handler for both: pin the y on open, and spend the clone line on
      // close -- whatever took li away (panel closed, bar closed, dismissed).
      onVisibleChanged: {
        pinnedY = visible ? wantY : -1
        if (!visible) {
          workspaceContent.resetClone()
          if (root.service) root.service.cloneRevealed = false
        }
      }
      width: workspaceContent.implicitWidth + Style.spacing.panelPadding * 2
      height: workspaceContent.implicitHeight + Style.spacing.panelPadding * 2
      color: Color.popups.background
      radius: Style.cornerRadius
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      focus: true
      Keys.onEscapePressed: root.escapePressed()
      // Every edit here writes straight through to settings as it happens
      // (0: "enter acts like save when...", same rule AutoLaunchConfig
      // already follows) -- there's nothing staged for Enter to commit, so
      // closing li is the whole of "Save" here. Same cascade as Escape: if
      // a child panel (launcher editor, clone) is layered on top, THAT
      // frame has focus instead and handles its own Enter first.
      Keys.onReturnPressed: root.escapePressed()
      Keys.onEnterPressed: root.escapePressed()

      CustomizeDialog {
        id: workspaceContent
        x: Style.spacing.panelPadding
        y: Style.spacing.panelPadding
        workspaceId: root.activeWorkspace > 0 ? root.activeWorkspace : 1
        cfg: root.activeWorkspace > 0 ? root.wsSetting(root.activeWorkspace) : ({ background: { mode: "default", path: "", poolFolder: "" }, panes: Model.normalizePanes(null), autoLaunchEnabled: true })
        previewPath: root.activeWorkspace > 0 ? root.previewFor(root.activeWorkspace) : ""
        foreground: root.contentForeground
        autoLaunchEnabled: root.autoLaunchEnabled
        randomizedOnce: root.randomizedOnce
        fsSlot: root.launchFsIndexFor(root.activeWorkspace)
        // li stops taking clicks while either of its side panels is open.
        childOpen: root.childPanelOpen
        onExpandedSlotChanged: if (root.service) root.service.expandedSlotIntent = workspaceContent.expandedSlot
        onFsSlotRequested: function(idx) { root.updateWorkspace(root.activeWorkspace, { fullScreenIndex: idx }) }
        onPoolPickRequested: {
          // Second click closes it again (0: "if the browse is clicked twice,
          // it closes its picker").
          if (root.pendingBrowse && root.pendingBrowse.kind === "wsPool") { root.cancelBrowse(); return }
          root.beginBrowseWsPool(root.activeWorkspace)
        }
        // The inline pool picker inside li, not the side picker panel.
        onPoolChosen: function(p) { root.updateWorkspace(root.activeWorkspace, { background: { poolFolder: p } }) }
        onPanesSwapRequested: function(from, to) { root.swapPanes(root.activeWorkspace, from, to) }
        // Clone and the launcher editor share li's left side: opening one
        // closes the other.
        onCloneOpenRequested: {
          cloneContent.reset()
          workspaceContent.expandedSlot = -1
          root.cloneDialogOpen = !root.cloneDialogOpen
        }
        onEditLauncherRequested: {
          // Only ever one child of li at a time (0) -- including the picker,
          // which shares the same slot to li's left.
          root.cloneDialogOpen = false
          if (root.pendingBrowse) root.cancelBrowse()
          Qt.callLater(function() { launcherFrame.forceActiveFocus() })
        }
        updateFn: root.updateWorkspace
        // Same toggle pattern as the standard-mode preview and the main
        // panel's cards: a second click (preview image, or either Select
        // button -- both route here) while this exact browse is already
        // open closes it again, no changes, instead of re-opening.
        // ANY open picker closes on a preview click, whatever opened it and
        // whichever half of li was pressed (0: "if I click on the preview
        // pane on the li when the WP is open, close the WP"). It used to
        // toggle only against an identical browse, so a pool picker sat
        // there while an image click quietly replaced it.
        onBrowseImageRequested: {
          if (root.pendingBrowse) { root.cancelBrowse(); return }
          root.beginBrowseImage(root.activeWorkspace, false)
        }
        onBrowsePoolRequested: {
          if (root.pendingBrowse) { root.cancelBrowse(); return }
          root.beginBrowseImage(root.activeWorkspace, true)
        }
        // The preview is the way out of any child panel now: one click peels
        // exactly one level, the same as Escape.
        onChildDismissRequested: root.escapePressed()
        cloneAlreadyShown: root.service ? root.service.cloneRevealed : false
        onCloneShown: if (root.service) root.service.cloneRevealed = true
        onRandomizeRequested: root.randomizeWorkspace(root.activeWorkspace)
        onLaunchNowRequested: if (root.service) root.service.launchNow(root.activeWorkspace)
        onCloseRequested: root.closeDialog()
      }
    }

    // One launcher's editor, to LI's LEFT -- the Clone panel uses the same
    // side, so opening either closes the other rather than stacking them.
    BorderSurface {
      id: launcherFrame
      // Every tooltip inside this frame clamps itself to it -- SsToolTip
      // walks up to this objectName (0: "CONSTRAIN ALL HOVERS TO THIER
      // RESPECTIVE PANEL").
      objectName: "ssPanelFrame"
      visible: dialogWin.launcherOpen
      // Back to li's LEFT, vertically centred on it, shrink-wrapped to its own
      // content (0: "put the AL Config back to the left centre of the li
      // Editor like it was before, it expands below the panel, its horrible").
      // Filling down to the main panel's bottom is gone.
      //
      // frameH is the height computed as its OWN property rather than read
      // back out of `height` inside the binding that defines height -- that
      // self-reference is what stopped the clamp settling the first time and
      // let the panel hang off the bottom of the screen. Keep it separate.
      readonly property real frameH: launcherContent.implicitHeight + Style.spacing.panelPadding * 2
      x: root.besideX(dialogFrame.x, dialogFrame.width, width)
      y: Math.max(cardFrame.topClear,
        Math.min(dialogFrame.y + dialogFrame.height / 2 - launcherFrame.frameH / 2,
          dialogWin.screenH - Style.gapsOut - launcherFrame.frameH))
      width: dialogFrame.width
      height: launcherFrame.frameH
      color: Color.popups.background
      radius: Style.cornerRadius
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      focus: true
      Keys.onEscapePressed: root.closeLauncherPanel()

      AutoLaunchConfig {
        id: launcherContent
        x: Style.spacing.panelPadding
        y: Style.spacing.panelPadding
        workspaceId: root.activeWorkspace > 0 ? root.activeWorkspace : 1
        slotIndex: Math.max(0, workspaceContent.expandedSlot)
        pane: (root.activeWorkspace > 0 && workspaceContent.expandedSlot >= 0
          && workspaceContent.expandedSlot < workspaceContent.cfg.panes.length)
          ? workspaceContent.cfg.panes[workspaceContent.expandedSlot] : null
        appOptions: workspaceContent.appOptions
        foreground: root.contentForeground
        onAppChanged: function(v) { workspaceContent.setPaneAppId(workspaceContent.expandedSlot, v) }
        onArgsChanged: function(v) { workspaceContent.setPaneArgs(workspaceContent.expandedSlot, v) }
        onCleared: {
          workspaceContent.setPaneAppId(workspaceContent.expandedSlot, "")
          workspaceContent.setPaneArgs(workspaceContent.expandedSlot, "")
        }
        onDeleted: workspaceContent.removePane(workspaceContent.expandedSlot)
        onSaveRequested: function(appId, args) { root.finishLauncherEdit(appId, args) }
        onCloseRequested: root.closeLauncherPanel()
      }
    }

    // Clone, opened from the arrow control at li's bottom-left and sitting
    // right beside it (0: "make it close to the button that launched it").
    BorderSurface {
      id: cloneFrame
      // Every tooltip inside this frame clamps itself to it -- SsToolTip
      // walks up to this objectName (0: "CONSTRAIN ALL HOVERS TO THIER
      // RESPECTIVE PANEL").
      objectName: "ssPanelFrame"
      visible: root.activeWorkspace > 0 && root.cloneDialogOpen
      // Directly under li and the same width (0: "have the clone workspace
      // diag to below its parent matching width").
      x: dialogFrame.x
      // Same independent height as the launcher frame above, for the same
      // reason -- the cloner's content is short so it never showed, but the
      // self-referential clamp was just as wrong here.
      readonly property real frameH: cloneContent.implicitHeight + Style.spacing.panelPadding * 2
      y: Math.max(cardFrame.topClear,
        Math.min(dialogFrame.y + dialogFrame.height + Style.gapsOut,
          dialogWin.screenH - Style.gapsOut - cloneFrame.frameH))
      width: cloneContent.implicitWidth + Style.spacing.panelPadding * 2
      height: cloneFrame.frameH
      color: Color.popups.background
      radius: Style.cornerRadius
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      focus: true
      Keys.onEscapePressed: root.closeClonePanel()
      // Enter is Clone, wherever the focus sits inside this panel. Typing "4"
      // and pressing Enter used to do nothing here and fire the STRIP's
      // Return handler instead -- which closed li, so it read as Escape.
      Keys.onReturnPressed: cloneContent.commit()
      Keys.onEnterPressed: cloneContent.commit()
      onVisibleChanged: if (visible) Qt.callLater(function() { cloneContent.focusField() })

      CloneDialog {
        id: cloneContent
        x: Style.spacing.panelPadding
        y: Style.spacing.panelPadding
        workspaceId: root.activeWorkspace > 0 ? root.activeWorkspace : 1
        foreground: root.contentForeground
        onCloneRequested: function(targets) { root.cloneWorkspace(root.activeWorkspace, targets) }
        onCloseRequested: root.closeClonePanel()
      }
    }

    BorderSurface {
      id: pickerFrame
      // Every tooltip inside this frame clamps itself to it -- SsToolTip
      // walks up to this objectName (0: "CONSTRAIN ALL HOVERS TO THIER
      // RESPECTIVE PANEL").
      objectName: "ssPanelFrame"
      visible: root.pendingBrowse !== null
      // Beside li (to its LEFT -- li is its parent here) when li's open for
      // this browse; otherwise (repo from Settings, or the Standard-mode
      // default-wallpaper picker) the same spot dialogFrame would have used,
      // since there's no li to sit beside.
      x: dialogFrame.visible ? root.besideX(dialogFrame.x, dialogFrame.width, width)
        : root.besideX(cardFrame.x, cardFrame.width, width)
      // Level with li's preview image rather than li's top edge (0: "INLINE
      // with the previews level"), then clamped to the screen: never above
      // the bar, never past the bottom. A picker taller than what's left
      // below the preview gets pushed up rather than running off.
      // Opens next to whatever summoned it. For the global pool that is the
      // "..." itself, so line up with the dots rather than the top of the
      // screen (0: "it opens close to the ... itself"). globalDots lives in
      // stripWin, but both windows overlay the same output, so mapping it
      // into cardFrame and adding cardFrame.y gives a comparable y.
      readonly property real preferredY: dialogFrame.visible
        ? dialogFrame.y + dialogFrame.height / 2 - height / 2
        // Flush with the main panel's own top edge, not a few pixels off it
        // (0: "the standard picker is a few pixels off the main panel, make
        // them even"). cardFrame.y IS that edge; topClear was the margin.
        : cardFrame.y
      y: Math.max(cardFrame.topClear,
        Math.min(preferredY, dialogWin.screenH - Style.gapsOut - height))
      width: browsePicker.implicitWidth + Style.spacing.panelPadding * 2
      height: browsePicker.implicitHeight + Style.spacing.panelPadding * 2
      color: Color.popups.background
      radius: Style.cornerRadius
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      focus: true
      Keys.onEscapePressed: root.escapePressed()
      // No keyboard path into the picker at all before this (0: "allow in
      // the fuzzy picker that a user can use the arrow buttons, and enter to
      // select") -- mouse-only throughout. Same shape as cloneFrame's own
      // Keys.onReturnPressed below: the frame owns the key, the content owns
      // what it means.
      Keys.onUpPressed: browsePicker.moveSelection(0, -1)
      Keys.onDownPressed: browsePicker.moveSelection(0, 1)
      Keys.onLeftPressed: browsePicker.moveSelection(-1, 0)
      Keys.onRightPressed: browsePicker.moveSelection(1, 0)
      Keys.onTabPressed: browsePicker.moveSelection(0, 1)
      Keys.onBacktabPressed: browsePicker.moveSelection(0, -1)
      Keys.onReturnPressed: browsePicker.activateSelection()
      Keys.onEnterPressed: browsePicker.activateSelection()

      WallpaperPicker {
        id: browsePicker
        x: Style.spacing.panelPadding
        y: Style.spacing.panelPadding
        pickFiles: root.pendingBrowse ? root.pendingBrowse.kind === "image" : false
        nameFilters: ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.bmp", "*.gif"]
        foreground: root.contentForeground
        // Titles the picker with the workspace it was opened for; 0 for the
        // global-pool browse, which belongs to no one. wsPool belongs to a
        // workspace just as much as `image` does -- it was left out, which
        // is why li's pool picker titled itself "Global".
        workspaceId: (root.pendingBrowse
          && (root.pendingBrowse.kind === "image" || root.pendingBrowse.kind === "wsPool"))
          ? root.pendingBrowse.workspaceId : 0
        // "Use Global Pool" only means something when this workspace actually
        // has its own pool override to reset -- otherwise clicking it is a
        // no-op (clearWsPool on an already-empty poolFolder).
        poolOverridden: (root.pendingBrowse && root.pendingBrowse.kind === "wsPool")
          ? !!root.wsPoolFolderRaw(root.pendingBrowse.workspaceId) : false
        onChosen: function(p) { root.finishBrowse(p) }
        // File mode only: same write the wsPool branch of finishBrowse does,
        // then the picker closes like any other commit.
        onFolderChosen: function(p) {
          var req = root.pendingBrowse
          if (!req || req.kind !== "image") return
          root.updateWorkspace(req.workspaceId, { background: { poolFolder: p } })
          root.cancelBrowse()
        }
        onCancelled: root.cancelBrowse()
        // Both resets moved in here from li's own settings row (0: "move the
        // Global Button out of LIE and into the picker... add a revert to
        // default button to the picker"). workspaceId is already the
        // resolved wsPool target above, so it's reused as-is rather than
        // re-deriving it from pendingBrowse a second time.
        onPoolResetRequested: root.clearWsPool(browsePicker.workspaceId)
        // Resets the pool SELECTION back to the omarchy theme's own
        // backgrounds folder (Model.resolveWallpaperFolder's fallback for a
        // blank poolFolder). It does not force any picture on screen -- the
        // randomizer draws from whichever pool is selected on its own normal
        // cycle. The write itself is confirmed working (verified via IPC:
        // poolFolder lands as "" and Service.cascadePoolChange rerolls every
        // workspace with no override of its own) -- what was actually broken
        // is that this open picker's own `folder` was a one-shot assignment
        // from beginBrowsePool(), never refreshed after the click, so 0 saw
        // no visible change and reported "does nothing." Compute the default
        // folder directly rather than reading root.poolFolder right back --
        // that property is fed by the same async settings round-trip as the
        // write itself (see trap 2 above), so it can still read the OLD
        // value here.
        onGlobalPoolResetRequested: {
          root.setPoolFolder("")
          browsePicker.folder = Model.resolveWallpaperFolder("", Quickshell.env("HOME"))
        }
      }
    }
  }
}
