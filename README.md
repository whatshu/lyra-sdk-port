# shu-sdk — minimal Luckfox Lyra (RK3506) build system

A small, reproducible build system for the [Luckfox Lyra](https://wiki.luckfox.com/) family
(RK3506 / RK3506B).  It builds **u-boot + kernel + buildroot** into a set of flashable
artifacts, using a pinned ubuntu 22.04 docker container whose host toolchain is itself
pinned with nix.  It is *not* a copy of the official SDK build machinery — it keeps the
official source repos, but replaces the build orchestration with a clean pi-gen-style
stage pipeline.

```mermaid
flowchart TB
    subgraph manifest[product-manifest (this repo)]
        O[orchestrator<br/>Makefile -> scripts/build.py]
        P[product/platform<br/>central configs, patches, rootfs overlay]
        C[product/custom<br/>your customisations]
    end

    subgraph vendor[git submodules - pinned mirrors]
        VK[kernel]
        VU[u-boot]
        VB[buildroot]
        VR[rkbin]
    end

    subgraph toolchain[reproducible environment]
        D[pinned ubuntu 22.04 image]
        N[nix-pinned host tools]
        T[vendor ARM toolchains]
    end

    O --> vendor
    P --> O
    C --> O
    O --> toolchain

    VK --> |stage kernel| K[zImage + dtb + modules + boot.img]
    VU --> |stage uboot| U[MiniLoaderAll.bin + uboot.img]
    VB --> |stage rootfs| R[rootfs.img]
    VR --> U
    K & U & R --> |stage firmware| F[update.img + firmware set]

    F --> REL[RELEASE/<target>-<ts>/<br/>release.xml + sha256sums]
```

## Why this shape

- **Repos as submodules.** `vendor/rockchip/{kernel,u-boot,buildroot,rkbin}` are git
  submodules pointing at pinned mirrors (`whatshu/lyra-*`) of the Luckfox SDK component
  repos.  The official `repo` tool is not used.  Every commit is recorded in the release
  manifest.
- **Configs centralised.** The board definitions (`config/boards/*.mk`) and component
  configs (`product/platform/configs/`) live in this repo.  A **full build** copies them
  over the vendor trees, resetting any hand-tuned temp config; a **partial build** leaves
  the temp config alone, so `make kernel-menuconfig && make kernel` keeps your changes.
- **Stages in Python.** `scripts/build.py` owns stage discovery, ordering, config
  override and environment; each stage's recipe is a small `run.sh`.  Follows boot order:
  `uboot → kernel → rootfs → firmware`.
- **Reproducible environment.** The container is `ubuntu:22.04@sha256:0199853f…`
  (immutable digest).  Host build tools are pinned by the image digest plus the recorded
  apt package versions (in the manifest); an optional `Dockerfile.nix` variant bakes a
  sha256-locked nixpkgs toolchain into `/nix/store` instead, for networks where the nix
  cache is reachable.  The ARM cross-compilers are the official binary releases pinned by
  sha256.
- **Releases are immutable snapshots.** Only `make release` saves artifacts — to
  `RELEASE/<target>-<timestamp>/` with `release.xml` (all repo commits, image hashes,
  tool hashes) and `sha256sums.txt`.  `make build` produces the same output in the
  volatile `out/`, overwritten each run.
- **Always a software path back to the bootrom.** The loader always contains the USB
  download mode, and the flash helper handles both "device is booted" and "device needs
  a fresh loader" cases without opening the board.

## Quick start

```sh
# 1. once: get the component sources (pinned mirrors)
make setup

# 2. once: build the pinned build container (slow first time)
make docker-image

# 3. full build for the connected board (default lyra-ultra-w-emmc)
make build

# 4. save an immutable release snapshot
make release BOARD=lyra-zero-w-sdmmc

# 5. flash the device (device in loader mode, or boots - see below)
make flash
```

## Boards

| target | board | storage | parameter |
|---|---|---|---|
| `lyra-sdmmc` / `lyra-spinand` | Lyra (RK3506G) | SD / NAND | `parameter-lyra-{sdmmc,spinand}.txt` |
| `lyra-ultra-w-emmc` | Lyra Ultra W (RK3506B) | eMMC | `parameter-lyra-emmc.txt` |
| `lyra-zero-w-sdmmc` / `lyra-zero-w-spinand` | Lyra Zero W (RK3506B) | SD / NAND | `parameter-lyra-sdmmc.txt` |

The same core builds all Lyra variants; adding a board is a new small file in
`config/boards/`.

## Common commands

```sh
make build BOARD=lyra-sdmmc         # full build -> out/firmware
make release BOARD=lyra-ultra-w-emmc   # full build + save to RELEASE/
make uboot|kernel|rootfs|firmware      # single stage (keeps temp config)
make uboot-menuconfig                  # tweak u-boot config (persists)
make kernel-menuconfig buildroot-menuconfig
make shell                             # interactive shell in the container
make list-boards list-stages
make clean                             # drop out/
```

## Customisation

- **Board definitions**: `config/boards/<target>.mk` — pick defconfigs, dts, parameter.
- **Component configs**: `product/platform/configs/{kernel,uboot,buildroot}/` are the
  restore points applied on full builds.
- **Your own**: `product/custom/` mirrors the same layout (configs, rootfs overlay) and
  is applied on top of `product/platform`.  It is git-ignored so you can keep local
  secrets out.
- **Rootfs**: `product/platform/rootfs/overlay/` is merged into the image; the
  post-rootfs hook that wires up fstab/modules/os-release lives in
  `product/platform/rootfs/post-rootfs.sh`.

## Recovering the device

If a flashed system fails to boot:

1. Hold the **BOOT** key and power on → the board stays in loader mode (USB download).
2. `make flash` writes a known-good `update.img`.

If a system *is* booting but you want to re-flash, the running bootloader can be asked
to reboot into loader mode (`upgrade_tool rd`) without touching the board.  The loader
is never overwritten by a failed rootfs, so this always works.

See `doc/` for details on the build stages, the release manifest schema and the
container/nix toolchain.
