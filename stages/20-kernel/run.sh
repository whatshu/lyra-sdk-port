#!/usr/bin/env bash
# Stage: kernel
#
# Builds the Linux kernel (zImage + dtb + modules) and the boot image
# (boot.img / zboot.img) using the rockchip `make <dts>.img` target.
# rkbin/tools provides the prebuilt `mkimage` host tool.
set -euo pipefail

cd "$VENDOR_DIR/kernel"

# Centralised board-DTS override: on a FULL build a file at
# product/platform/dts/$KERNEL_DTS.dts replaces the vendored board dts
# (mirrors the config-override behaviour of the other stages).
if [ "$FULL" = "1" ]; then
    for d in "$SDK_ROOT/product/platform/dts" "$SDK_ROOT/product/custom/dts"; do
        [ -d "$d" ] || continue
        if [ -f "$d/$KERNEL_DTS.dts" ]; then
            cp -f "$d/$KERNEL_DTS.dts" "arch/arm/boot/dts/$KERNEL_DTS.dts"
            echo "kernel: using overridden dts $d/$KERNEL_DTS.dts"
        fi
    done
fi

# mkimage is needed by scripts/mkimg for the boot image.
export PATH="$VENDOR_DIR/rkbin/tools:$PATH"

KMAKE=(make ARCH="$KERNEL_ARCH" CROSS_COMPILE="$TOOLCHAIN_PREFIX" -j"$NPROC")

# Regenerate .config on a full build (or first partial build).
if [ "$FULL" = "1" ] || [ ! -f .config ]; then
    "${KMAKE[@]}" "$KERNEL_CFG" $KERNEL_FRAGMENTS
fi

"${KMAKE[@]}" "$KERNEL_DTS.img"

# Kernel modules are installed into the rootfs by the buildroot
# post-build stage; build them here so they are ready.
"${KMAKE[@]}" modules

mkdir -p "$FW_DIR"
if [ "$BOOT_COMPRESSED" = "y" ] && [ -f zboot.img ]; then
    cp -f zboot.img "$FW_DIR/boot.img"
else
    cp -f boot.img "$FW_DIR/boot.img"
fi
[ ! -f resource.img ] || cp -f resource.img "$FW_DIR/resource.img"

echo "kernel stage done:"
ls -l "$FW_DIR"
