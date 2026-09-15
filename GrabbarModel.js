// Grabbar — pure state, protocol codec, journal and reconciliation logic.
// QML imports this; Node tests require() it. No I/O, no Hyprland.
//
// Everything that arrives from the backend socket, the journal file or the
// CLI is treated as untrusted input: tokens, workspace names, labels and
// geometry are validated before they influence an action.

var PLUGIN_ID = "tech.greyforge.grabbar"
var PROTOCOL = 1
var JOURNAL_SCHEMA = 1
var JOURNAL_MAX_BYTES = 262144
var JOURNAL_MAX_ENTRIES = 256
var OWNED_WORKSPACE = "special:grabbar-minimized"
var LABEL_MAX = 96
var CLASS_MAX = 128
var TOKEN_RE = /^g[0-9]{1,20}-[0-9]{1,12}$/
var REQUEST_RE = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/
var WORKSPACE_RE = /^[A-Za-z0-9_.:+ -]{1,64}$/
var SESSION_RE = /^[A-Za-z0-9_]{1,128}$/
// Control characters, zero-width and bidi-override marks are stripped from labels.
var CONTROL_RE = new RegExp("[\\u0000-\\u001f\\u007f-\\u009f\\u200b-\\u200f\\u2028-\\u202e\\u2066-\\u2069]", "g")

// --------------------------------------------------------------- codec

function encodeField(value) {
  var s = String(value === undefined || value === null ? "" : value)
  var out = ""
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i)
    if (c < 0x20 || c === 0x7f || c === 0x25 /* % */ || c === 0x09 || c === 0x0a) {
      out += "%" + (c < 16 ? "0" : "") + c.toString(16).toUpperCase()
    } else {
      out += s[i]
    }
  }
  return out
}

function decodeField(value) {
  var s = String(value || "")
  return s.replace(/%([0-9A-Fa-f]{2})/g, function (_, hex) {
    return String.fromCharCode(parseInt(hex, 16))
  })
}

function buildLine(type, fields) {
  var parts = [String(type)]
  fields = fields || {}
  for (var k in fields) {
    if (fields[k] === undefined || fields[k] === null) continue
    parts.push(k + "=" + encodeField(fields[k]))
  }
  return parts.join("\t") + "\n"
}

function parseLine(line) {
  var text = String(line || "").replace(/\r?\n$/, "")
  var parts = text.split("\t")
  var msg = { type: parts[0] || "" }
  for (var i = 1; i < parts.length; i++) {
    if (!parts[i]) continue
    var eq = parts[i].indexOf("=")
    if (eq < 0) msg[parts[i]] = ""
    else msg[parts[i].slice(0, eq)] = decodeField(parts[i].slice(eq + 1))
  }
  return msg
}

// ---------------------------------------------------------- validation

function isToken(value) {
  return TOKEN_RE.test(String(value || ""))
}

function isRequestId(value) {
  return REQUEST_RE.test(String(value || ""))
}

function normalizeWorkspace(value) {
  var s = String(value || "")
  return WORKSPACE_RE.test(s) ? s : ""
}

function isSpecialWorkspace(name) {
  return String(name || "").indexOf("special:") === 0
}

function sanitizeLabel(value, maxLen) {
  var s = String(value === undefined || value === null ? "" : value)
  s = s.replace(CONTROL_RE, "")
  s = s.replace(/\s+/g, " ").trim()
  var max = maxLen || LABEL_MAX
  if (s.length > max) s = s.slice(0, max - 1) + "…"
  return s
}

function sanitizeClass(value) {
  var s = String(value || "").replace(/[^A-Za-z0-9._-]/g, "")
  return s.slice(0, CLASS_MAX)
}

function clampInt(value, lo, hi, fallback) {
  var n = Math.floor(Number(value))
  if (!isFinite(n)) return fallback
  if (n < lo) return lo
  if (n > hi) return hi
  return n
}

function flag(value) {
  return value === true || value === 1 || value === "1" || value === "true"
}

// ------------------------------------------------------------- windows

