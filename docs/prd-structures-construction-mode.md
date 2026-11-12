# Refab Artist PRD: Structures Construction Mode

## Status

Drafted 2026-06-23 from owner direction. This is a new art-first construction
technique for generating sculptural support, lattice, scaffold, and organic
structures from source meshes.

This feature is not a Cura or PrusaSlicer replacement. Refab Artist generates
interesting, buildable sculpture geometry. Downstream slicing software remains
responsible for printer-specific supports, temperatures, speeds, brim/raft,
material profiles, and print-path constraints.

## One-line Summary

Add a mesh-only **Structures** construction mode that converts an imported mesh
into bounded, external, or through-object procedural structures, with editable
families such as organic trees, lattices, scaffolds, Voronoi cells, gyroids,
classic infill patterns, ribs, veins, roots, coral forms, and architectural
lamellae, then exports STL/OBJ and procedural Grasshopper definitions where
possible.

## Product Intent

The goal is to help artists create fascinating physical sculptures from the
hidden language of supports, infill, scaffolds, ribs, lattices, and generative
geometry.

The originating model is a control volume, obstacle, attractor, silhouette, and
optional output shell. The generated structure should remain meaningfully
bounded by or derived from that model, but it does not need to preserve the
model as a literal surface. The final object is the structure itself.

Reference visual directions:

- Porous Voronoi / trabecular surface and volume structures, like the supplied
  `Untitled1.jpg`.
- Irregular polygonal scaffold fields, like the supplied `Untitled.jpg`.
- Layered rib / lamella / contour structures with strong sculptural flow, like
  the supplied `500-2-4-300x300.jpg`.

## Users

- Artists using 3D printing, casting, ceramic shell, or hybrid fabrication.
- Makers who want support structures, infill, and lattices as the final object.
- Rhino / Grasshopper users who want a procedural version of the generated
  structure for further design work.

## Non-goals

- Do not rebuild Cura, PrusaSlicer, or a production FDM slicer.
- Do not guarantee that generated art prints without additional slicer supports.
- Do not add printer/material profiles, extrusion planning, G-code, print-time
  estimates, brim/raft settings, thermal controls, or slicer support warnings.
- Do not block artistic output because a slicer would consider it inefficient.
- Do not export flat cut sheets for this construction mode.

## Scope

### Construction Technique

Add one top-level construction mode:

- Label: **Structures**
- Export support: STL and OBJ only, plus Grasshopper `.gh` export.
- Project persistence: all settings, generator family, placement mode, seed,
  presets, and output options must be saved in Refab Artist project documents.
- Computation model: explicit **Generate** action, not live recomputation on
  every slider movement.

### Placement Modes

The mode has three placement strategies. All should be available to every
structure family where technically feasible.

1. **Internal Bounded**
   - Generate structures inside the source mesh boundary or inside an offset
     shell of that boundary.
   - User options:
     - Fill full volume.
     - Fill near shell only.
     - Leave hollow core.
     - Clip exactly to mesh boundary.
     - Keep a clearance from mesh boundary.
     - Include or exclude the original mesh shell in export.

2. **External Support Field**
   - Generate structures outside, on, or around the source model, similar in
     spirit to slicer supports.
   - User options:
     - Support detected overhang-like regions.
     - Decorative supports anywhere on selected surface regions.
     - Build plate only.
     - Everywhere.
     - Contact/fuse to source mesh or remain as separate shells.
     - Include or exclude source mesh in export.

3. **Through-object Field**
   - Generate structures from build plate through the object volume to the top
     or other selected terminating surface.
   - Structures may pass through the source model when selected; this is a
     sculpture generator, not a physical support planner.
   - User options:
     - Pass through object.
     - Avoid object interior.
     - Snake/curve around regions while terminating on bounding surface.
     - Start from build plate, bounding box, selected face band, or sampled
       base region.
     - End at top surface, all upward-facing surface regions, or full bounding
       shell.

## Structure Families

The product should ship with all families below. Some may share internal
graph/field infrastructure.

### Organic / Tree

Branching structures inspired by tree supports, roots, veins, mangroves,
vascular networks, coral, lightning, and growth systems.

Core controls:

