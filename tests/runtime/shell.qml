import QtQuick
import Quickshell
import "Plugin" as Plugin

ShellRoot {
  Plugin.Presets {
    id: plugin
  }

  Timer {
    id: quitTimer
    interval: 700
    onTriggered: Qt.quit()
  }

  Component.onCompleted: {
    var action = Quickshell.env("KDM_PRESETS_TEST_ACTION")
    if (action === "decline") {
      plugin.declineOnboardingShortcuts()
    } else if (action === "accept") {
      plugin.acceptOnboardingShortcuts()
    } else if (action === "set-default") {
      plugin.profiles = [{
        name: "Safe Demo",
        default: false,
        closeMode: "trackedOnly",
        workspaces: []
      }]
      plugin.setProfileDefault(0)
    } else {
      console.error("Unknown test action: " + action)
    }
    quitTimer.start()
  }
}
