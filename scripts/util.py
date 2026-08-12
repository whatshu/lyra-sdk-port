"""Small shared helpers for the build scripts."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

SDK_ROOT = Path(__file__).resolve().parent.parent


def _color(code: int, s: str) -> str:
    if not sys.stdout.isatty():
        return s
    return f"\033[{code}m{s}\033[0m"


def info(s: str) -> None:
    print(_color(36, f"[build] {s}"))


def notice(s: str) -> None:
    print(_color(35, f"[build] {s}"))


def warn(s: str) -> None:
    print(_color(33, f"[build] WARN: {s}"))


def die(s: str, code: int = 1) -> None:
    print(_color(31, f"[build] ERROR: {s}"), file=sys.stderr)
    sys.exit(code)


def run(cmd, *, cwd: Path | None = None, env: dict | None = None,
        check: bool = True, capture: bool = False, timeout: int | None = None,
        log_to: Path | None = None):
    """Run a command, streaming output by default; optionally tee to log_to.

    Stage output is shown live on the terminal *and* written to the stage
    log file, so a failing build is immediately visible.  When `capture`
    is set the output is collected instead and returned on the result.
    """
    full_env = os.environ.copy()
    if env:
        full_env.update(env)
    info("+ " + " ".join(str(c) for c in cmd))
    argv = [str(c) for c in cmd]

    if capture:
        kwargs = dict(check=False, timeout=timeout, env=full_env)
        kwargs["capture_output"] = True
        try:
            r = subprocess.run(argv, cwd=str(cwd or SDK_ROOT), **kwargs)
        except subprocess.TimeoutExpired as e:
            die(f"command timed out after {timeout}s: {' '.join(map(str, cmd))}")
        if check and r.returncode != 0:
            sys.stderr.write(r.stdout.decode(errors="replace"))
            sys.stderr.write(r.stderr.decode(errors="replace"))
            die(f"command failed ({r.returncode}): {' '.join(map(str, cmd))}")
        return r

    # Stream to the terminal live, and additionally tee into the stage log
    # file when requested (the default for build stages).  PYTHONUNBUFFERED
    # is set in the container so build output appears without buffering.
    logf = None
    if log_to is not None:
        log_to.parent.mkdir(parents=True, exist_ok=True)
        logf = open(log_to, "ab")
    try:
        p = subprocess.Popen(
            argv, cwd=str(cwd or SDK_ROOT), env=full_env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        assert p.stdout is not None
        for line in iter(p.stdout.readline, b""):
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
            if logf is not None:
                logf.write(line)
                logf.flush()
        rc = p.wait(timeout=timeout)
    except subprocess.TimeoutExpired as e:
        if "p" in locals():
            p.kill()
        die(f"command timed out after {timeout}s: {' '.join(map(str, cmd))}")
    finally:
        if logf is not None:
            logf.close()
    if check and rc != 0:
        die(f"command failed ({rc}): {' '.join(map(str, cmd))}")
    return p
