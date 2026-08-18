#!/usr/bin/env bash
# Stage: rootfs
#
# Builds the root filesystem with buildroot.  The buildroot defconfig
# carries the SDK's own post-build hook (board/rockchip/common/post-build.sh
# for lyra, board/luckfox/common/post-build.sh for pico) which applies the
# device/rockchip shim + product rootfs overlay, so the kernel modules and
# our customisations end up inside the image.
#
# On a FULL build the defconfig is regenerated; on a partial build the
# existing buildroot .config is reused to preserve menuconfig edits.
#
# pico (VENDOR=pico): mirrors the official flow — buildroot only produces
# the target dir (no fs image); rootfs.img is generated here from the
# post-processed target with mkfs.ext4 / mkfs.ubifs+ubinize, exactly like
# the official mkfs_ext4.sh / mkfs_ubi.sh tools.
set -euo pipefail

cd "$VENDOR_DIR/buildroot"
# Buildroot output lives in the volatile project build tree (out/), NOT in
# the vendored buildroot, so component rebuilds never dirty the submodule
# and `make clean` drops it.  The package source cache (BR2_DL_DIR) is the
# only persistent buildroot state.
BR_OUT="$OUT_DIR/buildroot-$BUILDROOT_CFG"

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

    # pico boards use the uclibc toolchain baked at a fixed path in the
    # container; rewrite the defconfig's external-toolchain path so it
    # resolves even when SDK_TOOLCHAIN points elsewhere.
    if [ "${VENDOR:-rockchip}" = "pico" ]; then
        sed -i "s|^BR2_TOOLCHAIN_EXTERNAL_PATH=.*|BR2_TOOLCHAIN_EXTERNAL_PATH=\"${TC_ROCKCHIP830}\"|" \
            "configs/${BUILDROOT_CFG}_defconfig"
    fi

    # A/B boards use a custom ubinize config (UBI volume named `system`, which
    # u-boot's ab_update_root_partition() looks up as root=ubi0:system).  The
    # defconfig references it as fs/ubi/ubinize-ab.cfg; stage the SDK's copy
    # into the vendored buildroot so that path resolves.
    if grep -q 'BR2_TARGET_ROOTFS_UBI_CUSTOM_CONFIG_FILE' \
            "configs/${BUILDROOT_CFG}_defconfig" 2>/dev/null; then
        src="$SDK_ROOT/config/image/ubinize-ab.cfg"
        if [ -f "$src" ]; then
            cp -f "$src" fs/ubi/ubinize-ab.cfg
        else
            echo "ERROR: $src missing (custom ubinize config)" >&2
            exit 1
        fi
    fi
fi

if [ "$FULL" = "1" ] || [ ! -f "$BR_OUT/.config" ]; then
    make O="$BR_OUT" "${BUILDROOT_CFG}_defconfig"
fi

# The RK buildroot generates the early rootfs.cpio from
# $(TOPDIR)/../output/buildroot/target (which the post-rootfs publishes
# later).  Pre-create it so that first pass doesn't fail on a missing dir;
# the post-build pass regenerates the images from the real content.
mkdir -p "$VENDOR_DIR/output/buildroot/target"

# BR2_DL_DIR stays at the vendor buildroot/dl (persistent cache).
make O="$BR_OUT" -j"$NPROC"

mkdir -p "$FW_DIR"
if [ "${VENDOR:-rockchip}" = "pico" ]; then
    # ---- pico: build rootfs.img from the post-processed target ------------
    # (official flow: buildroot makes no fs image; mkfirmware does it)
    TARGET_DIR="$BR_OUT/target"
    [ -d "$TARGET_DIR" ] || { echo "ERROR: $TARGET_DIR missing" >&2; exit 1; }

    size_to_bytes() { # 32K|64M|6G -> bytes
        local n="${1%?}" s="${1: -1}" m=1
        case "$s" in
            K|k) m=1024 ;; M|m) m=$((1024*1024)) ;;
            G|g) m=$((1024*1024*1024)) ;; *) n="$1"; m=1 ;;
        esac
        echo $((n * m))
    }

    case "$ROOTFS_TYPE" in
        ubifs)
            # spi_nand: UBI 128K blocks / 2K pages (official geometry),
            # dynamic volume `rootfs` with autoresize.
            LEB=$((128*1024 - 2*2048))
            MAXLEB=$(($(size_to_bytes "${ROOTFS_SIZE:-85M}") / LEB))
            mkfs.ubifs -x lzo -e "$LEB" -m 2048 -c "$MAXLEB" -d "$TARGET_DIR" \
                -F -o "$OUT_DIR/rootfs.ubifs"
            cat > "$OUT_DIR/rootfs-ubinize.cfg" <<EOF
[ubifs]
mode=ubi
vol_id=0
vol_type=dynamic
vol_name=rootfs
vol_alignment=1
vol_flags=autoresize
image=$OUT_DIR/rootfs.ubifs
EOF
            ubinize -o "$FW_DIR/rootfs.img" -m 2048 -p $((128*1024)) \
                "$OUT_DIR/rootfs-ubinize.cfg"
            ;;
        *)
            # emmc/sd_card: mkfs at the partition size then shrink to the
            # content (official mkfs_ext4.sh: ^64bit,^huge_file, -m 5).
            SIZE_M=$(( $(size_to_bytes "${ROOTFS_SIZE:-6G}") / 1024 / 1024 ))
            mkfs.ext4 -d "$TARGET_DIR" -r 1 -N 0 -m 5 -L "" \
                -O ^64bit,^huge_file "$FW_DIR/rootfs.img" "${SIZE_M}M"
            resize2fs -M "$FW_DIR/rootfs.img"
            e2fsck -fy "$FW_DIR/rootfs.img" >/dev/null 2>&1 || true
            tune2fs -m 5 "$FW_DIR/rootfs.img" >/dev/null
            resize2fs -M "$FW_DIR/rootfs.img"
            ;;
    esac
else
    # ---- lyra: collect the buildroot-generated image ----------------------
    case "$ROOTFS_TYPE" in
        ubi|ubifs)  IMG="rootfs.ubi" ;;
        squashfs)   IMG="rootfs.squashfs" ;;
        *)          IMG="rootfs.ext4" ;;
    esac
    [ -f "$BR_OUT/images/$IMG" ] || { echo "ERROR: $IMG not produced" >&2; exit 1; }
    cp -f "$BR_OUT/images/$IMG" "$FW_DIR/rootfs.img"
fi

echo "rootfs stage done:"
ls -lh "$FW_DIR/rootfs.img"
