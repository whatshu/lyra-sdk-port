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

# --- pico (RV1106/RV1103): env.img + update.img ------------------------------
# The official pico flow carries the partition table inside the u-boot
# environment (env.img) instead of a parameter.txt: the SPL idblock reads
# blkdevparts/mtdparts + sys_bootargs from env.img and boots the FIT in
# `boot`.  update.img = download.bin loader + the partition images, packed
# exactly like tools/linux/Linux_Pack_Firmware/mk-update_pack.sh does.
if [ "${VENDOR:-rockchip}" = "pico" ]; then
    msg "pico firmware: env.img + empty oem/userdata + update.img"

    for f in download.bin idblock.img uboot.img boot.img rootfs.img; do
        [ -f "$FW/$f" ] || { echo "ERROR: missing firmware piece: $f" >&2; exit 1; }
    done

    size_to_bytes() { # 32K|64M|6G -> bytes (mkenvimage takes no suffix)
        local n="${1%?}" s="${1: -1}" m=1
        case "$s" in
            K|k) m=1024 ;; M|m) m=$((1024*1024)) ;;
            G|g) m=$((1024*1024*1024)) ;; *) n="$1"; m=1 ;;
        esac
        echo $((n * m))
    }
    # partition size for a named partition, straight out of PART_CMD
    part_size() { # part_size oem -> 512M ("" when absent)
        local want="$1" p name szpart sz
        local old_ifs="$IFS"
        IFS=',' read -ra PARTS <<< "$PART_CMD"
        IFS="$old_ifs"
        for p in "${PARTS[@]}"; do
            name="${p##*(}"; name="${name%)}"
            [ "$name" = "$want" ] || continue
            szpart="${p%(*)}"; sz="${szpart%%@*}"
            [ "$sz" = "-" ] && return 0
            echo "$sz"; return 0
        done
        return 0
    }

    # --- env.img ------------------------------------------------------------
    # Exactly the official build_env 3-line format (the SPL greps these
    # strings out of the environment at boot).
    case "$BOOT_MEDIUM" in
        emmc)     PARTS_LINE="blkdevparts=mmcblk0:$PART_CMD" ;;
        sd_card)  PARTS_LINE="blkdevparts=mmcblk1:$PART_CMD" ;;
        spi_nand) PARTS_LINE="mtdparts=spi-nand0:$PART_CMD" ;;
        spi_nor)  PARTS_LINE="mtdparts=sfc_nor:$PART_CMD" ;;
        *) echo "ERROR: unknown BOOT_MEDIUM $BOOT_MEDIUM" >&2; exit 1 ;;
    esac
    ENV_CFG="$OUT_DIR/env.txt"
    {
        echo "$PARTS_LINE"
        echo "sys_bootargs=${ROOTFS_ARGS} rk_dma_heap_cma=${CMA_SIZE}"
        echo "sd_parts=mmcblk0:16K@512(env),512K@32K(idblock),4M(uboot)"
    } > "$ENV_CFG"
    msg "env.txt:"
    cat "$ENV_CFG"
    "$SDK_ROOT/tools/host/rk/mkenvimage" \
        -s "$(size_to_bytes "${ENV_SIZE:-32K}")" -p 0x0 \
        -o "$FW/env.img" "$ENV_CFG"
    strings "$FW/env.img" | grep -q "sys_bootargs=" \
        || { echo "ERROR: env.img sanity check failed" >&2; exit 1; }

    # --- empty oem/userdata --------------------------------------------------
    # 精简核心: no app/media content, but the official partition layout is
    # kept, so oem/userdata are empty filesystems built with the official
    # recipes (mkfs_ext4.sh / mkfs_ubi.sh).
    EMPTY="$OUT_DIR/empty-part"
    rm -rf "$EMPTY"; mkdir -p "$EMPTY"
    DATA_FS_TYPE="${DATA_FS_TYPE:-$([ "$BOOT_MEDIUM" = "spi_nand" ] && echo ubifs || echo ext4)}"
    for part in oem userdata; do
        sz="$(part_size "$part")"
        [ -n "$sz" ] || continue
        case "$DATA_FS_TYPE" in
            ubifs)
                # spi_nand: UBI 128K blocks / 2K pages, dynamic volume named
                # after the partition, autoresize (official geometry).
                LEB=$((128*1024 - 2*2048))
                MAXLEB=$(( $(size_to_bytes "$sz") / LEB ))
                mkfs.ubifs -x lzo -e "$LEB" -m 2048 -c "$MAXLEB" \
                    -d "$EMPTY" -F -o "$OUT_DIR/$part.ubifs"
                cat > "$OUT_DIR/$part-ubinize.cfg" <<EOF
