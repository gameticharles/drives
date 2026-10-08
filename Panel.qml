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

  moduleName: "storage-drives"
  ipcTarget: "storage-drives"
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

  // Cloud & rclone state
  property bool cloudAddOpen: false
  property string cloudAddProvider: "drive"
  property string cloudAddRemoteName: "gdrive"
  property string cloudAddFolder: "~/Google Drive"
  property string cloudAddMount: "~/Google Drive (Cloud)"
  property int cloudAddInterval: 10
  property bool cloudConfigDrawerOpen: false

  // A destructive cloud action waiting for its second click, e.g.
  // "purge:gdrive". It disarms by itself, so a stray click later never
  // finishes a delete somebody started and walked away from.
  property string armedCloudAction: ""

  function armOrRun(key, action) {
    if (armedCloudAction === key) {
      armedCloudAction = ""
      disarmTimer.stop()
      action()
      return
    }
    armedCloudAction = key
    disarmTimer.restart()
  }

  Timer {
    id: disarmTimer
    interval: 4000
    onTriggered: root.armedCloudAction = ""
  }

  // Draft of the browse folder being edited in an account's config drawer.
  property string cloudMountDraft: ""

  readonly property color warnColor: Qt.rgba(0.96, 0.62, 0.04, 1)

  function toneColor(tone) {
    if (tone === "error") return root.urgent
    if (tone === "warn") return root.warnColor
    if (tone === "busy" || tone === "ok") return bar && "activeColor" in bar ? bar.activeColor : root.foreground
    return root.dim
  }

  function rescanAll() {
    drives.rescan()
    if (activeTab === "network") drives.refreshCloud()
  }

  function openCloudAccount(remote) {
    if (!remote) return
    drives.selectedCloudRemote = remote
    cloudConfigDrawerOpen = false
    armedCloudAction = ""
    var acc = drives.cloudAccount(remote)
    cloudMountDraft = acc ? String(acc.browseMountPath || "") : ""
    // A shared folder is the one thing worth fixing before anything else.
    cloudConfigDrawerOpen = !!drives.cloudConflicts[remote]
    drives.refreshCloudStatus(remote, true)
    drives.refreshCloudFolders(remote)
  }

  function nextAvailableRemote(baseName) {
    if (!drives.hasCloudAccount(baseName)) return baseName
    for (var i = 2; i <= 20; i++) {
      var candidate = baseName + i
      if (!drives.hasCloudAccount(candidate)) return candidate
    }
    return baseName + "-new"
  }

  // Whether any connected account already uses this path, as its sync or its
  // browse folder — compared expanded, so "~/X" and "/home/me/X" collide.
  function pathTaken(path) {
    var target = Model.expandHomePath(path, drives.homePath)
    for (var i = 0; i < drives.cloudAccounts.length; i++) {
      var a = drives.cloudAccounts[i]
      if (Model.pathsOverlap(target, Model.expandHomePath(a.folderPath, drives.homePath))
          || Model.pathsOverlap(target, Model.expandHomePath(a.browseMountPath, drives.homePath))) return true
    }
    return false
  }

  // "~/Google Drive" → "~/Google Drive 2"; "~/Google Drive (Cloud)" →
  // "~/Google Drive 2 (Cloud)". Counts up until the path is free, rather than
  // appending " 2" once — which is how two accounts ended up sharing a mount.
  function nextAvailablePath(base) {
    if (!pathTaken(base)) return base
    var m = String(base).match(/^(.*?)(\s*\([^)]*\))?$/)
    var stem = m ? m[1] : base
    var suffix = m && m[2] ? m[2] : ""
    for (var i = 2; i <= 50; i++) {
      var candidate = stem + " " + i + suffix
      if (!pathTaken(candidate)) return candidate
    }
    return base
  }

  function nextAvailableFolder(baseFolder) { return nextAvailablePath(baseFolder) }
  function nextAvailableMount(baseMount) { return nextAvailablePath(baseMount) }

  function selectCloudAddProvider(type) {
    cloudAddProvider = type
    if (type === "drive") {
      cloudAddRemoteName = nextAvailableRemote("gdrive")
      cloudAddFolder = nextAvailableFolder("~/Google Drive")
      cloudAddMount = nextAvailableMount("~/Google Drive (Cloud)")
    } else if (type === "mega") {
      cloudAddRemoteName = nextAvailableRemote("mega")
      cloudAddFolder = nextAvailableFolder("~/Mega")
      cloudAddMount = nextAvailableMount("~/Mega (Cloud)")
    } else if (type === "onedrive") {
      cloudAddRemoteName = nextAvailableRemote("onedrive")
      cloudAddFolder = nextAvailableFolder("~/OneDrive")
      cloudAddMount = nextAvailableMount("~/OneDrive (Cloud)")
    } else if (type === "dropbox") {
      cloudAddRemoteName = nextAvailableRemote("dropbox")
      cloudAddFolder = nextAvailableFolder("~/Dropbox")
      cloudAddMount = nextAvailableMount("~/Dropbox (Cloud)")
    } else if (type === "webdav") {
      cloudAddRemoteName = nextAvailableRemote("nextcloud")
      cloudAddFolder = nextAvailableFolder("~/Nextcloud")
      cloudAddMount = nextAvailableMount("~/Nextcloud (Cloud)")
    } else {
      cloudAddRemoteName = nextAvailableRemote("cloud")
      cloudAddFolder = nextAvailableFolder("~/Cloud")
      cloudAddMount = nextAvailableMount("~/Cloud (Browse)")
    }
  }

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
    var cmd = path && path !== "" ? "omarchy-ntfs-fix " + Model.shellQuote(path) : "omarchy-ntfs-fix"
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
    } else {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    }
  }

  function runSpeedTest(mountpoint) {
    var cmd = "omarchy-disk-speedtest " + Model.shellQuote(mountpoint || "/tmp")
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
    } else {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    }
  }

  function runBtrfsScrub(mountpoint) {
    var cmd = "omarchy-drive-scrub " + Model.shellQuote(mountpoint || "/")
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
    } else {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    }
  }

  function runTrim(mountpoint) {
    var cmd = "omarchy-drive-trim " + Model.shellQuote(mountpoint || "/")
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
    } else {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    }
  }

  function runFlash(devicePath) {
    var cmd = "omarchy-drive-flash " + Model.shellQuote(devicePath || "")
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
    } else {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", cmd])
    }
  }

  function runRecovery(targetPath) {
    var cmd = "omarchy-drive-recover " + Model.shellQuote(targetPath || "")
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
    for (var i = 0; i < drives.visibleNetworkShares.length; i++) {
      if (networkShareMatchesFilter(drives.visibleNetworkShares[i], filterQuery)) count++
    }
    return count
  }

  readonly property bool alwaysShow: setting("alwaysShow", false) === true
  readonly property bool openOnMount: setting("openOnMount", true) === true

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property string labelMode: vertical ? "none" : String(setting("barLabel", "none"))
  readonly property string barLabel: Model.barLabelText(devices, labelMode)
  // A removable drive still busy says "do not remove"; any other write - the
  // system disk, an internal drive, a cloud sync - says what is being written
  // and how fast. Either way the bar icon turns urgent and pulses, and shows
  // the icon of the storage being written.
  readonly property bool writingActive: drives.anyBusy || drives.writing !== null
  readonly property string statusLine: drives.anyBusy
    ? (Model.formatRate(drives.totalWriteRate) !== ""
        ? "Writing " + Model.formatRate(drives.totalWriteRate) + " — do not remove"
        : "Busy — do not remove")
    : (drives.writing ? Model.writingText(drives.writing) : Model.summary(devices))
  readonly property string barTooltip: statusLine
  readonly property string barIcon: drives.writing ? drives.writing.glyph : Model.barGlyph(devices)

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

  // Device path of the drive being wiped whole, "" when none is. Shares the
  // type and quick/zero choice with the volume form; only one is ever open.
  property string formattingDevicePath: ""

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

  // Enter on a drive ejects it — but only a drive that can be pulled out. On
  // an internal disk it opens the drive's drawer instead of powering it off.
  function activateCursor() {
    if (!currentRow) return
    if (currentRow.kind === "device") {
      var device = currentDevice()
      if (Model.isEjectable(device)) drives.eject(device)
      else if (device) toggleDeviceTools(device.path)
    }
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

  // A refusal is said in the status line rather than leaving the button dead,
  // so "Unmount it first" reads as the next step instead of a broken button.
  function beginFormat(volume) {
    if (!volume) return
    var refusal = Model.canFormat(drives.fsCapabilities, volume, drives.deviceOfVolume(volume))
    if (refusal !== null) {
      drives.refuse(refusal)
      return
    }
    expandedVolumePath = volume.fsPath
    renamingKey = ""
    renamingLabelPath = ""
    unlockingPath = ""
    formattingDevicePath = ""
    var types = Model.formatTypes(drives.fsCapabilities)
    formatType = types.indexOf(volume.fstype) !== -1 ? volume.fstype : (types.length > 0 ? types[0] : "")
    formatQuick = true
    formattingPath = volume.fsPath
  }

  function finishFormat() {
    formattingPath = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function beginDriveFormat(device) {
    if (!device) return
    var refusal = Model.canFormatDrive(drives.fsCapabilities, device)
    if (refusal !== null) {
      drives.refuse(refusal)
      return
    }
    expandedDevicePath = device.path
    renamingKey = ""
    renamingLabelPath = ""
    unlockingPath = ""
    formattingPath = ""
    var types = Model.formatTypes(drives.fsCapabilities)
    formatType = types.length > 0 ? types[0] : ""
    formatQuick = true
    formattingDevicePath = device.path
  }

  function finishDriveFormat() {
    formattingDevicePath = ""
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
    if (Model.isEjectable(device)) drives.eject(device)
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
    if (formattingDevicePath !== "" && !drives.deviceByPath(formattingDevicePath)) formattingDevicePath = ""
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
    formattingDevicePath = ""
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

    function formatDrive(path: string, fstype: string, name: string): string {
      var device = drives.deviceByPath(path)
      if (!device) return "unknown device: " + path
      return drives.formatDrive(device, fstype, name, true)
    }

    function unmountAll(path: string): string {
      var device = drives.deviceByPath(path)
      if (!device) return "unknown device: " + path
      if (device.isSystem) return "refusing the system drive"
      drives.unmountAll(device)
      return "ok"
    }

    // The same rows the info grids draw, as an object, for a drive or a volume.
    function info(path: string): string {
      var device = drives.deviceByPath(path)
      var rows = device ? drives.deviceInfoFor(device) : null
      if (!rows) {
        var volume = drives.volumeByPath(path)
        if (!volume) return "unknown device or volume: " + path
        rows = drives.volumeInfoFor(volume)
      }
      var out = {}
      for (var i = 0; i < rows.length; i++) out[rows[i][0]] = rows[i][1]
      return JSON.stringify(out)
    }

    function phones(): string { return JSON.stringify(drives.portables) }
    function network(): string { return JSON.stringify(drives.networkShares) }
    function cloud(): string { return JSON.stringify(drives.cloudAccounts) }

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

    // Opens the panel on one cloud account's detail view.
    function openCloud(remote: string): string {
      if (!drives.hasCloudAccount(remote)) return "unknown cloud account: " + remote
      root.activeTab = "network"
      root.openCloudAccount(remote)
      root.open()
      return "ok"
    }

    // Opens the panel on one drive with its details (Drive Info) open:
    // `omarchy-shell storage-drives showDrive /dev/sda`.
    function showDrive(path: string): string {
      var device = drives.deviceByPath(path)
      if (!device) return "unknown device: " + path
      root.activeTab = "local"
      root.expandedDevicePath = device.path
      root.open()
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
        writing: drives.writing ? { kind: drives.writing.kind, name: drives.writing.name,
                                    rate: Math.round(drives.writing.rate) } : null,
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

    // A slow pulse while storage is being written, back to steady after.
    SequentialAnimation on opacity {
      running: root.writingActive
      loops: Animation.Infinite
      NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
      onRunningChanged: if (!running) button.opacity = 1
    }
  }

  Component {
    id: iconButton

    BarIconButton {
      anchors.fill: parent
      bar: root.bar
      text: root.barIcon
      tooltipText: root.hasUnmountedNtfs
        ? root.barTooltip + " · Unmounted NTFS partitions detected (click to manage/fix)"
        : root.barTooltip
      active: root.writingActive || root.hasUnmountedNtfs
      activeColor: root.writingActive ? root.urgent : (bar && "activeColor" in bar ? bar.activeColor : root.foreground)
      useActiveColor: true
      onPressed: function(buttonCode) { root.handleBarPress(buttonCode) }
    }
  }

  Component {
    id: labelledButton

    WidgetButton {
      anchors.fill: parent
      bar: root.bar
      text: root.barIcon + "  " + root.barLabel
      tooltipText: root.hasUnmountedNtfs
        ? root.barTooltip + " · Unmounted NTFS partitions detected (click to manage/fix)"
        : root.barTooltip
      active: root.writingActive || root.hasUnmountedNtfs
      activeColor: root.writingActive ? root.urgent : (bar && "activeColor" in bar ? bar.activeColor : root.foreground)
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
        || root.formattingDevicePath !== "" || root.cloudAddOpen

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
        if (text === "r" || text === "R") root.rescanAll()
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
          if (root.currentRow && root.currentRow.kind === "volume") root.beginFormat(root.currentVolume())
          else if (root.currentRow && root.currentRow.kind === "device") root.beginDriveFormat(root.currentDevice())
        }
        else if (text === "i" || text === "I") {
          if (root.currentRow && root.currentRow.kind === "volume" && root.currentVolume()) {
            root.toggleVolumeDrawer(root.currentVolume().fsPath)
          } else if (root.currentDevice()) {
            root.toggleDeviceTools(root.currentDevice().path)
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
            title: root.activeTab === "network" ? "Network Storage" : "Storage Drives"
            meta: root.activeTab === "network"
              ? Model.cloudOverview(drives.cloudAccounts, drives.cloudStatuses, drives.cloudConflicts, drives.networkCount)
              : root.statusLine
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.activeTab === "network"
                  ? (drives.writing && drives.writing.kind === "cloud" ? drives.writing.glyph : Model.GLYPH_SERVER)
                  : root.barIcon
                color: root.writingActive ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(2)

                PanelActionButton {
                  visible: root.hasUnmountedNtfs && drives.hasTool("omarchy-ntfs-fix")
                  iconText: Model.GLYPH_WRENCH
                  tooltipText: "Fix & Mount All NTFS Partitions"
                  foreground: root.urgent
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.runNtfsFix("")
                }

                PanelActionButton {
                  visible: drives.ejectableDevices.length > 1
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
                  onClicked: root.rescanAll()
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
                    text: "Network & Cloud (" + (drives.networkCount + drives.cloudAccountCount) + ")"
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
                  text: drives.hasTool("omarchy-ntfs-fix")
                    ? "Windows dirty bit may prevent mounting. Auto-repair is ready."
                    : "Windows dirty bit may prevent mounting. Check the volume to offer a repair."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              ActionChip {
                visible: drives.hasTool("omarchy-ntfs-fix")
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
              iconText: Model.GLYPH_CLOSE
              tooltipText: "Ask " + Model.describeBlockers(drives.blockers) + " to close, then try again"
              foreground: root.foreground
              hoverColor: root.urgent
              fontFamily: root.fontFamily
              enabled: !drives.busy
              Layout.alignment: Qt.AlignVCenter
              onClicked: drives.closeBlockersAndRetry()
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

          // Unflushed writes. System-wide — the kernel does not split it per
          // device — so it is only a hint, shown while a removable drive is
          // mounted and the amount is big enough to take noticeable time.
          Text {
            textFormat: Text.PlainText
            visible: root.activeTab === "local" && drives.dirtyBytes >= 8 * 1024 * 1024
              && Model.suspendTargets(drives.ejectableDevices).length > 0
            width: parent.width
            text: Model.formatBytes(drives.dirtyBytes) + " written but not yet flushed to disk — eject writes it out first"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
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

          // rclone Missing Warning Banner
          Rectangle {
            visible: root.activeTab === "network" && !drives.rcloneInstalled
            width: parent.width
            radius: Style.space(8)
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.08)
            border.width: 1
            border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.3)
            implicitHeight: rcloneWarnCol.implicitHeight + Style.space(20)

            ColumnLayout {
              id: rcloneWarnCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: Model.GLYPH_ALERT
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "rclone is required for cloud drives"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "rclone is not installed. It is required to connect, sync, and mount Google Drive, Mega, OneDrive, and other cloud storage accounts."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              // Installed through Omarchy's own package picker, never from here.
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: drives.rcloneWaiting
                  ? "Waiting for rclone to be installed. This goes away by itself once it is."
                  : (drives.rcloneFuse
                     ? "Install it from the Omarchy menu (Super + Space) \u203a Install \u203a Package: paste the copied search, then Enter."
                     : "Install rclone and fuse3 from the Omarchy menu (Super + Space) \u203a Install \u203a Package: paste the copied search, press Tab on each, then Enter.")
                color: drives.rcloneWaiting ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Flow {
                Layout.fillWidth: true
                spacing: Style.space(8)

                ActionChip {
                  label: "Copy search"
                  iconText: Model.GLYPH_COPY
                  tooltipText: "Copy " + drives.rcloneSearch + " for the Omarchy package picker"
                  onClicked: drives.copyRcloneSearch()
                }

                ActionChip {
                  label: "Open Install menu"
                  iconText: Model.GLYPH_MOUNT
                  tooltipText: "Copy the search and open the Omarchy menu at Install"
                  danger: true
                  onClicked: drives.installRclone()
                }

                ActionChip {
                  label: "Terminal Setup"
                  iconText: Model.GLYPH_TERMINAL
                  tooltipText: "Open terminal to configure rclone"
                  onClicked: drives.launchRcloneTerminal("rclone config")
                }
              }
            }
          }

          // ====================================================================
          // CASE A: Cloud Drive Detail View (when an account is selected)
          // ====================================================================
          Column {
            visible: root.activeTab === "network" && drives.selectedCloudRemote !== ""
            width: parent.width
            spacing: Style.space(12)

            // Top navigation row
            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              ActionChip {
                label: "Back"
                iconText: Model.GLYPH_ARROW_LEFT
                tooltipText: "Return to cloud accounts list"
                onClicked: {
                  drives.selectedCloudRemote = ""
                  root.cloudConfigDrawerOpen = false
                }
              }

              Item { Layout.fillWidth: true }

              ActionChip {
                label: drives.cloudFoldersLoading ? "Reading…" : "Refresh"
                iconText: Model.GLYPH_REFRESH
                tooltipText: "Reload cloud folders and sync status"
                onClicked: {
                  drives.refreshCloudStatus(drives.selectedCloudRemote)
                  drives.refreshCloudFolders(drives.selectedCloudRemote)
                }
              }
            }

            // Cloud Drive Hero & Controls Box
            Rectangle {
              width: parent.width
              radius: Style.space(10)
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
              border.width: 1
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
              implicitHeight: cloudHeroLayout.implicitHeight + Style.space(20)

              ColumnLayout {
                id: cloudHeroLayout
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(10)

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(10)

                  // Icon
                  Rectangle {
                    implicitWidth: Style.space(38)
                    implicitHeight: Style.space(38)
                    radius: Style.space(8)
                    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                    border.width: 1
                    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                    Layout.alignment: Qt.AlignVCenter

                    GoogleDriveIcon {
                      visible: !!(drives.selectedCloudAccount && drives.selectedCloudAccount.type === "drive")
                      anchors.centerIn: parent
                      iconSize: Style.font.iconLarge || Style.space(22)
                      color: root.foreground
                    }

                    Text {
                      visible: !(drives.selectedCloudAccount && drives.selectedCloudAccount.type === "drive")
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: drives.selectedCloudAccount ? Model.cloudProviderGlyph(drives.selectedCloudAccount.type) : Model.GLYPH_CLOUD
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.iconLarge || Style.space(20)
                    }
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(2)

                    // Row 1: Remote Name + Provider Tag + Status Tag
                    RowLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      Text {
                        textFormat: Text.PlainText
                        text: drives.selectedCloudRemote
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodyLarge || Style.space(15)
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Rectangle {
                        implicitWidth: provTag.implicitWidth + Style.space(10)
                        implicitHeight: provTag.implicitHeight + Style.space(4)
                        radius: Style.space(3)
                        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                        border.width: 1
                        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
                        Layout.alignment: Qt.AlignVCenter

                        Text {
                          id: provTag
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: drives.selectedCloudAccount ? Model.cloudProviderLabel(drives.selectedCloudAccount.type).toUpperCase() : "CLOUD"
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.captionSmall || Style.space(9)
                          font.bold: true
                        }
                      }

                      Rectangle {
                        visible: drives.selectedCloudStatus.statusText !== ""
                        implicitWidth: detailStTag.implicitWidth + Style.space(10)
                        implicitHeight: detailStTag.implicitHeight + Style.space(4)
                        radius: Style.space(3)
                        color: drives.selectedCloudStatus.lastResult === "error"
                          ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.15)
                          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                        border.width: 1
                        border.color: drives.selectedCloudStatus.lastResult === "error"
                          ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.3)
                          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
                        Layout.alignment: Qt.AlignVCenter

                        Text {
                          id: detailStTag
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: drives.selectedCloudStatus.statusText
                          color: drives.selectedCloudStatus.lastResult === "error" ? root.urgent : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.captionSmall || Style.space(9)
                        }
                      }
                    }

                    // Row 2: Account Identity
                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: drives.selectedCloudStatus.accountEmail !== ""
                        ? (drives.selectedCloudStatus.accountName !== "" ? drives.selectedCloudStatus.accountEmail + " (" + drives.selectedCloudStatus.accountName + ")" : drives.selectedCloudStatus.accountEmail)
                        : (drives.selectedCloudStatus.authenticated ? Model.shortHomePath(drives.selectedCloudStatus.folderPath, drives.homePath)
                           : (drives.selectedCloudStatus.statusText === "Checking…" ? "Checking…" : "Not signed in to rclone"))
                      color: drives.selectedCloudStatus.accountEmail !== "" ? root.foreground : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: drives.selectedCloudStatus.accountEmail !== ""
                      elide: Text.ElideRight
                    }

                    // Row 3: Folders & Storage summary
                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: Model.cloudSummary(drives.selectedCloudStatus)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }

                // Quota bar for the account as a whole.
                Rectangle {
                  visible: drives.selectedCloudStatus.quotaKnown
                  Layout.fillWidth: true
                  implicitHeight: Math.max(3, Style.space(4))
                  radius: height / 2
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

                  Rectangle {
                    readonly property real fraction: Model.cloudUsageFraction(drives.selectedCloudStatus)
                    readonly property bool hot: Model.cloudOverQuota(drives.selectedCloudStatus)
                      || fraction >= drives.fullWarnPct / 100
                    width: Math.max(fraction > 0 ? 2 : 0, parent.width * fraction)
                    height: parent.height
                    radius: parent.radius
                    color: hot ? root.urgent : root.foreground
                    opacity: hot ? 1 : 0.6
                  }
                }

                // Shared-folder warning, with the fix one click away.
                Rectangle {
                  readonly property string reason: drives.cloudConflicts[drives.selectedCloudRemote] || ""
                  readonly property string other: drives.selectedCloudStatus.browseConflict || ""
                  visible: reason !== "" || other !== ""
                  Layout.fillWidth: true
                  radius: Style.space(6)
                  color: Qt.rgba(root.warnColor.r, root.warnColor.g, root.warnColor.b, 0.1)
                  border.width: 1
                  border.color: Qt.rgba(root.warnColor.r, root.warnColor.g, root.warnColor.b, 0.35)
                  implicitHeight: conflictText.implicitHeight + Style.space(14)

                  Text {
                    id: conflictText
                    anchors.fill: parent
                    anchors.margins: Style.space(7)
                    textFormat: Text.PlainText
                    text: (parent.reason !== "" ? parent.reason : "The browse folder is mounted for '" + parent.other + "'")
                      + ". Two accounts sharing a folder mount or sync the wrong drive — give this one its own browse folder below."
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }

                // Action status or error banner
                Text {
                  visible: text !== ""
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: drives.cloudActionStatus !== "" ? drives.cloudActionStatus
                    : (drives.selectedCloudStatus.lastError !== "" ? drives.selectedCloudStatus.lastError
                      : (drives.cloudFoldersError !== "" ? drives.cloudFoldersError : drives.selectedCloudStatus.warning))
                  color: (drives.selectedCloudStatus.lastError !== "" || drives.cloudFoldersError !== "") && drives.cloudActionStatus === ""
                    ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                // Live Transfer Activity Card
                Rectangle {
                  visible: drives.selectedCloudStatus.syncing
                  Layout.fillWidth: true
                  radius: Style.space(6)
                  color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.08)
                  border.width: 1
                  border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.25)
                  implicitHeight: liveColSD.implicitHeight + Style.space(16)

                  ColumnLayout {
                    id: liveColSD
                    anchors.fill: parent
                    anchors.margins: Style.space(8)
                    spacing: Style.space(4)

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      Text {
                        text: Model.GLYPH_REFRESH
                        color: root.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }

                      ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(2)

                        Text {
                          textFormat: Text.PlainText
                          Layout.fillWidth: true
                          text: (drives.selectedCloudStatus.activeTransfers && drives.selectedCloudStatus.activeTransfers.length > 0)
                            ? drives.selectedCloudStatus.activeTransfers[0].name
                            : "Syncing in progress…"
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          elide: Text.ElideMiddle
                        }

                        Text {
                          textFormat: Text.PlainText
                          Layout.fillWidth: true
                          text: {
                            var ts = drives.selectedCloudStatus.transferStats || {}
                            var parts = []
                            if (ts.speed) parts.push(Model.formatBytes(ts.speed) + "/s")
                            if (ts.transfers !== undefined && ts.totalTransfers !== undefined && ts.totalTransfers > 0) {
                              parts.push(ts.transfers + " of " + ts.totalTransfers + " files")
                            }
                            if (ts.bytes && ts.totalBytes) {
                              parts.push(Model.formatBytes(ts.bytes) + " of " + Model.formatBytes(ts.totalBytes))
                            }
                            return parts.length > 0 ? parts.join(" • ") : "Syncing files with cloud…"
                          }
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.captionSmall || Style.space(9)
                        }
                      }
                    }

                    Rectangle {
                      Layout.fillWidth: true
                      visible: !!(drives.selectedCloudStatus.transferStats && drives.selectedCloudStatus.transferStats.totalBytes > 0)
                      height: Style.space(4)
                      radius: height / 2
                      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)

                      Rectangle {
                        readonly property real pct: (drives.selectedCloudStatus.transferStats && drives.selectedCloudStatus.transferStats.totalBytes > 0)
                          ? Math.min(1, Math.max(0, drives.selectedCloudStatus.transferStats.bytes / drives.selectedCloudStatus.transferStats.totalBytes))
                          : 0
                        width: parent.width * pct
                        height: parent.height
                        radius: height / 2
                        color: root.accent
                      }
                    }
                  }
                }

                // Conflict Warning Card
                Rectangle {
                  visible: !!(drives.selectedCloudStatus.conflictCount > 0)
                  Layout.fillWidth: true
                  radius: Style.space(6)
                  color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.08)
                  border.width: 1
                  border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.25)
                  implicitHeight: conflictColSD.implicitHeight + Style.space(16)

                  ColumnLayout {
                    id: conflictColSD
                    anchors.fill: parent
                    anchors.margins: Style.space(8)
                    spacing: Style.space(4)

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      Text {
                        text: Model.GLYPH_ALERT
                        color: root.urgent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }

                      ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(2)

                        Text {
                          textFormat: Text.PlainText
                          Layout.fillWidth: true
                          text: drives.selectedCloudStatus.conflictCount + " Conflicted File" + (drives.selectedCloudStatus.conflictCount === 1 ? "" : "s")
                          color: root.urgent
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }

                        Text {
                          textFormat: Text.PlainText
                          Layout.fillWidth: true
                          text: "Files edited simultaneously in both places. Preserved with .conflict extension."
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.captionSmall || Style.space(9)
                        }
                      }
                    }
                  }
                }

                // Notice if not authenticated in rclone
                Rectangle {
                  visible: !drives.selectedCloudStatus.authenticated && drives.rcloneInstalled
                    && drives.selectedCloudStatus.statusText !== "Checking…"
                  Layout.fillWidth: true
                  radius: Style.space(6)
                  color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.08)
                  border.width: 1
                  border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.25)
                  implicitHeight: unauthCol.implicitHeight + Style.space(16)

                  ColumnLayout {
                    id: unauthCol
                    anchors.fill: parent
                    anchors.margins: Style.space(8)
                    spacing: Style.space(4)

                    Text {
                      textFormat: Text.PlainText
                      text: "Remote '" + drives.selectedCloudRemote + "' is not yet configured in rclone"
                      color: root.urgent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: "Authenticate this remote in your browser to start syncing."
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Flow {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      ActionChip {
                        label: "Authorize in Browser"
                        iconText: Model.GLYPH_UNLOCKED
                        danger: true
                        tooltipText: "Trigger browser authentication for this remote"
                        onClicked: drives.authenticateCloudRemote(drives.selectedCloudRemote, drives.selectedCloudAccount ? drives.selectedCloudAccount.type : "drive")
                      }

                      ActionChip {
                        readonly property string key: "purge:" + drives.selectedCloudRemote
                        label: root.armedCloudAction === key ? "Click again to delete" : "Delete Account"
                        iconText: Model.GLYPH_TRASH
                        danger: true
                        tooltipText: "Remove this account from Storage Drives and its sign-in from rclone. Files in the cloud and on disk are kept."
                        onClicked: root.armOrRun(key, function() { drives.removeCloudAccount(drives.selectedCloudRemote, true) })
                      }
                    }
                  }
                }

                // Info Pairs (Disk usage, Cloud storage, Sync folder, Browse mount, Last sync)
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(4)

                  RowLayout {
                    visible: drives.selectedCloudStatus.accountEmail !== ""
                    Layout.fillWidth: true
                    Text { text: "Account"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    Item { Layout.fillWidth: true }
                    Text {
                      Layout.maximumWidth: parent.width * 0.62
                      text: drives.selectedCloudStatus.accountEmail + (drives.selectedCloudStatus.accountName !== "" ? " (" + drives.selectedCloudStatus.accountName + ")" : "")
                      color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
                      elide: Text.ElideMiddle
                    }
                  }

                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "On disk"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    Item { Layout.fillWidth: true }
                    Text {
                      text: (drives.selectedCloudStatus.localBytesApprox ? "≈ " : "") + Model.formatCloudBytes(drives.selectedCloudStatus.localBytes)
                      color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
                    }
                  }

                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "In Cloud"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    Item { Layout.fillWidth: true }
                    Text {
                      text: Model.cloudSpaceText(drives.selectedCloudStatus) || "—"
                      color: Model.cloudOverQuota(drives.selectedCloudStatus) ? root.urgent : root.foreground
                      font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
                    }
                  }

                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Synced folder"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    Item { Layout.fillWidth: true }
                    Text {
                      Layout.maximumWidth: parent.width * 0.62
                      text: Model.shortHomePath(drives.selectedCloudStatus.folderPath, drives.homePath)
                      color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideMiddle
                    }
                  }

                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Browse mount"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    Item { Layout.fillWidth: true }
                    Text {
                      Layout.maximumWidth: parent.width * 0.62
                      text: Model.shortHomePath(drives.selectedCloudStatus.mountPath, drives.homePath) + (drives.selectedCloudStatus.browseMounted ? " (mounted)" : "")
                      color: drives.selectedCloudStatus.browseMounted ? root.foreground : root.dim
                      font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideMiddle
                    }
                  }

                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Last sync"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    Item { Layout.fillWidth: true }
                    Text {
                      text: drives.selectedCloudStatus.syncing ? "Syncing now" : Model.relativeTime(drives.selectedCloudStatus.lastFinishedTs)
                      color: drives.selectedCloudStatus.syncing ? root.foreground : root.dim
                      font.family: root.fontFamily; font.pixelSize: Style.font.caption
                    }
                  }

                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Auto-sync"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                      implicitHeight: Style.space(18)
                      implicitWidth: autoSyncText.implicitWidth + Style.space(12)
                      radius: Style.space(3)
                      color: autoSyncMouse.containsMouse
                        ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                        : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                      border.width: 1
                      border.color: drives.selectedCloudStatus.timerEnabled
                        ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
                        : Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.25)

                      MouseArea {
                        id: autoSyncMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: drives.setCloudAutoSync(drives.selectedCloudRemote, !drives.selectedCloudStatus.timerEnabled, drives.selectedCloudAccount ? drives.selectedCloudAccount.syncIntervalMin : 10)
                      }

                      Text {
                        id: autoSyncText
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: drives.selectedCloudStatus.timerEnabled
                          ? "Active (" + (drives.selectedCloudAccount ? drives.selectedCloudAccount.syncIntervalMin : 10) + "m)"
                          : "Paused"
                        color: drives.selectedCloudStatus.timerEnabled ? root.foreground : root.urgent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.captionSmall || Style.space(9)
                        font.bold: true
                      }
                    }
                  }
                }

                // Action buttons — wrap onto a second row rather than squeeze.
                Flow {
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  ActionChip {
                    label: drives.selectedCloudStatus.syncing ? "Syncing…" : "Sync now"
                    iconText: Model.GLYPH_REFRESH
                    active: drives.selectedCloudStatus.syncing
                    tooltipText: "Run two-way sync with cloud remote"
                    enabled: !drives.selectedCloudStatus.syncing && drives.selectedCloudStatus.authenticated
                    opacity: enabled ? 1 : 0.5
                    onClicked: drives.syncCloudNow(drives.selectedCloudRemote, false)
                  }

                  ActionChip {
                    label: "Open"
                    iconText: Model.GLYPH_FOLDER
                    tooltipText: "Open synced folder in file manager"
                    onClicked: drives.openCloudFolder(drives.selectedCloudStatus.folderPath)
                  }

                  ActionChip {
                    label: drives.selectedCloudStatus.browseMounted ? "Browsing" : "Browse"
                    iconText: drives.selectedCloudStatus.browseMounted ? Model.GLYPH_HEALTHY : Model.GLYPH_CLOUD
                    active: drives.selectedCloudStatus.browseMounted
                    tooltipText: drives.selectedCloudStatus.browseMounted ? "Unmount read-only browse view" : "Mount full remote read-only without downloading"
                    onClicked: drives.toggleCloudBrowse(drives.selectedCloudRemote)
                  }

                  ActionChip {
                    label: "Config"
                    iconText: Model.GLYPH_COG
                    active: root.cloudConfigDrawerOpen
                    tooltipText: "Configure drive settings or disconnect"
                    onClicked: root.cloudConfigDrawerOpen = !root.cloudConfigDrawerOpen
                  }
                }

                // Inline Config Drawer
                Rectangle {
                  visible: root.cloudConfigDrawerOpen
                  Layout.fillWidth: true
                  radius: Style.space(6)
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
                  border.width: 1
                  border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                  implicitHeight: cfgDrawerCol.implicitHeight + Style.space(16)

                  ColumnLayout {
                    id: cfgDrawerCol
                    anchors.fill: parent
                    anchors.margins: Style.space(8)
                    spacing: Style.space(6)

                    Text {
                      textFormat: Text.PlainText
                      text: "Drive Configuration"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    Flow {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      ActionChip {
                        label: drives.selectedCloudStatus.timerEnabled ? "Pause Auto-sync" : "Resume Auto-sync"
                        iconText: drives.selectedCloudStatus.timerEnabled ? Model.GLYPH_HEALTHY : Model.GLYPH_REFRESH
                        active: drives.selectedCloudStatus.timerEnabled
                        onClicked: drives.setCloudAutoSync(drives.selectedCloudRemote, !drives.selectedCloudStatus.timerEnabled, drives.selectedCloudAccount ? drives.selectedCloudAccount.syncIntervalMin : 10)
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: "Auto-sync interval: " + (drives.selectedCloudAccount ? drives.selectedCloudAccount.syncIntervalMin : 10) + " minutes"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Flow {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      Repeater {
                        model: [5, 10, 15, 30, 60, 180]

                        ActionChip {
                          required property int modelData
                          readonly property int current: drives.selectedCloudAccount
                            ? (drives.selectedCloudAccount.syncIntervalMin || 10) : 10
                          label: modelData < 60 ? modelData + " min" : (modelData / 60) + " h"
                          active: current === modelData
                          onClicked: drives.setCloudInterval(drives.selectedCloudRemote, modelData)
                        }
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: "Browse folder"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      topPadding: Style.space(4)
                    }

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      TextField {
                        id: cloudMountField
                        Layout.fillWidth: true
                        foreground: root.foreground
                        verticalPadding: Style.space(2)
                        text: root.cloudMountDraft
                        onTextChanged: root.cloudMountDraft = text
                        placeholderText: "e.g. ~/Google Drive 2 (Cloud)"
                        onAccepted: if (mountSave.enabled) drives.changeCloudMount(drives.selectedCloudRemote, root.cloudMountDraft)
                      }

                      ActionChip {
                        id: mountSave
                        readonly property bool changed: drives.selectedCloudAccount
                          && root.cloudMountDraft.trim() !== String(drives.selectedCloudAccount.browseMountPath || "")
                        label: "Move"
                        iconText: Model.GLYPH_FOLDER
                        enabled: changed && mountCheck.ok && !drives.cloudBusy
                        opacity: enabled ? 1 : 0.5
                        tooltipText: "Unmount at the old folder and mount at this one"
                        onClicked: drives.changeCloudMount(drives.selectedCloudRemote, root.cloudMountDraft)
                      }
                    }

                    Text {
                      id: mountCheckText
                      readonly property var check: drives.selectedCloudAccount
                        ? Model.validateCloudAccount(drives.cloudAccounts,
                            Object.assign({}, drives.selectedCloudAccount, { browseMountPath: root.cloudMountDraft }),
                            drives.homePath, drives.selectedCloudRemote)
                        : ({ ok: true, reason: "" })
                      visible: !check.ok
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: check.reason
                      color: root.urgent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }

                    QtObject {
                      id: mountCheck
                      readonly property bool ok: mountCheckText.check.ok
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: "Troubleshooting"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      topPadding: Style.space(4)
                    }

                    Flow {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      ActionChip {
                        label: "View sync log"
                        iconText: Model.GLYPH_TERMINAL
                        tooltipText: "Open this account's sync log at its last lines, where a failed run says why"
                        onClicked: drives.openCloudLog(drives.selectedCloudRemote)
                      }

                      ActionChip {
                        label: "Resync"
                        iconText: Model.GLYPH_REFRESH
                        tooltipText: "Rebuild the sync baseline: merges both sides, newer file wins. Use after a failed or interrupted sync."
                        enabled: !drives.selectedCloudStatus.syncing && drives.selectedCloudStatus.authenticated
                        opacity: enabled ? 1 : 0.5
                        onClicked: drives.syncCloudNow(drives.selectedCloudRemote, true)
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: "Account Management"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      topPadding: Style.space(4)
                    }

                    Flow {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      ActionChip {
                        label: "Re-authenticate"
                        iconText: Model.GLYPH_UNLOCKED
                        tooltipText: "Reconnect or refresh browser authorization token for this remote"
                        onClicked: drives.authenticateCloudRemote(drives.selectedCloudRemote, drives.selectedCloudAccount ? drives.selectedCloudAccount.type : "drive")
                      }

                      ActionChip {
                        readonly property string key: "disconnect:" + drives.selectedCloudRemote
                        label: root.armedCloudAction === key ? "Click again to disconnect" : "Disconnect"
                        iconText: Model.GLYPH_EJECT
                        tooltipText: "Remove from Storage Drives. The rclone sign-in and every file are kept."
                        onClicked: root.armOrRun(key, function() { drives.removeCloudAccount(drives.selectedCloudRemote, false) })
                      }

                      ActionChip {
                        readonly property string key: "purge:" + drives.selectedCloudRemote
                        label: root.armedCloudAction === key ? "Click again to delete" : "Delete from rclone"
                        iconText: Model.GLYPH_TRASH
                        danger: true
                        tooltipText: "Disconnect and delete the rclone remote (its sign-in). Files in the cloud and on disk are kept."
                        onClicked: root.armOrRun(key, function() { drives.removeCloudAccount(drives.selectedCloudRemote, true) })
                      }
                    }
                  }
                }
              }
            }

            // Folders list
            Column {
              id: foldersListCol
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: "FOLDERS TO KEEP ON DISK"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.captionSmall || Style.space(9)
                font.bold: true
              }

              // Inside a folder: the path back up (the first crumb is the
              // drive's top), and the folder kept as a whole.
              Flow {
                visible: drives.cloudSubPath !== ""
                width: parent.width
                spacing: Style.space(4)
                Repeater {
                  model: drives.cloudSubPath !== "" ? [""].concat(drives.cloudSubPath.split("/")) : []
                  Row {
                    required property string modelData
                    required property int index
                    readonly property bool here: index === drives.cloudSubPath.split("/").length
                    spacing: Style.space(4)
                    Text {
                      visible: index > 0
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: "󰅂"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: index === 0 ? "Top" : modelData
                      color: here ? root.foreground : root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: here
                      MouseArea {
                        anchors.fill: parent
                        enabled: !parent.parent.here
                        cursorShape: Qt.PointingHandCursor
                        onClicked: drives.refreshCloudSubfolders(drives.selectedCloudRemote, drives.cloudSubPath.split("/").slice(0, index).join("/"))
                      }
                    }
                  }
                }
              }

              Rectangle {
                id: subSelf
                readonly property string name: drives.cloudSubPath.split("/").pop()
                readonly property var folder: ({ name: name, path: drives.cloudSubPath, state: drives.cloudSubState, covered: drives.cloudSubCovered })
                readonly property string state: drives.cloudFolderState(folder)
                visible: drives.cloudSubPath !== "" && drives.cloudSubState !== ""
                width: foldersListCol.width
                radius: Style.space(6)
                color: selfMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.02)
                border.width: 1
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                implicitHeight: selfRow.implicitHeight + Style.space(12)

                MouseArea {
                  id: selfMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: drives.toggleCloudFolder(drives.selectedCloudRemote, subSelf.folder)
                }

                RowLayout {
                  id: selfRow
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  anchors.topMargin: Style.space(8)
                  anchors.bottomMargin: Style.space(8)
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    Layout.preferredWidth: Style.space(20)
                    horizontalAlignment: Text.AlignHCenter
                    text: Model.cloudStateGlyph(subSelf.state)
                    color: subSelf.state === "off" ? root.dim : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(1)
                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: "All of " + subSelf.name
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }
                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: subSelf.state === "on" ? "Everything in it syncs, new folders too"
                        : subSelf.state === "partial" ? "Only what is ticked below syncs"
                        : "Nothing in it syncs: tick folders below, or all of it"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: drives.cloudSubPath !== "" ? drives.cloudSubLoading && drives.cloudSubfolders.length === 0 : drives.cloudFoldersLoading && drives.cloudFolders.length === 0
                width: parent.width
                text: drives.cloudSubPath !== "" ? "Reading " + drives.cloudSubPath.split("/").pop() + "…" : "Reading your cloud folders…"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
                topPadding: Style.space(8)
                bottomPadding: Style.space(8)
              }

              Text {
                textFormat: Text.PlainText
                visible: drives.cloudSubPath !== "" ? !drives.cloudSubLoading && drives.cloudSubfolders.length === 0 : !drives.cloudFoldersLoading && drives.cloudFolders.length === 0
                width: parent.width
                text: drives.cloudSubPath !== "" ? (drives.cloudSubError || "No folders inside, only files") : "No folders found in this drive"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
                topPadding: Style.space(8)
                bottomPadding: Style.space(8)
              }

              // Root files row
              Rectangle {
                visible: drives.cloudSubPath === ""
                width: foldersListCol.width
                radius: Style.space(6)
                color: rootMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.02)
                border.width: 1
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                implicitHeight: rootFilesRow.implicitHeight + Style.space(12)

                MouseArea {
                  id: rootMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: drives.setCloudRootFiles(drives.selectedCloudRemote, !drives.cloudRootFilesShown)
                }

                RowLayout {
                  id: rootFilesRow
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  anchors.topMargin: Style.space(8)
                  anchors.bottomMargin: Style.space(8)
                  spacing: Style.space(8)

                  Item {
                    implicitWidth: Style.space(20)
                    implicitHeight: Style.space(20)
                    Layout.alignment: Qt.AlignVCenter

                    Text {
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: drives.cloudRootFilesShown ? "󰄲" : "󰄱"
                      color: drives.cloudRootFilesShown ? root.foreground : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.icon
                    }
                  }

                  Item {
                    implicitWidth: Style.space(20)
                    implicitHeight: Style.space(20)
                    Layout.alignment: Qt.AlignVCenter

                    Text {
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: "󰈔"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.icon
                    }
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: Style.space(1)

                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: "Loose files at top of Drive"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: Model.cloudRootFilesMeta(drives.cloudRootFileCount, drives.cloudRootFileBytes) + (drives.cloudRootFilesShown ? "" : " · off unless you turn it on")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }
              }

              // Repeater over cloud folders
              Repeater {
                model: drives.cloudSubPath !== "" ? drives.cloudSubfolders : drives.cloudFolders

                Rectangle {
                  required property var modelData
                  required property int index
                  id: folderItem
                  readonly property string state: drives.cloudFolderState(modelData)

                  width: foldersListCol.width
                  radius: Style.space(6)
                  color: fMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.02)
                  border.width: 1
                  border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                  implicitHeight: fRow.implicitHeight + Style.space(12)

                  MouseArea {
                    id: fMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: drives.toggleCloudFolder(drives.selectedCloudRemote, modelData)
                  }

                  RowLayout {
                    id: fRow
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(10)
                    anchors.topMargin: Style.space(8)
                    anchors.bottomMargin: Style.space(8)
                    spacing: Style.space(8)

                    Item {
                      implicitWidth: Style.space(20)
                      implicitHeight: Style.space(20)
                      Layout.alignment: Qt.AlignVCenter

                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: Model.cloudStateGlyph(folderItem.state)
                        color: folderItem.state === "off" ? root.dim : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.icon
                      }
                    }

                    Item {
                      implicitWidth: Style.space(20)
                      implicitHeight: Style.space(20)
                      Layout.alignment: Qt.AlignVCenter

                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: Model.cloudFolderGlyph(modelData)
                        color: modelData && modelData.stale ? root.urgent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.icon
                      }
                    }

                    ColumnLayout {
                      Layout.fillWidth: true
                      Layout.alignment: Qt.AlignVCenter
                      spacing: Style.space(1)

                      Text {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: modelData ? String(modelData.name || "Untitled") : "Untitled"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        elide: Text.ElideRight
                      }

                      Text {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: Model.cloudFolderMeta(modelData, folderItem.state)
                        color: modelData && modelData.stale ? root.urgent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    // Open it, to keep only some of it or leave parts out.
                    Rectangle {
                      visible: !(modelData && modelData.stale)
                      Layout.alignment: Qt.AlignVCenter
                      implicitWidth: Style.space(26)
                      implicitHeight: Style.space(26)
                      radius: Style.space(13)
                      color: openMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10) : "transparent"
                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: "󰅂"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.icon
                      }
                      MouseArea {
                        id: openMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: drives.refreshCloudSubfolders(drives.selectedCloudRemote, String(modelData.path || modelData.name))
                      }
                    }
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: drives.cloudSubPath !== ""
                  ? "A folder you untick here is left out; the rest keeps syncing."
                  : "Open a folder (󰅂) to keep only some of it, or leave parts out. Add more any time: the next sync brings them down and changes nothing else."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.captionSmall || Style.space(9)
                wrapMode: Text.WordWrap
              }

              // Stale cleanup bar
              Rectangle {
                visible: drives.cloudSubPath === "" && (drives.cloudStaleBytes > 0 || drives.cloudStaleCount > 0)
                width: parent.width
                radius: Style.space(6)
                color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.08)
                border.width: 1
                border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.2)
                implicitHeight: staleLayout.implicitHeight + Style.space(16)

                RowLayout {
                  id: staleLayout
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: Model.cloudStaleMeta(drives.cloudStaleCount, drives.cloudStaleLoose, Model.formatCloudBytes(drives.cloudStaleBytes))
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  ActionChip {
                    label: "Clean up"
                    iconText: Model.GLYPH_TRASH
                    danger: true
                    tooltipText: "Verify files still exist in cloud, then remove local copies"
                    onClicked: drives.cleanupCloudStale(drives.selectedCloudRemote)
                  }
                }
              }
            }

            // Recent Activity Section
            Column {
              visible: !drives.selectedCloudStatus.syncing && !!drives.selectedCloudStatus.recentTransfers && drives.selectedCloudStatus.recentTransfers.length > 0
              width: parent.width
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: "Recent Activity"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                topPadding: Style.space(6)
              }

              Repeater {
                model: (!drives.selectedCloudStatus.syncing && drives.selectedCloudStatus.recentTransfers)
                  ? drives.selectedCloudStatus.recentTransfers.slice(0, 5) : []

                Rectangle {
                  required property var modelData
                  width: parent.width
                  implicitHeight: recentRow.implicitHeight + Style.space(10)
                  radius: Style.space(4)
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)

                  RowLayout {
                    id: recentRow
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(6)

                    Text {
                      text: (modelData.action && modelData.action.indexOf("Deleted") >= 0) ? Model.GLYPH_TRASH : Model.GLYPH_HEALTHY
                      color: (modelData.action && modelData.action.indexOf("Deleted") >= 0) ? root.urgent : root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 0

                      Text {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: modelData.name || "File"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideMiddle
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: (modelData.action || "Synced") + (modelData.size ? " (" + Model.formatBytes(modelData.size) + ")" : "")
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.captionSmall || Style.space(9)
                      }
                    }
                  }
                }
              }
            }
          }

          // ====================================================================
          // CASE B: Main Network & Cloud Overview (when no account is opened in detail)
          // ====================================================================
          Column {
            visible: root.activeTab === "network" && drives.selectedCloudRemote === ""
            width: parent.width
            spacing: Style.space(12)

            // Section 1: Cloud Storage (rclone)
            Column {
              width: parent.width
              spacing: Style.space(8)

              RowLayout {
                width: parent.width

                Text {
                  textFormat: Text.PlainText
                  text: "CLOUD DRIVES (RCLONE)"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.captionSmall || Style.space(9)
                  font.bold: true
                }

                Item { Layout.fillWidth: true }

                ActionChip {
                  label: root.cloudAddOpen ? "Cancel" : "Add Cloud Drive"
                  iconText: root.cloudAddOpen ? Model.GLYPH_ALERT : Model.GLYPH_PLUS
                  active: root.cloudAddOpen
                  tooltipText: "Add multiple Google Drives, Mega, OneDrive, or Dropbox accounts"
                  onClicked: {
                    // Suggestions are recomputed on every open: computed once,
                    // they went stale as soon as an account was added.
                    if (!root.cloudAddOpen) root.selectCloudAddProvider(root.cloudAddProvider)
                    root.cloudAddOpen = !root.cloudAddOpen
                  }
                }
              }

              // Add Cloud Drive Drawer / Dialog
              Rectangle {
                visible: root.cloudAddOpen
                width: parent.width
                radius: Style.space(8)
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
                border.width: 1
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
                implicitHeight: addFormCol.implicitHeight + Style.space(20)

                ColumnLayout {
                  id: addFormCol
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: "Add Cloud Storage Account"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  // Provider Selection Dropdown
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(4)

                    Text {
                      textFormat: Text.PlainText
                      text: "Storage Provider:"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    Dropdown {
                      id: cloudProviderDropdown
                      Layout.fillWidth: true
                      showLabel: false
                      options: Model.cloudProviderOptions()
                      value: root.cloudAddProvider
                      foreground: root.foreground
                      background: Color.popups.background
                      accent: Color.accent
                      fontFamily: root.fontFamily
                      onChanged: function(val) { root.selectCloudAddProvider(val) }

                      Binding {
                        target: cloudProviderDropdown
                        property: "value"
                        value: root.cloudAddProvider
                      }
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: Model.cloudProvider(root.cloudAddProvider).description
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  // Detected Remotes in rclone (if any)
                  ColumnLayout {
                    visible: drives.availableRemotes.length > 0
                    Layout.fillWidth: true
                    spacing: Style.space(4)

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      Text {
                        textFormat: Text.PlainText
                        text: "Remotes detected in rclone:"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      Item { Layout.fillWidth: true }

                      ActionChip {
                        label: "rclone config"
                        iconText: Model.GLYPH_TERMINAL
                        tooltipText: "Run rclone config in terminal to authenticate or create a remote"
                        onClicked: drives.launchRcloneTerminal("rclone config")
                      }
                    }

                    Flow {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      Repeater {
                        model: drives.availableRemotes

                        ActionChip {
                          required property var modelData
                          label: modelData.name + " (" + modelData.type + ")"
                          iconText: Model.cloudProviderGlyph(modelData.type)
                          active: root.cloudAddRemoteName === modelData.name
                          onClicked: {
                            root.cloudAddRemoteName = modelData.name
                            if (modelData.type === "drive") root.selectCloudAddProvider("drive")
                            else if (modelData.type === "mega") root.selectCloudAddProvider("mega")
                            else if (modelData.type === "onedrive") root.selectCloudAddProvider("onedrive")
                            else if (modelData.type === "dropbox") root.selectCloudAddProvider("dropbox")
                            else if (modelData.type === "webdav") root.selectCloudAddProvider("webdav")
                            else root.selectCloudAddProvider("other")
                            root.cloudAddRemoteName = modelData.name
                          }
                        }
                      }
                    }
                  }

                  // Form Fields: Remote Name, Folder, Mount
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(4)

                    Text {
                      textFormat: Text.PlainText
                      text: "Remote name (as configured in rclone):"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    TextField {
                      id: rNameField
                      Layout.fillWidth: true
                      foreground: root.foreground
                      verticalPadding: Style.space(4)
                      text: root.cloudAddRemoteName
                      onTextChanged: root.cloudAddRemoteName = text
                      placeholderText: "e.g. gdrive, gdrive-work, mega"
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: "Local sync folder:"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    TextField {
                      id: rFolderField
                      Layout.fillWidth: true
                      foreground: root.foreground
                      verticalPadding: Style.space(4)
                      text: root.cloudAddFolder
                      onTextChanged: root.cloudAddFolder = text
                      placeholderText: "e.g. ~/Google Drive"
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: "Browse mount path (on-demand FUSE view):"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    TextField {
                      id: rMountField
                      Layout.fillWidth: true
                      foreground: root.foreground
                      verticalPadding: Style.space(4)
                      text: root.cloudAddMount
                      onTextChanged: root.cloudAddMount = text
                      placeholderText: "e.g. ~/GDrive-Browse"
                    }
                  }

                  // Checked as you type, against every connected account, so a
                  // second account cannot be pointed at the first one's folders.
                  Text {
                    id: addCheckText
                    readonly property var check: Model.validateCloudAccount(drives.cloudAccounts, {
                      remoteName: root.cloudAddRemoteName,
                      folderPath: root.cloudAddFolder,
                      browseMountPath: root.cloudAddMount
                    }, drives.homePath, "")
                    visible: !check.ok
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: check.reason
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  // Buttons Row
                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(8)

                    ActionChip {
                      label: "Cancel"
                      onClicked: root.cloudAddOpen = false
                    }

                    Item { Layout.fillWidth: true }

                    ActionChip {
                      label: "Connect & Add Drive"
                      iconText: Model.GLYPH_PLUS
                      active: true
                      enabled: addCheckText.check.ok
                      opacity: enabled ? 1 : 0.5
                      tooltipText: addCheckText.check.ok ? "Save and connect this drive" : addCheckText.check.reason
                      onClicked: {
                        var remote = root.cloudAddRemoteName.trim()
                        if (remote === "") return
                        var provider = root.cloudAddProvider
                        var st = drives.cloudStatuses[remote]
                        var isAuth = drives.isRemoteAuthenticated(remote) || (st && st.authenticated === true)
                        var needsAuth = !isAuth
                        if (drives.addCloudAccount({
                          remoteName: remote,
                          type: provider,
                          displayName: remote,
                          folderPath: root.cloudAddFolder.trim(),
                          browseMountPath: root.cloudAddMount.trim(),
                          syncIntervalMin: root.cloudAddInterval,
                          autoSync: true,
                          autoMount: true
                        }) !== "ok") return
                        root.cloudAddOpen = false
                        if (needsAuth) {
                          drives.authenticateCloudRemote(remote, provider)
                        }
                      }
                    }
                  }
                }
              }

              // Cloud Accounts Empty State
              Rectangle {
                visible: drives.cloudAccountCount === 0 && !root.cloudAddOpen
                width: parent.width
                radius: Style.space(8)
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
                border.width: 1
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                implicitHeight: cloudEmptyCol.implicitHeight + Style.space(24)

                ColumnLayout {
                  id: cloudEmptyCol
                  anchors.fill: parent
                  anchors.margins: Style.space(12)
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: Model.GLYPH_CLOUD
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.display
                    Layout.alignment: Qt.AlignHCenter
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "No Cloud Drives Connected"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    Layout.alignment: Qt.AlignHCenter
                  }

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: "Keep chosen folders synced on disk, and browse the rest without downloading it. Pick a provider to start."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                  }

                  // Every provider, as an even grid of equal-width buttons.
                  // (A Flow given a plain `width` inside a ColumnLayout is
                  // sized to its widest child instead, which stacked these
                  // one per line.)
                  GridLayout {
                    id: providerGrid
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(4)
                    columns: Math.max(1, Math.floor((cloudEmptyCol.width + columnSpacing) / Style.space(130)))
                    columnSpacing: Style.space(6)
                    rowSpacing: Style.space(6)

                    Repeater {
                      model: Model.CLOUD_PROVIDERS

                      ActionChip {
                        required property var modelData
                        // Same preferred width for all, so fillWidth shares
                        // the row evenly instead of by label length.
                        Layout.fillWidth: true
                        Layout.preferredWidth: Style.space(100)
                        label: modelData.type === "other" ? "Other remote" : modelData.label.replace(/^Microsoft /, "")
                        iconText: modelData.type === "other" ? Model.GLYPH_PLUS : modelData.glyph
                        tooltipText: modelData.description
                        onClicked: {
                          root.selectCloudAddProvider(modelData.type)
                          root.cloudAddOpen = true
                        }
                      }
                    }
                  }
                }
              }

              // Cloud account tiles, one full-width row each, so a long email
              // address has room. Each says who the account is, how full it
              // is, and whether it needs anything; a click opens the full view.
              Column {
                id: cloudTiles
                visible: drives.cloudAccountCount > 0
                width: parent.width
                spacing: Style.space(8)

                Repeater {
                  model: drives.cloudAccounts

                  CloudTile {
                    required property var modelData
                    width: cloudTiles.width
                    account: modelData
                    visible: root.filterQuery === ""
                      || String(modelData.remoteName).toLowerCase().indexOf(root.filterQuery.toLowerCase()) !== -1
                  }
                }
              }
            }

            // Section 2: Mounted Network Shares
            Column {
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: "MOUNTED NETWORK SHARES (" + drives.networkCount + ")"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.captionSmall || Style.space(9)
                font.bold: true
              }

              // Network Empty State
              Column {
                visible: drives.networkCount === 0
                width: parent.width
                spacing: Style.space(6)
                topPadding: Style.space(16)
                bottomPadding: Style.space(16)

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
                  text: "No network shares mounted"
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
                visible: root.filterQuery !== "" && root.matchingNetworkCount === 0 && drives.networkCount > 0
                width: parent.width
                text: "No network shares matching \"" + root.filterQuery + "\""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                topPadding: Style.space(16)
                bottomPadding: Style.space(16)
              }

              // Network Share Cards
              Repeater {
                model: drives.visibleNetworkShares

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

  // One cloud account on a full-width row:
  //
  //   [icon] gdrive                              (● Ready to sync)
  //          Google Drive · gameticharles@gmail.com
  //   4.6 TB free of 5.0 TB (7% used)                  4.1 GB on disk
  //   [███░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]
  //   Synced 8m ago                          [sync] [open] [browse]
  component CloudTile: Rectangle {
    id: tile
    property var account: null
    readonly property string remote: account ? account.remoteName : ""
    readonly property var st: drives.cloudStatuses[remote] || Model.defaultCloudStatus(remote)
    readonly property string conflict: drives.cloudConflicts[remote] || ""
    readonly property string tone: Model.cloudTone(st, conflict)
    readonly property color toneColor: root.toneColor(tone)
    readonly property real fraction: Model.cloudUsageFraction(st)
    readonly property bool overQuota: Model.cloudOverQuota(st)
    readonly property bool hot: overQuota || fraction >= drives.fullWarnPct / 100
    readonly property string space: Model.cloudSpaceText(st)
    readonly property string identity: st.accountEmail !== ""
      ? (st.accountName !== "" ? st.accountEmail + " · " + st.accountName : st.accountEmail)
      : (st.authenticated ? Model.shortHomePath(account ? account.folderPath : "", drives.homePath)
                          : (st.statusText === "Checking…" ? "Checking…" : "Not signed in"))

    implicitHeight: tileLayout.implicitHeight + Style.space(18)
    radius: Style.space(10)
    color: tileMouse.containsMouse
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
    border.width: 1
    border.color: tone === "error" || tone === "warn"
      ? Qt.rgba(tile.toneColor.r, tile.toneColor.g, tile.toneColor.b, 0.35)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09)

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openCloudAccount(tile.remote)
    }

    ColumnLayout {
      id: tileLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(9)
      spacing: Style.space(6)

      // Icon, name and identity; status pill on the right.
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Rectangle {
          implicitWidth: Style.space(32)
          implicitHeight: Style.space(32)
          radius: Style.space(6)
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          Layout.alignment: Qt.AlignVCenter

          GoogleDriveIcon {
            visible: !!(tile.account && tile.account.type === "drive")
            anchors.centerIn: parent
            iconSize: Style.font.iconLarge || Style.space(18)
            color: root.foreground
          }

          Text {
            visible: !(tile.account && tile.account.type === "drive")
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: Model.cloudProviderGlyph(tile.account ? tile.account.type : "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: tile.remote
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }

            // Status pill: dot (pulses while syncing) and the word for it.
            Rectangle {
              Layout.alignment: Qt.AlignVCenter
              implicitWidth: pillRow.implicitWidth + Style.space(12)
              implicitHeight: pillRow.implicitHeight + Style.space(4)
              radius: height / 2
              color: Qt.rgba(tile.toneColor.r, tile.toneColor.g, tile.toneColor.b, 0.12)
              border.width: 1
              border.color: Qt.rgba(tile.toneColor.r, tile.toneColor.g, tile.toneColor.b, 0.3)

              RowLayout {
                id: pillRow
                anchors.centerIn: parent
                spacing: Style.space(4)

                Rectangle {
                  id: toneDot
                  implicitWidth: Style.space(6)
                  implicitHeight: Style.space(6)
                  radius: width / 2
                  color: tile.toneColor
                  Layout.alignment: Qt.AlignVCenter

                  SequentialAnimation on opacity {
                    running: tile.tone === "busy"
                    loops: Animation.Infinite
                    onRunningChanged: if (!running) toneDot.opacity = 1
                    NumberAnimation { to: 0.3; duration: 600 }
                    NumberAnimation { to: 1; duration: 600 }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: tile.conflict !== "" ? "Shared folder" : tile.st.statusText
                  color: tile.tone === "idle" ? root.dim : tile.toneColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.captionSmall || Style.space(9)
                  font.bold: true
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: Model.cloudProviderLabel(tile.account ? tile.account.type : "") + " · " + tile.identity
            color: tile.st.accountEmail !== "" ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }
        }
      }

      // Room in the cloud over its bar, as a drive's; what is on this
      // computer on the right.
      RowLayout {
        visible: tile.space !== "" || tile.st.localBytes > 0
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: tile.space
          color: tile.overQuota ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          text: Model.cloudOnDiskText(tile.st)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Rectangle {
        visible: tile.st.quotaKnown
        Layout.fillWidth: true
        implicitHeight: Math.max(3, Style.space(4))
        radius: height / 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

        Rectangle {
          width: Math.max(tile.fraction > 0 ? 2 : 0, parent.width * tile.fraction)
          height: parent.height
          radius: parent.radius
          color: tile.hot ? root.urgent : root.foreground
          opacity: tile.hot ? 1 : 0.6
        }
      }

      // What it is doing or needs, with the quick actions on the right.
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: {
            if (tile.conflict !== "") return tile.conflict + " — open to fix"
            if (tile.st.browseConflict) return "Browse folder is mounted for " + tile.st.browseConflict
            if (!tile.st.authenticated && tile.st.statusText !== "Checking…") {
              return tile.st.remoteType === "" ? "No rclone remote by this name — open to set it up"
                                              : "Signed out of rclone — open to sign in again"
            }
            if (tile.st.lastResult === "error" && tile.st.lastError) return tile.st.lastError
            if (tile.st.syncing) return "Syncing now…"
            var parts = [Model.cloudSummary(tile.st)]
            if (tile.st.lastFinishedTs > 0) parts.push("synced " + Model.relativeTime(tile.st.lastFinishedTs).toLowerCase())
            if (tile.st.browseMounted) parts.push("browsing")
            return parts.join(" · ")
          }
          color: tile.tone === "error" || tile.tone === "warn" ? tile.toneColor : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          Layout.alignment: Qt.AlignVCenter
        }

        Row {
          spacing: Style.space(1)
          Layout.alignment: Qt.AlignVCenter

          PanelActionButton {
            iconText: Model.GLYPH_REFRESH
            tooltipText: tile.st.syncing ? "Syncing…" : "Sync now"
            foreground: tile.st.syncing ? tile.toneColor : root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            size: Style.space(24)
            enabled: !tile.st.syncing && tile.st.authenticated
            onClicked: drives.syncCloudNow(tile.remote, false)
          }

          PanelActionButton {
            iconText: Model.GLYPH_FOLDER
            tooltipText: tile.st.browseMounted ? "Open the browse folder" : "Open the synced folder"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            size: Style.space(24)
            onClicked: {
              if (tile.st.browseMounted && tile.account.browseMountPath) drives.openCloudBrowse(tile.account.browseMountPath)
              else drives.openCloudFolder(tile.account.folderPath)
            }
          }

          PanelActionButton {
            iconText: tile.st.browseMounted ? Model.GLYPH_HEALTHY : Model.GLYPH_CLOUD
            tooltipText: tile.st.browseMounted ? "Unmount the browse folder" : "Mount the browse folder"
            foreground: tile.st.browseMounted ? (bar && "activeColor" in bar ? bar.activeColor : root.foreground) : root.dim
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            size: Style.space(24)
            enabled: tile.conflict === "" && tile.st.authenticated
            onClicked: drives.toggleCloudBrowse(tile.remote)
          }
        }
      }
    }
  }

  // Label/value grid for drive and volume details. Every value is click-to-copy,
  // since a UUID or serial is far more often pasted somewhere than read.
  // Rows arrive from Model.deviceInfoRows / volumeInfoRows already plain()ed.
  component InfoGrid: ColumnLayout {
    id: infoGrid
    property var rows: []
    property string heading: ""
    spacing: Style.space(3)

    Text {
      visible: infoGrid.heading !== ""
      textFormat: Text.PlainText
      text: infoGrid.heading
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      Layout.bottomMargin: Style.space(2)
    }

    Repeater {
      model: infoGrid.rows

      RowLayout {
        id: infoRow
        required property var modelData
        Layout.fillWidth: true
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          text: infoRow.modelData[0]
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          Layout.preferredWidth: Style.space(78)
          Layout.alignment: Qt.AlignTop
        }

        Text {
          textFormat: Text.PlainText
          text: infoRow.modelData[1]
          color: valueMouse.containsMouse
            ? (bar && "activeColor" in bar ? bar.activeColor : root.foreground)
            : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WrapAnywhere
          Layout.fillWidth: true

          MouseArea {
            id: valueMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: drives.copyText(infoRow.modelData[0], infoRow.modelData[1])
          }
        }
      }
    }
  }

  // Built-in format form, shared by a single volume and a whole drive. The
  // owner supplies the target's own rules (validation, confirmation token,
  // warning) and decides what happens on commit; this only draws the fields.
  component FormatForm: ColumnLayout {
    id: formatForm
    property string token: ""
    property var check: null
    property string warning: ""
    readonly property string label: formLabelField.text
    readonly property string typed: formConfirmField.text
    readonly property bool confirmed: token !== "" && Model.normaliseLabel(typed) === token
    readonly property bool ready: check !== null && check.ok && confirmed
    readonly property int room: Model.labelRemaining(Model.formatTarget(root.formatType), label)
    signal commit()
    signal cancel()

    spacing: Style.space(4)

    function reset() {
      formLabelField.text = ""
      formConfirmField.text = ""
      Qt.callLater(function() { formConfirmField.forceActiveFocus() })
    }

    onVisibleChanged: if (visible) reset()

    Flow {
      Layout.fillWidth: true
      spacing: Style.space(8)

      Repeater {
        model: Model.formatTypes(drives.fsCapabilities)

        Text {
          id: formTypeChip
          required property var modelData
          textFormat: Text.PlainText
          text: Model.formatFsType(formTypeChip.modelData)
          color: root.formatType === formTypeChip.modelData ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: root.formatType === formTypeChip.modelData

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.formatType = formTypeChip.modelData
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
        id: formLabelField
        Layout.fillWidth: true
        foreground: root.foreground
        verticalPadding: Style.space(2)
        placeholderText: "Filesystem label"
        Keys.onEscapePressed: formatForm.cancel()
      }

      Text {
        textFormat: Text.PlainText
        text: formatForm.room
        color: formatForm.room < 0 ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)

      TextField {
        id: formConfirmField
        Layout.fillWidth: true
        foreground: root.foreground
        verticalPadding: Style.space(2)
        placeholderText: formatForm.token !== "" ? "Type " + formatForm.token + " to erase" : ""
        onAccepted: if (formatForm.ready) formatForm.commit()
        Keys.onEscapePressed: formatForm.cancel()
      }

      PanelActionButton {
        iconText: Model.GLYPH_ERASER
        tooltipText: "Erase"
        foreground: formatForm.ready ? root.urgent : root.dim
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        enabled: !drives.busy && formatForm.ready
        Layout.alignment: Qt.AlignVCenter
        onClicked: formatForm.commit()
      }
    }

    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      text: formatForm.check && !formatForm.check.ok
        ? formatForm.check.reason
        : formatForm.warning + " Esc cancels."
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // ------------------------------------------------------------ StorageCard Component
  component StorageCard: Rectangle {
    id: storageCardRoot
    property var device: null
    property int deviceIndex: 0

    readonly property bool isExpanded: root.expandedDevicePath === (device ? device.path : "")
      || formattingDrive
    readonly property bool isSystem: device && device.isSystem === true
    readonly property bool ejectable: Model.isEjectable(device)
    readonly property bool anyMounted: device && device.mountedCount > 0
    readonly property var link: device ? drives.linkFor(device) : ({})
    readonly property bool formattingDrive: device && root.formattingDevicePath === device.path
    readonly property var driveFormatCheck: formattingDrive
      ? Model.validateDriveFormat(drives.fsCapabilities, device,
                                  { path: device.path, fstype: root.formatType,
                                    label: driveFormatForm.label, quick: root.formatQuick })
      : null

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
                  if (storageCardRoot.device.kindLabel) parts.push(storageCardRoot.device.kindLabel)
                  if (storageCardRoot.device.sizeText !== "") parts.push(storageCardRoot.device.sizeText)
                  var conn = Model.connectionShort(storageCardRoot.device, storageCardRoot.link)
                  if (conn !== "") parts.push(conn)
                  if (storageCardRoot.device.volumes.length === 0 && !storageCardRoot.isSystem) parts.push("No media inserted")
                  return parts.join(" · ")
                }
                color: root.dim
                Layout.fillWidth: true
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              // The activity on its own, so a long line of drive details
              // (kind, size, link speed) elides instead of it. Urgent on a
              // drive that can be pulled, and on the one the bar shows as
              // being written; the system disk's small background writes stay
              // quiet - they are information, not a warning.
              Text {
                visible: storageCardRoot.activity !== ""
                textFormat: Text.PlainText
                text: "· " + storageCardRoot.activity
                color: storageCardRoot.ejectable
                       || (drives.writing && storageCardRoot.device
                           && drives.writing.name === storageCardRoot.device.name)
                       ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
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

            // An internal data disk is unmounted, not ejected: it is not
            // coming out, and powering it off is not what anyone asked for.
            PanelActionButton {
              visible: !storageCardRoot.isSystem && !storageCardRoot.ejectable && storageCardRoot.anyMounted
              iconText: Model.GLYPH_UNMOUNT
              tooltipText: "Unmount every volume on this drive"
              foreground: root.foreground
              hoverColor: root.urgent
              fontFamily: root.fontFamily
              enabled: !drives.busy
              onClicked: drives.unmountAll(storageCardRoot.device)
            }

            // Quick Eject Button
            PanelActionButton {
              visible: storageCardRoot.ejectable
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

            // Unmount every volume without powering off — the step before a
            // whole-drive wipe, and the way to free an internal data disk.
            ActionChip {
              visible: !storageCardRoot.isSystem && storageCardRoot.anyMounted
              iconText: Model.GLYPH_UNMOUNT
              label: "Unmount All"
              tooltipText: "Unmount every volume on this drive, without powering it off"
              onClicked: drives.unmountAll(storageCardRoot.device)
            }

            // Flash Bootable ISO chip (only for removable / non-system drives)
            ActionChip {
              visible: storageCardRoot.ejectable && drives.hasTool("omarchy-drive-flash")
              iconText: Model.GLYPH_SPEEDOMETER
              label: "Flash Bootable ISO"
              tooltipText: "Write a bootable operating system ISO image to this USB drive"
              onClicked: root.runFlash(storageCardRoot.device.path)
            }

            // Recovery & Diagnostics chip (available for all drives)
            ActionChip {
              visible: drives.hasTool("omarchy-drive-recover")
              iconText: Model.GLYPH_STETHOSCOPE
              label: "Recover & Inspect"
              tooltipText: "Launch TUI storage diagnostics, S.M.A.R.T. queries & recovery tool"
              onClicked: root.runRecovery(storageCardRoot.device.path)
            }

            // Whole-drive wipe, built in over udisks: a fresh GPT table and
            // one partition. Removable, non-system drives only.
            ActionChip {
              visible: storageCardRoot.ejectable && !storageCardRoot.formattingDrive
              iconText: Model.GLYPH_ERASER
              label: "Format Entire Drive"
              danger: true
              tooltipText: "Erase every partition and create one new volume filling the drive"
              onClicked: root.beginDriveFormat(storageCardRoot.device)
            }
          }

          FormatForm {
            id: driveFormatForm
            visible: storageCardRoot.formattingDrive
            Layout.fillWidth: true
            token: storageCardRoot.device ? storageCardRoot.device.name : ""
            check: storageCardRoot.driveFormatCheck
            warning: Model.driveFormatWarning(storageCardRoot.device)
            onCancel: root.finishDriveFormat()
            onCommit: {
              if (!Model.driveFormatConfirmed(storageCardRoot.device, driveFormatForm.typed)) return
              drives.formatDrive(storageCardRoot.device, root.formatType, driveFormatForm.label, root.formatQuick)
              root.finishDriveFormat()
            }
          }

          InfoGrid {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(4)
            heading: "DRIVE INFO"
            rows: storageCardRoot.device ? drives.deviceInfoFor(storageCardRoot.device) : []
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
    readonly property var device: volume ? drives.deviceOfVolume(volume) : null
    // Read-only comes from /proc/mounts, not the lsblk tree — the volume
    // object never carries it, which is why this pill used to never show.
    readonly property bool readOnly: volume ? drives.readOnlyFor(volume) : false
    readonly property bool nearlyFull: volume ? Model.nearlyFull(volume, drives.fullWarnPct) : false
    readonly property bool isNtfs: volume && (volume.fstype === "ntfs" || volume.fstype === "ntfs3")

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
              visible: !!(volumeItemRoot.volume && volumeItemRoot.volume.mounted && volumeItemRoot.readOnly)
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
            color: volumeItemRoot.nearlyFull ? root.urgent : root.dim
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
              color: volumeItemRoot.nearlyFull ? root.urgent : root.foreground
              opacity: volumeItemRoot.nearlyFull ? 1.0 : 0.65

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
            // The NTFS repair hand-off only applies where the helper exists;
            // without it the button mounts, and a failed mount is answered by
            // the built-in check → repair path in the drawer.
            readonly property bool ntfsRepair: volumeItemRoot.isNtfs && !volumeItemRoot.volume.mounted
              && drives.hasTool("omarchy-ntfs-fix")
            iconText: {
              if (!volumeItemRoot.volume) return ""
              if (volumeItemRoot.volume.mounted) return Model.GLYPH_FOLDER
              if (volumeItemRoot.volume.encrypted && !volumeItemRoot.volume.unlocked) return Model.GLYPH_LOCKED
              if (ntfsRepair) return Model.GLYPH_WRENCH
              return Model.GLYPH_MOUNT
            }
            tooltipText: {
              if (!volumeItemRoot.volume) return ""
              if (volumeItemRoot.volume.mounted) return "Open in file manager"
              if (Model.canUnlock(volumeItemRoot.volume)) return "Unlock encrypted container"
              if (ntfsRepair) return "Repair & Mount NTFS"
              return "Mount volume"
            }
            foreground: ntfsRepair ? root.urgent : root.foreground
            fontFamily: root.fontFamily
            enabled: !drives.busy
            onClicked: {
              if (volumeItemRoot.volume.mounted) drives.openVolume(volumeItemRoot.volume)
              else if (Model.canUnlock(volumeItemRoot.volume)) root.beginUnlock(volumeItemRoot.volume)
              else if (ntfsRepair) root.runNtfsFix(volumeItemRoot.volume.fsPath)
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
            visible: volumeItemRoot.volume && volumeItemRoot.volume.mounted && drives.hasTool("dua")
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
            visible: !!(volumeItemRoot.volume && volumeItemRoot.volume.mounted) && drives.hasTool("omarchy-disk-speedtest")
            iconText: Model.GLYPH_SPEEDOMETER
            label: "Speed Test"
            tooltipText: "Run live read/write performance benchmark with omarchy-disk-speedtest"
            onClicked: root.runSpeedTest(volumeItemRoot.volume.mountpoint)
          }

          // 4. Btrfs Scrub
          ActionChip {
            visible: !!(volumeItemRoot.volume && volumeItemRoot.volume.mounted && volumeItemRoot.volume.fstype === "btrfs")
              && drives.hasTool("omarchy-drive-scrub")
            iconText: Model.GLYPH_SHIELD
            label: "Btrfs Scrub"
            tooltipText: "Verify checksums and repair corrupted blocks via btrfs scrub"
            onClicked: root.runBtrfsScrub(volumeItemRoot.volume.mountpoint)
          }

          // 5. Trim SSD — only where the drive actually accepts discards; a
          // thumb drive with DISC-MAX 0 would just print an error.
          ActionChip {
            visible: !!(volumeItemRoot.volume && volumeItemRoot.volume.mounted)
              && drives.supportsTrim(volumeItemRoot.device) && drives.hasTool("omarchy-drive-trim")
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
            visible: volumeItemRoot.isNtfs && drives.hasTool("omarchy-ntfs-fix")
            iconText: Model.GLYPH_WRENCH
            label: "NTFS Fix"
            danger: true
            tooltipText: "Clear dirty bit and mount with ntfs-3g"
            onClicked: root.runNtfsFix(volumeItemRoot.volume.fsPath)
          }

          // 11. Partition Recovery
          ActionChip {
            visible: !!(volumeItemRoot.volume && !volumeItemRoot.volume.isSystem) && drives.hasTool("omarchy-drive-recover")
            iconText: Model.GLYPH_STETHOSCOPE
            label: "Recover"
            tooltipText: "Launch TUI partition recovery & deep diagnosis tool"
            onClicked: root.runRecovery(volumeItemRoot.volume.fsPath || volumeItemRoot.volume.path)
          }

          // 12. Format Partition — the built-in udisks form, with the
          // volume's kernel name typed out to confirm. Removable drives only.
          // A mounted volume still shows the chip; clicking it says to
          // unmount first rather than hiding the option.
          ActionChip {
            visible: !!(volumeItemRoot.volume && !volumeItemRoot.volume.isSystem
              && Model.isEjectable(volumeItemRoot.device) && !volumeItemRoot.formatting)
            iconText: Model.GLYPH_ERASER
            label: "Format"
            danger: true
            tooltipText: "Erase this volume and create a new filesystem on it"
            onClicked: root.beginFormat(volumeItemRoot.volume)
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

        InfoGrid {
          visible: !volumeItemRoot.unlocking && !volumeItemRoot.renamingLabel && !volumeItemRoot.formatting
          Layout.fillWidth: true
          heading: "DETAILS"
          rows: volumeItemRoot.volume ? drives.volumeInfoFor(volumeItemRoot.volume) : []
        }

        // Status & Instruction Hint (only while an inline editor is open; the
        // details grid above says everything the old one-line summary did)
        Text {
          visible: volumeItemRoot.unlocking || volumeItemRoot.renamingLabel || volumeItemRoot.formatting
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
              if (s.overQuota) return s.usedText + " used of " + s.sizeText + " · over quota"
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
