# Test Record — AMP (Linux↔M0 rpmsg) + OTA A/B on the eMMC verification bed

Date: 2026-08-15 (power-cycle sessions 11:50, 12:xx)

Bed: **physical Lyra Ultra W** — board `lyra-ultra-w-emmc-ab-amp`
(RK3506B, eMMC, A/B boot + AMP).  NAND variant `lyra-zero-w-spinand-ab-amp`
shares the SoC/AMP path; its storage path is build-only (no Zero W hardware
yet).

Firmware under test (one coherent unit, built `make build
BOARD=lyra-ultra-w-emmc-ab-amp` at 03:28 + the M0 fix rebuilt at 11:45):

| image | md5 | note |
|---|---|---|
| `update.img` | `5f7b3898…` | the coherent 03:28 unit (u-boot + kernel + rootfs + amp) |
| `boot_a.img` / `boot_b.img` | `3046d6e7…` | identical, written to both slots |
| `system_a.img` / `system_b.img` | `198227ec…` | identical, written to both slots |
| `amp.img` **pre-fix** | `04335873…` | mcu.bin `57b60f84…` (marker responder, no INTEN enable) |
| `amp.img` **post-fix** (flashed) | `aa37f4fc…` | mcu.bin `273c87f5…` (`mbox_enable_rx` fix), amp2/RT-Thread `ffd76152…` unchanged |

Environment: SSH `root@192.168.123.100` (USB gadget ethernet, `luckfox`),
register/buffer reads via `devmem`.

---

## 1. Result summary

| # | test | result |
|---|---|---|
| A1 | M0 boots after a real mains power-cycle (POR) | ✅ all boot markers + heartbeat |
| A2 | AP→M0 (A2B) kick reaches the M0 **after the fix, zero manual intervention** | ✅ `A2B_INTEN=0x101` self-enabled |
| A3 | M0 announces endpoint → `/dev/ttyRPMSG0` | ✅ channel created at 4.0 s |
| A4 | `m0ping` ping→pong round-trip | ✅ **5/5, 0 lost, RTT avg 253 µs** (226–295) |
| B1 | `ota-update apply` writes inactive slot + promotes | ✅ slot B written, pri 15 |
| B2 | reboot lands on the promoted slot | ✅ `current_slot=b`, `root=PARTUUID d7891b4a…` |
| B3 | `S99abctl` marks the booted slot successful | ✅ `tries 0, successful_boot 1` |
| C1 | M0 is POR-only (does not re-run on any software reset) | ✅ confirmed (4 mechanisms, see §5) |

---

## 2. Root cause found: missing A2B_INTEN enable bit

The announce path was dead (`/dev/ttyRPMSG0` never appeared) even though the
M0 ran and the kernel posted its rx buffers.  The M0's poll was **not** the
problem — the official HAL does exactly what the responder does (`HAL_MBOX_*
` checks `A2B_STATUS & 1` for a B2A-mode remote).  The defect is upstream in
the **AP→M0 direction enable**:

- The AP's `rockchip_mbox_v2_startup()` writes `A2B_INTEN = 0x01000100`.
  Bit 24 is the write-enable key and is *consumed by the hardware*; only the
  bit-8 trigger-method field lands.  Live read: `A2B_INTEN = 0x00000100`.
- **Without `INTEN_TX_DONE` (bit 0) the hardware never latches
  `A2B_STATUS`**, so the AP's kick sits in `A2B_CMD/DAT` (`cmd=2`,
  `data=0x524D5347`) with status stuck at 0 — the M0 can never observe it.
- The kernel **expects the remote to enable its own receive side**
  (`HAL_MBOX_ChanEnable` writes `A2B_INTEN = 1<<16 | 1`), but the rk3506-mcu
  HAL project contains no mailbox code, so nobody ever set bit 0.
- Contrast: `B2A_INTEN = 0x101` (bit 0 + bit 8) — so M0→AP (liveness poke,
  reply kicks) worked all along.

**Reusable register insight** (RK3506 V2 mailbox): INTEN/STATUS use
write-enable keys — `1<<16` keys bits 0–15, `1<<24` keys the bit-8 trigger
field.  The key is consumed on the write and never stored; writing *both* keys
in one write is rejected (bit 0 did not land from `0x01000101`), while a
single-key write leaves the other field untouched (`0x00010001` → `0x101`
when bit 8 is already set).

**Fix** (`firmware/mcu/src/rpmsg_responder.c`, `mbox_enable_rx()`):

```c
#define MBOX_A2B_INTEN_EN  0x00010001UL   /* write-enable key | bit 0 */

static void mbox_enable_rx(void)
{
    volatile struct mbox_v2 *m = (volatile struct mbox_v2 *)(uintptr_t)MBOX2_BASE;
    m->a2b_inten = MBOX_A2B_INTEN_EN;
}
```

Called at responder init **and every heartbeat (256 iterations)** — it must be
periodic, because the AP re-runs `v2_startup()` on every Linux boot and its
write clears bit 0 again (chicken-and-egg: the handshake kick cannot be seen
until bit 0 is enabled, so the M0 cannot wait for a kick to self-enable).

---

## 3. Test A — M0 announce + m0ping

### A0. Live diagnosis (pre-fix, manual)

Before the fix the following was observed with the M0 running the marker
responder (mcu.bin `57b60f84…`):

```
A2B_INTEN @ff292000 = 0x00000100     # trigger only, no enable
A2B_STATUS @ff292004 = 0x00000000    # never latches
A2B_CMD/DAT @ff292008/0c = 0x2 / 0x524D5347   # kick sits, undelivered
B2A_INTEN @ff292010   = 0x00000101   # M0→AP works
```

