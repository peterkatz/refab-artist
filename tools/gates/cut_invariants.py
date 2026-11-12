#!/usr/bin/env python3
"""Cuttability invariants for Refab Artist's exported DXF.

Reads the DXF a user gets from Export (the same file `--headless-export
--format dxf` writes) and checks that its parts can be cut from the sheets it
lays them out on:

  FITS-SHEET            every part lies inside the sheet it was placed on
  NO-OVERLAP            no part's cuts reach into another part
  VALIDITY              every cut outline is closed, encloses area, does
                        not cross itself and does not pinch: touch itself
                        at a point between two lobes that are two pieces
                        held only there
  BISCUITS-IN-MATERIAL  every hole cut into a part (dowel or biscuit hole,
                        slot hole, a void of the model) lies inside the
                        part's material, clear of its edge (some material
                        left between them) and of other holes
  PART-COUNT            the file holds as many parts as the case should
                        export (when an expected count is given)
  SLOTS-FIT-MATERIAL    every slot cut into a part's edge is at least as wide
                        as the stock that seats in it (when a slot width is
                        given)
  MATERIAL-IN-MODEL     put back in the model from its part frame, every
                        part's material lies in the model: none of it more
                        than MATERIAL_OUTSIDE_TOL_MM outside the model's
                        section on the part's plane (when armed; the model
                        must be closed and wound consistently)

plus one quality metric that does not gate:

  CONTOUR-MATCHES-MESH  Hausdorff distance (mm) from each part outline to the
                        closest cross-section of the source mesh along the
                        case's slice axis

Layer conventions, as the Swift DXF writers emit them (DxfExporter,
CutSheetDocumentExporter.writeDXF):

  * `sheet_boundary`, `sheet_boundary_<n>`: one rectangle per sheet. The
    cut-sheet writer stacks sheets in +Y with a gap; the row-layout writers
    (Stacked, Radial) stack them edge to edge. `frame` is a sheet too.
  * `<label>_guide`: scored assembly guides, not cuts. `fold-line`: Folded
    Panels fold lines, perforated or scored, not part outlines.
  * `hole`: holes cut into whichever part contains them.
  * Every other layer is cut geometry. The cut-sheet writer gives each part a
    layer named after its label; the row-layout writers give each slice a
    layer, which may hold several separate pieces.

Parts are recovered from geometry. The LINE entities of a layer are chained
into loops. Where two loops cross, the smaller is a notch cut into the larger
if at least half of it lies inside the larger (a slot drawn across its
part's outline); otherwise they are two pieces cut on top of each other, and
NO-OVERLAP reports them. Groups are nested by containment, where even depth
is a part's outline and odd depth a hole in the part around it.
CIRCLE entities are holes of the part that contains their centre. TEXT
labels are ignored. Coordinates are millimetres.

Run:
    python3 tools/gates/cut_invariants.py --dxf <parts.dxf> --mesh <path> [--axis z]
"""

from __future__ import annotations

import argparse
import math
import re
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Sequence

import numpy as np


# ===========================================================================
# Tunables / defaults
# ===========================================================================

DEFAULT_HAUSDORFF_TOL_MM = 0.3       # contour metric threshold
SECTION_DECIMATION_MAX_POINTS = 720  # preserves sharp gear sections
ENDPOINT_TOL_MM = 1e-4               # endpoints closer than this are one point
                                     #   (the writers print 6 decimals)
FIT_TOL_MM = 1e-6                    # allowed overhang past a sheet edge
NOTCH_INSIDE_FRACTION = 0.5          # crossing loop this much inside its partner = a notch
NOTCH_SAMPLES = 32                   # grid samples per side when measuring that share
SLOT_WALL_ANGLE_TOL_DEG = 2.0        # slot walls this close to antiparallel
SLOT_WIDTH_TOL_MM = 0.01             # a slot may be this much narrower than its stock
MIN_LOOP_AREA_MM2 = 1e-6             # a loop below this encloses nothing
PINCH_TOL_MM = 1e-4                  # a corner this close to another stretch of its own loop touches it
HOLE_MIN_CLEARANCE_MM = 0.01         # a hole closer than this to its part's edge
                                     #   touches it: no material holds between them

SHEET_LAYER_PREFIX = "sheet_boundary"
FRAME_LAYER = "frame"
HOLE_LAYER = "hole"
SCORE_LAYERS = {"fold-line"}
SCORE_LAYER_SUFFIX = "_guide"


# ===========================================================================
# Mesh container + readers
# ===========================================================================

@dataclass
class Mesh:
    """Triangle soup: vertices (n,3) float64, faces (m,3) int."""
    vertices: np.ndarray
    faces: np.ndarray

    _tri_cache: Optional[np.ndarray] = field(default=None, repr=False, compare=False)

    @property
    def triangles(self) -> np.ndarray:
        """(m, 3, 3) array of triangle corner coordinates (cached)."""
        if self._tri_cache is None:
            self._tri_cache = self.vertices[self.faces]
        return self._tri_cache


def _read_stl(path: Path) -> Mesh:
    """Binary or ASCII STL."""
    data = path.read_bytes()

    # ASCII detection: starts with 'solid' AND contains 'facet'/'vertex' text.
    is_ascii = False
    if data[:5].lower() == b"solid":
        head = data[:2048].lower()
        if b"facet" in head or b"vertex" in head:
            is_ascii = True
        # If file size matches the binary layout exactly, prefer binary.
        if len(data) >= 84:
            n = struct.unpack_from("<I", data, 80)[0]
            if 84 + n * 50 == len(data):
                is_ascii = False

    tris: list[tuple[float, float, float]] = []
    if is_ascii:
        text = data.decode("utf-8", errors="replace")
        cur: list[tuple[float, float, float]] = []
        for line in text.splitlines():
            s = line.strip().split()
            if len(s) >= 4 and s[0] == "vertex":
                cur.append((float(s[1]), float(s[2]), float(s[3])))
            elif s and s[0] == "endfacet":
                if len(cur) >= 3:
                    # fan-triangulate any polygonal facet (STL is normally 3)
                    for i in range(1, len(cur) - 1):
                        tris.append(cur[0]); tris.append(cur[i]); tris.append(cur[i + 1])
                cur = []
        verts = np.asarray(tris, dtype=np.float64).reshape(-1, 3)
    else:
        if len(data) < 84:
            raise ValueError(f"{path}: too short to be a binary STL")
        n = struct.unpack_from("<I", data, 80)[0]
        expected = 84 + n * 50
        if expected != len(data):
            raise ValueError(
                f"{path}: binary STL size mismatch (header says {n} tris, "
                f"file is {len(data)} bytes, expected {expected})"
            )
        verts = np.empty((n * 3, 3), dtype=np.float64)
        off = 84
        for i in range(n):
            # 12 floats (normal + 3 verts) little-endian, then 2-byte attr
            f = struct.unpack_from("<12f", data, off)
            verts[i * 3 + 0] = f[3:6]
            verts[i * 3 + 1] = f[6:9]
            verts[i * 3 + 2] = f[9:12]
            off += 50

    if len(verts) == 0:
        raise ValueError(f"{path}: no triangles parsed")
    # Deduplicate vertices -> compact (verts, faces).
    uniq, inv = np.unique(np.round(verts, 8), axis=0, return_inverse=True)
    faces = inv.reshape(-1, 3).astype(np.int64)
    return Mesh(vertices=uniq, faces=faces)


def _read_obj(path: Path) -> Mesh:
    """OBJ v + f records, fan-triangulated."""
    verts: list[tuple[float, float, float]] = []
    faces: list[tuple[int, int, int]] = []
    for line in path.read_text(errors="replace").splitlines():
        s = line.strip().split()
        if not s:
            continue
        if s[0] == "v" and len(s) >= 4:
            verts.append((float(s[1]), float(s[2]), float(s[3])))
        elif s[0] == "f" and len(s) >= 4:
            idx = []
            for tok in s[1:]:
                vtok = tok.split("/")[0]
                if not vtok:
                    continue
                vi = int(vtok)
                idx.append(vi - 1 if vi > 0 else len(verts) + vi)
            for i in range(1, len(idx) - 1):
                faces.append((idx[0], idx[i], idx[i + 1]))
    if not verts or not faces:
        raise ValueError(f"{path}: no usable v/f records")
    return Mesh(
        vertices=np.asarray(verts, dtype=np.float64),
        faces=np.asarray(faces, dtype=np.int64),
    )


def load_mesh(path: Path) -> Mesh:
    ext = path.suffix.lower()
    if ext == ".stl":
        return _read_stl(path)
    if ext == ".obj":
        return _read_obj(path)
    raise ValueError(f"unsupported mesh extension: {path.suffix!r}")


# ===========================================================================
# DXF reading
# ===========================================================================

@dataclass
class DxfEntities:
    """LINE segments and CIRCLEs per layer, in file order."""
    lines: dict[str, list[tuple[float, float, float, float]]] = field(default_factory=dict)
    circles: dict[str, list[tuple[float, float, float]]] = field(default_factory=dict)


def read_dxf(path: Path) -> DxfEntities:
    """Read the ENTITIES section of an ASCII DXF as (group code, value) pairs."""
    rows = path.read_text(encoding="utf-8", errors="replace").splitlines()
    out = DxfEntities()
    kind: Optional[str] = None
    fields: dict[int, str] = {}
    in_entities = False

    def flush() -> None:
        if kind not in ("LINE", "CIRCLE"):
            return
        layer = fields.get(8, "0")
        try:
            if kind == "LINE":
                seg = (float(fields[10]), float(fields[20]), float(fields[11]), float(fields[21]))
                out.lines.setdefault(layer, []).append(seg)
            else:
                circle = (float(fields[10]), float(fields[20]), float(fields[40]))
                out.circles.setdefault(layer, []).append(circle)
        except (KeyError, ValueError) as exc:
            raise ValueError(f"{path}: malformed {kind} on layer {layer!r}") from exc

    for i in range(0, len(rows) - 1, 2):
        try:
            code = int(rows[i].strip())
        except ValueError as exc:
            raise ValueError(f"{path}:{i + 1}: expected a group code, got {rows[i]!r}") from exc
        value = rows[i + 1].strip()
        if code == 2 and value == "ENTITIES":
            in_entities = True
            continue
        if not in_entities:
            continue
        if code == 0:
            flush()
            if value == "ENDSEC":
                in_entities = False
                kind = None
            else:
                kind = value
            fields = {}
        else:
            fields[code] = value
    flush()
    return out


def is_sheet_layer(layer: str) -> bool:
    return layer == FRAME_LAYER or layer.startswith(SHEET_LAYER_PREFIX)


def is_score_layer(layer: str) -> bool:
    return layer in SCORE_LAYERS or layer.endswith(SCORE_LAYER_SUFFIX)


# ===========================================================================
# 2-D polygon geometry helpers
# ===========================================================================

def polygon_area(poly: np.ndarray) -> float:
    """Signed shoelace area (positive = CCW)."""
    x = poly[:, 0]
    y = poly[:, 1]
    return 0.5 * float(np.dot(x, np.roll(y, -1)) - np.dot(np.roll(x, -1), y))


def point_in_polygon(pt: np.ndarray, poly: np.ndarray) -> bool:
    """Ray-cast even-odd test. `poly` is (n,2), not closed-repeated."""
    x, y = float(pt[0]), float(pt[1])
    xi = poly[:, 0]
    yi = poly[:, 1]
    xj = np.roll(xi, 1)
    yj = np.roll(yi, 1)
    straddles = (yi > y) != (yj > y)
    with np.errstate(divide="ignore", invalid="ignore"):
        xint = (xj - xi) * (y - yi) / (yj - yi) + xi
    return bool(np.count_nonzero(straddles & (x < xint)) % 2)


def edges(poly: np.ndarray) -> np.ndarray:
    """(n,4) closed edge list [ax, ay, bx, by] of a loop."""
    return np.hstack([poly, np.roll(poly, -1, axis=0)])


def point_edge_distance(pt: np.ndarray, segs: np.ndarray) -> float:
    """Minimum distance from a point to a set of (n,4) segments."""
    if len(segs) == 0:
        return float("inf")
    ax, ay, bx, by = segs[:, 0], segs[:, 1], segs[:, 2], segs[:, 3]
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    with np.errstate(divide="ignore", invalid="ignore"):
        t = np.where(l2 > 0, ((pt[0] - ax) * dx + (pt[1] - ay) * dy) / l2, 0.0)
    t = np.clip(t, 0.0, 1.0)
    return float(np.hypot(pt[0] - (ax + t * dx), pt[1] - (ay + t * dy)).min())


def _orient(ax, ay, bx, by, cx, cy):
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)


def crossing_pairs(a: np.ndarray, b: np.ndarray, same: bool = False) -> np.ndarray:
    """Index pairs (i, j) where edge i of `a` properly crosses edge j of `b`.

    Both are (n,4) segment arrays. A proper crossing has the endpoints of each
    segment strictly on opposite sides of the other, so segments that only
    touch at a shared vertex (a self-touching outline, adjacent edges) do not
    count. With `same`, `a` and `b` are the edges of one loop and each pair is
    reported once.
    """
    if len(a) == 0 or len(b) == 0:
        return np.empty((0, 2), dtype=int)
    p1x, p1y, p2x, p2y = (a[:, k][:, None] for k in range(4))
    q1x, q1y, q2x, q2y = (b[:, k][None, :] for k in range(4))
    # Bounding-box rejection first; it removes almost every pair.
    overlap = (
        (np.minimum(p1x, p2x) <= np.maximum(q1x, q2x))
        & (np.minimum(q1x, q2x) <= np.maximum(p1x, p2x))
        & (np.minimum(p1y, p2y) <= np.maximum(q1y, q2y))
        & (np.minimum(q1y, q2y) <= np.maximum(p1y, p2y))
    )
    if same:
        overlap = np.triu(overlap, k=1)
    if not overlap.any():
        return np.empty((0, 2), dtype=int)
    i, j = np.nonzero(overlap)
    ax, ay, bx, by = a[i, 0], a[i, 1], a[i, 2], a[i, 3]
    cx, cy, dx, dy = b[j, 0], b[j, 1], b[j, 2], b[j, 3]
    scale = np.maximum.reduce([np.abs(bx - ax), np.abs(by - ay), np.abs(dx - cx), np.abs(dy - cy), np.ones_like(ax)])
    eps = 1e-12 * scale * scale
    d1 = _orient(cx, cy, dx, dy, ax, ay)
    d2 = _orient(cx, cy, dx, dy, bx, by)
    d3 = _orient(ax, ay, bx, by, cx, cy)
    d4 = _orient(ax, ay, bx, by, dx, dy)
    proper = (
        (((d1 > eps) & (d2 < -eps)) | ((d1 < -eps) & (d2 > eps)))
        & (((d3 > eps) & (d4 < -eps)) | ((d3 < -eps) & (d4 > eps)))
    )
    return np.stack([i[proper], j[proper]], axis=1)


