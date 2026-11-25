import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"
import vm from "node:vm"

const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*/, "")
const context = {}
vm.createContext(context)
vm.runInContext(source, context)
const Model = context

test("mood follows reach, playout and what is being made", () => {
  assert.equal(Model.mood("offline", null, 0), "sleepy")
  assert.equal(Model.mood("ok", null, 0), "sleepy")
  assert.equal(Model.mood("ok", { running: true, current: { kind: "music" } }, 2), "excited")
  assert.equal(Model.mood("ok", { running: false, current: null }, 0), "happy")
  assert.equal(Model.mood("ok", { running: true, current: null }, 0), "hungry")
  assert.equal(Model.mood("ok", { running: true, current: { kind: "speech" } }, 0), "onair")
  assert.equal(Model.mood("ok", { running: true, current: { kind: "ad" } }, 0), "onair")
  assert.equal(Model.mood("ok", { running: true, current: { kind: "music" } }, 0), "singing")
})

test("stateLine names each way the studio can be out of reach", () => {
  assert.equal(Model.stateLine("missing", false, null, false), "myradio is not installed")
  assert.equal(Model.stateLine("missing", true, null, false), "Start myradio once to finish setup")
  assert.equal(Model.stateLine("foreign", true, null, false), "Another account holds the studio port")
  assert.equal(Model.stateLine("unverified", true, null, false), "Can't verify the studio. Update myradio")
  assert.equal(Model.stateLine("badport", true, null, false), "Studio port must be from 1 to 65535")
  assert.equal(Model.stateLine("offline", true, null, false), "Studio is closed")
  assert.equal(Model.stateLine("ok", true, { running: false, health: {} }, false), "Off air")
  assert.equal(Model.stateLine("ok", true, { running: true, current: null, health: { state: "fault" } }, false), "Station fault")
  assert.equal(Model.stateLine("ok", true, { running: true, current: null, health: {} }, false), "Waiting for audio")
  assert.equal(Model.stateLine("ok", true, { running: true, current: { id: "a" }, listeners: 1 }, true), "Listening here")
  assert.equal(Model.stateLine("ok", true, { running: true, current: { id: "a" }, listeners: 1 }, false), "1 listener")
  assert.equal(Model.stateLine("ok", true, { running: true, current: { id: "a" }, listeners: 2 }, false), "2 listeners")
  assert.equal(Model.stateLine("ok", true, { running: true, current: { id: "a" }, listeners: 0 }, false), "Press play to listen")
})

test("clock and hours stay finite", () => {
  assert.equal(Model.clock(0), "0:00")
  assert.equal(Model.clock(61.9), "1:01")
  assert.equal(Model.clock(3600), "1:00:00")
  assert.equal(Model.clock(3661), "1:01:01")
  assert.equal(Model.clock(-4), "0:00")
  assert.equal(Model.clock(Number.POSITIVE_INFINITY), "0:00")
  assert.equal(Model.clock("nope"), "0:00")
  assert.equal(Model.hours(0), "0 s")
  assert.equal(Model.hours(45), "45 s")
  assert.equal(Model.hours(90), "2 min")
  assert.equal(Model.hours(3600), "1.0 h")
  assert.equal(Model.hours(10 * 3600), "10 h")
  assert.equal(Model.hours(-10), "0 s")
})

test("labels, titles and clamps", () => {
  assert.equal(Model.kindLabel("speech"), "DJ")
  assert.equal(Model.kindLabel("ad"), "Spot")
  assert.equal(Model.kindLabel("music"), "Song")
  assert.equal(Model.kindLabel(""), "")
  assert.equal(Model.mediaTitle(null), "myradio")
  assert.equal(
    Model.mediaTitle({ current: { title: "Rain", artist: "Dial" }, station: { name: "Night" } }),
    "Rain — Dial · Night"
  )
  assert.equal(Model.clampVolume(-3), 0)
  assert.equal(Model.clampVolume(80.4), 80)
  assert.equal(Model.clampVolume(200), 130)
  assert.equal(Model.clampSongSeconds(10), 30)
  assert.equal(Model.clampSongSeconds(150), 150)
  assert.equal(Model.clampSongSeconds(900), 580)
  assert.equal(Model.clampSongSeconds(Number.NaN), 150)
})

