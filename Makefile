include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-xc
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=deanzai <sd423498566@gmail.com>

LUCI_TITLE:=LuCI support for Xray node switching
LUCI_DEPENDS:=+luci-compat +lua +libuci-lua +luci-lib-jsonc +curl +ca-bundle +xray-core
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/xc
/etc/xc/
endef

define Package/$(PKG_NAME)/preinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ -f /etc/xc/nodes.json ] || exit 0
mkdir -p /etc/xc || exit 1
base=/etc/xc/legacy-backup-$$(date +%s)
backup=$$base
attempt=0
while ! mkdir "$$backup" 2>/dev/null; do \
	attempt=$$((attempt + 1)); \
	[ "$$attempt" -le 9 ] || exit 1; \
	backup=$$base-$$attempt; \
done
chmod 0700 "$$backup" || exit 1
for file in nodes.json current config.json config.previous current.previous; do \
	[ ! -f /etc/xc/$$file ] || { cp -p /etc/xc/$$file "$$backup/$$file" && chmod 0600 "$$backup/$$file"; } || exit 1; \
done
[ ! -f /usr/bin/xc ] || { cp -p /usr/bin/xc "$$backup/usr-bin-xc" && chmod 0600 "$$backup/usr-bin-xc"; } || exit 1
[ ! -f /etc/init.d/xc-xray ] || { cp -p /etc/init.d/xc-xray "$$backup/init.d-xc-xray" && chmod 0600 "$$backup/init.d-xc-xray"; } || exit 1
touch "$$backup/complete" || exit 1
chmod 0600 "$$backup/complete" || exit 1
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
