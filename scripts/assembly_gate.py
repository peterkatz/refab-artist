#!/usr/bin/env python3
"""Assembly-validity gate: can the cut sheet actually be ASSEMBLED?

The functional gate checks flat-part geometry (fits / overlap /
self-intersection / biscuits) but never assembly. This gate runs the app's
`--assembly-audit` (same planners as the exports, same CutSheetDocument as
the GUI/SVG/PDF) across the fixture corpus and checks the assembly-breaking
conditions the sheet already knows about:

  severed   slot/notch disconnects a part (red "Notches split part")
  detached  part has no connection to the build (blue, falls off)
  overflow  part exceeds the stock sheet (cannot be cut)

These are NECESSARY conditions for assemblability, not sufficient. Whether
the joints mate and hold every part to the rest is checked by the functional
gate (SLOTS-MATE, PARTS-JOINED) on the cases that export part frames; a
part the cut sheet shows blue there (not joined to the rest) is counted
here as detached. Known-broken cases are
listed with the issue that owns them and excluded from the exit code, same
convention as functional_gate.py.
"""

import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# (mode, fixture, label, extra-args)
CASES = [
    ("stacked", "tests/fixtures/primitives/cube_50mm_binary.stl", "cube", []),
    ("stacked", "tests/fixtures/primitives/sphere_d50mm.stl", "sphere", []),
    ("stacked", "tests/fixtures/primitives/cylinder_d40_h80mm.stl", "cylinder", []),
    ("stacked", "tests/fixtures/primitives/torus_R30_r10mm.stl", "torus", []),
    ("stacked", "tests/fixtures/real-world/simple_chair.stl", "chair", []),
    ("stacked", "tests/fixtures/real-world/spur_gear_T20_M2.stl", "gear", []),
    ("interlocked", "tests/fixtures/primitives/cube_50mm_binary.stl", "cube", []),
    ("interlocked", "tests/fixtures/primitives/sphere_d50mm.stl", "sphere", []),
    ("interlocked", "tests/fixtures/primitives/cylinder_d40_h80mm.stl", "cylinder", []),
    ("radial", "tests/fixtures/primitives/cylinder_d40_h80mm.stl", "cylinder", []),
    ("radial", "tests/fixtures/primitives/sphere_d50mm.stl", "sphere", []),
    ("curve", "tests/fixtures/primitives/sphere_d50mm.stl", "sphere", []),
    # 3D Slices produces a surface-preserving layered MESH (printable), not flat
    # laser-cut parts, so it has no flat-part assembly to validate here.
    ("folded", "tests/fixtures/primitives/cube_50mm_binary.stl", "cube", []),
    # Organic fixtures: where the bbox-slot generators actually break
    # (these reproduce the hand-model findings on committed fixtures).
    ("stacked", "tests/fixtures/organic/lumpy_blob.stl", "blob", []),
    ("interlocked", "tests/fixtures/organic/lumpy_blob.stl", "blob", []),
    # Guards the folded dense-mesh simplification (Detail budget): the audit
    # applies the GUI default (250 faces), so panel counts stay buildable.
    ("folded", "tests/fixtures/organic/lumpy_blob.stl", "blob", []),
    ("radial", "tests/fixtures/organic/lumpy_blob.stl", "blob", []),
    ("curve", "tests/fixtures/organic/lumpy_blob.stl", "blob", []),
    # Radial on a model shorter than ten rings of stock, a chair, and models
    # built from shells that touch or run into each other: every piece is
    # locked to a ring or fin (none marked blue).
    ("radial", "tests/fixtures/primitives/torus_R30_r10mm.stl", "torus", []),
    ("radial", "tests/fixtures/real-world/simple_chair.stl", "chair", []),
    ("radial", "tests/fixtures/organic/low_poly_head.stl", "head", []),
    ("radial", "tests/fixtures/pathological/cube_self_intersecting.stl", "overlap-cubes", []),
]

# Known-broken populations excluded from the exit code, each owned by a
# Linear issue. Everything else failing = regression -> exit 1.
KNOWN_BROKEN = {
}


def find_binary() -> Path:
    for configuration in ("release", "debug"):
        path = REPO / f"app/RefabArtist/.build/arm64-apple-macosx/{configuration}/RefabArtist"
        if path.exists():
            return path
    sys.exit("No built RefabArtist binary; run swift build first")


def main() -> int:
    binary = find_binary()
    rows = []
    regression = False
    for mode, fixture, label, extra in CASES:
        command = [
            str(binary), "--assembly-audit",
            "--mode", mode,
            "--fixture", str(REPO / fixture),
            "--thickness", "3",
        ] + extra
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            rows.append((mode, label, None, result.stderr.strip()))
            if (mode, label) not in KNOWN_BROKEN:
                regression = True
            continue
        report = json.loads(result.stdout)
        rows.append((mode, label, report, None))
        if not report["assemblable"] and (mode, label) not in KNOWN_BROKEN:
            regression = True

    print(f"{'case':22} {'parts':>5} {'severed':>7} {'detached':>8} {'overflow':>8}  assembly")
    for mode, label, report, error in rows:
        name = f"{mode}/{label}"
        known = KNOWN_BROKEN.get((mode, label))
        if error is not None:
            verdict = f"ERROR ({error})"
            print(f"{name:22} {'-':>5} {'-':>7} {'-':>8} {'-':>8}  {verdict}" + (f" *{known}" if known else ""))
            continue
        verdict = "PASS" if report["assemblable"] else "FAIL"
        suffix = f" *{known}" if known and verdict == "FAIL" else ""
        print(
            f"{name:22} {report['parts']:>5} {report['severed']:>7} "
            f"{report['detached']:>8} {report['overflow']:>8}  {verdict}{suffix}"
        )
    print("* = known-broken population, excluded from exit code (owning issue shown).")
    print("Checks are NECESSARY conditions only; joints and connectivity are gated by the functional gate (SLOTS-MATE, PARTS-JOINED).")
    return 1 if regression else 0


if __name__ == "__main__":
    sys.exit(main())
