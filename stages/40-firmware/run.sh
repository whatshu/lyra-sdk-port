#!/usr/bin/env bash
# Stage: firmware
#
# Collects the stage outputs into a coherent firmware set and packs the
# all-in-one update.img.  Multiple artefacts are produced so the same
# build can be flashed with the loader tool, written to an SD card or
# upgraded over USB.
#
# A/B boards (AB=1, see the lyra-ultra-w-emmc-ab board): the single-slot
# images are duplicated into uboot_a/b, boot_a/b and system_a/b, a misc.img
# carrying the initial AvbABData is generated, and the update.img lists all
# slot partitions.  See doc/ab-boot.md.
set -euo pipefail

FW="$FW_DIR"
mkdir -p "$FW"

msg() { echo ">>> firmware: $*"; }

# --- parameter / partition table -------------------------------------------
PARAM_SRC="$SDK_ROOT/config/image/$PARAMETER"
[ -f "$PARAM_SRC" ] || { echo "ERROR: parameter file $PARAM_SRC missing" >&2; exit 1; }
cp -f "$PARAM_SRC" "$FW/parameter.txt"

# --- required pieces --------------------------------------------------------
for f in MiniLoaderAll.bin uboot.img boot.img rootfs.img parameter.txt; do
    [ -f "$FW/$f" ] || { echo "ERROR: missing firmware piece: $f" >&2; exit 1; }
done

# --- A/B slot copies ---------------------------------------------------------
if [ "${AB:-0}" = "1" ]; then
    msg "A/B layout: duplicating images into slot copies"
    for s in a b; do
        cp -f "$FW/uboot.img"  "$FW/uboot_${s}.img"
        cp -f "$FW/boot.img"   "$FW/boot_${s}.img"
        cp -f "$FW/rootfs.img" "$FW/system_${s}.img"
    done
    msg "generating misc.img (initial AvbABData)"
    python3 "$SDK_ROOT/tools/scripts/mkabmeta.py" -o "$FW/misc.img"
fi

# --- all-in-one update.img ----------------------------------------------------
if [ -x "$SDK_ROOT/tools/host/rk/afptool" ] && \
   [ -x "$SDK_ROOT/tools/host/rk/rkImageMaker" ]; then
    msg "packing update.img"
    PKG="$OUT_DIR/updatepkg"
    rm -rf "$PKG"; mkdir -p "$PKG/Image"
    cp -f "$FW/MiniLoaderAll.bin" "$PKG/Image/"
    cp -f "$FW/parameter.txt"     "$PKG/Image/parameter.txt"
    cp -f "$FW/resource.img"      "$PKG/Image/" 2>/dev/null || true

    if [ "${AB:-0}" = "1" ]; then
        # A/B update.img carries every slot partition plus the misc metadata.
        for f in uboot_a uboot_b misc boot_a boot_b system_a system_b; do
            cp -f "$FW/$f.img" "$PKG/Image/"
        done
        # package-file: which partitions go into update.img
        cat > "$PKG/package-file" <<EOF
# NAME			Relative path
package-file	package-file
bootloader	Image/MiniLoaderAll.bin
parameter	Image/parameter.txt
uboot_a		Image/uboot_a.img
uboot_b		Image/uboot_b.img
misc		Image/misc.img
boot_a		Image/boot_a.img
boot_b		Image/boot_b.img
system_a	Image/system_a.img
system_b	Image/system_b.img
EOF
    else
        cp -f "$FW/uboot.img"  "$PKG/Image/"
        cp -f "$FW/boot.img"   "$PKG/Image/"
        cp -f "$FW/rootfs.img" "$PKG/Image/"
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
    fi
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
