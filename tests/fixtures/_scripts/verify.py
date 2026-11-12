#!/usr/bin/env python3
"""
Verify the Refab Artist fixture corpus parses cleanly.

For each STL under tests/fixtures/, attempts to parse it with numpy-stl and
prints (path, byte_size, triangle_count, sha256_12). Pathological fixtures are
expected to PARSE (they're valid STL syntax); the broken-ness is geometric, not
syntactic. The script does NOT enforce manifoldness — that's the point.

Exits non-zero if any STL fails to parse. Used as a Phase 2.1 gate.

Run from anywhere:
    python3 tests/fixtures/_scripts/verify.py
"""
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

from stl import mesh as stlmesh

from lib_mesh import fixtures_root


def sha256_12(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()[:12]


def main() -> int:
    root = fixtures_root()
    failures = 0
    print(f"{'path':<55} {'bytes':>10} {'tris':>8} {'sha256':>14}")
    print("-" * 90)
    for path in sorted(root.rglob("*.stl")):
        rel = path.relative_to(root)
        size = path.stat().st_size
        try:
            m = stlmesh.Mesh.from_file(str(path))
            tri_count = len(m.vectors)
        except Exception as e:
            print(f"{str(rel):<55} {size:>10} FAIL parse: {e}")
            failures += 1
            continue
        print(f"{str(rel):<55} {size:>10} {tri_count:>8} {sha256_12(path):>14}")
    # OBJ files too — light check that they're readable text and have v/f lines.
    for path in sorted(root.rglob("*.obj")):
        rel = path.relative_to(root)
        size = path.stat().st_size
        text = path.read_text(encoding="ascii", errors="strict")
        verts = sum(1 for line in text.splitlines() if line.startswith("v "))
        faces = sum(1 for line in text.splitlines() if line.startswith("f "))
        print(f"{str(rel):<55} {size:>10} v={verts} f={faces} {sha256_12(path):>14}")
    if failures:
        print(f"\nFAIL: {failures} fixture(s) failed to parse", file=sys.stderr)
        return 1
    print("\nOK: all fixtures parsed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
