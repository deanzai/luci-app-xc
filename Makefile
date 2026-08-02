include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-xc
PKG_VERSION:=0.1.0
PKG_RELEASE:=10
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)
PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=deanzai <sd423498566@gmail.com>

LUCI_TITLE:=LuCI support for Xray node switching
LUCI_DEPENDS:=+luci-compat +lua +libuci-lua +luci-lib-jsonc +curl +ca-bundle +xray-core
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/xc
endef

define Package/$(PKG_NAME)/preinst
#!/bin/sh
root="$${IPKG_INSTROOT:-}"
case "$$root" in ""|/*) ;; *) exit 1 ;; esac
xc_dir="$$root/etc/xc"
config="$$root/etc/config/xc"
[ ! -e "$$config" ] || chmod 0600 "$$config" || exit 1
[ ! -f "$$xc_dir/migration-complete" ] || exit 0
[ -f "$$xc_dir/nodes.json" ] || exit 0
mkdir -p "$$xc_dir" || exit 1
base="$$xc_dir/legacy-backup-$$(date +%s)"
backup=$$base
attempt=0
while ! mkdir "$$backup" 2>/dev/null; do \
	attempt=$$((attempt + 1)); \
	[ "$$attempt" -le 9 ] || exit 1; \
	backup=$$base-$$attempt; \
done
chmod 0700 "$$backup" || exit 1
for file in nodes.json current config.json config.previous current.previous; do \
	[ ! -f "$$xc_dir/$$file" ] || { cp -p "$$xc_dir/$$file" "$$backup/$$file" && chmod 0600 "$$backup/$$file"; } || exit 1; \
done
[ ! -f "$$root/usr/bin/xc" ] || { cp -p "$$root/usr/bin/xc" "$$backup/usr-bin-xc" && chmod 0600 "$$backup/usr-bin-xc"; } || exit 1
[ ! -f "$$root/etc/init.d/xc-xray" ] || { cp -p "$$root/etc/init.d/xc-xray" "$$backup/init.d-xc-xray" && chmod 0600 "$$backup/init.d-xc-xray"; } || exit 1
touch "$$backup/complete" || exit 1
chmod 0600 "$$backup/complete" || exit 1
exit 0
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
root="$${IPKG_INSTROOT:-}"
case "$$root" in ""|/*) ;; *) exit 1 ;; esac
mkdir -p "$$root/etc/xc/rollback" "$$root/etc/xc/xray/versions" "$$root/var/etc/xc" || exit 1
chmod 0700 "$$root/etc/xc" "$$root/etc/xc/rollback" "$$root/etc/xc/xray" "$$root/etc/xc/xray/versions" "$$root/var/etc/xc" || exit 1
chmod 0600 "$$root/etc/config/xc" || exit 1
if [ -z "$$root" ]; then
	if [ -f /etc/uci-defaults/luci-xc ]; then
		(. /etc/uci-defaults/luci-xc) && rm -f /etc/uci-defaults/luci-xc || exit 1
	fi
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* || exit 1
	rm -rf /tmp/luci-modulecache/ || exit 1
	/etc/init.d/rpcd reload 2>/dev/null || killall -HUP rpcd 2>/dev/null || true
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
