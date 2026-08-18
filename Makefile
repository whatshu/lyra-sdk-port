# shu-sdk — minimal Luckfox build system (Lyra RK3506 / Pico RV1106-RV1103).
#
# Everything that compiles runs inside the pinned ubuntu 22.04 build
# container (tools/docker/).  Host-side git/container plumbing stays on
# the host.  See README.md for the full picture.

SHELL        := /bin/bash
BOARD        ?= lyra-ultra-w-emmc
.DEFAULT_GOAL := help

# Board-config-derived defaults used by the menuconfig helpers below
# (the build stages get these through scripts/config.py + context.py).
VENDOR        := $(shell sed -n 's/^[[:space:]]*VENDOR[[:space:]]*[:=]\{1,2\}[[:space:]]*//p' config/boards/$(BOARD).mk | head -1)
VENDOR        := $(if $(VENDOR),$(VENDOR),rockchip)
TC_PREFIX     := $(if $(filter pico,$(VENDOR)),arm-rockchip830-linux-uclibcgnueabihf-,arm-none-linux-gnueabihf-)
KERNEL_ARCH   := $(shell sed -n 's/^[[:space:]]*KERNEL_ARCH[[:space:]]*[:=]\{1,2\}[[:space:]]*//p' config/boards/$(BOARD).mk | head -1)
KERNEL_ARCH   := $(if $(KERNEL_ARCH),$(KERNEL_ARCH),arm)
BUILDROOT_CFG := $(shell sed -n 's/^[[:space:]]*BUILDROOT_CFG[[:space:]]*[:=]\{1,2\}[[:space:]]*//p' config/boards/$(BOARD).mk | head -1)

# All build work runs inside the container; the SDK root is bind-mounted
# at /sdk so outputs persist on the host.
DOCKER       := tools/docker/run.sh

# Interim: the pico vendor trees are symlinks to local mirrors OUTSIDE the
# repo (until the GitHub repos exist and they become submodules).  The
# build container only sees /sdk, so the mirrors' directory must be
# mounted at the same absolute path — derived here from the symlink
# target.  Override SDK_EXTRA_MOUNT if the mirrors live elsewhere.
PICO_MIRRORS_DIR := $(shell dirname $$(readlink -f vendor/pico/u-boot 2>/dev/null) 2>/dev/null || true)
export SDK_EXTRA_MOUNT ?= $(if $(filter pico,$(VENDOR)),$(PICO_MIRRORS_DIR),)

STAGES       := uboot kernel rootfs firmware

.PHONY: help
help:
	@echo "shu-sdk — Luckfox Lyra (RK3506) / Pico (RV1106-RV1103) build system"
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
	@echo "  make flash BOARD=x      flash the latest update.img (device in loader mode)"
	@echo "  make pico               Luckfox Pico family quick reference"

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
	RUN_INTERACTIVE=1 $(DOCKER) bash

.PHONY: clean
clean:
	rm -rf out
	@echo "removed out/"

# ---------------------------------------------------------------------------
# Manual component configuration (temp configs preserved until full build)
# ---------------------------------------------------------------------------

.PHONY: uboot-menuconfig kernel-menuconfig buildroot-menuconfig
uboot-menuconfig:
	RUN_INTERACTIVE=1 $(DOCKER) bash -lc 'cd vendor/$(VENDOR)/u-boot && make CROSS_COMPILE=$(TC_PREFIX) menuconfig && ./make.sh CROSS_COMPILE=$(TC_PREFIX) --spl-new'
kernel-menuconfig:
	RUN_INTERACTIVE=1 $(DOCKER) bash -lc 'cd vendor/$(VENDOR)/kernel && make ARCH=$(KERNEL_ARCH) CROSS_COMPILE=$(TC_PREFIX) menuconfig'
buildroot-menuconfig:
	RUN_INTERACTIVE=1 $(DOCKER) bash -lc 'test -f /sdk/out/buildroot-$(BUILDROOT_CFG)/.config || { echo "run make build BOARD=$(BOARD) first"; exit 1; }; cd vendor/$(VENDOR)/buildroot && make O=/sdk/out/buildroot-$(BUILDROOT_CFG) menuconfig'

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
	@echo "  Build the board variant:  make build BOARD=lyra-ultra-w-emmc-pico2"
	@echo "  ssh -p 10024 root@127.0.0.1   # then on the Lyra: pico2 info / pico2 flash <img>"

.PHONY: pico
pico:
	@echo "Luckfox Pico (RV1106/RV1103) — see doc/pico.md"
	@echo "  Boards:   pico-ultra (RV1106G3, eMMC) / webbee-spinand / webbee-sdmmc (RV1103)"
	@echo "  Build:    make build BOARD=pico-ultra"
	@echo "  Flash:    make flash BOARD=pico-ultra   # board in loader/maskrom mode"
	@echo "  Console:  USB serial 1500000 baud 8N1 (ttyFIQ0); ssh root@<ip> / luckfox"

.PHONY: ab
ab:
	@echo "A/B (dual-slot) boot + OTA upgrade — see doc/ab-boot.md"
	@echo "  Build the board variant:  make build BOARD=lyra-ultra-w-emmc-ab"
	@echo "  On the device:            abctl status / abctl set-other-active /"
	@echo "                            ota-update apply --rootfs rootfs.img"

# ---------------------------------------------------------------------------
.PHONY: fmt
fmt:
	@PYTHONPYCACHEPREFIX="$$(mktemp -d)" python3 -m py_compile scripts/*.py \
		tools/scripts/mkabmeta.py \
		product/platform/rootfs/overlay-lyra-ultra-w-emmc-ab/usr/bin/abctl \
		product/platform/rootfs/overlay-lyra-ultra-w-emmc-ab/usr/bin/ota-update \
		product/platform/rootfs/overlay-lyra-ultra-w-emmc-ab-amp/usr/bin/abctl \
		product/platform/rootfs/overlay-lyra-ultra-w-emmc-ab-amp/usr/bin/ota-update \
		product/platform/rootfs/overlay-lyra-zero-w-spinand-ab-amp/usr/bin/abctl \
		product/platform/rootfs/overlay-lyra-zero-w-spinand-ab-amp/usr/bin/ota-update \
		&& echo "python ok"
	@bash -n stages/*/run.sh device/rockchip/common/post-build.sh \
		product/platform/rootfs/post-rootfs.sh tools/*.sh \
		product/platform/rootfs/overlay-lyra-ultra-w-emmc-ab/etc/init.d/S10mount-userdata \
		product/platform/rootfs/overlay-lyra-ultra-w-emmc-ab/etc/init.d/S99abctl \
		product/platform/rootfs/overlay-lyra-ultra-w-emmc-ab-amp/etc/init.d/S10mount-userdata \
		product/platform/rootfs/overlay-lyra-ultra-w-emmc-ab-amp/etc/init.d/S99abctl \
		product/platform/rootfs/overlay-lyra-zero-w-spinand-ab-amp/etc/init.d/S10mount-userdata \
		product/platform/rootfs/overlay-lyra-zero-w-spinand-ab-amp/etc/init.d/S99abctl \
		&& echo "bash ok"
