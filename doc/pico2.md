# Debugging & controlling a Raspberry Pi Pico 2 (RP2350) from the Luckfox Lyra

The Luckfox Lyra Ultra W can act as a **debugger** (bit-banged SWD over its RMIO
header, driven by OpenOCD) **and** a **communication host** (SPI master) for an
external Raspberry Pi Pico 2 (RP2350, Cortex-M33).

This firmware is a **separate board variant** — `lyra-ultra-w-emmc-pico2`, a fork
of the default `lyra-ultra-w-emmc` board config.  The default eMMC board does
**not** include any of the pico2 bits (no spidev node, no openocd, no helpers).

## Building the pico2 firmware

```sh
make build   BOARD=lyra-ultra-w-emmc-pico2     # full build -> out/firmware/
make release BOARD=lyra-ultra-w-emmc-pico2     # full build + immutable RELEASE/ snapshot
```

The board config `config/boards/lyra-ultra-w-emmc-pico2.mk` is byte-for-byte the
default emmc config except it selects the pico2 device tree and the pico2
buildroot defconfig, and the board-scoped rootfs overlay is merged in at build
time (see below).

## Wiring — Luckfox Lyra Ultra W ↔ Pico 2

Both sides are **3.3 V** logic — no level shifting.  Power the Pico 2 from its
own 5 V/USB supply (do **not** back-feed it from the Lyra header).  Keep the
wires short (< 10–20 cm) and share a common GND.

| function | Luckfox RMIO pin | Luckfox GPIO | sysfs# | Pico 2 pin |
|---|---|---|---|---|
| SPI1 CLK | RMIO8 | GPIO0_PB0 | (muxed to SPI) | SPI SCK |
| SPI1 MOSI | RMIO9 | GPIO0_PB1 | (muxed to SPI) | SPI TX / MOSI |
| SPI1 MISO | RMIO10 | GPIO0_PB2 | (muxed to SPI) | SPI RX / MISO |
| SPI1 CS0 | RMIO14 | GPIO0_PB6 | (muxed to SPI) | SPI CS |
| SWD SWCLK | RMIO24 | GPIO1_PB1 | 41 | Pico 2 debug pad **SWCLK** |
| SWD SWDIO | RMIO25 | GPIO1_PB2 | 42 | Pico 2 debug pad **SWDIO** |
| SWD (spare) | RMIO26 | GPIO1_PB3 | 43 | *(free; RP2350 has no SRST)* |
| GND | GND | — | — | Pico 2 GND (debug pad **GND** / pin 28) |

> The Pico 2's 3-pin debug connector order is **SWCLK – GND – SWDIO** (same as
> Pico 1).  On the RP2350 the SWD pins are dedicated package pins, so they are
> independent of the 40-pin header's GPIO2/GPIO3 (unlike RP2040).

