"""Stage engine.

Stages are declared as directories stages/NN-name/ containing a
stage.yaml manifest and (optionally) a bash run.sh.  Python owns the
stage lifecycle (discovery, ordering, dependency resolution, config
override, environment, result tracking); bash runs the actual build
recipe inside each stage.

For a *full* build every stage is run in dependency order and the
centralised configs in product/platform/configs/<component>/ (plus
product/custom/<component>/) are copied over the vendor trees, so any
hand-tuned temp config is reset.  For a *partial* build only the named
stages run and temp configs are left untouched.
"""

from __future__ import annotations

import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from .util import SDK_ROOT, die, info, notice, run, warn


@dataclass
class ConfigOverride:
    source: str  # repo-relative dir with the centralised configs
    dest: str    # repo-relative dir to copy into (the vendor tree)
    dest_ok_missing: bool = False


@dataclass
class Stage:
    name: str
    description: str = ""
    needs: list[str] = field(default_factory=list)
    run: Optional[str] = None
    config: Optional[ConfigOverride] = None


class StageError(Exception):
    pass


def _parse_yaml_lite(path: Path) -> dict:
    """A deliberately tiny YAML-subset parser for stage.yaml.

    Only supports flat mappings and list values written as
    `  - item`.  Keeps the engine dependency-free.
    """
    out: dict = {}
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].rstrip()
            if not line.strip():
                continue
            if line.startswith(("  ", "\t")):
                k = out.get("__last__")
                if k is not None and isinstance(out.get(k), list):
                    out[k].append(line.strip()[2:].strip())
                continue
            if ":" in line:
                k, v = line.split(":", 1)
                k = k.strip()
                v = v.strip()
                out["__last__"] = k
                out[k] = [] if v == "" else v
    out.pop("__last__", None)
    return out


def load_stages(root: Path) -> list[Stage]:
    stages_dir = root / "stages"
    stages: list[Stage] = []
    for d in sorted(stages_dir.glob("[0-9][0-9]-*")):
        yaml_path = d / "stage.yaml"
        if not yaml_path.exists():
            continue
        m = _parse_yaml_lite(yaml_path)
        name = m.get("name") or d.name.split("-", 1)[1]
        cfg = m.get("config") or {}
        config = None
        if cfg:
            config = ConfigOverride(
                source=cfg.get("source", ""),
                dest=cfg.get("dest", ""),
                dest_ok_missing=cfg.get("dest_ok_missing", "false") == "true",
            )
        stages.append(Stage(
            name=name,
            description=m.get("description", ""),
            needs=m.get("needs", []),
            run=m.get("run"),
            config=config,
        ))
    return stages


def order_stages(stages: list[Stage]) -> list[Stage]:
    """Topological sort of the stage graph (stable, needs-first)."""
    by_name = {s.name: s for s in stages}
    result: list[Stage] = []
    visited: set[str] = set()

    def visit(s: Stage, chain: list[str]) -> None:
        if s.name in visited:
            return
        if s.name in chain:
            die("circular stage dependency: " + " -> ".join(chain + [s.name]))
        for n in s.needs:
            if n not in by_name:
                warn(f"stage '{s.name}' needs unknown stage '{n}', ignoring")
                continue
            visit(by_name[n], chain + [s.name])
        visited.add(s.name)
        result.append(s)

    for s in stages:
        visit(s, [])
    return result


def _apply_config_override(stage: Stage, root: Path) -> None:
    src = root / stage.config.source
    dst = root / stage.config.dest
    if not src.is_dir():
        return
    if not dst.is_dir():
        if stage.config.dest_ok_missing:
            return
        dst.mkdir(parents=True, exist_ok=True)
    notice(f"[{stage.name}] overriding config: {stage.config.dest}")
    for f in src.iterdir():
        if f.is_file():
            shutil.copy2(f, dst / f.name)


def _stage_dir(root: Path, stage: Stage) -> Path:
    for d in sorted((root / "stages").glob("[0-9][0-9]-*")):
        yaml_path = d / "stage.yaml"
        if not yaml_path.exists():
            continue
        if _parse_yaml_lite(yaml_path).get("name") == stage.name:
            return d
    die(f"stage '{stage.name}': directory not found")


def run_stage(stage: Stage, ctx, full: bool) -> None:
    notice(f"===== stage: {stage.name} — {stage.description} =====")
    if full and stage.config:
        _apply_config_override(stage, ctx.root)

    if not stage.run:
        return
    stage_dir = _stage_dir(ctx.root, stage)
    run_script = stage_dir / stage.run
    if not run_script.exists():
        die(f"stage '{stage.name}': run script '{stage.run}' not found")
    env = ctx.stage_env(stage.name, full)
    env.update(ctx.toolchain_env())
    run(["bash", str(run_script)], cwd=ctx.root, env=env)


def run_stages(ctx, stages: list[Stage], names: Optional[list[str]],
               full: bool) -> None:
    ordered = order_stages(stages)
    if names:
        wanted = [s for s in ordered if s.name in names]
        if len(wanted) != len(names):
            have = {s.name for s in ordered}
            die("unknown stage(s): " + ", ".join(set(names) - have))
        targets = wanted
    else:
        targets = ordered

    for stage in targets:
        run_stage(stage, ctx, full)
