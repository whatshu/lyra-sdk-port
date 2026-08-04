#!/usr/bin/env bash
# Stage: kernel
#
# Builds the Linux kernel (zImage + dtb + modules) and the boot image
# (boot.img / zboot.img) using the rockchip `make <dts>.img` target.
# rkbin/tools provides the prebuilt `mkimage` host tool.
set -euo pipefail

cd "$VENDOR_DIR/kernel"

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
