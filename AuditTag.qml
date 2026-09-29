import QtQuick
import qs.Commons

// The little reference label each control carries during a walkthru audit
// (0: "add a debug mode (on by default) ... itemize each item with a label so I
// can reference it ... make them just enough to see them, but not blow the
// whole thing apart"). Numbering restarts per panel: a standalone item is a
// bare number, a cluster is that number plus a letter (3a, 3b ... 3z, 3aa).
//
// It never changes layout: anchored into the parent's top-left corner with zero
// implicit size, drawn over whatever is there. Parent it to a real control, not
// straight into a RowLayout/ColumnLayout, or the layout will give it a cell.
Item {
  id: root

  property string tag: ""
  // Every tag in a panel is bound to that panel's auditTags flag, so one debug
  // IPC call clears the lot.
  property bool shown: true
  // Separators and other full-width items put their tag at the right end, so it
  // doesn't stack on top of the tag belonging to whatever is under them.
  property bool atRight: false
  // Hangs the tag under the item instead of over it -- for the top row of a
  // panel, where there is no room above before the frame clips it.
  property bool below: false
  // Draws the tag INSIDE the item's top-left corner. Needed for anything that
  // clips its children (the previews do), which would otherwise cut the tag off.
  property bool inside: false

  anchors.left: root.atRight ? undefined : (parent ? parent.left : undefined)
  anchors.right: root.atRight ? (parent ? parent.right : undefined) : undefined
  // Sits just ABOVE the item rather than over it: a badge on top of a label
  // hides the very text being audited.
  anchors.bottom: (parent && !root.below && !root.inside) ? parent.top : undefined
  anchors.top: parent ? ((root.below) ? parent.bottom : (root.inside ? parent.top : undefined)) : undefined
  anchors.leftMargin: -2
  anchors.bottomMargin: -1
  anchors.topMargin: 1
  implicitWidth: 0
  implicitHeight: 0
  z: 900
  visible: root.shown && root.tag !== ""

  Rectangle {
    // The tag Item has zero size and sits on the parent's top edge, so the
    // badge is anchored upward off it.
    anchors.bottom: (root.below || root.inside) ? undefined : parent.bottom
    anchors.top: (root.below || root.inside) ? parent.top : undefined
    anchors.left: root.atRight ? undefined : parent.left
    anchors.right: root.atRight ? parent.right : undefined
    width: label.implicitWidth + 4
    height: label.implicitHeight + 1
    radius: 2
    // Its own colours, not the theme's: the tags have to stay readable over
    // wallpaper thumbnails and both light and dark themes.
    color: "#cc000000"
    border.width: 1
    border.color: "#ffcc66"

    Text {
      id: label
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: root.tag
      color: "#ffcc66"
      font.family: Style.font.family
      font.pixelSize: 8
      font.bold: true
    }
  }
}
