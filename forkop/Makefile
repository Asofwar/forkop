include $(TOPDIR)/rules.mk

PKG_NAME:=forkop

FORKOP_SOURCE_VERSION:=$(or $(FORKOP_PACKAGE_VERSION),$(FORKOP_VERSION))
FORKOP_HAS_RELEASE_VERSION:=$(if $(filter dev,$(FORKOP_SOURCE_VERSION)),,$(FORKOP_SOURCE_VERSION))
FORKOP_COMPILED_VERSION:=$(if $(FORKOP_HAS_RELEASE_VERSION),$(FORKOP_SOURCE_VERSION),$(or $(FORKOP_SOURCE_VERSION),dev))
FORKOP_RELEASE_VERSION_VALID:=$(if $(FORKOP_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(FORKOP_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' && printf '1'),1)

ifeq ($(FORKOP_RELEASE_VERSION_VALID),)
$(error FORKOP_PACKAGE_VERSION and FORKOP_VERSION must use x.y.z format)
endif

PKG_VERSION:=$(or $(FORKOP_HAS_RELEASE_VERSION),0.0.0)
PKG_RELEASE:=

PKG_MAINTAINER:=slayer326 <34569426+slayer326@users.noreply.github.com>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/forkop
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+ca-bundle +kmod-inet-diag +kmod-tun +curl +ucode +ucode-mod-fs +ucode-mod-uci +conntrack +kmod-nft-tproxy +coreutils-base64 +bind-dig +nftables-json +kmod-nft-nat +ip-full
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2
	TITLE:=Forkop backend service
	URL:=https://github.com/slayer326/forkop
	PKGARCH:=all
endef

define Package/forkop/description
	Rule-based Forkop backend with hybrid sing-box + zapret orchestration
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/forkop/prerm
#!/bin/sh

# OpenWrt never runs this file itself: the ipk's prerm sources it from
# default_prerm, where opkg's "prerm remove" or "prerm upgrade <new
# version>" arrive as $$2 and $$3, and apk appends it to the pre-deinstall
# script, which runs only for a removal. The new version tells whether the
# incoming release can lift the kill-switch.
[ -n "$${IPKG_INSTROOT}" ] && exit 0
forkop_action=remove
forkop_version=
if [ "$$2" = upgrade ]; then
	forkop_action=upgrade
	forkop_version="$$3"
	case "$$forkop_version" in
		*[!A-Za-z0-9.~+_-]*) forkop_version= ;;
	esac
fi
/usr/bin/forkop package_prerm "$$forkop_action" $${forkop_version:+"$$forkop_version"} >/dev/null 2>&1
exit 0
endef
# The same script as build.sh write_backend_postinst writes (make reads $$
# as $); tests/package_postinst_chain.sh compares them.
define Package/forkop/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
FORKOP_LIB=/usr/lib/forkop ucode -L /usr/lib/forkop /usr/lib/forkop/config/migration.uc migrate
forkop_migrate_status=$$?
FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh ||
	logger -t forkop "[warn] Package mirror migration failed (status $$?); the package feeds were left unchanged"
/usr/bin/forkop package_postinst
forkop_postinst_status=$$?
[ "$$forkop_migrate_status" -eq 0 ] || exit "$$forkop_migrate_status"
exit "$$forkop_postinst_status"
endef

define Package/forkop/conffiles
/etc/config/forkop
endef

define Package/forkop/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/forkop $(1)/etc/init.d/forkop
	$(INSTALL_BIN) ./files/etc/init.d/forkop-killswitch $(1)/etc/init.d/forkop-killswitch
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/forkop-killswitch $(1)/lib/upgrade/keep.d/forkop-killswitch
	$(INSTALL_DIR) $(1)/usr/share/nftables.d/ruleset-post
	$(INSTALL_DATA) ./files/usr/share/nftables.d/ruleset-post/90-forkop-killswitch-loader.nft $(1)/usr/share/nftables.d/ruleset-post/90-forkop-killswitch-loader.nft

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/forkop $(1)/etc/config/forkop

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/forkop $(1)/usr/bin/forkop

	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/forkop-ro $(1)/usr/libexec/forkop-ro

	$(INSTALL_DIR) $(1)/usr/lib/forkop
	$(CP) ./files/usr/lib/. $(1)/usr/lib/forkop/

	$(INSTALL_DIR) $(1)/usr/share/forkop/defaults
	$(INSTALL_CONF) ./files/etc/config/forkop $(1)/usr/share/forkop/defaults/forkop
	$(INSTALL_BIN) ./files/usr/share/forkop/mirror-migration.sh $(1)/usr/share/forkop/mirror-migration.sh

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(FORKOP_COMPILED_VERSION)/g' $(1)/usr/lib/forkop/core/constants.uc
endef

$(eval $(call BuildPackage,forkop))
