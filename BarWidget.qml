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
  moduleName: "io.github.silverstone.wpal"

  // Omarchy only grants serviceFor() a working facade under the trusted
  // stock bar (omarchy.bar) -- any replacement bar (e.g. a clone made via
  // `omarchy plugin clone omarchy.bar`) gets a deliberately service-less
  // facade and serviceFor() always returns null there, by design. When that
  // happens, fall back to a privately-instantiated copy of our own
  // Service.qml, the same pattern io.github.huligabuliga.omagoocal uses for
  // this exact problem. Service.qml needs nothing from the host besides
  // `settings` (pushed below) and `writeSettings` (a callback), so a private
  // copy is exactly as capable as the host-managed singleton -- just not
  // shared across widget instances, which only matters if this bar widget
  // is ever shown on 2+ screens at once under a replacement bar (accepted
  // tradeoff, not triggered by either machine's current config).
  readonly property var hostService: (root.bar && root.bar.shell) ? root.bar.shell.serviceFor(root.moduleName) : null
  readonly property var effectiveService: hostService || privateServiceLoader.item
  Loader {
    id: privateServiceLoader
    active: !!root.bar && !root.hostService
    source: Qt.resolvedUrl("Service.qml")
  }

  function pushSettings() {
    var svc = root.effectiveService
    if (!svc) return
    svc.settings = root.settings
    // Service only reads settings; this is how it asks for one write (see
    // Service.applyStartupMode). Reinstalled on every push so it never
    // points at a destroyed widget after a settings-write recreation.
    svc.writeSettings = function(next) {
      if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
    }
  }

  // The Loader resolving the private fallback is async, so it can arrive
  // after this widget's own settings/bar have already been pushed once --
  // re-push and re-inject so a late-arriving private instance isn't left
  // with stale/no settings.
  onEffectiveServiceChanged: { pushSettings(); injectPanel() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.effectiveService
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
    // Read-only query for the click-through test suite (tests/) -- lets a
    // script assert open/closed state without screenshot diffing.
    function isOpen(): bool { return root.opened }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""  // nf-fa-mountain, U+EF08 (BMP; the md-mountains supplementary-plane glyph did not render)
    onPressed: function(b) { root.togglePanel() }
  }
}
