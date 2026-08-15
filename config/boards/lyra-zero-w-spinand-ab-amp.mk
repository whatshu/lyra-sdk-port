# Board: Luckfox Lyra Zero W (RK3506B) — SPI NAND with A/B boot + AMP + TF data
# Storage: spinand (256 MB onboard W25N02KV) + external TF card as data
#
# The zero-w spinand board + u-boot's native A/B slot boot on NAND (single
# `uboot` slot; A/B over boot_a/b + system_a/b on UBI, volume named `system`)
# + full AMP (cpu2 = RT-Thread, M0 = HAL bare-metal) + the Linux<->M0 rpmsg
# ping-pong.  The TF card is data-only (a `userdata` ext4 partition mounted at
# /userdata); it is deliberately non-bootable, so u-boot falls back to NAND.
# See doc/ab-boot-nand.md + doc/amp.md.
BOARD := lyra-zero-w
CHIP := rk3506
CHIP_VARIANT := rk3506b
STORAGE := spinand

# U-Boot (rk3506b_luckfox_ab_amp = ANDROID_AB + AVB libs + AMP)
UBOOT_CFG := rk3506_luckfox
UBOOT_FRAGMENTS := rk3506b_luckfox_ab_amp
UBOOT_ARCH := arm
UBOOT_SPL := y

# Kernel (A/B dts drops the fixed root= / ubi.mtd=; AMP dtsi + rpmsg/mailbox)
KERNEL_ARCH := arm
KERNEL_CFG := rk3506_luckfox_defconfig
KERNEL_FRAGMENTS := rk3506-display.config rockchip_amp.config
KERNEL_DTS := rk3506b-luckfox-lyra-zero-w-ab-amp

# Buildroot rootfs (slim core; UBI volume named `system`; e2fsprogs formats
# the TF-card userdata on first boot)
BUILDROOT_CFG := rockchip_rk3506_luckfox_ab_amp
ROOTFS_TYPE := ubi

# Image assembly (NAND A/B partition table)
BOOT_COMPRESSED := y
PARAMETER := parameter-lyra-spinand-ab-amp.txt

# A/B boot: single `uboot` slot, boot_a/b + system_a/b, misc + amp partitions
AB := 1

# AMP: the firmware stage builds RT-Thread (cpu2) + the M0 responder and
# assembles amp.img into the `amp` partition; u-boot releases both cores.
AMP := 1

# Wi-Fi / BT
WIFIBT := AIC8800DC
