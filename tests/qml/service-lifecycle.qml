import QtQuick
import QtQuick.Window
import Quickshell
import "."
import "GrabbarModel.js" as Model

// Staged alongside the actual Service.qml in an isolated temporary home.
// The transport records actual service messages; no compositor is contacted.
ShellRoot {
  id: test
  property var readiness: []
  property var mountedWidget: null

  Service { id: service }
  Window { id: surface; visible: true; width: 100; height: 40 }
  Component { id: widget; BarWidget {} }
  QtObject {
    id: facade
    function serviceFor(id) { return service }
  }
  QtObject {
    id: defaultBar
    property QtObject shell: facade
    property string fontFamily: "sans"
  }
  property var sent: []
  QtObject {
    id: transport
    property bool connected: true
    function write(line) {
      test.sent = test.sent.concat([line])
      if (line.indexOf("ready\t") === 0) test.readiness = test.readiness.concat([line])
    }
    function flush() {}
  }

  function fail(message) {
    console.error("FAIL " + message)
    Qt.quit()
    throw new Error(message)
  }

  function expect(value) {
    if (service.restoreHost !== value || !readiness.length
        || readiness[readiness.length - 1].indexOf("restoreAccess=" + (value ? "1" : "0")) === -1)
      fail("incorrect readiness: " + JSON.stringify(readiness))
  }

  function runCycle(bar, label, done) {
    readiness = []
    service.sendReady()
    expect(false)
    mountedWidget = widget.createObject(surface.contentItem, { bar: bar })
    expect(true)
    // Repeated service publication must not create extra restore hosts.
    if (mountedWidget.bindService) {
      mountedWidget.bindService()
      mountedWidget.bindService()
    }
    mountedWidget.visible = false
    expect(false)
    mountedWidget.visible = true
    expect(true)
    mountedWidget.destroy()
    Qt.callLater(function() {
      test.expect(false)
      if (readiness.length !== 5) test.fail("duplicate readiness: " + JSON.stringify(readiness))
      console.log("PASS actual Service/BarWidget " + label + ": 0 -> 1 -> 0 -> 1 -> 0")
      done()
    })
  }

  function feed(type, fields) { service.onLine(Model.buildLine(type, fields).slice(0, -1)) }

  function hiddenWindow(token) {
    return { token: token, address: "0x10", stableId: "7", pid: "42", "class": "foot", title: "t",
             workspace: "-98", workspaceName: "special:grabbar-minimized", monitor: "DP-1", hidden: "1", owned: "1",
             alive: "1", originWorkspace: "3", originWorkspaceName: "3", originMonitor: "DP-1", kind: "snapshot" }
  }

  function connectAndSnapshot(epoch, windows) {
    service.onConnected()
    if (test.sent[test.sent.length - 1].indexOf("hello\t") !== 0) fail("no hello on connect")
    feed("welcome", { protocol: "1", backendEpoch: epoch, sessionId: "", grabbarVersion: "test", role: "shell" })
    for (var i = 0; i < windows.length; i++) feed("window", windows[i])
    feed("snapshotEnd", { count: String(windows.length) })
  }

  // A row minimized during this session survives a socket reconnect as an
  // ordinary minimized row (not "Recovered"), and a restore requested while
  // the backend is away keeps the row restorable instead of "restoring".
  function runReconnect() {
    service.journalConsumed = false
    connectAndSnapshot("100", [])
    if (service.model.entries.length !== 0) fail("unexpected rows after first reconcile")
    var win = Model.windowFromMessage(Object.assign(hiddenWindow("g100-5"), { hidden: "0", owned: "0", workspace: "3", workspaceName: "3" }))
    var prepared = Model.prepareEntry(service.model, win, "n100-1", 1)
    service.commit(Model.commitEntry(prepared.state, "g100-5", "n100-1").state)

    service.onDisconnected()
    var answer = service.restore("g100-5", "current", "")
    if (answer !== "offline" || service.model.entries[0].status !== "minimized") fail("offline restore left the row " + service.model.entries[0].status + " (" + answer + ")")
    if (service.restoreAll() !== 0 || service.model.entries[0].status !== "minimized") fail("offline restore-all changed the row")

    connectAndSnapshot("100", [hiddenWindow("g100-5")])
    var rows = service.model.entries
    if (rows.length !== 1 || rows[0].token !== "g100-5" || rows[0].recovered || rows[0].status !== "minimized"
        || rows[0].origin.workspaceName !== "3" || service.recoveredCount !== 0)
      fail("reconnect lost the session's minimize record: " + JSON.stringify(rows))
    console.log("PASS reconnect keeps session rows; offline restore keeps rows restorable")
  }

  Timer {
    interval: 100; running: true; repeat: false
    onTriggered: {
      if (service.session || service.socketPath) test.fail("test isolation missing")
      service.sock = transport
      service.backendReady = true
      service.journalConsumed = true
      test.runCycle(defaultBar, "with service lookup", function() {
        test.runCycle(null, "without service lookup", function() { test.runReconnect(); Qt.quit() })
      })
    }
  }
}
