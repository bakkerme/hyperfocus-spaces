import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "SpacesModel.js" as SpacesModel

Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property bool opened: false

  readonly property string pluginDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir)
    : (Quickshell.env("HOME") + "/.config/omarchy/plugins/brandon.spaces")
  readonly property string reorderScript: pluginDir + "/reorder-spaces.sh"
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string currentBackgroundLink: home + "/.local/state/omarchy/current/background"
  readonly property var appLibrary: shell ? shell.appLibrary : null

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // Monitor-block mapping from monitor-workspaces.lua
  property var monitorBlocks: ({})
  // Resolved wallpaper file path -> file:// URL
  property string wallpaperUrl: ""
  // Fresh Hyprland clients JSON grouped by workspace id
  property var clientsByWorkspace: ({})
  // Fresh Hyprland workspaces JSON (id -> { id, monitor, windows })
  property var existingWorkspaceIds: []
  // Active workspace id on the target monitor (kept optimistically synced during reorder)
  property int activeWorkspaceId: -1
  // Monitor logical rect for window layout projection
  property var monitorRect: ({ x: 0, y: 0, width: 1920, height: 1080 })
  // Keyboard selection cursor index into `allSpaces`
  property int selectedIndex: 0
  // Drag-to-reorder state (only for the monitor's own reorderable spaces)
  property int dragIndex: -1
  property int dropIndex: -1
  property bool dragging: false
  property bool suppressSlotAnimation: false
  property bool reorderInFlight: false
  property int dataRevision: 0

  readonly property var targetMonitor: overlay.targetMonitor || Hyprland.focusedMonitor
  readonly property string monitorName: targetMonitor ? String(targetMonitor.name || "") : ""

  readonly property int monitorBlock: SpacesModel.resolveMonitorBlock(
    monitorName,
    monitorBlocks,
    activeWorkspaceId > 0 ? activeWorkspaceId : (targetMonitor && targetMonitor.activeWorkspace ? targetMonitor.activeWorkspace.id : -1)
  )

  readonly property var spaceGroups: {
    var rev = root.dataRevision
    var raw = Hyprland.workspaces.values
    var list = []
    for (var i = 0; i < raw.length; i++) {
      var ws = raw[i]
      if (!ws) continue
      list.push({
        id: ws.id,
        monitorName: ws.monitor ? String(ws.monitor.name || "") : ""
      })
    }
    return SpacesModel.buildMonitorSpaces(root.monitorBlock, root.monitorName, list)
  }

  readonly property var ownIds: spaceGroups.ownIds || []
  readonly property var guestIds: spaceGroups.guestIds || []
  readonly property var allIds: ownIds.concat(guestIds)

  // Wayland toplevel lookup by normalized Hyprland address (for ScreencopyView)
  readonly property var toplevelByAddress: {
    var rev = root.dataRevision
    var map = {}
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var tl = values[i]
      if (!tl || !tl.wayland) continue
      var addr = SpacesModel.normalizeAddress(tl.address)
      if (addr) map[addr] = tl.wayland
    }
    return map
  }

  function waylandToplevelFor(address) {
    var key = SpacesModel.normalizeAddress(address)
    return key ? (root.toplevelByAddress[key] || null) : null
  }

  // Desktop entry icon resolution (matching Omarchy's Dock lookup)
  readonly property var terminalEntries: {
    var values = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (entry.runInTerminal || String(entry.execString || "").indexOf("--app-id=") >= 0) {
        out.push({ id: entry.id, execString: entry.execString || "", command: entry.command || [] })
      }
    }
    return out
  }

  function iconForAppClass(appClass) {
    var cls = String(appClass || "").trim()
    if (!cls) return ""
    var entry = DesktopEntries.heuristicLookup(cls)
    if (!entry) {
      var lower = cls.toLowerCase()
      for (var i = 0; i < root.terminalEntries.length; i++) {
        var te = root.terminalEntries[i]
        if (String(te.execString).toLowerCase().indexOf(lower) >= 0) {
          entry = DesktopEntries.byId(te.id)
          if (entry) break
        }
      }
    }
    var iconName = entry && entry.icon ? entry.icon : cls
    var resolved = root.appLibrary ? root.appLibrary.iconSource(iconName) : Quickshell.iconPath(iconName, true)
    return resolved ? String(resolved) : ""
  }

  // Monitor-workspaces state file watcher
  FileView {
    id: blocksFile
    path: root.stateHome + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.monitorBlocks = SpacesModel.parseMonitorBlocks(text())
    onLoadFailed: root.monitorBlocks = ({})
  }

  // Resolve current wallpaper symlink
  Process {
    id: bgProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      onStreamFinished: {
        var resolved = String(text || "").trim()
        if (resolved && !Util.isVideoPath(resolved)) {
          root.wallpaperUrl = Util.fileUrl(resolved)
        } else {
          root.wallpaperUrl = ""
        }
      }
    }
  }

  // Snapshot clients + workspaces + monitors from Hyprland in one fast call
  // separated by ASCII Record Separator (0x1e) so multi-line JSON parses intact.
  Process {
    id: snapshotProc
    command: ["bash", "-c", "printf '%s\\036%s\\036%s' \"$(hyprctl clients -j)\" \"$(hyprctl workspaces -j)\" \"$(hyprctl monitors -j)\""]
    stdout: StdioCollector {
      onStreamFinished: root.applySnapshot(text)
    }
  }

  // Reorder runner
  Process {
    id: reorderProc
    onExited: function(exitCode) {
      root.reorderInFlight = false
      if (exitCode !== 0) {
        console.warn("brandon.spaces: reorder-spaces.sh exited with code", exitCode)
      }
      Hyprland.refreshMonitors()
      Hyprland.refreshWorkspaces()
      Hyprland.refreshToplevels()
      root.refreshSnapshot()
    }
  }

  function applySnapshot(raw) {
    var parts = String(raw || "").split("\x1e")
    if (parts.length < 3) return

    try {
      var clients = JSON.parse(parts[0] || "[]")
      var workspaces = JSON.parse(parts[1] || "[]")
      var monitors = JSON.parse(parts[2] || "[]")

      var grouped = {}
      for (var i = 0; i < clients.length; i++) {
        var c = clients[i]
        if (!c || !c.workspace) continue
        var wsId = Number(c.workspace.id)
        if (!isFinite(wsId) || wsId <= 0) continue
        if (!grouped[wsId]) grouped[wsId] = []
        grouped[wsId].push(c)
      }
      root.clientsByWorkspace = grouped

      var existing = []
      for (var j = 0; j < workspaces.length; j++) {
        var w = workspaces[j]
        if (w && Number(w.id) > 0) existing.push(Number(w.id))
      }
      root.existingWorkspaceIds = existing

      var monName = root.monitorName
      var matched = null
      for (var m = 0; m < monitors.length; m++) {
        if (monitors[m].name === monName) { matched = monitors[m]; break }
        if (monitors[m].focused && !matched) matched = monitors[m]
      }
      if (matched) {
        root.monitorRect = SpacesModel.logicalMonitorRect(matched)
        if (matched.activeWorkspace && Number(matched.activeWorkspace.id) > 0) {
          root.activeWorkspaceId = Number(matched.activeWorkspace.id)
        }
      }

      root.dataRevision++
      root.syncSelectionToActive()
    } catch (e) {
      console.warn("brandon.spaces: failed to parse Hyprland snapshot:", e)
    }
  }

  function refreshSnapshot() {
    if (snapshotProc.running) return
    snapshotProc.running = true
  }

  function syncSelectionToActive() {
    if (root.dragging) return
    var idx = root.allIds.indexOf(root.activeWorkspaceId)
    if (idx >= 0) root.selectedIndex = idx
    else if (root.selectedIndex >= root.allIds.length) root.selectedIndex = Math.max(0, root.allIds.length - 1)
  }

  function screenByName(name) {
    if (!name) return null
    for (var i = 0; i < Quickshell.screens.length; i++) {
      if (Quickshell.screens[i].name === name) return Quickshell.screens[i]
    }
    return null
  }

  function open(payloadJson) {
    var requested = ""
    if (payloadJson) {
      try {
        var parsed = JSON.parse(String(payloadJson))
        if (parsed && typeof parsed.monitor === "string") requested = parsed.monitor
      } catch (e) {}
    }
    root.dragging = false
    root.dragIndex = -1
    root.dropIndex = -1
    root.opened = true
    if (requested) {
      var explicitScreen = root.screenByName(requested)
      if (explicitScreen) overlay.targetScreen = explicitScreen
    }
    Hyprland.refreshMonitors()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    if (!bgProc.running) bgProc.running = true
    root.refreshSnapshot()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.dragging = false
    root.dragIndex = -1
    root.dropIndex = -1
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function switchToSpace(id) {
    var mon = root.monitorName
    if (SpacesModel.blockOf(id) === root.monitorBlock && mon) {
      var slot = SpacesModel.slotOf(id)
      Util.execArgv(["hyprctl", "dispatch", "o.workspaces.focus(" + slot + ", \"" + mon + "\")"])
    } else {
      Util.execArgv(["hyprctl", "dispatch", "hl.dsp.focus({ workspace = \"" + id + "\" })"])
    }
    root.close()
  }

  function commitReorder(fromIndex, toIndex) {
    if (root.reorderInFlight) return
    var plan = SpacesModel.planReorder(root.ownIds, fromIndex, toIndex, root.existingWorkspaceIds)
    if (!plan) return

    // Optimistically update local clients + active workspace so the UI never flickers
    var nextGrouped = {}
    for (var key in root.clientsByWorkspace) {
      nextGrouped[key] = root.clientsByWorkspace[key]
    }
    var permMap = {}
    for (var p = 0; p < plan.slotPermutation.length; p++) {
      var move = plan.slotPermutation[p]
      permMap[move.from] = move.to
    }
    var saved = {}
    for (var s = 0; s < plan.slotPermutation.length; s++) {
      var fromId = plan.slotPermutation[s].from
      saved[fromId] = root.clientsByWorkspace[fromId] || []
    }
    for (var t = 0; t < plan.slotPermutation.length; t++) {
      var pair = plan.slotPermutation[t]
      if (saved[pair.from] && saved[pair.from].length > 0) nextGrouped[pair.to] = saved[pair.from]
      else delete nextGrouped[pair.to]
    }
    root.clientsByWorkspace = nextGrouped

    if (permMap[root.activeWorkspaceId] !== undefined) {
      root.activeWorkspaceId = permMap[root.activeWorkspaceId]
    }
    root.selectedIndex = toIndex
    root.dataRevision++

    var formatPairs = function(list) {
      if (!list || list.length === 0) return "-"
      return list.map(function(item) { return item.from + ":" + item.to }).join(",")
    }

    root.reorderInFlight = true
    reorderProc.command = [
      root.reorderScript,
      String(plan.tempBase),
      formatPairs(plan.renumberMoves),
      formatPairs(plan.slotPermutation)
    ]
    reorderProc.running = true
  }

  function summaryForWorkspace(wsId) {
    var list = root.clientsByWorkspace[wsId]
    if (!Array.isArray(list) || list.length === 0) return ""
    // Pick the most recently focused visible window on that space
    var best = null
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (!c || c.hidden || c.mapped === false) continue
      if (!best || Number(c.focusHistoryID || 9999) < Number(best.focusHistoryID || 9999)) best = c
    }
    if (!best) return ""
    var label = String(best.title || best.class || best.initialClass || "").trim()
    return label
  }

  // Keep live state synced if windows/workspaces change while overlay is open
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!root.opened || root.reorderInFlight) return
      var name = event ? String(event.name || "") : ""
      if (name === "openwindow" || name === "closewindow" || name === "movewindow"
          || name === "movewindowv2" || name === "workspacev2" || name === "changeworkspaceid"
          || name === "moveworkspacev2") {
        refreshDebounce.restart()
      }
    }
  }

  Timer {
    id: refreshDebounce
    interval: 80
    repeat: false
    onTriggered: {
      if (root.opened && !root.reorderInFlight) {
        Hyprland.refreshWorkspaces()
        Hyprland.refreshToplevels()
        root.refreshSnapshot()
      }
    }
  }

  // Responsive strip geometry
  readonly property int stripOuterMargin: Math.max(Style.gapsOut, Style.space(10))
  readonly property int stripPaddingX: Style.space(14)
  readonly property int stripPaddingY: Style.space(12)
  readonly property int cardSpacing: Style.space(12)
  readonly property int guestDividerGap: guestIds.length > 0 ? Style.space(18) : 0
  readonly property int footerHeight: Math.max(26, Style.font.caption + 14)

  readonly property real monitorAspect: {
    var r = root.monitorRect
    var ratio = (r && r.height > 0) ? (r.width / r.height) : (16 / 10)
    return Util.clamp(ratio, 1.2, 2.2)
  }

  readonly property int maxStripInnerWidth: Math.max(320, overlay.width - stripOuterMargin * 2 - stripPaddingX * 2)
  readonly property int cardCount: Math.max(1, root.allIds.length)

  readonly property int cardWidth: {
    var totalGaps = Math.max(0, cardCount - 1) * cardSpacing + guestDividerGap
    var fit = Math.floor((maxStripInnerWidth - totalGaps) / cardCount)
    return Math.max(150, Math.min(240, fit))
  }
  readonly property int previewHeight: Math.round(cardWidth / monitorAspect)
  readonly property int cardHeight: previewHeight + footerHeight

  readonly property int ownRowWidth: root.ownIds.length > 0
    ? (root.ownIds.length * cardWidth + Math.max(0, root.ownIds.length - 1) * cardSpacing)
    : 0
  readonly property int guestRowWidth: root.guestIds.length > 0
    ? (root.guestIds.length * cardWidth + Math.max(0, root.guestIds.length - 1) * cardSpacing)
    : 0
  readonly property int totalCardsWidth: ownRowWidth + (root.guestIds.length > 0 ? guestDividerGap + guestRowWidth : 0)

  readonly property bool barAtTop: !shell || !shell.barConfig || !shell.barConfig.position || shell.barConfig.position === "top"
  readonly property int stripTopOffset: barAtTop
    ? (Style.bar.sizeHorizontal + Math.max(Style.gapsOut, Style.space(8)))
    : Math.max(Style.gapsOut, Style.space(12))

  OverlayWindow {
    id: overlay
    shown: root.opened
    WlrLayershell.namespace: "brandon-spaces"

    // Backdrop scrim — click anywhere outside the strip to dismiss
    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim
      opacity: root.opened && overlay.contentRevealed ? 1 : 0
      Behavior on opacity {
        NumberAnimation {
          duration: Style.duration(root.opened ? 180 : 120)
          easing.type: Easing.OutCubic
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.close()
      }
    }

    // Keyboard navigation & shortcuts
    Item {
      id: keyCatcher
      focus: root.opened

      Keys.onPressed: function(event) {
        if (!root.opened) return
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
          return
        }

        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          if (root.selectedIndex >= 0 && root.selectedIndex < root.allIds.length) {
            root.switchToSpace(root.allIds[root.selectedIndex])
          }
          event.accepted = true
          return
        }

        var rk = Util.readingKey(event, true)
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0

        if (rk === Qt.Key_Left) {
          if (shift) {
            if (root.selectedIndex > 0 && root.selectedIndex < root.ownIds.length) {
              root.commitReorder(root.selectedIndex, root.selectedIndex - 1)
            }
          } else if (root.allIds.length > 0) {
            root.selectedIndex = (root.selectedIndex - 1 + root.allIds.length) % root.allIds.length
          }
          event.accepted = true
          return
        }

        if (rk === Qt.Key_Right) {
          if (shift) {
            if (root.selectedIndex >= 0 && root.selectedIndex < root.ownIds.length - 1) {
              root.commitReorder(root.selectedIndex, root.selectedIndex + 1)
            }
          } else if (root.allIds.length > 0) {
            root.selectedIndex = (root.selectedIndex + 1) % root.allIds.length
          }
          event.accepted = true
          return
        }

        // Direct slot jump with 1-9, 0
        if (!shift && event.key >= Qt.Key_0 && event.key <= Qt.Key_9) {
          var digit = event.key === Qt.Key_0 ? 10 : (event.key - Qt.Key_0)
          var targetId = root.monitorBlock * SpacesModel.SLOTS_PER_MONITOR + digit
          root.switchToSpace(targetId)
          event.accepted = true
          return
        }
      }
    }

    // Top horizontal Spaces strip
    BorderSurface {
      id: strip
      anchors.horizontalCenter: parent.horizontalCenter
      y: root.stripTopOffset
      width: Math.min(root.totalCardsWidth + root.stripPaddingX * 2, overlay.width - root.stripOuterMargin * 2)
      height: headerRow.height + Style.space(10) + root.cardHeight + root.stripPaddingY * 2 + 8
      radius: Style.cornerRadius
      color: Commons.Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))

      opacity: root.opened && overlay.contentRevealed ? 1 : 0
      scale: root.opened && overlay.contentRevealed ? 1 : 0.97
      transform: Translate {
        y: root.opened && overlay.contentRevealed ? 0 : -10
        Behavior on y {
          NumberAnimation {
            duration: Style.duration(root.opened ? 180 : 120)
            easing.type: Easing.Bezier
            easing.bezierCurve: Style.easeOut
          }
        }
      }

      Behavior on opacity {
        NumberAnimation {
          duration: Style.duration(root.opened ? 180 : 120)
          easing.type: Easing.OutCubic
        }
      }
      Behavior on scale {
        NumberAnimation {
          duration: Style.duration(root.opened ? 180 : 120)
          easing.type: Easing.Bezier
          easing.bezierCurve: Style.easeOut
        }
      }

      // Absorb clicks inside the strip so the scrim behind it doesn't dismiss on strip padding clicks
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(mouse) { mouse.accepted = true }
      }

      // Header row
      Item {
        id: headerRow
        anchors.top: parent.top
        anchors.topMargin: root.stripPaddingY
        anchors.left: parent.left
        anchors.leftMargin: root.stripPaddingX
        anchors.right: parent.right
        anchors.rightMargin: root.stripPaddingX
        height: Math.max(20, Style.font.caption + 6)

        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: strings.t("overlay.title")
            color: Commons.Color.menu.text
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
            font.weight: Font.DemiBold
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            visible: root.monitorName !== ""
            textFormat: Text.PlainText
            text: root.monitorName
            color: Util.alpha(Commons.Color.menu.text, 0.5)
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: strings.t("overlay.hint")
          color: Util.alpha(Commons.Color.menu.text, 0.48)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          visible: strip.width >= 480
        }
      }

      // Horizontally scrollable container for the space cards
      Flickable {
        id: scroller
        anchors.top: headerRow.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.leftMargin: root.stripPaddingX
        anchors.right: parent.right
        anchors.rightMargin: root.stripPaddingX
        height: root.cardHeight + 8
        contentWidth: Math.max(width, root.totalCardsWidth)
        contentHeight: height
        clip: true
        interactive: !root.dragging && contentWidth > width
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.HorizontalFlick

        // Support mouse wheel horizontal scrolling when overflowed
        WheelHandler {
          enabled: scroller.contentWidth > scroller.width && !root.dragging
          onWheel: function(event) {
            var delta = event.angleDelta.x !== 0 ? event.angleDelta.x : event.angleDelta.y
            var next = scroller.contentX - delta
            scroller.contentX = Util.clamp(next, 0, Math.max(0, scroller.contentWidth - scroller.width))
          }
        }

        Item {
          id: cardsCanvas
          x: Math.max(0, Math.floor((scroller.width - root.totalCardsWidth) / 2))
          y: 4
          width: root.totalCardsWidth
          height: root.cardHeight

          // Visual drop-target slot guide while dragging
          Rectangle {
            visible: root.dragging && root.dropIndex >= 0 && root.dropIndex < root.ownIds.length
            x: root.dropIndex * (root.cardWidth + root.cardSpacing)
            y: 0
            width: root.cardWidth
            height: root.cardHeight
            radius: Style.cornerRadius
            color: Util.alpha(Commons.Color.accent, 0.08)
            border.width: 2
            border.color: Util.alpha(Commons.Color.accent, 0.55)
            z: 0

            Behavior on x {
              NumberAnimation {
                duration: Style.duration(140)
                easing.type: Easing.OutCubic
              }
            }
          }

          // Reorderable own-monitor space cards
          Repeater {
            model: root.ownIds

            delegate: Item {
              id: cardSlot
              required property int modelData
              required property int index

              readonly property bool isDraggedCard: root.dragging && root.dragIndex === index
              readonly property int visualSlot: root.dragging
                ? SpacesModel.visualIndexDuringDrag(index, root.dragIndex, root.dropIndex)
                : index
              readonly property real restX: visualSlot * (root.cardWidth + root.cardSpacing)
              readonly property var wsClients: root.clientsByWorkspace[modelData] || []
              readonly property var projected: SpacesModel.projectWindows(
                wsClients,
                root.monitorRect,
                root.cardWidth - 8,
                root.previewHeight - 4
              )

              property real dragOffsetX: 0

              width: root.cardWidth
              height: root.cardHeight
              x: isDraggedCard ? dragOffsetX : restX
              y: isDraggedCard ? -4 : 0
              z: isDraggedCard ? 100 : (cardView.hovered ? 10 : 1)

              Behavior on x {
                enabled: !cardSlot.isDraggedCard && !root.suppressSlotAnimation
                NumberAnimation {
                  duration: Style.duration(160)
                  easing.type: Easing.OutCubic
                }
              }

              Behavior on y {
                NumberAnimation {
                  duration: Style.duration(140)
                  easing.type: Easing.OutCubic
                }
              }

              SpaceCard {
                id: cardView
                anchors.fill: parent
                spaceId: cardSlot.modelData
                slotNumber: SpacesModel.slotOf(cardSlot.modelData)
                isGuest: false
                isActive: cardSlot.modelData === root.activeWorkspaceId
                isSelected: cardSlot.index === root.selectedIndex
                isDragged: cardSlot.isDraggedCard
                previewWidth: root.cardWidth
                previewHeight: root.previewHeight
                footerHeight: root.footerHeight
                wallpaperUrl: root.wallpaperUrl
                projectedWindows: cardSlot.projected
                windowCount: cardSlot.projected.length
                summaryText: root.summaryForWorkspace(cardSlot.modelData)
                emptyLabel: strings.t("space.empty")
                captureEnabled: root.opened && overlay.contentRevealed
                iconLookup: root.iconForAppClass
                toplevelLookup: root.waylandToplevelFor
              }

              MouseArea {
                id: cardMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                preventStealing: true
                cursorShape: root.dragging && cardSlot.isDraggedCard ? Qt.ClosedHandCursor : Qt.PointingHandCursor

                property real pressCanvasX: 0
                property real startCardX: 0
                property bool movedPastThreshold: false

                onEntered: {
                  cardView.hovered = true
                  if (!root.dragging) root.selectedIndex = cardSlot.index
                }
                onExited: cardView.hovered = false

                onPressed: function(mouse) {
                  var pt = mapToItem(cardsCanvas, mouse.x, mouse.y)
                  pressCanvasX = pt.x
                  startCardX = cardSlot.restX
                  movedPastThreshold = false
                  cardSlot.dragOffsetX = startCardX
                  root.selectedIndex = cardSlot.index
                }

                onPositionChanged: function(mouse) {
                  if (!(mouse.buttons & Qt.LeftButton)) return
                  if (root.reorderInFlight) return
                  var pt = mapToItem(cardsCanvas, mouse.x, mouse.y)
                  var dx = pt.x - pressCanvasX

                  if (!movedPastThreshold && Math.abs(dx) >= 8) {
                    movedPastThreshold = true
                    root.dragIndex = cardSlot.index
                    root.dropIndex = cardSlot.index
                    root.dragging = true
                  }

                  if (movedPastThreshold && root.dragIndex === cardSlot.index) {
                    var minX = -root.cardWidth * 0.2
                    var maxX = root.ownRowWidth - root.cardWidth * 0.8
                    var clampedX = Util.clamp(startCardX + dx, minX, maxX)
                    cardSlot.dragOffsetX = clampedX
                    var centerX = clampedX + root.cardWidth / 2
                    root.dropIndex = SpacesModel.dropIndexForX(centerX, root.cardWidth, root.cardSpacing, root.ownIds.length)
                  }
                }

                onReleased: function(mouse) {
                  if (movedPastThreshold && root.dragging && root.dragIndex === cardSlot.index) {
                    var fromIdx = root.dragIndex
                    var toIdx = root.dropIndex
                    var willReorder = toIdx >= 0 && toIdx !== fromIdx
                    if (willReorder) root.suppressSlotAnimation = true
                    root.dragging = false
                    root.dragIndex = -1
                    root.dropIndex = -1
                    movedPastThreshold = false
                    if (willReorder) {
                      root.commitReorder(fromIdx, toIdx)
                      Qt.callLater(function() { root.suppressSlotAnimation = false })
                    }
                  } else {
                    movedPastThreshold = false
                    root.switchToSpace(cardSlot.modelData)
                  }
                }

                onCanceled: {
                  if (root.dragIndex === cardSlot.index) {
                    root.dragging = false
                    root.dragIndex = -1
                    root.dropIndex = -1
                  }
                  movedPastThreshold = false
                }
              }
            }
          }

          // Subtle separator before any guest workspaces (from unplugged monitors)
          Rectangle {
            visible: root.guestIds.length > 0
            x: root.ownRowWidth + Math.floor(root.guestDividerGap / 2)
            y: 12
            width: 1
            height: root.cardHeight - 24
            color: Util.alpha(Commons.Color.menu.text, 0.2)
          }

          // Guest workspaces (click-to-switch only so monitor-workspaces reclaim stays intact)
          Repeater {
            model: root.guestIds

            delegate: Item {
              id: guestSlot
              required property int modelData
              required property int index

              readonly property int fullIndex: root.ownIds.length + index
              readonly property var wsClients: root.clientsByWorkspace[modelData] || []
              readonly property var projected: SpacesModel.projectWindows(
                wsClients,
                root.monitorRect,
                root.cardWidth - 8,
                root.previewHeight - 4
              )

              x: root.ownRowWidth + root.guestDividerGap + index * (root.cardWidth + root.cardSpacing)
              y: 0
              width: root.cardWidth
              height: root.cardHeight

              SpaceCard {
                id: guestCard
                anchors.fill: parent
                spaceId: guestSlot.modelData
                slotNumber: SpacesModel.slotOf(guestSlot.modelData)
                isGuest: true
                isActive: guestSlot.modelData === root.activeWorkspaceId
                isSelected: guestSlot.fullIndex === root.selectedIndex
                isDragged: false
                previewWidth: root.cardWidth
                previewHeight: root.previewHeight
                footerHeight: root.footerHeight
                wallpaperUrl: root.wallpaperUrl
                projectedWindows: guestSlot.projected
                windowCount: guestSlot.projected.length
                summaryText: root.summaryForWorkspace(guestSlot.modelData)
                emptyLabel: strings.t("space.empty")
                captureEnabled: root.opened && overlay.contentRevealed
                iconLookup: root.iconForAppClass
                toplevelLookup: root.waylandToplevelFor
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: {
                  guestCard.hovered = true
                  root.selectedIndex = guestSlot.fullIndex
                }
                onExited: guestCard.hovered = false
                onClicked: root.switchToSpace(guestSlot.modelData)
              }
            }
          }
        }
      }
    }
  }
}
