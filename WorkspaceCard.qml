import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One compact card in the strip: the workspace number beside a thumbnail --
// number to the left keeps each card to thumbnail height instead of
// thumbnail-plus-a-text-row, so the ten-card strip is noticeably shorter.
// Clicking it opens the customize dialog for that workspace.
Item {
  id: root

  required property int workspaceId
  // Omarchy Default shows one card standing for the whole desktop, so it
  // hides the number; Custom mode's ten all carry theirs.
  property bool showNumber: true
  property string previewPath: ""
  // How long this card waits before fading its new wallpaper in, so a shuffle
  // cascades down the list instead of flipping all ten at once. 0 = no
  // stagger (the card appears normally).
  property int staggerMs: 0
  property bool active: false
  property string summaryText: ""
  property color foreground: Color.foreground
  // Auto Launch is live for this workspace (global + this one on, something
  // set): the thumbnail wears the theme's focus border. launchRects, with two
  // or more windows, adds the tile layout that will open (see Model.launchLayouts).
  property bool launchActive: false
  property var launchRects: []
  // The grid is drawn whenever 2+ launchers are configured, whether or not
  // they'd fire -- launchEnabled only changes its hue (see
  // LaunchLayoutOverlay). This is the main-panel half of 0's cascade: tick
  // "Auto Launch" off in li and every card showing that workspace re-hues.
  property bool launchEnabled: true
  // Mirrors the li dialog's full-screen pick for this workspace; -1 = none
  // designated.
  property int launchFsIndex: -1
  // This workspace's configured panes, for the per-launcher hover (0: "on
  // hover, for each launcher set, show its installed launcher or command,
  // and in the main panel too" -- same per-cell behavior as li, not a
  // combined list).
  property var panes: []
  // The frame the per-tile hovers must stay inside: a left-column card's
  // tooltip is centred on the tile by default, which hangs it off the left edge
  // of the panel (0: "constrain the hovers in left column line items, keep em
  // on the panel"). Panel passes its own card frame.
  property Item clampTarget: null

  readonly property var appEntries: (DesktopEntries.applications && DesktopEntries.applications.values) || []
  readonly property int configuredCount: Model.configuredCount(root.panes)
  // One hover region per launcher: the real grid at 2+, or the whole
  // thumbnail standing for the one launcher there is at exactly 1.
  readonly property var hoverRects: {
    if (root.launchRects.length > 1) return root.launchRects
    if (root.configuredCount === 1) return [[0, 0, 1, 1]]
    return []
  }
  // "1".."4" per tile, blank for a tile with nothing configured behind it.
  readonly property var orderLabels: root.hoverRects.map(function(r, i) {
    var p = root.panes[i]
    var set = !!p && (p.appId !== "" || String(p.args || "").trim() !== "")
    return set ? String(i + 1) : ""
  })

  function hoverTextFor(idx) {
    var p = root.panes[idx]
    if (!p || (p.appId === "" && String(p.args || "").trim() === "")) return ""
    var t = Model.paneLabel(root.appEntries, p)
    // One launcher can be the full-screen pick too, same as li (see
    // Panel.launchFsIndexFor).
    if (root.configuredCount >= 1 && idx === root.launchFsIndex) t += "\n(full screen)"
    return t
  }

  // Matches the strip's title-row width, so every thumbnail row scales to
  // fill the same span instead of sitting narrower in the middle of it.
  // Not readonly: Panel.qml overrides it to root.settingsWidth so the cards
  // track the panel's actual width instead of a stale hardcoded value.
  property int fullWidth: Style.space(120)
  readonly property int spacing: Style.space(4)
  readonly property int numberW: Style.space(20)
  readonly property int naturalCardW: fullWidth - numberW - spacing
  // Height scales with the thumbnail's width (56x38 ratio) so it never
  // distorts...
  readonly property int naturalCardH: Math.round(naturalCardW * 38 / 56)
  // ...unless Panel.qml caps it so all the cards fit on screen -- then the
  // width shrinks with it (same ratio) instead of stretching or cropping.
  // Panel.qml sizes the panel so the cap normally isn't hit.
  property int maxCardH: 0
  readonly property int cardH: maxCardH > 0 ? Math.min(naturalCardH, maxCardH) : naturalCardH
  readonly property int cardW: Math.min(naturalCardW, Math.round(cardH * 56 / 38))

  signal clicked()

  // One hover source for the whole card. The per-tile MouseAreas sit above
  // the card's own MouseArea and were swallowing its hover, so cards WITH
  // tiles never popped (0: "they all dont work").
  HoverHandler { id: cardHover }
  readonly property bool hovered: cardHover.hovered

  // The keyboard cursor. Drawn exactly like a hover so arrow-key navigation
  // and the mouse read the same; `hovered` on its own still drives the
  // tooltips, which a keyboard cursor must NOT pop.
  property bool selected: false
  readonly property bool highlighted: root.hovered || root.selected

  implicitWidth: fullWidth
  implicitHeight: cardH
  // A popped card draws over its neighbours instead of under them.
  z: root.highlighted ? 1 : 0

  Row {
    anchors.verticalCenter: parent.verticalCenter
    anchors.horizontalCenter: parent.horizontalCenter
    // Hovering pops the card straight out at the viewer rather than sliding it
    // sideways (0: "the panels are shifting LEFT on hover, I want them to pop
    // out straight twords the user, inc the pop x2") -- a centred scale, at
    // twice the old 5px worth of growth. The per-tile hover regions scale with
    // it, so the tile tooltips keep working.
    scale: root.highlighted ? 1 + (Style.space(10) / Math.max(1, root.cardW)) : 1
    transformOrigin: Item.Center
    Behavior on scale { NumberAnimation { duration: 90 } }
    spacing: root.spacing

    // The workspace number used to sit here, in its own gutter column to the
    // left of the thumbnail. It is not gone -- it is drawn as a watermark over
    // the preview itself now (0: "the LI numbers in the main panel will
    // watermark a diff tc OVER the ws preview, all underlying functionality
    // will remain intact"). `numberW` is deliberately still subtracted in the
    // width maths above, so no card changes size by this move.

    Rectangle {
      width: root.cardW
      height: root.cardH
      color: Qt.darker(root.foreground, 3)
      radius: Style.cornerRadius
      clip: true
      border.width: root.active ? 2 : (root.highlighted ? 1 : 0)
      border.color: Color.accent

      // The number, over the preview and behind everything that means
      // something: the tile grid, its commands and the per-tile hovers all sit
      // above this and are untouched. A DIFFERENT theme colour from the tile
      // work (accent, not foreground), held well back so it reads as a
      // watermark rather than a label. Inert by construction -- it is a Text,
      // it takes no input, and the card's own click and the per-tile command
      // hovers pass straight through it.
      Text {
        z: 1
        // EVERY card carries its number (0: "YOU LOST THE LIST ITEM NUMBERS").
        // I had gated this on a launcher being configured, reading an answer
        // about the number's COLOUR as being about the number itself -- that
        // wiped the numbers off most of the list. The colour still says
        // whether auto launch is live; the number is always there.
        visible: root.showNumber
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: root.workspaceId === 10 ? "0" : String(root.workspaceId)
        // The number says whether this workspace will auto launch (0: "change
        // the color of the li numbers to tc reddish when auto launch is on for
        // its WS. and grey when AL is disabled"): the toggle's own red when it
        // is live, plain grey when the global switch or this workspace's own is
        // off. Sizes are 0's: "to" 70%, then 75% of that, then 85% of that;
        // alpha 25% up a quarter twice, with the outline carrying it over a
        // bright thumbnail.
        readonly property color wmColor: root.launchEnabled ? "#e08a8a" : "#b6b6b6"
        color: Qt.rgba(wmColor.r, wmColor.g, wmColor.b, 0.39)
        // A flat tint vanished over a bright wallpaper -- the same trap that
        // hid the full-screen toggle and the ✕. A dark outline carries it on
        // a sunset thumbnail without making it any louder on a dark one.
        style: Text.Outline
        styleColor: Qt.rgba(0, 0, 0, 0.47)
        font.family: Style.font.family
        font.pixelSize: Math.round(root.cardH * 0.72 * 0.70 * 0.75 * 0.85)
        font.bold: true
      }

      Image {
        id: thumb
        anchors.fill: parent
        visible: root.previewPath !== ""
        source: root.previewPath !== "" ? Util.fileUrl(root.previewPath) : ""

        // A shuffle rewrites all ten wallpapers in ONE settings write (ten
        // writes would rebuild the whole panel ten times), so the cascade is
        // done visually: each card blanks and fades its new image back in a
        // beat later than the one above, spreading the change across about
        // two seconds (0: "have each one pop in / change over two seconds, so
        // the user can see them change, all changing at once is odd to me").
        onSourceChanged: if (root.staggerMs > 0) { thumb.opacity = 0; popIn.restart() }

        SequentialAnimation {
          id: popIn
          PauseAnimation { duration: root.staggerMs }
          NumberAnimation { target: thumb; property: "opacity"; to: 1; duration: 280; easing.type: Easing.OutCubic }
        }
        fillMode: Image.PreserveAspectCrop
        // Synchronous: these are tiny (160x90) thumbnails, and switching
        // wallpaper mode recreates every card at once -- async decoding left
        // a visible blank flash right when the list reappears.
        asynchronous: false
        // Width only: giving both dimensions stretches the decode to
        // exactly that box regardless of the image's real aspect.
        sourceSize.width: 320
      }

      // Same tiling li draws, at card scale: each tile carries its launch
      // ORDER in a smaller font, and the command itself is on the per-tile
      // hover below (0: "on the Main Panel, it shows the tile order smaller,
      // and on hover, shows the command set"). hoverRects, not launchRects,
      // so a lone launcher still marks the whole thumbnail as tile 1.
      LaunchLayoutOverlay {
        // Above the watermark (z 1): the tile grid and its numbers are
        // content, the watermark is background.
        z: 2
        anchors.fill: parent
        visible: root.hoverRects.length > 0
        rects: root.hoverRects
        labels: root.orderLabels
        // Two 75% cuts from the original 9px (0, twice: "reduce the px size
        // of the numbers", then "the numbers are still too big") -- on a 56x38
        // card these are a position marker, not something to read. 9 -> 7 -> 5.
        labelPixelSize: Math.max(Style.space(4),
          Math.round((Style.font.body - Style.space(3)) * 0.75 * 0.75))
        showFsCaption: false
        lineColor: root.foreground
        // The card tiles read quieter than li's: a set tile's white tint and
        // border drop to grey (0: "soften the tiles on the main li's down to
        // grey"). li keeps the white -- that is the editor, this is the map.
        setColor: "#b6b6b6"
        // The same red the Auto Launch toggle turns when it is off.
        disabledBorderColor: "#e08a8a"
        fullscreenIndex: root.launchFsIndex
        launchEnabled: root.launchEnabled
      }

      // The red active border is gone (0: "lose the red border, just shows
      // whats set in the WS as is"). Auto Launch being off is now said by
      // the tile overlay colour instead.

      // Soft blue halo while THIS workspace's editor is open, so it's clear
      // which line item the open li belongs to (0).
      TileGlow {
        glowColor: "#7aa2f7"
        hovered: root.active
      }

      MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
      }

      // Per-launcher hover, one region per cell (see hoverRects above);
      // click passthrough (NoButton) so the card's own click above still
      // opens li wherever these overlap it.
      Repeater {
        model: root.hoverRects

        MouseArea {
          required property var modelData
          required property int index
          x: modelData[0] * parent.width
          y: modelData[1] * parent.height
          width: modelData[2] * parent.width
          height: modelData[3] * parent.height
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          // The card underneath IS clickable, so the pointer must not flip
          // back to an arrow over a tile (0: "dont change the mouse tip on
          // hover in the list items, keep it change to the thumb if its
          // clickable").
          cursorShape: Qt.PointingHandCursor

          SsToolTip {
            id: tileTip
            visible: parent.containsMouse && root.hoverTextFor(index) !== ""
            // The clamp that used to be written out here is SsToolTip's own
            // job now, for every tooltip in the plugin rather than just this
            // one (0: "CONSTRAIN ALL HOVERS TO THIER RESPECTIVE PANEL"). The
            // frame is still passed explicitly, so the card's tooltips are
            // clamped even if the objectName walk ever comes up empty.
            clampTo: root.clampTarget
            // A command can be any length, so this one wraps rather than
            // running off the panel (0: "word wrap ALL mouseovers if they bust
            // the panel").
            text: root.hoverTextFor(index)
            fontSize: Style.font.body
          }
        }
      }
    }
  }
}
