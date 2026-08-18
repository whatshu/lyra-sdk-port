#!/usr/bin/env bash
# post-rootfs.sh <target-dir> <sdk-root>
#
# Runs on the buildroot rootfs target just before the image is created
# (invoked through the device/rockchip/common/post-build.sh shim).
#
# It is the central place that turns the vanilla buildroot rootfs into a
# Luckfox-compatible system: base directories, /etc/fstab, os-release,
# kernel modules and the product overlays.  All inputs come from
# product/platform/rootfs/ and product/custom/, never from the vendored
# trees.
set -euo pipefail

TARGET_DIR="$1"
SDK_ROOT="$2"
# VENDOR_DIR (the active vendor tree) comes from the stage environment; the
# board's VENDOR name (rockchip|pico) selects per-family rootfs tweaks.
VENDOR_DIR="${VENDOR_DIR:-$SDK_ROOT/vendor/rockchip}"
VENDOR_NAME="${VENDOR:-rockchip}"
PLATFORM="$SDK_ROOT/product/platform/rootfs"
CUSTOM="$SDK_ROOT/product/custom/rootfs"

ARCH="${KERNEL_ARCH:-arm}"
CROSS="${CROSS_COMPILE:-${TOOLCHAIN_PREFIX:-arm-none-linux-gnueabihf-}}"

msg() { echo ">>> post-rootfs: $*"; }

mkdir -p "$TARGET_DIR"

# ---------------------------------------------------------------------------
# 1. Base directories and convenience symlinks (mirrors post-dirs.sh)
# ---------------------------------------------------------------------------
msg "creating base directories and symlinks"
rm -rf "$TARGET_DIR/mnt/udisk" "$TARGET_DIR/mnt/sdcard" \
    "$TARGET_DIR/mnt/usb_storage" "$TARGET_DIR/mnt/external_sd" \
    "$TARGET_DIR/udisk" "$TARGET_DIR/sdcard" "$TARGET_DIR/data"
mkdir -p "$TARGET_DIR/mnt/sdcard" "$TARGET_DIR/mnt/udisk" "$TARGET_DIR/userdata"
ln -sf udisk       "$TARGET_DIR/mnt/usb_storage"
ln -sf sdcard      "$TARGET_DIR/mnt/external_sd"
ln -sf mnt/udisk   "$TARGET_DIR/udisk"
ln -sf mnt/sdcard  "$TARGET_DIR/sdcard"
ln -sf userdata    "$TARGET_DIR/data"

# ---------------------------------------------------------------------------
# 2. /etc/fstab (mirrors post-fstab.sh essentials)
# ---------------------------------------------------------------------------
msg "fixing /etc/fstab"
mkdir -p "$TARGET_DIR/etc"
FSTAB="$TARGET_DIR/etc/fstab"
touch "$FSTAB"

ROOT_TYPE="${ROOTFS_TYPE:-ext4}"
case "$ROOT_TYPE" in
    ext[234]) ;;
    *) ROOT_TYPE=auto ;;
esac
sed -i "s~\([[:space:]]/[[:space:]]\+\)\w\+~\1${ROOT_TYPE}~" "$FSTAB" || true

# buildroot provides the base entries; make sure the essential fses exist.
add_fs() { # src mnt fstype opts
    grep -qE "[[:space:]]$2([[:space:]]|$)" "$FSTAB" && return 0
    printf '%s\t%s\t%s\t%s\t0 0\n' "$1" "$2" "$3" "${4:-defaults}" >> "$FSTAB"
    mkdir -p "$TARGET_DIR$2"
}
add_fs proc      /proc           proc      nosuid,nodev,noexec
add_fs devtmpfs  /dev            devtmpfs  mode=0755
add_fs devpts    /dev/pts        devpts    mode=0620,ptmxmode=0000,gid=5
add_fs tmpfs     /dev/shm        tmpfs     nosuid,nodev,noexec
add_fs sysfs     /sys            sysfs     nosuid,nodev,noexec
add_fs configfs  /sys/kernel/config configfs
add_fs debugfs   /sys/kernel/debug   debugfs
add_fs pstore    /sys/fs/pstore  pstore    nosuid,nodev,noexec

# ---------------------------------------------------------------------------
# 3. /etc/os-release (mirrors post-os-release.sh)
# ---------------------------------------------------------------------------
msg "annotating /etc/os-release"
OS="$TARGET_DIR/etc/os-release"
touch "$OS"
sed -i "/^RK_BUILD_INFO=/d" "$OS"
echo "RK_BUILD_INFO=\"shu-sdk $(date +%F_%T) - ${BUILDROOT_CFG:-buildroot}\"" >> "$OS"

# ---------------------------------------------------------------------------
# 4. Kernel modules (mirrors post-modules.sh)
# ---------------------------------------------------------------------------
if [ -d "$VENDOR_DIR/kernel" ] && [ -f "$VENDOR_DIR/kernel/.config" ]; then
    msg "installing kernel modules"
    make -C "$VENDOR_DIR/kernel" \
        ARCH="$ARCH" CROSS_COMPILE="$CROSS" \
        INSTALL_MOD_PATH="$TARGET_DIR" modules_install 2>/dev/null \
        || msg "warning: kernel modules install failed (built kernel first?)"
fi

# ---------------------------------------------------------------------------
# 5. Product overlays (platform + custom) — the central customisation point.
# A per-board overlay ($PLATFORM/overlay-$TARGET, e.g.
# overlay-lyra-ultra-w-emmc-pico2) is merged in too, so a board can carry
# its own rootfs customisations without affecting the other boards.
# ---------------------------------------------------------------------------
for ov in "$PLATFORM/overlay" "$PLATFORM/overlay-$TARGET" "$CUSTOM/overlay"; do
    [ -d "$ov" ] || continue
    msg "applying overlay $ov"
    rsync -a --chmod=u=rwX,go=rX --exclude .empty "$ov/" "$TARGET_DIR/"
done

# ---------------------------------------------------------------------------
# 6. pico (RV1106/RV1103) specifics: nothing to fix here — the official
# images keep the default buildroot `console` getty (the kernel's
# CONFIG_FIQ_DEBUGGER_CONSOLE_DEFAULT_ENABLE makes /dev/console the
# fiq-debugger at 1500000 baud, so the login prompt follows the hardware
# automatically).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 7. Dynamic linker cache (mirrors post-ldcache.sh)
# ---------------------------------------------------------------------------
if [ -f "$TARGET_DIR/etc/ld.so.conf" ] && \
   ! [ -f "$TARGET_DIR/etc/ld.so.cache" ]; then
    if command -v ldconfig >/dev/null 2>&1; then
        msg "generating /etc/ld.so.cache"
        ldconfig -r "$TARGET_DIR" 2>/dev/null || true
    fi
fi

# ---------------------------------------------------------------------------
# 8. Publish the (modified) target for the RK image step.
# The Rockchip buildroot generates rootfs images from
# $(TOPDIR)/../output/buildroot/target, i.e. vendor/<name>/output/buildroot
# (a link to out/), so copy the post-processed target there.
# ---------------------------------------------------------------------------
EXTRA_TARGET_DIR="$VENDOR_DIR/output/buildroot/target"
msg "publishing target to $EXTRA_TARGET_DIR"
rm -rf "$EXTRA_TARGET_DIR"
mkdir -p "$(dirname "$EXTRA_TARGET_DIR")"
cp -a "$TARGET_DIR" "$EXTRA_TARGET_DIR"

msg "done"
