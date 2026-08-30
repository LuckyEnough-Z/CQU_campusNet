#
# Copyright (C) 2025 Your Name <your@email.com>
# This is free software, licensed under the Apache License, Version 2.0.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cquauth
PKG_VERSION:=1.0.9
PKG_RELEASE:=1

PKG_MAINTAINER:=lurenjiamax <lurenjiamax@gmail.com>

LUCI_TITLE:=CQU Auth (Chongqing University Authentication)
LUCI_PKGARCH:=all
# 1.0.9: 修复"自救反而弄断网"的 bug: 一次瞬时 chkstatus 空响应会导致 ifup 释放正常
#        的 DHCP 租约, 每 60s 重复一次打断进行中的 DHCP, 实测造成 20 分钟断网.
#        lua: is_authenticated(bool) -> portal_state(三态 online/offline/unreachable);
#             新增 iface_link_ok() 用 ubus 查 up+IPv4+默认路由, 链路正常时绝不 ifup;
#             真需要 ifup 时加 300s 退避, 且改为轮询等接口就绪(最多 30s)再认证;
#             删掉 check_authserver/LOGIN_SERVER (ping 判定已被链路检查取代).
#        ucode: get_status 增加 reachable 字段, 区分"门户说未登录"和"门户连不上".
# 1.0.8: 修复开机不自启 + ctx:load 竞态 + ipk 文件所有者问题.
#        init: 删除 boot() 函数 (它阻止 start_service 执行), START=95→99 (晚启动等 ubus 就绪).
#        lua: ctx:load("cquauth") 失败时跳过本轮 (不空转), ENABLED/ENABLE_ECMP 改为 (tonumber()==1) and 1 or 0 确保是数字.
#        ipk: 打包时用 tar --owner=0 --group=0 强制 root, 防止 UID 1000 泄露导致 LuCI 不显示启动项.
# 1.0.7: init 加 service_triggers (procd_add_reload_trigger "cquauth") + reload_service,
#        lua daemon 把 uci 读移到 while 循环每轮重读 + ctx:load("cquauth").
#        修复改账号/切 phone-pc 需要手动 restart cquauth_client 的 bug.
# 1.0.6: 改用 uclient-fetch (OpenWrt 基础组件, 不怕固件 curl/libcurl 版本不匹配),
#        并补上 get_gw 真正依赖的 jq (1.0.5 漏声明导致部分固件 jq 缺失).
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
