# Build environment

## Container

The image is built by `tools/docker/build-image.sh` from:

1. **A pinned base image.** `ubuntu:22.04@sha256:0199853f6d6b20b0424f3c5694a72a62764f01e6a771b1eb48a4197848986c7e`
   — an immutable digest, not a moving `22.04` tag, so an upstream rebuild of the
   "same" tag cannot change the build.
2. **nix-pinned host tools.** `tools/nix/default.nix` pins a nixpkgs snapshot
   (`release-24.11`, sha256-locked).  The host toolchain (make, gcc, python, dtc,
   cpio, kmod, …) is built once and the immutable closure is baked into
   `/nix/store`.  Nothing build-critical is installed from apt.
3. **Vendor ARM toolchains.** The official Rockchip/ARM binary releases, fetched
   with sha256 pinned in `tools/docker/toolchains.env`.  These are used as-is
   (never rebuilt from source).  Hash mismatches fail the image build loudly.

The image id is recorded in `tools/docker/image.info` and `container.env`, and
therefore in every release manifest.

### The nix cache

The nix store is not re-created per build: the first `docker build` compiles it and
the image layer is reused afterwards.  `tools/nix/cache.sh` can additionally export
the closure to `tools/nix/cache/` so a fresh machine (or CI) can restore the exact
store without touching the network:

```sh
nix-store --export $(nix-store -qR /nix/store/*-shu-sdk-tools) > tools/nix/cache/store.closure
nix-store --import < tools/nix/cache/store.closure   # on another machine
```

## Layout

```
tools/
├── docker/            # Dockerfile, build/run scripts, .dockerignore
├── nix/               # pinned host toolchain (default.nix) + cache
├── host/rk/           # vendored Rockchip host tools (afptool, rkImageMaker)
├── scripts/           # setup.sh, flash.sh
└── dl/                # local toolchain tarballs (git-ignored)
```

`tools/host/rk/afptool` + `rkImageMaker` are the Rockchip update.img packers
(shipped as static x86_64 binaries with the official SDK).

## Why not apt for everything?

Ubuntu's archive mutates over time; even inside a "pinned" image, `apt install`
on a later cache can pull different binaries.  Pin the *image* (digest), pin the
*toolchain* (nixpkgs rev + store hash), and pin the *cross-compilers* (sha256).
What's left to apt is a small set of runtime libraries that never influence the
produced artifacts.
