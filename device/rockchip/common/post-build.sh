#!/usr/bin/env bash
# Minimal replacement for the official SDK's device/rockchip post-build
# chain.  This is the hook that buildroot's
# board/rockchip/common/post-build.sh calls into (it is referenced by the
# relative path "../device/rockchip/common/post-build.sh" from the vendored
# buildroot tree).  All real work lives in product/platform/rootfs/.
#
# Invoked as:  post-build.sh <rootfs-target-dir> <defconfig-basename>
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "$(realpath "$0")")/../../.." && pwd)"
TARGET_DIR="$(realpath "$1")"

exec "$SDK_ROOT/product/platform/rootfs/post-rootfs.sh" \
    "$TARGET_DIR" "$SDK_ROOT"
