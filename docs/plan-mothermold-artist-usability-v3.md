# MotherMold Artist Usability V3 Plan

Date: 2026-07-09

Implementation decisions that supersede the original milestone wording are
recorded in `docs/mothermold-v2-decisions.md`.

Research basis: `docs/research/mothermold-artist-workflow-2026-07-09.md`

## Delivery rule

Each milestone starts with a failing test or measured reproduction and ends with
evidence from final geometry or actual UI/export bytes. A build failure may
remain previewable, but no red manufacturing gate may be converted to a warning
to keep Export enabled.

## M0: Freeze current failures

Add deterministic tests for:

- a default thin conformal shell with requested keys;
- a final keyed build compared with the same build using no keys;
- a MotherMold GUI export request for each packaging mode and STL/OBJ choice;
- a nonempty plan containing an error diagnostic;
- assembled/exploded/assembled preview transforms;
- a jacket master with an adequate flat base and one with an inadequate anchor
  footprint.

Gate: every test fails for the intended reason before production changes.

## M1: Final-stage registration

1. Reorder the pipeline so flanges and subtractive pour features are complete
   before key placement.
2. Place key candidates on real flange mating regions, avoiding the cavity,
   flange boundary, bolt bores, other seams, and each other.
3. Apply each male/female pair transactionally.
4. Validate both parts after each pair and after all later feature/cleanup stages.
5. Persist final key sites and requested/placed counts in `MotherMoldPlan`.
6. Throw a blocking planner error when a requested key pair is absent or loses
   its male protrusion/female clearance.

Gate: default 2-part and 4-part organic fixtures retain the exact requested key
count after final cleanup; every male feature crosses its seam, every female
pocket accepts it with configured clearance, all parts are watertight, and
assembled parts have no positive-volume collision above numerical tolerance.

## M2: Honest export and error gating

1. Add an Output section with Packaging and Assembly guide controls.
2. Introduce one MotherMold export-request resolver used by the inspector, save
   panel, GUI writer, and tests.
3. Derive allowed content type and extension from packaging:
   - separate parts: ZIP containing STL files;
   - combined objects: OBJ;
   - laid-out plate: STL.
4. Reject format/packaging mismatches before opening or writing a file.
5. Make any `.error` diagnostic block `exportSnapshot` and expose its reason.
6. Change success text to "Ready to export" only when all hard gates pass.

Gate: file signatures, extensions, archive members, and success messages agree
for every mode. Error plans remain visible but cannot be exported.

## M3: Reversible exploded inspection

1. Store one normalized pull direction per final mold part.
2. Add a toolbar button with assembled/exploded icon states and tooltips.
3. Keep the master stationary; translate only mold preview entities by a stable
   distance based on mold bounds.
4. Rename MotherMold preview segments to Master, Mold, and Both.
5. Reset explode when the plan is removed or the user leaves MotherMold.
6. Exclude explode state from settings, signatures, project serialization, and
   exporters.

Gate: one press reveals all interior surfaces; the second press restores exact
assembled transforms. Plan equality, stale state, and exported bytes are
unchanged by any number of toggles.

## M4: Master retention and sealing

1. Add jacket-only master-mount settings:
   - `flatBaseSocket` (default);
   - `externalFixture` (explicit advanced fallback);
   - socket depth and fit clearance.
2. Analyze the downward-facing master footprint at the proposed socket depth.
3. For `flatBaseSocket`, generate a real split base plate and negative socket
   joined to the jacket parts. The socket must locate X/Y and support Z.
4. Add a perimeter seal land and state explicitly that fit clearance locates the
   master but does not seal liquid; compatible sealant is required before pour.
5. Include mount geometry in volume, watertightness, component, bed-fit, preview,
   export, and assembly-guide checks.
6. Block export when the measured footprint is unstable; tell the artist to
   reorient the intended base downward or choose an external fixture.
7. For `externalFixture`, record a prominent unresolved-fixture warning and a
   required assembly-guide step; never describe the master as auto-secured.
8. Hide this control for direct rigid-negative/slip-shell builds and explain that
   the master is not present during casting.

Gate: the generated socket has a sufficient continuous footprint, cannot slide
laterally by more than fit clearance, is connected to the exported shell,
retains at least 98 percent of its measured locator geometry in final parts, and
preserves a valid fill volume. The guide shows how the master is mounted and
where the artist must apply sealant.

## M5: Parting and demold feedback

1. Persist `PartUndercutReport` regions in the plan.
2. Score auto candidates by trapped-region count, maximum depth, affected area,
   disconnected-part penalty, and flange feasibility. Silhouette area is only a
   tie-breaker.
3. Add visible pull-axis arrows and red/yellow/green draft/undercut overlay.
4. Implement manual primary axis and offset; add an orthogonal secondary axis for
   four-part molds.
5. Rebuild only on commit; allow cheap live plane preview during adjustment.
6. Remove the word "demoldable" from any state that has a blocking undercut.

Gate: the chosen auto candidate has the best deterministic score among evaluated
candidates, manual edits affect real planes, and all organic rigid-shell fixtures either
pass or stop export with visible trapped regions.

## M6: Honest shell semantics and pour system

1. Rename Gap to Nominal clearance.
2. Rename Smooth to Extra softening, default it to 0, and display Total offset =
   clearance + softening while the current Minkowski implementation is used.
3. Preserve the complete cavity for both subtypes. Build one controlled,
   sacrificial funnel and fill channel on a single mold part; never truncate the
   artwork with a cavity-sized open face.
4. Add manual spout/vent point editing with auto placement as the starting point.
5. Validate vent endpoints against high trapped-air regions and fill direction.
6. Add exterior pry points clear of the liquid seal.
7. Present the persisted `slipShell` case as Rigid casting shell. Do not claim a
   printed plastic negative can perform absorbent ceramic slip casting.

Gate: measured cavity offset matches the displayed total; every subtype has one
verified fill path owned by one part; automatic placement avoids seams and a
manual seam location is rejected transactionally; requested vents either
survive or block with a precise reason.

## M7: Manufacturing and artist workflow

1. Add per-part selection, isolate/show-all, and interior inspection while
   exploded.
2. Compute minimum wall, critical casting-surface overhang/support risk, part
   dimensions, and bed fit.
3. Replace generic laid-out translation with bed-aware packing and explicit
   orientation metadata.
4. Update the assembly guide with rendered assembled/exploded views, part names,
   hardware, socket/fixture, gasket/seal, material quantities, pour order, vent
   confirmation, cure/demold steps, and subtype-correct language.
5. Add silicone mass estimates from user-selectable density as well as volume.

Gate: an artist can answer, from Refab Artist alone, what to print, how each part is
oriented, how the master is held and sealed, how the mold closes, where material
enters and air exits, and why Export is blocked when any answer is missing.

## M8: Evidence and package

Run the full subtype x part-count x fixture matrix plus focused GUI tests.

Required evidence:

- final geometry measurements for keys, flange attachment, overlap, sacrificial
  fill gate, master locator retention, seal land, components, and watertightness;
- undercut scores and screenshots with overlays;
- assembled, exploded, isolated, and restored screenshots on desktop and compact
  windows;
- actual exported byte signatures and archive contents;
- deterministic rerun hashes;
- rebuilt app bundle launched against at least one simple master and two organic
  masters;
- a second artist-usability audit listing all remaining limitations plainly.

Stop line: do not call V3 complete, package it as ready, or enable manufacturing
export for a case whose final evidence matrix contains a red gate.
