import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Item {
  id: root

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("sync.sh")).replace(/^file:\/\//, ""))
  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy"
  readonly property string profilesPath: configPath + "/window-fade-profiles.json"
  property var applied: null
  property bool failed: false
  property string applyMessage: ""
  property bool pending: false
  property var profileOverrides: ({})
  property bool profilesReady: false
  property bool profileSaveFailed: false
  property bool writingProfiles: false
  property int profileRevision: 0
  property int writingRevision: 0
  property var clients: []
  property bool clientsReady: false
  property bool clientsFailed: false
  property bool windowChangeFailed: false
  readonly property bool changingWindow: windowChange.running

  function refreshClients() {
    clientRefresh.restart()
  }

  function validWindowId(stableId) {
    // Hyprland exposes stable IDs as hexadecimal strings.
    return typeof stableId === "string" && /^[a-f0-9]{1,16}$/i.test(stableId)
  }

  function setWindowExcluded(screen, stableId, excluded) {
    if (changingWindow || !/^[A-Za-z0-9._-]+$/.test(screen) || !validWindowId(stableId))
      return
    const tag = (excluded ? "+" : "-") + "window-fade-exclude-" + screen
    windowChangeFailed = false
    windowChange.exec(["hyprctl", "dispatch",
      'hl.dsp.window.tag({ tag = "' + tag + '", window = "stableid:' + stableId + '" })'])
  }

  Timer {
    id: clientRefresh
    interval: 80
    onTriggered: {
      if (clientQuery.running || windowChange.running)
        restart()
      else
        clientQuery.running = true
    }
  }

  Process {
    id: clientQuery
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector { id: clientResult }
    onExited: function(code) {
      try {
        const value = code === 0 ? JSON.parse(clientResult.text) : null
        if (!Array.isArray(value))
          throw new Error("expected a window list")
        root.clients = value
        root.clientsReady = true
        root.clientsFailed = false
      } catch (error) {
        root.clientsFailed = true
      }
    }
  }

  Process {
    id: windowChange
    stdout: StdioCollector { id: windowChangeResult }
    onExited: function(code) {
      root.windowChangeFailed = code !== 0 || windowChangeResult.text.trim() !== "ok"
      root.refreshClients()
    }
  }

  function setProfile(screen, key, value) {
    if (!profilesReady || !screen)
      return

    const next = Object.assign({}, profileOverrides)
    next[screen] = Object.assign({}, next[screen] || {}, { [key]: value })
    // Every panel reads the same draft immediately. A slow write cannot send
    // another monitor's stale copy back to the widgets.
    profileOverrides = next
    profileRevision++
    writeProfiles()
  }

  function writeProfiles() {
    if (writingProfiles)
      return
    writingProfiles = true
    writingRevision = profileRevision
    profilesWriter.setText(JSON.stringify(profileOverrides, null, 2) + "\n")
  }

  function writeCompleted(success) {
    writingProfiles = false
    profileSaveFailed = !success
    if (success)
      applyDelay.restart()
    if (writingRevision !== profileRevision)
      Qt.callLater(root.writeProfiles)
  }

  FileView {
    id: profilesReader
    path: root.profilesPath
    preload: true
    printErrors: false
    onLoaded: {
      try {
        const value = JSON.parse(text())
        if (!value || typeof value !== "object" || Array.isArray(value))
          throw new Error("expected a monitor profile object")
        root.profileOverrides = value
        root.profilesReady = true
      } catch (error) {
        root.profileSaveFailed = true
        console.warn("Window Fade: could not load monitor profiles:", error)
      }
    }
    onLoadFailed: function(error) {
      root.profilesReady = error === FileViewError.FileNotFound
      root.profileSaveFailed = !root.profilesReady
    }
  }

  FileView {
    id: profilesWriter
    path: root.profilesPath
    preload: false
    atomicWrites: true
    onSaved: root.writeCompleted(true)
    onSaveFailed: root.writeCompleted(false)
  }

  function applySettings() {
    if (syncProcess.running) {
      pending = true
      return
    }
    syncProcess.running = true
  }

  FileView {
    path: root.configPath + "/shell.json"
    preload: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: applyDelay.restart()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (["configreloaded", "monitoradded", "monitoraddedv2", "monitorremoved"].includes(event.name))
        applyDelay.restart()
    }
  }

  Timer {
    id: applyDelay
    interval: 160
    onTriggered: root.applySettings()
  }

  Process {
    id: syncProcess
    command: ["bash", root.helper]
    stdout: StdioCollector { id: result }
    stderr: StdioCollector { id: diagnostics }
    onExited: function(code) {
      root.failed = code !== 0
      root.applyMessage = code === 69 ? "engineMissing" : code === 78 ? "engineIncompatible" : "applyFailed"
      if (root.failed)
        console.warn("Window Fade:", diagnostics.text.trim())
      else
        root.applied = JSON.parse(result.text)

      if (root.pending) {
        root.pending = false
        applyDelay.restart()
      }
    }
  }

  IpcHandler {
    target: "windowfade"
    function status(): string {
      return JSON.stringify({
        applied: root.applied,
        failed: root.failed,
        applyMessage: root.failed ? root.applyMessage : "",
        savingProfiles: root.writingProfiles,
        profileSaveFailed: root.profileSaveFailed
      })
    }
  }

  Component.onCompleted: applyDelay.restart()
  // After removal, reconcile against the persisted layout once the shell has saved it.
  Component.onDestruction: Quickshell.execDetached(["bash", root.helper, "--settle"])
}
