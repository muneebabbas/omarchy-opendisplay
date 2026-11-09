#!/usr/bin/env python3
"""USB transport for OpenDisplay through usbmuxd. Run with python3 -I.

od-sender has no USB transport on Linux. An iOS receiver listens on TCP 9000
on the device, which usbmuxd can tunnel to: after a successful `Connect` the
usbmuxd socket is a raw byte pipe to that port. So a USB session is od-sender
connecting to a loopback port that this script forwards to the device.

  list                          receivers on USB as JSON: [{udid, deviceId, id, name, pv}]
  find ID                       print the UDID of the USB device whose receiver has this id
  state                         running | installed | missing
  forward --listen H:P --udid U forward a loopback port to the device (debugging)
  run --udid U --sender PATH    forward a free loopback port, run `od-sender run --to=127.0.0.1:<port>`
                                as a child, stop it when the device goes away; exits with its code

Exit codes: 0 ok, 1 other failure, 2 bad usage, 3 the device isn't on USB (run),
13 usbmuxd isn't available, 14 no USB receiver with that id (find).

usbmuxd's socket is /var/run/usbmuxd, or $USBMUXD_SOCKET_ADDRESS
("UNIX:/path" or "host:port"), as in libusbmuxd. The receiver id comes from
the receiver's first message (its hello), read on a connection that is then
closed without sending anything, which the receiver ignores (it doesn't touch
a running session). Results are cached per usbmuxd DeviceID, which changes on
every replug, in $XDG_RUNTIME_DIR/omarchy-opendisplay/usb-cache.json.
"""

import json
import os
import plistlib
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

RECEIVER_PORT = 9000
DEFAULT_SOCKET = "/var/run/usbmuxd"
ID_RE = re.compile(r"^[0-9A-Fa-f][0-9A-Fa-f-]{7,63}$")
UDID_RE = re.compile(r"^[0-9A-Fa-f][0-9A-Fa-f-]{15,63}$")
MAX_PLIST = 1024 * 1024
MAX_HELLO = 64 * 1024
MAX_DEVICES = 16


class Unavailable(Exception):
    """usbmuxd isn't running (or its socket can't be reached)."""


def socket_address():
    """(family, address) of usbmuxd. Keep in sync with opendisplay-util.py."""
    env = os.environ.get("USBMUXD_SOCKET_ADDRESS", "")
    if env.startswith("UNIX:"):
        return socket.AF_UNIX, env[5:]
    if env:
        host, _, port = env.rpartition(":")
        if host and port.isdigit():
            return socket.AF_INET, (host, int(port))
    return socket.AF_UNIX, DEFAULT_SOCKET


def usbmuxd_state():
    fam, addr = socket_address()
    try:
        s = socket.socket(fam, socket.SOCK_STREAM)
        s.settimeout(1)
        try:
            s.connect(addr)
            return "running"
        finally:
            s.close()
    except OSError:
        pass
    for d in ("/usr/bin", "/usr/sbin", "/usr/local/bin", "/usr/local/sbin", "/bin", "/sbin"):
        if os.path.isfile(os.path.join(d, "usbmuxd")):
            return "installed"
    return "installed" if shutil.which("usbmuxd") else "missing"


def recv_exact(s, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("connection closed")
        buf += chunk
    return bytes(buf)


def open_mux(timeout=3.0):
    fam, addr = socket_address()
    s = socket.socket(fam, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(addr)
    except OSError as e:
        s.close()
        raise Unavailable(str(e)) from e
    return s


def send_msg(s, msg, tag=1):
    body = plistlib.dumps(dict(msg, ClientVersionString="omarchy-opendisplay", ProgName="omarchy-opendisplay"))
    # length, version 1 (plist), message 8 (plist), tag
    s.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, tag) + body)


