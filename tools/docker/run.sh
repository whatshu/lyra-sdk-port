#!/usr/bin/env bash
# Runs a command inside the shu-sdk build container.
#
# The SDK root is bind-mounted at /sdk so all build output persists on the
# host.  out/ and cache/ are also volumes so heavy build state survives
# container teardown without polluting the image.
set -euo pipefail

# A build must never die because its stdout pipe reader went away (a
# command runner tearing down output capture sends SIGPIPE on the next
# write).  Ignore SIGPIPE: a write to a broken pipe then returns EPIPE
# instead of killing us.  We stream through tail below anyway, but this
# makes the whole script immune even when it writes directly.
trap '' SIGPIPE

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
# A TTY is only attached for interactive sessions (make shell / menuconfig);
# for a build we deliberately run without one, so there is no tty to
# detach when docker runs in the background.
TTY_ARGS=()
if [ "${RUN_INTERACTIVE:-0}" = "1" ]; then
    [ -t 0 ] && TTY_ARGS=( -it ) || TTY_ARGS=( -i )
fi

ENV_FILE="$SDK_ROOT/tools/docker/container.env"
ENV_ARGS=()
[ -f "$ENV_FILE" ] && ENV_ARGS+=( --env-file "$ENV_FILE" )

# Forward a host HTTP proxy into the container (host is reachable at the
# docker bridge gateway) so downloads during the build are accelerated.
if [ -n "${ZSH_HTTP_PROXY_URL:-}" ]; then
    GW=$(ip route 2>/dev/null | awk '/docker0/{print $9; exit}')
    if [ -n "$GW" ]; then
        ENV_ARGS+=( -e "http_proxy=${ZSH_HTTP_PROXY_URL/127.0.0.1/$GW}" \
                    -e "https_proxy=${ZSH_HTTP_PROXY_URL/127.0.0.1/$GW}" )
    fi
fi

# python buffers stdout when it is not a tty; the stage logs must stream
# live into the build log, so force unbuffered python in the container.
ENV_ARGS+=( -e PYTHONUNBUFFERED=1 )

# The container ENTRYPOINT is `bash -lc`, so the whole command must arrive
# as a single argument string.
CMD="$*"

# Interactive session (make shell / menuconfig): run docker in the
# foreground attached to the terminal.  No streaming indirection needed.
if [ "${RUN_INTERACTIVE:-0}" = "1" ]; then
    exec docker run "${TTY_ARGS[@]}" --rm \
        -v "$SDK_ROOT":/sdk \
        -v /etc/localtime:/etc/localtime:ro \
        "${ENV_ARGS[@]}" \
        ${SDK_EXTRA_MOUNT:+-v "$SDK_EXTRA_MOUNT":"$SDK_EXTRA_MOUNT"} \
        -w /sdk \
        "$IMAGE" \
        "$CMD"
fi

# Build path: stream docker's output through a temp file (via tail -f)
# instead of letting docker write straight to our stdout pipe.  A long
# build must survive its terminal: if the caller's pipe reader closes
# mid-build (e.g. a command runner tearing down its output capture),
# docker would otherwise die of SIGPIPE and take the build down with it
# (exit 141).
#
# So we run docker in the background writing to a file, and _our own_
# stdout/stderr are pointed at that file too (fd 3 keeps the real
# stdout).  Only the disposable `tail` forwards the file to the real
# stdout: if that pipe is broken, only `tail` dies of SIGPIPE and the
# build keeps going.  `tail -f --pid` exits on its own once docker is
# done, so no output is lost at the tail end.
LOG="$(mktemp "${TMPDIR:-/tmp}/shu-sdk-run.XXXXXX")"
exec 3>&1
exec >"$LOG" 2>&1

docker run --rm \
    -v "$SDK_ROOT":/sdk \
    -v /etc/localtime:/etc/localtime:ro \
    "${ENV_ARGS[@]}" \
    ${SDK_EXTRA_MOUNT:+-v "$SDK_EXTRA_MOUNT":"$SDK_EXTRA_MOUNT"} \
    -w /sdk \
    "$IMAGE" \
    "$CMD" >"$LOG" 2>&1 &
DOCKER_PID=$!

tail -n +1 -f --pid="$DOCKER_PID" "$LOG" >&3 &
TAIL_PID=$!
cleanup() { kill "$TAIL_PID" 2>/dev/null || true; rm -f "$LOG"; }
trap cleanup EXIT

set +e
wait "$DOCKER_PID"
RC=$?
set -e

# let tail flush whatever is still buffered, then stop it
wait "$TAIL_PID" 2>/dev/null || true
cleanup
exit "$RC"
