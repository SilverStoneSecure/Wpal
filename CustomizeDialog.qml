import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The centered "customize this workspace" dialog: a big thumbnail (click it
// to browse for a specific image), a per-workspace "use random from pool"
// reroll, and up to 4 auto-launch slots, added one at a time. Nothing shows
// until "+" is pressed; a configured slot always launches when Auto Launch
// does -- there's no per-slot on/off any more (see Model.js). "Remove Auto
// Launcher" deletes the slot outright and renumbers everything after it.
Item {
  id: root

  required property int workspaceId
  property var cfg: ({ background: { mode: "default", path: "" }, panes: [], autoLaunchEnabled: true, autoLaunchAsk: false })
  property string previewPath: ""
  property color foreground: Color.foreground
  property bool autoLaunchEnabled: true
  // True once any randomize control has been used this shell run: the
  // randomize button's hover text then reads "Change Again", like the
  // panel's row (see Service.randomizedOnce).
  property bool randomizedOnce: false
  // Walkthru audit tags, passed down from Panel (see AuditTag.qml).
  property bool auditTags: true
  // Whether the clone line has already run this panel-open. Panel keeps the
  // flag in the service so it survives li closing, reopening and the settings
  // writes that rebuild this dialog (0: "only fires once now, and stays till
  // panel close").
  property bool cloneAlreadyShown: false
  signal cloneShown()
  // Wind the clone line back to just its own mark. Called whenever li stops
  // being on screen -- panel closed, bar closed, li dismissed (0: "it SHOULD:
  // reset to just itself on every lost focus of its panel"). Clearing the
  // service flag alone was not enough: this dialog is HIDDEN, not destroyed,
  // so `cloneBox.phase` sat at 12 and the finished line was still drawn the
  // next time it came up.
  function resetClone() { cloneBox.reset() }
  // Play the clone line from here, the way a press on it does -- the only way
  // to watch the run without 0's pointer (debug rig; goes with the rest of it).
  function playClone() { cloneBox.play() }
  // A click on the preview while a child panel is open kills that child (0:
  // "let the clild die on click of the previoius preview"). The blanket below
  // swallows every other click on li while a child is up.
  signal childDismissRequested()
  property var updateFn: function(id, patch) {}

  // Which auto-launch slot's popup editor is open, -1 for none (see
  // launcherPopup on the preview). Set by addPane() for a new slot, or by
  // clicking a configured tile on the preview for an existing one.
  property int expandedSlot: -1

  // Wallpaper-source section (Global/Custom radios + randomize), collapsed
  // by default and revealed by "Set Wallpaper" (0: "trying to compact, the
  // panel was getting busy"). Toggled by the new row under WS(N).

  // Which configured slot (if any) opens full screen -- owned by Panel.qml,
  // persisted via updateFn like everything else here. -1 = none designated.
  // Only meaningful at 2+ configured launchers (0: a single launcher already
  // fills the workspace, no separate flag needed there).
  property int fsSlot: -1
  signal fsSlotRequested(int idx)
  // ONE launcher is enough (0: "a single AL should still show the Full screen
  // option"). It used to need two, on the reasoning that a lone window has
  // nothing to be full screen against -- but it is still a real setting for
  // that window, and hiding the toggle read as the control being missing.
  readonly property bool fsEligible: root.launchCount >= 1
  function toggleFs(idx) { root.fsSlotRequested(root.fsSlot === idx ? -1 : idx) }

  // Hover text for the disabled-workspace "(N set)" summary below: every
  // configured launcher as one combined list, marking which one is full
  // screen. Uses savedLauncherCount, not fsEligible, so it still reads right
  // while this workspace's Auto Launch is paused/off. Distinct from the
  // preview's own hover further down, which is per-launcher, not combined.
  function fsHoverList() {
    var lines = []
    var panes = root.cfg.panes || []
    for (var i = 0; i < panes.length; i++) {
      if (!root.paneHasData(i)) continue
      var line = (i + 1) + ". " + root.paneDesc(i)
      if (root.savedLauncherCount >= 1 && i === root.fsSlot) line += "  (full screen)"
      lines.push(line)
    }
    return lines.join("\n")
  }

  signal browseImageRequested()
  signal browsePoolRequested()
  signal randomizeRequested()
  signal launchNowRequested()
  signal cloneOpenRequested()
  signal closeRequested()
  // Open one launcher's own config panel beside li (see AutoLaunchConfig.qml)
  // -- replaces the popup that used to open over the preview.
  signal editLauncherRequested(int idx)
  // Per-workspace wallpaper pool (0: "we lost the override global, sort that
  // out select a pool just for this workspace"), behind the "..." below.
  signal poolPickRequested()
  signal poolResetRequested()
  // A folder chosen in the inline pool picker that drops in where the preview
  // is, rather than in a separate picker panel.
  signal poolChosen(string path)
  // Drag one launcher's tile onto another: they trade places, full-screen
  // pick riding along (0: "they just replace each other one for one and keep
  // theyre full screen status").
  signal panesSwapRequested(int from, int to)

  // li's own settings, disclosed by EITHER "..." -- the one just below the
  // first delimiter and the one at the bottom centre of the preview (0 asked
  // for both). Two triggers, one block, so the pool override and the Auto
  // Launch checkbox each exist exactly once; the block itself sits at the
  // bottom, where 0 wants the checkbox.
  property bool settingsOpen: false
  onWorkspaceIdChanged: root.settingsOpen = false

  // True while one of li's own side panels (Pane config, Clone) is open. li
  // then stops taking clicks entirely -- 0: "a click on the list item editor
  // panel should not be allowed to be clicked if a child is open". The click
  // is swallowed, not rerouted: nothing happens until the child is closed.
  // The inline pool picker is part of li, not a child, so it doesn't block.
  property bool childOpen: false

  implicitWidth: column.width
  implicitHeight: column.implicitHeight

  // Where the preview image starts, relative to this dialog's own top edge.
  // Panel.qml lines the wallpaper picker up with it (0: "have the picker
  // panel open INLINE with the previews level").
  readonly property real previewTop: previewBox.y

  // Clone moved out to its own panel (CloneDialog.qml), opened by Panel
  // beside the arrow button at the bottom of this card.

  // Installed applications for the app picker, sourced from Quickshell's own
  // DesktopEntries singleton -- not PluginShellApi.appLibrary, which is
  // gated to menu-kind plugins and this plugin isn't one. A synthetic
  // leading "(none)" option clears appId so the args field is read as the
  // command/URL itself instead (see Model.classifyPane).
  readonly property var appOptions: {
    var apps = (DesktopEntries.applications && DesktopEntries.applications.values) || []
    var out = [{ value: "", label: "Pick an app — or type a command below" }]
    for (var i = 0; i < apps.length; i++) {
      var e = apps[i]
      if (!e || !e.id) continue
      out.push({ value: String(e.id), label: String(e.name || e.id) })
    }
    return out
  }

  function appLabelFor(id) {
    for (var i = 0; i < root.appOptions.length; i++) {
      if (root.appOptions[i].value === id) return root.appOptions[i].label
    }
    return id
  }

  // Hover text for checkbox N: empty (no tooltip) when the slot has neither
  // an app nor args set. Otherwise line 1 is "the selected launcher item" --
  // the app's display name if one's picked, else the args value itself
  // (which is then the command/URL, not extra args). Line 2 only appears
  // when an app IS picked and args also has something in it, since that's
  // the one case where args means something separate from line 1.
  function paneTooltip(idx) {
    // Guarded: the tile repeaters can outlive a pane by a frame when a slot
    // is removed, and an undefined p threw here.
    var p = root.cfg.panes[idx]
    if (!p) return ""
    var hasApp = p.appId !== ""
    var hasArgs = p.args.trim() !== ""
    if (!hasApp && !hasArgs) return ""
    var line1 = hasApp ? root.appLabelFor(p.appId) : p.args
    return (hasApp && hasArgs) ? (line1 + "\nargs: " + p.args) : line1
  }

  // Inline summary shown on the collapsed row itself -- the app name if
  // one's picked, else the args value (which is the command/URL in that
  // case), else a placeholder for a genuinely empty slot.
  function paneDesc(idx) {
    var p = root.cfg.panes[idx]
    if (!p) return "(not set)"
    var args = String(p.args || "").trim()
    // The args come too (0: "If a AL has args, show it on the lie and the main
    // preview"). Two panes on the same app were indistinguishable without
    // them -- ws6's pair both read "foot" when one of them is "foot claude".
    // Written the way it actually runs, app then args.
    if (p.appId !== "") {
      var name = root.appLabelFor(p.appId)
      return args !== "" ? (name + " " + args) : name
    }
    return args !== "" ? args : "(not set)"
  }

  function paneHasData(idx) {
    var p = root.cfg.panes[idx]
    return !!p && (p.appId !== "" || p.args.trim() !== "")
  }

  // How many launchers are saved on this workspace (shown as "(N)" next to
  // the disabled label, since the slot list is hidden while it's off).
  readonly property int savedLauncherCount: {
    var n = 0
    var panes = root.cfg.panes || []
    for (var i = 0; i < panes.length; i++) {
      var p = panes[i]
      if (p && (p.appId !== "" || String(p.args || "").trim() !== "")) n++
    }
    return n
  }

  function patchBackground(p) { root.updateFn(root.workspaceId, { background: p }) }

  // Wallpaper source: the global pool (random, or one pinned pool image) or a
  // file outside it. The radios only choose which; the Select buttons open the
  // picker. Both picks are remembered (see Model.normalizeBackground), and
  // Outside with nothing picked falls back to the pool.
  readonly property string poolFolder: String(root.cfg.background.poolFolder || "").replace(/\/+$/, "")
  readonly property bool outsideSelected: root.cfg.background.source === "outside"
  readonly property string poolPick: root.cfg.background.poolPath || ""
  readonly property string outsidePick: root.cfg.background.outsidePath || ""

  // Image count in this workspace's pool, for "(N available)" on the
  // randomize row (same filters as the panel's own pool counter).
  FolderListModel {
    id: poolModel
    folder: root.poolFolder !== "" ? Util.fileUrl(root.poolFolder) : ""
    showDirs: false
    showDotAndDotDot: false
    caseSensitive: false
    nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp", "*.bmp", "*.gif"]
  }

  // Applies a source/pick change and the mode/path that follow from it.
  function setSource(patch) {
    var bg = Object.assign({}, root.cfg.background, patch)
    root.patchBackground(Object.assign(patch, Model.effectiveBackground(bg)))
  }

  function setPaneField(idx, field, value) {
    var panes = root.cfg.panes.map(function(p) { return Object.assign({}, p) })
    panes[idx][field] = value
    // The popup stays open across edits now (no accordion to auto-fold into
    // any more) -- Escape or a click outside closes it.
    root.updateFn(root.workspaceId, { panes: panes })
  }
  function setPaneAppId(idx, v) { root.setPaneField(idx, "appId", v) }
  function setPaneArgs(idx, v) { root.setPaneField(idx, "args", v) }

  // Slots actually shown: up to the last one holding data, plus the empty
  // one currently being edited. Saved-but-empty trailing slots stay hidden
  // (a workspace with none assigned shows only "+").
  readonly property int visibleCount: {
    var panes = root.cfg.panes
    var last = -1
    for (var i = 0; i < panes.length; i++) {
      if (panes[i].appId !== "" || panes[i].args.trim() !== "") last = i
    }
    var n = last + 1
    if (root.expandedSlot >= n && root.expandedSlot < panes.length) n = root.expandedSlot + 1
    return n
  }

  function addPane() {
    if (!root.canAddPane()) return
    var n = root.visibleCount
    var panes = root.cfg.panes.slice(0, n).concat([Model.emptyPane()])
    root.expandedSlot = n
    root.updateFn(root.workspaceId, { panes: panes })
  }

  // "+" only offers a next slot once the last shown one actually has
  // something in it -- slots fill in strictly in order. NOT gated on either
  // Auto Launch switch: launchers can be set up here with them off, same as
  // the editor itself (the switches decide whether they fire, not whether
  // they can be configured).
  function canAddPane() {
    var n = root.visibleCount
    return n < 4 && (n === 0 || root.paneHasData(n - 1))
  }

  // "Launch now" only makes sense with something configured to launch, and
  // with both the global and this workspace's Auto Launch on.
  function canLaunchNow() {
    return root.autoLaunchEnabled && root.cfg.autoLaunchEnabled && root.savedLauncherCount > 0
  }

  // Auto Launch is live here (global + this workspace on) with N windows set
  // to launch. Drives the focus border on the thumbnail, and from 2 windows up
  // the tile layout drawn on it plus the arrows that cycle the options.
  // Counts what's CONFIGURED either way: the grid, the layout cycler and the
  // full-screen pick all stay usable while Auto Launch is off for this
  // workspace -- launchLive is what decides whether any of it would fire, and
  // so which hue the overlay draws in.
  readonly property int launchCount: Model.configuredCount(root.cfg.panes)
  readonly property bool launchLive: root.autoLaunchEnabled && root.cfg.autoLaunchEnabled

  // This workspace's own pool, if it differs from the global one (poolFolder
  // itself is declared above, with the source-folder block).
  property string globalPoolFolder: ""
  readonly property bool poolOverridden: root.poolFolder !== "" && root.poolFolder !== root.globalPoolFolder
  readonly property string poolLabel: root.poolOverridden
    ? root.poolFolder.split("/").pop()
    : "Global"
  readonly property var launchOptions: Model.launchLayouts(root.launchCount)
  readonly property int launchLayoutIdx: Model.launchLayoutIndex(root.launchCount, root.cfg.launchLayout)
  // During a rebuild launchOptions and launchLayoutIdx can update a beat
  // apart, which indexed past the end of the array. Everything that indexes
  // it uses this clamped form instead.
  readonly property int safeLayoutIdx: Math.min(root.launchLayoutIdx, Math.max(0, root.launchOptions.length - 1))

  // One hover region per launcher on the preview: the real grid at 2+
  // windows, or the whole box standing for the one launcher there is at
  // exactly 1 (no grid to divide it into).
  readonly property var hoverRectsRaw: {
    if (root.launchOptions.length > 0) return root.launchOptions[root.safeLayoutIdx].rects
    if (root.launchCount === 1) return [[0, 0, 1, 1]]
    return []
  }
  // Every one of these Repeaters (the overlay's tiles, the hover areas, the
  // grips, the per-tile buttons) uses this as its MODEL, and a Repeater
  // rebuilds every delegate the moment the model is a different ARRAY -- even
  // an identical one. `hoverRectsRaw` is rebuilt on any cfg change, so a pane
  // swap used to tear down and recreate all the tiles a frame after the drop:
  // that is the flash on the tile that moved (0: "the MOVED panel has a glow
  // flash, remove it"). Hand on the same array unless the geometry actually
  // changed.
  property var hoverRects: []
  function syncHoverRects() {
    var next = root.hoverRectsRaw
    if (JSON.stringify(next) !== JSON.stringify(root.hoverRects)) root.hoverRects = next
  }
  onHoverRectsRawChanged: root.syncHoverRects()
  Component.onCompleted: root.syncHoverRects()
  // On-tile label per hoverRects entry -- the pane's own command/app name
  // instead of a position number (0: "remove the numbers, replace with the
  // command"). "" for a tile with nothing configured (hides it).
  readonly property var launchLabels: root.hoverRects.map(function(r, i) {
    return root.paneHasData(i) ? root.paneDesc(i) : ""
  })
  // That one launcher's own info (app/command + args), noting when it's
  // the full-screen pick. "" hides the tooltip (nothing configured there).
  function hoverTextFor(idx) {
    var t = root.paneTooltip(idx)
    if (t === "") return ""
    if (root.savedLauncherCount >= 1 && idx === root.fsSlot) t += "\n(full screen)"
    return t
  }
  // Which launcher tile the pointer is on, for that tile's own ✕. Cleared on
  // a short delay: moving from the tile ONTO the ✕ takes the hover off the
  // tile, and without the delay the button would vanish from under the
  // pointer before it could be clicked. The ✕ re-marks it on the way in, so
  // the two hovers stack (0: "I know its two level hovers").
  // Drag state for the preview tiles. The overlay draws from these; the tile
  // MouseAreas below write them. dragLimit keeps the carried tile inside its
  // own neighbourhood -- it is a nudge that says "this is moving", not a
  // free-floating icon.
  // The grip currently under the pointer, before any press. Hovering it
  // marks every OTHER tile as a candidate (0: "when the name hitbox is
  // covered, change ALL tiles not chosen to a tc").
  property int gripSlot: -1
  property int dragSlot: -1
  property real dragDX: 0
  property real dragDY: 0
  property int dropSlot: -1
  // The carry is free now -- the tile goes wherever the pointer takes it
  // (0: "it gets dragged to another launcher space"). Nothing is written
  // until the drop.
  //
  // A tile is claimed when the HELD tile's centre lands inside the middle
  // 75% of its mass (0: "when the dragged tile gets inside the 75% of the
  // targets mass"), which is a 12.5% margin all round.
  function targetForCentre(u, v) {
    var rs = root.hoverRects
    for (var i = 0; i < rs.length; i++) {
      var r = rs[i]
      var mx = r[2] * 0.125
      var my = r[3] * 0.125
      if (u >= r[0] + mx && u <= r[0] + r[2] - mx
        && v >= r[1] + my && v <= r[1] + r[3] - my) return i
    }
    return -1
  }

  // ---- the landing ------------------------------------------------------
  //
  // The ONE motion a drop is allowed: on release the HELD tile grows into the
  // cell it was over, in place, and nothing happens after that (0: "After
  // mouse release, inc the tile dragged to fit the space its over, thats it,
  // dont do anything after that"). The old settle -- which grew the OTHER
  // tile, back at its own home -- is gone for good; so is any post-drop pulse.
  //
  // landFrom is the cell whose tile is in flight, landTo the cell it flies
  // into.
  property int landFrom: -1
  property int landTo: -1
  // The grid exactly as it looked at release. `swapPanes`' write is async, so
  // without this the labels and the full-screen pick would flip mid-flight and
  // the drop would read as a switch all over again. This is a display freeze
  // on a timer -- NOT a read-back of the write (see the pin's trap 2).
  property var landLabels: []
  property int landFs: -1
  readonly property var landRect: (root.landTo >= 0 && root.landTo < root.hoverRects.length)
    ? root.hoverRects[root.landTo] : null
  Timer {
    id: landClear
    // The 120ms grow plus a margin. By the time this fires the write has
    // landed, so dropping the freeze changes nothing on screen: both tiles are
    // already drawn where the live model puts them.
    interval: 160
    onTriggered: root.endLanding()
  }
  function endLanding() {
    root.landFrom = -1
    root.landTo = -1
    root.landLabels = []
    root.landFs = -1
    root.dropSlot = -1
  }

  function endDrag() {
    root.dragSlot = -1
    root.dropSlot = -1
    root.dragDX = 0
    root.dragDY = 0
  }

  property int hoverSlot: -1
  Timer {
    id: hoverSlotClear
    interval: 120
    onTriggered: root.hoverSlot = -1
  }
  function markHover(idx, on) {
    if (on) { hoverSlotClear.stop(); root.hoverSlot = idx }
    else if (root.hoverSlot === idx) hoverSlotClear.restart()
  }

  // Which tile's MIDDLE a point falls in: the central half of the cell, so a
  // trade is committed by crossing into the heart of another tile rather than
  // by grazing its edge (0: "when the users pointer hits the middle of
  // another tile"). -1 when the point is in no tile's middle.
  function rectCenterIndexAt(u, v) {
    var rs = root.hoverRects
    for (var i = 0; i < rs.length; i++) {
      var r = rs[i]
      var cx = r[0] + r[2] / 2
      var cy = r[1] + r[3] / 2
      if (Math.abs(u - cx) <= r[2] / 4 && Math.abs(v - cy) <= r[3] / 4) return i
    }
    return -1
  }

  // Which launcher tile a point (in 0..1 preview units) falls in, -1 for
  // none -- the drop target when a tile is dragged onto another.
  function rectIndexAt(u, v) {
    var rs = root.hoverRects
    for (var i = 0; i < rs.length; i++) {
      var r = rs[i]
      if (u >= r[0] && u <= r[0] + r[2] && v >= r[1] && v <= r[1] + r[3]) return i
    }
    return -1
  }

  // Open one launcher's config panel (Panel watches expandedSlot).
  function openLauncher(idx) {
    root.expandedSlot = idx
    root.editLauncherRequested(idx)
  }

  function cycleLayout(dir) {
    var c = root.launchOptions.length
    if (c < 2) return
    root.updateFn(root.workspaceId, { launchLayout: (((root.launchLayoutIdx + dir) % c) + c) % c })
  }
  // Bound as the cycler pills' hover text, which is evaluated even while the
  // row is hidden -- so it has to survive there being no layouts at all.
  function layoutTip() {
    var o = root.launchOptions
    if (!o || o.length === 0) return ""
    return "Layout: " + o[root.safeLayoutIdx].name + " (" + (root.safeLayoutIdx + 1) + "/" + o.length + ")"
  }

  // Removes the slot outright (0: "add a remove Auto Launcher... bump all
  // numbers below up one, and go back to add a launcher") -- splices it out
  // rather than blanking it in place, so a later slot never sits without an
  // earlier one (the strictly-progressive rule). Shifts the full-screen pick
  // down with whatever was after the removed slot, or clears it if the
  // removed slot WAS the pick.
  // Empties THIS workspace's launchers in one write -- the per-workspace twin
  // of the main panel's Clear-all glyph (0: "add a garbage glyph, same as
  // main, put it beside the liE auto launch button"). It clears the slots and
  // the full-screen pick; it does NOT touch either Auto Launch switch, same
  // as the main panel's.
  function clearLaunchers() {
    root.expandedSlot = -1
    root.updateFn(root.workspaceId, { panes: [], fullScreenIndex: -1 })
  }

  function removePane(idx) {
    var panes = root.cfg.panes.slice()
    panes.splice(idx, 1)
    var patch = { panes: panes }
    if (root.fsSlot === idx) patch.fullScreenIndex = -1
    else if (root.fsSlot > idx) patch.fullScreenIndex = root.fsSlot - 1
    root.expandedSlot = -1
    root.updateFn(root.workspaceId, patch)
  }

  Column {
    id: column
    width: Style.space(340)
    spacing: Style.spacing.md

    Item {
      width: column.width
      implicitHeight: childrenRect.height
      AuditTag { tag: "1"; shown: root.auditTags }
      RowLayout {
        width: column.width
        spacing: Style.spacing.controlGap

        // Double-sized SilverStone mark, same as the main panel's title and the
        // launcher-config panel's (0: "font and icon all panels titles in this
        // format").
        Text {
          Layout.alignment: Qt.AlignVCenter
          textFormat: Text.PlainText
          text: ""
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Math.round(Style.font.body * 2)
          AuditTag { tag: "1a"; shown: root.auditTags; below: true }
        }

        Text {
          textFormat: Text.PlainText
          text: "WS" + (root.workspaceId === 10 ? "10 (0)" : String(root.workspaceId))
          AuditTag { tag: "1b"; shown: root.auditTags; below: true }
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.heading
          font.bold: true
          Layout.fillWidth: true
        }
      }
    }

    PanelSeparator {
      width: column.width
      foreground: root.foreground
      AuditTag { tag: "2"; shown: root.auditTags; atRight: true }
    }

    // The "Change Wallpaper" pill that used to sit here is gone (0: "lose the
    // Change Wallpaper pill, set does the job") -- "Set" on the preview opens
    // the picker for this workspace's pool. In its place, the first of the
    // two "..." triggers for li's settings block, right under the first
    // delimiter where 0 asked for it.
    Item {
      width: column.width
      // The row is as tall as the taller of the two, ALWAYS -- `implicitHeight`
      // is read whether or not the "+" is showing, so li does not change height
      // when the fourth launcher makes it disappear.
      implicitHeight: Math.max(settingsDots.implicitHeight,
        Math.max(addLauncherButton.implicitHeight, poolResetButton.implicitHeight))

      // Add the next launcher. Deliberately NOT gated on Auto Launch being on:
      // li is meant to be editable with the switches off, and with the gate on
      // there was no way to add a launcher at all while Global Auto Launch was
      // off -- which is what 0 hit ("were missing add auto launch button").
      // Left-justified on this row, with the dots still centred on it.
      Button {
        id: addLauncherButton
        visible: root.canAddPane()
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "+"
        AuditTag { tag: "4c"; shown: root.auditTags; below: true }
        bordered: true
        foreground: root.foreground
        horizontalPadding: Style.spacing.sm
        // Still matched to "Set" on the preview, so the two read as a pair
        // even now that they are not on the same surface.
        implicitWidth: setButton.implicitWidth
        // Counts up as slots fill, and the button itself vanishes at 4 (0).
        property bool tipOn: false
        onHovered: function(isHovered) { addLauncherButton.tipOn = isHovered }
        SsToolTip {
          visible: addLauncherButton.tipOn
          text: root.savedLauncherCount === 0
            ? "Add Launcher" : "Add Launcher " + (root.savedLauncherCount + 1)
        }
        onClicked: root.addPane()
      }

      // Back to the Global pool. This is the control the picker's "Use
      // Default" used to be, re-homed here when that button row went down to
      // one (0 chose to keep it rather than drop it with the dead props). It
      // only exists while this workspace HAS its own pool -- with nothing
      // overridden there is nothing to reset, so it stays out of the way.
      Button {
        id: poolResetButton
        visible: root.poolOverridden
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Global"
        bordered: true
        foreground: root.foreground
        horizontalPadding: Style.spacing.sm
        AuditTag { tag: "3c"; shown: root.auditTags; below: true }
        property bool tipOn: false
        onHovered: function(isHovered) { poolResetButton.tipOn = isHovered }
        SsToolTip {
          visible: poolResetButton.tipOn
          text: "This WorkSpace uses its own pool (" + root.poolLabel
            + ") — click to hand it back to the Global pool"
        }
        onClicked: root.poolResetRequested()
      }

      Text {
        id: settingsDots
        AuditTag { tag: "3"; shown: root.auditTags }
        // Right-justified now (0: "right just ify the ... on the li Editor"),
        // matching the main panel's own "..." row. It steps aside for the
        // "Global" reset button when that one is showing, since they share
        // this row's right end.
        anchors.right: parent.right
        anchors.rightMargin: poolResetButton.visible
          ? poolResetButton.width + Style.spacing.controlGap : 0
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "..."
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true

        MouseArea {
          id: settingsDotsMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          // Opens the pool picker as a child panel to li's left, modelled on
          // the global pool picker (0), instead of dropping it in place. A
          // second click closes it again.
          onClicked: root.poolPickRequested()

          // It was the one unlabelled control on li (0).
          SsToolTip {
            visible: settingsDotsMouse.containsMouse
            text: "Set Custom Pool\nfor WorkSpace " + (root.workspaceId === 10 ? "10 (0)" : String(root.workspaceId))
            fontSize: Style.font.body
          }
        }
      }
    }

    // Cycler arrows sit BESIDE the preview, level with its middle, and are
    // plain icon buttons rather than pills (0). The preview gives up their
    // width so nothing overlaps it.
    Item {
      width: column.width
      implicitHeight: childrenRect.height
      AuditTag { tag: "4"; shown: root.auditTags; atRight: true }
      RowLayout {
        width: column.width
        spacing: Style.spacing.xs

        PanelActionButton {
          Layout.alignment: Qt.AlignVCenter
          // HELD IN THE LAYOUT, always. `visible: false` takes an item out of a
          // RowLayout, which handed its width to the preview -- and the preview
          // is height-bound to its own width (56:38), so li grew taller with no
          // launchers and shrank the moment a second one brought the cyclers
          // back (0: "when the li windo has no launchers it lurches larger ...
          // that pane shouldnt lurch"). Opacity keeps the space reserved, so
          // the preview -- and li -- stay one size throughout.
          opacity: root.launchOptions.length > 1 ? 1 : 0
          enabled: root.launchOptions.length > 1
          iconText: "‹"
          AuditTag { tag: "4a"; shown: root.auditTags }
          foreground: root.foreground
          onClicked: root.cycleLayout(-1)
        }

        Rectangle {
          id: previewBox
          AuditTag { tag: "4b"; shown: root.auditTags; inside: true }
          // Inside a RowLayout the layout owns the geometry, so the 56:38 ratio
          // has to come through Layout.preferredHeight -- a plain `height` was
          // overridden and collapsed the preview to nothing.
          Layout.fillWidth: true
          Layout.preferredHeight: Math.round(width * 38 / 56)
          color: Qt.darker(root.foreground, 3)
          radius: Style.cornerRadius
          clip: true

          Image {
            anchors.fill: parent
            visible: root.previewPath !== ""
            source: root.previewPath !== "" ? Util.fileUrl(root.previewPath) : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 640
            sourceSize.height: 360
          }

          // Clicking the preview opens the picker for whichever source is
          // currently assigned (Global pool, or Custom outside-pool image) --
          // declared first so the layout-cycle arrows below still take priority
          // over it where they overlap.
          MouseArea {
            id: previewMouse
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.outsideSelected) root.browseImageRequested(); else root.browsePoolRequested()
          }

          Text {
            anchors.centerIn: parent
            visible: root.previewPath === ""
            textFormat: Text.PlainText
            text: "no image set"
            color: Qt.darker(root.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          // Where the auto-launched windows will tile (2+ windows), and which
          // one (if any) opens full screen.
          LaunchLayoutOverlay {
            anchors.fill: parent
            // hoverRects, not launchOptions: at exactly one launcher there is no
            // grid, but its command still gets drawn as plain text in the middle
            // of the whole preview (0: "if theres a command/app set on a
            // pane/tile, show it in plain text in the middle of the tile, not on
            // top" -- i.e. in the tile itself, not only in the hover popup).
            visible: root.launchCount > 0
            rects: root.hoverRects
            lineColor: root.foreground
            // Frozen while a tile is landing, so the async swap never flips a
            // label under the flight.
            labels: root.landTo >= 0 ? root.landLabels : root.launchLabels
            // One step down (0: "li item numbers -1 pt"). showFsCaption stays
            // at its default true, so the full-screen pick keeps its glyph and
            // "(fullscreen)" caption (0: "there should still be a full screen
            // glyph").
            // Three quarters of what it was (0: "reduce the sice of the li
            // items by 75%") -- 11px -> 8px, which also gives a long command
            // room to wrap inside its tile.
            labelPixelSize: Math.max(Style.space(6), Math.round(Style.font.bodySmall * 0.75))
            fullscreenIndex: root.landTo >= 0 ? root.landFs
              : (root.fsEligible ? root.fsSlot : -1)
            // Left at the overlay's own white default -- no orange here any more.
            // Same disabled hue the main panel's cards use, so ticking the
            // checkbox below re-hues both at once.
            launchEnabled: root.launchLive
            // Whichever tile is "chosen" right now -- held, or just under
            // the pointer's grip. Everything else lights as a candidate.
            othersIndex: root.dragSlot >= 0 ? root.dragSlot : root.gripSlot
            // Same tile: the one whose grip the pointer is on (or is carrying).
            // Its command goes accent and its hit box shows as a pill.
            labelHotIndex: root.dragSlot >= 0 ? root.dragSlot : root.gripSlot
            dragIndex: root.dragSlot
            dragDX: root.dragDX
            dragDY: root.dragDY
            dropIndex: root.dropSlot
            landIndex: root.landFrom
            landRect: root.landRect
          }

          // Per-launcher hover (0: "no buddy, on hover, for each launcher set,
          // show its installed launcher or command" -- not a combined list, one
          // region per cell, each showing only THAT launcher's own info). One
          // rect covering the whole preview when there's a single launcher (no
          // grid to divide it). Clicking a tile that HAS data opens the edit
          // popup for it instead of passing through to the wallpaper picker
          // (0's long-planned "preview click opens a launcher dialogue once 1+
          // are configured" -- "Set Wallpaper" above exists precisely to keep
          // wallpaper-picking reachable once this takes over the click).
          Repeater {
            model: root.hoverRects

            MouseArea {
              required property var modelData
              required property int index
              x: modelData[0] * previewBox.width
              y: modelData[1] * previewBox.height
              width: modelData[2] * previewBox.width
              height: modelData[3] * previewBox.height
              hoverEnabled: true
              onContainsMouseChanged: root.markHover(index, containsMouse)
              acceptedButtons: root.paneHasData(index) ? Qt.LeftButton : Qt.NoButton

              // Dragging lives on its own hit box over the command text
              // below; this area is the click that opens the editor.
              // Always the hand: an empty tile passes the click through to the
              // preview, which opens the wallpaper picker -- still clickable.
              cursorShape: Qt.PointingHandCursor

              // Press-and-release on the SAME tile opens that launcher's config
              // panel; drag onto another tile and the two launchers swap places
              // instead (0: "allow them to be clicked and dragged into the
              // different positions on the workspace, they just replace each
              // other one for one and keep theyre full screen status"). Only
              // meaningful once there are two tiles to trade between.
              onReleased: root.openLauncher(index)

              // NO hover pill on these tiles (0: "a pill the appears on top
              // of the tile, it has its name, dont, its info is already seen
              // on the tile preview ffs. have NOTHING there"). The command is
              // drawn in the tile itself, so the pill was the same string
              // twice, over the top of the thing it described. The main
              // panel's cards keep theirs -- they show order numbers, not
              // commands.
            }
          }

          // ---- drag handles -------------------------------------------
          //
          // An invisible box around the command text, and nothing else (0:
          // "put an invisible hit box around the desc"). Dragging a whole
          // tile fought with the click that opens the editor; the description
          // is the part that reads as "the thing itself", so that is the
          // grip. The rest of the tile stays a plain click.
          Repeater {
            model: root.hoverRects

            MouseArea {
              required property var modelData
              required property int index
              readonly property real cx: (modelData[0] + modelData[2] / 2) * previewBox.width
              readonly property real cy: (modelData[1] + modelData[3] / 2) * previewBox.height
              // THE COMMAND TEXT, and nothing more (0: "the MOVE mouseover
              // should be restricted to the text of the cmd. I told you that
              // already"). It used to be a band across 70% x 34% of the tile,
              // which is far more than the words cover -- so the four-way
              // cursor, and the drag, claimed most of the tile. `gripText`
              // below is a hidden copy of exactly what the overlay draws, so
              // `paintedWidth`/`paintedHeight` are the real ink; the box is
              // that plus a hair, and never wider than the tile.
              // A floor, so a one-word command is still grabbable, and a
              // ceiling at the tile itself (0: "add space to the hitbox like
              // you said before use your suggestion").
              readonly property real inkW: Math.min(modelData[2] * previewBox.width - 2,
                Math.max(Style.space(40), gripText.paintedWidth + Style.space(4)))
              readonly property real inkH: Math.min(modelData[3] * previewBox.height - 2,
                Math.max(Style.space(14), gripText.paintedHeight + Style.space(2)))
              // The label sits in a centred Column; when this tile is the
              // full-screen pick the "(fullscreen)" caption below it pushes the
              // command up by half the caption's height.
              readonly property real inkShift: (root.fsEligible && index === root.fsSlot)
                ? Math.round(gripText.font.pixelSize * 1.2 / 2) : 0
              width: inkW
              height: inkH
              x: cx - width / 2
              y: cy - height / 2 - inkShift

              // Never drawn -- it exists to measure. Same text, same font, same
              // wrap rules and same width as LaunchLayoutOverlay's label, so
              // its painted size IS the label's painted size.
              Text {
                id: gripText
                visible: false
                width: modelData[2] * previewBox.width - 4
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: 3
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.paneHasData(index) ? root.paneDesc(index) : ""
                font.family: Style.font.family
                font.pixelSize: Math.max(Style.space(6), Math.round(Style.font.bodySmall * 0.75))
              }
              visible: root.paneHasData(index) && root.launchCount >= 2
              enabled: visible
              hoverEnabled: true
              // 0 likes the four-way cursor: it says "this thing moves".
              cursorShape: Qt.SizeAllCursor
              acceptedButtons: Qt.LeftButton
              preventStealing: true
              onContainsMouseChanged: {
                if (containsMouse) root.gripSlot = index
                else if (root.gripSlot === index) root.gripSlot = -1
                // This band sits ON TOP of the tile's own hover area, so while
                // the pointer is over it that area reports "not hovered" and
                // the tile's ✕ vanished -- which, since the grip covers the
                // middle of the tile, is most of the time (0: "you lost the
                // delete button in the li editor tile preview"). Keep the tile
                // marked as hovered from here too.
                root.markHover(index, containsMouse)
              }

              property real pressX: 0
              property real pressY: 0

              onPressed: function(ev) {
                pressX = ev.x
                pressY = ev.y
                root.markHover(index, true)
                root.dragSlot = index
                root.dragDX = 0
                root.dragDY = 0
                root.dropSlot = -1
              }

              onPositionChanged: function(ev) {
                if (root.dragSlot !== index) return
                root.dragDX = ev.x - pressX
                root.dragDY = ev.y - pressY
                // Where the HELD tile's own centre now sits, in 0..1 preview
                // units -- that is what has to be inside the target's mass,
                // not the bare pointer.
                var u = (cx + root.dragDX) / previewBox.width
                var v = (cy + root.dragDY) / previewBox.height
                var over = root.targetForCentre(u, v)
                root.dropSlot = (over >= 0 && over !== index) ? over : -1
              }

              // Dropped on its own tile (or on nothing): everything just
              // springs back, no write, no pulse (0: "if it gets dropped in
              // its own ori tile, nothing happens, release everhting").
              onReleased: {
                var to = root.dropSlot
                var from = index
                // Dropped on its own tile, or on nothing: everything springs
                // back, no write, no motion at all.
                if (to < 0 || to === from) { root.endDrag(); return }
                // Freeze the grid as it stands, start the landing, and let go
                // of the carry. `dropSlot` deliberately stays SET until the
                // landing clears, so the tile that slid into the vacated space
                // stays there instead of popping home and back.
                root.landLabels = root.launchLabels.slice()
                root.landFs = root.fsEligible ? root.fsSlot : -1
                root.landFrom = from
                root.landTo = to
                root.dragSlot = -1
                // The pointer is still sitting on the grip, so nothing else
                // would clear this -- and every OTHER tile would stay lit as a
                // trade candidate after the drop was over. Let go of the whole
                // highlight with the button (0: "just drop the selected pane,
                // dont flash the moved one").
                root.gripSlot = -1
                root.dragDX = 0
                root.dragDY = 0
                root.panesSwapRequested(from, to)
                landClear.restart()
              }
              onCanceled: { root.endDrag(); root.endLanding() }
            }
          }

          // Remove THIS launcher. Top-right of its own tile, and PERMANENT
          // (0: "your still missing a delete button, promote it to the level of
          // the otheres ... if I cant see it its missing"). It used to appear
          // only while its tile was hovered, and it sat bare on the wallpaper:
          // between the drag grip stealing the hover and a bright picture
          // behind it, it read as gone. It is now a first-class control like
          // the "+", "Set" and the full-screen toggle -- always drawn, on the
          // same dark chip, same size, and explicitly on top of everything else
          // painted on the preview. removePane() splices the slot out, so 2-4
          // close up by themselves and the full-screen pick moves down with
          // them. Red on hover, like every destructive action in the shell.
          Repeater {
            model: root.hoverRects

            Item {
              id: rmCell
              required property var modelData
              required property int index
              visible: root.paneHasData(rmCell.index)
              x: (modelData[0] + modelData[2]) * previewBox.width - width - Style.spacing.xs
              y: modelData[1] * previewBox.height + Style.spacing.xs
              width: Style.space(20)
              height: Style.space(20)
              // Above the tiles, the grip bands and the hover areas.
              z: 5

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: Qt.rgba(0, 0, 0, 0.55)
              }

              PanelActionButton {
                id: rmButton
                anchors.fill: parent
                size: parent.width
                iconText: "✕"
                foreground: root.foreground
                hoverColor: Color.urgent
                property bool tipOn: false
                onHovered: function(isHovered) {
                  rmButton.tipOn = isHovered
                  root.markHover(rmCell.index, isHovered)
                }
                SsToolTip {
                  visible: rmButton.tipOn
                  text: "Remove this launcher"
                }
                AuditTag { tag: "4g"; shown: root.auditTags }
                onClicked: root.removePane(rmCell.index)
              }
            }
          }

          // Per-tile full-screen toggle: bottom-left of every configured
          // tile, sets THAT tile to open full screen (root.fsSlot /
          // root.toggleFs). Same rects as the hover Repeater above, so index
          // lines up with the pane/slot index. Only one slot can ever be the
          // pick -- toggleFs() enforces that (a second press on the current
          // pick clears it, pressing a different tile just moves it).
          //
          // It sits on a dark chip, like the "+" and "Set" buttons. Without
          // one it was a bare glyph painted straight onto the wallpaper, and
          // over a bright image the unset state simply could not be seen --
          // which is why 0 kept reporting it as GONE even while the control
          // was there and working. Never paint a control bare over the
          // preview image.
          Repeater {
            model: root.hoverRects

            Item {
              id: fsCell
              required property var modelData
              required property int index
              readonly property bool fsPick: root.fsSlot === fsCell.index
              visible: root.fsEligible && root.paneHasData(fsCell.index)
              x: modelData[0] * previewBox.width + Style.spacing.xs
              y: modelData[1] * previewBox.height + modelData[3] * previewBox.height - height - Style.spacing.xs
              width: Style.space(20)
              height: Style.space(20)

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                // Unset: the dark chip every control over the preview wears.
                // The pick: the CHIP goes accent and the glyph is knocked out
                // of it (0: "theyre fine when none selected, but show a
                // different tc more boldly when selected"). Two glyph colours
                // on one dark chip were too close to tell apart; a lit chip
                // reads from across the panel. This supersedes the earlier
                // "pick and candidate stay matched in weight" ruling.
                color: fsCell.fsPick ? Color.accent : Qt.rgba(0, 0, 0, 0.55)
              }

              PanelActionButton {
                id: fsButton
                anchors.fill: parent
                size: parent.width
                iconText: ""
                // Knocked out of the accent chip when this tile IS the pick,
                // plain foreground on the dark chip when it is only a
                // candidate. The two states no longer differ by glyph hue
                // alone -- the whole chip changes.
                // The candidate is held at half strength so the pick's lit
                // chip carries all the weight (0: "reduce the contrast of the
                // not selected full screen to 50%").
                foreground: fsCell.fsPick ? Color.popups.background
                  : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.5)
                // Hover has to move something in both states: accent glyph on
                // the dark chip, foreground glyph on the accent chip.
                hoverColor: fsCell.fsPick ? Color.foreground : Color.accent
                // Wrapped, not one long line off the side of li (0: "word wrap
                // ALL mouseovers if they bust the panel").
                property bool tipOn: false
                onHovered: function(isHovered) { fsButton.tipOn = isHovered }
                SsToolTip {
                  visible: fsButton.tipOn
                  text: fsCell.fsPick
                    ? "Opens full screen (click to unset)" : "Set to open full screen"
                }
                AuditTag { tag: "4e"; shown: root.auditTags }
                onClicked: root.toggleFs(fsCell.index)
              }
            }
          }

          // Selection border: while one launcher's config panel is open, the
          // preview it belongs to is outlined (0: "on selection on one AL, it
          // needs to have a border around the preview").
          Rectangle {
            anchors.fill: parent
            visible: root.expandedSlot >= 0
            color: "transparent"
            radius: parent.radius
            border.width: 2
            border.color: root.foreground
          }

          // The Hyprland active-border ring that used to be drawn here is
          // GONE (0: "theres a blue border arount the previloe tiles on the
          // lieditor, lose it"). It took its colour from the theme's
          // hyprland.active-border, which on this theme is #7aa2f7 -- the one
          // blue thing on li. The selection border above (foreground, while a
          // launcher's config panel is open) is the only ring left.


          // The "+" that used to sit here, top-left INSIDE the preview, is out
          // on the dots row above it now (0: "remove the add launcher out of
          // the preview panel, and place it left justified inline with the
          // ..."). The preview is the map of the workspace; the controls that
          // act on the whole thing live on the row above.

          // The preview's own "..." is gone (0: "lose the ... on the preview pane,
          // that functionality should be hidden by the top ..."). The pool picker
          // it used to reach now drops in place under the top dots instead.

          // Opens the wallpaper picker for whichever source this workspace is
          // on, top-right. With no launchers set the preview has no panes on it,
          // so clicking the image itself does the same thing.
          // Bottom-right, not top-right: the per-tile ✕ owns that corner now
          // (0: "I moved the set to the bottom because the x would clash").
          Button {
            id: setButton
            AuditTag { tag: "4d"; shown: root.auditTags; below: true }
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            anchors.margins: Style.spacing.sm
            text: "Set"
            bordered: true
            foreground: root.foreground
            background: Qt.rgba(0, 0, 0, 0.55)
            horizontalPadding: Style.spacing.sm
            // SsToolTip, so it is clamped inside li instead of running past
            // the frame from the preview's bottom-right corner.
            SsToolTip {
              visible: setButton.hot
              text: "Set Background for\nWorkSpace"
            }
            onClicked: if (root.outsideSelected) root.browseImageRequested(); else root.browsePoolRequested()
          }

          // The launcher editor is its own panel beside li now
          // (AutoLaunchConfig.qml, opened by Panel when expandedSlot >= 0), not a
          // popup over this preview (0: "when a + button is presses, it makes a new
          // panel, similar to the picker panel, to the right of its parent").
        }

        PanelActionButton {
          Layout.alignment: Qt.AlignVCenter
          // Same reservation as its twin on the left.
          opacity: root.launchOptions.length > 1 ? 1 : 0
          enabled: root.launchOptions.length > 1
          iconText: "›"
          AuditTag { tag: "4f"; shown: root.auditTags }
          foreground: root.foreground
          onClicked: root.cycleLayout(1)
        }
      }
    }

    // The Global/Custom source block that used to live here (radios,
    // image-path field, Select, per-workspace randomize) is GONE: the two
    // pills above replaced the only ways into it -- "Set" opens the picker
    // and "Change Wallpaper" rerolls -- and the source now follows
    // whichever picker made the pick (see Panel.finishBrowse).



    // Auto Launch gets its own delimited block here too (0).
    PanelSeparator {
      // Same reason as the cyclers: hiding it outright shortened li by its
      // height plus a row gap the moment the last launcher was removed. It
      // keeps its place in the column and just stops being drawn.
      opacity: (root.savedLauncherCount > 0 || root.expandedSlot >= 0) ? 1 : 0
      width: column.width
      foreground: root.foreground
      AuditTag { tag: "5"; shown: root.auditTags; atRight: true }
    }

    // Per-workspace Auto Launch, styled exactly like the main panel's Global
    // Auto Launch row (0: "style it after the main Auto Launch Disable style,
    // copy it over"): label left, ToggleSwitch right. Soft tint when on, soft
    // red when off -- same rule as the global row.
    // Always on screen from the moment li opens, never conditional: it used
    // to appear only once a launcher existed, so the row popped in later and
    // shoved everything below it down (0: "write it to screen on panel load,
    // so it doesnt jerk"). With nothing configured it renders greyed and
    // inert instead of vanishing.
    Item {
      width: column.width
      implicitHeight: childrenRect.height

    RowLayout {
      id: autoLaunchRow
      width: column.width
      // Tighter than controlGap, exactly like the main panel's row: at the
      // glyph's toggle-matched size the standard gap runs the cluster past
      // the panel border (trap 4).
      spacing: Style.spacing.sm

      readonly property bool hasLaunchers: root.savedLauncherCount > 0 || root.expandedSlot >= 0

      Text {
        id: autoLaunchLabel
        Layout.alignment: Qt.AlignVCenter
        textFormat: Text.PlainText
        // Just the words now (0: "remode the (disabled) make it look like
        // main") -- the main panel's row does not spell its state out either.
        // The toggle beside it says enabled/disabled, in its own red.
        // No fillWidth: that stretched the label into the gap and pushed the
        // glyph off the row. The spacer below does the pushing instead.
        text: "Auto Launch"
        AuditTag { tag: "6"; shown: root.auditTags }
        // White when live, greyed back when off -- not red (0: "make 6 white
        // when on, and greyed out when disabled, (not red)"). 1.9 is the same
        // step the built-in panels use for a de-emphasised label. The toggle
        // beside it keeps its own red ("but the button stays").
        // Greyed right back when this workspace has no launchers at all, so
        // the row reads as inert rather than as a live setting.
        color: !parent.hasLaunchers ? Qt.darker(root.foreground, 2.4)
          : (root.launchLive ? root.foreground : Qt.darker(root.foreground, 1.9))
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap

        // The only hover on this row, and only while there is nothing set --
        // it says how to get started (0). With launchers configured the label
        // already states enabled/disabled, so it stays quiet.
        MouseArea {
          id: alHintMouse
          anchors.fill: parent
          hoverEnabled: !parent.parent.hasLaunchers

          SsToolTip {
            visible: alHintMouse.containsMouse && !parent.parent.parent.hasLaunchers
            text: "(Click the + on the Preview)\nTo Enable Auto Launch"
            fontSize: Style.font.body
          }
        }
      }

      ToggleSwitch {
        id: wsAutoLaunchToggle
        enabled: parent.hasLaunchers
        opacity: parent.hasLaunchers ? 1 : 0.45
        checked: root.cfg.autoLaunchEnabled
        // Off reads in the same red the tiles use when auto launch is
        // blocked (0: "color the auto launch toggle buttons the same red as
        // the tile outline when blocking"); on is untouched.
        foreground: root.launchLive ? Color.foreground : "#e08a8a"
        AuditTag { tag: "6a"; shown: root.auditTags }
        onToggled: root.updateFn(root.workspaceId, { autoLaunchEnabled: !root.cfg.autoLaunchEnabled })
      }

      // One spacer: label+toggle cluster left, glyph hard right, and the rule
      // drawn OVER the row's centre line -- the main panel's arrangement,
      // copied whole.
      Item { Layout.fillWidth: true }

      // Empties this workspace's launchers. Same glyph, same size rule, same
      // accent-at-rest/red-on-hover as the main panel's Clear-all (0: "add a
      // garbage glyph, same as main").
      PanelActionButton {
        id: wsClearLaunchersButton
        AuditTag { tag: "6b"; shown: root.auditTags; below: true }
        Layout.alignment: Qt.AlignVCenter
        Layout.minimumWidth: implicitWidth
        Layout.preferredWidth: implicitWidth
        enabled: autoLaunchRow.hasLaunchers
        opacity: autoLaunchRow.hasLaunchers ? 1 : 0.45
        size: wsAutoLaunchToggle.implicitHeight
        fontSize: Style.font.iconLarge
        iconText: "\uf1f8"
        foreground: Color.accent
        hoverColor: Color.urgent
        property bool tipOn: false
        onHovered: function(isHovered) { wsClearLaunchersButton.tipOn = isHovered }
        SsToolTip {
          visible: wsClearLaunchersButton.tipOn
          text: "Clear this WorkSpace's launchers"
        }
        onClicked: root.clearLaunchers()
      }

    }

      // The delimiter: a vertical twin of PanelSeparator on the ROW's centre
      // line, 1px, three quarters of the toggle's height -- the main panel's
      // rule, same maths (0: "and a delimiter then the garbage can").
      Rectangle {
        x: Math.round(autoLaunchRow.width / 2)
        y: autoLaunchRow.y + Math.round((autoLaunchRow.height - height) / 2)
        width: 1
        height: Math.round(wsAutoLaunchToggle.implicitHeight * 0.75)
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
      }
    }

    // Clone, a line BELOW the Auto Launch row and hard right (0: "drop the
    // clone workspace a line below and justified rt"). At rest it is just the
    // one mark; pressing it plays 0's sequence left to right at an even 130ms
    // step, once, and the finished line stays -- across panel opens now, not
    // just this one.
    Item {
      width: column.width
      implicitHeight: cloneBox.implicitHeight

      Item {
        id: cloneBox
        AuditTag { tag: "8"; shown: root.auditTags }
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: cloneRow.implicitWidth
        implicitHeight: cloneRow.implicitHeight

        // Plays ON CLICK now, not on hover (0: "on click three dashes three
        // glyphs with commas, then ... after the last glyph").
        //
        // 0 = at rest, just the parent mark. 1-3 = that many dashes (the ">"
        // lands with the third). Then alternating mark/comma: 4 = 1st copy,
        // 5 = comma, 6 = 2nd copy, 7 = comma, 8 = 3rd copy, then 10/11/12
        // add the trailing "..." ONE DOT AT A TIME at the same step as the
        // rest (0: "have the ... come out at the same pace as the rest").
        property int phase: 0
        property bool playing: false
        // Three states, in this order (0: "on hover, before a click, change
        // to a theme color, but the animation goes back the the ori color,
        // then its spent till next"):
        //   at rest            -- the original dimmed foreground
        //   hovered, unspent   -- the theme accent, saying "press me"
        //   playing / spent    -- back to the original, and it stays there
        // Nothing turns white any more.
        readonly property color glyph: (cloneMouse.containsMouse
          && !cloneBox.playing && !root.cloneAlreadyShown)
          ? Color.accent : Qt.darker(root.foreground, 1.5)

        // Already run this panel-open? Come up fully drawn, don't replay.
        Component.onCompleted: if (root.cloneAlreadyShown) cloneBox.phase = 12

        function play() {
          if (root.cloneAlreadyShown) { cloneBox.phase = 12; return }
          cloneBox.phase = 0
          cloneBox.playing = true
        }

        function reset() {
          cloneBox.playing = false
          cloneBox.phase = 0
        }

        Timer {
          id: cloneStep
          running: cloneBox.playing && cloneBox.phase < 12
          repeat: true
          // One even step the whole way through -- no pauses (0: "lose the
          // delays"), they left the commas reading as a stray ellipsis.
          interval: 130
          onTriggered: {
            cloneBox.phase = cloneBox.phase + 1
            if (cloneBox.phase < 12) return
            // Done. It plays ONCE and stops (0: "the animation is on hover,
            // once and thats it") -- no loop. If the pointer has already left
            // (a click opens the Clone panel, which takes it) wind back to
            // rest so the next hover starts clean.
            // ONE run per panel-open, and the finished line STAYS. The Clone
            // panel opens HERE, at the end of the run, not on the press that
            // started it (0: "the clone button runs once then when its done,
            // open the clone diag") -- the line is the countdown to it.
            cloneBox.playing = false
            root.cloneShown()
            root.cloneOpenRequested()
          }
        }

        // Nothing happens on hover any more. The PRESS runs it, once, and
        // that is the only run there is until the panel has been closed and
        // opened again (0: "no more runs until the window opens again and it
        // is pressed") -- play() is a no-op once cloneAlreadyShown is set.

        Row {
          id: cloneRow
          spacing: 0

          Text {
            id: cloneHead
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: ""
            color: cloneBox.glyph
            // Same weight as the main panel's Clear-all trash glyph, which is
            // iconLarge (0: "inc the clone glyph so it is the same as the
            // delete glyph on main"). The dashes, commas and dots stay at body
            // size -- the MARK is the control, the line is its trail.
            font.family: Style.font.family
            font.pixelSize: Style.font.iconLarge + 2
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: {
              var n = Math.min(cloneBox.phase, 3)
              var out = " "
              for (var i = 0; i < n; i++) out += "-"
              // The head lands once the shaft is full (0: "8 is missing >
              // after the dashes"), same as the main panel's arrow did.
              if (n >= 3) out += ">"
              return out
            }
            color: cloneBox.glyph
            font.family: Style.font.family
            font.pixelSize: Style.font.body + 2
          }

          Repeater {
            // The three copies after the arrow, each with the comma that
            // precedes it once the sequence has got that far. The first has
            // none -- it sits straight after the ">".
            model: [{ mark: 4, sep: -1 }, { mark: 6, sep: 5 }, { mark: 8, sep: 7 }]

            Row {
              required property var modelData
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: modelData.sep > 0 && cloneBox.phase >= modelData.sep
                textFormat: Text.PlainText
                text: ","   // no space (0: "lose the spaces between commas")
                color: cloneBox.glyph
                font.family: Style.font.family
                font.pixelSize: Style.font.body + 2
              }

              Text {
                id: copyMark
                anchors.verticalCenter: parent.verticalCenter
                visible: cloneBox.phase >= modelData.mark
                textFormat: Text.PlainText
                // The leading space only survives on the FIRST of these (the one
                // with no comma before it) -- after a comma the glyph sits tight
                // against it (0: "lose the spaces between commas"; the gap was
                // this space, not the comma).
                text: (modelData.sep > 0 ? "" : " ") + ""
                color: cloneBox.glyph
                font.family: Style.font.family
                font.pixelSize: Style.font.iconLarge + 2
                // Grows in rather than snapping (0: "starting small and
                // gowning to its current size").
                scale: visible ? 1 : 0.3
                Behavior on scale { NumberAnimation { duration: 300; easing.type: Easing.OutBack } }
              }
            }
          }

          // The tail 0 asked for: once the 7th mark has landed, "..." closes
          // the line out (0: "add 3 more glyphs, then ... at the end"). A
          // sibling of the Repeater, NOT a second delegate inside it.
          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: cloneBox.phase >= 10
            textFormat: Text.PlainText
            text: ".".repeat(Math.max(0, Math.min(3, cloneBox.phase - 9)))
            color: cloneBox.glyph
            font.family: Style.font.family
            font.pixelSize: Style.font.body + 2
          }
        }

        MouseArea {
          id: cloneMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            // First press of the panel-open plays the line and the panel
            // opens when it lands. Once it has run, the line is spent for
            // this panel-open: a press just toggles the Clone panel.
            if (root.cloneAlreadyShown) { root.cloneOpenRequested(); return }
            cloneBox.play()
          }

          SsToolTip {
            visible: cloneMouse.containsMouse
            // Changes once the line has run, for the rest of this panel-open
            // (0: "no run again, until the hover over 'You Know you Want
            // To!'").
            text: root.cloneAlreadyShown ? "You Know you Want To!" : "Clone this WorkSpace"
            fontSize: Style.font.body
          }
        }
      }
    }

    // The old stacked accordion (one row per slot, inline Dropdown+args
    // editor, "Remove Auto Launcher") and "Launch now" are DEPRECATED (0,
    // 2026-09-22). Adding/editing/removing a launcher happens in the Pane
    // config panel beside li.
    //
    // SAVE IS GONE (0: "on WP remove save button, we will leave that to esc
    // just remove it") -- everything here writes live, so the button only ever
    // closed the panel, which Escape does. The delimiter that separated it
    // from the Auto Launch row went with it (0: "remove the bottom delimiter
    // after all that"), and the clone moved UP onto that row, right-justified,
    // so li's last line reads like the main panel's: the Auto Launch state on
    // the left, its one glyph control on the right.
  }

  // Declared last, so it sits above everything above: while a child panel is
  // open this eats every click aimed at li (see childOpen).
  MouseArea {
    id: childBlocker
    anchors.fill: parent
    visible: root.childOpen
    enabled: root.childOpen
    hoverEnabled: true
    acceptedButtons: Qt.AllButtons
    onPressed: {}
    onClicked: function(mouse) {
      // Second hole: the PREVIEW. A click on it closes whatever child is open
      // (0: "the WP picker doesnt close on click, prpbably a rule I made but
      // change it, only a click on the pane though"). It was this blanket
      // eating the click, so Panel's handler never ran.
      var pv = mapToItem(previewBox, mouse.x, mouse.y)
      if (pv.x >= 0 && pv.y >= 0 && pv.x <= previewBox.width && pv.y <= previewBox.height) {
        root.childDismissRequested()
        return
      }
      // One hole in the blanket: the clone glyph stays live, so pressing it
      // again closes the child it opened (0: "a click on the parents clone
      // glyph will close the child"). cloneOpenRequested already toggles.
      var p = mapToItem(cloneBox, mouse.x, mouse.y)
      if (p.x >= 0 && p.y >= 0 && p.x <= cloneBox.width && p.y <= cloneBox.height) {
        // The line stays drawn either way now -- closing the child neither
        // replays it nor winds it back.
        root.cloneOpenRequested()
      }
    }
  }
}