def read_msg(s):
    length = struct.unpack("<IIII", recv_exact(s, 16))[0]
    if length < 16 or length - 16 > MAX_PLIST:
        raise ConnectionError("bad usbmuxd message length")
    reply = plistlib.loads(recv_exact(s, length - 16))
    if not isinstance(reply, dict):
        raise ConnectionError("bad usbmuxd message")
    return reply


def usb_device(props):
    """(DeviceID, UDID) of a wired device; usbmuxd also lists Wi-Fi-paired ones."""
    if not isinstance(props, dict) or props.get("ConnectionType") != "USB":
        return None
    did, udid = props.get("DeviceID"), props.get("SerialNumber")
    if not isinstance(did, int) or not isinstance(udid, str) or not UDID_RE.match(udid):
        return None
    return did, udid


def list_devices():
    s = open_mux()
    try:
        send_msg(s, {"MessageType": "ListDevices"})
        reply = read_msg(s)
    finally:
        s.close()
    out = []
    for d in reply.get("DeviceList") or []:
        dev = usb_device(d.get("Properties") if isinstance(d, dict) else None)
        if dev and dev not in out:
            out.append(dev)
    return out[:MAX_DEVICES]


def connect_device(device_id, port=RECEIVER_PORT, timeout=3.0):
    """A socket piped to <port> on the device, or None if nothing listens there."""
    s = open_mux(timeout)
    try:
        send_msg(s, {"MessageType": "Connect", "DeviceID": device_id, "PortNumber": socket.htons(port)})
        reply = read_msg(s)
    except (OSError, ConnectionError, plistlib.InvalidFileException, ValueError):
        s.close()
        return None
    if reply.get("MessageType") != "Result" or reply.get("Number") != 0:
        s.close()
        return None
    return s


def clean_text(value, limit):
    text = re.sub(r"[\x00-\x1f\x7f-\x9f]", "", str(value or "")).strip()
    return text[:limit]


def probe(device_id):
    """The receiver's hello on the device, as {id, name, pv}, or None."""
    s = connect_device(device_id)
    if s is None:
        return None
    try:
        s.settimeout(3)
        n = struct.unpack(">I", recv_exact(s, 4))[0]
        if n == 0 or n > MAX_HELLO:
            return None
        hello = json.loads(recv_exact(s, n))
    except (OSError, ConnectionError, ValueError):
        return None
    finally:
        s.close()  # silently: the receiver drops a client that never speaks
    if not isinstance(hello, dict) or not ID_RE.match(str(hello.get("id") or "")):
        return None
    pv = hello.get("pv")
    return {
        "id": hello["id"],
        "name": clean_text(hello.get("device") or hello.get("name"), 64),
        "pv": pv if isinstance(pv, int) and not isinstance(pv, bool) else 0,
    }


def cache_path():
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return os.path.join(runtime, "omarchy-opendisplay", "usb-cache.json")


def load_cache():
    try:
        with open(cache_path(), encoding="utf-8") as f:
            data = json.loads(f.read(MAX_PLIST))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_cache(cache):
    path = cache_path()
    tmp = None
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # A unique temp name: list and find can run at the same time.
        fd, tmp = tempfile.mkstemp(prefix=".usb-cache.", dir=os.path.dirname(path))
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(cache, f)
        os.replace(tmp, path)
        tmp = None
    except OSError:
        pass
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def receivers():
    """Receivers on USB. A device is probed once per DeviceID; failed probes
    (the app isn't open) aren't cached, so they're retried on the next scan."""
    cache = load_cache()
    fresh = {}
    out = []
    for did, udid in list_devices():
        key = f"{udid}#{did}"
        info = cache.get(key)
        if not (isinstance(info, dict) and ID_RE.match(str(info.get("id") or ""))):
            info = probe(did)
        if info is None:
            continue
        fresh[key] = info
        out.append({"udid": udid, "deviceId": did, **info})
    if fresh != cache:
        save_cache(fresh)
    return out


def cmd_list():
    try:
        print(json.dumps(receivers()))
    except Unavailable:
        print("[]")
    return 0


