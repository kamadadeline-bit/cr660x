#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/work/openwrt"
LEDE_REPO="${LEDE_REPO:-https://github.com/coolsnowwolf/lede.git}"
LEDE_REF="${LEDE_REF:-master}"
UA3F_REF="${UA3F_REF:-v3.7.0}"
PASSWALL_LUCI_REF="${PASSWALL_LUCI_REF:-main}"
PASSWALL_PACKAGES_REF="${PASSWALL_PACKAGES_REF:-main}"
ARGON_REF="${ARGON_REF:-v3.1.0}"
ESURFING_REF="${ESURFING_REF:-v2.2.1-r7}"
UU_REF="${UU_REF:-v2.2.2}"
ZIG_VERSION="${ZIG_VERSION:-0.13.0}"
DEVICE_PROFILE="${DEVICE_PROFILE:-xiaomi_mi-router-cr660x}"
DEVICE_CONFIG="$ROOT_DIR/configs/devices/$DEVICE_PROFILE.config"

mkdir -p "$ROOT_DIR/work"
rm -rf "$BUILD_DIR" "$ROOT_DIR/work/MentoHUST-src" "$ROOT_DIR/work/Argon-src" \
  "$ROOT_DIR/work/ESurfing-src" "$ROOT_DIR/work/Dogcom-src" "$ROOT_DIR/work/Dogcom-LuCI-src" "$ROOT_DIR/work/UU-src"
git clone --depth 1 --branch "$LEDE_REF" "$LEDE_REPO" "$BUILD_DIR"
cd "$BUILD_DIR"

# Shared package choices; separate device profile holds target/flash/driver data.
case "$DEVICE_PROFILE" in
  xiaomi_mi-router-cr660x)
    TARGET_SUBDIR="ramips/mt7621"
    TARGET_PROFILE_LINE='CONFIG_TARGET_ramips_mt7621_DEVICE_xiaomi_mi-router-cr660x=y'
    SYSUPGRADE_GLOB='*xiaomi_mi-router-cr660x*squashfs-sysupgrade.bin'
    FACTORY_GLOB='*xiaomi_mi-router-cr660x*squashfs-factory.bin'
    ;;
  *)
    echo "ERROR: unknown/unimplemented DEVICE_PROFILE=$DEVICE_PROFILE" >&2
    exit 1
    ;;
esac
test -f "$DEVICE_CONFIG" || { echo "ERROR: device config missing: $DEVICE_CONFIG" >&2; exit 1; }
grep -q 'TARGET_DEVICES += xiaomi_mi-router-cr660x' target/linux/ramips/image/mt7621.mk || {
  echo 'ERROR: selected LEDE ref has no xiaomi_mi-router-cr660x device profile.' >&2
  exit 1
}

# Do not apply the Filogic/NX30 Pro-specific mac80211 netns patch to ramips/mt7621.

# Add the maintained PassWall package and LuCI feeds before feed metadata is updated.
python3 - "$BUILD_DIR/feeds.conf.default" "$PASSWALL_PACKAGES_REF" "$PASSWALL_LUCI_REF" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
packages_ref, luci_ref = sys.argv[2:4]
lines = path.read_text(encoding="utf-8").splitlines()
lines = [
    line for line in lines
    if not line.strip().startswith("src-git passwall_packages ")
    and not line.strip().startswith("src-git passwall_luci ")
]
prefix = [
    f"src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;{packages_ref}",
    f"src-git passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git;{luci_ref}",
]
path.write_text("\n".join(prefix + lines) + "\n", encoding="utf-8")
PY

./scripts/feeds update -a
./scripts/feeds install -a

# Trim LEDE's oversized router seed instead of fighting its forced defaults
# one package at a time. Keep only the base network stack here; Campus SY
# explicitly selects its own feature packages in packages.common.config.
python3 - "$BUILD_DIR/include/target.mk" "$BUILD_DIR/feeds/luci/modules/luci-mod-admin-full/Makefile" "$BUILD_DIR/feeds/packages/net/sqm-scripts/Makefile" <<'PY'
from pathlib import Path
import sys

target_mk = Path(sys.argv[1])
luci_admin_mk = Path(sys.argv[2])
sqm_mk = Path(sys.argv[3])

text = target_mk.read_text(encoding="utf-8")
start_token = "DEFAULT_PACKAGES.router:=" + chr(92) + "\n"
end_token = "\n\nifneq ($(DUMP),)"
if text.count(start_token) != 1:
    raise SystemExit("ERROR: could not uniquely locate DEFAULT_PACKAGES.router in include/target.mk")
