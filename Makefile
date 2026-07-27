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

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
