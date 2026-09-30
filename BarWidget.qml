import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon for SilverStone: per-workspace wallpaper + auto-launch panes.
// Click opens the configuration popup (Panel.qml).
//
// This widget is the only thing the host keeps alive with `settings` from
// shell.json for the plugin's whole lifetime -- a `service`-kind entry point
// (Service.qml) is never handed `settings` directly. So this widget pushes
// its settings down into the shared service on every change, mirroring the
// injectPanel() relay every first-party bar-widget-plus-panel plugin uses,
// just one hop further.
BarWidget {
  id: root
  moduleName: "chad.silverstone"

  function pushSettings() {
    var svc = root.bar && root.bar.shell ? root.bar.shell.serviceFor(root.moduleName) : null
    if (!svc) return
    svc.settings = root.settings
    // Service only reads settings; this is how it asks for one write (see
    // Service.turnOffAskAndLaunch). Reinstalled on every push so it never
    // points at a destroyed widget after a settings-write recreation.
    svc.writeSettings = function(next) {
      if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
    }
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // One-shot rewrite of the pre-rename pool keys (Model.migrateSettings).
  // This widget is the only holder of shell access, so the write has to be
  // made from here, and BEFORE pushSettings so the service sees the migrated
  // object on this same pass. Idempotent and a no-op once the keys are new,
  // so the write it makes cannot re-trigger itself -- which is what lets it
  // sit in onSettingsChanged rather than in a one-shot Component.onCompleted.
  function migrateSettings() {
    if (!Model.settingsNeedMigration(root.settings)) return
    if (root.bar && root.bar.shell)
      root.bar.shell.updateEntryInline(root.moduleName, Model.migrateSettings(root.settings))
  }

  // ---- Panel plumbing. Bar.findPanelWidget routes summon/hide/toggle
  //      through open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // migrateSettings is on BOTH paths: the host can hand `settings` over before
  // this widget finishes constructing, in which case onSettingsChanged never
  // fires for it and the completion path is the only one that runs. Harmless
  // to run twice -- the second pass has nothing left to move.
  onBarChanged: { migrateSettings(); injectPanel(); pushSettings() }
  onSettingsChanged: { migrateSettings(); injectPanel(); pushSettings() }
  Component.onCompleted: Qt.callLater(function() { migrateSettings(); pushSettings() })

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // The shell registers its own handler for the widget id, which shadows
  // this one -- same pattern omagoocal uses for its own extra IPC verbs.
  IpcHandler {
    target: "silverstone"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function debugOpenWorkspace(id: int): void { if (panelLoader.item) panelLoader.item.openWorkspace(id, 300) }
    function debugSetMode(v: string): void { if (panelLoader.item) panelLoader.item.setMasterEnabled(v === "true") }
    function debugSetOverride(p: string): void { if (panelLoader.item) { if (p) panelLoader.item.setGlobalOverride(p); else panelLoader.item.clearGlobalOverride() } }
    function debugBrowseImage(id: int, fromPool: bool): void { if (panelLoader.item) { panelLoader.item.openWorkspace(id, 300); panelLoader.item.beginBrowseImage(id, fromPool) } }
    function debugChoose(p: string): void { if (panelLoader.item) panelLoader.item.finishBrowse(p) }
    function debugBrowseDefault(): void { if (panelLoader.item) panelLoader.item.beginBrowseDefaultWallpaper(300) }
    function debugClone(id: int, text: string): void { if (panelLoader.item) { panelLoader.item.openWorkspace(id, 300); panelLoader.item.debugClone(text) } }
    function debugCloneWrite(id: int, csv: string): void { if (panelLoader.item) panelLoader.item.cloneWorkspace(id, csv.split(",").map(Number)) }
    function debugSetRepo(p: string): void { if (panelLoader.item) panelLoader.item.setPoolFolder(p) }
    function debugEditPane(id: int, idx: int): void {
      if (panelLoader.item) { panelLoader.item.openWorkspace(id, 300); panelLoader.item.debugEditPane(idx) }
    }
    function debugSetStartupCustom(v: string): void { if (panelLoader.item) panelLoader.item.setStartupCustom(v === "true") }
    function debugSetRandomized(v: string): void {
      var svc = root.bar && root.bar.shell ? root.bar.shell.serviceFor(root.moduleName) : null
      if (svc) svc.randomizedOnce = (v === "true")
    }
    // Drives the keyboard cursor without synthesizing key presses into 0's
    // live session. 0 = clear it.
    function debugCursor(id: int): void {
      if (panelLoader.item) panelLoader.item.cursorWs = id
    }
    // Opens/closes the global pool picker popup, i.e. what the main panel's
    // "..." does -- there is no way to synthesize that click from here.
    function debugBrowseRepo(v: string): void {
      if (panelLoader.item) panelLoader.item.debugBrowseRepo(v === "true")
    }
    function debugSetBrowseFolder(p: string): void {
      if (panelLoader.item) panelLoader.item.debugSetBrowseFolder(p)
    }
    function debugBrowseWsPool(id: int): void {
      if (panelLoader.item) { panelLoader.item.openWorkspace(id, 300); panelLoader.item.debugBrowseWsPool(id) }
    }
    function debugSetWsPool(id: int, p: string): void {
      if (panelLoader.item) panelLoader.item.debugSetWsPool(id, p)
    }
    // Presses the "Shuffle Backgrounds" glyph -- no way to synthesize that
    // click from here either.
    function debugShuffleAll(): void {
      if (panelLoader.item) panelLoader.item.shuffleGlobalWallpaper()
    }
    function debugAuditTags(v: string): void {
      var svc = root.bar && root.bar.shell ? root.bar.shell.serviceFor(root.moduleName) : null
      if (svc) svc.auditTags = (v === "true")
    }
    function debugLaunchNow(id: int): void {
      var svc = root.bar && root.bar.shell ? root.bar.shell.serviceFor(root.moduleName) : null
      if (svc) svc.launchNow(id)
    }
    function debugTurnOffAsk(): void {
      var svc = root.bar && root.bar.shell ? root.bar.shell.serviceFor(root.moduleName) : null
      if (svc) svc.turnOffAskAndLaunch()
    }
    // Pokes a workspace's real full-screen pick directly, for testing
    // without a pointer.
    function debugLiSettings(id: int, v: string): void {
      if (panelLoader.item) { panelLoader.item.openWorkspace(id, 300); panelLoader.item.debugLiSettings(v === "true") }
    }
    function debugPickerVersion(v: int): void {
      if (panelLoader.item) panelLoader.item.setPickerVersion(v)
    }
    // 1 = chip rail, 2 = ladder. Folder (pool) mode only.
    function debugPoolStyle(v: int): void {
      if (panelLoader.item) panelLoader.item.setPoolStyle(v)
    }
    // Presses Save in the Auto Launch editor -- the button itself cannot be
    // clicked from here, and Save is the one path that both writes and closes.
    function debugPlayClone(id: int): void {
      if (panelLoader.item) { panelLoader.item.openWorkspace(id, 300); panelLoader.item.debugPlayClone() }
    }
    function debugSaveAl(): void {
      if (panelLoader.item) panelLoader.item.debugSaveAl()
    }
    // The drag gesture cannot be synthesized from here; this drives the write
    // it ends in, so the swap itself can be verified.
    function debugSwapPanes(id: int, from: int, to: int): void {
      if (panelLoader.item) panelLoader.item.swapPanes(id, from, to)
    }
    // Holds the two tiles in their mid-trade colours (accent / urgent) so the
    // drag visuals can be seen without a pointer. -1 -1 clears it.
    function debugDragTiles(from: int, to: int): void {
      if (panelLoader.item) panelLoader.item.debugDragTiles(from, to)
    }
    function debugSetPane(id: int, idx: int, args: string): void {
      if (panelLoader.item) panelLoader.item.debugSetPane(id, idx, args)
    }
    function debugAddLauncher(id: int): void {
      if (panelLoader.item) { panelLoader.item.openWorkspace(id, 300); panelLoader.item.debugAddLauncher() }
    }
    function debugSetFullScreen(id: int, idx: int): void {
      if (panelLoader.item) panelLoader.item.updateWorkspace(id, { fullScreenIndex: idx })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""  // nf-fa-mountain, U+EF08 (BMP; the md-mountains supplementary-plane glyph did not render)
    onPressed: function(b) { root.togglePanel() }
  }
}
