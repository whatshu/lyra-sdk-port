# Luckfox Pico (RV1106 / RV1103) 系列接入

shu-sdk 在 Lyra (RK3506) 之外,以**同样的 stage 模式**接入 Luckfox Pico 家族。与 Lyra 一样,构建产物遵循官方固件格式(`update.img` 由 `package-file` 定义分区布局),所以烧写、启动、恢复流程与官方 SDK 完全一致。

| target | 板 | SoC | 存储 | 根文件系统 |
|---|---|---|---|---|
| `pico-ultra` | Luckfox Pico Ultra (1106G3) | RV1106G3 | eMMC | ext4 |
| `webbee-spinand` | Luckfox Webbee | RV1103 | SPI NAND | ubifs |
| `webbee-sdmmc` | Luckfox Webbee | RV1103 | SD 卡 | ext4 |

## 构建

```sh
make build BOARD=pico-ultra        # 完整构建 -> out/firmware/{update.img, 分区镜像...}
make build BOARD=webbee-spinand
make build BOARD=webbee-sdmmc
make flash BOARD=pico-ultra        # 烧写(loader 模式 / maskrom)
```

产物清单(以 `pico-ultra` 为例,与官方分区一一对应):

```
out/firmware/
├── download.bin   # mini-loader(官方 make.sh --spl-new 产物,烧写入口)
├── idblock.img    # SPL + DDR init
├── env.img        # u-boot 环境(mkenvimage;blkdevparts + sys_bootargs + sd_parts)
├── uboot.img      # FIT(ATF/OP-TEE/U-Boot,由 rkbin RV1106TOS.ini 打包)
├── boot.img       # FIT(kernel + dtb + resource,由 kernel 树 boot.its 打包)
├── oem.img        # 空分区(保留官方布局)
├── userdata.img   # 空分区(保留官方布局)
├── rootfs.img     # ext4 / ubifs 根文件系统
└── update.img     # afptool + rkImageMaker 总包(.xz 压缩副本 update.img.xz)
```

## 与 Lyra 构建路径的差异

Pico 家族的 vendor 树在 `vendor/pico/`,与 `vendor/rockchip/`(Lyra)平行;`VENDOR=pico` 的
board 会自动选择它。流程上几处不同:

- **u-boot**:官方两步走 —— 先 `make <defconfig> <fragments>` 生成 `.config`,再
  `./make.sh --spl-new`(不带板名;make.sh 会自行追加 `_defconfig` 后缀)。产物是
  `download.bin` + `idblock.img`,**没有** `MiniLoaderAll.bin`。
- **内核**:FIT 引导镜像由 kernel 树内 `scripts/mkimg` + `boot.its` 生成
  (`make <dts>.img` 传 `BOOT_ITS`)。FULL 构建先 `make mrproper`(官方 sysdrv 同款行为,
  防止陈旧的 in-tree 对象混入)。
- **工具链**:官方 `arm-rockchip830-linux-uclibcgnueabihf`(gcc 8.3.0)已烘焙进
  docker 镜像;板配置用 `TOOLCHAIN := rockchip830` 选择它(Lyra 用 arm-gnuabihf 12)。
- **rootfs 后处理**:官方 buildroot 树中的 `board/luckfox/common/post-build.sh` 垫片
  桥接回本 SDK 的 `device/rockchip` 后处理链(与 Lyra 相同的 `../device` 一级上翻约定);
  内核模块安装、inittab、fstab 等全部沿用 SDK 现有逻辑。

## 串口与登录

- 串口 **1500000 8N1**(与官方固件一致)。内核启用了 Rockchip FIQ debugger
  (`CONFIG_FIQ_DEBUGGER_CONSOLE_DEFAULT_ENABLE=y`),`/dev/console` = `ttyFIQ0`,getty
  直接用默认的 `console` 设备,无需改 inittab。
- 登录:`root` / `luckfox`。

## rootfs 范围(精简核心)

本次接入按**精简核心**构建(纯 buildroot):openssh、python3(+ssl)、nano、htop、
iperf3、lrzsz 与基础 busybox。**不包含**官方镜像的媒体/应用/WiFi 组件(RTL8188、
rkipc、RTSP 等)。分区布局与官方完全一致 —— `oem`、`userdata` 以空镜像占位,方便日后
填充或保持烧写工具兼容。

## 烧写

板子进入 loader 模式(或上电按住 BOOT 进 maskrom),然后:

```sh
make flash BOARD=pico-ultra
```

内部流程(与官方 `upgrade_tool` 一致,工具链自带二进制):

```sh
upgrade_tool ul  download.bin    # 写 mini-loader(-noreset,不进 rockusb 会话)
upgrade_tool uf  update.img      # 写整个固件包
upgrade_tool rd                  # 复位重启
```

见 `tools/scripts/flash.sh` 的 pico 分支。恢复手段与 Lyra 相同:能启动的系统上
`reboot-loader` 即可落回 loader 模式;loader 损坏时按住 BOOT 上电进 maskrom。

## 镜像仓过渡(临时)

Pico 的 u-boot / kernel / rkbin / buildroot 是**仓库外本地镜像**的单提交仓,
`vendor/pico/` 下是符号链接指向它们(镜像目录在
`/home/whatshu/develop/project/luckfox/pico/mirrors/`)。容器只挂载 `/sdk`,因此
`Makefile` 会从链接目标推导出镜像目录并经 `SDK_EXTRA_MOUNT` 一并挂载;`device`、
`output` 则沿用与 Lyra 相同的仓库内符号链接。

等 GitHub 仓库就绪后,这些镜像将转为 git submodule(流程与 Lyra 相同),届时移除
`SDK_EXTRA_MOUNT` 过渡逻辑。

## 如何接入 SDK

与 Lyra 同一套扩展点:

- **板级定义** — `config/boards/pico-ultra.mk`、`webbee-spinand.mk`、`webbee-sdmmc.mk`:
  `VENDOR=pico`、`TOOLCHAIN=rockchip830`、u-boot/kernel defconfig + fragments、
  `KERNEL_DTS`、buildroot defconfig,以及固件打包参数(`PART_CMD` / `BOOT_MEDIUM` /
  `ROOTFS_ARGS` / `CMA_SIZE` / `ENV_SIZE` / `RK_TAG` / `REQUIRED`)。
- **组件配置** — `product/platform/configs/{uboot,kernel,buildroot}/`:归档官方
  defconfig 与 fragments(luckfox_rv1106_uboot_defconfig + rk-emmc/rk-sfc/rgb-reset
  fragments、luckfox_rv1106_linux_defconfig、`luckfox_pico_{ext4,ubifs}_defconfig`)。
- **固件打包** — `stages/40-firmware/run.sh` 的 pico 分支:`PART_CMD` 生成 `env.txt`
  (blkdevparts/mtdparts + sys_bootargs + sd_parts)→ `mkenvimage`;空 oem/userdata
  (ext4 / ubifs 双配方);`package-file` → `afptool -pack` → `rkImageMaker -RK1106`
  → `update.img`。
- **构建入口** — `scripts/build.py` 依板解析 `config/boards/*.mk` 并导出为环境变量,
  pico 与 lyra 走同一条 stage 管线(`stages/10-uboot` … `stages/40-firmware`)。
