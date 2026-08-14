# Board: Luckfox Lyra Ultra W (RK3506B) — eMMC with A/B (dual-slot) boot
# Storage: emmc
# This is the default emmc board + u-boot's native A/B slot boot (CONFIG_ANDROID_AB)
# so firmware can be upgraded in place and roll back on a failed boot.
# See doc/ab-boot.md for the boot flow and the upgrade/rollback policy.
BOARD := lyra-ultra-w
CHIP := rk3506
CHIP_VARIANT := rk3506b
STORAGE := emmc

# U-Boot (rk3506b_luckfox_ab fragment adds CONFIG_ANDROID_AB + AVB libs)
UBOOT_CFG := rk3506_luckfox
UBOOT_FRAGMENTS := rk3506b_luckfox_ab
UBOOT_ARCH := arm
UBOOT_SPL := y

# Kernel (A/B dts drops the fixed root= ; u-boot injects root=PARTUUID)
KERNEL_ARCH := arm
KERNEL_CFG := rk3506_luckfox_defconfig
KERNEL_FRAGMENTS := rk3506-display.config
KERNEL_DTS := rk3506b-luckfox-lyra-ultra-w-ab

# Buildroot rootfs (fork; userdata auto-formatting via e2fsprogs)
BUILDROOT_CFG := rockchip_rk3506_luckfox_ab
ROOTFS_TYPE := ext4

# Image assembly (A/B partition table with uboot_a/b, misc, boot_a/b,
# system_a/b, userdata)
BOOT_COMPRESSED := y
PARAMETER := parameter-lyra-emmc-ab.txt

# A/B boot: the firmware stage duplicates slot images, builds misc.img
# (AvbABData) and packs an 8-partition update.img
AB := 1

# Wi-Fi / BT
WIFIBT := AIC8800DC
