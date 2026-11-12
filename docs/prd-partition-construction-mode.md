# Refab Artist PRD: Partition Construction Mode

## Status

Drafted 2026-06-25 from owner direction. This is a new fabrication-first
construction technique for dividing an oversized model into printable,
bed-sized pieces that key back together with controlled tolerance.

This feature is not a remesher or a sculpting tool. Refab Artist cuts an imported
solid into watertight chunks, adds registration keys at the seams, and exports
the pieces. Downstream slicing software remains responsible for printer-specific
supports, temperatures, speeds, brim/raft, material profiles, and print paths.

## One-line Summary

Add a mesh-only **Partition** construction mode that splits a source mesh into
multiple watertight, printer-bed-sized pieces — fully automatically from a build
volume, or manually by placing and angling cut planes in the viewport — adds
locating-pin registration keys with tolerance at every seam, and exports the
pieces as separate STL files, a named-object OBJ, or a laid-out plate, with an
assembly map.

## Product Intent

The goal is to make "this model is bigger than my printer" a two-minute,
in-app operation instead of a manual cut-and-key chore in ZBrush or other DCC
tools.

The user defines the printer build volume and (optionally) the model's real
size, and Refab Artist parts the model so every piece fits the bed. Seams carry
registration keys so the printed pieces locate and assemble accurately. The
process must be excellent both fully automated and fully manual, and the two
must share one underlying model so the user can auto-fit and then hand-tune.

### Locked decisions (2026-06-25)

These two product decisions are settled and must not be re-litigated during
implementation:

1. **Cut geometry: arbitrary single planes.** v1 supports axis-aligned grid
   cuts (Auto-fit) AND individually placed, individually angled cut planes
   (Manual). The engine treats every cut as an arbitrary plane; the grid is just
   a special case. Curved / organic seams are explicitly out of scope for v1.

2. **Default registration key: locating pins + sockets.** Cylindrical pin into a
   slightly larger socket, two pins per seam to lock rotation, glue-assembled.
   This is the shipping default and the first key built. Dovetail / wedge is a
   later second key type behind the same picker.

## Users

- Artists and makers printing large sculptures on consumer FDM/resin printers.
- Anyone who currently divides oversized models by hand in ZBrush, Blender, or
  Meshmixer and wants it done in Refab Artist instead.
- Users who need printed pieces to register accurately for gluing or pinning.

## Non-goals

- Do not build a boolean/CSG engine. Keys are built as additive cap geometry
  (see Registration Keys). No general mesh boolean is required or permitted as a
  dependency for v1.
- Do not add printer/material profiles, extrusion planning, G-code, print-time
  estimates, brim/raft settings, or thermal controls.
- Do not guarantee a piece prints without the downstream slicer's own supports.
- Do not export flat laser-cut sheets for this construction mode.
- Do not do curved, freeform, or detail-following seam surfaces in v1.
- Do not hollow, shell, or wall-thicken the model in v1 (pieces stay solid).

## Scope

### Construction Technique

Add one top-level construction mode:

- Label: **Partition**
- Export support: STL and OBJ only (mesh outputs). No DXF/PDF/SVG/EPS sheet.
- Project persistence: all settings — build volume, mode, plane set, key
  settings, packaging, naming, seed, and generated/stale state — must be saved
  in Refab Artist project documents.
- Computation model: explicit **Generate** ("Partition & preview") action, not
  live recomputation on every slider movement. Splitting a dense mesh is heavy;
  it runs off the main thread and is cached by a settings hash.

The mode hides controls that do not apply, matching how `.structures` already
hides them: no Manufacturing (material thickness) section, no Slice Direction
section. Partition has its own plane controls.

### Splitting Model

There is one persisted artifact: an ordered **set of cut planes** plus a **key
configuration**. Both Auto-fit and Manual operate on this same set.

