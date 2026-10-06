import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import qs.Commons
import qs.Ui

// The wallpaper picker: a contact sheet of thumbnails (file mode) or a
// folder ladder (pool mode), redrawn from scratch for Omarchy parity.
//
// Titled like its parent panels -- double-sized SilverStone mark, then the
// title, on a row of its own. That row used to end in a ✕; all the ✕s were
// removed for Omarchy parity, so Escape or a click outside cancels instead.
//
// Browse into folders, pick an image, Escape or an outside click cancels.
// Folder-only mode (pickFiles: false) keeps the "Choose this folder" button.
// Built on Qt's FolderListModel, never QtQuick.Dialogs --
// that crashes Quickshell on this machine (a dconf-worker/GLib heap
// corruption when the native GTK portal picker opens, confirmed via two
// matching coredumps).
Item {
  id: root
  property string moduleName: "io.github.silverstone.wpal"

  property string folder: Quickshell.env("HOME")
  property bool pickFiles: true

  // ONE constant height for the browsing area, in every mode and every
  // folder. Content-driven sizing was the mistake: it killed the dead space
  // but made the picker resize as you moved around.
  // Whatever is showing -- the browse list, or the thumbnail strip when there
  // is nothing to browse into -- fills exactly this, so the frame never moves.
  // Folder mode overrides it with a two-cell box; see sheetBox.
  readonly property real bodyH: Style.space(200)
  property var nameFilters: []
  property color foreground: Color.foreground
  property string currentPath: ""
  // Whose wallpaper is being picked, for the title. 0 when the pick isn't
  // tied to one workspace -- the global pool browse and Omarchy Default's
  // single picker.
  property int workspaceId: 0
  // Whether THIS workspace has its own raw pool override (as opposed to
  // following the global pool) -- gates "Use Global Pool" below so it isn't
  // shown as a no-op when there's nothing to reset.
  property bool poolOverridden: false

  signal chosen(string path)
  // File mode's "Use this folder": the picture is chosen by clicking it, so
  // this hands the FOLDER back separately -- Panel makes it that workspace's
  // pool.
  signal folderChosen(string path)
  signal cancelled()
  // Two different resets moved in here from li's own settings row: this
  // workspace's own pool override back to following whatever the global pool
  // currently is, or the GLOBAL pool
  // itself back to the omarchy theme folder. Panel.qml wires these to
  // clearWsPool()/setPoolFolder("") -- same actions, just triggered from
  // where the decision is actually being made now.
  signal poolResetRequested()
  signal globalPoolResetRequested()

  // The contact sheet's hovered file name, drawn in one band across the
  // bottom of the sheet rather than inside the thumbnail it belongs to.
  property string sheetHover: ""

  // The image under the pointer (or the selected one), shown in whichever
  // preview the current style has.
  property string hoverPath: ""
  onFolderChanged: { root.hoverPath = ""; root.sheetHover = ""; root.selectedIndex = -1 }
  readonly property string shownPath: root.hoverPath !== "" ? root.hoverPath : root.currentPath

  // Keyboard cursor into whichever grid/list is actually showing. -1 =
  // nothing highlighted yet -- the first arrow press just
  // lands on index 0 rather than moving from it. Panel.qml's pickerFrame
  // owns the real Keys handlers (same place Escape is already wired) and
  // calls moveSelection()/activateSelection() below; there was no keyboard
  // path into this picker at all before this pass, mouse-only throughout.
  property int selectedIndex: -1
  // The contact sheet is a fixed three-across grid (see sheet.cellWidth
  // below); the ladder is one column.
  readonly property int selectionCols: root.pickFiles ? 3 : 1
  readonly property int selectionCount: root.pickFiles ? imageModel.count : dirModel.count

  function moveSelection(dx, dy) {
    var count = root.selectionCount
    if (count === 0) return
    if (root.selectedIndex < 0) { root.selectedIndex = 0; return }
    var next = root.selectedIndex + dx + dy * root.selectionCols
    root.selectedIndex = Math.max(0, Math.min(count - 1, next))
    if (root.pickFiles) sheet.positionViewAtIndex(root.selectedIndex, GridView.Contain)
    else ladder.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  // Delegates aren't exposed through the model itself (FolderListModel has
  // no get()/data() from JS) -- itemAtIndex reads the actual instantiated
  // delegate, same fileName/fileIsDir every click handler here already uses.
  function activateSelection() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.selectionCount) return
    if (root.pickFiles) {
      var cell = sheet.itemAtIndex(root.selectedIndex)
      if (!cell) return
      if (cell.fileIsDir) root.folder = folderModel.currentPath + "/" + cell.fileName
      else root.chosen(folderModel.currentPath + "/" + cell.fileName)
    } else {
      var rung = ladder.itemAtIndex(root.selectedIndex)
      if (!rung) return
      root.folder = folderModel.currentPath + "/" + rung.fileName
    }
  }

  implicitWidth: column.width
  implicitHeight: column.implicitHeight

  // "/home/user/Pictures" -> [{label: "/home", path: "/home"},
  //                            {label: "/user", path: "/home/user"}, ...].
  // Rebuilt whenever the folder changes; each entry keeps the full path it
  // stands for, so a click is just an assignment to root.folder.
  readonly property var crumbs: {
    var p = folderModel.currentPath
    var parts = p.split("/").filter(function(x) { return x !== "" })
    var out = [{ label: "/", path: "/" }]
    var acc = ""
    for (var i = 0; i < parts.length; i++) {
      acc += "/" + parts[i]
      out.push({ label: parts[i] + (i < parts.length - 1 ? "/" : ""), path: acc })
    }
    return out
  }

  function goUp() {
    var p = folderModel.currentPath
    root.folder = p.substring(0, p.lastIndexOf("/")) || "/"
  }

  // Folders only. The ladder runs off this in BOTH modes, which is what gives
  // the image picker a way DOWN the tree -- it had the ↑ and nothing else.
  FolderListModel {
    id: dirModel
    folder: Util.fileUrl(root.folder)
    showDirs: true
    showFiles: false
    showDotAndDotDot: false
    sortField: FolderListModel.Name
  }

  // Images only, for the contact sheet: with the ladder carrying the folders,
  // the sheet is nothing but pictures.
  FolderListModel {
    id: imageModel
    folder: Util.fileUrl(root.folder)
    showDirs: false
    showFiles: true
    showDotAndDotDot: false
    sortField: FolderListModel.Name
    nameFilters: root.nameFilters
  }

  // Still the path source, and the model the two alternate styles (V1 Two
  // Pane, V3 Stage) browse with.
  FolderListModel {
    id: folderModel
    readonly property string currentPath: String(folder).replace(/^file:\/\//, "")
    folder: Util.fileUrl(root.folder)
    showDirs: true
    showFiles: root.pickFiles
    showDotAndDotDot: false
    sortField: FolderListModel.Name
    nameFilters: root.nameFilters
  }

  Column {
    id: column
    // Just inside li's 340.
    width: Style.space(320)
    // Tighter than md: the old gap left the thumbnail strip floating away
    // from the path line above it.
    spacing: Style.spacing.sm

    // ---- title row, in the shared panel format ---------------------------
    RowLayout {
      width: column.width
      spacing: Style.spacing.controlGap

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
        // Folder mode is a POOL picker -- but it can be the global pool or one
        // workspace's own, and it used to hardcode "Global WallPaper Pool" for
        // both. li's "..." therefore announced itself as global while editing
        // a single workspace. A workspace's own pool is its CUSTOM pool, said
        // in full so it can't be read as the global one. The image picker's
        // title is deliberately left alone.
        text: root.workspaceId > 0
          ? ("WS" + (root.workspaceId === 10 ? "10 (0)" : String(root.workspaceId))
             + (root.pickFiles ? " Background" : " Custom Background Pool"))
          : (root.pickFiles ? "Background" : "Global Background Pool")
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
    }

    PanelSeparator { width: column.width; foreground: root.foreground }

    // ---- path row, shared by all three styles ----------------------------
    RowLayout {
      width: column.width
      spacing: Style.spacing.controlGap

      // Bigger than the other action buttons and breathing while it sits
      // idle: it is the primary way back up the tree, sized and animated to
      // stay easy to find. The glyph itself holds still -- an accent glow
      // behind it swells and fades instead, which reads at a glance without
      // anything moving. Hover kills the animation stone dead: from then on
      // the button just does its job and nothing else.
      Item {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: upButton.implicitWidth
        implicitHeight: upButton.implicitHeight

        Rectangle {
          anchors.fill: upButton
          radius: Style.cornerRadius
          color: Color.accent
          visible: !upButton.hot
          opacity: 0

          SequentialAnimation on opacity {
            running: !upButton.hot
            loops: Animation.Infinite
            NumberAnimation { to: 0.5; duration: 750; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0.06; duration: 750; easing.type: Easing.InOutSine }
          }
        }

        PanelActionButton {
          id: upButton
          anchors.fill: parent
          iconText: "↑"
          size: Style.space(28)
          fontSize: Style.font.iconLarge
          property bool hot: false
          foreground: root.foreground
          hoverColor: Color.accent
          // Clamped inside the picker frame like every other hover here.
          SsToolTip { visible: upButton.hot; text: "Up one folder" }
          onHovered: function(isHovered) { upButton.hot = isHovered }
          onClicked: root.goUp()
        }
      }

      // Every folder on the way here is a button now. Walking to another
      // pool meant pressing ↑ once per level and reading a truncated line to
      // know where you were -- one press on any crumb jumps straight there.
      // The row scrolls itself
      // to the tail, so the folder you are IN is always the one on screen.
      Item {
        Layout.fillWidth: true
        implicitHeight: crumbRow.implicitHeight
        clip: true

        Row {
          id: crumbRow
          x: Math.min(0, parent.width - width)
          spacing: 0

          Repeater {
            model: root.crumbs

            Text {
              required property var modelData
              textFormat: Text.PlainText
              text: modelData.label
              color: crumbMouse.containsMouse ? Color.accent : root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.underline: crumbMouse.containsMouse

              MouseArea {
                id: crumbMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.folder = parent.modelData.path
              }
            }
          }
        }
      }
    }

    // ---- the strip preview, both pool pickers -----------------------------
    //
    // A single row of what is actually IN the folder you are standing in, so
    // the pool you are about to take is not a guess. Global pool and
    // per-workspace pool are the same component in pool mode, so one strip
    // serves both.
    //
    // INERT. Nothing here takes a click -- the pictures are evidence, not
    // controls; the ladder moves you and "Use this Folder" takes the folder.
    // The list itself does not drag-scroll either: the two arrows page it,
    // one screenful at a time.
    //
    // ALWAYS visible in pool mode now, empty folder or not. This used to
    // collapse to zero height on an empty folder -- same class of bug the
    // ladder below was already fixed
    // for ("FOUR rows, always"). Since the dialog's own height is
    // content-driven off this column, reserving the strip's space here is
    // the whole fix; nothing in Panel.qml needs to change.
    RowLayout {
      id: stripRow
      visible: !root.pickFiles
      width: column.width
      spacing: Style.spacing.xs

      readonly property real thumbH: Style.space(54)
      readonly property bool overflowing: strip.contentWidth > strip.width

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        // Held in the layout either way, so the strip does not jump sideways
        // as folders change.
        opacity: stripRow.overflowing ? 1 : 0
        enabled: stripRow.overflowing
        iconText: "\u2039"
        foreground: root.foreground
        onClicked: strip.page(-1)
      }

      ListView {
        id: strip
        Layout.fillWidth: true
        Layout.preferredHeight: stripRow.thumbH
        orientation: ListView.Horizontal
        clip: true
        interactive: false
        boundsBehavior: Flickable.StopAtBounds
        spacing: Style.spacing.xs
        model: imageModel

        // Sits in the strip's own reserved space instead of letting it
        // collapse -- same tone as the ladder's own empty-state line below.
        Text {
          anchors.centerIn: parent
          visible: imageModel.count === 0
          textFormat: Text.PlainText
          text: "(no images in this folder)"
          color: Qt.darker(root.foreground, 1.8)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        function page(dir) {
          var maxX = Math.max(0, contentWidth - width)
          contentX = Math.max(0, Math.min(contentX + dir * width, maxX))
        }
        // A folder change starts the strip back at its left edge.
        onModelChanged: contentX = 0

        delegate: Rectangle {
          required property string filePath
          width: Math.round(stripRow.thumbH * 16 / 9)
          height: stripRow.thumbH
          radius: Style.cornerRadius
          color: Qt.darker(root.foreground, 3)
          clip: true
          // Evidence, not a chooser (see the strip's own comment above) --
          // dimmed to read as a preview-only surface, not a pickable
          // thumbnail.
          opacity: 0.5

          Image {
            anchors.fill: parent
            source: Util.fileUrl(filePath)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 320
          }
        }
      }

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        opacity: stripRow.overflowing ? 1 : 0
        enabled: stripRow.overflowing
        iconText: "\u203a"
        foreground: root.foreground
        onClicked: strip.page(1)
      }
    }

    // ---- pool picker: the ladder -------------------------------------------
    //
    // One folder per line, full width, flat -- a chevron, the name, and a
    // hover bar. No tiles, no chips, no boxes: the tiles read as blanks and
    // the chips still boxed every name in its own frame.
    //
    // FOUR rows, always. That is the whole point of it: a folder with two
    // subfolders and a folder with forty are exactly the same height, and the
    // rest run under the wheel against the slim bar on the right.
    Item {
      id: poolLadder
      // Both modes: the pool takes a folder with it, the image picker walks
      // down the tree with it.
      // NOT gated on the folder having children any more. A leaf folder --
      // the theme's own backgrounds directory is one: seven pictures, no
      // subfolders -- made the ladder vanish, and with the pool picker having
      // no preview by design the panel came up as a title, a path and some
      // buttons. It keeps its four rows and says it is empty instead.
      width: column.width
      readonly property real rowH: Style.space(26)
      height: rowH * 4

      Text {
        anchors.centerIn: parent
        visible: dirModel.count === 0
        textFormat: Text.PlainText
        text: "(no folders in here — " + (imageModel.count === 1
          ? "1 picture)" : imageModel.count + " pictures)")
        color: Qt.darker(root.foreground, 1.8)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      ListView {
        id: ladder
        anchors.fill: parent
        anchors.rightMargin: Style.space(6)
        clip: true
        model: dirModel
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          id: rung
          required property string fileName
          required property bool fileIsDir
          required property int index
          width: ListView.view.width
          height: poolLadder.rowH
          radius: Style.cornerRadius
          // Keyboard cursor OR mouse hover, whichever's live.
          color: (index === root.selectedIndex || rungMouse.containsMouse)
            ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

          Text {
            id: rungChevron
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm
            textFormat: Text.PlainText
            text: "▸"
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: rungChevron.right
            anchors.leftMargin: Style.spacing.sm
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.sm
            textFormat: Text.PlainText
            text: rung.fileName
            elide: Text.ElideRight
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          MouseArea {
            id: rungMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.folder = folderModel.currentPath + "/" + rung.fileName
          }
        }
      }

      // The same slim bar the contact sheet uses, so a deep folder still
      // says how far down it goes without costing a row of arrows.
      Rectangle {
        anchors.right: parent.right
        width: Style.space(4)
        radius: width / 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
        visible: ladder.contentHeight > ladder.height
        height: Math.max(Style.space(20), parent.height * (ladder.height / Math.max(1, ladder.contentHeight)))
        y: ladder.contentHeight > ladder.height
          ? (ladder.contentY / (ladder.contentHeight - ladder.height)) * (parent.height - height)
          : 0
      }
    }

    // ---- the contact sheet: every image as a thumbnail --------------------
    // Three across; folders are
    // slim full-width rows above them. Pick by clicking the picture itself.
    // Height follows the CONTENT now, not a fixed 260. Three across, so nine
    // images is three rows: up to that it shrink-wraps
    // exactly, beyond it it grows to the cap -- "show them until the pane
    // bottom" -- and the arrows below page through the rest.
    Item {
      id: sheetBox
      // File mode only: the pool browses with the ladder above it, and a
      // folder full of pictures is not a pool picker.
      //
      // NOT gated on imageModel.count any more -- same class of bug as
      // stripRow and poolLadder above, just missed in both of those passes.
      // Collapsing this ~200px block on every image-less folder (common while
      // navigating down toward a picture)
      // resized the whole dialog and everything below it, including the
      // button row. Keeps its reserved height and says it's empty instead.
      visible: root.pickFiles
      width: column.width
      readonly property int rows: Math.ceil(imageModel.count / 3)
      // Always the body height, never the row count -- the grid scrolls
      // inside it instead of the frame growing and shrinking.
      height: root.bodyH

    Text {
      anchors.centerIn: parent
      visible: imageModel.count === 0
      textFormat: Text.PlainText
      text: "(no images in this folder)"
      color: Qt.darker(root.foreground, 1.8)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    GridView {
      id: sheet
      anchors.fill: parent
      anchors.rightMargin: Style.space(6)
      clip: true
      cellWidth: Math.floor((column.width - Style.space(6)) / 3)
      cellHeight: Math.round(Math.floor((column.width - Style.space(6)) / 3) * 9 / 16) + Style.spacing.sm
      model: imageModel
      boundsBehavior: Flickable.StopAtBounds

      // One screenful of rows at a time, for the arrows below.
      function page(dir) {
        var maxY = Math.max(0, contentHeight - height)
        contentY = Math.max(0, Math.min(contentY + dir * height, maxY))
      }

      delegate: Item {
        required property int index
        required property string fileName
        required property bool fileIsDir
        width: GridView.view.cellWidth
        height: GridView.view.cellHeight

        Rectangle {
          anchors.fill: parent
          anchors.margins: Style.spacing.xs / 2
          radius: Style.cornerRadius
          color: fileIsDir ? Qt.rgba(0, 0, 0, 0.25) : Qt.darker(root.foreground, 3)
          // Keyboard cursor OR mouse hover, whichever's live.
          border.width: (parent.index === root.selectedIndex || cellMouse.containsMouse) ? 2 : 0
          border.color: root.foreground
          clip: true

          Image {
            anchors.fill: parent
            visible: !fileIsDir
            source: fileIsDir ? "" : Util.fileUrl(folderModel.currentPath + "/" + fileName)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 240
          }

          // Folders read as text; images caption only while hovered, so the
          // sheet stays a sheet of pictures.
          Text {
            anchors.centerIn: parent
            width: parent.width - Style.spacing.sm
            visible: fileIsDir
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "▸ " + fileName
            elide: Text.ElideRight
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          // The name is no longer drawn in here -- see the band at the foot
          // of the sheet.
          MouseArea {
            id: cellMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: {
              if (containsMouse && !fileIsDir) root.sheetHover = fileName
              else if (!containsMouse && root.sheetHover === fileName) root.sheetHover = ""
            }
            onClicked: {
              if (fileIsDir) root.folder = folderModel.currentPath + "/" + fileName
              else root.chosen(folderModel.currentPath + "/" + fileName)
            }
          }
        }
      }
    }

      // The hovered file's name, spanning the whole panel and wrapping when
      // it needs to. Clipped inside its own 100px thumbnail it was three
      // elided characters; here it has the full width and up to three lines.
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: hoverName.implicitHeight + Style.spacing.xs * 2
        visible: root.sheetHover !== ""
        radius: Style.cornerRadius
        color: Qt.rgba(0, 0, 0, 0.8)
        z: 2

        Text {
          id: hoverName
          anchors.centerIn: parent
          width: parent.width - Style.spacing.sm * 2
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: root.sheetHover
          wrapMode: Text.WrapAtWordBoundaryOrAnywhere
          maximumLineCount: 3
          elide: Text.ElideRight
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }

      // Slim scrollbar, so a folder with more images than fit stays inside
      // the panel instead of running past it.
      Rectangle {
        anchors.right: parent.right
        width: Style.space(4)
        radius: width / 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
        visible: sheet.contentHeight > sheet.height
        height: Math.max(Style.space(20), parent.height * (sheet.height / Math.max(1, sheet.contentHeight)))
        y: sheet.contentHeight > sheet.height
          ? (sheet.contentY / (sheet.contentHeight - sheet.height)) * (parent.height - height)
          : 0
      }
    }

    // Arrows page the sheet when the folder holds more than fits. Hidden
    // entirely when everything is already on screen, so they add no dead
    // space of their own. Centred, and inside column.width -- they never
    // widen it.
    RowLayout {
      // File mode only. The pool's stack is strip -> picker -> buttons and
      // nothing else, so its two lines scroll on the wheel against the slim
      // scrollbar instead of costing a row.
      visible: root.pickFiles && sheet.contentHeight > sheet.height
      width: column.width
      spacing: Style.spacing.xs

      Item { Layout.fillWidth: true }

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        iconText: "\u2039"
        foreground: root.foreground
        onClicked: sheet.page(-1)
      }

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        iconText: "\u203a"
        foreground: root.foreground
        onClicked: sheet.page(1)
      }

      Item { Layout.fillWidth: true }
    }


    // ---- the button row, both modes ---------------------------------------
    //
    // Was ONE button, centred -- Escape and a click outside already
    // close this, and the ladder is how you get anywhere else. Two reset
    // buttons joined it later, each visible only in the ONE context it means
    // something in (see their own comments below); in file mode (picking a
    // single image) it's still "Use this Folder" alone, same as always --
    // a picture is chosen by clicking the picture, this only hands back the
    // folder it lives in.
    Item {
      width: column.width
      // Read a button's own implicitHeight, not the Row's: Row excludes
      // invisible children from its own implicit size, and in the
      // pickFiles+workspaceId===0 case (single global-override image) every
      // button in the row is hidden, which collapsed this whole area to 0 --
      // a visible panel-size change across picker invocations. A button's
      // implicitHeight is unaffected by its own visibility, so this stays
      // fixed no matter which buttons are shown.
      implicitHeight: useFolderButton.implicitHeight

      Row {
        id: buttonRow
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.spacing.controlGap

        // This workspace's own pool override, back to following the global
        // pool -- moved here from li's settings row, where it read "Global".
        // Per-workspace pool browse only -- meaningless during the global
        // browse itself or a single-image pick.
        Button {
          anchors.verticalCenter: parent.verticalCenter
          visible: !root.pickFiles && root.workspaceId > 0 && root.poolOverridden
          text: "Use Global Pool"
          bordered: true
          foreground: root.foreground
          horizontalPadding: Style.spacing.sm
          onClicked: root.poolResetRequested()
        }

        // The GLOBAL pool itself, back to the omarchy theme folder. Global
        // pool browse only -- showing "Use Global Pool" alongside this on a
        // per-workspace browse too was tried and reverted: three buttons was
        // one too many, so each context shows only the button that applies
        // to it.
        Button {
          anchors.verticalCenter: parent.verticalCenter
          visible: !root.pickFiles && root.workspaceId === 0
          text: "Revert to Default"
          bordered: true
          foreground: root.foreground
          horizontalPadding: Style.spacing.sm
          onClicked: root.globalPoolResetRequested()
        }

        Button {
          id: useFolderButton
          anchors.verticalCenter: parent.verticalCenter
          // Nothing to set it on for the Omarchy Default browse (workspaceId 0),
          // so file mode only offers it for a workspace's own picker.
          visible: !root.pickFiles || root.workspaceId > 0
          text: "Use this Folder"
          bordered: true
          foreground: root.foreground
          horizontalPadding: Style.spacing.sm
          onClicked: {
            if (root.pickFiles) root.folderChosen(folderModel.currentPath)
            else root.chosen(folderModel.currentPath)
          }
        }
      }
    }
  }
}
