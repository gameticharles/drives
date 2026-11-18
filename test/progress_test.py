#!/usr/bin/env python3
# What a running sync is doing (cloud-sync.py SyncProgress): bisync's phases,
# the changes it finds on each side and which way they go, and why the run
# started. The log lines are rclone 1.76's own, colour codes included.
# Run: python3 test/progress_test.py

import importlib.util
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


E = "\x1b"
# Path1 is the cloud, Path2 this computer. (msg, object) pairs, in order.
RUN = [
  ("Building Path1 and Path2 listings", ""),
  ("Path1 checking for diffs", ""),
  (f"- {E}[36mPath1{E}[0m    {E}[35m{E}[33mFile changed: {E}[35msize (larger){E}[0m, {E}[35mtime (newer){E}[0m{E}[0m{E}[0m - {E}[36mWork/THESIS 2026-08-08 - Draft.pdf{E}[0m", ""),
  (f"- {E}[36mPath1{E}[0m    {E}[35m{E}[32mFile is new{E}[0m{E}[0m               - {E}[36mWork/NewDir{E}[0m", ""),
  (f"- {E}[36mPath1{E}[0m    {E}[35m{E}[32mFile is new{E}[0m{E}[0m               - {E}[36mWork/NewDir/big.bin{E}[0m", ""),
  ("Path2 checking for diffs", ""),
  (f"- {E}[34mPath2{E}[0m    {E}[35m{E}[31mFile was deleted{E}[0m{E}[0m          - {E}[36mWork/old.txt{E}[0m", ""),
  (f"- {E}[34mPath2{E}[0m    {E}[35m{E}[32mFile is new{E}[0m{E}[0m               - {E}[36mWork/from-b.txt{E}[0m", ""),
  ("Applying changes", ""),
  (f"- {E}[36mPath1{E}[0m    {E}[35m{E}[32mQueue copy to{E}[0m Path2{E}[0m       - {E}[36mb/Work/NewDir{E}[0m", ""),
  (f"- {E}[34mPath2{E}[0m    {E}[35mDo queued copies to{E}[0m                - {E}[36mPath1{E}[0m", ""),
  ("Copied (new)", "Work/from-b.txt"),
  ("Deleted", "Work/old.txt"),
  ("Set directory modification time (using SetModTime)", "Work"),
  (f"- {E}[36mPath1{E}[0m    {E}[35mDo queued copies to{E}[0m                - {E}[36mPath2{E}[0m", ""),
  ("Made directory with metadata (mtime=2026-11-18T07:16:40.7630489Z)", "Work/NewDir"),
  ("Copied (replaced existing)", "Work/THESIS 2026-08-08 - Draft.pdf"),
  ("Updating listings", ""),
]


def feed(progress, upto):
  phases = []
  for msg, obj in RUN[:upto]:
    if obj:
      progress.done(obj, msg)
    elif progress.line(msg):
      phases.append(progress.phase)
  return phases


def t_phases_and_plan():
  p = cs.SyncProgress()
  eq(p.text({}), "Starting")
  eq(feed(p, 1), ["listing"])
  eq(p.text({"listed": 17067}), "Listing both sides · 17,067 items")
  feed(p, 9)
  eq(p.phase, "applying")
  eq([(c["name"], c["direction"], c["kind"]) for c in p.pending.values()], [
    ("Work/THESIS 2026-08-08 - Draft.pdf", "down", "changed"),  # " - " inside the name
    ("Work/NewDir", "down", "new"),
    ("Work/NewDir/big.bin", "down", "new"),
    ("Work/old.txt", "up", "deleted"),
    ("Work/from-b.txt", "up", "new"),
  ])
  eq(p.counts, {"up": 2, "down": 3})
  eq(p.text({}), "5 changes to apply")


def t_directions_and_done():
  p = cs.SyncProgress()
  feed(p, 11)
  eq((p.phase, p.direction), ("up", "up"))
  eq(p.text({}), "Uploading changes")
  feed(p, len(RUN))
  eq(p.phase, "finishing")
  eq(sorted(p.pending), ["Work/NewDir/big.bin"])  # not copied yet in this excerpt
  fields = p.fields({})
  eq(fields["plannedRemaining"], 1)
  eq(fields["plannedChanges"], [{"name": "Work/NewDir/big.bin", "direction": "down", "kind": "new"}])
  eq(fields["phaseText"], "Saving the sync state")