- **Auto-fit** computes the plane set from the build volume. The user picks a
  printer preset or custom W×D×H plus a bed margin; Refab Artist computes the
  minimum number of axis-aligned divisions per axis so every resulting piece
  fits the bed (accounting for key protrusion and margin), and populates the
  plane set. The user only presses Generate to build meshes.
- **Manual** lets the user add, remove, move, and rotate individual planes. New
  planes may be axis-aligned or arbitrarily angled. Editing happens primarily in
  the viewport via plane handles (same interaction family as the existing slice-
  direction ring and 3D dowel editing), with the inspector showing the plane
  list and numeric positions.
- Auto-fit then Manual is a first-class flow: Auto populates planes, Manual
  edits them. Re-running Auto-fit replaces the auto-generated planes but should
  preserve user-added manual planes where feasible (tag each plane with its
  source).

### Build Volume & Model Size

- Printer presets (editable list; ship a small starter set such as Bambu Lab
  X1C / A1 / A1 mini, Prusa MK4, Creality Ender 3) plus **Custom** with editable
  W/D/H in mm and a bed margin.
- Build volume is the usable interior box. The bed margin shrinks the effective
  fit box on all sides.
- Model size is read from the imported mesh bounds using the existing unit/scale
  detection (`MeshScaler`), shown as a live W×D×H readout. The user can still
  override scale through the existing model-scale controls; Partition consumes
  the effective (scaled) bounds.
- The fit box used for Auto-fit and fit-check is
  `buildVolume − 2·bedMargin − keyAllowance` along the relevant axis, where
  `keyAllowance` accounts for pin protrusion on cut faces.

### Registration Keys

Keys are built **without CSG**. Because Refab Artist generates the cut cap faces
itself, a key is a cap-construction problem, not a boolean subtraction:

- **Male piece:** build the seam cap as the cross-section polygon with the pin
  footprint punched out as a hole, then raise pin walls and a pin top cap. The
  result is one watertight shell with a boss protruding past the cut plane.
- **Female piece:** build the seam cap with the *enlarged* footprint
  (footprint + tolerance) punched out, then drop pocket walls and a floor. The
  result is one watertight shell with a recess.

Each printed piece remains an independent closed mesh; the two are never merged
or booleaned. Tolerance is exactly how much larger the female footprint is than
the male (radial clearance, in mm; default conservative for FDM, e.g. 0.2 mm,
editable).

Key type (v1):

- **Locating pins + sockets** (default): cylindrical pin, default two per seam
  to lock rotation. Controls: pin diameter, pin length, tolerance, pins per
  seam, edge margin (minimum clearance from the cross-section boundary).
- **Dovetail / wedge** (later, same picker): trapezoidal interlock that resists
  pulling apart along the seam. Same additive cap approach (trapezoidal boss vs
  trapezoidal pocket).
- **None — butt joint / glue**: flat caps, no key.

Key placement rules:

- Pin sites must sit strictly inside the seam cross-section with at least
  `edgeMargin` clearance to every boundary, on both adjacent pieces.
- If a seam cross-section is too thin or too concave to seat a key, mark the
  seam **not keyable** and fall back to a flat butt joint, and surface a warning.
  Never force a bad key.
- Pin protrusion is along the cut normal, so it grows the male piece's extent
  along that axis; the fit box must reserve `keyAllowance` for it.
- Placement is deterministic from the seed.

### Fit Check

Always-visible, honest readout after planning:

- Per piece: bounding-box size and a fits / does-not-fit indicator against the
  effective fit box (a piece may be re-oriented for printing; use its AABB).
- Count of oversized pieces, with which axis exceeds the bed.
- Count of seams that could not be keyed (will glue).
- Total piece count.

If any piece is still oversized after Auto-fit (e.g. a key reservation pushed it
over), Auto-fit must add the divisions needed to fix it before reporting done.

### Output Options

