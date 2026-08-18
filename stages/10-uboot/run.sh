#!/usr/bin/env bash
# Stage: uboot
#
# Builds U-Boot with the Rockchip make.sh flow.
#   - lyra (RK3506): MiniLoaderAll.bin + uboot.img (+ trust.img / idblock)
#   - pico (RV1106/RV1103): download.bin + idblock.img + uboot.img
#     (no MiniLoaderAll.bin — the loader is the download.bin mini-loader)
# On a FULL build the centralised defconfig/fragments are (re)applied and
# .config is regenerated.  On a partial build the existing .config is
# reused so hand-tuned changes survive.
set -euo pipefail

cd "$VENDOR_DIR/u-boot"

# RKBIN is resolved by make.sh relative to the u-boot tree; the rkbin
# tree is its sibling under vendor/<name>/.
if [ "${VENDOR:-rockchip}" = "pico" ]; then
    # pico flow (mirrors the official sysdrv uboot target exactly): plain
    # `make <defconfig> <fragments>` generates .config, then make.sh is
    # called WITHOUT a board name (it would append _defconfig itself and
    # fail on the full name) — --spl-new builds the SPL idblock.
    if [ "$FULL" = "1" ] || [ ! -f .config ]; then
        make CROSS_COMPILE="$TOOLCHAIN_PREFIX" "$UBOOT_CFG" $UBOOT_FRAGMENTS
    fi
    ./make.sh CROSS_COMPILE="$TOOLCHAIN_PREFIX" --spl-new
else
    MAKE_ARGS=(CROSS_COMPILE="$TOOLCHAIN_PREFIX")
    if [ "$FULL" = "1" ] || [ ! -f .config ]; then
        MAKE_ARGS+=( "$UBOOT_CFG" )
        for f in $UBOOT_FRAGMENTS; do
            MAKE_ARGS+=( "$f" )
        done
    fi
    MAKE_ARGS+=( --spl-new )
    ./make.sh "${MAKE_ARGS[@]}"
fi

# Collect the packed artifacts into the firmware staging dir.
mkdir -p "$FW_DIR"
if [ "${VENDOR:-rockchip}" = "pico" ]; then
    # pico flow (mirrors the official sysdrv/Makefile uboot target): the
    # loader produced by the idblock build is the download.bin mini-loader;
    # the idblock image itself is the SPL + u-boot blob.
    DL=$(ls -t ./*_download_v*.bin 2>/dev/null | head -1 || true)
    [ -n "$DL" ] || { echo "ERROR: no *_download_v*.bin produced" >&2; exit 1; }
    IDB=$(ls -t ./*_idblock_v*.img 2>/dev/null | head -1 || true)
    [ -n "$IDB" ] || { echo "ERROR: no *_idblock_v*.img produced" >&2; exit 1; }
    cp -f "$DL"  "$FW_DIR/download.bin"
    cp -f "$IDB" "$FW_DIR/idblock.img"
else
    LOADER=$(ls -t ./*_loader_*.bin 2>/dev/null | head -1 || true)
    [ -n "$LOADER" ] || { echo "ERROR: no *_loader_*.bin produced" >&2; exit 1; }
    cp -f "$LOADER" "$FW_DIR/MiniLoaderAll.bin"
    [ ! -f ./*_idblock_*.img ] || cp -f ./*_idblock_*.img "$FW_DIR/"
fi
cp -f uboot.img "$FW_DIR/uboot.img"
[ ! -f trust.img ] || cp -f trust.img "$FW_DIR/trust.img"

echo "uboot stage done:"
ls -l "$FW_DIR"
