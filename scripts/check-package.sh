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
LC_ALL=C
export LC_ALL
translation_tmp="${TMPDIR:-/tmp}/xc-translation-check.$$"
umask 077
mkdir "$translation_tmp" || exit 1
trap 'rm -rf "$translation_tmp"' EXIT HUP INT TERM
pot_path="${XC_POT_PATH:-po/templates/xc.pot}"
po_path="${XC_PO_PATH:-po/zh_Hans/xc.po}"
source_dir="${XC_LUCI_SOURCE_DIR:-luasrc}"

{
  printf '%s\n' Makefile "$pot_path" "$po_path"
  [ ! -d root ] || find root -type f -print
  [ ! -d scripts ] || find scripts -type f -name '*.sh' -print
  [ ! -d tests ] || find tests -type f -name '*.sh' -print
  [ ! -d "$source_dir" ] || find "$source_dir" -type f \( -name '*.lua' -o -name '*.htm' \) -print
} | sort -u > "$translation_tmp/lf-files"
carriage_return=$(printf '\r')
while IFS= read -r text_path; do
  [ -f "$text_path" ] || continue
  if LC_ALL=C grep -q "$carriage_return" "$text_path"; then
    echo "FAIL  CRLF line endings are forbidden: $text_path"
    failures=$(( failures + 1 ))
  fi
done < "$translation_tmp/lf-files"

if [ ! -d "$source_dir" ]; then
  echo "FAIL  LuCI source directory is missing: $source_dir"
  failures=$(( failures + 1 ))
  : > "$translation_tmp/source"
else
  find "$source_dir" -type f \( -name '*.lua' -o -name '*.htm' \) -exec awk '
  function identifier(c) { return c ~ /^[A-Za-z0-9_]$/ }
  function long_level(text, position, comment, cursor, level) {
    cursor = position + (comment ? 2 : 0)
    if (substr(text, cursor, 1) != "[") return -1
    cursor++; level = 0
    while (substr(text, cursor, 1) == "=") { cursor++; level++ }
    return substr(text, cursor, 1) == "[" ? level : -1
  }
  function long_delimiter(level, value) {
    value = "]"
    while (level > 0) { value = value "="; level-- }
    return value "]"
  }
  function reset_file() {
    mode = "normal"; stage = 0; captured = ""; escaped = 0
  }
  function decoded_escape(c) {
    if (c == "n") return "\n"
    if (c == "r") return "\r"
    if (c == "t") return "\t"
    return c
  }
  FNR == 1 { reset_file() }
  {
    line = $0 "\n"
    i = 1
    while (i <= length(line)) {
      c = substr(line, i, 1)
      pair = substr(line, i, 2)

      if (mode == "block_comment") {
        if (pair == "*/") { mode = "normal"; i += 2 } else i++
        continue
      }
      if (mode == "html_comment") {
        if (substr(line, i, 3) == "-->") { mode = "normal"; i += 3 } else i++
        continue
      }
      if (mode == "long_comment" || mode == "long_string") {
        if (substr(line, i, length(long_close)) == long_close) {
          mode = "normal"; i += length(long_close)
        } else i++
        continue
      }
      if (mode == "skip_string") {
        if (substr(line, i, 3) == "<%:") {
          rest = substr(line, i + 3)
          finish = index(rest, "%>")
          if (finish) { print substr(rest, 1, finish - 1); i += finish + 4; continue }
        }
        if (escaped) escaped = 0
        else if (c == "\\") escaped = 1
        else if (c == quote) mode = "normal"
        i++
        continue
      }
      if (mode == "capture") {
        if (c == "\n") { mode = "normal"; stage = 0; captured = ""; i++; continue }
        if (escaped) { captured = captured decoded_escape(c); escaped = 0; i++; continue }
        if (c == "\\") { escaped = 1; i++; continue }
        if (c == "\"") { mode = "normal"; stage = 3; i++; continue }
        captured = captured c
        i++
        continue
      }

      if (stage == 1) {
        if (c ~ /^[[:space:]]$/) { i++; continue }
        if (c == "(") { stage = 2; i++; continue }
        stage = 0
      }
      if (stage == 2) {
        if (c ~ /^[[:space:]]$/) { i++; continue }
        if (c == "\"") { mode = "capture"; captured = ""; escaped = 0; i++; continue }
        stage = 0
      }
      if (stage == 3) {
        if (c ~ /^[[:space:]]$/) { i++; continue }
        if (c == ")") { print captured; stage = 0; captured = ""; i++; continue }
        stage = 0; captured = ""
      }

      if (substr(line, i, 3) == "<%:") {
        rest = substr(line, i + 3)
        finish = index(rest, "%>")
        if (finish) { print substr(rest, 1, finish - 1); i += finish + 4; continue }
      }
      level = long_level(line, i, 1)
      if (level >= 0) {
        mode = "long_comment"; long_close = long_delimiter(level); i += level + 4; continue
      }
      if (pair == "--" || pair == "//") break
      if (pair == "/*") { mode = "block_comment"; i += 2; continue }
      if (substr(line, i, 4) == "<!--") { mode = "html_comment"; i += 4; continue }
      level = long_level(line, i, 0)
      if (level >= 0) {
        mode = "long_string"; long_close = long_delimiter(level); i += level + 2; continue
      }
      if (c == "\"" || c == "\047") { mode = "skip_string"; quote = c; escaped = 0; i++; continue }

      token = ""
      if (substr(line, i, 9) == "translate") token = "translate"
      else if (c == "_") token = "_"
      if (token != "") {
        before = i > 1 ? substr(line, i - 1, 1) : ""
        after = substr(line, i + length(token), 1)
        if (!identifier(before) && !identifier(after)) {
          stage = 1; i += length(token); continue
        }
      }
      i++
    }
  }
  ' {} + | sort -u > "$translation_tmp/source"
