#!/usr/bin/env python3
"""Build and test the portable Fibers target for the standalone Luau CLI.

The stock Lua source remains canonical.  This build computes the dependency
closure of the portable public surface and an explicit Luau test profile,
copies it to build/luau, and rewrites logical Lua module names to Luau aliases.
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
SOURCE_ROOTS = (REPO_ROOT / "src", REPO_ROOT / "reference")
AUXILIARY_ROOTS = (REPO_ROOT / "tests", REPO_ROOT / "examples", REPO_ROOT / "experiments")
PROFILE_PATH = REPO_ROOT / "tests" / "luau" / "profile.json"

# Initial portable surface.  The selected test profile adds further public and
# trusted modules to this closure.  Native host providers are not entry points.
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
FIBERS_MODULE_STRING_RE = re.compile(r"(['\"])(fibers(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\1")
PACKAGE_PATH_RE = re.compile(
    r"^[ \t]*package\.path\s*=\s*table\.concat\s*\(\s*\{.*?^[ \t]*\}\s*,\s*['\"];['\"]\s*\)\s*",
    re.MULTILINE | re.DOTALL,
)
KNOWN_ALIAS_ROOTS = ("fibers", "tests", "examples", "experiments")


def module_name(path: Path, root: Path, prefix: str | None = None) -> str:
    rel = path.relative_to(root)
    if rel.name == "init.lua":
        parts = rel.parent.parts
    else:
        parts = rel.with_suffix("").parts
    name = ".".join(parts)
    return f"{prefix}.{name}" if prefix else name


def alias_name(name: str) -> str:
    root, separator, rest = name.partition(".")
    if root not in KNOWN_ALIAS_ROOTS:
        return name
    if not separator:
        return f"@{root}"
    return f"@{root}/" + rest.replace(".", "/")


def source_modules() -> dict[str, Path]:
    modules: dict[str, Path] = {}
    for root in SOURCE_ROOTS:
        for path in sorted(root.rglob("*.lua")):
            name = module_name(path, root)
            if name in modules:
                raise RuntimeError(f"duplicate source module {name}: {path} and {modules[name]}")
            modules[name] = path
    return modules


def auxiliary_modules() -> dict[str, Path]:
    modules: dict[str, Path] = {}
    for root in AUXILIARY_ROOTS:
        prefix = root.name
        for path in sorted(root.rglob("*.lua")):
            name = module_name(path, root, prefix)
            if name in modules:
                raise RuntimeError(f"duplicate auxiliary module {name}: {path} and {modules[name]}")
            modules[name] = path
    return modules


def static_requirements(text: str) -> set[str]:
    return {match.group(2) for match in REQUIRE_RE.finditer(text)}


def portable_closure(modules: dict[str, Path], entries: set[str]) -> list[str]:
    missing = sorted(name for name in entries if name not in modules)
    if missing:
        raise RuntimeError("missing portable entry modules: " + ", ".join(missing))

    seen: set[str] = set()
    queue = deque(sorted(entries))
    while queue:
        name = queue.popleft()
        if name in seen:
            continue
        seen.add(name)
        text = modules[name].read_text(encoding="utf-8")
        for dependency in sorted(static_requirements(text)):
            if dependency in modules and dependency not in seen:
                queue.append(dependency)
    return sorted(seen)


def resolve_profile(profiles: dict[str, object], name: str, stack: tuple[str, ...] = ()) -> dict[str, object]:
    if name in stack:
        raise RuntimeError("cyclic Luau profile inheritance: " + " -> ".join((*stack, name)))
    raw = profiles.get(name)
    if not isinstance(raw, dict):
        raise RuntimeError(f"unknown or invalid Luau profile: {name}")

    parent_name = raw.get("extends")
    if parent_name is None:
        resolved: dict[str, object] = {}
    elif isinstance(parent_name, str):
        resolved = resolve_profile(profiles, parent_name, (*stack, name))
    else:
        raise RuntimeError(f"invalid extends value for Luau profile {name}")

    tests = list(resolved.get("tests", []))
    if "tests" in raw:
        raw_tests = raw.get("tests")
        if not isinstance(raw_tests, list) or not all(isinstance(path, str) for path in raw_tests):
            raise RuntimeError(f"Luau profile {name} has no valid test list")
        tests = list(raw_tests)

    excluded = raw.get("exclude", [])
    included = raw.get("include", [])
    if not isinstance(excluded, list) or not all(isinstance(path, str) for path in excluded):
        raise RuntimeError(f"invalid exclude list for Luau profile {name}")
    if not isinstance(included, list) or not all(isinstance(path, str) for path in included):
        raise RuntimeError(f"invalid include list for Luau profile {name}")
    unknown_exclusions = sorted(set(excluded) - set(tests))
    if unknown_exclusions:
        raise RuntimeError(
            f"Luau profile {name} excludes tests not present in its parent: " + ", ".join(unknown_exclusions)
        )
    excluded_set = set(excluded)
    tests = [path for path in tests if path not in excluded_set]
    for path in included:
        if path not in tests:
            tests.append(path)

    module_entries = list(resolved.get("module_entries", []))
    raw_entries = raw.get("module_entries", [])
    if not isinstance(raw_entries, list) or not all(isinstance(entry, str) for entry in raw_entries):
        raise RuntimeError(f"invalid module_entries for Luau profile {name}")
    for entry in raw_entries:
        if entry not in module_entries:
            module_entries.append(entry)

    for key, value in raw.items():
        if key not in {"extends", "tests", "exclude", "include", "module_entries"}:
            resolved[key] = value
    resolved["tests"] = tests
    resolved["module_entries"] = module_entries
    resolved["name"] = name
    return resolved


def load_profile(name: str) -> tuple[dict[str, object], dict[str, object]]:
    manifest = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
    if manifest.get("format") != 1:
        raise RuntimeError("unsupported Luau test-profile format")
    profiles = manifest.get("profiles")
    if not isinstance(profiles, dict):
        raise RuntimeError("Luau profile manifest has no profiles")
    profile = resolve_profile(profiles, name)

    records = manifest.get("tests")
    if not isinstance(records, list):
        raise RuntimeError("Luau profile manifest has no test classifications")
    classified: dict[str, str] = {}
    for record in records:
        if not isinstance(record, dict):
            raise RuntimeError("invalid Luau test classification record")
        path = record.get("path")
        classification = record.get("classification")
        if not isinstance(path, str) or not isinstance(classification, str):
            raise RuntimeError("invalid Luau test classification")
        if path in classified:
            raise RuntimeError(f"duplicate Luau test classification: {path}")
        classified[path] = classification

    actual = sorted(path.relative_to(REPO_ROOT).as_posix() for path in (REPO_ROOT / "tests").rglob("test_*.lua"))
    missing = sorted(set(actual) - set(classified))
    stale = sorted(set(classified) - set(actual))
    if missing or stale:
        details = []
        if missing:
            details.append("unclassified tests: " + ", ".join(missing))
        if stale:
            details.append("stale classifications: " + ", ".join(stale))
        raise RuntimeError("; ".join(details))

    tests = profile.get("tests")
    if not isinstance(tests, list) or not all(isinstance(path, str) for path in tests):
        raise RuntimeError(f"Luau profile {name} has no valid test list")
    duplicates = sorted(path for path in set(tests) if tests.count(path) > 1)
    if duplicates:
        raise RuntimeError("duplicate tests in Luau profile: " + ", ".join(duplicates))
    for path in tests:
        if classified.get(path) != "portable":
            raise RuntimeError(f"Luau profile contains non-portable test {path}")
        if not (REPO_ROOT / path).is_file():
            raise RuntimeError(f"missing Luau profile test {path}")

    return manifest, profile


def profile_dependencies(
    test_paths: list[str],
    source: dict[str, Path],
    auxiliary: dict[str, Path],
) -> tuple[set[str], list[str]]:
    source_entries: set[str] = set()
    auxiliary_selected: set[str] = set()
    queue: deque[Path] = deque(REPO_ROOT / path for path in test_paths)
    visited_paths: set[Path] = set()

    while queue:
        path = queue.popleft()
        path = path.resolve()
        if path in visited_paths:
            continue
        visited_paths.add(path)
        text = path.read_text(encoding="utf-8")
        for dependency in sorted(static_requirements(text)):
            if dependency in source:
                source_entries.add(dependency)
            elif dependency in auxiliary and dependency not in auxiliary_selected:
                auxiliary_selected.add(dependency)
                queue.append(auxiliary[dependency])

    return source_entries, sorted(auxiliary_selected)


def generated_relative_path(source: Path) -> Path:
    for root in SOURCE_ROOTS:
        if source.is_relative_to(root):
            return source.relative_to(root).with_suffix(".luau")
    for root in AUXILIARY_ROOTS:
        if source.is_relative_to(root):
            return Path(root.name) / source.relative_to(root).with_suffix(".luau")
    raise RuntimeError(f"source is outside known Luau roots: {source}")


def transform(text: str) -> str:
    # Transform exact Fibers module-name strings as well as direct requires.
    # The former covers deliberately dynamic host and evaluator selection.
    def replace_fibers_string(match: re.Match[str]) -> str:
        quote, name = match.group(1), match.group(2)
        return f"{quote}{alias_name(name)}{quote}"

    transformed = FIBERS_MODULE_STRING_RE.sub(replace_fibers_string, text)

    def replace_require(match: re.Match[str]) -> str:
        quote, name = match.group(1), match.group(2)
        root = name.partition(".")[0]
        if root in KNOWN_ALIAS_ROOTS:
            return f"require({quote}{alias_name(name)}{quote})"
        return match.group(0)

    transformed = REQUIRE_RE.sub(replace_require, transformed)
    if re.search(r"\brequire\s*\(\s*['\"](?:fibers|tests|examples|experiments)(?:\.|['\"])", transformed):
        raise RuntimeError("unrewritten portable require remains")
    return transformed


def transform_source(name: str, text: str, machine: str) -> str:
    transformed = transform(text)
    if name != "fibers.runtime":
        return transformed

    marker = "local requested = opts.machine"
    replacement = f"local requested = opts.machine or {json.dumps(machine)}"
    if transformed.count(marker) != 1:
        raise RuntimeError("could not set the generated Luau runtime's default machine")
    return transformed.replace(marker, replacement, 1)


def strip_stock_lua_loader(text: str, path: str) -> str:
    stripped = PACKAGE_PATH_RE.sub("", text)
    if "package.path" in stripped:
        raise RuntimeError(f"unrecognised package.path setup in portable test {path}")
    if re.search(r"\b(?:dofile|loadfile)\b", stripped):
        raise RuntimeError(f"stock-Lua file loader remains in portable test {path}")
    if "package.loaded" in stripped or "package.preload" in stripped:
        raise RuntimeError(f"stock-Lua module cache remains in portable test {path}")
    return stripped


IO_SHIM = """local io = {
  write = function(...)
    local parts = {}
    for i = 1, select('#', ...) do
      parts[i] = tostring(select(i, ...))
    end
    local text = table.concat(parts)
    if string.sub(text, -1) == '\\n' then
      text = string.sub(text, 1, -2)
    end
    print(text)
  end,
}

