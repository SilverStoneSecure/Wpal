import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// "Clone this Workspace to Another(s)" -- its own small panel now, opened
// beside the SilverStone-arrow button at the bottom of li (0: "bring up that
// dialouge as we did before, make it close to the button that launched it").
// It used to swap itself in over li's whole card, which put it nowhere near
// the control that opened it.
Item {
  id: root

  required property int workspaceId
  property color foreground: Color.foreground

  signal cloneRequested(var targets)
  signal closeRequested()

  implicitWidth: column.width
  implicitHeight: column.implicitHeight

  function reset() { field.text = "" }
  // The panel takes the keyboard as it opens, so typing lands in the box
  // instead of on the strip behind it (0: "hit enter, but it just felt like
  // escape").
  function focusField() { field.forceActiveFocus() }
  function commit() { if (root.canClone) root.cloneRequested(root.parsed.ids) }
  function setText(t) { field.text = t }

  // "2, 3,5" -> workspace ids. 0 means workspace 10. The workspace being
  // edited is never a valid target (cloning onto itself would only conflict
  // with its own settings): typing it is flagged and blocks Clone.
  function parseTargets(text) {
    var parts = String(text).split(",")
    var ids = [], bad = [], self = false
    for (var i = 0; i < parts.length; i++) {
      var t = parts[i].trim()
      if (t === "") continue
      if (!/^\d{1,2}$/.test(t)) { bad.push(t); continue }
      var n = parseInt(t, 10)
      if (n === 0) n = 10
      if (n < 1 || n > 10) { bad.push(t); continue }
      if (n === root.workspaceId) { self = true; continue }
      if (ids.indexOf(n) < 0) ids.push(n)
    }
    return { ids: ids, bad: bad, self: self }
  }

  readonly property var parsed: root.parseTargets(field.text)
  readonly property bool canClone: root.parsed.ids.length > 0 && root.parsed.bad.length === 0 && !root.parsed.self
  readonly property string available: {
    var out = []
    for (var n = 1; n <= 10; n++) if (n !== root.workspaceId) out.push(n)
    return out.join(", ")
  }

  Column {
    id: column
    // Matches li, which it now sits directly beneath.
    width: Style.space(340)
    spacing: Style.spacing.md

    RowLayout {
      width: column.width
      spacing: Style.spacing.controlGap

      // Shared panel-title format: double-sized mark, then the title.
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
        // Plain "Clone WS<N>", no quote marks -- matches the unquoted WS<N>
        // label used everywhere else (AutoLaunchConfig, WallpaperPicker,
        // CustomizeDialog). The "to another(s)" tail moved out of the title --
        // the caption under the separator already says it.
        text: "Clone WS" + (root.workspaceId === 10 ? "10 (0)" : String(root.workspaceId))
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
    }

    PanelSeparator { width: column.width; foreground: root.foreground }

    Text {
      width: column.width
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: "Clone this WorkSpace to Another(s)"
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    // Tab walks field -> Cancel -> Clone and back (0: "allow tabbing"). The
    // field takes the focus when the panel opens, so typing works immediately
    // and the first Tab lands somewhere predictable.
    TextField {
      id: field
      width: column.width
      activeFocusOnTab: true
      focus: true
      Component.onCompleted: field.forceActiveFocus()
      placeholderText: "Workspaces, comma separated: 2, 3, 5"
      onAccepted: if (root.canClone) root.cloneRequested(root.parsed.ids)
    }

    // No notes under the textbox (0: "no note below the textbox, thats your
    // logic to figure out") -- the parsing rules still hold, they're just not
    // narrated: bad or self-referencing input simply leaves Clone disabled.

    RowLayout {
      width: column.width
      spacing: Style.spacing.controlGap

      // Cancel is gone (0: "delete the cancel from the clone diag, we will
      // let esc handle that") -- same call as li's Save and the picker's
      // buttons. Escape and a click outside both close this.
      Item { Layout.fillWidth: true }
      Button {
        enabled: root.canClone
        opacity: root.canClone ? 1 : 0.4
        text: "Clone"
        bordered: true
        focusable: true
        foreground: root.foreground
        horizontalPadding: Style.spacing.sm
        onClicked: root.cloneRequested(root.parsed.ids)
      }
    }
  }
}