- Packaging:
  - **Separate STLs in a `.zip`** (default): one file per piece, named.
  - **One OBJ, named parts**: a single OBJ using `o`/`g` per piece (reuse the
    existing multi-object OBJ writer).
  - **Laid out on one plate**: a single combined file with pieces translated
    apart so they can be sent to a slicer as one arrangement.
- Part naming: a stable scheme (grid letters/numbers like `A1`, `B2` for
  axis-aligned grids; sequential `part-01…` otherwise).
- **Assembly map** (toggle, default on): a guide listing which piece joins which
  at which seam, key positions, and a recommended assembly order. Reuse and
  extend `AssemblyGuideExporter`.

## UI Requirements

The mode should feel like a deliberate fabrication tool, not a settings dump.

Primary inspector panels (top to bottom):

- **Build Volume**: printer preset picker, custom W/D/H, bed margin, live model-
  size readout.
- **Splitting**: Auto-fit / Manual segmented control. Auto-fit shows the
  computed grid (`2 × 1 × 3 = 6 parts`) and a strategy picker (fewest parts /
  even sizes / hide seams in flat areas — the last is a later refinement).
  Manual shows the plane list with add/remove and numeric positions, plus an
  "edit in viewport" affordance.
- **Seams & Keys**: key type picker, pin diameter, tolerance, pins per seam,
  edge margin.
- **Fit Check**: per-piece fit list and seam-keyability warnings.
- **Output**: packaging picker, assembly-map toggle, naming.
- **Generate** ("Partition & preview").

Viewport interaction:

- Source mesh shown semi-transparent.
- Cut planes shown as translucent rectangles with drag/rotate handles (Manual).
- Build-volume reference box visible.
- Pieces color-coded green (fits) / red (oversized) against the build box.
- Pin keys shown as glyphs on the seams.
- **Exploded-view slider** pulls pieces apart to inspect seams and keys.
- Changing planes or settings marks the result stale; export is disabled or
  warns until the user presses Generate.

Parameter UI:

- Physical units (mm) for build volume, margin, pin diameter, tolerance, edge
  margin, pin length.
- Integer steppers for pins-per-seam and per-axis division counts.
- Every generator path is deterministic from a seed control.

## Data Model

Add a persisted settings model, conceptually:

```swift
struct PartitionSettings: Codable, Equatable {
    var mode: PartitionMode               // autoFit | manual
    var buildVolume: PrinterVolume        // mm, usable interior
    var bedMargin: Double                 // mm, per-side
    var autoStrategy: PartitionAutoStrategy
    var planes: [PartitionPlane]          // the unified cut-plane set
    var key: PartitionKeySettings
    var packaging: PartitionPackaging
    var includeAssemblyMap: Bool
    var naming: PartitionNaming
    var seed: Int
}

struct PrinterVolume: Codable, Equatable { var width, depth, height: Double }

struct PartitionPlane: Codable, Equatable, Identifiable {
    var id: UUID
    var normal: Vec3      // unit normal
    var offset: Double    // plane: dot(p, normal) == offset, model space
    var source: PlaneSource   // auto | manual
}

struct PartitionKeySettings: Codable, Equatable {
    var type: PartitionKeyType            // none | pins | dovetail
    var pinDiameter: Double
    var pinLength: Double
    var tolerance: Double                 // radial female enlargement, mm
    var keysPerSeam: Int
    var edgeMargin: Double
}

enum PartitionMode: String, Codable { case autoFit, manual }
enum PartitionKeyType: String, Codable { case none, pins, dovetail }
enum PartitionPackaging: String, Codable { case separateZip, combinedObj, laidOutPlate }
enum PartitionAutoStrategy: String, Codable { case fewestParts, evenSizes, hideSeams }
enum PartitionNaming: String, Codable { case gridLabels, sequential }
enum PlaneSource: String, Codable { case auto, manual }
```

The final implementation does not need this exact shape, but it must preserve
these concepts in project files and headless exports, follow the
`StructureSettings` Codable/migration pattern (optional fields with defaults for
forward compatibility), and round-trip through save/open.

