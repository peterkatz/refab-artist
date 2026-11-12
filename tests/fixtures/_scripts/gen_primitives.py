#!/usr/bin/env python3
"""
Generate the primitives/ fixtures: cube (ASCII + binary STL + OBJ), sphere,
cylinder, torus. All synthesized from math. CC0.

Run from the repo root:
    python3 tests/fixtures/_scripts/gen_primitives.py
"""
from __future__ import annotations

from lib_mesh import (
    box_triangles, uv_sphere, cylinder, torus,
    write_stl_ascii, write_stl_binary, write_obj,
    mesh_stats, fixtures_root,
)


def main() -> None:
    out = fixtures_root() / "primitives"

    # 50 mm cube centered at origin, 12 triangles.
    cube = box_triangles(-25, -25, -25, 25, 25, 25)
    write_stl_ascii(out / "cube_50mm_ascii.stl", cube, solid_name="cube_50mm")
    write_stl_binary(out / "cube_50mm_binary.stl", cube, header="Refab Artist cube_50mm fixture")
    write_obj(out / "cube_50mm.obj", cube, object_name="cube_50mm")
    print("primitives/cube_50mm:", mesh_stats(cube).summary())

    # UV sphere, diameter 50 mm (radius 25), lat=20 lon=32 -> 2*32*(20-1)=1216 triangles
    # but with pole-fans counted correctly. We want ~960 triangles per the brief;
    # lat=16 lon=32 gives 2*32*15 = 960 minus pole degeneracies. Close enough.
    sphere = uv_sphere(radius=25.0, lat_segments=16, lon_segments=32)
    write_stl_binary(out / "sphere_d50mm.stl", sphere, header="Refab Artist sphere d50mm")
    print("primitives/sphere_d50mm:", mesh_stats(sphere).summary())

    # Closed cylinder, diameter 40 mm, height 80 mm, 64 segments -> 4*64=256 triangles
    cyl = cylinder(radius=20.0, height=80.0, segments=64)
    write_stl_binary(out / "cylinder_d40_h80mm.stl", cyl, header="Refab Artist cylinder d40 h80")
    print("primitives/cylinder_d40_h80mm:", mesh_stats(cyl).summary())

    # Torus R30 r10, 30 major * 30 minor -> 1800 triangles
    tor = torus(major_radius=30.0, minor_radius=10.0,
                major_segments=30, minor_segments=30)
    write_stl_binary(out / "torus_R30_r10mm.stl", tor, header="Refab Artist torus R30 r10")
    print("primitives/torus_R30_r10mm:", mesh_stats(tor).summary())


if __name__ == "__main__":
    main()