- Seed.
- Branch count / density.
- Branch diameter.
- Tip diameter.
- Taper curve.
- Branch angle.
- Branch curvature.
- Branch smoothing.
- Branch merge distance.
- Collision/avoidance against source mesh.
- Contact style: fused, near-touch, separated, ball tip, flat pad.
- Gravity / upward bias.
- Attractor points/curves.
- Randomness / jitter.
- Symmetry.
- Trunk count.
- Trunk minimum radius.
- Maximum unsupported span, as an art control rather than a print guarantee.

### Lattice Cells

Periodic or semi-periodic cell structures clipped to the selected region.

Initial cell types:

- Cubic.
- Body-centered cubic.
- Octet truss.
- Tetrahedral / octahedral.
- Diamond.
- Kelvin-like.
- Honeycomb.
- Gyroid / TPMS-style implicit field.

Core controls:

- Cell size.
- Strut diameter.
- Cell type.
- Cell rotation.
- Cell anisotropy.
- Boundary clipping mode.
- Shell offset / clearance.
- Smooth node blending.
- Density gradient.
- Attractor-based density.
- Random distortion.

### Scaffold / Classic Infill

Architectural, slicer-inspired, and construction scaffold patterns.

Initial patterns:

- Lines.
- Grid.
- Triangles.
- Tri-hex / honeycomb.
- Cubic.
- Concentric.
- Lightning.
- Zig-zag.
- Sparse tower scaffolds.

Core controls:

- Spacing.
- Layer height / vertical pitch.
- Strut/wall thickness.
- Pattern angle.
- Alternate layer angle.
- Phase offset.
- Density.
- Boundary trim.
- Merge intersections.
- Smooth or sharp nodes.

### Voronoi / Cellular

Porous structures and cellular shells.

Core controls:

- Point count / cell size.
- Seed.
- Surface Voronoi vs volume Voronoi.
- Strut mode vs wall mode.
- Wall thickness.
- Strut diameter.
- Relaxation iterations.
- Boundary adherence.
- Irregularity.
- Open-cell vs closed-cell.
- Shell-only vs volume fill.
- Gradient density.

### Rib / Lamella / Contour

Layered rib systems, radial ribs, flow ribs, contour bands, and wood/plywood
lamellae inspired by sculptural pavilions and existing Refab Artist slice modes.

Core controls:

- Rib family: parallel, radial, spiral, contour, flow-field, cross-rib.
- Rib count or spacing.
- Rib thickness.
- Rib depth.
- Smoothing.
- Twist.
- Surface offset.
- Gap.
- Alternating direction.
- Intersections: merged, slotted visual, separated.
- Flow attractors.

### Growth / Field Hybrids

More experimental families should be supported as presets or family variants:

- Vein networks.
- Root systems.
- Coral branching.
- Differential-growth boundaries.
- Stress-line / principal-direction-looking fields.
- Particle trails.
- Streamline fields.

These can reuse the organic graph generator, lattice thickener, and field
sampling infrastructure.

## Presets

The feature must include named presets and allow users to edit and save them.

Initial presets:

- Bone Porosity.
- Ceramic Shell Tree.
- Mangrove Roots.
- Coral Scaffold.
- Architectural Ribs.
- Voronoi Skin.
- Sparse Lightning.
- Gyroid Cloud.
- Honeycomb Sheet.
- Dense Trabecular.
- Flow Lamella.

Preset rules:

- Presets are editable.
- Presets expose their underlying parameters.
- User-created presets store generator family, placement mode, parameters,
  seed, and export settings.
- Presets should be usable starting points, not locked black boxes.

## Geometry Requirements

The output must be reasonably good downstream geometry:

- Prefer mostly manifold output.
- Avoid obvious self-intersections where practical.
- Avoid stupid intersecting geometry in default presets.
- Do not require full remeshing for every family.
- Use robust thickening and node blending for graph-based structures.
- Allow multiple separate shells in one STL/OBJ output.
- Allow the source mesh and generated structure to remain separate shells.
- Provide OBJ groups/material names where useful:
  - `source_mesh`
  - `structure_trunks`
  - `structure_branches`
  - `structure_cells`
  - `structure_contacts`
  - `structure_shell`

