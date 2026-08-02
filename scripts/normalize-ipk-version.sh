#!/bin/sh
set -eu

package=${1:-}
version=${2:-}
[ "$#" -eq 2 ] || { echo "usage: $0 <ipk> <version>" >&2; exit 2; }
[ -f "$package" ] || { echo "missing IPK: $package" >&2; exit 1; }
case "$version" in
	''|*[!0-9A-Za-z.+:~_-]*) echo "invalid package version" >&2; exit 2 ;;
esac

temporary=$(mktemp -d "${TMPDIR:-/tmp}/xc-ipk-version.XXXXXX")
cleanup() { rm -rf "$temporary"; }
trap cleanup EXIT HUP INT TERM

tar -xzf "$package" -C "$temporary"
[ -f "$temporary/control.tar.gz" ] && [ -f "$temporary/data.tar.gz" ] && [ -f "$temporary/debian-binary" ] || {
	echo "invalid IPK archive: $package" >&2
	exit 1
}
mkdir "$temporary/control"
tar -xzf "$temporary/control.tar.gz" -C "$temporary/control"
[ -f "$temporary/control/control" ] || { echo "IPK control metadata is missing" >&2; exit 1; }

current=$(sed -n 's/^Version:[[:space:]]*//p' "$temporary/control/control")
[ -n "$current" ] || { echo "IPK control Version is missing" >&2; exit 1; }
[ "$current" = "$version" ] && exit 0
[ "$(printf '%s\n' "$current" | wc -l)" -eq 1 ] || { echo "IPK control Version is invalid" >&2; exit 1; }
sed "s/^Version:[[:space:]].*$/Version: $version/" "$temporary/control/control" > "$temporary/control/control.new"
mv "$temporary/control/control.new" "$temporary/control/control"

tar -czf "$temporary/control.new.tar.gz" -C "$temporary/control" .
mv "$temporary/control.new.tar.gz" "$temporary/control.tar.gz"
package_tmp=$(mktemp "${package}.tmp.XXXXXX")
tar -czf "$package_tmp" -C "$temporary" debian-binary control.tar.gz data.tar.gz
chmod 0644 "$package_tmp"
mv "$package_tmp" "$package"