def cmd_find(rid):
    if not ID_RE.match(rid):
        print("invalid receiver id", file=sys.stderr)
        return 2
    try:
        found = receivers()
    except Unavailable:
        print("usbmuxd isn't running", file=sys.stderr)
        return 13
    for r in found:
        if r["id"].upper() == rid.upper():
            print(r["udid"])
            return 0
    print("receiver isn't connected by USB", file=sys.stderr)
    return 14


# --- forwarding -------------------------------------------------------------


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    for s, how in ((dst, socket.SHUT_WR), (src, socket.SHUT_RD)):
        try:
            s.shutdown(how)
        except OSError:
            pass


def serve_client(client, device_id, allowed=None):
    if allowed is not None and not allowed(client):
        log("refused a local connection that isn't from this session's od-sender")
        client.close()
        return
    dev = connect_device(device_id)
    if dev is None:
        log("couldn't reach the receiver on the device; is the OpenDisplay app open?")
        client.close()
        return
    dev.settimeout(None)
    client.settimeout(None)
    try:
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except OSError:
        pass
    t = threading.Thread(target=pump, args=(dev, client), daemon=True)
    t.start()
    pump(client, dev)
    # od-sender is done with this connection: a half-open device side must
    # not keep the other direction (and this thread) alive.
    try:
        dev.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    t.join(timeout=5)
    client.close()
    dev.close()


def accept_loop(listener, device_id, allowed=None):
    while True:
        try:
            client, _ = listener.accept()
        except OSError:
            return
        threading.Thread(target=serve_client, args=(client, device_id, allowed), daemon=True).start()


def tcp_inode(local_port, remote_port):
    """Inode of the IPv4 loopback socket with these ports, from /proc/net/tcp."""
    try:
        with open("/proc/net/tcp", encoding="ascii") as f:
            next(f, None)
            for line in f:
                fields = line.split()
                if len(fields) < 10:
                    continue
                lport = int(fields[1].rsplit(":", 1)[1], 16)
                rport = int(fields[2].rsplit(":", 1)[1], 16)
                if lport == local_port and rport == remote_port:
                    return fields[9]
    except (OSError, ValueError):
        pass
    return None


def peer_is(pid):
    """A check that an accepted loopback connection was made by process <pid>:
    the peer's socket inode must be one of that process's open files. Anyone
    else on this machine gets nothing (the receiver has no pairing, so the
    forwarder would otherwise hand the device to any local program)."""
    def allowed(client):
        try:
            peer_port = client.getpeername()[1]
            our_port = client.getsockname()[1]
        except OSError:
            return False
        inode = tcp_inode(peer_port, our_port)
        if inode is None:
            return False
        want = f"socket:[{inode}]"
        try:
            fds = os.listdir(f"/proc/{pid}/fd")
        except OSError:
            return False
        for fd in fds:
            try:
                if os.readlink(f"/proc/{pid}/fd/{fd}") == want:
                    return True
            except OSError:
                continue
        return False
    return allowed


def watch_detach(device_id, on_gone):
    """Calls on_gone() when the device is unplugged or usbmuxd goes away."""
    try:
        s = open_mux()
        send_msg(s, {"MessageType": "Listen"})
        read_msg(s)  # the Result for Listen
        # Unplugged between the caller's ListDevices and Listen being set up?
        if device_id not in [did for did, _ in list_devices()]:
            raise ConnectionError("device is gone")
        s.settimeout(None)
        while True:
            msg = read_msg(s)
            if msg.get("MessageType") == "Detached" and msg.get("DeviceID") == device_id:
                break
    except (OSError, ConnectionError, Unavailable, ValueError, plistlib.InvalidFileException):
        pass
    on_gone()


def log(text):
    # No timestamp/level, so the widget's log parser treats it as "other".
    print(f"usbmux: {text}", file=sys.stderr, flush=True)


def device_for(udid):
    for did, u in list_devices():
        if u.upper() == udid.upper():
            return did
    return None


