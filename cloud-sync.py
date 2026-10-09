#!/usr/bin/env python3
"""Multi-cloud rclone sync & browse helper for Omarchy Storage Drives.

Supports multiple accounts across Google Drive, Mega, OneDrive, Dropbox,
Nextcloud/WebDAV, and other rclone remotes.

Features:
- Two-way selective sync with rclone bisync
- Live folder picker (lsjson) & root files selection
- Read-only on-demand FUSE browse mount (rclone mount)
- Systemd user timer & service management per account
- Stale file detection & verified cleanup
- rclone installation detection and remote auto-discovery
"""

from __future__ import annotations

import argparse
import codecs
import configparser
import ctypes
import errno
import fcntl
import hashlib
import itertools
import json
import os
import re
import secrets
import selectors
import shutil
import tempfile
import signal
import stat
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, Iterable, Iterator

STATE_BASE = Path(os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local" / "state")) / "omarchy-storage-drives" / "cloud"
UNIT_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "systemd" / "user"

REMOTE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._@/-]*$")
GLOB_SPECIALS = set("\\*?[]{}")
SKIP_LOCAL = {".rclone-bisync", "lost+found"}
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
NAME_BAD = re.compile(r"[\x00-\x1f\x7f/]")
ANSI = re.compile(r"\x1b\[[0-9;]*m")

MAX_OUTPUT = 1 << 20
MAX_LIST_BYTES = 8 << 20
MAX_LIST_ENTRIES = 5000
MAX_ITEM_BYTES = 64 << 10
MAX_NAME_BYTES = 255
CHECK_STDERR_BYTES = 256 << 10
LOG_ROTATE_BYTES = 2 << 20
LOG_TAIL_BYTES = 16384
MAX_WALK_ENTRIES = 100_000
MAX_WALK_SECONDS = 2.0
ABOUT_CACHE_SECONDS = 60
EXIT_TIMEOUT = 124
EXIT_TOO_LARGE = 125
RCLONE_RESYNC_CODES = (2, 7)


def clean_text(value: str, limit: int = 400) -> str:
  text = " ".join((value or "").split())
  return text if len(text) <= limit else text[: limit - 1] + "…"


try:
  _PRCTL = ctypes.CDLL(None, use_errno=True).prctl
  _PRCTL.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
except (OSError, AttributeError):
  _PRCTL = None


def _die_with_parent() -> None:
  if _PRCTL is not None:
    _PRCTL(1, int(signal.SIGKILL), 0, 0, 0)


class ChildTimeout(RuntimeError):
  code = EXIT_TIMEOUT


class ChildOutputTooLarge(RuntimeError):
  code = EXIT_TOO_LARGE


_LIVE: set[subprocess.Popen] = set()


