# Changelog

All notable changes to Storage Drives. Newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Releases before 2.7.0 are
described in their commit messages.

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