def loops_cross(a: np.ndarray, b: np.ndarray) -> bool:
    return len(crossing_pairs(edges(a), edges(b))) > 0


def self_crossing(poly: np.ndarray) -> Optional[tuple[int, int]]:
    """First pair of non-adjacent edges that properly cross, or None."""
    n = len(poly)
    if n < 4:
        return None
    e = edges(poly)
    pairs = crossing_pairs(e, e, same=True)
    for i, j in pairs:
        if abs(int(i) - int(j)) in (1, n - 1):
            continue
        return int(i), int(j)
    return None


def pinch_point(loop: np.ndarray, tol: float = PINCH_TOL_MM) -> Optional[np.ndarray]:
    """Where an outline pinches: a corner lies on (within `tol` of) another
    stretch of the same outline, and the two lobes either side of that
    touch lie outside each other, so they are two pieces held together only
    at a point, whichever way each lobe turns (an outline drawn as a figure
    of eight, crossing over at the touch, has its lobes turned opposite
    ways). A lobe inside the other (a hole that reaches the edge) is not a
    pinch. Returns the touching corner, or None."""
    pts: list[np.ndarray] = []
    for q in np.asarray(loop, dtype=np.float64):
        if not pts or np.max(np.abs(q - pts[-1])) > tol:
            pts.append(q)
    while len(pts) > 1 and np.max(np.abs(pts[0] - pts[-1])) <= tol:
        pts.pop()
    n = len(pts)
    if n < 6:
        return None
    P = np.asarray(pts)
    A, B = P, np.roll(P, -1, axis=0)
    AB = B - A
    L2 = np.einsum("ij,ij->i", AB, AB)
    for start in range(0, n, 256):
        C = P[start:start + 256]
        AP = C[:, None, :] - A[None, :, :]
        with np.errstate(divide="ignore", invalid="ignore"):
            tt = np.where(L2[None, :] > 0, np.einsum("ijk,jk->ij", AP, AB) / L2[None, :], 0.0)
        tt = np.clip(tt, 0.0, 1.0)
        D = AP - tt[:, :, None] * AB[None, :, :]
        near = np.einsum("ijk,ijk->ij", D, D) <= tol * tol
        for ci, edge in zip(*np.nonzero(near)):
            corner = start + int(ci)
            edge = int(edge)
            nxt = (edge + 1) % n
            if edge == corner or nxt == corner:
                continue
            first, k = [], corner
            while True:
                first.append(P[k])
                if k == edge:
                    break
                k = (k + 1) % n
            second, k = [P[corner]], nxt
            while k != corner:
                second.append(P[k])
                k = (k + 1) % n
            if len(first) > 1 and np.max(np.abs(first[-1] - P[corner])) <= tol:
                first.pop()
            if len(second) > 1 and np.max(np.abs(second[1] - P[corner])) <= tol:
                second.pop(1)
            if len(first) < 3 or len(second) < 3:
                continue
            f, s = np.asarray(first), np.asarray(second)
            fa, sa = polygon_area(f), polygon_area(s)
            if abs(fa) <= tol or abs(sa) <= tol:
                continue
            if point_in_polygon((f[1] + f[2]) / 2, s) or point_in_polygon((s[1] + s[2]) / 2, f):
                continue
            return P[corner]
    return None


def bbox(points: np.ndarray) -> tuple[float, float, float, float]:
    return (
        float(points[:, 0].min()), float(points[:, 1].min()),
        float(points[:, 0].max()), float(points[:, 1].max()),
    )


def bboxes_overlap(a, b) -> bool:
    return not (a[2] < b[0] or b[2] < a[0] or a[3] < b[1] or b[3] < a[1])


def bbox_overlap_area(a, b) -> float:
    return max(0.0, min(a[2], b[2]) - max(a[0], b[0])) * max(0.0, min(a[3], b[3]) - max(a[1], b[1]))


# ===========================================================================
# Loop chaining: LINE segments -> closed loops and open chains
# ===========================================================================

def _same(p, q, tol: float = ENDPOINT_TOL_MM) -> bool:
    return abs(p[0] - q[0]) <= tol and abs(p[1] - q[1]) <= tol


def chain_segments(
    segments: Sequence[tuple[float, float, float, float]],
) -> tuple[list[np.ndarray], list[np.ndarray]]:
    """Chain LINE segments into closed loops and open chains.

    The writers emit each outline as consecutive segments sharing endpoints,
    so segments are chained in file order first; a chain closes when it gets
    back to its first point. Chains left open are then joined end to end
    wherever their endpoints coincide. Following file order keeps outlines
    that touch at a vertex (a gear's tooth roots) apart.

    Returns (loops, open_chains); loops are (n,2) arrays without the
    repeated closing point.
    """
    closed: list[list[tuple[float, float]]] = []
    open_chains: list[list[tuple[float, float]]] = []
    cur: Optional[list[tuple[float, float]]] = None

    for x1, y1, x2, y2 in segments:
        a, b = (x1, y1), (x2, y2)
        if _same(a, b):
            continue  # zero-length segment
        if cur is not None and _same(cur[-1], a):
            cur.append(b)
        elif cur is not None and _same(cur[-1], b):
            cur.append(a)
        else:
            if cur is not None:
                open_chains.append(cur)
            cur = [a, b]
        if len(cur) >= 4 and _same(cur[-1], cur[0]):
            closed.append(cur[:-1])
            cur = None
    if cur is not None:
        open_chains.append(cur)

    # Join open chains whose ends meet.
    merged = True
    while merged and len(open_chains) > 1:
        merged = False
        for i in range(len(open_chains)):
            for j in range(len(open_chains)):
                if i == j:
                    continue
                a, b = open_chains[i], open_chains[j]
                if _same(a[-1], b[0]):
                    joined = a + b[1:]
                elif _same(a[-1], b[-1]):
                    joined = a + b[-2::-1]
                else:
                    continue
                for k in sorted((i, j), reverse=True):
                    open_chains.pop(k)
                open_chains.append(joined)
                merged = True
                break
            if merged:
                break
    still_open = []
    for chain in open_chains:
        if len(chain) >= 4 and _same(chain[-1], chain[0]):
            closed.append(chain[:-1])
        else:
            still_open.append(chain)

    def as_array(points):
        arr = np.asarray(points, dtype=np.float64)
        keep = np.ones(len(arr), dtype=bool)
        keep[1:] = np.any(np.abs(np.diff(arr, axis=0)) > ENDPOINT_TOL_MM, axis=1)
        return arr[keep]

    return [as_array(c) for c in closed], [as_array(c) for c in still_open]


# ===========================================================================
# Parts
# ===========================================================================

@dataclass
class Part:
    layer: str
    name: str
    outline: np.ndarray
    holes: list[np.ndarray] = field(default_factory=list)
    notches: list[np.ndarray] = field(default_factory=list)
    circles: list[tuple[np.ndarray, float]] = field(default_factory=list)
    open_cuts: list[np.ndarray] = field(default_factory=list)
    sheet: Optional[str] = None

    @property
    def cut_loops(self) -> list[np.ndarray]:
        return [self.outline, *self.holes, *self.notches]

    @property
    def extent(self) -> tuple[float, float, float, float]:
        pts = [self.outline, *self.notches, *self.holes, *self.open_cuts]
        pts += [np.array([[c[0] - r, c[1] - r], [c[0] + r, c[1] + r]]) for c, r in self.circles]
        return bbox(np.vstack(pts))

    def in_material(self, pt: np.ndarray) -> bool:
        return point_in_polygon(pt, self.outline) and not any(point_in_polygon(pt, h) for h in self.holes)


@dataclass
class Layout:
    sheets: dict[str, tuple[float, float, float, float]]
    parts: list[Part]
    # Problems found while reading, charged to an invariant:
    stray_holes: list[tuple[str, str]]       # BISCUITS: (where, detail)
    stray_open_cuts: list[tuple[str, str]]   # VALIDITY: (where, detail)
    duplicate_loops: list[tuple[str, str]]   # VALIDITY: (where, detail)
    n_hole_layer_loops: int = 0              # mating slot holes on the `hole` layer


def _interior_probe(loop: np.ndarray) -> np.ndarray:
    """A point inside the loop: its first vertex nudged toward the inside.

    Containment between non-crossing loops only needs any point of the loop
    that does not lie on the other loop, but a vertex can sit exactly on a
    neighbour's edge; a point just inside avoids that.
    """
    n = len(loop)
    a, b, c = loop[-1], loop[0], loop[1 % n]
    bisector = (a - b) / (np.linalg.norm(a - b) or 1.0) + (c - b) / (np.linalg.norm(c - b) or 1.0)
    if np.linalg.norm(bisector) < 1e-12:
        bisector = np.array([-(c - b)[1], (c - b)[0]])
    bisector = bisector / (np.linalg.norm(bisector) or 1.0)
    span = max(np.ptp(loop[:, 0]), np.ptp(loop[:, 1]), 1e-9)
    step = 1e-6 * span
    for sign in (1.0, -1.0):
        probe = b + sign * step * bisector
        if point_in_polygon(probe, loop):
            return probe
    return loop.mean(axis=0)


def _loop_key(loop: np.ndarray) -> tuple:
    """Identity of a loop's path regardless of start point and direction."""
    return tuple(sorted(map(tuple, np.round(loop / ENDPOINT_TOL_MM).astype(np.int64))))


def split_duplicates(loops: list[np.ndarray]) -> tuple[list[np.ndarray], list[int]]:
    """Drop loops that retrace an earlier loop. Returns (unique loops, indices
    of the dropped ones in the input)."""
    seen: set[tuple] = set()
    unique, dropped = [], []
    for k, loop in enumerate(loops):
        key = _loop_key(loop)
        if key in seen:
            dropped.append(k)
        else:
            seen.add(key)
            unique.append(loop)
    return unique, dropped


def inside_fraction(small: np.ndarray, big: np.ndarray) -> float:
    """Share of `small`'s area that lies inside `big`, sampled on a grid."""
    x0, y0, x1, y1 = bbox(small)
    xs = x0 + (np.arange(NOTCH_SAMPLES) + 0.5) * (x1 - x0) / NOTCH_SAMPLES
    ys = y0 + (np.arange(NOTCH_SAMPLES) + 0.5) * (y1 - y0) / NOTCH_SAMPLES
    inside = [pt for pt in (np.array([x, y]) for x in xs for y in ys) if point_in_polygon(pt, small)]
    if not inside:
        return 0.0
    return sum(point_in_polygon(pt, big) for pt in inside) / len(inside)


def group_layer(layer: str, loops: list[np.ndarray]) -> tuple[list[Part], list[np.ndarray]]:
    """Group one layer's closed loops into parts. Returns (parts, orphan holes).

    Crossing loops are grouped only when the smaller one is a notch cut into
    the larger; any other crossing pair stays as two parts, which NO-OVERLAP
    then reports."""
    n = len(loops)
    if n == 0:
        return [], []
    parent = list(range(n))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    boxes = [bbox(l) for l in loops]
    areas = [abs(polygon_area(l)) for l in loops]
    pieces_crossing: list[tuple[int, int]] = []
    for i in range(n):
        for j in range(i + 1, n):
            if bboxes_overlap(boxes[i], boxes[j]) and loops_cross(loops[i], loops[j]):
                small, big = (i, j) if areas[i] <= areas[j] else (j, i)
                if inside_fraction(loops[small], loops[big]) >= NOTCH_INSIDE_FRACTION:
                    parent[find(i)] = find(j)
                else:
                    pieces_crossing.append((i, j))

    clusters: dict[int, list[int]] = {}
    for i in range(n):
        clusters.setdefault(find(i), []).append(i)
    groups = []
    rep_of_root = {}
    for root, members in clusters.items():
        rep = max(members, key=lambda k: areas[k])
        rep_of_root[root] = rep
        groups.append((rep, [m for m in members if m != rep]))
    # Loops that cross are not nested in one another.
    crossing_reps = {
        frozenset((rep_of_root[find(i)], rep_of_root[find(j)]))
        for i, j in pieces_crossing if find(i) != find(j)
    }

    probes = {rep: _interior_probe(loops[rep]) for rep, _ in groups}
    depth = {}
    for rep, _ in groups:
        depth[rep] = sum(
            1 for other, _ in groups
            if other != rep
            and frozenset((rep, other)) not in crossing_reps
            and point_in_polygon(probes[rep], loops[other])
        )

    parts_by_rep: dict[int, Part] = {}
    even = [(rep, rest) for rep, rest in groups if depth[rep] % 2 == 0]
    even.sort(key=lambda g: (bbox(loops[g[0]])[1], bbox(loops[g[0]])[0]))
    for k, (rep, rest) in enumerate(even):
        name = layer if len(even) == 1 else f"{layer}#{k + 1}"
        parts_by_rep[rep] = Part(layer=layer, name=name, outline=loops[rep],
                                 notches=[loops[m] for m in rest])
    orphans = []
    for rep, rest in groups:
        if depth[rep] % 2 == 0:
            continue
        holders = [r for r in parts_by_rep if point_in_polygon(probes[rep], loops[r])]
        if not holders:
            orphans.extend([loops[rep], *(loops[m] for m in rest)])
            continue
        holder = min(holders, key=lambda r: abs(polygon_area(loops[r])))
        parts_by_rep[holder].holes.extend([loops[rep], *(loops[m] for m in rest)])
    return list(parts_by_rep.values()), orphans


def _containing_part(parts: list[Part], pt: np.ndarray) -> Optional[Part]:
    """The part with the smallest outline containing `pt`."""
    holders = [p for p in parts if point_in_polygon(pt, p.outline)]
    if not holders:
        return None
    return min(holders, key=lambda p: abs(polygon_area(p.outline)))


def _hole_owner(parts: list[Part], loop: np.ndarray) -> Optional[Part]:
    """The part a hole is cut into: the one containing it, else the one whose
    outline it crosses (the hole then breaks the part's edge)."""
    owner = _containing_part(parts, _interior_probe(loop))
    if owner is not None:
        return owner
    box = bbox(loop)
    return next((p for p in parts if bboxes_overlap(box, bbox(p.outline)) and loops_cross(loop, p.outline)), None)


