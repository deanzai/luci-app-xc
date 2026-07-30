#!/bin/sh
set -eu

lua51="${LUA51:-}"
if [ -z "$lua51" ] && [ -x ./.tools/lua5.1 ]; then lua51=./.tools/lua5.1; fi
if [ -z "$lua51" ]; then lua51=$(command -v lua5.1 2>/dev/null || true); fi
if [ -z "$lua51" ]; then
  echo "FAIL Lua 5.1 is required" >&2
  exit 1
fi

"$lua51" -v
node --version
"$lua51" tests/run.lua
node tests/test_task9_ui.js
node tests/test_log_ui.js
node tests/test_status.js
sh tests/test_check_package.sh

po2lmo="${XC_PO2LMO:-}"
host_tmp=""
if [ -z "$po2lmo" ]; then po2lmo=$(command -v po2lmo 2>/dev/null || true); fi
if [ -z "$po2lmo" ]; then
  umask 077
  host_tmp="${TMPDIR:-/tmp}/xc-host-check.$$"
  mkdir "$host_tmp"
  trap 'rm -rf "$host_tmp"' EXIT HUP INT TERM
  po2lmo="$host_tmp/po2lmo"
  printf '%s\n' '#!/bin/sh' 'set -eu' '[ "$#" -eq 2 ]' '[ -s "$1" ]' "printf 'fixture-lmo\\n' > \"\$2\"" > "$po2lmo"
  chmod 0700 "$po2lmo"
fi
XC_PO2LMO="$po2lmo" sh scripts/check-package.sh
