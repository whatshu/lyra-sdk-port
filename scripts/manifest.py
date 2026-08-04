"""Release manifest generation.

Records every vendored component's git commit, the product manifest
commit, build environment facts (container image, toolchains, host
tools) and the sha256 of every produced artifact.  Emitted as XML so
releases can be diffed and archived programmatically.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import subprocess
import time
from pathlib import Path
from xml.dom import minidom
from xml.etree import ElementTree as ET

from .util import SDK_ROOT, run, warn


def git_commit(path: Path) -> str:
    try:
        r = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"],
                           capture_output=True, text=True, check=True)
        return r.stdout.strip()
    except Exception:
        return ""


def git_describe(path: Path) -> str:
    try:
        r = subprocess.run(["git", "-C", str(path), "describe",
                            "--always", "--tags", "--dirty"],
                           capture_output=True, text=True, check=True)
        return r.stdout.strip()
    except Exception:
        return git_commit(path)


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_status(ctx) -> ET.Element:
    """Snapshot of the product manifest + all vendored submodules."""
    root = ET.Element("repos")

    m = ET.SubElement(root, "repo")
    m.set("name", "product-manifest")
    m.set("path", ".")
    m.set("commit", git_commit(SDK_ROOT))
    m.set("describe", git_describe(SDK_ROOT))

    sub = subprocess.run(
        ["git", "-C", str(SDK_ROOT), "submodule", "status"],
        capture_output=True, text=True).stdout
    for line in sub.splitlines():
        if not line.strip():
            continue
        flag = line[0] if line[0] in "-+U" else ""
        parts = line[1:].split()
        if len(parts) < 2:
            continue
        commit, rel = parts[0], parts[1]
        repo = ET.SubElement(root, "repo")
        repo.set("name", rel)
        repo.set("path", rel)
        repo.set("commit", commit)
        repo.set("flag", flag)
        abs_p = SDK_ROOT / rel
        repo.set("describe", git_describe(abs_p) if abs_p.exists() else "")
        repo.set("dirty", str(has_dirty(abs_p)).lower())
    return root


def has_dirty(path: Path) -> bool:
    if not path.is_dir():
        return False
    r = subprocess.run(["git", "-C", str(path), "status", "--porcelain"],
                       capture_output=True, text=True)
    return bool(r.stdout.strip())


def env_facts(ctx) -> ET.Element:
    root = ET.Element("environment")
    root.set("host", platform.platform())
    root.set("python", platform.python_version())

    def kv(key: str, value: str, **attrs):
        el = ET.SubElement(root, "var")
        el.set("name", key)
        el.set("value", value)
        for k, v in attrs.items():
            el.set(k, v)

    kv("container_image", os.environ.get("SDK_IMAGE", ""))
    kv("container_image_sha256", os.environ.get("SDK_IMAGE_SHA256", ""))
    kv("board", ctx.target)
    kv("mode", ctx.mode)
    kv("uname", os.uname().nodename)
    kv("cpu_count", str(os.cpu_count() or 0))

    # host tool hashes baked into the image (set by the container entrypoint)
    tools = os.environ.get("SDK_TOOL_SHA256", "")
    if tools:
        for entry in tools.split():
            if "=" in entry:
                h, name = entry.split("=", 1)
                kv(f"tool:{name}", h)
    return root


def build_manifest(ctx, artifacts: list[Path]) -> str:
    top = ET.Element("release")
    top.set("name", ctx.target)
    top.set("time", time.strftime("%Y-%m-%dT%H:%M:%S%z"))
    top.set("generated-by", "shu-sdk build system")
    top.set("schema-version", "1.0")

    fw = ET.SubElement(top, "firmware")
    fw.set("board", ctx.board.get("BOARD"))
    fw.set("storage", ctx.board.get("STORAGE"))
    fw.set("chip", ctx.board.get("CHIP"))
    fw.set("chip_variant", ctx.board.get("CHIP_VARIANT"))
    fw.set("kernel_dts", ctx.board.get("KERNEL_DTS"))
    fw.set("parameter", ctx.board.get("PARAMETER"))

    top.append(git_status(ctx))
    top.append(env_facts(ctx))

    files = ET.SubElement(top, "artifacts")
    for p in sorted(artifacts):
        if not p.is_file():
            continue
        el = ET.SubElement(files, "file")
        el.set("name", p.name)
        el.set("size", str(p.stat().st_size))
        el.set("sha256", file_sha256(p))

    raw = ET.tostring(top, encoding="unicode")
    return minidom.parseString(raw).toprettyxml(indent="  ")


def write_manifest(xml: str, dest: Path) -> None:
    dest.write_text(xml)
