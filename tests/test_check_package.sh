#!/bin/sh
set -eu

tmp="${TMPDIR:-/tmp}/xc-check-package-test.$$"
mkdir "$tmp"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
failures=0

make_multiline() {
  awk '
    $0 == "msgid \"Test\"" { print "msgid \"\""; print "\"Test\""; next }
    $0 == "msgstr \"测速\"" { print "msgstr \"\""; print "\"测速\""; next }
    { print }
  ' "$1" > "$2"
}

run_check() {
  XC_POT_PATH="$1" XC_PO_PATH="$2" XC_PO2LMO="$3" \
    sh scripts/check-package.sh > "$tmp/output" 2>&1
}

make_multiline po/templates/xc.pot "$tmp/multiline.pot"
make_multiline po/zh_Hans/xc.po "$tmp/multiline.po"
if ! run_check "$tmp/multiline.pot" "$tmp/multiline.po" /usr/bin/po2lmo; then
  echo "FAIL valid multiline gettext entries were rejected"
  cat "$tmp/output"
  failures=$((failures + 1))
fi
if ! grep -q '^OK  generated /usr/lib/lua/luci/i18n/xc.zh-cn.lmo$' "$tmp/output"; then
  echo "FAIL check-package did not verify a generated non-empty LMO"
  failures=$((failures + 1))
fi

cp "$tmp/multiline.po" "$tmp/duplicate.po"
printf '\nmsgid ""\n"Test"\nmsgstr "重复"\n' >> "$tmp/duplicate.po"
if run_check "$tmp/multiline.pot" "$tmp/duplicate.po" /usr/bin/po2lmo; then
  echo "FAIL duplicate multiline msgid was accepted"
  failures=$((failures + 1))
fi

awk '
  $0 == "msgstr \"测速\"" { print "msgstr \"\""; print "\"\""; next }
  { print }
' po/zh_Hans/xc.po > "$tmp/empty.po"
if run_check po/templates/xc.pot "$tmp/empty.po" /usr/bin/po2lmo; then
  echo "FAIL empty continued msgstr was accepted"
  failures=$((failures + 1))
fi

if run_check po/templates/xc.pot po/zh_Hans/xc.po "$tmp/missing-po2lmo"; then
  echo "FAIL missing po2lmo was silently accepted"
  failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || exit 1
echo "PASS check-package gettext and LMO mutation tests"
