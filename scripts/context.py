"""Build context: resolves paths, toolchains and environment shared by stages."""

from __future__ import annotations

import os
from pathlib import Path

from config import BoardConfig, load_board, list_boards
from util import SDK_ROOT, die, warn

TOOLCHAIN_ARMHF = "gcc-arm-10.3-2021.07-x86_64-arm-none-linux-gnueabihf"
TOOLCHAIN_ARM_EABI = "gcc-arm-none-eabi-10-2020-q4-major-x86_64-linux"
# Official Luckfox pico (RV1106/RV1103) uclibc toolchain, used by boards
# with TOOLCHAIN := rockchip830 in their config.
TOOLCHAIN_ROCKCHIP830 = "arm-rockchip830-linux-uclibcgnueabihf"


class Context:
    def __init__(self, target: str, mode: str):
        self.root = SDK_ROOT
        self.target = target
        self.mode = mode  # "build" | "release" | "stage"
        self.board = load_board(self.root, target)
        # Boards select their vendor tree with VENDOR (default rockchip);
        # pico boards live under vendor/pico/.
        self.vendor = self.root / "vendor" / self.board.get("VENDOR", "rockchip")

        self.out = self.root / "out"
        self.fw = self.out / "firmware"
        self.log_dir = self.out / "log"
        self.cache = self.root / "cache"
        self.release = self.root / "RELEASE"

        # toolchains (mounted/baked in the container)
        self.toolchain_root = Path(os.environ.get("SDK_TOOLCHAIN",
                                                  str(self.root / "tools" / "toolchains")))
        self.tc_armhf = self.toolchain_root / TOOLCHAIN_ARMHF
        self.tc_arm_eabi = self.toolchain_root / TOOLCHAIN_ARM_EABI
        self.tc_rockchip830 = self.toolchain_root / TOOLCHAIN_ROCKCHIP830

        self.kernel = self.vendor / "kernel"
        self.uboot = self.vendor / "u-boot"
        self.buildroot = self.vendor / "buildroot"
        self.rkbin = self.vendor / "rkbin"

    def _selected_tc(self):
        """Toolchain root selected by the board's TOOLCHAIN variable."""
        if self.board.get("TOOLCHAIN", "armhf") == "rockchip830":
            return self.tc_rockchip830
        return self.tc_armhf

    # ---- paths -----------------------------------------------------------
    def check_vendor(self) -> None:
        missing = []
        for name in ("uboot", "kernel", "buildroot", "rkbin"):
            d = getattr(self, name)
            if not d.is_dir():
                missing.append(str(d.relative_to(self.root)))
        if missing:
            die("vendored components missing; run `make setup` first.\n"
                "  Missing: " + ", ".join(missing))

    def check_toolchain(self) -> None:
        tc = self._selected_tc()
        prefix = ("arm-rockchip830-linux-uclibcgnueabihf"
                  if tc == self.tc_rockchip830
                  else "arm-none-linux-gnueabihf")
        gcc = tc / "bin" / f"{prefix}-gcc"
        if not gcc.exists():
            die(f"ARM toolchain not found at {gcc}. "
                f"Set SDK_TOOLCHAIN or run `make docker-image`.")

    # ---- environment -----------------------------------------------------
    def stage_env(self, stage: str, full: bool) -> dict[str, str]:
        """Environment exported to a stage's run.sh."""
        tc = self._selected_tc() / "bin"
        env = {
            "SDK_ROOT": str(self.root),
            "OUT_DIR": str(self.out),
            "FW_DIR": str(self.fw),
            "VENDOR_DIR": str(self.vendor),
            "STAGE": stage,
            "FULL": "1" if full else "0",
            "TARGET": self.target,
            "NPROC": str(max(1, os.cpu_count() or 1)),
            # buildroot uses BR2_DL_DIR for offline cache
            "BR2_DL_DIR": str(self.cache / "buildroot-dl"),
            "PATH": (str(tc) + os.pathsep + os.environ.get("PATH", "")),
        }
        env.update(self.board.to_env())
        return env

    def toolchain_env(self) -> dict[str, str]:
        tc = self._selected_tc()
        if tc == self.tc_rockchip830:
            prefix = str(tc / "bin" / "arm-rockchip830-linux-uclibcgnueabihf-")
        else:
            prefix = str(tc / "bin" / "arm-none-linux-gnueabihf-")
        return {
            "CROSS_COMPILE": prefix,
            "TOOLCHAIN_PREFIX": prefix,
            "TOOLCHAIN_ARMHF": str(self.tc_armhf),
            "TOOLCHAIN_ARM_EABI": str(self.tc_arm_eabi),
            "TC_ROCKCHIP830": str(self.tc_rockchip830),
        }

    def ensure_dirs(self) -> None:
        for d in (self.out, self.fw, self.log_dir, self.cache,
                  self.release):
            d.mkdir(parents=True, exist_ok=True)
