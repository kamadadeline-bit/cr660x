# Xiaomi Mi Router CR6608 firmware (LEDE)

This repository prepares a CR6608-targeted firmware build from [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede).

## Optimization plan and requested defaults

1. Add an explicit `xiaomi_mi-router-cr6608` target profile and a CR6608 DTS compatible/model identity, reusing the LEDE CR660x series image/partition recipe. This is a source-level target adjustment; verify the exact unit's partition table and recovery method before flashing.
2. Include UA3F, OpenClash LuCI, Turbo ACC, and these requested packages: `kmod-nft-queue`, `kmod-nft-tproxy`, `kmod-sched-bpf`, `libubox-lua`. The build verifies selection and the output packages, instead of treating a successful compile step alone as proof.
3. Set UA3F enabled, TPROXY port 1080, GLOBAL rewrite, the specified QQ Browser User-Agent, TTL rewrite to 64, and TCP timestamp deletion. Keep TCP reordering/injection, fixed IP ID, initial TCP window, QUIC blocking, and eBPF L3 offload disabled as shown in the screenshots.
4. Set Turbo ACC software/hardware flow offload and Shortcut-FE disabled, FullCone NAT disabled, and BBR disabled so the Turbo ACC init script selects CUBIC.
5. Review the generated package artifacts and exact CR6608 image name before considering installation.

## Not included yet

The original `gwifi_clean.tar.gz` campus login plugin is not integrated. Only an incomplete placeholder had been committed earlier, and it has been removed rather than shipping a broken LuCI page. Upload the original archive again before integrating its scripts and web pages. OpenClash LuCI is included, but the Clash/Mihomo core and a user's proxy config are not bundled by the build workflow.

## Flashing safety

The CR6608 profile reuses the CR660x series image/partition recipe. This does not independently establish that every hardware revision or bootloader accepts a given image. Before flashing, compare the actual router revision and `/proc/mtd` layout, choose the correct factory or sysupgrade format for your current installation path, and confirm a recovery route. Do not flash while the image is still unverified.
