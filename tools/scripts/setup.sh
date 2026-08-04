#!/usr/bin/env bash
# Host-side setup: (re)sync the vendored component git submodules.
#
# The submodules point at our pinned mirrors of the Luckfox SDK component
# repos (whatshu/lyra-*).  Full history is retained; the exact revision
# used by the manifest is recorded in .gitmodules.
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SDK_ROOT"

git submodule sync --recursive
git submodule update --init --recursive --depth 1 || \
    git submodule update --init --recursive

echo ">>> submodules:"
git submodule status
echo ">>> vendored components ready"
