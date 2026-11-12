"""
Shared mesh-construction helpers for Refab Artist fixture generation scripts.

License: CC0 (Refab Artist project) — this code, and every fixture
produced by it, is dedicated to the public domain. The scripts ship in the
repo so that any reviewer can re-generate the fixtures and diff against the
committed bytes.

No third-party fixture content is consumed by this library. Everything is
synthesized from math.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple

import numpy as np
from stl import mesh as stlmesh


Vec3 = Tuple[float, float, float]
Tri = Tuple[Vec3, Vec3, Vec3]


# ---------- triangle construction ----------

def quad(a: Vec3, b: Vec3, c: Vec3, d: Vec3) -> List[Tri]:
    """Convert a CCW quad (a,b,c,d) to two triangles (a,b,c) + (a,c,d)."""
    return [(a, b, c), (a, c, d)]


def box_triangles(
    x0: float, y0: float, z0: float,
    x1: float, y1: float, z1: float,
    *,
    skip_faces: Iterable[str] = (),
) -> List[Tri]:
    """
    Axis-aligned box from (x0,y0,z0) to (x1,y1,z1). Faces wound CCW outward.

    skip_faces may contain any of: "+x" "-x" "+y" "-y" "+z" "-z" to omit that
    face entirely (used for open-shell fixtures).
    """
    skip = set(skip_faces)
    p000 = (x0, y0, z0)
    p100 = (x1, y0, z0)
    p110 = (x1, y1, z0)
    p010 = (x0, y1, z0)
    p001 = (x0, y0, z1)
    p101 = (x1, y0, z1)
    p111 = (x1, y1, z1)
    p011 = (x0, y1, z1)
    tris: List[Tri] = []
    if "-z" not in skip:
        # bottom face, normal -z, outward winding: looking from below CCW
        tris += quad(p000, p010, p110, p100)
    if "+z" not in skip:
        # top face, normal +z
        tris += quad(p001, p101, p111, p011)
    if "-y" not in skip:
        tris += quad(p000, p100, p101, p001)
    if "+y" not in skip:
        tris += quad(p010, p011, p111, p110)
    if "-x" not in skip:
        tris += quad(p000, p001, p011, p010)
    if "+x" not in skip:
        tris += quad(p100, p110, p111, p101)
    return tris


def inverted_box_triangles(
    x0: float, y0: float, z0: float,
    x1: float, y1: float, z1: float,
) -> List[Tri]:
    """Same box but with faces wound inward (used for hollow cavities)."""
    tris = box_triangles(x0, y0, z0, x1, y1, z1)
    return [(a, c, b) for (a, b, c) in tris]


def uv_sphere(radius: float, lat_segments: int, lon_segments: int,
              center: Vec3 = (0.0, 0.0, 0.0)) -> List[Tri]:
    """
    Closed UV sphere centered at `center`. Outward winding.
    Triangle count ≈ 2 * lon_segments * (lat_segments - 1).
    """
    cx, cy, cz = center
    verts = []
    # Build vertex grid (lat_segments+1 rows, lon_segments columns).
    for i in range(lat_segments + 1):
        theta = np.pi * i / lat_segments      # 0..pi
        z = radius * np.cos(theta)
        r = radius * np.sin(theta)
        row = []
        for j in range(lon_segments):
            phi = 2 * np.pi * j / lon_segments
            x = r * np.cos(phi)
            y = r * np.sin(phi)
            row.append((cx + x, cy + y, cz + z))
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
                # cap at north pole — degenerate top edge collapses to a point
                tris.append((a, b, c))
            elif i == lat_segments - 1:
                tris.append((a, b, d))
            else:
                tris += quad(a, b, c, d)
    return tris


def cylinder(radius: float, height: float, segments: int,
             center: Vec3 = (0.0, 0.0, 0.0)) -> List[Tri]:
    """
    Closed cylinder along +Z, centered horizontally at `center`, bottom at
    center.z, top at center.z + height. Outward winding. ~4*segments triangles.
    """
    cx, cy, cz = center
    z0 = cz
    z1 = cz + height
    ring_bot = []
    ring_top = []
    for j in range(segments):
        a = 2 * np.pi * j / segments
        x = radius * np.cos(a)
        y = radius * np.sin(a)
        ring_bot.append((cx + x, cy + y, z0))
        ring_top.append((cx + x, cy + y, z1))
    tris: List[Tri] = []
    center_bot = (cx, cy, z0)
    center_top = (cx, cy, z1)
    for j in range(segments):
        j2 = (j + 1) % segments
        # side quad
        tris += quad(ring_bot[j], ring_bot[j2], ring_top[j2], ring_top[j])
        # bottom fan (normal -z): wind so outward is -z
        tris.append((center_bot, ring_bot[j2], ring_bot[j]))
        # top fan (normal +z)
        tris.append((center_top, ring_top[j], ring_top[j2]))
    return tris


def torus(major_radius: float, minor_radius: float,
          major_segments: int, minor_segments: int,
          center: Vec3 = (0.0, 0.0, 0.0)) -> List[Tri]:
    """
    Standard torus, axis along +Z. Outward winding.
    Triangle count = 2 * major_segments * minor_segments.
    """
    cx, cy, cz = center
    grid = []
    for i in range(major_segments):
        u = 2 * np.pi * i / major_segments
        cu, su = np.cos(u), np.sin(u)
        row = []
        for j in range(minor_segments):
            v = 2 * np.pi * j / minor_segments
            cv, sv = np.cos(v), np.sin(v)
            x = (major_radius + minor_radius * cv) * cu
            y = (major_radius + minor_radius * cv) * su
            z = minor_radius * sv
            row.append((cx + x, cy + y, cz + z))
        grid.append(row)
    tris: List[Tri] = []
    for i in range(major_segments):
        i2 = (i + 1) % major_segments
        for j in range(minor_segments):
            j2 = (j + 1) % minor_segments
            a = grid[i][j]
            b = grid[i2][j]
            c = grid[i2][j2]
            d = grid[i][j2]
            tris += quad(a, b, c, d)
    return tris


def tetrahedron(size: float, center: Vec3 = (0.0, 0.0, 0.0)) -> List[Tri]:
    """Regular tetrahedron with circumscribing edge length ≈ size. 4 triangles."""
    s = size / 2.0
    cx, cy, cz = center
    a = (cx + s, cy + s, cz + s)
    b = (cx + s, cy - s, cz - s)
    c = (cx - s, cy + s, cz - s)
    d = (cx - s, cy - s, cz + s)
    return [
        (a, c, b),
        (a, b, d),
        (a, d, c),
        (b, c, d),
    ]


# ---------- STL writers ----------

def _flatten_for_numpy_stl(tris: Sequence[Tri]) -> np.ndarray:
    """Convert tri list to numpy-stl vector array."""
    n = len(tris)
    data = np.zeros(n, dtype=stlmesh.Mesh.dtype)
    for i, (a, b, c) in enumerate(tris):
        data["vectors"][i] = np.array([a, b, c], dtype=np.float32)
    return data


def write_stl_binary(path: Path, tris: Sequence[Tri], *, header: str = "") -> None:
    """Write a binary STL using numpy-stl with a fixed 80-byte header."""
    path.parent.mkdir(parents=True, exist_ok=True)
    data = _flatten_for_numpy_stl(tris)
    m = stlmesh.Mesh(data, remove_empty_areas=False)
    # Force header to a fixed deterministic value so re-runs produce identical bytes.
    hdr = header.encode("ascii", errors="ignore")[:80]
    hdr = hdr.ljust(80, b"\x00")
    # numpy-stl's save uses its own header by default; we control it via attribute.
    m.save(str(path), mode=stlmesh.stl.Mode.BINARY)
    # Overwrite the 80-byte header in-place with our deterministic value.
    with open(path, "r+b") as f:
        f.write(hdr)


def write_stl_ascii(path: Path, tris: Sequence[Tri], *, solid_name: str = "refabartist") -> None:
    """
    Write an ASCII STL by hand. Uses %.6f formatting so output is deterministic
    on every platform. Computes facet normals from the triangle winding (right-hand
    rule); falls back to (0,0,0) for degenerate triangles.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    lines: List[str] = [f"solid {solid_name}"]
    for a, b, c in tris:
        ax, ay, az = a
        bx, by, bz = b
        cx, cy, cz = c
        ux, uy, uz = bx - ax, by - ay, bz - az
        vx, vy, vz = cx - ax, cy - ay, cz - az
        nx = uy * vz - uz * vy
        ny = uz * vx - ux * vz
        nz = ux * vy - uy * vx
        nlen = (nx * nx + ny * ny + nz * nz) ** 0.5
        if nlen > 0:
            nx, ny, nz = nx / nlen, ny / nlen, nz / nlen
        lines.append(f"  facet normal {nx: .6f} {ny: .6f} {nz: .6f}")
        lines.append("    outer loop")
        lines.append(f"      vertex {ax: .6f} {ay: .6f} {az: .6f}")
        lines.append(f"      vertex {bx: .6f} {by: .6f} {bz: .6f}")
        lines.append(f"      vertex {cx: .6f} {cy: .6f} {cz: .6f}")
        lines.append("    endloop")
        lines.append("  endfacet")
    lines.append(f"endsolid {solid_name}")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def write_obj(path: Path, tris: Sequence[Tri], *, object_name: str = "refabartist") -> None:
    """Write a deterministic OBJ — vertex deduplication preserves index order."""
    path.parent.mkdir(parents=True, exist_ok=True)
    vert_index: dict = {}
    verts: List[Vec3] = []
    faces: List[Tuple[int, int, int]] = []
    for a, b, c in tris:
        idxs = []
        for v in (a, b, c):
            key = (round(v[0], 6), round(v[1], 6), round(v[2], 6))
            i = vert_index.get(key)
            if i is None:
                verts.append(key)
                i = len(verts)  # 1-based
                vert_index[key] = i
            idxs.append(i)
        faces.append(tuple(idxs))
    lines: List[str] = [
        "# Refab Artist fixture OBJ",
        f"o {object_name}",
    ]
    for x, y, z in verts:
        lines.append(f"v {x:.6f} {y:.6f} {z:.6f}")
    for i, j, k in faces:
        lines.append(f"f {i} {j} {k}")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


# ---------- numeric stats ----------

@dataclass
class MeshStats:
    triangle_count: int
    unique_vertex_count: int

    def summary(self) -> str:
        return f"triangles={self.triangle_count} vertices={self.unique_vertex_count}"


def mesh_stats(tris: Sequence[Tri]) -> MeshStats:
    verts = set()
    for a, b, c in tris:
        verts.add((round(a[0], 6), round(a[1], 6), round(a[2], 6)))
        verts.add((round(b[0], 6), round(b[1], 6), round(b[2], 6)))
        verts.add((round(c[0], 6), round(c[1], 6), round(c[2], 6)))
    return MeshStats(triangle_count=len(tris), unique_vertex_count=len(verts))


# ---------- repo paths ----------

def fixtures_root() -> Path:
    """Resolve tests/fixtures/ relative to this file (it lives in _scripts/)."""
    return Path(__file__).resolve().parent.parent