start = text.index(start_token)
end = text.index(end_token, start)
minimal = "\n".join([
    "DEFAULT_PACKAGES.router:=" + chr(92),
    "\tdnsmasq-full firewall4 nftables-json iptables ppp ppp-mod-pppoe " + chr(92),
    "\todhcp6c odhcpd-ipv6only ip6tables libip6tc kmod-ipt-nat6",
])
text = text[:start] + minimal + text[end:]
target_mk.write_text(text, encoding="utf-8")
if "luci-app-ssr-plus" in text or "luci-app-ddns" in text:
    raise SystemExit("ERROR: optional apps remain in the router default package seed.")

# OUI badges are optional MAC-vendor decorations, not required for LuCI admin.
# Drop the hard dependency but preserve the full network/status/system UI.
text = luci_admin_mk.read_text(encoding="utf-8")
old_dep = "LUCI_DEPENDS:=+luci-base +luci-mod-status +luci-mod-system +luci-mod-network +luci-app-oui"
new_dep = "LUCI_DEPENDS:=+luci-base +luci-mod-status +luci-mod-system +luci-mod-network"
if text.count(old_dep) != 1:
    raise SystemExit("ERROR: expected luci-mod-admin-full OUI dependency was not found exactly once.")
luci_admin_mk.write_text(text.replace(old_dep, new_dep), encoding="utf-8")
if "luci-app-oui" in luci_admin_mk.read_text(encoding="utf-8"):
    raise SystemExit("ERROR: optional OUI dependency was not removed.")

# The Coolsnowwolf SQM package still carries legacy iptables-only dependencies.
# Campus SY uses firewall4/nftables, so switch SQM to the upstream nftables
# dependency set while retaining tc, CAKE and IFB runtime support.
sqm_text = sqm_mk.read_text(encoding="utf-8")
old_sqm_dep = (
    "DEPENDS:=+tc +kmod-sched-core +kmod-ifb +iptables \\n"
    "\t+iptables-mod-ipopt +iptables-mod-conntrack-extra \\n"
    "\t+kmod-sched-cake"
)
new_sqm_dep = (
    "DEPENDS:=+tc +ip-full +kmod-sched-core +kmod-ifb +nftables-json \\n"
    "\t+kmod-sched-cake"
)
if sqm_text.count(old_sqm_dep) != 1:
    raise SystemExit("ERROR: expected legacy iptables dependency in sqm-scripts was not found exactly once.")
sqm_mk.write_text(sqm_text.replace(old_sqm_dep, new_sqm_dep), encoding="utf-8")
if "iptables-mod-conntrack-extra" in sqm_mk.read_text(encoding="utf-8"):
    raise SystemExit("ERROR: SQM legacy iptables dependency was not removed.")
print("Patched SQM dependencies for firewall4/nftables; kept tc, CAKE and IFB.")

# The standalone SSR-Plus feed package is not part of Campus SY; removing its
# feed link also removes its orphan Kconfig toggles and their hidden dependencies.
ssr_pkg = Path("package/feeds/helloworld/luci-app-ssr-plus")
if ssr_pkg.is_symlink() or ssr_pkg.exists():
    ssr_pkg.unlink() if ssr_pkg.is_symlink() or ssr_pkg.is_file() else __import__("shutil").rmtree(ssr_pkg)
print("Slimmed LEDE router defaults and removed optional LuCI OUI / SSR-Plus feed entries.")
PY

# Stage MentoHUST's daemon and its separate LuCI application as two OpenWrt packages.
MENTOHUST_SRC_DIR="$ROOT_DIR/work/MentoHUST-src"
git clone --depth 1 https://github.com/sbwml/luci-app-mentohust.git "$MENTOHUST_SRC_DIR"
test -f "$MENTOHUST_SRC_DIR/mentohust/Makefile" || {
  echo 'ERROR: MentoHUST daemon package Makefile not found.' >&2
  exit 1
}
test -f "$MENTOHUST_SRC_DIR/luci-app-mentohust/Makefile" || {
  echo 'ERROR: MentoHUST LuCI package Makefile not found.' >&2
  exit 1
}
rm -rf package/mentohust package/luci-app-mentohust
cp -a "$MENTOHUST_SRC_DIR/mentohust" package/mentohust
cp -a "$MENTOHUST_SRC_DIR/luci-app-mentohust" package/luci-app-mentohust

