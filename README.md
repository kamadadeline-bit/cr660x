# Xiaomi CR660X LEDE firmware

This repository builds the Xiaomi CR660X-family image from [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede). Run **Actions → Build Xiaomi CR660X firmware → Run workflow**; when it finishes, download the `cr660x-firmware` artifact.

## Current build configuration

- **UA3F**: enabled by default; TPROXY mode, port 1080, global User-Agent rewrite, using the requested QQ Browser User-Agent.
- **UA3F L3 rewrite**: fixed TTL enabled at 64 and TCP timestamp deletion enabled. IP ID rewrite, TCP initial window, QUIC blocking, and eBPF offload remain disabled, matching the supplied screenshots.
- **Turbo ACC**: LuCI page included. Software/hardware flow offload and Shortcut-FE are disabled; FullCone NAT is disabled; BBR selection is off so the system uses CUBIC.
- **Dependencies**: explicitly select `kmod-nft-queue`, `kmod-nft-tproxy`, `kmod-sched-bpf`, `libubox-lua`, and the nftables userspace package. The workflow fails early if these packages are not selected and checks package artifacts after compiling.
- **OpenClash**: LuCI package included. Clash/Mihomo core and its runtime configuration are not bundled by this build step.

Campus login plugin `gwifi` is **not included in this revision**: only a placeholder config had been committed previously, not the original login scripts and LuCI pages. That placeholder has been removed to avoid shipping a nonfunctional entry. The original `gwifi_clean.tar.gz` source must be available again before it can be integrated accurately; credentials should remain blank in a public repository.

## Flashing caution

LEDE identifies its profile as `xiaomi_mi-router-cr660x`; this does not by itself prove that every CR6608 hardware revision has the same partition layout. Verify the exact board revision, current bootloader, firmware image type, and recovery method before flashing. Do not flash the image solely because compilation succeeds.
