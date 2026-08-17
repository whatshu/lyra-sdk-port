# 构建环境

## 容器

镜像由 `tools/docker/build-image.sh` 构建,来源如下:

1. **锁定的基础镜像。** `ubuntu:22.04@sha256:0199853f6d6b20b0424f3c5694a72a62764f01e6a771b1eb48a4197848986c7e`
   —— 一个不可变的 digest,而不是会变动的 `22.04` 标签,因此上游对"相同"标签的
   重新构建不会改变本构建。
2. **主机工具 —— 两种变体:**
   - *默认 (apt):* 与官方 SDK 安装相同的主机工具链,由不可变的基础镜像以及
     记录在 `/etc/shu-sdk/packages.txt` 中的精确软件包版本共同锁定(该文件被哈希进
     每一个发布清单中)。
   - *更强的锁定 (`make docker-image NIX=1`):* `tools/nix/default.nix` 锁定了一个
     nixpkgs 快照(`release-24.11`,sha256 锁定);主机工具只构建一次,不可变的
     闭包被固化到 `/nix/store` 中,与 apt 归档无关。这要求 nix 二进制缓存
     可达。
3. **供应商 ARM 工具链。** 官方 Rockchip/ARM 二进制发布,通过 `tools/docker/toolchains.env`
   中锁定的 sha256 获取。这些工具按原样使用(绝不自源码重建)。哈希不匹配会导致
   镜像构建直接失败并明确报错。

镜像 id 记录在 `tools/docker/image.info` 和 `container.env` 中,因此也记录在
每一个发布清单中。

### nix 缓存

nix store 不会在每次构建时重新创建:第一次 `docker build` 会编译它,之后镜像层会被
复用。`tools/nix/cache.sh` 还可以将闭包导出到 `tools/nix/cache/`,这样一台新机器
(或 CI)可以在不访问网络的情况下恢复精确的 store:

```sh
nix-store --export $(nix-store -qR /nix/store/*-shu-sdk-tools) > tools/nix/cache/store.closure
nix-store --import < tools/nix/cache/store.closure   # on another machine
```

## 目录结构

```
tools/
├── docker/            # Dockerfile, build/run scripts, .dockerignore
├── nix/               # pinned host toolchain (default.nix) + cache
├── host/rk/           # vendored Rockchip host tools (afptool, rkImageMaker)
├── scripts/           # setup.sh, flash.sh
└── dl/                # local toolchain tarballs (git-ignored)
```

`tools/host/rk/afptool` + `rkImageMaker` 是 Rockchip 的 update.img 打包工具
(随官方 SDK 以静态 x86_64 二进制形式提供)。

## 为什么不全用 apt?

Ubuntu 的归档会随时间变化;即使在"锁定"的镜像内部,`apt install` 在更晚的缓存上
也可能拉取不同的二进制。锁定 *镜像*(digest)、锁定 *工具链*(nixpkgs 修订版本 +
store 哈希),并锁定 *交叉编译器*(sha256)。留给 apt 的只是一小组从不影响产物的
运行时库。
