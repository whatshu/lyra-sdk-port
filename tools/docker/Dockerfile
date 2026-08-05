#
# shu-sdk build container (default / apt toolchain).
#
#  - Base is a *pinned* ubuntu 22.04 (immutable digest, not a moving tag).
#  - Host build tools come from apt inside that pinned image.  The image
#    digest plus the recorded package versions (written to
#    /etc/shu-sdk/packages.txt and captured in every release manifest)
#    make the toolchain reproducible.  The apt archive is pointed at a
#    (configurable) regional mirror for speed.
#  - The ARM cross-compiler is the official Rockchip/ARM binary release,
#    verified by pinned sha256 and installed under /opt/toolchains.
#
# For a *stronger* pin (nix-built host tools, independent of the apt
# archive) use Dockerfile.nix where the nix binary cache is reachable;
# see tools/nix/README.
#
# Build via tools/docker/build-image.sh.

ARG UBUNTU_BASE=ubuntu:22.04@sha256:0199853f6d6b20b0424f3c5694a72a62764f01e6a771b1eb48a4197848986c7e

FROM ${UBUNTU_BASE}

ENV DEBIAN_FRONTEND=noninteractive

# Optional fast regional apt mirror (e.g. mirrors.aliyun.com).
ARG APT_MIRROR=archive.ubuntu.com
RUN if [ "$APT_MIRROR" != "archive.ubuntu.com" ]; then \
        sed -i \
            "s|http://archive.ubuntu.com/ubuntu|http://${APT_MIRROR}/ubuntu|g; \
             s|http://security.ubuntu.com/ubuntu|http://${APT_MIRROR}/ubuntu|g" \
            /etc/apt/sources.list; \
    fi

# Host build tools.  These are the same ones the official SDK installs; the
# pinned base image + recorded versions keep the set stable.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential make cmake ninja-build bison flex \
        python3 perl pkg-config bc gawk patch gettext \
        device-tree-compiler lz4 xz-utils zstd cpio unzip zip rsync \
        kmod file e2fsprogs util-linux unifdef \
        libssl-dev libelf-dev libgmp-dev libmpc-dev libmpfr-dev \
        openssl openssh-client curl wget git ca-certificates \
        locales tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen && update-locale LANG=en_US.UTF-8

ENV LANG=en_US.UTF-8 LC_ALL=C.UTF-8

# Some vendored scripts (e.g. kernel scripts/bmpconvert, u-boot make.sh)
# still call `python`/`python2`; point them at python3 (they are 3-safe).
RUN ln -sf /usr/bin/python3 /usr/bin/python \
    && ln -sf /usr/bin/python3 /usr/bin/python2

# Record exactly which apt versions are in the image; every release
# manifest points back at this image id, so the set is fully pinned.
RUN mkdir -p /etc/shu-sdk && dpkg-query -W > /etc/shu-sdk/packages.txt

# ---- vendor (Rockchip/ARM) cross toolchain -------------------------------
# build-image.sh stages the sha256-verified tarball into the build context.
ARG TOOLCHAIN_ARMHF_SHA256
COPY tools/docker/context/toolchains/armhf.tar.xz /tmp/armhf.tar.xz
RUN echo "$TOOLCHAIN_ARMHF_SHA256  /tmp/armhf.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/toolchains \
    && tar -xJf /tmp/armhf.tar.xz -C /opt/toolchains \
    && rm -f /tmp/armhf.tar.xz \
    && find /opt/toolchains -name "*.tar.*" -delete
ENV SDK_TOOLCHAIN=/opt/toolchains

# buildroot needs a writable home for its git/ccache state
ENV HOME=/root

WORKDIR /sdk
ENTRYPOINT ["/bin/bash", "-lc"]
