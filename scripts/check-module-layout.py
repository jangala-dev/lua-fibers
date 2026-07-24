#!/usr/bin/env python3
"""Check canonical Fibers module ownership and cross-runtime layout."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

REQUIRE_RE = re.compile(r"\brequire\s*(?:\(\s*)?(['\"])(fibers(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\1")

REQUIRED_PATHS = (
    "src/fibers/init.lua",
    "src/fibers/op.lua",
    "src/fibers/runtime.lua",
    "src/fibers/task.lua",
    "src/fibers/perform.lua",
    "src/fibers/policy.lua",
    "src/fibers/channel.lua",
    "src/fibers/mailbox.lua",
    "src/fibers/pulse.lua",
    "src/fibers/sleep.lua",
    "src/fibers/stream.lua",
    "src/fibers/file/init.lua",
    "src/fibers/process/init.lua",
    "src/fibers/socket/init.lua",
    "src/fibers/diagnostics/io.lua",
    "src/fibers/diagnostics/search.lua",
    "src/fibers/effect.lua",
    "src/fibers/region/init.lua",
    "src/fibers/region/settlement.lua",
    "src/fibers/region/adoption.lua",
    "src/fibers/resource/flow/init.lua",
    "src/fibers/resource/flow/errors.lua",
    "src/fibers/resource/flow/rope.lua",
    "src/fibers/resource/queue.lua",
    "src/fibers/resource/scalar.lua",
    "src/fibers/resource/completion.lua",
    "src/fibers/resource/rendezvous.lua",
    "src/fibers/resource/counter.lua",
    "src/fibers/resource/index.lua",
    "src/fibers/resource/keyed.lua",
    "src/fibers/resource/lease.lua",
    "src/fibers/resource/authoring.lua",
    "src/fibers/resource/signal.lua",
    "src/fibers/resource/event_queue.lua",
    "src/fibers/resource/clock.lua",
    "src/fibers/host/init.lua",
    "src/fibers/host/external.lua",
    "src/fibers/host/readiness.lua",
    "src/fibers/scope/init.lua",
    "src/fibers/internal/protected.lua",
    "src/fibers/internal/kernel/machine.lua",
    "src/fibers/internal/kernel/ledger.lua",
    "src/fibers/internal/kernel/algebra.lua",
    "src/fibers/internal/kernel/domain.lua",
    "src/fibers/internal/kernel/certificate.lua",
    "src/fibers/internal/kernel/dependencies.lua",
    "src/fibers/internal/kernel/ir.lua",
    "src/fibers/internal/kernel/path.lua",
    "src/fibers/internal/kernel/search_session.lua",
    "src/fibers/internal/kernel/supply.lua",
    "src/fibers/internal/kernel/trail.lua",
    "reference/fibers/internal/reference_machine.lua",
    "tests/groups.lua",
    "tests/profiles.lua",
    "tests/luau/profile.json",
    "scripts/build-luau.py",
    "scripts/check-links.lua",
    "scripts/check-test-layout.lua",
    "scripts/check-lua-syntax.lua",
)

FORBIDDEN_PATHS = (
    "src/fibers.lua",
    "src/fibers/atoms.lua",
    "src/fibers/atoms",
    "src/fibers/kernel.lua",
    "src/fibers/kernel",
    "src/fibers/flow.lua",
    "src/fibers/flow",
    "src/fibers/queue.lua",
    "src/fibers/scalar.lua",
    "src/fibers/resource/init.lua",
    "src/fibers/runner.lua",
    "src/fibers/lifetime",
    "src/fibers/external",
    "src/fibers/internal/reference_machine.lua",
    "src/fibers/internal/ledger_kernel",
)

SCAN_DIRS = ("src", "reference", "examples", "experiments", "performance", "tests", "scripts")
SCAN_EXCLUSIONS = {Path("tests/public/test_public_surface.lua")}


def repository_root(path: Path) -> Path:
    path = path.resolve()
    if (path / "src" / "fibers").is_dir():
        return path
    if path.name == "src" and (path / "fibers").is_dir():
        return path.parent
    raise ValueError(f"repository root not found from {path}")


def module_name(path: Path, root: Path) -> str:
    rel = path.relative_to(root)
    parts = rel.parent.parts if rel.name == "init.lua" else rel.with_suffix("").parts
    return ".".join(parts)


def source_modules(repo: Path) -> tuple[dict[str, Path], list[str]]:
    modules: dict[str, Path] = {}
    errors: list[str] = []
    for root in (repo / "src", repo / "reference"):
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.lua")):
            name = module_name(path, root)
            previous = modules.get(name)
            if previous is not None:
                errors.append(f"duplicate module {name}: {previous} and {path}")
            else:
                modules[name] = path
    return modules, errors


def check_unambiguous(root: Path) -> list[str]:
    errors: list[str] = []
    for extension in (".lua", ".luau"):
        for module_file in sorted(root.rglob(f"*{extension}")):
            if module_file.name == f"init{extension}":
                continue
            module_dir = module_file.with_suffix("")
            if module_dir.is_dir():
                errors.append(f"{module_file} conflicts with {module_dir}/")
    for lua_file in sorted(root.rglob("*.lua")):
        luau_file = lua_file.with_suffix(".luau")
        if luau_file.is_file():
            errors.append(f"{lua_file} conflicts with {luau_file}")
    for init_lua in sorted(root.rglob("init.lua")):
        init_luau = init_lua.with_name("init.luau")
        if init_luau.is_file():
            errors.append(f"{init_lua} conflicts with {init_luau}")
    return errors


def check_internal_ownership(repo: Path) -> list[str]:
    errors: list[str] = []
    internal = repo / "src" / "fibers" / "internal"
    if not internal.is_dir():
        return [f"missing global internal directory: {internal}"]
    allowed = {internal / "protected.lua", internal / "kernel"}
    for child in sorted(internal.iterdir()):
        if child not in allowed:
            errors.append(f"{child} has no global internal owner")
    return errors


def check_paths(repo: Path) -> list[str]:
    errors: list[str] = []
    for relative in REQUIRED_PATHS:
        if not (repo / relative).exists():
            errors.append(f"required repository path is missing: {relative}")
    for relative in FORBIDDEN_PATHS:
        if (repo / relative).exists():
            errors.append(f"deprecated or ambiguous repository path exists: {relative}")
    return errors


def check_static_imports(repo: Path, modules: dict[str, Path]) -> list[str]:
    errors: list[str] = []
    for directory in SCAN_DIRS:
        root = repo / directory
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.lua")):
            relative = path.relative_to(repo)
            if relative in SCAN_EXCLUSIONS:
                continue
            text = path.read_text(encoding="utf-8")
            for match in REQUIRE_RE.finditer(text):
                dependency = match.group(2)
                if dependency not in modules:
                    line = text.count("\n", 0, match.start()) + 1
                    errors.append(f"{relative}:{line}: unresolved Fibers module {dependency}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".", type=Path)
    args = parser.parse_args()

    try:
        repo = repository_root(args.root)
    except ValueError as error:
        print(f"repository layout error:\n  {error}")
        return 1

    modules, errors = source_modules(repo)
    errors.extend(check_unambiguous(repo / "src"))
    if (repo / "reference").is_dir():
        errors.extend(check_unambiguous(repo / "reference"))
    errors.extend(check_internal_ownership(repo))
    errors.extend(check_paths(repo))
    errors.extend(check_static_imports(repo, modules))

    if errors:
        print("repository layout errors:")
        for error in errors:
            print(f"  {error}")
        return 1

    print(f"repository layout: ok ({len(modules)} Lua modules)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
