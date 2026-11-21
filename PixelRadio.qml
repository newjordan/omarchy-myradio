import QtQuick
import qs.Commons

// The bar icon: Dial's silhouette on a 12x11 pixel grid, drawn in the bar's
// foreground so it follows the theme. On air, the antenna ball takes the
// accent color; while you listen, the screen shows a moving level meter.
// One Canvas, so the bar measures and centers it as a single box.
Canvas {
  id: root

  property color color: "white"
  property color accent: color
  property bool on: false
  property bool listening: false
  property bool offline: false
  property int frame: 0

  width: 12
  height: 11
  implicitWidth: 12
  implicitHeight: 11
  opacity: offline ? 0.45 : 1
  antialiasing: false
  renderStrategy: Canvas.Immediate

  // [x, y, w, h]
  readonly property var body: [
    [8, 1, 1, 1],                              // antenna stem
    [0, 2, 12, 1], [0, 9, 12, 1],              // top, bottom
    [0, 3, 1, 6], [11, 3, 1, 6],               // sides
    [8, 4, 2, 2],                              // knob
    [2, 7, 5, 1],                              // speaker grille
    [1, 10, 2, 1], [9, 10, 2, 1]               // feet
  ]

  // Level meter heights (0-2) per frame for the three screen columns.
  readonly property var meter: [[1, 2, 1], [2, 1, 2], [2, 2, 1], [1, 2, 2], [2, 1, 1], [1, 1, 2]]

  onColorChanged: requestPaint()
  onAccentChanged: requestPaint()
  onOnChanged: requestPaint()
  onListeningChanged: requestPaint()
  onFrameChanged: requestPaint()

  Timer {
    interval: 240
    repeat: true
    running: root.listening && root.visible && !Style.reduceMotion
    onTriggered: root.frame = (root.frame + 1) % root.meter.length
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    ctx.fillStyle = root.color
    for (var i = 0; i < body.length; i++) {
      var r = body[i]
      ctx.fillRect(r[0], r[1], r[2], r[3])
    }
    // Antenna ball.
    ctx.fillStyle = root.on ? root.accent : root.color
    ctx.fillRect(9, 0, 2, 1)
    // Screen (x 2-6, y 4-5).
    if (root.listening) {
      ctx.fillStyle = root.on ? root.accent : root.color
      var levels = meter[frame]
      for (var c = 0; c < 3; c++) {
        var h = levels[c]
        ctx.fillRect(2 + c * 2, 6 - h, 1, h)
      }
    } else {
      ctx.fillStyle = root.color
      ctx.fillRect(2, 4, 5, 1)
      ctx.fillRect(2, 5, 1, 1)
      ctx.fillRect(6, 5, 1, 1)
    }
  }
}
