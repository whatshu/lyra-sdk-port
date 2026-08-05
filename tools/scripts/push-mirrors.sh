#!/usr/bin/env bash
# Push the pinned Luckfox component mirrors to GitHub and wire them in as
# git submodules.
#
# The component sources (u-boot, kernel, buildroot, rkbin) are not public
# on GitHub; their canonical mirror lives in the Luckfox SDK snapshot that
# is already on this machine.  This script pushes the *committed* source of
# each component to the corresponding whatshu/lyra-* repo and pins it as a
# submodule so the manifest records the exact revision.
#
# Prerequisite: the 4 GitHub repos exist (whatshu/lyra-{u-boot,kernel,
# buildroot,rkbin}) and this host can push to them over SSH.
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_ROOT="${1:-/home/whatshu/develop/project/luckfox/lyra}"  # workspace SDK
GH="git@github.com:whatshu"

declare -A COMPONENTS=(
    [u-boot]=u-boot
    [kernel]=kernel-6.1
    [buildroot]=buildroot
    [rkbin]=rkbin
)

cd "$SDK_ROOT"

# --- push each component ---------------------------------------------------
for name in u-boot kernel buildroot rkbin; do
    src="$SRC_ROOT/${COMPONENTS[$name]}"
    echo ">>> pushing $name from $src"
    git -C "$src" remote remove github 2>/dev/null || true
    git -C "$src" remote add github "$GH/lyra-$name.git"
    git -C "$src" push -u github main
done

# --- replace the temporary symlinks with real submodules -------------------
for name in u-boot kernel buildroot rkbin; do
    rm -f "vendor/rockchip/$name"
done

for name in u-boot kernel buildroot rkbin; do
    echo ">>> submodule add $GH/lyra-$name.git vendor/rockchip/$name"
    git submodule add "$GH/lyra-$name.git" "vendor/rockchip/$name"
done

git submodule sync
echo ">>> mirrors pushed and wired as submodules:"
git submodule status
echo ">>> remember to commit .gitmodules + the submodule pins"
