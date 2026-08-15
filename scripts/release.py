"""Release packaging.

A release is a point-in-time, immutable snapshot of the firmware and
the exact source revisions that produced it.  Releases are stored on
disk under RELEASE/ (not in the volatile out/ tree) and are indexed in
RELEASE/index.xml so CI can discover and archive them.
"""

from __future__ import annotations

import shutil
import subprocess
import tarfile
import time
from pathlib import Path
from xml.etree import ElementTree as ET

from manifest import build_manifest, file_sha256, write_manifest
from util import die, info, notice, warn


def collect_firmware(ctx) -> list[Path]:
    fw = ctx.fw
    if not fw.is_dir():
        die("no firmware to release: out/firmware missing (run a full build first)")
    artifacts = []
    for f in sorted(fw.iterdir()):
        if f.is_file() or f.is_symlink():
            if f.is_symlink():
                if not f.resolve().is_file():
                    warn(f"dangling symlink in firmware dir: {f.name}")
                    continue
                artifacts.append(f.resolve())
            else:
                artifacts.append(f)
    if not artifacts:
        die("no firmware artifacts produced")
    return artifacts


def make_release_dir(ctx, artifacts: list[Path]) -> Path:
    rel = ctx.release
    rel.mkdir(parents=True, exist_ok=True)

    stamp = time.strftime("%Y%m%d-%H%M%S")
    name = f"{ctx.target}-{stamp}"
    # keep the newest N releases, mirroring the SDK's log retention
    existing = sorted(rel.glob(f"{ctx.target}-*"))
    if len(existing) >= 10:
        for stale in existing[: len(existing) - 9]:
            shutil.rmtree(stale, ignore_errors=True)

    release_dir = rel / name
    fw_dir = release_dir / "firmware"
    fw_dir.mkdir(parents=True)

    # hard-copy the artifacts (resolving symlinks)
    copied: list[Path] = []
    for a in artifacts:
        dst = fw_dir / a.name
        shutil.copy2(a, dst)
        copied.append(dst)

    # xz-compress every image so releases are cheap to transfer/archive
    notice("compressing release images with xz ...")
    for p in list(copied):
        xz = fw_dir / f"{p.name}.xz"
        subprocess.run(["xz", "-T0", "-6", "-k", str(p), "-c"],
                       stdout=open(xz, "wb"), check=True)
        copied.append(xz)
    info(f"compressed {len(copied) - len(artifacts)} images to .xz")

    # sha256 sums (includes the .xz copies)
    sums = "\n".join(f"{file_sha256(p)}  {p.name}"
                     for p in sorted(copied)) + "\n"
    (fw_dir / "sha256sums.txt").write_text(sums)

    # xml manifest
    xml = build_manifest(ctx, copied)
    write_manifest(xml, release_dir / "release.xml")

    # human readable metadata
    (release_dir / "firmware.txt").write_text(
        "\n".join(p.name for p in sorted(copied)) + "\n")

    write_release_notes(ctx, release_dir)

    update_index(ctx, release_dir, xml)

    make_flash_tarball(ctx, fw_dir)
    return release_dir


def write_release_notes(ctx, release_dir: Path) -> Path:
    """Write RELEASE_NOTES.md ("what this image does", human-readable) into
    the release directory.

    The body comes from `config/release-notes/<target>.md` so a board can
    carry its own description next to the machinery that ships it.  If the
    template is absent a placeholder pointing at release.xml is written —
    the manifest stays the source of truth for exact revisions.
    """
    notes = release_dir / "RELEASE_NOTES.md"
    tmpl = ctx.root / "config" / "release-notes" / f"{ctx.target}.md"
    if tmpl.is_file():
        notes.write_text(tmpl.read_text().rstrip() + "\n")
        info(f"release notes: {notes.relative_to(ctx.root)}")
    else:
        notes.write_text(
            f"# {ctx.target}\n\n"
            "No `config/release-notes/<target>.md` template yet — see "
            "`release.xml` for the exact source revisions of this image.\n")
        warn(f"no release-notes template for {ctx.target}; wrote placeholder")
    return notes


def make_flash_tarball(ctx, fw_dir: Path) -> Path:
    """Build RELEASE/flash-<target>.tar.gz holding just the latest
    flashable image (update.img.xz), nothing else.

    The tarball is overwritten on every release so it always points at
    the newest firmware; you flash it on a Linux host with
    `xz -d update.img.xz && ./upgrade_tool uf update.img` (or any
    Rockchip download tool).  Upgrade tooling is *not* bundled — that is
    environment-specific and should be installed once on the host.
    """
    tarball = ctx.release / f"flash-{ctx.target}.tar.gz"
    # prefer the compressed all-in-one image; fall back to the raw one
    img = None
    for name in ("update.img.xz", "update.img"):
        cand = fw_dir / name
        if cand.exists():
            img = cand
            break
    if img is None:
        warn("no update.img in release to pack into flash tarball; skipped")
        return tarball
    with tarfile.open(tarball, "w:gz") as tf:
        tf.add(img, arcname=img.name)
    notice(f"flash tarball updated: {tarball} ({img.name})")
    return tarball


def update_index(ctx, release_dir: Path, xml: str) -> None:
    index_path = ctx.release / "index.xml"
    root = ET.Element("releases")
    if index_path.exists():
        try:
            root = ET.parse(index_path).getroot()
        except Exception:
            root = ET.Element("releases")

    rel_xml = ET.fromstring(xml)
    entry = ET.Element("release")
    entry.set("target", ctx.target)
    entry.set("dir", release_dir.name)
    entry.set("time", rel_xml.get("time"))
    # aggregate artifact list
    for art in rel_xml.find("artifacts") or []:
        f = ET.SubElement(entry, "artifact")
        f.set("name", art.get("name"))
        f.set("sha256", art.get("sha256"))
        f.set("size", art.get("size"))
    root.append(entry)

    import xml.dom.minidom
    index_path.write_text(
        xml.dom.minidom.parseString(ET.tostring(root, encoding="unicode"))
        .toprettyxml(indent="  "))
    info(f"index updated: {index_path}")
