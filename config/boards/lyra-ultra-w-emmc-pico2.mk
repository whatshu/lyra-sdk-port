# Board: Luckfox Lyra Ultra W (RK3506B) — eMMC, Pico 2 (RP2350) debug variant
# Fork of the default lyra-ultra-w-emmc config; adds a bit-banged SWD
# debugger + SPI1 host for an external Raspberry Pi Pico 2 (see doc/pico2.md).
# Only the DTS and the buildroot defconfig differ from the default board.
# Storage: emmc
BOARD := lyra-ultra-w
CHIP := rk3506
CHIP_VARIANT := rk3506b
STORAGE := emmc

# U-Boot
UBOOT_CFG := rk3506_luckfox
UBOOT_FRAGMENTS := rk3506b_luckfox
UBOOT_ARCH := arm
UBOOT_SPL := y

# Kernel
KERNEL_ARCH := arm
KERNEL_CFG := rk3506_luckfox_defconfig
KERNEL_FRAGMENTS := rk3506-display.config
KERNEL_DTS := rk3506b-luckfox-lyra-ultra-w-pico2

# Buildroot rootfs
BUILDROOT_CFG := rockchip_rk3506_luckfox_pico2
ROOTFS_TYPE := ext4

# Image assembly
BOOT_COMPRESSED := y
PARAMETER := parameter-lyra-emmc.txt

# Wi-Fi / BT
WIFIBT := AIC8800DC
