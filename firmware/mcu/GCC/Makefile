# SPDX-License-Identifier: BSD-3-Clause */

# Copyright (c) 2026 shu-sdk contributors

PROJECT		:= RK3506
SOC		:= RK3506
CPU		:= -mcpu=cortex-m0

# BUS M0 — the shu-sdk rpmsg responder (see ../src/rpmsg_responder.c)
CFLAGS := -Os
LDFLAGS := --specs=nosys.specs
LINKER_SCRIPT := gcc_bus_m0.ld

include Cortex-M.mk
