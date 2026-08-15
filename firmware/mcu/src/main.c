/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Copyright (c) 2026 shu-sdk contributors
 *
 * M0 firmware entry.  The responder is deliberately silent: the RT-Thread
 * console on cpu2 owns UART4 (both UART3/4 IRQs route to cpu2 in amp-irqs),
 * so the M0 never touches the UART block.  All interaction with Linux is
 * through the virtio-rpmsg rings in DDR (see rpmsg_responder.c) plus the
 * mailbox registers.
 */

#include "hal_base.h"
#include "hal_bsp.h"
#include "rpmsg_responder.h"
#include "bootmark.h"

int main(void)
{
    BM_STAGE(BM_MAIN);
    BM_MARK(0x10, BM_A3_MAGIC);

    /* HAL BASE Init */
    HAL_Init();
    BM_STAGE(BM_HALINIT);
    BM_MARK(0x14, BM_A4_MAGIC);

    /* BSP Init (empty on RK3506, but keeps the parity with the demo) */
    BSP_Init();
    BM_STAGE(BM_BSP);
    BM_MARK(0x18, BM_A5_MAGIC);

    /*
     * Serve Linux rpmsg requests forever.  No UART, no INTMUX, no interrupts:
     * the mailbox A2B kicks are polled from this loop.
     */
    rpmsg_responder_run();

    /* unreachable */
    return 0;
}

int entry(void)
{
    return main();
}
