/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Copyright (c) 2026 shu-sdk contributors
 *
 * Boot-progress markers (temporary diagnostics).
 *
 * The M0 was observed to freeze before its first DDR write (rpmsg_responder_run
 * never reached *hb=0) without recording a fault (no 0x0BADF00D in the
 * fault_diag record).  To locate the hang, each startup stage writes a
 * monotonic stage id to 0x03c91040 -- inside the reserved rpmsg DDR window
 * (0x03c00000-0x03d00000, no-map) that the kernel never allocates, so Linux
 * can read the highest stage reached with devmem.
 *
 * Stage ids increase with progress; the surviving word is the last stage the
 * M0 reached.  Missing BM_RESET (or a frozen BM_RESET with the release
 * registers correct) means the M0 never executed -- see the mailbox B2A poke
 * in start_rk3506_mcu.S for the DDR-independent liveness signal.
 *
 *   0x03c91040  boot_prog   monotonic stage id (this header)
 *   0x03c91044  A0          reset vector entered        (start_rk3506_mcu.S)
 *   0x03c91048  A1          copy/zero tables done       (start_rk3506_mcu.S)
 *   0x03c9104c  A2          SystemInit returned         (start_rk3506_mcu.S)
 *   0x03c91050  A3          main() entered              (main.c)
 *   0x03c91054  A4          HAL_Init done               (main.c)
 *   0x03c91058  A5          BSP_Init done               (main.c)
 */

#ifndef _BOOTMARK_H_
#define _BOOTMARK_H_

#include <stdint.h>

#define BM_BASE       0x03c91040UL

#define BM_STAGE(_s)   (*((volatile uint32_t *)(uintptr_t)BM_BASE) = (_s))
#define BM_MARK(_off, _v) (*((volatile uint32_t *)(uintptr_t)(BM_BASE + (_off))) = (_v))

enum {
    BM_RESET    = 1,   /* Reset_Handler entry                       */
    BM_INIT     = 2,   /* copy/zero tables done                     */
    BM_SYSINIT  = 3,   /* SystemInit returned                       */
    BM_MAIN     = 4,   /* main() entered (before HAL_Init)          */
    BM_HALINIT  = 5,   /* HAL_Init returned                         */
    BM_BSP      = 6,   /* BSP_Init returned                         */
    BM_RUN      = 7,   /* rpmsg_responder_run entered               */
};

#define BM_A0_MAGIC 0xA0000001U
#define BM_A1_MAGIC 0xA0000002U
#define BM_A2_MAGIC 0xA0000003U
#define BM_A3_MAGIC 0xA0000004U
#define BM_A4_MAGIC 0xA0000005U
#define BM_A5_MAGIC 0xA0000006U

#endif /* _BOOTMARK_H_ */
