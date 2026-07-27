#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
version=5.1.5
archive="$root/.tools/lua-$version.tar.gz"
src="$root/.tools/lua-$version"
mkdir -p "$root/.tools"
[ -f "$archive" ] || curl -fL "https://www.lua.org/ftp/lua-$version.tar.gz" -o "$archive"
if [ ! -x "$root/.tools/lua5.1" ]; then
  rm -rf "$src"
  tar -xzf "$archive" -C "$root/.tools"
  make -C "$src" generic
  cp "$src/src/lua" "$root/.tools/lua5.1"
fi
"$root/.tools/lua5.1" -v
