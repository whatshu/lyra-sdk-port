#
# shu-sdk build container (nix host-toolchain variant).
#
# Stronger pinning than the default apt-based Dockerfile: every host build
# tool comes from a sha256-locked nixpkgs snapshot (tools/nix/default.nix)
# and its immutable store is baked into /nix/store.  The apt archive is
# never a source of build tools.
#
# Requires the nix binary cache to be reachable during `docker build`
# (cache.nixos.org or a mirror).  Build with:
#   tools/docker/build-image.sh --nix
#
# The apt variant is the default because the nix binary cache is often
# unreachable on restricted networks.

ARG UBUNTU_BASE=ubuntu:22.04@sha256:0199853f6d6b20b0424f3c5694a72a62764f01e6a771b1eb48a4197848986c7e

# ---------------------------------------------------------------------------
# stage 1: build the pinned nix host-toolchain
# ---------------------------------------------------------------------------
FROM ${UBUNTU_BASE} AS nix-tools

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl xz-utils bzip2 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The nix installer refuses to run as root, so install single-user as a
# dedicated non-root user with write access to /nix.
RUN useradd -m -s /bin/bash nixbuilder \
    && mkdir -p /nix /etc/nix \
    && chown -R nixbuilder /nix \
    && echo "sandbox = false" > /etc/nix/nix.conf
USER nixbuilder
RUN curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon
ENV PATH=/home/nixbuilder/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH

COPY tools/nix/default.nix /tmp/nix/default.nix
RUN nix-build /tmp/nix/default.nix -o /tmp/shu-sdk-tools \
    && ls -d /nix/store/*-shu-sdk-tools

# copy only the *closure* of the tools env for the final stage to COPY
RUN mkdir -p /tmp/closure && cp -a --parents $(nix-store -qR /tmp/shu-sdk-tools) /tmp/closure/

# ---------------------------------------------------------------------------
# stage 2: vendor ARM toolchains (sha256 verified)
# ---------------------------------------------------------------------------
FROM ${UBUNTU_BASE} AS toolchains

ENV DEBIAN_FRONTEND=noninteractive
ARG TOOLCHAIN_ARMHF_SHA256
RUN apt-get update && apt-get install -y --no-install-recommends \
        xz-utils bzip2 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/toolchains
COPY tools/docker/context/toolchains/armhf.tar.xz /tmp/armhf.tar.xz
RUN echo "$TOOLCHAIN_ARMHF_SHA256  /tmp/armhf.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/armhf.tar.xz -C /opt/toolchains \
    && rm -f /tmp/armhf.tar.xz \
    && find /opt/toolchains -name "*.tar.*" -delete

# ---------------------------------------------------------------------------
# final image
# ---------------------------------------------------------------------------
FROM ${UBUNTU_BASE}

ENV DEBIAN_FRONTEND=noninteractive
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

COPY --from=toolchains /opt/toolchains /opt/toolchains
ENV SDK_TOOLCHAIN=/opt/toolchains
ENV HOME=/root

WORKDIR /sdk
ENTRYPOINT ["/bin/bash", "-lc"]
