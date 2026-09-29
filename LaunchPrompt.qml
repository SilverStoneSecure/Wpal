import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The Y/N gate shown when "Auto Launch Ask" (global or per-workspace) is on
// and an empty workspace gains focus. Hosted by Service.qml, which owns all
// the state: it sets `workspaceId` (0 = hidden) and reacts to `answered`.
//
// Same HUD posture as the strip/dialog: a full-screen transparent overlay
// with an input mask over just the card, so clicks elsewhere reach whatever
// is underneath. Keyboard focus is primed Exclusive for a moment so Y / N /
// Enter / Esc work right away, then drops to on-demand.
PanelWindow {
  id: win

  property int workspaceId: 0
  // Offer "turn the nag off" (this workspace's own Ask). False when the
  // Global Ask is what raised the prompt -- global always wins, so a
  // workspace can't opt out of it and the offer would do nothing.
  property bool canTurnOff: false
  readonly property string workspaceName: workspaceId === 10 ? "WS10 (0)" : "WS" + workspaceId
  signal answered(bool launch)
  signal turnOffRequested()

  visible: workspaceId > 0
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "silverstone-launch-prompt"
  WlrLayershell.layer: WlrLayer.Overlay

  property bool focusPrimed: false
  WlrLayershell.keyboardFocus: focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive

  onVisibleChanged: {
    if (visible) {
      focusPrimed = false
      primeTimer.restart()
      Qt.callLater(function() { frame.forceActiveFocus() })
    } else {
      primeTimer.stop()
      focusPrimed = false
    }
  }

  Timer {
    id: primeTimer
    interval: 75
    onTriggered: win.focusPrimed = true
  }

  readonly property real tileSize: Style.space(120)
  readonly property real tileGap: Style.space(16)

  // The current Omarchy theme's own green (colors.toml `green`), same source
  // as the Omarchy mode tile's pulse in Panel.qml; fallback until it loads.
  property color themeGreen: "#9ece6a"
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var m = /^\s*green\s*=\s*"(#[0-9a-fA-F]{6})"/m.exec(text())
      if (m) win.themeGreen = m[1]
    }
  }

  component PromptTile: Rectangle {
    id: tile
    property string label: ""
    property color glowColor: Color.accent
    signal clicked()

    width: win.tileSize
    height: win.tileSize
    radius: Style.cornerRadius
    color: tileMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"
    border.width: 1
    border.color: Qt.darker(Color.popups.text, 2)

    TileGlow { glowColor: tile.glowColor; hovered: tileMouse.containsMouse }

    Text {
      anchors.centerIn: parent
      width: parent.width - Style.spacing.sm * 2
      textFormat: Text.PlainText
      text: tile.label
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.clicked()
    }
  }

  anchors.top: true
  anchors.bottom: true
  anchors.left: true
  anchors.right: true

  mask: Region {
    x: frame.x
    y: frame.y
    width: frame.width
    height: frame.height
  }

  BorderSurface {
    id: frame
    x: Math.round((win.width - width) / 2)
    y: Math.round((win.height - height) / 2)
    width: content.implicitWidth + Style.spacing.panelPadding * 2
    height: content.implicitHeight + Style.spacing.panelPadding * 2
    color: Color.popups.background
    radius: Style.cornerRadius
    borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    focus: true

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Y || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        win.answered(true)
        event.accepted = true
      } else if (event.key === Qt.Key_N || event.key === Qt.Key_Escape) {
        win.answered(false)
        event.accepted = true
      }
    }

    Column {
      id: content
      x: Style.spacing.panelPadding
      y: Style.spacing.panelPadding
      spacing: Style.spacing.md

      Text {
        textFormat: Text.PlainText
        text: win.workspaceName
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        text: "Launch your preconfigured Auto Launch windows?"
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      // Two equal squares, same look as the mode picker's tiles: transparent
      // at rest, a hover fill, and a pulsing glow (theme green for yes,
      // danger red for no).
      Row {
        x: Math.round((content.implicitWidth - width) / 2)
        spacing: win.tileGap

        PromptTile {
          label: "Yes"
          glowColor: win.themeGreen
          onClicked: win.answered(true)
        }
        PromptTile {
          label: "Just fn open"
          glowColor: Color.urgent
          onClicked: win.answered(false)
        }
      }

      // Only when this workspace's own Ask raised the prompt: one button
      // that says so and, clicked, switches that Ask off (launches this time,
      // never asks again until it's re-enabled in the workspace's "li"
      // editor).
      Rectangle {
        visible: win.canTurnOff
        width: content.implicitWidth
        height: nagText.implicitHeight + Style.spacing.sm * 2
        radius: Style.cornerRadius
        color: nagMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"
        border.width: 1
        border.color: Qt.darker(Color.popups.text, 2)

        Text {
          id: nagText
          anchors.centerIn: parent
          width: parent.width - Style.spacing.sm * 2
          textFormat: Text.PlainText
          text: "You have this\n" + win.workspaceName + "\nset to auto launch.\nTurn this Nag off Here..."
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: nagMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: win.turnOffRequested()
        }
      }
    }
  }
}