class Child:
  def __init__(self, command: list[str], *, timeout: float = 20.0, max_stdout: int = MAX_OUTPUT,
               max_stderr: int = MAX_OUTPUT, pass_fds: tuple[int, ...] = ()):
    self.command = command
    self.timeout = timeout
    self.max_stdout = max_stdout
    self.max_stderr = max_stderr
    self.pass_fds = pass_fds
    self.proc: subprocess.Popen | None = None
    self.stderr = bytearray()
    self.returncode: int | None = None
    self.deadline = 0.0

  def __enter__(self) -> "Child":
    self.proc = subprocess.Popen(
      self.command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
      start_new_session=True, pass_fds=self.pass_fds, preexec_fn=_die_with_parent)
    self.deadline = time.monotonic() + self.timeout
    _LIVE.add(self.proc)
    return self

  def __exit__(self, *exc: object) -> None:
    proc = self.proc
    if proc is None:
      return
    self._killpg()
    if proc.poll() is None:
      try:
        proc.wait(timeout=5)
      except subprocess.TimeoutExpired:
        pass
    for pipe in (proc.stdout, proc.stderr):
      if pipe is not None:
        pipe.close()
    _LIVE.discard(proc)

  def _killpg(self) -> None:
    proc = self.proc
    if proc is None:
      return
    try:
      os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
      pass

  def _abort(self) -> None:
    self._killpg()
    if self.proc is not None:
      try:
        self.proc.wait(timeout=5)
      except subprocess.TimeoutExpired:
        pass

  def chunks(self) -> Iterator[bytes]:
    proc = self.proc
    assert proc is not None and proc.stdout is not None and proc.stderr is not None
    out_fd, err_fd = proc.stdout.fileno(), proc.stderr.fileno()
    limit = {out_fd: self.max_stdout, err_fd: self.max_stderr}
    seen = {out_fd: 0, err_fd: 0}
    with selectors.DefaultSelector() as sel:
      for fd in limit:
        sel.register(fd, selectors.EVENT_READ)
      while limit:
        wait = self.deadline - time.monotonic()
        if wait <= 0:
          self._abort()
          raise ChildTimeout()
        for key, _ in sel.select(wait):
          try:
            data = os.read(key.fd, 65536)
          except OSError:
            data = b""
          if not data:
            sel.unregister(key.fd)
            del limit[key.fd]
            continue
          seen[key.fd] += len(data)
          if seen[key.fd] > limit[key.fd]:
            self._abort()
            raise ChildOutputTooLarge()
          if key.fd == err_fd:
            self.stderr += data
          else:
            yield data
    try:
      self.returncode = proc.wait(timeout=max(0.0, self.deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
      self._abort()
      raise ChildTimeout()
    self._killpg()

  def stderr_text(self) -> str:
    return bytes(self.stderr).decode("utf-8", "replace").strip()

  def failure(self) -> str:
    proc = self.proc
    if proc is None:
      return ""
    self._abort()
    room = max(0, self.max_stderr - len(self.stderr))
    if proc.stderr is not None and room:
      try:
        self.stderr += os.read(proc.stderr.fileno(), room)
      except OSError:
        pass
    code = proc.returncode
    if code is None or code == 0 or code < 0:
      return ""
    return self.stderr_text()


def run(command: list[str], timeout: float = 20, pass_fds: tuple[int, ...] = (), *,
        max_stdout: int = MAX_OUTPUT, max_stderr: int = MAX_OUTPUT) -> tuple[int, str, str]:
  out = bytearray()
  try:
    with Child(command, timeout=timeout, max_stdout=max_stdout, max_stderr=max_stderr, pass_fds=pass_fds) as child:
      for data in child.chunks():
        out += data
      code = child.returncode or 0
      err = child.stderr_text()
  except FileNotFoundError as error:
    return 127, "", str(error)
  except OSError as error:
    return 126, "", str(error)
  except ChildTimeout:
    return EXIT_TIMEOUT, "", f"Command timed out after {timeout:g}s"
  except ChildOutputTooLarge:
    return EXIT_TOO_LARGE, "", "Command produced too much output"
  return code, bytes(out).decode("utf-8", "replace").strip(), err


def kill_live_children(grace: float = 10.0) -> None:
  procs = list(_LIVE)
  for proc in procs:
    try:
      os.killpg(proc.pid, signal.SIGTERM)
    except OSError:
      pass
  deadline = time.monotonic() + grace
  while time.monotonic() < deadline and any(proc.poll() is None for proc in procs):
    time.sleep(0.05)
  for proc in procs:
    try:
      os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
      pass


def _on_signal(signum: int, _frame: object) -> None:
  kill_live_children()
  raise SystemExit(128 + signum)


class ListingTooLarge(RuntimeError):
  pass


class ListingUnreadable(RuntimeError):
  pass


def iter_json_array(chunks: Iterable[bytes], *, max_entries: int | None = None,
                    max_item_bytes: int | None = None) -> Iterator[Any]:
  max_entries = MAX_LIST_ENTRIES if max_entries is None else max_entries
  max_item = MAX_ITEM_BYTES if max_item_bytes is None else max_item_bytes
  decoder = json.JSONDecoder(parse_constant=lambda _: None)
  utf8 = codecs.getincrementaldecoder("utf-8")(errors="replace")
  buf = ""
  opened = False
  closed = False
  count = 0
  for raw in itertools.chain(chunks, (b"",)):
    buf += utf8.decode(raw, final=not raw)
    while True:
      buf = buf.lstrip()
      if not buf:
        break
      if closed:
        raise ListingUnreadable("data after the end of the listing")
      if not opened:
        if buf[0] != "[":
          raise ListingUnreadable("listing does not start with an array")
        buf = buf[1:]
        opened = True
        continue
      if buf[0] == "]":
        closed = True
        buf = buf[1:]
        continue
      if buf[0] == ",":
        buf = buf[1:]
        continue
      if buf[0] != "{":
        raise ListingUnreadable("listing row is not an object")
      try:
        item, end = decoder.raw_decode(buf)
      except json.JSONDecodeError:
        if len(buf) > max_item:
          raise ListingTooLarge("a listing entry is too long")
        break
      except ValueError:
        raise ListingUnreadable("listing row is not readable")
      if end > max_item:
        raise ListingTooLarge("a listing entry is too long")
      buf = buf[end:]
      count += 1
      if count > max_entries:
        raise ListingTooLarge(f"more than {max_entries} entries")
      yield item
  if not closed:
    raise ListingUnreadable("listing ended early")


def valid_drive_name(name: object) -> bool:
  if not isinstance(name, str) or not name.strip() or name in (".", ".."):
    return False
  if NAME_BAD.search(name):
    return False
  try:
    return len(name.encode("utf-8")) <= MAX_NAME_BYTES
  except UnicodeEncodeError:
    return False


def clamp_int(value: object, limit: int = 1 << 62) -> int:
  if isinstance(value, bool) or not isinstance(value, int):
    return 0
  return value if 0 <= value <= limit else 0


def escape_glob(text: str) -> str:
  escaped: list[str] = []
  for char in text:
    if char in GLOB_SPECIALS:
      escaped.append("\\" + char)
    else:
      escaped.append(char)
  return "".join(escaped)


def tail_bytes(path: Path, limit: int) -> str:
  try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
  except OSError:
    return ""
  try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
      return ""
    os.lseek(fd, max(0, info.st_size - limit), os.SEEK_SET)
    chunks = []
    remaining = limit
    while remaining > 0:
      data = os.read(fd, min(65536, remaining))
      if not data:
        break
      chunks.append(data)
      remaining -= len(data)
    return b"".join(chunks).decode("utf-8", "replace")
  finally:
    os.close(fd)


def _unlink_quiet(name: str, dir_fd: int) -> None:
  try:
    os.unlink(name, dir_fd=dir_fd)
  except OSError:
    pass


def rotate_log(path: Path, limit: int = LOG_ROTATE_BYTES) -> None:
  dfd = open_owned_dir(path.parent, fix_mode=0o700)
  try:
    try:
      info = os.stat(path.name, dir_fd=dfd, follow_symlinks=False)
    except FileNotFoundError:
      return
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
      _unlink_quiet(path.name, dfd)
      return
    if info.st_size > limit:
      os.replace(path.name, path.name + ".1", src_dir_fd=dfd, dst_dir_fd=dfd)
  finally:
    os.close(dfd)


def rclone_bin() -> str | None:
  return shutil.which("rclone")


def normalize_remote(value: str) -> str:
  remote = (value or "gdrive").strip().removesuffix(":").strip()
  if not REMOTE_RE.fullmatch(remote):
    raise ValueError("Remote name may only contain letters, numbers, spaces, dots, underscores, and hyphens")
  return remote


def remote_slug(remote: str) -> str:
  cleaned = normalize_remote(remote)
  return re.sub(r"[^A-Za-z0-9_.-]", "_", cleaned)


def remote_paths(remote: str) -> dict[str, Any]:
  slug = remote_slug(remote)
  state_dir = STATE_BASE / slug
  return {
    "slug": slug,
    "state_dir": state_dir,
    "selection_path": state_dir / "selection.json",
    "filters_path": state_dir / "filters.txt",
    "state_path": state_dir / "state.json",
    "cache_path": state_dir / "cache.json",
    "log_path": state_dir / "sync.log",
    "mount_log_path": state_dir / "mount.log",
    "workdir": state_dir / "workdir",
    "lock_path": state_dir / "sync.lock",
    "service_name": f"omarchy-storage-sync-{slug}.service",
    "timer_name": f"omarchy-storage-sync-{slug}.timer",
    "browse_service_name": f"omarchy-storage-browse-{slug}.service",
  }


def normalize_path(value: str, fallback: str) -> Path:
  if CONTROL.search(value or ""):
    raise ValueError("Folder path contains control characters")
  path = Path(os.path.expandvars(os.path.expanduser(value or fallback)))
  path = path if path.is_absolute() else (Path.home() / path)
  resolved = Path(os.path.normpath(str(path)))
  home = Path.home().resolve()
  if resolved in (Path("/"), home) or home not in resolved.parents:
    raise ValueError("Choose a folder inside your home directory, not the home directory itself")
  if CONTROL.search(str(resolved)):
    raise ValueError("Folder path contains control characters")
  return resolved


def read_json(path: Path, fallback: Any) -> Any:
  try:
    with path.open(encoding="utf-8") as handle:
      return json.load(handle)
  except (OSError, json.JSONDecodeError):
    return fallback


def open_owned_dir(path: Path, *, fix_mode: int | None = None) -> int:
  path.mkdir(parents=True, exist_ok=True, mode=0o700)
  try:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
  except OSError as error:
    if error.errno in (errno.ELOOP, errno.ENOTDIR):
      raise RuntimeError(f"{path} is a symlink or not a directory") from error
    raise
  try:
    info = os.fstat(fd)
    if info.st_uid != os.geteuid():
      raise RuntimeError(f"{path} is not owned by you (uid {info.st_uid})")
    if fix_mode is not None and (info.st_mode & 0o777) != fix_mode:
      try:
        os.fchmod(fd, fix_mode)
      except OSError:
        pass
    return fd
  except Exception:
    os.close(fd)
    raise


def open_owned_file(path: Path, flags: int = os.O_WRONLY | os.O_CREAT | os.O_APPEND, mode: int = 0o600) -> int:
  path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
  fd = os.open(path, flags | os.O_CLOEXEC, mode)
  try:
    info = os.fstat(fd)
    if info.st_uid != os.geteuid():
      raise RuntimeError(f"{path} is not owned by you (uid {info.st_uid})")
    if (info.st_mode & 0o777) != mode:
      try:
        os.fchmod(fd, mode)
      except OSError:
        pass
    return fd
  except Exception:
    os.close(fd)
    raise


def write_atomic(path: Path, text: str, mode: int = 0o600) -> None:
  dfd = open_owned_dir(path.parent, fix_mode=0o700)
  try:
    token = secrets.token_hex(8)
    tmp_name = f".{path.name}.tmp.{token}"
    fd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, mode, dir_fd=dfd)
    try:
      os.fchmod(fd, mode)
      payload = text.encode("utf-8")
      written = 0
      while written < len(payload):
        chunk = os.write(fd, payload[written:])
        if chunk == 0:
          raise OSError("zero-byte write")
        written += chunk
      os.fsync(fd)
    finally:
      os.close(fd)
    try:
      os.replace(tmp_name, path.name, src_dir_fd=dfd, dst_dir_fd=dfd)
    except Exception:
      _unlink_quiet(tmp_name, dfd)
      raise
  finally:
    os.close(dfd)


def write_json(path: Path, payload: Any) -> None:
  write_atomic(path, json.dumps(payload, indent=2, sort_keys=True) + "\n")


# ---- what is kept on disk
#
# A selection is folders to keep (any depth: "Work", "Work/2026/Reports"),
# folders left out of them ("Work/Videos": the rest of Work syncs), and
# whether the loose files at the top sync. Loose files are off unless you
# turn them on: a fresh account syncs nothing until you choose.
#
# The deepest rule on a path decides it: kept under a kept folder, left out
# under a left-out one. A left-out folder can't keep a folder of its own
# (rclone doesn't look inside an excluded folder), so normalise_selection
# drops such rules, and every rule under a path is dropped when that path is
# switched as a whole.

MAX_PATH_DEPTH = 32


def clean_cloud_path(value: object) -> str:
  return "/".join(part for part in str(value or "").strip().strip("/").split("/") if part != "")


def valid_cloud_path(value: object) -> bool:
  if not isinstance(value, str) or value == "":
    return False
  parts = value.split("/")
  return len(parts) <= MAX_PATH_DEPTH and all(valid_drive_name(part) for part in parts)


def at_or_under(path: str, ancestor: str) -> bool:
  return path == ancestor or path.startswith(ancestor + "/")


def strictly_under(path: str, ancestor: str) -> bool:
  return path.startswith(ancestor + "/")


def rule_for(selection: dict[str, Any], path: str) -> str:
  """The deepest rule at or above path: "+" kept, "-" left out, "" none."""
  best, depth = "", -1
  for sign, key in (("+", "folders"), ("-", "excludes")):
    for rule in selection[key]:
      if at_or_under(path, rule) and rule.count("/") > depth:
        best, depth = sign, rule.count("/")
  return best


def is_covered(selection: dict[str, Any], path: str) -> bool:
  return rule_for(selection, path) == "+"


def has_rules_beneath(selection: dict[str, Any], path: str) -> bool:
  return any(strictly_under(rule, path) for rule in selection["folders"] + selection["excludes"])


def path_state(selection: dict[str, Any], path: str) -> str:
  """on (all of it syncs), off (none of it), partial (some of it)."""
  if has_rules_beneath(selection, path):
    return "partial"
  return "on" if is_covered(selection, path) else "off"


def normalise_selection(selection: dict[str, Any]) -> dict[str, Any]:
  def cleaned(values: object) -> list[str]:
    out = {clean_cloud_path(v) for v in (values if isinstance(values, list) else []) if isinstance(v, str)}
    return sorted((v for v in out if valid_cloud_path(v)), key=lambda v: (v.count("/"), v.casefold()))
  includes: list[str] = []
  for path in cleaned(selection.get("folders")):
    if not any(at_or_under(path, kept) for kept in includes):
      includes.append(path)
  excludes: list[str] = []
  for path in cleaned(selection.get("excludes")):
    if any(strictly_under(path, kept) for kept in includes) and not any(at_or_under(path, out) for out in excludes):
      excludes.append(path)
  includes = [path for path in includes if not any(strictly_under(path, out) for out in excludes)]
  return {
    "folders": sorted(includes, key=str.casefold),
    "excludes": sorted(excludes, key=str.casefold),
    "rootFiles": selection.get("rootFiles") is True,
  }


def drop_beneath(selection: dict[str, Any], path: str) -> None:
  selection["folders"] = [rule for rule in selection["folders"] if not strictly_under(rule, path)]
  selection["excludes"] = [rule for rule in selection["excludes"] if not strictly_under(rule, path)]


def keep_path(selection: dict[str, Any], path: str) -> None:
  drop_beneath(selection, path)
  selection["excludes"] = [rule for rule in selection["excludes"] if rule != path]
  if not is_covered(selection, path):
    selection["folders"].append(path)


def leave_out_path(selection: dict[str, Any], path: str) -> None:
  drop_beneath(selection, path)
  if path in selection["folders"]:
    selection["folders"].remove(path)
  if is_covered(selection, path):
    selection["excludes"].append(path)


def toggle_path(selection: dict[str, Any], path: str) -> None:
  # A partly kept folder is kept whole by a click, unless it was kept and
  # had parts left out: then the click leaves it out.
  if is_covered(selection, path):
    leave_out_path(selection, path)
  else:
    keep_path(selection, path)


def load_selection(paths: dict[str, Any]) -> dict[str, Any]:
  data = read_json(paths["selection_path"], {})
  if not isinstance(data, dict):
    data = {}
  return normalise_selection(data)


def save_selection(paths: dict[str, Any], selection: dict[str, Any]) -> None:
  write_json(paths["selection_path"], normalise_selection(selection))


def build_filters(selection: dict[str, Any]) -> str:
  selection = normalise_selection(selection)
  lines = [
    "# Generated by Omarchy Storage Drives. Edit selection in panel.",
    "- /Personal Vault/**",
  ]
  # The deepest rule first: rclone takes the first rule that matches.
  rules = [("-", path) for path in selection["excludes"]] + [("+", path) for path in selection["folders"]]
  rules.sort(key=lambda rule: (-rule[1].count("/"), rule[1].casefold()))
  for sign, path in rules:
    lines.append(sign + " /" + escape_glob(path) + "/**")
  if selection["rootFiles"]:
    lines.append("+ /*")
  lines.append("- **")
  return "\n".join(lines) + "\n"


def sync_filters_file(paths: dict[str, Any], selection: dict[str, Any]) -> bool:
  desired = build_filters(selection)
  try:
    current = paths["filters_path"].read_text(encoding="utf-8")
  except OSError:
    current = ""
  if current == desired:
    return False
  write_atomic(paths["filters_path"], desired)
  return True


def load_state(paths: dict[str, Any]) -> dict[str, Any]:
  data = read_json(paths["state_path"], {})
  return data if isinstance(data, dict) else {}


def patch_state(paths: dict[str, Any], **fields: Any) -> dict[str, Any]:
  state = load_state(paths)
  state.update(fields)
  write_json(paths["state_path"], state)
  return state


def service_active(service_name: str) -> bool:
  code, out, _ = run(["systemctl", "--user", "is-active", service_name], timeout=6)
  return code == 0 and out.strip() in ("active", "activating")


def systemd_quote(value: str) -> str:
  escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$")
  return '"' + escaped + '"'


def unit_sources(remote: str, folder: Path, mount: Path) -> dict[str, str]:
  paths = remote_paths(remote)
  helper = systemd_quote(str(Path(__file__).resolve()))
  python = "/usr/bin/python3" if Path("/usr/bin/python3").exists() else (shutil.which("python3") or "/usr/bin/python3")
  slug = paths["slug"]

  return {
    paths["service_name"]: f"""[Unit]
Description=Omarchy Storage Drives sync ({remote}) (rclone bisync)
Documentation=https://rclone.org/bisync/

[Service]
Type=oneshot
ExecStart={python} {helper} run --remote {systemd_quote(remote)} --folder {systemd_quote(str(folder))}
TimeoutStartSec=7200
Nice=10
IOSchedulingClass=idle
""",
    paths["timer_name"]: f"""[Unit]
Description=Sync Omarchy Storage Drive ({remote})

[Timer]
OnBootSec=2min
OnUnitInactiveSec=10min
AccuracySec=30s
Unit={paths["service_name"]}

[Install]
WantedBy=timers.target
""",
    paths["browse_service_name"]: f"""[Unit]
Description=Omarchy Storage Drive browse mount ({remote})
Documentation=https://rclone.org/commands/rclone_mount/

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart={python} {helper} mount --remote {systemd_quote(remote)} --mount {systemd_quote(str(mount))}
ExecStop={python} {helper} unmount --remote {systemd_quote(remote)} --mount {systemd_quote(str(mount))}
TimeoutStartSec=180

[Install]
WantedBy=default.target
""",
  }


def ensure_units(remote: str, folder: Path, mount: Path) -> bool:
  changed = False
  for name, text in unit_sources(remote, folder, mount).items():
    path = UNIT_DIR / name
    try:
      current = path.read_text(encoding="utf-8")
    except OSError:
      current = ""
    if current != text:
      write_atomic(path, text, mode=0o644)
      changed = True
  if changed:
    run(["systemctl", "--user", "daemon-reload"], timeout=30)
  rclone = rclone_bin()
  label = get_account_display_label(rclone, remote)
  # A bookmark to a folder that does not exist shows in the file manager's
  # sidebar and cannot be opened, which is what every new account used to
  # get until its first sync created the folder.
  if ensure_sync_folder(remote, folder):
    add_gtk_bookmark(folder, f"{label} (Offline Sync)")
  else:
    remove_gtk_bookmark(folder)
  return changed


def ensure_sync_folder(remote: str, folder: Path) -> bool:
  """Create an account's sync folder if it has never synced; True if it exists.

  Same rule as do_run: before the first baseline an empty folder is the
  correct starting state. After it, a missing folder means it was moved or
  deleted, and quietly recreating it would set up a sync that reads as
  "delete everything in the cloud" — so it is left missing for the panel to
  report."""
  if folder.is_dir():
    return True
  if folder.exists() or load_state(remote_paths(remote)).get("baseline") is True:
    return False
  try:
    open_owned_dir_close(folder)
  except (OSError, RuntimeError):
    return False
  return folder.is_dir()


GTK_BOOKMARKS_FILE = Path.home() / ".config" / "gtk-3.0" / "bookmarks"


def get_account_display_label(rclone: str | None, remote: str) -> str:
  provider_names = {
    "drive": "Google Drive",
    "onedrive": "OneDrive",
    "mega": "Mega",
    "dropbox": "Dropbox",
    "box": "Box",
    "webdav": "Nextcloud",
    "pcloud": "pCloud",
  }
  try:
    conf_path = rclone_conf_path(rclone)
    if conf_path.exists():
      cparser = configparser.ConfigParser()
      cparser.read(str(conf_path))
      rtype = cparser.get(remote, "type", fallback="")
      base = provider_names.get(rtype, remote.capitalize())
      if remote.lower() in ("gdrive", "drive", "onedrive", "mega", "dropbox", "box"):
        return base
      return f"{base} ({remote})"
  except Exception:
    pass
  return remote.capitalize()


def add_gtk_bookmark(folder_path: Path, label: str) -> None:
  try:
    folder_url = folder_path.resolve().as_uri()
    GTK_BOOKMARKS_FILE.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    if GTK_BOOKMARKS_FILE.exists():
      lines = GTK_BOOKMARKS_FILE.read_text(encoding="utf-8").splitlines()
    filtered = [l for l in lines if not l.startswith(folder_url + " ") and l != folder_url]
    entry = f"{folder_url} {label}" if label else folder_url
    filtered.append(entry)
    GTK_BOOKMARKS_FILE.write_text("\n".join(filtered) + "\n", encoding="utf-8")
  except Exception:
    pass


def remove_gtk_bookmark(folder_path: Path) -> None:
  try:
    if not GTK_BOOKMARKS_FILE.exists():
      return
    folder_url = folder_path.resolve().as_uri()
    lines = GTK_BOOKMARKS_FILE.read_text(encoding="utf-8").splitlines()
    filtered = [l for l in lines if not l.startswith(folder_url + " ") and l != folder_url]
    if len(filtered) != len(lines):
      GTK_BOOKMARKS_FILE.write_text(("\n".join(filtered) + "\n") if filtered else "", encoding="utf-8")
  except Exception:
    pass


def rclone_conf_path(rclone: str | None = None) -> Path:
  if rclone:
    code, out, _ = run([rclone, "config", "file"], timeout=4)
    if code == 0 and out:
      for line in out.splitlines():
        p = Path(line.strip())
        if p.exists() or p.name.endswith(".conf"):
          return p
  return Path.home() / ".config" / "rclone" / "rclone.conf"


def is_remote_authenticated(rclone: str, remote: str, rtype: str) -> bool:
  try:
    conf_path = rclone_conf_path(rclone)
    if not conf_path.exists():
      return False
    cparser = configparser.ConfigParser()
    cparser.read(str(conf_path))
    if remote not in cparser:
      return False
    section = cparser[remote]
    if rtype in ("drive", "onedrive", "dropbox", "box"):
      token = section.get("token", "").strip()
      return bool(token and token != "{}")
    if rtype == "mega":
      return bool(section.get("user", "").strip() and section.get("pass", "").strip())
    return bool(section.get("type", "").strip())
  except Exception:
    return False


def unit_enabled(unit: str) -> bool:
  _, out, _ = run(["systemctl", "--user", "is-enabled", unit], timeout=6)
  return out.strip() in ("enabled", "enabled-runtime")


def timer_enabled(timer_name: str) -> bool:
  return unit_enabled(timer_name)


def ensure_onedrive_drive_id(rclone: str, remote: str) -> bool:
  conf_path = rclone_conf_path(rclone)
  if not conf_path.exists():
    return False

  try:
    cparser = configparser.ConfigParser()
    cparser.read(str(conf_path))
    if remote not in cparser or cparser[remote].get("type") != "onedrive":
      return False

    drive_id = cparser[remote].get("drive_id", "")
    if drive_id and not drive_id.startswith("b!"):
      return True

    token_str = cparser[remote].get("token", "")
    if not token_str:
      return False
    token = json.loads(token_str)
    access_token = token.get("access_token")
    if not access_token:
      return False

    req = urllib.request.Request("https://graph.microsoft.com/v1.0/me/drives", headers={
      "Authorization": f"Bearer {access_token}"
    })
    with urllib.request.urlopen(req, timeout=6) as resp:
      data = json.loads(resp.read().decode())

    candidates = data.get("value", [])
    valid_id = None
    valid_type = "personal"

    for d in candidates:
      d_id = str(d.get("id") or "")
      d_name = str(d.get("name") or "")
      d_type = str(d.get("driveType") or "personal")
      if d_id.startswith("b!"):
        continue
      if d_name.lower() == "onedrive" or str(d.get("webUrl") or "").endswith("/Documents"):
        valid_id = d_id
        valid_type = d_type
        break

    if not valid_id:
      for d in candidates:
        d_id = str(d.get("id") or "")
        d_name = str(d.get("name") or "")
        d_type = str(d.get("driveType") or "personal")
        if not d_id.startswith("b!") and "metadata" not in d_name.lower():
          valid_id = d_id
          valid_type = d_type
          break

    if not valid_id:
      return False

    cparser[remote]["drive_id"] = valid_id
    cparser[remote]["drive_type"] = valid_type
    with open(conf_path, "w") as f:
      cparser.write(f)
    return True
  except Exception:
    return False


def configured_remotes(rclone: str) -> tuple[dict[str, str], str]:
  code, out, err = run([rclone, "listremotes", "--long"], timeout=15)
  if code != 0:
    return {}, clean_text(err or out or "Could not list rclone remotes")
  remotes: dict[str, str] = {}
  for line in out.splitlines():
    line = line.strip()
    if not line or ":" not in line:
      continue
    parts = line.split(None, 1)
    name = parts[0].rstrip(":")
    rtype = parts[1].strip() if len(parts) > 1 else ""
    remotes[name] = rtype
    if rtype == "onedrive":
      ensure_onedrive_drive_id(rclone, name)
  return remotes, ""


def remote_folders(rclone: str, remote: str, path: str = "") -> tuple[list[str], str]:
  names: list[str] = []
  dropped = 0
  try:
    with Child([rclone, "lsjson", f"{remote}:{path}", "--dirs-only", "--no-modtime"],
               timeout=90, max_stdout=MAX_LIST_BYTES) as child:
      try:
        for row in iter_json_array(child.chunks()):
          name = row.get("Name") if isinstance(row, dict) else None
          if valid_drive_name(name):
            names.append(name)
          else:
            dropped += 1
      except ListingUnreadable:
        return [], clean_text(child.failure() or "rclone returned an unreadable folder listing")
      if child.returncode != 0:
        return [], clean_text(child.stderr_text() or f"Could not list folders for {remote}")
  except ListingTooLarge:
    return [], f"{remote}:{path} has more than {MAX_LIST_ENTRIES} folders"
  except ChildTimeout:
    return [], f"Listing folders for {remote} timed out"
  except ChildOutputTooLarge:
    return [], f"Folder listing for {remote} is too large"
  except OSError as error:
    return [], clean_text(str(error))
  return sorted(names, key=str.casefold), ""


def remote_root_files(rclone: str, remote: str) -> tuple[int, int, str]:
  code, out, err = run([rclone, "size", f"{remote}:", "--json", "--filter", "+ /*", "--filter", "- **"],
                       timeout=90, max_stdout=65536)
  if code != 0:
    return 0, 0, clean_text(err or out or "Could not count root files")
  try:
    data = json.loads(out or "{}", parse_constant=lambda _: None)
  except ValueError:
    return 0, 0, "rclone returned unreadable root file count"
  if not isinstance(data, dict):
    return 0, 0, "rclone returned unreadable root file count"
  return clamp_int(data.get("count")), clamp_int(data.get("bytes")), ""


def load_cache(paths: dict[str, Any]) -> dict[str, Any]:
  data = read_json(paths["cache_path"], {})
  return data if isinstance(data, dict) else {}


def save_cache(paths: dict[str, Any], cache: dict[str, Any]) -> None:
  if cache != load_cache(paths):
    write_json(paths["cache_path"], cache)


def storage_usage(rclone: str, remote: str, cache: dict[str, Any] | None = None) -> tuple[int, int, bool, str]:
  entry = (cache or {}).get("about")
  if isinstance(entry, dict) and entry.get("remote") == remote and time.time() - clamp_int(entry.get("ts")) < ABOUT_CACHE_SECONDS:
    return (clamp_int(entry.get("used")), clamp_int(entry.get("total")),
            entry.get("known") is True, str(entry.get("warning") or ""))
  code, out, err = run([rclone, "about", f"{remote}:", "--json"], timeout=25, max_stdout=65536)
  used = total = 0
  warning = ""
  if code != 0:
    warning = clean_text(err or out or "Storage usage is unavailable")
  else:
    try:
      data = json.loads(out or "{}", parse_constant=lambda _: None)
    except ValueError:
      data = None
    if not isinstance(data, dict):
      warning = "rclone returned invalid storage information"
    else:
      total = clamp_int(data.get("total"))
      used_value = data.get("used")
      if used_value is None and total > 0 and data.get("free") is not None:
        used_value = total - clamp_int(data.get("free"))
      used = clamp_int(used_value)
  known = total > 0
  if cache is not None:
    cache["about"] = {"remote": remote, "used": used, "total": total, "known": known, "warning": warning, "ts": int(time.time())}
  return used, total, known, warning


def remote_token(rclone: str, remote: str) -> dict[str, Any]:
  try:
    conf_path = rclone_conf_path(rclone)
    if not conf_path.exists():
      return {}
    cparser = configparser.ConfigParser()
    cparser.read(str(conf_path))
    if remote not in cparser:
      return {}
    token_str = cparser[remote].get("token", "{}")
    return json.loads(token_str) if token_str else {}
  except Exception:
    return {}


def user_identity(rclone: str, remote: str, rtype: str, cache: dict[str, Any] | None = None) -> dict[str, str]:
  entry = (cache or {}).get("identity")
  if isinstance(entry, dict) and entry.get("remote") == remote:
    age = time.time() - clamp_int(entry.get("ts"))
    if (entry.get("email") and age < 3600) or age < 300:
      return {"email": str(entry.get("email") or ""), "name": str(entry.get("name") or "")}

  email = ""
  name = ""
  try:
    code, out, _ = run([rclone, "config", "userinfo", f"{remote}:", "--json"], timeout=6)
    if code == 0 and out:
      data = json.loads(out)
      email = str(data.get("userPrincipalName") or data.get("email") or data.get("mail") or "")
      name = str(data.get("displayName") or data.get("name") or "")
  except Exception:
    pass

  token = remote_token(rclone, remote) if not email else {}
  access_token = token.get("access_token")

  if not email and rtype == "drive" and access_token:
    try:
      req = urllib.request.Request("https://www.googleapis.com/drive/v3/about?fields=user", headers={
        "Authorization": f"Bearer {access_token}"
      })
      with urllib.request.urlopen(req, timeout=4) as resp:
        info = json.loads(resp.read().decode())
        u = info.get("user", {})
        email = str(u.get("emailAddress") or "")
        name = str(u.get("displayName") or "")
    except Exception:
      pass

  if not email and rtype == "onedrive" and access_token:
    try:
      req = urllib.request.Request("https://graph.microsoft.com/v1.0/me/drives", headers={
        "Authorization": f"Bearer {access_token}"
      })
      with urllib.request.urlopen(req, timeout=5) as resp:
        info = json.loads(resp.read().decode())
        for d in info.get("value", []):
          u = d.get("owner", {}).get("user", {})
          if u.get("email"):
            email = str(u.get("email") or "")
            name = str(u.get("displayName") or "")
            break
    except Exception:
      pass

  # rclone has no userinfo for Dropbox, so the account card showed a folder
  # path where every other provider shows an email. Dropbox's own API answers
  # with the token rclone already holds.
  if not email and rtype == "dropbox" and access_token:
    try:
      req = urllib.request.Request("https://api.dropboxapi.com/2/users/get_current_account",
                                   data=b"null", method="POST", headers={
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
      })
      with urllib.request.urlopen(req, timeout=5) as resp:
        info = json.loads(resp.read(MAX_ITEM_BYTES).decode())
        email = str(info.get("email") or "")
        name = str((info.get("name") or {}).get("display_name") or "")
    except Exception:
      pass

  result = {"email": email, "name": name}
  if cache is not None:
    cache["identity"] = {"remote": remote, "email": email, "name": name, "ts": int(time.time())}
  return result


class WalkBudget:
  def __init__(self, max_entries: int | None = None, max_seconds: float | None = None):
    self.remaining = MAX_WALK_ENTRIES if max_entries is None else max_entries
    self.deadline = time.monotonic() + (MAX_WALK_SECONDS if max_seconds is None else max_seconds)
    self.exhausted = False

  def spend(self) -> bool:
    if self.exhausted:
      return False
    self.remaining -= 1
    if self.remaining < 0 or time.monotonic() > self.deadline:
      self.exhausted = True
      return False
    return True


def directory_bytes(path: Path, budget: WalkBudget | None = None) -> tuple[int, bool]:
  budget = budget or WalkBudget()
  total = 0
  stack = [path]
  while stack and not budget.exhausted:
    current = stack.pop()
    try:
      scan = os.scandir(current)
    except OSError:
      continue
    with scan:
      for entry in scan:
        if not budget.spend():
          break
        try:
          if entry.is_dir(follow_symlinks=False):
            stack.append(Path(entry.path))
          elif entry.is_file(follow_symlinks=False):
            total += entry.stat(follow_symlinks=False).st_size
        except OSError:
          continue
  return total, budget.exhausted


def local_top_level(folder: Path) -> tuple[dict[str, int], bool]:
  sizes: dict[str, int] = {}
  approx = False
  deadline = time.monotonic() + MAX_WALK_SECONDS
  try:
    entries = list(os.scandir(folder))
  except OSError:
    return sizes, False
  for entry in entries:
    if entry.name in SKIP_LOCAL or not valid_drive_name(entry.name):
      continue
    try:
      if entry.is_dir(follow_symlinks=False):
        budget = WalkBudget(max_entries=MAX_WALK_ENTRIES, max_seconds=max(0.05, deadline - time.monotonic()))
        sizes[entry.name], cut = directory_bytes(Path(entry.path), budget)
        approx = approx or cut
    except OSError:
      continue
  return sizes, approx


def local_stale(folder: Path, selection: dict[str, Any]) -> tuple[list[dict[str, Any]], bool]:
  """What is on disk but no longer synced: folders left out as a whole, and
  files in a folder that isn't kept (the top one included, unless its loose
  files sync). Kept folders are not walked, partly kept ones are."""
  out: list[dict[str, Any]] = []
  budget = WalkBudget()
  approx = False

  def walk(rel: str) -> None:
    nonlocal approx
    try:
      entries = list(os.scandir(folder / rel if rel else folder))
    except OSError:
      return
    files_sync = selection["rootFiles"] if not rel else is_covered(selection, rel)
    for entry in entries:
      if budget.exhausted:
        approx = True
        return
      if (not rel and entry.name in SKIP_LOCAL) or not valid_drive_name(entry.name):
        continue
      path = rel + "/" + entry.name if rel else entry.name
      try:
        if entry.is_dir(follow_symlinks=False):
          state = path_state(selection, path)
          if state == "partial":
            walk(path)
          elif state == "off":
            size, cut = directory_bytes(Path(entry.path), budget)
            approx = approx or cut
            out.append({"path": path, "dir": True, "bytes": size})
        elif not files_sync:
          out.append({"path": path, "dir": False, "bytes": entry.stat(follow_symlinks=False).st_size})
      except OSError:
        continue

  walk("")
  return out, approx


def path_is_live(path: Path) -> bool:
  try:
    os.stat(path)
    return True
  except OSError as error:
    return error.errno not in (errno.ENOTCONN, errno.EIO, errno.EREMOTEIO)


def mount_info(path: Path) -> tuple[bool, bool, str, bool]:
  findmnt = shutil.which("findmnt")
  if not findmnt:
    return False, False, "", True
  code, out, _ = run([findmnt, "-rn", "-M", str(path), "-o", "FSTYPE"], timeout=8)
  if code != 0 or not out:
    return False, False, "", True
  fs_type = out.splitlines()[0].split()[0]
  by_rclone = "rclone" in fs_type.lower()
  return True, by_rclone, fs_type, path_is_live(path) if by_rclone else True


def mount_source(path: Path) -> str:
  """SOURCE of the mount at exactly `path` ("gdrive:"), or "" if none."""
  findmnt = shutil.which("findmnt")
  if not findmnt:
    return ""
  code, out, _ = run([findmnt, "-n", "-M", str(path), "-o", "SOURCE"], timeout=8)
  if code != 0 or not out:
    return ""
  return out.splitlines()[0].strip()


def mounted_remote(path: Path) -> str:
  """Remote name ("gdrive") serving an rclone mount at `path`, or ""."""
  source = mount_source(path)
  return source.split(":", 1)[0] if ":" in source else ""


def browse_owned_by(path: Path, remote: str) -> bool:
  """An rclone mount at `path` counts as this remote's browse view only if it
  is serving this remote. Two accounts pointed at the same folder used to
  share one mount: the second reported itself mounted while showing the first
  account's files, and removing it unmounted the first."""
  return mounted_remote(path) == remote


def detach_stale_mount(path: Path) -> bool:
  fusermount = shutil.which("fusermount3") or shutil.which("fusermount")
  if not fusermount:
    return False
  return run([fusermount, "-uz", str(path)], timeout=15)[0] == 0


def mount_browse(remote: str, mount_path: Path) -> None:
  rclone = rclone_bin()
  if not rclone:
    raise RuntimeError("rclone is not installed")
  remotes, error = configured_remotes(rclone)
  if error:
    raise RuntimeError(error)
  if remote not in remotes:
    raise RuntimeError(f"rclone remote '{remote}' is not configured")

  mounted, by_rclone, fs_type, alive = mount_info(mount_path)
  if by_rclone and not browse_owned_by(mount_path, remote):
    other = mounted_remote(mount_path) or "another remote"
    raise RuntimeError(f"{mount_path} is already the browse folder for '{other}'; give '{remote}' its own path")
  if by_rclone and alive:
    label = get_account_display_label(rclone, remote)
    add_gtk_bookmark(mount_path, f"{label} (Cloud)")
    return
  if by_rclone and not alive:
    detach_stale_mount(mount_path)
    mounted, by_rclone, fs_type, alive = mount_info(mount_path)
  if mounted and not by_rclone:
    raise RuntimeError(f"{mount_path} is already mounted as {fs_type}")

  mount_fd = open_owned_dir(mount_path)
  try:
    with os.scandir(mount_fd) as scan:
      entries = [entry.name for entry in scan if not entry.name.startswith(".")]
      if entries:
        raise RuntimeError(f"Browse folder is not empty: {mount_path}")
  finally:
    os.close(mount_fd)

  paths = remote_paths(remote)
  rotate_log(paths["mount_log_path"])
  label = get_account_display_label(rclone, remote)
  display_name = f"{label} (Cloud)"

  rtype = remotes.get(remote, "")
  command = [
    rclone, "mount", f"{remote}:", str(mount_path),
    "--daemon",
    "--read-only",
    "-o", "x-gvfs-show",
    "-o", f"x-gvfs-name={display_name}",
    "--vfs-cache-mode", "full",
    "--vfs-cache-max-age", "6h",
    "--vfs-cache-max-size", "2G",
    "--vfs-read-chunk-size", "128M",
    "--vfs-read-chunk-size-limit", "1G",
    "--dir-cache-time", "5m",
    "--poll-interval", "1m",
    "--log-file", str(paths["mount_log_path"]),
    "--log-level", "NOTICE",
  ]
  if rtype == "drive":
    command.append("--drive-acknowledge-abuse")
  try:
    subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
  except OSError as error:
    raise RuntimeError(f"Could not start rclone mount: {error}") from error

  deadline = time.monotonic() + 20
  while time.monotonic() < deadline:
    state = mount_info(mount_path)
    if state[1] and state[3]:
      add_gtk_bookmark(mount_path, display_name)
      return
    time.sleep(0.4)
  raise RuntimeError("rclone started but browse mount did not appear")


def unmount_browse(mount_path: Path, remote: str = "") -> None:
  mounted, by_rclone, fs_type, _ = mount_info(mount_path)
  if not mounted:
    remove_gtk_bookmark(mount_path)
    return
  if not by_rclone:
    raise RuntimeError(f"Refusing to unmount {mount_path}; it is {fs_type}, not rclone")
  # Never take down another account's mount that happens to sit on this path.
  if remote and not browse_owned_by(mount_path, remote):
    return
  fusermount = shutil.which("fusermount3") or shutil.which("fusermount")
  if not fusermount:
    raise RuntimeError("fusermount is not installed")
  code, out, err = run([fusermount, "-u", str(mount_path)], timeout=15)
  if code != 0:
    code, out, err = run([fusermount, "-uz", str(mount_path)], timeout=15)
  if code != 0:
    raise RuntimeError(clean_text(err or out or "Could not unmount browse folder"))
  remove_gtk_bookmark(mount_path)


# The sync status any file manager can read: Flea draws it as a badge, the Nautilus extension as an
# emblem. A neutral name, so a reader never has to know which app synced the folder.
STATUS_XATTR = "user.sync.status"
LEGACY_XATTR = "user.terrace.sync"
SYNC_STATUSES = ("synced", "syncing", "partial", "conflict", "excluded")


def is_conflict_name(name: str) -> bool:
  """rclone bisync renames a conflict loser with a ".conflictN" part: notes.txt.conflict1."""
  return any(part.startswith("conflict") and part[8:].isdigit() or part == "conflict"
             for part in name.split(".")[1:])


def set_status_xattr(path: Path, status: str) -> bool:
  """Write the status only when it changed, so a file manager isn't sent an
  attribute event for every file on every sync. Symlinks can't hold user xattrs."""
  value = status.encode("utf-8")
  try:
    if os.getxattr(path, STATUS_XATTR, follow_symlinks=False) == value:
      return False
  except OSError:
    pass
  try:
    os.setxattr(path, STATUS_XATTR, value, follow_symlinks=False)
  except OSError:
    return False
  try:
    os.removexattr(path, LEGACY_XATTR, follow_symlinks=False)
  except OSError:
    pass
  return True


def tag_sync_path(path: Path, status: str) -> None:
  """Tag a file or folder with the status xattr, and a GIO emblem for file
  managers that read gvfs metadata. Status is one of SYNC_STATUSES."""
  if status not in SYNC_STATUSES or not path.exists() or not set_status_xattr(path, status):
    return

  emblem_map = {
    "synced": "emblem-default",          # Green circle with white check
    "syncing": "emblem-synchronizing",   # Blue rotating sync arrows
    "partial": "emblem-dropbox-selsync", # Grey selective sync badge
    "conflict": "emblem-important",      # Red exclamation warning
    "excluded": "emblem-shared",         # Cloud / shared
  }
  emblem = emblem_map.get(status, "")
  gio = shutil.which("gio")
  if gio and emblem:
    try:
      subprocess.run([gio, "set", "-t", "stringv", str(path), "metadata::emblems", emblem],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, timeout=2, check=False)
    except (OSError, subprocess.SubprocessError):
      pass


def tag_remote_tree(remote: str, folder: Path, selection: dict[str, Any], state: dict[str, Any]) -> None:
  """Tag every file and folder in the sync folder after a successful sync.

  Files: synced when the selection covers them, excluded when it doesn't,
  conflict for rclone's conflict copies. Folders: excluded (not descended),
  partial when only some of it syncs, synced otherwise, and conflict when a
  conflict sits anywhere beneath. Only the root and its top-level folders get
  a GIO emblem too: that costs a subprocess each, the xattr costs a syscall.
  """
  if not folder.is_dir():
    return
  selection = normalise_selection(selection)

  def walk(directory: Path, rel: str) -> bool:
    conflict = False
    try:
      with os.scandir(directory) as scan:
        entries = list(scan)
    except OSError:
      return False
    for entry in entries:
      if entry.is_symlink():
        continue
      child = f"{rel}/{entry.name}" if rel else entry.name
      if entry.is_dir(follow_symlinks=False):
        state_here = path_state(selection, child)
        if state_here == "off":
          status = "excluded"
        else:
          below = walk(Path(entry.path), child)
          conflict = conflict or below
          status = "conflict" if below else ("partial" if state_here == "partial" else "synced")
        (tag_sync_path if not rel else set_status_xattr)(Path(entry.path), status)
      else:
        covered = selection["rootFiles"] if not rel else is_covered(selection, child)
        if is_conflict_name(entry.name):
          status, conflict = "conflict", True
        else:
          status = "synced" if covered else "excluded"
        set_status_xattr(Path(entry.path), status)
    return conflict

  tag_sync_path(folder, "conflict" if walk(folder, "") else "synced")


def read_status_xattr(path: Path) -> str:
  try:
    return os.getxattr(path, STATUS_XATTR, follow_symlinks=False).decode("utf-8")
  except OSError:
    return ""


def untag_failed_sync(folder: Path, paths: dict[str, Any], root_tag: str) -> None:
  """A failed sync can't leave the root saying "syncing": an error needs the
  user (conflict), being offline doesn't, so the root keeps what it had."""
  if load_state(paths).get("lastResult") == "error":
    tag_sync_path(folder, "conflict")
  elif root_tag:
    tag_sync_path(folder, root_tag)
  else:
    try:
      os.removexattr(folder, STATUS_XATTR)
    except OSError:
      pass


def find_conflicts(folder: Path, max_find: int = 20) -> list[str]:
  if not folder.is_dir():
    return []
  conflicts: list[str] = []
  try:
    for root_dir, _, files in os.walk(folder):
      for f in files:
        if is_conflict_name(f):
          rel = str(Path(root_dir, f).relative_to(folder))
          conflicts.append(rel)
          if len(conflicts) >= max_find:
            return conflicts
  except OSError:
    pass
  return conflicts


def bisync_command(rclone: str, remote: str, folder: Path, resync: bool, rtype: str, paths: dict[str, Any]) -> list[str]:
  command = [
    rclone, "bisync", f"{remote}:", str(folder),
    "--filters-file", str(paths["filters_path"]),
    "--workdir", str(paths["workdir"]),
    "--create-empty-src-dirs",
    "--resilient",
    "--recover",
    "--fast-list",
    "--track-renames",
    "--force",
    "--transfers", "8",
    "--checkers", "16",
    "--use-json-log",
    "--stats", "1s",
    "--stats-file-name-length", "0",
    "--log-level", "INFO",
  ]
  if rtype == "drive":
    command += [
      "--drive-skip-gdocs",
      "--drive-acknowledge-abuse",
      "--tpslimit", "10",
      "--drive-pacer-min-sleep", "100ms",
    ]
  if rtype == "onedrive":
    command += ["--exclude", "/Personal Vault/**"]
  command += ["--resync", "--resync-mode", "newer"] if resync else ["--conflict-resolve", "newer"]
  return command


def stream_bisync(cmd: list[str], log_path: Path, paths: dict[str, Any], folder: Path, remote: str) -> tuple[int, str, str]:
  """Run bisync, streaming json logs line-by-line:
  - Formats human-readable logs to log_path for user viewing.
  - Updates state.json with activeTransfers and transferStats (throttled).
  - Tags transferred files as synced.
  - Returns (returncode, stdout, stderr).
  """
  proc = subprocess.Popen(
    cmd,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
    errors="replace"
  )

  recent_transfers: list[dict[str, Any]] = load_state(paths).get("recentTransfers", []) or []
  last_patch_ts = 0.0
  active_transfers: list[dict[str, Any]] = []
  transfer_stats: dict[str, Any] = {}
  err_lines: list[str] = []

  log_file = None
  try:
    log_fd = open_owned_file(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    log_file = open(log_fd, "a", encoding="utf-8")
  except Exception:
    pass

  try:
    assert proc.stderr is not None
    for raw_line in proc.stderr:
      line = raw_line.strip()
      if not line:
        continue

      try:
        obj = json.loads(line)
      except Exception:
        if log_file:
          log_file.write(line + "\n")
          log_file.flush()
        err_lines.append(line)
        continue

      lvl = str(obj.get("level", "info")).upper()
      t_str = str(obj.get("time", ""))[:19].replace("T", " ")
      msg = str(obj.get("msg", ""))
      src = str(obj.get("source", ""))
      obj_name = str(obj.get("object", ""))

      if log_file and msg:
        prefix = f"{t_str} {lvl:<7}: " if t_str else f"{lvl:<7}: "
        formatted = f"{prefix}{obj_name + ': ' if obj_name else ''}{msg}\n"
        log_file.write(formatted)
        log_file.flush()

      if lvl in ("ERROR", "NOTICE"):
        err_lines.append(f"{obj_name + ': ' if obj_name else ''}{msg}")

      stats = obj.get("stats")
      if isinstance(stats, dict):
        transferring = stats.get("transferring")
        if isinstance(transferring, list):
          active_transfers = [
            {
              "name": str(t.get("name", "")),
              "size": clamp_int(t.get("size")),
              "bytes": clamp_int(t.get("bytes")),
              "percentage": clamp_int(t.get("percentage")),
              "speed": clamp_int(t.get("speed")),
              "eta": clamp_int(t.get("eta")),
            }
            for t in transferring if isinstance(t, dict) and t.get("name")
          ]
        else:
          active_transfers = []

        transfer_stats = {
          "bytes": clamp_int(stats.get("bytes")),
          "totalBytes": clamp_int(stats.get("totalBytes")),
          "speed": clamp_int(stats.get("speed")),
          "transfers": clamp_int(stats.get("transfers")),
          "totalTransfers": clamp_int(stats.get("totalTransfers")),
          "checks": clamp_int(stats.get("checks")),
          "totalChecks": clamp_int(stats.get("totalChecks")),
          "elapsedTime": float(stats.get("elapsedTime", 0) or 0),
        }

      if obj_name and msg in ("Copied (new)", "Copied (replaced existing)", "Updated", "Deleted"):
        entry = {
          "name": obj_name,
          "action": msg,
          "size": clamp_int(obj.get("size")),
          "ts": int(time.time()),
        }
        recent_transfers = [entry] + [r for r in recent_transfers if r.get("name") != obj_name][:19]
        tag_sync_path(folder / obj_name, "synced")

      now = time.time()
      if now - last_patch_ts >= 1.5:
        patch_state(
          paths,
          activeTransfers=active_transfers,
          transferStats=transfer_stats,
          recentTransfers=recent_transfers,
        )
        last_patch_ts = now

    proc.wait(timeout=30)
  except Exception as ex:
    proc.kill()
    proc.wait()
    err_lines.append(str(ex))
  finally:
    if log_file:
      try:
        log_file.close()
      except Exception:
        pass

  patch_state(
    paths,
    activeTransfers=[],
    transferStats={},
    recentTransfers=recent_transfers,
  )
  return proc.returncode or 0, "", "\n".join(err_lines)


def bisync_running(paths: dict[str, Any]) -> bool:
  for entry in Path("/proc").iterdir():
    if not entry.name.isdigit():
      continue
    try:
      argv = (entry / "cmdline").read_bytes().split(b"\0")
    except OSError:
      continue
    if len(argv) >= 2 and argv[0].endswith(b"rclone") and argv[1] == b"bisync":
      if str(paths["workdir"]).encode("utf-8") in (entry / "cmdline").read_bytes():
        return True
  return False


def clear_stale_bisync_lock(paths: dict[str, Any]) -> bool:
  workdir = paths["workdir"]
  if not workdir.exists():
    return False
  dfd = open_owned_dir(workdir, fix_mode=0o700)
  try:
    with os.scandir(dfd) as scan:
      locks = [entry.name for entry in scan if entry.name.endswith(".lck") and entry.is_file(follow_symlinks=False)]
    if not locks or bisync_running(paths):
      return False
    for name in locks:
      _unlink_quiet(name, dfd)
  finally:
    os.close(dfd)
  return True


def do_run(remote_value: str, folder_value: str, resync: bool, again: int = 0) -> int:
  paths = remote_paths(normalize_remote(remote_value))
  used = build_filters(load_selection(paths))
  code = do_run_once(remote_value, folder_value, resync)
  # A selection changed while rclone ran applies only from the next run:
  # that run is now, rather than a timer tick away (twice at most).
  if code == 0 and again < 2 and build_filters(load_selection(paths)) != used:
    return do_run(remote_value, folder_value, False, again + 1)
  return code


def do_run_once(remote_value: str, folder_value: str, resync: bool) -> int:
  remote = normalize_remote(remote_value)
  folder = normalize_path(folder_value, "~/Cloud")
  paths = remote_paths(remote)
  rclone = rclone_bin()
  if not rclone:
    patch_state(paths, lastResult="error", lastError="rclone is not installed")
    return 1

  remotes, error = configured_remotes(rclone)
  if error or remote not in remotes:
    patch_state(paths, lastResult="error", lastError=error or f"Remote '{remote}' not configured")
    return 1

  rtype = remotes.get(remote, "")
  selection = load_selection(paths)
  sync_filters_file(paths, selection)

  # bisync aborts on a local folder that does not exist, which is exactly the
  # state of a freshly added account. Create it — but only before the first
  # baseline. Once a baseline exists, a missing folder means it was moved or
  # deleted, and syncing an empty folder against that baseline reads as
  # "delete everything in the cloud". Refuse instead.
  # A resync is the way out: it merges both sides and deletes nothing.
  if not folder.exists():
    if load_state(paths).get("baseline") is True and not resync:
      patch_state(paths, syncing=False, lastResult="error", finishedTs=int(time.time()),
                  lastError=f"Sync folder {folder} is missing. Restore it, or resync to start over.")
      return 1
    open_owned_dir_close(folder)

  paths["workdir"].mkdir(parents=True, exist_ok=True, mode=0o700)
  clear_stale_bisync_lock(paths)
  rotate_log(paths["log_path"])

  start_ts = int(time.time())
  previous = str(load_state(paths).get("lastResult") or "")
  patch_state(paths, syncing=True, startTs=start_ts)
  root_tag = read_status_xattr(folder)
  tag_sync_path(folder, "syncing")

  cmd = bisync_command(rclone, remote, folder, resync, rtype, paths)
  code, out, err = stream_bisync(cmd, paths["log_path"], paths, folder, remote)

  duration = time.time() - start_ts
  if code == 0:
    patch_state(paths, syncing=False, lastResult="ok", lastError="", finishedTs=int(time.time()),
                durationSec=round(duration, 1), baseline=True)
    tag_remote_tree(remote, folder, selection, load_state(paths))
    announce_recovery(remote, previous)
    return 0
  elif code in RCLONE_RESYNC_CODES:
    # Bisync requires a resync baseline run
    cmd_resync = bisync_command(rclone, remote, folder, True, rtype, paths)
    code2, out2, err2 = stream_bisync(cmd_resync, paths["log_path"], paths, folder, remote)
    duration2 = time.time() - start_ts
    if code2 == 0:
      patch_state(paths, syncing=False, lastResult="ok", lastError="", finishedTs=int(time.time()),
                  durationSec=round(duration2, 1), baseline=True)
      tag_remote_tree(remote, folder, selection, load_state(paths))
      announce_recovery(remote, previous)
      return 0
    else:
      record_failure(paths, remote, last_log_error(paths["log_path"]) or clean_text(err2 or out2 or "Resync failed"),
                     duration2, previous)
      untag_failed_sync(folder, paths, root_tag)
      return 1
  else:
    record_failure(paths, remote, last_log_error(paths["log_path"]) or clean_text(err or out or "Sync failed"),
                   duration, previous)
    untag_failed_sync(folder, paths, root_tag)
    return 1


# A sync that failed because the machine is offline is not a sync that failed:
# it is recorded as "offline" (the panel says "Waiting for network") and never
# notified, or every timer tick on a train would raise an alert.
NETWORK_ERRORS = re.compile(
  r"no such host|dial tcp|network is unreachable|connection refused|i/o timeout|"
  r"temporary failure in name resolution|tls handshake timeout|connection reset|"
  r"context deadline exceeded|couldn't connect|no route to host", re.I)


def is_network_error(reason: str) -> bool:
  return bool(NETWORK_ERRORS.search(reason or ""))


def notify(summary: str, body: str, critical: bool = False) -> None:
  """Best effort: syncs run from a systemd timer, with no panel open to show
  a failure, so a notification is the only way it is ever seen."""
  sender = shutil.which("omarchy-notification-send") or shutil.which("notify-send")
  if not sender:
    return
  command = [sender, "-u", "critical" if critical else "normal", clean_text(summary, 120), clean_text(body, 300)]
  try:
    subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=5, check=False)
  except (OSError, subprocess.TimeoutExpired):
    pass


def record_failure(paths: dict[str, Any], remote: str, reason: str, duration: float, previous: str) -> None:
  result = "offline" if is_network_error(reason) else "error"
  patch_state(paths, syncing=False, lastResult=result, lastError=reason,
              finishedTs=int(time.time()), durationSec=round(duration, 1))
  # Said once when it starts failing, not on every timer tick while it does.
  if result == "error" and previous != "error":
    notify(f"Cloud sync failed: {remote}", reason or "See the sync log in Storage Drives")


def announce_recovery(remote: str, previous: str) -> None:
  if previous == "error":
    notify(f"Cloud sync working again: {remote}", "The last sync finished cleanly.")


def open_owned_dir_close(path: Path) -> None:
  os.close(open_owned_dir(path))


LOG_ERROR = re.compile(r"\bERROR\s*:\s*(.+)$")


def last_log_error(log_path: Path) -> str:
  """The first real ERROR line of the latest run. rclone sends its reasons to
  the log file rather than stderr, so the panel used to say only "Resync
  failed" while the log said "directory not found". The first error is the
  cause; the ones after it are "bisync aborted" restating it."""
  text = tail_bytes(log_path, LOG_TAIL_BYTES)
  lines = text.splitlines()
  # Only the latest run: rclone starts each with a "Bisync" or "Synching" line.
  for i in range(len(lines) - 1, -1, -1):
    if "Synching Path1" in lines[i] or "Bisyncing" in lines[i] or "Starting bisync" in lines[i]:
      lines = lines[i:]
      break
  for line in lines:
    m = LOG_ERROR.search(ANSI.sub("", line))
    if m and "Bisync aborted" not in m.group(1) and "critical error" not in m.group(1):
      return clean_text(m.group(1), 240)
  for line in lines:
    m = LOG_ERROR.search(ANSI.sub("", line))
    if m:
      return clean_text(m.group(1), 240)
  return ""


# ---------------------------------------------------------------- payloads

def folders_payload(remote_value: str, folder_value: str, sub_path: str = "") -> dict[str, Any]:
  """The folders at the top (or inside sub_path), each on, off or partial."""
  remote = normalize_remote(remote_value)
  folder = normalize_path(folder_value, "~/Cloud")
  paths = remote_paths(remote)
  rclone = rclone_bin()
  selection = load_selection(paths)
  if not rclone:
    return {"ok": False, "folders": [], "lastError": "rclone is not installed"}
  base = clean_cloud_path(sub_path)
  if base and not valid_cloud_path(base):
    return {"ok": False, "folders": [], "lastError": "Folder path not allowed"}

  names, error = remote_folders(rclone, remote, base)
  if error:
    return {"ok": False, "folders": [], "lastError": error}

  local, approx = local_top_level(folder / base if base else folder)

  def row(name: str) -> dict[str, Any]:
    path = base + "/" + name if base else name
    state = path_state(selection, path)
    return {
      "name": name,
      "path": path,
      "state": state,
      "selected": state == "on",
      "partial": state == "partial",
      "covered": is_covered(selection, path),
      "localBytes": local.get(name, 0),
      "onDisk": name in local,
      "approx": approx,
    }

  rows = [row(name) for name in names]
  listed = {r["name"] for r in rows}
  # On disk only (deleted or renamed in the cloud, or made here and never
  # synced): shown so they can be cleaned up.
  extra = [dict(row(name), stale=True) for name in sorted(local, key=str.casefold) if name not in listed]
  payload: dict[str, Any] = {
    "ok": True,
    "path": base,
    "state": path_state(selection, base) if base else "",
    "covered": is_covered(selection, base) if base else False,
    "folders": rows + extra,
    "rootFiles": selection["rootFiles"],
    "lastError": "",
  }
  if not base:
    stale, stale_approx = local_stale(folder, selection)
    root_count, root_bytes, _ = remote_root_files(rclone, remote)
    payload.update({
      "rootFileCount": root_count,
      "rootFileBytes": root_bytes,
      "staleBytes": sum(item["bytes"] for item in stale),
      "staleCount": len(stale),
      "staleLooseFiles": sum(1 for item in stale if not item["dir"] and "/" not in item["path"]),
      "localBytesApprox": approx or stale_approx,
      "excludes": selection["excludes"],
      "kept": selection["folders"],
    })
  return payload


def status_payload(remote_value: str, folder_value: str, mount_value: str) -> dict[str, Any]:
  remote = normalize_remote(remote_value)
  folder = normalize_path(folder_value, "~/Cloud")
  mount_path = normalize_path(mount_value, "~/Cloud-Browse")
  paths = remote_paths(remote)
  rclone = rclone_bin()
  selection = load_selection(paths)
  state = load_state(paths)

  payload: dict[str, Any] = {
    "ok": True,
    "installed": rclone is not None,
    "authenticated": False,
    "remoteType": "",
    "accountEmail": "",
    "accountName": "",
    "syncing": False,
    "statusText": "Checking…",
    "folderPath": str(folder),
    "mountPath": str(mount_path),
    "remoteName": remote,
    "selectedCount": len(selection["folders"]),
    "excludedCount": len(selection["excludes"]),
    "rootFiles": selection["rootFiles"],
    "localBytes": 0,
    "localBytesApprox": False,
    "usedBytes": 0,
    "quotaBytes": 0,
    "usagePercent": 0,
    "quotaKnown": False,
    "browseMounted": False,
    "browseStale": False,
    "browseEnabled": False,
    "timerEnabled": False,
    "unitsInstalled": False,
    "lastResult": str(state.get("lastResult") or ""),
    "lastFinishedTs": int(state.get("finishedTs") or 0),
    "lastDurationSec": float(state.get("durationSec") or 0),
    "baseline": state.get("baseline") is True,
    "warning": "",
    "lastError": str(state.get("lastError") or ""),
    "browseConflict": "",
    "logPath": str(paths["log_path"]),
    "mountLogPath": str(paths["mount_log_path"]),
    "activeTransfers": state.get("activeTransfers", []) or [],
    "transferStats": state.get("transferStats", {}) or {},
    "recentTransfers": state.get("recentTransfers", []) or [],
    "conflictFiles": [],
    "conflictCount": 0,
  }

  if not rclone:
    payload["statusText"] = "rclone not installed"
    return payload

  remotes, config_error = configured_remotes(rclone)
  payload["remoteType"] = remotes.get(remote, "")
  payload["authenticated"] = (remote in remotes) and is_remote_authenticated(rclone, remote, payload["remoteType"])
  browse_state = mount_info(mount_path)
  owned = browse_state[1] and browse_owned_by(mount_path, remote)
  payload["browseMounted"] = owned and browse_state[3]
  payload["browseStale"] = owned and not browse_state[3]
  if browse_state[1] and not owned:
    payload["browseConflict"] = mounted_remote(mount_path)
  payload["browseEnabled"] = unit_enabled(paths["browse_service_name"])
  payload["timerEnabled"] = timer_enabled(paths["timer_name"])
  payload["unitsInstalled"] = (UNIT_DIR / paths["service_name"]).exists() and (UNIT_DIR / paths["timer_name"]).exists()
  payload["syncing"] = service_active(paths["service_name"]) or bisync_running(paths)

  if payload["authenticated"]:
    ensure_sync_folder(remote, folder)

  conflicts = find_conflicts(folder)
  payload["conflictFiles"] = conflicts
  payload["conflictCount"] = len(conflicts)
  if conflicts and not payload["warning"]:
    payload["warning"] = f"{len(conflicts)} conflicted files found"

  cache = load_cache(paths)
  cached = cache.get("localBytes") if isinstance(cache.get("localBytes"), dict) else None
  cache_ts = clamp_int(cached.get("ts")) if cached else 0
  sync_finished = int(state.get("finishedTs") or 0)
  cache_fresh = cached is not None and (time.time() - cache_ts < 300) and (cache_ts >= sync_finished)

  if payload["syncing"] and cached is not None:
    payload["localBytes"] = clamp_int(cached.get("bytes"))
    payload["localBytesApprox"] = True
  elif cache_fresh:
    payload["localBytes"] = clamp_int(cached.get("bytes"))
    payload["localBytesApprox"] = cached.get("approx", False) is True
  else:
    size, approx = directory_bytes(folder) if folder.is_dir() else (0, False)
    payload["localBytes"] = size
    payload["localBytesApprox"] = approx
    cache["localBytes"] = {"bytes": size, "approx": approx, "ts": int(time.time())}

  if config_error:
    payload["statusText"] = "Configuration error"
    payload["lastError"] = config_error
    return payload
  if not payload["authenticated"]:
    payload["statusText"] = "Not authenticated" if remote in remotes else "Not connected"
    return payload

  folder_mounted, _, fs_type, _ = mount_info(folder)
  if folder_mounted:
    payload["statusText"] = "Folder is mounted"
    payload["lastError"] = f"{folder} is mounted as {fs_type}; unmount it to sync into it"
    return payload

  if payload["syncing"]:
    entry = (cache or {}).get("about")
    if isinstance(entry, dict) and entry.get("remote") == remote:
      used = clamp_int(entry.get("used"))
      total = clamp_int(entry.get("total"))
      quota_known = entry.get("known") is True
      warning = str(entry.get("warning") or "")
    else:
      used = total = 0
      quota_known = False
      warning = ""
  else:
    used, total, quota_known, warning = storage_usage(rclone, remote, cache)
  payload.update(usedBytes=used, quotaBytes=total, quotaKnown=quota_known,
                 usagePercent=(used / total * 100) if total > 0 else 0, warning=warning)
  ident = user_identity(rclone, remote, payload["remoteType"], cache)
  payload["accountEmail"] = ident.get("email", "")
  payload["accountName"] = ident.get("name", "")
  try:
    save_cache(paths, cache)
  except (OSError, RuntimeError):
    pass

  if payload["syncing"]:
    payload["statusText"] = "Syncing…"
  elif payload["selectedCount"] == 0 and not selection["rootFiles"]:
    payload["statusText"] = "Nothing selected"
  elif payload["lastResult"] == "offline":
    payload["statusText"] = "Waiting for network"
  elif payload["lastResult"] == "error":
    payload["statusText"] = "Sync failed"
  elif payload["baseline"]:
    payload["statusText"] = "Synced"
  else:
    payload["statusText"] = "Ready to sync"
  return payload


def configured_accounts() -> list[dict[str, Any]]:
  """Discover configured accounts from Omarchy / Storage Drives state, or infer from remotes."""
  for store_path in (
    Path.home() / ".local" / "state" / "omarchy" / "cloud-drives.json",
    Path.home() / ".local" / "state" / "storage-drives" / "cloud-drives.json",
    STATE_BASE.parent / "omarchy" / "cloud-drives.json",
    STATE_BASE / "cloud-drives.json",
  ):
    if store_path.exists():
      data = read_json(store_path, {})
      if isinstance(data, dict) and isinstance(data.get("accounts"), list):
        return data["accounts"]
  rclone = rclone_bin()
  if rclone:
    remotes, _ = configured_remotes(rclone)
    accounts = []
    for r, rtype in remotes.items():
      guess_names = [f"~/{r}"]
      if rtype == "drive":
        guess_names.insert(0, "~/Google Drive")
      elif rtype == "onedrive":
        guess_names.insert(0, "~/OneDrive")
      elif rtype == "dropbox":
        guess_names.insert(0, "~/Dropbox")
      found = guess_names[0]
      for g in guess_names:
        if Path(g).expanduser().is_dir():
          found = g
          break
      accounts.append({"remoteName": r, "type": rtype, "folderPath": found})
    return accounts
  return []


def query_path(target_path: str, remote_hint: str = "", set_emblems: bool = False) -> dict[str, Any]:
  target = Path(target_path).expanduser().resolve()
  accounts = configured_accounts()

  matched_remote = ""
  matched_folder: Path | None = None
  matched_type = ""

  if remote_hint:
    r_clean = normalize_remote(remote_hint)
    for acc in accounts:
      if normalize_remote(acc.get("remoteName", "")) == r_clean:
        f = Path(normalize_path(acc.get("folderPath", "~/Cloud"), "~/Cloud")).resolve()
        matched_remote = r_clean
        matched_folder = f
        matched_type = str(acc.get("type", ""))
        break

  if not matched_folder:
    for acc in accounts:
      f = Path(normalize_path(acc.get("folderPath", "~/Cloud"), "~/Cloud")).resolve()
      if target == f or f in target.parents:
        matched_remote = normalize_remote(acc.get("remoteName", ""))
        matched_folder = f
        matched_type = str(acc.get("type", ""))
        break

  if not matched_folder:
    return {
      "ok": False,
      "managed": False,
      "path": str(target),
      "reason": "Path is not inside any managed cloud sync folder",
    }

  rel = target.relative_to(matched_folder).as_posix() if target != matched_folder else ""
  paths = remote_paths(matched_remote)
  selection = load_selection(paths)
  state = load_state(paths)
  is_syncing = state.get("syncing") is True
  active_transfers = state.get("activeTransfers", []) or []

  has_conflict = False
  if target.exists():
    if target.is_file():
      if ".conflict" in target.name:
        has_conflict = True
      else:
        has_conflict = any(target.parent.glob(f"{target.stem}.conflict*"))
    elif target.is_dir():
      has_conflict = any(target.glob("*.conflict*"))

  sel_state = path_state(selection, rel) if rel else "on"
  transferring = is_syncing and any(
    t.get("name") == rel or (rel and str(t.get("name", "")).startswith(rel + "/"))
    for t in active_transfers
  )

  if has_conflict:
    status = "conflict"
    emblem = "emblem-important"
  elif transferring:
    status = "syncing"
    emblem = "emblem-synchronizing"
  elif sel_state == "off":
    status = "excluded"
    emblem = "emblem-shared"
  elif sel_state == "partial":
    status = "partial"
    emblem = "emblem-dropbox-selsync"
  else:
    status = "synced"
    emblem = "emblem-default"

  if set_emblems and target.exists():
    tag_sync_path(target, status)

  return {
    "ok": True,
    "managed": True,
    "path": str(target),
    "remote": matched_remote,
    "remoteType": matched_type,
    "syncRoot": str(matched_folder),
    "relativePath": rel,
    "isDir": target.is_dir() if target.exists() else False,
    "exists": target.exists(),
    "status": status,
    "emblem": emblem,
    "selection": sel_state,
    "syncing": is_syncing,
    "transferring": transferring,
    "conflict": has_conflict,
    "lastSyncTs": int(state.get("finishedTs") or 0),
  }


def cmd_query(args: argparse.Namespace) -> None:
  print(json.dumps(query_path(args.path, remote_hint=args.remote or "", set_emblems=args.set_emblems)))


# ---------------------------------------------------------------- commands

def cmd_select(args: argparse.Namespace) -> None:
  remote = normalize_remote(args.remote)
  paths = remote_paths(remote)
  selection = load_selection(paths)

  def checked(value: str) -> str:
    path = clean_cloud_path(value)
    if not valid_cloud_path(path):
      raise ValueError(f"Folder path not allowed: {clean_text(value, 80)!r}")
    return path

  if args.set is not None:
    selection["folders"] = [checked(v) for v in args.set if v.strip()]
    selection["excludes"] = []
  for value in args.add or []:
    keep_path(selection, checked(value))
  for value in args.remove or []:
    leave_out_path(selection, checked(value))
  for value in args.toggle or []:
    toggle_path(selection, checked(value))
  if args.root_files is not None:
    selection["rootFiles"] = args.root_files
  selection = normalise_selection(selection)
  if len(selection["folders"]) + len(selection["excludes"]) > MAX_LIST_ENTRIES:
    raise ValueError(f"At most {MAX_LIST_ENTRIES} folders can be chosen")
  save_selection(paths, selection)
  sync_filters_file(paths, selection)
  print(json.dumps({"ok": True, "folders": selection["folders"], "excludes": selection["excludes"],
                    "rootFiles": selection["rootFiles"]}))


def trash_or_remove(path: Path) -> bool:
  gio = shutil.which("gio")
  if gio:
    code, _, _ = run([gio, "trash", str(path)], timeout=15)
    if code == 0:
      return True
  try:
    if path.is_dir() and not path.is_symlink():
      shutil.rmtree(path)
    else:
      path.unlink()
    return True
  except OSError:
    return False


def check_identical(rclone: str, local_dir: Path, remote_dir: str, names: list[str] | None) -> set[str]:
  """Which of names (or of everything under local_dir) the cloud holds
  byte for byte, as paths relative to local_dir."""
  command = [rclone, "check", str(local_dir), remote_dir, "--one-way", "--combined", "-", "--drive-acknowledge-abuse"]
  listing = None
  if names is not None:
    listing = tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".lst", delete=False)
    listing.write("\n".join(names) + "\n")
    listing.close()
    command += ["--files-from", listing.name]
  try:
    _, out, _ = run(command, timeout=600, max_stdout=MAX_LIST_BYTES)
  finally:
    if listing is not None:
      os.unlink(listing.name)
  return {line[2:] for line in (out or "").splitlines() if line.startswith("= ")}