# Stage the requested Dr.COM, ESurfing and UU client packages.
DOGCOM_SRC_DIR="$ROOT_DIR/work/Dogcom-src"
DOGCOM_LUCI_SRC_DIR="$ROOT_DIR/work/Dogcom-LuCI-src"
git clone --depth 1 https://github.com/mchome/openwrt-dogcom.git "$DOGCOM_SRC_DIR"
git clone --depth 1 https://github.com/mchome/luci-app-dogcom.git "$DOGCOM_LUCI_SRC_DIR"
test -f "$DOGCOM_SRC_DIR/Makefile" && test -f "$DOGCOM_LUCI_SRC_DIR/Makefile" || {
  echo 'ERROR: Dogcom core / LuCI package missing.' >&2; exit 1;
}
rm -rf package/openwrt-dogcom package/luci-app-dogcom
cp -a "$DOGCOM_SRC_DIR" package/openwrt-dogcom
cp -a "$DOGCOM_LUCI_SRC_DIR" package/luci-app-dogcom

ESURFING_SRC_DIR="$ROOT_DIR/work/ESurfing-src"
git clone --depth 1 --branch "$ESURFING_REF" https://github.com/BadGhost520/ESurfingClient-CVersion.git "$ESURFING_SRC_DIR"
bash "$ESURFING_SRC_DIR/scripts/sync-version.sh" 2.2.1-r7
test -f "$ESURFING_SRC_DIR/esurfingclient/Makefile" && test -f "$ESURFING_SRC_DIR/luci-app-esurfingclient/Makefile" || {
  echo 'ERROR: ESurfingClient OpenWrt packages missing.' >&2; exit 1;
}
rm -rf package/esurfingclient package/luci-app-esurfingclient
cp -a "$ESURFING_SRC_DIR/esurfingclient" package/esurfingclient
cp -a "$ESURFING_SRC_DIR/luci-app-esurfingclient" package/luci-app-esurfingclient

# ESurfingClient needs curl's staging headers and the libcurl package.
# PKG_BUILD_DEPENDS names the source package (PKG_NAME=curl), not the binary
# library subpackage (libcurl).
sed -i 's/^PKG_BUILD_DEPENDS:=libcurl$/PKG_BUILD_DEPENDS:=curl/' package/esurfingclient/Makefile
grep -qx 'PKG_BUILD_DEPENDS:=curl' package/esurfingclient/Makefile || {
  echo 'ERROR: ESurfingClient curl build dependency normalization failed.' >&2
  exit 1
}

# ESurfingClient upstream defaults to a fully static libcurl link on Linux.
# OpenWrt's libcurl.a has transitive OpenSSL/nghttp2 dependencies that CMake's
# FindCURL target does not propagate here. Use OpenWrt's shared libcurl instead
# and declare it as a runtime dependency of the client package.
python3 - package/esurfingclient/Makefile package/esurfingclient/app/CMakeLists.txt <<'PY'
from pathlib import Path
import sys

makefile = Path(sys.argv[1])
cmake = Path(sys.argv[2])
mk = makefile.read_text(encoding="utf-8")
cm = cmake.read_text(encoding="utf-8")

static_link = '-DCMAKE_EXE_LINKER_FLAGS="-static -lpthread -latomic"'
shared_link = '-DCMAKE_EXE_LINKER_FLAGS="-lpthread -latomic"'
if mk.count(static_link) != 1:
    raise SystemExit("ERROR: expected ESurfingClient static linker flag was not found exactly once.")
mk = mk.replace(static_link, shared_link)

# CURL_STATICLIB is only needed for Windows DLL builds. OpenWrt uses shared libcurl.
if mk.count("-DCURL_STATICLIB -pthread") != 2:
    raise SystemExit("ERROR: expected two ESurfingClient CURL_STATICLIB compile flags.")
mk = mk.replace("-DCURL_STATICLIB -pthread", "-pthread")

title = "\tTITLE:=ESurfingClient\n"
if mk.count(title) != 1:
    raise SystemExit("ERROR: ESurfingClient package title anchor was not found exactly once.")
mk = mk.replace(title, title + "\tDEPENDS:=+libcurl +libatomic\n")

old = """    set(BUILD_SHARED_LIBS OFF)
    set(CURL_USE_STATIC_LIBS TRUE)

    set(CMAKE_FIND_LIBRARY_SUFFIXES .a ${CMAKE_FIND_LIBRARY_SUFFIXES})
endif ()"""
new = """    set(BUILD_SHARED_LIBS OFF)
    if (__OPENWRT__)
        # Prefer OpenWrt's shared libcurl; static libcurl.a has unpropagated
        # OpenSSL/nghttp2 dependencies in this upstream CMake project.
        set(CURL_USE_STATIC_LIBS FALSE)
        set(CMAKE_FIND_LIBRARY_SUFFIXES .so .a)
    else ()
        set(CURL_USE_STATIC_LIBS TRUE)
        set(CMAKE_FIND_LIBRARY_SUFFIXES .a ${CMAKE_FIND_LIBRARY_SUFFIXES})
    endif ()
endif ()"""
if cm.count(old) != 1:
    raise SystemExit("ERROR: expected Linux static-CURL CMake block was not found exactly once.")
