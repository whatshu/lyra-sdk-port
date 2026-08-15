# Lyra Ultra W — eMMC A/B dual-slot boot + OTA (RK3506B)

`lyra-ultra-w-emmc-ab`: the Ultra W with **A/B dual-slot boot + OTA
upgrade + automatic rollback**.  Exact source revisions of every component
are in `release.xml` — the release is reproducible from that manifest alone.
Detail: `doc/ab-boot.md`.

## What this image does
Everything in `lyra-ultra-w-emmc` (Linux 2×A7, USB-gadget CDC-ECM+DHCP,
ADB, `reboot-loader`) **and**:
- **A/B dual-slot storage** — `uboot_a/b`, `boot_a/b`, `system_a/b` on the
  eMMC GPT, selected by PARTUUID.  u-boot's native `CONFIG_ANDROID_AB` picks
  the slot; the `misc` partition holds the slot state (`AvbABData`).
- `abctl status` — current slot, priorities, tries.  `abctl set-other-active`
  — manual slot flip (rollback).  A shared `userdata` partition survives slot
  switches (formatted once, mounted at `/userdata`).
- **OTA** — `ota-update apply --rootfs <img> --boot <img>` writes the
  inactive slot, promotes it (pri 15 / tries 7), reboots onto it; `S99abctl`
  marks the booted slot successful (`tries=0, successful_boot=1`).
- **Automatic rollback** — a slot that keeps failing to boot exhausts its
  tries and u-boot falls back to the other slot; a `root=PARTUUID` injection
  means both slots share one device tree and fstab.

## Verified on hardware (2026-08-13)
- Full A/B regression on the Ultra W bed: OTA to slot B, boot on B,
  `abctl mark-success`, manual + automatic rollback to A.

## Caveats
- A fresh flash is slot **a** (pri 15) with slot **b** as standby.
- Rollback is triggered by failed boots / manual `abctl` flip — there is no
  verified-boot signature chain (`libavb` present, vbmeta keys not enforced).
