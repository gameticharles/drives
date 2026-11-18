# Changelog

All notable changes to Storage Drives. Newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Releases before 2.7.0 are
described in their commit messages.

## [2.8.0] - 2026-11-18

### Added

- Local changes sync within seconds. Each account with auto-sync on gets a
  watch service (`omarchy-storage-watch-<account>.service`) that follows the
  sync folder with inotify. When the folder has been quiet for 15 seconds
  (or 2 minutes after the first change at most), it starts a sync. Before
  that, each changed path is checked against bisync's own listing of the last
  run, so the files a sync downloads never start another sync. Only selected
  folders count, and office and editor scratch files (`.~lock.*#`, `~$*`,
  swap and partial files) don't trigger a sync. The timer stays on and catches
  changes made in the cloud, so it can run less often: 20 to 30 minutes is
  enough. Accounts set up before this version get the watch service at their
  next timer run. When the inotify watch limit is reached, the rest of the
  folder is synced by the timer only.
- A notice on Google Drive accounts that use rclone's shared client ID.
  Google rate-limits that ID across every rclone user, so syncs are slow, and
  rclone is retiring it. The notice's **Set Up Client ID** button opens a
  terminal (`cloud-sync.py client-id --remote <name>`). It lists the steps in
  Google Cloud Console and asks for the client ID and secret. It then stops
  this account's sync, watch and browse mount, saves the ID, and signs in
  again (`rclone config reconnect`). It checks that the drive can be listed
  and starts a sync. If anything fails or is cancelled, the account goes back
  to its old client ID and token. **Guide** opens rclone's step-by-step page.
  The status payload has a new `sharedClientId` field.
