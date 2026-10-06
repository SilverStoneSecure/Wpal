import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One launcher's editor, as its own panel beside li rather than a popup over
// li's preview (0: "when a + button is presses, it makes a new panel, similar
// to the picker panel, to the right of its parent. I said diag box, but its a
// new panel with a title, textboxes and a clear, save delete").
//
// Titled in the shared panel format -- double-sized SilverStone mark, then
// "WS<N> Auto Launcher Config <slot>" -- the same shape the main panel and li
// use. Everything types straight through to settings (updateFn), so Save is
// just a close, like li's own (0: "save is basically just x cascades changes
// down"). Delete splices the slot out; li renumbers what's left, so a later
// launcher never sits without an earlier one.
Item {
  id: root
  property string moduleName: "io.github.silverstone.wpal"

  required property int workspaceId
  // 0-based slot into the workspace's panes; the title shows it 1-based.
  required property int slotIndex
  property var pane: null
  property var appOptions: []
  property color foreground: Color.foreground

  signal appChanged(string appId)
  signal argsChanged(string args)
  // Clear is a LOCAL edit: it empties the two boxes here and nothing cascades
  // to the previews until Save (0: "on clear on the AL edit, dont cascade
  // previews until save"). clearedDraft tracks that pending emptiness.
  property bool clearedDraft: false
  signal cleared()
  signal deleted()
  // Save, Enter and Escape all leave the same way: commit the field, then let
  // Panel close the panel -- and drop the slot entirely if nothing was set
  // (0: "if theres nothong set then the panes are minus oned and it neeeds to
  // be re added thru the plus button").
  // Carries what was just typed. The host must NOT read the saved settings
  // to decide whether this slot is empty -- the write below lands
  // asynchronously, so a read-back there sees the pane as it was before and
  // deletes the launcher that was just written (0: "the AL save button does
  // nothing").
  signal saveRequested(string appId, string args)
  signal closeRequested()

  // Enter anywhere in this panel is Save (0: "enter acts like save when
  // focised on that dialogue").
  Keys.onReturnPressed: root.commitAndSave()
  Keys.onEnterPressed: root.commitAndSave()

  // Save is what cascades: it writes the app and the args (empty ones too,
  // if Clear was pressed) and then closes.
  function commitAndSave() {
    if (root.clearedDraft) root.appChanged("")
    root.argsChanged(argsField.text)
    root.saveRequested(root.currentAppId, argsField.text)
  }

  // Commit one app from the picker -- the single path shared by a mouse click
  // and by Enter on the keyboard-driven search (0: "make arrows and tabbing
  // work in the fuzzy search").
  function selectApp(app) {
    if (!app) return
    root.clearedDraft = false
    root.draftAppId = app.value
    root.appChanged(app.value)
    root.appListOpen = false
    searchField.text = ""
    // Hand focus straight to args so the very next Enter saves and closes
    // (0: "focus is set on args, enter again closes the diag saves are
    // cascaded").
    argsField.forceActiveFocus()
  }

  // Search state for the app selector below.
  property bool appListOpen: false
  property string appFilter: ""
  // A different pane means a fresh editor -- INCLUDING the args box.
  //
  // Typing into a TextField replaces its `text` binding outright, so the
  // moment a command has been typed the box stops tracking `pane.args`: open
  // another slot and the editor still shows the last thing typed rather than
  // that slot's own command (0: "im clicking on ws4 al2 for an edit and the
  // command already assigned is not cx ... being shot over to the edit
  // dialouge"). Reloading it by hand on every pane AND slot change is the fix;
  // the declarative `text:` below only ever covers the first open.
  function loadPane() {
    root.clearedDraft = false
    root.appListOpen = false
    root.draftAppId = ""
    argsField.text = root.pane ? root.pane.args : ""
  }
  onPaneChanged: root.loadPane()
  // The pane OBJECT can stay identical when the same slot is closed and
  // reopened with no settings write in between, so the slot number is watched
  // too -- otherwise that path keeps the stale text.
  onSlotIndexChanged: root.loadPane()
  // The app just clicked, before its write has come back round through
  // settings. Same reason as saveRequested's arguments: pressing Save in the
  // same breath as picking an app would otherwise read the OLD pane, see an
  // empty launcher and bin the slot.
  property string draftAppId: ""
  readonly property string currentAppId: root.clearedDraft ? ""
    : (root.draftAppId !== "" ? root.draftAppId : ((root.pane && root.pane.appId) || ""))
  readonly property string currentAppLabel: {
    for (var i = 0; i < root.appOptions.length; i++) {
      if (root.appOptions[i].value === root.currentAppId) return root.appOptions[i].label
    }
    return root.currentAppId
  }
  readonly property var filteredApps: {
    var f = root.appFilter.toLowerCase()
    var out = []
    for (var i = 0; i < root.appOptions.length; i++) {
      var o = root.appOptions[i]
      if (f === "" || String(o.label).toLowerCase().indexOf(f) >= 0) out.push(o)
    }
    return out
  }

  readonly property string wsLabel: root.workspaceId === 10 ? "10 (0)" : String(root.workspaceId)

  implicitWidth: column.width
  implicitHeight: column.implicitHeight

  Column {
    id: column
    // Same width as li, the cloner and the picker (0: "make them the same
    // width"). 340 is li's own column width.
    width: Style.space(340)
    spacing: Style.spacing.md

    RowLayout {
      width: column.width
      spacing: Style.spacing.controlGap

      // Same double-sized mark as the other two panels' titles.
      Text {
        Layout.alignment: Qt.AlignVCenter
        textFormat: Text.PlainText
        text: ""
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.body * 2)
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        // Two lines: the workspace, then what's being edited (0: "line
        // return ... between WS1 And AutoLaunch").
        text: "WS" + root.wsLabel + "\nAuto Launch " + (root.slotIndex + 1)
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
    }

    PanelSeparator { width: column.width; foreground: root.foreground }

    // Pick an installed app, or leave it on "(none)" and let the field below
    // carry a command or a webapp URL (see Model.classifyPane).
    // App selector, in the shape of Omarchy's own apps menu: click it and a
    // searchable list of every installed app drops open; clicking a result IS
    // the selection (0's 4a -- the real menu plugin can't hand a pick back,
    // see the note in memory about doing it properly one day).
    Column {
      width: column.width
      spacing: Style.spacing.sm

      Rectangle {
        width: column.width
        height: selectedLabel.implicitHeight + Style.spacing.sm * 2
        radius: Style.cornerRadius
        color: selectorMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
        border.width: 1
        border.color: Qt.darker(root.foreground, 2)

        Text {
          id: selectedLabel
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.spacing.sm
          anchors.rightMargin: Style.spacing.sm
          textFormat: Text.PlainText
          text: root.currentAppLabel
          elide: Text.ElideRight
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        MouseArea {
          id: selectorMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: { root.appListOpen = !root.appListOpen; if (root.appListOpen) searchField.forceActiveFocus() }
        }
      }

      TextField {
        id: searchField
        visible: root.appListOpen
        width: column.width
        placeholderText: "Search apps"
        // Retyping refilters and drops the highlight back to the top hit, so
        // Enter takes the best match unless you arrow/Tab away first (0: "make
        // arrows and tabbing work in the fuzzy search").
        onTextChanged: { root.appFilter = text; appList.currentIndex = 0 }
        // Up/Down and Tab/Shift-Tab walk the results without leaving the box;
        // Enter picks the highlighted one. When the list is empty Enter falls
        // through to the panel's own Return handler (Save), untouched.
        Keys.onUpPressed: appList.moveSelection(-1)
        Keys.onDownPressed: appList.moveSelection(1)
        Keys.onReturnPressed: function(event) {
          if (root.appListOpen && appList.count > 0) {
            root.selectApp(root.filteredApps[appList.currentIndex]); event.accepted = true
          }
        }
        Keys.onEnterPressed: function(event) {
          if (root.appListOpen && appList.count > 0) {
            root.selectApp(root.filteredApps[appList.currentIndex]); event.accepted = true
          }
        }
        // Tab would move panel focus; trap it so it steps the list instead.
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Tab) { appList.moveSelection(1); event.accepted = true }
          else if (event.key === Qt.Key_Backtab) { appList.moveSelection(-1); event.accepted = true }
        }
      }

      ListView {
        id: appList
        visible: root.appListOpen
        width: column.width
        height: Math.min(Style.space(200), contentHeight)
        clip: true
        model: root.filteredApps
        currentIndex: 0
        boundsBehavior: Flickable.StopAtBounds
        // Clamp-and-scroll driven by the search box's arrow/Tab keys: keeps the
        // pick in range and always scrolled into view.
        function moveSelection(step) {
          if (count <= 0) return
          currentIndex = Math.max(0, Math.min(currentIndex + step, count - 1))
          positionViewAtIndex(currentIndex, ListView.Contain)
        }

        delegate: Rectangle {
          required property var modelData
          width: ListView.view.width
          height: appName.implicitHeight + Style.spacing.xs * 2
          radius: Style.cornerRadius
          // Highlighted by hover OR by the keyboard cursor, so mouse and
          // arrow/Tab navigation share one look.
          color: (appMouse.containsMouse || ListView.isCurrentItem)
            ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

          Text {
            id: appName
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.spacing.sm
            anchors.rightMargin: Style.spacing.sm
            textFormat: Text.PlainText
            text: modelData.label
            elide: Text.ElideRight
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          MouseArea {
            id: appMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            // The click IS the selection -- same path as keyboard Enter.
            onClicked: root.selectApp(modelData)
          }
        }
      }
    }

    TextField {
      id: argsField
      width: column.width
      text: root.pane ? root.pane.args : ""
      // With an app picked this box is that app's arguments, so it just says
      // "args" (0); with none picked it's the command/URL itself.
      placeholderText: (root.pane && root.pane.appId !== "")
        ? "args"
        : "Command, webapp URL, or blank for a plain terminal"
      onEditingFinished: root.argsChanged(text)
      // Enter in the field saves and closes, same as the button.
      onAccepted: root.commitAndSave()
    }

    RowLayout {
      width: column.width
      spacing: Style.spacing.controlGap

      // Delete sits apart on the left; the two safe actions pair up on the
      // right, Save last (0: "arrange the Clear Save Delete buttons better").
      Button {
        id: deleteButton
        text: "Delete"
        bordered: true
        foreground: root.foreground
        horizontalPadding: Style.spacing.sm
        // The longest hover text in the plugin, and this panel is narrow: it
        // wraps instead of running off the frame (0: "word wrap ALL mouseovers
        // if they bust the panel"). The built-in one-line tooltip is off.
        property bool tipOn: false
        onHovered: function(isHovered) { deleteButton.tipOn = isHovered }
        SsToolTip {
          visible: deleteButton.tipOn
          text: "Remove this launcher; the ones after it move up"
        }
        onClicked: root.deleted()
      }

      Item { Layout.fillWidth: true }

      Button {
        id: clearDraftButton
        text: "Clear"
        bordered: true
        foreground: root.foreground
        horizontalPadding: Style.spacing.sm
        // SsToolTip, not the built-in tooltipText, so this one is clamped
        // inside its own panel like every other hover (0: "CONSTRAIN ALL
        // HOVERS TO THIER RESPECTIVE PANEL").
        SsToolTip { visible: clearDraftButton.hot; text: "Empty both boxes" }
        onClicked: { root.clearedDraft = true; argsField.text = "" }
      }

      Button {
        text: "Save"
        bordered: true
        foreground: root.foreground
        horizontalPadding: Style.spacing.sm
        onClicked: root.commitAndSave()
      }
    }
  }
}
