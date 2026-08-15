# Asymmetric Multiprocessing (AMP) — RK3506: 2×Linux + RT-Thread + M0

The RK3506B has three Cortex-A7 cores and a Cortex-M0.  On the shu-sdk AMP
boards (`lyra-ultra-w-emmc-ab-amp`, `lyra-zero-w-spinand-ab-amp`) those become:

| core | runs |
|------|------|
| cpu0 / cpu1 | Linux (2× Cortex-A7, the normal SMP pair) |
| cpu@f02     | **RT-Thread** (Rockchip's `rk3506-32` BSP, a minimal demo task) |
| Cortex-M0   | **bare-metal HAL** rpmsg responder (`firmware/mcu/`) |

u-boot loads a single **amp.img FIT** from the `amp` partition and releases
both extra cores at boot; the kernel then talks to the M0 over virtio-rpmsg
(`/dev/ttyRPMSG0`).  The two Linux cores are untouched — cpu@f02 is deleted
from the kernel device tree (`rk3506-amp.dtsi`).

> **Why both RT-Thread *and* an M0 responder?**  The 3rd A7 (RT-Thread) shows
> that u-boot's PSCI cpu-on path works and gives a second general-purpose RTOS
> core for later use.  The M0 is the one that matters for the shipping feature:
> it is the low-latency, always-on peer for the Linux↔M0 **rpmsg ping-pong**
> (`m0ping`).  RT-Thread does not participate in the ping-pong.

## amp.img — the AMP FIT

`firmware/amp.its` packs the two images into one FIT (`mkimage -f amp.its -E
-p 0xe00 amp.img`, done by the firmware stage):

| image | type | cpu / load | starts with | core |
|-------|------|-----------|-------------|------|
| `amp2` | `firmware` | `cpu = <0xf02>`, load `0x03e00000` | PSCI `smc_cpu_on` | 3rd Cortex-A7 |
| `mcu`  | `standalone` | load `0xfff84000` | TEE SRAM release | Cortex-M0 |

- `amp2` (RT-Thread) is staged at DDR `0x03e00000` (the kernel's
  `amp_reserved` no-map region) and started via PSCI on cpu@f02 (mpidr `0xf02`).
- `mcu` is staged at `0xfff84000` in the SRAM carve-out (`mcu_reserved @
  0xfff80000, 0xc000`); the TEE maps address 0 → SRAM and releases the M0 in
  TCM mode (its vectors live at SRAM `0x0`).

The FIT carries a sha256 hash per image and a (currently unenforced) `rsa2048`
signature — u-boot's CONFIG_FIT_SIGNATURE is off, so the signature node is
metadata only.

## u-boot release path

With `CONFIG_AMP`/`CONFIG_ROCKCHIP_AMP`, `rk_board_late_init()` calls
`amp_cpus_on()` (`drivers/cpu/rockchip_amp.c`) unconditionally:

1. Reads the `amp` partition (GPT/MTD) into memory as a FIT.
2. Iterates the configuration's `loadables` (`amp2`, `mcu`) and for each calls
   `brought_up_amp()`:
   - **type=firmware** → `smc_cpu_on` (PSCI) starts the 3rd A7 at its load
     address.
   - **type=standalone** → `fit_standalone_release(id, entry)` on RK3506
     (`arch/arm/mach-rockchip/rk3506/rk3506.c`):
     1. `sip_smc_mcu_config(BUSMCU_0, MCU_CODE_START_ADDR, entry)` — the TEE
        maps address 0 to SRAM and stages the image.
     2. `writel(0x0c000000, CRU_GATE_CON5)` — gate the M0 clocks on
        (SWCK/TCK + HCLK).
     3. `writel(0xbcd3d80, GRF_SOC_CON36)` — M0 system-time calibration.
     4. `writel(0x00060004, PMU_INT_MASK_CON)` — release the M0 interrupt mask
        (`mcu_rst_dis_cfg=1`, `glb_int_mask_mcu=0`).
3. The boot CPU then continues to boot Linux.  The kernel does **not** re-gate
   the M0 (no CRU/PMU driver touches `GATE_CON5`/`PMU_INT_MASK_CON`), so the
   M0 keeps running across the kernel boot.

## Memory map (kernel side, `rk3506-amp.dtsi` + board dts)

All reserved, `no-map` — the kernel never allocates them:

| region | range | holds |
|--------|-------|-------|
| `amp_shmem_reserved` | `0x03b00000` 1 MiB | shared memory with cpu2 (RT-Thread) |
| `rpmsg_reserved`     | `0x03c00000` 1 MiB | virtio-rpmsg vrings + metadata |
| `rpmsg_dma_reserved` | `0x03d00000` 1 MiB | shared-dma-pool for rpmsg buffers |
| `amp_reserved`       | `0x03e00000` 1 MiB | RT-Thread image + heap (board dts) |
| `mcu_reserved`       | `0xfff80000` 48 KiB | M0 SRAM (TCM) |

The rpmsg vring layout (both sides must agree):

- `vring[0]` rvq @ `0x03c00000` — Linux posts empty rx buffers (M0 reads).
- `vring[1]` svq @ `0x03c08000` — Linux posts TX messages (M0 serves).
- mailbox0 @ `0xff290000` — **B2A**: M0 → Linux kick (`cmd=2`,
  `data=RPMSG_MBOX_MAGIC`), Linux rx.
- mailbox2 @ `0xff292000` — **A2B**: Linux → M0 kick, M0 txdone.
- `link-id 0x02`, `RPMSG_MBOX_MAGIC 0x524D5347`.

## Kernel AMP wiring

- **Config**: `arch/arm/configs/rockchip_amp.config` — mailbox, rpmsg,
  virtio, `rpmsg_tty`.
- **Drivers**: `drivers/rpmsg/rockchip_rpmsg_mbox.c` (vrings + mailbox
  transport), `drivers/soc/rockchip/rockchip_amp.c` (`/sys/rk_amp/boot_cpu`),
  `drivers/tty/rpmsg_tty.c` (`/dev/ttyRPMSG0`).
- **Boot**: with cpu@f02 deleted, the kernel boots 2 cores; the AMP dtsi routes
  UART3/4 + I2C0 + GPIO + mailbox IRQs to cpu2 via `amp-irqs`, so the extra
  peripherals belong to the RTOS side.

## M0 firmware (`firmware/mcu/`)

Bare-metal Rockchip HAL, `-mcpu=cortex-m0`, linked to TCM (`0x0`–`0x8000`,
stack at `0x7c00`); all interaction with Linux is through the DDR vrings plus
the mailbox registers — it never touches the UART block.

`rpmsg_responder.c` implements a virtio-rpmsg **responder** (mirrors the
kernel's `rockchip_rpmsg_mbox.c` constants):

- poll mailbox2 (A2B) for Linux kicks;
- serve the TX ring (svq), parse rpmsg buffers;
- reply by writing the used ring and kicking mailbox0 (B2A, `cmd=0x02`,
  `RPMSG_MBOX_MAGIC`);
- on "ping" it replies "pong" — the `m0ping` round-trip;
- a DDR heartbeat/diagnostic block at `0x03c90000` (`hb`, `diag_state`,
  `diag_detail`) lets Linux read M0 liveness/state with `devmem`;
- a `HardFault_Handler` (`fault_diag.c`) records a fault dump (MSP, CFSR/BFAR,
  stacked PC/LR/R0-R3) to `0x03c91000` and halts.

Built with `make -C firmware/mcu/GCC CROSS_COMPILE=arm-none-eabi-` (host or
build container).

## RT-Thread (cpu2, `vendor/rockchip/rtos`)

The official Rockchip `rk3506-32` BSP mirrored into the tree.  Built with
**scons**:

```sh
cd vendor/rockchip/rtos/bsp/rockchip/rk3506-32
scons --useconfig=board/evb1/defconfig_cpu2     # minimal non-SMP config
RTT_EXEC_PATH=/usr/bin RTT_PRMEM_BASE=0x03e00000 RTT_PRMEM_SIZE=0x00100000 \
RTT_SHMEM_BASE=0x03b00000 RTT_SHMEM_SIZE=0x00100000 CUR_CPU=2 scons -j$(nproc)
```

`defconfig_cpu2` is a minimal config (no SMP, 32 priorities, 1 kHz tick); the
firmware stage pins the same memory env the upstream build.sh uses.  The
RPMSG link-id `0x02` is left to the M0.  The demo task just heartbeats on the
RTOS console (UART4 routes to cpu2 in the AMP dtsi).

## Linux↔M0 ping-pong (`m0ping`)

`/usr/bin/m0ping` (rootfs overlay) opens `/dev/ttyRPMSG0` raw and does a
synchronous ping→pong per round, reporting RTT stats as JSON:

```sh
m0ping --count 1000
# {"device": "/dev/ttyRPMSG0", "rounds": 1000, "ok": 1000, "lost": 0,
#  "rtt_us": {"min": …, "avg": …, "max": …, "p50": …, "p99": …}}
```

The device node only appears after the AMP firmware is up and the M0 has
announced its endpoint, so `m0ping` retries the open for a few seconds.

## Build wiring (`stages/40-firmware/run.sh`)

With `AMP := 1` the firmware stage:

1. builds RT-Thread via scons → `amp2.bin`;
2. builds the M0 via make (arm-none-eabi) → `mcu.bin`;
3. runs `mkimage -f amp.its -E -p 0xe00 amp.img`;
4. packs `amp.img` into the `amp` partition of the update.img (both eMMC and
   NAND A/B package-files list it).

The build container pins `scons` + `gcc-arm-none-eabi` (tools/docker).

## Verification status

SoC-side AMP is exercised on the **hardware verification bed**
`lyra-ultra-w-emmc-ab-amp` (the physical Lyra Ultra W — same RK3506B as the
Zero W).  **The Linux↔M0 rpmsg link is now fully verified end-to-end**
(2026-08-15):

- u-boot `amp_cpus_on()` loads amp.img from the `amp` partition and the release
  registers land as designed (`CRU_GATE_CON5=0x0c000000`,
  `GRF_SOC_CON36=0x0bcd3d80`, `PMU_INT_MASK_CON=0x00060004`).
- The M0 announce→`/dev/ttyRPMSG0`→`m0ping` chain works with **zero manual
  intervention after a real mains power-cycle**: the responder self-enables its
  A2B receive path (`A2B_INTEN=0x101`), announces the `rpmsg-tty` endpoint
  (`addr 0x1f`), and serves `m0ping` at **5/5 rounds, RTT avg 253 µs**
  (226–295).  Full record: [doc/test-record-amp-ota.md](test-record-amp-ota.md).
- The one root cause found en route: the AP's mailbox `v2_startup()` writes
  `A2B_INTEN = 0x01000100`, whose bit-24 write-enable key is consumed and
  leaves **no bit-0 enable** — so the AP→M0 kick never latches `A2B_STATUS`
  and the M0 poll never fires.  Fix: the M0 re-asserts `A2B_INTEN = 0x00010001`
  at init and every heartbeat (the kernel expects the remote to self-enable,
  but re-runs `v2_startup()` on each boot).  See the test record, §2.
- **M0 is POR-only**: it executes only after a real mains power-cycle; warm
  reboots (PSCI) and CRU resets do not re-run it, so `/dev/ttyRPMSG0` is
  absent after `reboot` until the next power-cycle.  Exhaustively confirmed
  against 4 software-reset mechanisms (test record, §5).
- The A/B OTA regression on the AMP bed passes: `ota-update apply` writes +
  promotes slot B, a warm reboot lands on it, and `S99abctl` marks it
  successful (`tries 0, successful_boot 1`).
- The NAND zero-W board is build-only (no Zero W hardware yet) — the AMP
  firmware/SoC path is shared with the bed, the storage path is NAND-specific
  (see [doc/ab-boot-nand.md](ab-boot-nand.md)).
