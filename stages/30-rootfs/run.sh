#!/usr/bin/env bash
# Stage: rootfs
#
# Builds the root filesystem with buildroot.  The buildroot defconfig
# carries the SDK's own post-build hook (board/rockchip/common/post-build.sh)
# which applies the device/rockchip shim + product rootfs overlay, so the
# kernel modules and our customisations end up inside the image.
#
# On a FULL build the defconfig is regenerated; on a partial build the
# existing buildroot .config is reused to preserve menuconfig edits.
set -euo pipefail

cd "$VENDOR_DIR/buildroot"
BR_OUT="output/$BUILDROOT_CFG"

# Centralised/custom buildroot defconfig override.
if [ "$FULL" = "1" ]; then
    for d in "$SDK_ROOT/product/platform/configs/buildroot" \
             "$SDK_ROOT/product/custom/buildroot"; do
        [ -d "$d" ] || continue
        for f in "$d"/*_defconfig; do
            [ -e "$f" ] || continue
            base="$(basename "$f")"
            if [ "$base" = "${BUILDROOT_CFG}_defconfig" ]; then
                cp -f "$f" configs/"$base"
            fi
        done
    done
fi

if [ "$FULL" = "1" ] || [ ! -f "$BR_OUT/.config" ]; then
    make O="$BR_OUT" "${BUILDROOT_CFG}_defconfig"
fi

# BR2_DL_DIR stays at the vendor buildroot/dl (persistent cache).
make O="$BR_OUT" -j"$NPROC"

# Collect the rootfs image.
mkdir -p "$FW_DIR"
case "$ROOTFS_TYPE" in
    ubi|ubifs)  IMG="rootfs.ubi" ;;
    squashfs)   IMG="rootfs.squashfs" ;;
    *)          IMG="rootfs.ext4" ;;
esac
[ -f "$BR_OUT/images/$IMG" ] || { echo "ERROR: $IMG not produced" >&2; exit 1; }
cp -f "$BR_OUT/images/$IMG" "$FW_DIR/rootfs.img"

echo "rootfs stage done:"
ls -lh "$FW_DIR/rootfs.img"
