# Board: Luckfox Lyra (RK3506G) — SD card
# Storage: sdmmc
BOARD := lyra
CHIP := rk3506
CHIP_VARIANT := rk3506
STORAGE := sdmmc

# U-Boot
UBOOT_CFG := rk3506_luckfox
UBOOT_FRAGMENTS :=
UBOOT_ARCH := arm
UBOOT_SPL := y

# Kernel
KERNEL_ARCH := arm
KERNEL_CFG := rk3506_luckfox_defconfig
KERNEL_FRAGMENTS := rk3506-display.config
KERNEL_DTS := rk3506g-luckfox-lyra-sd

# Buildroot rootfs
BUILDROOT_CFG := rockchip_rk3506_luckfox
ROOTFS_TYPE := ext4

# Image assembly
BOOT_COMPRESSED := y
PARAMETER := parameter-lyra-sdmmc.txt
# extra partition for boot partition on sdmmc (1GB)
EXTRA_PART :=
