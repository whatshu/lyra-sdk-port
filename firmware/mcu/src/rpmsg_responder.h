/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Copyright (c) 2026 shu-sdk contributors
 *
 * M0 virtio-rpmsg responder.
 *
 * The M0 runs in the RK3506 SRAM (linked at 0x0, loaded at 0xfff84000 by the
 * TEE when u-boot releases it).  The Linux side is the stock Rockchip stack:
 * drivers/rpmsg/rockchip_rpmsg_mbox.c + virtio_rpmsg_bus.c, probed from the
 * rk3506-amp.dtsi `rpmsg@3c00000` node.  This file implements the exact
 * slave-side ring/mailbox protocol that driver expects, so Linux sees a
 * normal virtio-rpmsg "device" and exposes /dev/ttyRPMSG0 via rpmsg_tty.
 *
 * Topology (all numbers mirror the Linux driver / rk3506-amp.dtsi):
 *
 *   vring[0] rvq ("input")  @ 0x03c00000   Linux posts empty rx buffers
 *   vring[1] svq ("output") @ 0x03c80000   Linux posts TX messages
 *   mailbox0 @ 0xff290000                  M0 -> Linux rx kick   (B2A)
 *   mailbox2 @ 0xff292000                  Linux -> M0 kick (A2B); M0 txdone (B2A)
 *   link-id 0x02, RPMSG_MBOX_MAGIC 0x524D5347
 *
 * The M0 is a pure virtio "device": it never adds buffers to the avail ring,
 * it only consumes the avail ring (buffers Linux already posted) and
 * publishes completions to the used ring.  Mailbox A2B kicks are polled from
 * the main loop (no NVIC/INTMUX wiring needed), B2A kicks are issued with the
 * same cmd/data the kernel driver expects.
 *
 * See doc/amp.md for the ping-pong tool (/usr/bin/m0ping).
 */

#ifndef RPMSG_RESPONDER_H
#define RPMSG_RESPONDER_H

#include <stdint.h>

/* Runs forever: polls mailbox2, serves Linux rpmsg requests. */
void rpmsg_responder_run(void);

#endif /* RPMSG_RESPONDER_H */