def build_layout(entities: DxfEntities) -> Layout:
    sheets = {}
    for layer, segs in entities.lines.items():
        if is_sheet_layer(layer):
            arr = np.asarray(segs, dtype=np.float64).reshape(-1, 2)
            sheets[layer] = bbox(arr)

    parts: list[Part] = []
    stray_holes: list[tuple[str, str]] = []
    stray_open: list[tuple[str, str]] = []
    duplicates: list[tuple[str, str]] = []
    hole_loops: list[np.ndarray] = []
    open_by_layer: dict[str, list[np.ndarray]] = {}

    for layer, segs in entities.lines.items():
        if is_sheet_layer(layer) or is_score_layer(layer):
            continue
        loops, open_chains = chain_segments(segs)
        # A loop written twice is cut twice; nest the rest without it.
        loops, dropped = split_duplicates(loops)
        for k in dropped:
            duplicates.append((layer, f"loop {k + 1} retraces another loop on the layer (cut twice)"))
        if layer == HOLE_LAYER:
            hole_loops.extend(loops)
            open_by_layer.setdefault(layer, []).extend(open_chains)
            continue
        layer_parts, orphans = group_layer(layer, loops)
        parts.extend(layer_parts)
        for orphan in orphans:
            stray_holes.append((layer, "hole loop outside every outline on its layer"))
        open_by_layer.setdefault(layer, []).extend(open_chains)

    # Holes on the shared `hole` layer belong to the part that contains them.
    for k, loop in enumerate(hole_loops):
        owner = _hole_owner(parts, loop)
        if owner is None:
            stray_holes.append((f"{HOLE_LAYER}#{k + 1}", "hole outside every part"))
        else:
            owner.holes.append(loop)

    # Circles are holes of the part (on their own layer) containing the centre.
    for layer, circles in entities.circles.items():
        if is_sheet_layer(layer) or is_score_layer(layer):
            continue
        candidates = parts if layer == HOLE_LAYER else [p for p in parts if p.layer == layer]
        for k, (cx, cy, r) in enumerate(circles):
            centre = np.array([cx, cy])
            owner = _containing_part(candidates, centre)
            if owner is None:
                stray_holes.append((f"{layer}@circle{k + 1}", f"circle r={r:.3f}mm centred outside every part"))
            else:
                owner.circles.append((centre, r))

    # Open chains are cuts that never close: kept on the part around them.
    for layer, chains in open_by_layer.items():
        candidates = parts if layer == HOLE_LAYER else [p for p in parts if p.layer == layer]
        for chain in chains:
            owner = _containing_part(candidates, chain[0])
            if owner is not None:
                owner.open_cuts.append(chain)
            else:
                stray_open.append((layer, f"open cut path of {len(chain)} points outside every outline"))

    for part in parts:
        part.sheet = _assign_sheet(part, sheets)
    return Layout(sheets=sheets, parts=parts, stray_holes=stray_holes,
                  stray_open_cuts=stray_open, duplicate_loops=duplicates,
                  n_hole_layer_loops=len(hole_loops))


def _assign_sheet(part: Part, sheets: dict[str, tuple[float, float, float, float]]) -> Optional[str]:
    """The sheet the part is on: the one its extent overlaps most."""
    if not sheets:
        return None
    ext = part.extent
    best = max(sheets, key=lambda s: (bbox_overlap_area(ext, sheets[s]), -_box_distance(ext, sheets[s])))
    return best


def _box_distance(a, b) -> float:
    dx = max(0.0, max(a[0], b[0]) - min(a[2], b[2]))
    dy = max(0.0, max(a[1], b[1]) - min(a[3], b[3]))
    return math.hypot(dx, dy)


# ===========================================================================
# Mesh cross-section: triangles -> segments at plane -> stitched loops (mm)
# ===========================================================================

_AXIS_INDEX = {"x": 0, "y": 1, "z": 2}


def axis_indices(axis: str) -> tuple[int, int, int]:
    """Return (cut_axis, u, v) where u,v are the two in-plane axes."""
    a = _AXIS_INDEX[axis]
    plane = [i for i in (0, 1, 2) if i != a]
    return a, plane[0], plane[1]


def mesh_section_segments(mesh: Mesh, axis: str, coord: float) -> np.ndarray:
    """Vectorized triangle-plane intersection.

    Returns an (k, 4) array of [u1, v1, u2, v2] segments (mm) for every
    triangle that straddles the plane axis=coord. The standard two-crossing
    case is handled vectorially; the rare exact-vertex-on-plane case is
    folded into the edge-crossing logic via a tiny epsilon nudge.
    """
    a, u, v = axis_indices(axis)
    tris = mesh.triangles  # (m, 3, 3)
    if len(tris) == 0:
        return np.empty((0, 4), dtype=np.float64)

    dz = tris[:, :, a] - coord  # (m, 3) signed dist per vertex
    # Nudge exact-zero vertices to a definite side so each crossed edge yields
    # exactly one point and a straddling triangle yields exactly two.
    dz = np.where(np.abs(dz) < 1e-12, 1e-12, dz)

    s = dz > 0.0                       # (m,3) side flags
    npos = s.sum(axis=1)
    straddle = (npos == 1) | (npos == 2)
    if not straddle.any():
        return np.empty((0, 4), dtype=np.float64)

    T = tris[straddle]                 # (k,3,3)
    D = dz[straddle]                   # (k,3)
    S = s[straddle]                    # (k,3)

    # For each of the 3 edges, does it cross? (endpoints on opposite sides)
    tri_edges = [(0, 1), (1, 2), (2, 0)]
    cross_pts = np.full((len(T), 3, 2), np.nan, dtype=np.float64)
    for ei, (i, j) in enumerate(tri_edges):
        di = D[:, i]; dj = D[:, j]
        crosses = S[:, i] != S[:, j]
        denom = di - dj
        denom = np.where(denom == 0.0, 1.0, denom)  # guard; masked by `crosses`
        t = di / denom
        pu = T[:, i, u] + t * (T[:, j, u] - T[:, i, u])
        pv = T[:, i, v] + t * (T[:, j, v] - T[:, i, v])
        cross_pts[crosses, ei, 0] = pu[crosses]
        cross_pts[crosses, ei, 1] = pv[crosses]

    # Each straddling triangle has exactly two crossed edges. Gather the two
    # non-NaN crossing points per triangle without a Python loop: sort the 3
    # edge slots so the (exactly two) valid ones come first.
    valid = ~np.isnan(cross_pts[:, :, 0])         # (k,3)
    order = np.argsort(~valid, axis=1, kind="stable")  # valid (False) first
    rows = np.arange(len(T))[:, None]
    ordered = cross_pts[rows, order]              # (k,3,2)
    n_valid = valid.sum(axis=1)
    keep = n_valid >= 2
    segs = np.empty((len(T), 4), dtype=np.float64)
    segs[:, 0:2] = ordered[:, 0, :]
    segs[:, 2:4] = ordered[:, 1, :]
    return segs[keep]


def stitch_section(segs_arr: np.ndarray, quant: float = 1e-4) -> list[np.ndarray]:
    """Stitch mesh-section segments into loops.

    Quantizes endpoints onto a grid (`quant` mm) so coincident endpoints hash
    to the same key, builds an endpoint->segment adjacency, then walks each
    connected chain. Manifold sections close cleanly; any leftover open chain
    (rare, non-manifold) is still returned if it has >=3 points so the
    contour metric can evaluate it.

    `segs_arr` is an (n,4) array of [x1,y1,x2,y2].
    """
    n = len(segs_arr)
    if n == 0:
        return []

    def key(x, y):
        return (int(round(x / quant)), int(round(y / quant)))

    from collections import defaultdict
    adj: dict[tuple[int, int], list[tuple[int, tuple[int, int]]]] = defaultdict(list)
    nodes = np.empty((n, 2), dtype=object)
    for i in range(n):
        x1, y1, x2, y2 = segs_arr[i]
        k1 = key(x1, y1)
        k2 = key(x2, y2)
        nodes[i, 0] = k1
        nodes[i, 1] = k2
        adj[k1].append((i, k2))
        adj[k2].append((i, k1))

    coord_of: dict[tuple[int, int], tuple[float, float]] = {}
    for i in range(n):
        x1, y1, x2, y2 = segs_arr[i]
        coord_of.setdefault(nodes[i, 0], (x1, y1))
        coord_of.setdefault(nodes[i, 1], (x2, y2))

    used = np.zeros(n, dtype=bool)
    loops: list[np.ndarray] = []

    for s in range(n):
        if used[s]:
            continue
        start_node = nodes[s, 0]
        cur_node = start_node
        chain_nodes: list[tuple[int, int]] = [cur_node]
        seg = s
        guard = 0
        while guard <= n:
            guard += 1
            used[seg] = True
            a, b = nodes[seg, 0], nodes[seg, 1]
            nxt = b if cur_node == a else a
            chain_nodes.append(nxt)
            cur_node = nxt
            if cur_node == start_node:
                break
            found = -1
            for (si, _other) in adj[cur_node]:
                if not used[si]:
                    found = si
                    break
            if found < 0:
                break
            seg = found

        if len(chain_nodes) >= 2 and chain_nodes[0] == chain_nodes[-1]:
            chain_nodes = chain_nodes[:-1]
        pts = [coord_of[k] for k in chain_nodes]
        if len(pts) >= 3:
            loops.append(np.array(pts, dtype=np.float64))
    return loops


def mesh_section(mesh: Mesh, axis: str, coord: float) -> list[np.ndarray]:
    """Intersect the mesh with the plane axis=coord; return loops in (u,v) mm."""
    return stitch_section(mesh_section_segments(mesh, axis, coord))


# ===========================================================================
# Hausdorff distance (point-to-segment, symmetric)
# ===========================================================================

def _dirhaus_pts_to_poly(pts: np.ndarray, poly: np.ndarray) -> float:
    """Max over pts of min distance to any edge of poly (one-directional)."""
    ax = poly[:, 0]; ay = poly[:, 1]
    bx = np.roll(ax, -1); by = np.roll(ay, -1)
    dx = bx - ax; dy = by - ay
    L2 = dx * dx + dy * dy
    L2 = np.where(L2 <= 1e-300, 1e-300, L2)

    px = pts[:, 0][:, None]   # (P,1)
    py = pts[:, 1][:, None]
    t = ((px - ax[None, :]) * dx[None, :] + (py - ay[None, :]) * dy[None, :]) / L2[None, :]
    t = np.clip(t, 0.0, 1.0)
    cx = ax[None, :] + t * dx[None, :]
    cy = ay[None, :] + t * dy[None, :]
    d = np.hypot(px - cx, py - cy)         # (P,E)
    return float(d.min(axis=1).max())


def _decimate(poly: np.ndarray, max_pts: int) -> np.ndarray:
    """Evenly subsample a loop's vertices to at most `max_pts` points.

    Bounds the Hausdorff cost on very dense mesh sections (a finely
    tessellated circle has thousands of near-redundant points).
    """
    n = len(poly)
    if n <= max_pts:
        return poly
    idx = np.linspace(0, n, num=max_pts, endpoint=False).astype(int)
    return poly[idx]


def hausdorff(a: np.ndarray, b: np.ndarray, b_query: Optional[np.ndarray] = None) -> float:
    """Symmetric point-to-segment Hausdorff distance between two loops.

    `b_query`, if given, is a decimated vertex set of `b` used only as the
    query points for the b->a direction (the a->b direction still uses every
    edge of `b`).
    """
    bq = b if b_query is None else b_query
    return max(_dirhaus_pts_to_poly(a, b), _dirhaus_pts_to_poly(bq, a))


# ===========================================================================
# Result reporting
# ===========================================================================

@dataclass
class Violation:
    where: str
    detail: str
    value: float


@dataclass
class InvariantResult:
    name: str
    passed: bool
    worst_value: float
    worst_where: str
    violations: list[Violation] = field(default_factory=list)
    note: str = ""

    @property
    def n_violations(self) -> int:
        return len(self.violations)


# ===========================================================================
# The invariants
# ===========================================================================

def check_fits_sheet(layout: Layout) -> InvariantResult:
    """Every part's cuts lie inside the sheet it overlaps most."""
    worst, worst_where = 0.0, ""
    violations: list[Violation] = []
    if not layout.sheets:
        for part in layout.parts:
            violations.append(Violation(part.name, "the file has no sheet outline", float("inf")))
        return InvariantResult("FITS-SHEET", not violations, float("inf") if violations else 0.0,
                               violations[0].where if violations else "", violations,
                               "no sheet_boundary or frame layer")
    for part in layout.parts:
        sx0, sy0, sx1, sy1 = layout.sheets[part.sheet]
        bx0, by0, bx1, by1 = part.extent
        overhang = max(sx0 - bx0, sy0 - by0, bx1 - sx1, by1 - sy1)
        if overhang > worst:
            worst, worst_where = overhang, part.name
        if overhang > FIT_TOL_MM:
            violations.append(Violation(part.name, f"{overhang:.3f}mm past the edge of {part.sheet}", overhang))
    return InvariantResult("FITS-SHEET", not violations, worst, worst_where, violations)


def check_no_overlap(layout: Layout) -> InvariantResult:
    """No part's outline or notches cross another part, and no part sits in
    another part's material."""
    worst, worst_where = 0.0, ""
    violations: list[Violation] = []
    parts = layout.parts
    extents = [p.extent for p in parts]
    outer_edges = [np.vstack([edges(l) for l in [p.outline, *p.notches]]) for p in parts]
    for i in range(len(parts)):
        for j in range(i + 1, len(parts)):
            if not bboxes_overlap(extents[i], extents[j]):
                continue
            p, q = parts[i], parts[j]
            crossing = len(crossing_pairs(outer_edges[i], outer_edges[j])) > 0
            nested = q.in_material(_interior_probe(p.outline)) or p.in_material(_interior_probe(q.outline))
            if crossing or nested:
                area = bbox_overlap_area(extents[i], extents[j])
                where = f"{p.name}<->{q.name}"
                if area > worst:
                    worst, worst_where = area, where
                kind = "outlines cross" if crossing else "one part lies in the other's material"
                violations.append(Violation(where, f"{kind} (overlap box {area:.2f}mm^2)", area))
    return InvariantResult("NO-OVERLAP", not violations, worst, worst_where, violations)


