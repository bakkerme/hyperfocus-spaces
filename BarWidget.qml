import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "SpacesModel.js" as SpacesModel

BarWidget {
  id: root
  moduleName: "hyperfocus.spaces"

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  readonly property var monitor: {
    var window = root.QsWindow.window
    var screen = window ? window.screen : null
    return screen ? Hyprland.monitorFor(screen) : Hyprland.focusedMonitor
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰓩"
    tooltipText: SpacesModel.escapePlainText(strings.t("bar.tooltip"))
    onPressed: function(mouseButton) {
      if (!root.bar) return
      if (mouseButton === Qt.LeftButton) {
        var monName = root.monitor ? String(root.monitor.name || "") : ""
        var payload = monName ? JSON.stringify({ monitor: monName }) : "{}"
        root.bar.run("omarchy-shell shell toggle hyperfocus.spaces " + Util.shellQuote(payload))
      }
    }
  }
}