// A window snapshot as the backend reports it (one `window` message).
function windowFromMessage(msg) {
  msg = msg || {}
  if (!isToken(msg.token)) return null
  return {
    token: String(msg.token),
    address: String(msg.address || ""),
    stableId: String(msg.stableId || ""),
    pid: clampInt(msg.pid, 0, 4194304, 0),
    class: sanitizeClass(msg["class"]),
    title: sanitizeLabel(msg.title, 256),
    workspace: normalizeWorkspace(msg.workspace),
    workspaceName: normalizeWorkspace(msg.workspaceName),
    monitor: sanitizeClass(msg.monitor),
    floating: flag(msg.floating),
    pinned: flag(msg.pinned),
    maximized: flag(msg.maximized),
    fullscreen: flag(msg.fullscreen),
    hidden: flag(msg.hidden),
    owned: flag(msg.owned),
    alive: msg.alive === undefined ? true : flag(msg.alive),
    modal: flag(msg.modal),
    box: {
      x: clampInt(msg.x, -65536, 65536, 0),
      y: clampInt(msg.y, -65536, 65536, 0),
      w: clampInt(msg.w, 0, 65536, 0),
      h: clampInt(msg.h, 0, 65536, 0)
    },
    origin: msg.owned && flag(msg.owned) ? {
      workspace: normalizeWorkspace(msg.originWorkspace),
      workspaceName: normalizeWorkspace(msg.originWorkspaceName),
      monitor: sanitizeClass(msg.originMonitor),
      floating: flag(msg.originFloating),
      pinned: flag(msg.originPinned),
      maximized: flag(msg.originMaximized)
    } : null,
    request: String(msg.request || "")
  }
}

// --------------------------------------------------------------- state

function createState() {
  return {
    entries: [],      // minimized rows, newest first
    windows: {},      // token -> latest snapshot
    sequence: 0,
    backend: { epoch: "", sessionId: "", connected: false, minimizeEnabled: false, suspended: true },
    restoreHost: false
  }
}

function cloneState(state) {
  var next = createState()
  next.entries = (state.entries || []).map(function (e) { return Object.assign({}, e, { origin: Object.assign({}, e.origin || {}) }) })
  next.windows = Object.assign({}, state.windows || {})
  next.sequence = state.sequence || 0
  next.backend = Object.assign({}, state.backend || {})
  next.restoreHost = !!state.restoreHost
  return next
}

function findEntry(state, token) {
  var list = state.entries || []
  for (var i = 0; i < list.length; i++) if (list[i].token === token) return i
  return -1
}

function nextSequence(state) {
  state.sequence = (state.sequence || 0) + 1
  return state.sequence
}

// Transaction step 2: the shell records a `prepared` entry before the backend
// moves anything.
function prepareEntry(state, win, requestId, now) {
  if (!win || !isToken(win.token) || !isRequestId(requestId)) return { state: state, ok: false, reason: "invalid" }
  if (findEntry(state, win.token) !== -1) return { state: state, ok: false, reason: "duplicate" }
  var next = cloneState(state)
  next.entries.unshift({
    token: win.token,
    status: "prepared",
    request: String(requestId),
    address: win.address,
    stableId: win.stableId,
    pid: win.pid,
    class: win.class,
    title: win.title,
    origin: {
      workspace: win.workspace,
      workspaceName: win.workspaceName,
      monitor: win.monitor,
      floating: !!win.floating,
      pinned: !!win.pinned,
      maximized: !!win.maximized,
      box: Object.assign({}, win.box || {})
    },
    sequence: nextSequence(next),
    at: Number(now) || 0
  })
  return { state: next, ok: true }
}

function commitEntry(state, token, requestId) {
  var i = findEntry(state, token)
  if (i === -1) return { state: state, ok: false, reason: "missing" }
  var entry = state.entries[i]
  if (entry.status !== "prepared" || entry.request !== String(requestId)) return { state: state, ok: false, reason: "mismatch" }
  var next = cloneState(state)
  next.entries[i].status = "minimized"
  return { state: next, ok: true }
}

function cancelEntry(state, token) {
  var i = findEntry(state, token)
  if (i === -1) return { state: state, ok: false }
  var next = cloneState(state)
  next.entries.splice(i, 1)
  return { state: next, ok: true }
}

function markRestoring(state, token, requestId) {
  var i = findEntry(state, token)
  if (i === -1) return { state: state, ok: false }
  var next = cloneState(state)
  next.entries[i].status = "restoring"
  next.entries[i].restoreRequest = String(requestId || "")
  return { state: next, ok: true }
}

// Only after the compositor confirmed the window left the owned workspace.
function finishRestore(state, token, ok) {
  var i = findEntry(state, token)
  if (i === -1) return { state: state, ok: false }
  var next = cloneState(state)
  if (ok) next.entries.splice(i, 1)
  else {
    next.entries[i].status = "failed"
    next.entries[i].restoreRequest = ""
  }
  return { state: next, ok: true }
}