## Engine Architecture

Recommended internal split (separate files, mirroring the Structures engine
split):

1. **PartitionPlanner**
   - Accepts source `MeshSummary`, `PartitionSettings`, seed.
   - Resolves the plane set (Auto-fit computes; Manual uses stored planes),
     drives splitting and key placement, returns a deterministic `PartitionPlan`.

2. **PartitionAutoFit**
   - Given build volume, bed margin, model bounds, key allowance, and strategy,
     computes axis-aligned division counts and the resulting plane set.

3. **PlaneSplitter** (the core new primitive)
   - Splits one watertight solid piece by an arbitrary plane into two watertight
     capped pieces. Generalizes the existing axis-aligned half-space clip
     (`ThreeDSliceMeshExportBuilder.clipHalfSpace` / `clipTrianglesToSlab`) from
     "axis coordinate vs value" to "signed distance to an arbitrary plane," and
     caps by projecting the cut loop(s) into the plane's 2D basis, triangulating
     (reuse `ViewportSliceSolidRenderData.triangulate`, which handles holes via
     bridging), and lifting back.

4. **PartitionKeyBuilder**
   - For a seam (shared cap cross-section + plane), picks key sites (interior,
     `edgeMargin` clearance, deterministic from seed), builds the male boss into
     one piece's cap and the female pocket into the other's. No CSG.
   - Reports per-seam keyability.

5. **PartitionMesher**
   - Assembles per-piece meshes / OBJ layers / grouped output; applies the
     laid-out-plate translation when requested.

6. **PartitionExporter**
   - Writes separate STLs (via `ZipWriter`), named-object OBJ, laid-out single
     file, and the assembly map (via `AssemblyGuideExporter`).

7. **PartitionValidation**
   - Per-piece watertightness (`MeshPreflight`), finite coordinates, AABB vs fit
     box, seam keyability, piece count.

### Reuse map (do not reinvent)

- Mesh model: `MeshGeometryData { vertices: [Vec3], triangleIndices: [Int32] }`,
  `MeshSummary`, `Bounds3D` — `MeshInspector.swift`.
- Axis-aligned clip + cap reference: `ThreeDSliceMeshExportBuilder.swift`.
- Polygon (with holes) triangulation: `ViewportSliceSolidRenderData.triangulate`.
- Tube/cylinder primitive for pins: `StructureMeshBuilder.appendTube`.
- Bounds / unit scale / dimensions: `MeshScaler.swift`, `MeshInspector.boundsOf`.
- Watertightness facts: `MeshPreflight.swift` (`isWatertight`).
- Multi-file zip export: `ZipWriter.swift` (pattern in `EpsExporter+PerSheet`).
- Multi-object OBJ / multi-solid STL: `ObjExporter.swift`, `StlExporter.swift`.
- Construction-mode scaffold template: `.structures` end-to-end.
- Explicit Generate / off-main / stale-state: `sliceComputationEnabled` and the
  `structurePlan` computed-property pattern in `ContentView.swift`.

New geometry to build: box/prism primitive (trivial), arbitrary-plane clip and
cap, pin boss / socket pocket cap construction, dovetail cap (later).

## Suggested Implementation Order

Each step leaves the app building and shippable.

1. Add `ConstructionMode.partition`, restrict export formats to STL/OBJ, add
   `PartitionSettings` persistence, generated/stale state, the inspector panel
   skeleton, and an empty viewport preview. Hide Manufacturing and Slice
   Direction for this mode.
2. Auto-fit solver + `PlaneSplitter` for axis-aligned planes + capped pieces +
   STL/OBJ + zip packaging. This already delivers the core ask: divide an
   oversized model and export the pieces.
3. Generalize `PlaneSplitter` to arbitrary planes; add the Manual plane list and
   numeric editing.
