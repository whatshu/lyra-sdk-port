#!/usr/bin/env bash
# Builds the shu-sdk build container.
#
# The image is produced entirely from pinned inputs:
#   - ubuntu:22.04@sha256 (immutable digest)
#   - nixpkgs snapshot (tools/nix/default.nix)
#   - vendor ARM toolchains (tools/docker/toolchains.env, sha256 pinned)
#
# The resulting image is tagged shu-sdk:build-<git-head> and its id is
# recorded in tools/docker/image.info so tools/docker/run.sh and the
# release manifest can reference it.
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SDK_ROOT"

# --- load toolchain hashes -------------------------------------------------
TC_ENV="$SDK_ROOT/tools/docker/toolchains.env"
[ -f "$TC_ENV" ] || { echo "ERROR: $TC_ENV missing (copy toolchains.env.example)" >&2; exit 1; }
set -a; . "$TC_ENV"; set +a

for v in TOOLCHAIN_ARMHF_URL TOOLCHAIN_ARMHF_SHA256 \
         TOOLCHAIN_ARM_EABI_URL TOOLCHAIN_ARM_EABI_SHA256; do
    [ -n "${!v:-}" ] || { echo "ERROR: $v not set in $TC_ENV" >&2; exit 1; }
done

# --- build context ----------------------------------------------------------
# The Dockerfile only reads tools/nix + the toolchain args, so the whole
# repo is the context (small) with .dockerignore trimming the fat.
TAG="shu-sdk:build-$(git rev-parse --short HEAD 2>/dev/null || echo dev)"

echo ">>> building $TAG"
docker build \
    --build-arg "TOOLCHAIN_ARMHF_URL=$TOOLCHAIN_ARMHF_URL" \
    --build-arg "TOOLCHAIN_ARMHF_SHA256=$TOOLCHAIN_ARMHF_SHA256" \
    --build-arg "TOOLCHAIN_ARM_EABI_URL=$TOOLCHAIN_ARM_EABI_URL" \
    --build-arg "TOOLCHAIN_ARM_EABI_SHA256=$TOOLCHAIN_ARM_EABI_SHA256" \
    -f tools/docker/Dockerfile \
    -t "$TAG" \
    "$SDK_ROOT"

ID=$(docker inspect --format '{{.Id}}' "$TAG")
echo ">>> built $TAG ($ID)"

# Record the exact inputs for the release manifest.
NIX_TOOLS=$(docker run --rm "$TAG" bash -c 'ls -d /nix/store/*-shu-sdk-tools | head -1')
NIX_HASH=$(basename "$NIX_TOOLS" | cut -d- -f1)
{
    echo "SDK_IMAGE=$TAG"
    echo "SDK_IMAGE_SHA256=$ID"
    echo "SDK_TOOL_SHA256=make=${NIX_HASH} armhf=${TOOLCHAIN_ARMHF_SHA256} eabi=${TOOLCHAIN_ARM_EABI_SHA256}"
} > tools/docker/container.env
cat > tools/docker/image.info <<EOF
IMAGE=$TAG
IMAGE_ID=$ID
EOF
echo ">>> image info written to tools/docker/image.info"
echo ">>> container env written to tools/docker/container.env"
