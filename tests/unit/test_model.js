#!/usr/bin/env node
"use strict"

// Pure-model tests: codec, validation, journal, reconciliation table (spec
// §7.4), destination capture, geometry clamping, row labelling. Node only.

const assert = require("assert")
const path = require("path")
const M = require(path.join(__dirname, "..", "..", "GrabbarModel.js"))

let passed = 0
function test(name, fn) {
  try { fn(); passed++ } catch (e) { console.error("FAIL:", name); throw e }
}

function win(extra) {
  return Object.assign({
    token: "g100-1", address: "0xabc", stableId: "42", pid: 1234, class: "foot", title: "gfarch@greyarch:~",
    workspace: "2", workspaceName: "2", monitor: "DP-2", floating: false, pinned: false, maximized: false,
    fullscreen: false, hidden: false, owned: false, alive: true, modal: false, box: { x: 10, y: 40, w: 800, h: 600 }, origin: null, request: ""
  }, extra || {})
}

// ---------------------------------------------------------------- codec

test("codec round-trips control characters, percent, tabs and unicode", () => {
  const nasty = "a\tb\nc%deé ✕ ≡  z"
  assert.strictEqual(M.decodeField(M.encodeField(nasty)), nasty)
  assert.ok(M.encodeField(nasty).indexOf("\t") === -1)
  assert.ok(M.encodeField(nasty).indexOf("\n") === -1)
})

test("buildLine/parseLine agree with the native format", () => {
  const line = M.buildLine("action", { requestId: "r1", windowToken: "g1-2", action: "restore", title: "x\ty=z" })
  assert.strictEqual(line, "action\trequestId=r1\twindowToken=g1-2\taction=restore\ttitle=x%09y=z\n")
  const msg = M.parseLine(line)
  assert.deepStrictEqual(msg, { type: "action", requestId: "r1", windowToken: "g1-2", action: "restore", title: "x\ty=z" })
})

test("parseLine tolerates empty fields and missing '='", () => {
  assert.deepStrictEqual(M.parseLine("pong\t\tflag\tepoch=7\n"), { type: "pong", flag: "", epoch: "7" })
  assert.deepStrictEqual(M.parseLine(""), { type: "" })
})

// ----------------------------------------------------------- validation

test("token validation", () => {
  assert.ok(M.isToken("g1789446761-1"))
  assert.ok(!M.isToken("g1-"))
  assert.ok(!M.isToken("0x55d35b34c540"))
  assert.ok(!M.isToken('g1-1" }); os.execute("id'))
  assert.ok(!M.isToken(null))
})

test("workspace and label sanitizing", () => {
  assert.strictEqual(M.normalizeWorkspace("special:grabbar-minimized"), "special:grabbar-minimized")
  assert.strictEqual(M.normalizeWorkspace('2" }) os.exit()'), "")
  assert.strictEqual(M.sanitizeLabel("a\u0000b​\tc  d"), "abc d")
  assert.strictEqual(M.sanitizeLabel("x".repeat(200), 10).length, 10)
  assert.strictEqual(M.sanitizeClass("org.gnome.Nautilus; rm -rf"), "org.gnome.Nautilusrm-rf")
})

test("windowFromMessage rejects bad tokens and bounds geometry", () => {
  assert.strictEqual(M.windowFromMessage({ token: "nope" }), null)
  const w = M.windowFromMessage({ token: "g1-1", x: "-999999", w: "99999999", floating: "1", owned: "1", originWorkspaceName: "3", title: "T" })
  assert.strictEqual(w.box.x, -65536)
  assert.strictEqual(w.box.w, 65536)
  assert.strictEqual(w.floating, true)
  assert.strictEqual(w.origin.workspaceName, "3")
  assert.strictEqual(w.title, "T")
})

// ---------------------------------------------------------- transactions