[ubifs]
mode=ubi
vol_id=0
vol_type=dynamic
vol_name=$part
vol_alignment=1
vol_flags=autoresize
image=$OUT_DIR/$part.ubifs
EOF
                ubinize -o "$FW/$part.img" -m 2048 -p $((128*1024)) \
                    "$OUT_DIR/$part-ubinize.cfg"
                ;;
            *)
                # emmc/sd_card: official mkfs_ext4.sh recipe, shrunk to the
                # (empty) content.
                SIZE_M=$(( $(size_to_bytes "$sz") / 1024 / 1024 ))
                mkfs.ext4 -d "$EMPTY" -r 1 -N 0 -m 5 -L "" \
                    -O ^64bit,^huge_file "$FW/$part.img" "${SIZE_M}M"
                resize2fs -M "$FW/$part.img"
                e2fsck -fy "$FW/$part.img" >/dev/null 2>&1 || true
                tune2fs -m 5 "$FW/$part.img" >/dev/null
                resize2fs -M "$FW/$part.img"
                ;;
        esac
        msg "$part.img ($sz, $DATA_FS_TYPE): $(stat -c %s "$FW/$part.img") bytes"
    done

    # --- update.img ----------------------------------------------------------
    # Official layout: all images + package-file flat in one dir, afptool
    # -pack that dir, then rkImageMaker embeds the loader with the chip tag.
    PKG="$OUT_DIR/updatepkg"
    rm -rf "$PKG"; mkdir -p "$PKG"
    cp -f "$FW/download.bin" "$PKG/"
    {
        echo "package-file	package-file"
        echo "bootloader	download.bin"
        old_ifs="$IFS"; IFS=',' read -ra PARTS <<< "$PART_CMD"; IFS="$old_ifs"
        for p in "${PARTS[@]}"; do
            name="${p##*(}"; name="${name%)}"
            szpart="${p%(*)}"; sz="${szpart%%@*}"
            # partitions with a `-` size exist in the layout but carry no
            # image (official package-file skips them)
            [ "$sz" = "-" ] && continue
            [ -f "$FW/$name.img" ] || { echo "ERROR: $name.img missing" >&2; exit 1; }
            cp -f "$FW/$name.img" "$PKG/"
            echo "$name	$name.img"
        done
    } > "$PKG/package-file"
    msg "package-file:"
    cat "$PKG/package-file"
    ( cd "$PKG" && \
      "$VENDOR_DIR/rkbin/tools/afptool" -pack ./ update.raw.img && \
      "$VENDOR_DIR/rkbin/tools/rkImageMaker" "-${RK_TAG:-RK1106}" \
          download.bin update.raw.img "$FW/update.img" -os_type:androidos )

    msg "compressing update.img"
    xz -T0 -6 -k -c "$FW/update.img" > "$FW/update.img.xz"

    echo "firmware stage done:"
    ls -lh "$FW"
    exit 0
fi

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
    if [ "${STORAGE:-}" = "spinand" ]; then
        # NAND A/B (lyra-zero-w-spinand-ab-amp): a single `uboot` slot (SPL
        # slot-suffix lookup falls back to the plain name) with A/B carried by
        # boot_a/b + system_a/b; the amp partition holds the AMP FIT once the
        # firmware stage produces it.  system_a/b are UBI images (rootfs.ubi).
        msg "NAND A/B layout: single uboot + boot_a/b, system_a/b"
        for s in a b; do
            cp -f "$FW/boot.img"   "$FW/boot_${s}.img"
            cp -f "$FW/rootfs.img" "$FW/system_${s}.img"
        done
    else
        msg "eMMC A/B layout: duplicating images into slot copies"
        for s in a b; do
            cp -f "$FW/uboot.img"  "$FW/uboot_${s}.img"
            cp -f "$FW/boot.img"   "$FW/boot_${s}.img"
            cp -f "$FW/rootfs.img" "$FW/system_${s}.img"
        done
    fi
    msg "generating misc.img (initial AvbABData)"
    python3 "$SDK_ROOT/tools/scripts/mkabmeta.py" -o "$FW/misc.img"
fi

