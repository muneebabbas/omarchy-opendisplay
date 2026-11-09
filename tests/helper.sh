#!/usr/bin/env bash
# The checks below pass single-quoted scripts to `bash -c` on purpose.
# shellcheck disable=SC2016
# Tests for bin/omarchy-opendisplay and its python helpers.
#
#   bash tests/helper.sh
#
# Runs against a fake od-sender, fake systemctl/systemd-run/notify-send and a
# temporary HOME + XDG dirs, so it never touches the real session or network.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/bin/omarchy-opendisplay"
FIX="$ROOT/tests/fixtures"
ID="A0EC2343-F05E-4776-8903-8C62BB114896"

T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

export HOME="$T/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_RUNTIME_DIR="$T/run"
export FAKE="$T/fake"
mkdir -p "$HOME/.local/bin" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" "$FAKE" "$T/bin"

# --- fakes ------------------------------------------------------------------

cat > "$T/bin/od-sender" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) echo "od-sender ${FAKE_VERSION:-1.30.2}" ;;
  doctor)
    # Pops the next exit code from $FAKE/doctor (one per line); default 0.
    if [[ -s $FAKE/doctor ]]; then
      code="$(head -n1 "$FAKE/doctor")"; sed -i 1d "$FAKE/doctor"; exit "$code"
    fi
    exit 0 ;;
  *) echo "fake od-sender $*"; exit 0 ;;
esac
EOF
# Keeps per-unit state in $FAKE/units/<unit, "/" replaced> (active|failed|
# inactive; missing = inactive) and records every call in $FAKE/calls.
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE/calls"
mkdir -p "$FAKE/units" "$FAKE/desc"
args=("$@")
[[ ${args[0]-} == --user ]] && args=("${args[@]:1}")
verb="${args[0]-}"
units=() props="" value=0
for ((i = 1; i < ${#args[@]}; i++)); do
  a="${args[i]}"
  case "$a" in
    -p) props="${args[++i]}" ;;
    --value) value=1 ;;
    -o) ((i++)) ;;
    *.service) units+=("$a") ;;
  esac
