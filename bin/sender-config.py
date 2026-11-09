#!/usr/bin/env python3
"""Read and edit od-sender's sender.toml for the OpenDisplay Omarchy widget.

Run as `python3 -I sender-config.py ...`; stdlib only.

  get --json                              print the file as JSON ({} when absent)
  set [--receiver ID] key=value ...       edit in place (key= deletes)
  rollback                                restore sender.toml.bak

Edits are line-based so comments and keys this tool doesn't know survive.
Only a small set of keys may be written; everything is validated before the
file is touched, and the result is re-parsed and validated again before it
replaces the original (via .bak, .tmp, fsync, os.replace).
"""

import json
import os
import re
import sys
import tomllib

ID_RE = re.compile(r"^[0-9A-Fa-f][0-9A-Fa-f-]{7,63}$")
HEADER_RE = re.compile(r"^\s*\[\s*([^\[\]]*?)\s*\]\s*(#.*)?$")
RECEIVER_HEADER_RE = re.compile(r'^receiver\s*\.\s*"([^"]*)"$')
KEY_LINE_RE = re.compile(r'^\s*("?)([A-Za-z0-9_-]+)\1\s*=')

ENCODERS = ("auto", "v4l2m2m", "x264", "openh264")
CURSORS = ("auto", "video", "off")
TOP_KEYS = ("max-fps", "encoder", "cursor", "tailscale")
RECEIVER_KEYS = ("bitrate-mbps", "scale")


class ConfigError(Exception):
    """A failure that isn't the caller's fault (unreadable or broken sender.toml); exit 1."""

    code = 1


class ArgError(ConfigError):
    """A bad argument, key or value; exit 2 (see the helper's exit codes)."""

    code = 2


def config_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "opendisplay", "sender.toml")


def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def check_value(scope, key, value):
    """Validate a parsed TOML value for a key this tool manages."""
    if scope == "top":
        if key == "max-fps":
            return isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= 240
        if key == "encoder":
            return value in ENCODERS
        if key == "cursor":
            return value in CURSORS
        if key == "tailscale":
            return isinstance(value, bool)
        if key == "bitrate-mbps":
            return is_number(value) and 1 <= value <= 200
        if key == "scale":
            return check_value("receiver", "scale", value)
        return True
    if key == "bitrate-mbps":
        return is_number(value) and 1 <= value <= 200
    if key == "scale":
        if value in ("passthrough", "mac"):
            return True
        return is_number(value) and 1 <= value <= 4 and abs(value * 4 - round(value * 4)) < 1e-9
    return True


def validate_document(doc):
    for key, value in doc.items():
        if key == "receiver":
            if not isinstance(value, dict):
                raise ConfigError("receiver must be a table of receiver tables")
            for rid, table in value.items():
                if not isinstance(table, dict):
                    raise ConfigError(f"receiver.{rid} must be a table")
                for rkey, rvalue in table.items():
                    if not check_value("receiver", rkey, rvalue):
                        raise ConfigError(f"invalid value for receiver {rkey}")
        elif not isinstance(value, dict) and not check_value("top", key, value):
            raise ConfigError(f"invalid value for {key}")


def literal(scope, key, text):
    """Turn a validated text value into a TOML literal of the right type."""
    allowed = TOP_KEYS if scope == "top" else RECEIVER_KEYS
    if key not in allowed:
        raise ArgError(f"{key} can't be set here")
    if text == "":
        return None
    if key in ("max-fps", "bitrate-mbps"):
        if not re.fullmatch(r"[0-9]{1,3}", text):
            raise ArgError(f"{key} must be a whole number")
        value = int(text)
    elif key == "scale":
        if text in ("passthrough", "mac"):
            value = text
        elif re.fullmatch(r"[0-9](\.[0-9]{1,2})?", text):
            value = float(text)
            if value == int(value):
                value = int(value)
        else:
            raise ArgError("scale must be passthrough, mac or a number")
    elif key == "tailscale":
        if text not in ("true", "false"):
            raise ArgError("tailscale must be true or false")
        value = text == "true"
    else:
        value = text
    if not check_value(scope, key, value):
        raise ArgError(f"invalid value for {key}")
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    return json.dumps(value)  # a TOML basic string for these plain ASCII values


def split_sections(lines):
    """Yield (table, start, end) spans; table is None for top level,
    ("receiver", id) for receiver tables, ("other", name) otherwise."""
    spans = []
    table, start = None, 0
    for i, line in enumerate(lines):
        m = HEADER_RE.match(line)
        if m and not line.lstrip().startswith("[["):
            spans.append((table, start, i))
            name = m.group(1)
            rm = RECEIVER_HEADER_RE.match(name)
            table = ("receiver", rm.group(1)) if rm else ("other", name)
            start = i
        elif line.lstrip().startswith("[["):
            spans.append((table, start, i))
            table, start = ("other", line.strip()), i
    spans.append((table, start, len(lines)))
    return spans


