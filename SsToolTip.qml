import QtQuick
import qs.Commons
import qs.Ui

// A PanelToolTip that WRAPS instead of running off the side of the panel
// (0: "word wrap ALL mouseovers if they bust the panel"), and that stays
// INSIDE the panel it belongs to (0: "CONSTRAIN ALL HOVERS TO THIER
// RESPECTIVE PANEL").
//
// A tooltip is a popup living inside a layer surface, and the shell's
// PanelToolTip draws its text on one unbroken line: anything longer than the
// panel is simply cut off at the frame. Here the line is measured first
// (TextMetrics, so there is no width<->implicitWidth loop) and the box is
// capped at `maxWidth`, wrapping at word boundaries past that. Short tooltips
// are unchanged -- they never reach the cap.
//
// Drop-in for PanelToolTip: `text`, `fontSize`, `visible` behave the same.
PanelToolTip {
  id: root
  property string moduleName: "io.github.silverstone.wpal"

  // Narrower than any of this plugin's panels, so a wrapped tooltip still
  // fits whichever one it pops up in.
  property real maxWidth: Style.space(240)

  // The panel frame this box may not leave. Every frame in Panel.qml carries
  // objectName "ssPanelFrame", so a tooltip finds its own panel by walking up
  // from the control it is declared in -- no call site has to pass one, and a
  // tooltip declared outside any frame (the bar widget) simply isn't clamped.
  // Resolved once, on completion: the parent chain never changes afterwards.
  property Item clampTo: null
  // STOCK PLACEMENT: centred above the control, the way every tooltip in the
  // shell sits (0: "im not liking the place ment of all the hovers, its
  // annoying, go back to default hover placement"). The below-by-default
  // experiment -- an attempt at "dont cover the label above" -- moved every
  // box in the plugin and 0 liked that less than the thing it fixed. Nothing
  // repositions a tooltip any more EXCEPT the panel clamp below, which only
  // acts when the box would otherwise be drawn outside its own panel
  // (0: "CONSTRAIN ALL HOVERS TO THIER RESPECTIVE PANEL").
  property bool below: false
  // Breathing room at the frame's inner edge, and between box and control.
  readonly property real clampEdge: Style.space(2)
  readonly property real clampGap: Style.space(3)

  function findFrame() {
    var p = root.parent
    while (p) {
      if (p.objectName === "ssPanelFrame") return p
      p = p.parent
    }
    return null
  }
  Component.onCompleted: if (!root.clampTo) root.clampTo = root.findFrame()

  // Pull `want` back inside `container` on one axis (0 = x, 1 = y). When the
  // container is SMALLER than the box -- a launcher tile, say -- there is no
  // position that fits, and the box is pinned to the container's near edge.
  function fit(want, box, container, axis) {
    if (!container || !root.parent) return want
    var origin = root.parent.mapToItem(container, 0, 0)
    var here = axis === 0 ? origin.x : origin.y
    var span = axis === 0 ? container.width : container.height
    var lo = -here + root.clampEdge
    var hi = span - here - box - root.clampEdge
    if (hi < lo) return lo
    return Math.max(lo, Math.min(want, hi))
  }

  // Centred on the control, then pulled back inside the frame at either edge.
  // `visible` is read on purpose: mapToItem is not a reactive dependency, so
  // re-running the maths every time the box is shown is what keeps it honest
  // after the panel has moved.
  x: {
    var def = root.parent ? (root.parent.width - root.width) / 2 : 0
    if (!root.parent || !root.visible) return def
    return root.fit(def, root.width, root.clampTo, 0)
  }

  // Above the control, and flipped below rather than slid over it when above
  // has no room inside the frame.
  y: {
    var over = -root.height - root.clampGap
    var under = (root.parent ? root.parent.height : 0) + root.clampGap
    var def = root.below ? under : over
    if (!root.parent || !root.visible) return def
    if (root.clampTo) {
      var origin = root.parent.mapToItem(root.clampTo, 0, 0)
      var lo = -origin.y + root.clampEdge
      var hi = root.clampTo.height - origin.y - root.height - root.clampEdge
      if (hi >= lo && (def < lo || def > hi)) {
        var flip = root.below ? over : under
        if (flip >= lo && flip <= hi) return flip
      }
    }
    return root.fit(def, root.height, root.clampTo, 1)
  }

  TextMetrics {
    id: metrics
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    text: root.text
  }

  contentItem: Text {
    textFormat: Text.PlainText
    text: root.text
    color: root.panelForeground
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    wrapMode: Text.WordWrap
    // The unwrapped width, capped. Measured, never derived from this Text's
    // own implicitWidth -- that is what makes a wrapping Text loop.
    width: Math.min(metrics.advanceWidth + leftPadding + rightPadding + 1, root.maxWidth)
    leftPadding: Style.spacing.sm
    rightPadding: Style.spacing.sm
    topPadding: Style.spacing.sm
    bottomPadding: Style.spacing.sm
  }
}
