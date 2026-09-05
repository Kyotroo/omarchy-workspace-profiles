import QtQuick
import QtTest
import "file:/usr/share/omarchy/shell/Ui"
import ".."

Item {
  width: 320
  height: 120
  property int submittedCount: 0
  property int parentActivationCount: 0

  PanelKeyCatcher {
    id: catcher
    anchors.fill: parent
    onActivateRequested: parentActivationCount++

    NameEditor {
      id: editor
      objectName: "editor"
      onSubmitted: submittedCount++
    }
  }

  TestCase {
    name: "NameEditor"
    when: windowShown

    function init() {
      submittedCount = 0
      parentActivationCount = 0
      editor.text = "Reading"
      editor.forceActiveFocus()
    }

    function test_returnSubmitsWithoutActivatingParent() {
      keyClick(Qt.Key_Return)
      compare(submittedCount, 1)
      compare(parentActivationCount, 0)
    }

    function test_keypadEnterSubmitsWithoutActivatingParent() {
      keyClick(Qt.Key_Enter)
      compare(submittedCount, 1)
      compare(parentActivationCount, 0)
    }
  }
}
