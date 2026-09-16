import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon plus popup for USB sticks, SD cards, NVMe/SATA internal drives, and portables.
//
// Features a modern frosted-card container layout with progressive disclosure:
// Essential info and primary actions are clean and uncluttered up front, while
// rich maintenance tools (dua Disk Usage, Terminal, Check, Format, Rename, NTFS Fix)
// expand smoothly in sleek inspector drawers.
Panel {
  id: root

  moduleName: "drives"
  ipcTarget: "drives"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool hasUnmountedNtfs: Model.hasUnmountedNtfs(root.devices)

  // Track expanded inspector drawers for progressive disclosure
  property string expandedDevicePath: ""
  property string expandedVolumePath: ""
  property var expandedTelemetry: ({})
  readonly property bool anyTelemetryOpen: Object.keys(expandedTelemetry).length > 0

  // Live filter search
  property bool searchOpen: false
  property string filterQuery: ""
  property string activeTab: "local"

  function isTelemetryExpanded(path) {
    if (!path) return false
    return !!expandedTelemetry[path]
  }

  function toggleTelemetry(path) {
    if (!path) return
    var next = Object.assign({}, expandedTelemetry)
    if (next[path]) {
      delete next[path]
    } else {
      next[path] = true
      drives.probeSmart(true)
    }
    expandedTelemetry = next
  }

  function toggleDeviceTools(path) {
    expandedDevicePath = (expandedDevicePath === path ? "" : path)
  }

  function toggleVolumeDrawer(path) {
    expandedVolumePath = (expandedVolumePath === path ? "" : path)
  }

  function runNtfsFix(path) {
    var cmd = path && path !== "" ? "omarchy-ntfs-fix " + path : "omarchy-ntfs-fix"
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
    } else {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    }
  }

  function launchFormat(devicePath) {
    if (!devicePath || devicePath === "") return
    var cmd = "omarchy-drive-format '" + devicePath + "'"
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
    } else {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    }
  }

  function runSpeedTest(mountpoint) {
    var cmd = "omarchy-disk-speedtest '" + (mountpoint || "/tmp") + "'"
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
    } else {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    }
  }

  function runBtrfsScrub(mountpoint) {
    var cmd = "omarchy-drive-scrub '" + (mountpoint || "/") + "'"
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
    } else {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    }
  }

  function runTrim(mountpoint) {
    var cmd = "omarchy-drive-trim '" + (mountpoint || "/") + "'"
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
    } else {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    }
  }

  function runFlash(devicePath) {
    var cmd = "omarchy-drive-flash '" + (devicePath || "") + "'"
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
    } else {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    }
  }

  function runRecovery(targetPath) {
    var cmd = "omarchy-drive-recover '" + (targetPath || "") + "'"
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
    } else {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    }
  }

  function deviceMatchesFilter(device, query) {
    if (!device) return false
    if (!query || query === "") return true
    var q = query.toLowerCase()
    if (device.title && device.title.toLowerCase().indexOf(q) !== -1) return true
    if (device.path && device.path.toLowerCase().indexOf(q) !== -1) return true
    if (device.name && device.name.toLowerCase().indexOf(q) !== -1) return true
    if (device.volumes) {
      for (var i = 0; i < device.volumes.length; i++) {
        if (volumeMatchesFilter(device.volumes[i], query, device)) return true
      }
    }
    return false
  }

  function volumeMatchesFilter(volume, query, device) {
    if (!volume) return false
    if (!query || query === "") return true
    var q = query.toLowerCase()
    if (device) {
      if (device.title && device.title.toLowerCase().indexOf(q) !== -1) return true
      if (device.path && device.path.toLowerCase().indexOf(q) !== -1) return true
      if (device.name && device.name.toLowerCase().indexOf(q) !== -1) return true
    }
    if (volume.title && volume.title.toLowerCase().indexOf(q) !== -1) return true
    if (volume.label && volume.label.toLowerCase().indexOf(q) !== -1) return true
    if (volume.fstype && volume.fstype.toLowerCase().indexOf(q) !== -1) return true
    if (volume.mountpoint && volume.mountpoint.toLowerCase().indexOf(q) !== -1) return true
    if (volume.fsPath && volume.fsPath.toLowerCase().indexOf(q) !== -1) return true
    return false
  }

  readonly property int matchingDeviceCount: {
    if (!filterQuery || filterQuery === "") return devices.length
    var count = 0
    for (var i = 0; i < devices.length; i++) {
      if (deviceMatchesFilter(devices[i], filterQuery)) count++
    }
    return count
  }

  function networkShareMatchesFilter(share, query) {
    if (!share) return false
    if (!query || query === "") return true
    var q = query.toLowerCase()
    if (share.title && share.title.toLowerCase().indexOf(q) !== -1) return true
    if (share.mountpoint && share.mountpoint.toLowerCase().indexOf(q) !== -1) return true
    if (share.source && share.source.toLowerCase().indexOf(q) !== -1) return true
    if (share.server && share.server.toLowerCase().indexOf(q) !== -1) return true
    if (share.fstype && share.fstype.toLowerCase().indexOf(q) !== -1) return true
    return false
  }

  readonly property int matchingNetworkCount: {
    if (!filterQuery || filterQuery === "") return drives.networkCount
    var count = 0
    for (var i = 0; i < drives.networkShares.length; i++) {
      if (networkShareMatchesFilter(drives.networkShares[i], filterQuery)) count++
    }
    return count
  }

  readonly property bool alwaysShow: setting("alwaysShow", false) === true
  readonly property bool openOnMount: setting("openOnMount", true) === true

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property string labelMode: vertical ? "none" : String(setting("barLabel", "none"))
  readonly property string barLabel: Model.barLabelText(devices, labelMode)
  readonly property string barTooltip: drives.anyBusy
    ? (Model.formatRate(drives.totalWriteRate) !== ""
        ? "Writing " + Model.formatRate(drives.totalWriteRate) + " — do not remove"
        : "Busy — do not remove")
    : Model.summary(devices)

  // Key of the drive whose nickname is being edited inline, "" when none is.
  property string renamingKey: ""

  // fsPath of the volume whose filesystem label is being edited, "" when none is.
  property string renamingLabelPath: ""

  // fsPath of the locked volume whose passphrase is being typed, "" when none is.
  property string unlockingPath: ""

  // fsPath of the volume whose format is being set up, "" when none is.
  property string formattingPath: ""
  property string formatType: ""
  property bool formatQuick: true

  readonly property var devices: drives.devices
  readonly property var rows: Model.navRows(drives.devices, drives.portables)
  property int cursor: 0
  property bool cursorActive: false
  property Item cursorItem: null

  readonly property var currentRow: rows.length > 0
    ? rows[Math.max(0, Math.min(cursor, rows.length - 1))]
    : null

  function currentDevice() {
    if (!currentRow) return null
    return devices[currentRow.device] || null
  }

  function currentPortable() {
    if (!currentRow || currentRow.kind !== "portable") return null
    return drives.portables[currentRow.portable] || null
  }

  function currentVolume() {
    if (!currentRow || currentRow.kind !== "volume") return null
    var device = devices[currentRow.device]
    return device ? (device.volumes[currentRow.volume] || null) : null
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy === 0 || rows.length === 0) return
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + dy))
    scrollCursorIntoView()
  }

  function setCursor(index) {
    cursorActive = true
    cursor = Math.max(0, Math.min(Math.max(0, rows.length - 1), index))
  }

  function clampCursor() {
    if (rows.length === 0) {
      cursor = 0
      return
    }
    if (cursor > rows.length - 1) cursor = rows.length - 1
  }

  function rowIndexOfDevice(deviceIndex) {
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].kind === "device" && rows[i].device === deviceIndex) return i
    }
    return 0
  }

  function rowIndexOfVolume(deviceIndex, volumeIndex) {
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].kind === "volume" && rows[i].device === deviceIndex && rows[i].volume === volumeIndex) return i
    }
    return 0
  }

  function rowIndexOfPortable(portableIndex) {
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].kind === "portable" && rows[i].portable === portableIndex) return i
    }
    return 0
  }

  function activateCursor() {
    if (!currentRow) return
    if (currentRow.kind === "device") drives.eject(currentDevice())
    else if (currentRow.kind === "portable") activatePortable(currentPortable())
    else activateVolume(currentVolume())
  }

  function activatePortable(entry) {
    if (!entry) return
    drives.openPortable(entry)
  }

  function handleBarPress(buttonCode) {
    if (buttonCode === Qt.RightButton) {
      drives.refresh()
    } else if (buttonCode === Qt.MiddleButton) {
      var mounted = Model.mountedVolumes(devices)
      if (mounted.length > 0) drives.openVolume(mounted[0])
    } else {
      toggle()
    }
  }

  function beginRename(device) {
    if (!device) return
    expandedDevicePath = device.path
    renamingKey = device.key
  }

  function finishRename() {
    renamingKey = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function beginUnlock(volume) {
    if (!volume || !Model.canUnlock(volume)) return
    expandedVolumePath = volume.fsPath
    renamingKey = ""
    renamingLabelPath = ""
    formattingPath = ""
    unlockingPath = volume.fsPath
  }

  function finishUnlock() {
    unlockingPath = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function beginLabelEdit(volume) {
    if (!volume || !Model.canRelabel(volume)) return
    expandedVolumePath = volume.fsPath
    renamingKey = ""
    formattingPath = ""
    renamingLabelPath = volume.fsPath
  }

  function finishLabelEdit() {
    renamingLabelPath = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function beginFormat(volume) {
    if (!volume) return
    if (Model.canFormat(drives.fsCapabilities, volume, drives.deviceOfVolume(volume)) !== null) return
    expandedVolumePath = volume.fsPath
    renamingKey = ""
    renamingLabelPath = ""
    unlockingPath = ""
    var types = Model.formatTypes(drives.fsCapabilities)
    formatType = types.indexOf(volume.fstype) !== -1 ? volume.fstype : (types.length > 0 ? types[0] : "")
    formatQuick = true
    formattingPath = volume.fsPath
  }

  function finishFormat() {
    formattingPath = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function activateVolume(volume) {
    if (!volume) return
    if (volume.mounted) drives.openVolume(volume)
    else if (!volume.isSystem && Model.canUnlock(volume)) beginUnlock(volume)
    else if (!volume.isSystem) drives.mount(volume, openOnMount)
  }

  function ejectCurrent() {
    var device = currentDevice()
    if (device && !device.isSystem) drives.eject(device)
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    Qt.callLater(function() { scrollItemIntoView(root.cursorItem) })
  }

  visible: devices.length > 0 || drives.portables.length > 0 || drives.supportHint !== null || alwaysShow
  implicitWidth: button.item ? button.item.implicitWidth : 0
  implicitHeight: button.item ? button.item.implicitHeight : barSize

  onVisibleChanged: if (!visible && opened) close()
  onRowsChanged: {
    clampCursor()
    var i
    if (renamingKey !== "") {
      var stillHere = false
      for (i = 0; i < devices.length; i++) {
        if (devices[i].key === renamingKey) stillHere = true
      }
      if (!stillHere) renamingKey = ""
    }
    if (renamingLabelPath !== "" && !drives.volumeByPath(renamingLabelPath)) renamingLabelPath = ""
    if (formattingPath !== "" && !drives.volumeByPath(formattingPath)) formattingPath = ""
    if (unlockingPath !== "") {
      var lockedHere = false
      for (i = 0; i < devices.length; i++) {
        for (var u = 0; u < devices[i].volumes.length; u++) {
          var candidate = devices[i].volumes[u]
          if (candidate.fsPath === unlockingPath && Model.canUnlock(candidate)) lockedHere = true
        }
      }
      if (!lockedHere) unlockingPath = ""
    }
  }

  onOpenedChanged: {
    drives.watchClosely = opened
    renamingKey = ""
    renamingLabelPath = ""
    unlockingPath = ""
    formattingPath = ""
    if (opened) {
      cursorActive = false
      cursor = 0
      if (panelFlick) panelFlick.contentY = 0
      drives.refresh()
      drives.refreshPortables()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      expandedTelemetry = ({})
    }
  }

  Service {
    id: drives
    settings: root.settings
    telemetryActive: root.anyTelemetryOpen
  }

  IpcHandler {
    target: root.ipcTarget

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh(): string { drives.refresh(); return "ok" }
    function list(): string { return JSON.stringify(drives.devices) }

    function eject(path: string): string {
      for (var i = 0; i < drives.devices.length; i++) {
        if (drives.devices[i].path === path) {
          drives.eject(drives.devices[i])
          return "ok"
        }
      }
      return "unknown device: " + path
    }

    function rename(path: string, nickname: string): string {
      for (var i = 0; i < drives.devices.length; i++) {
        if (drives.devices[i].path === path) {
          drives.setNickname(drives.devices[i], nickname)
          return "ok"
        }
      }
      return "unknown device: " + path
    }

    function lock(path: string): string {
      var volume = drives.volumeByPath(path)
      if (!volume) return "unknown volume: " + path
      return drives.lock(volume)
    }

    function mountReadOnly(path: string): string {
      var volume = drives.volumeByPath(path)
      if (!volume) return "unknown volume: " + path
      return drives.mountReadOnly(volume)
    }

    function label(path: string, name: string): string {
      var volume = drives.volumeByPath(path)
      if (!volume) return "unknown volume: " + path
      return drives.setVolumeLabel(volume, name)
    }

    function check(path: string): string {
      var volume = drives.volumeByPath(path)
      if (!volume) return "unknown volume: " + path
      return drives.checkVolume(volume)
    }

    function format(path: string, fstype: string, name: string): string {
      var volume = drives.volumeByPath(path)
      if (!volume) return "unknown volume: " + path
      return drives.formatVolume(volume, fstype, name, true)
    }

    function phones(): string { return JSON.stringify(drives.portables) }
    function network(): string { return JSON.stringify(drives.networkShares) }

    function smart(path: string): string {
      for (var i = 0; i < drives.devices.length; i++) {
        if (drives.devices[i].path === path) {
          return JSON.stringify(drives.smartFor(drives.devices[i]) || Model.parseSmart(""))
        }
      }
      return "unknown device: " + path
    }

    function ejectAll(): string {
      if (drives.devices.length === 0) return "no drives attached"
      drives.ejectAll()
      return "ok"
    }

    function expandVolume(path: string): string {
      root.expandedVolumePath = path
      return "ok"
    }

    function expandDevice(path: string): string {
      root.expandedDevicePath = path
      return "ok"
    }

    function toggleTelemetry(path: string): string {
      root.toggleTelemetry(path)
      return "ok"
    }

    function setTab(tab: string): string {
      if (tab === "local" || tab === "network") {
        root.activeTab = tab
        return "ok"
      }
      return "invalid tab: " + tab
    }

    function status(): string {
      return JSON.stringify({
        open: root.opened,
        devices: drives.deviceCount,
        mounted: drives.mountedCount,
        busy: drives.anyBusy,
        writeRate: Math.round(drives.totalWriteRate),
        pendingEject: drives.pendingEjectPath,
        working: drives.busy,
        checked: drives.checkedFsPath,
        healthy: drives.checkVerdict,
        hooks: drives.hookReport(),
        health: drives.healthReport()
      })
    }
  }

  Loader {
    id: button
    anchors.fill: parent
    sourceComponent: root.labelMode !== "none" && root.barLabel !== "" ? labelledButton : iconButton
  }

  Component {
    id: iconButton

    BarIconButton {
      anchors.fill: parent
      bar: root.bar
      text: Model.barGlyph(root.devices)
      tooltipText: root.hasUnmountedNtfs
        ? root.barTooltip + " · Unmounted NTFS partitions detected (click to manage/fix)"
        : root.barTooltip
      active: drives.anyBusy || root.hasUnmountedNtfs
      activeColor: drives.anyBusy ? root.urgent : (bar && "activeColor" in bar ? bar.activeColor : root.foreground)
      useActiveColor: true
      onPressed: function(buttonCode) { root.handleBarPress(buttonCode) }
    }
  }

  Component {
    id: labelledButton

    WidgetButton {
      anchors.fill: parent
      bar: root.bar
      text: Model.barGlyph(root.devices) + "  " + root.barLabel
      tooltipText: root.hasUnmountedNtfs
        ? root.barTooltip + " · Unmounted NTFS partitions detected (click to manage/fix)"
        : root.barTooltip
      active: drives.anyBusy || root.hasUnmountedNtfs
      activeColor: drives.anyBusy ? root.urgent : (bar && "activeColor" in bar ? bar.activeColor : root.foreground)
      useActiveColor: true
      onPressed: function(buttonCode) { root.handleBarPress(buttonCode) }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.renamingKey !== "" || root.renamingLabelPath !== ""
        || root.unlockingPath !== "" || root.formattingPath !== ""

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          return
        }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onDeleteRequested: root.ejectCurrent()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") drives.rescan()
        else if (text === "e") root.ejectCurrent()
        else if (text === "E") drives.ejectAll()
        else if (text === "o" || text === "O") drives.openVolume(root.currentVolume())
        else if (text === "t" || text === "T") drives.openTerminal(root.currentVolume())
        else if (text === "d" || text === "D") drives.openDiskUsage(root.currentVolume())
        else if (text === "s" || text === "S") drives.setShowSystemDrives(!drives.showSystemDrives)
        else if (text === "y" || text === "Y") drives.copyPath(root.currentVolume())
        else if (text === "n" || text === "N") root.beginRename(root.currentDevice())
        else if (text === "l" || text === "L") root.beginLabelEdit(root.currentVolume())
        else if (text === "c" || text === "C") drives.checkVolume(root.currentVolume())
        else if (text === "f" || text === "F") {
          var vol = root.currentVolume()
          if (vol && !vol.isSystem) root.launchFormat(vol.fsPath || vol.path)
          else {
            var dev = root.currentDevice()
            if (dev && !dev.isSystem) root.launchFormat(dev.path)
          }
        }
        else if (text === "m" || text === "M") {
          if (root.currentRow && root.currentRow.kind === "portable") drives.togglePortable(root.currentPortable())
          else {
            var mVol = root.currentVolume()
            if (mVol && !mVol.isSystem) drives.toggleMount(mVol, root.openOnMount)
          }
        }
        else if (text === "w" || text === "W") {
          root.activeTab = (root.activeTab === "local" ? "network" : "local")
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ------------------------------------------------------------ Hero
          PanelHero {
            id: hero
            width: parent.width
            title: root.activeTab === "network" ? "Network Storage" : "Drives"
            meta: root.activeTab === "network"
              ? (drives.networkCount === 0 ? "No active network mounts" : drives.networkCount + " mounted network / cloud " + (drives.networkCount === 1 ? "share" : "shares"))
              : (drives.anyBusy
                  ? (Model.formatRate(drives.totalWriteRate) !== ""
                      ? "Writing " + Model.formatRate(drives.totalWriteRate) + " — do not remove"
                      : "Busy — do not remove")
                  : Model.summary(root.devices))
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.activeTab === "network" ? Model.GLYPH_SERVER : Model.barGlyph(root.devices)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(2)

                PanelActionButton {
                  visible: root.hasUnmountedNtfs
                  iconText: Model.GLYPH_WRENCH
                  tooltipText: "Fix & Mount All NTFS Partitions"
                  foreground: root.urgent
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.runNtfsFix("")
                }

                PanelActionButton {
                  visible: root.devices.length > 1
                  iconText: Model.GLYPH_EJECT
                  tooltipText: "Eject every removable drive"
                  foreground: root.foreground
                  hoverColor: root.urgent
                  fontFamily: root.fontFamily
                  enabled: !drives.busy
                  onClicked: drives.ejectAll()
                }

                PanelActionButton {
                  iconText: drives.showSystemDrives ? Model.GLYPH_DISK : Model.GLYPH_SD
                  tooltipText: drives.showSystemDrives ? "Hide internal storage (removable only)" : "Show all storage drives (including OS & Swap)"
                  foreground: drives.showSystemDrives ? root.foreground : root.dim
                  fontFamily: root.fontFamily
                  onClicked: drives.setShowSystemDrives(!drives.showSystemDrives)
                }

                PanelActionButton {
                  iconText: Model.GLYPH_REFRESH
                  tooltipText: "Rescan"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !drives.refreshing
                  onClicked: drives.rescan()
                }

                PanelActionButton {
                  iconText: Model.GLYPH_SEARCH
                  tooltipText: root.searchOpen ? "Hide search filter (/)" : "Search & filter drives and partitions (/)"
                  foreground: (root.searchOpen || root.filterQuery !== "") ? (bar && "activeColor" in bar ? bar.activeColor : root.foreground) : root.dim
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: {
                    root.searchOpen = !root.searchOpen
                    if (!root.searchOpen) root.filterQuery = ""
                  }
                }
              }
            }
          }

          // Live Search Filter Input
          Rectangle {
            visible: root.searchOpen || root.filterQuery !== ""
            width: parent.width
            implicitHeight: searchRowLayout.implicitHeight + Style.space(8)
            radius: Style.space(6)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            RowLayout {
              id: searchRowLayout
              anchors.fill: parent
              anchors.margins: Style.space(4)
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: Model.GLYPH_SEARCH
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconSmall
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: Style.space(4)
              }

              TextField {
                id: searchInputField
                Layout.fillWidth: true
                foreground: root.foreground
                verticalPadding: Style.space(2)
                placeholderText: "Search drives, labels, filesystems..."
                text: root.filterQuery
                onTextChanged: root.filterQuery = text
                onVisibleChanged: if (visible) Qt.callLater(function() { searchInputField.forceActiveFocus() })
                Keys.onEscapePressed: {
                  root.filterQuery = ""
                  root.searchOpen = false
                  keyCatcher.forceActiveFocus()
                }
              }

              PanelActionButton {
                visible: root.filterQuery !== ""
                iconText: Model.GLYPH_ALERT
                tooltipText: "Clear search filter"
                foreground: root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                size: Style.space(20)
                onClicked: {
                  root.filterQuery = ""
                  searchInputField.text = ""
                }
              }
            }
          }

          // ------------------------------------------------------------ Storage Tabs Selector
          Rectangle {
            width: parent.width
            implicitHeight: Style.space(34)
            radius: Style.space(8)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

            RowLayout {
              anchors.fill: parent
              anchors.margins: Style.space(3)
              spacing: Style.space(4)

              // Tab 1: Local Drives
              Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: Style.space(6)
                color: root.activeTab === "local"
                  ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                  : (localTabHover.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05) : "transparent")
                border.width: root.activeTab === "local" ? 1 : 0
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)

                RowLayout {
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: Model.GLYPH_DISK
                    color: root.activeTab === "local" ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    Layout.alignment: Qt.AlignVCenter
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "Drives (" + root.devices.length + ")"
                    color: root.activeTab === "local" ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: root.activeTab === "local"
                    Layout.alignment: Qt.AlignVCenter
                  }
                }

                MouseArea {
                  id: localTabHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.activeTab = "local"
                }
              }

              // Tab 2: Network & Cloud Storage
              Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: Style.space(6)
                color: root.activeTab === "network"
                  ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                  : (netTabHover.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05) : "transparent")
                border.width: root.activeTab === "network" ? 1 : 0
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)

                RowLayout {
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: Model.GLYPH_SERVER
                    color: root.activeTab === "network" ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    Layout.alignment: Qt.AlignVCenter
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "Network & Cloud (" + drives.networkCount + ")"
                    color: root.activeTab === "network" ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: root.activeTab === "network"
                    Layout.alignment: Qt.AlignVCenter
                  }
                }

                MouseArea {
                  id: netTabHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.activeTab = "network"
                }
              }
            }
          }

          // ------------------------------------------------------------ Global Alerts
          // NTFS Alert Banner
          Rectangle {
            visible: root.activeTab === "local" && root.hasUnmountedNtfs
            width: parent.width
            implicitHeight: ntfsAlertRow.implicitHeight + Style.space(12)
            radius: Style.space(6)
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.12)
            border.width: 1
            border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35)

            RowLayout {
              id: ntfsAlertRow
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: Model.GLYPH_ALERT
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                Layout.alignment: Qt.AlignVCenter
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "Unmounted NTFS partition(s) detected"
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "Windows dirty bit may prevent mounting. Auto-repair is ready."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              ActionChip {
                iconText: Model.GLYPH_WRENCH
                label: "Fix All"
                danger: true
                tooltipText: "Run omarchy-ntfs-fix on all NTFS partitions"
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.runNtfsFix("")
              }
            }
          }

          // Status & Error Text
          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: drives.lastError !== "" ? drives.lastError : drives.actionStatus
            color: drives.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // In-use Blocker Banner
          RowLayout {
            visible: drives.blockers.length > 0
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "Held by " + Model.describeBlockers(drives.blockers)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            PanelActionButton {
              iconText: Model.GLYPH_UNMOUNT
              tooltipText: "Unmount anyway (lazy unmount)"
              foreground: root.foreground
              hoverColor: root.urgent
              fontFamily: root.fontFamily
              enabled: !drives.busy && drives.blockedFsPath !== ""
              Layout.alignment: Qt.AlignVCenter
              onClicked: drives.forceUnmountBlocked()
            }
          }

          // Pending Eject Banner
          RowLayout {
            visible: drives.pendingEjectPath !== ""
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "Ejecting once writes finish…"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            PanelActionButton {
              iconText: Model.GLYPH_ALERT
              tooltipText: "Cancel eject"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.alignment: Qt.AlignVCenter
              onClicked: drives.cancelPendingEject()
            }
          }

          // Repair Offered Notice
          RowLayout {
            visible: drives.repairOffered
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "Repairing rewrites the filesystem. Copy anything you need off it first."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            PanelActionButton {
              iconText: Model.GLYPH_READONLY
              tooltipText: "Mount read-only so files can be copied off safely"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !drives.busy && drives.repairOffered
              Layout.alignment: Qt.AlignVCenter
              onClicked: drives.mountReadOnly(drives.volumeByPath(drives.checkedFsPath))
            }

            PanelActionButton {
              iconText: Model.GLYPH_WRENCH
              tooltipText: "Repair this filesystem"
              foreground: root.foreground
              hoverColor: root.urgent
              fontFamily: root.fontFamily
              enabled: !drives.busy && drives.repairOffered
                && Model.canRepair(drives.fsCapabilities, drives.volumeByPath(drives.checkedFsPath))
              Layout.alignment: Qt.AlignVCenter
              onClicked: drives.repairVolume(drives.volumeByPath(drives.checkedFsPath))
            }
          }

          // Empty State
          Text {
            textFormat: Text.PlainText
            visible: root.activeTab === "local" && root.devices.length === 0 && drives.portables.length === 0
            width: parent.width
            text: drives.loaded ? "No drives detected." : "Looking for drives…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(20)
            bottomPadding: Style.space(20)
          }

          // Filter Empty State
          Text {
            textFormat: Text.PlainText
            visible: root.activeTab === "local" && root.filterQuery !== "" && root.matchingDeviceCount === 0 && root.devices.length > 0
            width: parent.width
            text: "No drives matching \"" + root.filterQuery + "\""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(20)
            bottomPadding: Style.space(20)
          }

          // ------------------------------------------------------------ Storage Cards
          Repeater {
            model: root.activeTab === "local" ? root.devices : []

            StorageCard {
              id: storageCard
              required property var modelData
              required property int index

              width: column.width
              device: modelData
              deviceIndex: index
              visible: !!root.deviceMatchesFilter(modelData, root.filterQuery)
            }
          }

          // ------------------------------------------------------------ Phones & Cameras
          Column {
            visible: root.activeTab === "local" && (drives.portables.length > 0 || drives.supportHint !== null)
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "PHONES & CAMERAS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // Support Hint
            RowLayout {
              visible: drives.supportHint !== null
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: Model.GLYPH_ALERT
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
                Layout.alignment: Qt.AlignVCenter
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: drives.supportHint ? drives.supportHint.text : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: drives.supportHint ? "Installs " + drives.supportHint.detail : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              PanelActionButton {
                iconText: Model.GLYPH_MOUNT
                tooltipText: "Open Omarchy's installer for these packages"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: drives.installSupport()
              }
            }

            Repeater {
              model: drives.portables

              PortableCard {
                required property var modelData
                required property int index

                width: parent.width
                entry: modelData
                portableIndex: index
              }
            }
          }

          // ------------------------------------------------------------ Network & Cloud Storage
          // Network Empty State
          Column {
            visible: root.activeTab === "network" && drives.networkCount === 0
            width: parent.width
            spacing: Style.space(6)
            topPadding: Style.space(24)
            bottomPadding: Style.space(24)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: Model.GLYPH_SERVER
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "No network or cloud shares mounted"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "NFS, Samba/CIFS, SSHFS, Rclone, and DAVFS endpoints appear here automatically when mounted."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }

          // Network Filter Empty State
          Text {
            textFormat: Text.PlainText
            visible: root.activeTab === "network" && root.filterQuery !== "" && root.matchingNetworkCount === 0 && drives.networkCount > 0
            width: parent.width
            text: "No network shares matching \"" + root.filterQuery + "\""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(20)
            bottomPadding: Style.space(20)
          }

          // Network Share Cards
          Repeater {
            model: root.activeTab === "network" ? drives.networkShares : []

            NetworkShareCard {
              required property var modelData
              required property int index

              width: column.width
              share: modelData
              shareIndex: index
              visible: !!root.networkShareMatchesFilter(modelData, root.filterQuery)
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ Reusable UI Components

  // Compact, elegant action chip / tile
  component ActionChip: Rectangle {
    id: chip
    property string iconText: ""
    property string label: ""
    property string tooltipText: ""
    property color foreground: root.foreground
    property color hoverColor: foreground
    property color activeColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
    property bool danger: false
    property bool active: false
    signal clicked()

    implicitHeight: Style.space(28)
    implicitWidth: chipRow.implicitWidth + Style.space(18)
    radius: Style.space(5)
    color: chipMouse.containsMouse
      ? (danger ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.18) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12))
      : (active ? activeColor : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04))
    border.width: 1
    border.color: chipMouse.containsMouse
      ? (danger ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.45) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22))
      : (danger ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.25) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08))

    Behavior on color { ColorAnimation { duration: 60 } }

    RowLayout {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        text: chip.iconText
        color: chip.danger ? root.urgent : (chipMouse.containsMouse ? chip.hoverColor : chip.foreground)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        textFormat: Text.PlainText
        text: chip.label
        color: chip.danger ? root.urgent : (chipMouse.containsMouse ? chip.hoverColor : chip.foreground)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        Layout.alignment: Qt.AlignVCenter
      }
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }

    PanelToolTip {
      visible: chip.tooltipText !== "" && chipMouse.containsMouse
      text: chip.tooltipText
      fontFamily: root.fontFamily
    }
  }

  // Filesystem pill badge
  component FsPill: Rectangle {
    id: pill
    property string text: ""
    property bool urgentColor: false
    implicitWidth: pillText.implicitWidth + Style.space(10)
    implicitHeight: pillText.implicitHeight + Style.space(3)
    radius: Style.space(4)
    color: urgentColor
      ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.16)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
    border.width: 1
    border.color: urgentColor
      ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.45)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

    Text {
      id: pillText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: pill.text.toUpperCase()
      color: pill.urgentColor ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // ------------------------------------------------------------ StorageCard Component
  component StorageCard: Rectangle {
    id: storageCardRoot
    property var device: null
    property int deviceIndex: 0

    readonly property bool isExpanded: root.expandedDevicePath === (device ? device.path : "")
    readonly property bool isSystem: device && device.isSystem === true

    readonly property bool selected: root.cursorActive && root.currentRow
      && root.currentRow.kind === "device" && root.currentRow.device === deviceIndex
    onSelectedChanged: if (selected) root.cursorItem = devHeaderSurface
    readonly property string activity: device ? drives.activityLabelFor(device) : ""
    readonly property bool renaming: device && device.key !== "" && root.renamingKey === device.key

    readonly property var autoOpen: Model.autoOpenPolicy(Model.driveSettings(drives.store, device).autoOpen)
    readonly property bool mountsReadOnly: Model.shouldMountReadOnly(drives.store, device)
    readonly property bool ejectPending: device
      && (drives.pendingEjectPath === device.path || drives.pendingEjectPath === "*")

    readonly property var hook: device ? drives.hookStateFor(device) : null
    readonly property string hookText: device ? drives.hookLabelFor(device) : ""
    readonly property string healthVerdict: device ? drives.smartVerdictFor(device) : "unsupported"
    readonly property string healthText: device ? drives.smartHintFor(device) : ""

    readonly property var smartData: device ? drives.smartFor(device) : null
    readonly property var tempHistory: device ? drives.tempHistoryFor(device) : []
    readonly property var tempStats: device ? drives.tempStatsFor(device) : null
    readonly property bool hasTemp: !!(smartData && smartData.temperatureC !== null && smartData.temperatureC !== undefined)
    readonly property bool showTelemetry: root.isTelemetryExpanded(device ? device.path : "")

    radius: Style.space(10)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
    border.width: 1
    border.color: selected
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09)

    implicitHeight: visible ? (cardLayout.implicitHeight + Style.space(16)) : 0

    function commitRename(value) {
      drives.setNickname(device, value)
      root.finishRename()
    }
    function cancelRename() { root.finishRename() }

    ColumnLayout {
      id: cardLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(8)

      // Device Card Header
      CursorSurface {
        id: devHeaderSurface
        Layout.fillWidth: true
        hasCursor: storageCardRoot.selected
        foreground: root.foreground
        implicitHeight: devHeaderRow.implicitHeight + Style.space(4)

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          onEntered: root.setCursor(root.rowIndexOfDevice(storageCardRoot.deviceIndex))
        }

        RowLayout {
          id: devHeaderRow
          anchors.fill: parent
          spacing: Style.space(8)

          // Device Icon Container
          Rectangle {
            implicitWidth: Style.space(32)
            implicitHeight: Style.space(32)
            radius: Style.space(6)
            color: storageCardRoot.isSystem
              ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.12)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
            border.width: 1
            border.color: storageCardRoot.isSystem
              ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.3)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
            Layout.alignment: Qt.AlignVCenter

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: storageCardRoot.device ? storageCardRoot.device.glyph : Model.GLYPH_DISK
              color: storageCardRoot.isSystem ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
            }
          }

          // Device Details
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                visible: !storageCardRoot.renaming
                Layout.fillWidth: true
                text: storageCardRoot.device ? storageCardRoot.device.title : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              // OS Drive / Swap Guard Pill
              Rectangle {
                visible: storageCardRoot.isSystem
                implicitWidth: osDevTag.implicitWidth + Style.space(12)
                implicitHeight: osDevTag.implicitHeight + Style.space(4)
                radius: Style.space(3)
                color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.16)
                border.width: 1
                border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.45)
                Layout.alignment: Qt.AlignVCenter

                RowLayout {
                  anchors.centerIn: parent
                  spacing: Style.space(3)

                  Text {
                    textFormat: Text.PlainText
                    text: Model.GLYPH_LOCKED
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    id: osDevTag
                    textFormat: Text.PlainText
                    text: storageCardRoot.device && storageCardRoot.device.name && storageCardRoot.device.name.indexOf("zram") === 0
                      ? "SWAP" : "OS DRIVE"
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }
            }

            // Inline nickname editor
            TextField {
              id: devNameField
              visible: storageCardRoot.renaming
              Layout.fillWidth: true
              foreground: root.foreground
              verticalPadding: Style.space(2)
              placeholderText: storageCardRoot.device ? storageCardRoot.device.deviceName : ""
              onVisibleChanged: if (visible) {
                text = storageCardRoot.device && storageCardRoot.device.nickname !== "" ? storageCardRoot.device.nickname : ""
                Qt.callLater(function() { devNameField.forceActiveFocus(); devNameField.selectAll() })
              }
              onAccepted: storageCardRoot.commitRename(text)
              Keys.onEscapePressed: storageCardRoot.cancelRename()
            }

            // Subtitle info line
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: {
                  if (!storageCardRoot.device) return ""
                  var parts = []
                  if (storageCardRoot.device.sizeText !== "") parts.push(storageCardRoot.device.sizeText)
                  if (storageCardRoot.device.tran !== "") parts.push(storageCardRoot.device.tran.toUpperCase())
                  if (storageCardRoot.device.volumes.length === 0 && !storageCardRoot.isSystem) parts.push("No media inserted")
                  if (storageCardRoot.activity !== "") parts.push(storageCardRoot.activity)
                  return parts.join(" · ")
                }
                color: storageCardRoot.activity !== "" ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Text {
                visible: storageCardRoot.mountsReadOnly
                textFormat: Text.PlainText
                text: "· Read-Only Mode"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // Health Warning
            Text {
              textFormat: Text.PlainText
              visible: storageCardRoot.healthVerdict === "warning" || storageCardRoot.healthVerdict === "failing"
              Layout.fillWidth: true
              text: storageCardRoot.healthText
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Hook Activity
            Text {
              textFormat: Text.PlainText
              visible: storageCardRoot.hookText !== ""
              Layout.fillWidth: true
              text: storageCardRoot.hookText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            // Hook Progress Bar
            Rectangle {
              visible: storageCardRoot.hook !== null && storageCardRoot.hook.active && storageCardRoot.hook.percent !== null
              Layout.fillWidth: true
              implicitHeight: Math.max(2, Style.space(3))
              radius: height / 2
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

              Rectangle {
                readonly property real fraction: storageCardRoot.hook && storageCardRoot.hook.percent !== null
                  ? storageCardRoot.hook.percent / 100 : 0
                width: Math.max(parent.width > 0 && fraction > 0 ? 2 : 0, parent.width * fraction)
                height: parent.height
                radius: parent.radius
                color: root.foreground
                opacity: 0.65
                Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
              }
            }
          }

          // Header Right Action Controls
          Row {
            spacing: Style.space(2)
            Layout.alignment: Qt.AlignVCenter

            // Telemetry & Health Drawer Toggle Button (Pointing Up/Down Chevron)
            PanelActionButton {
              visible: true
              iconText: storageCardRoot.showTelemetry ? Model.GLYPH_CHEVRON_UP : Model.GLYPH_CHEVRON_DOWN
              tooltipText: storageCardRoot.showTelemetry
                ? "Hide health & temperature telemetry"
                : "Show health & temperature telemetry"
              foreground: storageCardRoot.showTelemetry
                ? (bar && "activeColor" in bar ? bar.activeColor : root.foreground)
                : root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleTelemetry(storageCardRoot.device ? storageCardRoot.device.path : "")
            }

            // Device Tools Drawer Toggle Button
            PanelActionButton {
              visible: true
              iconText: Model.GLYPH_COG
              tooltipText: storageCardRoot.isExpanded ? "Hide drive settings" : "Drive settings & tools"
              foreground: storageCardRoot.isExpanded ? (bar && "activeColor" in bar ? bar.activeColor : root.foreground) : root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleDeviceTools(storageCardRoot.device.path)
            }

            // Quick Eject Button
            PanelActionButton {
              visible: !storageCardRoot.isSystem
              iconText: Model.GLYPH_EJECT
              tooltipText: storageCardRoot.ejectPending
                ? "Waiting for writes to finish — click to cancel"
                : "Eject drive safely (unmount and power off)"
              foreground: storageCardRoot.ejectPending ? root.urgent : root.foreground
              hoverColor: root.urgent
              fontFamily: root.fontFamily
              enabled: !drives.busy
              onClicked: {
                if (storageCardRoot.ejectPending) drives.cancelPendingEject()
                else drives.eject(storageCardRoot.device)
              }
            }
          }
        }
      }

      // Telemetry & Health Status Strip (Dedicated Collapsible Row)
      Rectangle {
        id: telemetryStrip
        visible: storageCardRoot.showTelemetry
        Layout.fillWidth: true
        implicitHeight: storageCardRoot.showTelemetry ? Style.space(26) : 0
        radius: Style.space(5)
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
        border.width: 1
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(6)

          // Left: S.M.A.R.T. Health Status
          RowLayout {
            spacing: Style.space(4)
            Layout.alignment: Qt.AlignVCenter

            Text {
              textFormat: Text.PlainText
              text: storageCardRoot.healthVerdict === "healthy" ? Model.GLYPH_HEALTHY
                : storageCardRoot.healthVerdict === "unsupported" ? Model.GLYPH_STETHOSCOPE
                : Model.GLYPH_ALERT
              color: storageCardRoot.healthVerdict === "healthy"
                ? (bar && "activeColor" in bar ? bar.activeColor : root.foreground)
                : storageCardRoot.healthVerdict === "unsupported" ? root.dim : root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              Layout.alignment: Qt.AlignVCenter
            }

            Text {
              textFormat: Text.PlainText
              text: {
                if (drives.smartRefreshing) {
                  return "Querying telemetry..."
                }
                if (storageCardRoot.healthVerdict === "healthy") {
                  var hours = storageCardRoot.smartData && storageCardRoot.smartData.powerOnHours
                  return hours ? "Healthy · " + Number(hours).toLocaleString() + " hrs" : "Healthy"
                } else if (storageCardRoot.healthVerdict === "failing") {
                  return "Drive Failing"
                } else if (storageCardRoot.healthVerdict === "warning") {
                  return "Warning"
                } else if (storageCardRoot.healthVerdict === "unsupported") {
                  return storageCardRoot.smartData ? "Telemetry unsupported" : "Awaiting telemetry..."
                }
                return "SMART Ready"
              }
              color: storageCardRoot.healthVerdict === "healthy" ? root.foreground
                : storageCardRoot.healthVerdict === "unsupported" ? root.dim : root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: storageCardRoot.healthVerdict !== "healthy" && storageCardRoot.healthVerdict !== "unsupported"
              Layout.alignment: Qt.AlignVCenter
            }

            // Quick S.M.A.R.T. refresh button
            PanelActionButton {
              iconText: Model.GLYPH_REFRESH
              tooltipText: storageCardRoot.healthText !== "" ? storageCardRoot.healthText : "Refresh SMART telemetry"
              foreground: root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              size: Style.space(18)
              enabled: !drives.refreshing && !drives.smartRefreshing
              onClicked: drives.probeSmart(true)
            }
          }

          Item { Layout.fillWidth: true }

          // Right: Live Temperature Sparkline & Gauge
          Rectangle {
            id: tempPill
            visible: !!storageCardRoot.hasTemp
            implicitHeight: Style.space(18)
            implicitWidth: tempPillRow.implicitWidth + Style.space(8)
            radius: Style.space(4)
            readonly property string status: storageCardRoot.tempStats ? Model.tempStatus(storageCardRoot.tempStats.current) : "normal"
            readonly property color statusColor: status === "hot" ? root.urgent
              : status === "warm" ? Qt.rgba(0.96, 0.62, 0.04, 1)
              : (bar && "activeColor" in bar ? bar.activeColor : root.foreground)

            color: status === "hot" ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.14)
              : status === "warm" ? Qt.rgba(0.96, 0.62, 0.04, 0.14)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)

            border.width: 1
            border.color: status === "hot" ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35)
              : status === "warm" ? Qt.rgba(0.96, 0.62, 0.04, 0.35)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
            Layout.alignment: Qt.AlignVCenter

            RowLayout {
              id: tempPillRow
              anchors.centerIn: parent
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: Model.GLYPH_THERMOMETER
                color: tempPill.statusColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                Layout.alignment: Qt.AlignVCenter
              }

              Text {
                textFormat: Text.PlainText
                text: storageCardRoot.tempStats && storageCardRoot.tempStats.current !== null
                  ? storageCardRoot.tempStats.current.toFixed(1) + "°C" : ""
                color: tempPill.statusColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                Layout.alignment: Qt.AlignVCenter
              }

              Canvas {
                id: sparklineCanvas
                implicitWidth: Style.space(32)
                implicitHeight: Style.space(10)
                Layout.alignment: Qt.AlignVCenter

                readonly property var history: storageCardRoot.tempHistory
                onHistoryChanged: requestPaint()

                onPaint: {
                  var ctx = getContext("2d")
                  ctx.clearRect(0, 0, width, height)
                  var coords = Model.sparklineCoords(history, width, height, 1)
                  if (coords.length < 2) return

                  ctx.strokeStyle = tempPill.statusColor
                  ctx.lineWidth = 1.5
                  ctx.beginPath()
                  ctx.moveTo(coords[0].x, coords[0].y)
                  for (var i = 1; i < coords.length; i++) {
                    ctx.lineTo(coords[i].x, coords[i].y)
                  }
                  ctx.stroke()
                }
              }
            }

            MouseArea {
              id: tempPillArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: drives.probeSmart(true)
            }

            PanelToolTip {
              visible: tempPillArea.containsMouse
              text: {
                if (!storageCardRoot.tempStats || storageCardRoot.tempStats.current === null) return "No temperature reading"
                var cur = storageCardRoot.tempStats.current.toFixed(1) + "°C"
                var minStr = storageCardRoot.tempStats.min !== null ? storageCardRoot.tempStats.min.toFixed(1) + "°C" : cur
                var maxStr = storageCardRoot.tempStats.max !== null ? storageCardRoot.tempStats.max.toFixed(1) + "°C" : cur
                var trendStr = storageCardRoot.tempStats.trend === "rising" ? "rising"
                  : storageCardRoot.tempStats.trend === "cooling" ? "cooling" : "stable"
                return "Temperature: " + cur + "\nMin: " + minStr + " · Max: " + maxStr + " · Trend: " + trendStr + "\nClick to refresh"
              }
            }
          }
        }
      }

      // Device Settings Drawer (Progressive Disclosure)
      Rectangle {
        visible: storageCardRoot.isExpanded
        Layout.fillWidth: true
        radius: Style.space(6)
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
        border.width: 1
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        implicitHeight: devDrawerLayout.implicitHeight + Style.space(12)

        ColumnLayout {
          id: devDrawerLayout
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: "DRIVE SETTINGS"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Flow {
            Layout.fillWidth: true
            spacing: Style.space(6)

            // Auto-open chip
            ActionChip {
              visible: !storageCardRoot.isSystem
              iconText: storageCardRoot.autoOpen === false ? Model.GLYPH_FOLDER_OFF : Model.GLYPH_FOLDER
              label: storageCardRoot.autoOpen === true
                ? "Auto-Open: On"
                : storageCardRoot.autoOpen === false
                  ? "Auto-Open: Off"
                  : "Auto-Open: Default"
              tooltipText: "Cycle auto-open policy on mount (Always / Never / Follow global)"
              onClicked: drives.cycleAutoOpen(storageCardRoot.device)
            }

            // Read-only chip
            ActionChip {
              visible: !storageCardRoot.isSystem
              iconText: Model.GLYPH_READONLY
              label: storageCardRoot.mountsReadOnly ? "Read-Only: On" : "Read-Only: Off"
              active: storageCardRoot.mountsReadOnly
              tooltipText: "Toggle read-only mount policy for all partitions on this drive"
              onClicked: drives.setDriveReadOnly(storageCardRoot.device, !storageCardRoot.mountsReadOnly)
            }

            // Rename nickname chip
            ActionChip {
              visible: !storageCardRoot.isSystem
              iconText: Model.GLYPH_PENCIL
              label: "Rename Nickname"
              tooltipText: "Assign a custom local nickname to this hardware"
              onClicked: root.beginRename(storageCardRoot.device)
            }

            // Flash Bootable ISO chip (only for removable / non-system drives)
            ActionChip {
              visible: !storageCardRoot.isSystem
              iconText: Model.GLYPH_SPEEDOMETER
              label: "Flash Bootable ISO"
              tooltipText: "Write a bootable operating system ISO image to this USB drive"
              onClicked: root.runFlash(storageCardRoot.device.path)
            }

            // Recovery & Diagnostics chip (available for all drives)
            ActionChip {
              iconText: Model.GLYPH_STETHOSCOPE
              label: "Recover & Inspect"
              tooltipText: "Launch TUI storage diagnostics, S.M.A.R.T. queries & recovery tool"
              onClicked: root.runRecovery(storageCardRoot.device.path)
            }

            // Format entire drive chip (strictly not allowed on system drives)
            ActionChip {
              visible: !storageCardRoot.isSystem
              iconText: Model.GLYPH_ERASER
              label: "Format Entire Drive"
              danger: true
              tooltipText: "Erase all partitions and create a clean partition table"
              onClicked: root.launchFormat(storageCardRoot.device.path)
            }
          }
        }
      }

      // Divider between card header and volume list
      Rectangle {
        visible: storageCardRoot.device && storageCardRoot.device.volumes.length > 0
        Layout.fillWidth: true
        height: 1
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
      }

      // Volume List inside Card
      Repeater {
        model: storageCardRoot.device ? storageCardRoot.device.volumes : []

        VolumeItem {
          required property var modelData
          required property int index

          Layout.fillWidth: true
          volume: modelData
          deviceIndex: storageCardRoot.deviceIndex
          volumeIndex: index
          visible: !!root.volumeMatchesFilter(modelData, root.filterQuery, storageCardRoot.device)
        }
      }
    }
  }

  // ------------------------------------------------------------ VolumeItem Component
  component VolumeItem: ColumnLayout {
    id: volumeItemRoot
    property var volume: null
    property int deviceIndex: 0
    property int volumeIndex: 0

    readonly property bool isDrawerOpen: root.expandedVolumePath === (volume ? volume.fsPath : "")
      || volumeItemRoot.renamingLabel || volumeItemRoot.unlocking || volumeItemRoot.formatting

    readonly property bool selected: root.cursorActive && root.currentRow
      && root.currentRow.kind === "volume"
      && root.currentRow.device === deviceIndex
      && root.currentRow.volume === volumeIndex
    onSelectedChanged: if (selected) root.cursorItem = volSurface
    readonly property bool actionable: volume
      && (volume.mounted || Model.isMountable(volume) || (volume.encrypted && !volume.unlocked))
    readonly property bool working: volume && drives.busyPath === volume.fsPath
    readonly property real trashBytes: volume ? drives.trashSizeFor(volume) : 0

    readonly property bool renamingLabel: volume && root.renamingLabelPath === volume.fsPath
    readonly property bool unlocking: volume && root.unlockingPath === volume.fsPath
    readonly property bool canCheck: volume && Model.canCheck(drives.fsCapabilities, volume)
    readonly property var checkHint: volume ? Model.checkHint(drives.fsCapabilities, volume) : null

    readonly property bool formatting: volume && root.formattingPath === volume.fsPath
    readonly property bool formattable: volume
      && Model.canFormat(drives.fsCapabilities, volume, drives.deviceOfVolume(volume)) === null

    readonly property var formatCheck: formatting
      ? Model.validateFormat(drives.fsCapabilities, volume, drives.deviceOfVolume(volume),
                             { fsPath: volume.fsPath, fstype: root.formatType,
                               label: formatLabelField.text, quick: root.formatQuick })
      : null
    readonly property int formatRoom: formatting
      ? Model.labelRemaining(Model.formatTarget(root.formatType), formatLabelField.text)
      : 0
    readonly property bool formatReady: formatting && formatCheck !== null && formatCheck.ok
      && Model.formatConfirmed(volume, confirmField.text)

    readonly property var labelCheck: renamingLabel && volume
      ? Model.validateLabel(volume, labelField.text)
      : null
    readonly property int labelRoom: renamingLabel && volume
      ? Model.labelRemaining(volume, labelField.text)
      : 0

    function commitLabel(value) {
      drives.setVolumeLabel(volumeItemRoot.volume, value)
      root.finishLabelEdit()
    }
    function cancelLabel() { root.finishLabelEdit() }

    function commitUnlock(value) {
      drives.unlock(volumeItemRoot.volume, value)
      passphraseField.text = ""
      root.finishUnlock()
    }
    function cancelUnlock() {
      passphraseField.text = ""
      root.finishUnlock()
    }

    function commitFormat() {
      if (!Model.formatConfirmed(volumeItemRoot.volume, confirmField.text)) return
      drives.formatVolume(volumeItemRoot.volume, root.formatType, formatLabelField.text, root.formatQuick)
      root.finishFormat()
    }
    function cancelFormat() { root.finishFormat() }

    spacing: Style.space(4)

    // Main Volume Row
    CursorSurface {
      id: volSurface
      Layout.fillWidth: true
      hasCursor: volumeItemRoot.selected
      foreground: root.foreground
      implicitHeight: volRowLayout.implicitHeight + Style.space(6)

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: volumeItemRoot.actionable && !volumeItemRoot.renamingLabel && !volumeItemRoot.formatting
          ? Qt.PointingHandCursor : Qt.ArrowCursor
        onEntered: root.setCursor(root.rowIndexOfVolume(volumeItemRoot.deviceIndex, volumeItemRoot.volumeIndex))
        onClicked: if (!volumeItemRoot.renamingLabel && !volumeItemRoot.formatting) root.activateVolume(volumeItemRoot.volume)
      }

      RowLayout {
        id: volRowLayout
        anchors.fill: parent
        anchors.leftMargin: Style.space(8)
        anchors.rightMargin: Style.space(4)
        spacing: Style.space(8)

        // Left Info Column
        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          // First Line: Title, Filesystem pill, OS badges
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              visible: volumeItemRoot.volume && volumeItemRoot.volume.encrypted
              text: volumeItemRoot.volume && volumeItemRoot.volume.unlocked ? Model.GLYPH_UNLOCKED : Model.GLYPH_LOCKED
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              Layout.alignment: Qt.AlignVCenter
            }

            Text {
              textFormat: Text.PlainText
              text: volumeItemRoot.volume ? volumeItemRoot.volume.title : ""
              color: volumeItemRoot.volume && volumeItemRoot.volume.mounted ? root.foreground : Qt.darker(root.foreground, 1.25)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: volumeItemRoot.volume && volumeItemRoot.volume.mounted
              elide: Text.ElideRight
              Layout.alignment: Qt.AlignVCenter
            }

            // Filesystem Pill
            FsPill {
              visible: volumeItemRoot.volume && volumeItemRoot.volume.fstype !== ""
              text: volumeItemRoot.volume ? volumeItemRoot.volume.fstype : ""
              urgentColor: volumeItemRoot.volume && (volumeItemRoot.volume.fstype === "ntfs" || volumeItemRoot.volume.fstype === "ntfs3") && !volumeItemRoot.volume.mounted
              Layout.alignment: Qt.AlignVCenter
            }

            // Read-Only Pill
            Rectangle {
              visible: !!(volumeItemRoot.volume && volumeItemRoot.volume.mounted && volumeItemRoot.volume.readOnly)
              implicitWidth: roPillText.implicitWidth + Style.space(8)
              implicitHeight: roPillText.implicitHeight + Style.space(2)
              radius: Style.space(3)
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              Layout.alignment: Qt.AlignVCenter

              Text {
                id: roPillText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "RO"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            // System Volume Pill (Root, Boot, Swap)
            Rectangle {
              visible: volumeItemRoot.volume && volumeItemRoot.volume.isSystem
              implicitWidth: osVolTag.implicitWidth + Style.space(10)
              implicitHeight: osVolTag.implicitHeight + Style.space(4)
              radius: Style.space(3)
              color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.16)
              border.width: 1
              border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.45)
              Layout.alignment: Qt.AlignVCenter

              RowLayout {
                anchors.centerIn: parent
                spacing: Style.space(3)

                Text {
                  textFormat: Text.PlainText
                  text: Model.GLYPH_LOCKED
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  id: osVolTag
                  textFormat: Text.PlainText
                  text: {
                    if (!volumeItemRoot.volume) return "SYSTEM"
                    if (volumeItemRoot.volume.fstype === "swap" || volumeItemRoot.volume.mountpoint === "[SWAP]") return "SWAP"
                    if (volumeItemRoot.volume.mountpoint === "/") return "OS ROOT"
                    if (volumeItemRoot.volume.mountpoint === "/boot" || volumeItemRoot.volume.mountpoint === "/efi") return "BOOT"
                    return "SYSTEM"
                  }
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }
          }

          // Second Line: Free space metadata text
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: {
              if (volumeItemRoot.working) return "Working…"
              if (!volumeItemRoot.volume) return ""
              if (volumeItemRoot.volume.fstype === "swap" || volumeItemRoot.volume.mountpoint === "[SWAP]") {
                return Model.formatBytes(volumeItemRoot.volume.sizeBytes) + " · Active Swap Memory"
              }
              if (volumeItemRoot.volume.mounted) {
                var avail = Model.formatBytes(volumeItemRoot.volume.fsavail)
                var total = Model.formatBytes(volumeItemRoot.volume.fssize)
                var pct = Math.round(Model.usedFraction(volumeItemRoot.volume) * 100)
                return avail + " free of " + total + " (" + pct + "% used)"
              }
              if (volumeItemRoot.volume.fstype === "ntfs" || volumeItemRoot.volume.fstype === "ntfs3") {
                return Model.formatBytes(volumeItemRoot.volume.fssize) + " · Unmounted NTFS"
              }
              if (volumeItemRoot.volume.encrypted && !volumeItemRoot.volume.unlocked) {
                return "Encrypted container (Locked)"
              }
              return volumeItemRoot.volume.fssize > 0
                ? Model.formatBytes(volumeItemRoot.volume.fssize) + " · Unmounted"
                : "Unmounted"
            }
            color: volumeItemRoot.volume && volumeItemRoot.volume.mounted && Model.usedFraction(volumeItemRoot.volume) > 0.9
              ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // Slim Usage Progress Bar (Mounted Volumes)
          Rectangle {
            visible: volumeItemRoot.volume && volumeItemRoot.volume.mounted && volumeItemRoot.volume.fssize > 0
            Layout.fillWidth: true
            implicitHeight: Math.max(2, Style.space(3))
            radius: height / 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

            Rectangle {
              readonly property real fraction: Model.usedFraction(volumeItemRoot.volume)
              width: Math.max(parent.width > 0 && fraction > 0 ? 2 : 0, parent.width * fraction)
              height: parent.height
              radius: parent.radius
              color: fraction > 0.9 ? root.urgent : root.foreground
              opacity: fraction > 0.9 ? 1.0 : 0.65

              Behavior on width {
                NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
              }
            }
          }
        }

        // Right Actions Column: ONLY ONE Primary Button + Drawer Toggle
        Row {
          spacing: Style.space(2)
          Layout.alignment: Qt.AlignVCenter

          // Primary Quick Action Button
          PanelActionButton {
            visible: volumeItemRoot.volume
              && volumeItemRoot.volume.fstype !== "swap"
              && volumeItemRoot.volume.mountpoint !== "[SWAP]"
              && (volumeItemRoot.volume.mounted
                  || (!volumeItemRoot.volume.isSystem && (Model.isMountable(volumeItemRoot.volume) || volumeItemRoot.volume.encrypted)))
            iconText: {
              if (!volumeItemRoot.volume) return ""
              if (volumeItemRoot.volume.mounted) return Model.GLYPH_FOLDER
              if (volumeItemRoot.volume.encrypted && !volumeItemRoot.volume.unlocked) return Model.GLYPH_LOCKED
              if ((volumeItemRoot.volume.fstype === "ntfs" || volumeItemRoot.volume.fstype === "ntfs3") && !volumeItemRoot.volume.mounted) return Model.GLYPH_WRENCH
              return Model.GLYPH_MOUNT
            }
            tooltipText: {
              if (!volumeItemRoot.volume) return ""
              if (volumeItemRoot.volume.mounted) return "Open in file manager"
              if (Model.canUnlock(volumeItemRoot.volume)) return "Unlock encrypted container"
              if ((volumeItemRoot.volume.fstype === "ntfs" || volumeItemRoot.volume.fstype === "ntfs3") && !volumeItemRoot.volume.mounted) return "Repair & Mount NTFS"
              return "Mount volume"
            }
            foreground: volumeItemRoot.volume && (volumeItemRoot.volume.fstype === "ntfs" || volumeItemRoot.volume.fstype === "ntfs3") && !volumeItemRoot.volume.mounted
              ? root.urgent : root.foreground
            fontFamily: root.fontFamily
            enabled: !drives.busy
            onClicked: {
              if (volumeItemRoot.volume.mounted) drives.openVolume(volumeItemRoot.volume)
              else if (Model.canUnlock(volumeItemRoot.volume)) root.beginUnlock(volumeItemRoot.volume)
              else if ((volumeItemRoot.volume.fstype === "ntfs" || volumeItemRoot.volume.fstype === "ntfs3") && !volumeItemRoot.volume.mounted) root.runNtfsFix(volumeItemRoot.volume.fsPath)
              else drives.toggleMount(volumeItemRoot.volume, root.openOnMount)
            }
          }

          // Progressive Disclosure Drawer Toggle (⋯)
          PanelActionButton {
            visible: volumeItemRoot.volume
              && volumeItemRoot.volume.fstype !== "swap"
              && volumeItemRoot.volume.mountpoint !== "[SWAP]"
            iconText: Model.GLYPH_DOTS
            tooltipText: volumeItemRoot.isDrawerOpen ? "Hide action tiles" : "Inspector & Action tiles (Dua, Terminal, Format, Check...)"
            foreground: volumeItemRoot.isDrawerOpen ? (bar && "activeColor" in bar ? bar.activeColor : root.foreground) : root.dim
            hoverColor: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.toggleVolumeDrawer(volumeItemRoot.volume.fsPath)
          }
        }
      }
    }

    // ------------------------------------------------------------ Volume Inspector Drawer (Option 3 blend)
    Rectangle {
      visible: volumeItemRoot.isDrawerOpen
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(8)
      radius: Style.space(6)
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
      border.width: 1
      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
      implicitHeight: drawerLayout.implicitHeight + Style.space(12)

      ColumnLayout {
        id: drawerLayout
        anchors.fill: parent
        anchors.margins: Style.space(8)
        spacing: Style.space(8)

        // Action Tiles Grid / Flow
        Flow {
          Layout.fillWidth: true
          spacing: Style.space(6)

          // 1. Disk Usage (dua)
          ActionChip {
            visible: volumeItemRoot.volume && volumeItemRoot.volume.mounted
            iconText: Model.GLYPH_PIE
            label: "Disk Usage"
            tooltipText: "Analyze disk space with dua in floating terminal"
            onClicked: drives.openDiskUsage(volumeItemRoot.volume)
          }

          // 2. Terminal
          ActionChip {
            visible: volumeItemRoot.volume && volumeItemRoot.volume.mounted
            iconText: Model.GLYPH_TERMINAL
            label: "Terminal"
            tooltipText: "Open terminal at mountpoint"
            onClicked: drives.openTerminal(volumeItemRoot.volume)
          }

          // 3. Speed Test
          ActionChip {
            visible: !!(volumeItemRoot.volume && volumeItemRoot.volume.mounted)
            iconText: Model.GLYPH_SPEEDOMETER
            label: "Speed Test"
            tooltipText: "Run live read/write performance benchmark with omarchy-disk-speedtest"
            onClicked: root.runSpeedTest(volumeItemRoot.volume.mountpoint)
          }

          // 4. Btrfs Scrub
          ActionChip {
            visible: !!(volumeItemRoot.volume && volumeItemRoot.volume.mounted && volumeItemRoot.volume.fstype === "btrfs")
            iconText: Model.GLYPH_SHIELD
            label: "Btrfs Scrub"
            tooltipText: "Verify checksums and repair corrupted blocks via btrfs scrub"
            onClicked: root.runBtrfsScrub(volumeItemRoot.volume.mountpoint)
          }

          // 5. Trim SSD
          ActionChip {
            visible: !!(volumeItemRoot.volume && volumeItemRoot.volume.mounted)
            iconText: Model.GLYPH_WRENCH
            label: "Trim SSD"
            tooltipText: "Reclaim unused storage blocks via fstrim"
            onClicked: root.runTrim(volumeItemRoot.volume.mountpoint)
          }

          // 6. Unmount
          ActionChip {
            visible: volumeItemRoot.volume && volumeItemRoot.volume.mounted && !volumeItemRoot.volume.isSystem
            iconText: Model.GLYPH_UNMOUNT
            label: "Unmount"
            tooltipText: "Unmount partition"
            onClicked: drives.toggleMount(volumeItemRoot.volume, false)
          }

          // 7. Mount Read-Only
          ActionChip {
            visible: volumeItemRoot.volume && !volumeItemRoot.volume.mounted && !volumeItemRoot.volume.isSystem
            iconText: Model.GLYPH_READONLY
            label: "Mount RO"
            tooltipText: "Mount read-only without write permissions"
            onClicked: drives.mountReadOnly(volumeItemRoot.volume)
          }

          // 8. Check Filesystem
          ActionChip {
            visible: !volumeItemRoot.volume.isSystem && (volumeItemRoot.canCheck || (volumeItemRoot.checkHint !== null && volumeItemRoot.checkHint.packages !== ""))
            iconText: Model.GLYPH_STETHOSCOPE
            label: "Check"
            tooltipText: volumeItemRoot.canCheck
              ? "Check this filesystem for errors"
              : (volumeItemRoot.checkHint ? volumeItemRoot.checkHint.text : "Check filesystem")
            onClicked: {
              if (volumeItemRoot.canCheck) drives.checkVolume(volumeItemRoot.volume)
              else drives.installCheckTools(volumeItemRoot.volume)
            }
          }

          // 9. Rename Volume Label
          ActionChip {
            visible: !volumeItemRoot.volume.isSystem && Model.canRelabel(volumeItemRoot.volume) && !volumeItemRoot.renamingLabel
            iconText: Model.GLYPH_TAG
            label: "Rename"
            tooltipText: "Change the volume label stored on the filesystem"
            onClicked: root.beginLabelEdit(volumeItemRoot.volume)
          }

          // 10. NTFS Auto-Fix
          ActionChip {
            visible: volumeItemRoot.volume && (volumeItemRoot.volume.fstype === "ntfs" || volumeItemRoot.volume.fstype === "ntfs3")
            iconText: Model.GLYPH_WRENCH
            label: "NTFS Fix"
            danger: true
            tooltipText: "Clear dirty bit and mount with ntfs-3g"
            onClicked: root.runNtfsFix(volumeItemRoot.volume.fsPath)
          }

          // 11. Partition Recovery
          ActionChip {
            visible: !!(volumeItemRoot.volume && !volumeItemRoot.volume.isSystem)
            iconText: Model.GLYPH_STETHOSCOPE
            label: "Recover"
            tooltipText: "Launch TUI partition recovery & deep diagnosis tool"
            onClicked: root.runRecovery(volumeItemRoot.volume.fsPath || volumeItemRoot.volume.path)
          }

          // 12. Format Partition (Strictly forbidden on system volumes!)
          ActionChip {
            visible: !volumeItemRoot.volume.isSystem
            iconText: Model.GLYPH_ERASER
            label: "Format"
            danger: true
            tooltipText: "Safely format partition with interactive wizard"
            onClicked: root.launchFormat(volumeItemRoot.volume.fsPath || volumeItemRoot.volume.path)
          }

          // 13. Empty Trash
          ActionChip {
            visible: volumeItemRoot.trashBytes > 0
            iconText: Model.GLYPH_TRASH
            label: "Empty Trash (" + Model.formatBytes(volumeItemRoot.trashBytes) + ")"
            danger: true
            tooltipText: "Permanently delete files in .Trash on this volume"
            onClicked: drives.emptyTrash(volumeItemRoot.volume)
          }

          // 14. Lock Container
          ActionChip {
            visible: volumeItemRoot.volume && Model.canLock(volumeItemRoot.volume)
            iconText: Model.GLYPH_LOCKED
            label: "Lock LUKS"
            tooltipText: "Unmount and close encrypted container"
            onClicked: drives.lock(volumeItemRoot.volume)
          }
        }

        // Inline Editor: Rename Label
        RowLayout {
          visible: volumeItemRoot.renamingLabel
          Layout.fillWidth: true
          spacing: Style.space(6)

          TextField {
            id: labelField
            Layout.fillWidth: true
            foreground: root.foreground
            verticalPadding: Style.space(2)
            placeholderText: volumeItemRoot.volume && volumeItemRoot.volume.fstypeLabel !== ""
              ? volumeItemRoot.volume.fstypeLabel + " label"
              : "Volume label"
            onVisibleChanged: if (visible) {
              text = volumeItemRoot.volume ? volumeItemRoot.volume.label : ""
              Qt.callLater(function() { labelField.forceActiveFocus(); labelField.selectAll() })
            }
            onAccepted: volumeItemRoot.commitLabel(text)
            Keys.onEscapePressed: volumeItemRoot.cancelLabel()
          }

          Text {
            textFormat: Text.PlainText
            text: volumeItemRoot.labelRoom
            color: volumeItemRoot.labelRoom < 0 ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            Layout.alignment: Qt.AlignVCenter
          }
        }

        // Inline Editor: Passphrase Unlock
        TextField {
          id: passphraseField
          visible: volumeItemRoot.unlocking
          Layout.fillWidth: true
          password: true
          foreground: root.foreground
          verticalPadding: Style.space(2)
          placeholderText: "Type encryption passphrase"
          onVisibleChanged: if (visible) {
            text = ""
            Qt.callLater(function() { passphraseField.forceActiveFocus() })
          }
          onAccepted: volumeItemRoot.commitUnlock(text)
          Keys.onEscapePressed: volumeItemRoot.cancelUnlock()
        }

        // Inline Editor: Built-in Format Form
        ColumnLayout {
          visible: volumeItemRoot.formatting
          Layout.fillWidth: true
          spacing: Style.space(4)

          Flow {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Repeater {
              model: Model.formatTypes(drives.fsCapabilities)

              Text {
                id: typeChip
                required property var modelData
                textFormat: Text.PlainText
                text: Model.formatFsType(typeChip.modelData)
                color: root.formatType === typeChip.modelData ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.formatType === typeChip.modelData

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.formatType = typeChip.modelData
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: root.formatQuick ? "· Quick" : "· Zero first"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.formatQuick = !root.formatQuick
              }
            }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            TextField {
              id: formatLabelField
              Layout.fillWidth: true
              foreground: root.foreground
              verticalPadding: Style.space(2)
              placeholderText: "Filesystem label"
              onVisibleChanged: if (visible) text = ""
            }

            Text {
              textFormat: Text.PlainText
              text: volumeItemRoot.formatRoom
              color: volumeItemRoot.formatRoom < 0 ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              Layout.alignment: Qt.AlignVCenter
            }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            TextField {
              id: confirmField
              Layout.fillWidth: true
              foreground: root.foreground
              verticalPadding: Style.space(2)
              placeholderText: volumeItemRoot.volume
                ? "Type " + Model.formatToken(volumeItemRoot.volume) + " to erase"
                : ""
              onVisibleChanged: if (visible) {
                text = ""
                Qt.callLater(function() { confirmField.forceActiveFocus() })
              }
              onAccepted: volumeItemRoot.commitFormat()
              Keys.onEscapePressed: volumeItemRoot.cancelFormat()
            }

            PanelActionButton {
              iconText: Model.GLYPH_ERASER
              tooltipText: "Erase this volume"
              foreground: volumeItemRoot.formatReady ? root.urgent : root.dim
              hoverColor: root.urgent
              fontFamily: root.fontFamily
              enabled: !drives.busy && volumeItemRoot.formatReady
              Layout.alignment: Qt.AlignVCenter
              onClicked: volumeItemRoot.commitFormat()
            }
          }
        }

        // Status & Instruction Hint
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: {
            if (volumeItemRoot.unlocking) return "Enter unlocks and mounts · Esc cancels"
            if (volumeItemRoot.renamingLabel) {
              if (volumeItemRoot.labelCheck && !volumeItemRoot.labelCheck.ok) return volumeItemRoot.labelCheck.message
              return "Enter renames the filesystem · Esc cancels"
            }
            if (volumeItemRoot.formatting) {
              if (volumeItemRoot.formatCheck && !volumeItemRoot.formatCheck.ok) return volumeItemRoot.formatCheck.reason
              return Model.formatWarning(volumeItemRoot.volume) + " Esc cancels."
            }
            return drives.metaFor(volumeItemRoot.volume)
          }
          color: volumeItemRoot.formatting
            || (volumeItemRoot.renamingLabel && volumeItemRoot.labelCheck && !volumeItemRoot.labelCheck.ok)
            ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ------------------------------------------------------------ PortableCard Component
  component PortableCard: Rectangle {
    id: portableCardRoot
    property var entry: null
    property int portableIndex: 0

    readonly property bool selected: root.cursorActive && root.currentRow
      && root.currentRow.kind === "portable" && root.currentRow.portable === portableIndex
    onSelectedChanged: if (selected) root.cursorItem = portableCardRoot

    radius: Style.space(8)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
    border.width: 1
    border.color: selected
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

    implicitHeight: portableCardLayout.implicitHeight + Style.space(12)

    CursorSurface {
      anchors.fill: parent
      hasCursor: portableCardRoot.selected
      foreground: root.foreground

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: root.setCursor(root.rowIndexOfPortable(portableCardRoot.portableIndex))
        onClicked: root.activatePortable(portableCardRoot.entry)
      }

      RowLayout {
        id: portableCardLayout
        anchors.fill: parent
        anchors.margins: Style.space(8)
        spacing: Style.space(8)

        // Portable Icon
        Rectangle {
          implicitWidth: Style.space(28)
          implicitHeight: Style.space(28)
          radius: Style.space(5)
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
          Layout.alignment: Qt.AlignVCenter

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: Model.portableGlyph(portableCardRoot.entry)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: portableCardRoot.entry ? portableCardRoot.entry.name : ""
            color: portableCardRoot.entry && portableCardRoot.entry.mounted ? root.foreground : Qt.darker(root.foreground, 1.25)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: Model.portableMeta(portableCardRoot.entry)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Row {
          spacing: Style.space(2)
          Layout.alignment: Qt.AlignVCenter

          PanelActionButton {
            visible: portableCardRoot.entry && portableCardRoot.entry.uri !== ""
            iconText: Model.GLYPH_FOLDER
            tooltipText: "Browse device in file manager"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: drives.openPortable(portableCardRoot.entry)
          }

          PanelActionButton {
            iconText: portableCardRoot.entry && portableCardRoot.entry.mounted ? Model.GLYPH_UNMOUNT : Model.GLYPH_MOUNT
            tooltipText: portableCardRoot.entry && portableCardRoot.entry.mounted ? "Unmount" : "Mount"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !drives.busy
            onClicked: drives.togglePortable(portableCardRoot.entry)
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ NetworkShareCard Component
  component NetworkShareCard: Rectangle {
    id: netCardRoot
    property var share: null
    property int shareIndex: 0

    radius: Style.space(10)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09)
    implicitHeight: visible ? (netLayout.implicitHeight + Style.space(16)) : 0

    ColumnLayout {
      id: netLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(8)

      // Header row
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        // Share Icon Container
        Rectangle {
          implicitWidth: Style.space(32)
          implicitHeight: Style.space(32)
          radius: Style.space(6)
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          Layout.alignment: Qt.AlignVCenter

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: netCardRoot.share ? netCardRoot.share.glyph : Model.GLYPH_SERVER
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon
          }
        }

        // Details
        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: netCardRoot.share ? netCardRoot.share.title : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }

            // FS Type Pill Badge
            Rectangle {
              implicitWidth: fsTypeTag.implicitWidth + Style.space(10)
              implicitHeight: fsTypeTag.implicitHeight + Style.space(4)
              radius: Style.space(3)
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              border.width: 1
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
              Layout.alignment: Qt.AlignVCenter

              Text {
                id: fsTypeTag
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: netCardRoot.share ? netCardRoot.share.typeLabel : "NETWORK"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            // Read-Only Badge
            Rectangle {
              visible: !!(netCardRoot.share && netCardRoot.share.readOnly)
              implicitWidth: roTag.implicitWidth + Style.space(10)
              implicitHeight: roTag.implicitHeight + Style.space(4)
              radius: Style.space(3)
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              border.width: 1
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
              Layout.alignment: Qt.AlignVCenter

              Text {
                id: roTag
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "RO"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          // Subtitle (server & mount point)
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: {
              if (!netCardRoot.share) return ""
              var s = netCardRoot.share
              if (s.server !== "") return s.server + " · " + s.mountpoint
              return s.source + " · " + s.mountpoint
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // Capacity / Usage summary
          Text {
            visible: !!(netCardRoot.share && netCardRoot.share.sizeBytes > 0)
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: {
              if (!netCardRoot.share || netCardRoot.share.sizeBytes <= 0) return ""
              var s = netCardRoot.share
              var pct = Math.round(s.usedFraction * 100)
              return s.usedText + " used of " + s.sizeText + " (" + s.availText + " free, " + pct + "%)"
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        // Action Buttons
        Row {
          spacing: Style.space(2)
          Layout.alignment: Qt.AlignVCenter

          // Open Folder
          PanelActionButton {
            iconText: Model.GLYPH_FOLDER
            tooltipText: "Browse mount in file manager"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: drives.openNetworkShare(netCardRoot.share)
          }

          // Open Terminal
          PanelActionButton {
            iconText: Model.GLYPH_TERMINAL
            tooltipText: "Open terminal at mount point"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: drives.openNetworkTerminal(netCardRoot.share)
          }

          // Copy Mountpoint Path
          PanelActionButton {
            iconText: Model.GLYPH_COPY
            tooltipText: "Copy mount path to clipboard"
            foreground: root.dim
            hoverColor: root.foreground
            fontFamily: root.fontFamily
            onClicked: Quickshell.execDetached(["wl-copy", netCardRoot.share ? netCardRoot.share.mountpoint : ""])
          }

          // Unmount Network Share
          PanelActionButton {
            iconText: Model.GLYPH_UNMOUNT
            tooltipText: "Unmount network share"
            foreground: root.foreground
            hoverColor: root.urgent
            fontFamily: root.fontFamily
            enabled: !drives.busy
            onClicked: drives.unmountNetworkShare(netCardRoot.share)
          }
        }
      }

      // Usage Progress Bar (when size > 0)
      Rectangle {
        visible: !!(netCardRoot.share && netCardRoot.share.sizeBytes > 0)
        Layout.fillWidth: true
        implicitHeight: Style.space(4)
        radius: height / 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

        Rectangle {
          readonly property real fraction: netCardRoot.share ? netCardRoot.share.usedFraction : 0
          width: Math.max(parent.width > 0 && fraction > 0 ? 3 : 0, parent.width * fraction)
          height: parent.height
          radius: parent.radius
          color: fraction >= 0.9 ? root.urgent
            : fraction >= 0.75 ? Qt.rgba(0.96, 0.62, 0.04, 1)
            : (bar && "activeColor" in bar ? bar.activeColor : root.foreground)
        }
      }
    }
  }
}