def cmd_cleanup(args: argparse.Namespace) -> int:
  """Frees what is on disk but no longer synced, one item at a time, and
  only once the cloud is seen to hold the same bytes: a folder whose every
  file matches, a file that matches."""
  remote = normalize_remote(args.remote)
  folder = normalize_path(args.folder, "~/Cloud")
  paths = remote_paths(remote)
  rclone = rclone_bin()
  if not rclone:
    raise RuntimeError("rclone is not installed")

  selection = load_selection(paths)
  stale, _ = local_stale(folder, selection)
  if args.only:
    only = {clean_cloud_path(v) for v in args.only}
    stale = [item for item in stale if item["path"] in only]

  removed: list[str] = []
  freed = 0
  kept_back = 0
  files_by_dir: dict[str, list[dict[str, Any]]] = {}
  for item in stale:
    if item["dir"]:
      target = folder / item["path"]
      if not target.is_dir() or target.is_symlink():
        continue
      code, _, _ = run([rclone, "check", str(target), f"{remote}:{item['path']}", "--one-way", "--drive-acknowledge-abuse"], timeout=600)
      if code != 0:
        kept_back += 1
        continue
      if trash_or_remove(target):
        removed.append(item["path"])
        freed += item["bytes"]
      else:
        kept_back += 1
    else:
      parent = item["path"].rpartition("/")[0]
      files_by_dir.setdefault(parent, []).append(item)
  for parent, items in files_by_dir.items():
    local_dir = folder / parent if parent else folder
    same = check_identical(rclone, local_dir, f"{remote}:{parent}", [i["path"].rpartition("/")[2] for i in items])
    for item in items:
      name = item["path"].rpartition("/")[2]
      if name not in same:
        kept_back += 1
        continue
      if trash_or_remove(local_dir / name):
        removed.append(item["path"])
        freed += item["bytes"]
      else:
        kept_back += 1
  print(json.dumps({"ok": True, "removed": removed, "freedBytes": freed, "keptBack": kept_back}))
  return 0


