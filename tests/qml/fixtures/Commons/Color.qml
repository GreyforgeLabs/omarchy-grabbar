pragma Singleton
import QtQuick
QtObject {
  readonly property var bar: ({ background: "#222222", text: "#ffffff" })
  readonly property color background: "#111111"
  readonly property color urgent: "#ff0000"
}
