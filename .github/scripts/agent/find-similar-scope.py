#!/usr/bin/env python3
"""Validates the find-similar scoper's output and turns it into custom defect scanner units.

Drops paths that do not exist and unknown test packages, prefixes unit ids with the seed so their fingerprints never
collide with catalogue units, and requires at least one usable unit. Prints the units as compact JSON (the defect scanner's
custom_scopes input).

Usage: find-similar-scope.py <result.json> <seed: issue:<n>|pr:<n>>
"""
import json
import re
import sys
from pathlib import Path

MAX_INPUT = 60000  # workflow_dispatch inputs are limited to 65535 characters


def slug(text):
    return re.sub(r"[^a-z0-9-]+", "-", text.lower()).strip("-")[:40] or "unit"


def main():
    result = json.loads(Path(sys.argv[1]).read_text() or "null")
    seed = sys.argv[2]
    if not re.fullmatch(r"(issue|pr):[0-9]+", seed):
        raise SystemExit(f"::error::Invalid seed {seed}")
    if not isinstance(result, dict) or not result.get("units") or not result.get("pattern"):
        raise SystemExit("::error::The scoper produced no valid output")
    prefix = "similar-" + seed.replace(":", "")
    known_packages = {p.name for p in Path("ballerina-tests").iterdir() if p.is_dir()} | {"native", "compiler-plugin"}

    units = []
    for unit in result["units"][:3]:
        paths = [p.strip().removeprefix("./") for p in unit.get("paths", [])]
        missing = [p for p in paths if not Path(p).exists()]
        paths = [p for p in paths if Path(p).exists()]
        if missing:
            print(f"::warning::Unit {unit.get('id')}: dropped missing paths {missing}", file=sys.stderr)
        if not paths:
            print(f"::warning::Unit {unit.get('id')}: no existing paths, skipped", file=sys.stderr)
            continue
        units.append({
            "id": f"{prefix}-{slug(unit.get('id', ''))}",
            "description": unit.get("description", ""),
            "spec_sections": unit.get("spec_sections", []),
            "paths": paths,
            "test_packages": [t for t in unit.get("test_packages", []) if t in known_packages],
            "hints": unit.get("hints", []),
            "pattern": result["pattern"],
            "exclude": result.get("exclude", []),
        })
    if not units:
        raise SystemExit("::error::No usable scope unit (all paths missing)")
    out = json.dumps(units, separators=(",", ":"))
    if len(out) > MAX_INPUT:
        raise SystemExit(f"::error::Generated scopes are too large for a workflow input ({len(out)} characters)")
    print(out)


if __name__ == "__main__":
    main()
