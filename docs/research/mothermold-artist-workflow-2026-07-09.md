# MotherMold Artist Workflow Research

Date: 2026-07-09

## Purpose

This note records the current MotherMold failures, how established mold tools
handle the same problems, and the product decisions that follow. It is evidence
for the implementation plan in `docs/plan-mothermold-artist-usability-v3.md`.

The standard is not that Refab Artist can produce geometry. An artist must be able
to understand the mold, inspect every mating surface, hold the physical master
in a known position, recognize a blocked build, and export files whose contents
match their names and controls.

## Current stop-ship problems

### 1. Registration keys do not survive the final pipeline

- Default rigid wall: 4 mm.
- Default round key footprint needs about 14.9 mm of usable seam width after
  radius, tolerance, and edge margins are counted on both sides.
- Keys are currently attempted on the thin conformal wall before flanges exist.
- `MoldFlangeBuilder` later normalizes every part back to its parting half-space.
  That trim removes the male protrusion while leaving the female pocket.
- A reproduced two-part build reported one key but the keyed output contained
  about 343 mm3 less material than the no-key output. The remaining male-side
  change was only an embedded remnant, not a usable boss.

Decision: registration belongs on the finished flange plates after spout and
vent bores. Requested keys are a manufacturing contract: both mating features
must survive final cleanup, or the build is blocked.

### 2. GUI export can put ZIP bytes in an STL file

- MotherMold defaults to `separateZip` but the inspector does not expose
  packaging.
- The save panel derives its extension from the global STL/OBJ selector and does
  not include MotherMold packaging in its ZIP decision.
- The exporter then follows the hidden MotherMold packaging value.
- Reproduction: the GUI proposed an `.stl` name while the written file began
  with the ZIP `PK` signature.

Decision: packaging is visible, and the save-panel type, extension, bytes, and
success message all derive from one export request.

### 3. Plans with blocking errors can still be exported

- `MotherMoldUIContract.exportSnapshot` checks only that a current plan has
  parts.
- Undercut, missing flange, or missing pour-system errors do not disable Export.
- The interface can say both "Built 2 mold parts" and that the build has errors.

Decision: an error plan is inspectable but not manufacturable. The viewport
remains available, while Export is disabled with the first blocking reason and
a specific recovery action.

### 4. Auto parting is described more strongly than it works

- The current axis score uses projected convex-hull area, not undercut depth or
  trapped-region count.
- Organic rigid-shell fixtures retain serious undercut errors.
- Undercut regions are reduced to text diagnostics; artists cannot see them.
- Manual parting is visible but disabled.

Decision: stop calling auto output demoldable unless the measured undercut gate
passes. Candidate parting directions must be scored by the same draft/undercut
measurement shown in the viewport. Manual axis and offset controls are required
as the recovery path.

### 5. Gap and smoothing are not independent

The jacket cavity currently offsets by `siliconeGap + smoothing`. A displayed
6 mm gap plus 3 mm smoothing therefore produces about 9 mm of clearance.

Decision for the current exact geometry engine: expose one honest nominal
clearance and an optional, explicitly additive detail-softening amount, show the
resulting total offset, and default softening to zero. A later surface-fairing
algorithm may preserve nominal clearance, but the UI must not imply that today.

### 6. There is no useful mold-inspection workflow

- No reversible exploded/assembled control.
- No part isolation or interior-oriented labels.
- Generic preview labels call mold parts "Slices."
- No visual undercut overlay.
- No print-orientation, bed-fit, minimum-wall, or support-surface check.

Decision: add a view-only Explode toggle that moves each part along its actual
pull direction while the master remains fixed. Pressing it again must restore
the exact assembled view. Explode state must never change the generated plan,
staleness signature, project geometry, or export bytes.

### 7. A silicone-jacket master has no retention system

The closed jacket assumes a physical master can remain centered in an empty
silicone gap during assembly and pouring. It cannot do so reliably without a
fixture. A flat floor alone does not touch or locate the master.

Decision: jacket builds require an explicit master-mount strategy.

- **Flat-base socket (default):** the artist orients the intended mounting face
  downward. Refab Artist generates a split base plate and shallow negative socket
  that locates the bottom of the master and provides a seal land. Fit clearance
  is not a liquid seal; the artist must apply compatible clay or reusable
  sealant continuously around that land.
- **External fixture:** for a master that cannot sacrifice a base opening, the
  artist explicitly chooses an external stem, suspension, or custom fixture.
  Refab Artist reports the unresolved fixture as a manufacturing warning and the
  assembly guide records the choice. It is never silently assumed.
- The automatic socket is accepted only when its measured contact footprint is
  large enough to resist sliding and tipping. Otherwise the build is blocked
  with instructions to reorient the master or choose an external fixture.

For direct rigid-negative output, the original master is not present
during casting. The interface and guide must explain that distinction instead
of showing a master-retention control that does not apply.

### 8. A printed plastic shell is not a ceramic slip-casting mold

Ceramic slip casting depends on an absorbent plaster working mold drawing water
from the clay slip. USG describes pottery plaster specifically as an absorbent
slip-casting mold material. A normal FDM/resin-printed shell is nonporous and
cannot honestly promise that process.

Decision: retain the persisted `slipShell` identifier for project compatibility,
but label the current output **Rigid casting shell** and describe it as a direct
negative for compatible casting materials. A true ceramics workflow would use
printed tooling to make a plaster working mold and is a separate future subtype.

Sources:

- https://assemblies-tools.usg.com/content/usgcom/en/products/industrial/ceramics/pottery-plaster-regular.html
- https://www.usg.com/api/download-center/v1/assets/05fee646-adc1-53e7-b178-db371bbde3f9?country=us&download=true

## Comparable tools and practices