def write_timer_interval(timer_name: str, minutes: int) -> None:
  value = max(1, min(1440, int(minutes)))
  write_atomic(
    UNIT_DIR / (timer_name + ".d") / "interval.conf",
    "# Generated by Omarchy Storage Drives.\n"
    "[Timer]\n"
    f"OnUnitInactiveSec={value}min\n",
    mode=0o644,
  )
  run(["systemctl", "--user", "daemon-reload"], timeout=25)


def units_from_args(args: argparse.Namespace) -> None:
  ensure_units(
    normalize_remote(args.remote),
    normalize_path(args.folder, "~/Cloud"),
    normalize_path(args.mount, "~/Cloud-Browse"),
  )


def cmd_browse(args: argparse.Namespace) -> None:
  remote = normalize_remote(args.remote)
  mount_path = normalize_path(args.mount, "~/Cloud-Browse")
  paths = remote_paths(remote)
  units_from_args(args)
  action = ["enable", "--now"] if args.enable else ["disable", "--now"]
  code, out, err = run(["systemctl", "--user", *action, paths["browse_service_name"]], timeout=25)
  if code != 0:
    raise RuntimeError(clean_text(err or out or "Could not change the browse service"))
  state = mount_info(mount_path)
  print(json.dumps({"ok": True, "browseMounted": state[1] and state[3] and browse_owned_by(mount_path, remote)}))


