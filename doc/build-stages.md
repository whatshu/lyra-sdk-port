# 构建阶段

构建过程遵循设备的启动顺序。阶段是目录 `stages/NN-name/`,由 `scripts/build.py` 管理;每个阶段包含一个 `stage.yaml`(元数据)和一个 `run.sh`(配方)。Python 负责生命周期,bash 负责配方。

## 流水线

```
stages/
├── 10-uboot/     # SPL loader + uboot.img  (MiniLoaderAll.bin)
├── 20-kernel/    # zImage + dtb + modules + boot.img/zboot.img
├── 30-rootfs/    # buildroot rootfs (ext4/ubi/squashfs) + post-build hook
└── 40-firmware/  # assemble firmware set + update.img
```

**完整构建**(`make build`)按依赖顺序运行它们;**部分构建**(`make uboot`, …)只运行指定的阶段,并保留任何手动调优的临时配置。

## 配置覆盖语义

| 模式 | 对临时配置的影响 |
|---|---|
| `FULL=1`(构建/发布) | 在阶段运行前,`product/platform/configs/<comp>`(以及 `product/custom/<comp>`)被复制到 vendor 树上;`.config` 被重新生成 |
| `FULL=0`(单阶段) | 不复制,复用现有的 `.config` → `make kernel-menuconfig` 的改动得以保留 |

恢复点位于 `product/platform/configs/`:

- `kernel/rk3506_luckfox_defconfig`, `rk3506-display.config`
- `uboot/rk3506_luckfox_defconfig`, `rk3506b_luckfox.config`
- `buildroot/`(可选的覆盖,复制到 vendored defconfig 之上)

## 每个阶段产出什么

### 10-uboot
运行 Rockchip 的 `u-boot/make.sh` 流程:

```
./make.sh CROSS_COMPILE=<toolchain> rk3506_luckfox [rk3506b_luckfox] --spl-new
```

它进行配置(defconfig + fragments),构建 u-boot + SPL,然后打包 `rk3506_spl_loader_v1.04.110.bin`(即 `MiniLoaderAll.bin`)和 `uboot.img`。rkbin(DDR/trust 二进制块)从 `vendor/rockchip/rkbin` 中获取。

### 20-kernel
```
make ARCH=arm CROSS_COMPILE=<toolchain> rk3506_luckfox_defconfig rk3506-display.config
make ARCH=arm CROSS_COMPILE=<toolchain> <dts>.img      # boot.img/zboot.img + resource.img
make ARCH=arm CROSS_COMPILE=<toolchain> modules
```

`scripts/mkimg` 需要 `mkimage`,由 `vendor/rockchip/rkbin/tools` 提供。

### 30-rootfs
```
make O=output/<cfg> <cfg>_defconfig
make O=output/<cfg>
```

> **Buildroot 输出是与主机相关的。** `output/<cfg>/host/` 树包含链接到*构建*机器 glibc 的主机工具;在一台主机上生成的输出会在另一台主机上的 `target-finalize` 阶段失败(例如 `glib-compile-schemas: undefined symbol g_task_set_static_name`)。务必在固定的容器内从干净的输出开始构建 buildroot。共享 `BR2_DL_DIR` 缓存中的包源码会被复用,因此干净构建只需重新编译。

buildroot 的 vendored post-build hook(`board/rockchip/common/post-build.sh`)调用我们的 shim `device/rockchip/common/post-build.sh`,后者运行 `product/platform/rootfs/post-rootfs.sh`:

- 基础目录 + 便捷符号链接
- 为 root fs 类型配置的 `/etc/fstab`
- os-release 标注
- 内核模块安装
- `product/platform/rootfs/overlay` + `product/custom/rootfs/overlay`
- ld.so.cache

镜像(`rootfs.ext4` / `rootfs.ubi` / …)被复制到 `out/firmware/rootfs.img`。buildroot 的下载缓存保留在 `vendor/rockchip/buildroot/dl`。

### 40-firmware
将 `MiniLoaderAll.bin`、`uboot.img`、`boot.img`、`rootfs.img` 以及 `parameter.txt`(来自 `config/image/`)收集到 `out/firmware/`,然后使用 vendored 的 `afptool` + `rkImageMaker` 打包成一体的 `update.img`。该阶段还会用 xz 压缩它(`xz -T0 -6`,多线程)为 `out/firmware/update.img.xz`,使得同一构建在归档/传输时开销更低(`make release` 以相同方式压缩其快照副本)。

对于 **A/B 板卡**(`AB=1`,例如 `lyra-ultra-w-emmc-ab`),该阶段将 `uboot.img`/`boot.img`/`rootfs.img` 复制为 `uboot_a/b`、`boot_a/b` 和 `system_a/b`,生成携带初始 `AvbABData` 的 `misc.img`(`tools/scripts/mkabmeta.py`),并且 `update.img` 的 package-file 列出所有槽位分区外加 `misc`(参见 `doc/ab-boot.md`)。

## 部分构建的陷阱

`make rootfs` 需要内核至少被构建过一次(模块安装)。`make firmware` 需要 uboot/kernel/rootfs 的产物。阶段脚本会明确报错失败,而不是产出损坏的镜像。
