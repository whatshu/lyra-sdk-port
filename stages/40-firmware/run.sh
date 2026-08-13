#!/usr/bin/env bash
# Stage: firmware
#
# Collects the stage outputs into a coherent firmware set and packs the
# all-in-one update.img.  Multiple artefacts are produced so the same
# build can be flashed with the loader tool, written to an SD card or
# upgraded over USB.
set -euo pipefail

FW="$FW_DIR"
mkdir -p "$FW"

# --- parameter / partition table -------------------------------------------
PARAM_SRC="$SDK_ROOT/config/image/$PARAMETER"
[ -f "$PARAM_SRC" ] || { echo "ERROR: parameter file $PARAM_SRC missing" >&2; exit 1; }
cp -f "$PARAM_SRC" "$FW/parameter.txt"

# --- required pieces --------------------------------------------------------
for f in MiniLoaderAll.bin uboot.img boot.img rootfs.img parameter.txt; do
    [ -f "$FW/$f" ] || { echo "ERROR: missing firmware piece: $f" >&2; exit 1; }
done

# --- all-in-one update.img ----------------------------------------------------
if [ -x "$SDK_ROOT/tools/host/rk/afptool" ] && \
   [ -x "$SDK_ROOT/tools/host/rk/rkImageMaker" ]; then
    msg() { echo ">>> firmware: $*"; }
    msg "packing update.img"
    PKG="$OUT_DIR/updatepkg"
    rm -rf "$PKG"; mkdir -p "$PKG/Image"
    cp -f "$FW/MiniLoaderAll.bin" "$PKG/Image/"
    cp -f "$FW/parameter.txt"     "$PKG/Image/parameter.txt"
    cp -f "$FW/uboot.img"         "$PKG/Image/"
    cp -f "$FW/boot.img"          "$PKG/Image/"
    cp -f "$FW/rootfs.img"        "$PKG/Image/"
    cp -f "$FW/resource.img"      "$PKG/Image/" 2>/dev/null || true

    # package-file: which partitions go into update.img
    cat > "$PKG/package-file" <<EOF
# NAME			Relative path
package-file	package-file
bootloader	Image/MiniLoaderAll.bin
parameter	Image/parameter.txt
uboot		Image/uboot.img
boot		Image/boot.img
rootfs		Image/rootfs.img
EOF
    # The rkImageMaker tag (e.g. RK3506) is embedded in the loader header.
    TAG="RK$(dd if="$FW/MiniLoaderAll.bin" bs=1 skip=21 count=4 2>/dev/null | rev)"
    ( cd "$PKG" && "$SDK_ROOT/tools/host/rk/afptool" -pack ./ update.raw.img && \
      "$SDK_ROOT/tools/host/rk/rkImageMaker" "-$TAG" \
        Image/MiniLoaderAll.bin update.raw.img "$FW/update.img" -os_type:androidos )

    # xz-compress update.img (parallel) so the same build is cheap to
    # archive/transfer; make release does the same for its snapshot.
    msg "compressing update.img"
    xz -T0 -6 -k -c "$FW/update.img" > "$FW/update.img.xz"
else
    echo "WARNING: afptool/rkImageMaker missing; skipping update.img"
fi

# --- manifest of what we produced --------------------------------------------
echo "firmware stage done:"
ls -lh "$FW"
