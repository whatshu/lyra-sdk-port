#!/usr/bin/env bash
# Stage: uboot
#
# Builds U-Boot for the rk3506 with the Rockchip make.sh flow.
# On a FULL build the centralised defconfig/fragments are (re)applied and
# .config is regenerated.  On a partial build the existing .config is
# reused so hand-tuned changes survive.
set -euo pipefail

cd "$VENDOR_DIR/u-boot"

MAKE_ARGS=(CROSS_COMPILE="$TOOLCHAIN_PREFIX")
if [ "$FULL" = "1" ] || [ ! -f .config ]; then
    MAKE_ARGS+=( "$UBOOT_CFG" )
    for f in $UBOOT_FRAGMENTS; do
        MAKE_ARGS+=( "$f" )
    done
fi
MAKE_ARGS+=( --spl-new )

# RKBIN is resolved by make.sh relative to the u-boot tree; the rkbin
# submodule is its sibling under vendor/rockchip/.
./make.sh "${MAKE_ARGS[@]}"

# Collect the packed artifacts into the firmware staging dir.
mkdir -p "$FW_DIR"
LOADER=$(ls -t ./*_loader_*.bin 2>/dev/null | head -1 || true)
[ -n "$LOADER" ] || { echo "ERROR: no *_loader_*.bin produced" >&2; exit 1; }
cp -f "$LOADER" "$FW_DIR/MiniLoaderAll.bin"
cp -f uboot.img "$FW_DIR/uboot.img"
[ ! -f trust.img ] || cp -f trust.img "$FW_DIR/trust.img"
[ ! -f ./*_idblock_*.img ] || cp -f ./*_idblock_*.img "$FW_DIR/"

echo "uboot stage done:"
ls -l "$FW_DIR"
