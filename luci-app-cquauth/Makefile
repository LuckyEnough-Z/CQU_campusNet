#
# Copyright (C) 2025 Your Name <your@email.com>
# This is free software, licensed under the Apache License, Version 2.0.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cquauth
PKG_VERSION:=1.0.6
PKG_RELEASE:=1

PKG_MAINTAINER:=lurenjiamax <lurenjiamax@gmail.com>

LUCI_TITLE:=CQU Auth (Chongqing University Authentication)
LUCI_PKGARCH:=all
# 1.0.6: 改用 uclient-fetch (OpenWrt 基础组件, 不怕固件 curl/libcurl 版本不匹配),
# 并补上 get_gw 真正依赖的 jq (1.0.5 漏声明导致部分固件 jq 缺失).
LUCI_DEPENDS:=+jq +uclient-fetch

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/postinst
#!/bin/sh
chmod 0755 /etc/init.d/cquauth_client /usr/bin/cquauth_client \
           /usr/share/rpcd/ucode/cquauth /usr/share/cquauth/diag-sharing.sh
if [ -z "$${IPKG_INSTROOT}" ] && [ -f /tmp/cquauth.bak ]; then
        mv /tmp/cquauth.bak /etc/config/cquauth
fi
exit 0
endef

# Reserve configs
define Package/$(PKG_NAME)/conffiles
/etc/config/cquauth
endef

define Package/$(PKG_NAME)/preinst
#!/bin/sh
# check if we are on real system
if [ -z "$${IPKG_INSTROOT}" ]; then
        #Backup config file
        cp /etc/config/cquauth /tmp/cquauth.bak
fi
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