test("prepare -> commit -> restore lifecycle", () => {
  let s = M.createState()
  let r = M.prepareEntry(s, win(), "n1-1", 1000)
  assert.ok(r.ok)
  assert.strictEqual(r.state.entries[0].status, "prepared")
  assert.ok(!M.prepareEntry(r.state, win(), "n1-2").ok, "duplicate prepare refused")
  assert.ok(!M.commitEntry(r.state, "g100-1", "n1-9").ok, "commit with another request refused")
  r = M.commitEntry(r.state, "g100-1", "n1-1")
  assert.ok(r.ok)
  assert.strictEqual(r.state.entries[0].status, "minimized")
  r = M.markRestoring(r.state, "g100-1", "c1")
  assert.strictEqual(r.state.entries[0].status, "restoring")
  const failed = M.finishRestore(r.state, "g100-1", false)
  assert.strictEqual(failed.state.entries[0].status, "failed", "failed restore stays actionable")
  const done = M.finishRestore(r.state, "g100-1", true)
  assert.strictEqual(done.state.entries.length, 0)
  assert.strictEqual(s.entries.length, 0, "original state untouched")
})

test("cancelling a prepared entry removes it", () => {
  const r = M.prepareEntry(M.createState(), win(), "n1-1", 1)
  assert.strictEqual(M.cancelEntry(r.state, "g100-1").state.entries.length, 0)
})

// -------------------------------------------------------------- journal

test("journal excludes titles and round-trips entries", () => {
  let s = M.prepareEntry(M.createState(), win({ title: "Secret document" }), "n1-1", 5).state
  s = M.commitEntry(s, "g100-1", "n1-1").state
  const j = M.toJournal(s, "sess", "777")
  const text = JSON.stringify(j)
  assert.ok(text.indexOf("Secret") === -1)
  const p = M.parseJournal(text, "sess")
  assert.strictEqual(p.status, "ok")
  assert.strictEqual(p.epoch, "777")
  assert.strictEqual(p.entries[0].token, "g100-1")
  assert.strictEqual(p.entries[0].origin.workspaceName, "2")
  assert.strictEqual(p.entries[0].title, "")
})

test("journal parse: empty, corrupt, oversized, wrong schema, foreign session", () => {
  assert.strictEqual(M.parseJournal("", "s").status, "empty")
  assert.strictEqual(M.parseJournal("{nope", "s").status, "invalid")
  assert.strictEqual(M.parseJournal("x".repeat(M.JOURNAL_MAX_BYTES + 1), "s").status, "invalid")
  assert.strictEqual(M.parseJournal(JSON.stringify({ schema: 99, session: "s", entries: [] }), "s").status, "invalid")
  assert.strictEqual(M.parseJournal(JSON.stringify({ schema: 1, session: "other", entries: [] }), "s").status, "stale")
})

test("journal parse drops malformed entries and bounds the count", () => {
  const entries = []
  for (let i = 0; i < M.JOURNAL_MAX_ENTRIES + 10; i++) entries.push({ token: "g1-" + i, status: "minimized", origin: {} })
  entries.push({ token: "bad token", status: "minimized" })
  entries.push({ token: "g1-9999", status: "restoring" })
  const p = M.parseJournal(JSON.stringify({ schema: 1, session: "s", entries }), "s")
  assert.strictEqual(p.entries.length, M.JOURNAL_MAX_ENTRIES)
  assert.ok(p.entries.every(e => M.isToken(e.token)))
})

// ------------------------------------------------------- reconciliation

function jentry(token, status, extra) {
  return Object.assign({ token, status, request: "n1-1", address: "0xabc", stableId: "42", pid: 1, class: "foot", title: "",
    origin: { workspace: "2", workspaceName: "2", monitor: "DP-2", floating: false, pinned: false, maximized: false, box: null }, sequence: 3, at: 1 }, extra || {})
}

test("§7.4: matching hidden window + valid journal -> reconstructed", () => {
  const live = { "g100-1": win({ hidden: true, owned: true, title: "Live title" }) }
  const r = M.reconcile(M.createState(), [jentry("g100-1", "minimized")], live, "100", "100")
  assert.deepStrictEqual(r.report.reconstructed, ["g100-1"])
  assert.strictEqual(r.state.entries[0].title, "Live title")
})

