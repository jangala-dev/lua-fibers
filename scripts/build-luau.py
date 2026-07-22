#!/usr/bin/env python3
"""Build the portable Fibers source tree for the standalone Luau CLI.

The stock Lua source remains canonical.  This build computes the dependency
closure of the portable public surface, copies it to build/luau, and rewrites
logical Lua module names to Luau aliases.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from collections import deque
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = REPO_ROOT / "src"

# Initial portable surface.  Shared file and process abstractions can enter the
# closure through public modules, but native host providers are not entry points.
PORTABLE_ENTRIES = (
    "fibers",
    "fibers.channel",
    "fibers.flow",
    "fibers.flow.errors",
    "fibers.flow.rope",
    "fibers.host",
    "fibers.host.manual",
    "fibers.host.pure",
    "fibers.mailbox",
    "fibers.op",
    "fibers.perform",
    "fibers.policy",
    "fibers.pulse",
    "fibers.resource.counter",
    "fibers.resource.index",
    "fibers.resource.keyed",
    "fibers.resource.lease",
    "fibers.resource.rendezvous",
    "fibers.runtime",
    "fibers.scalar",
    "fibers.scope",
    "fibers.sleep",
    "fibers.stream",
    "fibers.task",
)

REQUIRE_RE = re.compile(r"\brequire\s*\(\s*(['\"])([^'\"]+)\1\s*\)")
MODULE_STRING_RE = re.compile(r"(['\"])(fibers(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\1")


def module_name(path: Path) -> str:
    rel = path.relative_to(SOURCE_ROOT)
    if rel.name == "init.lua":
        parts = rel.parent.parts
    else:
        parts = rel.with_suffix("").parts
    return ".".join(parts)


def alias_name(name: str) -> str:
    # The alias points at src/fibers, whose package entry point is init.luau.
    # Luau resolves an alias root directly to that init module; spelling the
    # root as @fibers/init incorrectly asks for a child component named init.
    if name == "fibers":
        return "@fibers"
    return "@fibers/" + name.removeprefix("fibers.").replace(".", "/")


def source_modules() -> dict[str, Path]:
    modules: dict[str, Path] = {}
    for path in sorted(SOURCE_ROOT.rglob("*.lua")):
        name = module_name(path)
        if name in modules:
            raise RuntimeError(f"duplicate Lua module {name}: {path} and {modules[name]}")
        modules[name] = path
    return modules


def static_dependencies(text: str, modules: dict[str, Path]) -> set[str]:
    return {match.group(2) for match in REQUIRE_RE.finditer(text) if match.group(2) in modules}


def portable_closure(modules: dict[str, Path]) -> list[str]:
    missing = [name for name in PORTABLE_ENTRIES if name not in modules]
    if missing:
        raise RuntimeError("missing portable entry modules: " + ", ".join(missing))

    seen: set[str] = set()
    queue = deque(PORTABLE_ENTRIES)
    while queue:
        name = queue.popleft()
        if name in seen:
            continue
        seen.add(name)
        text = modules[name].read_text(encoding="utf-8")
        for dependency in sorted(static_dependencies(text, modules)):
            if dependency not in seen:
                queue.append(dependency)
    return sorted(seen)


def generated_relative_path(source: Path) -> Path:
    """Preserve the canonical unambiguous module layout in the Luau build."""
    return source.relative_to(SOURCE_ROOT).with_suffix(".luau")


def transform(text: str) -> str:
    # Transform exact module-name strings as well as direct require calls.  The
    # former covers the deliberately dynamic host-family table in fibers.host.
    def replace(match: re.Match[str]) -> str:
        quote, name = match.group(1), match.group(2)
        # Dynamic optional hosts may be outside the portable closure.  Keep the
        # alias rewrite so pcall(require, name) fails cleanly in Luau.
        return f"{quote}{alias_name(name)}{quote}"

    transformed = MODULE_STRING_RE.sub(replace, text)
    if re.search(r"\brequire\s*\(\s*['\"]fibers(?:\.|['\"])", transformed):
        raise RuntimeError("unrewritten Fibers require remains")
    return transformed


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_file(path: Path, text: str) -> dict[str, str]:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = text.encode("utf-8")
    path.write_bytes(data)
    return {"path": path.as_posix(), "sha256": sha256(data)}


def verify_unambiguous_layout(output: Path) -> None:
    source_root = output / "src"
    for module_file in source_root.rglob("*.luau"):
        if module_file.name == "init.luau":
            continue
        sibling_directory = module_file.with_suffix("")
        if sibling_directory.is_dir():
            raise RuntimeError(
                f"ambiguous Luau module layout: {module_file} conflicts with {sibling_directory}/"
            )


def verify_generated_entrypoint(output: Path, smoke_text: str) -> None:
    entrypoint = output / "src" / "fibers" / "init.luau"
    if not entrypoint.is_file():
        raise RuntimeError(f"missing generated Fibers entry point: {entrypoint}")
    if "require('@fibers')" not in smoke_text and 'require("@fibers")' not in smoke_text:
        raise RuntimeError("Luau smoke test does not require the @fibers alias root")
    if "@fibers/init" in smoke_text:
        raise RuntimeError("Luau package root must be required as @fibers, not @fibers/init")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="build/luau", help="output directory relative to the repository")
    args = parser.parse_args()

    output = (REPO_ROOT / args.output).resolve()
    if REPO_ROOT not in output.parents:
        raise RuntimeError("Luau output must remain within the repository")
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    modules = source_modules()
    selected = portable_closure(modules)
    selected_set = set(selected)
    manifest_files: list[dict[str, str]] = []

    for name in selected:
        source = modules[name]
        rel = generated_relative_path(source)
        generated = output / "src" / rel
        text = transform(source.read_text(encoding="utf-8"))
        record = write_file(generated, text)
        record["path"] = generated.relative_to(output).as_posix()
        record["module"] = name
        record["source"] = source.relative_to(REPO_ROOT).as_posix()
        manifest_files.append(record)

    smoke_source = REPO_ROOT / "tests" / "luau" / "smoke.lua"
    smoke_text = transform(smoke_source.read_text(encoding="utf-8"))
    smoke_path = output / "tests" / "smoke.luau"
    smoke_record = write_file(smoke_path, smoke_text)
    smoke_record["path"] = smoke_path.relative_to(output).as_posix()
    manifest_files.append(smoke_record)
    verify_generated_entrypoint(output, smoke_text)
    verify_unambiguous_layout(output)

    luaurc = {
        "languageMode": "nocheck",
        "lint": {"*": False},
        "aliases": {"fibers": "./src/fibers"},
    }
    write_file(output / ".luaurc", json.dumps(luaurc, indent=2) + "\n")

    readme = """# Generated Luau build\n\nThis directory is generated by `scripts/build-luau.py`.  Do not edit it.\n\nThe initial target contains the portable Fibers core, in-memory resources,\nManualHost and PureHost.  Native files, sockets and processes are intentionally\nnot part of this build.\n\nRun `make test-luau` from the repository root.\n"""
    write_file(output / "README.md", readme)

    manifest = {
        "format": 1,
        "kind": "fibers-portable-luau",
        "entries": list(PORTABLE_ENTRIES),
        "modules": selected,
        "files": manifest_files,
    }
    write_file(output / "manifest.json", json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    print(f"built {len(selected)} portable Luau modules in {output.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
