import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One auto-launch pane spec: a type selector plus whatever value that type
// needs (an installed app, a webapp URL, nothing for a plain terminal, or a
// free-text shell command -- the escape hatch that lets a pane express
// something like `ssh -t silverstone 'bash -lc claude'`).
Item {
  id: root

  required property int index
  property string paneType: "command"
  property string value: ""
  property color foreground: Color.foreground

  signal changed(string paneType, string value)
  signal removeRequested()

  implicitHeight: row.implicitHeight
  implicitWidth: row.implicitWidth

  // Installed applications, sourced from Quickshell's own DesktopEntries
  // singleton -- not PluginShellApi.appLibrary, which is gated to menu-kind
  // plugins and this plugin isn't one.
  readonly property var appOptions: {
    var apps = (DesktopEntries.applications && DesktopEntries.applications.values) || []
    var out = []
    for (var i = 0; i < apps.length; i++) {
      var e = apps[i]
      if (!e || !e.id) continue
      out.push({ value: String(e.id), label: String(e.name || e.id) })
    }
    out.sort(function(a, b) { return a.label < b.label ? -1 : (a.label > b.label ? 1 : 0) })
    return out
  }

  RowLayout {
    id: row
    width: parent.width
    spacing: Style.spacing.controlGap

    Dropdown {
      Layout.preferredWidth: Style.space(110)
      showLabel: false
      options: Model.paneTypeOptions()
      value: root.paneType
      onChanged: function(v) {
        root.paneType = v
        root.value = ""
        root.changed(v, "")
      }
    }

    Dropdown {
      visible: root.paneType === "app"
      Layout.fillWidth: true
      showLabel: false
      options: root.appOptions
      value: root.value
      onChanged: function(v) { root.value = v; root.changed(root.paneType, v) }
    }

    TextField {
      visible: root.paneType === "webapp" || root.paneType === "command"
      Layout.fillWidth: true
      text: root.value
      placeholderText: Model.paneValuePlaceholder(root.paneType)
      onTextChanged: { root.value = text; root.changed(root.paneType, text) }
    }

    Text {
      visible: root.paneType === "terminal"
      Layout.fillWidth: true
      textFormat: Text.PlainText
      text: "(plain terminal, no options)"
      color: Qt.darker(root.foreground, 1.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    PanelActionButton {
      iconText: "✕"
      foreground: root.foreground
      hoverColor: Color.urgent
      onClicked: root.removeRequested()
    }
  }
}
