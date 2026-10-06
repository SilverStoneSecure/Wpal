import QtQuick
import qs.Commons

// Concentric fading rings just outside a tile. Off at rest; pulses while
// `hovered` is true. Parent it to the tile and let it fill it.
Item {
  id: root
  property string moduleName: "io.github.silverstone.wpal"

  property color glowColor: Color.accent
  property bool hovered: false
  property real pulse: 0

  z: -1
  anchors.fill: parent

  Repeater {
    model: 8
    Rectangle {
      required property int index
      anchors.centerIn: parent
      width: root.width + (index + 1) * 2
      height: root.height + (index + 1) * 2
      radius: Style.cornerRadius + index + 1
      color: "transparent"
      border.width: 1
      border.color: root.glowColor
      opacity: root.pulse * Math.pow(1 - index / 8, 2)
    }
  }

  SequentialAnimation {
    running: root.hovered
    loops: Animation.Infinite
    NumberAnimation { target: root; property: "pulse"; from: 0.35; to: 1.0; duration: 650; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "pulse"; from: 1.0; to: 0.35; duration: 650; easing.type: Easing.InOutSine }
    onStopped: root.pulse = 0
  }
}