// Live titles stay in memory only; refresh a row without reordering.
function updateTitle(state, token, title) {
  var i = findEntry(state, token)
  if (i === -1) return state
  var next = cloneState(state)
  next.entries[i].title = sanitizeLabel(title, 256)
  return next
}

function removeDead(state, token) {
  return cancelEntry(state, token).state
}

// ------------------------------------------------------------- journal

function toJournal(state, session, epoch) {
  var entries = []
  var list = state.entries || []
  for (var i = 0; i < list.length && entries.length < JOURNAL_MAX_ENTRIES; i++) {
    var e = list[i]
    if (e.status !== "prepared" && e.status !== "minimized" && e.status !== "restoring" && e.status !== "failed") continue
    entries.push({
      token: e.token,
      status: e.status === "restoring" ? "minimized" : e.status,
      request: e.request,
      address: e.address,
      stableId: e.stableId,
      pid: e.pid,
      class: e.class,
      // no title: titles are never persisted
      origin: {
        workspace: e.origin.workspace,
        workspaceName: e.origin.workspaceName,
        monitor: e.origin.monitor,
        floating: !!e.origin.floating,
        pinned: !!e.origin.pinned,
        maximized: !!e.origin.maximized,
        box: e.origin.box || null
      },
      sequence: e.sequence,
      at: e.at
    })
  }
  return { schema: JOURNAL_SCHEMA, session: String(session || ""), epoch: String(epoch || ""), sequence: state.sequence || 0, entries: entries }
}

function parseJournal(raw, session) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  if (!text.trim()) return { status: "empty", entries: [], sequence: 0, epoch: "" }
  if (text.length > JOURNAL_MAX_BYTES) return { status: "invalid", reason: "oversized", entries: [], sequence: 0, epoch: "" }
  var data
  try { data = JSON.parse(text) } catch (e) { return { status: "invalid", reason: "json", entries: [], sequence: 0, epoch: "" } }
  if (!data || typeof data !== "object" || data.schema !== JOURNAL_SCHEMA) return { status: "invalid", reason: "schema", entries: [], sequence: 0, epoch: "" }
  if (!Array.isArray(data.entries)) return { status: "invalid", reason: "entries", entries: [], sequence: 0, epoch: "" }
  if (String(data.session || "") !== String(session || "")) return { status: "stale", reason: "session", entries: [], sequence: 0, epoch: String(data.epoch || "") }
  var entries = []
  for (var i = 0; i < data.entries.length && entries.length < JOURNAL_MAX_ENTRIES; i++) {
    var e = data.entries[i]
    if (!e || typeof e !== "object" || !isToken(e.token)) continue
    if (e.status !== "prepared" && e.status !== "minimized" && e.status !== "failed") continue
    var origin = e.origin && typeof e.origin === "object" ? e.origin : {}
    entries.push({
      token: String(e.token),
      status: e.status,
      request: isRequestId(e.request) ? String(e.request) : "",
      address: String(e.address || "").slice(0, 32),
      stableId: String(e.stableId || "").slice(0, 32),
      pid: clampInt(e.pid, 0, 4194304, 0),
      class: sanitizeClass(e.class),
      title: "",
      origin: {
        workspace: normalizeWorkspace(origin.workspace),
        workspaceName: normalizeWorkspace(origin.workspaceName),
        monitor: sanitizeClass(origin.monitor),
        floating: !!origin.floating,
        pinned: !!origin.pinned,
        maximized: !!origin.maximized,
        box: origin.box && typeof origin.box === "object" ? {
          x: clampInt(origin.box.x, -65536, 65536, 0), y: clampInt(origin.box.y, -65536, 65536, 0),
          w: clampInt(origin.box.w, 0, 65536, 0), h: clampInt(origin.box.h, 0, 65536, 0)
        } : null
      },
      sequence: clampInt(e.sequence, 0, 1e12, 0),
      at: clampInt(e.at, 0, 1e15, 0)
    })
  }
  return { status: "ok", entries: entries, sequence: clampInt(data.sequence, 0, 1e12, 0), epoch: String(data.epoch || "") }
}

// -------------------------------------------------------- reconciliation

