# 校园网 SY — Xiaomi CR660x / CR6608 独立设备构建

本仓库独立适配 CR660x 系列设备，公共功能包和构建修复沿用 [NX30 Pro 公共方案](https://github.com/kamadadeline-bit/nx30pro)，但设备配置、DTS、分区、无线驱动和镜像规则保持独立。

## 设备 profile

- Target：`ramips/mt7621`
- 上游 profile：`xiaomi_mi-router-cr660x`
- DTS compatible：`xiaomi,mi-router-cr660x`
- NAND：128 MiB；上游 image recipe 声明 `IMAGE_SIZE := 128512k`
- Kernel 分区：4 MiB；上游 factory recipe 使用 `append-kernel | pad-to 4 MiB | append-ubi`
- 端口与 MAC：沿用上游 CR660x `02_network` board script，不覆盖成 NX30 Pro 的 DSA/Filogic 网络配置
- 无线和设备内核包：由 CR660x 上游 profile 负责

**设备边界：** 本次编译目标固定为上游 CR660x profile。CR6606/CR6608/CR6609 不能只凭系列名称假定所有硬件修订完全相同；刷机前核对机身型号、`ubus call system board`、`/tmp/sysinfo/board_name` 和 `/proc/mtd`。

## 公共校园网包白名单

沿用 NX30 Pro 的公共包配置：UA3F（nftables TPROXY 与内核依赖）、MentoHUST、Dogcom、ESurfingClient C、NetKeeper/闪讯 PPP 环境、WPA-EAP（wpad-openssl）、UU 游戏加速器、PassWall（nftables）、SQM、Wi-Fi relay 组件、STA 掉线恢复服务及 Argon 中文主题。

不加入 OpenClash、SSR-Plus、Turbo ACC、MiniEAP、Docker 等当前公共白名单以外的组件。NetKeeper/闪讯环境不等于 H3C iNode 认证后端；具体校园网认证仍需按学校环境验证。

## 构建产物与强制检查

每次成功构建必须同时有：

- `openwrt-ramips-mt7621-xiaomi_mi-router-cr660x-squashfs-factory.bin`
- `openwrt-ramips-mt7621-xiaomi_mi-router-cr660x-squashfs-sysupgrade.bin`
- CR660x `.manifest`
- `BUILD-INFO.txt`、`build.config`、`SHA256SUMS`

构建脚本检查上游 factory 生成规则、两种镜像是否分别生成、sysupgrade tar 的 kernel/root 成员、4 MiB kernel 分区、factory 镜像大小、最终 manifest 必需包及 SHA-256 自检。factory 缺失或任何检查失败时，Actions 必须失败且不发布固件。

## 刷机安全

- factory 与 sysupgrade 用途不同，不能互相改名代替。
- factory 只用于与实际硬件修订、引导程序及分区布局匹配的首次刷机路径；sysupgrade 仅用于已运行兼容 OpenWrt/LEDE 的系统内升级。
- 不要强制绕过设备兼容性检查。
- 首次测试前备份原厂分区和配置，并确认设备专用恢复途径。