"""


def wrap_test(text: str, path: str) -> str:
    body = transform(strip_stock_lua_loader(text, path))
    prelude = IO_SHIM if re.search(r"\bio\.", body) else ""
    return (
        f"-- Generated from {path}; do not edit.\n"
        "return function()\n"
        + prelude
        + body.rstrip()
        + "\nend\n"
    )


def test_module_name(path: str) -> str:
    source = Path(path)
    return ".".join(source.with_suffix("").parts)


def render_runner(profile_name: str, test_paths: list[str]) -> str:
    lines = [
        f"-- Generated Luau test runner for profile {profile_name}; do not edit.",
        "local tests = {",
    ]
    for path in test_paths:
        alias = alias_name(test_module_name(path))
        lines.extend(
            [
                "  {",
                f"    name = {json.dumps(path)},",
                "    run = function()",
                f"      local test = require({json.dumps(alias)})",
                "      return test()",
                "    end,",
                "  },",
            ]
        )
    lines.extend(
        [
            "}",
            "",
            "local passed, skipped, failed = 0, 0, 0",
            "local failures = {}",
            f"print(string.format('tests/luau/{profile_name}: running %d tests', #tests))",
            "for i = 1, #tests do",
            "  local test = tests[i]",
            "  local ok, result = pcall(test.run)",
            "  local is_skip = ok and type(result) == 'table' and (result.status == 'skip' or result.tag == 'skip')",
            "  if not ok then",
            "    failed = failed + 1",
            "    failures[#failures + 1] = test.name .. ': ' .. tostring(result)",
            "    print('FAIL ' .. test.name .. ' ' .. tostring(result))",
            "  elseif is_skip then",
            "    skipped = skipped + 1",
            "    print('skip ' .. test.name .. ' ' .. tostring(result.reason or result.message or 'skipped'))",
            "  else",
            "    passed = passed + 1",
            "    print('ok   ' .. test.name)",
            "  end",
            "end",
            f"print(string.format('tests/luau/{profile_name}: summary: %d ok, %d skipped, %d failed, %d total', passed, skipped, failed, #tests))",
            "if failed > 0 then",
            "  error(table.concat(failures, '\\n'), 0)",
            "end",
            "return true",
            "",
        ]
    )
    return "\n".join(lines)


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


def record_generated(record: dict[str, str], generated: Path, output: Path, source: Path | None = None) -> dict[str, str]:
    record["path"] = generated.relative_to(output).as_posix()
    if source is not None:
        record["source"] = source.relative_to(REPO_ROOT).as_posix()
    return record


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="build/luau", help="output directory relative to the repository")
    parser.add_argument("--profile", default="portable", help="named profile from tests/luau/profile.json")
    args = parser.parse_args()

    output = (REPO_ROOT / args.output).resolve()
    if REPO_ROOT not in output.parents:
        raise RuntimeError("Luau output must remain within the repository")
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    classification_manifest, profile = load_profile(args.profile)
    test_paths = list(profile["tests"])
    machine = profile.get("machine", "ledger")
    if machine not in {"ledger", "reference"}:
        raise RuntimeError(f"invalid machine for Luau profile {args.profile}: {machine}")
    source = source_modules()
    auxiliary = auxiliary_modules()
    test_source_entries, auxiliary_selected = profile_dependencies(test_paths, source, auxiliary)
    explicit_entries = profile.get("module_entries", [])
    if not isinstance(explicit_entries, list) or not all(isinstance(name, str) for name in explicit_entries):
        raise RuntimeError(f"invalid module_entries for Luau profile {args.profile}")
    entries = set(PORTABLE_ENTRIES) | test_source_entries | set(explicit_entries)
    selected = portable_closure(source, entries)
    manifest_files: list[dict[str, str]] = []

    for name in selected:
        source_path = source[name]
        rel = generated_relative_path(source_path)
        generated = output / "src" / rel
        text = transform_source(name, source_path.read_text(encoding="utf-8"), machine)
        record = record_generated(write_file(generated, text), generated, output, source_path)
        record["module"] = name
        manifest_files.append(record)

    for name in auxiliary_selected:
        source_path = auxiliary[name]
        rel = generated_relative_path(source_path)
        generated = output / "src" / rel
        text = transform(source_path.read_text(encoding="utf-8"))
        record = record_generated(write_file(generated, text), generated, output, source_path)
        record["module"] = name
        manifest_files.append(record)

    for path in test_paths:
        source_path = REPO_ROOT / path
        rel = Path(path).with_suffix(".luau")
        generated = output / "src" / rel
        text = wrap_test(source_path.read_text(encoding="utf-8"), path)
        record = record_generated(write_file(generated, text), generated, output, source_path)
        record["test"] = path
        manifest_files.append(record)

    smoke_source = REPO_ROOT / "tests" / "luau" / "smoke.lua"
    smoke_text = transform(smoke_source.read_text(encoding="utf-8"))
    smoke_path = output / "tests" / "smoke.luau"
    manifest_files.append(record_generated(write_file(smoke_path, smoke_text), smoke_path, output, smoke_source))

    runner_text = render_runner(args.profile, test_paths)
    runner_path = output / "tests" / f"{args.profile}.luau"
    manifest_files.append(record_generated(write_file(runner_path, runner_text), runner_path, output))

    profile_copy = output / "tests" / "profile.json"
    profile_text = json.dumps(classification_manifest, indent=2) + "\n"
    manifest_files.append(record_generated(write_file(profile_copy, profile_text), profile_copy, output, PROFILE_PATH))

    verify_generated_entrypoint(output, smoke_text)
    verify_unambiguous_layout(output)

    luaurc = {
        "languageMode": "nocheck",
        "lint": {"*": False},
        "aliases": {
            "fibers": "./src/fibers",
            "tests": "./src/tests",
            "examples": "./src/examples",
            "experiments": "./src/experiments",
        },
    }
    write_file(output / ".luaurc", json.dumps(luaurc, indent=2) + "\n")

    readme = f"""# Generated Luau build

This directory is generated by `scripts/build-luau.py`.  Do not edit it.

The target contains the portable Fibers core, in-memory resources, ManualHost,
PureHost, the reference evaluator and the `{args.profile}` Luau test profile,
using the `{machine}` evaluator by default.
Native host providers are intentionally outside this build.

Run `make test-luau` from the repository root.
"""
    write_file(output / "README.md", readme)

    manifest = {
        "format": 2,
        "kind": "fibers-portable-luau",
        "profile": args.profile,
        "machine": machine,
        "entries": sorted(entries),
        "modules": selected,
        "auxiliary_modules": auxiliary_selected,
        "tests": test_paths,
        "files": manifest_files,
    }
    write_file(output / "manifest.json", json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    print(
        f"built {len(selected)} portable Luau modules and {len(test_paths)} {args.profile} tests "
        f"in {output.relative_to(REPO_ROOT)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
