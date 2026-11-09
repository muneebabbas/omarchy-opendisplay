#!/usr/bin/env python3
"""JSON-producing helpers for bin/omarchy-opendisplay. Run with python3 -I.

  status                                   sessions, units and auto-connect state as JSON
  release FILE ARCH INSTALLED              check-update JSON from a GitHub release object
  verify-sha FILE SHAFILE DIGEST           check a download against .sha256 and the API digest
  check-tar FILE TOPDIR                    reject unsafe or unexpected tarball entries
"""

import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile

ID_RE = re.compile(r"^[0-9A-Fa-f][0-9A-Fa-f-]{7,63}$")
OUTPUT_RE = re.compile(r"^od-[0-9a-f]{6}$")
TRANSIENT_RE = re.compile(r"^opendisplay-(addr-)?[0-9a-f]{8}\.service$")
TEMPLATE_RE = re.compile(r"^od-sender@(.+)\.service$")
VERSION_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
MAX_JSON = 1024 * 1024


def unescape_unit(text):
    return re.sub(r"\\x([0-9a-fA-F]{2})", lambda m: chr(int(m.group(1), 16)), text)


def runtime_dir():
    return os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"


def config_home():
    return os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")


def systemctl(*args):
    try:
        r = subprocess.run(["systemctl", "--user", *args], check=False, capture_output=True, text=True, timeout=10)
        return r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def to_from_argv(argv):
    for i, a in enumerate(argv):
        if a.startswith("--to="):
            return a[5:]
        if a == "--to" and i + 1 < len(argv):
            return argv[i + 1]
    return ""