def t_conflict_and_resync():
  p = cs.SyncProgress()
  p.line("- Path1    File changed: time (newer) - Work/both.txt")
  p.line("- Path2    File changed: size (larger) - Work/both.txt")
  eq(p.pending["Work/both.txt"]["kind"], "conflict")
  eq(p.counts, {"up": 0, "down": 1})
  r = cs.SyncProgress(resync=True)
  assert r.line("Copying Path2 files to Path1")
  eq(r.text({}), "First sync: copying to the cloud")
  assert r.line(f"- {E}[36mPath1{E}[0m    {E}[35mResync is copying files to{E}[0m         - {E}[36mPath2{E}[0m")
  eq(r.text({}), "First sync: copying to this computer")
  assert not r.line("Transferred: 0 B / 0 B, -, 0 B/s, ETA -")


def t_reason():
  with tempfile.TemporaryDirectory() as tmp:
    paths = {"state_path": Path(tmp) / "state.json", "state_dir": Path(tmp)}
    eq(cs.take_sync_reason(paths)["kind"], "timer")
    cs.patch_state(paths, syncReason={"kind": "local", "paths": ["Work/a.docx"], "count": 3, "ts": int(time.time())})
    eq(cs.take_sync_reason(paths)["kind"], "local")
    cs.patch_state(paths, syncReason={"kind": "local", "paths": ["Work/a.docx"], "ts": int(time.time()) - 7 * 3600})
    eq(cs.take_sync_reason(paths)["kind"], "timer")  # a stale note is not this run's reason
    eq(cs.take_sync_reason(paths, "selection")["kind"], "selection")
  eq(cs.sync_reason_text({"kind": "local", "paths": ["Work/a.docx"], "count": 3}), "For your change to Work/a.docx and 2 more")
  eq(cs.sync_reason_text({"kind": "local", "paths": ["Work/a.docx"], "count": 1}), "For your change to Work/a.docx")
  eq(cs.sync_reason_text({"kind": "local", "paths": [], "count": 0}), "For a change in this folder")
  eq(cs.sync_reason_text({"kind": "manual"}), "Started with Sync now")
  eq(cs.sync_reason_text({"kind": "timer"}), "Regular check")
  eq(cs.sync_reason_text(None), "")


def t_resync_only_when_needed():
  aborted = ("ERROR : There were errors while building listings. Aborting as it is too dangerous to continue.\n"
             "ERROR : \x1b[33mBisync aborted. Error is retryable without --resync due to --resilient mode.\x1b[0m")
  assert not cs.needs_resync(aborted), "a retryable abort must not resync"
  assert cs.needs_resync("ERROR : \x1b[31mBisync aborted. Must run --resync to recover.\x1b[0m")
  assert cs.needs_resync("Bisync critical error: cannot find prior Path1 or Path2 listings, likely due to critical error on prior run")
  assert not cs.needs_resync("")


def t_rate_limit_reason():
  with tempfile.TemporaryDirectory() as tmp:
    paths = {"state_path": Path(tmp) / "state.json", "state_dir": Path(tmp)}
    real = cs.notify
    sent = []
    cs.notify = lambda *a, **k: sent.append(a)
    try:
      cs.record_failure(paths, "gdrive", "couldn't list directory: googleapi: Error 403: Quota exceeded for quota metric "
                        "'Queries' and limit 'Previous quota: Requests per minute', rateLimitExceeded", 1740.0, "ok")
    finally:
      cs.notify = real
    state = cs.load_state(paths)
    eq(state["lastResult"], "error")
    assert state["lastError"].startswith("The cloud refused more requests for now (rate limit)"), state["lastError"]
    assert "client ID of your own" in state["lastError"]
    eq(len(sent), 1)


test("phases, and the changes found on each side", t_phases_and_plan)
test("copy batches set the direction; finished files leave the plan", t_directions_and_done)
test("a change on both sides is a conflict; resync copies both ways", t_conflict_and_resync)
test("why a run started", t_reason)
test("a resync only when rclone says one is needed", t_resync_only_when_needed)
test("a rate limit is reported as one", t_rate_limit_reason)
print(f"\n{passes} passed, {failures} failed")
sys.exit(1 if failures else 0)