cm = cm.replace(old, new)

# Refuse to build if FindCURL still resolves the static archive on OpenWrt.
if cm.count("find_package(CURL REQUIRED)") != 1:
    raise SystemExit("ERROR: ESurfingClient find_package(CURL) anchor was not found exactly once.")
find_guard = r'''find_package(CURL REQUIRED)

if (__OPENWRT__)
    set(_curl_link_candidates "${CURL_LIBRARIES};${CURL_LIBRARY};${CURL_LIBRARY_RELEASE}")
    if (_curl_link_candidates MATCHES "[.]a($|[;])")
        message(FATAL_ERROR "OpenWrt ESurfingClient selected static libcurl: ${_curl_link_candidates}")
    endif ()
    message(STATUS "OpenWrt ESurfingClient shared libcurl: ${_curl_link_candidates}")
endif ()'''
cm = cm.replace("find_package(CURL REQUIRED)", find_guard)

makefile.write_text(mk, encoding="utf-8")
cmake.write_text(cm, encoding="utf-8")

if "-static -lpthread -latomic" in mk:
    raise SystemExit("ERROR: ESurfingClient still forces a static executable link.")
if "-DCURL_STATICLIB" in mk:
    raise SystemExit("ERROR: ESurfingClient still defines CURL_STATICLIB for shared libcurl.")
if "DEPENDS:=+libcurl +libatomic" not in mk:
    raise SystemExit("ERROR: ESurfingClient runtime libcurl/libatomic dependencies are missing.")
if "if (__OPENWRT__)\n        # Prefer OpenWrt's shared libcurl" not in cm:
    raise SystemExit("ERROR: OpenWrt shared-libcurl selection patch did not apply.")
print("Patched ESurfingClient to use shared libcurl with explicit runtime dependency.")
PY

UU_SRC_DIR="$ROOT_DIR/work/UU-src"
git clone --depth 1 --branch "$UU_REF" https://github.com/xiaodoudou/luci-app-uugamebooster.git "$UU_SRC_DIR"
if ! command -v zig >/dev/null 2>&1 && [ ! -x "$HOME/zig/zig" ]; then
  echo "ERROR: Zig $ZIG_VERSION is required for UU architecture shims." >&2; exit 1;
fi
if [ -x "$HOME/zig/zig" ]; then export PATH="$HOME/zig:$PATH"; fi
sh "$UU_SRC_DIR/tools/build-preload.sh" "$UU_SRC_DIR/luci-app-uugamebooster/root/usr/lib/uuplugin"
test -s "$UU_SRC_DIR/luci-app-uugamebooster/root/usr/lib/uuplugin/uu-view-preload-aarch64.so" || {
  echo 'ERROR: UU aarch64 view-filter shim not generated.' >&2; exit 1;
}
rm -rf package/luci-app-uugamebooster
cp -a "$UU_SRC_DIR/luci-app-uugamebooster" package/luci-app-uugamebooster

# The LEDE Kconfig symbol is libstdcpp; ABI_VERSION=6 is only the runtime
# package ABI suffix and is not the source package name used by LUCI_DEPENDS.
sed -i 's/+libstdcpp6/+libstdcpp/g' package/luci-app-uugamebooster/Makefile
grep -q 'LUCI_DEPENDS:=.*+libstdcpp' package/luci-app-uugamebooster/Makefile || {
  echo 'ERROR: UU Game Booster libstdc++ dependency normalization failed.' >&2
  exit 1
}

