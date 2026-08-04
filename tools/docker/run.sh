#!/usr/bin/env bash
# Runs a command inside the shu-sdk build container.
#
# The SDK root is bind-mounted at /sdk so all build output persists on the
# host.  out/ and cache/ are also volumes so heavy build state survives
# container teardown without polluting the image.
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SDK_ROOT"

INFO="$SDK_ROOT/tools/docker/image.info"
if [ -f "$INFO" ]; then
    . "$INFO"
fi
IMAGE="${IMAGE:-shu-sdk:build}"
# pull once if missing
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo ">>> image $IMAGE not found; building it (first run takes a while)" >&2
    "$SDK_ROOT/tools/docker/build-image.sh"
fi

# Pass through the variables the build scripts hand to the container.
TTY_ARGS=()
[ -t 0 ] && TTY_ARGS+=( -it )

exec docker run "${TTY_ARGS[@]}" --rm \
    -v "$SDK_ROOT":/sdk \
    -v /etc/localtime:/etc/localtime:ro \
    --env-file "$SDK_ROOT/tools/docker/container.env" \
    -w /sdk \
    "$IMAGE" \
    "$@"
