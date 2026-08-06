# shu-sdk — minimal Luckfox Lyra (RK3506) build system.
#
# Everything that compiles runs inside the pinned ubuntu 22.04 build
# container (tools/docker/).  Host-side git/container plumbing stays on
# the host.  See README.md for the full picture.

SHELL        := /bin/bash
BOARD        ?= lyra-ultra-w-emmc
.DEFAULT_GOAL := help

# All build work runs inside the container; the SDK root is bind-mounted
# at /sdk so outputs persist on the host.
DOCKER       := tools/docker/run.sh

STAGES       := uboot kernel rootfs firmware

.PHONY: help
help:
	@echo "shu-sdk — Luckfox Lyra (RK3506) build system"
	@echo
	@echo "Setup (host):"
	@echo "  make setup              sync git submodules (needs GH access)"
	@echo "  make docker-image       build the pinned ubuntu 22.04 + nix container"
	@echo "  make docker-pull        pull a prebuilt container image instead"
	@echo
	@echo "Build (runs in container; BOARD defaults to $(BOARD)):"
	@echo "  make build   BOARD=x    full build -> out/firmware/ (overwrites)"
	@echo "  make release BOARD=x    full build + save immutable snapshot to RELEASE/"
	@echo "  make uboot|kernel|rootfs|firmware BOARD=x   build one stage only"
	@echo "  make stage STAGES='uboot kernel' BOARD=x    build several stages"
	@echo "  make shell              interactive shell inside the build container"
	@echo "  make clean              remove out/"
	@echo
	@echo "Manual component config (persist; a full build resets them):"
	@echo "  make uboot-menuconfig kernel-menuconfig buildroot-menuconfig"
	@echo
	@echo "Device:"
	@echo "  make list-boards list-stages"
	@echo "  make flash              flash the latest update.img (needs device in loader mode)"

# ---------------------------------------------------------------------------
# Host-side plumbing
# ---------------------------------------------------------------------------

.PHONY: setup
setup:
	tools/scripts/setup.sh

.PHONY: docker-image
docker-image:
	@if [ "$(NIX)" = "1" ]; then tools/docker/build-image.sh --nix; \
	else tools/docker/build-image.sh; fi

.PHONY: list-boards
list-boards:
	@python3 scripts/build.py list-boards

.PHONY: list-stages
list-stages:
	@python3 scripts/build.py list-stages

# ---------------------------------------------------------------------------
# Build targets (inside the container)
# ---------------------------------------------------------------------------

.PHONY: build release
build:
	$(DOCKER) ./scripts/build.py build --board $(BOARD)
release:
	$(DOCKER) ./scripts/build.py release --board $(BOARD)

.PHONY: $(STAGES) stage
$(STAGES):
	$(DOCKER) ./scripts/build.py stage --board $(BOARD) $@
stage:
	@[ -n "$(STAGES)" ] || { echo "usage: make stage STAGES='uboot kernel'"; exit 1; }
	$(DOCKER) ./scripts/build.py stage --board $(BOARD) $(STAGES)

.PHONY: shell
shell:
	$(DOCKER) bash

.PHONY: clean
clean:
	rm -rf out
	@echo "removed out/"

# ---------------------------------------------------------------------------
# Manual component configuration (temp configs preserved until full build)
# ---------------------------------------------------------------------------

.PHONY: uboot-menuconfig kernel-menuconfig buildroot-menuconfig
uboot-menuconfig:
	$(DOCKER) bash -lc 'cd vendor/rockchip/u-boot && make CROSS_COMPILE=$${TOOLCHAIN_PREFIX} menuconfig && ./make.sh CROSS_COMPILE=$${TOOLCHAIN_PREFIX} --spl-new'
kernel-menuconfig:
	$(DOCKER) bash -lc 'cd vendor/rockchip/kernel && make ARCH=$${KERNEL_ARCH} CROSS_COMPILE=$${TOOLCHAIN_PREFIX} menuconfig'
buildroot-menuconfig:
	$(DOCKER) bash -lc 'cd vendor/rockchip/buildroot && make O=output/$${BUILDROOT_CFG} menuconfig'

# ---------------------------------------------------------------------------
# Device flashing — the software path back to the bootrom.
# The device can be brought back into loader mode from Linux with
# `upgrade_tool rd` / `rkdeveloptool rd`, or by holding the BOOT key while
# powering on.  The USB gadget download mode is always compiled into the
# bootloader, so a flashed-but-broken system can always be re-flashed.
# ---------------------------------------------------------------------------

.PHONY: flash
flash:
	tools/scripts/flash.sh $(BOARD)

.PHONY: flash-latest
flash-latest:
	tools/scripts/flash.sh $(BOARD) latest

.PHONY: pico2
pico2:
	@echo "Pico 2 (RP2350) debug over SWD + SPI — see doc/pico2.md"
	@echo "  ssh -p 10024 root@127.0.0.1   # then on the Lyra: pico2 info / pico2 flash <img>"

# ---------------------------------------------------------------------------
.PHONY: fmt
fmt:
	@python3 -m py_compile scripts/*.py && echo "python ok"
	@bash -n stages/*/run.sh device/rockchip/common/post-build.sh \
		product/platform/rootfs/post-rootfs.sh tools/*.sh && echo "bash ok"
