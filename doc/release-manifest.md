# 发布

`make release` 在磁盘上生成一个不可变、自我描述的快照。每个发布中的
`RELEASE_NOTES.md` 从 `config/release-notes/<target>.md` 复制而来
(当开发板没有模板时会写入一个占位符),因此每块开发板都在随附的机制旁携带
自己的功能说明:

```
RELEASE/
├── index.xml                      # catalog of every release
└── <target>-<YYYYmmdd-HHMMSS>/
    ├── release.xml                # manifest (below)
    ├── RELEASE_NOTES.md           # human-readable "what this image does"
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

发布保存在*硬盘*上,绝不会放在易失的 `out/` 目录树中。`make build` 会将
同样的固件写入 `out/firmware/`,但**不会**保存它——重复的完整构建会相互
覆盖。只有 `release` 会持久保留,而且每个发布都是自我描述的,因此 CI 可以
归档或对其做 diff。

每个目标保留最近 10 个发布。

## release.xml 结构

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

`<repos>` 记录每个随附组件以及产品清单本身的精确提交——只需检出这些提交,
即可仅凭清单重现一个发布。`<environment>` 记录容器镜像、其 id 以及
nix/工具链哈希。`<artifacts>` 为每个文件携带一个 sha256,并镜像到
`firmware/sha256sums.txt`。
