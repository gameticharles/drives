#!/usr/bin/env python3
# Google Drive on rclone's shared client ID (cloud-sync.py): telling which
# remotes use it, reading rclone.conf, and checking what the `client-id`
# helper accepts. Nothing here talks to Google or changes rclone's config.
# Run: python3 test/client_id_test.py

import importlib.util
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


def t_shared():
  assert cs.uses_shared_client_id({"type": "drive", "token": "{}"})
  assert cs.uses_shared_client_id({"type": "drive", "client_id": "  "})
  assert not cs.uses_shared_client_id({"type": "drive", "client_id": "1-a.apps.googleusercontent.com"})
  assert not cs.uses_shared_client_id({"type": "onedrive"}), "only Google Drive"
  assert not cs.uses_shared_client_id(None)
  assert not cs.uses_shared_client_id({})


def t_conf_section():
  with tempfile.TemporaryDirectory() as tmp:
    conf = Path(tmp) / "rclone.conf"
    # A token is JSON with % signs in it at times: no interpolation.
    conf.write_text('[gdrive]\ntype = drive\ntoken = {"access_token":"a%2Fb"}\n\n[box]\ntype = box\n')
    real = cs.rclone_conf_path
    cs.rclone_conf_path = lambda rclone=None: conf
    try:
      section = cs.remote_conf_section(None, "gdrive")
      assert section and section["token"] == '{"access_token":"a%2Fb"}', section
      assert cs.uses_shared_client_id(section)
      assert cs.remote_conf_section(None, "missing") is None
      assert cs.is_remote_authenticated("", "gdrive", "drive")
      assert not cs.is_remote_authenticated("", "box", "box"), "no token"
      conf.write_text("# Encrypted rclone configuration File\n\nRCLONE_ENCRYPT_V0:\nabc\n")
      assert cs.remote_conf_section(None, "gdrive") is None, "encrypted config cannot be read"
    finally:
      cs.rclone_conf_path = real


def t_inputs():
  assert cs.GOOGLE_CLIENT_ID.match("123456789012-abcdefghijklmnop0123456789abcdef.apps.googleusercontent.com")
  assert not cs.GOOGLE_CLIENT_ID.match("123.apps.googleusercontent.com.evil")
  assert not cs.GOOGLE_CLIENT_ID.match("my client")
  assert cs.GOOGLE_CLIENT_SECRET.match("GOCSPX-AbCdEf_123456")
  assert not cs.GOOGLE_CLIENT_SECRET.match("short")
  assert not cs.GOOGLE_CLIENT_SECRET.match("has space in it")


def t_default_interval():
  units = cs.unit_sources("gdrive", Path.home() / "Google Drive", Path.home() / "Cloud-Browse")
  assert "OnUnitInactiveSec=30min" in units["omarchy-storage-sync-gdrive.timer"]


test("only Google Drive without a client_id is on the shared one", t_shared)
test("rclone.conf sections read as written", t_conf_section)
test("client ID and secret checks", t_inputs)
test("auto-sync defaults to every 30 minutes", t_default_interval)
print(f"\n{passes} passed, {failures} failed")
sys.exit(1 if failures else 0)
