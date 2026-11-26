import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "." as Local

Panel {
  id: root
  moduleName: "pgrove.window-fade"
  implicitWidth: icon.implicitWidth
  implicitHeight: icon.implicitHeight

  readonly property var service: (bar && bar.shell ? bar.shell.serviceFor(moduleName) : null)
    || Local.WindowFadeServiceState.current
  readonly property var display: QsWindow.window ? QsWindow.window.screen : null
  readonly property string screenName: display ? display.name : ""
  readonly property var monitor: display ? Hyprland.monitorFor(display) : null
  readonly property var currentWorkspace: {
    if (!monitor)
      return null
    const special = monitor.lastIpcObject.specialWorkspace
    return special && special.name ? special : monitor.activeWorkspace
  }
  readonly property var entry: settings || ({})
  readonly property var profile: Object.assign({},
    entry.screenProfiles ? entry.screenProfiles[screenName] : null,
    service ? service.profileOverrides[screenName] : null)
  readonly property bool fadeEnabled: profileSetting("fadeEnabled", true) !== false
  readonly property var excludedApps: {
    const saved = profileSetting("excludedApps", [])
    return Array.isArray(saved) ? saved.filter(validApp) : []
  }
  readonly property int delayMs: boundedSetting("delayMs", 1000, 300000, 250)
  readonly property int duration: boundedSetting("fadeMs", 2000, 5000, 250) / 250
  readonly property int saturation: boundedSetting("saturation", 60, 100, 1)
  readonly property int brightness: boundedSetting("brightness", 75, 100, 1)
  readonly property int transparency: boundedSetting("transparency", 0, 100, 1)
  readonly property int wallpaperBrightness: boundedSetting("wallpaperBrightness", 100, 100, 1)
  readonly property int wallpaperSaturation: boundedSetting("wallpaperSaturation", 100, 100, 1)
  readonly property bool saveFailed: !!service && service.profileSaveFailed
  readonly property bool applyFailed: !!service && service.failed
  readonly property string applyMessage: service && service.applyMessage || "applyFailed"
  readonly property color panelForeground: Commons.Color.popups.text
  property bool showingExclusions: false
  property bool showingWallpaper: false
  property string exclusionMode: "windows"
  readonly property var displayClients: {
    if (!service || !showingExclusions || !monitor)
      return []
    return service.clients.filter(client => client.mapped && client.monitor === monitor.id)
  }
  readonly property var exclusionChoices: {
    if (exclusionMode === "apps") {
      const apps = new Set(excludedApps)
      displayClients.forEach(client => { if (validApp(client.class)) apps.add(client.class) })
      return Array.from(apps, app => ({
        id: app, label: appName(app), checked: excludedApps.includes(app)
      })).sort((a, b) => a.label.localeCompare(b.label) || a.id.localeCompare(b.id))
    }
    if (!currentWorkspace)
      return []
    const tag = "window-fade-exclude-" + screenName
    return displayClients.filter(client => client.workspace && client.workspace.id === currentWorkspace.id
      && service.validWindowId(client.stableId)).map(client => ({
      id: client.stableId,
      label: String(client.title || appName(client.class) || strings.t("untitledWindow")).slice(0, 240),
      app: appName(client.class),
      checked: Array.isArray(client.tags) && client.tags.includes(tag)
    })).sort((a, b) => a.label.localeCompare(b.label))
  }
  readonly property var sliderSpecs: [
    { label: "delay", key: "delayMs", max: 138, timing: true },
    { label: "duration", key: "fadeMs", max: 20, timing: true },
    { label: "saturation", key: "saturation", max: 100, timing: false },
    { label: "brightness", key: "brightness", max: 100, timing: false },
    { label: "transparency", key: "transparency", max: 100, timing: false }
  ]
  readonly property var wallpaperSliderSpecs: [
    { label: "wallpaperBrightness", key: "wallpaperBrightness", max: 100, timing: false },
    { label: "wallpaperSaturation", key: "wallpaperSaturation", max: 100, timing: false }
  ]

  function profileSetting(key, fallback) {
    if (profile[key] !== undefined && profile[key] !== null)
      return profile[key]
    return entry[key] === undefined || entry[key] === null ? fallback : entry[key]
  }

  function validApp(app) {
    return typeof app === "string" && app.length > 0 && app.length <= 256
      && !/[\u0000-\u001f\u007f-\u009f]/.test(app)
  }

  function appName(app) {
    if (!validApp(app))
      return ""
    if (app === "foot")
      return strings.t("footTerminal")
    const desktopEntry = DesktopEntries.heuristicLookup(app)
    return String(desktopEntry && desktopEntry.name || app).slice(0, 80)
  }

  function toggleExclusion(choice) {
    if (!service || !choice)
      return
    if (exclusionMode === "apps") {
      save("excludedApps", choice.checked
        ? excludedApps.filter(app => app !== choice.id)
        : excludedApps.concat(choice.id))
    } else {
      service.setWindowExcluded(screenName, choice.id, !choice.checked)
    }
  }

  onShowingExclusionsChanged: {
    if (showingExclusions && service) {
      Hyprland.refreshMonitors()
      service.refreshClients()
    }
  }
  onOpenedChanged: {
    if (!opened) {
      showingExclusions = false
      showingWallpaper = false
    }
  }

  Connections {
    target: Hyprland
    enabled: root.showingExclusions && !!root.service
    function onRawEvent(event) {
      if (event.name.startsWith("activespecial"))
        Hyprland.refreshMonitors()
      if (/^(openwindow|closewindow|movewindow|windowtitle|moveworkspace|renameworkspace|configreloaded)/.test(event.name))
        root.service.refreshClients()
    }
  }

  function save(key, value) {
    if (!service || !service.profilesReady || !screenName)
      return
    if (!saveFailed && profileSetting(key, undefined) === value)
      return
    service.setProfile(screenName, key, value)
  }

  function boundedSetting(key, fallback, maximum, step) {
    const value = profileSetting(key, fallback)
    const valid = typeof value === "number" && Number.isFinite(value) ? value : fallback
    return Math.max(0, Math.min(maximum, Math.round(valid / step) * step))
  }

  // Preserve useful precision for short delays without making five minutes
  // require over a thousand slider positions.
  function delayTicks(milliseconds) {
    if (milliseconds <= 10000) return milliseconds / 250
    if (milliseconds <= 60000) return 30 + Math.round(milliseconds / 1000)
    return 78 + Math.round(milliseconds / 5000)
  }

  function delayMilliseconds(ticks) {
    if (ticks <= 40) return ticks * 250
    if (ticks <= 90) return (ticks - 30) * 1000
    return (ticks - 78) * 5000
  }

  function timingLabel(milliseconds) {
    if (milliseconds >= 60000) {
      const minutes = Math.floor(milliseconds / 60000)
      const seconds = Math.floor(milliseconds / 1000) % 60
      const label = strings.t(seconds ? "minutesSeconds" : "minutes").arg(Commons.I18n.formatNumber(minutes, 0))
      return seconds ? label.arg(Commons.I18n.formatNumber(seconds, 0)) : label
    }
    const decimals = milliseconds % 1000 === 0 ? 0 : (milliseconds % 500 === 0 ? 1 : 2)
    return strings.t("seconds").arg(Commons.I18n.formatNumber(milliseconds / 1000, decimals))
  }

  function sliderValue(key, ticks) {
    if (key === "delayMs") return delayMilliseconds(ticks)
    if (key === "fadeMs") return ticks * 250
    return ticks
  }

  function sliderTicks(key) {
    if (key === "delayMs") return delayTicks(delayMs)
    if (key === "fadeMs") return duration
    if (key === "saturation") return saturation
    if (key === "brightness") return brightness
    if (key === "wallpaperBrightness") return wallpaperBrightness
    if (key === "wallpaperSaturation") return wallpaperSaturation
    return transparency
  }

  function sliderLabel(value, timing) {
    if (timing) return timingLabel(value)
    return strings.t("percent").arg(Commons.I18n.formatNumber(value, 0))
  }

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  BarIconButton {
    id: icon
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(0xF00DE) // brightness-6
    opacity: root.fadeEnabled ? 1 : 0.55
    tooltipText: strings.t(root.applyFailed ? root.applyMessage : root.fadeEnabled ? "on" : "off")
      + (root.screenName ? " · " + root.screenName : "")
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton)
        root.save("fadeEnabled", !root.fadeEnabled)
      else if (mouseButton === Qt.LeftButton)
        root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: icon
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(root.showingExclusions ? 350 : 300))
    contentHeight: panel.fittedContentHeight(root.showingExclusions
      ? exclusions.implicitHeight : controls.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onCloseRequested: {
        if (root.showingExclusions)
          root.showingExclusions = false
        else if (root.showingWallpaper)
          root.showingWallpaper = false
        else
          root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (!root.showingExclusions)
          return
        if (dx)
          root.exclusionMode = dx > 0 ? "windows" : "apps"
        if (dy && exclusionList.count) {
          exclusionList.currentIndex = Math.max(0, Math.min(exclusionList.count - 1, exclusionList.currentIndex + dy))
          exclusionList.positionViewAtIndex(exclusionList.currentIndex, ListView.Contain)
        }
      }
      onActivateRequested: {
        if (root.showingWallpaper)
          return
        if (!root.showingExclusions)
          root.showingExclusions = true
        else if (exclusionList.currentItem && exclusionList.currentItem.enabled)
          root.toggleExclusion(exclusionList.currentItem.modelData)
      }

      Column {
        id: controls
        visible: !root.showingExclusions
        width: parent.width
        spacing: Style.spacing.md

        Toggle {
          visible: !root.showingWallpaper
          width: parent.width
          label: strings.t("title")
          description: root.display && root.display.model
            ? strings.t("screenModel").arg(root.screenName).arg(root.display.model)
            : strings.t("screen").arg(root.screenName)
          checked: root.fadeEnabled
          onClicked: root.save("fadeEnabled", !root.fadeEnabled)
        }

        Button {
          visible: !root.showingWallpaper
          width: parent.width
          bordered: true
          text: strings.t("exclusions")
          onClicked: root.showingExclusions = true
        }

        Button {
          width: parent.width
          bordered: true
          text: strings.t(root.showingWallpaper ? "back" : "wallpaper")
          onClicked: root.showingWallpaper = !root.showingWallpaper
        }

        Text {
          visible: root.showingWallpaper
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("wallpaperForScreen").arg(root.screenName)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          color: root.panelForeground
        }

        Repeater {
          model: root.showingWallpaper ? root.wallpaperSliderSpecs : root.sliderSpecs
          delegate: Column {
            id: timing
            required property var modelData
            width: controls.width
            spacing: Style.spacing.xs

            Item {
              width: parent.width
              height: label.implicitHeight
              PanelSectionHeader {
                id: label
                text: strings.t(timing.modelData.label)
              }
              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.sliderLabel(
                  timing.modelData.key === "delayMs" && !slider.dragging
                    ? root.delayMs : root.sliderValue(timing.modelData.key, slider.liveValue),
                  timing.modelData.timing)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.panelForeground
              }
            }

            PanelSlider {
              id: slider
              width: parent.width
              bar: root.bar
              integer: true
              step: 1
              minimum: 0
              maximum: timing.modelData.max
              value: root.sliderTicks(timing.modelData.key)
              onReleased: function(value) {
                root.save(timing.modelData.key, root.sliderValue(timing.modelData.key, value))
              }
            }
          }
        }

        Text {
          visible: root.saveFailed || root.applyFailed
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t(root.saveFailed ? "saveFailed" : root.applyMessage)
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: root.panelForeground
        }
      }

      Column {
        id: exclusions
        visible: root.showingExclusions
        width: parent.width
        spacing: Style.spacing.md

        Button {
          width: parent.width
          text: strings.t("back")
          bordered: true
          onClicked: root.showingExclusions = false
        }

        ButtonGroup {
          width: parent.width
          value: root.exclusionMode
          options: [
            { value: "apps", label: strings.t("apps") },
            { value: "windows", label: strings.t("windows") }
          ]
          onChanged: function(value) { root.exclusionMode = value }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t(root.exclusionMode === "apps" ? "excludeAppsHelp" : "excludeWindowsHelp")
          color: root.panelForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          visible: exclusionList.count > 0
          width: parent.width
          textFormat: Text.PlainText
          text: strings.tn(root.exclusionMode === "apps" ? "appCount" : "windowCount", exclusionList.count)
            .arg(Commons.I18n.formatNumber(exclusionList.count))
            .arg(root.exclusionMode === "windows" && root.currentWorkspace
              ? strings.t("workspace").arg(root.currentWorkspace.name) : root.screenName)
          color: root.panelForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        ListView {
          id: exclusionList
          width: parent.width
          height: Math.min(contentHeight, Style.space(410))
          visible: count > 0
          clip: true
          spacing: Style.spacing.xs
          model: root.showingExclusions ? root.exclusionChoices : []
          Controls.ScrollBar.vertical: Controls.ScrollBar {
            id: exclusionScrollBar
            policy: exclusionList.contentHeight > exclusionList.height
              ? Controls.ScrollBar.AlwaysOn : Controls.ScrollBar.AlwaysOff
          }
          delegate: Toggle {
            required property var modelData
            width: exclusionList.width - exclusionScrollBar.implicitWidth
            label: modelData.label
            description: modelData.app || ""
            checked: modelData.checked
            hasCursor: ListView.isCurrentItem
            enabled: !!root.service && (root.exclusionMode === "apps"
              ? root.service.profilesReady : !root.service.changingWindow)
            onClicked: root.toggleExclusion(modelData)
          }
        }

        Text {
          visible: !exclusionList.count || root.saveFailed || root.applyFailed
            || (!!root.service && (root.service.clientsFailed || root.service.windowChangeFailed))
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t(root.saveFailed ? "saveFailed" : root.applyFailed ? root.applyMessage
            : root.service && root.service.windowChangeFailed ? "windowChangeFailed"
            : root.service && root.service.clientsFailed ? "windowsFailed"
            : root.service && !root.service.clientsReady ? "loadingWindows"
            : root.exclusionMode === "windows" ? "noWindowsOnWorkspace" : "noApps")
          color: root.panelForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