Default FDM-safe starting assumptions:

- Use Bambu-class consumer FDM with a common 0.4 mm nozzle as the intuitive
  baseline, but keep all dimensions user-editable.
- Default minimum member diameter should be conservative enough for ordinary
  FDM art prints, with presets allowed to go thinner for experimentation.
- Do not add slicer-like printability warnings as a required workflow.

## Output Options

Per export:

- Include source mesh: on/off.
- Source mesh role:
  - reference shell,
  - fused shell,
  - separate shell,
  - hidden/control volume only.
- Structure shell relationship:
  - fused to source,
  - separate but touching,
  - separated by clearance,
  - clipped to boundary.
- Mesh export format:
  - STL,
  - OBJ with groups/material names.
- Grasshopper export:
  - `.gh` document where feasible,
  - generated structure should be procedural rather than baked mesh where
    possible,
  - stock Rhino/Grasshopper components only as the default target.

## Grasshopper Export

Grasshopper export is a first-class deliverable, not a later vague idea.

Requirements:

- Export a real `.gh` file.
- Prefer stock Rhino/Grasshopper components.
- Recreate the Refab Artist structure procedurally as closely as practical.
- Include visible, inspectable canvas stages:
  - input mesh,
  - bounds / clipping region,
  - sampling points,
  - graph/field generation,
  - thickening,
  - clipping,
  - mesh output,
  - bake/export-ready geometry.
- Expose the same major parameters users see in Refab Artist.
- Preserve seed-driven reproducibility where Grasshopper can match it.
- Avoid black-box one-shot scripts as the primary export path.

Acceptable fallback:

- If a family cannot be represented faithfully with stock components, export a
  visible Grasshopper definition with a clearly labeled scripted component for
  only the irreducible algorithmic part. The surrounding pipeline must remain
  inspectable.

## UI Requirements

The mode should behave like a serious creative tool, not a slicer settings dump.

Primary panels:

- Placement Mode.
- Structure Family.
- Preset.
- Shape Region.
- Parameters.
- Output.
- Generate.

Interaction:

- Changing parameters marks the generated structure stale.
- User presses **Generate** to rebuild.
- Viewport shows:
  - source mesh,
  - generated structure,
  - optional bounds/clipping shell,
  - optional start/end/contact points,
  - optional graph skeleton preview.
- Export is disabled or warns if generation is stale.

Parameter UI:

- Use physical units where they are intuitive: diameter, spacing, shell offset,
  wall thickness, clearance.
- Use normalized sliders where the concept is aesthetic: randomness,
  smoothness, curl, distortion, branchiness, organicity.
- Every generator has a seed control.
- Presets can be duplicated and edited.

## Data Model

Add a persisted settings model, conceptually:

```swift
struct StructureSettings: Codable, Equatable {
    var placementMode: StructurePlacementMode
    var family: StructureFamily
    var presetID: String?
    var seed: Int
    var includeSourceMesh: Bool
    var sourceMeshRole: SourceMeshRole
    var shellRelationship: StructureShellRelationship
    var bounds: StructureBoundsSettings
    var parameters: StructureParameters
    var output: StructureOutputSettings
}
```

Core enums:

```swift
enum StructurePlacementMode: String, Codable {
    case internalBounded
    case externalSupportField
    case throughObjectField
}

enum StructureFamily: String, Codable {
    case organicTree
    case lattice
    case scaffoldInfill
    case voronoiCellular
    case ribLamella
    case growthField
}

enum SourceMeshRole: String, Codable {
    case controlOnly
    case separateShell
    case fusedShell
    case referenceShell
}
```

The final implementation does not need this exact shape, but it must preserve
these concepts in project files and headless exports.

## Engine Architecture

Recommended internal split:

1. **StructurePlanner**
   - Accepts source `MeshSummary`, settings, and seed.
   - Builds a deterministic intermediate representation.

2. **StructureRegionBuilder**
   - Computes boundary volume, offset shell, build plate, top surface, base
     region, clipping region, and optional obstacle field.

3. **StructureSampler**
   - Produces points, curves, seed sites, voxel/field samples, surface samples,
     and attractor inputs.

