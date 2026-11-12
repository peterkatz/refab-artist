# Engine Convergence

> Historical. Decision D1 (2026-05-25, `docs/PRD.md`) made the engine Swift-only, and the C++ engine and CLI described below were removed. This note records the comparison that led there.

PR #63 currently has two geometry surfaces:

- a broad Swift app/exporter surface that drives the prototype UI and headless smoke tests
- a narrow C++ engine/CLI surface that covers importer inspection, stacked slice planning/contours, and stacked DXF output

This split is useful for bootstrapping, but it is not safe as a long-term architecture unless cross-language equivalence is measured explicitly.

## Swift Surface

The Swift app currently owns the broadest behavior:

- mesh import/preflight/scaling: `MeshInspector.swift`, `MeshPreflight.swift`, `MeshScaler.swift`
- construction modes: `StackedSlices.swift`, `InterlockedSlices.swift`, `RadialSlices.swift`, `CurveSlices.swift`, `ThreeDSlices.swift`, `FoldedPanels.swift`
- joinery and slots: `InterlockedSlotCutouts.swift`, `InterlockedSlotGuides.swift`, `RadialSliceSlotCutouts.swift`, `ThreeDSliceSlotCutouts.swift`
- vector exports: `DxfExporter.swift`, `SvgExporter.swift`, `EpsExporter.swift`, `PdfExporter.swift`
- mesh exports: `ObjExporter.swift`, `StlExporter.swift`, plus mode-specific mesh builders
- sheet/layout preview: `ExportLayoutSettings.swift`, `ExportSheetPreview.swift`
- assembly guidance: `AssemblySteps.swift`, `AssemblyGuideExporter.swift`, `AssemblyStepHighlight.swift`, `AssemblyStepNavigation.swift`
- current broad export smoke: `HeadlessExportSmokeTests.swift`

This is the behavior the gates check, because it is what the app actually presents.

## C++ Surface

The C++ engine is much smaller:

- `engine/include/slicer/mesh.hpp`
- `engine/include/slicer/stacked_slices.hpp`
- `engine/include/slicer/dxf_export.hpp`
- `engine/src/mesh.cpp`
- `engine/src/stacked_slices.cpp`
- `engine/src/dxf_export.cpp`
- `cli/src/main.cpp`

Current C++ coverage:

- ASCII STL, binary STL, and OBJ inspection
- mesh bounds/count metadata
- stacked slice planning on X/Y/Z axes
- stacked contour extraction
- stacked DXF export
- JSON output for CLI measurement

Current C++ gaps:

- interlocked, radial, curve, 3D slices, and folded panels
- kerf/slot/notch/dowel behavior beyond the stacked helper path
- zipped multi-sheet DXF plan packaging
- Swift app project/settings semantics
- Swift exporter equivalence checks

## Decision

Short term: the Swift app/exporter surface is the authority because it is the broad prototype users can run.

Medium term: do not crown the C++ engine as authoritative until equivalence tests exist. The C++ engine can become the durable geometry core, but only after behavior is moved behind shared contracts and proven against the Swift/app surface.

## First Cross-Language Test

Define the first cross-language comparison around the simplest shared slice case:

```text
case_id: cross_language_stacked_cube_z_5mm
fixture: tests/fixtures/cube_ascii.stl
mode: stacked
axis: z
material_thickness_mm: 5
expected shared facts:
  - slice_count
  - slice_positions
  - contour layer_count
  - per-layer path_count
  - per-layer point_count
  - per-layer bounds
  - DXF line_count
  - DXF layer names and line counts
```

Candidate producers:

- C++: `build-cmake/slicer_cli --json --stacked --contours --axis z --thickness 5 --export-dxf ... tests/fixtures/cube_ascii.stl`
- Swift: `swift run --package-path app/RefabArtist RefabArtist --headless-export ...`

Both commands should write the same measurement JSON shape, or directly comparable intermediates that one normalizer can read.

Current first result:

- C++ and Swift agree on slice count for `cross_language_stacked_cube_z_5mm`: 10
- C++ and Swift agree on slice positions
- C++ DXF line count: 40
- Swift DXF line count: 44

The line-count mismatch is expected for now because the Swift exporter writes additional DXF entities such as labels/sheet behavior that the C++ helper does not. That difference should become an explicit equivalence policy instead of an accidental divergence.

## Next Implementation Step

Expand the Swift headless export command across all modes/formats before widening the C++ engine. That keeps equivalence measured against the app's actual behavior rather than only the narrow C++ helper.
