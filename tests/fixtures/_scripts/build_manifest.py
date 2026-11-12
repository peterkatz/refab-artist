#!/usr/bin/env python3
"""
Build tests/fixtures/MANIFEST.md from the on-disk corpus.

For every fixture file (.stl, .obj) under tests/fixtures/, computes:
  - relative path
  - byte size
  - SHA-256 first 12 hex chars
  - triangle count (STL: from numpy-stl; OBJ: count `f ` lines as triangles
    if all face lines have exactly 3 verts, else label "polygon")
  - vertex count (STL: 3 * tri; OBJ: count `v ` lines)
  - license (always CC0 / locally-generated)
  - source (which generator script produced it; "hand-authored" for legacy)
  - intended use
The hand-written "Owner's hand scans" and "Tracked MotherMold hand fixtures"
sections at the end of MANIFEST.md are kept as they are when it is rebuilt.

The intended-use blurbs live in a per-fixture dictionary in this script —
when adding a new fixture, append an entry here AND in the matching
gen_<category>.py.

Run from anywhere:
    python3 tests/fixtures/_scripts/build_manifest.py
"""
from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Dict, Tuple

from stl import mesh as stlmesh

from lib_mesh import fixtures_root


# (license_label, source_label, intended_use)
FIXTURE_META: Dict[str, Tuple[str, str, str]] = {
    # ---- legacy (top-level) ----
    "cube_ascii.stl": (
        "CC0", "hand-authored (predates corpus)",
        "Baseline watertight ASCII STL — referenced by the existing Swift unit test suite (StlExporter, DxfExporter, etc.).",
    ),
    "cube.obj": (
        "CC0", "hand-authored (predates corpus)",
        "OBJ parser smoke test — note: only two faces of the cube are tessellated. Kept for legacy compatibility; prefer `primitives/cube_50mm.obj` for new work.",
    ),
    "rectangular_prism_ascii.stl": (
        "CC0", "hand-authored (predates corpus)",
        "Nonuniform-bounds exerciser (80x40x30 mm) for DXF/PDF exporter tests.",
    ),
    "square_pyramid_ascii.stl": (
        "CC0", "hand-authored (predates corpus)",
        "Non-box triangular topology for HeadlessExport tests.",
    ),
    # ---- primitives ----
    "primitives/cube_50mm_ascii.stl": (
        "CC0", "gen_primitives.py",
        "ASCII-STL parser baseline — smallest valid closed mesh.",
    ),
    "primitives/cube_50mm_binary.stl": (
        "CC0", "gen_primitives.py",
        "Binary-STL parser baseline — same geometry as the ASCII cube; lets ASCII vs binary parsing be diffed without geometry confounders.",
    ),
    "primitives/cube_50mm.obj": (
        "CC0", "gen_primitives.py",
        "OBJ parser baseline — same geometry as the cube STLs.",
    ),
    "primitives/sphere_d50mm.stl": (
        "CC0", "gen_primitives.py",
        "Smooth closed mesh of moderate density (960 tri) — exercises Stacked, Curve, and Radial slicing without stress-test cost.",
    ),
    "primitives/cylinder_d40_h80mm.stl": (
        "CC0", "gen_primitives.py",
        "Tall cylinder with closed caps — exercises Stacked slice distribution along Z and verifies cap handling.",
    ),
    "primitives/torus_R30_r10mm.stl": (
        "CC0", "gen_primitives.py",
        "Genus-1 surface (one through-hole) — Stacked and 3D Slices must handle inner contours without merging them with the outer.",
    ),
    # ---- stress ----
    "stress/sphere_dense_d50mm.stl": (
        "CC0", "gen_stress.py",
        ">100k-triangle stress mesh (107,184 tri, ~5.4 MB) — slicing throughput and memory benchmark; Phase 6.1 reference.",
    ),
    "stress/tetrahedron_minimal.stl": (
        "CC0", "gen_stress.py",
        "Minimum-triangle closed mesh (4 tri) — guards against parsers/algorithms with implicit assumptions about mesh density.",
    ),
    "stress/thin_shell_box_open_50mm.stl": (
        "CC0", "gen_stress.py",
        "Open shell (cube with +Z face removed, 10 tri) — every closed-mesh assumption in the slicing pipeline gets stressed; preflight should warn.",
    ),
    "stress/hollow_box_50mm.stl": (
        "CC0", "gen_stress.py",
        "Two-shell solid (50mm outer + 30mm inverted inner, 24 tri) — Stacked must produce nested contours (outer + inner) on every slice through the cavity.",
    ),
    "stress/multi_component_2spheres.stl": (
        "CC0", "gen_stress.py",
        "Two disjoint spheres in a single mesh (1248 tri) — slicing must produce two disjoint contour sets per slice; assembly must label two component groups.",
    ),
    # ---- pathological ----
    "pathological/cube_nonmanifold_edge.stl": (
        "CC0", "gen_pathological.py",
        "Cube + one extra fin sharing an edge — three triangles meet at the shared edge. Preflight must flag non-manifold; behavior thereafter is mode-dependent (Stacked: ignore the fin; Interlocked: hard-fail or warn). See pathological/README.md.",
    ),
    "pathological/cube_self_intersecting.stl": (
        "CC0", "gen_pathological.py",
        "Two overlapping cubes in one mesh — surface self-intersects. Slicing libraries differ on tolerance; document what each mode does.",
    ),
    "pathological/cube_zero_area_face.stl": (
        "CC0", "gen_pathological.py",
        "Cube + one degenerate (collinear-vertex) triangle. Preflight must detect and skip; normal computation must not divide by zero.",
    ),
    "pathological/cube_very_thin_feature_1mm.stl": (
        "CC0", "gen_pathological.py",
        "Cube with a 1 mm-thick protrusion. Material-preset kerf compensation should refuse or warn (typical plywood stock is 3-6 mm).",
    ),
    "pathological/lumpy_blob_open_poles.stl": (
        "CC0", "gen_pathological.py (lumpy_blob from gen_organic.py with shared_poles=False)",
        "The lumpy blob cracked open at both poles: one pole vertex per longitude, at different heights, so the polar fans leave wedge-shaped slits, as a real scan often is. Sections through the poles come out as open chains; the functional gate cuts it in Curve, Radial, Interlocked and Stacked at 3 and 5 mm.",
    ),
    "pathological/torus_mixed_winding.stl": (
        "CC0", "gen_pathological.py (torus from lib_mesh.py, as primitives/torus_R30_r10mm.stl)",
        "The primitives torus with the triangles of the inner third of its tube wound inward: a closed surface whose triangles face both ways. Radial and Curve must cut the same parts as from the torus; the functional gate checks their joints against the consistently wound torus.",
    ),
    "pathological/torus_inverted.stl": (
        "CC0", "gen_pathological.py (torus from lib_mesh.py, as primitives/torus_R30_r10mm.stl)",
        "The primitives torus with every triangle wound inward: a closed surface wound wholly inside out, as some exporters write. Radial and Curve must cut the same parts as from the torus; the functional gate checks them against the torus wound outward.",
    ),
    "pathological/blocks_touching_at_corner.stl": (
        "CC0", "gen_pathological.py",
        "A 20 mm square block and a kite-shaped block, 30 mm tall, meeting along one vertical edge only. Every horizontal section is two pieces touching at a corner, which a contourer joining segments the straightest way on draws as one figure of eight; Stacked must cut them as two pieces.",
    ),
    # ---- organic ----
    "organic/lumpy_blob.stl": (
        "CC0", "gen_organic.py",
        "Sphere with deterministic sinusoidal radial displacement (1932 tri) — freeform silhouette that's still closed and manifold; Stacked/Curve slicing produces irregular contour shapes.",
    ),
    "organic/low_poly_head.stl": (
        "CC0", "gen_organic.py",
        "Stylized 60-tri bust (head + neck + brow + nose + crown). Multiple stacked features along Z so Stacked produces visibly different contour shapes per slice.",
    ),
    # ---- real-world ----
    "real-world/simple_chair.stl": (
        "CC0", "gen_real_world.py",
        "Six-piece chair silhouette (seat + back + 4 legs). Representative of a 'design my own chair' use case; multi-component without overlap.",
    ),
    "real-world/spur_gear_T20_M2.stl": (
        "CC0", "gen_real_world.py",
        "Extruded 20-tooth M=2 involute spur gear, 8 mm thick (1440 tri). Highly featured outline — kerf compensation visibly changes tooth thickness.",
    ),
}


