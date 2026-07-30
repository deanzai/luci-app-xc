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
echo "=== Translation catalog check ==="
translation_tmp="${TMPDIR:-/tmp}/xc-translation-check.$$"
mkdir "$translation_tmp" || exit 1
trap 'rm -rf "$translation_tmp"' EXIT HUP INT TERM

awk '
function emit(mark, rest, finish, value) {
  while ((mark = index($0, "translate(\"")) > 0) {
    rest = substr($0, mark + 11)
    finish = index(rest, "\"")
    if (!finish) break
    print substr(rest, 1, finish - 1)
    $0 = substr(rest, finish + 1)
  }
  while ((mark = index($0, "_(\"")) > 0) {
    rest = substr($0, mark + 3)
    finish = index(rest, "\"")
    if (!finish) break
    print substr(rest, 1, finish - 1)
    $0 = substr(rest, finish + 1)
  }
  while ((mark = index($0, "<%:")) > 0) {
    rest = substr($0, mark + 3)
    finish = index(rest, "%>")
    if (!finish) break
    print substr(rest, 1, finish - 1)
    $0 = substr(rest, finish + 2)
  }
}
{ emit() }
' $(find luasrc -type f \( -name '*.lua' -o -name '*.htm' \) -print) | sort -u > "$translation_tmp/source"

catalog_ids() {
  awk '/^msgid "/ { value = substr($0, 8, length($0) - 8); if (value != "") print value }' "$1"
}

catalog_ids po/templates/xc.pot > "$translation_tmp/pot-all"
catalog_ids po/zh_Hans/xc.po > "$translation_tmp/po-all"
sort -u "$translation_tmp/pot-all" > "$translation_tmp/pot"
sort -u "$translation_tmp/po-all" > "$translation_tmp/po"

for catalog in po/templates/xc.pot po/zh_Hans/xc.po; do
  if grep -q '^#,.*fuzzy' "$catalog"; then
    echo "FAIL  $catalog contains fuzzy entries"
    failures=$(( failures + 1 ))
  fi
done
for kind in pot po; do
  if [ "$(wc -l < "$translation_tmp/$kind-all")" -ne "$(wc -l < "$translation_tmp/$kind")" ]; then
    echo "FAIL  $kind catalog contains duplicate msgids"
    failures=$(( failures + 1 ))
  fi
  if ! cmp -s "$translation_tmp/source" "$translation_tmp/$kind"; then
    echo "FAIL  $kind catalog does not exactly cover visible LuCI strings"
    failures=$(( failures + 1 ))
  fi
done

if ! awk '
  /^msgid "/ { id = substr($0, 8, length($0) - 8); next }
  /^msgstr "/ {
    value = substr($0, 9, length($0) - 9)
    if (id != "" && value == "") { print "empty translation: " id; failed = 1 }
    if (id != "" && value == id && id != "XC" && id != "Xray" && id != "OK" && id != "UUID") {
      print "untranslated entry: " id; failed = 1
    }
  }
  END { exit failed }
' po/zh_Hans/xc.po; then
  echo "FAIL  Simplified Chinese catalog has empty or untranslated entries"
  failures=$(( failures + 1 ))
fi

if [ -n "${XC_PACKAGE_ROOT:-}" ]; then
  check "$XC_PACKAGE_ROOT/usr/lib/lua/luci/i18n/xc.zh-cn.lmo"
else
  echo "EXPECT  /usr/lib/lua/luci/i18n/xc.zh-cn.lmo in built luci-i18n-xc-zh-cn package"
fi
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
