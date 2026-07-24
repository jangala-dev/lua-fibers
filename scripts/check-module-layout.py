#!/usr/bin/env python3
"""Reject module layouts that are ambiguous across Lua and Luau."""

from __future__ import annotations

import argparse
from pathlib import Path


def check_root(root: Path, extensions: tuple[str, ...]) -> list[str]:
    errors: list[str] = []

    for extension in extensions:
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



def check_fibers_ownership(root: Path) -> list[str]:
    errors: list[str] = []
    fibers = root / "fibers"
    if not fibers.is_dir():
        return errors

    internal = fibers / "internal"
    if internal.is_dir():
        allowed = {internal / "protected.lua", internal / "kernel"}
        for child in sorted(internal.iterdir()):
            if child not in allowed:
                errors.append(
                    f"{child} has no global internal owner; move it to its semantic subsystem"
                )

    forbidden = [
        fibers / "flow.lua",
        fibers / "queue.lua",
        fibers / "scalar.lua",
        fibers / "resource" / "init.lua",
        fibers / "runner.lua",
    ]
    for path in forbidden:
        if path.exists():
            errors.append(f"deprecated duplicate public path exists: {path}")

    return errors

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("roots", nargs="+", type=Path)
    args = parser.parse_args()

    errors: list[str] = []
    for root in args.roots:
        if not root.is_dir():
            errors.append(f"module root does not exist: {root}")
            continue
        errors.extend(check_root(root, (".lua", ".luau")))
        errors.extend(check_fibers_ownership(root))

    if errors:
        print("ambiguous module layout:")
        for error in errors:
            print(f"  {error}")
        return 1

    print("module layout: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
