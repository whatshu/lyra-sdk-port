#!/usr/bin/env bash
# Builds the shu-sdk build container.
#
# Default: apt-pinned host tools (Dockerfile).  Pass --nix for the
# nix-built toolchain (Dockerfile.nix) where the nix binary cache is
# reachable.
#
# Pinned inputs in both variants:
#   - ubuntu:22.04@sha256 (immutable digest)
#   - vendor ARM toolchain (tools/docker/toolchains.env, sha256 pinned)
#   - apt: the exact package versions are recorded (default)
#   - nix: nixpkgs snapshot (tools/nix/default.nix) baked into /nix/store
#
# The image id + the tool/package pins are written to
# tools/docker/image.info and container.env, so every release manifest can
# point back at exactly what produced it.
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SDK_ROOT"

USE_NIX=0
[ "${1:-}" = "--nix" ] && USE_NIX=1

# --- load toolchain hashes -------------------------------------------------
TC_ENV="$SDK_ROOT/tools/docker/toolchains.env"
[ -f "$TC_ENV" ] || { echo "ERROR: $TC_ENV missing (copy toolchains.env.example)" >&2; exit 1; }
set -a; . "$TC_ENV"; set +a

[ -n "$TOOLCHAIN_ARMHF_URL" ] && [ -n "$TOOLCHAIN_ARMHF_SHA256" ] || {
    echo "ERROR: TOOLCHAIN_ARMHF_URL / TOOLCHAIN_ARMHF_SHA256 not set in $TC_ENV" >&2
    exit 1; }

# --- stage the (verified) toolchain tarball into the build context --------
CTX="$SDK_ROOT/tools/docker/context/toolchains"
mkdir -p "$CTX"
if [ -f "$CTX/armhf.tar.xz" ] && echo "$TOOLCHAIN_ARMHF_SHA256  $CTX/armhf.tar.xz" | \
        sha256sum -c - >/dev/null 2>&1; then
    echo ">>> using cached toolchain tarball"
else
    echo ">>> downloading $TOOLCHAIN_ARMHF_URL"
    curl -fsSL -o "$CTX/armhf.tar.xz.part" "$TOOLCHAIN_ARMHF_URL" \
        || { echo "ERROR: download failed" >&2; exit 1; }
    echo "$TOOLCHAIN_ARMHF_SHA256  $CTX/armhf.tar.xz.part" | sha256sum -c - \
        || { echo "ERROR: sha256 mismatch" >&2; exit 1; }
    mv -f "$CTX/armhf.tar.xz.part" "$CTX/armhf.tar.xz"
fi

# --- build ------------------------------------------------------------------
TAG="shu-sdk:build-$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
DOCKERFILE="tools/docker/Dockerfile"
[ "$USE_NIX" = 1 ] && DOCKERFILE="tools/docker/Dockerfile.nix"

echo ">>> building $TAG ($DOCKERFILE)"
docker build \
    --build-arg "TOOLCHAIN_ARMHF_SHA256=$TOOLCHAIN_ARMHF_SHA256" \
    --build-arg "APT_MIRROR=${APT_MIRROR:-mirrors.aliyun.com}" \
    -f "$DOCKERFILE" \
    -t "$TAG" \
    "$SDK_ROOT"

ID=$(docker inspect --format '{{.Id}}' "$TAG")
echo ">>> built $TAG ($ID)"

# --- record exact inputs for the release manifest --------------------------
APT_PKGS=""
if [ "$USE_NIX" = 0 ]; then
    # hash of the recorded apt package versions inside the image
    APT_PKGS="$(docker run --rm "$TAG" bash -c 'sha256sum /etc/shu-sdk/packages.txt | cut -d" " -f1')"
    docker run --rm "$TAG" cat /etc/shu-sdk/packages.txt > tools/docker/packages.txt
fi

{
    echo "SDK_IMAGE=$TAG"
    echo "SDK_IMAGE_SHA256=$ID"
    echo "SDK_TOOLCHAIN=apt"
    echo "SDK_APT_PACKAGES=$APT_PKGS"
    echo "SDK_TOOL_SHA256=armhf=$TOOLCHAIN_ARMHF_SHA256"
} > tools/docker/container.env
cat > tools/docker/image.info <<EOF
IMAGE=$TAG
IMAGE_ID=$ID
EOF
echo ">>> image info written to tools/docker/image.info"
echo ">>> container env written to tools/docker/container.env"