# UA3F keeps its OpenWrt package Makefile under openwrt/ and Go sources at the repo root.
# Stage a proper top-level package directory, then fix source paths for OpenWrt's build system.
UA3F_SRC_DIR="$ROOT_DIR/work/UA3F-src"
rm -rf "$UA3F_SRC_DIR" package/UA3F
git clone --depth 1 --branch "$UA3F_REF" https://github.com/SunBK201/UA3F.git "$UA3F_SRC_DIR"
mkdir -p package/UA3F
cp "$UA3F_SRC_DIR"/go.mod "$UA3F_SRC_DIR"/go.sum "$UA3F_SRC_DIR"/main.go "$UA3F_SRC_DIR"/LICENSE package/UA3F/
cp -a "$UA3F_SRC_DIR"/cmd "$UA3F_SRC_DIR"/internal package/UA3F/
cp -a "$UA3F_SRC_DIR"/openwrt/files "$UA3F_SRC_DIR"/openwrt/htdocs "$UA3F_SRC_DIR"/openwrt/luasrc "$UA3F_SRC_DIR"/openwrt/po package/UA3F/
cp "$UA3F_SRC_DIR"/openwrt/Makefile package/UA3F/Makefile
python3 - "$BUILD_DIR/package/UA3F/Makefile" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
content = content.replace("PKG_NAME:=UA3F", "PKG_NAME:=ua3f")
content = content.replace(
    "$(CP) ../go.mod ../go.sum ../main.go ../cmd ../internal $(PKG_BUILD_DIR)",
    "$(CP) $(TOPDIR)/package/UA3F/go.mod $(TOPDIR)/package/UA3F/go.sum $(TOPDIR)/package/UA3F/main.go $(TOPDIR)/package/UA3F/cmd $(TOPDIR)/package/UA3F/internal $(PKG_BUILD_DIR)"
)
content = content.replace("po2lmo ./po/zh_cn/ua3f.po", "po2lmo $(TOPDIR)/package/UA3F/po/zh_cn/ua3f.po")
content = content.replace("./files/", "$(TOPDIR)/package/UA3F/files/")
content = content.replace("./luasrc/", "$(TOPDIR)/package/UA3F/luasrc/")
content = content.replace("./htdocs/", "$(TOPDIR)/package/UA3F/htdocs/")

# Campus SY uses UA3F's native nftables backend. On OpenWrt, detectFirewallBackend()
# selects nftables whenever nft + kmod-nft-tproxy (TPROXY) and, where needed,
# kmod-nft-queue (NFQUEUE/desync) are installed. Do not pull in the legacy
# iptables extension stack: it reintroduces kmod-ipt-raw and is not needed here.
old_dep = "\tDEPENDS:=$(GO_ARCH_DEPENDS) +luci-compat +ipset +iptables +iptables-mod-tproxy +iptables-mod-extra +iptables-mod-ipopt +iptables-mod-nfqueue +iptables-mod-conntrack-extra +kmod-nf-conntrack-netlink"
new_dep = "\tDEPENDS:=$(GO_ARCH_DEPENDS) +luci-compat +nftables-json +kmod-nft-tproxy +kmod-nft-queue +kmod-sched-bpf +libubox-lua +kmod-nf-conntrack-netlink"
if content.count(old_dep) != 1:
    raise SystemExit("ERROR: expected UA3F legacy iptables dependency line was not found exactly once.")
content = content.replace(old_dep, new_dep)
if "iptables-mod-conntrack-extra" in content or "iptables-mod-tproxy" in content:
    raise SystemExit("ERROR: UA3F legacy iptables package dependencies remain.")
if "+nftables-json" not in content or "+kmod-nft-tproxy" not in content or "+kmod-nft-queue" not in content:
    raise SystemExit("ERROR: UA3F nftables dependency set is incomplete.")
if "../go.mod" in content or "./files/" in content or "./luasrc/" in content or "./htdocs/" in content:
    raise SystemExit("UA3F Makefile path normalization incomplete.")
path.write_text(content, encoding="utf-8")
print("Patched UA3F package dependencies to native nftables TPROXY/NFQUEUE backend.")
PY

# Pin the well-established Argon theme to the current stable upstream release.
ARGON_SRC_DIR="$ROOT_DIR/work/Argon-src"
git clone --depth 1 --branch "$ARGON_REF" https://github.com/jerrykuku/luci-theme-argon.git "$ARGON_SRC_DIR"
test -f "$ARGON_SRC_DIR/Makefile" || {
  echo 'ERROR: Argon theme Makefile not found.' >&2
  exit 1
}
rm -rf package/luci-theme-argon
cp -a "$ARGON_SRC_DIR" package/luci-theme-argon

cat "$ROOT_DIR/configs/packages.common.config" "$DEVICE_CONFIG" > .config
make defconfig

# Assert target profile survived Kconfig.
grep -qx "$TARGET_PROFILE_LINE" .config || {
  echo "ERROR: target profile $DEVICE_PROFILE was dropped by Kconfig." >&2
  exit 1
}
for package in \
  ua3f nftables-json kmod-nft-queue kmod-nft-tproxy kmod-sched-bpf libubox-lua \
  kmod-nft-core kmod-nfnetlink-queue kmod-nf-tproxy kmod-nf-conntrack \
  kmod-nf-conntrack-netlink kmod-sched-core dnsmasq-full \
  luci-app-passwall ipt2socks mentohust luci-app-mentohust libpcap \
  dogcom luci-app-dogcom esurfingclient luci-app-esurfingclient libcurl libatomic \
  luci-app-uugamebooster wpad-openssl \
  luci-proto-relay relayd iw kmod-nft-socket kmod-nft-nat \
  luci-base luci-mod-admin-full luci-mod-network luci-mod-status luci-mod-system \
  luci-app-firewall luci-proto-ppp uhttpd uhttpd-mod-ubus rpcd-mod-rrdns \
  luci-theme-argon luci-app-argon-config \
  luci-app-sqm sqm-scripts tc-tiny kmod-ifb kmod-sched-cake \
  kmod-nf-reject kmod-nf-reject6 kmod-tun kmod-ipt-nat unshare libstdcpp; do
  if ! grep -qx "CONFIG_PACKAGE_${package}=y" .config; then
    echo "ERROR: required package ${package} is missing or was dropped by Kconfig." >&2
    exit 1
  fi
