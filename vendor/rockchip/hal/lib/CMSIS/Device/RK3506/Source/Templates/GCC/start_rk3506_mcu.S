/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Copyright (c) 2023 Rockchip Electronics Co., Ltd.
 */

#include "hal_conf.h"

#ifdef HAL_MCU_CORE

/*
;//-------- <<< Use Configuration Wizard in Context Menu >>> ------------------
*/

                .syntax  unified
                .arch    armv6-m

                .section .vectors
                .align   2
                .globl   __Vectors
                .globl   __Vectors_End
                .globl   __Vectors_Size
__Vectors:
                .long    __StackTop                         /*     Top of Stack */
                .long    Reset_Handler                      /*     Reset Handler */
                .long    NMI_Handler                        /* -14 NMI Handler */
                .long    HardFault_Handler                  /* -13 Hard Fault Handler */
                .long    MemManage_Handler                  /* -12 MPU Fault Handler */
                .long    BusFault_Handler                   /* -11 Bus Fault Handler */
                .long    UsageFault_Handler                 /* -10 Usage Fault Handler */
                .long    0                                  /*     Reserved */
                .long    0                                  /*     Reserved */
                .long    0                                  /*     Reserved */
                .long    0                                  /*     Reserved */
                .long    SVC_Handler                        /*  -5 SVCall Handler */
                .long    DebugMon_Handler                   /*  -4 Debug Monitor Handler */
                .long    0                                  /*     Reserved */
                .long    PendSV_Handler                     /*  -2 PendSV Handler */
                .long    SysTick_Handler                    /*  -1 SysTick Handler */

                /* Interrupts */
                .space   (64 * 4)                          /* Interrupts 0 .. 63 are left out */
__Vectors_End:
                .equ     __Vectors_Size, __Vectors_End - __Vectors
                .size    __Vectors, . - __Vectors

                .thumb
                .section .text
                .align   2

                .thumb_func
                .type    Reset_Handler, %function
                .globl   Reset_Handler
                .fnstart
Reset_Handler:

/* ---- shu-sdk boot-progress markers (temporary diagnostics) --------------- */
/* The FIRST thing the M0 does is a DDR-independent liveness poke on          */
/* mailbox0 (B2A): the status bit + magic are observable with devmem even     */
/* if the M0 cannot reach DDR at all (e.g. a DDR master firewall).  Only      */
/* after that do we touch DDR: the highest stage reached lands in              */
/* 0x03c91040 (reserved rpmsg window, kernel never touches it).  Order is     */
/* deliberate — a DDR fault must never swallow the liveness signal.           */
                ldr      r3, =0xff290018      /* mailbox0 b2a_cmd */
                movs     r2, #2
                str      r2, [r3]
                ldr      r2, =0x524d5347      /* RPMSG_MBOX_MAGIC */
                str      r2, [r3, #4]
                ldr      r3, =0x03c91040
                movs     r2, #1
                str      r2, [r3]
                ldr      r2, =0xA0000001
                str      r2, [r3, #4]
/* ---- end markers --------------------------------------------------------- */

/* Firstly it copies data from read only memory to RAM.
 * There are two schemes to copy. One can copy more than one sections.
 * Another can copy only one section. The former scheme needs more
 * instructions and read-only data to implement than the latter.
 * Macro __STARTUP_COPY_MULTIPLE is used to choose between two schemes.
 */

                ldr      r4, =__copy_table_start__
                ldr      r5, =__copy_table_end__

.L_loop0:
                cmp      r4, r5
                bge      .L_loop0_done
                ldr      r1, [r4]
                ldr      r2, [r4, #4]
                ldr      r3, [r4, #8]

.L_loop0_0:
                subs     r3, #4
                blt      .L_loop0_0_done
                ldr      r0, [r1, r3]
                str      r0, [r2, r3]
                b        .L_loop0_0

.L_loop0_0_done:
                adds     r4, #12
                b        .L_loop0

.L_loop0_done:

                ldr      r3, =__zero_table_start__
                ldr      r4, =__zero_table_end__

.L_loop2:
                cmp      r3, r4
                bge      .L_loop2_done
                ldr      r1, [r3]
                ldr      r2, [r3, #4]
                movs     r0, 0

.L_loop2_0:
                subs     r2, #4
                blt      .L_loop2_0_done
                str      r0, [r1, r2]
                b        .L_loop2_0
.L_loop2_0_done:

                adds     r3, #8
                b        .L_loop2
.L_loop2_done:

/* ---- shu-sdk boot-progress marker: init tables done ---------------------- */
                ldr      r3, =0x03c91040
                movs     r2, #2
                str      r2, [r3]
                ldr      r2, =0xA0000002
                str      r2, [r3, #8]      /* A1 @ 0x03c91048 (bootmark.h) */
/* ---- end markers --------------------------------------------------------- */

                ldr      r3, =__StackTop
                msr      msp, r3
                bl       SystemInit
/* ---- shu-sdk boot-progress marker: SystemInit returned ------------------- */
                ldr      r3, =0x03c91040
                movs     r2, #3
                str      r2, [r3]
                ldr      r2, =0xA0000003
                str      r2, [r3, #12]     /* A2 @ 0x03c9104c (bootmark.h) */
/* ---- end markers --------------------------------------------------------- */
                bl       entry

                .fnend
                .size    Reset_Handler, . - Reset_Handler


                .thumb_func
                .type    Default_Handler, %function
                .weak    Default_Handler
                .fnstart
Default_Handler:
                b        .
                .fnend
                .size    Default_Handler, . - Default_Handler

/* Macro to define default exception/interrupt handlers.
 * Default handler are weak symbols with an endless loop.
 * They can be overwritten by real handlers.
 */
                .macro   Set_Default_Handler  Handler_Name
                .weak    \Handler_Name
                .set     \Handler_Name, Default_Handler
                .endm

/* Default exception/interrupt handler */

                Set_Default_Handler  NMI_Handler
                Set_Default_Handler  HardFault_Handler
                Set_Default_Handler  MemManage_Handler
                Set_Default_Handler  BusFault_Handler
                Set_Default_Handler  UsageFault_Handler
                Set_Default_Handler  SVC_Handler
                Set_Default_Handler  DebugMon_Handler
                Set_Default_Handler  PendSV_Handler
                Set_Default_Handler  SysTick_Handler

                .end

#endif  /* End of HAL_MCU_CORE */