4. Registration keys: locating pins + sockets with tolerance, key placement,
   fit/keyability warnings, and the assembly map.
5. Viewport editing: plane handles (place/move/rotate), build-box reference,
   piece color-coding, exploded-view slider.
6. Headless CLI flags + tests + visual evidence.
7. Polish and later items: dovetail key, seam-hiding strategy, presets.

## Acceptance Criteria

Functional:

- User can import STL/OBJ, choose **Partition**, set a build volume, press
  Generate, preview bed-sized pieces, and export them.
- Auto-fit produces pieces that all fit the effective fit box, or reports which
  do not and why.
- Manual mode lets the user add, move, and rotate arbitrary cut planes and see
  pieces update.
- Locating pins are placed on keyable seams with the configured tolerance;
  non-keyable seams fall back to butt joints with a warning.
- Export produces separate STLs in a zip, a named-object OBJ, or a laid-out
  plate, plus an optional assembly map.
- Project save/open round-trips all settings and the plane set.
- Headless export reproduces the same output from saved or CLI settings.
- Every generator path is deterministic from the seed.

Geometry:

- Every exported piece is watertight (`MeshPreflight.isWatertight`) with finite
  coordinates and valid indices.
- Male pin and female socket pairs share a footprint differing only by the
  tolerance; a printed pair fits.
- The union of pieces reconstructs the source volume (no dropped or duplicated
  regions) within tolerance.
- No piece exceeds the effective fit box after Auto-fit, or it is flagged.

UX:

- No flat cut-sheet export path appears for **Partition**.
- Parameter edits do not trigger expensive recomputation until Generate.
- Stale results are visibly marked; export warns or is disabled when stale.
- Dense models (hundreds of thousands of triangles) partition off the main
  thread with caching; the UI does not freeze.
- The default and reopened windows are large enough for the Partition inspector
  without clipping labels, menus, sliders, or the Generate action.

Tests:

- `swift test --package-path app/RefabArtist`
- `ConstructionMode` + `ExportFormatSupport` covers `.partition`.
- `PartitionSettings` Codable round-trip + project round-trip.
- Auto-fit division math: a model N× the bed on an axis yields the right count.
- `PlaneSplitter` on a cube/sphere: two watertight halves, capped, volume
  conserved within tolerance; arbitrary (non-axis-aligned) plane case.
- Key builder: male/female footprint differ by exactly the tolerance; both
  pieces watertight; non-keyable thin section falls back and warns.
- Fit-check flags an oversized piece and an unkeyable seam.
- Packaging: zip contains one STL per piece; OBJ has one object per piece.
- Headless command + Grasshopper-style not required (mesh only).
- Visual evidence: render the pieces of a cube and one organic mesh, exploded,
  showing keyed seams; show that changing the build volume changes the piece
  count and that tolerance changes socket size.

## Open Technical Risks

- Arbitrary-plane clipping must stitch cut edges into closed loops reliably
  before capping; degenerate/coplanar triangles need care. The axis-aligned code
  is the proven starting point.
- Capping concave or multi-loop cross-sections relies on the existing ear-clip +
  hole bridging; verify it holds for real organic sections, not just convex
  fixtures (the project's historical blind spot — test on concave sections).
- Pin placement on thin/concave sections must degrade gracefully to butt joints.
- Splitting a dense mesh against many planes is O(planes × triangles) naively;
  bucket triangles by piece and only clip within candidates, and cache by a
  settings hash. Keep it behind explicit Generate.
- Re-running Auto-fit while preserving manual planes needs a clear ownership tag
  per plane (auto vs manual).

## References

- Existing in-repo reference: `docs/prd-structures-construction-mode.md` and
  `docs/handoff-structures-construction-mode.md` (construction-mode scaffold).
- Axis-aligned solid slicing reference:
  `app/RefabArtist/Sources/RefabArtist/ThreeDSliceMeshExportBuilder.swift`.
