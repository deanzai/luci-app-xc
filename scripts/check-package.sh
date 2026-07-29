#!/bin/sh
set -eu
failures=0
check() {
  if [ -f "$1" ]; then
    echo "OK  $1"
  else
    echo "MISS  $1"
    failures=$(( failures + 1 ))
  fi
}
echo "=== Package file check ==="
check README.md
check README_EN.md
check LICENSE
check Makefile
check root/etc/config/xc
check root/etc/init.d/xc
check root/etc/hotplug.d/iface/95-xc
check root/etc/uci-defaults/luci-xc
check root/usr/bin/xc
check root/usr/lib/lua/xc/schema.lua
check root/usr/lib/lua/xc/importer.lua
check root/usr/lib/lua/xc/generator.lua
check root/usr/lib/lua/xc/runtime.lua
check root/usr/lib/lua/xc/probe.lua
check root/usr/lib/lua/xc/platform.lua
check root/usr/lib/lua/xc/cli.lua
check luasrc/controller/xc.lua
check luasrc/model/cbi/xc/settings.lua
check luasrc/model/cbi/xc/nodes.lua
check luasrc/model/cbi/xc/node.lua
check luasrc/model/cbi/xc/log.lua
check luasrc/view/xc/status.htm
check luasrc/view/xc/node_table.htm
check luasrc/view/xc/ping.htm
check luasrc/view/xc/import.htm
check luasrc/view/xc/log.htm
check po/templates/xc.pot
check po/zh_Hans/xc.po
echo ""
echo "=== Workflow check ==="
if [ -f .github/workflows/build.yml ]; then
  echo "OK  .github/workflows/build.yml"
else
  echo "MISS  .github/workflows/build.yml"
  failures=$(( failures + 1 ))
fi
echo ""
echo "=== Build matrix ==="
if grep -q "21.02" .github/workflows/build.yml 2>/dev/null; then
  echo "OK  matrix includes 21.02"
else
  echo "MISS  21.02 in build matrix"
  failures=$(( failures + 1 ))
fi
if grep -q "24.10" .github/workflows/build.yml 2>/dev/null; then
  echo "OK  matrix includes 24.10"
else
  echo "MISS  24.10 in build matrix"
  failures=$(( failures + 1 ))
fi
echo ""
if [ "$failures" -eq 0 ]; then
  echo "All checks PASS"
else
  echo "$failures check(s) FAILED"
  exit 1
fi

