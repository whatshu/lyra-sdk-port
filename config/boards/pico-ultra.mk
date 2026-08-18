# Board: Luckfox Pico Ultra (RV1106G3) — eMMC
# 对应官方 BoardConfig-EMMC-Buildroot-RV1106_Luckfox_Pico_Ultra-IPC.mk
VENDOR := pico
CHIP := rv1106
STORAGE := emmc

# 官方 uclibc 工具链(gcc 8.3,烘焙在 docker 镜像 /opt/toolchains 下)
TOOLCHAIN := rockchip830

# U-Boot(官方 defconfig + eMMC iomux + RGB 复位引脚 fragment)
UBOOT_CFG := luckfox_rv1106_uboot_defconfig
UBOOT_FRAGMENTS := rk-emmc.config rv1106-luckfox-rgb-reset.config
UBOOT_ARCH := arm
UBOOT_SPL := y

# Kernel
KERNEL_ARCH := arm
KERNEL_CFG := luckfox_rv1106_linux_defconfig
KERNEL_DTS := rv1106g-luckfox-pico-ultra

# Buildroot rootfs(精简核心,ext4)
BUILDROOT_CFG := luckfox_pico_ext4
ROOTFS_TYPE := ext4
ROOTFS_SIZE := 6G

# 启动介质与分区布局 —— 与官方 RK_PARTITION_CMD_IN_ENV 完全一致,由
# 40-firmware stage 写进 env.img(SPL 从这里读分区表 + sys_bootargs)
BOOT_MEDIUM := emmc
PART_CMD := 32K(env),512K@32K(idblock),256K(uboot),32M(boot),512M(oem),256M(userdata),6G(rootfs)
ROOTFS_ARGS := root=/dev/mmcblk0p7 rootfstype=ext4
CMA_SIZE := 66M
ENV_SIZE := 32K
DATA_FS_TYPE := ext4

# update.img 打包(rkImageMaker 的芯片标记)
RK_TAG := RK1106
REQUIRED := download.bin idblock.img env.img uboot.img boot.img oem.img userdata.img rootfs.img update.img
