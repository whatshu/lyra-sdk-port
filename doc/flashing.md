# 烧写固件

固件集由 `make build` 生成在 `out/firmware/` 中(或由 `make release` 以不可变快照的形式保存在 `RELEASE/` 下)。请在板子物理连接的机器上执行烧写。

## 产物

| 文件 | 说明 |
|---|---|
| `MiniLoaderAll.bin` | SPL loader(DDR 初始化 + u-boot SPL + USB 下载模式) |
| `uboot.img` | 主 U-Boot 镜像(FIT) |
| `boot.img` | kernel + dtb + resource |
| `rootfs.img` | buildroot 根文件系统 |
| `parameter.txt` | 分区表 |
| `update.img` | 上述所有内容打包,用于一条命令烧写 |

## 一条命令烧写(最简单)

将 `update.img` 拷贝到机器上,然后:

```sh
# board in loader mode: hold BOOT + power on, or `adb reboot loader`
# from a booted system.  Check:
upgrade_tool ld          # Mode=Loader  or  Mode=Maskrom
# flash everything:
upgrade_tool uf update.img
```

`upgrade_tool`(Linux Upgrade Tool)是一个静态的 x86_64 二进制程序;SDK 将其打包在 `vendor/rockchip/tools/linux/Linux_Upgrade_Tool/`。你需要对 Rockchip USB 设备节点有写权限——要么以 root 运行,要么安装来自 `tools/scripts/99-rockchip-usb.rules` 的 udev 规则。

## A/B 板子(`lyra-ultra-w-emmc-ab`)

A/B 的 `update.img` 文件包含各槽位副本(`uboot_a/b`、`boot_a/b`、`system_a/b`)以及 A/B 元数据(`misc`),因此它们是作为一个整体被烧写的:

```sh
upgrade_tool uf update.img        # flashes every partition in the image
```

`di -uboot/-b/-rootfs` 标志以及 `rkdeveloptool wlx` 分区标志无法寻址带槽位后缀的分区——始终使用 `uf`(或 `make flash BOARD=lyra-ultra-w-emmc-ab`,它会自动选择正确的模式)。新烧写后默认激活槽位 **a**;参见 `doc/ab-boot.md`。

## 逐个分区烧写(rkdeveloptool)

开源替代方案,适用于 loader 模式的板子:

```sh
sudo apt install rkdeveloptool   # Ubuntu; or build from source
rkdeveloptool ld                 # must list exactly one device
rkdeveloptool ul MiniLoaderAll.bin        # upload loader (idblock)
rkdeveloptool wlx uboot   uboot.img
rkdeveloptool wlx boot    boot.img
rkdeveloptool wlx rootfs  rootfs.img
rkdeveloptool rd                       # reboot
```

> 当检测到不止一个 Rockchip 设备时,rkdeveloptool 拒绝运行(`Found too many rockusb devices`)。请先拔掉其他设备。

## 恢复途径

- loader 始终携带 USB 下载功能,因此即使 rootfs 烧写失败也总能重新烧写——失败的 rootfs 写入永远不会影响 loader 本身。
- **已启动的系统** → `adb reboot loader`(或 `reboot loader`)可重新进入 loader 模式,无需触碰板子。
- **无法启动但 loader 完好** → 重新上电;u-boot 会回退到下载模式,或在开机时按住 **BOOT**。
- **最坏情况** → 开机时按住 **BOOT** → 进入 maskrom;`upgrade_tool uf` 仍然有效(maskrom 接受全新的 loader)。

## 备注

- 在 Ubuntu 22.04 上,USB 设备节点需要 udev 规则(`tools/scripts/99-rockchip-usb.rules`);在一些较新的发行版上,`plugdev` 用户组已经授予了访问权限。
- 如果 loader 上传时报告 `Download Boot Fail / please check ddr`,说明 loader 的 DDR 配置与板子的 RAM 不匹配——请对照 `config/boards/` 仔细检查板子型号(`Makefile` 中的 `BOARD=`)。
