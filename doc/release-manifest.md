# Releases

`make release` produces an immutable, self-describing snapshot on disk:

```
RELEASE/
├── index.xml                      # catalog of every release
└── <target>-<YYYYmmdd-HHMMSS>/
    ├── release.xml                # manifest (below)
    ├── firmware.txt
    └── firmware/
        ├── MiniLoaderAll.bin
        ├── uboot.img
        ├── boot.img
        ├── rootfs.img
        ├── parameter.txt
        ├── update.img
        └── sha256sums.txt
```

Releases are kept on the *hard disk*, never in the volatile `out/` tree.
`make build` writes the same firmware to `out/firmware/` but does **not**
save it — repeated full builds overwrite each other.  Only `release`
persists, and each release is self-describing so CI can archive or diff it.

The 10 most recent releases per target are retained.

## release.xml schema

```xml
<release name="lyra-ultra-w-emmc" time="2026-08-04T21:00:00+0800"
         generated-by="shu-sdk" schema-version="1.0">
  <firmware board="lyra-ultra-w" storage="emmc" chip="rk3506"
            chip_variant="rk3506b" kernel_dts="rk3506b-luckfox-lyra-ultra-w"
            parameter="parameter-lyra-emmc.txt"/>
  <repos>
    <repo name="product-manifest" path="." commit="…" describe="…"/>
    <repo name="kernel" path="vendor/rockchip/kernel" commit="…" dirty="false"/>
    <repo name="u-boot" path="vendor/rockchip/u-boot" commit="…" dirty="false"/>
    <repo name="buildroot" path="vendor/rockchip/buildroot" commit="…" dirty="false"/>
    <repo name="rkbin" path="vendor/rockchip/rkbin" commit="…" dirty="false"/>
  </repos>
  <environment container_image="shu-sdk:build-…"
               container_image_sha256="sha256:…"
               board="…" mode="release"
               tool:make="…" tool:armhf="…" tool:eabi="…"/>
  <artifacts>
    <file name="boot.img" size="…" sha256="…"/>
    …
  </artifacts>
</release>
```

`<repos>` records the exact commit of every vendored component and of the
product manifest itself — a release is reproducible from the manifest alone
by checking out those commits.  `<environment>` records the container image,
its id, and the nix/toolchain hashes.  `<artifacts>` carries a sha256 per
file, mirrored in `firmware/sha256sums.txt`.
