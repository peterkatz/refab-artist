# Refab Artist — Product Requirements

> Product name **Refab Artist** (adopted 2026-10-07). The project's earlier name was NeoSlicer; a few older documents and settings keys still use it.

## What it is

An original, Apple Silicon-native macOS app that takes a 3D model and produces flat parts you can cut on a laser, CNC, or by hand — plus assembly instructions to put them back together into the original shape.

## Why this exists

Building an object from flat sheet material — plywood, MDF, acrylic, cardboard — starts with turning a 3D model into parts a laser cutter, CNC router or hand saw can cut: slices or panels laid out on sheets, joints that fit the material's real thickness, and an order to put them together in. Doing that by hand is slow and error-prone.

Refab Artist does it as an open-source, Apple Silicon-native Mac app, written from its own specifications: import a mesh, choose a construction technique and material, and export cut sheets with assembly steps.

## Users

Makers, hobbyists, makerspace staff, fab-shop operators, design-tech educators, anyone doing assemble-from-flat-parts construction. Solo and small-shop scale. Not enterprise. Not commercial production lines.

## In scope

- Six construction modes: **Stacked**, **Interlocked**, **Curve**, **Radial**, **3D Slices**, **Folded Panels**
- Mesh and casting modes, which write STL/OBJ rather than cut sheets: **Structures** (infill, supports, skin), **Partition** (bed-sized keyed pieces, and splitting by undercuts) and **MotherMold** (two- and four-part casting molds)
- **Inflatables** (flat panels and seams for inflatable sculpture) ships as an experimental mode, hidden behind Settings > Show experimental modes
- Whole-model mesh tools in the Modify Form panel: **Make Watertight** (Fix in place, Make walls, Rebuild as solid), **Hollow** and **Thicken**
- Mesh import: STL (binary + ASCII), OBJ
- Vector exports: DXF, SVG, PDF, EPS (for cutting)
- Mesh exports: STL, OBJ (for verification and downstream use)
- Per-mode parameters: material thickness, kerf, slot offset, notch width, notch angle, slot relief, dowel placement, slice count and distribution, model scale, target dimensions, unit normalization
- Sheet layout with pagination, auto-rotation, fit summary, overflow highlighting, visible sheet labels
- 3D preview viewport (RealityKit) with orbit/pan/zoom, snap presets (iso/front/right/top), layer toggles (Model / Slices / Both)
- Assembly step guidance, step navigation, viewport step highlighting, sheet-preview clickable parts, assembly guide export
- Project save / open (native document format)
- Material presets (plywood, MDF, acrylic, cardboard, common thicknesses)

## Non-goals

- Not a copy of any other app's interface. The workflow is mode-first, parameter-panel, sheet-preview (`docs/specs/ui-workflow.md`), built from native macOS controls (real menus, real inspectors, real file dialogs).
- Not a plugin for, or an integration with, any CAD application. It works on exported meshes (STL, OBJ).
- Not cross-platform. macOS Apple Silicon only. Intel macOS not supported. Windows / Linux out of scope.
- Not a paid product. No accounts, no telemetry, no cloud.
- Not a general-purpose CAD or mesh-editing tool. Import a mesh; cut it up; export. That's it.

## Approach

### Clean-room, spec-first

Refab Artist never copies, decompiles or disassembles other software, its UI resources, help text or output files, and uses third-party code only under a compatible licence, listed in `THIRD_PARTY_NOTICES.md`. The discipline is:

1. **Write a plain-English spec.** For each mode, document what it does in enough detail that two independent implementers would arrive at behaviorally equivalent code. Specs live in `docs/specs/<mode>.md` as first-class deliverables.
2. **Implement from the spec.** Write Swift from the spec. When the behaviour changes, the spec changes with it.
3. **Prove it with the gates.** The functional gate and physical cut tests decide whether a mode works (§ Success criteria).

### Spec depth requirement

Specs must be deep enough that physical-material testing is a confirmation, not a debugging tool. Each mode spec MUST include:

- **Parameter inventory**: every input, valid range, units, defaults, interactions with other parameters
- **Decision logic**: flowchart-level description of how the mode decides slice count, slice positions, slot positions, slot dimensions, kerf compensation, etc.
- **Intermediate data structures**: what's computed and held between input and output
- **Edge cases**: behavior on non-manifold meshes, self-intersecting meshes, zero-area faces, very dense meshes, very sparse meshes, meshes thinner than slice thickness, meshes at scale boundaries
- **Output structure**: per export format, what layers/entities/colors/labels are written, in what order, with what coordinate system
- **Worked example**: an actual fixture run through the algorithm by hand or pseudocode, with arithmetic shown
- **Known issues**: where the current code falls short of what the mode should do

### Validation

Refab Artist's output is judged on its own terms: the functional gate (cuttability invariants on a fixture corpus of the project's own models), the assembly gate, the Swift test suite, and physical cut-and-assemble tests. Matching another program's output files is not a goal.

## Success criteria

- All six modes pass the **functional-correctness gate** (`scripts/functional_gate.py` — cuttability invariants; see `docs/functional-gate.md`) across the fixture corpus. This is the ship/launch gate.
- All exports (DXF/SVG/PDF/EPS/STL/OBJ) are structurally valid and open correctly in target downstream tools (Illustrator, AutoCAD, LightBurn, Inkscape, Lightroom-class slicers)
- At least one real-world fixture cuts and physically assembles on baseline material (laser-cut plywood)
- App runs natively on Apple Silicon, with no Intel binaries in its dependencies
- Source is GPL-3.0 licensed, repo is public, README is accurate, contribution path is documented

## Licensing

- **Source license: GPL-3.0** (full text in `LICENSE`). Copyright is held by Pete Katz. Contributions are accepted under the contributor agreement in `CONTRIBUTING.md`: contributors keep their copyright, license their work to the project under GPL-3.0, and additionally grant Pete Katz the right to relicense it under any licence, including proprietary and commercial licences.
- **Distributed binary license**: GPL-3.0. The geometry engine statically links `manifold` (Apache 2.0) for 3D mesh operations and `Clipper2` (Boost) for 2D polygon operations; both are GPL-3.0-compatible and are listed in `THIRD_PARTY_NOTICES.md`. CGAL is **not** a dependency (decision D2, 2026-05-25).
- **No other software's assets in the repo, ever.** No app bundles, executables or libraries, interface files, icons, help documents, installers or anything extracted from them, and no files produced by other software as test evidence.
- **No code or text copied from other software.** No code, strings or symbol names copied from other software in code, comments or docs, and no third-party code without a GPL-compatible licence (`THIRD_PARTY_NOTICES.md`).

## Resolved direction (decisions D1-D4, 2026-05-25)

- **Engine architecture (D1):** Swift-only. No separate C++ engine. `engine/src/`, `cli/`, top-level `CMakeLists.txt` to be deleted (NEO-33). Geometry uses `manifold` (Apache 2.0) for 3D mesh ops and `Clipper2` (Boost) for 2D polygon ops, called from Swift via small C interop layers. macOS-only is a hard scope assumption.
- **CGAL (D2):** Not used. Surgical escape hatch only — if Manifold/Clipper2 can't handle a specific pathological case, CGAL could be added behind a feature flag for just that operation, producing a two-tier distribution. Default binary remains CGAL-free.
- **Public-launch trigger (D3, revised 2026-06-08):** All six construction modes pass the **functional-correctness gate** (`scripts/functional_gate.py`; see `docs/functional-gate.md`), plus the lighter Phase 7 launch tasks. A stranger downloading v0.1.0 gets the whole tool, every mode, producing cuttable parts.
- **Distribution (D4):** GitHub releases only. README points at the releases page. No Homebrew cask. No Mac App Store (incompatible with current artifact policy anyway).

## Known open considerations (not decisions, just things to track)

- **Physical material validation.** Needs real laser-cutter runs at some point. Not blocking software work but blocking "Refab Artist is trustworthy" claims. Happens at the end per project owner.
- **OpenClaw's role going forward.** Currently paused. If revived: bounded builder/verifier on queued tickets only; never autonomous-controller mode.