done

# PassWall's Nftables Transparent Proxy Kconfig option selects ipt2socks
# even when the Iptables Transparent Proxy option is disabled.
if ! grep -qx 'CONFIG_PACKAGE_luci-app-passwall_Nftables_Transparent_Proxy=y' .config; then
  echo 'ERROR: PassWall Nftables Transparent Proxy option was dropped by Kconfig.' >&2
  exit 1
fi
if grep -qx 'CONFIG_PACKAGE_luci-app-passwall_Iptables_Transparent_Proxy=y' .config; then
  echo 'ERROR: PassWall Iptables Transparent Proxy must remain disabled.' >&2
  exit 1
fi

# Assert the four PPP / PPPoE runtime layers used by FlashNet.
for ppp_package in ppp ppp-mod-pppoe kmod-ppp kmod-pppoe; do
  if ! grep -qx "CONFIG_PACKAGE_${ppp_package}=y" .config; then
    echo "ERROR: required FlashNet PPP package ${ppp_package} is missing." >&2
    exit 1
  fi
done

# Reject unrequested proxy frontends and unrelated acceleration apps.
for forbidden in \
  luci luci-light luci-theme-bootstrap luci-app-oui luci-app-package-manager \
  luci-app-openclash luci-app-ssr-plus luci-app-turboacc luci-app-minieap \
  luci-app-arpbind luci-app-autoreboot luci-app-ddns luci-app-filetransfer \
  luci-app-nlbwmon luci-app-rclone luci-app-upnp luci-app-vlmcsd \
  luci-app-vsftpd luci-app-wol luci-app-accesscontrol \
  ddns-scripts-aliyun ddns-scripts_dnspod ddns-scripts_aliyun \
  ddns-scripts coremark block-mount kmod-nf-nathelper kmod-nf-nathelper-extra \
  kmod-ipt-raw kmod-ipt-conntrack-extra iptables-mod-conntrack-extra \
  iptables-mod-tproxy iptables-mod-extra iptables-mod-ipopt iptables-mod-nfqueue \
  default-settings; do
  if grep -qx "CONFIG_PACKAGE_${forbidden}=y" .config; then
    echo "ERROR: unrequested package ${forbidden} was selected." >&2
    exit 1
  fi
done

# These meta-collections must stay off: they re-add package-manager, Bootstrap,
# and IPv6 UI components that Campus SY does not request.
for forbidden in luci luci-light luci-app-oui luci-app-package-manager luci-theme-bootstrap luci-proto-ipv6; do
  if grep -qx "CONFIG_PACKAGE_${forbidden}=y" .config; then
    echo "ERROR: unwanted LuCI collection/component ${forbidden} was selected." >&2
    exit 1
  fi
done

# Confirm no unrequested translations or helper daemons leaked from the seed config.
for forbidden in \
  luci-i18n-arpbind-zh-cn luci-i18n-autoreboot-zh-cn luci-i18n-ddns-zh-cn \
  luci-i18n-filetransfer-zh-cn luci-i18n-nlbwmon-zh-cn \
  luci-i18n-package-manager-zh-cn luci-i18n-ssr-plus-zh-cn \
  luci-i18n-upnp-zh-cn luci-i18n-vlmcsd-zh-cn luci-i18n-vsftpd-zh-cn \
  luci-i18n-wol-zh-cn 3proxy dns2tcp nping vsftpd vlmcsd etherwake coremark htop default-settings; do
  if grep -qx "CONFIG_PACKAGE_${forbidden}=y" .config; then
    echo "ERROR: unrequested package ${forbidden} was selected." >&2
    exit 1
  fi
done

# Confirm the standalone SSR-Plus app and PassWall's optional SSR-libev engines stay disabled.
if grep -qx 'CONFIG_PACKAGE_luci-app-ssr-plus=y' .config; then
  echo 'ERROR: standalone luci-app-ssr-plus must not be enabled; use PassWall.' >&2
  exit 1
