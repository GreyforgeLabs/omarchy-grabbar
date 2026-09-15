import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "GrabbarModel.js" as Model

// Grabbar shell service: the only writer of the recovery journal, the
// backend's shell client, and the restore model behind the bar widget and
// the drawer. It never resolves an action against the focused window; every
// action carries a backend token.
Item {
  id: root
  visible: false

  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) ? String(manifest.id) : Model.PLUGIN_ID
  // Omarchy strips __sourceDir from third-party manifests; fall back to the
  // directory this file was loaded from.
  readonly property string pluginDir: {
    if (manifest && manifest.__sourceDir) return String(manifest.__sourceDir)
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.slice(7)
    return url.replace(/\/+$/, "")
  }
  readonly property string journalBin: pluginDir + "/helpers/grabbar-journal"
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/grabbar"
  readonly property string session: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string socketPath: (runtimeDir && session) ? runtimeDir + "/grabbar/" + session + "/backend.sock" : ""

  // ------------------------------------------------------------- model
  property var model: Model.createState()
  property var live: ({})            // token -> latest backend snapshot
  property var rows: []              // drawer rows, newest first
  property int minimizedCount: 0
  property int failedCount: 0
  property int recoveredCount: 0
  property string notice: ""
  property string lastResult: ""
  signal windowMinimized(string token)
  signal windowRestored(string token)

  // ----------------------------------------------------------- backend
  property bool backendConnected: false
  property bool backendReady: false   // welcomed as the shell
  property bool busy: false           // another shell service holds the backend
  property string backendEpoch: ""
  property string backendVersion: ""
  property bool minimizeEnabled: false
  property bool suspended: true
  property bool paused: false         // Disable Grabbar was chosen
  property bool snapshotDone: false
  property var restoreHosts: ({})
  readonly property bool restoreHost: Object.keys(restoreHosts).length > 0

  // ----------------------------------------------------------- journal
  property string journalStatus: "loading"
  property var journalParsed: null
  property bool journalConsumed: false
  property bool journalDirty: false
  property string pendingJournalText: ""
  property var afterWrite: []
  property int requestSeq: 0

  readonly property string attentionReason: {
    if (busy) return "Another Grabbar shell service is connected"
    if (!backendConnected) return "Grabbar's native backend is not loaded"
    if (paused) return "Grabbar is turned off — open Settings to turn it on"
    if (!restoreHost) return "Grabbar needs its bar widget before windows can be minimized"
    if (failedCount > 0) return failedCount + " window" + (failedCount === 1 ? "" : "s") + " could not be restored — open the drawer"
    if (recoveredCount > 0) return "Recovered windows are waiting in the drawer"
    return ""
  }
  readonly property bool attention: attentionReason !== ""

  // ------------------------------------------------------------ publish

  function publish() {
    var labelled = Model.rowsWithOrdinals(root.model.entries)
    var out = []
    for (var i = 0; i < labelled.length; i++) {
      var e = labelled[i]
      out.push(Object.assign({}, e, { origin: Model.originLabel(e), where: e.origin || {} }))
    }
    root.rows = out
    var s = Model.statusSummary(root.model)
    root.minimizedCount = s.minimized
    root.failedCount = s.failed
    root.recoveredCount = s.recovered
  }

  function commit(state) {
    root.model = state
    root.publish()
    root.persist()
  }

  function say(text) {
    root.notice = String(text || "")
    if (root.notice) noticeTimer.restart()
  }

  function nextRequestId() {
    root.requestSeq += 1
    return "s" + root.requestSeq
  }

  // ------------------------------------------------------------ journal

  function persist() {
    if (!root.session) return
    root.pendingJournalText = JSON.stringify(Model.toJournal(root.model, root.session, root.backendEpoch))
    root.journalDirty = true
    persistDebounce.restart()
  }

  // Run `cb(ok)` once the journal holding the current model is on disk.
  function persistThen(cb) {
    root.afterWrite = root.afterWrite.concat([cb])
    root.persist()
    persistDebounce.stop()
    root.flushJournal()
  }

  function flushJournal() {
    if (!root.journalDirty || journalWriter.running) return
    if (quarantineProcess.running) { persistDebounce.restart(); return }
    root.journalDirty = false
    journalWriter.payload = root.pendingJournalText
    journalWriter.command = ["python3", root.journalBin, "write", "--state-dir", root.stateDir]
    journalWriter.running = true
  }

  function onJournalWritten(text) {
    var ok = false
    try { ok = JSON.parse(String(text || "{}")).status === "ok" } catch (e) {}
    var cbs = root.afterWrite
    root.afterWrite = []
    for (var i = 0; i < cbs.length; i++) { try { cbs[i](ok) } catch (e) { console.warn("grabbar: afterWrite", e) } }
    if (ok) root.journalStatus = "ok"
    else root.say("Grabbar could not save its recovery information")
    if (root.journalDirty) persistDebounce.restart()
  }

  function readJournal() {
    if (journalReader.running) return
    journalReader.command = ["python3", root.journalBin, "read", "--state-dir", root.stateDir]
    journalReader.running = true
  }

  function onJournalRead(text) {
    var envelope = null
    try { envelope = JSON.parse(String(text || "").slice(0, Model.JOURNAL_MAX_BYTES + 4096)) } catch (e) {}
    var status = envelope && envelope.status ? String(envelope.status) : "error"
    if (status === "ok") {
      var parsed = Model.parseJournal(envelope.text, root.session)
      root.journalParsed = parsed
      root.journalStatus = parsed.status
      if (parsed.status === "invalid" || parsed.status === "stale") root.quarantineJournal(parsed.reason || parsed.status)
    } else if (status === "empty") {
      root.journalStatus = "empty"
      root.journalParsed = { status: "empty", entries: [], epoch: "" }
    } else {
      root.journalStatus = status
      root.journalParsed = { status: status, entries: [], epoch: "" }
      root.quarantineJournal(status)
    }
    root.maybeReconcile()
  }

  function quarantineJournal(reason) {
    console.warn("grabbar: quarantining recovery journal:", reason)
    quarantineProcess.command = ["python3", root.journalBin, "quarantine", "--state-dir", root.stateDir,
                                 "--reason", String(reason || "damaged").replace(/[^A-Za-z0-9_-]/g, "")]
    quarantineProcess.running = true
  }

  // --------------------------------------------------------- reconcile

  function maybeReconcile() {
    if (!root.snapshotDone || root.journalStatus === "loading" || root.journalConsumed) return
    var parsed = root.journalParsed || { status: "empty", entries: [], epoch: "" }
    var entries = parsed.status === "ok" ? parsed.entries : []
    var result = Model.reconcile(root.model, entries, root.live, root.backendEpoch, parsed.epoch)
    root.journalConsumed = true
    root.commit(result.state)
    var r = result.report
    if (r.recovered.length) root.say("Recovered " + r.recovered.length + " hidden window" + (r.recovered.length === 1 ? "" : "s"))
    else if (r.reconstructed.length || r.completed.length)
      root.say("Restored " + (r.reconstructed.length + r.completed.length) + " minimized window" + ((r.reconstructed.length + r.completed.length) === 1 ? "" : "s") + " to the drawer")
    console.log("grabbar: reconcile", JSON.stringify(r))
    root.sendReady()
  }

  // ------------------------------------------------------------ socket

  function send(type, fields) {
    if (!root.sock || !root.sock.connected) return false
    root.sock.write(Model.buildLine(type, fields || {}))
    root.sock.flush()
    return true
  }

  function sendReady() {
    if (!root.backendReady || !root.journalConsumed) return
    root.send("ready", { restoreAccess: root.restoreHost ? "1" : "0" })
    root.pushTheme()
    root.pushSettings()
    if (root.settings.enabled === false) root.send("pause", { requestId: root.nextRequestId() })
  }

  function registerRestoreHost(name) {
    var next = Object.assign({}, root.restoreHosts)
    next[String(name || "host")] = (next[String(name || "host")] || 0) + 1
    root.restoreHosts = next
    root.sendReady()
  }

  function unregisterRestoreHost(name) {
    var key = String(name || "host")
    var next = Object.assign({}, root.restoreHosts)
    if (next[key] > 1) next[key] -= 1
    else delete next[key]
    root.restoreHosts = next
    root.sendReady()
  }

  function onConnected() {
    root.backendConnected = true
    root.busy = false
    root.snapshotDone = false
    root.journalConsumed = false
    root.live = {}
    root.send("hello", { protocol: Model.PROTOCOL, client: "shell", sessionId: root.session })
  }

  function onDisconnected() {
    root.backendConnected = false
    root.backendReady = false
    root.snapshotDone = false
    root.journalConsumed = false
    root.minimizeEnabled = false
    root.suspended = true
    root.live = {}
  }

  function onLine(data) {
    var msg = Model.parseLine(data)
    switch (msg.type) {
      case "welcome":
        root.backendEpoch = String(msg.backendEpoch || "")
        root.backendVersion = String(msg.grabbarVersion || "")
        if (msg.role === "shell") root.backendReady = true
        else { root.busy = true; root.say("Another Grabbar shell service is connected") }
        break
      case "error":
        if (msg.reason === "busy") root.busy = true
        else console.warn("grabbar: backend error", JSON.stringify(msg))
        break
      case "window":
        root.onWindow(msg)
        break
      case "snapshotEnd":
        root.snapshotDone = true
        root.maybeReconcile()
        break
      case "state":
        root.minimizeEnabled = msg.minimizeEnabled === "1"
        root.suspended = msg.suspended === "1"
        root.paused = msg.paused === "1"
        break
      case "minimizeRequest":
        root.onMinimizeRequest(msg)
        break
      case "result":
        root.onResult(msg)
        break
      case "notice":
        root.say(msg.text)
        break
      case "menuRequest":
        root.onMenuRequest(msg)
        break
      case "event":
        if (msg.kind === "backendStopping") root.say("Grabbar's native backend is stopping" + (Number(msg.restored) > 0 ? "; your windows were restored" : ""))
        break
      case "pong":
        break
      default:
        break
    }
  }

  function onWindow(msg) {
    var win = Model.windowFromMessage(msg)
    if (!win) return
    var kind = String(msg.kind || "")
    var next = Object.assign({}, root.live)
    if (!win.alive || kind === "closed" || kind === "destroyedWhileMinimized") delete next[win.token]
    else next[win.token] = win
    root.live = next

    var idx = Model.findEntry(root.model, win.token)
    if (idx === -1) return
    var entry = root.model.entries[idx]

    if (kind === "destroyedWhileMinimized" || kind === "closed" || !win.alive) {
      root.commit(Model.removeDead(root.model, win.token))
      if (kind === "destroyedWhileMinimized") root.say((entry.class || "A window") + " exited while minimized")
      return
    }
    if (kind === "released") {
      root.commit(Model.removeDead(root.model, win.token))
      return
    }
    if (kind === "title") {
      root.model = Model.updateTitle(root.model, win.token, win.title)
      root.publish()
      return
    }
    if (entry.status === "restoring" && !win.hidden) {
      var done = Model.finishRestore(root.model, win.token, true)
      root.commit(done.state)
      if (done.ok) root.windowRestored(win.token)
      return
    }
    // Journal entry but window visible: clear the stale state without moving it.
    if (entry.status === "minimized" && !win.hidden && !win.owned && root.snapshotDone) {
      root.commit(Model.removeDead(root.model, win.token))
    }
  }

  function onMinimizeRequest(msg) {
    var win = Model.windowFromMessage(msg)
    var requestId = String(msg.requestId || "")
    if (!win || !Model.isRequestId(requestId)) return
    if (!root.restoreHost) { root.say("Minimize is unavailable until Grabbar's bar widget is in place"); return }
    var r = Model.prepareEntry(root.model, win, requestId, Date.now())
    if (!r.ok) { console.warn("grabbar: prepare refused", r.reason); return }
    root.model = r.state
    root.publish()
    var token = win.token
    root.persistThen(function(ok) {
      if (!ok) {
        root.commit(Model.cancelEntry(root.model, token).state)
        return
      }
      root.send("action", { requestId: requestId, windowToken: token, action: "minimizeCommit" })
    })
  }

  function onResult(msg) {
    var token = String(msg.windowToken || "")
    var action = String(msg.action || "")
    var status = String(msg.status || "")
    var requestId = String(msg.requestId || "")
    root.lastResult = action + ":" + status
    if (action === "minimizeCommit") {
      if (status === "ok") {
        var c = Model.commitEntry(root.model, token, requestId)
        if (c.ok) { root.commit(c.state); root.windowMinimized(token) }
      } else {
        root.commit(Model.cancelEntry(root.model, token).state)
        if (msg.error) root.say(msg.error)
      }
      return
    }
    if (action === "restore") {
      if (status === "ok") {
        if (msg.hidden === "0") {
          var fin = Model.finishRestore(root.model, token, true)
          root.commit(fin.state)
          if (fin.ok) root.windowRestored(token)
        }
        if (msg.error) root.say("Restored to the current workspace: " + msg.error)
      } else if (status === "stale") {
        root.commit(Model.removeDead(root.model, token))
        root.say("That window is gone")
      } else if (status === "refused" && root.live[token] && !root.live[token].hidden) {
        root.commit(Model.removeDead(root.model, token))
      } else {
        root.commit(Model.finishRestore(root.model, token, false).state)
        root.say(msg.error || "Grabbar could not restore the window")
      }
      return
    }
    if (action === "restoreAll" && status === "ok") return
    if (status !== "ok" && msg.error) root.say(msg.error)
  }

  // ----------------------------------------------------------- actions

  function currentMonitorName() {
    try {
      var m = Hyprland.focusedMonitor
      if (m && m.name) return String(m.name)
    } catch (e) {}
    return ""
  }

  function restore(token, mode, monitor) {
    if (!Model.isToken(token)) return "invalid"
    var idx = Model.findEntry(root.model, token)
    if (idx === -1) return "unknown"
    var entry = root.model.entries[idx]
    if (entry.status === "prepared" || entry.status === "restoring") return "busy"
    var dest = Model.restoreDestination(entry, mode === "original" ? "original" : "current", monitor || root.currentMonitorName())
    var requestId = root.nextRequestId()
    root.commit(Model.markRestoring(root.model, token, requestId).state)
    root.send("action", { requestId: requestId, windowToken: token, action: "restore", destination: dest.destination, monitor: dest.monitor, focus: "1" })
    if (dest.fallback) root.say("The original workspace is gone; restoring here")
    return "restoring"
  }

  function restoreAll() {
    var mon = root.currentMonitorName()
    var list = root.model.entries.slice()
    var n = 0
    // Oldest first so the newest ends up focused last.
    for (var i = list.length - 1; i >= 0; i--) {
      if (list[i].status === "minimized" || list[i].status === "failed") { root.restore(list[i].token, "current", mon); n++ }
    }
    return n
  }

  function minimizeToken(token) {
    if (!Model.isToken(token)) return "invalid"
    if (!root.minimizeEnabled) return "disabled"
    root.send("action", { requestId: root.nextRequestId(), windowToken: token, action: "minimizePrepare" })
    return "requested"
  }

  function openDrawer() { root.openOverlay({ view: "drawer" }) }

  function statusJson() {
    return JSON.stringify({
      schema: 1,
      plugin: root.pluginId,
      backend: { connected: root.backendConnected, ready: root.backendReady, busy: root.busy, epoch: root.backendEpoch, version: root.backendVersion, socket: root.socketPath },
      minimizeEnabled: root.minimizeEnabled,
      suspended: root.suspended,
      paused: root.paused,
      enabled: root.settings.enabled !== false,
      settings: { buttonsLeft: root.settings.buttonsLeft, controlSize: root.settings.controlSize, excludedClasses: root.settings.excludedClasses },
      restoreHost: root.restoreHost,
      journal: root.journalStatus,
      minimized: root.minimizedCount,
      failed: root.failedCount,
      recovered: root.recoveredCount,
      entries: root.model.entries.map(function(e) { return { token: e.token, status: e.status, class: e.class, origin: e.origin.workspaceName || e.origin.workspace, recovered: !!e.recovered } })
    })
  }

  // ------------------------------------------------------------- theme

  // The bar widget (which can see qs.Commons) hands the Omarchy palette
  // over; the backend paints the strip with it instead of its config colors.
  property var theme: ({})

  function setTheme(values) {
    var next = {}
    var keys = ["barColor", "inactiveBarColor", "textColor", "hoverColor", "closeHoverColor", "textFont"]
    for (var i = 0; i < keys.length; i++) {
      var v = values ? values[keys[i]] : undefined
      if (v !== undefined && v !== null && String(v) !== "") next[keys[i]] = String(v)
    }
    if (JSON.stringify(next) === JSON.stringify(root.theme)) return
    root.theme = next
    root.pushTheme()
  }

  function pushTheme() {
    if (!root.backendReady) return
    if (Object.keys(root.theme).length === 0) return
    root.send("theme", root.theme)
  }

  // ---------------------------------------------------------- settings

  // Persisted in this plugin's own bar layout entry in ~/.config/omarchy/shell.json
  // (written by the bar widget through the host's updateEntryInline) and
  // mirrored under the state directory so a disable/enable cycle of the
  // widget, which drops the entry, does not lose the exclusion list.
  readonly property string settingsMirrorPath: stateDir + "/settings.json"
  property var fileSettings: null
  property var mirrorSettings: null
  property var settingsWriter: null   // function(patch) -> bool, registered by the bar widget
  readonly property var settings: Model.normalizeSettings(fileSettings || mirrorSettings || {})

  FileView {
    id: shellConfigFile
    path: root.home + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.fileSettings = Model.readOwnEntry(text(), root.pluginId)
    onLoadFailed: root.fileSettings = null
    onFileChanged: reload()
  }

  FileView {
    id: settingsMirror
    path: root.settingsMirrorPath
    atomicWrites: true
    printErrors: false
    onLoaded: { try { root.mirrorSettings = JSON.parse(text()) } catch (e) { root.mirrorSettings = null } }
    onLoadFailed: root.mirrorSettings = null
  }

  onSettingsChanged: root.pushSettings()

  function pushSettings() {
    if (!root.backendReady) return
    var s = root.settings
    root.send("settings", { buttonsLeft: s.buttonsLeft ? "1" : "0", controlSize: s.controlSize, excludedClasses: s.excludedClasses.join("|") })
  }

  function saveSettings(patch) {
    var next = Model.normalizeSettings(Object.assign({}, root.settings, patch || {}))
    var ok = false
    if (typeof root.settingsWriter === "function") {
      try { ok = root.settingsWriter(next) === true } catch (e) { console.warn("grabbar: settings writer", e) }
    }
    if (ok) root.fileSettings = next
    else root.mirrorSettings = next
    try { settingsMirror.setText(JSON.stringify(next)) } catch (e) {}
    return ok
  }

  function excludeClass(cls) {
    var c = Model.sanitizeClass(cls)
    if (!c) return false
    var list = root.settings.excludedClasses.slice()
    if (list.indexOf(c) === -1) list.push(c)
    return root.saveSettings({ excludedClasses: list })
  }

  function includeClass(cls) {
    var c = Model.sanitizeClass(cls)
    return root.saveSettings({ excludedClasses: root.settings.excludedClasses.filter(function(x) { return x !== c }) })
  }

  // Disable Grabbar: windows come back first, then the strip goes away and
  // Minimize stays refused until it is turned on again (spec §10.4).
  function disable() {
    root.saveSettings({ enabled: false })
    if (!root.backendReady) return "offline"
    root.send("pause", { requestId: root.nextRequestId() })
    return "paused"
  }

  function enable() {
    root.saveSettings({ enabled: true })
    if (!root.backendReady) return "offline"
    root.send("resume", { requestId: root.nextRequestId() })
    return "resumed"
  }

  // -------------------------------------------------------- window menu

  property var menuWindow: null       // the window the open menu targets
  property real menuX: 0
  property real menuY: 0

  function onMenuRequest(msg) {
    var win = Model.windowFromMessage(msg)
    if (!win) return
    root.menuWindow = win
    root.menuX = Number(msg.x) || 0
    root.menuY = Number(msg.y) || 0
    root.openOverlay({ view: "menu", token: win.token, x: root.menuX, y: root.menuY })
  }

  function liveWindow(token) {
    return root.live[token] || null
  }

  function toggleMaximize(token) {
    if (!Model.isToken(token)) return "invalid"
    root.send("action", { requestId: root.nextRequestId(), windowToken: token, action: "toggleMaximize" })
    return "requested"
  }

  function setFloating(token, on) {
    if (!Model.isToken(token)) return "invalid"
    root.send("action", { requestId: root.nextRequestId(), windowToken: token, action: "setFloating", value: on ? "1" : "0" })
    return "requested"
  }

  function closeWindow(token) {
    if (!Model.isToken(token)) return "invalid"
    root.send("action", { requestId: root.nextRequestId(), windowToken: token, action: "close" })
    return "requested"
  }

  function openOverlay(payload) {
    try {
      if (root.shell && typeof root.shell.summon === "function")
        root.shell.summon(root.pluginId, JSON.stringify(payload || {}))
    } catch (e) {}
  }

  function openSettings() { root.openOverlay({ view: "settings" }) }

  // --------------------------------------------------------- lifecycle

  Component.onCompleted: {
    root.readJournal()
    root.connectBackend()
  }

  // A Quickshell Socket that failed to connect (or lost its peer) does not
  // retry when `connected` is re-assigned, so every attempt uses a fresh
  // Socket object. Signals from a superseded socket are ignored.
  property var sock: null

  function connectBackend() {
    if (!root.socketPath) return
    if (root.sock) {
      var old = root.sock
      root.sock = null
      old.connected = false
      old.destroy()
    }
    root.sock = socketComponent.createObject(root)
    root.sock.connected = true
  }

  Component {
    id: socketComponent
    Socket {
      id: s
      path: root.socketPath
      connected: false
      parser: SplitParser {
        splitMarker: "\n"
        onRead: function(data) { if (s === root.sock) root.onLine(data) }
      }
      onConnectedChanged: {
        if (s !== root.sock) return
        if (connected) root.onConnected()
        else root.onDisconnected()
      }
      onError: function(err) { if (s === root.sock) root.backendConnected = false }
    }
  }

  // Retry every 2 s while not connected: the native plugin may be loaded after
  // the shell, unloaded for an update, or reloaded at any time.
  Timer {
    id: reconnectTimer
    interval: 2000
    repeat: true
    running: root.socketPath !== "" && !root.backendConnected
    onTriggered: root.connectBackend()
  }

  Timer { id: noticeTimer; interval: 6000; repeat: false; onTriggered: root.notice = "" }

  Timer { id: persistDebounce; interval: 150; repeat: false; onTriggered: root.flushJournal() }

  Process {
    id: journalReader
    running: false
    stdout: StdioCollector { id: journalReaderOut; waitForEnd: true }
    onExited: function() { root.onJournalRead(journalReaderOut.text) }
  }

  Process {
    id: journalWriter
    property string payload: ""
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: journalWriterOut; waitForEnd: true }
    onStarted: {
      journalWriter.write(payload)
      journalWriter.stdinEnabled = false
    }
    onExited: function() {
      journalWriter.stdinEnabled = true
      root.onJournalWritten(journalWriterOut.text)
    }
  }

  Process {
    id: quarantineProcess
    running: false
    onExited: function() { if (root.journalDirty) persistDebounce.restart() }
  }

  IpcHandler {
    target: "tech.greyforge.grabbar"

    function status(): string { return root.statusJson() }
    function restore(token: string, mode: string): string { return root.restore(token, mode, "") }
    function restoreAll(): string { return String(root.restoreAll()) }
    function minimize(token: string): string { return root.minimizeToken(token) }
    function openDrawer(): string { root.openDrawer(); return "ok" }
    function openSettings(): string { root.openSettings(); return "ok" }
    function reconcile(): string {
      root.journalConsumed = false
      root.snapshotDone = false
      root.journalStatus = "loading"
      root.readJournal()
      root.send("snapshot", {})
      return "requested"
    }
    function disable(): string { return root.disable() }
    function enable(): string { return root.enable() }
    function ping(): string { return root.backendConnected ? "connected" : "disconnected" }
  }
}