done
file() { printf '%s/units/%s' "$FAKE" "${1//\//_}"; }
state() { local f; f="$(file "$1")"; if [[ -r $f ]]; then cat "$f"; else echo inactive; fi; }
set_state() { printf '%s\n' "$2" > "$(file "$1")"; }
case "$verb" in
  show)
    if [[ $value == 1 ]]; then
      for u in "${units[@]}"; do
        case "$props" in
          ActiveState) state "$u" ;;
          InactiveExitTimestamp) [[ $(state "$u") != inactive ]] && echo "@1700000000" ;;
        esac
      done
    else
      first=1
      for u in "${units[@]}"; do
        [[ $first == 1 ]] || echo
        first=0
        printf 'Id=%s\nActiveState=%s\nExecMainStatus=0\nDescription=%s\nInactiveExitTimestamp=@1700000000\n' \
          "$u" "$(state "$u")" "$(cat "$FAKE/desc/${u//\//_}" 2>/dev/null)"
      done
    fi ;;
  stop|disable) for u in "${units[@]}"; do set_state "$u" inactive; done ;;
  start|restart|enable) for u in "${units[@]}"; do set_state "$u" active; done ;;
  reset-failed) for u in "${units[@]}"; do [[ $(state "$u") == failed ]] && set_state "$u" inactive; done ;;
  list-units)
    out=""
    for f in "$FAKE"/units/*; do
      [[ -e $f ]] || continue
      u="$(basename "$f")"; st="$(cat "$f")"
      [[ $st == inactive ]] && continue
      [[ $u == opendisplay-* || $u == od-sender@* ]] || continue
      u="${u//\\/\\\\}"
      out+="${out:+,}{\"unit\":\"$u\",\"active\":\"$st\"}"
    done
    echo "[$out]" ;;
esac
exit 0
EOF
cat > "$T/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE/systemd-run"
echo "systemd-run $*" >> "$FAKE/calls"
[[ -n ${FAKE_RUN_FAIL-} ]] && exit 1
mkdir -p "$FAKE/units" "$FAKE/desc"
unit="" desc=""
for a in "$@"; do
  case "$a" in
    --unit=*) unit="${a#--unit=}" ;;
    --description=*) desc="${a#--description=}" ;;
  esac
done
echo active > "$FAKE/units/$unit"
printf '%s' "$desc" > "$FAKE/desc/$unit"
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/notify-send"
chmod +x "$T/bin/"*
# A clean PATH (so a real od-sender in ~/.local/bin can't leak in), keeping the
# python3 the tests were started with, so CI can pin the minimum version.
PYDIR="$(dirname "$(command -v python3)")"
export PATH="$T/bin:$PYDIR:/usr/local/bin:/usr/bin:/bin"

pass=0
echo "python: $(python3 --version)"
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*" >&2; }
check() {  # <name> <command...>
  local name="$1"; shift
  if "$@"; then ok; else bad "$name"; fi
}
contains() { [[ $1 == *"$2"* ]]; }
set_unit() { mkdir -p "$FAKE/units"; printf '%s\n' "$2" > "$FAKE/units/${1//\//_}"; }
reset_fake() { rm -rf "$FAKE/units" "$FAKE/desc" "$FAKE/calls" "$FAKE/systemd-run"; }
code_of() { "$@" >/dev/null 2>&1; echo $?; }
TRANSIENT="opendisplay-a0ec2343.service"
TEMPLATE='od-sender@A0EC2343\x2dF05E\x2d4776\x2d8903\x2d8C62BB114896.service'

CFG="$XDG_CONFIG_HOME/opendisplay/sender.toml"

# --- unit names -------------------------------------------------------------

names="$("$HELPER" unit-names "$ID")"
check "transient unit name" contains "$names" "opendisplay-a0ec2343.service"
check "template unit name" contains "$names" 'od-sender@A0EC2343\x2dF05E\x2d4776\x2d8903\x2d8C62BB114896.service'
check "output name" contains "$names" "od-a0ec23"
check "addr unit name" bash -c '[[ $("$0" addr-unit 10.93.10.226:9000) =~ ^opendisplay-addr-[0-9a-f]{8}\.service$ ]]' "$HELPER"
check "addr unit accepts IPv6" bash -c '"$0" addr-unit "[fe80::1]:9000" >/dev/null' "$HELPER"
check "addr unit rejects backslash" bash -c '! "$0" addr-unit "a\\b:9000" 2>/dev/null' "$HELPER"

for bad_id in "-rf" "../../etc" "A0EC2343;rm" "a0ec" '$(id)' "--to=x"; do
  check "rejects id $bad_id" bash -c '! "$0" connect "$1" 2>/dev/null' "$HELPER" "$bad_id"
done
for bad_addr in "-oProxy:1" "1.2.3.4" "1.2.3.4:0" "1.2.3.4:70000" 'a;b:9000'; do
  check "rejects addr $bad_addr" bash -c '! "$0" connect-addr "$1" 2>/dev/null' "$HELPER" "$bad_addr"
done
check "rejects unit for logs" bash -c '! "$0" logs "sshd.service" 2>/dev/null' "$HELPER"
check "disconnect rejects junk" bash -c '! "$0" disconnect "x; rm -rf ~" 2>/dev/null' "$HELPER"

# --- connect builds a safe systemd-run command ------------------------------

reset_fake
"$HELPER" connect "$ID" >/dev/null
run="$(cat "$FAKE/systemd-run" 2>/dev/null)"
check "connect uses the transient unit" contains "$run" "--unit=opendisplay-a0ec2343.service"
check "connect sets NO_COLOR" contains "$run" "--setenv=NO_COLOR=1"
check "connect has Restart=no" contains "$run" "--property=Restart=no"
check "connect passes --to=<id>" contains "$run" "--to=$ID"
check "connect doesn't --collect" bash -c '! grep -q -- --collect "$0"' "$FAKE/systemd-run"
check "connect names the unit with the description contract" contains "$run" "--description=OpenDisplay to $ID"
rm -f "$FAKE/systemd-run"
"$HELPER" connect "$ID" >/dev/null
check "connect is a no-op when the transient unit is active" [ ! -e "$FAKE/systemd-run" ]
set_unit "$TRANSIENT" failed
"$HELPER" connect "$ID" >/dev/null
check "connect resets a failed transient first" grep -q "^systemctl --user reset-failed -- $TRANSIENT" "$FAKE/calls"
check "connect restarts after resetting" [ -e "$FAKE/systemd-run" ]
reset_fake
"$HELPER" connect-addr 10.93.10.226:9000 >/dev/null
check "connect-addr passes --to=<addr>" grep -qx -- "--to=10.93.10.226:9000" "$FAKE/systemd-run"

# disconnect and restart pick the right units
reset_fake
set_unit "$TRANSIENT" active
set_unit "$TEMPLATE" active
"$HELPER" disconnect "$ID"
check "disconnect <id> stops the transient unit" grep -q "^systemctl --user stop -- $TRANSIENT" "$FAKE/calls"
check "disconnect <id> stops the template unit" grep -qF "systemctl --user stop -- $TEMPLATE" "$FAKE/calls"
set_unit "$TRANSIENT" active
set_unit "$TEMPLATE" active
rm -f "$FAKE/calls"
"$HELPER" disconnect "$TRANSIENT"
check "disconnect <unit> stops that unit" grep -q "^systemctl --user stop -- $TRANSIENT" "$FAKE/calls"
check "disconnect <unit> stops only that unit" bash -c '! grep -qF "stop -- $1" "$0"' "$FAKE/calls" "$TEMPLATE"
set_unit "$TRANSIENT" active
set_unit "$TEMPLATE" active
rm -f "$FAKE/calls"
"$HELPER" restart "$ID"
check "restart prefers the template unit" grep -qF "systemctl --user restart -- $TEMPLATE" "$FAKE/calls"
check "restart touches only one unit" bash -c '! grep -q "restart -- $1" "$0"' "$FAKE/calls" "$TRANSIENT"
set_unit "$TEMPLATE" inactive
rm -f "$FAKE/calls"
"$HELPER" restart "$ID"
check "restart falls back to the transient unit" grep -q "^systemctl --user restart -- $TRANSIENT" "$FAKE/calls"

# exit codes that don't need other state
reset_fake
check "invalid id exits 2" [ "$(code_of "$HELPER" connect "-rf")" = 2 ]
check "invalid address exits 2" [ "$(code_of "$HELPER" connect-addr "1.2.3.4")" = 2 ]
check "invalid unit exits 2" [ "$(code_of "$HELPER" logs "sshd.service")" = 2 ]
check "unknown command exits 2" [ "$(code_of "$HELPER" frobnicate)" = 2 ]
check "status rejects other arguments" [ "$(code_of "$HELPER" status --xml)" = 2 ]
check "autoconnect on without the template exits 7" [ "$(code_of "$HELPER" autoconnect "$ID" on)" = 7 ]
check "autoconnect with a bad mode exits 2" [ "$(code_of "$HELPER" autoconnect "$ID" maybe)" = 2 ]
check "check-update rejects other arguments" [ "$(code_of "$HELPER" check-update --bogus)" = 2 ]

# change stamp
STAMP="$XDG_RUNTIME_DIR/omarchy-opendisplay/changed"
rm -f "$STAMP"
"$HELPER" connect "$ID" >/dev/null
check "connect writes the change stamp" [ -s "$STAMP" ]
rm -f "$STAMP"
FAKE_RUN_FAIL=1 "$HELPER" connect-addr 10.93.10.226:9000 >/dev/null 2>&1
check "a failed connect still writes the change stamp" [ -s "$STAMP" ]
echo 123 > "$STAMP"
"$HELPER" status >/dev/null
check "status leaves an existing stamp alone" [ "$(cat "$STAMP")" = 123 ]
rm -f "$STAMP"
"$HELPER" status >/dev/null
check "status creates a missing stamp" [ -e "$STAMP" ]
reset_fake

# install-plan
UTIL="$ROOT/bin/opendisplay-util.py"
plan="$(python3 -I "$UTIL" install-plan <<< '{"sessions": [], "units": [
  {"unit": "od-sender@x.service", "state": "active", "template": true, "to": "AAAAAAAA-1"},
  {"unit": "opendisplay-a0ec2343.service", "state": "activating", "template": false, "to": "A0EC2343-F05E"},
  {"unit": "opendisplay-addr-0123abcd.service", "state": "active", "template": false, "to": "10.0.0.1:9000"},
  {"unit": "opendisplay-deadbeef.service", "state": "failed", "template": false, "to": "deadbeef"}]}')"
check "install-plan lists template, id and addr units" [ "$plan" = "template od-sender@x.service AAAAAAAA-1
id opendisplay-a0ec2343.service A0EC2343-F05E
addr opendisplay-addr-0123abcd.service 10.0.0.1:9000" ]
plan="$(python3 -I "$UTIL" install-plan <<< '{"sessions": [{"unit": null}], "units": [
  {"unit": "opendisplay-a0ec2343.service", "state": "active", "template": false, "to": "x"}]}')"
check "install-plan reports EXTERNAL for a session outside units" [ "$plan" = EXTERNAL ]

# --- version ----------------------------------------------------------------

v="$("$HELPER" version)"
check "version parses" contains "$v" '"version": "1.30.2"'
check "version on PATH is managed=other" contains "$v" '"managed": "other"'
mv "$T/bin/od-sender" "$HOME/.local/bin/od-sender"
v="$("$HELPER" version)"
check "version in ~/.local/bin is managed=user" contains "$v" '"managed": "user"'
v="$(FAKE_VERSION=garbage "$HELPER" version)"
check "unparseable version is not installed" contains "$v" '"installed": false'

# --- status -----------------------------------------------------------------

mkdir -p "$XDG_RUNTIME_DIR/opendisplay"
echo 999999999 > "$XDG_RUNTIME_DIR/opendisplay/od-a0ec23.lock"
s="$("$HELPER" status --json)"
check "stale lock file is not a session" contains "$s" '"sessions": []'
check "status reports the template as missing" contains "$s" '"templateInstalled": false'
mkdir -p "$XDG_CONFIG_HOME/systemd/user/graphical-session.target.wants"
touch "$XDG_CONFIG_HOME/systemd/user/od-sender@.service" \
  "$XDG_CONFIG_HOME/systemd/user/graphical-session.target.wants/od-sender@A0EC2343\\x2dF05E\\x2d4776\\x2d8903\\x2d8C62BB114896.service"
s="$("$HELPER" status --json)"
check "status lists enabled auto-connect ids" contains "$s" "\"autoconnect\": [\"$ID\"]"
check "status sees the template unit" contains "$s" '"templateInstalled": true'

# --- config -----------------------------------------------------------------

check "config-get on a missing file is {}" [ "$("$HELPER" config-get)" = "{}" ]

mkdir -p "$(dirname "$CFG")"
cat > "$CFG" <<'EOF'
# my sender settings
to = "iPad"            # default receiver
position = "auto-right"
workspace = "8"

[receiver."a0ec2343-f05e-4776-8903-8c62bb114896"]
# keep this comment
scale = 2
EOF
"$HELPER" config-set --receiver "$ID" bitrate-mbps=35
check "config-set succeeds" [ $? -eq 0 ]
check "keeps comments" grep -q "^# my sender settings" "$CFG"
check "keeps inline comments on other keys" grep -q 'to = "iPad"            # default receiver' "$CFG"
check "keeps unknown keys" grep -q '^workspace = "8"' "$CFG"
check "keeps receiver comment" grep -q "^# keep this comment" "$CFG"
check "writes into the existing table (case-insensitive id)" bash -c '[ "$(grep -c "^\[receiver" "$0")" = 1 ] && grep -q "^bitrate-mbps = 35" "$0"' "$CFG"
check "made a backup" [ -f "$CFG.bak" ]

"$HELPER" config-set max-fps=90 encoder=openh264 tailscale=false
check "top-level keys go before the first table" python3 -c '
import tomllib,sys; d=tomllib.load(open(sys.argv[1],"rb"))
assert d["max-fps"]==90 and d["encoder"]=="openh264" and d["tailscale"] is False
assert "max-fps" not in d["receiver"]["a0ec2343-f05e-4776-8903-8c62bb114896"]' "$CFG"

"$HELPER" config-set --receiver "$ID" bitrate-mbps= scale=
check "deleting the last keys keeps a table that still has a comment" grep -q "^# keep this comment" "$CFG"
"$HELPER" config-set --receiver "BEEF0000-0000-0000-0000-000000000001" scale=1.5
check "creates a new receiver table" grep -q '^\[receiver."BEEF0000-0000-0000-0000-000000000001"\]' "$CFG"
"$HELPER" config-set --receiver "BEEF0000-0000-0000-0000-000000000001" scale=
check "removes an emptied receiver table" bash -c '! grep -q BEEF0000 "$0"' "$CFG"

before="$(cat "$CFG")"
for kv in position=auto-left workspace=3 to=x capture=wlr bitrate-mbps=20 "max-fps=999" "encoder=nvenc" "tailscale=yes"; do
  check "rejects top-level $kv" bash -c '! "$0" config-set "$1" 2>/dev/null' "$HELPER" "$kv"
done
for kv in max-fps=60 "bitrate-mbps=0" "bitrate-mbps=2.5" "scale=1.3" "scale=9" 'scale="x"'; do
  check "rejects receiver $kv" bash -c '! "$0" config-set --receiver "$1" "$2" 2>/dev/null' "$HELPER" "$ID" "$kv"
done
check "a rejected value exits 2" [ "$(code_of "$HELPER" config-set max-fps=999)" = 2 ]
check "rejects a bad receiver id" bash -c '! "$0" config-set --receiver "-x" scale=2 2>/dev/null' "$HELPER"
check "rejected writes leave the file untouched" [ "$(cat "$CFG")" = "$before" ]

printf '0\n2\n' > "$FAKE/doctor"
err="$("$HELPER" config-set max-fps=30 2>&1)"
code=$?
check "doctor 0 -> 2 is reported (exit 6)" [ $code -eq 6 ]
check "doctor 0 -> 2 message" contains "$err" "od-sender rejected the setting"
check "doctor 0 -> 2 rolls back" [ "$(cat "$CFG")" = "$before" ]

printf '2\n2\n' > "$FAKE/doctor"
"$HELPER" config-set max-fps=30 2>/dev/null
code=$?
check "already-broken doctor keeps the change (exit 5)" [ $code -eq 5 ]
check "already-broken doctor keeps the change" grep -q '^max-fps = 30' "$CFG"

printf 'to = [broken\n' > "$CFG"
check "won't edit a file that doesn't parse" bash -c '! "$0" config-set max-fps=60 2>/dev/null' "$HELPER"
check "config-get reports a parse error" bash -c '! "$0" config-get >/dev/null' "$HELPER"
rm -f "$CFG" "$CFG.bak"
"$HELPER" config-set --receiver "$ID" bitrate-mbps=8
printf '0\n2\n' > "$FAKE/doctor"
"$HELPER" config-set max-fps=30 2>/dev/null
check "rollback restores, not deletes, a file that existed" grep -q "bitrate-mbps = 8" "$CFG"
rm -f "$CFG" "$CFG.bak"
printf '0\n2\n' > "$FAKE/doctor"
"$HELPER" config-set max-fps=30 2>/dev/null
check "rollback removes a file that didn't exist" [ ! -e "$CFG" ]

# --- check-update -----------------------------------------------------------

u="$(OMARCHY_OPENDISPLAY_RELEASE_FILE="$FIX/release.json" "$HELPER" check-update)"
check "check-update finds the release" contains "$u" '"latest": "1.30.2"'
check "check-update: same version is not newer" contains "$u" '"newer": false'
check "check-update picks this arch's asset" contains "$u" "od-sender-$(uname -m)-unknown-linux-gnu.tar.gz\""
check "check-update carries the API digest" contains "$u" '"digest": "sha256:'
u="$(FAKE_VERSION=1.29.9 OMARCHY_OPENDISPLAY_RELEASE_FILE="$FIX/release.json" "$HELPER" check-update)"
check "check-update: older install sees newer" contains "$u" '"newer": true'
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["tag_name"]="v1.100.0"; json.dump(d,open(sys.argv[2],"w"))' "$FIX/release.json" "$T/rel-100.json"
u="$(OMARCHY_OPENDISPLAY_RELEASE_FILE="$T/rel-100.json" "$HELPER" check-update)"
check "check-update compares numerically" contains "$u" '"newer": true'
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["prerelease"]=True; json.dump(d,open(sys.argv[2],"w"))' "$FIX/release.json" "$T/rel-pre.json"
check "check-update skips prereleases" bash -c '! OMARCHY_OPENDISPLAY_RELEASE_FILE="$1" "$0" check-update 2>/dev/null' "$HELPER" "$T/rel-pre.json"
head -c 1100000 /dev/zero > "$T/rel-big.json"
check "check-update refuses release JSON over 1 MB" bash -c '! OMARCHY_OPENDISPLAY_RELEASE_FILE="$1" "$0" check-update 2>/dev/null' "$HELPER" "$T/rel-big.json"

# a fresh cache is reused without network; --force asks GitHub
CACHE_DIR="$XDG_CACHE_HOME/omarchy-opendisplay"
mkdir -p "$CACHE_DIR" "$T/curlfail"
printf '#!/bin/sh\nexit 7\n' > "$T/curlfail/curl"
chmod +x "$T/curlfail/curl"
cp "$FIX/release.json" "$CACHE_DIR/release.json"
touch "$CACHE_DIR/release.json"
u="$(PATH="$T/curlfail:$PATH" "$HELPER" check-update)"
check "check-update uses a fresh cache without network" contains "$u" '"latest": "1.30.2"'
check "check-update reports checkedAt" contains "$u" "\"checkedAt\": $(stat -c %Y "$CACHE_DIR/release.json")"
PATH="$T/curlfail:$PATH" "$HELPER" check-update --force >/dev/null 2>&1
check "check-update --force asks GitHub (exit 11)" [ $? -eq 11 ]
touch -d '7 hours ago' "$CACHE_DIR/release.json"
PATH="$T/curlfail:$PATH" "$HELPER" check-update >/dev/null 2>&1
check "check-update with a stale cache asks GitHub (exit 11)" [ $? -eq 11 ]
rm -f "$CACHE_DIR/release.json"

# --- shared validation corpus (tests/fixtures/validation.json) ---------------

# Prints "<kind> <json string>" lines; the helper decodes each with python so
# odd characters (spaces, quotes, backslashes, empty) survive intact.
corpus_value() { python3 -I -c 'import json,sys; sys.stdout.write(json.loads(sys.argv[1]))' "$1"; }
corpus_lines() {  # <group> <valid|invalid>
  python3 -I -c 'import json,sys; [print(json.dumps(x)) for x in json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]]]' "$FIX/validation.json" "$1" "$2"
}
for group in ids addrs; do
  if [[ $group == ids ]]; then sub=unit-names; else sub=addr-unit; fi
  for kind in valid invalid; do
    want=2; [[ $kind == valid ]] && want=0
    while IFS= read -r line; do
      v="$(corpus_value "$line")"
      check "corpus: $group $kind '$v' exits $want" [ "$(code_of "$HELPER" "$sub" "$v")" = "$want" ]
    done < <(corpus_lines "$group" "$kind")
  done
done
while IFS=$'\t' read -r scope key value ok; do
  [[ $value == - ]] && value=""
  rm -f "$CFG" "$CFG.bak"; : > "$FAKE/doctor"
  if [[ $scope == receiver ]]; then
    "$HELPER" config-set --receiver "$ID" "$key=$value" >/dev/null 2>&1
  else
    "$HELPER" config-set "$key=$value" >/dev/null 2>&1
  fi
  rc=$?
  if [[ $ok == 1 ]]; then
    check "corpus: $scope $key=$value is accepted" [ $rc -eq 0 ]
  else
    check "corpus: $scope $key=$value is rejected" [ $rc -ne 0 ]
  fi
done < <(python3 -I -c 'import json,sys
for e in json.load(open(sys.argv[1]))["settings"]:
    print("\t".join([e["scope"], e["key"], e["value"] or "-", "1" if e["ok"] else "0"]))' "$FIX/validation.json")
rm -f "$CFG" "$CFG.bak"

# --- install ----------------------------------------------------------------

ARCH="$(uname -m)"
TOP="od-sender-$ARCH-unknown-linux-gnu"
ASSET="$TOP.tar.gz"
DL="$T/dl"
mkdir -p "$DL"

make_release() {  # <tag> -> release JSON for the tarball in $DL, with correct digests
  local sum
  sum="$(sha256sum "$DL/$ASSET" | cut -d' ' -f1)"
  printf '%s  %s\n' "$sum" "$ASSET" > "$DL/$ASSET.sha256"
  python3 - "$1" "$sum" "$ASSET" "$T/release.json" <<'EOF'
import json, sys
tag, digest, name, out = sys.argv[1:5]
base = f"https://github.com/peetzweg/opendisplay/releases/download/{tag}/"
json.dump({"tag_name": tag, "draft": False, "prerelease": False,
           "html_url": f"https://github.com/peetzweg/opendisplay/releases/tag/{tag}",
           "assets": [{"name": name, "browser_download_url": base + name, "digest": "sha256:" + digest},
                      {"name": name + ".sha256", "browser_download_url": base + name + ".sha256", "digest": "sha256:" + "0" * 64}]},
          open(out, "w"))
EOF
}

build_tarball() {  # <version>
  rm -rf "$T/src" && mkdir -p "$T/src/$TOP"
  cat > "$T/src/$TOP/od-sender" <<EOF
#!/usr/bin/env bash
[[ \$1 == --version ]] && echo "od-sender $1"
exit 0
EOF
  cat > "$T/src/$TOP/install.sh" <<'EOF'
#!/usr/bin/env bash
install -Dm755 "$(dirname "$0")/od-sender" "$HOME/.local/bin/od-sender"
EOF
  chmod +x "$T/src/$TOP/"*
  tar -czf "$DL/$ASSET" -C "$T/src" "$TOP"
}

run_install() {
  OMARCHY_OPENDISPLAY_RELEASE_FILE="$T/release.json" OMARCHY_OPENDISPLAY_DOWNLOAD_DIR="$DL" "$HELPER" install 2>&1
}

build_tarball 9.9.9
make_release v9.9.9
out="$(run_install)"
check "install succeeds with matching checksums ($out)" [ "$("$HOME/.local/bin/od-sender" --version)" = "od-sender 9.9.9" ]
check "install leaves no temp dirs" bash -c '! ls -d "$0"/install.* 2>/dev/null' "$XDG_CACHE_HOME/omarchy-opendisplay"
check "install keeps a log for Details" [ -s "$XDG_CACHE_HOME/omarchy-opendisplay/last-update.log" ]

build_tarball 9.9.10
make_release v9.9.10
echo "0000000000000000000000000000000000000000000000000000000000000000  $ASSET" > "$DL/$ASSET.sha256"
out="$(run_install)"
check "install refuses a .sha256 mismatch" contains "$out" "checksum mismatch"
check "mismatch leaves the old binary" [ "$("$HOME/.local/bin/od-sender" --version)" = "od-sender 9.9.9" ]

make_release v9.9.10
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["assets"][0]["digest"]="sha256:"+"1"*64; json.dump(d,open(sys.argv[1],"w"))' "$T/release.json"
out="$(run_install)"
check "install refuses an API digest mismatch" contains "$out" "GitHub's digest"

make_release v9.9.10
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); del d["assets"][0]["digest"]; json.dump(d,open(sys.argv[1],"w"))' "$T/release.json"
out="$(run_install)"
check "install refuses when the API digest is missing" contains "$out" "no checksum"

make_release v9.9.10
rm -f "$DL/$ASSET.sha256"
out="$(run_install)"
check "install refuses when the .sha256 file is missing" contains "$out" "failed"

# A tarball with a ../ entry.
rm -rf "$T/src" && mkdir -p "$T/src/$TOP"
echo x > "$T/src/evil"
printf '#!/bin/sh\n' > "$T/src/$TOP/od-sender"; printf '#!/bin/sh\n' > "$T/src/$TOP/install.sh"
python3 - "$DL/$ASSET" "$T/src" "$TOP" <<'EOF'
import sys, tarfile, os
out, src, top = sys.argv[1:4]
with tarfile.open(out, "w:gz") as tf:
    tf.add(os.path.join(src, top), arcname=top)
    tf.add(os.path.join(src, "evil"), arcname=top + "/../../evil")
EOF
make_release v9.9.10
out="$(run_install)"
check "install refuses a ../ entry" contains "$out" "unsafe path"

# A tarball with a symlink.
rm -rf "$T/src" && mkdir -p "$T/src/$TOP"
printf '#!/bin/sh\n' > "$T/src/$TOP/install.sh"
ln -s /bin/sh "$T/src/$TOP/od-sender"
tar -czf "$DL/$ASSET" -C "$T/src" "$TOP"
make_release v9.9.10
out="$(run_install)"
check "install refuses a symlink entry" contains "$out" "not a regular file"
check "refused installs leave the old binary" [ "$("$HOME/.local/bin/od-sender" --version)" = "od-sender 9.9.9" ]

# A failed install brings the stopped sessions back.
build_tarball 9.9.11
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/src/$TOP/install.sh"
tar -czf "$DL/$ASSET" -C "$T/src" "$TOP"
make_release v9.9.11
reset_fake
"$HELPER" connect "$ID" >/dev/null
rm -f "$FAKE/systemd-run"
echo 5 > "$XDG_RUNTIME_DIR/omarchy-opendisplay/changed"
run_install >/dev/null
code=$?
check "a failing install.sh exits non-zero" [ $code -ne 0 ]
check "a failing install.sh restarts the stopped session" [ -e "$FAKE/systemd-run" ]
check "the restarted session is active again" [ "$(cat "$FAKE/units/$TRANSIENT")" = active ]
check "a failing install.sh still stamps the change" [ "$(cat "$XDG_RUNTIME_DIR/omarchy-opendisplay/changed")" != 5 ]
check "a failing install.sh leaves no temp dirs" bash -c '! ls -d "$0"/install.* 2>/dev/null' "$XDG_CACHE_HOME/omarchy-opendisplay"
reset_fake

# pacman-managed installs are information only.
cat > "$T/bin/pacman" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/bin/pacman"
mv "$HOME/.local/bin/od-sender" "$T/bin/od-sender"
out="$(run_install)"
check "install refuses a pacman-managed od-sender" contains "$out" "installed by pacman"
OMARCHY_OPENDISPLAY_RELEASE_FILE="$T/release.json" OMARCHY_OPENDISPLAY_DOWNLOAD_DIR="$DL" "$HELPER" install >/dev/null 2>&1
check "pacman-managed install exits 10" [ $? -eq 10 ]
rm -f "$T/bin/pacman" "$T/bin/od-sender"
check "a missing od-sender exits 8" [ "$(code_of "$HELPER" connect "$ID")" = 8 ]

echo "$pass passed, $fail failed"
(( fail == 0 ))