def check_validity(layout: Layout) -> InvariantResult:
    """Every cut loop is closed, encloses area and does not cross itself; no
    part's outline pinches (`pinch_point`); no cut path is left open or
    written twice."""
    worst, worst_where = float("inf"), ""
    violations: list[Violation] = []
    for where, detail in layout.stray_open_cuts + layout.duplicate_loops:
        violations.append(Violation(where, detail, 0.0))
    for part in layout.parts:
        for chain in part.open_cuts:
            violations.append(Violation(part.name, f"open cut path of {len(chain)} points", 0.0))
        for k, loop in enumerate(part.cut_loops):
            where = part.name if k == 0 else f"{part.name}#loop{k + 1}"
            distinct = len(np.unique(np.round(loop, 6), axis=0))
            if distinct < 3:
                violations.append(Violation(where, f"only {distinct} distinct vertices", 0.0))
                continue
            area = abs(polygon_area(loop))
            if area < worst:
                worst, worst_where = area, where
            if area < MIN_LOOP_AREA_MM2:
                violations.append(Violation(where, f"encloses {area:.2e}mm^2", area))
                continue
            pair = self_crossing(loop)
            if pair is not None:
                violations.append(Violation(where, f"crosses itself (edges {pair[0]} and {pair[1]})", area))
                continue
            if k == 0:
                pinch = pinch_point(loop)
                if pinch is not None:
                    violations.append(Violation(
                        where, f"pinches at ({pinch[0]:.3f}, {pinch[1]:.3f}): two pieces held only at a point", area))
    if worst == float("inf"):
        worst = 0.0
    return InvariantResult("VALIDITY", not violations, worst, worst_where, violations)


def loop_clearance(a: np.ndarray, b: np.ndarray) -> float:
    """Least distance between two loops that do not cross: from a vertex of
    one to an edge of the other, whichever way round is nearer."""
    a_edges, b_edges = edges(a), edges(b)
    return min(min(point_edge_distance(p, b_edges) for p in a),
               min(point_edge_distance(p, a_edges) for p in b))


def check_holes_in_material(layout: Layout) -> InvariantResult:
    """Every hole and circle lies inside its part's outline and outside the
    part's other holes, with material between it and the part's edge
    (at least HOLE_MIN_CLEARANCE_MM)."""
    worst, worst_where = float("inf"), ""
    violations: list[Violation] = []
    n_holes = 0
    for where, detail in layout.stray_holes:
        n_holes += 1
        violations.append(Violation(where, detail, -1.0))
        worst, worst_where = min(worst, -1.0), where
    for part in layout.parts:
        outline_edges = edges(part.outline)
        hole_edges = [edges(h) for h in part.holes]
        for k, hole in enumerate(part.holes):
            n_holes += 1
            where = f"{part.name}#hole{k + 1}"
            if len(crossing_pairs(edges(hole), outline_edges)) > 0:
                violations.append(Violation(where, "crosses the part outline", -1.0))
                worst, worst_where = min(worst, -1.0), where
                continue
            if not point_in_polygon(_interior_probe(hole), part.outline):
                violations.append(Violation(where, "lies outside the part outline", -1.0))
                worst, worst_where = min(worst, -1.0), where
                continue
            others = [m for m in range(len(part.holes)) if m != k]
            clash = next((m for m in others
                          if len(crossing_pairs(hole_edges[k], hole_edges[m])) > 0
                          or point_in_polygon(_interior_probe(hole), part.holes[m])), None)
            if clash is not None:
                violations.append(Violation(where, f"overlaps hole {clash + 1} (no material around it)", -1.0))
                worst, worst_where = min(worst, -1.0), where
                continue
            clearance = loop_clearance(hole, part.outline)
            if clearance < worst:
                worst, worst_where = clearance, where
            if clearance < HOLE_MIN_CLEARANCE_MM:
                violations.append(Violation(
                    where, f"touches the part outline ({clearance:.3f}mm of material between them)", clearance))
        for k, (centre, radius) in enumerate(part.circles):
            n_holes += 1
            where = f"{part.name}@circle{k + 1}"
            inside = part.in_material(centre)
            edge_distance = min([point_edge_distance(centre, outline_edges)]
                                + [point_edge_distance(centre, e) for e in hole_edges])
            clearance = edge_distance - radius if inside else -(edge_distance + radius)
            if clearance < worst:
                worst, worst_where = clearance, where
            if not inside:
                violations.append(Violation(where, "centre is not in the part's material", clearance))
            elif clearance < 0:
                violations.append(Violation(where, f"cuts {-clearance:.3f}mm past the material edge", clearance))
            elif clearance < HOLE_MIN_CLEARANCE_MM:
                violations.append(Violation(
                    where, f"touches the material edge ({clearance:.3f}mm of material between them)", clearance))
    if worst == float("inf"):
        worst = 0.0
    note = "" if n_holes else "no holes present"
    return InvariantResult("BISCUITS-IN-MATERIAL", not violations, worst, worst_where, violations, note)


def check_part_count(layout: Layout, expected: Optional[int]) -> InvariantResult:
    """The file holds the number of parts the case should export."""
    found = len(layout.parts)
    if expected is None:
        return InvariantResult("PART-COUNT", True, 0.0, "", [], "no expected count given")
    if found == expected:
        return InvariantResult("PART-COUNT", True, 0.0, "", [])
    detail = f"{found} parts, expected {expected}"
    return InvariantResult("PART-COUNT", False, float(found - expected), "file",
                           [Violation("file", detail, float(found - expected))])


def slot_widths(outline: np.ndarray) -> list[tuple[int, float]]:
    """(vertex index, width) of every slot cut into an outline's edge.

    A slot is three edges: a wall going in, the slot bottom, and a wall coming
    back out antiparallel to the first, with the outline turning inward at
    both bottom corners. Its width is the distance between the walls. A slot
    with a wall on the outline's own extent (a slot at the end of a part,
    with no material past that wall) is not counted.
    """
    poly = np.asarray(outline, dtype=np.float64)
    if polygon_area(poly) < 0:
        poly = poly[::-1]
    n = len(poly)
    if n < 4:
        return []
    cos_tol = math.cos(math.radians(SLOT_WALL_ANGLE_TOL_DEG))
    found = []
    for i in range(n):
        p0, p1, p2, p3 = poly[i], poly[(i + 1) % n], poly[(i + 2) % n], poly[(i + 3) % n]
        e1, e2, e3 = p1 - p0, p2 - p1, p3 - p2
        l1, l2, l3 = (float(np.hypot(*e)) for e in (e1, e2, e3))
        if min(l1, l2, l3) <= ENDPOINT_TOL_MM:
            continue
        d1, d2, d3 = e1 / l1, e2 / l2, e3 / l3
        if float(np.dot(d1, d3)) > -cos_tol:
            continue
        # Both bottom corners turn clockwise: inward on a CCW outline.
        if d1[0] * d2[1] - d1[1] * d2[0] >= 0 or d2[0] * d3[1] - d2[1] * d3[0] >= 0:
            continue
        wall = d1 - d3
        wall = wall / float(np.hypot(*wall))
        normal = np.array([-wall[1], wall[0]])
        offsets = poly @ normal
        lo, hi = float(offsets.min()), float(offsets.max())
        walls = (float((p0 + p1) @ normal) / 2, float((p2 + p3) @ normal) / 2)
        if any(abs(w - lo) <= 1e-3 or abs(w - hi) <= 1e-3 for w in walls):
            continue
        found.append(((i + 1) % n, abs(float(wall[0] * e2[1] - wall[1] * e2[0]))))
    return found


def check_slots_fit_material(layout: Layout, slot_width: Optional[float]) -> InvariantResult:
    """Every slot cut into a part's edge is at least `slot_width` wide: the
    stock it seats must fit."""
    if slot_width is None:
        return InvariantResult("SLOTS-FIT-MATERIAL", True, 0.0, "", [], "no slot width given")
    worst, worst_where = float("inf"), ""
    violations: list[Violation] = []
    n_slots = 0
    for part in layout.parts:
        for vertex, width in slot_widths(part.outline):
            n_slots += 1
            shortfall = width - slot_width
            where = f"{part.name}@vertex{vertex}"
            if shortfall < worst:
                worst, worst_where = shortfall, where
            if shortfall < -SLOT_WIDTH_TOL_MM:
                violations.append(Violation(
                    where, f"slot is {width:.3f}mm wide, narrower than the {slot_width:.3f}mm stock", shortfall))
    if worst == float("inf"):
        worst = 0.0
    note = "" if n_slots else "no slots present"
    return InvariantResult("SLOTS-FIT-MATERIAL", not violations, worst, worst_where, violations, note)


def check_slot_count(layout: Layout, expected: Optional[int], count_part_holes: bool = False) -> InvariantResult:
    """The file holds the joint cuts the case should export: slots cut into
    part edges plus mating slot holes on the `hole` layer, or, with
    `count_part_holes`, every hole cut into a part."""
    if expected is None:
        return InvariantResult("SLOT-COUNT", True, 0.0, "", [], "no expected slot count given")
    holes = sum(len(p.holes) + len(p.circles) for p in layout.parts) if count_part_holes else layout.n_hole_layer_loops
    found = sum(len(slot_widths(p.outline)) for p in layout.parts) + holes
    if found == expected:
        return InvariantResult("SLOT-COUNT", True, 0.0, "", [])
    detail = f"{found} slots, expected {expected}"
    return InvariantResult("SLOT-COUNT", False, float(found - expected), "file",
                           [Violation("file", detail, float(found - expected))])


# ===========================================================================
# Joints: the parts put back in the model
# ===========================================================================
#
# A part-frames file (`--part-frames`, written beside the DXF) gives, for each
# part label, the affine map from its DXF coordinates to model coordinates:
# model = dxfToModel @ (x, y, 1). With it the parts go back where they belong
# in the model, and every place two of them cross can be checked.
#
# Two parts cross along the line their planes share. Along that line, and
# along eight lines around the beam where their two slabs of stock overlap
# (its corners and the middles of its sides, a hair inside its faces), the
# parts' material must not overlap: if it does, the parts pass through each
# other. A slot narrower than the other part's stock at the angle they cross
# (`t·(1 + |cos a|) / sin a` for stock `t` and angle `a`) leaves material at a
# corner of the beam. Parts of different families (a label's prefix: "Z" and
# "C" in "Z-3", "C-5") are meant to be joined there: within each span where
# the line runs through the model, each part keeps material on one side and
# the two together fill the span (half-lap slots whose depths add up).
# A part that stops short of the crossing (no material on the line, and none
# on one side of it: the part ends there) takes no part in it; the other part
# must then fill the span by itself (no slot with nothing to fill it). A part
# with material on both sides of the line but none on it has a slot cut right
# through it there: it does take part, and the joint does not hold.

JOINT_MIN_SPAN_MM = 0.2      # a model span shorter than this is grazing contact
JOINT_OVERLAP_TOL_MM = 0.02  # material overlap allowed along a crossing
JOINT_GAP_TOL_MM = 1.0       # unfilled length allowed in a joint (crowded slots merge up to 1 mm webs)
PARALLEL_SINE = 0.05         # parts this close to parallel do not cross
BEAM_INSET_MM = 0.02         # how far inside each part's faces the lines around the beam run
BESIDE_MARGIN_MM = 1.0       # past twice the beam's half-width, where a part's material beside a crossing is looked for
PARALLEL_GRID = 40           # samples across a part's longer side when comparing parallel parts
PARALLEL_OVERLAP_TOL_MM2 = 1.0  # outline area two parallel parts closer than the stock may share


def load_part_frames(path: Path) -> dict[str, np.ndarray]:
    """label -> 3x3 dxfToModel matrix."""
    import json
    data = json.loads(Path(path).read_text())
    return {p["label"]: np.asarray(p["dxfToModel"], dtype=np.float64) for p in data["parts"]}


def load_folded_frames(path: Path) -> list[dict]:
    """The Folded Panels nets of a part-frames file (`folds`), if any."""
    import json
    return json.loads(Path(path).read_text()).get("folds", [])


def load_detached_labels(path: Path) -> set[str]:
    """The labels the part-frames file marks `"detached": true`: parts the
    cut sheet shows blue, as not joined to the rest of the model."""
    import json
    data = json.loads(Path(path).read_text())
    return {p["label"] for p in data["parts"] if p.get("detached")}


@dataclass
class PlacedPart:
    part: Part
    family: str
    linear: np.ndarray    # (3,2): DXF direction -> model direction
    offset: np.ndarray    # (3,): model point of DXF (0, 0)
    to_dxf: np.ndarray    # (2,3): model direction -> DXF direction (in-plane)
    normal: np.ndarray
    plane: float          # normal . point on the plane

    def dxf(self, point: np.ndarray) -> np.ndarray:
        return self.to_dxf @ (point - self.offset)

    def model_points(self, pts: np.ndarray) -> np.ndarray:
        return pts @ self.linear.T + self.offset


def part_family(label: str) -> str:
    """The family a part belongs to, from its label: the prefix of a
    cut-sheet label ("Z" in "Z-3", "C" in "C-5-2") or a row-layout layer name
    without its number ("first_axis" in "first_axis_003", "radial" in
    "radial_012")."""
    return re.sub(r"_\d+$", "", label.split("-")[0])


def place_parts(layout: Layout, frames: dict[str, np.ndarray]) -> tuple[list[PlacedPart], list[str]]:
    """Parts with a frame, and the labels of parts that have none."""
    placed, missing = [], []
    for part in layout.parts:
        m = frames.get(part.layer)
        if m is None:
            missing.append(part.name)
            continue
        linear, offset = m[:, :2], m[:, 2]
        normal = np.cross(linear[:, 0], linear[:, 1])
        normal = normal / (np.linalg.norm(normal) or 1.0)
        placed.append(PlacedPart(part=part, family=part_family(part.layer), linear=linear, offset=offset,
                                 to_dxf=np.linalg.pinv(linear), normal=normal,
                                 plane=float(normal @ offset)))
    return placed, missing


def _merge(spans: list[tuple[float, float]]) -> list[tuple[float, float]]:
    out: list[tuple[float, float]] = []
    for lo, hi in sorted(spans):
        if out and lo <= out[-1][1] + 1e-9:
            out[-1] = (out[-1][0], max(out[-1][1], hi))
        else:
            out.append((lo, hi))
    return out


def _span_length(spans) -> float:
    return sum(hi - lo for lo, hi in spans)


def _intersect(a, b) -> list[tuple[float, float]]:
    out = []
    for lo1, hi1 in a:
        for lo2, hi2 in b:
            lo, hi = max(lo1, lo2), min(hi1, hi2)
            if hi > lo:
                out.append((lo, hi))
    return _merge(out)