def proc_info(pid):
    try:
        with open(f"/proc/{pid}/comm") as f:
            if f.read().strip() != "od-sender":
                return None
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            argv = [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
        unit = None
        with open(f"/proc/{pid}/cgroup") as f:
            for line in f:
                last = line.strip().rsplit("/", 1)[-1]
                if TRANSIENT_RE.match(last) or TEMPLATE_RE.match(last):
                    unit = last
        return {"argv": argv, "unit": unit}
    except OSError:
        return None


def sessions():
    out = []
    for path in sorted(glob.glob(os.path.join(runtime_dir(), "opendisplay", "*.lock"))):
        output = os.path.basename(path)[:-5]
        if not OUTPUT_RE.match(output):
            continue
        try:
            with open(path) as f:
                pid = int(f.read(32).strip())
            since = int(os.stat(path).st_mtime)
        except (OSError, ValueError):
            continue
        info = proc_info(pid)
        if info is None:
            continue  # stale lock: the sender is gone
        to = to_from_argv(info["argv"])
        out.append({
            "output": output,
            "pid": pid,
            "unit": info["unit"],
            "id": to if ID_RE.match(to) else None,
            "to": to[:96],
            "since": since,
        })
    return out


def units():
    raw = systemctl("list-units", "--all", "--plain", "--no-legend", "-o", "json",
                    "opendisplay-*", "od-sender@*")
    try:
        listed = json.loads(raw) if raw.strip() else []
    except json.JSONDecodeError:
        listed = []
    names = [u.get("unit", "") for u in listed
             if u.get("active") in ("active", "activating", "deactivating", "failed")]
    names = [n for n in names if TRANSIENT_RE.match(n) or (TEMPLATE_RE.match(n) and n != "od-sender@.service")]
    if not names:
        return []
    props = "Id,ActiveState,ExecMainStatus,Description,InactiveExitTimestamp"
    shown = systemctl("show", "--timestamp=unix", "-p", props, *names)
    out = []
    for block in shown.strip().split("\n\n"):
        props = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        uid = props.get("Id", "")
        m = TEMPLATE_RE.match(uid)
        if m:
            to = unescape_unit(m.group(1))
        elif TRANSIENT_RE.match(uid):
            desc = props.get("Description", "")
            to = desc[len("OpenDisplay to "):] if desc.startswith("OpenDisplay to ") else ""
        else:
            continue
        since = props.get("InactiveExitTimestamp", "").lstrip("@")
        try:
            status = int(props.get("ExecMainStatus", "0") or 0)
        except ValueError:
            status = 0
        out.append({
            "unit": uid,
            "state": props.get("ActiveState", ""),
            "template": bool(m),
            "id": to if ID_RE.match(to) else None,
            "to": to[:96],
            "status": status,
            "since": int(since) if since.isdigit() else 0,
        })
    return out


def autoconnect():
    ids = []
    for path in glob.glob(os.path.join(config_home(), "systemd", "user", "*.wants", "od-sender@*.service")):
        m = TEMPLATE_RE.match(os.path.basename(path))
        if m:
            inst = unescape_unit(m.group(1))
            if ID_RE.match(inst) and inst not in ids:
                ids.append(inst)
    return ids


def template_installed():
    dirs = [os.path.join(config_home(), "systemd", "user"),
            os.path.join(os.path.expanduser("~"), ".local", "share", "systemd", "user"),
            "/etc/systemd/user", "/usr/lib/systemd/user"]
    return any(os.path.isfile(os.path.join(d, "od-sender@.service")) for d in dirs)


def cmd_status():
    print(json.dumps({
        "sessions": sessions(),
        "units": units(),
        "autoconnect": autoconnect(),
        "templateInstalled": template_installed(),
    }))
    return 0


def load_release(path):
    if os.path.getsize(path) > MAX_JSON:
        raise ValueError("release JSON is larger than 1 MB")
    with open(path, encoding="utf-8") as f:
        rel = json.load(f)
    if not isinstance(rel, dict):
        raise ValueError("release JSON is not an object")
    return rel


def version_tuple(v):
    m = VERSION_RE.match(v or "")
    return tuple(int(x) for x in m.groups()) if m else None


def find_asset(rel, name):
    for a in rel.get("assets") or []:
        if isinstance(a, dict) and a.get("name") == name:
            return a
    return None


GH_DOWNLOAD = re.compile(r"^https://github\.com/peetzweg/opendisplay/releases/download/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")


def cmd_release(path, arch, installed):
    rel = load_release(path)
    if rel.get("draft") or rel.get("prerelease"):
        raise ValueError("latest release is a draft or prerelease")
    tag = str(rel.get("tag_name", ""))
    latest = version_tuple(tag)
    if latest is None:
        raise ValueError(f"unexpected release tag {tag[:40]!r}")
    name = f"od-sender-{arch}-unknown-linux-gnu.tar.gz"
    asset = find_asset(rel, name)
    sha = find_asset(rel, name + ".sha256")
    html = str(rel.get("html_url", ""))
    if not re.match(r"^https://github\.com/peetzweg/opendisplay/releases/", html):
        html = "https://github.com/peetzweg/opendisplay/releases/latest"
    cur = version_tuple(installed)
    out = {
        "latest": "{}.{}.{}".format(*latest),
        "url": asset.get("browser_download_url") if asset else None,
        "digest": asset.get("digest") if asset else None,
        "sha256Url": sha.get("browser_download_url") if sha else None,
        "htmlUrl": html,
        "newer": cur is None or latest > cur,
    }
    for key in ("url", "sha256Url"):
        if out[key] is not None and not GH_DOWNLOAD.match(str(out[key])):
            out[key] = None
    if out["digest"] is not None and not re.match(r"^sha256:[0-9a-f]{64}$", str(out["digest"])):
        out["digest"] = None
    print(json.dumps(out))
    return 0


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_verify_sha(path, sha_file, digest):
    actual = sha256_file(path)
    try:
        with open(sha_file, encoding="utf-8") as f:
            first = f.read(4096).split()
    except OSError:
        first = []
    if not first or not re.match(r"^[0-9a-fA-F]{64}$", first[0]):
        print("checksum file is missing or malformed", file=sys.stderr)
        return 1
    m = re.match(r"^sha256:([0-9a-f]{64})$", digest or "")
    if not m:
        print("GitHub didn't publish a sha256 digest for this asset", file=sys.stderr)
        return 1
    if first[0].lower() != actual:
        print("checksum mismatch against the .sha256 file", file=sys.stderr)
        return 1
    if m.group(1) != actual:
        print("checksum mismatch against GitHub's digest", file=sys.stderr)
        return 1
    return 0


def cmd_check_tar(path, topdir):
    try:
        with tarfile.open(path, "r:gz") as tf:
            members = tf.getmembers()
    except (tarfile.TarError, OSError, EOFError) as e:
        print(f"not a valid tarball: {e}", file=sys.stderr)
        return 1
    names = set()
    for m in members:
        name = m.name
        parts = [p for p in name.split("/") if p not in ("", ".")]
        if name.startswith("/") or ".." in name.split("/"):
            print(f"unsafe path in archive: {name!r}", file=sys.stderr)
            return 1
        if not (m.isreg() or m.isdir()):
            print(f"archive entry is not a regular file or directory: {name!r}", file=sys.stderr)
            return 1
        if not parts or parts[0] != topdir:
            print(f"unexpected top-level entry: {name!r}", file=sys.stderr)
            return 1
        names.add("/".join(parts))
    for required in (f"{topdir}/od-sender", f"{topdir}/install.sh"):
        if required not in names:
            print(f"archive is missing {required}", file=sys.stderr)
            return 1
    return 0


def main(argv):
    try:
        if argv[:1] == ["status"]:
            return cmd_status()
        if argv[:1] == ["release"] and len(argv) == 4:
            return cmd_release(argv[1], argv[2], argv[3])
        if argv[:1] == ["verify-sha"] and len(argv) == 4:
            return cmd_verify_sha(argv[1], argv[2], argv[3])
        if argv[:1] == ["check-tar"] and len(argv) == 3:
            return cmd_check_tar(argv[1], argv[2])
    except (ValueError, OSError, json.JSONDecodeError) as e:
        print(str(e), file=sys.stderr)
        return 1
    print(__doc__.strip(), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
