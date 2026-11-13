"""In-app updates for SpotVault.

The newest *approved* version is the GitHub release marked "Latest". New
builds are published as pre-releases first (apps ignore those), tested, and
then approved in the admin panel, which makes them Latest. See UPDATES.md.
"""
import os
import re
import tempfile

import requests

REPO = "sarathlal-12/spotvault"
LATEST_API = f"https://api.github.com/repos/{REPO}/releases/latest"
RELEASES_PAGE = f"https://github.com/{REPO}/releases/latest"
_HEADERS = {"Accept": "application/vnd.github+json", "User-Agent": "SpotVault-Updater"}


def parse_version(text):
    """'v1.3.0' / '1.3' -> (1, 3, 0). Unknown parts count as 0."""
    nums = [int(n) for n in re.findall(r"\d+", text or "")[:3]]
    return tuple(nums + [0] * (3 - len(nums)))


def is_newer(latest, current):
    return parse_version(latest) > parse_version(current)


def check_latest(timeout=8):
    """Return info about the approved release, or None if there is none.

    Raises requests exceptions when offline, so a manual check can say so.
    """
    res = requests.get(LATEST_API, headers=_HEADERS, timeout=timeout)
    if res.status_code == 404:
        return None
    res.raise_for_status()
    data = res.json()
    installer = None
    for asset in data.get("assets") or []:
        name = asset.get("name", "")
        if name.lower().endswith(".exe") and "setup" in name.lower():
            installer = {"name": name, "url": asset.get("browser_download_url", ""),
                         "size": asset.get("size", 0)}
            break
    tag = data.get("tag_name", "")
    return {
        "version": tag.lstrip("vV"),
        "tag": tag,
        "title": data.get("name") or tag,
        "notes": (data.get("body") or "").strip(),
        "page": data.get("html_url") or RELEASES_PAGE,
        "installer": installer,
    }


def download_installer(info, progress=None, cancelled=lambda: False):
    """Download the Windows installer to the temp folder and return its path."""
    inst = info["installer"]
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", inst["name"])
    dest = os.path.join(tempfile.gettempdir(), safe)
    part = dest + ".part"
    with requests.get(inst["url"], headers={"User-Agent": "SpotVault-Updater"}, stream=True, timeout=30) as res:
        res.raise_for_status()
        total = int(res.headers.get("Content-Length") or inst.get("size") or 0)
        got = 0
        with open(part, "wb") as f:
            for chunk in res.iter_content(256 * 1024):
                if cancelled():
                    raise RuntimeError("cancelled")
                f.write(chunk)
                got += len(chunk)
                if progress and total:
                    progress(got / total)
    if total and got != total:
        os.remove(part)
        raise RuntimeError(f"Download incomplete ({got} of {total} bytes)")
    if os.path.exists(dest):
        os.remove(dest)
    os.replace(part, dest)
    return dest