// Compare journal entries with the live snapshot from the backend (spec §7.4).
// `live` is a map token -> window snapshot from the current backend epoch.
// Journal entries from an older epoch cannot be matched by token; their
// windows are recovered only through verified membership of the owned
// workspace (address + stableId evidence assists, never overrides).
function reconcile(state, journalEntries, live, backendEpoch, journalEpoch) {
  var next = cloneState(state)
  next.entries = []
  var report = { reconstructed: [], completed: [], cancelled: [], cleared: [], removed: [], recovered: [], quarantined: false }
  var sameEpoch = String(journalEpoch || "") === String(backendEpoch || "")
  var claimed = {}

  var list = journalEntries || []
  for (var i = 0; i < list.length; i++) {
    var e = list[i]
    var win = null
    if (sameEpoch) win = live[e.token] || null
    else {
      // Different epoch: tokens are dead. Match only a window that is on the
      // owned workspace AND carries the same address + stableId evidence.
      for (var t in live) {
        var w = live[t]
        if (w.hidden && w.address === e.address && w.stableId === e.stableId && !claimed[t]) { win = w; break }
      }
    }
    if (!win || !win.alive) { report.removed.push(e.token); continue }
    if (claimed[win.token]) continue
    if (win.hidden) {
      claimed[win.token] = true
      var row = Object.assign({}, e, { token: win.token, title: win.title, status: "minimized", sequence: e.sequence || nextSequence(next), at: e.at || 0 })
      if (win.origin && (!row.origin.workspaceName && win.origin.workspaceName)) row.origin = Object.assign({}, row.origin, win.origin)
      next.entries.push(row)
      if (e.status === "prepared") report.completed.push(win.token)
      else report.reconstructed.push(win.token)
    } else {
      if (e.status === "prepared") report.cancelled.push(e.token)
      else report.cleared.push(e.token)
    }
  }

  // Unrecorded live windows on Grabbar's workspace: expose as Recovered.
  for (var token in live) {
    var lw = live[token]
    if (!lw.alive || !lw.hidden || claimed[token]) continue
    claimed[token] = true
    next.entries.push({
      token: token,
      status: "minimized",
      recovered: true,
      request: lw.request || "",
      address: lw.address,
      stableId: lw.stableId,
      pid: lw.pid,
      class: lw.class,
      title: lw.title,
      origin: lw.origin ? Object.assign({ box: null }, lw.origin) : { workspace: "", workspaceName: "", monitor: "", floating: false, pinned: false, maximized: false, box: null },
      sequence: nextSequence(next),
      at: 0
    })
    report.recovered.push(token)
  }

  next.entries.sort(function (a, b) { return (b.sequence || 0) - (a.sequence || 0) })
  return { state: next, report: report }
}

// ----------------------------------------------------------- destination

// The drawer captures its destination when the action starts (spec §5.2).
function restoreDestination(entry, mode, drawerMonitor) {
  var m = sanitizeClass(drawerMonitor)
  if (mode === "original") {
    if (entry && entry.origin && (entry.origin.workspaceName || entry.origin.workspace)) return { destination: "original", monitor: m, fallback: false }
    return { destination: "current", monitor: m, fallback: true }
  }
  return { destination: "current", monitor: m, fallback: false }
}

// Keep a floating box inside the work area with its strip reachable.
function clampBox(box, area, stripHeight) {
  var strip = clampInt(stripHeight, 0, 200, 34)
  var b = { x: Number(box.x) || 0, y: Number(box.y) || 0, w: Number(box.w) || 0, h: Number(box.h) || 0 }
  var a = { x: Number(area.x) || 0, y: Number(area.y) || 0, w: Number(area.w) || 0, h: Number(area.h) || 0 }
  if (a.w <= 0 || a.h <= 0 || b.w <= 0 || b.h <= 0) return b
  if (b.w > a.w) b.w = a.w
  if (b.h > a.h) b.h = a.h
  if (b.x < a.x) b.x = a.x
  if (b.x + b.w > a.x + a.w) b.x = a.x + a.w - b.w
  if (b.y < a.y + strip) b.y = a.y + strip
  if (b.y + b.h > a.y + a.h) b.y = Math.max(a.y + strip, a.y + a.h - b.h)
  return b
}

// ---------------------------------------------------------------- rows

function originLabel(entry, monitorLabels) {
  var parts = []
  var o = entry && entry.origin ? entry.origin : {}
  var ws = o.workspaceName || o.workspace
  if (ws && !isSpecialWorkspace(ws)) parts.push(/^[0-9]+$/.test(ws) ? "Workspace " + ws : sanitizeLabel(ws, 32))
  var mon = o.monitor
  if (mon) parts.push((monitorLabels && monitorLabels[mon]) || mon)
  if (entry && entry.recovered) parts.push("Recovered")
  return parts.join(" · ")
}

