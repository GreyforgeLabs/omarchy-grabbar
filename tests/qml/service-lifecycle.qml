import QtQuick
import QtQuick.Window
import Quickshell
import "."

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
  QtObject {
    id: transport
    property bool connected: true
    function write(line) {
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

  Timer {
    interval: 100; running: true; repeat: false
    onTriggered: {
      if (service.session || service.socketPath) test.fail("test isolation missing")
      service.sock = transport
      service.backendReady = true
      service.journalConsumed = true
      test.runCycle(defaultBar, "with service lookup", function() {
        test.runCycle(null, "without service lookup", function() { Qt.quit() })
      })
    }
  }
}
