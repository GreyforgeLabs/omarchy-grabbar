import QtQuick
Item {
  property var bar
  property string text
  property int fontSize
  property bool keepSpace
  property bool active
  property string tooltipText
  signal pressed(int button)
}
