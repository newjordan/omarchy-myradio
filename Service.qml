import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// One instance per shell. Polls the local myradio studio, owns the listener
// (mpv on a verified connection, started through ctl.sh) and runs station actions. Every bar
// widget, on every monitor, reads this object.
Item {
  id: root

  property var shell: null

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string ctl: pluginDir + "/ctl.sh"
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/myradio.json"

  // ---- Reachability and station state (from ctl.sh status).
  property string reach: "offline"        // ok | offline | missing | foreign (port held by another account) | unverified (reply not signed by the studio)
  property bool installed: false
  property bool listening: false
  property var status: null
  property bool everPolled: false

  // ---- Persisted preferences and requests.
  property int volume: 80
  property int songSeconds: 150
  property string dataDir: ""
  property string port: ""
  property var requests: []               // [{key, job_id, role, text, state, track_id, queued, at}]
  property bool stateLoaded: false

  // ---- Panels open on any monitor speed up polling.
  property int openPanels: 0
  property string notice: ""
  property bool noticeIsError: false

  readonly property bool online: reach === "ok" && status !== null
  readonly property bool running: online && status.running === true
  readonly property var current: online ? status.current : null
  readonly property var queue: online && status.queue ? status.queue : []
  readonly property var history: online && status.history ? status.history : []
  readonly property var generation: online ? status.generation : null
  // Test-tone ("fixture") workers count too, so a test station can exercise requests.
  function canRole(role) {
    if (!generation) return false
    if (generation.roles && generation.roles[role]) return true
    return Array.isArray(generation.fixture_roles) && generation.fixture_roles.indexOf(role) >= 0
  }
  readonly property bool canMakeSongs: canRole("song")
  readonly property bool canSpeak: canRole("update")
  readonly property int making: generation && generation.jobs ? (Number(generation.jobs.running) || 0) : 0
  readonly property int waiting: generation && generation.jobs ? (Number(generation.jobs.queued) || 0) : 0
  readonly property string stationName: online && status.station && status.station.name ? status.station.name : "myradio"
  readonly property string tagline: online && status.station && status.station.tagline ? status.station.tagline : ""
  readonly property string mood: Model.mood(reach, status, making)
  readonly property string stateLine: Model.stateLine(reach, installed, status, listening)
  readonly property bool onAir: running && current !== null

  // Elapsed time, advanced locally between polls so the progress bar moves smoothly.
  property real elapsed: 0
  property real elapsedAt: 0
  readonly property real duration: current && current.duration ? Number(current.duration) : 0

  function env() {
    var e = {}
    if (dataDir) e.MYRADIO_DATA_DIR = dataDir
    if (port) e.MYRADIO_PORT = port
    return e
  }

  // ---- Commands. Each runs in its own Process so actions never queue behind a poll.
  Component {
    id: commandComponent
    Process {
      id: proc
      property var onDone: null
      property bool finished: false
      property bool exited: false
      property int code: 0
      function settle() {
        if (!finished || !exited) return
        if (onDone) onDone(code, String(out.text || ""))
        proc.destroy()
      }
      stdout: StdioCollector {
        id: out
        waitForEnd: true
        onStreamFinished: { proc.finished = true; proc.settle() }
      }
      onExited: function(exitCode) { proc.code = exitCode; proc.exited = true; proc.settle() }
    }
  }

  function run(args, done) {
    var p = commandComponent.createObject(root, {
      command: [ctl].concat(args),
      environment: env(),
      onDone: done || null
    })
    p.running = true
    return p
  }

  function say(text, isError) {
    notice = text
    noticeIsError = !!isError
    noticeTimer.restart()
  }

  Timer {
    id: noticeTimer
    interval: 4000
    onTriggered: root.notice = ""
  }

  // quiet: no notice on error and no follow-up poll (used by request tracking).
  function action(operation, args, done, quiet) {
    var body = JSON.stringify({ operation: operation, arguments: args || {} })
    run(["action", body], function(code, text) {
      var reply = Model.parseState(text)
      if (reply.error && !quiet) root.say(reply.error, true)
      if (done) done(reply)
      if (!quiet) poll()
    })
  }

  // ---- Transport. Play means "let me hear it": start playout if needed, then listen.
  function play() {
    if (!online) { launch(); return }
    if (!running) {
      action("transport.start", {}, function(reply) { if (!reply.error) listen() })
      return
    }
    listen()
  }

  function pause() { unlisten() }
  function togglePlay() { listening ? pause() : play() }
  function skip() { action("transport.skip") }
  function fadeNext() { action("transport.fade_next") }
  function stopStation() {
    unlisten()
    action("transport.stop")
  }
  function removeQueued(queueId) { action("queue.remove", { queue_id: queueId }) }
  function playNext(queueId) { action("queue.move", { queue_id: queueId, position: 0 }) }

  function listen() {
    listening = true
    run(["listen", String(volume)], function() {
      run(["title", Model.mediaTitle(status)])
      poll()
    })
  }

  function unlisten() {
    listening = false
    run(["unlisten"], function() { poll() })
  }

  function setVolume(v) {
    volume = Math.max(0, Math.min(130, Math.round(v)))
    volumeDebounce.restart()
  }

  Timer {
    id: volumeDebounce
    interval: 60
    onTriggered: {
      if (root.listening) root.run(["volume", String(root.volume)])
      root.saveState()
    }
  }

  function nudgeVolume(steps) { setVolume(volume + steps * 5) }

  function openStudio() {
    if (!online && reach !== "ok") { if (reach !== "foreign" && reach !== "unverified") launch(); return }
    run(["open"], function(code) {
      if (code === 93) root.say("Another account holds the studio port, so nothing was sent.", true)
      else if (code === 94) root.say("Could not verify the studio. Your control code was not sent. Update myradio to 0.5.0 or newer.", true)
      else if (code !== 0) root.say("The studio is not reachable.", true)
    })
  }

  function launch() {
    run(["launch"], function(code) {
      if (code === 91) root.say("myradio is not installed. Install it from myradio.garden.", true)
      else { root.say("Starting myradio…", false); fastPoll.restart() }
    })
  }

  // ---- Requests: a song from a description, or a message the DJ reads on air.
  function request(role, text) {
    text = String(text || "").trim()
    if (role === "song" && text.length < 3) { say("Describe the song in a few words.", true); return false }
    if (role === "update" && text.length < 1) return false
    var key = "omarchy-" + Date.now().toString(36)
    var entry = { key: key, job_id: "", role: role, text: text, state: "sending", track_id: "", queued: false, at: Date.now() }
    requests = [entry].concat(requests).slice(0, 8)
    saveState()
    var call = Model.enqueueCall(role, text, songSeconds, key)
    action(call.operation, call.arguments, function(reply) {
      var job = reply && reply.job ? reply.job : null
      updateRequest(key, job ? { job_id: job.id, state: job.state || "queued" } : { state: "failed", error: reply.error || "Not accepted" })
      if (job) say(role === "song" ? "Song requested. It plays next when it is ready." : "Sent to the DJ.", false)
    })
    return true
  }

  function updateRequest(key, fields) {
    var next = []
    for (var i = 0; i < requests.length; i++) {
      var r = requests[i]
      if (r.key === key) {
        var copy = {}
        for (var k in r) copy[k] = r[k]
        for (var f in fields) copy[f] = fields[f]
        next.push(copy)
      } else next.push(r)
    }
    requests = next
    saveState()
  }

  // Ask for a failed request again; it is followed and queued like a new one.
  function retryRequest(key) {
    var r = null
    for (var i = 0; i < requests.length; i++) if (requests[i].key === key) r = requests[i]
    if (!r || !r.job_id) return
    action("generation.retry", { job_id: r.job_id }, function(reply) {
      if (reply && reply.job) root.updateRequest(key, { state: reply.job.state || "queued", error: "", queued: false })
    })
  }

  function dismissRequest(key) {
    requests = requests.filter(function(r) { return r.key !== key })
    saveState()
  }

  // Follow each open request; when its audio reaches the library, queue it to play next.
  function syncDirectorRequests() {
    var list = director && Array.isArray(director.requests) ? director.requests : []
    if (list.length === 0) return
    var changed = false
    var next = requests.map(function(r) {
      if (!r.director) return r
      for (var i = 0; i < list.length; i++) {
        var d = list[i]
        if (d.key !== r.key) continue
        var state = d.state === "queued" ? "succeeded" : d.state
        if (state === r.state && (d.track_id || "") === (r.track_id || "")) return r
        changed = true
        var copy = {}
        for (var k in r) copy[k] = r[k]
        copy.state = state
        copy.queued = d.state === "queued"
        copy.track_id = d.track_id || ""
        copy.message = d.message || ""
        copy.headlines = d.headlines || []
        return copy
      }
      return r
    })
    if (changed) { requests = next; saveState() }
  }

  // What a request row says: where its clip is now, or how far it got.
  function requestLabel(r) {
    if (r.track_id && (r.queued || r.state === "succeeded")) {
      if (current && current.id === r.track_id) return "ON AIR"
      for (var i = 0; i < queue.length; i++) if (queue[i].track_id === r.track_id) return "UP NEXT"
      return "PLAYED"
    }
    if (r.state === "looking") return "LOOKING"
    if (r.state === "recording") return "RECORDING"
    if (r.state === "nothing") return "NOTHING NEW"
    if (r.state === "sending") return "SENDING"
    return Model.jobLabel(r).toUpperCase()
  }

  property int following: 0
  function followRequests() {
    if (!online || following > 0) return
    for (var i = 0; i < requests.length; i++) {
      var r = requests[i]
      if (r.director || !r.job_id || r.queued || (Model.jobDone(r) && r.state !== "succeeded")) continue
      following++
      ;(function(req) {
        root.action("generation.job", { job_id: req.job_id }, function(reply) {
          root.following = Math.max(0, root.following - 1)
          var job = reply ? reply.job : null
          if (!job || !job.state) return
          var fields = { state: job.state, track_id: job.track_id || "", error: job.error || "" }
          if (job.state === "succeeded" && job.track_id && !req.queued) {
            fields.queued = true
            root.action("queue.add", { track_id: job.track_id, position: 0 })
            root.say(req.role === "song" ? "Your song is ready. It plays next." : "The DJ has it. It airs next.", false)
          }
          root.updateRequest(req.key, fields)
        }, true)
      })(r)
    }
  }

  readonly property bool hasOpenRequests: {
    for (var i = 0; i < requests.length; i++) {
      var r = requests[i]
      if (!r.director && r.job_id && !r.queued && !Model.jobDone(r)) return true
      if (r.director && (r.state === "looking" || r.state === "recording")) return true
    }
    return false
  }

  // ---- Autopilot DJ (the director extension; null on a myradio without it).
  readonly property var director: online && status.director ? status.director : null
  property bool autopilotBusy: false
  property bool autopilotWanted: false
  readonly property bool autopilotOn: autopilotBusy ? autopilotWanted : !!(director && director.enabled)

  function setAutopilot(on) {
    if (!director) return
    autopilotWanted = on
    autopilotBusy = true
    action("director.configure", { settings: { enabled: on } }, function(reply) {
      root.autopilotBusy = false
      if (!reply.error) root.say(on ? "Autopilot DJ is on." : "Autopilot DJ is off.", false)
    })
  }

  // ---- DJs (the hosts extension) and spoken lines.
  property var hosts: []                  // [{id, name, role, speaker, blurb}]
  property string hostId: "marlowe"
  property string requestMode: "song"     // song | news | dj, remembered between opens
  function setMode(m) { if (m === "song" || m === "news" || m === "dj") { requestMode = m; saveState() } }
  readonly property var host: {
    for (var i = 0; i < hosts.length; i++) if (hosts[i].id === hostId) return hosts[i]
    return hosts.length > 0 ? hosts[0] : null
  }
  readonly property bool canHostBreak: canRole("host_break")
  readonly property bool canStationId: canRole("id")

  property bool hostsLoaded: false
  function loadHosts() {
    action("hosts.list", {}, function(reply) {
      root.hostsLoaded = true
      var list = reply && (reply.hosts || reply.personas)
      if (!Array.isArray(list)) return
      root.hosts = list.filter(function(h) { return !h.hidden }).map(function(h) {
        return { id: h.id, name: h.name, role: h.role, speaker: h.speaker, blurb: h.blurb }
      })
    }, true)
  }

  function stepHost(delta) {
    if (hosts.length === 0) return
    var i = 0
    for (var k = 0; k < hosts.length; k++) if (hosts[k].id === hostId) i = k
    hostId = hosts[(i + delta + hosts.length) % hosts.length].id
    saveState()
  }

  function facts() {
    var now = new Date()
    var f = {
      station: stationName,
      local_time: Qt.formatTime(now, "HH:mm"),
      weekday: Qt.formatDate(now, "dddd")
    }
    var h = now.getHours()
    f.daypart = h < 5 ? "overnight" : h < 10 ? "morning" : h < 15 ? "midday" : h < 19 ? "afternoon" : "evening"
    if (tagline) f.tagline = tagline
    if (host) f.host = host.name
    if (current) {
      f.now_title = current.title || ""
      if (current.artist) f.now_artist = current.artist
    }
    var next = queue.length > 0 ? queue[0] : null
    if (next) {
      f.next_title = next.title || ""
      if (next.artist) f.next_artist = next.artist
    }
    return f
  }

  // Voice a written script and put it on air next.
  function voice(role, script, speaker, label) {
    var key = "omarchy-" + Date.now().toString(36)
    var entry = { key: key, job_id: "", role: role, text: label, state: "sending", track_id: "", queued: false, at: Date.now(), host: host ? host.name : "" }
    requests = [entry].concat(requests).slice(0, 8)
    saveState()
    action("generation.enqueue", {
      role: role,
      payload: { text: script, speaker: speaker },
      priority: 85,
      idempotency_key: key
    }, function(reply) {
      var job = reply && reply.job ? reply.job : null
      updateRequest(key, job ? { job_id: job.id, state: job.state || "queued" } : { state: "failed", error: reply.error || "Not accepted" })
      if (job) say((host ? host.name : "The DJ") + " is recording it. It airs next.", false)
    })
  }

  // News: with the director, the topic is looked up (Google News through a researcher) and the chosen DJ reads the
  // sourced headlines on air next. Without it (an older myradio), the line is read as a listener update.
  function news(text) {
    text = String(text || "").trim()
    if (text.length < 3) { say("Say what to look up in a few words.", true); return false }
    if (director) {
      var h0 = host
      action("director.news_now", h0 ? { topic: text, host: h0.id } : { topic: text }, function(reply) {
        if (!reply || !reply.key) return
        var entry = { key: reply.key, job_id: "", role: "news", text: text, state: "looking", track_id: "", queued: false,
                      at: Date.now(), host: h0 ? h0.name : "", director: true, message: reply.message || "" }
        root.requests = [entry].concat(root.requests).slice(0, 8)
        root.saveState()
        root.say(reply.message || "Looking it up.", false)
      })
      return true
    }
    if (!host) return false
    var h = host
    action("hosts.compose_update", {
      persona: h.id,
      brief: { topic: "the news", items: [{ text: text.slice(0, 600), source: stationName + " newsroom" }] },
      facts: facts()
    }, function(reply) {
      if (!reply || !reply.text) return
      root.voice("update", reply.text, reply.speaker !== undefined ? reply.speaker : h.speaker, text)
    })
    return true
  }

  // Something for the chosen DJ to say on air, word for word.
  function sayLine(text) {
    text = String(text || "").trim()
    if (text.length < 2 || !host) return false
    voice("host_break", text.slice(0, 1000), host.speaker, text)
    return true
  }

  // A short DJ segment: time check, station ID, back-announce, next-up intro.
  readonly property var segments: [
    { id: "time_check", label: "Time", role: "host_break" },
    { id: "station_id", label: "Station ID", role: "id" },
    { id: "song_back_announce", label: "Back-announce", role: "host_break" },
    { id: "song_intro", label: "Next up", role: "host_break" }
  ]

  function segment(segId) {
    if (!host) return
    var seg = null
    for (var i = 0; i < segments.length; i++) if (segments[i].id === segId) seg = segments[i]
    if (!seg) return
    var h = host
    action("hosts.compose", { persona: h.id, segment: seg.id, facts: facts() }, function(reply) {
      if (!reply || !reply.text) return
      root.voice(seg.role, reply.text, reply.speaker !== undefined ? reply.speaker : h.speaker, h.name + ": " + seg.label.toLowerCase())
    })
  }

  // ---- Polling.
  Process {
    id: statusProc
    command: [root.ctl, "status"]
    environment: root.env()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  function poll() {
    if (!statusProc.running) statusProc.running = true
  }

  function applyStatus(text) {
    var v = Model.parseState(text)
    if (!v.reach) return
    var prevTitle = current ? current.id : ""
    reach = v.reach
    installed = v.installed === true
    listening = v.listening === true
    status = v.status || null
    everPolled = true
    if (status) {
      elapsed = Number(status.elapsed) || 0
      elapsedAt = Date.now()
      var nowId = status.current ? status.current.id : ""
      if (listening && nowId !== prevTitle) run(["title", Model.mediaTitle(status)])
    }
    if (hasOpenRequests) followRequests()
    syncDirectorRequests()
    if (online && hosts.length === 0 && !hostsAsked) { hostsAsked = true; loadHosts() }
    if (!online) { hostsAsked = false; hostsLoaded = false }
  }
  property bool hostsAsked: false

  Timer {
    id: pollTimer
    interval: root.openPanels > 0 ? 1500 : (root.listening || root.hasOpenRequests ? 4000 : 8000)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  // After launching the studio, look often until it answers.
  Timer {
    id: fastPoll
    interval: 1000
    repeat: true
    property int left: 20
    onRunningChanged: if (running) left = 20
    onTriggered: {
      root.poll()
      if (--left <= 0 || root.online) stop()
    }
  }

  // Smooth progress between polls.
  property real now: Date.now()
  Timer {
    interval: 250
    repeat: true
    running: root.onAir && root.openPanels > 0
    onTriggered: root.now = Date.now()
  }
  readonly property real position: onAir ? Math.min(duration > 0 ? duration : 1e9, elapsed + Math.max(0, (now - elapsedAt) / 1000)) : 0

  // ---- Persisted state.
  FileView {
    id: stateFile
    path: root.statePath
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.loadState(text())
    onLoadFailed: root.stateLoaded = true
  }

  function loadState(text) {
    var s = Model.parseState(text)
    if (typeof s.volume === "number") volume = Math.max(0, Math.min(130, Math.round(s.volume)))
    if (typeof s.songSeconds === "number") songSeconds = Math.max(30, Math.min(580, Math.round(s.songSeconds)))
    if (typeof s.dataDir === "string") dataDir = s.dataDir
    if (typeof s.port === "string" || typeof s.port === "number") port = String(s.port || "")
    if (Array.isArray(s.requests)) requests = s.requests.slice(0, 8)
    if (typeof s.hostId === "string" && s.hostId) hostId = s.hostId
    if (s.requestMode === "song" || s.requestMode === "news" || s.requestMode === "dj") requestMode = s.requestMode
    stateLoaded = true
    poll()
  }

  function saveState() {
    if (!stateLoaded) return
    stateFile.setText(JSON.stringify({
      volume: volume, songSeconds: songSeconds, dataDir: dataDir, port: port, hostId: hostId, requestMode: requestMode, requests: requests
    }, null, 2) + "\n")
  }

  // ---- IPC: omarchy-shell newjordan.myradio <fn>
  ShellIpc {
    target: "newjordan.myradio"
    function play(): void { root.play() }
    function pause(): void { root.pause() }
    function toggle(): void { root.togglePlay() }
    function skip(): void { root.skip() }
    function studio(): void { root.openStudio() }
    function request(text: string): void { root.request("song", text) }
    function news(topic: string): void { root.news(topic) }
    function say(text: string): void { root.sayLine(text) }
    function dj(segment: string): void { root.segment(segment) }
    function autopilot(state: string): void { root.setAutopilot(state === "on" ? true : state === "off" ? false : !root.autopilotOn) }
    function nowPlaying(): string { return root.current ? Model.mediaTitle(root.status) : root.stateLine }
  }
}
