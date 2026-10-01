import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import qs.Commons
import qs.Ui

// The wallpaper picker, redrawn from scratch in three competing styles (0:
// "I want to rework the wallpaper picker, its kind of ugly, make three new
// styles, same functionality, and a version selector so i can test the
// different versions"). `version` picks one; the ‹ n/3 › control in the title
// row cycles it live, so all three can be compared without a restart.
//
// Titled like its parent panels -- double-sized SilverStone mark, then the
// title, on a row of its own. That row used to end in a ✕; all the ✕s were
// removed for Omarchy parity, so Escape or a click outside cancels instead.
//
// Same behaviour in all three: browse into folders, pick an image, Escape or
// an outside click cancels. Folder-only mode (pickFiles: false) keeps the "Choose this
// folder" button. Built on Qt's FolderListModel, never QtQuick.Dialogs --
// that crashes Quickshell on this machine (see FolderPicker.qml).
Item {
  id: root

  property string folder: Quickshell.env("HOME")
  property bool pickFiles: true

  // ONE constant height for the browsing area, in every mode and every
  // folder. Content-driven sizing was the mistake: it killed the dead space
  // but made the picker resize as you moved around (0: "the picker itself is
  // thrashing around ... make a picker that doesnt trash the height around").
  // Whatever is showing -- the browse list, or the thumbnail strip when there
  // is nothing to browse into -- fills exactly this, so the frame never moves.
  // Folder mode overrides it with a two-cell box; see sheetBox.
  readonly property real bodyH: Style.space(200)
  property var nameFilters: []
  property color foreground: Color.foreground
  property string currentPath: ""
  // Whose wallpaper is being picked, for the title (0: "a Wapp Paper Title
  // WS<N> WallPaper"). 0 when the pick isn't tied to one workspace -- the
  // global pool browse and Omarchy Default's single picker.
  property int workspaceId: 0
  // 1 = Two Pane, 2 = Contact Sheet, 3 = Stage. 0 picked Contact Sheet, so
  // that is the default; the cycler stays for now so 1 and 3 are still
  // reachable for comparison.
  property int version: 2
  readonly property int versionCount: 3
  // Which pool picker is showing: 1 = the chip rail (two lines of name
  // chips), 2 = the ladder (full-width name rows). Only folder mode uses it.
  // `debugPoolStyle 1|2` flips it live, the way `version` does for files.
  property int poolStyle: 2
  readonly property string versionName: root.version === 1 ? "Two Pane"
    : (root.version === 2 ? "Contact Sheet" : "Stage")

  signal chosen(string path)
  // File mode's "Use this folder": the picture is chosen by clicking it, so
  // this hands the FOLDER back separately -- Panel makes it that workspace's
  // pool (0: mimic GWP's buttons "into the WS wallpaper").
  signal folderChosen(string path)
  signal cancelled()
  signal versionPicked(int version)
  // Two different resets moved in here from li's own settings row (0: "move
  // the Global Button out of LIE and into the picker... add a revert to
  // default button to the picker"): this workspace's own pool override back
  // to following whatever the global pool currently is, or the GLOBAL pool
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

  // Keyboard cursor into whichever grid/list is actually showing (0: "allow
  // in the fuzzy picker that a user can use the arrow buttons, and enter to
  // select"). -1 = nothing highlighted yet -- the first arrow press just
  // lands on index 0 rather than moving from it. Panel.qml's pickerFrame
  // owns the real Keys handlers (same place Escape is already wired) and
  // calls moveSelection()/activateSelection() below; there was no keyboard
  // path into this picker at all before this pass, mouse-only throughout.
  property int selectedIndex: -1
  // Contact Sheet is a fixed three-across grid (see sheet.cellWidth below);
  // the ladder is one column. Only these two default, reachable views get a
  // keyboard cursor -- V1/V2/Stage and the chip-rail pool style are
  // debug-only alternates nobody hits day to day.
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

  // "/home/chad/Pictures" -> [{label: "/home", path: "/home"},
  //                            {label: "/chad", path: "/home/chad"}, ...].
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
  function cycleVersion(dir) {
    var v = root.version + dir
    if (v > root.versionCount) v = 1
    if (v < 1) v = root.versionCount
    root.version = v
    root.versionPicked(v)
  }

  // Folders only. The ladder runs off this in BOTH modes, which is what gives
  // the image picker a way DOWN the tree -- it had the ↑ and nothing else
  // (0: "on the picker itself, its broken, it can only go up").
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
    // Just inside li's 340 (0: "narrow it to just thinner than its parent").
    width: Style.space(320)
    // Tighter than md: the old gap left the thumbnail strip floating away
    // from the path line above it (0: "the slider should be right up to the
    // text", "lose the dead space").
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
        // Folder mode is the pool picker, titled as 0 named it; file mode is
        // the wallpaper picker for whichever workspace opened it.
        // Folder mode is a POOL picker -- but it can be the global pool or one
        // workspace's own, and it used to hardcode "Global WallPaper Pool" for
        // both. li's "..." therefore announced itself as global while editing
        // a single workspace (0: "the ... on the LI Editor opens up global").
        // A workspace's own pool is its CUSTOM pool, said in full so it can't
        // be read as the global one (0: "WS<N> Custom WallPaper Pool"). The
        // image picker's title is deliberately left alone.
        text: root.workspaceId > 0
          ? ("WS" + (root.workspaceId === 10 ? "10 (0)" : String(root.workspaceId))
             + (root.pickFiles ? " Background" : " Custom Background Pool"))
          : (root.pickFiles ? "Background" : "Global Background Pool")
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }

      // 0 picked Contact Sheet, so the ‹ n/3 › cycler is out of the title
      // (it collided with the title at this width). The other two styles are
      // still in the file -- `debugPickerVersion 1|2|3` switches them.
    }

    PanelSeparator { width: column.width; foreground: root.foreground }

    // ---- path row, shared by all three styles ----------------------------
    RowLayout {
      width: column.width
      spacing: Style.spacing.controlGap

      // Bigger than the other action buttons and breathing while it sits
      // idle: it is the way back up the tree and 0 was hunting for it every
      // time ("takes me a moment every time"). The GLYPH itself holds still
      // now (0: "stop the pixel throbbing") -- an accent glow behind it swells
      // and fades instead, which reads at a glance without anything moving.
      // Hover kills it stone dead: from then on the button does its job and
      // nothing else (0: "do nithing when hovers except your job").
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
      // know where you were (0: "the WP pool picker si still unusable") --
      // one press on any crumb jumps straight there. The row scrolls itself
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

    // ---- pool picker, style 1: the chip rail ------------------------------
    //
    // Two lines of name chips, paging sideways on ‹ ›. Superseded as the
    // default by the ladder below (0 asked for another style); kept because
    // `debugPoolStyle 1` still reaches it for a side-by-side.
    RowLayout {
      id: poolBrowseRow
      visible: !root.pickFiles && root.poolStyle === 1 && dirModel.count > 0
      width: column.width
      spacing: Style.spacing.xs

      readonly property int rows: 2
      readonly property real chipH: Style.space(26)
      readonly property bool overflowing: poolRail.contentWidth > poolRail.width

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        visible: poolBrowseRow.overflowing
        iconText: "\u2039"
        foreground: root.foreground
        onClicked: poolRail.step(-1)
      }

      GridView {
        id: poolRail
        Layout.fillWidth: true
        Layout.preferredHeight: poolBrowseRow.rows * cellHeight
        flow: GridView.FlowTopToBottom
        clip: true
        interactive: false
        boundsBehavior: Flickable.StopAtBounds
        cellHeight: poolBrowseRow.chipH + Style.spacing.xs
        // Two chips across, so the names have room to read; more than four
        // folders and the arrows page sideways through the rest.
        cellWidth: Math.floor(width / 2)
        model: dirModel

        // One column of chips per press.
        function step(dir) {
          var maxX = Math.max(0, contentWidth - width)
          contentX = Math.max(0, Math.min(contentX + dir * cellWidth, maxX))
        }

        Connections {
          target: dirModel
          function onFolderChanged() { poolRail.contentX = 0 }
        }

        delegate: Item {
          id: chip
          required property string fileName
          required property bool fileIsDir
          width: poolRail.cellWidth
          height: poolRail.cellHeight

          Rectangle {
            anchors.fill: parent
            anchors.rightMargin: Style.spacing.xs
            anchors.bottomMargin: Style.spacing.xs
            radius: Style.cornerRadius
            color: chipMouse.containsMouse
              ? Style.hoverFillFor(root.foreground, Color.accent)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)

            Text {
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.sm
              anchors.rightMargin: Style.spacing.sm
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              text: "▸ " + chip.fileName
              elide: Text.ElideRight
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: chipMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.folder = folderModel.currentPath + "/" + chip.fileName
            }
          }
        }
      }

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        visible: poolBrowseRow.overflowing
        iconText: "\u203a"
        foreground: root.foreground
        onClicked: poolRail.step(1)
      }
    }

    // ---- the strip preview, both pool pickers -----------------------------
    //
    // A single row of what is actually IN the folder you are standing in, so
    // the pool you are about to take is not a guess (0: "put the stip preview
    // back into both pool pickers"). Global pool and per-workspace pool are
    // the same component in pool mode, so one strip serves both.
    //
    // INERT. Nothing here takes a click (0: "preview click does nothing") --
    // the pictures are evidence, not controls; the ladder moves you and "Use
    // this Folder" takes the folder. The list itself does not drag-scroll
    // either: the two arrows page it, one screenful at a time.
    //
    // ALWAYS visible in pool mode now, empty folder or not (0: "the custom
    // pool picker thrashes when theres no images in a folder... open the
    // diag large enough for the slide to have space when no images are
    // there. and not thrash"). This used to collapse to zero height on an
    // empty folder -- same class of bug the ladder below was already fixed
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

    // ---- pool picker, style 2: the ladder ---------------------------------
    //
    // One folder per line, full width, flat -- a chevron, the name, and a
    // hover bar. No tiles, no chips, no boxes: the tiles read as blanks and
    // the chips still boxed every name in its own frame.
    //
    // FOUR rows, always. That is the whole point of it (0: "another style
    // picker that doesnt thrash"): a folder with two subfolders and a folder
    // with forty are exactly the same height, and the rest run under the
    // wheel against the slim bar on the right.
    Item {
      id: poolLadder
      // Both modes: the pool takes a folder with it, the image picker walks
      // down the tree with it. Style 1 (the chip rail) is a pool-only
      // alternate, so file mode always gets the ladder.
      // NOT gated on the folder having children any more. A leaf folder --
      // the theme's own backgrounds directory is one: seven pictures, no
      // subfolders -- made the ladder vanish, and with the pool picker having
      // no preview by design the panel came up as a title, a path and some
      // buttons (0: "the custom pool background it blasted"). It keeps its
      // four rows and says it is empty instead.
      visible: root.pickFiles || root.poolStyle === 2
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

    // ================= V1: Two Pane =======================================
    // The familiar shape, tidied: big preview on the left, names on the
    // right, folders marked with ▸.
    Row {
      // Collapses entirely when there is nothing to browse into, instead of
      // holding a fixed 230px of empty box (0: "KILL THE DEAD SPACE ON GWP,
      // the middle 1/3 is dead space").
      visible: root.version === 1 && folderModel.count > 0
      spacing: Style.spacing.sm

      Rectangle {
        width: Style.space(170)
        height: root.bodyH
        color: "transparent"

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          height: Math.round(width * 9 / 16)
          visible: root.shownPath !== ""
          color: Qt.darker(root.foreground, 3)
          radius: Style.cornerRadius
          clip: true

          Image {
            anchors.fill: parent
            source: root.shownPath !== "" ? Util.fileUrl(root.shownPath) : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 320
          }
        }
      }

      ListView {
        width: column.width - Style.space(170) - Style.spacing.sm
        height: Style.space(230)
        clip: true
        model: folderModel
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          required property int index
          required property string fileName
          required property bool fileIsDir
          width: ListView.view.width
          height: Math.max(Style.space(26), rowText.implicitHeight + Style.spacing.xs * 2)
          color: rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
          radius: Style.cornerRadius

          Text {
            id: rowText
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.spacing.sm
            anchors.rightMargin: Style.spacing.sm
            textFormat: Text.PlainText
            text: (fileIsDir ? "▸ " : "") + fileName
            elide: Text.ElideRight
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: root.hoverPath = (containsMouse && !fileIsDir)
              ? folderModel.currentPath + "/" + fileName : ""
            onClicked: {
              if (fileIsDir) root.folder = folderModel.currentPath + "/" + fileName
              else root.chosen(folderModel.currentPath + "/" + fileName)
            }
          }
        }
      }
    }

    // ================= V2: Contact Sheet ==================================
    // Every image in the folder as a thumbnail, three across; folders are
    // slim full-width rows above them. Pick by clicking the picture itself.
    // Height follows the CONTENT now, not a fixed 260 (0: "compress the
    // wallpaper picker up to the amount of images ... it kills dead space").
    // Three across, so nine images is three rows: up to that it shrink-wraps
    // exactly, beyond it it grows to the cap -- "show them until the pane
    // bottom" -- and the arrows below page through the rest.
    Item {
      id: sheetBox
      // File mode only: the pool browses with the ladder above it, and a
      // folder full of pictures is not a pool picker.
      //
      // NOT gated on imageModel.count any more -- same class of bug as
      // stripRow and poolLadder above, just missed in both of those passes
      // (0: "the BG Picker for a LIE is thrashing... I dont want to chase
      // buttons around the screen"). Collapsing this ~200px block on every
      // image-less folder (common while navigating down toward a picture)
      // resized the whole dialog and everything below it, including the
      // button row. Keeps its reserved height and says it's empty instead.
      visible: root.version === 2 && root.pickFiles
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
      // it needs to (0: "allow the text to span the panel, then wrap it if
      // needed. AGAIN"). Clipped inside its own 100px thumbnail it was three
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
      // the panel instead of running past it (0).
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

    // Arrows page the sheet when the folder holds more than fits (0: "if
    // theres lots, use the arrows for nav thru the folder"). Hidden entirely
    // when everything is already on screen, so they add no dead space of
    // their own. Centred, and inside column.width -- they never widen it.
    RowLayout {
      // File mode only. The pool's stack is strip -> picker -> buttons and
      // nothing else (0: "thats it then the button"), so its two lines scroll
      // on the wheel against the slim scrollbar instead of costing a row.
      visible: root.version === 2 && root.pickFiles && sheet.contentHeight > sheet.height
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

    // ================= V3: Stage ==========================================
    // One big stage showing what you're about to set, with a filmstrip of
    // candidates under it. Click the stage to take it, or a strip item.
    Column {
      visible: root.version === 3 && folderModel.count > 0
      width: column.width
      spacing: Style.spacing.sm

      Rectangle {
        width: column.width
        height: Math.round(column.width * 9 / 16)
        color: Qt.darker(root.foreground, 3)
        radius: Style.cornerRadius
        clip: true

        Image {
          anchors.fill: parent
          source: root.shownPath !== "" ? Util.fileUrl(root.shownPath) : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          sourceSize.width: 480
        }

        Text {
          anchors.centerIn: parent
          visible: root.shownPath === ""
          textFormat: Text.PlainText
          text: "hover a Background"
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          anchors.fill: parent
          enabled: root.shownPath !== ""
          cursorShape: Qt.PointingHandCursor
          onClicked: root.chosen(root.shownPath)
        }
      }

      ListView {
        width: column.width
        height: Style.space(86)
        orientation: ListView.Horizontal
        spacing: Style.spacing.sm
        clip: true
        model: folderModel
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          required property int index
          required property string fileName
          required property bool fileIsDir
          width: fileIsDir ? Style.space(110) : Style.space(130)
          height: Style.space(80)
          radius: Style.cornerRadius
          color: fileIsDir ? Qt.rgba(0, 0, 0, 0.25) : Qt.darker(root.foreground, 3)
          border.width: stripMouse.containsMouse ? 2 : 0
          border.color: root.foreground
          clip: true

          Image {
            anchors.fill: parent
            visible: !fileIsDir
            source: fileIsDir ? "" : Util.fileUrl(folderModel.currentPath + "/" + fileName)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 200
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.spacing.sm
            visible: fileIsDir
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WrapAnywhere
            textFormat: Text.PlainText
            text: "▸ " + fileName
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          MouseArea {
            id: stripMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: root.hoverPath = (containsMouse && !fileIsDir)
              ? folderModel.currentPath + "/" + fileName : ""
            onClicked: {
              if (fileIsDir) root.folder = folderModel.currentPath + "/" + fileName
              else root.chosen(folderModel.currentPath + "/" + fileName)
            }
          }
        }
      }
    }

    // ---- the button row, both modes ---------------------------------------
    //
    // Was ONE button, centred (0: "remove all buttons, leave the Use this
    // folder centered, omarchy style") -- Escape and a click outside already
    // close this, and the ladder is how you get anywhere else. Two reset
    // buttons joined it later, each visible only in the ONE context it means
    // something in (see their own comments below); in file mode (picking a
    // single image) it's still "Use this Folder" alone, same as always --
    // a picture is chosen by clicking the picture, this only hands back the
    // folder it lives in.
    Item {
      width: column.width
      implicitHeight: buttonRow.implicitHeight

      Row {
        id: buttonRow
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.spacing.controlGap

        // This workspace's own pool override, back to following the global
        // pool -- moved here from li's settings row, where it read "Global"
        // (0: "move the Global Button out of LIE and into the picker, reads
        // 'Use Global Pool' even with the use this folder"). Per-workspace
        // pool browse only -- meaningless during the global browse itself or
        // a single-image pick.
        Button {
          anchors.verticalCenter: parent.verticalCenter
          visible: !root.pickFiles && root.workspaceId > 0
          text: "Use Global Pool"
          bordered: true
          foreground: root.foreground
          horizontalPadding: Style.spacing.sm
          onClicked: root.poolResetRequested()
        }

        // The GLOBAL pool itself, back to the omarchy theme folder (0: "add
        // a revert to default button to the picker, it sets the omarchy
        // theme folder as global default"). Global pool browse only -- 0
        // tried it alongside "Use Global Pool" on a per-workspace browse too
        // and bounced it right back ("bring that one back, I dont want three
        // buttons" -- "that one" = Use Global Pool, i.e. drop back to two).
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
