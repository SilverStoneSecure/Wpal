import QtQuick
import qs.Commons

// Draws how a workspace's auto-launched windows will tile, over a thumbnail.
// rects: one [x, y, w, h] (0..1 units) per window, in launch order.
Item {
  id: root
  property string moduleName: "io.github.silverstone.wpal"

  property var rects: []
  property color lineColor: Color.foreground
  // One label per rect (parallel to `rects`) -- the pane's own command/app
  // name, elided to fit. "" hides the label on that tile.
  property var labels: []
  // Which rect (if any) is the designated full-screen pane: tinted/bordered
  // in fsColor instead of the plain cell style, and captioned "(fullscreen)"
  // under its own command, same font, placed underneath. -1 = none. Each li
  // version (see CustomizeDialog) may add its OWN extra visual on top of this
  // (a full-coverage "ghost", a corner ribbon, ...) -- this is just the
  // shared baseline cell treatment.
  property int fullscreenIndex: -1
  // White, like every other tile outline here -- the full-screen pick is told
  // apart by weight and its "(fullscreen)" caption, not by hue.
  property color fsColor: "#ffffff"
  // False when these launchers won't actually fire -- global Auto Launch off,
  // or this workspace's own checkbox unticked. The grid still draws either
  // way, so what's configured stays visible, in a different theme hue from a
  // live one; this cascades to the matching tiles on the main panel when
  // toggled. No colored TEXT is involved -- the enabled/disabled wording in
  // li stays unhued.
  property bool launchEnabled: true
  // Global Auto Launch off, or this workspace's own off: the tiles go red.
  // Same soft red as the enabled/disabled labels.
  // Back to a real red. It had been mixed 50% toward its own luminance grey
  // (#c19696) on an earlier "soften the red hue" pass, which left the blocked
  // tiles reading as dusty pink rather than as a warning. This is the same
  // #e08a8a the Auto Launch toggle wears when it is off, so the fill, the
  // border and the switch are all one colour now.
  property color disabledColor: "#e08a8a"
  // The BORDER's own blocked colour. li keeps the softened fill hue above;
  // the main panel's cards pass the toggle's full red, so a glance down the
  // list says "auto launch is off" in exactly the colour the toggle is
  // wearing.
  property color disabledBorderColor: root.disabledColor
  // The standing highlight on a tile that HAS a launcher set: white, heavier
  // than an empty tile's hairline, on li's preview and the main panel's cards
  // alike.
  property color setColor: "#ffffff"

  // ---- drag state, driven by li's tile MouseAreas -----------------------
  //
  // A swap used to happen with no motion at all: the only thing that changed
  // was a command NAME in two tiles, which nobody reads mid-gesture. So the
  // tiles now behave like objects: press shrinks one, dragging
  // carries it a little way (never far -- it must stay legible in its row),
  // and the tile it would land on shifts into the space it came out of. The
  // drop itself is silent: everything is simply drawn where it now belongs.
  // The tile that is "chosen" (held, or with the pointer on its grip). Every
  // OTHER tile then reads as a candidate in its own theme colour, so the set
  // you can trade with is visible the moment you touch the grip. -1 = nothing
  // chosen.
  property int othersIndex: -1
  property int dragIndex: -1
  property real dragDX: 0
  property real dragDY: 0
  property int dropIndex: -1
  // The landing. NOT an animation: the frame the button comes up, the dropped
  // tile is simply DRAWN filling the cell it was over -- `landIndex` is that
  // tile, `landRect` is the cell, in the same 0..1 form as `rects`. It takes
  // that cell's position AND size (cells are not all the same shape: "Main
  // left, three right" has a quarter-height one). It exists only because the
  // swap is written asynchronously; it holds the finished picture for the
  // frame or two until the write lands, so nothing flips or slides
  // afterwards.
  property int landIndex: -1
  property var landRect: null
  // Whichever tile is out of its home right now -- held, or landing. The tile
  // it traded with sits in the space this one left, through the drag AND the
  // landing, so it never pops home and back.
  readonly property int dragSource: root.dragIndex >= 0 ? root.dragIndex : root.landIndex
  readonly property bool moving: root.dragIndex >= 0 || root.landIndex >= 0
  // li draws each tile's command at caption size; the main panel's cards are a
  // fraction of that size, so they pass a smaller one and label the tiles
  // with their launch ORDER instead -- the command itself is the card's
  // per-tile hover, which WorkspaceCard already has.
  property int labelPixelSize: Style.font.body
  // Which tile's command text is under the pointer right now, -1 for none.
  // li passes its grip slot; the main panel's cards pass nothing, so no pill
  // is ever drawn there.
  property int labelHotIndex: -1
  // "(fullscreen)" under the label doesn't fit on a card-sized thumbnail; the
  // tile's own tint and border still mark the pick there.
  property bool showFsCaption: true
  // A flat label colour washes out over some wallpapers -- same trap as the
  // watermark numbers, same fix: a dark outline. Off by default so main's
  // tiny per-tile order
  // numbers are untouched; li turns it on for its command labels.
  property bool labelOutline: false

  Repeater {
    model: root.rects

    Rectangle {
      id: tile
      required property var modelData
      required property int index
      readonly property bool isFs: index === root.fullscreenIndex
      readonly property string labelText: (root.labels && root.labels[index]) || ""

      readonly property bool candidate: root.othersIndex >= 0 && index !== root.othersIndex
      readonly property bool labelHot: index === root.labelHotIndex && labelText !== ""
      readonly property bool dragging: index === root.dragIndex
      readonly property bool dropTarget: index === root.dropIndex
      readonly property bool landing: index === root.landIndex && !!root.landRect

      // Where this tile's own rect puts it.
      readonly property real homeX: modelData[0] * root.width + 1
      readonly property real homeY: modelData[1] * root.height + 1
      // The space the held tile came out of -- valid only while something is
      // being dragged.
      readonly property var dragRect: (root.dragSource >= 0 && root.rects
        && root.dragSource < root.rects.length) ? root.rects[root.dragSource] : null
      // The tile that traded places is displaced into the vacated space, and
      // during the LANDING it also takes that space's size, so when the freeze
      // drops both tiles are already exactly where the model draws them.
      readonly property bool displaced: dropTarget && !!dragRect && !landing

      // Cross the middle of another tile and THAT tile slides into the held
      // one's empty space. The held tile itself just nudges with the
      // pointer.
      x: landing ? root.landRect[0] * root.width + 1
        : dragging ? homeX + root.dragDX
        : displaced ? dragRect[0] * root.width + 1 : homeX
      y: landing ? root.landRect[1] * root.height + 1
        : dragging ? homeY + root.dragDY
        : displaced ? dragRect[1] * root.height + 1 : homeY
      // Only while a drag is LIVE. The moment it ends, dragIndex goes to -1,
      // these switch off and every tile is simply drawn where it now belongs
      // -- no slide, no swap to watch.
      // ONLY while the pointer is still down. The frame the button is
      // released every Behavior here is dead, so the tile simply IS in the
      // space it was over -- no grow, no glide, nothing to sit through.
      Behavior on x { enabled: root.dragIndex >= 0 && !tile.dragging; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on y { enabled: root.dragIndex >= 0 && !tile.dragging; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

      // Three quarter size while it is held, so the space it came out of
      // reads as empty and the tile coming to fill it has somewhere to go.
      // Everything else is drawn at 100%, including
      // the instant the drag ends -- the held tile simply IS full size again.
      // Held: three quarters. Released: full size, that same frame.
      scale: dragging ? 0.75 : 1
      Behavior on scale { enabled: root.dragIndex >= 0; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
      opacity: dragging ? 0.9 : 1

      // Fitting the space it is over means the target cell's SIZE too, not just
      // its position -- set outright, not animated. The displaced tile takes
      // the vacated cell's size at the same instant, so both tiles are already
      // exactly where the model will draw them when the freeze drops.
      width: landing ? root.landRect[2] * root.width - 2
        : (root.landIndex >= 0 && dropTarget && dragRect) ? dragRect[2] * root.width - 2
        : modelData[2] * root.width - 2
      height: landing ? root.landRect[3] * root.height - 2
        : (root.landIndex >= 0 && dropTarget && dragRect) ? dragRect[3] * root.height - 2
        : modelData[3] * root.height - 2
      readonly property color dc: root.disabledColor
      readonly property color dbc: root.disabledBorderColor
      readonly property color sc: root.setColor
      // A tile with something configured behind it is "set": it keeps the
      // highlight permanently, rather than only while its config panel is
      // open. An empty tile keeps the old hairline.
      readonly property bool isSet: labelText !== ""
      // A full-screen pane gets NO extra tile treatment any more -- it reads
      // as a set tile, plus its caption, plus the brighter logo li draws in
      // it.
      // Held tile in the accent, the tiles it could trade with in muted,
      // everything else as it was.
      color: dragging
        ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
        : candidate
        ? Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.26)
        : (!root.launchEnabled
          ? Qt.rgba(dc.r, dc.g, dc.b, isSet ? 0.22 : 0.10)
          : (isSet ? Qt.rgba(sc.r, sc.g, sc.b, 0.10) : Qt.rgba(0, 0, 0, 0.32)))
      // Gated like the scale: the fill eases only while a drag is LIVE. On
      // release dragIndex is -1, so the held tile's accent and every
      // candidate's muted fill drop back instantly instead of fading out
      // behind the drop.
      Behavior on color { enabled: root.dragIndex >= 0; ColorAnimation { duration: 120 } }
      // Rounded, like the preview and cards themselves.
      radius: Style.cornerRadius
      // Three weights: full-screen pick > set tile > empty slot. Hue never
      // carries the difference any more -- width, fill and the caption do.
      border.width: (dragging || candidate) ? 2 : (isSet ? 2 : 1)
      // The tile you have hold of takes a theme colour of its own, and a tile
      // that has just been rearranged blends toward a second one.
      border.color: dragging ? Color.accent
        : candidate ? Color.muted
        : !root.launchEnabled
        ? Qt.rgba(dbc.r, dbc.g, dbc.b, isSet ? 0.9 : 0.5)
        : (isSet ? Qt.rgba(sc.r, sc.g, sc.b, 0.9)
          : Qt.rgba(root.lineColor.r, root.lineColor.g, root.lineColor.b, 0.55))
      // Drawn after the others in the same Repeater pass, but bumped above
      // them anyway so a future overlapping layout still reads as "on top".
      // The held tile, and the landing one, ride over the tile they are
      // trading with; there is only one `z` on this delegate.
      z: (dragging || landing) ? 2 : (isFs ? 1 : 0)

      // The command, and -- on the full-screen pick only -- "(fullscreen)"
      // right under it in the same font, rather than replacing it.
      Column {
        anchors.centerIn: parent
        width: parent.width - 4
        spacing: 0

        Text {
          id: cmdText
          visible: parent.parent.labelText !== ""
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          // Long commands wrap now instead of being cut off mid-word. Three
          // lines, then elide -- a tile is a map of the screen, not a text
          // box.
          wrapMode: Text.WrapAtWordBoundaryOrAnywhere
          maximumLineCount: 3
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: parent.parent.labelText
          // The command and its args take the accent while the pointer is on
          // their grip.
          color: tile.labelHot ? Color.accent : root.lineColor
          // Same dark-outline trick as the watermark numbers, gated off for
          // main (see labelOutline above).
          style: root.labelOutline ? Text.Outline : Text.Normal
          styleColor: Qt.rgba(0, 0, 0, 0.47)
          font.family: Style.font.family
          font.pixelSize: root.labelPixelSize

          // THE GRIP ITSELF, drawn. The hit box around the command text is
          // invisible by design -- this is
          // the same rectangle, same maths as CustomizeDialog's `inkW`/`inkH`
          // (painted ink plus a hair, floored so one word is still grabbable,
          // capped at the tile), rounded all the way to a pill. On the dark
          // chip every control over the preview wears, never bare over the
          // wallpaper.
          Rectangle {
            z: -1
            visible: tile.labelHot
            anchors.centerIn: parent
            width: Math.min(tile.width,
              Math.max(Style.space(40), cmdText.paintedWidth + Style.space(4)))
            height: Math.min(tile.height,
              Math.max(Style.space(14), cmdText.paintedHeight + Style.space(2)))
            radius: height / 2
            color: Qt.rgba(0, 0, 0, 0.55)
            border.width: 1
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.9)
          }
        }

        Text {
          visible: parent.parent.isFs && root.showFsCaption
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: "(fullscreen)"
          // Same colour as the command above it; the tile's own accent
          // tint/border is what still pops.
          color: root.lineColor
          style: root.labelOutline ? Text.Outline : Text.Normal
          styleColor: Qt.rgba(0, 0, 0, 0.47)
          font.family: Style.font.family
          font.pixelSize: root.labelPixelSize
        }
      }
    }
  }
}
