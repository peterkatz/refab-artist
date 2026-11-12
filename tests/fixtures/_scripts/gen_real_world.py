#!/usr/bin/env python3
"""
Generate the real-world/ fixtures — silhouettes of objects an actual user of
Refab Artist might want to fabricate. All composed from primitives
or generated procedurally so provenance is 100% local-script. CC0.

  - simple_chair.stl: 6-piece chair silhouette (seat, back, 4 legs).
  - spur_gear_T20_M2.stl: extruded involute spur gear, 20 teeth, module 2,
    height 8 mm.

We deliberately do NOT include a logo or any branded shape — license-tricky.

Run from anywhere:
    python3 tests/fixtures/_scripts/gen_real_world.py
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


def simple_chair() -> List[Tri]:
    """
    Six-piece chair silhouette. Units: mm. Roughly real chair proportions
    miniaturized to fit in a 200x200x300 mm box for slicer testing.
    """
    tris: List[Tri] = []
    # Seat: 200x200x20 mm at z=180..200.
    tris += box_triangles(-100, -100, 180, 100, 100, 200)
    # Backrest: 200x20x150 mm at the back of the seat (y=80..100, z=200..350).
    tris += box_triangles(-100, 80, 200, 100, 100, 350)
    # Four legs: 20x20x180 mm at each seat corner.
    for sx in (-1, 1):
        for sy in (-1, 1):
            x0 = sx * 100 - 20 if sx > 0 else sx * 100
            x1 = x0 + 20
            y0 = sy * 100 - 20 if sy > 0 else sy * 100
            y1 = y0 + 20
            tris += box_triangles(x0, y0, 0, x1, y1, 180)
    return tris


def involute_point(base_radius: float, t: float) -> tuple:
    """One point on the involute of a circle, parameterized by roll angle t."""
    x = base_radius * (math.cos(t) + t * math.sin(t))
    y = base_radius * (math.sin(t) - t * math.cos(t))
    return (x, y)


def spur_gear_profile(teeth: int, module: float) -> List[tuple]:
    """
    Compute the 2D outline of an involute spur gear, returned as a CCW polygon
    of (x, y) tuples. Standard 20° pressure-angle profile, simplified:
      - addendum = module
      - dedendum = 1.25 * module
      - per-tooth samples: 6 involute points on each flank.

    The result is an approximation suitable as a test fixture; this is not
    a metrology-grade gear generator.
    """
    pressure_angle = math.radians(20.0)
    pitch_radius = module * teeth / 2.0
    base_radius = pitch_radius * math.cos(pressure_angle)
    addendum_radius = pitch_radius + module
    dedendum_radius = pitch_radius - 1.25 * module
    if dedendum_radius < 0.1:
        dedendum_radius = 0.1

    # t for which involute reaches addendum_radius:
    # |involute(t)| = base_radius * sqrt(1 + t^2) = addendum_radius
    t_max = math.sqrt((addendum_radius / base_radius) ** 2 - 1.0)
    # t for pitch radius
    t_pitch = math.sqrt(max(0.0, (pitch_radius / base_radius) ** 2 - 1.0))

    # Angular offset of the involute at pitch radius
    inv_pitch = math.atan2(*involute_point(base_radius, t_pitch)[::-1])

    # Tooth angular thickness at pitch circle = pi / teeth (half-thickness each side)
    tooth_angle = math.pi / teeth
    half_tooth = tooth_angle / 2.0

    n_samples = 6
    polygon: List[tuple] = []

    for i in range(teeth):
        # Center of this tooth.
        tooth_center = (2 * math.pi / teeth) * i

        # Rising (left) flank: involute from base to addendum.
        flank_left: List[tuple] = []
        for k in range(n_samples + 1):
            t = t_max * k / n_samples
            px, py = involute_point(base_radius, t)
            # Rotate so the involute crosses the pitch circle at -half_tooth from tooth_center.
            rotate_by = tooth_center - half_tooth - inv_pitch
            cx = px * math.cos(rotate_by) - py * math.sin(rotate_by)
            cy = px * math.sin(rotate_by) + py * math.cos(rotate_by)
            flank_left.append((cx, cy))

        # Top arc — a few points along addendum from end-of-left to start-of-right.
        end_left_angle = math.atan2(flank_left[-1][1], flank_left[-1][0])
        # Right flank is mirror of left across tooth-center.
        flank_right: List[tuple] = []
        for k in range(n_samples + 1):
            t = t_max * k / n_samples
            px, py = involute_point(base_radius, t)
            # Mirror: rotate by tooth_center + half_tooth + inv_pitch, then flip y about that radial.
            rotate_by = tooth_center + half_tooth + inv_pitch
            # mirror the flank by negating local y
            cx = px * math.cos(rotate_by) - (-py) * math.sin(rotate_by)
            cy = px * math.sin(rotate_by) + (-py) * math.cos(rotate_by)
            flank_right.append((cx, cy))
        # flank_right currently goes base->tip; we want tip->base.
        flank_right.reverse()

        start_right_angle = math.atan2(flank_right[0][1], flank_right[0][0])
        n_top = 3
        top_arc: List[tuple] = []
        for k in range(1, n_top):
            a = end_left_angle + (start_right_angle - end_left_angle) * k / n_top
            top_arc.append((addendum_radius * math.cos(a), addendum_radius * math.sin(a)))

        # Bottom arc (root) — go from end-of-right (back at base radius) to
        # start-of-left of NEXT tooth. We add the root arc here connecting to
        # next tooth's first flank point.
        end_right_angle = math.atan2(flank_right[-1][1], flank_right[-1][0])
        next_center = (2 * math.pi / teeth) * ((i + 1) % teeth)
        if i == teeth - 1:
            next_left_angle = (2 * math.pi) + math.atan2(
                polygon[0][1] if polygon else 0.0,
                polygon[0][0] if polygon else 1.0,
            )
        else:
            # Approx: next left flank starts roughly at next_center - half_tooth at root.
            next_left_angle = next_center - half_tooth - inv_pitch
        n_root = 3
        root_arc: List[tuple] = []
        for k in range(1, n_root):
            a = end_right_angle + (next_left_angle - end_right_angle) * k / n_root
            root_arc.append((dedendum_radius * math.cos(a), dedendum_radius * math.sin(a)))

        polygon += flank_left
        polygon += top_arc
        polygon += flank_right
        polygon += root_arc

    # The involute samples above are produced tooth-by-tooth, but the mirrored
    # flank math can wrap around +/-pi and create cross-gear jumps in list
    # order. The fixture contract is a simple CCW star-shaped profile, so sort
    # by polar angle before extrusion and fail generation if that contract is
    # violated.
    polygon.sort(key=lambda p: math.atan2(p[1], p[0]) % (2 * math.pi))
    assert_simple_polygon(polygon)
    return polygon


def assert_simple_polygon(polygon: List[tuple]) -> None:
    """Raise if a generated 2D fixture profile has proper self-crossings."""
    def orient(a: tuple, b: tuple, c: tuple) -> float:
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])

    def same(a: tuple, b: tuple) -> bool:
        return abs(a[0] - b[0]) <= 1e-9 and abs(a[1] - b[1]) <= 1e-9

    def crosses(a1: tuple, a2: tuple, b1: tuple, b2: tuple) -> bool:
        if same(a1, b1) or same(a1, b2) or same(a2, b1) or same(a2, b2):
            return False
        d1 = orient(a1, a2, b1)
        d2 = orient(a1, a2, b2)
        d3 = orient(b1, b2, a1)
        d4 = orient(b1, b2, a2)
        return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0))

    n = len(polygon)
    for i in range(n):
        a1 = polygon[i]
        a2 = polygon[(i + 1) % n]
        for j in range(i + 1, n):
            if abs(i - j) == 1 or abs(i - j) == n - 1:
                continue
            b1 = polygon[j]
            b2 = polygon[(j + 1) % n]
            if crosses(a1, a2, b1, b2):
                raise ValueError(f"generated polygon self-intersects at edges {i} and {j}")


def extrude_polygon(polygon: List[tuple], height: float) -> List[Tri]:
    """
    Extrude a 2D polygon (CCW, in XY) into a closed 3D solid from z=0 to z=height.
    Uses a centroid-fan to triangulate the top and bottom caps. This works for
    convex-ish star-shaped polygons (like the gear, which is star-shaped about
    its center).
    """
    cx = sum(p[0] for p in polygon) / len(polygon)
    cy = sum(p[1] for p in polygon) / len(polygon)
    center_bot: Vec3 = (cx, cy, 0.0)
    center_top: Vec3 = (cx, cy, height)
    tris: List[Tri] = []
    n = len(polygon)
    for i in range(n):
        x0, y0 = polygon[i]
        x1, y1 = polygon[(i + 1) % n]
        # side quad, outward winding (CCW polygon -> outward normal)
        a = (x0, y0, 0.0)
        b = (x1, y1, 0.0)
        c = (x1, y1, height)
        d = (x0, y0, height)
        tris += quad(a, b, c, d)
        # bottom triangle, normal -z: CCW when viewed from below
        tris.append((center_bot, b, a))
        # top triangle, normal +z
        tris.append((center_top, d, c))
    return tris


def main() -> None:
    out = fixtures_root() / "real-world"

    chair = simple_chair()
    write_stl_binary(out / "simple_chair.stl", chair,
                     header="Refab Artist simple chair (6-piece)")
    print("real-world/simple_chair:", mesh_stats(chair).summary())

    profile = spur_gear_profile(teeth=20, module=2.0)
    gear = extrude_polygon(profile, height=8.0)
    write_stl_binary(out / "spur_gear_T20_M2.stl", gear,
                     header="Refab Artist spur gear T=20 M=2 h=8mm")
    print("real-world/spur_gear_T20_M2:", mesh_stats(gear).summary())


if __name__ == "__main__":
    main()
