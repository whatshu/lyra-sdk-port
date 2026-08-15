# Lyra Ultra W — eMMC (RK3506B)

`lyra-ultra-w-emmc`: the base Lyra Ultra W image — Linux on the RK3506B's
2× Cortex-A7 with an eMMC rootfs and USB-gadget networking.  Exact source
revisions of every component are in `release.xml` — the release is
reproducible from that manifest alone.

## What this image does
- Linux (2× Cortex-A7 SMP), eMMC root (ext4, auto-resized on first boot),
  display pipeline enabled, Wi-Fi/BT (AIC8800DC).
- **USB gadget CDC-ECM + DHCP** — plug the board into a host and it
  auto-configures 192.168.123.x; SSH in as `root@192.168.123.100`
  (`luckfox`).  `dnsmasq` serves the gadget link.
- **ADB** over the same gadget function.
- `reboot-loader` — reboot straight into Rockchip loader mode for
  re-flashing without touching the BOOT key.

## Verified on hardware
- This is the default, continuously-used Ultra W image (the bed for the A/B
  and AMP variants below); re-flashed and re-tested regularly.

## Caveats
- Single-slot storage: flashing replaces the whole system (no A/B fallback —
  use `lyra-ultra-w-emmc-ab` for dual-slot + OTA).
