# Pathological fixtures

Every mesh in this folder is intentionally broken. The point is to exercise
Refab Artist's preflight checks and error paths — not to test what Refab Artist does
with valid input.

**Do not "fix" these fixtures.** If `_scripts/verify.py` fails on one, the
generator script is wrong, not the on-disk file. Re-run
`_scripts/gen_pathological.py`.

Each fixture violates exactly one well-known geometry-correctness invariant
so failures in the slicing pipeline can be attributed to the specific class
of input pathology.

## Catalog

### `cube_nonmanifold_edge.stl`

**What's wrong:** Three triangles share a single edge.

A manifold surface has exactly two triangles meeting at every edge. This
fixture is a normal 50 mm cube (12 triangles) plus one extra triangle (a
"fin") that re-uses the existing edge from `(25,-25,-25)` to `(25,25,-25)`.
Result: three triangles meet at that edge.

**Expected Refab Artist behavior:**

- **Preflight:** must detect and flag non-manifold (`MeshPreflight` returns a
  warning or error).
- **Stacked, Curve, Radial:** safe to slice if the fin sits outside the slice
  plane; contour generation may emit an extra open line segment when the
  plane crosses the fin — document this in the per-mode spec.
- **Interlocked, 3D Slices, Folded Panels:** these modes depend on the input
  being a closed manifold. Hard-fail with a clear error is the desired
  behavior.

### `cube_self_intersecting.stl`

**What's wrong:** Two solid cubes interpenetrating, stored as a single mesh.

The mesh contains two separate 50 mm cubes (cube A centered at origin, cube
B centered at `(20,20,20)`). Their surfaces cross each other through the
overlap region.

**Expected Refab Artist behavior:**

- **Preflight:** should flag self-intersection (the `manifold` library's
  invariant check catches this when invoked).
- **Slicing:** each contour-extraction at a Z height that crosses the overlap
  will produce overlapping or self-touching contour rings. The Stacked
  spec must document whether the union, the symmetric difference, or the
  raw rings are emitted.

### `cube_zero_area_face.stl`

**What's wrong:** One triangle has zero area (collinear vertices).

A normal 50 mm cube (12 triangles) plus one degenerate triangle whose three
vertices are collinear at `(0,0,0)`, `(10,0,0)`, `(20,0,0)`. The cross
product of its edges is the zero vector, so the face normal is undefined.

**Expected Refab Artist behavior:**

- **Preflight:** detect and report the zero-area face count; do not crash.
- **Normal computation:** must not divide by zero when normalizing. Either
  emit a sentinel (e.g. zero normal) or skip the face entirely.
- **All slicing modes:** ignore the degenerate face; otherwise behave
  exactly as on the unmodified cube.

### `cube_very_thin_feature_1mm.stl`

**What's wrong:** A 1 mm-thick protrusion is thinner than typical material
stock for laser/CNC fabrication (plywood is usually 3–6 mm).

A 50 mm cube with a 1 mm × 10 mm × 20 mm fin protruding from the `+X` face.
The geometry itself is well-defined; the issue is semantic — slot fits and
kerf compensation calculations break down when feature thickness drops
below material thickness.

**Expected Refab Artist behavior:**

- **Preflight:** warn (not error) when minimum feature thickness < currently
  configured material thickness.
- **Interlocked, Curve:** slot generation must skip or warn on the thin fin
  — generating a slot in a 1 mm feature would carve through the part.
- **Material presets:** the warning text should reference the active preset
  by name ("Birch 3 mm ply requires features ≥ 3 mm").

### `lumpy_blob_open_poles.stl`

**What's wrong:** The mesh is cracked open at both poles.

The lumpy blob of `organic/lumpy_blob.stl`, built with one pole vertex per
longitude instead of one shared vertex (`lumpy_blob(..., shared_poles=False)`
in `_scripts/gen_organic.py`, the generator's first version). The
displacement varies with longitude at the poles, so those vertices lie at
different heights on the axis, and neighbouring polar-fan triangles do not
share their edges: each pole is split by thin wedge-shaped slits (168
boundary edges). Real scans are often cracked like this.

**Expected Refab Artist behavior:**

- **Slicing:** a section through a pole comes out as open chains. Curve
  Slices joins them across the cracks; every outline exported in any mode
  must still be a valid, simple outline (the functional gate's VALIDITY).
- **Curve, Radial, Interlocked, Stacked:** gated at 3 and 5 mm stock
  (`scripts/functional_gate.py`, the `cracked-blob` cases).

### `torus_mixed_winding.stl`

**What's wrong:** The triangles wind both ways.

The torus of `primitives/torus_R30_r10mm.stl` (same vertices, same triangle
order) with the triangles of the inner third of its tube, around the hole,
wound the other way: they face into the solid. The surface is closed and
otherwise unchanged; 600 of its 1800 triangles are flipped.

**Expected Refab Artist behavior:**

- **Radial, Curve:** section loops are turned by the way the triangles
  they were cut from face, so a mesh whose triangles disagree is read with
  them made to agree (`MeshWinding`). The parts must be those of the
  consistently wound torus: rings and first-axis ribs keep their hole.
  Gated at 3 and 5 mm (the `torus-mixed-winding` cases), with the joints
  checked against `primitives/torus_R30_r10mm.stl`, since the gate reads
  inside and outside from the winding.

### `torus_inverted.stl`

**What's wrong:** The whole surface faces inward.

The torus of `primitives/torus_R30_r10mm.stl` with every triangle wound the
other way, so all 1800 face into the solid. The triangles agree with each
other; only which way the whole surface faces is wrong, as in an inside-out
export.

**Expected Refab Artist behavior:**

- **Radial, Curve:** a mesh that encloses a negative volume is read the
  other way round (`MeshWinding`), so the parts are those of the torus:
  rings and first-axis ribs keep their hole. Gated in Radial at the CLI's
  defaults (5 mm, 12 fins) and in Curve with first axis Z at 3 and 5 mm
  (the `torus-inverted` cases), checked against
  `primitives/torus_R30_r10mm.stl`.

### `blocks_touching_at_corner.stl`

**What's wrong:** Two solids meet along one edge only.

A 20 mm square block (x, y from -20 to 0) and a kite-shaped block (corners
(0, 0), (20, 5), (20, 20), (5, 20)), both 30 mm tall, that share the
vertical edge at x = y = 0 and nothing else. Every horizontal section is two
pieces touching at one corner. The kite's edge leaves that corner nearly
straight on from the block's, so a contourer that joins segments the
straightest way on draws each section as one figure of eight crossing over
at the corner.

**Expected Refab Artist behavior:**

- **Stacked:** each section is cut as its two pieces; no exported outline
  pinches (touches itself at a point between two pieces). Gated at 3 and
  5 mm (the `corner-blocks` cases: VALIDITY and PART-COUNT).

## Adding a new pathological fixture

1. Pick one specific invariant to violate. Don't bundle two failures into
   one fixture — it makes attribution impossible.
2. Add a generator to `_scripts/gen_pathological.py` (or split that script
   if it grows past ~250 lines).
3. Add a section to this README explaining what's wrong, why, and what
   each mode is expected to do.
4. Re-run `_scripts/build_manifest.py` to refresh `MANIFEST.md`.