test("§7.4: prepared + hidden -> completed; prepared + visible -> cancelled", () => {
  const hidden = M.reconcile(M.createState(), [jentry("g100-1", "prepared")], { "g100-1": win({ hidden: true }) }, "100", "100")
  assert.deepStrictEqual(hidden.report.completed, ["g100-1"])
  const visible = M.reconcile(M.createState(), [jentry("g100-1", "prepared")], { "g100-1": win() }, "100", "100")
  assert.deepStrictEqual(visible.report.cancelled, ["g100-1"])
  assert.strictEqual(visible.state.entries.length, 0)
})

test("§7.4: entry but window visible -> cleared without moving; entry but window gone -> removed", () => {
  const cleared = M.reconcile(M.createState(), [jentry("g100-1", "minimized")], { "g100-1": win() }, "100", "100")
  assert.deepStrictEqual(cleared.report.cleared, ["g100-1"])
  const removed = M.reconcile(M.createState(), [jentry("g100-1", "minimized")], {}, "100", "100")
  assert.deepStrictEqual(removed.report.removed, ["g100-1"])
})

test("§7.4: unrecorded hidden window -> Recovered row", () => {
  const r = M.reconcile(M.createState(), [], { "g100-7": win({ token: "g100-7", hidden: true }) }, "100", "100")
  assert.deepStrictEqual(r.report.recovered, ["g100-7"])
  assert.strictEqual(r.state.entries[0].recovered, true)
  assert.ok(M.originLabel(r.state.entries[0]).indexOf("Recovered") !== -1)
})

test("§7.4: different epoch never replays tokens; matches only hidden windows by evidence", () => {
  const live = {
    "g200-1": win({ token: "g200-1", hidden: true, address: "0xabc", stableId: "42" }),
    "g200-2": win({ token: "g200-2", hidden: false, address: "0xdef", stableId: "43" })
  }
  const r = M.reconcile(M.createState(), [jentry("g100-1", "minimized"), jentry("g100-2", "minimized", { address: "0xdef", stableId: "43" })], live, "200", "100")
  assert.strictEqual(r.state.entries.length, 1)
  assert.strictEqual(r.state.entries[0].token, "g200-1", "adopted under the live token, origin kept from the journal")
  assert.strictEqual(r.state.entries[0].origin.workspaceName, "2")
  assert.deepStrictEqual(r.report.removed, ["g100-2"], "a visible window is never acted on from an old journal")
})

test("reconcile never claims one live window for two entries", () => {
  const live = { "g100-1": win({ hidden: true }) }
  const r = M.reconcile(M.createState(), [jentry("g100-1", "minimized"), jentry("g100-1", "minimized")], live, "100", "100")
  assert.strictEqual(r.state.entries.length, 1)
})

// ----------------------------------------------------------- destination

test("restore destination is captured per action and falls back when origin is unknown", () => {
  const e = { origin: { workspaceName: "3", workspace: "3" } }
  assert.deepStrictEqual(M.restoreDestination(e, "current", "DP-2"), { destination: "current", monitor: "DP-2", fallback: false })
  assert.deepStrictEqual(M.restoreDestination(e, "original", "DP-2"), { destination: "original", monitor: "DP-2", fallback: false })
  assert.deepStrictEqual(M.restoreDestination({ origin: {} }, "original", "DP 2;"), { destination: "current", monitor: "DP2", fallback: true })
})

// -------------------------------------------------------------- geometry

test("clampBox keeps the strip reachable inside the work area", () => {
  const area = { x: 0, y: 35, w: 1920, h: 1045 }
  assert.deepStrictEqual(M.clampBox({ x: -100, y: -100, w: 800, h: 600 }, area, 34), { x: 0, y: 69, w: 800, h: 600 })
  assert.deepStrictEqual(M.clampBox({ x: 1800, y: 1000, w: 800, h: 600 }, area, 34), { x: 1120, y: 480, w: 800, h: 600 })
  const big = M.clampBox({ x: 0, y: 0, w: 4000, h: 3000 }, area, 34)
  assert.strictEqual(big.w, 1920)
  assert.strictEqual(big.h, 1045)
  assert.strictEqual(big.y, 69)
})

