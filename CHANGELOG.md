# Changelog

All notable changes to Storage Drives. Newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Releases before 2.7.0 are
described in their commit messages.

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
