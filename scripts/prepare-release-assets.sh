#!/bin/sh
# Copy SDK output to uniquely named, platform-labelled release assets.
# The original package filename is preserved apart from the platform suffix:
#   luci-app-xc_0.1.0-r10_all_openwrt-23.05.ipk
set -eu

platform=${1:-}
source_root=${2:-bin/packages}
destination=${3:-dist}

if [ -z "$platform" ]; then
	echo "usage: $0 <platform> [source-root] [destination]" >&2
	exit 2
fi
case "$platform" in
	openwrt-21.02|openwrt-23.05|openwrt-24.10) ;;
	*)
		echo "unsupported platform: $platform" >&2
		exit 2
		;;
esac
[ -d "$source_root" ] || { echo "missing package output: $source_root" >&2; exit 1; }
mkdir -p "$destination"

file_list=$(mktemp)
trap 'rm -f "$file_list"' EXIT HUP INT TERM
find "$source_root" -type f \( \
	-name 'luci-app-xc_*.ipk' -o \
	-name 'luci-i18n-xc-zh-cn_*.ipk' \
\) -print > "$file_list"
while IFS= read -r package; do
	name=${package##*/}
	case "$name" in
		*_openwrt-21.02.ipk|*_openwrt-23.05.ipk|*_openwrt-24.10.ipk)
			continue
			;;
	esac
	base=${name%.ipk}
	cp "$package" "$destination/${base}_${platform}.ipk"
done < "$file_list"

set -- "$destination"/*_${platform}.ipk
if [ "$1" = "$destination/*_${platform}.ipk" ]; then
	echo "no luci-app-xc packages found below $source_root" >&2
	exit 1
fi
(
	cd "$destination"
	sha256sum *_${platform}.ipk > "SHA256SUMS-${platform}.txt"
)
echo "Prepared platform suffix assets for $platform in $destination"
