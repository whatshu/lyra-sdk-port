# syntax=docker/dockerfile:1
#
# shu-sdk build container.
#
#  - Base is a *pinned* ubuntu 22.04 (immutable digest, not a moving tag).
#  - Host build tools come from a *pinned* nixpkgs snapshot (tools/nix),
#    baked into /nix/store.  Ubuntu apt is never a source of build tools,
#    so upstream binary churn cannot change what we produce.
#  - The ARM cross-compilers are the official Rockchip/ARM binary releases,
#    fetched with pinned sha256 and installed under /opt/toolchains.
#
# Build via tools/docker/build-image.sh.

ARG UBUNTU_BASE=ubuntu:22.04@sha256:0199853f6d6b20b0424f3c5694a72a62764f01e6a771b1eb48a4197848986c7e

# ---------------------------------------------------------------------------
# stage 1: build the pinned nix host-toolchain
# ---------------------------------------------------------------------------
FROM ${UBUNTU_BASE} AS nix-tools

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl xz-utils bzip2 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# deterministic single-user nix (we are root inside the image)
RUN curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon
ENV PATH=/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH

COPY tools/nix/default.nix /tmp/nix/default.nix
RUN nix-build /tmp/nix/default.nix -o /tmp/shu-sdk-tools

# copy only the *closure* of the tools env into a context the next stage
# can COPY from (store paths + the buildEnv itself)
RUN mkdir -p /tmp/closure && cp -a --parents $(nix-store -qR /tmp/shu-sdk-tools) /tmp/closure/

# ---------------------------------------------------------------------------
# stage 2: fetch the vendor ARM toolchains (pinned hashes)
# ---------------------------------------------------------------------------
FROM ${UBUNTU_BASE} AS toolchains

ENV DEBIAN_FRONTEND=noninteractive
ARG TOOLCHAIN_ARMHF_URL
ARG TOOLCHAIN_ARMHF_SHA256
ARG TOOLCHAIN_ARM_EABI_URL
ARG TOOLCHAIN_ARM_EABI_SHA256

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl xz-utils bzip2 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/toolchains \
    && curl -fsSL -o /tmp/armhf.tar.xz "$TOOLCHAIN_ARMHF_URL" \
    && echo "$TOOLCHAIN_ARMHF_SHA256  /tmp/armhf.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/armhf.tar.xz -C /opt/toolchains \
    && curl -fsSL -o /tmp/eabi.tar.bz2 "$TOOLCHAIN_ARM_EABI_URL" \
    && echo "$TOOLCHAIN_ARM_EABI_SHA256  /tmp/eabi.tar.bz2" | sha256sum -c - \
    && tar -xjf /tmp/eabi.tar.bz2 -C /opt/toolchains \
    && rm -f /tmp/*.tar.* \
    && find /opt/toolchains -name "*.tar.*" -delete

# ---------------------------------------------------------------------------
# final image
# ---------------------------------------------------------------------------
FROM ${UBUNTU_BASE}

ENV DEBIAN_FRONTEND=noninteractive

# Only a thin apt layer: locale data + the few runtime bits we want from
# Ubuntu itself.  Nothing build-critical comes from apt.
RUN apt-get update && apt-get install -y --no-install-recommends \
        locales tzdata \
        libc6 libstdc++6 libgcc-s1 libz1 libssl3 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen && update-locale LANG=en_US.UTF-8

ENV LANG=en_US.UTF-8 LC_ALL=C.UTF-8

# pinned nix host-tools (immutable store + a stable /opt link for PATH)
COPY --from=nix-tools /tmp/closure/nix/ /nix/
RUN ln -sf "$(ls -d /nix/store/*-shu-sdk-tools | head -1)" /opt/shu-sdk-tools \
    && echo "/opt/shu-sdk-tools/lib" > /etc/ld.so.conf.d/shu-sdk.conf \
    && ldconfig
ENV PATH=/opt/shu-sdk-tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# vendor (Rockchip/ARM) cross toolchains
COPY --from=toolchains /opt/toolchains /opt/toolchains
ENV SDK_TOOLCHAIN=/opt/toolchains

# buildroot needs a home for ccache and the git identity
ENV HOME=/root

WORKDIR /sdk
ENTRYPOINT ["/bin/bash", "-lc"]
