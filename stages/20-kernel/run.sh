#!/usr/bin/env bash
# Stage: kernel
#
# Builds the Linux kernel (zImage + dtb + modules) and the boot image
# (boot.img / zboot.img) using the rockchip `make <dts>.img` target.
# rkbin/tools provides the prebuilt `mkimage` host tool.
set -euo pipefail

cd "$VENDOR_DIR/kernel"

# Boards may not carry kernel config fragments (pico boards don't); the
# vendor trees for pico live OUTSIDE the bind-mounted /sdk (symlinked
# mirrors), so tell git it may run there (setlocalversion etc.).
KERNEL_FRAGMENTS="${KERNEL_FRAGMENTS:-}"
BOOT_COMPRESSED="${BOOT_COMPRESSED:-}"
if [ "${VENDOR:-rockchip}" = "pico" ]; then
    git config --global --add safe.directory "$(readlink -f "$VENDOR_DIR/kernel")" \
        2>/dev/null || true
fi

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

# Regenerate .config on a full build (or first partial build).  The pico
# kernel flow (official sysdrv) starts from `make mrproper` so no stale
# in-tree objects survive a config change; the lyra tree is also built
# in-tree but its configs are stable per board, so it keeps the plain
# defconfig regen.
if [ "${VENDOR:-rockchip}" = "pico" ]; then
    if [ "$FULL" = "1" ]; then
        make ARCH="$KERNEL_ARCH" mrproper
    fi
    if [ "$FULL" = "1" ] || [ ! -f .config ]; then
        "${KMAKE[@]}" "$KERNEL_CFG" $KERNEL_FRAGMENTS
    fi
    # FIT boot image: scripts/mkimg builds boot.img from the kernel + dts
    # using the vendored boot.its (official flow passes BOOT_ITS explicitly).
    "${KMAKE[@]}" BOOT_ITS="$VENDOR_DIR/kernel/boot.its" "$KERNEL_DTS.img"
else
    if [ "$FULL" = "1" ] || [ ! -f .config ]; then
        "${KMAKE[@]}" "$KERNEL_CFG" $KERNEL_FRAGMENTS
    fi
    "${KMAKE[@]}" "$KERNEL_DTS.img"
fi

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