// ------------------------------------------------------------------ rows

test("duplicate titles get display-only ordinals; labels are sanitized", () => {
  const rows = M.rowsWithOrdinals([
    { token: "g1-1", class: "chromium", title: "Inbox" },
    { token: "g1-2", class: "chromium", title: "Inbox" },
    { token: "g1-3", class: "foot", title: "" }
  ])
  assert.strictEqual(rows[0].label, "Inbox (1)")
  assert.strictEqual(rows[1].label, "Inbox (2)")
  assert.strictEqual(rows[2].label, "foot")
})

test("originLabel and statusSummary", () => {
  assert.strictEqual(M.originLabel({ origin: { workspaceName: "2", monitor: "DP-2" } }, { "DP-2": "Left display" }), "Workspace 2 · Left display")
  assert.strictEqual(M.originLabel({ origin: { workspaceName: "special:grabbar-minimized" } }), "")
  const s = { entries: [{ status: "minimized" }, { status: "prepared" }, { status: "failed", recovered: true }] }
  assert.deepStrictEqual(M.statusSummary(s), { minimized: 1, prepared: 1, failed: 1, recovered: 1, total: 3 })
})

// ------------------------------------------------------------- settings

test("normalizeSettings validates and bounds; readOwnEntry finds the plugin entry", () => {
  const s = M.normalizeSettings({ enabled: false, buttonsLeft: true, controlSize: "huge", excludedClasses: ["chromium", "bad class; rm", "chromium", 42] })
  assert.deepStrictEqual(s, { enabled: false, buttonsLeft: true, controlSize: "standard", excludedClasses: ["chromium", "badclassrm", "42"] })
  assert.deepStrictEqual(M.normalizeSettings(null), { enabled: true, buttonsLeft: false, controlSize: "standard", excludedClasses: [] })
  const doc = JSON.stringify({ bar: { layout: { left: [{ id: "x" }], right: [{ id: "tech.greyforge.grabbar", controlSize: "large", excludedClasses: ["foot"] }] } } })
  assert.deepStrictEqual(M.readOwnEntry(doc, "tech.greyforge.grabbar"), { controlSize: "large", excludedClasses: ["foot"] })
  assert.strictEqual(M.readOwnEntry(doc, "nope"), null)
  assert.strictEqual(M.readOwnEntry("{bad", "x"), null)
})

test("hasBarEntry finds the widget in any bar section, as an object or a bare id", () => {
  const id = "tech.greyforge.grabbar"
  assert.strictEqual(M.hasBarEntry(JSON.stringify({ bar: { layout: { right: [{ id: "x" }, { id }] } } }), id), true)
  assert.strictEqual(M.hasBarEntry(JSON.stringify({ bar: { layout: { center: ["x", id] } } }), id), true)
  assert.strictEqual(M.hasBarEntry(JSON.stringify({ bar: { layout: { left: [{ id: "x" }], right: [] } } }), id), false)
  assert.strictEqual(M.hasBarEntry(JSON.stringify({ bar: { id: "some.bar" } }), id), false)
  assert.strictEqual(M.hasBarEntry(JSON.stringify({ bar: { layout: { right: [null, 42, {}] } } }), id), false)
  assert.strictEqual(M.hasBarEntry("{bad", id), false)
})

test("updateTitle refreshes a row in place without reordering", () => {
  let s = M.prepareEntry(M.createState(), win({ token: "g100-1", title: "A" }), "n1-1", 1).state
  s = M.prepareEntry(s, win({ token: "g100-2", title: "B" }), "n1-2", 2).state
  const next = M.updateTitle(s, "g100-1", "A\u0000 renamed")
  assert.strictEqual(next.entries[1].title, "A renamed")
  assert.strictEqual(next.entries[0].token, "g100-2")
})

console.log("test_model: " + passed + " passed")