# --- AMP firmware (cpu2 RT-Thread + M0 rpmsg responder) ------------------------
# AMP=1 boards carry an `amp` partition holding the AMP FIT that u-boot
# releases at boot (CONFIG_ROCKCHIP_AMP).  The FIT combines RT-Thread on the
# 3rd Cortex-A7 (type=firmware, loaded at 0x03e00000) with the M0 responder
# (type=standalone, loaded at 0xfff84000 by the TEE).  See doc/amp.md.
if [ "${AMP:-0}" = "1" ]; then
    msg "building AMP firmware (RT-Thread on cpu2 + M0 rpmsg responder)"
    RTOS_BSP="$SDK_ROOT/vendor/rockchip/rtos/bsp/rockchip/rk3506-32"
    MCU_DIR="$SDK_ROOT/firmware/mcu/GCC"
    MKIMAGE="$SDK_ROOT/vendor/rockchip/u-boot/tools/mkimage"
    [ -x "$MKIMAGE" ] || { echo "ERROR: mkimage missing at $MKIMAGE" >&2; exit 1; }

    # cpu2 RT-Thread: official rk3506-32 BSP, built with the committed
    # defconfig_cpu2 rtconfig.h (rpmsg link-id 0x02 is left to the M0) and the
    # same memory env the upstream build.sh uses (load 0x03e00000, shared
    # rpmsg rings reserved at 0x03c00000).  scons picks the arm-none-eabi
    # toolchain via RTT_EXEC_PATH.
    if [ ! -f "$RTOS_BSP/rtconfig.h" ]; then
        echo "ERROR: $RTOS_BSP/rtconfig.h missing (run scons --useconfig=board/evb1/defconfig_cpu2)" >&2
        exit 1
    fi
    ( cd "$RTOS_BSP" && \
      export RTT_ROOT="$SDK_ROOT/vendor/rockchip/rtos" \
             RTT_EXEC_PATH=/usr/bin \
             RTT_PRMEM_BASE=0x03e00000 RTT_PRMEM_SIZE=0x00100000 \
             RTT_SHMEM_BASE=0x03b00000 RTT_SHMEM_SIZE=0x00100000 \
             LINUX_RPMSG_BASE=0x03c00000 LINUX_RPMSG_SIZE=0x00200000 \
             CUR_CPU=2 && \
      scons -c >/dev/null && scons -j"${NPROC:-$(nproc)}" ) || \
        { echo "ERROR: RT-Thread (cpu2) build failed" >&2; exit 1; }
    cp -f "$RTOS_BSP/rtthread.bin" "$FW/amp2.bin"

    # M0 responder: bare-metal Rockchip HAL (cortex-m0), linked to the TCM at
    # 0x0; the TEE stages the standalone image at 0xfff84000 from the FIT.
    # The engine injects CROSS_COMPILE=.../arm-none-linux-gnueabihf- into every
    # stage env (the A7 Linux toolchain); the M0 needs the bare-metal
    # arm-none-eabi- prefix instead (present at /usr/bin in the build
    # container).  A make command-line assignment overrides both the injected
    # env var and the Makefile's ?= default, so this is the single place the
    # M0 toolchain is pinned.
    ( make -C "$MCU_DIR" CROSS_COMPILE=arm-none-eabi- ) || \
        { echo "ERROR: M0 responder build failed" >&2; exit 1; }
    cp -f "$MCU_DIR/TestDemo.bin" "$FW/mcu.bin"

    # Combined AMP FIT.  mkimage needs the ITS alongside the two binaries.
    cp -f "$SDK_ROOT/firmware/amp.its" "$FW/amp.its"
    ( cd "$FW" && "$MKIMAGE" -f amp.its -E -p 0xe00 amp.img ) || \
        { echo "ERROR: amp.img assembly failed" >&2; exit 1; }
    msg "amp.img: $(stat -c %s "$FW/amp.img") bytes (amp2.bin + mcu.bin)"
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
        if [ "${STORAGE:-}" = "spinand" ]; then
            # NAND A/B update.img: single uboot, boot_a/b, amp, system_a/b, misc.
            for f in uboot misc boot_a boot_b system_a system_b; do
                cp -f "$FW/$f.img" "$PKG/Image/"
            done
            [ -f "$FW/amp.img" ] && cp -f "$FW/amp.img" "$PKG/Image/"
            # package-file: which partitions go into update.img (amp line only
            # when the firmware stage has produced amp.img).
            cat > "$PKG/package-file" <<EOF
# NAME			Relative path
package-file	package-file
bootloader	Image/MiniLoaderAll.bin
parameter	Image/parameter.txt
uboot		Image/uboot.img
misc		Image/misc.img
boot_a		Image/boot_a.img
boot_b		Image/boot_b.img
$( [ -f "$FW/amp.img" ] && echo "amp		Image/amp.img" )
system_a	Image/system_a.img
system_b	Image/system_b.img
EOF
        else
            # eMMC A/B update.img carries every slot partition plus the misc
            # metadata (uboot_a/b, boot_a/b, amp, system_a/b, misc).
            for f in uboot_a uboot_b misc boot_a boot_b system_a system_b; do
                cp -f "$FW/$f.img" "$PKG/Image/"
            done
            [ -f "$FW/amp.img" ] && cp -f "$FW/amp.img" "$PKG/Image/"
            # package-file: which partitions go into update.img (amp line only
            # when the firmware stage has produced amp.img).
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
$( [ -f "$FW/amp.img" ] && echo "amp		Image/amp.img" )
system_a	Image/system_a.img
system_b	Image/system_b.img
EOF
        fi
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