def find_span(lines, receiver):
    for table, start, end in split_sections(lines):
        if receiver is None and table is None:
            return start, end, False
        if receiver is not None and table and table[0] == "receiver" and table[1].upper() == receiver.upper():
            return start, end, True
    return None


def apply_change(lines, receiver, key, lit):
    span = find_span(lines, receiver)
    if span is None:
        if lit is None:
            return lines
        out = list(lines)
        while out and out[-1].strip() == "":
            out.pop()
        if out:
            out.append("")
        out.append(f'[receiver."{receiver}"]')
        out.append(f"{key} = {lit}")
        return out
    start, end, has_header = span
    body_start = start + 1 if has_header else start
    for i in range(body_start, end):
        m = KEY_LINE_RE.match(lines[i])
        if m and m.group(2) == key:
            out = list(lines)
            if lit is None:
                del out[i]
                if has_header:
                    out = drop_empty_table(out, start)
            else:
                out[i] = f"{key} = {lit}"
            return out
    if lit is None:
        return lines
    insert = body_start
    for i in range(body_start, end):
        if lines[i].strip() != "":
            insert = i + 1
    out = list(lines)
    out.insert(insert, f"{key} = {lit}")
    return out


def drop_empty_table(lines, header_index):
    end = len(lines)
    for i in range(header_index + 1, len(lines)):
        if HEADER_RE.match(lines[i]) or lines[i].lstrip().startswith("[["):
            end = i
            break
    if any(line.strip() for line in lines[header_index + 1:end]):
        return lines
    out = lines[:header_index] + lines[end:]
    while header_index > 0 and header_index <= len(out) and out[header_index - 1].strip() == "" and (
        header_index == len(out) or out[header_index].strip() == ""
    ):
        del out[header_index - 1]
        header_index -= 1
    while out and out[-1].strip() == "":
        out.pop()
    return out


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def cmd_get():
    text = read_text(config_path())
    try:
        doc = tomllib.loads(text) if text else {}
    except tomllib.TOMLDecodeError as e:
        print(json.dumps({"error": f"sender.toml doesn't parse: {e}"}))
        return 1
    print(json.dumps(doc))
    return 0


def cmd_set(args):
    receiver = None
    changes = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--receiver":
            if i + 1 >= len(args):
                raise ArgError("--receiver needs an id")
            receiver = args[i + 1]
            i += 2
            continue
        if a == "--":
            i += 1
            continue
        if "=" not in a:
            raise ArgError(f"expected key=value, got {a!r}")
        key, value = a.split("=", 1)
        changes.append((key.strip(), value.strip()))
        i += 1
    if receiver is not None and not ID_RE.match(receiver):
        raise ArgError("invalid receiver id")
    if not changes:
        raise ArgError("nothing to set")
    scope = "receiver" if receiver is not None else "top"
    lits = [(k, literal(scope, k, v)) for k, v in changes]

    path = config_path()
    original = read_text(path)
    if original:
        try:
            validate_document(tomllib.loads(original))
        except tomllib.TOMLDecodeError as e:
            raise ConfigError(f"sender.toml doesn't parse, not editing it: {e}") from None
    lines = original.splitlines()
    for key, lit in lits:
        lines = apply_change(lines, receiver, key, lit)
    result = "\n".join(lines) + ("\n" if lines else "")

    try:
        validate_document(tomllib.loads(result))
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"edit would break sender.toml: {e}") from None

    os.makedirs(os.path.dirname(path), exist_ok=True)
    if original:
        write_atomic(path + ".bak", original)
    else:
        # Remember that there was no file, so a rollback removes it again.
        write_atomic(path + ".bak", "")
    write_atomic(path, result)
    return 0


def write_atomic(path, text):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        os.write(fd, text.encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)


def cmd_rollback():
    path = config_path()
    bak = path + ".bak"
    if not os.path.exists(bak):
        raise ConfigError("no backup to restore")
    text = read_text(bak)
    if text == "":
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
    else:
        write_atomic(path, text)
    return 0


def main(argv):
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 1
    try:
        if argv[0] == "get":
            return cmd_get()
        if argv[0] == "set":
            return cmd_set(argv[1:])
        if argv[0] == "rollback":
            return cmd_rollback()
        raise ArgError(f"unknown command {argv[0]!r}")
    except ConfigError as e:
        print(str(e), file=sys.stderr)
        return e.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