def part_spans(placed: PlacedPart, origin: np.ndarray, direction: np.ndarray) -> list[tuple[float, float]]:
    """Where the model line origin + u * direction runs through the part's
    material (its outline minus holes and notches), as spans of u. The line
    is projected onto the part's plane."""
    p0 = placed.dxf(origin)
    p1 = placed.dxf(origin + direction)
    d = p1 - p0
    length = float(np.hypot(*d))
    if length < 1e-9:
        return []
    d = d / length
    scale = 1.0 / length  # DXF distance per unit of u
    loops = [placed.part.outline, *placed.part.holes, *placed.part.notches]
    us = []
    for loop in loops:
        a = loop
        b = np.roll(loop, -1, axis=0)
        sa = (a[:, 0] - p0[0]) * d[1] - (a[:, 1] - p0[1]) * d[0]
        sb = (b[:, 0] - p0[0]) * d[1] - (b[:, 1] - p0[1]) * d[0]
        cross = (sa > 0) != (sb > 0)
        t = sa[cross] / (sa[cross] - sb[cross])
        pts = a[cross] + t[:, None] * (b[cross] - a[cross])
        us.extend(((pts - p0) @ d).tolist())
    us = sorted(us)
    spans = []
    for lo, hi in zip(us, us[1:]):
        if hi - lo < 1e-9:
            continue
        mid = p0 + d * (lo + hi) / 2
        if placed.part.in_material(mid) and not any(point_in_polygon(mid, n) for n in placed.part.notches):
            spans.append((lo * scale, hi * scale))
    return _merge(spans)


def mesh_spans(mesh: Mesh, origin: np.ndarray, direction: np.ndarray) -> list[tuple[float, float]]:
    """Where the line runs inside the mesh, as spans of u. A point is inside
    where the surfaces around it wind round it: the line enters the model
    where it crosses a triangle from its outside (the side its winding faces)
    and leaves where it crosses one from inside, so shells that overlap
    count once, not as a hole, and a cavity whose surface faces into it is
    outside. Where one shell ends exactly where the next begins the span
    stops and starts again there. The line is nudged a hair off its course
    so it never runs exactly through a mesh edge or vertex."""
    direction = direction / np.linalg.norm(direction)
    helper = np.array([0.5773, 0.5774, 0.5775])
    side = np.cross(direction, helper)
    if np.linalg.norm(side) < 1e-6:
        side = np.cross(direction, np.array([1.0, 0.0, 0.0]))
    side = side / np.linalg.norm(side)
    up = np.cross(direction, side)
    o = origin + 1.37e-4 * side + 0.91e-4 * up
    tri = mesh.triangles
    v0, e1, e2 = tri[:, 0], tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0]
    pvec = np.cross(direction, e2)
    det = np.einsum("ij,ij->i", e1, pvec)
    ok = np.abs(det) > 1e-12
    inv = np.where(ok, 1.0 / np.where(ok, det, 1.0), 0.0)
    tvec = o - v0
    u = np.einsum("ij,ij->i", tvec, pvec) * inv
    qvec = np.cross(tvec, e1)
    v = (qvec @ direction) * inv
    t = np.einsum("ij,ij->i", e2, qvec) * inv
    hit = ok & (u >= 0) & (v >= 0) & (u + v <= 1)
    # det > 0: the line meets the triangle's outside face (it enters).
    steps = np.where(det[hit] > 0, 1, -1)
    order = np.lexsort((steps, t[hit]))  # by u; leaving before entering at one u
    spans: list[tuple[float, float]] = []
    winding, start = 0, 0.0
    for at, step in zip(t[hit][order], steps[order]):
        before, winding = winding, winding + int(step)
        if before == 0 and winding != 0:
            start = float(at)
        elif before != 0 and winding == 0:
            spans.append((start, float(at)))
    return spans


@dataclass
class Rib:
    """The parts cut from one plane (a slice's pieces)."""
    name: str
    family: str
    pieces: list[PlacedPart]

    @property
    def normal(self) -> np.ndarray:
        return self.pieces[0].normal

    @property
    def plane(self) -> float:
        return self.pieces[0].plane

    def spans(self, origin: np.ndarray, direction: np.ndarray) -> list[tuple[float, float]]:
        return _merge([s for piece in self.pieces for s in part_spans(piece, origin, direction)])

    def reaches(self, origin: np.ndarray, direction: np.ndarray, span: tuple[float, float], beside: float) -> bool:
        """Whether the rib takes part in a crossing along origin + u * direction
        within `span`: it has material on the line there, or on both sides of
        it `beside` mm away in its own plane (a slot cut through it)."""
        if _intersect(self.spans(origin, direction), [span]):
            return True
        side = np.cross(self.normal, direction)
        side = side / (np.linalg.norm(side) or 1.0)
        return all(_intersect(self.spans(origin + k * beside * side, direction), [span]) for k in (-1.0, 1.0))


def parallel_overlap(p: Rib, q: Rib, stock: float) -> float:
    """How much of two (nearly) parallel ribs' outlines (mm^2, sampled) lies
    over each other where they stand closer than the stock, so their slabs
    share material: the points of p's material within the stock of q's plane
    that land in q's material."""
    shared = 0.0
    for piece in p.pieces:
        # Nowhere within the stock of q's plane: nothing to sample.
        corners = piece.model_points(piece.part.outline)
        if np.min(np.abs(corners @ q.normal - q.plane)) >= stock - JOINT_OVERLAP_TOL_MM and \
                np.ptp(np.sign(corners @ q.normal - q.plane)) == 0:
            continue
        x0, y0, x1, y1 = bbox(piece.part.outline)
        step = max(x1 - x0, y1 - y0) / PARALLEL_GRID
        if step <= 0:
            continue
        xs = np.arange(x0 + step / 2, x1, step)
        ys = np.arange(y0 + step / 2, y1, step)
        for x in xs:
            for y in ys:
                pt = np.array([x, y])
                if not piece.part.in_material(pt):
                    continue
                model = piece.model_points(pt[None, :])[0]
                if abs(float(q.normal @ model) - q.plane) >= stock - JOINT_OVERLAP_TOL_MM:
                    continue
                if any(other.part.in_material(other.dxf(model)) for other in q.pieces):
                    shared += step * step
    return shared


def ribs_of(placed: list[PlacedPart]) -> list[Rib]:
    ribs: list[Rib] = []
    for piece in placed:
        for rib in ribs:
            same_plane = (rib.family == piece.family
                          and np.linalg.norm(np.cross(rib.normal, piece.normal)) < 1e-6
                          and abs(rib.normal @ piece.offset - rib.plane) < 1e-6)
            if same_plane:
                rib.pieces.append(piece)
                rib.name += f"+{piece.part.name}"
                break
        else:
            ribs.append(Rib(name=piece.part.name, family=piece.family, pieces=[piece]))
    return ribs


def check_joints(layout: Layout, frames: Optional[dict[str, np.ndarray]], mesh: Optional[Mesh],
                 stock: Optional[float], expected_joints: Optional[int],
                 detached: Optional[set[str]] = None) -> tuple[InvariantResult, InvariantResult, InvariantResult]:
    """SLOTS-MATE, PARTS-CLEAR and PARTS-JOINED.

    SLOTS-MATE: wherever two parts of different families cross inside the
    model, they are joined by mating slots: along their crossing line each
    model span is filled by the two parts' material without overlap (the slot
    depths add up), each part keeps some material along the crossing (the
    joint holds), and along the lines around the beam the material does not
    overlap either (each slot is wide enough for the other part's stock at
    the angle they cross).
    PARTS-CLEAR: no two parts of one family pass through each other, and no
    two parallel parts stand closer than the stock where their outlines
    overlap (their slabs would share material).
    PARTS-JOINED: the joints hold every part to the rest of the model. Two
    parts are joined where both keep material along the line of a joint that
    holds; the parts fall into groups, the largest (most parts, then most
    material) is the model, and every part outside it must be one the
    part-frames file marks `detached` (the cut sheet shows it blue, to be
    glued), and every part so marked must lie outside it.
    """
    if expected_joints is None:
        note = "no part frames given"
        return (InvariantResult("SLOTS-MATE", True, 0.0, "", [], note),
                InvariantResult("PARTS-CLEAR", True, 0.0, "", [], note),
                InvariantResult("PARTS-JOINED", True, 0.0, "", [], note))
    if frames is None or mesh is None or stock is None:
        missing = "part frames" if frames is None else "the model" if mesh is None else "the stock thickness"
        v = [Violation("file", f"no {missing} to check the joints against", 0.0)]
        return (InvariantResult("SLOTS-MATE", False, 0.0, "file", v),
                InvariantResult("PARTS-CLEAR", False, 0.0, "file", list(v)),
                InvariantResult("PARTS-JOINED", False, 0.0, "file", list(v)))

    placed, unframed = place_parts(layout, frames)
    mate: list[Violation] = [Violation(name, "part has no frame in the part-frames file", 0.0) for name in unframed]
    clear: list[Violation] = []
    worst_overlap, worst_where = 0.0, ""
    joints = 0
    ribs = ribs_of(placed)
    # Which parts the joints hold together (union-find over `placed`).
    group = list(range(len(placed)))
    index = {id(piece): k for k, piece in enumerate(placed)}

    def root(k: int) -> int:
        while group[k] != k:
            group[k] = group[group[k]]
            k = group[k]
        return k
    for i in range(len(ribs)):
        for j in range(i + 1, len(ribs)):
            p, q = ribs[i], ribs[j]
            cross = np.cross(p.normal, q.normal)
            sine = float(np.linalg.norm(cross))
            if sine < PARALLEL_SINE:
                shared = parallel_overlap(p, q, stock)
                if shared > PARALLEL_OVERLAP_TOL_MM2:
                    gap = abs(float(p.normal @ q.pieces[0].offset) - p.plane)
                    clear.append(Violation(
                        f"{p.name}x{q.name}",
                        f"the parts pass through each other: {gap:.3f}mm apart in {stock:g}mm stock, "
                        f"their stock shares {shared:.1f}mm^2",
                        shared))
                continue
            d = cross / sine
            system = np.vstack([p.normal, q.normal, d])
            origin = np.linalg.solve(system, np.array([p.plane, q.plane, 0.0]))
            where = f"{p.name}x{q.name}"
            joined = p.family != q.family
            # Material overlap along the line and the lines around the beam:
            # (h1, h2) is the depth into each part's stock off its plane.
            overlap = 0.0
            edge = max(0.0, stock / 2 - BEAM_INSET_MM)
            for h1 in (0.0, -edge, edge):
                for h2 in (0.0, -edge, edge):
                    o = origin + np.linalg.solve(system, np.array([h1, h2, 0.0]))
                    overlap = max(overlap, _span_length(_intersect(p.spans(o, d), q.spans(o, d))))
            if overlap > worst_overlap:
                worst_overlap, worst_where = overlap, where
            if overlap > JOINT_OVERLAP_TOL_MM:
                target = mate if joined else clear
                kind = ("the parts collide where they cross: a slot is missing, too shallow or too narrow"
                        if joined else "the parts pass through each other and are not joined")
                target.append(Violation(where, f"{kind} ({overlap:.3f}mm of material overlaps)", overlap))
            if not joined:
                continue
            ps, qs = p.spans(origin, d), q.spans(origin, d)
            # Twice the half-width of the beam in either part's plane: past
            # any slot that seats the other part's stock.
            beside = stock * (1.0 + abs(float(p.normal @ q.normal))) / sine + BESIDE_MARGIN_MM
            held_p = held_q = 0.0
            crossed = False
            for span in mesh_spans(mesh, origin, d):
                if span[1] - span[0] < JOINT_MIN_SPAN_MM:
                    continue
                inside_p, inside_q = _intersect(ps, [span]), _intersect(qs, [span])
                if not inside_p and not inside_q:
                    continue  # no part was cut from this stretch of the model
                if not (p.reaches(origin, d, span, beside) and q.reaches(origin, d, span, beside)):
                    # One part stops short of the crossing: nothing to join,
                    # and the other part must not be slotted there.
                    gap = (span[1] - span[0]) - _span_length(_merge(inside_p + inside_q))
                    if gap > JOINT_GAP_TOL_MM:
                        at = f"{where}@[{span[0]:.2f},{span[1]:.2f}]"
                        mate.append(Violation(at, f"a slot leaves {gap:.3f}mm of the model empty where no part crosses", gap))
                    continue
                joints += 1
                crossed = True
                held_p += _span_length(inside_p)
                held_q += _span_length(inside_q)
                holders = [index[id(piece)] for rib in (p, q) for piece in rib.pieces
                           if _span_length(_intersect(part_spans(piece, origin, d), [span])) > JOINT_OVERLAP_TOL_MM]
                for k in holders[1:]:
                    group[root(k)] = root(holders[0])
                gap = (span[1] - span[0]) - _span_length(_merge(inside_p + inside_q))
                if gap > JOINT_GAP_TOL_MM:
                    at = f"{where}@[{span[0]:.2f},{span[1]:.2f}]"
                    mate.append(Violation(at, f"the slots leave {gap:.3f}mm of the crossing empty: their depths do not add up", gap))
            # Each part keeps some material along the crossing, or the other
            # passes through it unheld (a slot cut right through).
            if crossed and min(held_p, held_q) <= JOINT_OVERLAP_TOL_MM:
                holder = q.name if held_p <= JOINT_OVERLAP_TOL_MM else p.name
                mate.append(Violation(where, f"only {holder} keeps material where they cross: the joint does not hold", 0.0))
    if joints != expected_joints:
        mate.append(Violation("file", f"{joints} joints, expected {expected_joints}", float(joints - expected_joints)))
    note = f"{joints} joints checked"
    return (InvariantResult("SLOTS-MATE", not mate, worst_overlap, worst_where, mate, note),
            InvariantResult("PARTS-CLEAR", not clear, worst_overlap, worst_where, clear, note),
            parts_joined(placed, [root(k) for k in range(len(placed))], detached or set()))