- A running sync shows what it is doing, for every cloud account. Before, the
  panel said only "Syncing", which on a large Google Drive meant 20 minutes
  with no other feedback. The sync helper now reads bisync's own log
  (`SyncProgress`) and records:
  - The stage: starting, listing both sides (with a running count of items
    listed), comparing, applying changes, uploading, downloading, or
    finishing.
  - Every change bisync found, with its direction: new, changed or deleted,
    here or in the cloud, and changes made on both sides. Each one leaves the
    list as it completes.
  - The direction of each file in flight and of each recent transfer.
  - Why the run started: your change to a file (named), Sync now, a change
    to the folders kept on disk, or the regular timer.

  The live card shows the stage, the reason, a total ("2 to upload · 3 to
  download"), then up to six files with an arrow or trash icon and their
  percentage or what is still to happen, and "and N more". An account's
  status reads "Syncing · listing", "Syncing · uploading" and so on, and its
  tile names the file in flight ("Uploading q3.pdf · 42% · 3 more"). New
  status fields: `phase`, `phaseText`, `plannedChanges`, `plannedRemaining`,
  `plannedCounts`, `syncReasonText`. New Model.js helpers: `cloudSyncFeed`,
  `cloudSyncLine`.

- A pause button for all cloud sync, in the header next to search on the
  Cloud tab. Pausing stops any sync that is running at once, and nothing
  syncs until you resume. Timer runs, the watch service and Sync now all
  do nothing while paused. rclone's `--resilient --recover` pick up a
  stopped run at the next sync. The pause is one flag
  (`~/.local/state/omarchy-storage-drives/cloud/paused.json`) for every
  account. Terrace reads the same flag, and the pause survives a reboot. A
  "Cloud sync paused" bar with **Resume** shows on every tab, and each
  account reads "Paused". Resuming syncs each account with auto-sync on once,
  to catch up ("Catching up after the pause"). Browse mounts and network
  shares keep working. CLI: `cloud-sync.py pause --on|--off`, which prints
  `{"paused": …, "since": …}`. Tests: `test/pause_test.py`.

### Changed

- The **Network & Cloud** tab is now two tabs, **Cloud** and **Network**,
  so the panel has three: Drives, Cloud and Network. Each has its own count
  and header line ("3 cloud drives · 1 syncing", "2 network shares mounted").
  The `w` key cycles through all three, and `setTab` takes `cloud`.
  `openCloud` opens the Cloud tab.
- The header has two rows. Row one holds the title and the header buttons,
  and row two holds the status line, which now runs the full width (up to two
  lines). Before, Omarchy's `PanelHero` set aside the buttons' width on both
  rows, so the status line was cut short by buttons that sit beside the
  title.
- Auto-sync runs every 30 minutes by default, not every 10. Local changes no
  longer wait for the timer, so it only has to catch changes made in the
  cloud. Accounts keep the interval they already have.

### Fixed

- CI failed on every push since 2026-10-08 before any test ran. The
  workflow installed `qml-tools`, a package Ubuntu doesn't have. It now
  installs `qt6-declarative-dev-tools`, which provides
  `/usr/lib/qt6/bin/qmlformat` for the wiring check that the QML parses. The
  workflow also moves to Node 22 and `actions/checkout@v5` /
  `actions/setup-node@v5`, which clears GitHub's Node 20 deprecation warning.
- A running sync was reported as not running. `systemctl is-active` exits
  with code 3 for a oneshot service that is still starting ("activating"),
  which is the whole of a sync, so `service_active` read it as stopped. It
  now reads the state text.
- `rclone bisync` was passed `--track-renames`, which bisync ignores (it
  syncs with copy and move). rclone logged an ERROR line about it on every
  run. The flag is gone.
- Leftover `.state.json.tmp.*` files from interrupted writes are removed at
  the start of each sync, once they are an hour old.
- A failed sync started a full `--resync` when it didn't need one. bisync's
  exit codes 2 and 7 cover both "Must run --resync to recover" and an abort
  that `--resilient` makes "retryable without --resync". That second case
  covers a listing cut short by a rate limit or a network blip. Every such
  failure was followed straight away by a resync. On a large Google Drive
  that takes an hour or more, and because a resync copies each side's files
  to the other, files deleted since the last good sync came back. A resync
  now starts only when rclone's log says one is needed (`needs_resync`).
- Google's rate-limit refusal (`403 Quota exceeded for quota metric
  'Queries'…`) read as if the drive were full. It is now reported as a rate
  limit that the next sync retries, with a pointer to a client ID of your
  own.
- A Sync now pressed while a sync was running queued the next run, but that
  run was labelled a regular check. The note now waits for it.
- The panel used `root.accent` in seven places (the "syncing" card, the
  rclone install wait, folder rows, recent transfers) but never defined it.
  Those parts had no accent colour, and each sync logged `TypeError: Cannot
  read property 'r' of undefined`. It is now `Commons.Color.accent`.

## [2.7.6] - 2026-11-16

### Fixed

- Google Drive sync no longer lists the whole drive. `rclone bisync` ran with
  `--fast-list`, which on Google Drive lists every item before the folder
  selection is applied; on a large drive a run took over 30 minutes for a few
  selected folders and rarely finished. `--fast-list` is now used only for
  other providers. Google Drive remotes should also have their own client ID,
  because rclone's shared one is heavily rate-limited.

## [2.7.5] - 2026-10-23

### Fixed

- Storage Drives lost the Omarchy theme colours after the Omarchy 4.0.6 update (Qt
  6.12). Qt 6.12 adds a global `Color` object to QtQuick that wins over the
  imported `qs.Commons` singleton, so `Color.background`, `Color.accent` and
  the rest were undefined and the plugin fell back to its hard-coded colours.
  Every use is now qualified as `Commons.Color` (`import qs.Commons as
  Commons`). Use the qualified form in new code; a bare `Color` means
  QtQuick's.

## [2.7.4] - 2026-10-16

### Fixed

- Mount and sync services find an `rclone` installed by mise
  (`~/.local/share/mise/shims`) or into `~/.local/bin`. systemd user units don't
  get the login shell's PATH, so a service written by Storage Drives failed to
  start with such an rclone. Terrace's built-in copy of this engine had the fix
  already; the two share the same drives and accounts, so either can now write
  the services.

## [2.7.3] - 2026-10-09

### Changed

- Sync status is written as the neutral extended attribute `user.sync.status`
  (synced, syncing, partial, conflict, excluded), so any file manager can read it
  without knowing which app synced the folder. Flea draws it as a badge, the
  Nautilus extension as an emblem. The old `user.terrace.sync` is cleared on retag.
- After each successful sync every file and folder in the sync folder is tagged,
  not just the top level: files the selection keeps are synced, others excluded,
  rclone conflict copies conflict; folders are partial when only some of them
  syncs and conflict when a conflict sits beneath. A tag is rewritten only when
  it changes (23,571 entries: 0.87 s first pass, 0.39 s unchanged).
- The sync root reads syncing while a sync runs; a failed sync marks it conflict,
  an offline one restores what it had.

### Fixed

- Conflict detection matched any name containing ".conflict" (my.conflicts.txt);
  it now matches rclone's `.conflictN` part only (sync engine and Nautilus extension).

## [2.7.2] - 2026-10-08

### Added
- **File Manager Agnostic Sync Badges & Path Query**: Added `python3 cloud-sync.py query <path>` CLI command (with optional `--set-emblems`), providing fast JSON resolution of sync root, relative path, selection state (`on`/`partial`/`off`), sync status (`synced`/`syncing`/`partial`/`conflict`/`excluded`), and emblem mapping. Works independently of any single file manager.
- **Nautilus Sync Emblems Extension**: Added `storage-drives-emblems.py` (`Nautilus.InfoProvider` / `Nautilus.MenuProvider`) delivering real-time desktop sync badges and context menus to Nautilus without daemon lock-in.
- **Consistent Emblem Hierarchy**: Standardized desktop emblem visual cues:
  - `synced`: Green circle with white checkmark (`emblem-default`) for fully synchronized files and folders.
  - `partial`: Slate grey selective sync badge (`emblem-dropbox-selsync`) for folders containing deselected subfolders.
  - `syncing`: Blue rotating sync arrows (`emblem-synchronizing`) for active transfers.
  - `conflict`: Red exclamation warning (`emblem-important`) for files preserved with `.conflict` suffix.
  - `excluded`: Shared/cloud badge (`emblem-shared`) for unselected items.
- **Live Transfer Queue & Stats**: Replaced blocking bisync execution with streaming JSON logs (`--use-json-log --stats 1s`), exposing real-time active transfers, current speed, ETA, and progress metrics to the UI.
- **Live Activity Card & Recent Transfer Feed**: Added real-time transfer progress bar, active file banner, conflict warning card, and recent transfers activity list to the detailed account panel.

## [2.7.1] - 2026-10-08

### Fixed
- **Google Drive 403 Abuse Flag & Shortcut Failures**: Added `--drive-acknowledge-abuse` to `bisync_command`, `mount_browse`, and `rclone check`. Prevents syncs from crashing on `.lnk` files, executables, or false-positive security flags.
- **Poll Storm During Syncing**: Throttled `cloudSyncPoll` in `Service.qml` from 3s to 5s and added concurrency guards so that status requests are not queued when a check is already in-flight.
- **Disk-Walking Caching**: Fixed `status_payload` in `cloud-sync.py` to reuse cached `localBytes` when idle for up to 5 minutes or until the next sync completes, eliminating up to 2 seconds of disk traversal per status query.
- **Blocking Status Calls During Active Sync**: `status_payload` now returns cached storage usage immediately while syncing is active instead of blocking on an 18-second `rclone about` query, speeding up live status checks from ~5.6s to 0.21s.
- **OneDrive Redundant Probing**: Removed unnecessary `rclone about` queries in `ensure_onedrive_drive_id` when `drive_id` is already valid in `rclone.conf`, cutting status check time from 8.4s to 0.21s.
- **Credential & API Rate Limit Handling**: `user_identity` now parses tokens directly from `rclone.conf` using `configparser` without spawning `rclone config dump`, and caches negative lookups for 5 minutes to avoid tripping Google API rate limits.
- **Safe Stale Cleanups via Trash**: `cmd_cleanup` now routes removed files through `gio trash` (falling back to POSIX unlink/rmtree), preventing permanent data loss when de-selecting synced folders.

### Changed
- **Bisync Performance & Move Tracking**: Enabled `--fast-list` and `--track-renames` in `bisync_command`, plus Google Drive API pacing (`--tpslimit 10`, `--drive-pacer-min-sleep 100ms`). In benchmarks, directory listing speed improved from 8 minutes down to under 2 minutes for 110,000+ files.
- **Browse Mount Progressive Streaming**: Added `--vfs-read-chunk-size 128M` and `--vfs-read-chunk-size-limit 1G` to `mount_browse` for smooth streaming of large files.
- **Custom OAuth Credentials Support**: `cloudAuthCommand` in `Model.js` now accepts optional custom `clientId` and `clientSecret` parameters in preparation for Google's 2026 retirement of rclone's shared client ID.

## [2.7.0] - 2026-10-05

### Added
- Cloud sync can keep part of a folder. In the Network & Cloud tab, open a
  cloud account and use the arrow on a folder: tick the folders inside to
  keep only those, or keep it whole and untick the ones to leave out (a
  large Videos folder, say). Folders go as deep as you like, the path above
  the list walks back up, and each checkbox shows all, some or none of a
  folder kept. Folders added later are brought down by the next sync
  without touching anything else.
- `cloud-sync.py folders --path <folder>` lists the folders inside one, and
  `select --toggle=<path>` keeps or leaves out any path. `selection.json`
  gains `excludes` (paths left out of kept folders); `folders` may now hold
  paths at any depth. Older selection files read as before.

### Changed
- Cloud tiles read like a drive's: the free space over the quota bar
  ("4.7 TB free of 5.0 TB (6% used)", or how far over quota), and the size
  kept on this computer on the right ("4.1 GB on disk"), with the bar
  across the full width below. The account view's "In Cloud" uses the same
  wording.

### Fixed
- Loose files at the top of a cloud drive synced although they were turned
  off. A new account synced at once with them on (the old default), before
  there was any chance to choose, and a change made while a sync ran only
  applied to the run after it. Now:
  - Loose files are off unless you turn them on, and a new account syncs
    nothing until you choose.
  - A change made during a sync is applied by a second run straight after it.
  - A change made while another cloud task runs waits its turn instead of
    being dropped, and shows at once.
- "Clean up" could have deleted a folder you keep part of (it freed every
  top-level folder not kept whole). It now frees only what no longer syncs:
  left-out folders, files in folders that aren't kept, and loose files that
  are off. Each is checked against the cloud first, and anything the cloud
  doesn't hold byte for byte stays.
