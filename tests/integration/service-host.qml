import QtQuick
import Quickshell

// Minimal standalone host for Service.qml: runs in a separate Quickshell
// process pointed at the nested compositor, so the shell service can be
// exercised against the native backend without loading anything into the
// operator's live omarchy-shell. The harness copies this file next to
// Service.qml, GrabbarModel.js and helpers/ (Quickshell refuses module
// paths outside its config folder). A bar widget is simulated by
// registering a restore host at startup.
ShellRoot {
  id: host

  Service {
    id: service
    shell: null
    manifest: ({ id: "tech.greyforge.grabbar" })
    Component.onCompleted: {
      var hosted = Quickshell.env("GRABBAR_TEST_HOSTED") !== "0"
      if (hosted) service.registerRestoreHost("test-widget")
      console.log("grabbar-test-host: service started, restoreHost=" + hosted)
    }
    onNoticeChanged: if (notice) console.log("grabbar-test-host notice: " + notice)
    onWindowMinimized: function(token) { console.log("grabbar-test-host minimized " + token) }
    onWindowRestored: function(token) { console.log("grabbar-test-host restored " + token) }
  }
}
