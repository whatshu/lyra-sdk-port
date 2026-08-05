# Flashing the firmware

The firmware set is produced in `out/firmware/` by `make build` (or saved
as an immutable snapshot under `RELEASE/` by `make release`).  Flash it
from the machine the board is physically attached to.

## Artifacts

| file | what it is |
|---|---|
| `MiniLoaderAll.bin` | SPL loader (DDR init + u-boot SPL + USB download mode) |
| `uboot.img` | main U-Boot image (FIT) |
| `boot.img` | kernel + dtb + resource |
| `rootfs.img` | buildroot root filesystem |
| `parameter.txt` | partition table |
| `update.img` | all of the above packed for one-command flashing |

## One-command flash (easiest)

Get `update.img` onto the machine, then:

```sh
# board in loader mode: hold BOOT + power on, or `adb reboot loader`
# from a booted system.  Check:
upgrade_tool ld          # Mode=Loader  or  Mode=Maskrom
# flash everything:
upgrade_tool uf update.img
```

`upgrade_tool` (Linux Upgrade Tool) is a static x86_64 binary; the SDK
ships it at `vendor/rockchip/tools/linux/Linux_Upgrade_Tool/`.  You need
write access to the Rockchip USB device node — either run as root, or
install the udev rule from `tools/scripts/99-rockchip-usb.rules`.

## Partition-by-partition (rkdeveloptool)

The open-source alternative, good for loader-mode boards:

```sh
sudo apt install rkdeveloptool   # Ubuntu; or build from source
rkdeveloptool ld                 # must list exactly one device
rkdeveloptool ul MiniLoaderAll.bin        # upload loader (idblock)
rkdeveloptool wlx uboot   uboot.img
rkdeveloptool wlx boot    boot.img
rkdeveloptool wlx rootfs  rootfs.img
rkdeveloptool rd                       # reboot
```

> rkdeveloptool refuses to run while more than one Rockchip device is
> visible (`Found too many rockusb devices`).  Unplug the others first.

## Recovery paths

- The loader always carries the USB download function, so a bad rootfs
  flash can always be re-flashed — the loader itself is never touched by a
  failed rootfs write.
- **Booted system** → `adb reboot loader` (or `reboot loader`) re-enters
  loader mode without touching the board.
- **Won't boot, loader intact** → power-cycle; u-boot falls back to
  download mode, or hold **BOOT** on power-up.
- **Worst case** → hold **BOOT** on power-up → maskrom; `upgrade_tool uf`
  still works (maskrom accepts a fresh loader).

## Notes

- On Ubuntu 22.04 the USB device node needs the udev rule
  (`tools/scripts/99-rockchip-usb.rules`); on some newer distros the
  `plugdev` group already grants access.
- If the loader upload reports `Download Boot Fail / please check ddr`,
  the loader's DDR config does not match the board's RAM — double-check
  the board variant (`BOARD=` in the Makefile) against `config/boards/`.