fi
if grep -qx 'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Client=y' .config || \
   grep -qx 'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Server=y' .config; then
  echo 'ERROR: PassWall SSR-libev engines should stay disabled for this build.' >&2
  exit 1
fi
if grep -qx 'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Client=y' .config || \
   grep -qx 'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Simple_Obfs=y' .config || \
   grep -qx 'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Plugin=y' .config; then
  echo 'ERROR: optional PassWall Rust/obfs/plugin components must remain disabled to preserve flash space.' >&2
  exit 1
fi

# Apply shared first-boot defaults and STA recovery service; no NX30-specific
# partition, DTS, or wireless-driver files are copied into this device profile.
mkdir -p files/etc/uci-defaults files/etc/init.d files/etc/config files/usr/sbin
cp "$ROOT_DIR/files/etc/uci-defaults/98-campus-sy-cr660x" files/etc/uci-defaults/
cp "$ROOT_DIR/files/etc/init.d/wifi-bridge-guard" files/etc/init.d/
cp "$ROOT_DIR/files/etc/config/wifi-bridge-guard" files/etc/config/
cp "$ROOT_DIR/files/usr/sbin/wifi-bridge-guard" files/usr/sbin/
chmod 0755 files/etc/uci-defaults/98-campus-sy-cr660x
chmod 0755 files/etc/init.d/wifi-bridge-guard files/usr/sbin/wifi-bridge-guard

echo 'Disk before downloads:'
df -h .
make download -j"$(nproc)" V=s || make download -j1 V=s

echo 'Disk before compilation:'
df -h .
make -j"$(nproc)" V=s

OUT="$BUILD_DIR/bin/targets/$TARGET_SUBDIR"
test -d "$OUT" || { echo 'ERROR: expected target output directory not found.' >&2; exit 1; }
SYSUPGRADE_IMAGE="$(find "$OUT" -maxdepth 1 -type f -name "$SYSUPGRADE_GLOB" -print -quit)"
FACTORY_IMAGE="$(find "$OUT" -maxdepth 1 -type f -name "$FACTORY_GLOB" -print -quit)"
if [[ -z "$SYSUPGRADE_IMAGE" ]]; then
  echo "ERROR: CR660x sysupgrade image was not generated." >&2
  find "$OUT" -maxdepth 1 -type f -printf '%f\n' | sort || true
  exit 1
fi
if [[ -z "$FACTORY_IMAGE" ]]; then
  echo "ERROR: CR660x factory.bin was not generated; refusing to publish this build." >&2
  find "$OUT" -maxdepth 1 -type f -printf '%f\n' | sort || true
  exit 1
fi

# Verify the source image recipe rather than merely renaming another artifact.
IMAGE_MK="$BUILD_DIR/target/linux/ramips/image/mt7621.mk"
DEVICE_BLOCK="$(sed -n '/^define Device\/xiaomi_mi-router-cr660x$/,/^endef$/p' "$IMAGE_MK")"
grep -q 'IMAGE_SIZE := 128512k' <<<"$DEVICE_BLOCK" || { echo "ERROR: unexpected CR660x IMAGE_SIZE." >&2; exit 1; }
grep -q 'KERNEL_SIZE := 4096k' <<<"$DEVICE_BLOCK" || { echo "ERROR: unexpected CR660x kernel partition size." >&2; exit 1; }
grep -q 'IMAGES += factory.bin' <<<"$DEVICE_BLOCK" || { echo "ERROR: upstream CR660x factory declaration missing." >&2; exit 1; }
grep -q 'IMAGE/factory.bin := append-kernel .*append-ubi' <<<"$DEVICE_BLOCK" || { echo "ERROR: CR660x factory image recipe missing or changed." >&2; exit 1; }

TAR_PREFIX="sysupgrade-xiaomi_mi-router-cr660x"
tar -tf "$SYSUPGRADE_IMAGE" | grep -qx "$TAR_PREFIX/kernel" || { echo "ERROR: sysupgrade tar has no CR660x kernel member." >&2; exit 1; }
tar -tf "$SYSUPGRADE_IMAGE" | grep -qx "$TAR_PREFIX/root" || { echo "ERROR: sysupgrade tar has no CR660x root member." >&2; exit 1; }
KERNEL_BYTES="$(tar -xOf "$SYSUPGRADE_IMAGE" "$TAR_PREFIX/kernel" | wc -c | tr -d ' ')"
ROOTFS_BYTES="$(tar -xOf "$SYSUPGRADE_IMAGE" "$TAR_PREFIX/root" | wc -c | tr -d ' ')"
FACTORY_BYTES="$(stat -c '%s' "$FACTORY_IMAGE")"
MAX_KERNEL_BYTES=$((4 * 1024 * 1024))
MAX_FACTORY_BYTES=$((128512 * 1024))
echo "CR660X_KERNEL_BYTES=$KERNEL_BYTES"
echo "CR660X_ROOTFS_BYTES=$ROOTFS_BYTES"
echo "CR660X_FACTORY_BYTES=$FACTORY_BYTES"
if (( KERNEL_BYTES > MAX_KERNEL_BYTES )); then
  echo "ERROR: CR660x kernel exceeds the 4 MiB kernel partition." >&2
  exit 1
