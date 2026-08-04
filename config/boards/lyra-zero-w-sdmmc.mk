# Board: Luckfox Lyra Zero W (RK3506B) — SD card
# Storage: sdmmc
BOARD := lyra-zero-w
CHIP := rk3506
CHIP_VARIANT := rk3506b
STORAGE := sdmmc

# U-Boot
UBOOT_CFG := rk3506_luckfox
UBOOT_FRAGMENTS := rk3506b_luckfox
UBOOT_ARCH := arm
UBOOT_SPL := y

# Kernel
KERNEL_ARCH := arm
KERNEL_CFG := rk3506_luckfox_defconfig
KERNEL_FRAGMENTS := rk3506-display.config
KERNEL_DTS := rk3506b-luckfox-lyra-zero-w-sd

# Buildroot rootfs
BUILDROOT_CFG := rockchip_rk3506_luckfox
ROOTFS_TYPE := ext4

# Image assembly
BOOT_COMPRESSED := y
PARAMETER := parameter-lyra-sdmmc.txt

# Wi-Fi / BT
WIFIBT := AIC8800DC
