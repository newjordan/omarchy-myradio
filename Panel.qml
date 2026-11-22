import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar widget: a pixel radio in the bar, and a panel with what is on air, the
// transport, song requests and the queue. State lives in Service.qml, shared by
// every monitor's bar.
Panel {
  id: root
  moduleName: "newjordan.myradio"
  manageIpc: false
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property var radio: null
  function lookupService() {
    if (radio) return
    var s = bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor("newjordan.myradio") : null
    if (s) radio = s
  }
  onBarChanged: lookupService()
  Timer {
    interval: 400
    repeat: true
    running: !root.radio
    triggeredOnStart: true
    onTriggered: root.lookupService()
  }

  readonly property bool online: radio ? radio.online : false
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property color accent: Commons.Color.accent
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Keyboard cursor over the queue rows; -1 is the transport.
  property int cursor: -1
  readonly property string requestRole: radio ? radio.requestMode : "song"
  function setRole(v) { if (radio) radio.setMode(v) }

  onOpenedChanged: {
    if (!radio) return
    radio.openPanels = Math.max(0, radio.openPanels + (opened ? 1 : -1))
    if (opened) { radio.poll(); cursor = -1 }
  }
  Component.onDestruction: if (radio && opened) radio.openPanels = Math.max(0, radio.openPanels - 1)

  function moveCursor(dy) {
    var n = radio ? radio.queue.length : 0
    cursor = Math.max(-1, Math.min(n - 1, cursor + dy))
  }

  function activate() {
    if (!radio) return
    if (cursor >= 0 && cursor < radio.queue.length) radio.playNext(radio.queue[cursor].id)
    else radio.togglePlay()
  }

  function focusRequest() {
    var c = panel.loadedContent
    if (!c || !root.radio || !root.radio.online) return
    if (root.requestRole === "dj" && c.sayField) c.sayField.forceActiveFocus()
    else if (c.requestField && c.requestField.visible) c.requestField.forceActiveFocus()
  }

  // ---------------------------------------------------------------- bar icon
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.radio ? (root.radio.current ? Model.mediaTitle(root.radio.status) : root.radio.stateLine) : "myradio"
    iconComponent: Component {
      Item {
        PixelRadio {
          x: Math.round((parent.width - width) / 2)
          y: Math.round((parent.height - height) / 2)
          on: root.radio ? root.radio.onAir : false
          listening: root.radio ? root.radio.listening : false
          offline: !root.online
          color: root.fg
          accent: root.accent
        }
      }
    }
    onPressed: function(b) {
      if (!root.radio) return
      if (b === Qt.MiddleButton) root.radio.togglePlay()
      else if (b === Qt.RightButton) root.radio.skip()
      else root.toggle()
    }
    onWheelMoved: function(delta) { if (root.radio) root.radio.nudgeVolume(delta > 0 ? 1 : -1) }
  }

  // ---------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(404))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(820))

    content: PanelKeyCatcher {
      id: keys
      property alias requestField: requestField
      property alias sayField: sayField
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      blocked: requestField.activeFocus || sayField.activeFocus

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (root.radio) root.radio.nudgeVolume(dx)
      }
      onActivateRequested: root.activate()
      onDeleteRequested: if (root.radio && root.cursor >= 0 && root.cursor < root.radio.queue.length) root.radio.removeQueued(root.radio.queue[root.cursor].id)
      onTextKey: function(t, mods) {
        if (!root.radio) return
        if (t === "n") root.radio.skip()
        else if (t === "f") root.radio.fadeNext()
        else if (t === "o") root.radio.openStudio()
        else if (t === "w") root.radio.windUp()
        else if (t === "a") root.radio.setAutopilot(!root.radio.autopilotOn)
        else if (t === "/" || t === "r") root.focusRequest()
        else if (t === "d") { root.setRole(root.requestRole === "song" ? "news" : root.requestRole === "news" ? "dj" : "song"); root.focusRequest() }
        else if (t === ",") root.radio.stepHost(-1)
        else if (t === ".") root.radio.stepHost(1)
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: flick.width
          spacing: Style.space(14)

          // ------------------------------------------------ hero: Dial + station
          Item {
            width: parent.width
            height: Math.max(dial.height, heroText.implicitHeight)

            Image {
              id: dial
              width: Style.space(76)
              height: width
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              source: Qt.resolvedUrl("assets/dial-" + (root.radio ? root.radio.mood : "sleepy") + ".png")
              smooth: false
              mipmap: false
              fillMode: Image.PreserveAspectFit
              sourceSize.width: 256
              sourceSize.height: 256

              // Dial bobs to the beat while a song plays.
              property real bob: 0
              transform: Translate { y: dial.bob }
              SequentialAnimation on bob {
                running: root.opened && !Style.reduceMotion && root.radio && (root.radio.mood === "singing" || root.radio.mood === "excited")
                loops: Animation.Infinite
                NumberAnimation { to: -3; duration: 260; easing.type: Easing.OutQuad }
                NumberAnimation { to: 0; duration: 260; easing.type: Easing.InQuad }
                onRunningChanged: if (!running) dial.bob = 0
              }
            }

            Column {
              id: heroText
              anchors.left: dial.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Row {
                spacing: Style.space(8)
                width: parent.width

                Text {
                  textFormat: Text.PlainText
                  text: root.radio ? root.radio.stationName : "myradio"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                  elide: Text.ElideRight
                  width: Math.min(implicitWidth, parent.width - airPill.width - parent.spacing)
                  anchors.verticalCenter: parent.verticalCenter
                }

                // ON AIR light.
                Rectangle {
                  id: airPill
                  visible: root.radio && root.radio.onAir
                  anchors.verticalCenter: parent.verticalCenter
                  height: airText.implicitHeight + Style.space(4)
                  width: airText.implicitWidth + airDot.width + Style.space(14)
                  radius: Math.min(height / 2, Math.max(2, Style.cornerRadius))
                  color: Util.alpha(root.accent, 0.16)
                  border.width: 1
                  border.color: Util.alpha(root.accent, 0.6)

                  Rectangle {
                    id: airDot
                    width: Style.space(6); height: width; radius: width / 2
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.accent
                    SequentialAnimation on opacity {
                      running: airPill.visible && root.opened && !Style.reduceMotion
                      loops: Animation.Infinite
                      NumberAnimation { to: 0.25; duration: 700 }
                      NumberAnimation { to: 1; duration: 700 }
                    }
                  }
                  Text {
                    id: airText
                    anchors.left: airDot.right
                    anchors.leftMargin: Style.space(5)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "ON AIR"
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.2
                  }
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                visible: text !== ""
                text: root.radio ? root.radio.tagline : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.radio ? root.radio.stateLine.toUpperCase() : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
            }
          }

          // ------------------------------------------------ studio closed / not installed
          Column {
            visible: root.radio && !root.radio.online
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.fg }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: !root.radio ? "" : root.radio.reach === "foreign"
                ? "Another account on this computer is using the studio's port, so nothing is sent to it. Stop that program or run the studio on another port."
                : root.radio.reach === "unverified"
                ? "Something answers on the studio's port but cannot prove it is your studio, so its replies are ignored and your control code is never sent. Update myradio to 0.5.0 or newer (on the station computer, if you use an SSH tunnel)."
                : root.radio.startCommand.length
                ? "Your studio is shut down. Wind it up to start it, play and go live."
                : root.radio.installed
                ? "Your station runs on this computer. Start the studio to put it on air, or wind it up to start, play and go live."
                : "myradio is a radio station that runs on your graphics card: songs, a DJ and your agent on air. Install it from myradio.garden, start it once, and it shows up here."
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              lineHeight: 1.2
            }

            Row {
              spacing: Style.space(8)
              Button {
                visible: root.radio && (root.radio.installed || root.radio.startCommand.length > 0)
                         && root.radio.reach !== "foreign" && root.radio.reach !== "unverified"
                text: root.radio && root.radio.winding ? "Winding up…" : "Wind up"
                iconText: ""
                iconSpinning: !!root.radio && root.radio.winding
                tooltipText: "Start the studio, start playing and go live"
                bordered: true
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.radio.windUp()
              }
              Button {
                visible: root.radio && root.radio.installed && root.radio.startCommand.length === 0
                         && root.radio.reach !== "foreign" && root.radio.reach !== "unverified"
                text: "Start myradio"
                iconText: ""
                bordered: true
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.radio.launch()
              }
              Button {
                text: "myradio.garden"
                iconText: ""
                bordered: true
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: Quickshell.execDetached(["xdg-open", "https://myradio.garden"])
              }
            }
          }

          // ------------------------------------------------ now playing
          Column {
            visible: root.online
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.fg }

            Column {
              width: parent.width
              spacing: Style.space(3)

              Text {
                textFormat: Text.PlainText
                text: root.radio && root.radio.current ? Model.kindLabel(root.radio.current.kind).toUpperCase() : "NOTHING ON AIR"
                color: root.radio && root.radio.current ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.radio && root.radio.current ? (root.radio.current.title || "Untitled")
                  : (root.radio && root.radio.status && root.radio.status.library_total === 0
                      ? (root.radio.making > 0 ? "Making the first song…" : "The library is empty")
                      : (root.radio && root.radio.running ? "Waiting for audio" : "Press play to start the station"))
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                visible: text !== ""
                text: root.radio && root.radio.current ? (root.radio.current.artist || "") : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
            }

            // Progress.
            Column {
              visible: root.radio && root.radio.current && root.radio.duration > 0
              width: parent.width
              spacing: Style.space(4)

              Rectangle {
                width: parent.width
                height: Style.space(3)
                radius: height / 2
                color: root.faint
                Rectangle {
                  height: parent.height
                  radius: parent.radius
                  width: root.radio && root.radio.duration > 0 ? parent.width * Math.min(1, root.radio.position / root.radio.duration) : 0
                  color: root.fg
                }
              }
              Item {
                width: parent.width
                height: posText.implicitHeight
                Text {
                  id: posText
                  textFormat: Text.PlainText
                  text: root.radio ? Model.clock(root.radio.position) : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  anchors.right: parent.right
                  textFormat: Text.PlainText
                  text: root.radio ? Model.clock(root.radio.duration) : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // Transport.
            Item {
              width: parent.width
              height: playBtn.height

              Row {
                anchors.centerIn: parent
                spacing: Style.space(18)

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: "Stop the station"
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  enabled: root.radio && root.radio.running
                  onClicked: root.radio.stopStation()
                }

                // Play: start the station if needed, then listen here.
                Rectangle {
                  id: playBtn
                  width: Style.space(46)
                  height: width
                  radius: width / 2
                  color: playArea.pressed ? Qt.darker(root.fg, 1.25) : (playArea.containsMouse || root.cursor === -1 && root.opened ? root.fg : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.88))
                  border.width: root.cursor === -1 ? 2 : 0
                  border.color: Util.alpha(root.accent, 0.8)
                  Text {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: root.radio && root.radio.listening ? 0 : 2
                    textFormat: Text.PlainText
                    text: root.radio && root.radio.listening ? "" : ""
                    color: Commons.Color.popups.background
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                  }
                  MouseArea {
                    id: playArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.radio.togglePlay()
                  }
                  PanelToolTip {
                    visible: playArea.containsMouse
                    text: root.radio && root.radio.listening ? "Stop listening (the station keeps playing)" : "Listen"
                  }
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: "Skip  (n)"
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  enabled: root.radio && root.radio.onAir
                  onClicked: root.radio.skip()
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: "Fade into the next track  (f)"
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  enabled: root.radio && root.radio.onAir
                  onClicked: root.radio.fadeNext()
                }
              }
            }

            // Volume.
            Row {
              width: parent.width
              spacing: Style.space(10)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.radio && root.radio.volume === 0 ? "" : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
                width: Style.space(16)
              }
              PanelSlider {
                id: volSlider
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(16) - volText.width - parent.spacing * 2
                bar: root.bar
                minimum: 0
                maximum: 130
                step: 5
                integer: true
                value: root.radio ? root.radio.volume : 80
                onMoved: function(v) { if (root.radio) root.radio.setVolume(v) }
                onReleased: function(v) { if (root.radio) root.radio.setVolume(v) }
              }
              Text {
                id: volText
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(28)
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                text: root.radio ? String(root.radio.volume) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ------------------------------------------------ requests: song, news, DJ
          Column {
            visible: root.online
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.fg }

            Item {
              width: parent.width
              height: roleGroup.height
              PanelSectionHeader {
                anchors.verticalCenter: parent.verticalCenter
                text: root.requestRole === "song" ? "REQUEST A SONG" : root.requestRole === "news" ? "NEWS AND INFO" : "ON THE MIC"
                foreground: root.fg
                fontFamily: root.fontFamily
              }
              ButtonGroup {
                id: roleGroup
                anchors.right: parent.right
                focusable: false
                options: [{ value: "song", label: "Song" }, { value: "news", label: "News" }, { value: "dj", label: "DJ" }]
                value: root.requestRole
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onChanged: function(v) { root.setRole(v); root.focusRequest() }
              }
            }

            // DJ stepper (news and DJ modes).
            Item {
              visible: root.requestRole !== "song"
              width: parent.width
              height: Math.max(hostPrev.height, hostText.implicitHeight)
              PanelActionButton {
                id: hostPrev
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                iconText: ""
                tooltipText: "Previous DJ  ( , )"
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.radio.stepHost(-1)
              }
              Column {
                id: hostText
                anchors.left: hostPrev.right
                anchors.right: hostNext.left
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)
                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: root.radio && root.radio.host ? root.radio.host.name + "  ·  " + root.radio.host.role
                    : (root.radio && root.radio.hostsLoaded ? "No DJs on this station" : "Loading DJs…")
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  visible: text !== ""
                  text: root.radio && root.radio.host ? (root.radio.host.blurb || "") : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              PanelActionButton {
                id: hostNext
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: ""
                tooltipText: "Next DJ  ( . )"
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.radio.stepHost(1)
              }
            }

            TextField {
              id: requestField
              visible: root.requestRole !== "dj"
              width: parent.width
              foreground: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              enabled: root.radio && (root.requestRole === "song" ? root.radio.canMakeSongs : root.radio.canSpeak)
              placeholderText: root.requestRole === "song"
                ? (!enabled ? "Add a music maker in the studio first"
                   : root.radio.songWarming ? "Genre, mood, what it is about (the maker is warming up)" : "Genre, mood, what it is about")
                : (!enabled ? "Add a DJ voice in the studio first"
                   : (root.radio.director ? "A topic to look up, like Cerebras hackathon" : "A news line for the DJ to read")
                     + (root.radio.voiceWarming ? " (the voice is warming up)" : ""))
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  requestField.text = ""
                  keys.forceActiveFocus()
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  var ok = root.requestRole === "song" ? root.radio.request("song", requestField.text) : root.radio.news(requestField.text)
                  if (ok) requestField.text = ""
                  event.accepted = true
                }
              }
            }

            // Something for the DJ to say, word for word.
            TextField {
              id: sayField
              visible: root.requestRole === "dj"
              width: parent.width
              foreground: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              enabled: root.radio && root.radio.canHostBreak
              placeholderText: enabled ? "Something for " + (root.radio.host ? root.radio.host.name : "the DJ") + " to say on air"
                                       : "Add a DJ voice in the studio first"
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  sayField.text = ""
                  keys.forceActiveFocus()
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (root.radio.sayLine(sayField.text)) sayField.text = ""
                  event.accepted = true
                }
              }
            }

            // Quick DJ segments.
            Flow {
              visible: root.requestRole === "dj"
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: root.radio ? root.radio.segments : []
                Button {
                  required property var modelData
                  text: modelData.label
                  bordered: true
                  enabled: root.radio && (modelData.role === "id" ? root.radio.canStationId : root.radio.canHostBreak)
                  opacity: enabled ? 1 : 0.4
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.radio.segment(modelData.id)
                }
              }
            }
            Text {
              visible: root.requestRole === "dj" && root.radio && !root.radio.canHostBreak
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Add a DJ voice in the studio to put these on air."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Autopilot DJ: intros, station IDs and news made ahead and placed between songs.
            Item {
              visible: root.requestRole === "dj" && root.radio && root.radio.director !== null
              width: parent.width
              height: Math.max(autoText.implicitHeight, autoSwitch.implicitHeight) + Style.space(6)
              Column {
                id: autoText
                anchors.left: parent.left
                anchors.right: autoSwitch.left
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)
                Text {
                  textFormat: Text.PlainText
                  text: "AUTOPILOT DJ"
                  color: root.radio && root.radio.autopilotOn ? root.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: {
                    var d = root.radio ? root.radio.director : null
                    if (!d) return ""
                    var st = d.settings || {}
                    var parts = ["Intro every " + (st.every_songs || 3) + " songs"]
                    if (st.station_id_minutes) parts.push("ID every " + st.station_id_minutes + " min")
                    if (st.news_minutes) parts.push("news every " + st.news_minutes + " min")
                    if (root.radio.autopilotOn && d.waiting > 0) parts.push(d.waiting + " lined up")
                    return parts.join("  ·  ")
                  }
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
              ToggleSwitch {
                id: autoSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.radio ? root.radio.autopilotOn : false
                busy: root.radio ? root.radio.autopilotBusy : false
                foreground: root.fg
                onToggled: root.radio.setAutopilot(!checked)
              }
            }

            // Recent requests and their progress.
            Column {
              width: parent.width
              spacing: Style.space(2)
              visible: root.radio && root.radio.requests.length > 0

              Repeater {
                model: root.radio ? root.radio.requests.slice(0, 4) : []
                Item {
                  required property var modelData
                  width: parent ? parent.width : 0
                  height: Style.space(24)

                  Text {
                    id: reqIcon
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(18)
                    textFormat: Text.PlainText
                    text: modelData.role === "song" ? "" : (modelData.role === "update" || modelData.role === "news") ? "" : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    anchors.left: reqIcon.right
                    anchors.right: reqState.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: (modelData.host && modelData.role !== "song" ? modelData.host + ": " : "") + modelData.text
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                  Text {
                    id: reqState
                    anchors.right: retry.visible ? retry.left : dismiss.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.radio ? root.radio.requestLabel(modelData) : ""
                    color: modelData.state === "failed" || modelData.state === "expired" ? (root.bar ? root.bar.urgent : Commons.Color.urgent)
                      : (text === "ON AIR" || text === "UP NEXT" || modelData.state === "running" || modelData.state === "looking" || modelData.state === "recording"
                         ? root.accent : root.dim)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                    SequentialAnimation on opacity {
                      running: (modelData.state === "running" || modelData.state === "looking" || modelData.state === "recording") && root.opened && !Style.reduceMotion
                      loops: Animation.Infinite
                      NumberAnimation { to: 0.35; duration: 600 }
                      NumberAnimation { to: 1; duration: 600 }
                    }
                  }
                  MouseArea {
                    id: reqHover
                    anchors.left: parent.left
                    anchors.right: reqState.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                  }
                  PanelToolTip {
                    visible: reqHover.containsMouse && text !== ""
                    text: {
                      var lines = []
                      if (modelData.message) lines.push(modelData.message)
                      var heads = modelData.headlines || []
                      for (var i = 0; i < heads.length; i++) lines.push("• " + heads[i])
                      if (!lines.length && modelData.error) lines.push(modelData.error)
                      return lines.join("\n")
                    }
                  }
                  PanelActionButton {
                    id: retry
                    visible: modelData.job_id && (modelData.state === "failed" || modelData.state === "expired" || modelData.state === "interrupted")
                    anchors.right: dismiss.left
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "\uf01e"
                    tooltipText: modelData.error ? "Try again: " + modelData.error : "Try again"
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.radio.retryRequest(modelData.key)
                  }
                  PanelActionButton {
                    id: dismiss
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: ""
                    tooltipText: "Dismiss"
                    foreground: root.dim
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.radio.dismissRequest(modelData.key)
                  }
                }
              }
            }
          }

          // ------------------------------------------------ up next
          Column {
            visible: root.online
            width: parent.width
            spacing: Style.space(4)

            PanelSeparator { foreground: root.fg }

            Item {
              width: parent.width
              height: upHeader.implicitHeight
              PanelSectionHeader {
                id: upHeader
                text: "UP NEXT"
                foreground: root.fg
                fontFamily: root.fontFamily
              }
              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: !root.radio || !root.radio.status ? "" : (root.radio.status.queue_total > 0
                  ? root.radio.status.queue_total + " queued"
                  : (root.radio.status.station && root.radio.status.station.auto_fill ? "Auto-fill from the library" : "Queue is empty"))
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Repeater {
              model: root.radio ? root.radio.queue.slice(0, 6) : []
              Rectangle {
                required property var modelData
                required property int index
                width: parent ? parent.width : 0
                height: Style.spacing.popupRowHeight
                radius: Style.cornerRadius
                color: root.cursor === index || rowMouse.containsMouse ? Style.hoverFillFor(root.fg, root.accent) : "transparent"

                Text {
                  id: rowIndex
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  textFormat: Text.PlainText
                  text: String(index + 1)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  anchors.left: rowIndex.right
                  anchors.right: rowActions.visible ? rowActions.left : rowTime.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: (modelData.title || "Untitled") + (modelData.artist ? "  ·  " + modelData.artist : "")
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text {
                  id: rowTime
                  visible: !rowActions.visible
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: (modelData.kind && modelData.kind !== "music" ? Model.kindLabel(modelData.kind).toUpperCase() + "  " : "") + Model.clock(modelData.duration)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Row {
                  id: rowActions
                  visible: root.cursor === index || rowMouse.containsMouse
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)
                  z: 2
                  PanelActionButton {
                    visible: index > 0
                    iconText: ""
                    tooltipText: "Play next  (Enter)"
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    onClicked: root.radio.playNext(modelData.id)
                  }
                  PanelActionButton {
                    iconText: ""
                    tooltipText: "Remove  (x)"
                    foreground: root.fg
                    hoverColor: root.bar ? root.bar.urgent : Commons.Color.urgent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    onClicked: root.radio.removeQueued(modelData.id)
                  }
                }
                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
                  onContainsMouseChanged: if (containsMouse) root.cursor = index
                }
              }
            }
          }

          // ------------------------------------------------ footer
          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.fg; visible: root.online }

            Item {
              width: parent.width
              height: Math.max(footerText.implicitHeight, footerButtons.implicitHeight)
              visible: root.online

              Text {
                id: footerText
                anchors.left: parent.left
                anchors.right: footerButtons.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: {
                  if (!root.radio || !root.radio.status) return ""
                  var s = root.radio.status
                  var parts = [s.library_total + (s.library_total === 1 ? " track" : " tracks")]
                  if (s.stats && s.stats.on_air_seconds) parts.push(Model.hours(s.stats.on_air_seconds) + " on air")
                  if (root.radio.autopilotOn) parts.push("autopilot")
                  if (s.broadcast === "streaming") parts.push("LIVE")
                  return parts.join("  ·  ")
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Row {
                id: footerButtons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                // Shown while the station is stopped, or while a saved broadcast is not live.
                Button {
                  visible: !!root.radio && !!root.radio.status && (root.radio.status.running !== true
                           || (root.radio.status.broadcast_ready === true
                               && ["streaming", "connecting", "retrying"].indexOf(root.radio.status.broadcast) < 0))
                  text: root.radio && root.radio.winding ? "Winding up…" : "Wind up"
                  iconText: ""
                  iconSpinning: !!root.radio && root.radio.winding
                  tooltipText: "Start the studio if needed, start playing and go live"
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.radio.windUp()
                }
                // Two clicks: the first arms it for a few seconds.
                Button {
                  id: offAirBtn
                  property bool armed: false
                  text: armed ? "Shut down?" : "Off air"
                  iconText: ""
                  tooltipText: "Stop the broadcast and playout, and shut the studio down"
                  foreground: armed ? (root.bar ? root.bar.urgent : Commons.Color.urgent) : root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: {
                    if (!armed) { armed = true; disarm.restart(); return }
                    armed = false
                    root.radio.offAir()
                  }
                  Timer { id: disarm; interval: 4000; onTriggered: offAirBtn.armed = false }
                }
                Button {
                  id: studioBtn
                  text: "Open studio"
                  iconText: ""
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.radio.openStudio()
                }
              }
            }

            // Notices from the last action.
            Text {
              width: parent.width
              visible: root.radio && root.radio.notice !== ""
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.radio ? root.radio.notice : ""
              color: root.radio && root.radio.noticeIsError ? (root.bar ? root.bar.urgent : Commons.Color.urgent) : root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }
    }
  }
}