def listen(host, port):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((host, port))
    listener.listen(4)
    return listener


def cmd_forward(addr, udid):
    host, _, port = addr.rpartition(":")
    if host not in ("127.0.0.1", "localhost") or not port.isdigit() or not 1 <= int(port) <= 65535:
        print("--listen must be 127.0.0.1:<port>", file=sys.stderr)
        return 2
    did = device_for(udid)
    if did is None:
        print("device isn't connected by USB", file=sys.stderr)
        return 3
    listener = listen("127.0.0.1", int(port))
    gone = threading.Event()
    threading.Thread(target=watch_detach, args=(did, gone.set), daemon=True).start()
    threading.Thread(target=accept_loop, args=(listener, did), daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: gone.set())
    try:
        gone.wait()
    except KeyboardInterrupt:
        pass
    listener.close()
    return 0


def cmd_run(udid, sender):
    if not os.path.isabs(sender) or not os.access(sender, os.X_OK):
        print("--sender must be the absolute path of od-sender", file=sys.stderr)
        return 2
    did = device_for(udid)
    if did is None:
        log("the device isn't connected by USB")
        return 3
    listener = listen("127.0.0.1", 0)
    port = listener.getsockname()[1]
    child = subprocess.Popen([sender, "run", f"--to=127.0.0.1:{port}"])
    # Only od-sender's own connections are forwarded.
    threading.Thread(target=accept_loop, args=(listener, did, peer_is(child.pid)), daemon=True).start()
    stopping = threading.Event()

    def escalate():
        # SIGINT lets od-sender remove its display; if it hangs (upstream
        # bug 1 in docs/SPEC.md), SIGTERM, then SIGKILL.
        for sig, wait in ((signal.SIGTERM, 5), (signal.SIGKILL, 3)):
            deadline = time.monotonic() + wait
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    return
                time.sleep(0.1)
            if child.poll() is None:
                child.send_signal(sig)

    def stop(reason=None):
        if stopping.is_set():
            return
        stopping.set()
        if reason:
            log(reason)
        if child.poll() is None:
            child.send_signal(signal.SIGINT)  # od-sender disconnects cleanly
            threading.Thread(target=escalate, daemon=True).start()

    signal.signal(signal.SIGTERM, lambda *_: stop())
    signal.signal(signal.SIGINT, lambda *_: stop())
    threading.Thread(target=watch_detach, args=(did, lambda: stop("the device was unplugged")),
                     daemon=True).start()
    while True:
        try:
            code = child.wait(timeout=1)
            break
        except subprocess.TimeoutExpired:
            continue
    listener.close()
    # A requested stop (systemctl stop, unplug) is a clean end, whatever
    # od-sender's own status, so the unit isn't left failed.
    if stopping.is_set():
        return 0
    return code if code >= 0 else 1


def opt(argv, name):
    for i, a in enumerate(argv):
        if a.startswith(name + "="):
            return a[len(name) + 1:]
        if a == name and i + 1 < len(argv):
            return argv[i + 1]
    return None


def main(argv):
    cmd = argv[:1]
    try:
        if argv == ["list"] or argv == ["list", "--json"]:
            return cmd_list()
        if cmd == ["find"] and len(argv) == 2:
            return cmd_find(argv[1])
        if argv == ["state"]:
            print(usbmuxd_state())
            return 0
        if cmd in (["forward"], ["run"]):
            udid = opt(argv, "--udid") or ""
            if not UDID_RE.match(udid):
                print("invalid --udid", file=sys.stderr)
                return 2
            if cmd == ["forward"]:
                return cmd_forward(opt(argv, "--listen") or "", udid)
            return cmd_run(udid, opt(argv, "--sender") or "")
    except Unavailable:
        print("usbmuxd isn't running", file=sys.stderr)
        return 13
    except (OSError, ConnectionError, ValueError, plistlib.InvalidFileException) as e:
        print(str(e), file=sys.stderr)
        return 1
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
