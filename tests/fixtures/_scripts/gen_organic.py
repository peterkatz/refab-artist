#!/usr/bin/env python3
"""
Generate the organic/ fixtures.

We do NOT download external assets (Stanford Bunny, Utah Teapot, etc.) — those
would require runtime network access that isn't guaranteed in the build sandbox
and would also introduce a third-party provenance chain we'd need to validate.
Instead we synthesize organic-looking meshes deterministically from math, so
every byte in the committed fixture is traceable to this script.

Two organic fixtures:
  - lumpy_blob.stl: UV sphere with a smooth deterministic radial displacement
    field (sum of low-frequency sines), giving a "lumpy potato" silhouette.
  - low_poly_head.stl: stylized geometric head built by stacking and tapering
    primitive boxes (a literal "low-poly bust" — head + neck + simple features).

Both ship CC0.

Run from anywhere:
    python3 tests/fixtures/_scripts/gen_organic.py
"""
from __future__ import annotations

import math
from typing import List

from lib_mesh import (
    box_triangles, quad,
    write_stl_binary,
    mesh_stats, fixtures_root,
    Tri, Vec3,
)


def lumpy_blob(base_radius: float, lat_segments: int, lon_segments: int,
               shared_poles: bool = True) -> List[Tri]:
    """
    Sphere with deterministic radial displacement
        r(theta, phi) = base_radius * (1 + amp * f(theta, phi))
    where f is a fixed sum of low-frequency sines so the output is reproducible
    on any machine and has no RNG.

    With `shared_poles=False` each pole gets one vertex per longitude, as the
    first version of this generator built it: the displacement still varies
    with phi there, so those vertices lie at different heights on the axis,
    the polar fans' edges are not shared and the mesh is cracked open at both
    poles (`pathological/lumpy_blob_open_poles.stl`, built by
    gen_pathological.py).
    """
    amp = 0.18

    def displaced(theta: float, phi: float) -> Vec3:
        # Sum of a few low-frequency sinusoids in spherical coordinates.
        d = (
            math.sin(3 * theta) * math.cos(2 * phi)
            + 0.6 * math.sin(2 * theta + 1.1) * math.cos(3 * phi - 0.4)
            + 0.4 * math.sin(5 * theta) * math.sin(4 * phi + 0.7)
        )
        r = base_radius * (1.0 + amp * d)
        z = r * math.cos(theta)
        rr = r * math.sin(theta)
        x = rr * math.cos(phi)
        y = rr * math.sin(phi)
        return (x, y, z)

    verts = []
    for i in range(lat_segments + 1):
        theta = math.pi * i / lat_segments
        row = []
        for j in range(lon_segments):
            phi = 2 * math.pi * j / lon_segments
            # The displacement still varies with phi at the poles, so each
            # pole is one shared vertex; one per phi would leave the polar
            # fans' edges unshared and the mesh open there.
            pole = shared_poles and i in (0, lat_segments)
            row.append(displaced(theta, 0.0 if pole else phi))
        verts.append(row)

    tris: List[Tri] = []
    for i in range(lat_segments):
        for j in range(lon_segments):
            j2 = (j + 1) % lon_segments
            a = verts[i][j]
            b = verts[i + 1][j]
            c = verts[i + 1][j2]
            d = verts[i][j2]
            if i == 0:
                tris.append((a, b, c))
            elif i == lat_segments - 1:
                tris.append((a, b, d))
            else:
                tris += quad(a, b, c, d)
    return tris


def low_poly_head() -> List[Tri]:
    """
    Stylized geometric bust: head (chamfered box-ish via stacked sections)
    + neck + simple brow ridge + nose. All axis-aligned boxes, all outward.

    Roughly 50 mm tall, centered at origin in XY, base at z=0.
    """
    tris: List[Tri] = []
    # Neck: 20x20x15 mm at the bottom.
    tris += box_triangles(-10, -10, 0, 10, 10, 15)
    # Head main mass: 40x35x40 mm sitting on top of neck.
    tris += box_triangles(-20, -17.5, 15, 20, 17.5, 55)
    # Brow ridge: 30x4x4 mm bump on the front (-Y) face at eye-line.
    tris += box_triangles(-15, -19.5, 38, 15, -17.5, 42)
    # Nose: 5x6x10 mm protrusion in the center front.
    tris += box_triangles(-2.5, -23.5, 28, 2.5, -17.5, 38)
    # Crown: small 30x25x5 mm cap on top to break the boxy silhouette.
    tris += box_triangles(-15, -12.5, 55, 15, 12.5, 60)
    return tris


def main() -> None:
    out = fixtures_root() / "organic"

    # Lumpy blob: lat=24 lon=42 -> ≈ 2*42*23 = 1932 triangles (target ~2k).
    blob = lumpy_blob(base_radius=25.0, lat_segments=24, lon_segments=42)
    write_stl_binary(out / "lumpy_blob.stl", blob,
                     header="Refab Artist lumpy blob (sinusoidal displacement)")
    print("organic/lumpy_blob:", mesh_stats(blob).summary())

    head = low_poly_head()
    write_stl_binary(out / "low_poly_head.stl", head,
                     header="Refab Artist low-poly stylized head")
    print("organic/low_poly_head:", mesh_stats(head).summary())


if __name__ == "__main__":
    main()