4. **StructureGraphGenerator**
   - Generates centerline graphs for trees, roots, veins, lightning, scaffold
     frames, and ribs.

5. **StructureCellGenerator**
   - Generates cell complexes for lattice, Voronoi, honeycomb, TPMS/gyroid-like
     fields, and classic infill.

6. **StructureMesher**
   - Converts graphs/cells/fields to mesh shells.
   - Supports tube sweeps, node blending, wall thickening, shell clipping, and
     grouped output.

7. **StructureExporter**
   - Writes STL, OBJ, and Grasshopper definitions.

8. **StructureValidation**
   - Computes lightweight facts: vertex count, face count, shell count, bounds,
     non-manifold edge count where available, degenerate faces, obvious NaNs.

## Suggested Implementation Order

Although the requested product should be complete, implementation should still
land in coherent steps that leave the app working after each PR.

1. Add `ConstructionMode.structures`, mesh-only export support, settings
   persistence, stale/generated state, and empty placeholder viewport.
2. Add graph-based organic/tree generator for internal bounded and through-object
   modes.
3. Add scaffold/classic infill generator.
4. Add Voronoi/cellular generator.
5. Add lattice/gyroid-style generator.
6. Add rib/lamella generator.
7. Add growth-field variants and presets.
8. Add OBJ groups/materials and stronger validation summaries.
9. Add Grasshopper `.gh` export for each family, using visible procedural
   canvas stages.
10. Add headless CLI support and regression tests.

## Acceptance Criteria

Functional:

- User can import STL/OBJ, choose **Structures**, choose placement mode, choose
  family, adjust parameters, press **Generate**, preview result, and export STL
  or OBJ.
- User can include or exclude the source mesh.
- Source mesh and structure can export as separate shells.
- Every family has at least one useful preset and editable parameters.
- Every generator is seed-reproducible.
- Project save/open round-trips settings and stale/generated state.
- Headless export can generate the same output from saved or CLI settings.
- Grasshopper export creates a real `.gh` file for supported families.

Geometry:

- Generated mesh has finite coordinates and valid triangle indices.
- Generated mesh bounds respect the selected placement mode.
- Default presets avoid obvious self-intersections in simple fixtures.
- OBJ output uses useful object/group names.
- STL output opens in common slicers as a mesh.

UX:

- No flat cut-sheet export path appears for **Structures**.
- Parameter edits do not trigger expensive recomputation until **Generate**.
- Stale generated results are visibly marked.
- Presets are editable rather than opaque.

Tests:

- Unit tests for settings codability and migration.
- Unit tests for deterministic seed behavior.
- Geometry smoke tests for cube, sphere, bunny-like fixture if available, and
  a thin/tall irregular model.
- Export smoke tests for STL, OBJ, and `.gh`.
- Project round-trip tests.
- Headless command tests.

## Open Technical Risks

- Generating stock-component `.gh` files programmatically may require careful
  reverse engineering of Grasshopper file serialization or a Rhino-side helper.
- Robust clipping of arbitrary lattices and Voronoi cells to mesh interiors may
  need a voxel/SDF or manifold boolean path for quality.
- Tree/organic structures that snake through and around meshes need a practical
  pathfinding representation; exact mesh-aware collision is likely too slow if
  attempted naively.
- TPMS/gyroid output likely benefits from implicit sampling and marching cubes
  or an equivalent meshing path.
- "All families in all modes" is a product goal, but some pairings may need
  family-specific adaptations rather than identical algorithms.

## Research References

- CuraEngine support-area generation: `https://github.com/Ultimaker/CuraEngine/wiki/Generating-Areas`
- UltiMaker tree supports overview: `https://ultimaker.com/learn/tree-supports-what-are-they-and-how-do-they-work/`
- Cura Tree Support 2.0 discussion: `https://github.com/Ultimaker/Cura/discussions/14805`
- Prusa organic supports: `https://help.prusa3d.com/article/organic-supports_480131`
- Crystallon Grasshopper lattice toolkit: `https://www.food4rhino.com/en/app/crystallon`
- Rhino Grasshopper developer guides: `https://developer.rhino3d.com/guides/grasshopper/`
