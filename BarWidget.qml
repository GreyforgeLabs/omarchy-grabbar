import QtQuick
import Quickshell
import Quickshell.Widgets
import qs.Commons
import qs.Ui
import "GrabbarModel.js" as Model

// Grabbar bar widget: the stable place a minimized window can be found again.
//
//   glyph [count]   — always visible (spec §5.1), highlighted when attention is needed
//
// Stateless: everything comes from the live service. Its presence is what
// lets the service declare restore access to the native backend; without a
// mounted widget Minimize stays disabled. It also hands the service the two
// things only a bar widget can see: the Omarchy palette (for the strip) and
// the host's settings writer (for this plugin's shell.json entry).
BarWidget {
  id: root
  moduleName: "tech.greyforge.grabbar"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  readonly property int count: service ? Number(service.minimizedCount || 0) : 0
  readonly property bool attention: !!(service && service.attention)
  readonly property string attentionReason: service ? String(service.attentionReason || "") : ""
  readonly property string glyph: String.fromCodePoint(0xF05B2)   // nf-md-window_restore: a window stack
  property bool pulse: false

  visible: true
  implicitWidth: vertical ? barSize : layout.implicitWidth
  implicitHeight: vertical ? layout.implicitHeight : barSize

  function tooltip() {
    if (attention) return attentionReason
    if (!service) return "Grabbar — click for minimized windows"
    if (count === 0) return "No minimized windows\nright-click: Grabbar settings"
    return count + " minimized window" + (count === 1 ? "" : "s") + "\nclick: open · middle: restore all · right: settings"
  }

  function openDrawer() {
    if (service && service.openDrawer) { service.openDrawer(); return }
    if (bar) bar.run("omarchy-shell shell toggle " + moduleName + " '{\"view\":\"drawer\"}'")
  }

  function openSettings() {
    if (service && service.openSettings) { service.openSettings(); return }
    if (bar) bar.run("omarchy-shell shell toggle " + moduleName + " '{\"view\":\"settings\"}'")
  }

  // ------------------------------------------------------ service wiring

  // The service may be published after this widget mounts (plugin reloads,
  // shell start order), so register whenever it becomes available, not only
  // once at creation. Registration is idempotent on the service side.
  function declareRestoreHost() {
    if (!service) return
    if (service.registerRestoreHost) service.registerRestoreHost("bar-widget")
    if ("settingsWriter" in service) service.settingsWriter = root.writeSettings
    root.pushTheme()
  }
  Component.onCompleted: declareRestoreHost()
  onServiceChanged: declareRestoreHost()
  Component.onDestruction: {
    if (!service) return
    if (service.unregisterRestoreHost) service.unregisterRestoreHost("bar-widget")
    if ("settingsWriter" in service && service.settingsWriter === root.writeSettings) service.settingsWriter = null
  }

  // Settings are persisted through the host's own writer: the whole layout
  // entry is rewritten atomically and nothing else in shell.json changes.
  function writeSettings(next) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return false
    var entry = {}
    for (var k in next) entry[k] = next[k]
    return bar.shell.updateEntryInline(moduleName, entry) === true
  }

  // Omarchy palette → strip colors. Focused strip uses the bar surface; the
  // unfocused one steps toward the background so the active window reads.
  readonly property var themeValues: ({
    barColor: String(Color.bar.background),
    inactiveBarColor: String(Qt.tint(Color.bar.background, Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.45))),
    textColor: String(Color.bar.text),
    hoverColor: String(Qt.rgba(Color.bar.text.r, Color.bar.text.g, Color.bar.text.b, 0.18)),
    closeHoverColor: String(Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.85)),
    textFont: String((bar && bar.fontFamily) || Style.font.family || "")
  })
  onThemeValuesChanged: pushTheme()
  function pushTheme() { if (service && service.setTheme) service.setTheme(themeValues) }

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onWindowMinimized() { root.pulse = true; pulseTimer.restart() }
  }
  Timer { id: pulseTimer; interval: 1200; repeat: false; onTriggered: root.pulse = false }

  Flow {
    id: layout
    anchors.centerIn: parent
    flow: root.vertical ? Flow.TopToBottom : Flow.LeftToRight
    spacing: 0

    WidgetButton {
      bar: root.bar
      text: root.vertical || root.count === 0 ? root.glyph : (root.glyph + " " + root.count)
      fontSize: Style.font.caption
      keepSpace: true   // the restore entry point must never collapse to nothing
      active: root.attention || root.pulse
      tooltipText: root.tooltip()
      onPressed: function(button) {
        if (button === Qt.RightButton) { root.openSettings(); return }
        if (button === Qt.MiddleButton) { if (root.service && root.count > 0) root.service.restoreAll(); return }
        root.openDrawer()
      }
    }
  }
}
