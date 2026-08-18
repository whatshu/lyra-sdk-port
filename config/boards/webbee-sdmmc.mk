# Board: Luckfox Pico WebBee (RV1103) — SD 卡启动
# 对应官方 BoardConfig-SD_CARD-Buildroot-RV1103_Luckfox_Pico_WebBee-IPC.mk
VENDOR := pico
CHIP := rv1103
STORAGE := sdmmc

# 官方 uclibc 工具链(gcc 8.3,烘焙在 docker 镜像 /opt/toolchains 下)
TOOLCHAIN := rockchip830

# U-Boot(官方 defconfig + eMMC/SDMMC iomux fragment)
UBOOT_CFG := luckfox_rv1106_uboot_defconfig
UBOOT_FRAGMENTS := rk-emmc.config
UBOOT_ARCH := arm
UBOOT_SPL := y

# Kernel
KERNEL_ARCH := arm
KERNEL_CFG := luckfox_rv1106_linux_defconfig
KERNEL_DTS := rv1103g-luckfox-pico-webbee

# Buildroot rootfs(精简核心,ext4)
BUILDROOT_CFG := luckfox_pico_ext4
ROOTFS_TYPE := ext4
ROOTFS_SIZE := 6G

# 启动介质与分区布局 —— 与官方 RK_PARTITION_CMD_IN_ENV 完全一致(SD 卡上
# 设备节点为 mmcblk1),由 40-firmware stage 写进 env.img
BOOT_MEDIUM := sd_card
PART_CMD := 32K(env),512K@32K(idblock),256K(uboot),32M(boot),512M(oem),256M(userdata),6G(rootfs)
ROOTFS_ARGS := root=/dev/mmcblk1p7 rootfstype=ext4
CMA_SIZE := 1M
ENV_SIZE := 32K
DATA_FS_TYPE := ext4

# update.img 打包(rkImageMaker 的芯片标记)
RK_TAG := RK1106
REQUIRED := download.bin idblock.img env.img uboot.img boot.img oem.img userdata.img rootfs.img update.img
