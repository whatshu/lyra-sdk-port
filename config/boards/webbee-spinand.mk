# Board: Luckfox Pico WebBee (RV1103) — SPI NAND
# 对应官方 BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_WebBee-IPC.mk
VENDOR := pico
CHIP := rv1103
STORAGE := spinand

# 官方 uclibc 工具链(gcc 8.3,烘焙在 docker 镜像 /opt/toolchains 下)
TOOLCHAIN := rockchip830

# U-Boot(官方 defconfig + SPI NOR/SFC 控制器 iomux fragment)
UBOOT_CFG := luckfox_rv1106_uboot_defconfig
UBOOT_FRAGMENTS := rk-sfc.config
UBOOT_ARCH := arm
UBOOT_SPL := y

# Kernel
KERNEL_ARCH := arm
KERNEL_CFG := luckfox_rv1106_linux_defconfig
KERNEL_DTS := rv1103g-luckfox-pico-webbee

# Buildroot rootfs(精简核心,ubifs)
BUILDROOT_CFG := luckfox_pico_ubifs
ROOTFS_TYPE := ubifs
ROOTFS_SIZE := 85M

# 启动介质与分区布局 —— 与官方 RK_PARTITION_CMD_IN_ENV 完全一致,由
# 40-firmware stage 写进 env.img(SPL 从这里读分区表 + sys_bootargs)
BOOT_MEDIUM := spi_nand
PART_CMD := 256K(env),256K@256K(idblock),512K(uboot),4M(boot),30M(oem),6M(userdata),85M(rootfs)
ROOTFS_ARGS := ubi.mtd=6 root=ubi0:rootfs rootfstype=ubifs
CMA_SIZE := 1M
ENV_SIZE := 256K
DATA_FS_TYPE := ubifs

# update.img 打包(rkImageMaker 的芯片标记)
RK_TAG := RK1106
REQUIRED := download.bin idblock.img env.img uboot.img boot.img oem.img userdata.img rootfs.img update.img