fi
if (( FACTORY_BYTES > MAX_FACTORY_BYTES )); then
  echo "ERROR: CR660x factory image exceeds 128512 KiB." >&2
  exit 1
fi
if [[ "$(sha256sum "$SYSUPGRADE_IMAGE" | awk '{print $1}')" == "$(sha256sum "$FACTORY_IMAGE" | awk '{print $1}')" ]]; then
  echo "ERROR: factory and sysupgrade are identical; refusing to publish." >&2
  exit 1
fi

MANIFEST="$(find "$OUT" -maxdepth 1 -type f -name '*xiaomi_mi-router-cr660x.manifest' -print -quit)"
test -n "$MANIFEST" || { echo "ERROR: CR660x manifest missing." >&2; exit 1; }
for package in ua3f kmod-nft-queue kmod-nft-tproxy kmod-sched-bpf libubox-lua mentohust dogcom esurfingclient luci-app-passwall luci-app-uugamebooster wpad-openssl; do
  if ! awk '{print $1}' "$MANIFEST" | grep -Fxq "$package"; then
    echo "ERROR: required package $package is missing from final CR660x manifest." >&2
    exit 1
  fi
done

cp .config "$OUT/build.config"
{
  echo "DEVICE_PROFILE=$DEVICE_PROFILE"
  echo "DEVICE_COMPATIBLE=xiaomi,mi-router-cr660x"
  echo "LEDE_REPO=$LEDE_REPO"
  echo "LEDE_REF=$LEDE_REF"
  echo "LEDE_COMMIT=$(git rev-parse HEAD)"
  echo "UA3F_REF=$UA3F_REF"
  echo "UA3F_COMMIT=$(git -C "$UA3F_SRC_DIR" rev-parse HEAD)"
  echo "ESURFING_REF=$ESURFING_REF"
  echo "ESURFING_COMMIT=$(git -C "$ESURFING_SRC_DIR" rev-parse HEAD)"
  echo "DOGCOM_COMMIT=$(git -C "$DOGCOM_SRC_DIR" rev-parse HEAD)"
  echo "DOGCOM_LUCI_COMMIT=$(git -C "$DOGCOM_LUCI_SRC_DIR" rev-parse HEAD)"
  echo "UU_REF=$UU_REF"
  echo "UU_COMMIT=$(git -C "$UU_SRC_DIR" rev-parse HEAD)"
  echo "PASSWALL_LUCI_REF=$PASSWALL_LUCI_REF"
  echo "PASSWALL_LUCI_COMMIT=$(git -C "$BUILD_DIR/feeds/passwall_luci" rev-parse HEAD)"
  echo "PASSWALL_PACKAGES_REF=$PASSWALL_PACKAGES_REF"
  echo "PASSWALL_PACKAGES_COMMIT=$(git -C "$BUILD_DIR/feeds/passwall_packages" rev-parse HEAD)"
  echo "MENTOHUST_COMMIT=$(git -C "$MENTOHUST_SRC_DIR" rev-parse HEAD)"
  echo "ARGON_REF=$ARGON_REF"
  echo "ARGON_COMMIT=$(git -C "$ARGON_SRC_DIR" rev-parse HEAD)"
  echo "CR660X_KERNEL_BYTES=$KERNEL_BYTES"
  echo "CR660X_ROOTFS_BYTES=$ROOTFS_BYTES"
  echo "CR660X_FACTORY_BYTES=$FACTORY_BYTES"
  echo "CR660X_FACTORY_MAX_BYTES=$MAX_FACTORY_BYTES"
} > "$OUT/BUILD-INFO.txt"

find "$OUT" -maxdepth 1 -type f \( -name '*.bin' -o -name '*.itb' -o -name '*.img' -o -name '*.tar' \) -print0 | xargs -0 -r sha256sum > "$OUT/SHA256SUMS"
test -s "$OUT/SHA256SUMS" || { echo 'ERROR: no firmware images found for checksumming.' >&2; exit 1; }
(cd "$OUT" && sha256sum -c SHA256SUMS)

echo 'CR660x build artifacts:'
find "$OUT" -maxdepth 1 -type f -printf '%f\n' | sort
