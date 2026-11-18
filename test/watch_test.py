#!/usr/bin/env python3
# Sync on a local change (cloud-sync.py `watch`): which paths count, how a
# change is told apart from what the last sync wrote, and the inotify tree
# watch itself. Nothing here talks to the cloud or to systemd.
# Run: python3 test/watch_test.py

import importlib.util
import os
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("cloud_sync", HERE.parent / "cloud-sync.py")
cs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cs)

passes = failures = 0


def test(name, fn):
  global passes, failures
  try:
    fn()
    passes += 1
    print("  ok   " + name)
  except AssertionError as error:
    failures += 1
    print("  FAIL " + name + "\n       " + str(error))


def eq(a, b):
  assert a == b, f"{a!r} != {b!r}"


def sel(folders=(), excludes=(), root=False):
  return cs.normalise_selection({"folders": list(folders), "excludes": list(excludes), "rootFiles": root})


def t_watched_path():
  s = sel(["Work", "Teaching/2026"], ["Work/Videos"])
  assert cs.watched_path(s, "Work/report.docx")
  assert cs.watched_path(s, "Teaching/2026/week1.pdf")
  assert not cs.watched_path(s, "Work/Videos/clip.mp4"), "left-out folder"
  assert not cs.watched_path(s, "Teaching/2025/old.pdf"), "not selected"
  assert not cs.watched_path(s, "loose.txt"), "loose files are off"
  assert cs.watched_path(sel(["Work"], root=True), "loose.txt")
  assert not cs.watched_path(sel(["Work"], root=True), "Other/file.txt")
  assert not cs.watched_path(sel(["Personal Vault"]), "Personal Vault/x")
  for scratch in (".~lock.report.docx#", "~$report.docx", ".report.docx.swp", "notes.txt~",
                  "big.iso.partial", ".goutputstream-ABC123"):
    assert not cs.watched_path(s, "Work/" + scratch), scratch
  # Only the name itself is a scratch name; a folder named like one is not.
  assert cs.watched_path(s, "Work/drafts~/real.docx")
  assert not cs.watched_path(s, "Work/.rclone-bisync/x")


def t_listing_time():
  eq(cs.listing_time("2024-02-23T14:04:52.669000000+0000"), 1708697092.669)
  eq(cs.listing_time("2024-02-23T15:04:52+0100"), 1708697092.0)
  eq(cs.listing_time("2024-02-23T14:04:52Z"), 1708697092.0)
  eq(cs.listing_time("garbage"), None)


def write_listing(workdir, entries):
  workdir.mkdir(parents=True, exist_ok=True)
  lines = ["# bisync listing v1 from 2026-11-18T06:27:51.605914519+0000"]
  for kind, size, mtime, name in entries:
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(mtime)) + ".000000000+0000"
    quoted = name.replace("\\", "\\\\").replace('"', '\\"')
    lines.append(f'{kind} {size:>8} - - {stamp} "{quoted}"')
  (workdir / "remote_..home_x_Drive.path2.lst").write_text("\n".join(lines) + "\n", encoding="utf-8")


def t_changes_against_listing():
  with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp) / "Drive"
    (root / "Work").mkdir(parents=True)
    synced = root / "Work" / "synced.txt"
    synced.write_text("12345")
    edited = root / "Work" / "edited.txt"
    edited.write_text("abc")
    quoted = root / "Work" / 'say "hi".txt'
    quoted.write_text("q")
    stamp = 1_790_000_000
    for path in (synced, edited, quoted):
      os.utime(path, (stamp, stamp))
    paths = {"workdir": Path(tmp) / "workdir"}
    write_listing(paths["workdir"], [
      ("d", -1, stamp, "Work"),
      ("-", 5, stamp, "Work/synced.txt"),
      ("-", 3, stamp, "Work/edited.txt"),
      ("-", 1, stamp, 'Work/say "hi".txt'),
      ("-", 9, stamp, "Work/deleted.txt"),
    ])
    edited.write_text("abcd")  # a local edit after the sync: new size and time
    (root / "Work" / "new.txt").write_text("n")
    (root / "Work" / "Fresh").mkdir()
    pending = {"Work", "Work/synced.txt", "Work/edited.txt", 'Work/say "hi".txt', "Work/deleted.txt",
               "Work/new.txt", "Work/Fresh", "Work/gone-and-never-synced.tmp"}
    eq(cs.local_changes(root, paths, pending),
       ["Work/Fresh", "Work/deleted.txt", "Work/edited.txt", "Work/new.txt"])
    # Same size, newer time counts too (bisync compares size and modtime).
    os.utime(synced, (stamp + 30, stamp + 30))
    eq(cs.local_changes(root, paths, {"Work/synced.txt"}), ["Work/synced.txt"])
    # No listing yet (never synced): everything pending counts.
    eq(cs.local_changes(root, {"workdir": Path(tmp) / "none"}, {"Work/synced.txt"}), ["Work/synced.txt"])