def cmd_timer(args: argparse.Namespace) -> None:
  remote = normalize_remote(args.remote)
  paths = remote_paths(remote)
  units_from_args(args)
  timer_name = paths["timer_name"]
  if args.interval:
    write_timer_interval(timer_name, args.interval)
  action = ["enable", "--now"] if args.enable else ["disable", "--now"]
  code, out, err = run(["systemctl", "--user", *action, timer_name], timeout=20)
  if code != 0:
    raise RuntimeError(clean_text(err or out or "Could not change the sync timer"))
  print(json.dumps({"ok": True, "timerEnabled": timer_enabled(timer_name)}))


def cmd_sync(args: argparse.Namespace) -> None:
  remote = normalize_remote(args.remote)
  paths = remote_paths(remote)
  units_from_args(args)
  service_name = paths["service_name"]
  if args.resync:
    patch_state(paths, forceResync=True)
  code, out, err = run(["systemctl", "--user", "start", service_name, "--no-block"], timeout=20)
  if code != 0:
    raise RuntimeError(clean_text(err or out or "Could not start the sync service"))
  print(json.dumps({"ok": True, "started": True}))


def cmd_remove_account(args: argparse.Namespace) -> None:
  remote = normalize_remote(args.remote)
  paths = remote_paths(remote)
  timer = paths["timer_name"]
  service = paths["service_name"]
  browse = paths["browse_service_name"]

  run(["systemctl", "--user", "disable", "--now", timer], timeout=15)
  run(["systemctl", "--user", "stop", service], timeout=15)
  run(["systemctl", "--user", "disable", "--now", browse], timeout=15)

  if args.mount:
    try:
      mount_p = normalize_path(args.mount, "~/Cloud-Browse")
      if browse_owned_by(mount_p, remote) or not mount_info(mount_p)[0]:
        unmount_browse(mount_p, remote)
        remove_gtk_bookmark(mount_p)
        # The browse folder only ever held the mount; once it is off, an empty
        # folder named "… (Cloud)" in $HOME is litter. rmdir refuses anything
        # that is not empty, so this cannot remove a file.
        if not mount_info(mount_p)[0]:
          try:
            mount_p.rmdir()
          except OSError:
            pass
    except Exception:
      pass

  if getattr(args, "folder", None):
    try:
      folder_p = normalize_path(args.folder, "~/Cloud")
      remove_gtk_bookmark(folder_p)
    except Exception:
      pass

  for name in (timer, service, browse):
    p = UNIT_DIR / name
    if p.exists():
      try:
        p.unlink()
      except OSError:
        pass
  dropin = UNIT_DIR / (timer + ".d")
  if dropin.exists():
    shutil.rmtree(dropin, ignore_errors=True)

  if paths["state_dir"].exists():
    shutil.rmtree(paths["state_dir"], ignore_errors=True)

  if getattr(args, "purge_remote", False):
    rclone = rclone_bin()
    if rclone:
      run([rclone, "config", "delete", remote], timeout=15)

  run(["systemctl", "--user", "daemon-reload"], timeout=15)
  print(json.dumps({"ok": True, "removed": remote}))


