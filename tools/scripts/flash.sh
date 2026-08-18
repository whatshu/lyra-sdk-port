#!/usr/bin/env bash
# Flash firmware to a Luckfox board (Lyra RK3506 / Pico RV1106-RV1103).
#
# Recovery model (the software path back to the bootrom):
#   1. The device is in loader mode (Rockchip download mode) or maskrom.
#      From a *booted* system, `adb reboot loader` re-enters loader mode.
#   2. The loader is uploaded to RAM (`upgrade_tool ul`) and the image is
#      written (`upgrade_tool uf update.img`) — no pins, no buttons.
#
# The loader (MiniLoaderAll.bin for lyra, download.bin for pico) always
# contains the USB download function, so even a bad rootfs flash can
# always be re-flashed this way.
#
# Needs write access to the Rockchip USB device node.  If that fails,
# install tools/scripts/99-rockchip-usb.rules once, or run this with sudo.
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOARD="${1:-lyra-ultra-w-emmc}"
MODE="${2:-latest}"

# pick the update image to flash
case "$MODE" in
    latest)
        REL=$(ls -d "$SDK_ROOT"/RELEASE/"$BOARD"-* 2>/dev/null | sort | tail -1 || true)
        if [ -n "$REL" ] && [ -f "$REL/firmware/update.img" ]; then
            IMG="$REL/firmware/update.img"
        else
            IMG="$SDK_ROOT/out/firmware/update.img"
        fi
        ;;
    /*)
        IMG="$MODE"
        ;;
    *)
        IMG="$SDK_ROOT/RELEASE/$MODE/firmware/update.img"
        ;;
esac

[ -f "$IMG" ] || { echo "ERROR: update image not found: $IMG" >&2; exit 1; }

# VENDOR comes from the board config (rockchip | pico).
VENDOR=$(sed -n 's/^[[:space:]]*VENDOR[[:space:]]*[:=]\{1,2\}[[:space:]]*//p' \
    "$SDK_ROOT/config/boards/$BOARD.mk" | head -1 || true)
VENDOR="${VENDOR:-rockchip}"

# Prefer the SDK's Linux upgrade_tool (matches the official rkflash.sh);
# fall back to the rkbin copy.  pico boards vendor their own upgrade_tool
# (vendor/pico/rkbin/tools).
if [ "$VENDOR" = "pico" ]; then
    UT="$SDK_ROOT/vendor/pico/rkbin/tools/upgrade_tool"
else
    UT="$SDK_ROOT/vendor/rockchip/tools/linux/Linux_Upgrade_Tool/Linux_Upgrade_Tool/upgrade_tool"
    [ -x "$UT" ] || UT="$SDK_ROOT/vendor/rockchip/rkbin/tools/upgrade_tool"
fi
[ -x "$UT" ] || { echo "ERROR: upgrade_tool not found (run \`make setup\`)" >&2; exit 1; }

echo ">>> flashing $IMG"
echo ">>> device in loader/maskrom mode? (power-cycle with BOOT held,"
echo ">>> or from a booted system: adb reboot loader)"

# upgrade_tool needs to claim the USB interface; fall back to sudo if the
# device node is not writable by this user.
run() { "$@"; }
if ! "$UT" ld 2>&1 | grep -q "rockusb connected"; then
    echo "ERROR: no device in loader mode" >&2
    exit 1
fi
if ! dd if=/dev/bus/usb/*/* of=/dev/null bs=1 count=0 2>/dev/null \
    && ! "$UT" td >/dev/null 2>&1; then
    :
fi

# Try a probe upload; if the device node is not writable, re-run as root.
if ! timeout 20 "$UT" td >/dev/null 2>&1; then
    echo ">>> device not accessible without root; retrying with sudo"
    exec sudo -E "$0" "$BOARD" "$MODE"
fi

if [ "$VENDOR" = "pico" ]; then
    # pico: no parameter.txt — the partition table lives in env.img inside
    # update.img, so the whole image is flashed in one go (official
    # rkflash.sh flow: ul download.bin + uf update.img + rd).  The loader
    # is the download.bin mini-loader; take it from the image's own dir
    # (RELEASE snapshot or out/firmware).
    LOADER="${IMG%/update.img}/download.bin"
    [ -f "$LOADER" ] || LOADER="$SDK_ROOT/out/firmware/download.bin"
    [ -f "$LOADER" ] || { echo "ERROR: download.bin not found" >&2; exit 1; }
    echo ">>> loader: $LOADER"
    timeout 30 "$UT" ul -noreset "$LOADER" || {
        echo ">>> loader upload failed; is the device in loader/maskrom mode?" >&2
        exit 1
    }
    timeout 600 "$UT" uf "$IMG"
    timeout 30 "$UT" rd
    echo ">>> flash done"
    exit 0
fi

timeout 30 "$UT" ul -noreset "$SDK_ROOT/out/firmware/MiniLoaderAll.bin" || {
    echo ">>> loader upload failed; is the device in loader/maskrom mode?" >&2
    exit 1
}

# A/B boards (AB=1 in the board config) carry uboot_a/b, boot_a/b, system_a/b
# and misc partitions that the di -uboot/-b/-rootfs flags cannot address, so
# flash the whole update.img instead (upgrade_tool uf writes every partition
# the image lists).
if grep -qE '^\s*AB\s*(:=|=)\s*1\b' "$SDK_ROOT/config/boards/$BOARD.mk" 2>/dev/null; then
    echo ">>> A/B board: flashing full update.img"
    timeout 600 "$UT" uf "$IMG"
    timeout 30 "$UT" rd
    echo ">>> flash done"
    exit 0
fi

# Write the partitions per the official rkflash.sh flow.
P="$SDK_ROOT/out/firmware"
timeout 60 "$UT" di -p "$P/parameter.txt"
timeout 60 "$UT" di -uboot "$P/uboot.img"
timeout 60 "$UT" di -b "$P/boot.img"
timeout 120 "$UT" di -rootfs "$P/rootfs.img"
timeout 30 "$UT" rd

echo ">>> flash done"