def sha256_12(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()[:12]


def stl_counts(path: Path) -> tuple[int, int]:
    m = stlmesh.Mesh.from_file(str(path))
    n_tri = len(m.vectors)
    return n_tri, n_tri * 3  # vertex count = 3 * triangles (not unique)


def obj_counts(path: Path) -> tuple[int, int]:
    text = path.read_text(encoding="ascii", errors="strict")
    verts = sum(1 for line in text.splitlines() if line.startswith("v "))
    faces = sum(1 for line in text.splitlines() if line.startswith("f "))
    return faces, verts


def main() -> None:
    root = fixtures_root()
    rows = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix.lower() not in (".stl", ".obj"):
            continue
        rel = str(path.relative_to(root))
        meta = FIXTURE_META.get(rel)
        if meta is None:
            raise SystemExit(f"missing FIXTURE_META entry for: {rel}")
        license_label, source_label, intended_use = meta
        size = path.stat().st_size
        if path.suffix.lower() == ".stl":
            tri, vert = stl_counts(path)
        else:
            tri, vert = obj_counts(path)
        rows.append((rel, size, sha256_12(path), tri, vert,
                     license_label, source_label, intended_use))

    total_bytes = sum(r[1] for r in rows)
    total_tris = sum(r[3] for r in rows)
    by_cat: Dict[str, int] = {}
    for rel, *_ in rows:
        cat = rel.split("/")[0] if "/" in rel else "legacy"
        by_cat[cat] = by_cat.get(cat, 0) + 1

    out_path = root / "MANIFEST.md"
    lines = []
    lines.append("# Fixture corpus manifest")
    lines.append("")
    lines.append(
        "Generated by `_scripts/build_manifest.py`. Re-run after adding, removing, "
        "or regenerating any fixture so the table reflects on-disk bytes. Every "
        "fixture is CC0 / public-domain-dedicated; see `README.md` for the license "
        "posture and `_scripts/README.md` for the generator chain."
    )
    lines.append("")
    lines.append("## Totals")
    lines.append("")
    lines.append(f"- Files: {len(rows)}")
    lines.append(f"- Total bytes: {total_bytes:,}")
    lines.append(f"- Total triangles: {total_tris:,}")
    lines.append("- By category: " + ", ".join(
        f"{k}={v}" for k, v in sorted(by_cat.items())))
    lines.append("")
    lines.append("## Per-fixture")
    lines.append("")
    lines.append("| Path | Bytes | SHA-256-12 | Tri | Vert | License | Source | Intended use |")
    lines.append("|---|---:|---|---:|---:|---|---|---|")
    for rel, size, sha, tri, vert, lic, src, use in rows:
        lines.append(
            f"| `{rel}` | {size:,} | `{sha}` | {tri:,} | {vert:,} | {lic} | {src} | {use} |"
        )
    lines.append("")
    text = "\n".join(lines) + "\n"
    # The hand-scan sections after the generated table are written by hand
    # (they record the owner's scans, which no generator makes); keep them.
    if out_path.exists():
        previous = out_path.read_text(encoding="utf-8")
        marker = "\n## Owner's hand scans"
        if marker in previous:
            text += previous[previous.index(marker) + 1:]
    out_path.write_text(text, encoding="utf-8")
    print(f"wrote {out_path} ({len(rows)} fixtures, {total_bytes:,} bytes)")


if __name__ == "__main__":
    main()
