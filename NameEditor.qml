import QtQuick
import qs.Ui as Ui

// A single-line name editor that owns Return/Enter so a submission cannot
// bubble into whichever panel view becomes visible next.
Ui.TextField {
  signal submitted(string value)

  Keys.onReturnPressed: function(event) {
    submitted(text)
    event.accepted = true
  }
  Keys.onEnterPressed: function(event) {
    submitted(text)
    event.accepted = true
  }
}
