#!/usr/bin/env python3
# Pausing every cloud sync (cloud-sync.py `pause`): the flag, stopping what is
# running, runs ending at once while paused, and catching up on resume.
# systemd and rclone are stubs: nothing here starts, stops or syncs anything.
# Run: python3 test/pause_test.py

import argparse
import importlib.util
import io
import json
import sys
import tempfile
from contextlib import redirect_stdout
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


class Sandbox:
  """State and unit folders in a temp dir; systemd answers from `active`
  and `enabled`, and every systemctl call is recorded."""

  def __init__(self, active=(), enabled=()):
    self.tmp = tempfile.TemporaryDirectory()
    root = Path(self.tmp.name)
    self.saved = {name: getattr(cs, name) for name in
                  ("STATE_BASE", "UNIT_DIR", "PAUSE_PATH", "run", "service_active", "timer_enabled")}
    cs.STATE_BASE = root / "state"
    cs.UNIT_DIR = root / "units"
    cs.PAUSE_PATH = cs.STATE_BASE / "paused.json"
    cs.STATE_BASE.mkdir(mode=0o700)
    cs.UNIT_DIR.mkdir()
    for slug in ("gdrive", "dropbox", "onedrive"):
      (cs.UNIT_DIR / f"omarchy-storage-sync-{slug}.service").write_text("[Service]\n")
      (cs.STATE_BASE / slug).mkdir(mode=0o700)
    self.active, self.enabled, self.calls = set(active), set(enabled), []
    cs.run = self.fake_run
    cs.service_active = lambda unit: unit in self.active
    cs.timer_enabled = lambda unit: unit in self.enabled

  def fake_run(self, command, timeout=20, **_):
    self.calls.append(command)
    return 0, "", ""

  def close(self):
    for name, value in self.saved.items():
      setattr(cs, name, value)
    self.tmp.cleanup()


def pause(on):
  out = io.StringIO()
  with redirect_stdout(out):
    cs.cmd_pause(argparse.Namespace(on=on, off=not on))
  return json.loads(out.getvalue())


def t_pause_stops_running():
  box = Sandbox(active={"omarchy-storage-sync-gdrive.service"})
  try:
    result = pause(True)
    assert result["paused"] and result["since"] > 0, result
    assert cs.sync_paused()
    eq(box.calls, [["systemctl", "--user", "stop", "omarchy-storage-sync-gdrive.service"]])
    # Pausing again keeps the first time it was paused.
    since = result["since"]
    eq(pause(True)["since"], since)
  finally:
    box.close()


def t_runs_end_while_paused():
  box = Sandbox()
  try:
    pause(True)
    called = []
    real = cs.rclone_bin
    cs.rclone_bin = lambda: called.append(1) or "/bin/false"
    try:
      with redirect_stdout(io.StringIO()):
        eq(cs.do_run_once("gdrive", str(Path.home() / "Google Drive"), False), 0)
    finally:
      cs.rclone_bin = real
    eq(called, [])  # never got as far as rclone
    try:
      cs.cmd_sync(argparse.Namespace(remote="gdrive", folder="~/Cloud", mount="~/Cloud-Browse", resync=False))
      raise AssertionError("Sync now ran while paused")
    except RuntimeError as error:
      assert "paused" in str(error)
  finally:
    box.close()


def t_resume_catches_up():
  box = Sandbox(enabled={"omarchy-storage-sync-gdrive.timer", "omarchy-storage-sync-onedrive.timer"},
                active={"omarchy-storage-sync-onedrive.service"})
  try:
    pause(True)
    box.calls.clear()
    box.active = {"omarchy-storage-sync-onedrive.service"}  # still running somehow: left alone
    result = pause(False)
    eq(result["paused"], False)
    assert not cs.sync_paused()
    # Only accounts with auto-sync on, and not one already running.
    eq(box.calls, [["systemctl", "--user", "start", "--no-block", "omarchy-storage-sync-gdrive.service"]])
    note = cs.load_state(cs.remote_paths("gdrive")).get("syncReason")
    eq(note["kind"], "resume")
    eq(cs.take_sync_reason(cs.remote_paths("gdrive"))["kind"], "resume")
    eq(cs.sync_reason_text(note), "Catching up after the pause")
    assert "syncReason" not in cs.load_state(cs.remote_paths("dropbox"))
  finally:
    box.close()


def t_unit_and_stop_cleanup():
  units = cs.unit_sources("gdrive", Path.home() / "Google Drive", Path.home() / "Cloud-Browse")
  assert "SuccessExitStatus=143" in units["omarchy-storage-sync-gdrive.service"], "a pause would leave the unit failed"
  with tempfile.TemporaryDirectory() as tmp:
    paths = {"state_path": Path(tmp) / "state.json", "state_dir": Path(tmp)}
    cs.patch_state(paths, syncing=True, phase="up", phaseText="Uploading changes",
                   activeTransfers=[{"name": "a"}], plannedChanges=[{"name": "a"}], plannedRemaining=1)
    real = cs.untag_failed_sync
    cs.untag_failed_sync = lambda *a: None
    try:
      cs.stopped_midway(paths, Path(tmp), "")
    finally:
      cs.untag_failed_sync = real
    state = cs.load_state(paths)
    eq((state["syncing"], state["phase"], state["activeTransfers"], state["plannedRemaining"]), (False, "", [], 0))


test("pausing writes the flag and stops what is running", t_pause_stops_running)
test("runs and Sync now do nothing while paused", t_runs_end_while_paused)
test("resuming syncs each auto-sync account once", t_resume_catches_up)
test("a stopped run leaves no 'syncing' behind", t_unit_and_stop_cleanup)
print(f"\n{passes} passed, {failures} failed")
sys.exit(1 if failures else 0)
