import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "GrabbarModel.js" as Model

// Grabbar overlay. One overlay entry point hosts three views:
//
//   drawer   — the minimized windows drawer (spec §5.2): newest first, Restore
//              as the main action, Original workspace as the secondary one,
//              Restore all in the header. No close, delete or relaunch here.
//   menu     — the window menu (spec §3.4) for one window, opened from the
//              strip's menu button or a right-click on the strip.
//   settings — the short settings panel (spec §9) with Restore all, Check
//              setup and the Grabbar on/off switch.
//
// The host calls open(payloadJson) / close(); `opened` reports the state.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  property string view: "drawer"
  property int selectedIndex: 0
  property string monitorName: ""
  property var menuTarget: null       // live window snapshot the menu acts on
  property real menuX: 0
  property real menuY: 0
  property bool confirmHide: false
  property bool showTechnical: false

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property color accent: Color.accent
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int cardWidth: Math.min(Style.space(520), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(440), panel.height - Style.gapsOut * 2)
  readonly property int rowHeight: Math.max(Style.space(48), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  readonly property int menuRowHeight: Style.space(30)
  readonly property string pluginId: (manifest && manifest.id) || Model.PLUGIN_ID
  readonly property var rows: service && service.rows ? service.rows : []
  readonly property string notice: service ? String(service.notice || "") : ""
  readonly property var settings: service && service.settings ? service.settings : Model.normalizeSettings({})
  readonly property bool grabbarOn: service ? !service.paused && settings.enabled !== false : false

  // The live snapshot for the menu's window refreshes while the menu is open
  // (maximized / floating state may change under it); the token never does.
  readonly property var menuLive: menuTarget && service && service.liveWindow ? (service.liveWindow(menuTarget.token) || menuTarget) : menuTarget

  // ------------------------------------------------------------ screens

  function screenAt(x, y) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var s = screens[i]
      if (x >= s.x && x < s.x + s.width && y >= s.y && y < s.y + s.height) return s
    }
    return null
  }

  function screenNamed(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (String(screens[i].name) === String(name)) return screens[i]
    return screens.length ? screens[0] : null
  }

  // ------------------------------------------------------------ open/close

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(String(payloadJson || "{}")) || {} } catch (e) {}
    var wanted = String(payload.view || "drawer")
    if (wanted !== "menu" && wanted !== "settings") wanted = "drawer"
    root.confirmHide = false
    root.selectedIndex = 0
    // The destination is captured when the drawer opens, not when a row is
    // hovered or focus changes later (spec §5.2).
    root.monitorName = service && service.currentMonitorName ? service.currentMonitorName() : ""
    if (wanted === "menu") {
      var token = String(payload.token || "")
      var live = service && service.liveWindow ? service.liveWindow(token) : null
      if (!live && service && service.menuWindow && service.menuWindow.token === token) live = service.menuWindow
      if (!live) { wanted = "drawer" } else {
        root.menuTarget = live
        root.menuX = Number(payload.x) || 0
        root.menuY = Number(payload.y) || 0
        var s = root.screenAt(root.menuX, root.menuY)
        if (s) panel.screen = s
      }
    }
    if (wanted !== "menu") {
      var ms = root.screenNamed(root.monitorName)
      if (ms) panel.screen = ms
    }
    root.view = wanted
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false; root.menuTarget = null }

  function dismiss() {
    root.opened = false
    root.menuTarget = null
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() { if (root.opened) root.dismiss(); else root.open("{}") }

  function switchView(name) {
    root.confirmHide = false
    root.selectedIndex = 0
    root.view = name
    var ms = root.screenNamed(root.monitorName)
    if (ms && name !== "menu") panel.screen = ms
  }

  // ------------------------------------------------------------- actions

  function restoreRow(row, original) {
    if (!service || !row) return
    service.restore(row.token, original ? "original" : "current", root.monitorName)
    if (root.rows.length <= 1) root.dismiss()
  }

  function restoreAll() {
    if (!service) return
    service.restoreAll()
    root.dismiss()
  }

  function select(delta, count) {
    if (count === 0) return
    var next = root.selectedIndex + delta
    if (next < 0) next = 0
    if (next >= count) next = count - 1
    root.selectedIndex = next
  }

  // Window menu entries (spec §3.4). Window actions first, product entries
  // after the separator. Disabled items keep a short reason.
  readonly property var menuItems: {
    var w = root.menuLive
    if (!w) return []
    var minimizeOk = service && service.minimizeEnabled && !w.fullscreen && !w.modal
    var minimizeWhy = !service || !service.minimizeEnabled ? "Minimize is unavailable until the drawer is ready"
      : (w.fullscreen ? "Leave fullscreen first" : (w.modal ? "Dialogs are minimized with their window" : ""))
    return [
      { id: "minimize", label: "Minimize", enabled: !!minimizeOk, why: minimizeWhy },
      { id: "maximize", label: w.maximized ? "Restore size" : "Maximize", enabled: !w.fullscreen, why: w.fullscreen ? "Leave fullscreen first" : "" },
      { id: "float", label: "Move freely", enabled: true, checked: !!w.floating },
      { id: "close", label: "Close", enabled: true },
      { id: "sep" },
      { id: "drawer", label: "Minimized windows", enabled: true },
      { id: "hide", label: "Hide Grabbar for " + (w.class || "this app"), enabled: !!w.class, why: w.class ? "" : "This window has no application class" },
      { id: "settings", label: "Grabbar settings", enabled: true }
    ]
  }

  function runMenuItem(item) {
    if (!item || !item.enabled || !root.menuLive || !service) return
    var token = root.menuLive.token
    switch (item.id) {
      case "minimize": service.minimizeToken(token); root.dismiss(); break
      case "maximize": service.toggleMaximize(token); root.dismiss(); break
      case "float": service.setFloating(token, !root.menuLive.floating); root.dismiss(); break
      case "close": service.closeWindow(token); root.dismiss(); break
      case "drawer": root.switchView("drawer"); break
      case "hide": root.confirmHide = true; break
      case "settings": root.switchView("settings"); break
      default: break
    }
  }

  function confirmHideNow() {
    if (root.menuLive && service && service.excludeClass) service.excludeClass(root.menuLive.class)
    root.confirmHide = false
    root.dismiss()
  }

  function setGrabbarOn(on) {
    if (!service) return
    if (on) service.enable(); else service.disable()
  }

  // Setup facts for "Check setup": plain, actionable lines.
  readonly property var setupLines: {
    if (!service) return [{ ok: false, text: "The Grabbar service is not running" }]
    var out = []
    out.push({ ok: service.backendConnected, text: service.backendConnected ? "Native backend loaded (" + service.backendVersion + ")" : "Native backend is not loaded — see README: Enabling the native controls" })
    out.push({ ok: service.restoreHost, text: service.restoreHost ? "Bar widget in place; minimized windows can be found" : "Bar widget missing — Minimize stays off" })
    out.push({ ok: service.minimizeEnabled || service.paused, text: service.paused ? "Grabbar is turned off" : (service.minimizeEnabled ? "Minimize enabled" : "Minimize disabled") })
    out.push({ ok: service.journalStatus === "ok" || service.journalStatus === "empty", text: "Recovery journal: " + service.journalStatus })
    if (service.busy) out.push({ ok: false, text: "Another Grabbar shell service holds the backend" })
    return out
  }

  // ------------------------------------------------------------- window

  PanelWindow {
    id: panel
    visible: root.opened
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "grabbar-overlay"
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    anchors { top: true; bottom: true; left: true; right: true }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
      Rectangle { anchors.fill: parent; color: root.view === "menu" ? "transparent" : root.scrim }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (root.confirmHide) root.confirmHide = false
          else if (root.view !== "drawer" && root.view !== "menu" && root.rows.length > 0) root.switchView("drawer")
          else root.dismiss()
          event.accepted = true; return
        }
        var count = root.view === "menu" ? root.menuItems.length : (root.view === "drawer" ? root.rows.length : 0)
        if (event.key === Qt.Key_Down || event.key === Qt.Key_J) { root.select(1, count); event.accepted = true }
        else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) { root.select(-1, count); event.accepted = true }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (root.view === "menu") root.runMenuItem(root.menuItems[root.selectedIndex])
          else if (root.view === "drawer") root.restoreRow(root.rows[root.selectedIndex], event.modifiers & Qt.ShiftModifier)
          event.accepted = true
        }
        else if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier) && root.view === "drawer") { root.restoreAll(); event.accepted = true }
      }
    }

    // ------------------------------------------------------------ drawer

    Rectangle {
      id: card
      visible: root.view === "drawer"
      width: root.cardWidth
      height: Math.min(root.cardHeight, header.height + Math.max(1, root.rows.length) * root.rowHeight + root.contentMargin * 2 + Style.space(8) + (root.notice ? noticeRow.height + Style.space(4) : 0))
      anchors.horizontalCenter: parent.horizontalCenter
      y: Style.gapsOut + Style.space(8)
      radius: root.cornerRadius
      color: root.background
      border.color: root.border
      border.width: 1

      MouseArea { anchors.fill: parent; onClicked: function(m) { m.accepted = true } }

      Column {
        anchors.fill: parent
        anchors.margins: root.contentMargin
        spacing: Style.space(4)

        Item {
          id: header
          width: parent.width
          height: Style.space(32)
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.rows.length === 0 ? "No minimized windows" : (root.rows.length + " minimized window" + (root.rows.length === 1 ? "" : "s"))
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.weight: Font.Medium
          }
          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            PillButton { label: "Restore all"; visible: root.rows.length > 1; onActivated: root.restoreAll() }
            PillButton { label: "Settings"; onActivated: root.switchView("settings") }
          }
        }

        Text {
          id: noticeRow
          visible: root.notice !== ""
          width: parent.width
          text: root.notice
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        ListView {
          id: list
          width: parent.width
          height: parent.height - header.height - (root.notice ? noticeRow.height + Style.space(4) : 0) - Style.space(4)
          clip: true
          model: root.rows
          currentIndex: root.selectedIndex
          delegate: Rectangle {
            id: row
            required property var modelData
            required property int index
            width: list.width
            height: root.rowHeight
            radius: root.cornerRadius
            color: index === root.selectedIndex || rowArea.containsMouse ? root.selectedBackground : "transparent"

            MouseArea {
              id: rowArea
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onEntered: root.selectedIndex = row.index
              onClicked: function(m) { root.restoreRow(row.modelData, m.button === Qt.RightButton) }
            }

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)

              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - actions.width - Style.space(10)
                spacing: 2
                Text {
                  width: parent.width
                  text: row.modelData.label
                  elide: Text.ElideRight
                  color: row.index === root.selectedIndex ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  width: parent.width
                  text: (row.modelData.status === "failed" ? "Could not restore — try again · " : "") + (row.modelData.origin || "")
                  elide: Text.ElideRight
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                id: actions
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)
                PillButton {
                  label: row.modelData.status === "failed" ? "Retry" : "Restore"
                  onActivated: root.restoreRow(row.modelData, false)
                }
                PillButton {
                  label: "Original workspace"
                  visible: !!(row.modelData.where && (row.modelData.where.workspaceName || row.modelData.where.workspace))
                  onActivated: root.restoreRow(row.modelData, true)
                }
              }
            }
          }
        }
      }
    }

    // ------------------------------------------------------- window menu

    Rectangle {
      id: menuCard
      visible: root.view === "menu" && root.menuLive !== null
      width: Style.space(260)
      height: menuColumn.implicitHeight + Style.space(12)
      radius: root.cornerRadius
      color: root.background
      border.color: root.border
      border.width: 1
      // Anchor at the pointer, kept inside the screen.
      x: Math.max(Style.gapsOut, Math.min(root.menuX - (panel.screen ? panel.screen.x : 0), panel.width - width - Style.gapsOut))
      y: Math.max(Style.gapsOut, Math.min(root.menuY - (panel.screen ? panel.screen.y : 0), panel.height - height - Style.gapsOut))

      MouseArea { anchors.fill: parent; onClicked: function(m) { m.accepted = true } }

      Column {
        id: menuColumn
        anchors.fill: parent
        anchors.margins: Style.space(6)
        spacing: 0

        Text {
          width: parent.width
          height: root.menuRowHeight
          verticalAlignment: Text.AlignVCenter
          leftPadding: Style.space(10)
          text: root.menuLive ? (root.menuLive.title || root.menuLive.class || "Window") : ""
          elide: Text.ElideRight
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.confirmHide ? [] : root.menuItems
          delegate: Item {
            required property var modelData
            required property int index
            width: menuColumn.width
            height: modelData.id === "sep" ? Style.space(9) : root.menuRowHeight
            Rectangle {
              visible: modelData.id === "sep"
              anchors.centerIn: parent
              width: parent.width - Style.space(16)
              height: 1
              color: root.border
            }
            Rectangle {
              visible: modelData.id !== "sep"
              anchors.fill: parent
              radius: root.cornerRadius
              color: (index === root.selectedIndex || itemArea.containsMouse) && modelData.enabled ? root.selectedBackground : "transparent"
              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(8)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(14)
                  text: modelData.checked ? "✓" : ""
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(22)
                  text: modelData.label + (modelData.enabled || !modelData.why ? "" : " — " + modelData.why)
                  elide: Text.ElideRight
                  color: modelData.enabled ? ((index === root.selectedIndex || itemArea.containsMouse) ? root.selectedText : root.foreground) : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
              MouseArea {
                id: itemArea
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.selectedIndex = index
                onClicked: root.runMenuItem(modelData)
              }
            }
          }
        }

        Column {
          visible: root.confirmHide
          width: parent.width
          spacing: Style.space(6)
          padding: Style.space(6)
          Text {
            width: parent.width - Style.space(12)
            text: "Hide Grabbar for " + (root.menuLive ? root.menuLive.class : "") + "? Its windows lose the title strip. You can undo this in Grabbar settings."
            wrapMode: Text.WordWrap
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Row {
            spacing: Style.space(6)
            PillButton { label: "Hide"; onActivated: root.confirmHideNow() }
            PillButton { label: "Cancel"; onActivated: root.confirmHide = false }
          }
        }
      }
    }

    // ----------------------------------------------------------- settings

    Rectangle {
      id: settingsCard
      visible: root.view === "settings"
      width: root.cardWidth
      height: Math.min(panel.height - Style.gapsOut * 2, settingsColumn.implicitHeight + root.contentMargin * 2)
      anchors.horizontalCenter: parent.horizontalCenter
      y: Style.gapsOut + Style.space(8)
      radius: root.cornerRadius
      color: root.background
      border.color: root.border
      border.width: 1

      MouseArea { anchors.fill: parent; onClicked: function(m) { m.accepted = true } }

      Column {
        id: settingsColumn
        anchors.fill: parent
        anchors.margins: root.contentMargin
        spacing: Style.space(10)

        Item {
          width: parent.width
          height: Style.space(32)
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Grabbar settings"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.weight: Font.Medium
          }
          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            PillButton { label: "Restore all" + (root.rows.length ? " (" + root.rows.length + ")" : ""); visible: root.rows.length > 0; onActivated: root.restoreAll() }
            PillButton { label: "Minimized windows"; onActivated: root.switchView("drawer") }
          }
        }

        SettingRow {
          label: "Grabbar"
          hint: root.grabbarOn ? "Turning it off returns minimized windows first" : "Off: no title strips, Minimize refused"
          options: ["On", "Off"]
          current: root.grabbarOn ? 0 : 1
          onChosen: function(i) { root.setGrabbarOn(i === 0) }
        }
        SettingRow {
          label: "Controls on"
          hint: "Actions keep the same meaning on either side"
          options: ["Right", "Left"]
          current: root.settings.buttonsLeft ? 1 : 0
          onChosen: function(i) { if (service) service.saveSettings({ buttonsLeft: i === 1 }) }
        }
        SettingRow {
          label: "Control size"
          hint: "Standard 34 px strip · Large 46 px strip, applied immediately"
          options: ["Standard", "Large"]
          current: root.settings.controlSize === "large" ? 1 : 0
          onChosen: function(i) { if (service) service.saveSettings({ controlSize: i === 1 ? "large" : "standard" }) }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          Text {
            text: "Excluded applications"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            visible: root.settings.excludedClasses.length === 0
            text: "None. Use “Hide Grabbar for …” in a window's menu to add one."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Repeater {
            model: root.settings.excludedClasses
            delegate: Row {
              required property var modelData
              spacing: Style.space(8)
              height: Style.space(26)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: modelData
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              PillButton { label: "Show Grabbar again"; onActivated: if (service) service.includeClass(modelData) }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          Text {
            text: "Setup check"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Repeater {
            model: root.setupLines
            delegate: Text {
              required property var modelData
              width: settingsColumn.width
              text: (modelData.ok ? "✓ " : "✗ ") + modelData.text
              wrapMode: Text.WordWrap
              color: modelData.ok ? root.foreground : Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          PillButton { label: root.showTechnical ? "Hide technical details" : "Technical details"; onActivated: root.showTechnical = !root.showTechnical }
          Text {
            visible: root.showTechnical && !!service
            width: settingsColumn.width
            text: service ? ("plugin " + service.pluginDir + "\nbackend epoch " + service.backendEpoch + " · socket " + service.socketPath + "\njournal " + service.stateDir + "/state.json (" + service.journalStatus + ")\nCLI: grabbar status · grabbar doctor · grabbar autoload status") : ""
            wrapMode: Text.WrapAnywhere
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // ---------------------------------------------------------- components

  component PillButton: Rectangle {
    id: pill
    property string label: ""
    signal activated()
    width: pillText.implicitWidth + Style.space(14)
    height: Style.space(24)
    radius: root.cornerRadius
    color: pillArea.containsMouse ? root.selectedBackground : "transparent"
    border.color: root.border
    border.width: 1
    Text {
      id: pillText
      anchors.centerIn: parent
      text: pill.label
      color: pillArea.containsMouse ? root.selectedText : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    MouseArea { id: pillArea; anchors.fill: parent; hoverEnabled: true; onClicked: function(m) { m.accepted = true; pill.activated() } }
  }

  component SettingRow: Item {
    id: settingRow
    property string label: ""
    property string hint: ""
    property var options: []
    property int current: 0
    signal chosen(int index)
    width: settingsColumn.width
    height: Style.space(40)
    Column {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - choices.width - Style.space(10)
      spacing: 2
      Text { text: settingRow.label; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
      Text { width: parent.width; text: settingRow.hint; elide: Text.ElideRight; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    }
    Row {
      id: choices
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)
      Repeater {
        model: settingRow.options
        delegate: Rectangle {
          required property var modelData
          required property int index
          width: choiceText.implicitWidth + Style.space(16)
          height: Style.space(26)
          radius: root.cornerRadius
          color: index === settingRow.current ? root.selectedBackground : (choiceArea.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05) : "transparent")
          border.color: index === settingRow.current ? root.accent : root.border
          border.width: 1
          Text {
            id: choiceText
            anchors.centerIn: parent
            text: modelData
            color: index === settingRow.current ? root.selectedText : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          MouseArea { id: choiceArea; anchors.fill: parent; hoverEnabled: true; onClicked: settingRow.chosen(index) }
        }
      }
    }
  }
}
