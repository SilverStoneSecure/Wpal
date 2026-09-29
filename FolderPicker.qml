import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import qs.Commons
import qs.Ui

// A local-filesystem browser built on Qt's own FolderListModel -- not
// QtQuick.Dialogs' native File/FolderDialog, which reproducibly crashes the
// whole Quickshell process on this system (a dconf-worker/GLib heap
// corruption when the native GTK-backed picker opens, confirmed via two
// matching coredumps: "glib/gmem.c:106: failed to allocate 4 bytes" inside
// libdconfsettings.so). FolderListModel is pure Qt with no GTK/dconf
// involvement, so it can't hit that path.
//
// pickFiles: false browses/selects directories only (Choose button picks the
// current directory). pickFiles: true additionally lists files matching
// nameFilters and clicking one selects it directly.
Item {
  id: root

  property string folder: Quickshell.env("HOME")
  property bool pickFiles: false
  property var nameFilters: []
  property color foreground: Color.foreground

  // The wallpaper already assigned for whatever this picker is browsing
  // for, shown in the preview pane until something is hovered -- so the
  // pane isn't dead space on open.
  property string currentPath: ""

  signal chosen(string path)
  signal cancelled()

  // Row under the pointer (files only), for the hover thumbnail below.
  property int hoverIndex: -1
  property string hoverPath: ""
  onFolderChanged: { root.hoverIndex = -1; root.hoverPath = "" }

  // With files (the image pickers) a preview pane sits beside the list, and
  // the list itself narrows to compensate -- the full 340px folder-only
  // width otherwise left a wide strip of dead space next to the preview.
  readonly property real previewPaneW: Style.space(160)
  readonly property real listPaneW: root.pickFiles ? Style.space(200) : column.width
  readonly property real filesRowW: root.listPaneW + (root.pickFiles ? Style.spacing.sm + root.previewPaneW : 0)
  implicitWidth: root.filesRowW
  implicitHeight: column.implicitHeight

  function goUp() {
    var p = folderModel.currentPath
    var parent = p.substring(0, p.lastIndexOf("/"))
    root.folder = parent || "/"
  }

  FolderListModel {
    id: folderModel
    readonly property string currentPath: String(folder).replace(/^file:\/\//, "")
    folder: Util.fileUrl(root.folder)
    showDirs: true
    showFiles: root.pickFiles
    showDotAndDotDot: false
    showHidden: false
    nameFilters: root.pickFiles ? root.nameFilters : []
    sortField: FolderListModel.Type
  }

  Column {
    id: column
    width: Style.space(340)
    spacing: Style.spacing.sm

    RowLayout {
      width: root.filesRowW
      spacing: Style.spacing.sm * 2

      Text {
        textFormat: Text.PlainText
        text: folderModel.currentPath
        // No longer fillWidth/elide -- stays only as wide as the path needs
        // (so the up arrow sits close to it, not stranded far to the right
        // by empty fill space), capped at the picker's own width and word
        // wrapped past that instead of eliding.
        wrapMode: Text.WrapAnywhere
        Layout.maximumWidth: column.width
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
      PanelActionButton {
        iconText: "↑"
        foreground: root.foreground
        onClicked: root.goUp()
      }

      Item { Layout.fillWidth: true }
    }

    Row {
      spacing: Style.spacing.sm

      // Preview pane, now to the LEFT of the list (0: "swap the preview
      // and the list left to right in the wallpaper picker"): the thumbnail
      // of the image under the pointer, vertically centered. Takes no mouse
      // input, so hover stays on the row.
      Item {
        visible: root.pickFiles
        width: root.previewPaneW
        height: listHost.height

        Rectangle {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          height: Math.round(width * 9 / 16)
          visible: root.hoverPath !== "" || root.currentPath !== ""
          color: Qt.darker(root.foreground, 3)
          radius: Style.cornerRadius
          clip: true

          Image {
            anchors.fill: parent
            source: {
              var p = root.hoverPath !== "" ? root.hoverPath : root.currentPath
              return p !== "" ? Util.fileUrl(p) : ""
            }
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 320
            sourceSize.height: 180
          }
        }
      }

      Item {
        id: listHost
        width: root.listPaneW
        height: Style.space(220)

        ListView {
          id: fileList
          anchors.fill: parent
          clip: true
          model: folderModel

          delegate: Rectangle {
            id: rowItem
            required property int index
            required property string fileName
            required property bool fileIsDir

            width: ListView.view.width
            height: Math.max(Style.space(28), nameText.implicitHeight + Style.spacing.xs * 2)
            color: rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
            radius: Style.cornerRadius

            Text {
              id: nameText
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.spacing.sm
              anchors.rightMargin: Style.spacing.sm
              textFormat: Text.PlainText
              text: (fileIsDir ? "▸ " : "") + fileName
              wrapMode: Text.WrapAnywhere
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: {
                if (containsMouse && !fileIsDir) {
                  root.hoverIndex = rowItem.index
                  root.hoverPath = folderModel.currentPath + "/" + fileName
                } else if (!containsMouse && root.hoverIndex === rowItem.index) {
                  root.hoverIndex = -1
                  root.hoverPath = ""
                }
              }
              onClicked: {
                if (fileIsDir) root.folder = folderModel.currentPath + "/" + fileName
                else root.chosen(folderModel.currentPath + "/" + fileName)
              }
            }
          }
        }
      }
    }

    Button {
      visible: !root.pickFiles
      text: "Choose this folder"
      bordered: true
      foreground: root.foreground
      onClicked: root.chosen(folderModel.currentPath)
    }
  }
}