def parts_joined(placed: list[PlacedPart], groups: list[int], detached: set[str]) -> InvariantResult:
    """PARTS-JOINED from the group each placed part's joints put it in (see
    `check_joints`)."""
    sizes: dict[int, tuple[int, float]] = {}
    for piece, g in zip(placed, groups):
        count, area = sizes.get(g, (0, 0.0))
        sizes[g] = (count + 1, area + abs(polygon_area(piece.part.outline)))
    main = max(sizes, key=lambda g: sizes[g]) if sizes else None
    outside = [piece.part.layer for piece, g in zip(placed, groups) if g != main]
    violations = [Violation(label, "not joined to the rest of the model, and not marked to be glued (detached)", 1.0)
                  for label in sorted(set(outside) - detached)]
    violations += [Violation(label, "marked detached, but its joints hold it to the rest of the model", 1.0)
                   for label in sorted(detached & {piece.part.layer for piece, g in zip(placed, groups) if g == main})]
    groups_found = sorted((c for c, _a in sizes.values()), reverse=True)
    note = f"joint groups {groups_found}" + (f"; {len(set(outside))} parts marked detached" if outside else "")
    return InvariantResult("PARTS-JOINED", not violations, float(len(set(outside) - detached)), "", violations, note)


# ===========================================================================
# Folded Panels: the nets folded back up
# ===========================================================================
#
# A Folded Panels part is a net of panels joined by fold lines. Its entry in
# the part-frames file (`folds`) gives, for each panel, the map from DXF to
# model coordinates, the direction from its outside face into its stock
# (the stock lies on the inside of the model surface), the panel's outline
# and the joint features that stand out of it (tabs, lugs, fingers), all in
# DXF coordinates, and which panels a fold joins. A panel's material is the
# part's material (outline less holes) inside its outline or features.
#
# Folded up, every panel is a slab of stock behind its net. Two panels joined
# by a fold are one piece bent there and are not compared. Any other two must
# not pass into each other: along lines running through both slabs (parallel
# to where their planes meet, on a grid across both thicknesses) their
# material must not overlap. A tab that misses its slot, a lug its mate runs
# into, or a seam whose stock was not cut back all show up as overlap.

MATERIAL_GRID_MM = 0.5         # spacing of the points checked inside each part
MATERIAL_OUTSIDE_TOL_MM = 0.5  # how far a part's material may lie outside the model's section


def plane_section(mesh: Mesh, placed: PlacedPart) -> np.ndarray:
    """The model's section on a placed part's plane, in the part's DXF
    coordinates: (n, 4) segments [ax, ay, bx, by], each run with the model's
    material on its left as the triangle it was cut from faces (its winding
    points out of the material). A corner exactly on the plane counts as
    below it, so the segments join into closed loops."""
    tri = mesh.triangles
    s = tri @ placed.normal - placed.plane                     # (m, 3)
    above = s > 0
    count = above.sum(axis=1)
    crossing = (count == 1) | (count == 2)
    tri, s, above = tri[crossing], s[crossing], above[crossing]
    if len(tri) == 0:
        return np.empty((0, 4))
    points = []
    for i, j in ((0, 1), (1, 2), (2, 0)):
        cut = above[:, i] != above[:, j]
        with np.errstate(divide="ignore", invalid="ignore"):
            f = np.where(cut, s[:, i] / (s[:, i] - s[:, j]), 0.0)
        points.append((cut, tri[:, i] + f[:, None] * (tri[:, j] - tri[:, i])))
    # Each crossing triangle has exactly two cut edges: the first two found.
    first = np.where(points[0][0][:, None], points[0][1], points[1][1])
    second = np.where(points[0][0][:, None] & points[1][0][:, None], points[1][1], points[2][1])
    a = (first - placed.offset) @ placed.to_dxf.T
    b = (second - placed.offset) @ placed.to_dxf.T
    normal = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0]) @ placed.to_dxf.T
    d = b - a
    left = np.stack([-d[:, 1], d[:, 0]], axis=1)
    # The winding points out of the material: turn the segment so it does
    # not point to the segment's left.
    swap = np.einsum("ij,ij->i", left, normal) > 0
    a2 = np.where(swap[:, None], b, a)
    b2 = np.where(swap[:, None], a, b)
    keep = np.hypot(*(b2 - a2).T) > 1e-12
    return np.hstack([a2[keep], b2[keep]])


def section_winding(points: np.ndarray, segments: np.ndarray) -> np.ndarray:
    """The winding number of each point about the oriented section
    `segments` (non-zero: inside the model; overlapping shells count once)."""
    out = np.zeros(len(points), dtype=int)
    if len(segments) == 0:
        return out
    ax, ay, bx, by = (segments[:, k][None, :] for k in range(4))
    for start in range(0, len(points), 512):
        x = points[start:start + 512, 0][:, None]
        y = points[start:start + 512, 1][:, None]
        side = (bx - ax) * (y - ay) - (x - ax) * (by - ay)
        up = (ay <= y) & (by > y) & (side > 0)
        down = (by <= y) & (ay > y) & (side < 0)
        out[start:start + 512] = up.sum(axis=1) - down.sum(axis=1)
    return out


def segment_distance(points: np.ndarray, segments: np.ndarray) -> np.ndarray:
    """Each point's distance to the nearest of `segments`."""
    out = np.full(len(points), np.inf)
    if len(segments) == 0 or len(points) == 0:
        return out
    a, b = segments[:, :2], segments[:, 2:]
    ab = b - a
    l2 = np.maximum(np.einsum("ij,ij->i", ab, ab), 1e-24)
    for start in range(0, len(points), 256):
        p = points[start:start + 256]
        ap = p[:, None, :] - a[None, :, :]
        tt = np.clip(np.einsum("ijk,jk->ij", ap, ab) / l2[None, :], 0.0, 1.0)
        dd = ap - tt[:, :, None] * ab[None, :, :]
        out[start:start + 256] = np.sqrt(np.einsum("ijk,ijk->ij", dd, dd).min(axis=1))
    return out


def material_samples(part: Part, step: float = MATERIAL_GRID_MM) -> np.ndarray:
    """Points on a `step` grid inside a part's material: inside its
    outline, outside its holes and notches."""
    x0, y0, x1, y1 = bbox(part.outline)
    xs = np.arange(x0 + step / 2, x1, step)
    ys = np.arange(y0 + step / 2, y1, step)
    if len(xs) == 0 or len(ys) == 0:
        return np.empty((0, 2))
    grid = np.stack(np.meshgrid(xs, ys), axis=-1).reshape(-1, 2)
    keep = _inside_many(grid, _edge_arrays(part.outline))
    for loop in [*part.holes, *part.notches]:
        if not keep.any():
            break
        keep &= ~_inside_many(grid, _edge_arrays(loop))
    return grid[keep]


def mesh_is_closed(mesh: Mesh) -> bool:
    """Whether every edge of the mesh (corners at one position are one
    vertex) is used by an even number of triangles: no crack or hole."""
    tri = np.round(mesh.triangles, 6).reshape(-1, 3)
    _, ids = np.unique(tri, axis=0, return_inverse=True)
    ids = ids.reshape(-1, 3)
    e = np.concatenate([ids[:, [0, 1]], ids[:, [1, 2]], ids[:, [2, 0]]])
    e = np.sort(e, axis=1)
    e = e[e[:, 0] != e[:, 1]]
    _, counts = np.unique(e, axis=0, return_counts=True)
    return bool(np.all(counts % 2 == 0))


def check_material_in_model(layout: Layout, frames: Optional[dict[str, np.ndarray]],
                            mesh: Optional[Mesh], armed: bool) -> InvariantResult:
    """MATERIAL-IN-MODEL: put back in the model, every part's material lies
    in the model. Each part is placed by its frame, the model is cut by the
    part's plane, and every point of a MATERIAL_GRID_MM grid inside the
    part's material (outline minus holes and notches) must lie inside that
    section, read from the triangles' winding as `mesh_spans` reads it, or
    within MATERIAL_OUTSIDE_TOL_MM of its edge. Slots, notches and trimmed
    hairlines only take material away; material outside the model is a
    hole of the model cut solid, a loop turned the wrong way, or a piece
    that is not the model's. The model must be closed and wound
    consistently (a case whose own mesh is not names one that is, as the
    functional gate's REFERENCE_MESH does); an open mesh fails the check
    rather than being read wrongly."""
    if not armed:
        return InvariantResult("MATERIAL-IN-MODEL", True, 0.0, "", [], "not armed")
    if frames is None or mesh is None:
        missing = "part frames" if frames is None else "the model"
        v = [Violation("file", f"no {missing} to check the material against", 0.0)]
        return InvariantResult("MATERIAL-IN-MODEL", False, 0.0, "file", v)
    if not mesh_is_closed(mesh):
        v = [Violation("model", "the model is not closed: its inside cannot be read from its winding", 0.0)]
        return InvariantResult("MATERIAL-IN-MODEL", False, 0.0, "model", v)
    placed, unframed = place_parts(layout, frames)
    violations = [Violation(name, "part has no frame in the part-frames file", 0.0) for name in unframed]
    worst, worst_where = 0.0, ""
    cell = MATERIAL_GRID_MM * MATERIAL_GRID_MM
    for piece in placed:
        samples = material_samples(piece.part)
        if len(samples) == 0:
            continue
        segments = plane_section(mesh, piece)
        outside = samples[section_winding(samples, segments) == 0]
        if len(outside) == 0:
            continue
        distance = segment_distance(outside, segments)
        far = distance > MATERIAL_OUTSIDE_TOL_MM
        deepest = float(distance.max())
        if deepest > worst:
            worst, worst_where = deepest, piece.part.name
        if far.any():
            violations.append(Violation(
                piece.part.name,
                f"{far.sum() * cell:.1f} mm^2 of material lies outside the model, up to {deepest:.2f} mm "
                f"(a hole of the model cut solid, or material that is not the model's)",
                deepest))
    return InvariantResult("MATERIAL-IN-MODEL", not violations, worst, worst_where, violations)


FOLD_DEPTH_SAMPLES = 5        # lines across each slab's thickness
FOLD_PARALLEL_GRID = 14       # points per side sampled on near-parallel panels
FOLD_COVER_STEP_MM = 0.25     # spacing of the points checked along a net's outline
FOLD_COVER_GRID_MM = 1.0      # spacing of the points checked inside a net
FOLD_COVER_TOL_MM = 0.05      # how far a net's material may lie outside its panels and features
FOLD_HOLE_GRID = 5            # points per side sampled across a slot hole or a protrusion
FOLD_CONTACT_MM = 0.05        # a protrusion this close to another panel's stock rests on it


@dataclass
class FoldedPanel:
    name: str
    net: str
    part: Part
    regions: list[np.ndarray]
    linear: np.ndarray    # (3,2): DXF direction -> model direction
    offset: np.ndarray    # (3,): model point of DXF (0, 0)
    to_dxf: np.ndarray    # (2,3)
    inward: np.ndarray    # unit, from the outside face into the stock
    cuts: list[np.ndarray] = field(default_factory=list)   # the part's holes and notches near the panel

    def __post_init__(self):
        box = bbox(np.vstack(self.regions))
        self.cuts = [c for c in [*self.part.holes, *self.part.notches] if bboxes_overlap(bbox(c), box)]
        # Edge arrays for the even-odd test, built once.
        self._regions = [_edge_arrays(r) for r in self.regions]
        self._outline = _edge_arrays(self.part.outline)
        self._cuts = [_edge_arrays(c) for c in self.cuts]
        # The edges a line can cross inside the panel's box: all of each
        # region and cut, and the outline's edges that reach into the box.
        # Crossings outside the box bound only spans outside every region.
        edges = []
        for loop in [self.part.outline, *self.cuts, *self.regions]:
            a, b = loop, np.roll(loop, -1, axis=0)
            near = ((np.maximum(a[:, 0], b[:, 0]) >= box[0]) & (np.minimum(a[:, 0], b[:, 0]) <= box[2])
                    & (np.maximum(a[:, 1], b[:, 1]) >= box[1]) & (np.minimum(a[:, 1], b[:, 1]) <= box[3]))
            edges.append((a[near], b[near]))
        self._edges_a = np.vstack([a for a, _ in edges])
        self._edges_b = np.vstack([b for _, b in edges])

    def dxf(self, point: np.ndarray) -> np.ndarray:
        return self.to_dxf @ (point - self.offset)

    def model(self, pts: np.ndarray) -> np.ndarray:
        return pts @ self.linear.T + self.offset

    def has_material(self, pt: np.ndarray) -> bool:
        return (any(_inside(pt, r) for r in self._regions)
                and _inside(pt, self._outline)
                and not any(_inside(pt, c) for c in self._cuts))

    def spans(self, origin: np.ndarray, direction: np.ndarray) -> list[tuple[float, float]]:
        """Where the model line origin + u * direction runs through the
        panel's material, as spans of u (the line projected onto its plane)."""
        p0 = self.dxf(origin)
        d = self.dxf(origin + direction) - p0
        length = float(np.hypot(*d))
        if length < 1e-9:
            return []
        d = d / length
        a, b = self._edges_a, self._edges_b
        sa = (a[:, 0] - p0[0]) * d[1] - (a[:, 1] - p0[1]) * d[0]
        sb = (b[:, 0] - p0[0]) * d[1] - (b[:, 1] - p0[1]) * d[0]
        cross = (sa > 0) != (sb > 0)
        t = sa[cross] / (sa[cross] - sb[cross])
        pts = a[cross] + t[:, None] * (b[cross] - a[cross])
        us = np.sort((pts - p0) @ d)
        if len(us) < 2:
            return []
        lo, hi = us[:-1], us[1:]
        keep = hi - lo >= 1e-9
        lo, hi = lo[keep], hi[keep]
        if len(lo) == 0:
            return []
        mids = p0[None, :] + d[None, :] * ((lo + hi) / 2)[:, None]
        material = np.zeros(len(mids), dtype=bool)
        for r in self._regions:
            material |= _inside_many(mids, r)
        inside = np.nonzero(material)[0]
        if len(inside):
            held = _inside_many(mids[inside], self._outline)
            for c in self._cuts:
                held &= ~_inside_many(mids[inside], c)
            material[inside] = held
        return _merge([(float(a) / length, float(b) / length) for a, b, m in zip(lo, hi, material) if m])


def _inside_many(pts: np.ndarray, arrays) -> np.ndarray:
    """`_inside` for many points at once."""
    xi, yi, xj, yj = arrays
    x = pts[:, 0][:, None]
    y = pts[:, 1][:, None]
    straddles = (yi[None, :] > y) != (yj[None, :] > y)
    with np.errstate(divide="ignore", invalid="ignore"):
        xint = (xj - xi)[None, :] * (y - yi[None, :]) / (yj - yi)[None, :] + xi[None, :]
    return (np.count_nonzero(straddles & (x < xint), axis=1) % 2).astype(bool)


