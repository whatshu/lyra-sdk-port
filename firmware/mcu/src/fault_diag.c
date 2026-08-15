/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Copyright (c) 2026 shu-sdk contributors
 *
 * Bring-up fault instrumentation (temporary, removed once the M0 rpmsg
 * responder is stable).
 *
 * The default CMSIS HardFault_Handler is an infinite loop with no record of
 * why the core faulted, so bring-up has been blind: the heartbeat counter
 * froze (0x03c90000) but there was no way to learn *where*.  This file
 * overrides the (weak) HardFault_Handler to dump the fault state to a fixed
 * DDR scratch area that Linux can read with devmem, then hangs.
 *
 * Cortex-M0 is ARMv6-M: there is no BusFault/UsageFault state, no BFAR.  The
 * useful evidence is the exception stack frame -- the PC of the faulting
 * instruction -- plus whatever live counters the responder keeps in DDR.
 *
 * Fault record layout @ 0x03c91000 (all words):
 *   0x00  magic     0x0BADF00D when a fault has been recorded
 *   0x04  msp       exception-frame base (also handler entry SP)
 *   0x08  cfsr      CFSR (ARMv6-M: only UsageFault bits meaningful)
 *   0x0c  bfar      BFAR (0 on M0; kept for parity with M3/M4 dumps)
 *   0x10  diag_state   responder's last state word (0x03c90004)
 *   0x14  diag_detail  responder's last detail word (0x03c90008)
 *   0x18  pc        faulting instruction address (frame[6])
 *   0x1c  lr        stacked LR (frame[5])
 *   0x20  r0        stacked R0 (frame[0])
 *   0x24  r1        stacked R1 (frame[1])
 *   0x28  r2        stacked R2 (frame[2])
 *   0x2c  r3        stacked R3 (frame[3])
 *   0x30  psr       stacked APSR/xPSR (frame[7])
 */

#include <stdint.h>

#define FAULT_BASE     0x03c91000UL
#define DIAG_STATE_ADDR 0x03c90004UL
#define DIAG_DETAIL_ADDR 0x03c90008UL

/*
 * Naked: the hardware has already pushed the 8-word exception frame onto the
 * MSP before the handler runs, and a naked function adds no prologue, so SP
 * at entry IS the frame base.  All stores go to the DDR scratch region, which
 * the responder has already proven writable (the heartbeat lives there).
 */
__attribute__((naked)) void HardFault_Handler(void)
{
    __asm volatile (
        "   ldr  r1, =0x03c91000\n"      /* fault record base             */
        "   ldr  r0, =0x0BADF00D\n"
        "   str  r0, [r1, #0]\n"         /* magic                         */
        "   mrs  r0, msp\n"              /* r0 = exception frame base     */
        "   str  r0, [r1, #4]\n"         /* msp                           */
        "   ldr  r0, =0xE000ED28\n"      /* SCB->CFSR                     */
        "   ldr  r0, [r0]\n"
        "   str  r0, [r1, #8]\n"         /* cfsr                          */
        "   ldr  r0, =0xE000ED3C\n"      /* SCB->BFAR (zero on M0)        */
        "   ldr  r0, [r0]\n"
        "   str  r0, [r1, #12]\n"        /* bfar                          */
        "   ldr  r0, =0x03c90004\n"
        "   ldr  r0, [r0]\n"
        "   str  r0, [r1, #16]\n"        /* diag_state at fault time      */
        "   ldr  r0, =0x03c90008\n"
        "   ldr  r0, [r0]\n"
        "   str  r0, [r1, #20]\n"        /* diag_detail at fault time     */
        "   mov  r2, sp\n"
        "   ldr  r0, [r2, #24]\n"        /* frame[6] = faulting PC        */
        "   str  r0, [r1, #24]\n"        /* pc                             */
        "   ldr  r0, [r2, #20]\n"
        "   str  r0, [r1, #28]\n"        /* lr                             */
        "   ldr  r0, [r2, #0]\n"
        "   str  r0, [r1, #32]\n"        /* r0                             */
        "   ldr  r0, [r2, #4]\n"
        "   str  r0, [r1, #36]\n"        /* r1                             */
        "   ldr  r0, [r2, #8]\n"
        "   str  r0, [r1, #40]\n"        /* r2                             */
        "   ldr  r0, [r2, #12]\n"
        "   str  r0, [r1, #44]\n"        /* r3                             */
        "   ldr  r0, [r2, #28]\n"
        "   str  r0, [r1, #48]\n"        /* psr                            */
        "   b    .\n"                     /* hang like the default handler */
    );
}
