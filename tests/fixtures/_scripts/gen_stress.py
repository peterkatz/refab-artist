#!/usr/bin/env python3
"""
Generate the stress/ fixtures.

Run from anywhere:
    python3 tests/fixtures/_scripts/gen_stress.py
"""
from __future__ import annotations

from lib_mesh import (
    box_triangles, inverted_box_triangles, uv_sphere, tetrahedron,
    write_stl_binary,
    mesh_stats, fixtures_root,
)


def main() -> None:
    out = fixtures_root() / "stress"

    # Dense UV sphere — need >100k triangles.
    # 2 * lon * (lat - 1) - 2*lon (pole degens) ~ approx 2*lon*(lat-1)
    # lat=232 lon=232 -> ~107k triangles. Diameter 50 mm.
    dense = uv_sphere(radius=25.0, lat_segments=232, lon_segments=232)
    write_stl_binary(out / "sphere_dense_d50mm.stl", dense,
                     header="Refab Artist dense sphere >100k tri")
    print("stress/sphere_dense_d50mm:", mesh_stats(dense).summary())

    # Sparse mesh — regular tetrahedron, edge ~50 mm -> 4 triangles.
    tetra = tetrahedron(size=50.0)
    write_stl_binary(out / "tetrahedron_minimal.stl", tetra,
                     header="Refab Artist tetrahedron 4-tri minimal")
    print("stress/tetrahedron_minimal:", mesh_stats(tetra).summary())

    # Thin shell — 50 mm box with the +Z face removed (open cup).
    open_box = box_triangles(-25, -25, -25, 25, 25, 25, skip_faces=("+z",))
    write_stl_binary(out / "thin_shell_box_open_50mm.stl", open_box,
                     header="Refab Artist open box (top removed)")
    print("stress/thin_shell_box_open_50mm:", mesh_stats(open_box).summary())

    # Hollow box — outer 50 mm box + inverted inner 30 mm box (two shells).
    outer = box_triangles(-25, -25, -25, 25, 25, 25)
    inner = inverted_box_triangles(-15, -15, -15, 15, 15, 15)
    hollow = outer + inner
    write_stl_binary(out / "hollow_box_50mm.stl", hollow,
                     header="Refab Artist hollow box 50/30")
    print("stress/hollow_box_50mm:", mesh_stats(hollow).summary())

    # Multi-component: two disjoint spheres, 20 mm radius, centers 60 mm apart.
    sph_a = uv_sphere(radius=20.0, lat_segments=14, lon_segments=24,
                      center=(-30.0, 0.0, 0.0))
    sph_b = uv_sphere(radius=20.0, lat_segments=14, lon_segments=24,
                      center=(30.0, 0.0, 0.0))
    multi = sph_a + sph_b
    write_stl_binary(out / "multi_component_2spheres.stl", multi,
                     header="Refab Artist two disjoint spheres")
    print("stress/multi_component_2spheres:", mesh_stats(multi).summary())


if __name__ == "__main__":
    main()