def _edge_arrays(poly: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    xi, yi = poly[:, 0], poly[:, 1]
    return xi, yi, np.roll(xi, 1), np.roll(yi, 1)


def _inside(pt: np.ndarray, arrays) -> bool:
    """`point_in_polygon` on a loop's precomputed edge arrays."""
    xi, yi, xj, yj = arrays
    x, y = float(pt[0]), float(pt[1])
    straddles = (yi > y) != (yj > y)
    with np.errstate(divide="ignore", invalid="ignore"):
        xint = (xj - xi) * (y - yi) / (yj - yi) + xi
    return bool(np.count_nonzero(straddles & (x < xint)) % 2)


def place_folded_panels(layout: Layout, folds: list[dict]) -> tuple[list[FoldedPanel], set[frozenset], list[str]]:
    """The panels of every folded part, the pairs a fold joins (by name), and
    the labels of folded parts missing from the DXF."""
    panels: list[FoldedPanel] = []
    hinged: set[frozenset] = set()
    missing: list[str] = []
    by_layer: dict[str, list[Part]] = {}
    for part in layout.parts:
        by_layer.setdefault(part.layer, []).append(part)
    for net in folds:
        label = net["label"]
        parts = by_layer.get(label, [])
        if not parts:
            missing.append(label)
            continue
        names = []
        for k, entry in enumerate(net["panels"]):
            m = np.asarray(entry["dxfToModel"], dtype=np.float64)
            linear, offset = m[:, :2], m[:, 2]
            regions = [np.asarray(r, dtype=np.float64) for r in [entry["region"], *entry["features"]] if len(r) >= 3]
            name = f"{label}/p{k + 1}"
            names.append(name)
            if not regions:
                continue
            probe = _interior_probe(regions[0])
            part = next((p for p in parts if point_in_polygon(probe, p.outline)), parts[0])
            inward = np.asarray(entry["inward"], dtype=np.float64)
            inward = inward / (np.linalg.norm(inward) or 1.0)
            panels.append(FoldedPanel(name=name, net=label, part=part, regions=regions, linear=linear,
                                      offset=offset, to_dxf=np.linalg.pinv(linear), inward=inward))
        for a, b in net.get("hinges", []):
            hinged.add(frozenset((names[a], names[b])))
    return panels, hinged, missing


def _slab_box(panel: FoldedPanel, stock: float) -> tuple[np.ndarray, np.ndarray]:
    pts = panel.model(np.vstack(panel.regions))
    pts = np.vstack([pts, pts + stock * panel.inward])
    return pts.min(axis=0), pts.max(axis=0)


def _depths(stock: float) -> np.ndarray:
    edge = max(0.0, stock - BEAM_INSET_MM)
    return np.linspace(BEAM_INSET_MM, edge, FOLD_DEPTH_SAMPLES)


def folded_overlap(p: FoldedPanel, q: FoldedPanel, stock: float) -> float:
    """The longest stretch along which the two panels' slabs of stock hold
    material at once (0 when they keep clear)."""
    cross = np.cross(p.inward, q.inward)
    sine = float(np.linalg.norm(cross))
    worst = 0.0
    if sine >= PARALLEL_SINE:
        d = cross / sine
        system = np.vstack([p.inward, q.inward, d])
        base = np.array([p.inward @ p.offset, q.inward @ q.offset, 0.0])
        for h1 in _depths(stock):
            for h2 in _depths(stock):
                origin = np.linalg.solve(system, base + np.array([h1, h2, 0.0]))
                worst = max(worst, _span_length(_intersect(p.spans(origin, d), q.spans(origin, d))))
        return worst
    # Planes (nearly) parallel: sample points through p's slab and look for
    # q's material at the same place, inside q's slab.
    hits = 0
    for region in p.regions:
        x0, y0, x1, y1 = bbox(region)
        for i in range(FOLD_PARALLEL_GRID):
            for j in range(FOLD_PARALLEL_GRID):
                pt = np.array([x0 + (i + 0.5) * (x1 - x0) / FOLD_PARALLEL_GRID,
                               y0 + (j + 0.5) * (y1 - y0) / FOLD_PARALLEL_GRID])
                if not p.has_material(pt):
                    continue
                surface = p.model(pt[None, :])[0]
                for h in _depths(stock):
                    x = surface + h * p.inward
                    depth = float((x - q.offset) @ q.inward)
                    if BEAM_INSET_MM < depth < stock - BEAM_INSET_MM and q.has_material(q.dxf(x)):
                        hits += 1
                        break
    if hits:
        cell = max((bbox(r)[2] - bbox(r)[0]) / FOLD_PARALLEL_GRID for r in p.regions)
        worst = max(worst, cell * hits)
    return worst


def _segment_distances(pts: np.ndarray, loops: list[np.ndarray]) -> np.ndarray:
    """Distance from each point to the nearest edge of any of the loops."""
    a = np.vstack([loop for loop in loops])
    b = np.vstack([np.roll(loop, -1, axis=0) for loop in loops])
    ab = b - a
    length = np.einsum("ij,ij->i", ab, ab)
    length = np.where(length > 0, length, 1.0)
    out = np.full(len(pts), np.inf)
    for start in range(0, len(pts), 512):
        chunk = pts[start:start + 512]
        ap = chunk[:, None, :] - a[None, :, :]
        t = np.clip(np.einsum("ijk,jk->ij", ap, ab) / length[None, :], 0.0, 1.0)
        d = ap - t[:, :, None] * ab[None, :, :]
        out[start:start + 512] = np.sqrt(np.min(np.einsum("ijk,ijk->ij", d, d), axis=1))
    return out


def net_material_outside_panels(part: Part, panels: list[FoldedPanel]) -> tuple[float, float, float, np.ndarray]:
    """Where the net's material (its outline less holes and notches) lies
    outside every one of its panels' outlines and features, which the fold-up
    check cannot see: the length of outline (mm) that runs more than
    `FOLD_COVER_TOL_MM` outside them, the area (mm^2, sampled on a
    `FOLD_COVER_GRID_MM` grid) inside the net that does, the farthest such
    point's distance, and that point."""
    zones = [region for panel in panels for region in panel.regions]
    arrays = [(bbox(z), _edge_arrays(z)) for z in zones]
    # Points along the outline, a hair inside the material.
    outline = part.outline
    inward = 1.0 if polygon_area(outline) > 0 else -1.0
    pts, weights = [], []
    for a, b in zip(outline, np.roll(outline, -1, axis=0)):
        edge = b - a
        length = float(np.hypot(*edge))
        if length < 1e-9:
            continue
        normal = inward * np.array([-edge[1], edge[0]]) / length
        n = max(1, int(np.ceil(length / FOLD_COVER_STEP_MM)))
        t = (np.arange(n) + 0.5) / n
        pts.append(a[None, :] + t[:, None] * edge[None, :] + 0.01 * normal[None, :])
        weights.append(np.full(n, length / n))
    on_outline = np.vstack(pts)
    on_weights = np.concatenate(weights)
    # Points inside the material.
    x0, y0, x1, y1 = bbox(outline)
    xs = np.arange(x0 + FOLD_COVER_GRID_MM / 2, x1, FOLD_COVER_GRID_MM)
    ys = np.arange(y0 + FOLD_COVER_GRID_MM / 2, y1, FOLD_COVER_GRID_MM)
    grid = np.stack(np.meshgrid(xs, ys), axis=-1).reshape(-1, 2) if len(xs) and len(ys) else np.zeros((0, 2))
    if len(grid):
        keep = _inside_many(grid, _edge_arrays(outline))
        for cut in [*part.holes, *part.notches]:
            cx0, cy0, cx1, cy1 = bbox(cut)
            near = np.nonzero(keep & (grid[:, 0] >= cx0) & (grid[:, 0] <= cx1) & (grid[:, 1] >= cy0) & (grid[:, 1] <= cy1))[0]
            if len(near):
                keep[near] &= ~_inside_many(grid[near], _edge_arrays(cut))
        grid = grid[keep]
    worst, where = 0.0, np.zeros(2)
    totals = []
    for points in (on_outline, grid):
        if not len(points):
            totals.append(np.zeros(0, dtype=bool))
            continue
        covered = np.zeros(len(points), dtype=bool)
        for (x0, y0, x1, y1), arr in arrays:
            near = np.nonzero(~covered & (points[:, 0] >= x0) & (points[:, 0] <= x1)
                              & (points[:, 1] >= y0) & (points[:, 1] <= y1))[0]
            if len(near):
                covered[near] |= _inside_many(points[near], arr)
        outside = ~covered
        if outside.any():
            d = _segment_distances(points[outside], zones)
            far = d > FOLD_COVER_TOL_MM
            if far.any() and float(d.max()) > worst:
                worst, where = float(d.max()), points[outside][int(np.argmax(d))]
            idx = np.nonzero(outside)[0][far]
            outside = np.zeros(len(points), dtype=bool)
            outside[idx] = True
        totals.append(outside)
    length = float(on_weights[totals[0]].sum()) if len(on_outline) else 0.0
    area = float(totals[1].sum()) * FOLD_COVER_GRID_MM ** 2 if len(grid) else 0.0
    return length, area, worst, where


def _holds_material(panels: list[FoldedPanel], owner: FoldedPanel, x: np.ndarray, stock: float,
                    boxes: dict[str, tuple[np.ndarray, np.ndarray]], slack: float = -BEAM_INSET_MM,
                    material: bool = True) -> bool:
    """Whether another panel's stock holds the model point `x`: it lies in
    that panel's slab (`slack` past its faces) over its material, or, with
    `material` off, anywhere over its outline or features."""
    for q in panels:
        if q is owner:
            continue
        lo, hi = boxes[q.name]
        if np.any(x < lo - stock) or np.any(x > hi + stock):
            continue
        depth = float((x - q.offset) @ q.inward)
        if not (-slack < depth < stock + slack):
            continue
        pt = q.dxf(x)
        if q.has_material(pt) if material else any(_inside(pt, r) for r in q._regions):
            return True
    return False


def _sample_inside(loop: np.ndarray, per_side: int) -> list[np.ndarray]:
    """Points of a grid over the loop's box that lie inside it, and a point
    nudged inside it from its first vertex."""
    x0, y0, x1, y1 = bbox(loop)
    pts = [np.array([x0 + (i + 0.5) * (x1 - x0) / per_side, y0 + (j + 0.5) * (y1 - y0) / per_side])
           for i in range(per_side) for j in range(per_side)]
    arrays = _edge_arrays(loop)
    return [p for p in pts if _inside(p, arrays)] + [_interior_probe(loop)]


def folded_joints_mate(layout: Layout, panels: list[FoldedPanel], stock: float,
                       holes_hold_joints: bool) -> list[Violation]:
    """The Folded half of SLOTS-MATE: with the nets folded up, every slot
    hole cut in a panel (not one a net closes around, outside every panel)
    has another panel's stock passing through it, unless the case's joints
    leave their holes empty (`holes_hold_joints` off: lacing holes, for a
    cord); and every protrusion (a feature's material past its panel's
    outline: a tab, tongue, lug or finger) meets another panel, passing
    through that panel's stock where it has a hole or notch, or resting on
    it, or carries a slot hole another panel passes through."""
    violations: list[Violation] = []
    boxes = {p.name: _slab_box(p, stock) for p in panels}
    by_net: dict[str, list[FoldedPanel]] = {}
    for panel in panels:
        by_net.setdefault(panel.net, []).append(panel)
    depths = _depths(stock)
    occupied_holes: list[tuple[FoldedPanel, np.ndarray]] = []
    for part in layout.parts:
        net = [p for p in by_net.get(part.layer, []) if p.part is part]
        for hole in part.holes:
            # The panel whose outline holds most of the hole. A hole outside
            # every panel's outline is one the net closes around, or one on a
            # feature (a rivet tab's pin hole), which nothing passes through.
            inside = _sample_inside(hole, FOLD_HOLE_GRID)
            counts = [sum(_inside(pt, p._regions[0]) for pt in inside) for p in net]
            if not counts or max(counts) * 2 <= len(inside):
                continue
            owner = net[int(np.argmax(counts))]
            occupied = any(_holds_material(panels, owner, owner.model(pt[None, :])[0] + h * owner.inward, stock, boxes)
                           for pt in inside for h in depths)
            if occupied:
                occupied_holes.append((owner, hole))
            elif holes_hold_joints:
                c = hole.mean(axis=0)
                violations.append(Violation(f"{owner.name}@({c[0]:.1f},{c[1]:.1f})",
                                            "folded up, no other panel passes through this slot hole", 0.0))
    for p in panels:
        for feature in p.regions[1:]:
            pts = [pt for pt in _sample_inside(feature, FOLD_HOLE_GRID + 2)
                   if not _inside(pt, p._regions[0]) and p.has_material(pt)]
            if not pts:
                continue
            if any(owner is p and min(_segment_distances(hole, [feature]).min(), _segment_distances(feature, [hole]).min())
                   <= stock for owner, hole in occupied_holes):
                continue  # a lug: it carries the wall of a slot another panel passes through
            surface = p.model(np.array(pts))
            engaged = any(_holds_material(panels, p, x + h * p.inward, stock, boxes, slack=FOLD_CONTACT_MM, material=False)
                          for x in surface for h in depths)
            if not engaged:
                c = feature.mean(axis=0)
                violations.append(Violation(f"{p.name}@({c[0]:.1f},{c[1]:.1f})",
                                            "folded up, this protrusion meets no other panel: it has no slot or notch to sit in", 0.0))
    return violations


def check_folded(layout: Layout, folds: list[dict], stock: Optional[float],
                 expected_panels: Optional[int], holes_hold_joints: bool = True) -> tuple[InvariantResult, InvariantResult]:
    """SLOTS-MATE and PARTS-CLEAR for Folded Panels nets (see above).
    PARTS-CLEAR also checks that each net's material lies inside its panels'
    outlines and features (`net_material_outside_panels`), so none of it
    escapes the fold-up check; SLOTS-MATE that every net has its frames and
    that its joints mate (`folded_joints_mate`)."""
    if stock is None:
        v = [Violation("file", "no stock thickness to fold the nets with", 0.0)]
        return (InvariantResult("SLOTS-MATE", False, 0.0, "file", v),
                InvariantResult("PARTS-CLEAR", False, 0.0, "file", list(v)))
    panels, hinged, missing = place_folded_panels(layout, folds)
    mate = [Violation(label, "folded part not found in the DXF", 0.0) for label in missing]
    framed = {p.part.layer for p in panels}
    mate += [Violation(part.name, "part has no panels in the part-frames file", 0.0)
             for part in layout.parts if part.layer not in framed]
    if expected_panels is not None and len(panels) != expected_panels:
        mate.append(Violation("file", f"{len(panels)} panels, expected {expected_panels}",
                              float(len(panels) - expected_panels)))
    clear: list[Violation] = []
    worst, worst_where = 0.0, ""
    for part in layout.parts:
        net = [p for p in panels if p.part is part]
        if not net:
            continue
        length, area, farthest, at = net_material_outside_panels(part, net)
        if length > 0 or area > 0:
            clear.append(Violation(part.name, f"{length:.2f}mm of the net's outline (and {area:.0f}mm^2 inside it) lies "
                                              f"outside every panel and feature, up to {farthest:.3f}mm, near "
                                              f"({at[0]:.1f},{at[1]:.1f}): folded up, that material is not checked",
                                   farthest))
    mate += folded_joints_mate(layout, panels, stock, holes_hold_joints)
    boxes = [_slab_box(p, stock) for p in panels]
    pad = 1e-6
    for i in range(len(panels)):
        for j in range(i + 1, len(panels)):
            if frozenset((panels[i].name, panels[j].name)) in hinged:
                continue
            (lo1, hi1), (lo2, hi2) = boxes[i], boxes[j]
            if np.any(lo1 > hi2 + pad) or np.any(lo2 > hi1 + pad):
                continue
            overlap = folded_overlap(panels[i], panels[j], stock)
            where = f"{panels[i].name}x{panels[j].name}"
            if overlap > worst:
                worst, worst_where = overlap, where
            if overlap > JOINT_OVERLAP_TOL_MM:
                clear.append(Violation(where, f"folded up, the panels' stock passes into each other "
                                              f"({overlap:.3f}mm of material overlaps)", overlap))
    note = f"{len(panels)} folded panels checked"
    return (InvariantResult("SLOTS-MATE", not mate, 0.0, "", mate,
                            note + ("" if holes_hold_joints else "; slot holes may be empty (lacing)")),
            InvariantResult("PARTS-CLEAR", not clear, worst, worst_where, clear, note))


# ===========================================================================
# Contour metric
# ===========================================================================

def _bbox_centre(pts: np.ndarray) -> np.ndarray:
    return np.array([
        0.5 * (pts[:, 0].min() + pts[:, 0].max()),
        0.5 * (pts[:, 1].min() + pts[:, 1].max()),
    ])


# The packers rotate parts a quarter turn and the slice plane has no
# preferred handedness, so the part may be any of the 8 symmetries of the
# square relative to the mesh section.
_ORIENTATIONS = tuple(
    (rotate, np.array(flip))
    for rotate in (False, True)
    for flip in ((1.0, 1.0), (1.0, -1.0), (-1.0, 1.0), (-1.0, -1.0))
)


def _orient_loop(loop: np.ndarray, rotate: bool, flip: np.ndarray) -> np.ndarray:
    out = loop[:, ::-1] if rotate else loop
    return out * flip


def _best_haus_to_section(cand: np.ndarray, secs: list[np.ndarray]) -> float:
    """Best (min) Hausdorff of a recentred candidate to any loop in a section."""
    best = float("inf")
    for sec in secs:
        # Recentre each section loop on its own box: a plane can cut the mesh
        # into several separate contours and the part matches one of them.
        sec_c = sec - _bbox_centre(sec)
        sec_q = _decimate(sec_c, SECTION_DECIMATION_MAX_POINTS)
        for rotate, flip in _ORIENTATIONS:
            d = hausdorff(cand, _orient_loop(sec_c, rotate, flip), b_query=_orient_loop(sec_q, rotate, flip))
            if d < best:
                best = d
    return best


def check_contour_matches_mesh(layout: Layout, mesh: Mesh, axis: str, tol_mm: float) -> InvariantResult:
    """Each part outline against the closest mesh cross-section (a metric).

    A coarse plane sweep across the axis extent finds the best region for
    each outline, then a ternary refinement of the bracketing window pins the
    plane down. Slots, notches and rings cut into a part are part of its
    outline, so this metric only reads near zero for plain sections.
    """
    a, _, _ = axis_indices(axis)
    cut_min = float(mesh.vertices[:, a].min())
    cut_max = float(mesh.vertices[:, a].max())
    span = cut_max - cut_min
    if span <= 0:
        return InvariantResult("CONTOUR-MATCHES-MESH", False, float("inf"),
                               "mesh has zero extent along axis", [], "degenerate mesh")

    pad = 1e-4 * span
    n_coarse = 120
    coarse_coords = np.linspace(cut_min + pad, cut_max - pad, n_coarse)
    section_cache: dict[float, list[np.ndarray]] = {}

    def section_at(coord: float) -> list[np.ndarray]:
        key = round(coord, 6)
        s = section_cache.get(key)
        if s is None:
            s = [_decimate(loop, SECTION_DECIMATION_MAX_POINTS) for loop in mesh_section(mesh, axis, float(coord))]
            section_cache[key] = s
        return s

    coarse_secs = [section_at(float(c)) for c in coarse_coords]
    worst, worst_where = 0.0, ""
    violations: list[Violation] = []
    for part in layout.parts:
        cand = part.outline - _bbox_centre(part.outline)
        best_d, best_i = float("inf"), 0
        for i, secs in enumerate(coarse_secs):
            d = _best_haus_to_section(cand, secs)
            if d < best_d:
                best_d, best_i = d, i
        lo = coarse_coords[max(0, best_i - 1)]
        hi = coarse_coords[min(n_coarse - 1, best_i + 1)]
        for _ in range(7):
            mid_lo = lo + (hi - lo) / 3.0
            mid_hi = hi - (hi - lo) / 3.0
            d_lo = _best_haus_to_section(cand, section_at(float(mid_lo)))
            d_hi = _best_haus_to_section(cand, section_at(float(mid_hi)))
            best_d = min(best_d, d_lo, d_hi)
            if d_lo <= d_hi:
                hi = mid_hi
            else:
                lo = mid_lo
        if best_d > worst:
            worst, worst_where = best_d, part.name
        if best_d > tol_mm:
            violations.append(Violation(part.name, f"Hausdorff {best_d:.3f}mm > {tol_mm}mm", best_d))
    note = "" if layout.parts else "no parts found"
    return InvariantResult("CONTOUR-MATCHES-MESH", bool(layout.parts) and not violations,
                           worst, worst_where, violations, note)


# ===========================================================================
# The validator
# ===========================================================================

def validate(
    dxf_path: Path,
    mesh_path: Optional[Path],
    axis: str = "z",
    tol_mm: float = DEFAULT_HAUSDORFF_TOL_MM,
    contour: bool = True,
    expected_parts: Optional[int] = None,
    slot_width: Optional[float] = None,
    expected_slots: Optional[int] = None,
    part_frames: Optional[Path] = None,
    expected_joints: Optional[int] = None,
    stock: Optional[float] = None,
    count_part_holes: bool = False,
    folded_holes_hold_joints: bool = True,
    material_in_model: bool = False,
) -> dict:
    """Check one exported DXF. `mesh_path` (and `contour`) drive the metric;
    `expected_parts`, `slot_width` (mm) and `expected_slots` arm PART-COUNT,
    SLOTS-FIT-MATERIAL and SLOT-COUNT, and `expected_joints` arms SLOTS-MATE,
    PARTS-CLEAR and PARTS-JOINED, which then need `part_frames` (the export's
    part-frames file), the mesh and the stock thickness (`stock`, else
    `slot_width`). For Folded Panels frames (`folds`), `expected_joints` is
    the number of panels, PARTS-JOINED is not checked, and with
    `folded_holes_hold_joints` off (Laced joints) slot holes may be empty.
    With `count_part_holes`, SLOT-COUNT counts every hole cut into a part (Folded
    Panels joint holes) where it would count `hole`-layer loops.
    `material_in_model` arms MATERIAL-IN-MODEL, which needs `part_frames` and
    a closed, consistently wound mesh. Each passes with a note when it is not
    armed."""
    layout = build_layout(read_dxf(dxf_path))
    needs_mesh = contour or expected_joints is not None or material_in_model
    mesh = load_mesh(mesh_path) if mesh_path is not None and needs_mesh else None
    has_frames = part_frames is not None and Path(part_frames).is_file()
    folds = load_folded_frames(part_frames) if has_frames else []
    thickness = stock if stock is not None else slot_width
    frames = None
    if folds and expected_joints is not None:
        joints = (*check_folded(layout, folds, thickness, expected_joints, folded_holes_hold_joints),
                  InvariantResult("PARTS-JOINED", True, 0.0, "", [], "Folded Panels nets: not checked"))
    else:
        frames = load_part_frames(part_frames) if has_frames else None
        detached = load_detached_labels(part_frames) if frames is not None else set()
        joints = check_joints(layout, frames, mesh, thickness, expected_joints, detached)
    invariants = [
        check_fits_sheet(layout),
        check_no_overlap(layout),
        check_validity(layout),
        check_holes_in_material(layout),
        check_part_count(layout, expected_parts),
        check_slots_fit_material(layout, slot_width),
        check_slot_count(layout, expected_slots, count_part_holes),
        *joints,
        check_material_in_model(layout, frames, mesh, material_in_model),
    ]
    if contour and mesh is not None:
        invariants.append(check_contour_matches_mesh(layout, mesh, axis, tol_mm))
    return {
        "case": mesh_path.stem if mesh_path is not None else dxf_path.stem,
        "dxf": str(dxf_path),
        "axis": axis,
        "n_sheets": len(layout.sheets),
        "n_parts": len(layout.parts),
        "tol_mm": tol_mm,
        "invariants": invariants,
        "layout": layout,
    }


# ===========================================================================
# CLI / printing
# ===========================================================================

_UNITS = {
    "FITS-SHEET": "mm",
    "NO-OVERLAP": "mm^2",
    "VALIDITY": "mm^2",
    "BISCUITS-IN-MATERIAL": "mm",
    "PART-COUNT": " parts",
    "SLOTS-FIT-MATERIAL": "mm",
    "SLOT-COUNT": " slots",
    "SLOTS-MATE": "mm",
    "PARTS-CLEAR": "mm",
    "PARTS-JOINED": " parts",
    "MATERIAL-IN-MODEL": "mm",
    "CONTOUR-MATCHES-MESH": "mm",
}


def print_summary(result: dict, max_offenders: int = 3) -> None:
    print("=" * 72)
    print(f"CASE: {result['case']}    axis={result['axis']}    tol={result['tol_mm']}mm")
    print(f"  sheets={result['n_sheets']}  parts={result['n_parts']}")
    print("-" * 72)
    all_pass = True
    for inv in result["invariants"]:
        status = "PASS" if inv.passed else "FAIL"
        if not inv.passed:
            all_pass = False
        line = f"  [{status}] {inv.name:<22} worst={inv.worst_value:+.4f}{_UNITS.get(inv.name, '')}"
        if inv.worst_where:
            line += f" @ {inv.worst_where}"
        line += f"  (violations={inv.n_violations})"
        print(line)
        if inv.note:
            print(f"           note: {inv.note}")
        if not inv.passed:
            for vio in inv.violations[:max_offenders]:
                print(f"           - {vio.where}: {vio.detail}")
            if inv.n_violations > max_offenders:
                print(f"           ... +{inv.n_violations - max_offenders} more")
    print("-" * 72)
    print(f"  OVERALL: {'PASS' if all_pass else 'FAIL'}")
    print("=" * 72)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Cuttability invariants for an exported Refab Artist DXF.")
    ap.add_argument("--dxf", required=True, type=Path, help="exported DXF")
    ap.add_argument("--mesh", type=Path, default=None, help="source mesh (.stl/.obj), for the contour metric")
    ap.add_argument("--axis", default="z", choices=["x", "y", "z"], help="slice axis for the contour metric")
    ap.add_argument("--tol", type=float, default=DEFAULT_HAUSDORFF_TOL_MM,
                    help="contour-metric Hausdorff threshold (mm)")
    ap.add_argument("--expected-parts", type=int, default=None,
                    help="number of parts the file should hold (arms PART-COUNT)")
    ap.add_argument("--slot-width", type=float, default=None,
                    help="stock thickness the slots must fit, mm (arms SLOTS-FIT-MATERIAL)")
    ap.add_argument("--expected-slots", type=int, default=None,
                    help="number of joint cuts the file should hold (arms SLOT-COUNT)")
    ap.add_argument("--part-frames", type=Path, default=None,
                    help="the export's part-frames file (with --expected-joints, arms SLOTS-MATE, PARTS-CLEAR and PARTS-JOINED)")
    ap.add_argument("--expected-joints", type=int, default=None,
                    help="number of joints the parts should make, or of panels for Folded Panels nets "
                         "(arms SLOTS-MATE, PARTS-CLEAR and PARTS-JOINED)")
    ap.add_argument("--stock", type=float, default=None,
                    help="stock thickness, mm, for SLOTS-MATE, PARTS-CLEAR and PARTS-JOINED (default: --slot-width)")
    ap.add_argument("--count-part-holes", action="store_true",
                    help="SLOT-COUNT counts every hole cut into a part (Folded Panels)")
    ap.add_argument("--json", action="store_true", help="also emit JSON")
    args = ap.parse_args(argv)

    if not args.dxf.is_file():
        print(f"error: DXF not found: {args.dxf}", file=sys.stderr)
        return 2
    if args.mesh is not None and not args.mesh.is_file():
        print(f"error: mesh not found: {args.mesh}", file=sys.stderr)
        return 2

    result = validate(args.dxf, args.mesh, args.axis, tol_mm=args.tol,
                      expected_parts=args.expected_parts, slot_width=args.slot_width,
                      expected_slots=args.expected_slots, part_frames=args.part_frames,
                      expected_joints=args.expected_joints, stock=args.stock,
                      count_part_holes=args.count_part_holes)
    print_summary(result)

    if args.json:
        import json
        slim = {
            "case": result["case"], "axis": result["axis"],
            "n_sheets": result["n_sheets"], "n_parts": result["n_parts"],
            "invariants": [
                {"name": i.name, "passed": i.passed,
                 "worst_value": i.worst_value, "worst_where": i.worst_where,
                 "n_violations": i.n_violations, "note": i.note}
                for i in result["invariants"]
            ],
        }
        print(json.dumps(slim, indent=2))

    gated = [i for i in result["invariants"] if i.name != "CONTOUR-MATCHES-MESH"]
    return 0 if all(i.passed for i in gated) else 1


if __name__ == "__main__":
    raise SystemExit(main())