def cmd_rclone_check() -> None:
  rclone = rclone_bin()
  installed = rclone is not None
  version = ""
  if installed:
    code, out, _ = run([rclone, "version"], timeout=5)
    if code == 0 and out:
      version = out.splitlines()[0].strip()
  fuse = (shutil.which("fusermount3") or shutil.which("fusermount")) is not None
  print(json.dumps({
    "ok": True,
    "installed": installed,
    "path": rclone or "",
    "version": version,
    "fuse3": fuse
  }))


def cmd_remotes() -> None:
  rclone = rclone_bin()
  if not rclone:
    print(json.dumps({"ok": False, "remotes": [], "lastError": "rclone is not installed"}))
    return
  remotes, error = configured_remotes(rclone)
  if error:
    print(json.dumps({"ok": False, "remotes": [], "lastError": error}))
    return
  list_data = [
    {
      "name": name,
      "type": rtype,
      "authenticated": is_remote_authenticated(rclone, name, rtype)
    }
    for name, rtype in sorted(remotes.items())
  ]
  print(json.dumps({"ok": True, "remotes": list_data}))


def parser() -> argparse.ArgumentParser:
  result = argparse.ArgumentParser(description=__doc__)
  commands = result.add_subparsers(dest="command", required=True)

  commands.add_parser("rclone-check")
  commands.add_parser("remotes")

  status = commands.add_parser("status")
  status.add_argument("--remote", default="gdrive")
  status.add_argument("--folder", default="~/Cloud")
  status.add_argument("--mount", default="~/Cloud-Browse")

  folders = commands.add_parser("folders")
  folders.add_argument("--remote", default="gdrive")
  folders.add_argument("--folder", default="~/Cloud")
  folders.add_argument("--path", default="")

  select = commands.add_parser("select")
  select.add_argument("--remote", default="gdrive")
  select.add_argument("--add", action="append", default=[])
  select.add_argument("--remove", action="append", default=[])
  select.add_argument("--set", action="append", default=None)
  select.add_argument("--toggle", action="append", default=[])
  select.add_argument("--root-files", dest="root_files", action="store_true", default=None)
  select.add_argument("--no-root-files", dest="root_files", action="store_false", default=None)

  sync = commands.add_parser("sync")
  sync.add_argument("--resync", action="store_true")
  sync.add_argument("--remote", default="gdrive")
  sync.add_argument("--folder", default="~/Cloud")
  sync.add_argument("--mount", default="~/Cloud-Browse")

  runner = commands.add_parser("run")
  runner.add_argument("--remote", default="gdrive")
  runner.add_argument("--folder", default="~/Cloud")
  runner.add_argument("--resync", action="store_true")

  cleanup = commands.add_parser("cleanup")
  cleanup.add_argument("--remote", default="gdrive")
  cleanup.add_argument("--folder", default="~/Cloud")
  cleanup.add_argument("--only", action="append", default=[])

  mount = commands.add_parser("mount")
  mount.add_argument("--remote", default="gdrive")
  mount.add_argument("--mount", default="~/Cloud-Browse")

  unmount = commands.add_parser("unmount")
  unmount.add_argument("--mount", default="~/Cloud-Browse")
  unmount.add_argument("--remote", default="")

  browse = commands.add_parser("browse")
  browse_group = browse.add_mutually_exclusive_group(required=True)
  browse_group.add_argument("--enable", action="store_true")
  browse_group.add_argument("--disable", action="store_true")
  browse.add_argument("--remote", default="gdrive")
  browse.add_argument("--folder", default="~/Cloud")
  browse.add_argument("--mount", default="~/Cloud-Browse")

  timer = commands.add_parser("timer")
  group = timer.add_mutually_exclusive_group(required=True)
  group.add_argument("--enable", action="store_true")
  group.add_argument("--disable", action="store_true")
  timer.add_argument("--interval", type=int, default=0)
  timer.add_argument("--remote", default="gdrive")
  timer.add_argument("--folder", default="~/Cloud")
  timer.add_argument("--mount", default="~/Cloud-Browse")

  remove = commands.add_parser("remove-account")
  remove.add_argument("--remote", required=True)
  remove.add_argument("--mount", default="")
  remove.add_argument("--folder", default="")
  remove.add_argument("--purge-remote", action="store_true", default=False)

  query = commands.add_parser("query")
  query.add_argument("path", help="Local file or folder path")
  query.add_argument("--remote", default="", help="Optional remote name hint")
  query.add_argument("--set-emblems", action="store_true", help="Apply GIO emblem and xattr to path")

  return result