test("song requests are rejected before the studio sees a leading dash", () => {
  assert.equal(Model.requestIssue("song", "  hi "), "Describe the song in a few words.")
  assert.equal(Model.requestIssue("song", "-slow jazz"), "Describe the song without a leading dash.")
  assert.equal(Model.requestIssue("song", "slow jazz about rain"), "")
  assert.equal(Model.requestIssue("update", ""), "")
})

test("enqueue keeps the studio's size limits", () => {
  const song = Model.enqueueCall("song", "x".repeat(900), 12, "k")
  assert.equal(song.operation, "generation.enqueue")
  assert.equal(song.arguments.role, "song")
  assert.equal(song.arguments.payload.tags.length, 800)
  assert.equal(song.arguments.payload.duration_s, 30)
  assert.equal(song.arguments.idempotency_key, "k")
  const update = Model.enqueueCall("update", "y".repeat(1200), 150, "k2")
  assert.equal(update.arguments.payload.text.length, 1000)
  assert.equal(update.arguments.payload.tags, undefined)
})

test("news topics are clipped to the studio limit and keys do not collide in one millisecond", () => {
  assert.equal(Model.clipNewsTopic("  " + "a".repeat(250)), "a".repeat(200))
  const a = Model.requestKey(1_700_000_000_000, 1)
  const b = Model.requestKey(1_700_000_000_000, 2)
  assert.notEqual(a, b)
  assert.match(a, /^omarchy-[a-z0-9]+-[a-z0-9]+$/)
})

test("finished jobs include interrupted, and only those can be retried", () => {
  for (const state of ["succeeded", "failed", "cancelled", "expired", "interrupted"]) {
    assert.equal(Model.jobDone({ state }), true, state)
  }
  assert.equal(Model.jobDone({ state: "running" }), false)
  assert.equal(Model.jobDone({ state: "queued" }), false)
  assert.equal(Model.jobLabel({ state: "interrupted" }), "Interrupted")
  assert.equal(Model.jobLabel({ state: "running" }), "Making")
  assert.equal(Model.canRetry("cancelled"), true)
  assert.equal(Model.canRetry("interrupted"), true)
  assert.equal(Model.canRetry("running"), false)
})

test("broadcast encoding counts as live and a failed maker is not polled forever", () => {
  for (const state of ["streaming", "connecting", "retrying", "encoding"]) {
    assert.equal(Model.broadcastLive(state), true, state)
  }
  assert.equal(Model.broadcastLive("failed"), false)
  assert.equal(Model.broadcastLive("disconnected"), false)
  assert.equal(Model.needsPoll({ director: true, state: "looking" }), true)
  assert.equal(Model.needsPoll({ director: true, state: "queued" }), false)
  assert.equal(Model.needsPoll({ job_id: "j", state: "interrupted", queued: false }), false)
  assert.equal(Model.needsPoll({ job_id: "j", state: "running", queued: false }), true)
  assert.equal(Model.needsPoll({ job_id: "j", state: "succeeded", queued: false, queuing: false }), true)
  assert.equal(Model.needsPoll({ job_id: "j", state: "succeeded", queued: true }), false)
  assert.equal(Model.needsPoll({ job_id: "j", state: "succeeded", queuing: true, queued: false }), true)
})

test("a finished song is queued only after queue.add can be tried", () => {
  const ready = Model.followUpdate({ queued: false, queuing: false }, { state: "succeeded", track_id: "t1" })
  assert.equal(ready.queueTrack, "t1")
  assert.equal(ready.fields.queuing, true)
  assert.equal(ready.fields.queued, undefined)
  const again = Model.followUpdate({ queued: false, queuing: true }, { state: "succeeded", track_id: "t1" })
  assert.equal(again.queueTrack, "")
  const running = Model.followUpdate({ queued: false }, { state: "running", track_id: "" })
  assert.equal(running.queueTrack, "")
  assert.equal(running.fields.state, "running")
  assert.equal(Model.followUpdate({}, null), null)
})

test("parseState drops anything that is not a JSON object", () => {
  assert.equal(JSON.stringify(Model.parseState("")), "{}")
  assert.equal(JSON.stringify(Model.parseState("nope")), "{}")
  assert.equal(JSON.stringify(Model.parseState("null")), "{}")
  assert.equal(JSON.stringify(Model.parseState('"hi"')), "{}")
  assert.equal(JSON.stringify(Model.parseState('{"reach":"ok"}')), '{"reach":"ok"}')
})