Physical positions: the RMIO labels are printed on the Lyra header silkscreen —
verify against the [Luckfox Lyra Pinout](https://wiki.luckfox.com/Luckfox-Lyra/Pinout/)
(Ultra/Ultra W tab) once the board is in hand.

## What the build provides

- `/dev/spidev1.0` — SPI1 master on RMIO8/9/10/14 (1 MHz default), enabled in
  the pico2 board device tree (`product/platform/dts/rk3506b-luckfox-lyra-ultra-w-pico2.dts`).
- `openocd` — OpenOCD built with `--enable-sysfsgpio` and RP2350 target support
  (pinned snapshot `88b9bd396`, v0.12.0-1240).
- `/etc/openocd/pico2.cfg` — SWD bit-bang on sysfs GPIO 41/42.
- `/usr/bin/pico2` — helper: `flash`, `halt`, `run`, `reset`, `info`.
- `/usr/bin/pico2-spi-demo.py` — python-spidev loopback check.

## Using the debugger (run on the Lyra, over the USB network)

Plug the USB-C into a Linux host — the gadget exposes a CDC-ECM link and a
DHCP server, so the host auto-configures (e.g. 192.168.123.x).  SSH straight
to the device:

```sh
ssh root@192.168.123.100             # password: luckfox

# connect and list targets
pico2 info

# halt / reset / run
pico2 halt
pico2 reset
pico2 run

# flash an ELF/hex/bin (bit-banged SWD is slow — small images only)
pico2 flash /path/to/hello.elf

# interactive GDB server on the Lyra (openocd -c 'gdb_port 3333'), then from a host:
#   gdb-multiarch hello.elf
#   (gdb) target remote <lyra-ip>:3333
```

Notes:

- OpenOCD bit-bangs via `/sys/class/gpio`, so it must run as root (the `pico2`
  helper is invoked by root on the Lyra).
- Start at `adapter speed 100` (kHz); if the initial connect fails, drop to
  `50`/`10` kHz in `/etc/openocd/pico2.cfg`.  sysfs bit-bang is the bottleneck,
  not the RP2350.
- RP2350 flashing over bit-bang is slow (minutes) — fine for debugging/light
  flashing.
- If the probe dies with `Require swclk and swdio gpio for SWD mode`, the
  adapter block uses `adapter gpio swclk/swdio` — that syntax belongs to the
  (uncompiled here) linuxgpiod driver.  This sysfsgpio build registers its own
  commands: `sysfsgpio swclk_num <n>` / `sysfsgpio swdio_num <n>`.

## SPI communication

The SPI demo shorts MOSI↔MISO locally to prove the bus works:

```sh
# on the Lyra: short RMIO9 to RMIO10 with a jumper, then:
pico2-spi-demo.py
# -> "OK: MOSI and MISO are shorted (loopback)"
```

For a real two-way link, wire the SPI pins to a Pico 2 SPI slave and use
`python3 -c 'import spidev; ...'` or any `/dev/spidev1.0` consumer.  `python3`
and `python-spidev` are already in the rootfs.

## Silicon revision (security)

The well-known RP2350 secure-boot breaks target the **A2** stepping
(`SYSINFO_CHIP_ID` = `0x20004927` — the DEF CON 2024 "RP2350 Hacking Challenge"
chip).  Newer silicon is not affected.  Check a board over SWD:

```sh
# on the Lyra, with the Pico 2 wired:
openocd -f /etc/openocd/pico2.cfg -c init -c halt \
  -c 'mdw 0x40000000 1' -c 'mdw 0x00000010 1' -c shutdown
```

- `0x40000000` (SYSINFO_CHIP_ID): `0x30004927` → revision nibble `0x3` = **A3**
  stepping (`0x2` = A2, the vulnerable one).
- `0x00000013` (bootrom version byte): `0x04` → **bootrom v4**.  A3 hardware +
  v4 bootrom is what the community calls the "A4" revision.

The reference board used for this feature is **A3 + bootrom v4** — not the
affected A2.

## How this is wired into the SDK

All pico2 bits are scoped to the `lyra-ultra-w-emmc-pico2` board; the default
`lyra-ultra-w-emmc` board keeps the plain DTS, a buildroot defconfig without
openocd, and no pico2 scripts.

- **Board config** — `config/boards/lyra-ultra-w-emmc-pico2.mk` (fork of the
  default emmc config) selects `KERNEL_DTS := rk3506b-luckfox-lyra-ultra-w-pico2`
  and `BUILDROOT_CFG := rockchip_rk3506_luckfox_pico2`.
- **Device tree** — `product/platform/dts/rk3506b-luckfox-lyra-ultra-w-pico2.dts`
  is the board DTS with the `&spi1` spidev node; a FULL build copies
  `$KERNEL_DTS.dts` over the vendored tree (see `stages/20-kernel/run.sh`).  To
  iterate on the DTS only:
  `cp product/platform/dts/rk3506b-luckfox-lyra-ultra-w-pico2.dts vendor/rockchip/kernel/arch/arm/boot/dts/ && make kernel BOARD=lyra-ultra-w-emmc-pico2`.
- **Buildroot** — `product/platform/configs/buildroot/rockchip_rk3506_luckfox_pico2_defconfig`
  enables `openocd` + sysfsgpio; the vendored buildroot's `openocd`/`jimtcl`
  packages were bumped for RP2350 support.
- **Rootfs overlay** — the config/helper/demo above live in the board-scoped
  `product/platform/rootfs/overlay-lyra-ultra-w-emmc-pico2/`, merged in by
  `product/platform/rootfs/post-rootfs.sh` (it applies `overlay-$TARGET` for the
  active board in addition to the shared `overlay/`).