// Duplicate titles get a display-only ordinal.
function rowsWithOrdinals(entries) {
  var seen = {}
  var counts = {}
  var list = entries || []
  for (var i = 0; i < list.length; i++) {
    var key = (list[i].class || "") + " " + (list[i].title || "")
    counts[key] = (counts[key] || 0) + 1
  }
  return list.map(function (e) {
    var key = (e.class || "") + " " + (e.title || "")
    seen[key] = (seen[key] || 0) + 1
    var label = e.title || e.class || "Window"
    if (counts[key] > 1) label += " (" + seen[key] + ")"
    return Object.assign({}, e, { label: sanitizeLabel(label, LABEL_MAX) })
  })
}

// ------------------------------------------------------------ settings

// Settings live in the plugin's own bar layout entry (spec §9). Everything is
// validated: unknown keys are dropped, classes are sanitized and bounded.
function normalizeSettings(raw) {
  var r = raw && typeof raw === "object" ? raw : {}
  var classes = []
  var src = Array.isArray(r.excludedClasses) ? r.excludedClasses : []
  for (var i = 0; i < src.length && classes.length < 64; i++) {
    var c = sanitizeClass(src[i])
    if (c && classes.indexOf(c) === -1) classes.push(c)
  }
  return {
    enabled: r.enabled === false ? false : true,
    buttonsLeft: r.buttonsLeft === true || r.buttonsLeft === "left" || r.controlsOn === "left",
    controlSize: r.controlSize === "large" ? "large" : "standard",
    excludedClasses: classes
  }
}

// Find this plugin's entry in a shell.json document and return its settings
// (everything but `id`), or null when the entry is absent.
function readOwnEntry(raw, pluginId) {
  var parsed
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { return null }
  if (!parsed || typeof parsed !== "object") return null
  var layout = parsed.bar && parsed.bar.layout ? parsed.bar.layout : null
  if (!layout) return null
  var sections = ["left", "center", "right"]
  for (var s = 0; s < sections.length; s++) {
    var list = Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      if (entry && typeof entry === "object" && String(entry.id || "") === String(pluginId)) {
        var copy = {}
        for (var k in entry) if (k !== "id") copy[k] = entry[k]
        return copy
      }
    }
  }
  return null
}

function statusSummary(state) {
  var minimized = 0, prepared = 0, failed = 0, recovered = 0
  var list = state.entries || []
  for (var i = 0; i < list.length; i++) {
    if (list[i].status === "prepared") prepared++
    else if (list[i].status === "failed") failed++
    else minimized++
    if (list[i].recovered) recovered++
  }
  return { minimized: minimized, prepared: prepared, failed: failed, recovered: recovered, total: list.length }
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    PLUGIN_ID: PLUGIN_ID, PROTOCOL: PROTOCOL, JOURNAL_SCHEMA: JOURNAL_SCHEMA, JOURNAL_MAX_BYTES: JOURNAL_MAX_BYTES,
    JOURNAL_MAX_ENTRIES: JOURNAL_MAX_ENTRIES, OWNED_WORKSPACE: OWNED_WORKSPACE,
    encodeField: encodeField, decodeField: decodeField, buildLine: buildLine, parseLine: parseLine,
    isToken: isToken, isRequestId: isRequestId, normalizeWorkspace: normalizeWorkspace, isSpecialWorkspace: isSpecialWorkspace,
    sanitizeLabel: sanitizeLabel, sanitizeClass: sanitizeClass, clampInt: clampInt, flag: flag,
    windowFromMessage: windowFromMessage, createState: createState, cloneState: cloneState, findEntry: findEntry,
    prepareEntry: prepareEntry, commitEntry: commitEntry, cancelEntry: cancelEntry, markRestoring: markRestoring,
    finishRestore: finishRestore, updateTitle: updateTitle, removeDead: removeDead,
    toJournal: toJournal, parseJournal: parseJournal, reconcile: reconcile,
    restoreDestination: restoreDestination, clampBox: clampBox, originLabel: originLabel, rowsWithOrdinals: rowsWithOrdinals,
    statusSummary: statusSummary, normalizeSettings: normalizeSettings, readOwnEntry: readOwnEntry
  }
}
