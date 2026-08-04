# Board: Luckfox Lyra (RK3506G) — SPI NAND
# Storage: spinand
BOARD := lyra
CHIP := rk3506
CHIP_VARIANT := rk3506
STORAGE := spinand

# U-Boot
UBOOT_CFG := rk3506_luckfox
UBOOT_FRAGMENTS :=
UBOOT_ARCH := arm
UBOOT_SPL := y

# Kernel
KERNEL_ARCH := arm
KERNEL_CFG := rk3506_luckfox_defconfig
KERNEL_FRAGMENTS := rk3506-display.config
KERNEL_DTS := rk3506g-luckfox-lyra

# Buildroot rootfs
BUILDROOT_CFG := rockchip_rk3506_luckfox
ROOTFS_TYPE := ubi

# Image assembly
BOOT_COMPRESSED := y
PARAMETER := parameter-lyra-spinand.txt
