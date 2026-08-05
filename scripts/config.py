"""Board configuration loading.

Board configs live in config/boards/<target>.mk and use a simple
`KEY := value` / `KEY = value` format (also readable by bash). This
module parses them into a dict and normalises values.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from util import die, info

_KEY_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?::=|\+=|==|\?=|=\?)\s*(.*)$")


class BoardConfig:
    def __init__(self, data: dict[str, str]):
        self.data = data

    def get(self, key: str, default: str = "") -> str:
        return self.data.get(key, default)

    def getbool(self, key: str, default: bool = False) -> bool:
        v = self.data.get(key, "").strip()
        if not v:
            return default
        return v.lower() in ("y", "yes", "true", "1", "on")

    def __getitem__(self, key: str) -> str:
        return self.data[key]

    def __contains__(self, key: str) -> bool:
        return key in self.data

    def keys(self):
        return self.data.keys()

    def to_env(self) -> dict[str, str]:
        """Environment representation for stage run.sh scripts."""
        return self.data.copy()


def parse_mk(path: Path) -> dict[str, str]:
    """Parse a simple .mk file into a dict of KEY -> VALUE."""
    data: dict[str, str] = {}
    if not path.exists():
        return data
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].rstrip()
            if not line.strip():
                continue
            m = _KEY_RE.match(line)
            if not m:
                continue
            key, value = m.group(1), m.group(2).strip()
            value = value.strip('"').strip("'")
            data[key] = value
    return data


def load_board(root: Path, target: str) -> BoardConfig:
    cfg_path = root / "config" / "boards" / f"{target}.mk"
    if not cfg_path.exists():
        die(f"Unknown board target '{target}': {cfg_path} not found.\n"
            f"Available targets: {list_boards(root)}")
    data = parse_mk(cfg_path)
    # defaults
    data.setdefault("BOARD", target)
    data.setdefault("CHIP", "rk3506")
    data.setdefault("STORAGE", "sdmmc")
    return BoardConfig(data)


def list_boards(root: Path) -> list[str]:
    d = root / "config" / "boards"
    if not d.exists():
        return []
    return sorted(p.stem for p in d.glob("*.mk"))