def drain(watch, seconds=1.0):
  seen = []
  end = time.monotonic() + seconds
  while time.monotonic() < end:
    seen += watch.read(0.1)
  return seen


def t_tree_watch():
  with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "A" / "B").mkdir(parents=True)
    watch = cs.TreeWatch(root)
    try:
      watch.add_tree("")
      eq(sorted(watch.dirs.values()), ["", "A", "A/B"])
      (root / "A" / "B" / "f.txt").write_text("x")
      assert "A/B/f.txt" in drain(watch, 0.3)
      # A new folder is watched as it appears, files inside it reported.
      (root / "A" / "C").mkdir()
      assert "A/C" in drain(watch, 0.3)
      (root / "A" / "C" / "g.txt").write_text("y")
      assert "A/C/g.txt" in drain(watch, 0.3)
      # A folder filled before its watch exists still reports its contents.
      (root / "A" / "D" / "E").mkdir(parents=True)
      (root / "A" / "D" / "E" / "early.txt").write_text("e")
      seen = drain(watch, 0.3)
      assert "A/D/E/early.txt" in seen and "A/D" in seen, seen
      assert "A/D/E" in watch.dirs.values()
      # A moved folder is reported under its new name, from then on too.
      os.rename(root / "A" / "B", root / "A" / "Moved")
      seen = drain(watch, 0.3)
      assert "A/B" in seen and "A/Moved" in seen, seen
      (root / "A" / "Moved" / "h.txt").write_text("z")
      assert "A/Moved/h.txt" in drain(watch, 0.3)
      assert "A/B" not in watch.dirs.values()
      os.remove(root / "A" / "C" / "g.txt")
      assert "A/C/g.txt" in drain(watch, 0.3)
      assert not watch.root_gone
    finally:
      watch.close()
    gone = Path(tmp) / "gone"
    gone.mkdir()
    watch = cs.TreeWatch(gone)
    try:
      watch.add_tree("")
      gone.rmdir()
      drain(watch, 0.3)
      assert watch.root_gone
    finally:
      watch.close()


def t_stale_tmp():
  with tempfile.TemporaryDirectory() as tmp:
    state = Path(tmp)
    os.chmod(state, 0o700)
    old = state / ".state.json.tmp.01c3595cb84a1a7f"
    young = state / ".state.json.tmp.1985c5b8de71576e"
    other = state / "state.json"
    for path in (old, young, other):
      path.write_text("{}")
    os.utime(old, (time.time() - 7200, time.time() - 7200))
    os.utime(other, (time.time() - 7200, time.time() - 7200))
    eq(cs.clear_stale_tmp_files(state), 1)
    assert not old.exists() and young.exists() and other.exists()


def t_units():
  folder = Path.home() / "Google Drive"
  text = cs.watch_unit_source("gdrive", folder)
  assert 'watch --remote "gdrive" --folder "' + str(folder) + '"' in text, text
  assert "Restart=on-failure" in text and "SuccessExitStatus=143" in text
  units = cs.unit_sources("gdrive", folder, Path.home() / "Cloud-Browse")
  assert "omarchy-storage-watch-gdrive.service" in units
  command = cs.bisync_command("rclone", "gdrive", folder, False, "drive", cs.remote_paths("gdrive"))
  assert "--track-renames" not in command


test("only selected, non-scratch paths count", t_watched_path)
test("bisync listing times parse", t_listing_time)
test("changes are told apart from what the sync wrote", t_changes_against_listing)
test("the tree watch follows new, moved and removed folders", t_tree_watch)
test("stale atomic-write leftovers are cleared", t_stale_tmp)
test("watch unit and bisync flags", t_units)
print(f"\n{passes} passed, {failures} failed")
sys.exit(1 if failures else 0)
