pragma Singleton
import QtQml

// Shared only by Grabbar components loaded from this plugin directory.
// Presence comes from live widgets, never persisted layout configuration.
QtObject {
  property var hosts: []
  readonly property int count: hosts.length

  function registerHost(host) {
    if (!host || hosts.indexOf(host) !== -1) return
    hosts = hosts.concat([host])
  }

  function unregisterHost(host) {
    hosts = hosts.filter(function(item) { return item !== host })
  }
}