Manual enable + re-kick (proves the mechanism):

```
devmem 0xff292000 32 0x00010001      # set bit 0 (key 1<<16), bit 8 preserved
devmem 0xff292008 32 0x2             # cmd
devmem 0xff29200c 32 0x524d5347      # dat -> A2B_STATUS latches, M0 consumes
```

Result: `rvq used idx 0→1` (NS announce posted), `/dev/ttyRPMSG0` appears,
kernel logs `creating channel rpmsg-tty addr 0x1f`.  `m0ping` first run:
**5/5 ok, RTT µs {min 231.9, avg 287.6, max 417.4, p50 270.1}**.

### A1–A4. Post-fix, real power-cycle, zero manual intervention

New amp.img (mcu.bin `273c87f5…`) flashed to `/dev/mmcblk0p6`, then a mains
power-cycle.  Battery run automatically after the board returned (~16 s):

```
A2B_INTEN @ff292000 = 0x00000101     # self-enabled by the new firmware  ✅
boot_prog = 7; A0–A5 = 0xA0000001..06  # all boot markers                ✅
heartbeat 0x1732B → 0x19055 → 0x1AD7D # M0 alive, serving                ✅
/dev/ttyRPMSG0 present; dmesg: "creating channel rpmsg-tty addr 0x1f"    ✅
rvq used idx = 1                       # NS announce consumed            ✅
m0ping: {"rounds":5,"ok":5,"lost":0,
         "rtt_us":{"min":226.0,"avg":253.0,"max":295.5,"p50":254.6}}     ✅
post-ping rvq used = 6, svq used = 5   # NS + 5 pongs / 5 pings          ✅
```

The firmware fix is confirmed end-to-end: after a clean POR the whole
Linux↔M0 rpmsg link (announce → `/dev/ttyRPMSG0` → ping-pong) arms itself.

---

## 4. Test B — OTA A/B regression

`ota-update` (same machinery as the `lyra-ultra-w-emmc-ab` board, doc/ab-boot.md):

```
ota-update apply --rootfs /system_a.img --boot /boot_a.img
>>> writing system_a.img (261488640 B) -> /dev/mmcblk0p8   # system_b
>>> writing boot_a.img (6322176 B)     -> /dev/mmcblk0p5    # boot_b
{"ok": true, "slot": "b", "dry_run": false}
```

Post-apply metadata: **B pri 15 / tries 7, A demoted to pri 14**.  Warm reboot
(PSCI) → landed on slot B:

```
current_slot: b        root: PARTUUID d7891b4a-7115-4ca8-bd65-19d775fed905
androidboot.slot_suffix: _b
slots.b: priority 15, tries 0, successful_boot 1   # S99abctl mark-success ran
slots.a: priority 14, tries 7, successful_boot 0   # fallback
```

Slot B rootfs = `/dev/mmcblk0p8`; tools (`abctl`/`m0ping`/`ota-update`) present;
AMP kernel boots from B (`rockchip-rpmsg … rpmsg host is online`).  Rollback
(`abctl set-other-active`) was verified on the `lyra-ultra-w-emmc-ab` bed on
the same A/B machinery and is not re-run here.

---

## 5. Known behaviour / limitations

- **M0 is POR-only.**  It executes only after a real mains power-cycle.  All
  software reset paths fail to re-run it (exhaustively tested 2026-08-15):
  (1) CRU `SRST_HRESETN_M0_AC` (SOFTRST_CON00 bit 10 — write doesn't even
  stick), (2) CRU `SRST_H_M0` (SOFTRST_CON05 bit 10 — no effect), (3) PSCI
  warm `reboot`, (4) CRU `GLB_SRST_FST` global reset.  Root model: u-boot/TEE
  (`sip_smc_mcu_config`) only stage the code; the M0 core release + bootrom
  vector setup happens only in the POR path.  So after any warm reboot
  `/dev/ttyRPMSG0` is absent until the next power-cycle (DDR heartbeat word
  stays frozen at its pre-reboot value).
- **Firmware must self-heal the A2B enable** across Linux reboots (periodic
  `mbox_enable_rx()`), because the AP's `v2_startup` clears bit 0 each boot.
- `amp2` (RT-Thread on cpu@f02) is present in the FIT and released by u-boot,
  but its console heartbeat was not observed this session (not part of the
  ping-pong; see doc/amp.md).
- Deferred cleanup: staged OTA images `/boot_a.img` + `/system_a.img`
  (~267 MB) sit in slot A's rootfs; remove by mounting `/dev/mmcblk0p7`.
  The temporary boot-progress markers (`bootmark.h`, `fault_diag.c`) remain
  in the M0 build and can be removed once the link is considered stable.

## 6. Reproducing

Host-side scripts used (live on the build host at test time):

- `/tmp/watch-powercycle2.sh` — wait for board DOWN→UP, then run the battery.
- `/tmp/verify-amp-postfix.sh` — post-POR battery: A2B_INTEN self-enable
  check → boot markers → heartbeat → `/dev/ttyRPMSG0` → `m0ping` → `abctl`.
- `/tmp/mbox-enable-test.sh`, `/tmp/mbox-enable2.sh` — live register enable +
  re-kick diagnosis.
- Board-side: `/tmp/m0diag.sh`, `/tmp/ampmarker.sh` (flash/read marker build).

Key manual checks:

```sh
devmem 0xff292000               # A2B_INTEN — want 0x101
devmem 0x03c90000               # M0 heartbeat
devmem 0x03c01002               # rvq used idx (NS announce + replies)
ls -la /dev/ttyRPMSG0
m0ping --count 5
abctl status
```
