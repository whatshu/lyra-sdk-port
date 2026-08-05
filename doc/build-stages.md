# Build stages

The build follows the boot order of the device.  Stages are directories
`stages/NN-name/` managed by `scripts/build.py`; each has a `stage.yaml`
(metadata) and a `run.sh` (the recipe).  Python owns lifecycle, bash owns
the recipe.

## Pipeline

```
stages/
├── 10-uboot/     # SPL loader + uboot.img  (MiniLoaderAll.bin)
├── 20-kernel/    # zImage + dtb + modules + boot.img/zboot.img
├── 30-rootfs/    # buildroot rootfs (ext4/ubi/squashfs) + post-build hook
└── 40-firmware/  # assemble firmware set + update.img
```

A **full build** (`make build`) runs them in dependency order; a
**partial build** (`make uboot`, …) runs only the named stage and keeps any
hand-tuned temp config.

## Config override semantics

| mode | effect on temp config |
|---|---|
| `FULL=1` (build / release) | `product/platform/configs/<comp>` (and `product/custom/<comp>`) are copied over the vendor tree before the stage runs; `.config` is regenerated |
| `FULL=0` (single stage) | no copy, existing `.config` reused → `make kernel-menuconfig` changes survive |

The restore points live in `product/platform/configs/`:

- `kernel/rk3506_luckfox_defconfig`, `rk3506-display.config`
- `uboot/rk3506_luckfox_defconfig`, `rk3506b_luckfox.config`
- `buildroot/` (optional overrides copied over the vendored defconfig)

## What each stage produces

### 10-uboot
Runs the Rockchip `u-boot/make.sh` flow:

```
./make.sh CROSS_COMPILE=<toolchain> rk3506_luckfox [rk3506b_luckfox] --spl-new
```

It configures (defconfig + fragments), builds u-boot + SPL, then packs
`rk3506_spl_loader_v1.04.110.bin` (= `MiniLoaderAll.bin`) and `uboot.img`.
rkbin (DDR/trust blobs) is consumed from `vendor/rockchip/rkbin`.

### 20-kernel
```
make ARCH=arm CROSS_COMPILE=<toolchain> rk3506_luckfox_defconfig rk3506-display.config
make ARCH=arm CROSS_COMPILE=<toolchain> <dts>.img      # boot.img/zboot.img + resource.img
make ARCH=arm CROSS_COMPILE=<toolchain> modules
```

`scripts/mkimg` needs `mkimage`, provided by `vendor/rockchip/rkbin/tools`.

### 30-rootfs
```
make O=output/<cfg> <cfg>_defconfig
make O=output/<cfg>
```

> **Buildroot output is host-specific.**  The `output/<cfg>/host/` tree contains
> host tools linked against the *building* machine's glibc; an output produced on
> one host will fail at `target-finalize` on another (e.g.
> `glib-compile-schemas: undefined symbol g_task_set_static_name`).  Always build
> buildroot inside the pinned container from a clean output.  The package sources
> in the shared `BR2_DL_DIR` cache are reused, so a clean build only re-compiles.

buildroot's vendored post-build hook (`board/rockchip/common/post-build.sh`)
calls our shim `device/rockchip/common/post-build.sh`, which runs
`product/platform/rootfs/post-rootfs.sh`:

- base dirs + convenience symlinks
- `/etc/fstab` for the root fs type
- os-release annotation
- kernel module installation
- `product/platform/rootfs/overlay` + `product/custom/rootfs/overlay`
- ld.so.cache

The image (`rootfs.ext4` / `rootfs.ubi` / …) is copied to `out/firmware/rootfs.img`.
The buildroot download cache stays in `vendor/rockchip/buildroot/dl`.

### 40-firmware
Collects `MiniLoaderAll.bin`, `uboot.img`, `boot.img`, `rootfs.img` and the
`parameter.txt` (from `config/image/`) into `out/firmware/`, then packs the
all-in-one `update.img` with the vendored `afptool` + `rkImageMaker`.

## Partial build pitfalls

`make rootfs` requires the kernel to have been built once (modules install).
`make firmware` requires uboot/kernel/rootfs outputs.  The stage scripts
fail loudly rather than producing a broken image.
