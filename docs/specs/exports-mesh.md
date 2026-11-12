# Mesh Exports (STL / OBJ) — spec

How the slicing modes write STL and OBJ. For the flat-part slicing modes
(Stacked, Interlocked, Radial, Curve, Folded Panels) the mesh is a
**verification** output: each cut part extruded to its thickness and put back
in its place on the model, so the assembled result can be checked in a 3D
viewer before cutting. For 3D Slices the mesh *is* the product
(`docs/specs/threeD.md`). Structures, Partition, MotherMold and Inflatables
write their own meshes and are covered by their PRDs.

Sources: `StlExporter.swift`, `ObjExporter.swift`,
`ViewportSliceSolidRenderData.swift`, the per-mode mesh builders
(`InterlockedSliceMeshExportBuilder`, `RadialSliceMeshExportBuilder`,
`CurveSliceMeshExportBuilder`, `ThreeDSliceMeshExportBuilder`,
`StackedDowelMeshBuilder`).

---

## 1. Units and frame

- Millimetres, in the model's own coordinate frame after import scaling,
  orientation and Object Size transforms. No re-centring.
- Every part sits where it belongs in the assembled model: a slice of
  thickness `t` at plane position `p` spans `p − t/2` to `p + t/2` along its
  normal.

## 2. Two construction paths

### 2.1 Built meshes

Used for Interlocked, Radial, Curve, 3D Slices, and Stacked with dowel holes
(GUI). A mode-specific builder produces one triangulated mesh per part:

- Each part outline is split into pieces; holes are bridged into the outer
  loop and the caps are ear-clipped, so concave outlines and hollow parts are
  correct. Side walls are emitted for outer loops and (reversed) for holes.
- **Slot cutouts** (Interlocked, Curve): when a part outline is an
  axis-aligned rectangle, the plan-level slot polygons are subtracted by
  splitting the rectangle into cells around them. A part whose outline is not
  a rectangle is extruded **without** its slots.
- Radial uses the finished ring and fin outlines (joints already cut, holes
  included).
- Stacked with dowels cuts a 24-segment hole (or the dowel shape's outline)
  through every slice the rod passes through.

### 2.2 Contour extrusion

Used for Stacked without dowels, Folded Panels, and as the fallback when a
mode's builder produces nothing. Every closed contour loop of a layer — hole
loops included — is extruded on its own: a bottom cap (reversed), a top cap,
and two triangles per side edge. Caps are fan-triangulated from the loop's
first vertex. Hole loops therefore become solid plugs rather than holes, and
concave caps can be triangulated incorrectly (§ 6).

## 3. STL

- **ASCII only.** One `solid <name>` … `endsolid <name>` block holding every
  part; STL has no grouping.
- Each triangle:

  ```
    facet normal nx ny nz
      outer loop
        vertex x y z
        vertex x y z
        vertex x y z
      endloop
    endfacet
  ```

  Values use `%.6f`. The normal is the normalised cross product of the
  triangle's first two edges (zero for a degenerate triangle). Triangles are
  counter-clockwise seen from outside.
- Solid names: `refabartist_stacked_slices`, `refabartist_interlocked_slices`,
  `refabartist_radial_slices`, `refabartist_curve_slices`, `refabartist_3d_slices`,
  `refabartist_folded_panels`.

## 4. OBJ

- Header:

  ```
  # Refab Artist <title> mesh export
  # Units: millimeters
  ```

  where `<title>` is `stacked slice`, `interlocked slice`, `radial slice`,
  `curve slice`, `3D slice` or `folded panel`.
- One block per part, opened with both `o <name>` and `g <name>`, followed by
  its `v x y z` lines (`%.6f`) and its faces. Face indices are 1-based and
  global across the file. No `vn`, `vt`, `mtllib` or `usemtl` lines.
- Built meshes (§ 2.1) write triangles. Contour extrusion (§ 2.2) writes each
  cap as one polygon face and each side as a quad.
- Part names:

  | Mode | Names |
  |---|---|
  | Stacked | `slice_NNN` |
  | Interlocked | `primary_NNN`, `secondary_NNN` |
  | Radial | `first_axis_NNN`, `radial_NNN` (`_CC` suffix for extra pieces) |
  | Curve | `first_axis_NNN`, `curve_NNN` |
  | 3D Slices | `three_d_NNN` |
  | Folded Panels | `folded_panel_NNN` |

  `NNN` is the 1-based index, zero-padded to three digits.

## 5. Thickness per mode

| Mode | App and CLI |
|---|---|
| Stacked, Interlocked, Radial, Curve | material thickness (not the slot width) |
| Folded Panels | material thickness |
| 3D Slices | — (bands follow the surface) |

Under a Slice Direction tilt the parts are cut from the model turned into the
slicing frame and written in that frame (`docs/specs/ui-workflow.md`). The
part frames written beside a vector export (`--part-frames`,
`docs/specs/exports-dxf.md` § 4) are not: they map to the model as imported.

Folded Panels parts are laid flat at z = 0 in their unfolded layout, not
folded into place.

## 6. Edge cases and known issues

- **Empty plan**: an ASCII STL with an empty solid, or an OBJ with only the
  header (and empty `o`/`g` blocks for layers without closed loops).
- **Open contours** (from non-manifold or open meshes) are skipped; only
  closed loops are extruded.
- **Contour extrusion** (§ 2.2) treats hole loops as solids and
  fan-triangulates caps, so Stacked slices with holes or concave outlines
  export with filled holes and possibly wrong caps when dowels are off.
- **Slots on non-rectangular parts** are not cut into Interlocked and Curve
  mesh exports.

## 7. Worked example

50 mm cube, `--mode stacked --format obj`, CLI defaults (thickness 5 mm, axis
Z):

- 10 slices at `z = −21.25, −16.25, …, 23.75`
  (`docs/specs/stacked.md`).
- Each slice is one closed square loop of 4 vertices, extruded ±2.5 mm:
  8 vertices, 2 cap faces (4-gons) and 4 side quads per slice.
- The file has the header, then `o slice_001` / `g slice_001` with 8 `v`
  lines and 6 `f` lines, and so on to `slice_010` — 80 vertices in total.
