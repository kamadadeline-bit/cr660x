# Xiaomi CR660X LEDE firmware

This repository contains the build workflow and overlay for the Xiaomi CR660X family, based on [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede).

## Build

Open **Actions → Build Xiaomi CR660X firmware → Run workflow**. The workflow clones LEDE, adds UA3F and OpenClash, configures the `xiaomi_mi-router-cr660x` profile, and uploads build artifacts.

Included requested components: UA3F, OpenClash, and the uploaded `gwifi` LuCI auto-login overlay. The `gwifi` account, password, portal address, NAS name and AES key must be configured for your own campus network after flashing; credentials are intentionally left blank.

**Caution:** LEDE currently labels this target CR660x and lists `xiaomi,mi-router-cr6606` as a supported compatibility string. Verify the exact CR6608 board revision and bootloader/partition compatibility before flashing. Do not flash a factory image unless your current installation method specifically requires it.
