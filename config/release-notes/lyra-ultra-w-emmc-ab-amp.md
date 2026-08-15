# Lyra Ultra W — eMMC A/B dual-slot boot + full AMP (RK3506B)

`lyra-ultra-w-emmc-ab-amp`: A/B boot + OTA upgrade **plus** the complete RK3506
AMP stack (2×Linux + RT-Thread + Cortex-M0 rpmsg responder), verified on
hardware (physical Lyra Ultra W).

Exact source revisions of every vendored component are in `release.xml` — the
release is reproducible from that manifest alone.  Detail: `doc/ab-boot.md`,
`doc/amp.md`, `doc/test-record-amp-ota.md`.

## What this image does

### Boot / storage — A/B dual-slot + OTA upgrade
- Dual system slots `boot_a/b` + `system_a/b` on the eMMC GPT, selected by
  PARTUUID; `uboot_a/b` kept as-is.
- `abctl status` — current slot, priorities, tries.  `abctl set-other-active`
  — manual slot flip (the rollback path).
- `ota-update apply --rootfs <img> --boot <img>` — writes the inactive slot,
  promotes it (pri 15 / tries 7), reboots onto it; `S99abctl` marks the booted
  slot successful, and a failed boot auto-rollbacks to the other slot.

### Compute — full AMP, all four cores used
- cpu0 / cpu1 — Linux SMP (2× Cortex-A7).
- cpu@f02 — **RT-Thread** (Rockchip rk3506-32 BSP), staged at `0x03e00000`
  and released by u-boot via PSCI `smc_cpu_on`.
- Cortex-M0 — bare-metal HAL **rpmsg responder** (`firmware/mcu/`), released
  by the TEE at SRAM `0xfff84000`.

### Linux ↔ M0 synchronous rpmsg ping-pong
- `/dev/ttyRPMSG0` (rpmsg_tty) appears automatically after a real power-cycle.
- `m0ping` — synchronous ping→pong per round; verified **5/5 rounds, RTT avg
  253 µs** (226–295), zero loss.
- M0 exposes a DDR heartbeat/diagnostic block (`0x03c90000`) and a HardFault
  dump record (`0x03c91000`), readable from Linux with `devmem`.

## Verified on hardware (2026-08-15, eMMC bed)
- **A/B OTA regression**: slot B written → promoted → warm reboot lands on B →
  `S99abctl` marks it successful (`successful_boot 1, tries 0`).
- **Announce → ttyRPMSG0 → m0ping** end-to-end with **zero manual
  intervention** after a mains power-cycle.
- **M0 root cause fixed**: the AP's mailbox `v2_startup()` writes
  `A2B_INTEN = 0x01000100`, whose bit-24 write-enable key is consumed and
  leaves no bit-0 enable — so the AP→M0 kick never latched `A2B_STATUS` and
  the responder never saw it.  The responder now re-asserts
  `A2B_INTEN = 0x00010001` at init and every heartbeat.  See
  `doc/test-record-amp-ota.md` §2.

## Caveats
- **M0 is POR-only**: it runs only after a real mains power-cycle; warm
  reboots (PSCI) and CRU resets do not re-run it, so `/dev/ttyRPMSG0` is
  absent after `reboot` until the next power-cycle.
- RT-Thread (cpu@f02) is released but its console heartbeat was not observed
  in the test session — it is not part of the ping-pong.
- The NAND variant `lyra-zero-w-spinand-ab-amp` shares the AMP/SoC path but is
  build-only (no Zero W hardware yet) — its storage path is NAND-specific.
