import QtQuick
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "SpacesModel.js" as SpacesModel

Item {
  id: card

  required property int spaceId
  required property int slotNumber
  required property bool isGuest
  required property bool isActive
  required property bool isSelected
  required property bool isDragged
  required property real previewWidth
  required property real previewHeight
  required property real footerHeight
  required property string wallpaperUrl
  required property var projectedWindows
  required property int windowCount
  required property string summaryText
  required property string emptyLabel
  required property bool captureEnabled
  required property var iconLookup
  required property var toplevelLookup

  readonly property bool isEmpty: windowCount === 0
  readonly property int cornerRadius: Math.max(0, Style.cornerRadius)
  readonly property int innerRadius: Math.min(4, cornerRadius)

  width: previewWidth
  height: previewHeight + footerHeight

  scale: isDragged ? 1.04 : (hovered && !isDragged ? 1.015 : 1.0)
  Behavior on scale {
    NumberAnimation {
      duration: Style.duration(140)
      easing.type: Easing.OutCubic
    }
  }

  property bool hovered: false

  Rectangle {
    id: frame
    anchors.fill: parent
    radius: card.cornerRadius
    color: card.isActive
      ? Util.alpha(Commons.Color.accent, 0.14)
      : (card.isSelected || card.hovered
        ? Style.hoverFillFor(Commons.Color.menu.text, Commons.Color.accent)
        : Style.normalFillFor(Commons.Color.menu.text, Commons.Color.accent))
    border.width: card.isDragged || card.isActive ? 2 : (card.isSelected || card.hovered ? 1 : 1)
    border.color: card.isDragged
      ? Commons.Color.accent
      : (card.isActive
        ? Commons.Color.accent
        : (card.isSelected
          ? Util.alpha(Commons.Color.accent, 0.75)
          : (card.hovered
            ? Util.alpha(Commons.Color.menu.text, 0.45)
            : Util.alpha(Commons.Color.menu.text, 0.2))))

    Behavior on border.color {
      ColorAnimation { duration: Style.duration(120) }
    }

    // Mini desktop thumbnail area
    Rectangle {
      id: previewArea
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: 4
      anchors.leftMargin: 4
      anchors.rightMargin: 4
      height: Math.max(24, card.previewHeight - 4)
      radius: card.innerRadius
      color: Commons.Color.background
      clip: true

      Image {
        id: wallpaper
        anchors.fill: parent
        source: card.wallpaperUrl
        sourceSize.width: Math.max(160, Math.ceil(previewArea.width * 2))
        sourceSize.height: Math.max(100, Math.ceil(previewArea.height * 2))
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        smooth: true
        mipmap: true
        opacity: card.isEmpty ? 0.65 : 0.88
      }

      // Subtle scrim over wallpaper so window miniatures stay legible across bright wallpapers
      Rectangle {
        anchors.fill: parent
        color: Util.alpha(Commons.Color.background, card.isEmpty ? 0.16 : 0.14)
      }

      // Scaled miniature windows in their actual Hyprland layout
      Repeater {
        model: card.projectedWindows

        delegate: Item {
          id: winBox
          required property var modelData

          readonly property var waylandHandle: card.toplevelLookup ? card.toplevelLookup(modelData.address) : null
          readonly property string appIcon: card.iconLookup ? card.iconLookup(modelData.appClass) : ""
          readonly property bool showLiveCapture: card.captureEnabled && !!waylandHandle

          x: Math.round(modelData.x)
          y: Math.round(modelData.y)
          width: Math.max(10, Math.round(modelData.width))
          height: Math.max(10, Math.round(modelData.height))
          z: modelData.zIndex

          // Clean themed fallback miniature window
          Rectangle {
            anchors.fill: parent
            radius: Math.min(3, card.innerRadius)
            color: Util.alpha(Commons.Color.background, 0.92)
            border.width: 1
            border.color: modelData.floating
              ? Util.alpha(Commons.Color.accent, 0.7)
              : Util.alpha(Commons.Color.foreground, 0.35)
            clip: true

            // Tiny titlebar strip
            Rectangle {
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              height: Math.min(8, Math.max(3, Math.round(parent.height * 0.14)))
              color: Util.alpha(Commons.Color.foreground, 0.12)
              visible: parent.height >= 18
            }

            // Centered app icon in schematic fallback
            Image {
              anchors.centerIn: parent
              anchors.verticalCenterOffset: parent.height >= 26 ? 2 : 0
              width: Math.max(12, Math.min(26, Math.round(Math.min(parent.width, parent.height) * 0.45)))
              height: width
              source: winBox.appIcon
              sourceSize.width: 48
              sourceSize.height: 48
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
              mipmap: true
              visible: !screencopy.hasContent && source !== "" && parent.width >= 16 && parent.height >= 16
            }

            // Fallback initial letter if no icon found
            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: String(modelData.appClass || modelData.title || "?").slice(0, 1).toUpperCase()
              color: Util.alpha(Commons.Color.foreground, 0.75)
              font.family: Style.font.menuFamily
              font.pixelSize: Math.max(9, Math.min(14, Math.round(Math.min(parent.width, parent.height) * 0.35)))
              font.weight: Font.Medium
              visible: !screencopy.hasContent && winBox.appIcon === "" && parent.width >= 16 && parent.height >= 16
            }

            // Live / snapshot Wayland toplevel preview when Hyprland provides frames
            ScreencopyView {
              id: screencopy
              anchors.fill: parent
              anchors.margins: 1
              captureSource: winBox.showLiveCapture ? winBox.waylandHandle : null
              live: false
              paintCursor: false
              visible: hasContent
              constraintSize: Qt.size(
                Math.max(32, Math.ceil(parent.width * 2)),
                Math.max(32, Math.ceil(parent.height * 2))
              )

              Timer {
                id: captureTrigger
                interval: 16
                repeat: false
                onTriggered: {
                  if (screencopy.captureSource && winBox.showLiveCapture) {
                    screencopy.captureFrame()
                  }
                }
              }

              onCaptureSourceChanged: {
                if (captureSource && winBox.showLiveCapture) captureTrigger.restart()
              }

              Component.onCompleted: {
                if (captureSource && winBox.showLiveCapture) captureTrigger.restart()
              }
            }

            // Small corner app badge over live capture when window is large enough
            Rectangle {
              visible: screencopy.hasContent && winBox.appIcon !== "" && parent.width >= 38 && parent.height >= 30
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.margins: 3
              width: 16
              height: 16
              radius: Math.min(3, card.innerRadius)
              color: Util.alpha(Commons.Color.background, 0.82)
              border.width: 1
              border.color: Util.alpha(Commons.Color.foreground, 0.2)

              Image {
                anchors.centerIn: parent
                width: 12
                height: 12
                source: winBox.appIcon
                sourceSize.width: 24
                sourceSize.height: 24
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
              }
            }
          }
        }
      }

      // Clean desktop wallpaper preview for empty spaces (slot number is shown in footer badge)
    }

    // Footer metadata bar
    Item {
      id: footer
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: card.footerHeight

      // Space slot pill
      Rectangle {
        id: slotBadge
        anchors.left: parent.left
        anchors.leftMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        height: Math.max(16, Style.font.caption + 4)
        width: Math.max(height, slotText.implicitWidth + 8)
        radius: card.innerRadius
        color: card.isActive
          ? Commons.Color.accent
          : Util.alpha(Commons.Color.menu.text, 0.12)

        Text {
          id: slotText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: card.isGuest ? String(card.spaceId) : SpacesModel.slotLabel(card.slotNumber)
          color: card.isActive ? Commons.Color.background : Commons.Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          font.weight: Font.Bold
        }
      }

      // Window summary or Empty label
      Text {
        anchors.left: slotBadge.right
        anchors.leftMargin: 6
        anchors.right: countBadge.visible ? countBadge.left : parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: card.isEmpty ? card.emptyLabel : card.summaryText
        color: card.isEmpty
          ? Util.alpha(Commons.Color.menu.text, 0.5)
          : Commons.Color.menu.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      // Window count badge when multiple windows are open
      Rectangle {
        id: countBadge
        visible: card.windowCount > 1
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        height: Math.max(15, Style.font.caption + 2)
        width: Math.max(height, countText.implicitWidth + 6)
        radius: card.innerRadius
        color: Util.alpha(Commons.Color.menu.text, 0.1)

        Text {
          id: countText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: Commons.I18n.formatNumber(card.windowCount, 0)
          color: Util.alpha(Commons.Color.menu.text, 0.8)
          font.family: Style.font.menuFamily
          font.pixelSize: Math.max(9, Style.font.caption - 1)
        }
      }
    }
  }
}
