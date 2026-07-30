#!/bin/sh
set -eu

tmp="${TMPDIR:-/tmp}/xc-check-package-test.$$"
mkdir "$tmp"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
failures=0

cat > "$tmp/po2lmo" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 2 ]
[ -s "$1" ]
printf 'fixture-lmo\n' > "$2"
EOF
chmod 0700 "$tmp/po2lmo"
po2lmo="$tmp/po2lmo"

make_multiline() {
  awk '
    $0 == "msgid \"Test\"" { print "msgid \"\""; print "\"Test\""; next }
    $0 == "msgstr \"测速\"" { print "msgstr \"\""; print "\"测速\""; next }
    { print }
  ' "$1" > "$2"
}

run_check() {
  XC_POT_PATH="$1" XC_PO_PATH="$2" XC_PO2LMO="$3" XC_LUCI_SOURCE_DIR="${4:-luasrc}" \
    sh scripts/check-package.sh > "$tmp/output" 2>&1
}

cp -R luasrc "$tmp/luasrc"
cat > "$tmp/luasrc/multiline.lua" <<'EOF'
local translated = translate(
  "Multiline translate label"
)
local shorthand = _(
  "Multiline underscore label"
)
local same_line = translate("Warning")
-- translate("Comment-only label")
local arbitrary = 'translate("String-only label")'
--[[
translate("Long-comment level-zero label")
_("Long-comment level-zero shorthand")
]]
--[=[
translate("Long-comment level-one label")
_("Long-comment level-one shorthand")
]=]
local long_string = [[translate("Long-string level-zero label")]]
local long_string_equals = [=[_("Long-string level-one label")]=]
return translated, shorthand, same_line
EOF
cat > "$tmp/luasrc/commented.htm" <<'EOF'
<!-- <%:Comment-only template label%> -->
<script type="text/javascript">
// translate("Comment-only JavaScript label")
var arbitrary = '_("String-only JavaScript label")';
</script>
EOF
cp po/templates/xc.pot "$tmp/source-multiline.pot"
cat >> "$tmp/source-multiline.pot" <<'EOF'

msgid "Multiline translate label"
msgstr ""

msgid "Multiline underscore label"
msgstr ""
EOF
cp po/zh_Hans/xc.po "$tmp/source-multiline.po"
cat >> "$tmp/source-multiline.po" <<'EOF'

msgid "Multiline translate label"
msgstr "多行翻译标签"

msgid "Multiline underscore label"
msgstr "多行简写标签"
EOF
if ! run_check "$tmp/source-multiline.pot" "$tmp/source-multiline.po" "$po2lmo" "$tmp/luasrc"; then
  echo "FAIL valid multiline LuCI gettext calls were not discovered"
  cat "$tmp/output"
  failures=$((failures + 1))
fi

make_multiline po/templates/xc.pot "$tmp/multiline.pot"
make_multiline po/zh_Hans/xc.po "$tmp/multiline.po"
if ! run_check "$tmp/multiline.pot" "$tmp/multiline.po" "$po2lmo"; then
  echo "FAIL valid multiline gettext entries were rejected"
  cat "$tmp/output"
  failures=$((failures + 1))
fi
if ! grep -q '^OK  generated /usr/lib/lua/luci/i18n/xc.zh-cn.lmo$' "$tmp/output"; then
  echo "FAIL check-package did not verify a generated non-empty LMO"
  failures=$((failures + 1))
fi

cp -R luasrc "$tmp/crlf-luasrc"
printf 'local value = true\r\nreturn value\r\n' > "$tmp/crlf-luasrc/crlf.lua"
if run_check po/templates/xc.pot po/zh_Hans/xc.po "$po2lmo" "$tmp/crlf-luasrc"; then
  echo "FAIL CRLF LuCI source was accepted"
  failures=$((failures + 1))
elif ! grep -Fq "FAIL  CRLF line endings are forbidden: $tmp/crlf-luasrc/crlf.lua" "$tmp/output"; then
  echo "FAIL CRLF LuCI source did not return the stable error"
  cat "$tmp/output"
  failures=$((failures + 1))
fi

cp "$tmp/multiline.po" "$tmp/duplicate.po"
printf '\nmsgid ""\n"Test"\nmsgstr "重复"\n' >> "$tmp/duplicate.po"
if run_check "$tmp/multiline.pot" "$tmp/duplicate.po" "$po2lmo"; then
  echo "FAIL duplicate multiline msgid was accepted"
  failures=$((failures + 1))
fi

awk '
  $0 == "msgstr \"测速\"" { print "msgstr \"\""; print "\"\""; next }
  { print }
' po/zh_Hans/xc.po > "$tmp/empty.po"
if run_check po/templates/xc.pot "$tmp/empty.po" "$po2lmo"; then
  echo "FAIL empty continued msgstr was accepted"
  failures=$((failures + 1))
fi

if run_check po/templates/xc.pot po/zh_Hans/xc.po "$tmp/missing-po2lmo"; then
  echo "FAIL missing po2lmo was silently accepted"
  failures=$((failures + 1))
fi

run_package_root() {
  XC_PACKAGE_ROOT="$1" XC_PO2LMO="$tmp/missing-po2lmo" \
    sh scripts/check-package.sh > "$tmp/package-root-output" 2>&1
}
for state in valid empty missing; do
  root="$tmp/package-$state"
  mkdir -p "$root/usr/lib/lua/luci/i18n"
  if [ "$state" = valid ]; then printf 'valid-lmo\n' > "$root/usr/lib/lua/luci/i18n/xc.zh-cn.lmo"; fi
  if [ "$state" = empty ]; then : > "$root/usr/lib/lua/luci/i18n/xc.zh-cn.lmo"; fi
  if [ "$state" = valid ]; then
    if ! run_package_root "$root"; then
      echo "FAIL non-empty package-root LMO was rejected"
      failures=$((failures + 1))
    fi
  else
    if run_package_root "$root"; then
      echo "FAIL $state package-root LMO was accepted"
      failures=$((failures + 1))
    elif ! grep -q '^FAIL  package translation is missing or empty: /usr/lib/lua/luci/i18n/xc.zh-cn.lmo$' "$tmp/package-root-output"; then
      echo "FAIL $state package-root LMO did not return the stable error"
      failures=$((failures + 1))
    fi
  fi
done

[ "$failures" -eq 0 ] || exit 1
echo "PASS check-package gettext and LMO mutation tests"
