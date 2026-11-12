#!/usr/bin/env python3
"""
Generate the pathological/ fixtures.

These are INTENTIONALLY broken meshes that exercise Refab Artist's error handling
and preflight checks, and what each mode cuts from them. Each one violates one well-known geometry-correctness
invariant; see pathological/README.md for the complete catalog.

Run from anywhere:
    python3 tests/fixtures/_scripts/gen_pathological.py
"""
from __future__ import annotations

import math

from lib_mesh import (
    box_triangles, torus,
    write_stl_binary,
    mesh_stats, fixtures_root,
)
from gen_organic import lumpy_blob


def main() -> None:
    out = fixtures_root() / "pathological"

    # 1. Non-manifold edge: a 50 mm cube plus one extra triangle that shares
    #    an existing cube edge — three triangles meet at one edge instead of two.
    cube = box_triangles(-25, -25, -25, 25, 25, 25)
    # The +x face has the edge (25,-25,-25)->(25,25,-25). Add a fin extending
    # outward along +x from that edge so the edge is shared by 3 triangles.
    fin = [
        ((25.0, -25.0, -25.0), (25.0, 25.0, -25.0), (50.0, 0.0, -25.0)),
    ]
    nm = cube + fin
    write_stl_binary(out / "cube_nonmanifold_edge.stl", nm,
                     header="Refab Artist non-manifold edge (cube+fin)")
    print("pathological/cube_nonmanifold_edge:", mesh_stats(nm).summary())

    # 2. Self-intersecting: two 50 mm cubes overlapping at the center, stored
    #    as one mesh. Cube A centered at origin; cube B shifted by (20,20,20).
    cube_a = box_triangles(-25, -25, -25, 25, 25, 25)
    cube_b = box_triangles(-5, -5, -5, 45, 45, 45)
    si = cube_a + cube_b
    write_stl_binary(out / "cube_self_intersecting.stl", si,
                     header="Refab Artist self-intersecting cubes")
    print("pathological/cube_self_intersecting:", mesh_stats(si).summary())

    # 3. Zero-area face: a 50 mm cube plus one degenerate triangle whose three
    #    vertices are collinear (and at the same point too — both forms count
    #    as zero area). We use collinear-but-distinct to also exercise area=0
    #    without coincident vertices.
    cube = box_triangles(-25, -25, -25, 25, 25, 25)
    degenerate = [
        ((0.0, 0.0, 0.0), (10.0, 0.0, 0.0), (20.0, 0.0, 0.0)),
    ]
    za = cube + degenerate
    write_stl_binary(out / "cube_zero_area_face.stl", za,
                     header="Refab Artist cube + zero-area facet")
    print("pathological/cube_zero_area_face:", mesh_stats(za).summary())

    # 4. Very thin feature: a 50 mm cube with a 1 mm-thick protrusion off the
    #    +X face. Not topologically broken; semantically thinner than typical
    #    plywood stock so slot fit will fail / require warning. We model it as
    #    a separate solid attached at the +X face (so the combined surface has
    #    a non-manifold edge where the protrusion meets the parent cube —
    #    this is intentional; production CAD systems handle this fine but it
    #    exercises our preflight).
    cube = box_triangles(-25, -25, -25, 25, 25, 25)
    # Protrusion: 1 mm thick (X 25..26), 20 mm tall (Z -10..10), 10 mm deep (Y -5..5).
    fin_box = box_triangles(25.0, -5.0, -10.0, 26.0, 5.0, 10.0)
    thin = cube + fin_box
    write_stl_binary(out / "cube_very_thin_feature_1mm.stl", thin,
                     header="Refab Artist cube + 1mm thin feature")
    print("pathological/cube_very_thin_feature_1mm:", mesh_stats(thin).summary())

    # 5. Cracked: the lumpy blob (organic/lumpy_blob.stl) with one pole
    #    vertex per longitude instead of one shared vertex. The displacement
    #    varies with longitude there, so the pole vertices lie at different
    #    heights on the axis and the polar fans' edges are not shared: both
    #    poles are cracked open by thin wedge-shaped slits, as a real scan
    #    often is. Same lat/lon counts as the organic blob.
    cracked = lumpy_blob(base_radius=25.0, lat_segments=24, lon_segments=42, shared_poles=False)
    write_stl_binary(out / "lumpy_blob_open_poles.stl", cracked,
                     header="Refab Artist lumpy blob, cracked open at the poles")
    print("pathological/lumpy_blob_open_poles:", mesh_stats(cracked).summary())

    # 6. Mixed winding: the torus of primitives/torus_R30_r10mm.stl (same
    #    vertices, same triangle order) with the triangles of the inner third
    #    of its tube (around the hole, where cos(minor angle) < -0.5 at the
    #    triangle's centre) wound the other way, so they face into the solid.
    #    The surface is closed and unchanged; only which way its triangles
    #    face disagrees.
    major, minor = 30.0, 10.0
    def inner_third(tri) -> bool:
        cx = sum(p[0] for p in tri) / 3
        cy = sum(p[1] for p in tri) / 3
        return math.hypot(cx, cy) - major < -0.5 * minor * math.cos(math.pi / 30)
    mixed = [(a, c, b) if inner_third((a, b, c)) else (a, b, c)
             for a, b, c in torus(major_radius=major, minor_radius=minor,
                                  major_segments=30, minor_segments=30)]
    write_stl_binary(out / "torus_mixed_winding.stl", mixed,
                     header="Refab Artist torus R30 r10, inner third wound inward")
    print("pathological/torus_mixed_winding:", mesh_stats(mixed).summary(),
          "flipped:", sum(1 for t in torus(major, minor, 30, 30) if inner_third(t)))

    # 7. Inside out: the same torus with every triangle wound the other way,
    #    so all of them face into the solid. Its triangles all agree with
    #    each other; only which way the whole surface faces is wrong, as in
    #    an inside-out export.
    inverted = [(a, c, b) for a, b, c in torus(major_radius=major, minor_radius=minor,
                                               major_segments=30, minor_segments=30)]
    write_stl_binary(out / "torus_inverted.stl", inverted,
                     header="Refab Artist torus R30 r10, wound inside out")
    print("pathological/torus_inverted:", mesh_stats(inverted).summary())

    # 8. Pinched sections: a 20 mm square block and a kite-shaped block, both
    #    30 mm tall, that meet along one vertical edge only (at x = y = 0).
    #    Every horizontal section is two pieces touching at one corner. The
    #    kite's edge leaves that corner nearly straight on from the block's,
    #    so a contourer that joins segments along the straightest way on
    #    draws each section as one figure of eight crossing over at the
    #    corner: the outline pinches, and must be cut as two pieces.
    block = box_triangles(-20.0, -20.0, 0.0, 0.0, 0.0, 30.0)
    kite = prism_triangles([(0.0, 0.0), (20.0, 5.0), (20.0, 20.0), (5.0, 20.0)], 0.0, 30.0)
    write_stl_binary(out / "blocks_touching_at_corner.stl", block + kite,
                     header="Refab Artist blocks meeting along one edge")
    print("pathological/blocks_touching_at_corner:", mesh_stats(block + kite).summary())


def prism_triangles(polygon, z0: float, z1: float):
    """A prism from z0 to z1 over a convex polygon given counter-clockwise
    seen from +z, faces wound outward."""
    n = len(polygon)
    bottom = [(x, y, z0) for x, y in polygon]
    top = [(x, y, z1) for x, y in polygon]
    tris = []
    for i in range(1, n - 1):
        tris.append((bottom[0], bottom[i + 1], bottom[i]))
        tris.append((top[0], top[i], top[i + 1]))
    for i in range(n):
        a, b = bottom[i], bottom[(i + 1) % n]
        c, d = top[(i + 1) % n], top[i]
        tris.append((a, b, c))
        tris.append((a, c, d))
    return tris


if __name__ == "__main__":
    main()
