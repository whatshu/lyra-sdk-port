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
        check: bool = True, capture: bool = False, timeout: int | None = None):
    """Run a command, streaming output by default."""
    full_env = os.environ.copy()
    if env:
        full_env.update(env)
    info("+ " + " ".join(str(c) for c in cmd))
    try:
        r = subprocess.run([str(c) for c in cmd], cwd=str(cwd or SDK_ROOT),
                           env=full_env, check=False, capture_output=capture,
                           timeout=timeout)
    except subprocess.TimeoutExpired as e:
        die(f"command timed out after {timeout}s: {' '.join(map(str, cmd))}")
    if check and r.returncode != 0:
        if capture:
            sys.stderr.write(r.stdout.decode(errors="replace"))
            sys.stderr.write(r.stderr.decode(errors="replace"))
        die(f"command failed ({r.returncode}): {' '.join(map(str, cmd))}")
    return r
