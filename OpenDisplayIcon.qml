import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Tablet glyph drawn natively (an outlined slate with a home bar), so it stays
// crisp at bar size and takes the theme's colors. State is expressed by the
// caller through `color`/opacity; `badge` adds the update dot.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Commons.Color.foreground
  property color badgeColor: Commons.Color.urgent
  property bool badge: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real stroke: Math.max(1, Math.round(iconSize * 0.11))

  Rectangle {
    id: slate
    anchors.centerIn: parent
    height: root.iconSize
    width: Math.round(root.iconSize * 0.78)
    radius: Math.max(1, root.iconSize * 0.14)
    color: "transparent"
    border.width: root.stroke
    border.color: root.color

    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: root.stroke + Math.max(1, Math.round(root.iconSize * 0.07))
      width: Math.max(2, Math.round(parent.width * 0.26))
      height: Math.max(1, Math.round(root.stroke * 0.9))
      color: root.color
    }
  }

  BorderSurface {
    visible: root.badge
    width: Math.max(5, Math.round(root.iconSize * 0.4))
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: -Math.round(width * 0.25)
    anchors.topMargin: -Math.round(width * 0.2)
    borderSpec: Border.flat(Commons.Color.popups.background, 1)
  }
}
