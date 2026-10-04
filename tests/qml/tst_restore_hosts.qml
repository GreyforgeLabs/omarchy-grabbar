import QtQuick
import QtTest
import "../../lifecycle" as Lifecycle

TestCase {
  name: "RestoreHosts"
  when: windowShown

  Component { id: widget; Lifecycle.RestoreHost {} }
  Component {
    id: service
    QtObject { readonly property bool restoreHost: Lifecycle.Hosts.count > 0 }
  }

  function cleanup() {
    tryCompare(Lifecycle.Hosts, "count", 0)
  }

  function test_unmounted_configuration_is_not_a_host() {
    var observer = createTemporaryObject(service, this)
    compare(observer.restoreHost, false)
    compare(Lifecycle.Hosts.count, 0)
  }

  function test_mount_unmount_without_service_lookup() {
    var observer = createTemporaryObject(service, this)
    // No service facade is supplied: replacement bars must work too.
    var host = widget.createObject(this)
    compare(Lifecycle.Hosts.count, 1)
    compare(observer.restoreHost, true)
    host.destroy()
    tryCompare(observer, "restoreHost", false)
  }

  function test_service_starts_after_widget() {
    var host = widget.createObject(this)
    var observer = createTemporaryObject(service, this)
    compare(observer.restoreHost, true)
    host.destroy()
    tryCompare(observer, "restoreHost", false)
  }

  function test_service_replacement_observes_existing_widget() {
    var host = widget.createObject(this)
    var old = service.createObject(this)
    compare(old.restoreHost, true)
    old.destroy()
    wait(0)
    var replacement = createTemporaryObject(service, this)
    compare(replacement.restoreHost, true)
    host.destroy()
    tryCompare(replacement, "restoreHost", false)
  }

  function test_multiple_widgets_and_idempotence() {
    var first = widget.createObject(this)
    var second = widget.createObject(this)
    first.sync()
    first.sync()
    compare(Lifecycle.Hosts.count, 2)
    first.destroy()
    tryCompare(Lifecycle.Hosts, "count", 1)
    second.destroy()
    tryCompare(Lifecycle.Hosts, "count", 0)
  }

  function test_hidden_widget_does_not_register() {
    var host = widget.createObject(this, { active: false })
    compare(Lifecycle.Hosts.count, 0)
    host.active = true
    compare(Lifecycle.Hosts.count, 1)
    host.active = false
    compare(Lifecycle.Hosts.count, 0)
    host.destroy()
    wait(0)
  }
}
