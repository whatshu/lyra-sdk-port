#!/usr/bin/env bash
# Flash firmware to a Luckfox Lyra board.
#
# Recovery model (the software path back to the bootrom):
#   1. The device boots the Rockchip download mode (loader) either by
#      holding the BOOT key on power-up, or - when a known-good system is
#      running - by asking the bootloader to reboot into loader mode
#      (`upgrade_tool rd` or the kernel's usb-download gadget).
#   2. upgrade_tool/rkdeveloptool then write MiniLoaderAll.bin + update.img
#      over USB, which never requires opening the board.
#
# The loader (MiniLoaderAll.bin) always contains the USB download
# function, so a bad flash can always be re-flashed this way.
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOARD="${1:-lyra-ultra-w-emmc}"
MODE="${2:-latest}"

# pick the update image to flash
case "$MODE" in
    latest)
        # newest release for this board, else out/firmware
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
echo ">>> flashing $IMG"

# upgrade_tool lives in the rkbin submodule; rkdeveloptool is the open
# alternative.  We run inside the build container with the USB devices
# passed through so udev/tools are consistent.
UPGRADE="$SDK_ROOT/vendor/rockchip/rkbin/tools/upgrade_tool"
[ -x "$UPGRADE" ] || { echo "ERROR: run `make setup` first (upgrade_tool missing)" >&2; exit 1; }

docker run --rm \
    --privileged \
    -v /dev/bus/usb:/dev/bus/usb \
    -v "$SDK_ROOT":/sdk \
    -w /sdk \
    "$( . "$SDK_ROOT/tools/docker/image.info" 2>/dev/null; echo "${IMAGE:-shu-sdk:build}" )" \
    bash -c "
        DEVICES=\$($UPGRADE ld 2>/dev/null | grep -c '^No device' || true)
        if \$UPGRADE ld | grep -q 'No device'; then
            echo '>>> no device in loader mode yet; power-cycle with BOOT held,'
            echo '>>> or if the system boots, use:  upgrade_tool rd'
            echo '>>> (this always works even after a bad flash - the loader stays intact)'
            exit 1
        fi
        \$UPGRADE uf '$IMG' -noreset
        \$UPGRADE rd
    "
echo ">>> flash done"
