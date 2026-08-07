# Debugging & controlling a Raspberry Pi Pico 2 (RP2350) from the Luckfox Lyra

The Luckfox Lyra Ultra W can act as a **debugger** (bit-banged SWD over its RMIO
header, driven by OpenOCD) **and** a **communication host** (SPI master) for an
external Raspberry Pi Pico 2 (RP2350, Cortex-M33).

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
  the board device tree (`product/platform/dts/`).
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

## How this is wired into the SDK

- **Device tree** — `product/platform/dts/rk3506b-luckfox-lyra-ultra-w.dts` is
  the board DTS with the `&spi1` spidev node; a FULL build copies it over the
  vendored tree (see `stages/20-kernel/run.sh`).  To iterate on the DTS only:
  `cp product/platform/dts/rk3506b-luckfox-lyra-ultra-w.dts vendor/rockchip/kernel/arch/arm/boot/dts/ && make kernel`.
- **Buildroot** — `product/platform/configs/buildroot/rockchip_rk3506_luckfox_defconfig`
  enables `openocd` + sysfsgpio; the vendored buildroot's `openocd`/`jimtcl`
  packages were bumped for RP2350 support.
- **Rootfs overlay** — the config/helper/demo above live in
  `product/platform/rootfs/overlay/`.