fi

parse_catalog() {
  awk '
  function decode(line, out, body, i, c, nextc, number, count) {
    if (line !~ /^".*"$/) { malformed = 1; return "" }
    body = substr(line, 2, length(line) - 2)
    out = ""
    for (i = 1; i <= length(body); i++) {
      c = substr(body, i, 1)
      if (c != "\\") { out = out c; continue }
      i++
      if (i > length(body)) { malformed = 1; return out }
      nextc = substr(body, i, 1)
      if (nextc == "n") out = out "\n"
      else if (nextc == "r") out = out "\r"
      else if (nextc == "t") out = out "\t"
      else if (nextc == "\\" || nextc == "\"") out = out nextc
      else if (nextc ~ /^[0-7]$/) {
        number = nextc + 0
        count = 1
        while (count < 3 && i < length(body) && substr(body, i + 1, 1) ~ /^[0-7]$/) {
          i++; count++; number = (number * 8) + substr(body, i, 1)
        }
        out = out sprintf("%c", number)
      } else { malformed = 1; return out }
    }
    return out
  }
  function finish() {
    if (!have) return
    if (fuzzy) { print "fuzzy catalog entry: " id > "/dev/stderr"; malformed = 1 }
    if (id != "") {
      if (id ~ /[\t\r\n]/ || value ~ /[\t\r\n]/) {
        print "unsupported control character in catalog entry" > "/dev/stderr"; malformed = 1
      } else print id "\t" value
    }
    have = 0; field = ""; id = ""; value = ""; context = ""; fuzzy = 0
  }
  /^#,/ { if ($0 ~ /(^|[, ])fuzzy([, ]|$)/) fuzzy = 1; next }
  /^msgctxt / { context = decode(substr($0, 9)); field = "context"; next }
  /^msgid / {
    if (have) finish()
    have = 1; id = decode(substr($0, 7)); field = "id"; next
  }
  /^msgstr / { if (!have) malformed = 1; value = decode(substr($0, 8)); field = "value"; next }
  /^msgid_plural / || /^msgstr\[/ { malformed = 1; next }
  /^"/ {
    continued = decode($0)
    if (field == "id") id = id continued
    else if (field == "value") value = value continued
    else if (field == "context") context = context continued
    else malformed = 1
    next
  }
  /^[[:space:]]*$/ { finish(); next }
  /^#/ { next }
  { malformed = 1 }
  END { finish(); exit malformed }
  ' "$1"
}

if ! parse_catalog "$pot_path" > "$translation_tmp/pot-records"; then
  echo "FAIL  $pot_path is not a supported valid gettext catalog"
  failures=$(( failures + 1 ))
fi
if ! parse_catalog "$po_path" > "$translation_tmp/po-records"; then
  echo "FAIL  $po_path is not a supported valid gettext catalog"
  failures=$(( failures + 1 ))
fi
cut -f1 "$translation_tmp/pot-records" > "$translation_tmp/pot-all"
cut -f1 "$translation_tmp/po-records" > "$translation_tmp/po-all"
sort -u "$translation_tmp/pot-all" > "$translation_tmp/pot"
sort -u "$translation_tmp/po-all" > "$translation_tmp/po"

for kind in pot po; do
  if [ "$(wc -l < "$translation_tmp/$kind-all")" -ne "$(wc -l < "$translation_tmp/$kind")" ]; then
    echo "FAIL  $kind catalog contains duplicate msgids"
    failures=$(( failures + 1 ))
  fi
  if ! cmp -s "$translation_tmp/source" "$translation_tmp/$kind"; then
    echo "FAIL  $kind catalog does not exactly cover visible LuCI strings"
    comm -3 "$translation_tmp/source" "$translation_tmp/$kind" | sed 's/^/  /'
    failures=$(( failures + 1 ))
  fi
done

if ! awk -F '\t' '
  {
    id = $1; value = $2
    if (value == "") { print "empty translation: " id; failed = 1 }
    if (value == id && id != "XC" && id != "Xray" && id != "OK" && id != "UUID") {
      print "untranslated entry: " id; failed = 1
    }
  }
  END { exit failed }
' "$translation_tmp/po-records"; then
  echo "FAIL  Simplified Chinese catalog has empty or untranslated entries"
  failures=$(( failures + 1 ))
fi

if [ -n "${XC_PACKAGE_ROOT:-}" ]; then
  package_lmo="$XC_PACKAGE_ROOT/usr/lib/lua/luci/i18n/xc.zh-cn.lmo"
  if [ -s "$package_lmo" ]; then
    echo "OK  $package_lmo"
  else
    echo "FAIL  package translation is missing or empty: /usr/lib/lua/luci/i18n/xc.zh-cn.lmo"
    failures=$(( failures + 1 ))
  fi
else
  po2lmo_tool="${XC_PO2LMO:-}"
  if [ -z "$po2lmo_tool" ]; then po2lmo_tool=$(command -v po2lmo 2>/dev/null || true); fi
  lmo_output="$translation_tmp/xc.zh-cn.lmo"
  if [ -z "$po2lmo_tool" ] || [ ! -x "$po2lmo_tool" ]; then
    echo "FAIL  po2lmo is required to verify xc.zh-cn.lmo"
    failures=$(( failures + 1 ))
  elif "$po2lmo_tool" "$po_path" "$lmo_output" && [ -s "$lmo_output" ]; then
    echo "OK  generated /usr/lib/lua/luci/i18n/xc.zh-cn.lmo"
  else
    echo "FAIL  unable to generate a non-empty xc.zh-cn.lmo"
    failures=$(( failures + 1 ))
  fi
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