### Moldboxer (Blender)

Official Moldboxer material shows an automatic path for simple centered meshes
and a manual pre-confirm stage where the artist moves/scales the box, funnel,
and channels. It also exposes Heal, Clean Cut/flat-master preparation, Clear
Extraction, custom channels, inner cores, and two-part silicone molds. Product
images place alignment features on broad parting surfaces and show masters or
cores supported by a flat base/top plate.

Patterns to adopt:

- automatic first result plus editable geometry before final generation;
- visible extraction/demold operation;
- flat-master preparation and a real support plate;
- channels and funnel positions that can be corrected manually;
- keys on broad mating plates rather than inside thin walls.

Sources:

- https://moldboxer.com/?lang=en
- https://moldboxer.com/download/linux
- https://moldboxer.com/guides
- https://moldboxer.com/buy

### FormArmor Pro (Blender)

FormArmor documents separate controls for clearance, wall thickness, open base,
and bottom trim; automatic and manual cut planes; split/merge refinement; an
open/close mold-parts action; hardware placement after the mold parts exist;
manual hardware placement; draft coloring; gates/vents; volume estimates; and
batch export.

Patterns to adopt:

- assembled/exploded inspection as a first-class action;
- manual recovery after automation;
- hardware applied to completed parts;
- red/yellow/green draft feedback in the viewport;
- a pre-export checklist that refers to measured geometry.

Source: https://superhivemarket.com/products/formarmorpro/docs

### SOLIDWORKS Mold Tools

SOLIDWORKS separates draft analysis, undercut analysis, parting-line analysis,
shutoff surfaces, interlock surfaces, and tooling split. It can display core and
cavity transparently or move them apart by a specified distance.

Patterns to adopt:

- analysis before the tooling split is treated as actionable geometry, not a
  paragraph of warnings;
- the pull direction is explicit and reversible;
- interlocks and shutoffs are separate, inspectable mold features;
- separated and transparent views are inspection tools, not exported geometry.

Sources:

- https://help.solidworks.com/2023/english/SolidWorks/sldworks/c_Mold_Design_Tools_Overview.htm
- https://help.solidworks.com/2024/English/solidworks/sldworks/HIDD_MOLD_CAVITY_CORE_SOLIDS.htm

### Formlabs silicone-tooling guidance

Formlabs documents alignment features that constrain embedded objects, mating
registration features, fill gates, air vents, pry points, clamping in the draw
direction, and keeping critical interior surfaces free of print-support marks.
Its detailed guidance notes that alignment pins should follow the draw direction
and that venting must follow likely air traps.

Patterns to adopt:

- distinguish master/object alignment from mold-half registration;
- validate vents against fill direction and likely trapped-air regions;
- provide exterior pry points;
- orient parts to protect the casting surface.

Sources:

- https://formlabs.com/global/blog/casting-silicone-guide/
- https://formlabs-media.formlabs.com/rs/060-UIG-504/images/WP-EN-Silicone-Molding-For-Product-Design.pdf

### Smooth-On moldmaking guidance

Smooth-On requires the model to be secured to a baseboard and sealed around its
perimeter so liquid rubber cannot flow underneath. It separately requires all
mold-box seams to be sealed and describes positive/negative registration keys
for multi-part rubber molds.

Pattern to adopt: master location and liquid sealing are explicit operations.
Neither can be inferred from a generic floor toggle.

Source: https://www.smooth-on.com/assets/pdf/Smoothon_HTB_2008.pdf

### Shape Cast research system

Shape Cast uses an interactive proof before fabrication, separates outer mold
parts for printing/disassembly, adds flanges with bolts and heat-set inserts,
anchors inner and outer forms with a bottom ring, provides gasket material to
prevent leakage, and reports material quantities. It also protects critical
surfaces from support damage through print orientation.

Patterns to adopt:

- dedicated anchor/base component;
- gasket/seal provision;
- explicit fasteners and assembly order;
- manufacturing-aware orientation and material readout.

Source: https://inovo.studio/pubs/shapecast-chi24.pdf

## V3 product decisions

1. Explode is a reversible viewport toggle, with the master fixed and mold parts
   translated along stored pull directions. It is never a generation setting.
2. Keys are built after flanges and all subtractive pour features, then validated
   against the final geometry.
3. Requested registration count is exact-or-blocking, not best effort.
4. Blocking diagnostics disable manufacturing export but preserve inspection.
5. MotherMold packaging is explicit and drives both the save panel and writer.
6. Jacket master mounting defaults to a generated flat-base socket/plate.
7. External master fixturing is an explicit alternative, not an invisible
   assumption.
8. Rigid-shell/direct-negative output does not claim that a physical master stays
   inside the mold during casting.
9. Auto parting is ranked by measured demoldability and exposes a manual axis and
   offset recovery path.
10. Clearance language reports the actual offset performed by the engine.
11. The assembly guide must identify the master mount, seal/gasket, fasteners,
    pour material, vent path, and print orientation.
12. No build is called ready until organic fixtures pass the same final export
    gates used by the GUI and headless path.
13. The legacy `slipShell` subtype is presented as a nonporous rigid casting
    shell, not as a ceramic slip-casting plaster mold.
14. Both subtypes preserve the complete intended cavity and use one controlled,
    sacrificial funnel and fill channel owned by one part. The earlier rigid
    open-face proposal is rejected because it removed artwork and could open the
    far wall or floor.
15. Four-part flange and key counts are based on four physical part-pair
    interfaces, not the two infinite split planes.
16. MotherMold registration uses 8-degree tapered round or tapered bar keys;
    legacy `pins` and `dovetail` names remain only for serialized compatibility.
17. Partial topology repair is never accepted. A replacement geometry must pass
    the same printable gate used for export.
