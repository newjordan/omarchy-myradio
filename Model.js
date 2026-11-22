.pragma library

// Pure helpers for the myradio plugin. No QML types, so they stay testable.

// Which Dial to show for the station's state.
function mood(reach, status, making) {
  if (reach !== "ok" || !status) return "sleepy"
  if (making > 0) return "excited"
  if (!status.running) return "happy"
  var cur = status.current
  if (!cur) return "hungry"
  if (cur.kind === "speech" || cur.kind === "ad") return "onair"
  return "singing"
}

// What the station is doing, in one line.
function stateLine(reach, installed, status, listening) {
  if (reach === "missing") return installed ? "Start myradio once to finish setup" : "myradio is not installed"
  if (reach === "foreign") return "Another account holds the studio port"
  if (reach !== "ok" || !status) return "Studio is closed"
  var health = status.health || {}
  if (health.state === "fault") return "Station fault"
  if (!status.running) return "Off air"
  if (!status.current) return "Waiting for audio"
  if (listening) return "Listening here"
  var n = Number(status.listeners) || 0
  return n > 0 ? n + (n === 1 ? " listener" : " listeners") : "Press play to listen"
}

function clock(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var m = Math.floor(s / 60)
  var r = s % 60
  if (m >= 60) {
    var h = Math.floor(m / 60)
    m = m % 60
    return h + ":" + (m < 10 ? "0" : "") + m + ":" + (r < 10 ? "0" : "") + r
  }
  return m + ":" + (r < 10 ? "0" : "") + r
}

function kindLabel(kind) {
  if (kind === "speech") return "DJ"
  if (kind === "ad") return "Spot"
  if (kind === "music") return "Song"
  return kind ? String(kind) : ""
}

function hours(seconds) {
  var h = (Number(seconds) || 0) / 3600
  if (h < 1) return Math.round(h * 60) + " min"
  return (h < 10 ? h.toFixed(1) : Math.round(h)) + " h"
}

// The media title the listener publishes over MPRIS.
function mediaTitle(status) {
  if (!status || !status.current) return "myradio"
  var cur = status.current
  var name = status.station && status.station.name ? status.station.name : "myradio"
  return (cur.title || "Untitled") + (cur.artist ? " — " + cur.artist : "") + " · " + name
}

// A request from the panel, as a generation.enqueue call. role "song" makes a
// song from a description; role "update" has the DJ read the text on air.
function enqueueCall(role, text, durationS, key) {
  var payload = role === "song"
    ? { tags: String(text).slice(0, 800), duration_s: durationS }
    : { text: String(text).slice(0, 1000) }
  return {
    operation: "generation.enqueue",
    arguments: { role: role, payload: payload, priority: 80, idempotency_key: key }
  }
}

function jobLabel(job) {
  if (!job) return ""
  var state = String(job.state || "")
  if (state === "queued") return "Waiting"
  if (state === "running") return "Making"
  if (state === "succeeded") return "Done"
  if (state === "failed") return "Failed"
  if (state === "cancelled") return "Cancelled"
  if (state === "expired") return "Expired"
  if (state === "interrupted") return "Interrupted"
  return state
}

function jobDone(job) {
  var s = job ? String(job.state || "") : ""
  return s === "succeeded" || s === "failed" || s === "cancelled" || s === "expired"
}

function parseState(text) {
  try {
    var v = JSON.parse(String(text || ""))
    return v && typeof v === "object" ? v : {}
  } catch (e) {
    return {}
  }
}
