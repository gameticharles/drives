#!/usr/bin/env python3
# Cloud sync selection (cloud-sync.py): which folders are
# kept, the rclone filters they make, and what clean-up may free. Nothing
# here talks to the cloud: rclone is a stub. Run: python3 test/selection_test.py

import importlib.util
import json
import os
import sys
import tempfile
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


def sel(folders=(), excludes=(), root=False):
  return cs.normalise_selection({"folders": list(folders), "excludes": list(excludes), "rootFiles": root})


def eq(a, b):
  assert a == b, f"{a!r} != {b!r}"


def t_default():
  eq(cs.normalise_selection({}), {"folders": [], "excludes": [], "rootFiles": False})
  eq(cs.normalise_selection({"folders": ["A"]})["rootFiles"], False)
  eq(cs.normalise_selection({"rootFiles": True})["rootFiles"], True)


def t_states():
  s = sel(["Work"], ["Work/Videos"])
  eq(cs.path_state(s, "Work"), "partial")
  eq(cs.path_state(s, "Work/Videos"), "off")
  eq(cs.path_state(s, "Work/Videos/2024"), "off")
  eq(cs.path_state(s, "Work/Reports"), "on")
  eq(cs.path_state(s, "Photos"), "off")
  s = sel(["Photos/2026"])
  eq(cs.path_state(s, "Photos"), "partial")
  eq(cs.path_state(s, "Photos/2026"), "on")
  eq(cs.path_state(s, "Photos/2025"), "off")


def t_normalise():
  # Kept inside a kept folder: redundant. Left out of nothing: meaningless.
  eq(sel(["A", "A/B"], ["C/D"]), {"folders": ["A"], "excludes": [], "rootFiles": False})
  # Kept inside a left-out folder: rclone never looks there.
  eq(sel(["A", "A/B/C"], ["A/B"]), {"folders": ["A"], "excludes": ["A/B"], "rootFiles": False})
  # Bad paths are dropped, slashes tidied.
  eq(sel(["/A/", "..", "A//B", ""])["folders"], ["A"])


def t_toggle():
  s = sel()
  cs.toggle_path(s, "Work"); s = cs.normalise_selection(s)
  eq(s["folders"], ["Work"])
  cs.toggle_path(s, "Work/Videos"); s = cs.normalise_selection(s)
  eq((s["folders"], s["excludes"]), (["Work"], ["Work/Videos"]))
  # Back on: the exclusion goes.
  cs.toggle_path(s, "Work/Videos"); s = cs.normalise_selection(s)
  eq((s["folders"], s["excludes"]), (["Work"], []))
  # A part of an unkept folder, then a second part later.
  s = sel()
  cs.toggle_path(s, "Photos/2026"); cs.toggle_path(s, "Photos/2025"); s = cs.normalise_selection(s)
  eq(s["folders"], ["Photos/2025", "Photos/2026"])
  # The parent as a whole replaces its parts.
  cs.toggle_path(s, "Photos"); s = cs.normalise_selection(s)
  eq(s["folders"], ["Photos"])
  # Off again: everything under it goes too.
  cs.toggle_path(s, "Photos/Old"); cs.toggle_path(s, "Photos"); s = cs.normalise_selection(s)
  eq((s["folders"], s["excludes"]), ([], []))


def t_filters():
  f = cs.build_filters(sel(["Work", "Photos/2026"], ["Work/Videos"])).splitlines()
  rules = [l for l in f if not l.startswith("#")]
  eq(rules, ["- /Personal Vault/**", "+ /Photos/2026/**", "- /Work/Videos/**", "+ /Work/**", "- **"])
  assert "+ /*" not in rules, "loose files are off by default"
  assert "+ /*" in cs.build_filters(sel(root=True)), "loose files on when chosen"
  # Glob characters in names are escaped.
  assert "+ /Data \\[2026\\]/**" in cs.build_filters(sel(["Data [2026]"]))


def t_stale_and_cleanup():
  # Sync folders must be inside the home directory.
  cache = Path.home() / ".cache"
  cache.mkdir(exist_ok=True)
  with tempfile.TemporaryDirectory(dir=cache, prefix="terrace-test-") as tmp:
    root = Path(tmp) / "Drive"
    for p in ["Work/Reports/r.pdf", "Work/Videos/v.mp4", "Work/notes.txt", "Photos/2026/a.jpg", "Photos/2025/b.jpg",
              "Photos/top.jpg", "Old/x.bin", "loose.pdf", "local-only.txt"]:
      (root / p).parent.mkdir(parents=True, exist_ok=True)
      (root / p).write_bytes(b"x" * 10)
    s = sel(["Work", "Photos/2026"], ["Work/Videos"])
    stale, _ = cs.local_stale(root, s)
    got = sorted((i["path"], i["dir"]) for i in stale)
    eq(got, [("Old", True), ("Photos/2025", True), ("Photos/top.jpg", False), ("Work/Videos", True),
             ("local-only.txt", False), ("loose.pdf", False)])
    assert not any(p.startswith("Work/Reports") or p == "Work" or p == "Photos/2026" for p, _ in got), "kept folders are never stale"

    # Clean-up with a stub rclone: the cloud holds everything but local-only.txt.
    bindir = Path(tmp) / "bin"; bindir.mkdir()
    stub = bindir / "rclone"
    stub.write_text("#!/bin/sh\n"
                    "if [ \"$1\" = check ]; then\n"
                    "  for a in \"$@\"; do case $prev in --files-from) list=$a;; esac; prev=$a; done\n"
                    "  if [ -n \"$list\" ]; then grep -v '^local-only.txt$' \"$list\" | sed 's/^/= /'; fi\n"
                    "  exit 0\nfi\nexit 1\n")
    stub.chmod(0o755)
    state = Path(tmp) / "state"
    os.environ["XDG_STATE_HOME"] = str(state)
    os.environ["PATH"] = str(bindir) + os.pathsep + os.environ["PATH"]
    cs.STATE_BASE = state / "omarchy-storage-drives" / "cloud"
    paths = cs.remote_paths("gdrive")
    paths["state_dir"].mkdir(parents=True)
    cs.save_selection(paths, s)

    class A: remote = "gdrive"; folder = str(root); only = []
    import io, contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
      cs.cmd_cleanup(A())
    out = json.loads(buf.getvalue())
    eq(sorted(out["removed"]), ["Old", "Photos/2025", "Photos/top.jpg", "Work/Videos", "loose.pdf"])
    eq(out["keptBack"], 1)
    assert (root / "local-only.txt").exists(), "a file the cloud lacks is kept"
    assert (root / "Work/Reports/r.pdf").exists() and (root / "Work/notes.txt").exists() and (root / "Photos/2026/a.jpg").exists()


test("loose files are off unless chosen", t_default)
test("each path is on, off or partial", t_states)
test("redundant and impossible rules are dropped", t_normalise)
test("toggling keeps, leaves out, and replaces parts", t_toggle)
test("filters put the deepest rule first", t_filters)
test("clean-up frees only what isn't kept and the cloud holds", t_stale_and_cleanup)
print(f"\n{passes} passed, {failures} failed")
sys.exit(1 if failures else 0)
