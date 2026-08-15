# Lyra Ultra W — eMMC + Pico 2 debug (RK3506B)

`lyra-ultra-w-emmc-pico2`: the base Ultra W image **plus** the Raspberry Pi
Pico 2 (RP2350) debug/communication tooling.  Exact source revisions of every
component are in `release.xml` — the release is reproducible from that
manifest alone.  Detail: `doc/pico2.md`.

## What this image does
Everything in `lyra-ultra-w-emmc` (Linux 2×A7, eMMC root, USB-gadget
CDC-ECM+DHCP at 192.168.123.100, ADB, `reboot-loader`) **and**:
- `/dev/spidev1.0` — SPI1 master on the RMIO header (8/9/10/14).
- OpenOCD **SWD bit-bang** over the RMIO header (`/etc/openocd/pico2.cfg`,
  sysfs GPIO 41/42).
- `/usr/bin/pico2` — `info` / `flash` / `halt` / `run` / `reset` for a
  connected Pico 2.

## Verified on hardware
- Exercised on real hardware (Pico 2 bootrom read over SWD — bootrom v4,
  RP2350 A3).

## Caveats
- Pico 2 debug is an *external* device driven by the Lyra; it does not change
  the base system otherwise.
