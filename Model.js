.pragma library

// Pure helpers for the myradio plugin. No QML types, so they stay testable.

var LIVE_BROADCAST = ["streaming", "connecting", "retrying", "encoding"]

// Which Dial to show for the station's state.
function mood(reach, status, making) {
  if (reach !== "ok" || !status) return "sleepy"
  if (making > 0) return "excited"
  if (!status.running) return "happy"
  if (!status.current) return "hungry"
  var cur = status.current
  if (cur.kind === "speech" || cur.kind === "ad") return "onair"
  return "singing"
}

// What the station is doing, in one line.
function stateLine(reach, installed, status, listening) {
  if (reach === "missing") return installed ? "Start myradio once to finish setup" : "myradio is not installed"
  if (reach === "foreign") return "Another account holds the studio port"
  if (reach === "unverified") return "Can't verify the studio. Update myradio"
  if (reach === "badport") return "Studio port must be from 1 to 65535"
  if (reach !== "ok" || !status) return "Studio is closed"
  var health = status.health || {}
  if (health.state === "fault") return "Station fault"
  if (!status.running) return "Off air"
  if (!status.current) return "Waiting for audio"
  if (listening) return "Listening here"
  var n = Number(status.listeners) || 0
  return n > 0 ? n + (n === 1 ? " listener" : " listeners") : "Press play to listen"
}

function finite(seconds) {
  var n = Number(seconds)
  return isFinite(n) ? n : 0
}

function clock(seconds) {
  var n = finite(seconds)
  if (n < 0) n = 0
  var s = Math.floor(n)
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
  var n = finite(seconds)
  if (n < 0) n = 0
  if (n < 60) return Math.round(n) + " s"
  var h = n / 3600
  if (h < 1) return Math.round(h * 60) + " min"
  return (h < 10 ? h.toFixed(1) : String(Math.round(h))) + " h"
}

function clampVolume(v) {
  var n = Math.round(finite(v))
  if (n < 0) return 0
  if (n > 130) return 130
  return n
}

function clampSongSeconds(v) {
  var raw = Number(v)
  if (!isFinite(raw)) return 150
  var n = Math.round(raw)
  if (n < 30) return 30
  if (n > 580) return 580
  return n
}

// A broadcast that is on the way out or already streaming. `encoding` is past
// the start call: asking the studio to start again is an error.
function broadcastLive(state) {
  return LIVE_BROADCAST.indexOf(state) >= 0
}

function canRetry(state) {
  return state === "failed" || state === "expired" || state === "interrupted" || state === "cancelled"
}

// The media title the listener publishes over MPRIS.
function mediaTitle(status) {
  if (!status || !status.current) return "myradio"
  var cur = status.current
  var name = status.station && status.station.name ? status.station.name : "myradio"
  return (cur.title || "Untitled") + (cur.artist ? " — " + cur.artist : "") + " · " + name
}

function requestIssue(role, text) {
  text = String(text == null ? "" : text).trim()
  if (role === "song") {
    if (text.length < 3) return "Describe the song in a few words."
    if (text.charAt(0) === "-") return "Describe the song without a leading dash."
  }
  return ""
}

// The studio accepts a news topic of at most 200 characters.
function clipNewsTopic(text) {
  return String(text == null ? "" : text).trim().slice(0, 200)
}

function requestKey(nowMs, seq) {
  var n = Math.floor(finite(nowMs))
  var s = Math.floor(finite(seq))
  if (n < 0) n = 0
  if (s < 0) s = 0
  return "omarchy-" + n.toString(36) + "-" + s.toString(36)
}

// A request from the panel, as a generation.enqueue call. role "song" makes a
// song from a description; role "update" has the DJ read the text on air.
function enqueueCall(role, text, durationS, key) {
  var payload = role === "song"
    ? { tags: String(text == null ? "" : text).slice(0, 800), duration_s: clampSongSeconds(durationS) }
    : { text: String(text == null ? "" : text).slice(0, 1000) }
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
  return s === "succeeded" || s === "failed" || s === "cancelled" || s === "expired" || s === "interrupted"
}

// Keep polling while a generation job can still change, or while its finished
// audio has not been placed in the queue yet.
function needsPoll(r) {
  if (!r) return false
  if (r.director) return r.state === "looking" || r.state === "recording"
  if (r.queuing) return true
  if (!r.job_id || r.queued) return false
  if (jobDone(r) && r.state !== "succeeded") return false
  return true
}

// What to store after generation.job, and which track to place at the front of
// the queue. The track is queued only after queue.add succeeds.
function followUpdate(request, job) {
  if (!job || !job.state) return null
  var fields = { state: String(job.state), track_id: job.track_id || "", error: job.error || "" }
  var queueTrack = ""
  if (fields.state === "succeeded" && fields.track_id && request && !request.queued && !request.queuing) {
    fields.queuing = true
    queueTrack = fields.track_id
  }
  return { fields: fields, queueTrack: queueTrack }
}

function parseState(text) {
  try {
    var v = JSON.parse(String(text || ""))
    return v && typeof v === "object" ? v : {}
  } catch (e) {
    return {}
  }
}
