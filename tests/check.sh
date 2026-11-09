#!/usr/bin/env bash
# Runs every check the CI runs:
#
#   bash tests/check.sh               tests + lint + QML parse + manifest validation
#   bash tests/check.sh --tests-only  just the two test suites
#
# Required: bash, node, python3 >= 3.11, jq and the usual GNU userland (see
# README "Development"). Linters are taken from `uvx` at pinned versions when
# uv is installed, otherwise from PATH. Locally a missing linter is skipped
# with a notice; under CI (CI=true) it fails the run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

SHELLCHECK_PIN="shellcheck-py==0.11.0.1"
RUFF_PIN="ruff==0.17.4"
# omarchy-plugin-validate from omacom/omarchy, pinned by commit and checksum.
VALIDATOR_URL="https://raw.githubusercontent.com/omacom/omarchy/b99593ed3c5d104210394669efc88a684f76ddbf/bin/omarchy-plugin-validate"
VALIDATOR_SHA256="b6f6aba33a329a5ccd339050fbb2ce82272b791dd1f0d6a28c1837caa035b8c4"

failed=()
skipped=()

step() {  # <name> <command...>
  local name="$1"; shift
  printf '\n== %s\n' "$name"
  if "$@"; then printf -- '-- ok: %s\n' "$name"; else failed+=("$name"); printf -- '-- FAILED: %s\n' "$name"; fi
}

missing() {  # <name> <what>
  if [[ ${CI-} == true ]]; then
    printf '\n== %s\n-- FAILED: %s not available\n' "$1" "$2"
    failed+=("$1")
  else
    printf '\n== %s\n-- skipped: %s not available\n' "$1" "$2"
    skipped+=("$1")
  fi
}

require() {
  local ok=1 tool
  for tool in bash node python3 jq tar sha256sum sha1sum flock timeout systemd-escape; do
    command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; ok=0; }
  done
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' || { echo "python3 >= 3.11 is required (tomllib)" >&2; ok=0; }
  (( ok ))
}

shellcheck_cmd() {
  if command -v uvx >/dev/null; then echo "uvx --from $SHELLCHECK_PIN shellcheck"
  elif command -v shellcheck >/dev/null; then echo shellcheck
  else return 1; fi
}

ruff_cmd() {
  if command -v uvx >/dev/null; then echo "uvx $RUFF_PIN"
  elif command -v ruff >/dev/null; then echo ruff
  else return 1; fi
}

# Qt 6's qmlformat; a Qt 5 one (qt5-declarative) can't parse Qt 6 QML.
qmlformat_cmd() {
  local c
  for c in /usr/lib/qt6/bin/qmlformat /usr/lib/qt6/libexec/qmlformat /usr/lib/x86_64-linux-gnu/qt6/bin/qmlformat qmlformat6 qmlformat; do
    command -v "$c" >/dev/null || continue
    [[ $("$c" --version 2>/dev/null) == "qmlformat 6."* ]] && { echo "$c"; return 0; }
  done
  return 1
}

# qmlformat parses each file and exits non-zero on a syntax error. A full
# qmllint needs the running shell's modules (qs.Commons, qs.Ui, Quickshell),
# which aren't available outside an Omarchy install.
qml_parse() {
  local q="$1" f rc=0
  for f in ./*.qml; do
    "$q" "$f" >/dev/null || { echo "qmlformat couldn't parse $f" >&2; rc=1; }
  done
  return $rc
}

validate_manifest() {
  if command -v omarchy >/dev/null; then
    omarchy plugin validate "$ROOT"
    return
  fi
  local tmp rc
  tmp="$(mktemp)"
  if ! curl --proto '=https' -fsSL --max-time 30 -o "$tmp" "$VALIDATOR_URL"; then
    rm -f "$tmp"; echo "couldn't download the Omarchy plugin validator" >&2; return 1
  fi
  if [[ $(sha256sum "$tmp" | cut -d' ' -f1) != "$VALIDATOR_SHA256" ]]; then
    rm -f "$tmp"; echo "validator checksum mismatch; update VALIDATOR_URL and VALIDATOR_SHA256 together" >&2; return 1
  fi
  bash "$tmp" "$ROOT"
  rc=$?
  rm -f "$tmp"
  return $rc
}

step "required tools" require || true
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "install the missing tools first (README > Development)" >&2
  exit 1
fi

step "Model.js tests (node tests/run.js)" node tests/run.js
step "helper tests (bash tests/helper.sh)" bash tests/helper.sh

if [[ ${1-} != --tests-only ]]; then
  if sc="$(shellcheck_cmd)"; then
    # shellcheck disable=SC2086  # $sc is a command line
    step "shellcheck" $sc bin/omarchy-opendisplay tests/helper.sh tests/check.sh
  else
    missing "shellcheck" "shellcheck (or uv)"
  fi

  if rf="$(ruff_cmd)"; then
    # shellcheck disable=SC2086
    step "ruff" $rf check bin/sender-config.py bin/opendisplay-util.py bin/usbmux.py
  else
    missing "ruff" "ruff (or uv)"
  fi

  if q="$(qmlformat_cmd)"; then
    step "QML parse (qmlformat)" qml_parse "$q"
  else
    missing "QML parse (qmlformat)" "qmlformat (Qt 6 declarative tools)"
  fi

  if command -v omarchy >/dev/null || command -v curl >/dev/null; then
    step "manifest (omarchy-plugin-validate)" validate_manifest
  else
    missing "manifest (omarchy-plugin-validate)" "omarchy or curl"
  fi
fi

echo
[[ ${#skipped[@]} -gt 0 ]] && printf 'skipped: %s\n' "${skipped[@]}"
if [[ ${#failed[@]} -gt 0 ]]; then
  printf 'FAILED: %s\n' "${failed[@]}"
  exit 1
fi
echo "all checks passed"
