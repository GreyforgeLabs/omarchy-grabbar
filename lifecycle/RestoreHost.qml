import QtQml
import "." as Lifecycle

// One per actual widget instance; independent of the host's service facade.
QtObject {
  id: root
  property bool active: true
  property bool mounted: false

  function sync() {
    if (mounted && active) Lifecycle.Hosts.registerHost(root)
    else Lifecycle.Hosts.unregisterHost(root)
  }

  onActiveChanged: sync()
  Component.onCompleted: { mounted = true; sync() }
  Component.onDestruction: Lifecycle.Hosts.unregisterHost(root)
}
