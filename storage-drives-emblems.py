"""Nautilus extension providing real-time sync status emblems and context menu
actions for Terrace OS / Storage Drives.
"""

from gi import require_version
require_version("Nautilus", "4.1")

from gi.repository import GObject, Gio, Nautilus
from pathlib import Path
import os
import json
import time


def get_cloud_roots():
    roots = {}
    for store_path in (
        Path.home() / ".local" / "state" / "omarchy" / "cloud-drives.json",
        Path.home() / ".local" / "state" / "storage-drives" / "cloud-drives.json",
    ):
        if store_path.exists():
            try:
                data = json.loads(store_path.read_text(encoding="utf-8"))
                for acc in data.get("accounts", []):
                    f = acc.get("folderPath")
                    if f:
                        p = Path(f.replace("~", str(Path.home()))).resolve()
                        roots[str(p)] = acc.get("remoteName", "")
            except Exception:
                pass
    if not roots:
        for name in ("Google Drive", "OneDrive", "Dropbox"):
            p = (Path.home() / name).resolve()
            if p.is_dir():
                roots[str(p)] = name.lower()
    return roots


class TerraceSyncEmblemExtension(GObject.GObject, Nautilus.InfoProvider, Nautilus.MenuProvider):
    def __init__(self):
        super().__init__()
        self._roots = get_cloud_roots()
        self._last_roots_check = time.time()

    def _is_managed(self, path_str):
        if time.time() - self._last_roots_check > 30:
            self._roots = get_cloud_roots()
            self._last_roots_check = time.time()
        for root in self._roots:
            if path_str == root or path_str.startswith(root + "/"):
                return root, self._roots[root]
        return None, None

    def update_file_info(self, file: Nautilus.FileInfo) -> Nautilus.OperationResult:
        location = file.get_location()
        if not location:
            return Nautilus.OperationResult.COMPLETE

        path_str = location.get_path()
        if not path_str:
            return Nautilus.OperationResult.COMPLETE

        root, remote = self._is_managed(path_str)
        if not root:
            return Nautilus.OperationResult.COMPLETE

        name = file.get_name()
        if ".conflict" in name:
            file.add_emblem("emblem-important")
            return Nautilus.OperationResult.COMPLETE

        # 1. Extended attribute check
        try:
            xattr_status = os.getxattr(path_str, "user.terrace.sync").decode("utf-8")
            emblem_map = {
                "synced": "emblem-default",          # Green circle with white check
                "syncing": "emblem-synchronizing",   # Blue rotating sync arrows
                "partial": "emblem-dropbox-selsync", # Grey selective sync badge
                "conflict": "emblem-important",      # Red exclamation warning
                "excluded": "emblem-shared",         # Cloud / shared
            }
            emblem = emblem_map.get(xattr_status)
            if emblem:
                file.add_emblem(emblem)
                return Nautilus.OperationResult.COMPLETE
        except OSError:
            pass

        # 2. Selection rules check
        rel = os.path.relpath(path_str, root)
        if rel == ".":
            file.add_emblem("emblem-default")
            return Nautilus.OperationResult.COMPLETE

        state_dir = Path.home() / ".local" / "state" / "omarchy-storage-drives" / "cloud" / remote
        sel_file = state_dir / "selection.json"
        if sel_file.exists():
            try:
                sel = json.loads(sel_file.read_text())
                excludes = sel.get("excludes", [])
                folders = sel.get("folders", [])
                if any(rel == e or rel.startswith(e + "/") for e in excludes):
                    file.add_emblem("emblem-shared")
                    return Nautilus.OperationResult.COMPLETE
                if any(f.startswith(rel + "/") for f in folders):
                    file.add_emblem("emblem-dropbox-selsync")
                    return Nautilus.OperationResult.COMPLETE
            except Exception:
                pass

        file.add_emblem("emblem-default")
        return Nautilus.OperationResult.COMPLETE

    def get_file_items(self, files: list[Nautilus.FileInfo]) -> list[Nautilus.MenuItem]:
        if not files:
            return []
        location = files[0].get_location()
        if not location:
            return []
        path_str = location.get_path()
        if not path_str:
            return []
        root, remote = self._is_managed(path_str)
        if not root:
            return []

        item = Nautilus.MenuItem(
            name="TerraceStorage::SyncNow",
            label="Sync Cloud Remote (%s)" % remote,
            tip="Trigger sync for %s" % remote,
        )
        item.connect("activate", self._on_sync_now, remote)
        return [item]

    def _on_sync_now(self, menu_item, remote):
        Gio.Subprocess.new(["systemctl", "--user", "start", f"omarchy-storage-sync-{remote}.service"], Gio.SubprocessFlags.NONE)
