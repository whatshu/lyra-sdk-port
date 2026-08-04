#!/usr/bin/env bash
# Export / import the pinned nix toolchain store to tools/nix/cache/.
#
# This is the persistent nix cache: even if cache.nixos.org or nixpkgs
# disappears, the exact store can be restored offline with --import.
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="$SDK_ROOT/tools/nix/cache"

case "${1:-export}" in
    export)
        TOOLS="$(ls -d /nix/store/*-shu-sdk-tools | head -1)"
        [ -n "$TOOLS" ] || { echo "tools not built" >&2; exit 1; }
        mkdir -p "$CACHE"
        echo ">>> exporting closure of $TOOLS"
        nix-store --export $(nix-store -qR "$TOOLS") > "$CACHE/store.closure"
        echo ">>> wrote $CACHE/store.closure ($(du -h "$CACHE/store.closure" | cut -f1))"
        ;;
    import)
        [ -f "$CACHE/store.closure" ] || { echo "no cache yet" >&2; exit 1; }
        echo ">>> importing nix store from cache"
        nix-store --import < "$CACHE/store.closure"
        ;;
    *) echo "usage: $0 export|import" >&2; exit 1 ;;
esac
