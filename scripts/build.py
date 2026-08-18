#!/usr/bin/env python3
"""shu-sdk build orchestrator.

Run from the SDK root (typically inside the build container):

    build.py build   --board <target>   # full build, volatile out/
    build.py release --board <target>   # full build + save to RELEASE/
    build.py stage   --board <target> <stage...>   # partial build
    build.py list-stages
    build.py list-boards
    build.py clean

The Makefile at the top level wraps this.  Stages are managed here in
Python; per-stage recipes are bash scripts under stages/.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path

# Allow running as `./scripts/build.py` (not just `python3 -m scripts.build`).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from config import list_boards
from context import Context
from engine import load_stages, order_stages, run_stages
from release import collect_firmware, make_release_dir
from util import SDK_ROOT, die, info, notice

ALL_STAGES = ["uboot", "kernel", "rootfs", "firmware"]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="build.py",
                                 description="shu-sdk build orchestrator")
    sub = ap.add_subparsers(dest="command", required=True, metavar="COMMAND")

    for name, help_ in (("build", "full build into volatile out/"),
                        ("release", "full build + save to RELEASE/")):
        p = sub.add_parser(name, help=help_)
        p.add_argument("--board", default="lyra-ultra-w-emmc",
                       help="board target (config/boards/<target>.mk)")
    p_stage = sub.add_parser("stage", help="build one or more stages only")
    p_stage.add_argument("--board", default="lyra-ultra-w-emmc",
                         help="board target (config/boards/<target>.mk)")
    p_stage.add_argument("stages", nargs="+", help="stage names")
    sub.add_parser("list-stages", help="list stages")
    sub.add_parser("list-boards", help="list board targets")
    sub.add_parser("clean", help="remove out/")

    args = ap.parse_args(argv)
    args.board = getattr(args, "board", "lyra-ultra-w-emmc")

    root = SDK_ROOT

    if args.command == "list-boards":
        for b in list_boards(root):
            print(b)
        return 0

    stages = load_stages(root)
    if args.command == "list-stages":
        for s in order_stages(stages):
            print(f"{s.name:12} {s.description}")
        return 0

    if args.command == "clean":
        ctx = Context(args.board, "build")
        if (ctx.out / "firmware").exists():
            shutil.rmtree(ctx.out)
        info(f"cleaned {ctx.out}")
        return 0

    ctx = Context(args.board, args.command)
    ctx.check_vendor()
    ctx.check_toolchain()

    if args.command == "stage":
        if not args.stages:
            die("`stage` requires at least one stage name")
        ctx.ensure_dirs()
        run_stages(ctx, stages, names=args.stages, full=False)
        return 0

    # full build: clean the volatile out/ then run everything
    ctx.ensure_dirs()
    if (ctx.out / "firmware").exists():
        shutil.rmtree(ctx.out / "firmware")
    (ctx.out / "firmware").mkdir(parents=True, exist_ok=True)

    run_stages(ctx, stages, names=None, full=True)

    # sanity: firmware was produced.  The exact set is board-defined (REQUIRED
    # in the board config); pico boards need download.bin/idblock.img/env.img
    # and the oem/userdata images instead of MiniLoaderAll.bin/parameter.txt.
    fw = ctx.fw
    required = ctx.board.get("REQUIRED", "MiniLoaderAll.bin uboot.img boot.img rootfs.img").split()
    for name in required:
        if not (fw / name).exists():
            die(f"full build finished but {name} is missing from out/firmware")

    notice("===== full build OK =====")
    for f in sorted(fw.iterdir()):
        if f.is_file() or f.is_symlink():
            notice(f"  out/firmware/{f.name}")

    if args.command == "release":
        artifacts = collect_firmware(ctx)
        release_dir = make_release_dir(ctx, artifacts)
        notice(f"===== release saved to {release_dir} =====")
    return 0


if __name__ == "__main__":
    sys.exit(main())
