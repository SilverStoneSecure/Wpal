import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// The overall settings dialog: a way out from per-workspace customization
// for everyone at once (Omarchy Default = plain Omarchy theme everywhere,
// ignoring every workspace's own setup; SilverStone Custom = each workspace
// acts on its own configuration), plus the shared wallpaper pool that backs
// the "Browse" and "Randomize from Pool" pickers -- empty ("Not set"), a
// local folder, or an http(s) URL to download from once. Everything below
// Wallpaper Mode is SilverStone-only and stays hidden in Omarchy Default --
// in that mode there's nothing here at all besides the mode buttons; the
// strip's single ws1 card is what shows/picks the wallpaper, not this dialog.
Item {
  id: root

  property bool customMode: true
  // Raw setting: "" when unset, a folder path, or an http(s) URL.
  property string wallpaperRepository: ""
  // Independent of wallpaper mode -- a global kill switch for every
  // workspace's auto-launch panes, without touching what's configured.
  property bool autoLaunchEnabled: true

  signal customModeRequested(bool v)
  signal repositoryEdited(string value)
  signal browseRepositoryRequested()
  signal autoLaunchRequested(bool v)
  signal shuffleRequested()
  signal closeRequested()

  implicitWidth: column.width
  implicitHeight: column.implicitHeight

  // The two mode tiles size to whichever label is bigger (so they always
  // match) rather than a fixed constant -- ssLabel/defLabel are the Text
  // items inside each tile below; QML resolves ids anywhere in the same
  // file, not just after their declaration.
  readonly property real modeTileW: Math.max(ssLabel.implicitWidth, defLabel.implicitWidth) + Style.spacing.lg * 2
  readonly property real modeTileH: Math.max(ssLabel.implicitHeight, defLabel.implicitHeight) + Style.spacing.lg * 2

  Column {
    id: column
    width: Style.space(320)
    spacing: Style.spacing.md

    RowLayout {
      width: column.width
      spacing: Style.spacing.controlGap

      Text {
        textFormat: Text.PlainText
        text: "SilverStone Settings"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
        Layout.fillWidth: true
      }
      PanelActionButton {
        iconText: "✕"
        foreground: Color.foreground
        onClicked: root.closeRequested()
      }
    }

    PanelSectionHeader { text: "Wallpaper Mode" }

    RowLayout {
      width: column.width
      spacing: Style.spacing.controlGap

      Rectangle {
        id: silverstoneModeButton
        Layout.fillWidth: true
        Layout.preferredHeight: root.modeTileH
        radius: Style.cornerRadius
        color: root.customMode
          ? Style.selectedFillFor(Color.foreground, Color.accent)
          : (ssMouse.containsMouse ? Style.hoverFillFor(Color.foreground, Color.accent) : "transparent")
        border.width: 1
        border.color: Qt.darker(Color.foreground, 2)

        Text {
          id: ssLabel
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "SilverStone\nCustom"
          horizontalAlignment: Text.AlignHCenter
          color: root.customMode ? Style.selectedStateColor(Color.foreground, Color.accent) : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: root.customMode
        }

        MouseArea {
          id: ssMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.customModeRequested(true)
        }
      }

      Rectangle {
        id: defaultModeButton
        Layout.fillWidth: true
        Layout.preferredHeight: root.modeTileH
        radius: Style.cornerRadius
        color: !root.customMode
          ? Style.selectedFillFor(Color.foreground, Color.accent)
          : (defMouse.containsMouse ? Style.hoverFillFor(Color.foreground, Color.accent) : "transparent")
        border.width: 1
        border.color: Qt.darker(Color.foreground, 2)

        Text {
          id: defLabel
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "Omarchy\nDefault"
          horizontalAlignment: Text.AlignHCenter
          color: !root.customMode ? Style.selectedStateColor(Color.foreground, Color.accent) : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: !root.customMode
        }

        MouseArea {
          id: defMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.customModeRequested(false)
            root.closeRequested()
          }
        }
      }
    }

    // ---- SilverStone Custom only ------------------------------------------

    Column {
      visible: root.customMode
      width: column.width
      spacing: Style.spacing.md

      PanelSeparator { width: column.width; foreground: Color.foreground }

      PanelSectionHeader { text: "Global Wallpaper Pool:" }

      RowLayout {
        width: column.width
        spacing: Style.spacing.controlGap

        TextField {
          Layout.fillWidth: true
          text: root.wallpaperRepository
          placeholderText: "Not set using theme defaults"
          onEditingFinished: root.repositoryEdited(text)
        }
        Button {
          text: "Browse"
          bordered: true
          foreground: Color.foreground
          onClicked: root.browseRepositoryRequested()
        }
      }

      RowLayout {
        width: column.width
        spacing: Style.spacing.controlGap

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: "Randomize all Wallpapers from Pool"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        PanelActionButton {
          id: shuffleButton
          iconText: "♻"
          foreground: Color.foreground
          onClicked: {
            root.shuffleRequested()
            shuffleSpin.restart()
          }

          RotationAnimation {
            id: shuffleSpin
            target: shuffleButton
            from: 0
            to: 360
            duration: 400
            easing.type: Easing.OutCubic
          }
        }
      }

      PanelSeparator { width: column.width; foreground: Color.foreground }

      PanelSectionHeader { text: "Auto Launch" }

      RowLayout {
        width: column.width
        spacing: Style.spacing.controlGap

        Text {
          Layout.alignment: Qt.AlignVCenter
          textFormat: Text.PlainText
          text: "Global Auto Launch (" + (root.autoLaunchEnabled ? "enabled" : "disabled") + ")"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          Layout.fillWidth: true
        }
        ToggleSwitch {
          checked: root.autoLaunchEnabled
          onToggled: root.autoLaunchRequested(!root.autoLaunchEnabled)
        }
      }
    }
  }
}
