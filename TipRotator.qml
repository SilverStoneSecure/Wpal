import QtQuick

// Hover text that rotates while the pointer stays on a button (the randomize
// buttons' little easter egg): `base` for 5s, then "Roll the Dice" for 3s,
// then the quote for 5s, then round again. Leaving the button resets it.
// Zero-size and invisible; declare it inside the button, feed `hovering` from
// the button's hovered() signal, and bind the tooltip to `text`.
Item {
  id: root

  property bool hovering: false
  property string base: ""

  property int stage: 0
  readonly property var extras: [
    "Roll the Dice",
    "Nothing worth having comes without some kind of fight\nYou Gotta Kick at the Darkness 'till it BLEEDS daylight!"
  ]
  // How long each stage shows: base, dice, quote.
  readonly property var durations: [5000, 3000, 5000]
  readonly property string text: root.stage === 0 ? root.base : root.extras[root.stage - 1]

  onHoveringChanged: {
    root.stage = 0
    tick.interval = root.durations[0]
    if (root.hovering) tick.restart()
    else tick.stop()
  }

  Timer {
    id: tick
    repeat: false
    onTriggered: {
      root.stage = (root.stage + 1) % (root.extras.length + 1)
      tick.interval = root.durations[root.stage]
      tick.restart()
    }
  }
}
