import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns everything that talks to the system: the lsblk snapshot, the udev
// event stream that makes the snapshot current, the kernel's own I/O counters
// that say whether a drive is still being written to, and the udisksctl calls
// that mount, unmount, and power off a drive.
//
// Nothing here runs as root. Mounting a removable filesystem is
// `allow_active: yes` in the udisks2 policy, so the logged-in session may do
// it without a prompt; anything that needs more than that (an unlock
// passphrase) is handed to a terminal rather than faked in the panel.
Item {
  id: root

  property var settings: ({})

  // Parsed device list — the single source of truth the panel draws from.
  property var devices: []
  property bool refreshing: false
  property bool loaded: false

  // Per-device I/O, keyed by kernel name ("sda"): write/read rates, requests
  // in flight, and whether the drive is settled enough to pull.
  property var activity: ({})

  // What each drive's onConnect hook is doing, keyed by the name of the file
  // it reports into. A hook is the one kind of work on a drive the kernel
  // counters cannot see: an rsync goes quiet between file batches.
  property var hooks: ({})

  // Health as udisks reports it, keyed by device path. Most drives report
  // none — a USB stick carries neither SMART interface — and that is a normal,
  // quiet answer rather than a fault.
  property var smart: ({})
  property string _smartSignature: ""
  property var tempHistory: ({})

  onSmartChanged: {
    var history = Object.assign({}, tempHistory)
    var changed = false
    for (var dev in smart) {
      if (!smart.hasOwnProperty(dev)) continue
      var s = smart[dev]
      if (s && typeof s.temperatureC === "number" && !isNaN(s.temperatureC)) {
        var list = (history[dev] ? history[dev].slice() : [])
        list.push(s.temperatureC)
        if (list.length > 20) list.shift()
        history[dev] = list
        changed = true
      }
    }
    if (changed) tempHistory = history

    // A drive whose own health verdict just got worse is told about at
    // once, panel open or not. The first reading counts: a disk that is
    // already failing when the shell starts is exactly the one to mention.
    var verdicts = {}
    for (var i = 0; i < devices.length; i++) {
      var device = devices[i]
      var verdict = Model.smartVerdict(smart[device.path])
      verdicts[device.path] = verdict
      // A standing warning (one reallocated sector, years old) is not
      // repeated at every login: the first read of a session alerts only on
      // "failing". Getting worse after that alerts at either level.
      var seen = _healthVerdicts[device.path] !== undefined
      if (healthAlertsEnabled && Model.healthWorsened(_healthVerdicts[device.path], verdict)
          && (seen || verdict === "failing")) {
        notify(verdict === "failing" ? device.title + " reports itself failing" : device.title + " has a health warning",
               Model.smartHint(smart[device.path]) + (verdict === "failing" ? ". Back up what is on it now." : ""),
               Model.GLYPH_ALERT, verdict === "failing" ? "critical" : "normal")
      }
    }
    _healthVerdicts = verdicts
  }

  property var _healthVerdicts: ({})

  // Network and cloud storage (NFS, CIFS/Samba, SSHFS, Rclone, DAVFS). The
  // visible list leaves out the browse mounts of connected cloud accounts,
  // which their own cards already show.
  property var networkShares: []
  readonly property var visibleNetworkShares: Model.visibleNetworkShares(networkShares, cloudAccounts, homePath)
  readonly property int networkCount: visibleNetworkShares.length

  // Cloud & rclone accounts (Google Drive, Mega, OneDrive, etc.)
  readonly property string homePath: Quickshell.env("HOME") || ""
  readonly property string cloudStorePath: Quickshell.env("HOME") + "/.local/state/omarchy/cloud-drives.json"
  property var cloudStore: ({ version: 1, accounts: [] })
  readonly property var cloudAccounts: (cloudStore && cloudStore.accounts) ? cloudStore.accounts : []
  readonly property int cloudAccountCount: cloudAccounts.length
  // remoteName -> why its paths collide with another account's, for accounts
  // saved before the add form checked.
  readonly property var cloudConflicts: Model.cloudPathConflicts(cloudAccounts, homePath)

  property bool rcloneInstalled: false
  property string rcloneVersion: ""
  property bool rcloneFuse: false
  property var availableRemotes: []
  property var cloudStatuses: ({})

  property string selectedCloudRemote: ""
  readonly property var selectedCloudAccount: {
    for (var i = 0; i < cloudAccounts.length; i++) {
      if (cloudAccounts[i].remoteName === selectedCloudRemote) return cloudAccounts[i]
    }
    return null
  }
  readonly property var selectedCloudStatus: {
    if (!selectedCloudRemote || selectedCloudRemote === "") return Model.defaultCloudStatus("")
    return cloudStatuses[selectedCloudRemote] || Model.defaultCloudStatus(selectedCloudRemote)
  }

  property var cloudFolders: []
  property int cloudStaleCount: 0
  property double cloudStaleBytes: 0
  property int cloudRootFileCount: 0
  property double cloudRootFileBytes: 0
  property bool cloudRootFiles: true
  property bool cloudFoldersLoading: false
  property string cloudFoldersError: ""
  property var pendingCloudFolders: ({})
  property string cloudActionStatus: ""

  readonly property bool cloudBusy: cloudControlProcess.running
  readonly property string cloudHelperPath: {
    var value = String(Qt.resolvedUrl("cloud-sync.py"))
    if (value.indexOf("file://") === 0) value = value.substring(7)
    return decodeURIComponent(value)
  }

  // S.M.A.R.T. reading has two speeds. In the background, health is read once
  // whenever the set of attached drives changes and every six hours — enough
  // to notice a drive going bad, never continuous. The minute-by-minute
  // temperature polling only runs while a drive's telemetry row is open.
  // (Before, the background read was gated behind the open row too, so a
  // failing disk was never noticed unless somebody went looking.)
  property bool telemetryActive: false
  readonly property bool smartRefreshing: smartProcess.running

  onTelemetryActiveChanged: {
    if (telemetryActive) probeSmart(true)
  }

  // The panel sets this while it is open, so free space stays current while
  // someone is looking at it and costs nothing while they are not.
  property bool watchClosely: false

  // Path of the device or volume an action is running against, so exactly one
  // row can show a spinner instead of the whole panel greying out.
  property string busyPath: ""
  property string busyAction: ""

  property string lastError: ""
  property string actionStatus: ""

  // An eject asked for while the drive is still being written to. Holds a
  // device path, or "*" for eject-all, and fires once the writes settle.
  property string pendingEjectPath: ""

  // Processes holding an unmount open, discovered only after udisks refuses.
  property var blockers: []
  property string blockedFsPath: ""

  // Phones and cameras, which are not block devices at all — gvfs mounts
  // them over MTP and lsblk never sees them.
  property var portables: []

  // Which gvfs backends exist, and what is plugged in that none of them can
  // reach. Drives the "install this to browse your phone" hint.
  property var support: ({ backends: {}, devices: [] })
  readonly property var supportHint: Model.supportHint(support)

  // Per-drive settings the user has saved, keyed so they survive replugging.
  property var store: ({ version: 1, drives: {} })

  // Mount options per mount point, straight from /proc/mounts — the kernel's
  // own answer to "is this mounted read-only?", which the lsblk tree does not
  // carry.
  property var mountFlags: ({})

  // Bytes sitting in each mounted volume's trash, keyed by trash directory.
  property var trashSizes: ({})
  property string uid: ""

  // What udisks says it can fsck, asked about the filesystem types actually
  // attached, and what it says it can create, which is the same answer for
  // every drive. The signature is the sorted list it was last asked about, so
  // a drive going in or out only costs a probe when it brings a new type.
  property var fsCapabilities: ({ check: {}, repair: {}, format: [] })
  property string _capsSignature: ""
  property bool _capsProbed: false

  // The filesystem the last check was about, and what it said: true healthy,
  // false damaged, null unreadable. A repair is only ever offered for this
  // exact path and only while the answer was false, so it cannot be started
  // against a volume nobody has looked at.
  property string checkedFsPath: ""
  property string checkedUuid: ""
  property var checkVerdict: null

  // Whether the repair button may be shown at all. Recomputed from the live
  // device list, so swapping the drive for another that lands on the same
  // /dev node retracts the offer instead of re-pointing it.
  readonly property bool repairOffered: {
    if (checkedFsPath === "" || checkVerdict !== false) return false
    for (var d = 0; d < devices.length; d++) {
      var volumes = devices[d].volumes
      for (var v = 0; v < volumes.length; v++) {
        if (volumes[v].fsPath === checkedFsPath) {
          return Model.repairAuthorised(
            { fsPath: checkedFsPath, uuid: checkedUuid, verdict: checkVerdict }, volumes[v])
        }
      }
    }
    return false
  }

  readonly property bool busy: actionProcess.running
  readonly property int deviceCount: devices.length
  readonly property int mountedCount: {
    var total = 0
    for (var i = 0; i < devices.length; i++) total += devices[i].mountedCount
    return total
  }

  // The drives someone can unplug. Everything that says "do not remove" or
  // holds an eject back looks only at these: the disk the system runs from is
  // written to every few seconds, and counting it made the bar icon flash
  // urgent for journald and held eject-all back indefinitely.
  readonly property var ejectableDevices: Model.ejectableDevices(devices)

  // True while any attached drive still has I/O in flight or is running its
  // connect hook — the state in which pulling the drive is what loses data.
  readonly property bool anyBusy: {
    for (var i = 0; i < ejectableDevices.length; i++) {
      if (isDeviceBusy(ejectableDevices[i])) return true
    }
    return false
  }

  // The storage being written right now - any drive, the system disk
  // included, or a syncing cloud account - for the bar icon and the header.
  // Unlike anyBusy it never holds an eject back. See Model.writingNow.
  readonly property var writing: Model.writingNow(devices, activity, _busyTicks,
                                                  cloudAccounts, cloudStatuses)

  readonly property real totalWriteRate: {
    var total = 0
    for (var i = 0; i < ejectableDevices.length; i++) {
      var entry = activity[ejectableDevices[i].name]
      if (entry) total += entry.writeRate
    }
    return total
  }

  // Data the kernel is still holding for some disk, from /proc/meminfo. It is
  // system-wide — the kernel does not split it per device without root — so it
  // is a hint shown beside removable drives, never a verdict on one of them.
  property real dirtyBytes: 0

  // How each drive is attached, read from sysfs: USB link speed, PCIe link,
  // SATA link. Keyed by kernel name; re-read only when the set of drives
  // changes, since none of it moves while a drive stays plugged in.
  property var links: ({})
  property string _linkSignature: ""

  // Optional terminal helpers that are installed on this machine. A button
  // that hands off to one is hidden when it is missing, rather than opening a
  // terminal that says "command not found".
  property var tools: ({})

  function hasTool(name) {
    return tools[name] === true
  }

  function linkFor(device) {
    if (!device) return ({})
    return links[device.name] || ({})
  }

  function deviceInfoFor(device) {
    return Model.deviceInfoRows(device, linkFor(device))
  }

  function volumeInfoFor(volume) {
    return Model.volumeInfoRows(volume, readOnlyFor(volume))
  }

  function supportsTrim(device) {
    return !!(device && device.discardMax !== null && device.discardMax > 0)
  }

  readonly property bool notificationsEnabled: setting("notifications", true) === true

  readonly property bool autoMountOnConnect: setting("autoMountOnConnect", true) === true
  readonly property bool autoCleanTrashOnEject: setting("autoCleanTrashOnEject", false) === true
  readonly property bool unmountOnSuspend: setting("unmountOnSuspend", true) === true
  property bool showSystemDrives: setting("showSystemDrives", true) === true
  onShowSystemDrivesChanged: refresh()

  readonly property real thumbMaxBytes: intSetting("thumbMaxGb", 256, 1, 65536) * 1024 * 1024 * 1024
  onThumbMaxBytesChanged: refresh()
  readonly property int fullWarnPct: intSetting("fullWarnPct", 90, 50, 100)
  readonly property bool healthAlertsEnabled: setting("healthAlerts", true) === true
  readonly property bool lowSpaceAlertsEnabled: setting("lowSpaceAlerts", true) === true

  // Volumes already told about for being nearly full; see Model.spaceAlerts.
  property var _spaceAlerted: ({})

  function checkSpace() {
    var step = Model.spaceAlerts(devices, _spaceAlerted, fullWarnPct)
    _spaceAlerted = step.alerted
    if (!lowSpaceAlertsEnabled) return
    for (var i = 0; i < step.alerts.length; i++) {
      notify("Running out of space", Model.spaceAlertText(step.alerts[i]), Model.GLYPH_ALERT, "normal")
    }
  }

  function setShowSystemDrives(value) {
    showSystemDrives = value
  }

  // A volume Windows left hibernated or dirty refuses to mount read-write. The
  // fix needs root, and a detached process has no terminal to ask for a
  // password in — so it used to fail silently here. Mount it if it will mount;
  // if not, say so, and leave the repair to a click that opens a terminal.
  readonly property string ntfsMountScript: [
    'set -u',
    'udisksctl mount --no-user-interaction -b "$1" >/dev/null 2>&1 && exit 0',
    '[ "$2" = 1 ] || exit 0',
    'omarchy-notification-send -g "$3" "NTFS volume needs a repair" ' +
      '"$4 did not mount — Windows may have left it hibernated or dirty. Open Storage Drives to fix it." || true'
  ].join("\n")

  function autoMountNtfs(volume) {
    if (!volume || volume.mounted) return
    Quickshell.execDetached(["bash", "-c", ntfsMountScript, "storage-drives", volume.fsPath,
                             notificationsEnabled ? "1" : "0", Model.GLYPH_ALERT, Model.plain(volume.title)])
  }

  property string _successMessage: ""

  // A LUKS passphrase on its way to a process, held only between building the
  // command and the process starting, and cleared the moment it is written.
  property string _secret: ""
  property string _stdout: ""
  property string _stderr: ""
  property string _openAfterPath: ""
  property var _statSamples: ({})

  // Consecutive samples each device has read busy, so a one-sample blip — the
  // remount every rename and check performs — is not mistaken for a copy.
  property var _busyTicks: ({})
  property var _previousDevices: []
  property var _expectedRemovals: ({})
  property bool _seenFirstSnapshot: false
  property int _quietTicks: 0

  // One quiet sample is not enough to call a copy finished: throughput dips to
  // zero between bursts. Two consecutive quiet seconds is the threshold.
  readonly property int quietTicksBeforeEject: 2

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // Lives in Model.js so the escaping is covered by tests.
  function quote(value) {
    return Model.shellQuote(value)
  }

  function deviceByPath(path) {
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].path === path) return devices[i]
    }
    return null
  }

  function activityFor(device) {
    if (!device) return null
    return activity[device.name] || null
  }

  // A running hook counts as busy for the same reason kernel I/O does: pulling
  // the drive while it works is what loses the copy. It goes through here
  // rather than beside it, so the eject hold, the pending-eject wait and the
  // bar icon all pick it up without a second mechanism to keep in step.
  function isDeviceBusy(device) {
    var entry = activityFor(device)
    return !!(entry && entry.busy) || hookActive(device)
  }

  function activityLabelFor(device) {
    return Model.activityLabel(activityFor(device))
  }

  // ------------------------------------------------------------- reading

  function refresh() {
    if (lsblkProcess.running) return
    refreshing = true
    lsblkProcess.running = true
    if (!mountsProcess.running) mountsProcess.running = true
    if (!networkMountsProcess.running) networkMountsProcess.running = true
  }

  function readOnlyFor(volume) {
    return Model.isReadOnly(mountFlags, volume)
  }

  function metaFor(volume) {
    return Model.volumeMeta(volume, readOnlyFor(volume))
  }

  // What the rescan button and `r` do. Unlike refresh(), it also forgets what
  // udisks last said it could fsck — so installing a missing tool and pressing
  // rescan is enough to make the check button appear, without a shell restart.
  // Health is forgotten for the same reason: it is the only other answer here
  // that is read once and then kept.
  function rescan() {
    forgetCapabilities()
    _smartSignature = ""
    _linkSignature = ""
    refresh()
    refreshPortables()
    probeTools()
  }

  function applySnapshot(raw) {
    var next = []
    try {
      next = Model.parse(raw, root.showSystemDrives, root.thumbMaxBytes)
    } catch (e) {
      lastError = "Could not read the block device list"
      refreshing = false
      return
    }

    Model.applyStore(next, store)
    var diff = Model.deviceDiff(_previousDevices, next)
    devices = next
    _previousDevices = next
    loaded = true
    refreshing = false

    // The first snapshot describes drives that were already attached before
    // the shell started; announcing those would mean a notification storm at
    // every login.
    if (_seenFirstSnapshot) announceChanges(diff)
    _seenFirstSnapshot = true

    if (watchClosely) probeTrash()
    probeCapabilities()
    probeLinks()
    probeSmart()
    checkSpace()
    updateSuspendTargets()

    // A mount requested with "open after mounting" only knows where the
    // filesystem landed once the next snapshot comes back with a mount point.
    if (_openAfterPath !== "") {
      var pending = _openAfterPath
      _openAfterPath = ""
      var volume = volumeByPath(pending)
      if (volume && volume.mounted) openVolume(volume)
    }
  }

  function volumeByPath(fsPath) {
    for (var d = 0; d < devices.length; d++) {
      var volumes = devices[d].volumes
      for (var v = 0; v < volumes.length; v++) {
        if (volumes[v].fsPath === fsPath) return volumes[v]
      }
    }
    return null
  }

  // ------------------------------------------------------- arrival/removal

  function announceChanges(diff) {
    var i
    for (i = 0; i < diff.added.length; i++) {
      var added = diff.added[i]
      if (added.isSystem) continue
      notify(added.title + " connected", Model.connectedSummary(added), added.glyph)
      runConnectHook(added)

      if (root.autoMountOnConnect && added.volumes) {
        for (var v = 0; v < added.volumes.length; v++) {
          var vol = added.volumes[v]
          if (!vol.mounted && !vol.isSystem) {
            if (vol.fstype === "ntfs" || vol.fstype === "ntfs3") {
              root.autoMountNtfs(vol)
            } else if (Model.isMountable(vol)) {
              root.mount(vol, false)
            }
          }
        }
      }
    }
    for (i = 0; i < diff.removed.length; i++) {
      var gone = diff.removed[i]
      if (gone.isSystem) continue
      // We powered this one off ourselves and already said "safe to remove".
      if (_expectedRemovals[gone.path]) {
        var seen = _expectedRemovals
        delete seen[gone.path]
        _expectedRemovals = seen
        continue
      }
      // Unplugged with a filesystem still mounted: the one case worth
      // interrupting someone over, because it is the case that loses files.
      if (gone.mountedCount > 0) {
        notify("Removed while still mounted",
               gone.title + " was unplugged before it was unmounted. Files may be incomplete.",
               Model.GLYPH_ALERT, "critical")
      } else {
        notify(gone.title + " removed", "", gone.glyph)
      }
    }
  }

  // ------------------------------------------------------------- activity

  // The meminfo lines ride along on the same process: one fork a second
  // rather than two, and parseBlockStats skips anything that is not under a
  // stat header.
  readonly property string statsScript:
    'head -v -n 1 -- "$@" 2>/dev/null; grep -E "^(Dirty|Writeback):" /proc/meminfo'

  function sampleActivity() {
    if (statsProcess.running || devices.length === 0) return
    var command = ["bash", "-c", statsScript, "storage-drives"]
    for (var i = 0; i < devices.length; i++) {
      command.push("/sys/block/" + devices[i].name + "/stat")
    }
    statsProcess.command = command
    statsProcess.running = true
  }

  function applyStats(raw) {
    var built = Model.buildActivity(_statSamples, Model.parseBlockStats(raw), Date.now())
    activity = built.activity
    _statSamples = built.samples
    dirtyBytes = Model.parseDirtyBytes(raw)

    // Rebuilt from the live device list, so a drive that has gone takes its
    // tally with it rather than lingering as a name nobody looks up.
    var ticks = {}
    for (var i = 0; i < devices.length; i++) {
      var name = devices[i].name
      var entry = built.activity[name]
      ticks[name] = Model.advanceBusy(_busyTicks[name], !!(entry && entry.busy))
    }
    _busyTicks = ticks
    advancePendingEject()
  }

  // An eject deferred for writes runs as soon as the drive has been quiet for
  // two consecutive samples. One quiet sample is not enough: a copy in
  // progress dips to zero between bursts.
  function advancePendingEject() {
    if (pendingEjectPath === "") return

    var targets = pendingEjectTargets()
    if (targets.length === 0) {
      pendingEjectPath = ""
      _quietTicks = 0
      return
    }

    var stillBusy = false
    for (var i = 0; i < targets.length; i++) {
      if (isDeviceBusy(targets[i])) stillBusy = true
    }

    var step = Model.advanceQuiet(stillBusy, _quietTicks, quietTicksBeforeEject)
    _quietTicks = step.quietTicks
    if (!step.run) return

    pendingEjectPath = ""
    _quietTicks = 0
    runEject(targets)
  }

  function pendingEjectTargets() {
    if (pendingEjectPath === "") return []
    if (pendingEjectPath === "*") return ejectableDevices
    var device = deviceByPath(pendingEjectPath)
    return device ? [device] : []
  }

  function cancelPendingEject() {
    pendingEjectPath = ""
    _quietTicks = 0
    actionStatus = ""
  }

  // ------------------------------------------------------------- actions

  function runAction(command, path, action, successMessage, secret) {
    if (actionProcess.running) return
    _secret = secret === undefined || secret === null ? "" : secret
    lastError = ""
    actionStatus = ""
    blockers = []
    blockedFsPath = ""
    checkedFsPath = ""
    checkedUuid = ""
    checkVerdict = null
    _stdout = ""
    _stderr = ""
    _successMessage = successMessage
    busyPath = path
    busyAction = action
    actionProcess.command = command
    actionProcess.running = true
  }

  // The drive gets the last word on both halves of this. A drive saved as
  // read-only mounts read-only however it was reached, and its own autoOpen
  // decides whether a file manager follows — `openAfter` is the global default
  // the caller came with, not the answer.
  function mount(volume, openAfter) {
    if (!volume || !Model.isMountable(volume) || busy) return
    var device = deviceOfVolume(volume)
    var readOnly = Model.shouldMountReadOnly(store, device)
    _openAfterPath = Model.shouldOpenOnMount(store, device, openAfter === true) ? volume.fsPath : ""
    var command = ["udisksctl", "mount", "--no-user-interaction"]
    if (readOnly) command.push("-o", "ro")
    command.push("-b", volume.fsPath)
    runAction(command, volume.fsPath, "mount",
              "Mounted " + volume.title + (readOnly ? " read-only" : ""))
  }

  function unmount(volume, force) {
    if (!volume || !volume.mounted || busy || volume.isSystem) return
    _openAfterPath = ""
    var command = ["udisksctl", "unmount", "--no-user-interaction", "-b", volume.fsPath]
    if (force) command.push("--force")
    runAction(command, volume.fsPath, "unmount",
              (force ? "Force unmounted " : "Unmounted ") + volume.title)
  }

  // The rescue path out of a failed check. Repair rewrites the filesystem, so
  // the honest first move on a drive that failed is to read what is still
  // there without writing a byte to it — which the panel previously advised
  // ("copy anything you still need off it first") without offering any way to
  // do.
  //
  // A filesystem already mounted read-write has to come off first; there is no
  // remount here, because changing the mount is the whole operation rather
  // than a step on the way to one. If the read-only mount then fails, the
  // drive is left unmounted and the error says so, which beats quietly putting
  // it back writable.
  function mountReadOnly(volume) {
    if (!volume) return "unknown volume"
    if (volume.isSystem) return refuse("System volumes cannot be remounted")
    if (busy) return refuse("Another action is still running")
    if (volume.encrypted && !volume.unlocked) return refuse("Unlock this volume first")
    if (volume.mounted && readOnlyFor(volume)) {
      actionStatus = volume.title + " is already mounted read-only"
      return "unchanged"
    }
    if (!volume.mounted && !Model.isMountable(volume)) {
      return refuse(describeFs(volume) + " cannot be mounted")
    }
    var blocked = fsActionBlocked(volume)
    if (blocked !== "") return refuse(blocked)

    var script = [
      'set -u',
      'dev=$1',
      'if [ "$2" = 1 ]; then udisksctl unmount --no-user-interaction -b "$dev" >/dev/null || exit 1; fi',
      'udisksctl mount --no-user-interaction -o ro -b "$dev" >/dev/null'
    ].join("\n")
    runAction(["bash", "-c", script, "removable-drives", volume.fsPath, volume.mounted ? "1" : "0"],
              volume.fsPath, "mount-ro", "Mounted " + volume.title + " read-only")
    return "ok"
  }

  function toggleMount(volume, openAfter) {
    if (!volume || volume.isSystem) return
    if (volume.mounted) unmount(volume, false)
    else if (volume.encrypted && !volume.unlocked) unlock(volume)
    else mount(volume, openAfter)
  }

  function forceUnmountBlocked() {
    var volume = volumeByPath(blockedFsPath)
    if (volume) unmount(volume, true)
  }

  // udisksctl reads a key only from a file, never from stdin, so the
  // passphrase has to land on disk somewhere. XDG_RUNTIME_DIR is tmpfs — it
  // never reaches persistent storage — the file is created under umask 077,
  // and a trap removes it however the script ends.
  //
  // The passphrase reaches the script on stdin rather than as an argument,
  // because /proc/<pid>/cmdline is readable by every other process this user
  // runs, and a passphrase in argv is a passphrase in `ps`.
  //
  // udisks refuses the backing partition for mount and unmount alike, so the
  // mount that follows targets the mapper udisksctl names on its way out —
  // and honours the drive's own read-only setting, because the container is
  // the third way a filesystem on it can come up.
  readonly property string unlockScript: [
    'set -u',
    'dev=$1',
    'ro=$2',
    'mountfs() {',
    '  if [ "$ro" = 1 ]; then udisksctl mount --no-user-interaction -o ro -b "$1" >/dev/null',
    '  else udisksctl mount --no-user-interaction -b "$1" >/dev/null',
    '  fi',
    '}',
    'keyfile="${XDG_RUNTIME_DIR:-/dev/shm}/removable-drives.$$.key"',
    "trap 'rm -f \"$keyfile\"' EXIT INT TERM",
    'umask 077',
    'IFS= read -r pass',
    'printf %s "$pass" > "$keyfile"',
    'unset pass',
    'out=$(udisksctl unlock --no-user-interaction -b "$dev" --key-file "$keyfile") || exit 1',
    'printf "%s\\n" "$out"',
    'mapper=${out##* as }',
    'mapper=${mapper%.}',
    'case "$mapper" in',
    '  /dev/*) mountfs "$mapper" ;;',
    '  *) echo "udisks did not say which device it unlocked" >&2; exit 1 ;;',
    'esac'
  ].join("\n")

  function unlock(volume, passphrase) {
    if (!Model.canUnlock(volume)) return "This volume is not locked"
    if (busy) return refuse("Another action is still running")
    if (String(passphrase || "") === "") return refuse("Enter the passphrase first")
    var readOnly = Model.shouldMountReadOnly(store, deviceOfVolume(volume))
    runAction(["bash", "-c", unlockScript, "removable-drives", volume.path, readOnly ? "1" : "0"],
              volume.fsPath, "unlock", "Unlocked " + volume.title,
              String(passphrase))
    return "ok"
  }

  // The other half of unlocking. Closing a container means taking the
  // filesystem inside it offline first, so this is one action rather than two
  // the user has to know the order of — and the two steps address different
  // devices: the filesystem lives on the mapper, while only the backing
  // partition can be locked.
  function lock(volume) {
    if (!volume) return "unknown volume"
    if (busy) return refuse("Another action is still running")
    if (!Model.canLock(volume)) return refuse("This volume is not unlocked")
    var blocked = fsActionBlocked(volume)
    if (blocked !== "") return refuse(blocked)
    var script = [
      'set -u',
      'if [ "$2" = 1 ]; then udisksctl unmount --no-user-interaction -b "$1" >/dev/null || exit 1; fi',
      'udisksctl lock --no-user-interaction -b "$3" >/dev/null'
    ].join("\n")
    runAction(["bash", "-c", script, "removable-drives",
               volume.fsPath, volume.mounted ? "1" : "0", volume.path],
              volume.fsPath, "lock", "Locked " + volume.title)
    return "ok"
  }

  // Ejecting a drive the kernel is still writing to is exactly the mistake
  // this widget exists to prevent, so the request is held rather than refused
  // and runs by itself the moment the drive goes quiet.
  function eject(device) {
    if (!device || busy || device.isSystem) return
    if (isDeviceBusy(device)) {
      pendingEjectPath = device.path
      _quietTicks = 0
      actionStatus = "Waiting for writes to finish on " + device.title + "…"
      return
    }
    runEject([device])
  }

  function ejectAll() {
    if (busy || ejectableDevices.length === 0) return
    if (anyBusy) {
      pendingEjectPath = "*"
      _quietTicks = 0
      actionStatus = "Waiting for writes to finish…"
      return
    }
    runEject(ejectableDevices)
  }

  // Unmount everything, re-lock anything that was unlocked, then cut power.
  // `set -e` stops at the first failure so a busy filesystem surfaces as an
  // error instead of a half-ejected drive, and power-off is allowed to fail
  // on hubs and card readers that don't implement it — by then the drive is
  // already safe to pull.
  function runEject(list) {
    if (!list || list.length === 0 || busy) return
    var script = "set -e\n"
    var titles = []
    var internalTitles = []
    var ejectCount = 0
    for (var d = 0; d < list.length; d++) {
      var device = list[d]
      if (device.isSystem) continue
      ejectCount++
      // An internal data disk is unmounted, never powered off: it is not
      // coming out of the machine, and spinning it down behind the kernel's
      // back is not what "unmount everything" asked for.
      if (device.removable) titles.push(device.title)
      else internalTitles.push(device.title)
      for (var v = 0; v < device.volumes.length; v++) {
        var volume = device.volumes[v]
        if (volume.isSystem) continue
        if (root.autoCleanTrashOnEject && volume.mounted) {
          var tPath = trashPathFor(volume)
          if (tPath !== "" && Model.isSafeTrashPath(tPath, mountedMountpoints(), uid)) {
            script += "rm -rf -- " + quote(tPath) + " 2>/dev/null || true\n"
          }
        }
        if (volume.mounted) script += "udisksctl unmount --no-user-interaction -b " + quote(volume.fsPath) + "\n"
        if (volume.encrypted && volume.unlocked) script += "udisksctl lock --no-user-interaction -b " + quote(volume.path) + "\n"
      }
      if (!device.removable) continue
      script += "udisksctl power-off --no-user-interaction -b " + quote(device.path) + " || true\n"

      // Remember that this one is meant to disappear, so its removal is not
      // reported back to the user as an accident.
      var expected = _expectedRemovals
      expected[device.path] = true
      _expectedRemovals = expected
    }
    if (ejectCount === 0) return
    var message = titles.length > 0
      ? "Safe to remove " + titles.join(", ")
      : "Unmounted " + internalTitles.join(", ")
    runAction(["bash", "-c", script], list.length === 1 ? list[0].path : "*",
              titles.length > 0 ? "eject" : "unmount", message)
  }

  // Every mounted volume on one drive, without powering it off: what wiping
  // the whole drive asks for first, and what an internal data disk's eject
  // button means.
  function unmountAll(device) {
    if (!device || device.isSystem || busy) return
    var script = "set -e\n"
    var any = false
    for (var v = 0; v < device.volumes.length; v++) {
      var volume = device.volumes[v]
      if (volume.isSystem || !volume.mounted) continue
      script += "udisksctl unmount --no-user-interaction -b " + quote(volume.fsPath) + "\n"
      any = true
    }
    if (!any) return
    runAction(["bash", "-c", script], device.path, "unmount", "Unmounted every volume on " + device.title)
  }

  function openVolume(volume) {
    if (!volume || !volume.mounted) return
    var command = String(setting("fileManager", "")).replace(/^\s+|\s+$/g, "")
    if (command === "") {
      Quickshell.execDetached(["uwsm-app", "--", "xdg-open", volume.mountpoint])
      return
    }
    Quickshell.execDetached(["bash", "-c", command + " " + quote(volume.mountpoint)])
  }

  function openTerminal(volume) {
    if (!volume || !volume.mounted) return
    Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "-e", "bash", "-c",
                             "cd \"$1\" && exec $SHELL", "shell", volume.mountpoint])
  }

  function openDiskUsage(volume) {
    if (!volume || !volume.mounted) return
    Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "--app-id=TUI.float", "-e", "bash", "-c",
                             "dua i \"$1\"", "dua", volume.mountpoint])
  }

  function openNetworkShare(share) {
    if (!share || !share.mountpoint) return
    var command = String(setting("fileManager", "")).replace(/^\s+|\s+$/g, "")
    if (command === "") {
      Quickshell.execDetached(["uwsm-app", "--", "xdg-open", share.mountpoint])
      return
    }
    Quickshell.execDetached(["bash", "-c", command + " " + quote(share.mountpoint)])
  }

  function openNetworkTerminal(share) {
    if (!share || !share.mountpoint) return
    Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "-e", "bash", "-c",
                             "cd \"$1\" && exec $SHELL", "shell", share.mountpoint])
  }

  function unmountNetworkShare(share) {
    if (!share || !share.mountpoint) return
    var script = [
      "MNT=" + quote(share.mountpoint),
      "if command -v fusermount3 >/dev/null 2>&1 && fusermount3 -u \"$MNT\" 2>/dev/null; then exit 0; fi",
      "if command -v fusermount >/dev/null 2>&1 && fusermount -u \"$MNT\" 2>/dev/null; then exit 0; fi",
      "if command -v gio >/dev/null 2>&1 && gio mount -u \"$MNT\" 2>/dev/null; then exit 0; fi",
      "umount \"$MNT\""
    ].join("\n")
    runAction(["bash", "-c", script], share.mountpoint, "unmount", "Unmounted " + share.title)
  }

  // ------------------------------------------------------- Cloud drive actions

  function expandHome(path) {
    var value = String(path || "")
    var home = String(Quickshell.env("HOME") || "")
    if (value === "~") return home
    if (value.indexOf("~/") === 0) return home + value.substring(1)
    return value
  }

  function noteCloud(text) {
    cloudActionStatus = text
    cloudActionTimer.restart()
  }

  function saveCloudStore(next) {
    cloudStore = next
    cloudStoreWriter.command = ["bash", "-c",
                                'mkdir -p "$(dirname "$2")" && printf %s "$1" > "$2"',
                                "storage-drives-cloud", JSON.stringify(next), cloudStorePath]
    cloudStoreWriter.running = true
  }

  function cloudAccount(remoteName) {
    for (var i = 0; i < cloudAccounts.length; i++) {
      if (cloudAccounts[i].remoteName === remoteName) return cloudAccounts[i]
    }
    return null
  }

  // Saves fields onto an existing account and nothing else. Changing the sync
  // interval used to go through addCloudAccount, which also re-enabled the
  // browse mount every time.
  function updateCloudAccount(remoteName, fields) {
    var acc = cloudAccount(remoteName)
    if (!acc) return
    saveCloudStore(Model.withCloudAccount(cloudStore, Object.assign({}, acc, fields)))
  }

  function setCloudInterval(remoteName, minutes) {
    var st = cloudStatuses[remoteName]
    updateCloudAccount(remoteName, { syncIntervalMin: minutes })
    if (st && st.timerEnabled) setCloudAutoSync(remoteName, true, minutes)
  }

  // Moving the browse mount: unmount at the old path, save, mount at the new
  // one. The unit files are rewritten on the way, since they name the path.
  function changeCloudMount(remoteName, newPath) {
    var acc = cloudAccount(remoteName)
    if (!acc) return "unknown account"
    var next = Object.assign({}, acc, { browseMountPath: String(newPath || "").trim() })
    var check = Model.validateCloudAccount(cloudAccounts, next, homePath, remoteName)
    if (!check.ok) {
      noteCloud(check.reason)
      return check.reason
    }
    var folderP = expandHome(acc.folderPath || "~/Cloud")
    var st = cloudStatuses[remoteName]
    var wasOn = !!(st && (st.browseEnabled || st.browseMounted))
    noteCloud("Moving the browse folder…")
    runCloudControl(["python3", cloudHelperPath, "browse", "--remote", remoteName, "--folder", folderP,
                     "--mount", expandHome(acc.browseMountPath || "~/Cloud-Browse"), "--disable"], function() {
      saveCloudStore(Model.withCloudAccount(cloudStore, next))
      if (wasOn || acc.autoMount !== false) {
        runCloudControl(["python3", cloudHelperPath, "browse", "--remote", remoteName, "--folder", folderP,
                         "--mount", expandHome(next.browseMountPath), "--enable"], function() {
          refreshCloudStatus(remoteName)
        })
      } else {
        refreshCloudStatus(remoteName)
      }
    })
    return "ok"
  }

  // The sync log, in a pager at its end — where the error that failed the
  // last run is. rclone writes its reasons there rather than to stderr.
  function openCloudLog(remoteName) {
    var st = cloudStatuses[remoteName]
    var path = st && st.logPath ? String(st.logPath) : ""
    if (path === "") {
      noteCloud("No sync log yet")
      return
    }
    launchRcloneTerminal("less +G " + quote(path))
  }

  function addCloudAccount(account) {
    if (!account || !account.remoteName) return "Enter the rclone remote name"
    var check = Model.validateCloudAccount(cloudAccounts, account, homePath, "")
    if (!check.ok) {
      noteCloud(check.reason)
      return check.reason
    }
    var next = Model.withCloudAccount(cloudStore, account)
    saveCloudStore(next)
    refreshCloudStatus(account.remoteName)
    var st = cloudStatuses[account.remoteName]
    var isAuth = isRemoteAuthenticated(account.remoteName) || (st && st.authenticated === true)
    if (isAuth && account.browseMountPath && account.autoMount !== false) {
      var folderP = expandHome(account.folderPath || "~/Cloud")
      var mountP = expandHome(account.browseMountPath)
      runCloudControl(["python3", cloudHelperPath, "browse", "--remote", account.remoteName, "--folder", folderP, "--mount", mountP, "--enable"], function() {
        refreshCloudStatus(account.remoteName)
      })
    }
    return "ok"
  }

  function removeCloudAccount(remoteName, purgeRcloneRemote) {
    if (!remoteName) return
    var acc = null
    for (var i = 0; i < cloudAccounts.length; i++) {
      if (cloudAccounts[i].remoteName === remoteName) { acc = cloudAccounts[i]; break }
    }
    var folderP = acc ? acc.folderPath : ""
    var mountP = acc ? acc.browseMountPath : ""
    var next = Model.withoutCloudAccount(cloudStore, remoteName)
    saveCloudStore(next)
    var args = ["python3", cloudHelperPath, "remove-account", "--remote", remoteName]
    if (purgeRcloneRemote) args.push("--purge-remote")
    if (mountP) args = args.concat(["--mount", expandHome(mountP)])
    if (folderP) args = args.concat(["--folder", expandHome(folderP)])
    runCloudControl(args, function() {
      refreshCloud()
    })
    if (selectedCloudRemote === remoteName) selectedCloudRemote = ""
  }

  function refreshCloud() {
    if (!cloudCheckProcess.running) cloudCheckProcess.running = true
    if (!cloudRemotesProcess.running) cloudRemotesProcess.running = true
    refreshCloudStatuses()
  }

  function refreshCloudStatuses() {
    if (!cloudAccounts || cloudAccounts.length === 0) return
    for (var i = 0; i < cloudAccounts.length; i++) {
      refreshCloudStatus(cloudAccounts[i].remoteName)
    }
  }

  // One status process at a time, and every request after the first waits its
  // turn. Returning early instead — what this did before — meant that looping
  // over every account refreshed the first and silently dropped the rest, so a
  // second Google Drive account never left "Checking…".
  property var _cloudStatusQueue: []

  // `first` puts the request at the head of the queue: the account someone
  // just opened should not wait behind every other account's refresh.
  function refreshCloudStatus(remoteName, first) {
    if (!remoteName) return
    if (cloudStatusProcess.running) {
      if (cloudStatusProcess.targetRemote === remoteName) return
      // A request already waiting keeps its place. Moving it to the back on
      // every refresh starved the accounts at the end: the 3.5 s poll
      // re-queued them all faster than ~2 s checks could drain, so the last
      // accounts never got a status, read as signed out, and kept the poll
      // (and rclone) running forever.
      var queued = _cloudStatusQueue.indexOf(remoteName) >= 0
      if (queued && first !== true) return
      var rest = _cloudStatusQueue.filter(function(r) { return r !== remoteName })
      _cloudStatusQueue = first === true ? [remoteName].concat(rest) : rest.concat([remoteName])
      return
    }
    var acc = null
    for (var i = 0; i < cloudAccounts.length; i++) {
      if (cloudAccounts[i].remoteName === remoteName) { acc = cloudAccounts[i]; break }
    }
    if (!acc) return
    var folderP = expandHome(acc.folderPath || "~/Cloud")
    var mountP = expandHome(acc.browseMountPath || "~/Cloud-Browse")
    cloudStatusProcess.targetRemote = remoteName
    cloudStatusProcess.command = ["python3", cloudHelperPath, "status",
                                  "--remote", remoteName,
                                  "--folder", folderP,
                                  "--mount", mountP]
    cloudStatusProcess.running = true
  }

  function refreshCloudFolders(remoteName) {
    if (!remoteName || cloudFoldersProcess.running) return
    var acc = null
    for (var i = 0; i < cloudAccounts.length; i++) {
      if (cloudAccounts[i].remoteName === remoteName) { acc = cloudAccounts[i]; break }
    }
    var folderP = acc ? expandHome(acc.folderPath || "~/Cloud") : expandHome("~/Cloud")
    cloudFoldersLoading = true
    cloudFoldersProcess.targetRemote = remoteName
    cloudFoldersProcess.command = ["python3", cloudHelperPath, "folders",
                                   "--remote", remoteName,
                                   "--folder", folderP]
    cloudFoldersProcess.running = true
  }

  function isCloudFolderSelected(folder) {
    if (!folder) return false
    var pending = pendingCloudFolders[folder.name]
    return pending === undefined ? folder.selected === true : pending === true
  }

  function toggleCloudFolder(remoteName, folder) {
    if (!folder || cloudBusy || !remoteName) return
    var name = String(folder.name)
    var next = !isCloudFolderSelected(folder)
    var copy = {}
    for (var key in pendingCloudFolders) copy[key] = pendingCloudFolders[key]
    copy[name] = next
    pendingCloudFolders = copy

    noteCloud(next ? "Adding " + name + "…" : "Removing " + name + " from sync…")
    runCloudControl(["python3", cloudHelperPath, "select", "--remote", remoteName, (next ? "--add=" : "--remove=") + name], function() {
      refreshCloudFolders(remoteName)
      refreshCloudStatus(remoteName)
    })
  }

  function setCloudRootFiles(remoteName, enabled) {
    if (cloudBusy || !remoteName) return
    noteCloud(enabled ? "Including root files…" : "Excluding root files…")
    runCloudControl(["python3", cloudHelperPath, "select", "--remote", remoteName, enabled ? "--root-files" : "--no-root-files"], function() {
      refreshCloudFolders(remoteName)
      refreshCloudStatus(remoteName)
    })
  }

  function syncCloudNow(remoteName, resync) {
    if (cloudBusy || !remoteName) return
    var acc = null
    for (var i = 0; i < cloudAccounts.length; i++) {
      if (cloudAccounts[i].remoteName === remoteName) { acc = cloudAccounts[i]; break }
    }
    var folderP = acc ? expandHome(acc.folderPath || "~/Cloud") : expandHome("~/Cloud")
    var mountP = acc ? expandHome(acc.browseMountPath || "~/Cloud-Browse") : expandHome("~/Cloud-Browse")
    noteCloud("Starting sync…")
    var args = ["python3", cloudHelperPath, "sync", "--remote", remoteName, "--folder", folderP, "--mount", mountP]
    if (resync === true) args.push("--resync")
    runCloudControl(args, function() {
      refreshCloudStatus(remoteName)
      cloudSyncPoll.restart()
    })
  }

  function setCloudAutoSync(remoteName, enabled, intervalMin) {
    if (cloudBusy || !remoteName) return
    var acc = null
    for (var i = 0; i < cloudAccounts.length; i++) {
      if (cloudAccounts[i].remoteName === remoteName) { acc = cloudAccounts[i]; break }
    }
    var folderP = acc ? expandHome(acc.folderPath || "~/Cloud") : expandHome("~/Cloud")
    var mountP = acc ? expandHome(acc.browseMountPath || "~/Cloud-Browse") : expandHome("~/Cloud-Browse")
    var interval = intervalMin || (acc ? acc.syncIntervalMin : 10) || 10
    noteCloud(enabled ? "Enabling automatic sync…" : "Pausing automatic sync…")
    var args = ["python3", cloudHelperPath, "timer", "--remote", remoteName, "--folder", folderP, "--mount", mountP, enabled ? "--enable" : "--disable"]
    if (enabled) args = args.concat(["--interval", String(interval)])
    runCloudControl(args, function() {
      refreshCloudStatus(remoteName)
    })
  }

  function toggleCloudBrowse(remoteName) {
    if (cloudBusy || !remoteName) return
    var acc = null
    for (var i = 0; i < cloudAccounts.length; i++) {
      if (cloudAccounts[i].remoteName === remoteName) { acc = cloudAccounts[i]; break }
    }
    var folderP = acc ? expandHome(acc.folderPath || "~/Cloud") : expandHome("~/Cloud")
    var mountP = acc ? expandHome(acc.browseMountPath || "~/Cloud-Browse") : expandHome("~/Cloud-Browse")
    var st = cloudStatuses[remoteName]
    var turningOn = !(st && st.browseMounted)
    noteCloud(turningOn ? "Mounting browse folder…" : "Unmounting browse folder…")
    var args = ["python3", cloudHelperPath, "browse", "--remote", remoteName, "--folder", folderP, "--mount", mountP, turningOn ? "--enable" : "--disable"]
    runCloudControl(args, function() {
      refreshCloudStatus(remoteName)
    })
  }

  function cleanupCloudStale(remoteName) {
    if (cloudBusy || !remoteName) return
    var acc = null
    for (var i = 0; i < cloudAccounts.length; i++) {
      if (cloudAccounts[i].remoteName === remoteName) { acc = cloudAccounts[i]; break }
    }
    var folderP = acc ? expandHome(acc.folderPath || "~/Cloud") : expandHome("~/Cloud")
    noteCloud("Verifying against remote before deleting…")
    runCloudControl(["python3", cloudHelperPath, "cleanup", "--remote", remoteName, "--folder", folderP], function() {
      refreshCloudFolders(remoteName)
      refreshCloudStatus(remoteName)
    })
  }

  function openCloudFolder(folderPath) {
    var expanded = expandHome(folderPath)
    if (!expanded) return
    var command = String(setting("fileManager", "")).replace(/^\s+|\s+$/g, "")
    if (command === "") {
      Quickshell.execDetached(["uwsm-app", "--", "xdg-open", expanded])
      return
    }
    Quickshell.execDetached(["bash", "-c", command + " " + quote(expanded)])
  }

  function openCloudBrowse(mountPath) {
    var expanded = expandHome(mountPath)
    if (!expanded) return
    var command = String(setting("fileManager", "")).replace(/^\s+|\s+$/g, "")
    if (command === "") {
      Quickshell.execDetached(["uwsm-app", "--", "xdg-open", expanded])
      return
    }
    Quickshell.execDetached(["bash", "-c", command + " " + quote(expanded)])
  }

  function launchRcloneTerminal(cmd) {
    var c = cmd && cmd !== "" ? cmd : "rclone config"
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", c])
  }

  // rclone is installed by the user, through Omarchy's own package picker:
  // this plugin never runs a package manager. It copies a search that shows
  // exactly the packages needed ("^rclone$ | ^fuse3$" - in that fzf list a
  // space would mean "and" and find nothing), opens the Omarchy menu at
  // Install, then watches for rclone to arrive.
  readonly property string rcloneSearch: rcloneFuse ? "^rclone$" : "^rclone$ | ^fuse3$"
  property bool rcloneWaiting: false
  property real rcloneWaitStarted: 0

  function copyRcloneSearch() {
    copyText("search for the Omarchy installer", rcloneSearch)
  }

  function installRclone() {
    copyRcloneSearch()
    Quickshell.execDetached(["omarchy-menu", "summon", "install"])
    rcloneWaitStarted = Date.now()
    rcloneWaiting = true
  }

  Timer {
    interval: 3000
    repeat: true
    running: root.rcloneWaiting
    onTriggered: {
      if (root.rcloneInstalled || Date.now() - root.rcloneWaitStarted > 15 * 60 * 1000) {
        root.rcloneWaiting = false
        return
      }
      root.refreshCloud()
    }
  }

  function hasRemote(remoteName) {
    var r = String(remoteName || "").trim()
    for (var i = 0; i < availableRemotes.length; i++) {
      if (availableRemotes[i].name === r) return true
    }
    return false
  }

  function isRemoteAuthenticated(remoteName) {
    var r = String(remoteName || "").trim()
    for (var i = 0; i < availableRemotes.length; i++) {
      if (availableRemotes[i].name === r) {
        return availableRemotes[i].authenticated === true
      }
    }
    return false
  }

  function hasCloudAccount(remoteName) {
    var r = String(remoteName || "").trim()
    for (var i = 0; i < cloudAccounts.length; i++) {
      if (cloudAccounts[i].remoteName === r) return true
    }
    return false
  }

  function authenticateCloudRemote(remoteName, providerType) {
    var cmd = Model.cloudAuthCommand(remoteName, providerType)
    if (providerType === "onedrive") {
      cmd = cmd + " || true; python3 " + quote(cloudHelperPath) + " status --remote " + quote(remoteName)
    }
    launchRcloneTerminal(cmd)
  }

  function hasUnauthenticatedCloudAccount() {
    for (var i = 0; i < cloudAccounts.length; i++) {
      var r = cloudAccounts[i].remoteName
      var st = cloudStatuses[r]
      // No status yet means its check is still queued, not signed out.
      if (st && !st.authenticated) return true
    }
    return false
  }

  // Same reasoning as the status queue. Setting a new command on a process
  // that is still running does not start it, but did overwrite the callback,
  // so an auto-mount landing mid-sync lost the sync's follow-up refresh.
  property var _onCloudControlDone: null
  property var _cloudControlQueue: []

  function runCloudControl(command, onDone) {
    if (cloudControlProcess.running) {
      _cloudControlQueue = _cloudControlQueue.concat([{ command: command, onDone: onDone || null }])
      return
    }
    _onCloudControlDone = onDone || null
    cloudControlProcess.command = command
    cloudControlProcess.running = true
  }

  function nextCloudControl() {
    if (_cloudControlQueue.length === 0 || cloudControlProcess.running) return
    var next = _cloudControlQueue[0]
    _cloudControlQueue = _cloudControlQueue.slice(1)
    runCloudControl(next.command, next.onDone)
  }

  function nextCloudStatus() {
    if (_cloudStatusQueue.length === 0 || cloudStatusProcess.running) return
    var next = _cloudStatusQueue[0]
    _cloudStatusQueue = _cloudStatusQueue.slice(1)
    refreshCloudStatus(next)
  }

  // ------------------------------------------------------- sleep guard
  //
  // Closing the lid with a drive mounted and pulling it out later is the same
  // way of losing files this widget exists to prevent, and nothing else on the
  // system stops it. logind will wait for a delay inhibitor before suspending
  // — up to InhibitDelayMaxSec, fifteen seconds here — which is far longer
  // than unmounting takes.
  //
  // The lock is released as soon as the unmounting is done, so a machine with
  // nothing mounted suspends as promptly as it did before. Re-arming waits for
  // the resume signal rather than happening immediately, so a fresh delay lock
  // can never land in the middle of the suspend it was just told about.

  readonly property string suspendTargetsPath:
    Quickshell.env("HOME") + "/.local/state/omarchy/drives-suspend"

  property string _suspendSignature: ""

  // The guard is a shell loop rather than QML because the unmounting has to
  // finish while the lock is still held; a Process started from here would
  // return long before that, and the lock would be gone.
  readonly property string suspendScript: [
    'set -u',
    'targets=$1',
    'notify=$3',
    'glyph=$4',
    // systemd-inhibit holds the lock as an fd, so logind drops it the moment
    // that process dies — but only if it actually dies. Killing this script
    // leaves it reparented to init, still holding a delay lock that nothing
    // will ever release, and every shell restart leaks another one until
    // suspend waits the full fifteen seconds every time.
    'inhibit_pid=""',
    // A trap covers a polite shutdown. It cannot cover SIGKILL, which is what
    // a shell restart actually delivers — and the inhibitor, reparented to
    // init, then holds a delay lock nothing will release. So the guard also
    // records its inhibitor's pid and reaps the previous one on the way in.
    // /proc is consulted rather than a name pattern, because this script's own
    // command line contains every string a pattern would match.
    'guardfile=$2',
    'reap_stale() {',
    '  [ -r "$guardfile" ] || return 0',
    '  old=$(cat "$guardfile" 2>/dev/null)',
    '  case "$old" in ""|*[!0-9]*) return 0 ;; esac',
    '  case "$(tr -d \'\\000\' 2>/dev/null < /proc/$old/cmdline)" in',
    // The whole group, not just the inhibitor. systemd-inhibit spawns the
    // process that waits for the signal, and killing only the parent leaves
    // that child alive — reparented, still holding a gdbus monitor, blocked
    // on a read that will never return. The lock was freed and nineteen
    // monitors were not.
    '    systemd-inhibit*) kill -- -"$old" 2>/dev/null ;;',
    '  esac',
    '}',
    // The guard loop itself outlives a shell restart too (and a bar that
    // rebuilds its widgets destroys the Process without killing it), and an
    // orphaned loop re-arms a fresh inhibitor and monitor after every resume.
    // So exactly one guard runs: each records its pid and stops the one before
    // it, recognised by its exact guard-file argument in /proc. TERM lets that
    // guard's own cleanup release its inhibitor and monitor.
    'loopfile="$guardfile.loop"',
    'reap_loop() {',
    '  [ -r "$loopfile" ] || return 0',
    '  old=$(cat "$loopfile" 2>/dev/null)',
    '  case "$old" in ""|*[!0-9]*) return 0 ;; esac',
    '  [ "$old" = "$$" ] && return 0',
    "  tr '\\000' '\\n' 2>/dev/null < /proc/$old/cmdline | grep -qxF -- \"$guardfile\" || return 0",
    '  kill "$old" 2>/dev/null',
    // Before the inhibitor is reaped below: an old guard whose inhibitor
    // vanished first would move on and start a monitor as it was stopped.
    '  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do',
    '    kill -0 "$old" 2>/dev/null || break',
    '    sleep 0.1',
    '  done',
    '}',
    'reap_loop',
    'reap_stale',
    'printf %s "$$" > "$loopfile"',
    'cleanup() {',
    '  [ -n "${inhibit_pid:-}" ] && kill -- -"$inhibit_pid" 2>/dev/null',
    '  [ -n "${MONITOR_PID:-}" ] && kill "$MONITOR_PID" 2>/dev/null',
    // And any child not tracked yet (a monitor started as the signal came).
    '  pkill -TERM -P $$ 2>/dev/null',
    '  exit 0',
    '}',
    'trap cleanup EXIT INT TERM HUP',
    'wait_for_sleep_signal() {',
    '  coproc MONITOR { gdbus monitor --system --dest org.freedesktop.login1' +
      ' --object-path /org/freedesktop/login1; }',
    '  while IFS= read -r line <&"${MONITOR[0]}"; do',
    '    case "$line" in *"PrepareForSleep ($1,)"*) break ;; esac',
    '  done',
    '  kill "$MONITOR_PID" 2>/dev/null',
    '  wait "$MONITOR_PID" 2>/dev/null',
    '}',
    // A drive that refused to unmount is the whole reason this exists, so it
    // is the one outcome that must not pass in silence. Sleeping while
    // believing your drives were parked is worse than never having been
    // offered the feature: it manufactures the confidence that gets a drive
    // pulled out of a sleeping laptop.
    'unmount_targets() {',
    '  [ -r "$1" ] || return 0',
    '  failed=""',
    '  while IFS= read -r dev; do',
    '    [ -n "$dev" ] || continue',
    '    if udisksctl unmount --no-user-interaction -b "$dev" >/dev/null 2>&1; then',
    '      continue',
    '    fi',
    '    failed="$failed $dev"',
    '  done < "$1"',
    '  [ -n "$failed" ] || return 0',
    '  [ "$2" = 1 ] || return 0',
    '  omarchy-notification-send -u critical -g "$3" "Still mounted going into sleep" \\',
    '    "Could not unmount:$failed — do not unplug until this is sorted" || true',
    '}',
    'export -f wait_for_sleep_signal unmount_targets',
    'while true; do',
    // setsid so the inhibitor leads its own process group: that is what makes
    // the whole tree killable as one, rather than by name — and this script's
    // own command line contains every name a pattern would match.
    '  setsid systemd-inhibit --what=sleep --mode=delay --who="Removable Drives"' +
      ' --why="Unmounting removable drives" \\',
    "    bash -c 'wait_for_sleep_signal true; unmount_targets \"$1\" \"$2\" \"$3\"'" +
      ' removable-drives "$targets" "$notify" "$glyph" &',
    '  inhibit_pid=$!',
    '  printf %s "$inhibit_pid" > "$guardfile"',
    '  wait "$inhibit_pid"',
    '  inhibit_pid=""',
    '  wait_for_sleep_signal false',
    'done'
  ].join("\n")

  // Rewritten only when the mounted set changes, so a drive appearing or going
  // quiet does not cost a write.
  function updateSuspendTargets() {
    if (!unmountOnSuspend) return
    var text = Model.suspendTargets(devices).join("\n")
    if (text === _suspendSignature) return
    _suspendSignature = text
    suspendWriter.command = ["bash", "-c",
                             'mkdir -p "$(dirname "$2")" && printf %s "$1" > "$2"',
                             "removable-drives", text, suspendTargetsPath]
    suspendWriter.running = true
  }

  // -------------------------------------------------- per-drive memory

  readonly property string storePath: Quickshell.env("HOME") + "/.local/state/omarchy/removable-drives.json"

  function saveDriveSetting(device, name, value) {
    if (!device) return
    var next = Model.withDriveSetting(store, device, name, value)
    store = next
    storeWriter.command = ["bash", "-c",
                           'mkdir -p "$(dirname "$2")" && printf %s "$1" > "$2"',
                           "removable-drives", JSON.stringify(next), storePath]
    storeWriter.running = true
    // Re-apply immediately so the panel renames without waiting for lsblk.
    var applied = devices.slice()
    Model.applyStore(applied, next)
    devices = applied
  }

  function setNickname(device, nickname) {
    saveDriveSetting(device, "nickname", String(nickname || "").replace(/^\s+|\s+$/g, ""))
  }

  // Both save null rather than false for the off position, so turning a
  // setting back off leaves the file the way it was before anyone touched it
  // instead of littering it with defaults written out longhand.
  function cycleAutoOpen(device) {
    saveDriveSetting(device, "autoOpen", Model.nextAutoOpen(driveSetting(device, "autoOpen", null)))
  }

  function setDriveReadOnly(device, readOnly) {
    saveDriveSetting(device, "readOnly", readOnly ? true : null)
  }

  function driveSetting(device, name, fallback) {
    var saved = Model.driveSettings(store, device)
    var value = saved[name]
    return value === undefined || value === null ? fallback : value
  }

  // ------------------------------------------------------- connect hooks
  //
  // A user-authored command run when a specific drive appears — a backup, a
  // sync, an import. It is never inferred and never suggested; it only runs
  // if someone put it in the state file for that drive themselves.
  //
  // Until it had somewhere to report, the panel drew a drive running an rsync
  // as an idle one, and someone could pull it mid-copy. The busy icon is no
  // substitute: kernel I/O goes quiet between an rsync's file batches.

  // Where a hook writes its progress, and the only file this plugin ever asks
  // one to touch. XDG_RUNTIME_DIR is tmpfs, so it never reaches persistent
  // storage and never outlives the session.
  readonly property string progressDir: {
    var runtime = String(Quickshell.env("XDG_RUNTIME_DIR") || "")
    return (runtime !== "" ? runtime : "/dev/shm") + "/omarchy-removable-drives/progress"
  }

  function progressName(device) {
    return Model.hookProgressName(Model.driveKey(device))
  }

  // The wrapper is what lets the panel tell a hook still working from one that
  // died: it records its own pid beside the progress file, and a trap clears
  // that however the hook ends. A pid file rather than a Process held here,
  // because a hook outlives a shell restart and the panel should find it again
  // when it comes back.
  //
  // The user's command still reaches bash as a positional argument rather than
  // as script text, and gains $3 — the file above — beside the $1 and $2 it
  // already had. Every hook written before this one is unaffected.
  readonly property string hookScript: [
    'set -u',
    'dir=$1',
    'file=$dir/$2',
    'mkdir -p "$dir" || exit 1',
    ': > "$file" || exit 1',
    "trap 'rm -f \"$file.pid\"' EXIT INT TERM HUP",
    'printf %s "$$" > "$file.pid"',
    'bash -c "$5" removable-drives "$3" "$4" "$file"'
  ].join("\n")

  function runConnectHook(device) {
    var command = String(driveSetting(device, "onConnect", "")).replace(/^\s+|\s+$/g, "")
    if (command === "") return
    var name = progressName(device)
    if (name === "") return
    markHookStarted(name)
    Quickshell.execDetached(["bash", "-c", hookScript, "storage-drives",
                             progressDir, name, device.path, mountpointOf(device), command])
  }

  function mountpointOf(device) {
    if (!device) return ""
    for (var i = 0; i < device.volumes.length; i++) {
      if (device.volumes[i].mounted) return device.volumes[i].mountpoint
    }
    return ""
  }

  // One pass over every drive with a hook: whether the process this plugin
  // started is still alive, then whatever it has written. Capped, because a
  // runaway hook writing into its progress file should cost a truncated line
  // rather than the whole panel.
  readonly property string hookPollScript: [
    'set -u',
    'dir=$1',
    'shift',
    'for name; do',
    '  file=$dir/$name',
    '  run=0',
    '  pid=$(cat "$file.pid" 2>/dev/null) || pid=""',
    '  case "$pid" in',
    '    ""|*[!0-9]*) ;;',
    '    *) kill -0 "$pid" 2>/dev/null && run=1 ;;',
    '  esac',
    '  echo "==> $name $run <=="',
    '  if [ -r "$file" ]; then head -c 1024 "$file"; echo; fi',
    'done'
  ].join("\n")

  function hookedDrives() {
    var out = []
    for (var i = 0; i < devices.length; i++) {
      var command = String(driveSetting(devices[i], "onConnect", "")).replace(/^\s+|\s+$/g, "")
      if (command === "") continue
      var name = progressName(devices[i])
      if (name !== "") out.push(name)
    }
    return out
  }

  // Polling stops once every hook has reported itself finished, so a drive
  // whose hook ran an hour ago costs nothing per second. A hook starting marks
  // that drive active again, which is what starts the poll back up.
  function hooksWorthPolling() {
    var names = hookedDrives()
    for (var i = 0; i < names.length; i++) {
      var state = hooks[names[i]]
      if (!state || state.active) return names
    }
    return []
  }

  function sampleHooks() {
    if (hooksProcess.running) return
    var names = hooksWorthPolling()
    if (names.length === 0) return
    var command = ["bash", "-c", hookPollScript, "removable-drives", progressDir]
    for (var i = 0; i < names.length; i++) command.push(names[i])
    hooksProcess.command = command
    hooksProcess.running = true
  }

  // Rebuilt against the drives actually attached, the same way the busy tally
  // is, so a drive that has gone takes its hook state with it.
  function applyHooks(raw) {
    var report = Model.parseHookReport(raw)
    var live = hookedDrives()
    var next = {}
    for (var i = 0; i < live.length; i++) {
      var name = live[i]
      if (report[name] !== undefined) next[name] = report[name]
      else if (hooks[name] !== undefined) next[name] = hooks[name]
    }
    hooks = next
    advancePendingEject()
  }

  // Busy from the instant the hook is launched rather than from the first poll
  // a second later, so an eject clicked in that gap is held rather than cutting
  // power to a copy that had only just started. It is also what puts the drive
  // back in the poll, since the poll stops once every hook has finished.
  function markHookStarted(name) {
    var next = {}
    for (var key in hooks) next[key] = hooks[key]
    next[name] = { active: true, percent: null, status: "", done: false }
    hooks = next
  }

  function hookStateFor(device) {
    if (!device) return null
    var name = progressName(device)
    return name === "" ? null : (hooks[name] || null)
  }

  function hookActive(device) {
    var state = hookStateFor(device)
    return !!(state && state.active)
  }

  function hookLabelFor(device) {
    return Model.hookLabel(hookStateFor(device))
  }

  // What `status` reports, so a backup script polling for a drive to settle
  // sees the same thing the panel does.
  function hookReport() {
    var out = []
    for (var i = 0; i < devices.length; i++) {
      var state = hookStateFor(devices[i])
      if (!state) continue
      out.push({
        device: devices[i].path,
        active: state.active,
        percent: state.percent,
        status: state.status,
        done: state.done
      })
    }
    return out
  }

  // -------------------------------------------------------------- trash

  function mountedMountpoints() {
    var out = []
    for (var d = 0; d < devices.length; d++) {
      for (var v = 0; v < devices[d].volumes.length; v++) {
        if (devices[d].volumes[v].mounted) out.push(devices[d].volumes[v].mountpoint)
      }
    }
    return out
  }

  function probeTrash() {
    if (trashProcess.running || uid === "") return
    var mounts = mountedMountpoints()
    if (mounts.length === 0) {
      trashSizes = ({})
      return
    }
    var command = ["du", "-sb", "--"]
    for (var i = 0; i < mounts.length; i++) {
      var candidates = Model.trashCandidates(mounts[i], uid)
      for (var c = 0; c < candidates.length; c++) command.push(candidates[c])
    }
    trashProcess.command = command
    trashProcess.running = true
  }

  function trashSizeFor(volume) {
    if (!volume || !volume.mounted) return 0
    var candidates = Model.trashCandidates(volume.mountpoint, uid)
    for (var i = 0; i < candidates.length; i++) {
      var size = trashSizes[candidates[i]]
      if (size > 0) return size
    }
    return 0
  }

  function trashPathFor(volume) {
    if (!volume || !volume.mounted) return ""
    var candidates = Model.trashCandidates(volume.mountpoint, uid)
    for (var i = 0; i < candidates.length; i++) {
      if (trashSizes[candidates[i]] > 0) return candidates[i]
    }
    return ""
  }

  // Recursive deletion, so the path is re-derived from the live mount list
  // and matched exactly rather than trusted from the caller.
  function emptyTrash(volume) {
    var path = trashPathFor(volume)
    if (path === "" || busy) return
    if (!Model.isSafeTrashPath(path, mountedMountpoints(), uid)) {
      lastError = "Refusing to empty an unrecognised trash path"
      return
    }
    runAction(["rm", "-rf", "--", path], volume.fsPath, "trash",
              "Emptied trash on " + volume.title)
  }

  // ------------------------------------------- labels and integrity

  // Renaming a filesystem and running its fsck are both on
  // org.freedesktop.UDisks2.Filesystem, and `udisksctl` has a verb for
  // neither — so these three go over the bus directly. Both are
  // `modify-device` in the udisks policy, which is `allow_active: yes` for a
  // removable drive: the same no-password path mounting already takes, and
  // still nothing running as root.

  // One script for all three, because they share a shape: resolve the udisks
  // object for the device, take the filesystem offline, do the one thing, put
  // it back. The mount is restored whether or not the middle step worked — a
  // rename udisks refused should not also leave the drive unmounted.
  //
  // The object path is asked for rather than built. udisks escapes the kernel
  // name into it, so an unlocked LUKS volume at /dev/mapper/backup is
  // .../block_devices/dm_2d3, and a plugin guessing at that encoding would
  // work on every stick and fail on every encrypted one.
  //
  // Everything variable arrives as a positional argument. The label is the one
  // string here a person typed rather than a device supplied, and passing it
  // as "$4" means it never becomes part of the script text.
  readonly property string fsScript: [
    'set -u',
    'dev=$1',
    'remount=$2',
    'method=$3',
    'label=${4-}',
    'raw=$(busctl call org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager' +
      ' org.freedesktop.UDisks2.Manager ResolveDevice "a{sv}a{sv}" 1 path s "$dev" 0) || exit 1',
    // The path is the last field and arrives wrapped in quotes. Trimming from
    // the first slash and then dropping one trailing character lifts it out
    // without naming a quote anywhere — a literal one would have to survive
    // both QML's escaping and bash's, and only looks right in one of them.
    'obj=/${raw#*/}',
    'obj=${obj%?}',
    'case "$obj" in',
    '  /org/freedesktop/UDisks2/block_devices/*) ;;',
    '  *) echo "udisks does not recognise $dev" >&2; exit 1 ;;',
    'esac',
    'if [ "$remount" = 1 ]; then udisksctl unmount --no-user-interaction -b "$dev" >/dev/null || exit 1; fi',
    'rc=0',
    'if [ "$method" = SetLabel ]; then',
    '  busctl --timeout=120 call org.freedesktop.UDisks2 "$obj"' +
      ' org.freedesktop.UDisks2.Filesystem SetLabel "sa{sv}" "$label" 0 || rc=$?',
    'else',
    // An fsck has no useful upper bound — a big NTFS volume can take an hour —
    // so the bus timeout is a day rather than busctl's default 25 seconds,
    // which would abandon the call while the tool was still working.
    '  busctl --timeout=86400 call org.freedesktop.UDisks2 "$obj"' +
      ' org.freedesktop.UDisks2.Filesystem "$method" "a{sv}" 0 || rc=$?',
    'fi',
    // Putting the filesystem back can fail on its own — the drive was renamed
    // or repaired and is now sitting unmounted. Swallowing that reported the
    // rename as a plain success while the drive had quietly gone away, so it
    // comes back as its own exit code when nothing else went wrong, and as an
    // extra line on stderr when something did.
    'remount_rc=0',
    'if [ "$remount" = 1 ]; then udisksctl mount --no-user-interaction -b "$dev" >/dev/null || remount_rc=$?; fi',
    'if [ "$remount_rc" != 0 ]; then',
    '  echo "the filesystem could not be mounted again" >&2',
    '  if [ "$rc" = 0 ]; then rc=75; fi',
    'fi',
    'exit $rc'
  ].join("\n")

  // One round trip per filesystem type, and only for the types attached, plus
  // one for the list of filesystems udisks will create. That last one is asked
  // even when nothing attached has a filesystem at all — a stick with no
  // partition table is exactly the one somebody wants to format.
  readonly property string capsScript:
    'out=$(busctl --timeout=10 get-property org.freedesktop.UDisks2' +
    ' /org/freedesktop/UDisks2/Manager org.freedesktop.UDisks2.Manager' +
    ' SupportedFilesystems 2>/dev/null) || out="";' +
    ' echo "Supported $out";' +
    ' for fs in "$@"; do for op in CanCheck CanRepair; do' +
    ' out=$(busctl --timeout=10 call org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager' +
    ' org.freedesktop.UDisks2.Manager "$op" s "$fs" 2>/dev/null) || out="";' +
    ' echo "$op $fs $out"; done; done'

  // What rescan and a fresh install of a missing tool both mean: ask udisks
  // again rather than trusting the answer from before.
  function forgetCapabilities() {
    _capsProbed = false
    _capsSignature = ""
  }

  function probeCapabilities() {
    if (capsProcess.running || devices.length === 0) return
    var types = Model.fsTypesPresent(devices)
    var signature = types.join(",")
    if (_capsProbed && signature === _capsSignature) return
    _capsProbed = true
    _capsSignature = signature
    var command = ["bash", "-c", capsScript, "removable-drives"]
    for (var i = 0; i < types.length; i++) command.push(types[i])
    capsProcess.command = command
    capsProcess.running = true
  }

  function deviceOfVolume(volume) {
    if (!volume) return null
    for (var d = 0; d < devices.length; d++) {
      for (var v = 0; v < devices[d].volumes.length; v++) {
        if (devices[d].volumes[v].fsPath === volume.fsPath) return devices[d]
      }
    }
    return null
  }

  // All three take the filesystem offline, and unmounting a drive mid-copy is
  // the one move this widget exists to prevent. Unlike an eject the request is
  // refused rather than held: an eject that runs two seconds late is still the
  // eject you asked for, while a rename that fires once you have wandered off
  // is a drive silently unmounted behind you.
  function fsActionBlocked(volume) {
    if (!volume) return "No volume selected"
    var device = deviceOfVolume(volume)
    if (device && hookActive(device)) {
      return device.title + " is still running its connect hook — try again once it finishes"
    }
    if (device && Model.sustainedBusy(_busyTicks[device.name])) {
      return device.title + " is still being written to — try again once it settles"
    }
    return ""
  }

  function runFsAction(volume, method, label, action, successMessage) {
    runAction(["bash", "-c", fsScript, "removable-drives",
               volume.fsPath, volume.mounted ? "1" : "0", method, label],
              volume.fsPath, action, successMessage)
  }

  // These three answer with "ok" or with the reason they did not run, so a
  // script calling them over IPC learns what the panel would have shown in its
  // status line. Silence would be worse than a refusal: a rename that was
  // turned away for a drive still settling looks exactly like one that worked.
  function refuse(reason) {
    lastError = reason
    return reason
  }

  // "ISO9660 volumes" rather than "an ISO9660 volume", so the sentence does not
  // have to guess at an article for a name it has never seen.
  function describeFs(volume) {
    var named = volume ? Model.clean(volume.fstypeLabel) : ""
    if (named === "") named = volume ? Model.clean(volume.fstype) : ""
    return named === "" ? "This filesystem" : named + " volumes"
  }

  function setVolumeLabel(volume, label) {
    if (!volume) return "unknown volume"
    if (busy) return refuse("Another action is still running")
    if (!Model.canRelabel(volume)) {
      return refuse(describeFs(volume) + " cannot be renamed from here")
    }
    var checked = Model.validateLabel(volume, label)
    if (!checked.ok) return refuse(checked.message)
    // Enter on a field nobody edited is the common case, and it should close
    // the editor rather than unmount the drive to write the name it already
    // has.
    if (checked.label === Model.normaliseLabel(volume.label)) {
      actionStatus = ""
      return "unchanged"
    }
    var blocked = fsActionBlocked(volume)
    if (blocked !== "") return refuse(blocked)
    runFsAction(volume, "SetLabel", checked.label, "relabel",
                checked.label === "" ? "Cleared the name on " + volume.title
                                     : "Renamed " + volume.title + " to " + checked.label)
    return "ok"
  }

  function checkVolume(volume) {
    if (!volume) return "unknown volume"
    if (busy) return refuse("Another action is still running")
    if (!Model.canCheck(fsCapabilities, volume)) {
      return refuse(describeFs(volume) + " cannot be checked here")
    }
    var blocked = fsActionBlocked(volume)
    if (blocked !== "") return refuse(blocked)
    runFsAction(volume, "Check", "", "check", "")
    return "ok"
  }

  // Reachable only from the button a failed check puts on screen, so a repair
  // — the one operation here that rewrites a filesystem — always follows a
  // deliberate second click on a volume already known to be damaged.
  function repairVolume(volume) {
    if (!volume) return "unknown volume"
    if (busy) return refuse("Another action is still running")
    if (!Model.canRepair(fsCapabilities, volume)) {
      return refuse(describeFs(volume) + " cannot be repaired here")
    }
    if (!Model.repairAuthorised(
          { fsPath: checkedFsPath, uuid: checkedUuid, verdict: checkVerdict }, volume)) {
      return refuse("Check this filesystem before repairing it")
    }
    var blocked = fsActionBlocked(volume)
    if (blocked !== "") return refuse(blocked)
    runFsAction(volume, "Repair", "", "repair", "")
    return "ok"
  }

  // ------------------------------------------------------------- formatting

  // Format lives on org.freedesktop.UDisks2.Block rather than on Filesystem,
  // and takes (s type, a{sv} options), so it resolves the object the same way
  // the rename and fsck script does — asked for, never built, because udisks
  // escapes the kernel name into it.
  //
  // There is no unmount and no remount around this one. A mounted volume is
  // refused outright rather than taken offline on the way to being erased, so
  // by the time the script runs the drive is already the way the person left
  // it.
  //
  // The options are assembled as positional arguments and counted, because the
  // label is the one string here somebody typed and it must never become part
  // of the script text. take-ownership is what makes a fresh ext4 or btrfs
  // writable by the person who asked for it rather than by root alone; udisks
  // ignores it on the filesystems that have no ownership to take.
  readonly property string formatScript: [
    'set -u',
    'dev=$1',
    'fstype=$2',
    'label=$3',
    'erase=$4',
    'raw=$(busctl call org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager' +
      ' org.freedesktop.UDisks2.Manager ResolveDevice "a{sv}a{sv}" 1 path s "$dev" 0) || exit 1',
    'obj=/${raw#*/}',
    'obj=${obj%?}',
    'case "$obj" in',
    '  /org/freedesktop/UDisks2/block_devices/*) ;;',
    '  *) echo "udisks does not recognise $dev" >&2; exit 1 ;;',
    'esac',
    'count=1',
    'set -- take-ownership b true',
    'if [ -n "$label" ]; then count=$((count + 1)); set -- "$@" label s "$label"; fi',
    'if [ "$erase" = 1 ]; then count=$((count + 1)); set -- "$@" erase s zero; fi',
    // Zeroing a drive has no useful upper bound and neither does laying down a
    // big NTFS volume, so the bus timeout is a day rather than busctl's default
    // twenty-five seconds, which would abandon the call mid-write.
    'busctl --timeout=86400 call org.freedesktop.UDisks2 "$obj"' +
      ' org.freedesktop.UDisks2.Block Format "sa{sv}" "$fstype" "$count" "$@"'
  ].join("\n")

  // The only thing here that destroys data on purpose. Every refusal comes
  // back as the sentence the panel would have shown, so a script calling this
  // over IPC learns why nothing happened — and the plan is validated whole,
  // against the volume it names, before a byte of it reaches the bus.
  function formatVolume(volume, fstype, label, quick) {
    if (!volume) return "unknown volume"
    if (busy) return refuse("Another action is still running")

    var plan = {
      fsPath: volume.fsPath,
      fstype: Model.clean(fstype),
      label: Model.normaliseLabel(label),
      quick: quick !== false
    }
    var checked = Model.validateFormat(fsCapabilities, volume, deviceOfVolume(volume), plan)
    if (!checked.ok) return refuse(checked.reason)

    var blocked = fsActionBlocked(volume)
    if (blocked !== "") return refuse(blocked)

    // Nothing is opened afterwards, and nothing is mounted back. Somebody who
    // has just erased a disk wants to see the empty volume in the panel, not a
    // file manager opening over it.
    _openAfterPath = ""
    runAction(["bash", "-c", formatScript, "removable-drives",
               plan.fsPath, plan.fstype, plan.label, plan.quick ? "0" : "1"],
              plan.fsPath, "format", Model.describeFormat(volume, plan.fstype))
    return "ok"
  }

  // Wiping the whole drive: a fresh GPT table, then one partition filling it,
  // formatted in the same call. Both steps are udisks methods on the
  // allow_active path, so this needs no root and no helper package — unlike
  // the parted/wipefs route, which needs both.
  //
  // The partition table interface appears on the disk object a moment after
  // Format("gpt") returns, once udisks has re-read the device, so the second
  // call waits for it rather than racing it. It is called exactly once: a
  // retry after a half-finished call would stack a second partition behind
  // the first.
  readonly property string formatDriveScript: [
    'set -u',
    'dev=$1',
    'fstype=$2',
    'label=$3',
    'erase=$4',
    'ptype=$5',
    'raw=$(busctl call org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager' +
      ' org.freedesktop.UDisks2.Manager ResolveDevice "a{sv}a{sv}" 1 path s "$dev" 0) || exit 1',
    'obj=/${raw#*/}',
    'obj=${obj%?}',
    'case "$obj" in',
    '  /org/freedesktop/UDisks2/block_devices/*) ;;',
    '  *) echo "udisks does not recognise $dev" >&2; exit 1 ;;',
    'esac',
    'if [ "$erase" = 1 ]; then',
    '  busctl --timeout=86400 call org.freedesktop.UDisks2 "$obj"' +
      ' org.freedesktop.UDisks2.Block Format "sa{sv}" gpt 1 erase s zero || exit 1',
    'else',
    '  busctl --timeout=600 call org.freedesktop.UDisks2 "$obj"' +
      ' org.freedesktop.UDisks2.Block Format "sa{sv}" gpt 0 || exit 1',
    'fi',
    'tries=0',
    'until busctl get-property org.freedesktop.UDisks2 "$obj" org.freedesktop.UDisks2.PartitionTable Type >/dev/null 2>&1; do',
    '  tries=$((tries + 1))',
    '  if [ "$tries" -ge 40 ]; then echo "udisks never saw the new partition table on $dev" >&2; exit 1; fi',
    '  sleep 0.25',
    'done',
    'count=1',
    'set -- take-ownership b true',
    'if [ -n "$label" ]; then count=$((count + 1)); set -- "$@" label s "$label"; fi',
    'busctl --timeout=86400 call org.freedesktop.UDisks2 "$obj"' +
      ' org.freedesktop.UDisks2.PartitionTable CreatePartitionAndFormat "ttssa{sv}sa{sv}"' +
      ' 1048576 0 "$ptype" "" 0 "$fstype" "$count" "$@" >/dev/null'
  ].join("\n")

  function formatDrive(device, fstype, label, quick) {
    if (!device) return "unknown device"
    if (busy) return refuse("Another action is still running")
    var plan = {
      path: device.path,
      fstype: Model.clean(fstype),
      label: Model.normaliseLabel(label),
      quick: quick !== false
    }
    var checked = Model.validateDriveFormat(fsCapabilities, device, plan)
    if (!checked.ok) return refuse(checked.reason)
    if (isDeviceBusy(device) || Model.sustainedBusy(_busyTicks[device.name])) {
      return refuse(device.title + " is still being written to — try again once it settles")
    }
    _openAfterPath = ""
    runAction(["bash", "-c", formatDriveScript, "storage-drives",
               plan.path, plan.fstype, plan.label, plan.quick ? "0" : "1",
               Model.partitionTypeFor(plan.fstype)],
              plan.path, "format", Model.describeDriveFormat(device, plan.fstype))
    return "ok"
  }

  // sysfs is read with plain cat, a few directories up from each block
  // device: the USB device's negotiated speed, the NVMe controller's PCIe
  // link, the SATA port's link. Nothing here needs root.
  readonly property string linkScript: [
    'set -u',
    'for name; do',
    '  echo "==> $name <=="',
    '  d=$(readlink -f "/sys/block/$name/device" 2>/dev/null) || continue',
    '  [ -n "$d" ] || continue',
    '  n=$d',
    '  while [ -n "$n" ] && [ "$n" != / ] && [ "$n" != /sys ]; do',
    '    if [ -r "$n/speed" ] && [ -r "$n/idVendor" ]; then',
    '      echo "usbSpeed=$(cat "$n/speed" 2>/dev/null)"',
    '      echo "usbVersion=$(cat "$n/version" 2>/dev/null)"',
    '      echo "usbId=$(cat "$n/idVendor" 2>/dev/null):$(cat "$n/idProduct" 2>/dev/null)"',
    '      break',
    '    fi',
    '    case "${n##*/}" in',
    '      ata[0-9]*)',
    '        for s in "$n"/link*/ata_link/link*/sata_spd; do',
    '          if [ -r "$s" ]; then echo "sataSpeed=$(cat "$s" 2>/dev/null)"; break; fi',
    '        done',
    '        break ;;',
    '    esac',
    '    n=${n%/*}',
    '  done',
    '  p=$d/device',
    '  if [ -r "$p/current_link_speed" ]; then',
    '    echo "pcieSpeed=$(cat "$p/current_link_speed" 2>/dev/null)"',
    '    echo "pcieWidth=$(cat "$p/current_link_width" 2>/dev/null)"',
    '    echo "pcieMaxSpeed=$(cat "$p/max_link_speed" 2>/dev/null)"',
    '    echo "pcieMaxWidth=$(cat "$p/max_link_width" 2>/dev/null)"',
    '  fi',
    'done'
  ].join("\n")

  function probeLinks() {
    if (linkProcess.running) return
    var names = []
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].kind !== "swap") names.push(devices[i].name)
    }
    names.sort()
    var signature = names.join(",")
    if (signature === _linkSignature) return
    _linkSignature = signature
    if (names.length === 0) {
      links = ({})
      return
    }
    linkProcess.command = ["bash", "-c", linkScript, "storage-drives"].concat(names)
    linkProcess.running = true
  }

  function probeTools() {
    if (toolsProcess.running) return
    toolsProcess.command = ["bash", "-c",
                            'for t; do command -v "$t" >/dev/null 2>&1 && echo "$t"; done',
                            "storage-drives"].concat(Model.OPTIONAL_TOOLS)
    toolsProcess.running = true
  }

  // Info rows are click-to-copy: a UUID or a serial is copied far more often
  // than it is read.
  function copyText(label, value) {
    var text = String(value === undefined || value === null ? "" : value)
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", 'printf %s "$1" | wl-copy', "storage-drives", text])
    actionStatus = "Copied " + Model.plain(label)
  }

  // The other half of naming who holds a busy mount: asking them to let go.
  // SIGTERM only, so programs get to save, and only for the pids fuser
  // listed — which can only ever be this user's own processes, since kill
  // refuses anyone else's. The shell itself is never on the list: the script's
  // parent is the shell, and it is skipped by pid.
  property string _blockedAction: ""
  property string _blockedPath: ""

  readonly property string closeBlockersScript: [
    'set -u',
    'for pid; do',
    '  case "$pid" in ""|*[!0-9]*) continue ;; esac',
    '  [ "$pid" = "$PPID" ] && continue',
    '  kill -TERM "$pid" 2>/dev/null || true',
    'done',
    'sleep 2'
  ].join("\n")

  function closeBlockersAndRetry() {
    if (blockers.length === 0 || closeBlockersProcess.running || busy) return
    var command = ["bash", "-c", closeBlockersScript, "storage-drives"]
    for (var i = 0; i < blockers.length; i++) command.push(String(blockers[i].pid))
    actionStatus = "Asking " + Model.describeBlockers(blockers) + " to close…"
    closeBlockersProcess.command = command
    closeBlockersProcess.running = true
  }

  function retryBlocked() {
    var action = _blockedAction
    var path = _blockedPath
    if (action === "eject") {
      if (path === "*") ejectAll()
      else eject(deviceByPath(path))
      return
    }
    var volume = volumeByPath(path)
    if (volume) unmount(volume, false)
    else if (deviceByPath(path)) unmountAll(deviceByPath(path))
  }

  // Same bargain as the gvfs hint: a plugin may not install anything, so it
  // names the package udisks went looking for and opens Omarchy's installer.
  function installCheckTools(volume) {
    var hint = Model.checkHint(fsCapabilities, volume)
    if (!hint || hint.packages === "") return
    forgetCapabilities()
    Quickshell.execDetached(["omarchy-install-app", hint.label, hint.packages])
  }

  // Check exits 0 whether or not it liked what it found, so the verdict is on
  // stdout rather than in the exit code, and a filesystem that failed its
  // check is a result to report rather than an error to raise.
  function applyVerdict(action, fsPath) {
    var volume = volumeByPath(fsPath)
    var verdict = Model.parseFsVerdict(_stdout)
    var name = volume ? volume.title : "A drive"

    if (action === "check") {
      checkVerdict = verdict
      checkedFsPath = fsPath
      checkedUuid = volume ? volume.uuid : ""
      actionStatus = Model.describeCheck(volume, verdict)
      if (verdict === false) {
        notify("Filesystem errors found", name + " did not pass its check.",
               Model.GLYPH_ALERT, "normal")
      }
      return
    }

    checkVerdict = null
    checkedFsPath = ""
    checkedUuid = ""
    actionStatus = Model.describeRepair(volume, verdict)
    // Three outcomes, not two: the tool can also finish without saying whether
    // it fixed anything, and reporting that as a failed repair would be as
    // wrong as reporting it as a clean one.
    var repaired = verdict === true
    notify(repaired ? "Repaired" : "Repair did not finish cleanly",
           actionStatus,
           repaired ? Model.GLYPH_HEALTHY : Model.GLYPH_ALERT,
           repaired ? "" : "normal")
  }

  // ------------------------------------------------------- drive health
  //
  // smartctl is the reflex and it is the wrong tool: it wants root for most
  // devices, and smartmontools is not standard on Omarchy, so reaching for it
  // would break both "nothing runs as root" and "no extra packages". udisks
  // already does the privileged read and publishes the answer over the bus on
  // the same allow_active path mounting takes.
  //
  // Most drives will answer with nothing. Only an external SSD or a hard drive
  // behind a SAT-capable bridge reports health at all; a USB thumb drive
  // carries neither interface, and that silence is the normal answer rather
  // than something to explain.

  // Both interfaces are asked of every drive and the absent one simply answers
  // nothing, which costs less than asking udisks which of the two a drive has
  // and then asking again.
  //
  // The object path is resolved rather than built, the same way fsScript does
  // it — and health lives on the drive object rather than the block one, so it
  // takes the second lookup to get there.
  //
  // Reading the properties does not refresh them. udisks hands back whatever
  // its own last poll cached, which measured ten minutes stale here: the bus
  // said 308 K while every hwmon sensor on the same drive said 36.85 °C, a gap
  // of two degrees that is staleness rather than arithmetic. So SmartUpdate is
  // called first. It is `allow_active: yes` in the udisks policy — the same
  // no-password path everything else here takes — under
  // org.freedesktop.udisks2.ata-smart-update and its nvme twin.
  //
  // Best-effort, and deliberately not `|| continue`: a drive that refuses an
  // update is still read, because a stale number beats no number. `nowakeup`
  // goes to ATA, which is the interface that takes it, so a parked external
  // disk is not spun up merely to draw a temperature. An NVMe has no heads to
  // park and takes no such option.
  readonly property string smartScript: [
    'set -u',
    'for dev; do',
    '  echo "==> $dev <=="',
    '  raw=$(busctl --timeout=20 call org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager' +
      ' org.freedesktop.UDisks2.Manager ResolveDevice "a{sv}a{sv}" 1 path s "$dev" 0 2>/dev/null) || continue',
    '  obj=/${raw#*/}',
    '  obj=${obj%?}',
    '  case "$obj" in /org/freedesktop/UDisks2/block_devices/*) ;; *) continue ;; esac',
    '  raw=$(busctl --timeout=20 get-property org.freedesktop.UDisks2 "$obj"' +
      ' org.freedesktop.UDisks2.Block Drive 2>/dev/null) || continue',
    '  drive=/${raw#*/}',
    '  drive=${drive%?}',
    '  case "$drive" in /org/freedesktop/UDisks2/drives/*) ;; *) continue ;; esac',
    '  busctl --timeout=30 call org.freedesktop.UDisks2 "$drive"' +
      ' org.freedesktop.UDisks2.Drive.Ata SmartUpdate "a{sv}" 1 nowakeup b true' +
      ' >/dev/null 2>&1 || true',
    '  for p in SmartFailing SmartTemperature SmartPowerOnSeconds SmartNumBadSectors' +
      ' SmartSelftestStatus SmartUpdated; do',
    '    v=$(busctl --timeout=20 get-property org.freedesktop.UDisks2 "$drive"' +
      ' org.freedesktop.UDisks2.Drive.Ata "$p" 2>/dev/null) || continue',
    '    echo "$p $v"',
    '  done',
    '  busctl --timeout=30 call org.freedesktop.UDisks2 "$drive"' +
      ' org.freedesktop.UDisks2.NVMe.Controller SmartUpdate "a{sv}" 0 >/dev/null 2>&1 || true',
    '  for p in SmartCriticalWarning SmartTemperature SmartPowerOnHours' +
      ' SmartSelftestStatus SmartUpdated; do',
    '    v=$(busctl --timeout=20 get-property org.freedesktop.UDisks2 "$drive"' +
      ' org.freedesktop.UDisks2.NVMe.Controller "$p" 2>/dev/null) || continue',
    '    echo "$p $v"',
    '  done',
    'done'
  ].join("\n")

  // Read once when the set of attached drives changes, and on an explicit
  // rescan. Never on the free-space timer: refreshing it is a round trip to
  // the drive itself, and every answer but the temperature changes over hours
  // rather than seconds. The temperature is therefore a snapshot from the last
  // read, which is what the health icon re-reads on a click.
  property double _lastSmartProbeTime: 0

  function probeSmart(force) {
    if (smartProcess.running) return
    var now = Date.now()
    if (force === true && (now - _lastSmartProbeTime < 4000)) return

    var paths = []
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].kind !== "swap") paths.push(devices[i].path)
    }
    paths.sort()
    var signature = paths.join(",")
    if (force !== true && signature === _smartSignature) return
    _smartSignature = signature
    _lastSmartProbeTime = now
    if (paths.length === 0) {
      smart = ({})
      return
    }
    var command = ["bash", "-c", smartScript, "storage-drives"]
    for (var p = 0; p < paths.length; p++) command.push(paths[p])
    smartProcess.command = command
    smartProcess.running = true
  }

  function smartFor(device) {
    if (!device) return null
    return smart[device.path] || null
  }

  function smartVerdictFor(device) {
    return Model.smartVerdict(smartFor(device))
  }

  function smartHintFor(device) {
    return Model.smartHint(smartFor(device))
  }

  function tempHistoryFor(device) {
    if (!device || !device.path) return []
    return tempHistory[device.path] || []
  }

  function tempStatsFor(device) {
    var hist = tempHistoryFor(device)
    var cur = smartFor(device)
    var curTemp = (cur && typeof cur.temperatureC === "number") ? cur.temperatureC : null
    return Model.tempStats(hist, curTemp)
  }

  // Folded into `status` the way a check's verdict is, keyed by device path so
  // a script with two drives attached can tell which one it is reading.
  function healthReport() {
    var out = {}
    for (var i = 0; i < devices.length; i++) {
      out[devices[i].path] = Model.smartVerdict(smartFor(devices[i]))
    }
    return out
  }

  // ------------------------------------------------ phones and cameras

  function refreshPortables() {
    if (gioProcess.running) return
    gioProcess.running = true
    if (!supportProcess.running) supportProcess.running = true
  }

  // A plugin cannot install anything itself, so this opens Omarchy's own
  // installer in a floating terminal and lets the user decide there.
  function installSupport() {
    var hint = supportHint
    if (!hint) return
    Quickshell.execDetached(["omarchy-install-app", hint.label, hint.packages])
    // Installing usbmuxd does not start it: its udev rule fires when an Apple
    // device is plugged in, so a phone that was already connected when the
    // packages landed leaves AFC silently unavailable. The install terminal
    // says "Done" and the panel would otherwise still show nothing, with no
    // hint that the cable is the last step.
    actionStatus = hint.reconnect
      ? "Once the install finishes, unplug the device and plug it back in"
      : "Reconnect the device once the install finishes"
  }

  function mountPortable(entry) {
    if (!entry || entry.uri === "" || busy) return
    runAction(["gio", "mount", entry.uri], entry.uri, "mount-portable", "Mounted " + entry.name)
  }

  function unmountPortable(entry) {
    if (!entry || entry.uri === "" || busy) return
    runAction(["gio", "mount", "-u", entry.uri], entry.uri, "unmount-portable", "Unmounted " + entry.name)
  }

  function togglePortable(entry) {
    if (!entry) return
    if (entry.mounted) unmountPortable(entry)
    else mountPortable(entry)
  }

  // Not xdg-open: nothing registers an x-scheme-handler for gphoto2://,
  // afc:// or mtp://, so xdg-open exits 0 and silently does nothing. gio
  // resolves the URI through GIO itself, which also mounts the device on
  // demand — so browsing works whether or not it is mounted yet.
  function openPortable(entry) {
    if (!entry || entry.uri === "") return
    var command = String(setting("fileManager", "")).replace(/^\s+|\s+$/g, "")
    if (command !== "") {
      Quickshell.execDetached(["bash", "-c", command + " " + quote(entry.uri)])
      return
    }
    Quickshell.execDetached(["gio", "open", entry.uri])
  }

  // ------------------------------------------------------ small actions

  function copyPath(volume) {
    if (!volume || !volume.mounted) return
    Quickshell.execDetached(["bash", "-c", 'printf %s "$1" | wl-copy', "storage-drives", volume.mountpoint])
    actionStatus = "Copied " + volume.mountpoint
  }

  // Device names reach the notification surface too, and that surface is not
  // ours to pin: Omarchy renders the body as Text.StyledText and the summary
  // with the default AutoText, stripping <img> from the body only. A drive
  // label is chosen by whoever formatted the stick, so it is sanitised here —
  // at the one point every notification passes through — rather than trusting
  // whichever daemon draws it.
  function notify(headline, description, glyph, urgency) {
    if (!notificationsEnabled) return
    var command = ["omarchy-notification-send", "-g", glyph]
    if (urgency) command.push("-u", urgency)
    command.push(Model.plain(headline))
    if (description && description !== "") command.push(Model.plain(description))
    Quickshell.execDetached(command)
  }

  // udisks reports a busy filesystem without saying what is holding it. fuser
  // knows, and ps turns its pids into names a person can act on.
  function probeBlockers(mountpoints) {
    if (mountpoints.length === 0 || blockersProcess.running) return
    var script = 'pids=$(fuser -m "$@" 2>/dev/null); [ -n "$pids" ] && ps -o pid=,comm= -p $pids || true'
    var command = ["bash", "-c", script, "removable-drives"]
    for (var i = 0; i < mountpoints.length; i++) command.push(mountpoints[i])
    blockersProcess.command = command
    blockersProcess.running = true
  }

  function mountedPathsFor(path) {
    var out = []
    var list = path === "*" ? devices : (deviceByPath(path) ? [deviceByPath(path)] : [])
    if (list.length === 0) {
      var volume = volumeByPath(path)
      if (volume && volume.mounted) {
        blockedFsPath = volume.fsPath
        return [volume.mountpoint]
      }
      return out
    }
    for (var d = 0; d < list.length; d++) {
      for (var v = 0; v < list[d].volumes.length; v++) {
        if (list[d].volumes[v].mounted) {
          if (blockedFsPath === "") blockedFsPath = list[d].volumes[v].fsPath
          out.push(list[d].volumes[v].mountpoint)
        }
      }
    }
    return out
  }

  // ----------------------------------------------------------- processes

  Process {
    id: lsblkProcess
    command: ["lsblk", "-J", "-b", "-o",
              "NAME,PATH,LABEL,PARTLABEL,FSTYPE,FSVER,SIZE,FSSIZE,FSAVAIL,FSUSED,MOUNTPOINT,MOUNTPOINTS,RM,HOTPLUG,RO,ROTA,TYPE,TRAN,VENDOR,MODEL,REV,UUID,PARTUUID,PARTTYPENAME,PTTYPE,DISC-MAX,SERIAL"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySnapshot(text)
    }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode !== 0) root.lastError = "lsblk exited with " + exitCode
    }
  }

  Process {
    id: statsProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStats(text)
    }
  }

  Process {
    id: hooksProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyHooks(text)
    }
  }

  Process {
    id: smartProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.smart = Model.parseSmartReport(text)
    }
  }

  Process {
    id: networkMountsProcess
    command: ["bash", "-c", "findmnt -b -J -l -o TARGET,SOURCE,FSTYPE,OPTIONS,SIZE,USED,AVAIL 2>/dev/null || cat /proc/mounts"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.networkShares = Model.parseNetworkMounts(text)
    }
  }

  Process {
    id: blockersProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.blockers = Model.parseBlockers(text)
    }
  }

  Process {
    id: closeBlockersProcess
    onExited: {
      root.blockers = []
      root.retryBlocked()
    }
  }

  Process {
    id: linkProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.links = Model.parseLinkReport(text)
    }
  }

  Process {
    id: toolsProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.tools = Model.parseToolList(text)
    }
  }

  Process {
    id: actionProcess
    // Only the unlock script ever reads stdin; for everything else the pipe is
    // opened and never written, which no command here notices.
    stdinEnabled: true
    onStarted: {
      if (root._secret !== "") {
        write(root._secret + "\n")
        root._secret = ""
      }
    }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._stdout = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root._stderr = text }
    onExited: function(exitCode) {
      var action = root.busyAction
      var path = root.busyPath
      root.busyPath = ""
      root.busyAction = ""

      // The work itself landed either way; the remount is what separates these.
      // A filesystem that was renamed and then failed to mount back is still
      // renamed, so the verdict and the success message stand — but the drive
      // is gone from the file manager, and that is the part worth shouting.
      // Omarchy's udiskie auto-mounts too, and whichever of the two is second
      // gets AlreadyMounted. The volume is mounted, which is what was asked.
      var alreadyMounted = exitCode !== 0 && action === "mount" && Model.isAlreadyMounted(root._stderr)
      if (exitCode === 0 || exitCode === Model.EXIT_REMOUNT_FAILED || alreadyMounted) {
        root.actionStatus = root._successMessage
        if (action === "eject") {
          root.notify("Safe to remove",
                      root._successMessage.replace(/^Safe to remove /, ""),
                      Model.GLYPH_EJECT)
        }
        // Worth a notification of its own: a full erase runs long enough that
        // the panel is usually shut by the time it finishes.
        if (action === "format") {
          root.notify("Formatted", root._successMessage.replace(/^Formatted /, ""), Model.GLYPH_ERASER)
        }
        if (action === "check" || action === "repair") root.applyVerdict(action, path)
        if (exitCode === Model.EXIT_REMOUNT_FAILED) {
          root.lastError = Model.remountWarning(root.actionStatus)
          root.actionStatus = ""
          root.notify("Left unmounted", root.lastError, Model.GLYPH_ALERT, "normal")
        }
      } else {
        root._openAfterPath = ""
        var detail = Model.formatError(root._stderr)
        root.lastError = detail !== "" ? detail : (action + " failed")
        // "Target is busy" is only half an answer; go find the other half.
        if (/busy/i.test(root.lastError)) {
          root.blockedFsPath = ""
          root._blockedAction = action
          root._blockedPath = path
          root.probeBlockers(root.mountedPathsFor(path))
        }
        root.notify("Removable drives", root.lastError, Model.GLYPH_ALERT, "normal")
      }
      root.refresh()
      // A phone mount changes gvfs state, which lsblk knows nothing about.
      if (action === "mount-portable" || action === "unmount-portable") root.refreshPortables()
      if (root.watchClosely) root.probeTrash()
    }
  }

  Process {
    id: gioProcess
    command: ["gio", "mount", "-li"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.portables = Model.parseGioMounts(text)
    }
  }

  // One probe for both questions: which backends gvfs advertises, and what is
  // on the USB bus. Root hubs (1d6b) are skipped; everything else reports its
  // vendor and every interface class it exposes.
  Process {
    id: supportProcess
    command: ["bash", "-c", 'for f in /usr/share/gvfs/mounts/*.mount; do [ -e "$f" ] || continue; n=$(basename "$f" .mount); echo "backend $n"; done; for d in /sys/bus/usb/devices/*/; do [ -r "$d/idVendor" ] || continue; v=$(cat "$d/idVendor" 2>/dev/null); [ "$v" = "1d6b" ] && continue; cls=""; for i in "$d"*:*/bInterfaceClass; do [ -r "$i" ] && cls="$cls,$(cat "$i" 2>/dev/null)"; done; echo "usb $v$cls $(cat "$d/product" 2>/dev/null)"; done']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.support = Model.parseSupport(text)
    }
  }

  Process {
    id: suspendWriter
  }

  Process {
    id: suspendGuard
    // setpriv: the kernel sends the guard TERM when the shell exits, however
    // it exits, so its trap releases the inhibitor instead of leaving it
    // reparented to init.
    command: ["setpriv", "--pdeathsig", "TERM", "bash", "-c", root.suspendScript, "removable-drives",
              root.suspendTargetsPath, root.suspendTargetsPath + ".guard",
              root.notificationsEnabled ? "1" : "0", Model.GLYPH_ALERT]
    running: root.unmountOnSuspend
  }

  Process {
    id: mountsProcess
    command: ["cat", "/proc/mounts"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.mountFlags = Model.parseMountFlags(text)
    }
  }

  Process {
    id: capsProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.fsCapabilities = Model.parseFsCapabilities(text)
    }
  }

  Process {
    id: trashProcess
    // Most candidates do not exist; du complains about those on stderr and
    // still reports the ones that do, so a non-zero exit is expected here.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.trashSizes = Model.parseSizes(text)
    }
  }

  Process {
    id: storeWriter
  }

  Process {
    id: uidProcess
    command: ["id", "-u"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.uid = String(text).replace(/\s+/g, "")
    }
  }

  // The saved nicknames and hooks. Watched rather than read once, so editing
  // the file by hand takes effect without restarting the shell.
  FileView {
    id: storeFile
    path: root.storePath
    watchChanges: true
    printErrors: false
    onLoaded: root.store = Model.parseStore(text())
    onFileChanged: reload()
    onLoadFailed: root.store = ({ version: 1, drives: {} })
  }

  // udev tells us the moment a device appears or disappears, which is the
  // difference between a widget that reacts and one that polls. stdbuf keeps
  // udevadm line-buffered — piped, it would otherwise sit on a 4KB buffer and
  // deliver the first event minutes late.
  Process {
    id: monitorProcess
    command: ["stdbuf", "-oL", "udevadm", "monitor", "--udev", "--subsystem-match=block", "--subsystem-match=usb"]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        if (/(add|remove|change|bind|unbind)/.test(String(line))) debounce.restart()
      }
    }
    onExited: monitorRestart.restart()
  }

  // A burst of udev lines arrives for every partition on a stick; settle
  // before asking lsblk, so plugging in a 4-partition drive costs one call.
  Timer {
    id: debounce
    interval: 350
    onTriggered: {
      root.refresh()
      root.refreshPortables()
      // gvfs auto-mounts a phone a beat after udev announces it, so the
      // first listing catches it unmounted. Look again once it has settled.
      settleTimer.restart()
    }
  }

  Timer {
    id: settleTimer
    interval: 2500
    onTriggered: root.refreshPortables()
  }

  Timer {
    id: monitorRestart
    interval: 3000
    onTriggered: if (!monitorProcess.running) monitorProcess.running = true
  }

  // I/O counters are only sampled while something removable is attached, so
  // the widget costs nothing on a machine with no drive plugged in. A hook is
  // read on the same tick, and only for a drive that has one still working.
  Timer {
    interval: 1000
    running: root.devices.length > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.sampleActivity()
      root.sampleHooks()
    }
  }

  // Free space drifts while a copy runs; only worth watching while the panel
  // is on screen.
  Timer {
    interval: Math.max(2, root.intSetting("refreshIntervalSec", 8, 2, 300)) * 1000
    running: root.watchClosely
    repeat: true
    onTriggered: {
      root.refresh()
      root.refreshPortables()
    }
  }

  // Gentle S.M.A.R.T. and temperature sampling: only when the panel is open AND
  // at least one drive's telemetry row is expanded in the UI, at a relaxed 60-second
  // cooldown so background S.M.A.R.T. querying halts completely when collapsed.
  Timer {
    interval: 60000
    running: root.watchClosely && root.devices.length > 0 && root.telemetryActive
    repeat: true
    onTriggered: root.probeSmart(true)
  }

  // Background health read: rare on purpose. SmartUpdate asks ATA drives not
  // to wake (nowakeup), so a parked disk is not spun up for this.
  Timer {
    interval: 6 * 60 * 60 * 1000
    running: root.devices.length > 0
    repeat: true
    onTriggered: root.probeSmart(true)
  }

  // Backstop for a machine where udevadm is unavailable or its stream dies
  // quietly: never more than a minute stale.
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: cloudStoreWriter
  }

  FileView {
    id: cloudStoreFile
    path: root.cloudStorePath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.cloudStore = Model.parseCloudStore(text())
      root.refreshCloudStatuses()
    }
    onFileChanged: reload()
    onLoadFailed: root.cloudStore = Model.defaultCloudStore()
  }

  Process {
    id: cloudCheckProcess
    command: ["python3", root.cloudHelperPath, "rclone-check"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseCloudCheck(text)
        root.rcloneInstalled = parsed.installed === true
        root.rcloneVersion = String(parsed.version || "")
        root.rcloneFuse = parsed.fuse3 === true
      }
    }
  }

  Process {
    id: cloudRemotesProcess
    command: ["python3", root.cloudHelperPath, "remotes"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.availableRemotes = Model.parseCloudRemotes(text)
      }
    }
  }

  Process {
    id: cloudStatusProcess
    property string targetRemote: ""
    stdout: StdioCollector {
      id: cloudStatusStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: cloudStatusStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      Qt.callLater(root.nextCloudStatus)
      if (!targetRemote || targetRemote === "") return
      var parsed = Model.parseCloudStatus(String(cloudStatusStdout.text || ""), targetRemote)
      var copy = Object.assign({}, root.cloudStatuses)
      copy[targetRemote] = parsed
      root.cloudStatuses = copy

      // Not while the path is someone else's: the mount would fail, and this
      // runs on every status refresh, so it would fail every few seconds.
      if (parsed.authenticated && !parsed.browseMounted && !parsed.browseEnabled && parsed.mountPath
          && !parsed.browseConflict && !root.cloudConflicts[targetRemote]) {
        var acc = null
        for (var i = 0; i < cloudAccounts.length; i++) {
          if (cloudAccounts[i].remoteName === targetRemote) { acc = cloudAccounts[i]; break }
        }
        if (acc && acc.autoMount !== false) {
          var folderP = expandHome(acc.folderPath || "~/Cloud")
          var mountP = expandHome(acc.browseMountPath || "~/Cloud-Browse")
          runCloudControl(["python3", cloudHelperPath, "browse", "--remote", targetRemote, "--folder", folderP, "--mount", mountP, "--enable"], function() {
            refreshCloudStatus(targetRemote)
          })
        }
      }
    }
  }

  Process {
    id: cloudFoldersProcess
    property string targetRemote: ""
    stdout: StdioCollector {
      id: cloudFoldersStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: cloudFoldersStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.cloudFoldersLoading = false
      var parsed = Model.parseCloudFolders(String(cloudFoldersStdout.text || ""))
      if (parsed.ok) {
        root.cloudFolders = parsed.folders
        root.cloudStaleBytes = parsed.staleBytes
        root.cloudStaleCount = parsed.staleCount
        root.cloudRootFiles = parsed.rootFiles
        root.cloudRootFileCount = parsed.rootFileCount
        root.cloudRootFileBytes = parsed.rootFileBytes
        root.cloudFoldersError = ""
        root.pendingCloudFolders = ({})
      } else {
        root.cloudFoldersError = parsed.lastError || "Could not list cloud folders"
      }
    }
  }

  Process {
    id: cloudControlProcess
    stdout: StdioCollector {
      id: cloudControlStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: cloudControlStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var err = String(cloudControlStderr.text || "").trim()
        root.lastError = err || "Cloud operation failed"
        root.noteCloud(root.lastError)
      }
      var cb = root._onCloudControlDone
      root._onCloudControlDone = null
      if (cb) Qt.callLater(cb)
      Qt.callLater(root.nextCloudControl)
    }
  }

  Timer {
    id: cloudActionTimer
    interval: 3200
    repeat: false
    onTriggered: root.cloudActionStatus = ""
  }

  Timer {
    id: cloudSyncPoll
    interval: 3000
    repeat: true
    running: {
      if (!root.selectedCloudRemote || root.selectedCloudRemote === "") return false
      var st = root.cloudStatuses[root.selectedCloudRemote]
      return st && st.syncing === true
    }
    onTriggered: root.refreshCloudStatus(root.selectedCloudRemote)
  }

  Timer {
    id: cloudUnauthPoll
    interval: 3500
    repeat: true
    running: root.cloudAccountCount > 0 && root.hasUnauthenticatedCloudAccount()
    // Let the checks already in flight finish before queueing another round.
    onTriggered: if (!cloudStatusProcess.running && root._cloudStatusQueue.length === 0) root.refreshCloud()
  }

  onWatchCloselyChanged: if (watchClosely) {
    refreshPortables()
    probeTrash()
    refreshCloudStatuses()
  }

  Component.onCompleted: {
    refresh()
    refreshPortables()
    refreshCloud()
    probeTools()
  }
}
