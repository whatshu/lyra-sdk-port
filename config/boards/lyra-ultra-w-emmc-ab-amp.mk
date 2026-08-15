# Board: Luckfox Lyra Ultra W (RK3506B) — eMMC, A/B boot + AMP (verification bed)
# Storage: emmc
# The emmc-ab board plus u-boot AMP loading (CONFIG_AMP): the firmware stage
# assembles amp.img (RT-Thread on cpu2 + M0 HAL) into the `amp` partition and
# u-boot releases both cores at boot.  This is the on-hardware verification
# bed for everything AMP/M0/ping-pong (the SoC is shared with the Zero W); the
# rootfs is the same A/B ext4 build as the shipping emmc-ab board.
# See doc/ab-boot.md + doc/amp.md.
BOARD := lyra-ultra-w
CHIP := rk3506
CHIP_VARIANT := rk3506b
STORAGE := emmc

# U-Boot (combined AB+AMP fragment: ANDROID_AB + AVB libs + AMP)
UBOOT_CFG := rk3506_luckfox
UBOOT_FRAGMENTS := rk3506b_luckfox_ab_amp
UBOOT_ARCH := arm
UBOOT_SPL := y

# Kernel (A/B dts + AMP dtsi, rpmsg/mailbox fragment)
KERNEL_ARCH := arm
KERNEL_CFG := rk3506_luckfox_defconfig
KERNEL_FRAGMENTS := rk3506-display.config rockchip_amp.config
KERNEL_DTS := rk3506b-luckfox-lyra-ultra-w-ab-amp

# Buildroot rootfs (the emmc-ab A/B ext4 rootfs; userdata auto-format via
# e2fsprogs)
BUILDROOT_CFG := rockchip_rk3506_luckfox_ab
ROOTFS_TYPE := ext4

# Image assembly (A/B partition table with uboot_a/b, misc, boot_a/b, amp,
# system_a/b, userdata)
BOOT_COMPRESSED := y
PARAMETER := parameter-lyra-emmc-ab-amp.txt

# A/B boot: the firmware stage duplicates slot images, builds misc.img
# (AvbABData) and packs a 9-partition update.img
AB := 1

# AMP: the firmware stage builds RT-Thread (cpu2) + the M0 responder and
# assembles amp.img into the `amp` partition; u-boot releases both cores.
AMP := 1

# Wi-Fi / BT
WIFIBT := AIC8800DC