def main() -> int:
  args = parser().parse_args()
  for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(signum, _on_signal)
  try:
    if args.command == "rclone-check":
      cmd_rclone_check()
    elif args.command == "remotes":
      cmd_remotes()
    elif args.command == "status":
      print(json.dumps(status_payload(args.remote, args.folder, args.mount)))
    elif args.command == "folders":
      print(json.dumps(folders_payload(args.remote, args.folder, args.path)))
    elif args.command == "select":
      cmd_select(args)
    elif args.command == "query":
      cmd_query(args)
    elif args.command == "sync":
      cmd_sync(args)
    elif args.command == "run":
      paths = remote_paths(args.remote)
      state = load_state(paths)
      forced = args.resync or state.get("forceResync") is True
      if forced:
        patch_state(paths, forceResync=False)
      return do_run(args.remote, args.folder, forced)
    elif args.command == "cleanup":
      return cmd_cleanup(args)
    elif args.command == "mount":
      mount_browse(normalize_remote(args.remote), normalize_path(args.mount, "~/Cloud-Browse"))
    elif args.command == "unmount":
      unmount_browse(normalize_path(args.mount, "~/Cloud-Browse"),
                     normalize_remote(args.remote) if args.remote else "")
    elif args.command == "browse":
      cmd_browse(args)
    elif args.command == "timer":
      cmd_timer(args)
    elif args.command == "remove-account":
      cmd_remove_account(args)
  except (OSError, RuntimeError, ValueError) as error:
    if args.command in ("status", "folders", "query"):
      print(json.dumps({"ok": False, "lastError": clean_text(str(error)), "folders": []}))
      return 0
    print(clean_text(str(error)), file=sys.stderr)
    return 1
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
