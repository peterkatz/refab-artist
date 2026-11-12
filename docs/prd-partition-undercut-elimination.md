# Refab Artist Specification: Rigid-Mold Partition

## Status

- **Document type:** product requirements, geometry contract, implementation plan, and research record
- **Proposed UI name:** **Split for Two-Piece Molds**
- **Internal working name:** undercut-elimination partition purpose
- **Parent feature:** `ConstructionMode.partition`
- **Status:** proposed; implementation must not begin before the M0 feasibility and IP gates
- **Written:** 2026-07-10
- **Target process for the first release:** rigid, reusable, two-piece molds with opposite linear pull directions

## Decision Summary

Refab Artist should add **Split for Two-Piece Molds** as a second purpose inside the existing
**Partition** construction mode:

1. **Fit Printer** keeps the current behavior: split an oversized model into
   bed-sized pieces.
2. **Split for Two-Piece Molds** divides a model into the fewest practical pieces for which
   Refab Artist can prove a valid rigid two-piece-mold release direction.

The user-facing promise is not merely "fewer undercut-looking faces." The hard
contract is:

> Every exported piece has a stored pull axis and passes the complete
> fixed-direction DHF verifier after all seams and assembly features have been
> applied.

This is a real and studied problem. The closest published precedent is
**Volume Decomposition for Two-Piece Rigid Casting** (Alderighi et al., 2021),
which automatically partitions a watertight solid into double-height-field
parts. **CoreCavity** (Nakashima et al., 2018) is the strongest interaction and
seam-editing precedent for thin shells. As of July 2026, the surveyed products
did not reveal a maker-oriented desktop or web tool that combines automatic
solid-object decomposition, a hard two-piece-moldability certificate, editable
seams, assembly locators, and export. This is an evidence-bounded capability
gap, not a claim that no unreviewed or private tool exists.

The recommended delivery path is deliberately staged:

- **First shippable solver:** scoped planar cuts in a binary cut tree, using
  Refab Artist's existing arbitrary-plane splitter, with a deterministic search and
  an exact final release gate. This will solve a useful subset of models without
  adding a volumetric meshing dependency or pretending to solve every case.
- **Later research solver:** freeform volumetric double-height-field
  decomposition, only after an architecture, license, and freedom-to-operate
  review.

Automatic mold generation is not part of this feature. It remains a separate
MotherMold concern. Split for Two-Piece Molds outputs the decomposed object pieces,
assembly information, and a moldability report.

## Premise Audit

### The feature is valid, but "undercut" needs a process definition

An undercut does not exist in isolation. It exists relative to:

- a manufacturing process;
- one or more pull directions;
- the number and rigidity of mold pieces;
- the permitted extraction motion;
- clearance, draft, and material deformation assumptions.

Three problems that sound similar are not interchangeable:

| Problem | Actual goal | Required geometric property |
|---|---|---|
| Support-free FDM printing | Avoid support below overhangs | One-sided printability under a layer/build direction |
| One-piece/open-face molding | Remove a cast from one mold component | A pyramidal or single-height-field part |
| Rigid two-piece molding | Remove two mold halves in opposite directions | A double-height-field part plus a valid extraction path |

This specification targets the third row. Support-free printing may reuse some
analysis later, but must not be presented as the same feature.

### The feature splits the object, not the mold

There are two different ways to cope with a complex shape:

1. keep the object whole and design one supported rigid or flexible mold
   assembly around it; or
2. split the object into simpler pieces, cast each piece in a simple two-piece
   mold, and assemble the pieces afterward.

Split for Two-Piece Molds implements option 2. Current MotherMold supports a
limited family of 2/4-part rigid shells and silicone jackets for option 1; it
does not design arbitrary sliders, side actions, inserts, or advanced tooling.
Those remain out of scope. Keeping this boundary explicit prevents the UI,
validation, and exported artifacts from making the wrong promise.

### Existing Refab Artist foundations are useful but not sufficient

The current Partition implementation already provides:

- a mesh-only construction mode;
- an arbitrary-plane split/cap primitive that is watertight on the current
  fixture coverage, but is not yet attributed or a universal proof;
- pin, wedge, and butt-joint seam construction;
- an async Generate/stale-result UI pattern and one-plan cache, but no
  cooperative planner cancellation, progress stream, or reusable analysis
  cache;
- project persistence;
- exploded preview;
- STL/OBJ/ZIP packaging and an assembly-map path.

MotherMold provides useful but process-specific heuristics:

- undercut-region reporting;
- candidate pull-axis scoring;
- sampled translated collision checks that are not a continuous proof;
- undercut markers and demold-direction preview movement.

The main architectural mismatch is that current Partition planes are global:
every plane is applied to every current piece that it crosses. Sensible
undercut removal needs a **scoped recursive cut**: split this troublesome piece,
without cutting already-valid siblings. It also needs stable piece identities,
seam adjacency, pull directions, validation certificates, and an assembly or
disassembly sequence. Those concepts do not exist in the current
`PartitionPlan`. M0 must build an independent DHF contract; it must not turn
the current MotherMold analyzer into a generic certificate by renaming it.

## Research and Existing Work

### Direct precedent: solid decomposition for two-piece rigid casting

**Alderighi, Malomo, Bickel, Cignoni, and Pietroni (2021), "Volume
Decomposition for Two-Piece Rigid Casting," ACM Transactions on Graphics
40(6), Article 272. DOI: [10.1145/3478513.3480555](https://doi.org/10.1145/3478513.3480555).**
Open-access copies: [project page](https://vcg.isti.cnr.it/publication/2021/AMBCP21/)
and [author PDF](https://openportal.isti.cnr.it/data/2021/456702/2021_456702.postprint.pdf).

This is the closest published match to the proposed feature. It:

- tetrahedralizes a closed solid;
- samples 512 candidate extraction directions;
- estimates double-height-field accessibility through the volume by testing 15
  points per tetrahedron (vertices, edge midpoints, face centers, and center);
- labels tetrahedra by compatible pull direction;
- solves a multi-label graph-cut objective combining accessibility, compactness,
  boundary/seam cost, and label count;
- converts the volumetric labels into solid parts;
- smooths and constrains internal interfaces so smoothing does not reintroduce
  undercuts;
- produces parts that can be cast separately and assembled by linear motion.

The paper is important for two reasons. First, it proves that the product idea
has a serious algorithmic basis. Second, it documents why a naive face-normal
test or semantic surface segmentation is not enough: the problem is volumetric,
global, and coupled to assembly.

The paper also sets realistic expectations. Its reported examples commonly take
minutes, use tens of thousands of tetrahedra, and can return multiple parts even
for visually simple models. It acknowledges that sampled accessibility is not
complete for every nested or highly occluded solid, that tessellation resolution
affects results, that zero-draft walls can still create friction, and that
splitting can reduce structural robustness.

The paper's continuous accessibility criterion is sufficient for the restricted
partition family it defines but incomplete: it can exclude valid DHF
partitions. Its implementation estimates that criterion at 15 points per
tetrahedron; that finite estimate is neither complete nor a formal proof. For
rare occluded internal interfaces, the paper may carve material and introduce
holes to recover accessibility. That fallback directly violates Refab Artist's
source-union contract. Refab Artist must refine the discretization, split again, or
fail; it may never carve or open the source silently.

### Direct interaction precedent: CoreCavity

**Nakashima, Auzinger, Iarussi, Zhang, Igarashi, and Bickel (2018),
"CoreCavity: Interactive Shell Decomposition for Fabrication with Two-Piece
Rigid Molds," ACM Transactions on Graphics 37(4), Article 135. DOI:
[10.1145/3197517.3201341](https://doi.org/10.1145/3197517.3201341).**
[Official open-access record](https://research-explorer.ista.ac.at/record/12).

CoreCavity decomposes a thin-shell equivalent of a freeform object into parts
that can each be formed in a two-piece rigid mold. It uses:

- a low-resolution, volume-aware coarse decomposition;
- candidate parting directions;
- overhang and global overlap energies;
- graph-cut parting-line classification;
- active-contour seam smoothing;
- user-authored no-cut, cut, merge, and selective-smoothing edits;
- high-resolution detail restoration;
- swept volumes to repair remaining moldability violations.

Its most useful product lesson is that seam placement is partly subjective.
Automatic manufacturing constraints should be hard, but a user must be able to
protect important details, move a seam, split a part, and merge parts while
seeing moldability update immediately.

Its limitations are equally important. The published method targets thin
shells, sometimes changes geometry to repair violations, and reported large
runtime differences between simple and dense inputs. Refab Artist must not silently
deform an imported model in this purpose. Source-preserving decomposition is a
locked requirement.

### One-sided alternative: approximate pyramidal decomposition

**Hu, Li, Zhang, and Cohen-Or (2014), "Approximate Pyramidal Shape
Decomposition," ACM Transactions on Graphics 33(6), Article 213. DOI:
[10.1145/2661229.2661244](https://doi.org/10.1145/2661229.2661244).**
[Author PDF](https://www.cs.sfu.ca/~haoz/pubs/hu_siga14_pym.pdf).

A pyramidal shape has a planar base and a remaining boundary that is a height
function over the base. Such a part is suitable for one-sided molding and often
support-free layered fabrication. The paper builds candidate parts from sampled
interior points, cells, and blocks, then uses Exact Cover to select a small
decomposition.

This is relevant but more restrictive than Refab Artist's default goal. It should
influence a future **Open-face molds** or **Support-free pieces** profile, not be
used as the definition of rigid two-piece moldability.

### Printer-volume partition precedent

**Luo, Baran, Rusinkiewicz, and Matusik (2012), "Chopper: Partitioning
Models into 3D-Printable Parts," ACM Transactions on Graphics 31(6), Article
129. DOI: [10.1145/2366145.2366148](https://doi.org/10.1145/2366145.2366148).**
[Project page and author PDF](https://gfx.cs.princeton.edu/pubs/Luo_2012_CPM/index.php).

Chopper is the conceptual ancestor of the existing Fit Printer purpose. Its
objective combines build-volume fit, few parts, connector feasibility,
assemblability, structural soundness, and unobtrusive seams. Those secondary
objectives remain valuable here, but moldability must be a hard constraint,
not another weighted preference.

For assembly-aware volume partitioning, Araújo et al., "Surface2Volume:
Surface Segmentation Conforming Assemblable Volumetric Partition," 2019, DOI:
[10.1145/3306346.3323004](https://doi.org/10.1145/3306346.3323004), is a useful
reference for separating a surface-driven proposal from a verified volumetric
and linearly assemblable result. Herholz, Matusik, and Alexa,
"Approximating Free-form Geometry with Height Fields for Manufacturing," 2015,
DOI: [10.1111/cgf.12556](https://doi.org/10.1111/cgf.12556), informs graph-cut
seam objectives but also illustrates why surface-only height-field segmentation
does not by itself establish a solid extraction or assembly path.

### Parting direction, parting lines, and small-undercut repair

- Fekete and Mitchell, "Terrain Decomposition and Layered Manufacturing,"
  2001, DOI:
  [10.1142/S0218195901000687](https://doi.org/10.1142/S0218195901000687),
  establishes hardness results for minimum terrain decomposition. Refab Artist
  should promise a low-part-count feasible result, not a global optimum.
- Ahn et al., "Separating an Object from Its Cast," 2002, DOI:
  [10.1016/S0010-4485(01)00119-1](https://doi.org/10.1016/S0010-4485(01)00119-1),
  gives necessary and sufficient castability tests for a fixed direction on a
  polyhedron. It is a stronger starting point for an independent final verifier
  than a sampled face-normal heuristic.
- McMains and Chen, "Finding Undercut-Free Parting Directions for Polygons
  with Curved Edges," 2006, DOI:
  [10.1115/1.2164450](https://doi.org/10.1115/1.2164450), formalizes two-part
  moldability in terms of opposing removal directions and monotonicity.
- Khardekar, Burton, and McMains, "Finding Feasible Mold Parting Directions
  Using Graphics Hardware," 2006, DOI:
  [10.1016/j.cad.2006.01.008](https://doi.org/10.1016/j.cad.2006.01.008),
  is a useful precedent for fast interactive direction previews while a more
  conservative verifier runs separately.
- Li, Martin, and Langbein, "Molds for Meshes: Computing Smooth Parting Lines
  and Undercut Removal," 2009, DOI:
  [10.1109/TASE.2009.2021324](https://doi.org/10.1109/TASE.2009.2021324),
  computes smooth parting lines for complex triangle meshes and discusses
  minor-undercut removal.
- Bassi, Bedi, and Salas, "Undercut Free Parting Direction Determination for
  Injection Molded Parts Using Surface Based Accessibility Analysis," 2010,
  DOI: [10.3722/cadaps.2010.621-637](https://doi.org/10.3722/cadaps.2010.621-637),
  evaluates candidate directions using swept accessibility.
- Alderighi et al., "State of the Art in Computational Mould Design," 2022,
  DOI: [10.1111/cgf.14581](https://doi.org/10.1111/cgf.14581), provides the
  broadest recent map of geometric mold-design approaches.

### Commercial and adjacent tools

Current CAD and mold packages commonly analyze draft, identify undercuts, and
suggest sliders or core/cavity assignments. Examples include:

- [SOLIDWORKS Undercut Analysis](https://help.solidworks.com/2026/English/SolidWorks/sldworks/c_mold_tools_undercut_analysis.htm);
- [PTC Creo Mold Design face splitting and classification](https://support.ptc.com/help/creo/ced_modeling/r20.8.0.0/en/ced_modeling/OSDM_Modules/MoldDesign_Split.html);
- [Siemens NX Mold Design](https://www.siemens.com/en-us/products/nx-manufacturing/tooling-fixture-design/mold-design/).

More automated mold-oriented comparators include
[Plyable](https://www.plyable.com/automated-mold-design/),
[ActionBOX](https://mold.actionbox.ca/how-it-works), and
[Moldboxer](https://moldboxer.com/). They are important workflow references for
visibility, parting, and mold output, but the surveyed public descriptions do
not establish the same product contract: automatically split the **object**
into a small set of reassemblable DHF solids and issue a per-piece certificate.
[Metamolds](https://ista.ac.at/en/news/metamolds-molding-a-mold/) is a research
alternative that keeps the object intact and introduces cuts into a flexible
mold; that is deliberately a different branch of the design space.

Those tools primarily analyze or decompose tooling while preserving the object
as one part. They are not direct substitutes for automatic object
decomposition.

Semantic tools such as
[Meshy Auto Split](https://www.meshy.ai/tutorials/auto-split-3d-model-into-parts)
and [Tripo model segmentation](https://www.tripo3d.ai/features/ai-model-segmentation)
are references for visually natural boundaries, not manufacturing validators.
Manual fabrication splitters such as
[PrusaSlicer Cut](https://help.prusa3d.com/article/cut-tool_1779) and
[Materialise Magics Section Cut](https://www.materialise.com/en/academy/industrial/magics/video-tutorials/section-cut-function)
are references for plane cuts and joinery. None of these public product pages
publishes a hard rigid two-piece-mold release guarantee for every output
object piece.

### Research conclusion

The surveyed work shows a capability gap between:

- undercut/draft analysis;
- automatic mold generation for an already-moldable object;
- semantic or printer-size splitting; and
- automatic, editable, proven decomposition of the object into moldable parts.

Refab Artist can test that opportunity if it treats manufacturing validity as a hard
certificate and aesthetic seam placement as an optimization and editing
problem.

## Patent and Licensing Gate

The CoreCavity work is associated with specific granted patents currently
reported active, including
[US 11,931,922 B2](https://patents.google.com/patent/US11931922B2/en) and
[EP 3,810,389 B1](https://patents.google.com/patent/EP3810389B1/en). As a
high-level reading only, US claim 1 combines computational mold design with a
manufacturing method and dependent claim 5 adds splitting into sub-objects; EP
claim 1 requires a feasible mold design as output and dependent claim 5 adds
splitting. Part-only export omits important stated elements, but that is not a
freedom-to-operate conclusion.

A separate granted European patent currently reported active,
[EP 4,415,945 B1](https://patents.google.com/patent/EP4415945B1/en), describes
visibility-based selection of candidate mold pieces, parting-line construction,
and generation of mold CAD shells; it does not simply claim volumetric object
partition in isolation. It is another reason to scope the review to the actual
product workflow rather than only one academic paper.

This document makes no infringement or validity conclusion. It establishes a
release gate:

1. Before shipping even the planar v1 workflow, obtain a qualified
   freedom-to-operate review. Expand it before any CoreCavity-like freeform
   solver or automatic mold output.
2. Keep the first Split for Two-Piece Molds release scoped to decomposition, validation,
   and part export. Do not add automatic mold generation through this feature.
3. Implement from a specification written for Refab Artist and independently written
   code. A paper is not a source-code license.
4. Record the license and patent review for every new geometry dependency.

Patent status and scope must be confirmed in official registers and by counsel.
The planar, scoped-cut solver described below is a product and engineering
recommendation, not a legal workaround. Counsel must evaluate the actual
implementation and distribution.

## Product Definition

### One-line summary

Add a **Split for Two-Piece Molds** purpose to Partition that automatically or manually
splits a watertight model into source-faithful pieces, assigns each piece a
rigid two-piece-mold axis, certifies each final piece as a double height field
for ideal opposite linear pulls, and exports only verified pieces with an
object-assembly map and machine-readable moldability report.

### Primary user story

The v1 persona is a **product hypothesis**, not an established market fact: a
resin sculpture or model-kit maker who specifically uses or wants reusable
rigid two-piece molds, accepts a glued multi-piece final object, and wants each
digital master piece prepared for a separate mold design. M0 must validate or
reject this hypothesis with people in that exact workflow; generic resin
printing or flexible-silicone users do not count as confirming evidence.

> As a model maker with an object that cannot be released from a simple rigid
> mold, I want Refab Artist to divide the object at sensible seams so I can design
> and fabricate one simple mold per object piece, cast the pieces, and reassemble
> them without manually discovering hidden undercuts.

Injection molding, plaster slip casting, flexible silicone production, and
industrial tooling have different flow, draft, core, and material constraints.
They may use the geometry report as analysis, but v1 is not a complete process
solution for those personas.

### Secondary user stories

- I want to know whether the entire object is already moldable before it is cut.
- I want to lock a preferred pull axis for the whole object or for one piece.
- I want seams to avoid faces, engraved detail, and thin features.
- I want to mark regions where cuts are forbidden or preferred.
- I want the smallest practical number of parts, not a cloud of tiny valid
  fragments.
- I want to inspect exactly which geometry failed and why.
- I want edits to revalidate only the affected subtree.
- I want an assembly order and stable piece names.

### Downstream v1 workflow

1. Generate and certify the object-piece decomposition.
2. Export the object pieces and report as one ZIP transaction.
3. Design a separate mold for each object piece, either in another tool or by
   importing the piece into a new MotherMold project when it lies inside
   MotherMold's supported envelope.
4. Preserve the certified pull axis during mold design. A mold generated on a
   different axis does not inherit this certificate.
5. Cast and assemble the object pieces using the reported object-assembly
   sequence.

There is no one-click batch handoff in v1. A later integration milestone may
add **Create MotherMold projects for certified pieces**, including exact pull
axes and source hashes, but only after MotherMold can accept and honor those
inputs explicitly.

### Goals

- Return zero cuts whenever a searched or user-specified direction is strictly
  certified for the original object. Finite automatic direction search does not
  prove that an unsearched valid axis is absent.
- Meet fixture-specific maximum piece counts recorded in the accepted M0
  expectation manifest; do not use "low part count" without that bound.
- Preserve the source surface exactly within the project's geometry tolerance.
- Make every automated decision inspectable and manually correctable.
- Never label a sampled heuristic result as proven.
- Reuse the existing Partition and MotherMold foundations instead of creating a
  second unrelated geometry stack.
- Keep output deterministic and project-reproducible.

### Non-goals for the first release

- Generating the rigid molds, runners, gates, vents, ejector pins, or cooling
  channels.
- Simulating resin flow, shrinkage, pressure, heat, cure, or material strain.
- Designing sliders, side actions, sacrificial cores, flexible molds, or lost
  molds.
- Modifying, smoothing, inflating, or deforming the source surface to make it
  moldable.
- Guaranteeing injection-molding production readiness.
- Guaranteeing sufficient physical draft when the source has zero-draft walls.
- Support-free FDM optimization.
- Semantic AI as a source of truth.
- Freeform internal seams in the first shippable solver.
- Claiming a globally minimum number of parts.

## Geometric Contract

### Coordinate and scale convention

- All manufacturing values are millimeters after Refab Artist's existing import
  scale and unit normalization.
- Pull directions are normalized model-space vectors.
- A plane is represented by `dot(point, normal) == offset`. Add a shared
  `CanonicalPlane` utility by extracting and testing the currently private
  MotherMold sign logic; current Partition normalizes magnitude but does not
  sign-canonicalize.
- All persisted and reported directions are stored in model space. Exported
  reorientation is an output transform and must not mutate the certificate.

### Double-height-field criterion

For a solid piece `P`, unit direction `d`, and every point `x` in the plane
perpendicular to `d`, define
`I(x) = { t | x + t*d is in interior(P) }`. `P` is a double height field along
`d` when every `I(x)` is empty or one connected interval. Boundary-only
tangencies and coincident projected features are handled by the numerical
predicate policy, not hidden behind an "almost every" exception. The boundary
can then be assigned to two opposing height fields, one associated with `d` and
the other with `-d`.

For a triangle mesh, Refab Artist evaluates this through a combination of:

1. line/column interval tests;
2. upper/lower surface classification;
3. local face-normal and requested-draft tests;
4. a conservative, complete fixed-direction DHF test on the final polyhedral
   geometry.

The sampled tests accelerate search; only item 4 can issue a certificate.

A DHF certificate proves geometric compatibility with **ideal** opposing
height-field tooling and linear pulls along `+d` and `-d`. This feature does not
construct a particular finite mold body, parting apron, clamp system, or outer
envelope, so it does not claim that an unspecified physical mold has passed a
collision simulation. Any later mold generated by MotherMold or another tool
must be validated as its own artifact.

### What "verified" means

A final piece is **DHF-certified for ideal rigid two-piece pulls** only when all
of these are true:

1. The final mesh is closed, consistently oriented, finite, and watertight.
2. It has no self-intersections above tolerance.
3. A specific pull axis `d` is stored.
4. A conservative fixed-direction DHF test over the complete triangle mesh
   shows no disallowed multi-interval region. A denser finite ray sample is not
   sufficient for this gate.
5. The boundary can be divided into connected upper and lower mold-contact
   patches, allowing multiple parting loops for holes where valid.
6. Signed draft is computed separately for the upper and lower patches,
   excluding only the true parting band. Authored seam caps are real
   mold-contact faces and remain in draft analysis. Any negative value is
   consistent with a DHF failure, while low positive draft is advisory in v1.
7. Every multi-piece result has a mandatory collision-free object-piece
   disassembly/assembly sequence. Mold pull axes and object assembly motions are
   separate facts.
8. The same checks pass after all assembly locators or seam features are added.

The certificate binds to the canonical assembled-coordinate piece mesh hash,
canonical cut-tree hash, `RigidMoldGenerationInputHash`, ordered assembly-plan
hash, and verifier version. File serialization and rigid layout transforms have
separate artifact hashes. Editing or regenerating any bound geometry, cut, or
motion invalidates the certificate.

The verifier has three outcomes and never collapses an internal error into a
pass:

- **Strictly verified:** the complete verifier finds no open multi-interval
  region. If numerical classification is ambiguous, the outcome is
  Indeterminate rather than Verified;
- **Failed:** at least one hard geometry, release, topology, or assembly gate
  failed;
- **Indeterminate/error:** the complete test could not be constructed or
  completed. This is export-blocking and must name the failed verifier stage.

### Draft and undercut are reported separately

- **Geometric undercut:** a hard collision or multi-interval violation.
- **Negative draft:** after upper/lower ownership is assigned, a face slopes
  against its half's release direction.
- **Zero/low draft:** mathematically releasable but likely to bind because of
  friction, surface texture, shrinkage, or process variation.

With outward face normal `n`, axis `d`, and side sign `s = +1` for the `+d`
patch and `s = -1` for the `-d` patch, the signed draft is
`asin(clamp(s * dot(n, d), -1, 1))`. Faces in a versioned parting band are
excluded because a smooth parting locus necessarily tends toward zero draft.

The first release has no user-authorized residual-undercut mode. Numerical
tolerances are internal robustness thresholds, not permission to accept a
physical undercut. Refab Artist reports negative draft through the DHF failure and
warns about low positive draft. The positive draft threshold is advisory-only
in v1 because Refab Artist does not alter the source to add draft.

### Source fidelity

- Before joinery, the union of all pieces must reproduce the source solid. The
  hard test is
  `volume((union(pieces)) symmetricDifference source) <= volumeTolerance`;
  missing-source volume and overlap volume are reported separately.
- Cut caps and optional joinery are the only newly authored surfaces.
- Source exterior vertices may be welded within tolerance but not smoothed or
  displaced.
- The pre-joinery sum of piece volumes must match the source volume within the
  documented relative and absolute tolerance.
- Pairwise piece interiors must not overlap in assembled position.
- After joinery, conservation is checked against the authored delta:
  `expectedFinalVolume = sourceVolume + maleBossVolume - femalePocketVolume`.
  Any other loss or gain, pairwise overlap, or source-exterior change is a hard
  failure.

## User Experience

### Entry point

The top of the Partition inspector gains a **Purpose** control:

- **Fit Printer**
- **Split for Two-Piece Molds**

The current `PartitionMode` remains the Fit Printer interaction choice
(`autoFit` or `manual`) and must not be overloaded to mean purpose. Internally,
add a separate `PartitionPurpose` plus a purpose-specific
`MoldablePlanningMode`; this preserves each purpose's Auto/Manual selection when
the user switches between them.

### First-run flow

1. Import an STL or OBJ.
2. Choose **Partition**.
3. Set Purpose to **Split for Two-Piece Molds**.
4. Refab Artist explains: "Creates object pieces for rigid two-piece molds. It
   does not generate the molds."
5. Leave Release Direction on **Automatic** and Max Pieces on 8; Advanced uses
   **Standard** search quality by default.
6. Press **Analyze & partition**.
7. See one of four outcomes:
   - **Already verified for rigid two-piece release:** one verified object
     piece, no seams.
   - **Verified decomposition:** all pieces green, with pull arrows and an
     assembly order.
   - **No verified planar solution:** best attempt remains inspectable, failed
     regions are red, export is blocked, and the UI offers focused recovery
     actions.
   - **Verification error:** the candidate could not be classified because a
     numerical predicate, topology check, or proof stage was indeterminate.
     Export is blocked, the failing stage is named, and this is not presented
     as either geometric infeasibility or a search miss.

### Inspector structure

The default inspector stays small. It exposes only:

1. **Process** - an informational **Rigid two-piece mold** row and the boundary
   of what Refab Artist certifies.
2. **Release direction** - Automatic or Fixed, with the direction ring only
   when Fixed is selected.
3. **Decomposition** - Max pieces and priority: Fewer pieces / Balanced /
   Cleaner seams.
4. **Verification** - one plain-language status, verified piece count, worst
   blocker, and a disclosure for per-piece certificates.
5. **Output** - STL pieces or named-object OBJ, both packaged with the required
   report and object-assembly guide.

The existing outer construction action becomes **Analyze & partition**. Do not
add a second Generate button inside the subpanel. While running, the action area
shows phase, cancel, elapsed time, and evaluated-candidate count. Progress must
not imply a guaranteed completion percentage when the frontier is open-ended.

An **Advanced** disclosure contains Search quality, draft advisory, minimum
piece volume, minimum seam area, symmetry preference, detail avoidance, and
seed. The tolerance policy is read-only diagnostic information.

After a result exists, contextual editing exposes the scoped cut tree,
lock/unlock, per-piece pull locks, add/delete/merge, no-cut paint, preferred-
seam paint, piece isolation, and Explode. Locking a generated cut or generated
piece pull is an authored edit: Refab Artist first performs **Adopt generated
cuts**, switches to Manual, and applies the lock atomically. Face paint is the
exception because it is a source-face constraint and may remain an Automatic
planning input. These controls do not occupy the first-run inspector.
Public **Assembly locators** remain None-only through M6; no disabled Tapered
picker appears before both the engine and M7 physical gate exist. Internal
post-M6 builds may expose it only for validation.

Printer fit is deliberately not a simultaneous hard constraint in v1. A future
**Prepare master pieces for printing** follow-on may feed certified object
pieces into Fit Printer while preserving their certificates and source hashes.

### Viewport requirements

- Source shown semi-transparent when exploded.
- Each piece has a stable color.
- Pull arrow for each piece.
- Scoped cut surfaces, not only point handles.
- Red heatmap or markers for measured failing regions.
- Amber for low-draft but geometrically releasable regions.
- Green verification outline only after the final proof.
- Selected piece can be isolated.
- Explode moves pieces along a collision-free assembly/disassembly direction
  without mutating export transforms.
- A **Show release envelopes** diagnostic may render the certified upper and
  lower height-field contact sheets; these are mathematical inspection data,
  not generated mold bodies.

### Honest status language

Allowed success wording:

- "One object piece is verified for ideal rigid two-piece pulls along Z."
- "6 of 6 object pieces are verified for ideal rigid two-piece pulls."
- "Verified after assembly locators were applied." This wording becomes
  available only after the locator engine and M7 physical gate pass.

The technical-details disclosure and JSON report may additionally name the
mathematical contract as **double height field (DHF)**. The primary status and
recovery UI must use the plain-language wording above.

Required failure wording:

- "No verified planar decomposition was found within 8 object pieces. Two
  undercut regions remain on Object Piece C. Increase Max Pieces, unlock +Z, or
  add a cut to Object Piece C."
- "The proposed assembly locator locks Object Piece B. Remove it or change its
  orientation."
- "The source contains an enclosed component with no linear escape path. This
  solver cannot certify it."

Forbidden wording:

- "Moldable" based only on face normals.
- "No undercuts" when only a sampled proxy passed.
- "Optimal" unless a finite exhaustive search actually proves optimality.
- "Injection-molding ready."

## Parameter Inventory

### User-facing parameters

| Parameter | Type / range | Default | Behavior and interactions |
|---|---|---|---|
| Purpose | Fit Printer / Split for Two-Piece Molds | Existing projects decode to Fit Printer | Selects the objective and inspector; does not replace Auto/Manual |
| Process | Rigid two-piece mold | Rigid two-piece mold | Locked in v1; future profiles require separate contracts |
| Planning | Automatic / Manual | Automatic | Automatic creates and may refine a scoped cut tree; Manual edits it |
| Pull policy | Automatic / Fixed / Per-piece locks | Automatic | Fixed uses one undirected axis pair for all leaves; creating a per-piece lock from a generated result first adopts the tree and switches to Manual |
| Fixed pull axis | unit vector | +Z when Fixed is first selected | Edited numerically or with direction ring; `d` and `-d` represent the same mold axis but preserve chosen upper/lower labeling |
| Search quality | Quick / Standard / Thorough | Standard | Maps to deterministic direction, plane, beam, and refinement budgets; never to a wall-clock cutoff |
| Max pieces | integer 1...32 | 8 | Stored as `maxParts`; hard search limit; lowering below current leaves marks plan stale |
| Verification tolerance | read-only policy and version | Project policy | Opens an explanation of separate linear, angular, area, and volume tolerances; it is not one broad user knob |
| Draft advisory | 0...10 degrees | 1 degree | Evaluated as signed draft on each upper/lower patch; the versioned parting band is excluded. It produces warnings but is not a v1 hard gate |
| Pieces vs seam quality | three-state priority | Balanced | Changes lexicographic tie-breaking, not moldability validity |
| Minimum piece volume | 0...10% of source plus optional mm3 floor | 0.5%, floor 1 mm3 | Rejects slivers; cannot exceed a value that makes current locked cuts infeasible without warning |
| Minimum seam area | 0...source projected area | Derived from joint footprint, otherwise 4 mm2 | Prevents fragile or unjoinable seams |
| Avoid fine detail | Off / Medium / Strong | Medium | Adds seam cost from curvature, saliency, and small features; never overrides validity |
| Preserve symmetry | Boolean | On when robust symmetry is detected | Adds paired candidate cuts and a symmetry deviation cost; may increase part count |
| No-cut paint | per-face weights 0 or prohibited | None | Hard constraint unless it makes all solutions infeasible; then report the conflict, never ignore it |
| Preferred-seam paint | per-face weight 0...1 | None | Soft cost only |
| Assembly locators | None; Tapered alignment after engine + M7 physical gate | None | The first UI shows None as an informational row. The picker appears only after the new rigid-mold joinery engine and the validated process envelope exist |
| Locator clearance | 0...2 mm | Process-calibrated future default | Hidden until Tapered alignment ships; clearance direction and measurement are explicit |
| Locators per seam | 1...8 | 2 | Hidden until Tapered alignment ships; candidate placement respects seam area and final pull and assembly directions |
| Output format | Separate STL ZIP / Named-object OBJ ZIP | Separate STL ZIP | Both are one atomic package with report and guide |
| Include source mesh for full audit | Boolean | Off | Adds a canonical source OBJ so a third party can recompute source fidelity; warns that it republishes the source model and increases package size |
| Seed | signed 64-bit integer | stable project default | Affects deterministic tie-breaking and candidate ordering only |

### Search-quality budgets

The exact values are implementation constants, benchmarked in M0 and then
locked for reproducibility. The initial proposal is:

| Quality | Direction samples | Candidate planes per expanded leaf | Beam width | Refinement passes | Exact finalists |
|---|---:|---:|---:|---:|---:|
| Quick | 42 plus geometry-derived axes | 24 | 8 | 1 | 3 |
| Standard | 162 plus geometry-derived axes | 64 | 24 | 3 | 8 |
| Thorough | 642 plus geometry-derived axes | 160 | 64 | 6 | 24 |

These counts are provisional until fixture benchmarks show their recall. The
persisted setting is the quality enum, not the raw counts. Changing constants in
a future version requires a planner-version bump so reopened projects can
explain why regeneration differs.

### Internal tolerance policy

`GeometryTolerancePolicy` is versioned, reported, and derived from
model scale and robust-predicate requirements. It is not a
single editable millimeter value. At minimum it defines separate:

- linear endpoint/weld tolerance in mm;
- ray-hit coincidence tolerance in mm;
- angular classification tolerance in radians;
- degenerate-triangle and minimum-area tolerance in mm2;
- absolute volume tolerance in mm3;
- relative volume tolerance as a dimensionless fraction;
- self-intersection contact tolerance in mm;
- pairwise overlap/collision-volume tolerance in mm3.

Changing the policy or any field invalidates cached analyses and certificates.
None of these thresholds authorizes a physical undercut or models flexible
material compliance.

Self-intersection means any intersection between non-adjacent triangles with a
segment or positive-area coplanar overlap beyond the policy thresholds.
Topologically adjacent triangles may share only their declared edge or vertex.
Source-exterior fidelity uses provenance plus symmetric Hausdorff distance on
the preserved exterior; generated caps and locators are evaluated separately.

### Derived metrics

- unresolved undercut area in mm2;
- maximum and p95 undercut depth in mm;
- count and area of multi-interval columns;
- minimum, p05, and median draft in degrees;
- seam surface area and visible seam length;
- minimum piece volume and advisory proxy thickness;
- piece-count balance and volume variance;
- number of unique pull axes;
- pairwise overlap volume;
- volume-conservation error;
- assembly collision count and minimum clearance;
- final certificate status and reason code.

`maximum undercut depth` is a proxy diagnostic, not a compliance allowance. For
a sampled violating ray it is the minimum axial translation along the assigned
half's pull direction from the implicated boundary hit to clear the next
occluding source interval; the reported maximum is taken over those samples.
The complete verifier decides strict status independently of this sampled
number.

## Persisted Data Model

The exact Swift syntax may change, but these concepts are required:

```swift
enum PartitionPurpose: String, Codable {
    case fitPrinter
    case rigidTwoPieceMoldParts
}

struct PartitionSettings: Codable, Equatable {
    // Existing fields remain for backward compatibility.
    var purpose: PartitionPurpose
    var mode: PartitionMode
    var printerPreset: PartitionPrinterPreset
    var buildVolume: PrinterVolume
    var bedMargin: Double
    var autoStrategy: PartitionAutoStrategy
    var manualPlanes: [PartitionPlane]
    var key: PartitionKeySettings
    var packaging: PartitionPackaging
    var includeAssemblyMap: Bool
    var naming: PartitionNaming
    var explodePreview: Double

    // New optional nested contract. View state uses `.defaultValue` when nil.
    var moldable: MoldablePartitionSettings?
}

struct MoldablePartitionSettings: Codable, Equatable {
    var process: MoldabilityProcess
    var planningMode: MoldablePlanningMode
    var pullPolicy: PullDirectionPolicy
    var fixedPullDirection: Vec3?
    var quality: MoldableSearchQuality
    var maxParts: Int
    var tolerancePolicyVersion: Int
    var draftAdvisoryDegrees: Double
    var priority: MoldablePartitionPriority
    var minimumPieceVolumeFraction: Double
    var minimumPieceVolumeMM3: Double
    var minimumSeamAreaMM2: Double
    var detailAvoidance: DetailAvoidance
    var preserveSymmetry: Bool
    var joinery: MoldableJoinerySettings
    var packaging: MoldablePackaging
    var includeCanonicalSourceAuditMesh: Bool
    var seed: Int64
    // Automatic-mode output selection, not a search input. Nil means that no
    // completed generation has persisted a current alternative yet.
    var selectedAutomaticAlternativeTreeHash: String?
    // Raw structured payload is retained so an invalid authored tree can be
    // quarantined without making the rest of the project undecodable.
    // Automatic planner output lives on PartitionPlan, not in settings.
    var authoredCutTree: PersistedPartitionCutTreeEnvelope?
    var faceConstraints: PartitionFaceConstraints
    var lockedPullDirections: [PartitionRegionID: Vec3]
    var plannerVersion: Int
}

enum MoldabilityProcess: String, Codable {
    case rigidTwoPiece
}

enum MoldablePlanningMode: String, Codable {
    case automatic
    case manual
}

struct MoldableJoinerySettings: Codable, Equatable {
    var type: MoldableJoineryType
    var clearanceMM: Double
    var locatorsPerSeam: Int
}

enum MoldableJoineryType: String, Codable {
    case none
    case taperedAlignment // decoded but public-unavailable until the M7 gate
}

enum MoldablePackaging: String, Codable {
    case separateSTLZip
    case namedOBJZip
}

enum PullDirectionPolicy: String, Codable {
    case automatic
    case fixed
    case perPieceLocks
}

struct PartitionCutTree: Codable, Equatable {
    var rootRegionID: PartitionRegionID
    var nodes: [PartitionCutNode]
}

struct PersistedPartitionCutTreeEnvelope: Codable, Equatable {
    var schemaVersion: Int
    var sourceGeometryFingerprint: String
    var rawTree: JSONValue
}

enum AuthoredCutTreeLoadState: Equatable {
    case none
    case usable(PartitionCutTree)
    case quarantined(rawPayload: JSONValue, diagnostics: [String])
}

struct PartitionCutNode: Codable, Equatable, Identifiable {
    var id: PartitionCutNodeID
    var targetRegionID: PartitionRegionID
    var plane: CanonicalPartitionPlane
    var negativeChildID: PartitionRegionID
    var positiveChildID: PartitionRegionID
    var source: ScopedCutSource
    var isLocked: Bool
}
```

### Migration

- Projects without `purpose` decode as `.fitPrinter`.
- Existing `PartitionSettings.mode` remains the Fit Printer planning mode.
  Split for Two-Piece Molds stores its own `moldable.planningMode`, defaulting to
  `.automatic`.
- Existing `manualPlanes: [PartitionPlane]` remains authoritative for Fit
  Printer Manual mode.
- Existing `PartitionSettings.key` remains the Fit Printer joint configuration.
  Split for Two-Piece Molds stores separate `moldable.joinery`, defaulting to None, so
  switching purposes never destroys or silently changes the user's printer-fit
  keys.
- Existing `PartitionSettings.packaging` and `includeAssemblyMap` remain Fit
  Printer output settings. Rigid-mold output uses its nested atomic ZIP
  packaging; the object-assembly guide is mandatory and has no omit toggle.
- `includeCanonicalSourceAuditMesh` defaults to false for new and migrated
  projects; it is a packaging-only audit option, not a geometry input.
- `selectedAutomaticAlternativeTreeHash` defaults to nil. On the first
  successful generation, Refab Artist selects the priority profile's default and
  immediately persists that result's canonical hash as output-selection state.
  It restores the current alternative after save/open without converting it
  into an authored Manual recipe. If deterministic regeneration under the same
  planner version does not produce a persisted hash, the project reports the
  missing selection and remains stale rather than silently selecting and
  exporting another result.
- Missing `moldable` decodes as nil and the UI supplies
  `MoldablePartitionSettings.defaultValue`; no existing coding key is renamed.
- Split for Two-Piece Molds uses a scoped cut tree. A legacy global plane list can be
  imported by replaying planes over the root and recording every actual split,
  but the conversion is one-way and must be explicit.
- Cached plans and certificates are not trusted after application or planner
  version changes. Settings reopen; geometry regenerates.
- New ordinary fields decode with defaults through `decodeIfPresent`, following
  the existing project migration pattern. The authored cut-tree envelope uses
  a custom decoder: it captures `rawTree` as `JSONValue` before attempting a
  typed `PartitionCutTree` decode, so a tree-schema failure cannot fail the
  surrounding `PartitionSettings` decode.

### Deterministic identity and cut-tree validity

- Automatic node IDs are stable hashes of planner version, canonical parent
  region ID, sign-canonical plane coefficients, and deterministic sibling
  ordinal.
- Child region IDs are stable hashes of node ID plus `negative` or `positive`.
- Manual node IDs are created once, persisted in the authored tree, and never
  regenerated from wall-clock time. Report-only region IDs are derived from
  piece ID and sorted face provenance, not random UUIDs.
- Plane canonicalization chooses the sign whose first nonzero normal component
  in X/Y/Z order is positive. Reversing a plane swaps negative/positive child
  roles, seam-side ownership, and any male/female assignment before hashing.
- Nodes serialize in parent-before-child topological order with deterministic
  sibling order.
- `cutTreeHash` is content-addressed from the cut-tree schema version, matching
  source fingerprint, canonical root/region IDs, ordered canonical node
  records, leaf set, and physical seam adjacency. UI labels, colors, selection,
  and Explode are excluded.

Cut-tree loading has two explicit validation phases:

1. **Phase A - structural, source-independent.** After typed decode, reject a
   wrong root, cycle, orphan, duplicate node or child ID, multiple parents,
   parent-after-child order, non-finite/noncanonical plane, and structurally
   impossible region reference. A decode or Phase A failure produces
   `quarantined(rawPayload:diagnostics:)`; it does not discard the raw payload
   and it does not prevent the rest of the project from opening.
2. **Phase B - source-bound replay.** Only after the effective source geometry
   is loaded, require a matching source fingerprint, replay every plane against
   its recorded parent, require exactly two valid children per cut, enforce Max
   Pieces, and validate every face constraint and pull lock against the replayed
   regions. A Phase B failure also retains the authored payload for repair or
   explicit removal; it never silently falls back to a different tree.

While either phase is quarantined or Phase B is unresolved, the rigid-mold Plan
is unavailable, the inspector names the diagnostic, and export is blocked. A
user may remove the quarantined recipe, attempt a versioned migration, or keep
it for a newer Refab Artist; merely reopening the project never drops bad nodes
and proceeds as if they were valid.

Automatic planning writes the resulting cut tree to `PartitionPlan`, not back
into settings. Therefore Generate does not change its own input signature. The
explicit **Adopt generated cuts** action canonically encodes the current plan
tree and source fingerprint into `moldable.authoredCutTree`, switches to Manual,
and atomically marks the current plan stale. Manual edits mutate only the
authored tree. Attempting to lock a
generated node or a generated region's pull performs that same adoption and
mode switch in the same undoable transaction; there is no separate
"automatic-but-with-locked-generated-cuts" recipe. Automatic regeneration may
use source-face constraints and the global Fixed pull setting, but it never
uses a prior generated tree or generated-region pull lock as an implicit input.

## Intermediate Data Structures

```swift
struct DirectionalSampleSet {
    var meshFingerprint: String
    var directions: [Vec3]
    var perDirection: [DirectionalAccessibilityField]
}

struct DirectionalAccessibilityField {
    var direction: Vec3
    var columnsTested: Int
    var violatingColumns: [DirectionalColumnViolation]
    var undercutRegions: [DirectionalUndercutRegion]
    var minimumDraftDegrees: Double
    var proxyScore: Double
}

struct DirectionalUndercutRegion {
    var id: DirectionalUndercutRegionID // deterministic content-derived ID
    var faceIDs: [Int]
    var areaMM2: Double
    var maximumDepthMM: Double
    var centroid: Vec3
    var preferredEscapeDirections: [Vec3]
}

struct PartitionSearchState {
    var cutTree: PartitionCutTree
    var leaves: [PartitionLeaf]
    var objective: MoldableObjectiveFacts
    var historyHash: UInt64
}

struct PartitionLeaf {
    var regionID: PartitionRegionID
    var mesh: MeshGeometryData
    var sourceFaceMap: SourceFaceMap
    var candidateDirections: [PullDirectionEvaluation]
    var selectedDirection: Vec3?
    var proxyStatus: ProxyMoldabilityStatus
}

struct MoldableObjectiveFacts {
    // Compared by a profile-specific lexicographic ordering below; do not
    // collapse hard validity into a weighted scalar.
    var hardConstraintViolations: Int
    var unresolvedMaximumDepthMM: Double
    var unresolvedAreaMM2: Double
    var partCount: Int
    var sliverPenalty: Double
    var seamDetailPenalty: Double
    var seamAreaMM2: Double
    var uniquePullAxisCount: Int
    var pieceVolumeVariance: Double
    var deterministicTieBreak: UInt64
}

struct MoldabilityCertificate: Codable, Equatable {
    var pieceID: PartitionRegionID
    var pieceMeshHash: String
    var rigidMoldGenerationInputHash: String
    var cutTreeHash: String
    var assemblyPlanHash: String
    var pullDirection: Vec3
    var partingLoops: [[Vec3]]
    var upperPatchFaceIDs: [Int]
    var lowerPatchFaceIDs: [Int]
    var proxyColumnsTested: Int
    var proxyMultiIntervalColumnCount: Int
    var proxyMaximumUndercutDepthMM: Double
    var upperMinimumSignedDraftDegrees: Double
    var lowerMinimumSignedDraftDegrees: Double
    var proofMethodID: String
    var predicatePolicyVersion: Int
    var tolerancePolicyVersion: Int
    var dhfProofDigest: String
    // A leaf may move as part of several ancestor subassemblies.
    var assemblyMotionEventIDs: [AssemblyMotionEventID]
    var outcome: CertificateOutcome // verified | failed | indeterminate
    var reasonCodes: [MoldabilityReasonCode]
    var verifierVersion: Int
}

struct AssemblyMotionEvent: Codable, Equatable, Identifiable {
    var id: AssemblyMotionEventID
    var originatingCutNodeID: PartitionCutNodeID
    var activeSubassemblyRegionIDs: [PartitionRegionID]
    var movingRegionIDs: [PartitionRegionID]
    // Exact complement of movingRegionIDs inside the active subassembly.
    var stationaryRegionIDs: [PartitionRegionID]
    var translationDirection: Vec3
    var translationDistanceMM: Double
    // The proven path is T(t) = direction * distance * t, t in [0, 1].
    var continuousCollisionProofDigest: String
}

struct PartitionAssemblyPlan: Codable, Equatable {
    // Deterministic top-down disassembly order. Assembly is the exact reverse.
    var disassemblyEvents: [AssemblyMotionEvent]
    var assemblyPlanHash: String
}
```

`PartitionPlan` owns one `PartitionAssemblyPlan`; a per-piece certificate only
references the events in which that leaf participates. A single step number or
single translation vector on each leaf is insufficient because a leaf can
first move inside an ancestor group and later move again when that group is
opened.

Every `AssemblyMotionEventID` is content-addressed from a versioned canonical
encoding of the originating cut, ordered active/moving/stationary region sets,
normalized direction, distance, collision-proof method/version, and proof
digest. `assemblyPlanHash` is a Merkle-style root over the canonical cut-tree
hash and the **ordered** event IDs; the empty one-piece plan has a defined root.
Certificates carry both that root and their participating event IDs. Reordering
events, changing a distance, or replacing a proof therefore invalidates every
affected certificate even when piece meshes remain byte-identical.

The three priority profiles compare the same facts in explicit order after
hard constraints and unresolved DHF depth/area:

| Profile | Remaining lexicographic order |
|---|---|
| Fewer pieces | part count, sliver penalty, seam-detail penalty, seam area, unique pull axes, volume variance, deterministic tie-break |
| Balanced | sliver penalty, part count, seam-detail penalty, volume variance, seam area, unique pull axes, deterministic tie-break |
| Cleaner seams | seam-detail penalty, seam area, sliver penalty, part count, volume variance, unique pull axes, deterministic tie-break |

An alternative is distinct only when its canonical cut-tree hash differs. If
multiple profile labels select the same tree, show it once. Tests supply states
whose order differs under each profile and assert the exact selected hash.

`SourceFaceMap` is required. Without it Refab Artist cannot reliably preserve
painted constraints, measure exterior fidelity, or explain which original area
caused a failure after multiple cuts.

Every final triangle carries one provenance value:

- `source(faceID)` for preserved exterior geometry;
- `cut(nodeID, side)` for a generated seam cap;
- `joinery(seamID, featureID)` for a generated assembly locator or pocket.

Painted constraints apply only to source faces. Draft, fidelity, and failure
reports must distinguish exterior source geometry from intentional cut and
joinery surfaces.

This requires an attributed-fragment rewrite of the current
`PartitionGeometry` API: its triangle-soup clip path does not retain source
face IDs. Each clipped fragment must carry its original face ID plus barycentric
or equivalent source coordinates; generated caps and joinery receive authored
provenance. One-to-many clipping, repeated subtree replay, and paint propagation
are dedicated tests, not assumed reuse.

## Algorithm Contract

### Overview

The first shippable algorithm is a deterministic, coarse-to-exact search over
**scoped planar cuts**:

```text
preflight source
  -> build reusable acceleration data
  -> test the whole source for a valid pull direction
  -> if valid, return one piece
  -> otherwise cluster the worst undercut regions
  -> propose scoped cut planes for the worst leaf
  -> beam-search cut trees and per-leaf pull directions
  -> refine the best verified or near-verified candidates
  -> rebuild finalists from the high-resolution source
  -> apply joinery
  -> run exact topology, conservation, release, and assembly gates
  -> emit certificates or an honest no-verified-solution-found result
```

### Stage 0: input preflight

1. Apply the effective model transform and unit scale.
2. Reject non-finite coordinates and invalid indices.
3. Remove or isolate zero-area triangles using the shared geometry tolerance.
4. Establish orientation and connected components.
5. Require a watertight, consistently oriented solid for strict automatic
   planning. A repair path may be offered, but the repaired mesh becomes the
   explicit source and is shown as changed.
6. Detect nested disconnected shells. Classify each as material boundary or
   separate solid. Do not guess silently.
7. Require exactly one effective material solid per planning invocation. If
   several independent solids are present, block with instructions to separate
   them into Refab Artist source objects first; v1 does not invent a cut forest or
   assembly relationship for pre-disconnected objects.
8. Compute source volume, surface area, bounds, mesh hash, adjacency, curvature,
   concave edges, symmetry candidates, and BVH.
9. Create a search proxy capped at a benchmarked triangle count while retaining
   the high-resolution source for every final gate.

### Stage 1: candidate pull directions

Candidate axes are an undirected set; `d` and `-d` share moldability but may
produce different upper/lower labels. Generate them from:

- world X/Y/Z;
- oriented-bounding-box axes;
- PCA axes;
- stable clusters in the face-normal distribution;
- normals of large planar regions;
- axes of detected rotational symmetry;
- a deterministic icosphere or Fibonacci-sphere sample at the selected quality;
- user-fixed directions and, in Manual mode, authored per-piece locks.

Deduplicate directions by angular tolerance, sign-canonicalize them, and sort
them deterministically before evaluation.

### Stage 2: proxy directional analysis

For every leaf and direction:

1. Build an orthonormal basis `(u, v, d)`.
2. Project the leaf bounds to the `u-v` plane.
3. Cast an adaptive grid of parallel lines along `d` through the projected
   domain. Add samples at projected vertices, sharp features, silhouette
   changes, and suspected undercut regions.
4. Intersect each line with the triangle BVH.
5. Sort hits, merge coincident hits within tolerance, and construct inside
   intervals using oriented parity.
6. Mark columns with more than one material interval.
7. Estimate blocking depth and map the responsible hits back to source faces.
8. Cluster connected failing faces into undercut regions.
9. Classify draft using face normals, while exempting intentional parting/cap
   faces from the exterior-detail metric.
10. Produce a cheap proxy score.

This stage is a search heuristic. A pass here is never an export certificate.

### Stage 3: zero-cut fast path

Take the highest-ranked whole-model directions into the exact verifier. If any
passes, return a one-piece plan. This rule is important: the feature must not
cut an already moldable object merely because a multi-piece objective happens
to have a lower weighted seam score. If no searched direction passes, the
result means "no certified direction found in this search," not "no direction
exists"; Manual accepts an arbitrary user-specified axis for certification.

### Stage 4: undercut-region clustering

Choose the invalid leaf with the lexicographically worst combination of:

1. no feasible sampled direction;
2. largest maximum blocking depth;
3. largest blocked area;
4. largest number of disconnected violation regions;
5. largest volume.

Within the leaf, cluster violating faces using mesh adjacency and spatial
proximity. Preserve source-face ownership. Each region records possible escape
directions and nearby concave or high-curvature feature lines.

### Stage 5: scoped plane proposal

Generate candidate planes only for the selected leaf. Sources include:

- planes through the boundary of the worst undercut cluster;
- planes aligned to large flat regions;
- planes through concave-edge loops or valleys;
- local PCA frames around the violation;
- symmetry planes and symmetry-paired cuts;
- axes and offsets inherited from a good direction for the expected children;
- quantized offsets through the leaf at 20%, 35%, 50%, 65%, and 80% when no
  better feature plane exists;
- locked manual planes.

For each base plane, include a deterministic neighborhood of offset and angular
perturbations appropriate to the quality level.

Reject before expensive analysis when:

- the plane does not split the leaf;
- either child is below the minimum-volume gate;
- a no-cut face is crossed;
- the cap area is below the seam minimum;
- the split creates an unrequested disconnected fragment;
- the splitter cannot produce two watertight children;
- source-volume conservation fails.

### Stage 6: exact scoped split

Use the existing arbitrary-plane splitter and cap pipeline for the first
implementation. Each successful cut creates one binary `PartitionCutNode`, two
stable child region IDs, one physical seam adjacency, and a source-face map.

The current behavior of replaying every plane across every piece must not be
used for this purpose. Rebuilding a plan means replaying each node only against
its recorded parent region.

For finalist verification, compare the triangle-soup split result against a
Manifold-backed split where available. A disagreement above tolerance is a
geometry error, not a reason to choose whichever result looks better.

### Stage 7: deterministic beam search

Initialize the frontier with the root leaf. For each expansion:

1. select the worst invalid leaf;
2. generate and prefilter its candidate planes;
3. split it;
4. evaluate best pull directions for the two children;
5. update the state objective;
6. canonicalize the cut tree and reject duplicate states;
7. retain the best `beamWidth` states.

The objective is lexicographic. Moldability, topology, source fidelity,
minimum-piece, no-cut, and max-parts constraints are hard.
Only states tied on hard validity are compared on residual depth/area, part
count, seam quality, symmetry, and balance.

Never hide a hard failure inside a weighted scalar. A state with one DHF or
object-assembly failure cannot beat a verified state because it has a prettier
seam.

For the planar solver, the cut tree provides a conservative mandatory group-
motion proof. Disassembly traverses the cut tree **top down**: at the root,
separate one complete child subtree from the other as a rigid group by moving
it outward along the originating cut-plane normal; then recursively open each
already separated child group. At every event, `movingRegionIDs` and
`stationaryRegionIDs` partition that event's active subassembly, and the
continuous translation `T(t)` is collision-tested for all `t in [0, 1]` against
the stationary set and every other piece still present at that point in the
linearized sequence. Bounds separation is only a broad-phase stop condition,
not the collision proof.

Assembly is the exact inverse: apply the events in reverse, bottom-up order,
with the inverse translation. A leaf can therefore participate in several
events as part of nested moving groups. Mold pull direction is never
substituted for an object-assembly motion. Joinery is authored afterward and
must pass the same continuous group-path checks. A future freeform solver needs
a general assembly planner rather than assuming this planar-cut guarantee.

Stop when:

- the zero-cut source is certified, which is trivially minimum part count; or
- the finite deterministic search budget is exhausted; or
- no retained frontier state has a valid expansion; or
- Max Pieces makes further expansion impossible; or
- the user cancels.

Beam search discards states and has no admissible global lower bound in this
specification, so a multi-piece result is described as the best verified state
found within the stated search, never as optimal.

Cancellation returns no new current plan. The last verified plan remains
available if settings have not invalidated it; otherwise it is visibly stale.

### Stage 8: seam refinement

For the top states, refine each unlocked plane through deterministic coordinate
search over small normal rotations and offsets. Accept a change only if:

- all already-valid leaves remain valid in proxy analysis;
- no hard constraint regresses;
- the lexicographic objective improves.

The first release does not turn planar cuts into freeform surfaces. "Cleaner
seams" means better placement of planar seams, not a hidden curved-cut feature.

### Stage 9: high-resolution reconstruction and exact proof

Rebuild each finalist by replaying the cut tree against the original
high-resolution source, then run:

1. finite-coordinate and index validation;
2. watertightness and consistent orientation;
3. self-intersection checks;
4. pre-joinery source-union symmetric difference, missing volume, and overlap;
5. pairwise non-overlap in assembled position;
6. connected-component policy;
7. conservative fixed-direction DHF verification over the projected triangle
   arrangement, or an equivalently complete formulation accepted in M0;
8. upper/lower patch connectivity and parting-loop construction;
9. signed upper/lower draft analysis outside the parting band;
10. mandatory continuous object-piece assembly/disassembly collision proof.

The exact DHF verifier must be a neutral engine service, not a direct
call to `MoldUndercutAnalyzer`, because that type currently assumes MotherMold
parts, cavity ownership, and mold settings, and its sampled translated poses do
not implement this certificate. Refactor only reusable low-level primitives
behind:

- `DirectionalAccessibilityAnalyzer`;
- `DoubleHeightFieldVerifier`;
- `LinearAssemblyVerifier`.

MotherMold may later call compatible low-level services with a cavity-specific
adapter, but its torus and cavity heuristics are not behavior to preserve here.

### Stage 10: joinery and re-verification

Default joint is None. If tapered alignment is selected:

1. place candidate locators on the physical part-pair seam, not on an infinite
   plane count;
2. ensure enough edge and wall clearance;
3. prefer orientations compatible with both pieces' pull and final assembly
   directions;
4. apply the male/female pair transactionally;
5. rerun topology, authored-volume-delta, DHF, and assembly verification on
   both modified pieces;
6. roll back the entire locator pair if either piece fails;
7. report an unkeyable seam rather than forcing a lock.

Existing straight pins and wedges may reintroduce an undercut when their axis
does not match a piece's extraction direction. They are not automatically safe
just because they are safe for FDM printing.

### Stage 11: result selection

Return up to three verified alternatives when available:

- **Fewest parts**;
- **Balanced**;
- **Cleanest seams**.

The user's selected alternative becomes the current generated plan and stores
its canonical cut-tree hash in
`selectedAutomaticAlternativeTreeHash`. On the first successful generation,
the profile-default result is selected and its hash is persisted before the
Plan can be current. This is persisted selection state, not an authored cut
recipe and not an input to the search. Save/open reruns the same versioned
deterministic search and selects the matching result. If a previously persisted
hash is absent from those results, export remains blocked until the user
explicitly chooses a new result; Refab Artist never substitutes a new profile
default silently. **Adopt generated cuts** still copies the selected tree into
the authored Manual envelope. Alternative geometry stays in the Plan cache
rather than being duplicated in project settings.

If no verified state is found and the selected diagnostic finalist is
definitively **Failed**, return its proven violation regions and reported pull
axes. This is not proof that another direction or decomposition cannot exist.
If the finalist is **Indeterminate/error**, use the separate Verification Error
result: name the failed proof stage and any numerically ambiguous locus, but do
not paint red physical-undercut regions that were never proved. Both branches
are preview-only and keep standard mesh export disabled.

## Freeform Volumetric Solver Research Track

Scoped planar cuts cannot solve every useful object and can over-fragment
others. A later solver may implement volumetric double-height-field
decomposition inspired by the 2021 literature:

1. produce a robust volume discretization;
2. precompute directional accessibility per cell;
3. solve a direction-label optimization over the cell adjacency graph;
4. extract connected components per label;
5. reconstruct and regularize internal interfaces;
6. enforce DHF and assembly constraints during smoothing;
7. transfer source surface detail without deformation;
8. run the same exact Refab Artist final verifier.

If any cell or reconstructed interface has no admissible DHF label, the solver
must refine, split again, or fail. It may not copy the paper's rare fallback of
carving material or opening a hole through the assembled object.

This track is not authorized merely by accepting this specification. It has
separate gates:

- freedom-to-operate review;
- dependency and Apache-distribution review;
- decision on tetrahedral, voxel, or adaptive-cell representation;
- proof that interface reconstruction does not require an unapproved or
  source-deforming pipeline;
- benchmark showing a material capability gain over scoped planar cuts;
- a migration story for cut-tree/manual editing.

The 2021 research implementation used TetWild, Embree, and GCO v3. The
distributed GCO v3 terms are reported as noncommercial research/evaluation and
must not ship in Refab Artist as-is; a redistributable replacement or a different
optimizer is required. TetWild/WildMeshing variants have changed over time, so
the review must identify the exact repository, revision, license, and transitive
dependencies rather than approving the name generically. Relevant starting
points are the current
[WildMeshing Toolkit](https://github.com/wildmeshing/wildmeshing-toolkit) and a
[published GCO v3 source header](https://sibr.gitlabpages.inria.fr/docs/nightly/GCoptimization_8h_source.html).
The exact versions, patent terms, binary architecture, Swift/C-interop impact,
and Apache-2.0 distribution compatibility all require review. The repository's
Swift-only architecture decision is not automatically reopened by this research
track.

The final certificate remains shared. A sophisticated planner is allowed to
propose geometry; it is not allowed to redefine what "verified" means.

## Worked Example

### Fixture

Use a purpose-built `orthogonal-double-hook` fixture composed of two joined
regions:

- source bounds: 120 x 80 x 60 mm;
- source volume: 192,000 mm3;
- Region A is known by construction to be a DHF along +X/-X;
- Region B is known by construction to be a DHF along +Y/-Y;
- the joined source has no verified common pull axis in the Standard direction
  set;
- the intended flat interface is at `x = 0`, with area 1,600 mm2;
- the fixture includes a shallow engraved detail band 5 mm away from a worse
  alternative plane.

The fixture generator and its analytic region ownership belong in tests so the
expected answer does not depend on a hand-edited STL.

### Default settings

- Quality: Standard.
- Max Pieces: 4.
- Strict undercut policy: no user-accepted residual mode.
- Draft advisory: 1 degree outside the parting band.
- Minimum piece volume: `max(0.5% x 192,000, 1) = 960 mm3`.
- Minimum seam area: 4 mm2.
- Avoid fine detail: Medium.
- Assembly locators: None.

### Whole-model analysis

Suppose the proxy evaluates 162 uniform directions plus 14 geometry-derived
axes. The best common direction has:

- 24 violating columns;
- 420 mm2 blocked surface area;
- 8.0 mm maximum blocking depth.

The exact zero-cut verifier therefore fails. Refab Artist does not return one
piece.

### Candidate cuts

The worst undercut clusters sit on opposite hooks. Candidate generation
produces:

- feature plane `x = 0`;
- parallel offsets at `x = -5` and `x = +5`;
- principal planes through the source centroid;
- planes following the two largest concave-edge clusters;
- angular perturbations required by Standard quality.

The `x = 0` split yields:

- Child A volume: 96,000 mm3;
- Child B volume: 96,000 mm3;
- volume sum: 192,000 mm3;
- conservation error: 0 mm3 within numerical tolerance;
- seam area: 1,600 mm2;
- both children above the 960 mm3 minimum.

Proxy analysis selects +X/-X as A's mold axis and +Y/-Y as B's mold axis, with
zero violating columns. The complete verifier certifies both DHF properties.
Separately, the planar cut tree proves one object-assembly motion event along
the seam normal X; the inverse event is the disassembly instruction.

The `x = +5` candidate may also be valid, but it crosses the engraved detail
band and incurs a higher detail penalty. The `x = -5` candidate produces an
unbalanced 70/30 volume split. The balanced objective selects `x = 0` without
claiming that it is the only valid decomposition.

### Joinery check

In an internal post-M6 validation build, if a tester changes Assembly locators
to Tapered, Refab Artist proposes two new tapered locator pairs. If one locator violates Child
B's +Y DHF property or its -X assembly path, the complete verifier rejects that
pair. The UI reports the seam as unlocatable or tries another orientation; it
never preserves the old green certificate.

### Output facts

- 2 STL pieces.
- 1 physical seam connecting A and B.
- Pull axes: A = X, B = Y.
- Assembly event: translate subtree B along -X, normal to the `x = 0` seam,
  from its separated pose to its assembled position. B's Y mold pull remains a
  separate fact.
- 2 valid certificates bound to canonical assembled-coordinate mesh hashes.
- Serialized STL file hashes, object-assembly guide, and
  `moldability-report.json` included.

## Output Contract

Before certification and packaging, every final piece passes a versioned
`CanonicalManufacturingMesh` normalization: permitted welds only, coordinates
quantized on a grid materially finer than the linear fidelity tolerance,
consistent orientation, and deterministic vertex/triangle ordering. Topology,
DHF, source fidelity, overlap, joinery, and assembly are rerun on that normalized
geometry. The certificate's `pieceMeshHash` is over this geometry, not an
earlier high-precision working mesh.

Each serializer must preserve the normalized coordinates exactly under its
declared decimal/binary encoding. The exporter parses every just-written entry,
reconstructs the same canonical mesh, and requires the certificate hash before
the entry can enter the ZIP. This round trip is what makes package-only
revalidation of canonical piece hashes possible; a merely byte-hashed lossy STL
is insufficient.

### Separate STL ZIP

```text
model-object-pieces-for-two-piece-molds.zip
  model-object-piece-A.stl
  model-object-piece-B.stl
  object-assembly-guide.txt
  moldability-report.json
```

- The first release uses the existing STL encoding; changing to binary STL is a
  separate exporter change and must be declared in the report.
- Stable piece names from cut-tree region IDs and deterministic display labels.
- Geometry is in the canonical assembled model coordinate frame.

### Named-object OBJ ZIP

- One ZIP contains one OBJ with an `o` object per piece, the same required
  object-assembly guide, and the JSON report.
- Stable object names.
- Vertex and face ordering deterministic for the same planner/verifier version.

Both packaging modes are single-destination, atomic ZIP transactions. Write to
a temporary sibling, validate every entry and hash, then replace the destination
only after the full package succeeds. On cancellation or error, remove the
temporary package and leave any existing destination untouched. Rigid-mold
partition export must fail closed on an invalid index or triangle; it may not
reuse the current exporter's skip-and-continue behavior.

### Printing follow-on

Rigid-Mold Partition does not lay pieces on a printer plate in v1. A later
**Prepare master pieces for printing** transaction may create a derived Fit
Printer project. It must preserve each canonical assembled-geometry hash,
record every rigid transform, and recheck actual transformed bounds after any
print-specific joinery.

### Object-assembly guide

For every piece and seam, include:

- piece name and color;
- pull direction;
- mating neighbor;
- assembly-locator count and clearance;
- every ordered assembly motion event that includes the piece, including the
  moving group, stationary group, originating seam, direction, and distance;
- warning that Refab Artist has verified geometry, not resin flow, material draft,
  shrinkage, mold strength, or process parameters;
- any low-draft advisory.

### Machine-readable report

`moldability-report.json` includes:

- schema version;
- app, planner, splitter, and verifier versions;
- source mesh hash, units, bounds, and volume;
- `rigidMoldGenerationInputHash` as defined below;
- cut tree and physical seam adjacency;
- per-piece mesh hash, bounds, volume, pull direction, metrics, certificate,
  reason codes, and referenced assembly-motion event IDs;
- the ordered top-down disassembly motion events and reverse-order assembly
  instruction, canonical cut-tree hash, and assembly-plan hash;
- volume-conservation and pairwise-overlap summaries;
- assembly-locator survival and re-verification status;
- overall `verificationOutcome: verified|failed|indeterminate` plus the
  compatibility convenience field `verified: true|false`.

It also includes `verificationMode: strict`, tolerance-policy version, canonical
assembled-geometry hashes, exact serialized geometry-entry hashes, the exact
object-assembly-guide hash, and any recorded rigid transforms. A certificate
binds to canonical geometry; an artifact hash binds to exact file bytes.

The hash graph must not be recursive. `moldability-report.json` contains hashes
for the geometry entries and assembly guide only; it contains neither its own
hash nor the enclosing ZIP hash. After the final ZIP bytes exist, the exporter
may calculate and return an outer archive SHA-256 as detached completion
metadata, but that value is not embedded in the archive. If another system
needs the report-file hash, it likewise records it outside the report.

### Generation-input hash

`RigidMoldGenerationInputHash` is SHA-256 over one versioned canonical encoding
of exactly these inputs:

- `EffectiveGeometryFingerprint`, units, accepted repair/normalization choice,
  and source transform;
- only the nested rigid-mold analysis and search fields: process, planning
  mode, pull policy/fixed axis, quality, Max Pieces, draft advisory, priority,
  piece/seam limits, detail avoidance, symmetry, seed, and joinery geometry;
- the authored cut-tree payload when Manual, otherwise an explicit automatic
  sentinel; source-face paint and applicable authored region pull locks;
- planner, splitter, proof-method, predicate, tolerance, joinery, and verifier
  versions.

The hash explicitly excludes every Fit Printer setting, ZIP/OBJ/STL packaging
choice, the source-audit inclusion toggle, naming-only fields, viewport Explode,
selected piece, camera, and `selectedAutomaticAlternativeTreeHash`. The latter
chooses among already-generated, separately mesh/cut-tree/assembly-hash-bound
plans; it does not alter search. Changing an excluded packaging field may
change serialized artifact hashes, but it does not invalidate a geometry
certificate. Canonical field order, float encoding, enum spelling, absent-value
encoding, and hash-schema version are fixed in tests; do not hash an incidental
Swift `Codable` byte stream.

The current-Plan key is broader than the generation-input hash.
`CurrentRigidMoldPlanKey` hashes the `RigidMoldGenerationInputHash`, selected
`cutTreeHash`, `assemblyPlanHash`, canonical ordered piece-mesh-hash set, and
proof/verifier versions. It changes when the user selects a different generated
alternative even though the underlying search inputs do not. The noncircular
`CurrentRigidMoldExportKey` additionally hashes the completed certificate-set
digest and packaging/artifact choices; certificates never key themselves
through that export digest.

### Independent revalidation scopes

The exporter and documentation distinguish two scopes:

1. **Package-only revalidation** uses the report plus exported piece bytes. It
   can recompute artifact hashes, piece-local topology and DHF status, canonical
   piece hashes, pairwise overlap, seam adjacency, and every continuous
   assembly motion. It cannot independently compare the pieces with source
   geometry that is not in the package.
2. **Full source-fidelity revalidation** additionally requires either the
   original effective source whose canonical fingerprint matches the report or
   the optional `audit/canonical-source.obj` entry produced by **Include source
   mesh for full audit**. That option is off by default because it increases
   package size and republishes source geometry. Its exact bytes and canonical
   geometry hash are included among the report's geometry-entry hashes.

Without the matching source, missing-volume, added-volume, source-exterior, and
union-symmetric-difference values remain producer-computed, source-hash-bound
claims; the package must not describe them as independently reproduced. With
the source, the full validator recomputes them rather than trusting the report.

Normal export requires `verified: true`. A report for an inspection-only plan
may be saved with the project but is not packaged as a successful mesh export.

## Headless Contract

Add explicit flags without overloading existing Fit Printer flags:

```text
--partition-purpose rigid-two-piece-molds
--partition-rigid-mold-settings path.json
--partition-release-process rigid-two-piece
--partition-release-planning automatic|manual
--partition-release-pull auto|x|y|z|NX,NY,NZ
--partition-release-quality quick|standard|thorough
--partition-release-max-pieces N
--partition-release-draft-advisory-deg N
--partition-release-min-piece-volume-fraction N
--partition-release-min-piece-volume-mm3 N
--partition-release-min-seam-area-mm2 N
--partition-release-seam-priority fewer|balanced|cleaner
--partition-release-detail-avoidance off|medium|strong
--partition-release-preserve-symmetry true|false
--partition-face-constraints path.json
--partition-region-pull-locks path.json
--partition-assembly-locators none|tapered
--partition-locator-clearance-mm N
--partition-locators-per-seam N
--partition-release-output separate-stl-zip|named-obj-zip
--partition-include-source-audit true|false
--partition-alternative-tree-hash HASH
--partition-seed N
--partition-authored-cut-tree path.json
```

`--partition-rigid-mold-settings` accepts the canonical versioned serialization
of the complete nested settings contract and is the durable parity path as
fields evolve. Individual flags override the bundle in command-line order and
the resolved effective settings are emitted in the report; an unknown or
unavailable field is an error, never ignored. Face constraints and region pull
locks carry the matching source fingerprint. Tapered-locator flags are rejected
in public builds until their release gate passes. The existing global output-
destination argument supplies the atomic ZIP path.

Headless output must include measured fields, not only a success string:

```text
partition_purpose=rigid-two-piece-molds
verified=true
dhf_verifier_outcome=verified
piece_count=2
seam_count=1
missing_source_volume_mm3=0.000000
overlap_volume_mm3=0.000000
minimum_signed_draft_excluding_parting_deg=0.000000
assembly_verified=true
cut_tree_hash=...
assembly_plan_hash=...
piece_A_pull=1,0,0
piece_B_pull=0,1,0
piece_A_canonical_hash=...
piece_B_canonical_hash=...
report=/path/to/moldability-report.json
```

Manual mode is not reproducible until the CLI can ingest the scoped cut tree.
`--partition-authored-cut-tree` consumes the same versioned envelope, including
its source fingerprint, and performs both validation phases. It must not accept
`manual` and then silently use automatic planes or ignore a fingerprint
mismatch. In Automatic mode, a requested alternative-tree hash must be present
among the deterministic results or the command fails; it never exports a
different alternative as fallback.

## Performance and Concurrency

### Principles

- All planning and exact verification run off the main thread.
- The UI remains responsive and cancellation is cooperative.
- Search output is deterministic: no wall-clock timeout changes the chosen
  geometry.
- Cache keys are tiered; no search result is stored under a proxy-analysis key.
  Geometry acceleration data keys on `EffectiveGeometryFingerprint` plus
  import/acceleration versions. Directional proxy fields additionally key on
  the exact canonical direction set, proxy resolution, tolerance policy, and
  proxy-analyzer version. Search summaries and alternative Plans key on the
  full `RigidMoldGenerationInputHash`. Certificates key on the full
  `CurrentRigidMoldPlanKey` plus proof/verifier versions.
- Revalidate only the affected cut-tree subtree after a local edit, then rerun
  global assembly and conservation gates.
- Proxy results may be reused across alternative states; final certificates may
  not be reused after geometry changes.

This requires a new cancellable planner API, not only the current detached Task
wrapper:

- the view owns one `PartitionPlanningTask` and cancels/replaces it explicitly;
- a cancel request changes the visible state to **Cancelling...** and disables
  repeated cancel immediately; this acknowledgement is not a claim that the
  geometry task has already terminated;
- the planner accepts a typed progress sink and checks cancellation between
  direction batches, candidate splits, beam expansions, refinements, and final
  verifier stages;
- noninterruptible Manifold calls are named progress phases and cancellation is
  observed immediately after they return. Their maximum uninterrupted duration
  is benchmarked separately; any release fixture exceeding the M0 ceiling must
  use a subdividable operation or a killable worker boundary rather than hiding
  the latency behind the 500 ms acknowledgement target;
- a cache actor owns immutable acceleration data, proxy fields, search
  summaries, and certificates in separate typed stores. Max Pieces, seed,
  priority, volume/seam limits, symmetry, authored tree, face constraints,
  region pull locks, and joinery cannot be omitted from a search/result key
  because they are already covered by `RigidMoldGenerationInputHash`;
- Manifold handles remain confined to one owning task and are never shared
  across parallel candidates.

The current path/triangle-count/bounds signature is not certificate-grade.
`EffectiveGeometryFingerprint` hashes canonical effective vertex coordinates,
indices, component/orientation normalization, accepted repair result, scale and
model transform, plus import-normalization version. A changed fingerprint
orphans face paint and pull locks until they are explicitly remapped; it never
leaves the old plan green because path, count, and bounds happened to match.

### Provisional benchmark gates

M0 must establish honest targets on the project's chosen baseline Apple Silicon
Mac. Until then, these are provisional budgets rather than ship claims:

- already-moldable 100k-triangle fixture: Standard analysis in under 10 seconds;
- two-to-four-piece 100k-triangle fixture: Standard result in under 60 seconds;
- 500k-triangle input: no main-thread stall over 100 ms and peak resident memory
  below 4 GB;
- cancel request visibly acknowledged as **Cancelling...** in under 500 ms;
- interruptible work reaches a cancelled terminal state within 2 seconds, and
  each named noninterruptible geometry phase stays below a separately reported
  M0 ceiling no greater than 5 seconds on the release fixture matrix;
- exact verification accounts for a separately reported portion of runtime.

If measurements miss these targets, reduce proxy resolution or search breadth
without weakening the final gate. Never speed up by relabeling proxy analysis
as proof.

## Failure and Edge-Case Policy

### Non-manifold or open source

Automatic strict planning blocks. Offer an explicit repair or return to the
source application. Do not cap arbitrary artistic openings as if they were
defects.

### Self-intersections

Block strict planning unless a source-preserving normalization produces a
single well-defined solid and the user accepts that normalized mesh.

### Multiple disconnected solids

One v1 planning invocation accepts one effective material solid. If components
are independent objects, require the user to separate them into distinct
Refab Artist source objects and plan each independently; those pre-existing
components do not count as algorithmic cuts. If they are one intended
preassembled multi-solid assembly, block with a specific unsupported-input
message. Do not synthesize a cut-tree root or assembly order that never existed.

### Nested shells and trapped internal components

Report no linear escape path. A planar or even DHF decomposition may be
infeasible without first isolating the inner component. Never return a green
result based only on external faces.

### Internal cavities and through-holes

Multiple parting loops are allowed when line-interval and extraction proofs
pass. A through-hole is not automatically an undercut. A blind side hole often
is.

### Coplanar and vertex-grazing cuts

Use the existing canonical tolerance policy. Repeated runs must classify the
same triangles consistently. A cut that produces zero-thickness caps or
ambiguous ownership is rejected.

### Thin features

Use detail avoidance and advisory proxy-thickness signals to discourage thin
cuts, and respect no-cut constraints as hard. If all retained candidates sever
a protected thin feature, report the conflict and show the crossed protected
faces.

### Tiny disconnected debris

Do not discard it silently. Either associate it with a source component,
generate a named piece above the minimum-volume policy, or reject the
candidate.

### Symmetry

Symmetry is a preference unless a user lock makes it hard. If symmetric cuts
increase part count or prevent verification, show the tradeoff.

### No-cut constraints make the problem infeasible

Show the protected faces crossed by the highest-ranked otherwise-valid
candidates and give a recovery action. Do not claim a globally smallest
conflict set, weaken the constraint, or ignore the paint.

### Max Pieces exhausted

Keep the best diagnostic state, state which piece remains invalid, and offer to
increase Max Pieces or add a manual cut. Export stays blocked.

### Candidate direction missed

Thorough mode expands uniform sampling. Manual pull locks allow arbitrary
directions. Failure in a finite sample must be worded "not found" rather than
"does not exist" unless an exact infeasibility proof exists.

### Zero draft

Geometric proof may pass at 0 degrees. Report low-draft area and warn that
real tooling may bind. V1 reports the advisory without claiming a process-
specific hard draft requirement.

### Joinery reintroduces an undercut

Roll back the locator transaction, invalidate both affected certificates, and
surface the exact violation. Never export the unverified locator because the base
pieces passed earlier.

### Dense mesh or search exhaustion

Return a resumable diagnostic state only if its cache key and planner version
match. A partial frontier is not a verified plan.

## Validation and Test Plan

### Testing rule

Every milestone begins with failing tests for its geometry and honesty gates.
A green build without measured fixtures is not milestone completion.

M0 creates a checked-in fixture expectation manifest. Each analytic fixture
records source hash, tested axes, expected strict outcome, allowed piece-count
range, expected cut plane/offset tolerance where analytic, assembly motion,
and applicable tolerance-policy version. Organic fixtures record an owner-
accepted seam-region mask and regression bounds rather than a fictional
analytic optimum. Later milestones may tighten these values only through a
reviewed manifest change, never by weakening a failing test ad hoc.

### Unit tests

- direction sign canonicalization;
- adaptive column hit sorting and tolerance deduplication;
- interval construction for convex, concave, hollow, and tangent cases;
- face draft classification;
- undercut-region connected clustering;
- cut-tree scoped replay;
- stable region IDs and seam adjacency;
- authored-tree Phase A quarantine and Phase B source-bound replay failure;
- generated-cut/pull locking atomically adopts the tree and switches to Manual;
- automatic alternative selection persists by canonical tree hash and never
  falls back silently when the hash is missing;
- top-down group-motion event construction and bottom-up inverse assembly;
- objective lexicographic comparison;
- deterministic candidate order and tie-breaking;
- migration from legacy Partition settings;
- report schema, nonrecursive hash graph, and mesh/input/cut-tree/ordered-
  assembly-plan hash binding.

### Geometry fixtures

| Fixture | Expected contract |
|---|---|
| Cube | One piece; primary axes valid; no false undercuts |
| Sphere | One piece; valid along sampled axes; verifies curved surfaces |
| Z-extruded L-prism | One piece along Z; invalid lateral axes may be reported but must not force a cut |
| Torus aligned to Z | One DHF piece along Z with multiple parting loops; catches hole false positives |
| Blind side-hole block | Fails along the blocked axis; another valid axis accepted if present |
| Orthogonal double hook | Known two-piece decomposition with different pull axes |
| U-joint | Piece-count range, allowed axes, and mandatory assembly sequence come from the checked-in M0 expectation manifest |
| Hollow bottle with flared reentrant lip and trapped-core profile | Requires multiple pieces or honest failure under planar limits; the analytic profile proves multiple axial material intervals |
| Concave organic | Accepted seam-region mask and maximum piece count come from the checked-in M0 expectation manifest; no convex-only blind spot |
| Nested shell with trapped core | No false success; clear infeasible reason |
| Thin protected arm | No-cut policy honored; candidate rejected rather than amputating debris |
| Locator-lock fixture | Base pieces pass, straight locator fails, tapered alternative passes or falls back |

The torus expectation is an intentional semantic fork from the current
MotherMold undercut heuristic, whose Z-axis torus regression expects a warning.
M0 may extract low-level ray/math utilities, but it must not preserve that
cavity-specific behavior under a renamed generic analyzer.

### Invariants for every verified fixture

- every final piece watertight and finite;
- pre-joinery symmetric-difference, missing-source, and overlap volumes are
  below their separate policy thresholds;
- after joinery, measured volume equals the explicitly authored boss-minus-
  pocket delta and pairwise overlap remains below tolerance;
- each piece has exactly one current certificate and pull axis;
- the complete fixed-direction DHF verifier returns `verified`, not merely a
  zero count on sampled columns;
- for the one effective source solid, a binary tree with `N` leaves has exactly
  `N - 1` recorded group-motion events; every event partitions its active
  subassembly into disjoint moving and stationary leaf sets, passes continuous
  collision verification, and the reverse event order reconstructs the
  assembly;
- source exterior provenance is complete and its symmetric Hausdorff deviation
  is within the linear fidelity tolerance; authored caps/joinery are excluded;
- assembly-locator geometry, when exercised internally after M6 or released
  after M7, survives and is reverified;
- same inputs and planner version produce identical mesh hashes;
- save/open and headless regeneration reproduce the same facts.

### Negative tests

- proxy pass but complete DHF verifier fail/error -> export blocked;
- stale certificate hash -> export blocked;
- changed event distance/order/proof digest with unchanged piece meshes ->
  assembly-plan root changes and export is blocked;
- manual cut tree missing a referenced parent -> preserve the raw tree in Phase
  A quarantine, open the rest of the project, and block Plan/export;
- structurally valid authored tree bound to a different source -> fail Phase B,
  retain the tree for repair/removal, and never silently regenerate it;
- Max Pieces reached with residual region -> preview-only;
- no-cut paint ignored by an otherwise good plane -> test fails;
- tiny disconnected piece silently dropped -> test fails;
- invalid assembly-locator pair partially applied -> entire transaction rolls back;
- report contains its own or outer-ZIP hash -> schema validation fails;
- source-less package claims independently revalidated source fidelity -> test
  fails; the same package plus matching original/audit source recomputes it;
- current global-plane replay splits a valid sibling -> test fails;
- CLI Manual without cut tree -> command fails with a specific message.

### Visual evidence

For at least cube, torus, orthogonal double hook, U-joint, and concave organic:

- assembled view;
- exploded view along reported directions;
- pull arrows;
- cut surfaces;
- undercut and low-draft overlays;
- per-piece isolation;
- before/after assembly-locator verification after M6;
- one failed planar case with recovery guidance.

### Physical validation

Software geometry tests are necessary but not sufficient for the product claim.
Before public release:

1. choose at least one organic and one mechanical two-or-more-piece fixture;
2. generate each mold on the exact certified axis and from geometry consistent
   with the certified upper/lower contact sheets. MotherMold may be used only
   after an explicit import path proves that it honors that axis and source
   hash; its current independent auto-parting choice is not equivalent;
3. fabricate the molds;
4. cast at least three cycles per fixture;
5. require 3/3 cycles per fixture to release by the intended opposite linear
   pulls without prying, mold damage, or cast-piece fracture, then complete the
   reported object assembly. Record release force where measurable, flash,
   seam gap, locator fit if present, breakage, and assembly error;
6. compare low-draft warnings with actual binding;
7. publish the settings and measured results in a validation report.

Unexpected binding or an unreported geometric lock is a release blocker. Flash,
force, and cosmetic seam quality are recorded as process data until a specific
material/tooling profile defines numeric thresholds. The physical test confirms
the process envelope; it does not replace the geometry test suite.

## Implementation Architecture

### Reuse

- `Partition.swift`: extend settings with purpose and nested moldable settings.
- `PartitionGeometry.swift`: starting point for an attributed arbitrary-plane
  split/cap rewrite.
- `PartitionKeys.swift`: reference for seam sampling only. Its straight pins and
  wedges are not the M6 tapered locator engine.
- `PartitionPlanner.swift`: keep Fit Printer behavior; route Split for Two-Piece Molds to a
  separate planner.
- `PartitionPanel.swift`: conditional purpose-specific inspector.
- `PartitionExporter.swift`: stable adjacency-aware guide and JSON report.
- `ContentView.swift`: existing Generate, stale signature, async cache, and
  export gate.
- `ModelSceneView.swift`: reuse exploded transforms and MotherMold undercut
  marker patterns; add actual plane surfaces and pull arrows.
- `MoldUndercutAnalyzer.swift`: extract neutral low-level tests, not the
  MotherMold-specific API.
- `ManifoldEngine.swift`: robust finalist splits, intersection, and swept
  collision operations.
- `MeshPreflight.swift`: topology facts.
- `MeshInspector.swift` and `MeshScaler.swift`: source geometry and units.

### New modules

1. `MoldablePartitionSettings.swift`
2. `PartitionCutTree.swift`
3. `SourceFaceMap.swift`
4. `DirectionalAccessibilityAnalyzer.swift`
5. `UndercutRegionClusterer.swift`
6. `MoldableCutCandidateGenerator.swift`
7. `MoldablePartitionOptimizer.swift`
8. `DoubleHeightFieldVerifier.swift`
9. `LinearAssemblyVerifier.swift`
10. `MoldabilityCertificate.swift`
11. `MoldabilityReportExporter.swift`
12. `MoldablePartitionOverlay.swift`
13. `PartitionValidation.swift`

### Planner boundaries

```text
PartitionPlanner
  |- FitPrinterPartitionPlanner       existing semantics
  `- MoldablePartitionPlanner
       |- DirectionalAccessibilityAnalyzer
       |- UndercutRegionClusterer
       |- MoldableCutCandidateGenerator
       |- MoldablePartitionOptimizer
       |- PartitionGeometry / ManifoldEngine
       |- DoubleHeightFieldVerifier
       |- LinearAssemblyVerifier
       `- PartitionValidation
```

Fit Printer and Split for Two-Piece Molds share geometry and export primitives, but not
their objective logic. This avoids a growing `if purpose == ...` monolith.

## Delivery Plan and Gates

### M0 - feasibility, terminology, and IP gate

Deliverables:

- neutral definition of DHF, undercut, draft, and release proof in code/tests;
- analytic fixture generators;
- refactored read-only directional analyzer prototype;
- candidate direction benchmark;
- planar cut search spike on orthogonal double hook, U-joint, bottle, and
  concave organic;
- dependency alternatives memo for future volumetric work;
- qualified patent/FTO review scope and owner.
- at least five interviews with resin sculpture/model-kit makers who
  specifically use or want **reusable rigid two-piece molds**, covering
  willingness to cast and glue multiple pieces, acceptable seam locations,
  maximum practical piece count, and current workaround cost. Flexible-only
  silicone users and print-only makers may inform adjacent needs but do not
  validate the primary persona hypothesis.

Exit gate:

- cube, sphere, torus, and Z-extruded L-prism have no false-green or
  false-red result under their known valid axes;
- at least two nontrivial fixtures are solved by scoped planar cuts;
- nested/trapped fixture fails honestly;
- runtime and memory are measured;
- product owner accepts the planar solver's capability boundary;
- interviews confirm a concrete target workflow and record a go/no-go product
  decision; geometric feasibility alone is not treated as market validation;
- no feature UI is exposed yet.

### M1 - product shell and persistence

Deliverables:

- `PartitionPurpose` and migration;
- purpose picker and conditional inspector skeleton;
- moldable settings and project round-trip;
- headless argument model;
- stale signature includes every relevant field;
- one-piece analysis and viewport pull arrow.

All UI remains behind an internal feature flag through M6. Even inside that
flag, Output controls are absent until M6's transactional export, headless
parity, and post-joinery revalidation gates pass; passing M4 and M5 alone is not
enough. M6 may enable a controlled validation/beta surface. M7 remains the
normal-build public-release gate because the feature makes a physical-process
claim that must be bounded by recorded casting trials.

Exit gate:

- existing Partition projects reopen unchanged as Fit Printer;
- no unsupported control is active;
- one-piece success and failure wording is test-backed.

### M2 - scoped planar cut tree

Deliverables:

- stable region IDs;
- formal cut-tree validator and corrupt-tree migration policy;
- parent-scoped binary cuts;
- attributed triangle/fragments and source-face mapping through repeated clips;
- physical seam adjacency;
- legacy-plane import utility;
- scoped manual add/move/delete/merge;
- node-ID-based callbacks replacing array-index selection.

Exit gate:

- a cut to one invalid leaf never splits a valid sibling;
- replay is deterministic;
- topology and volume conservation pass on concave and hollow fixtures.

### M3 - complete DHF and object-assembly proof kernel

Deliverables:

- conservative, complete fixed-direction DHF verification with tri-state
  verified/failed/indeterminate output;
- upper/lower patch and parting-loop construction;
- numerical predicate/tolerance policy and proof digest;
- continuous top-down group-disassembly and reverse-assembly collision gate;
- content-addressed assembly-motion events and proof roots;
- fixed-axis diagnostic API usable by manual fixtures before any optimizer can
  claim success.

Exit gate:

- proxy-pass/exact-fail fixture is blocked;
- torus multiple-loop case passes;
- nested case is blocked or indeterminate, never green;
- multi-level cut trees produce complete group-motion proofs;
- no automatic optimizer is merged until this gate is green.

### M4 - automatic optimizer and certificate integration

Deliverables:

- direction sampling;
- proxy accessibility fields;
- undercut clustering;
- candidate plane generation;
- deterministic beam search;
- Quick/Standard/Thorough budgets;
- alternative results;
- mesh/input/assembly-proof-bound certificates;
- JSON report generation for internal validation.

Exit gate:

- zero cuts for known one-piece fixtures;
- intended two-piece cut recovered for orthogonal double hook;
- U-joint and concave organic meet the checked-in fixture expectation manifest;
- Max Pieces exhaustion is honest;
- benchmark targets are measured, not estimated;
- every optimizer finalist is accepted or rejected by the already-green M3
  proof kernel, never by proxy status alone;
- internal report round-trip preserves certificate and reason-code facts. No
  user export is claimed before M6.

### M5 - guided editing and visual explanation

Deliverables:

- scoped plane surfaces and handles;
- full plane-orientation gizmo keyed by node ID and selected target region;
- no-cut/preferred-seam painting;
- pull locks;
- per-piece isolation;
- undercut and low-draft overlays;
- local subtree reoptimization;
- defined delete behavior: deleting a cut collapses its entire descendant
  subtree, removes descendant region pull locks after confirmation, preserves
  source-face paint, and invalidates every affected certificate;
- direct recovery actions.

Exit gate:

- user edits cannot leave a stale green certificate;
- painted hard constraints are never silently ignored;
- failed regions remain attached to the correct exploded piece.

### M6 - joinery, export, and headless parity

Deliverables:

- None and internally testable tapered assembly locators built by a new
  rigid-mold joinery engine, not current straight Partition pins/wedges; the
  public picker remains absent pending M7 physical validation;
- transactional rollback;
- adjacency-aware object-assembly guide;
- STL ZIP and named-object OBJ ZIP transactions;
- complete CLI flags and cut-tree import;
- save/open/headless byte and fact parity.

Exit gate:

- assembly-locator lock regression blocked;
- no physical interface is missing from the guide;
- export independently rechecks current mesh, cut-tree, input, and ordered
  assembly-plan hashes against every certificate;
- every successful export passes package-only revalidation from the report and
  exported piece bytes;
- full source-fidelity revalidation passes when the original matching source or
  optional canonical-source audit entry is supplied, and a package without
  either source never claims to have independently reproduced source fidelity;
- current manual/headless reproduction gap is closed.

### M7 - physical validation and release

Deliverables:

- two physical multi-piece casting studies;
- performance matrix;
- known-limitations page;
- user documentation;
- final license and patent sign-off;
- packaged app and complete test report.

Exit gate:

- all software gates green;
- physical results recorded;
- if tapered assembly locators are in the release, their clearance/material
  matrix passes and the picker is enabled only in the validated process
  envelope; otherwise the shipped UI remains None-only;
- no claim exceeds the measured process envelope;
- no open high-severity IP or dependency issue.

### R1 - optional volumetric/freeform research

This begins only after M0's separate approval and must demonstrate materially
better valid decompositions than the planar solver before product integration.

### I1 - optional MotherMold handoff

After both features expose compatible contracts, add **Create MotherMold
projects for certified object pieces**. It creates one project per piece,
transfers the canonical piece hash and certified axis, disables independent
auto-parting unless the user explicitly breaks the link, and requires the final
mold artifact to pass MotherMold's own geometry gates. This is integration work,
not part of the v1 decomposition release.

## Acceptance Criteria

### Functional

- User can select Split for Two-Piece Molds without losing existing Fit Printer settings.
- Refab Artist returns one piece when no cut is needed.
- Automatic mode can produce different pull axes per piece.
- Manual edits are scoped to one cut-tree region.
- User can lock axes and protect surface regions.
- Every attempted proof has an explicit verified, failed, or indeterminate
  outcome. Fresh/stale is a separate dimension shown for every cached Plan; a
  stale prior success is never displayed as a current verified result.
- Normal export is impossible when any final piece lacks a current certificate.
- Save/open and CLI reproduce the same plan and facts.

### Geometry

- No source exterior deformation beyond tolerance.
- Final pieces are watertight, non-overlapping, and volume-conserving.
- Each verified piece satisfies the two-piece release contract.
- Every recorded top-down group-disassembly event and reverse bottom-up
  assembly event is collision-free under the modeled continuous linear motion.
- Joinery cannot bypass re-verification.
- Planar infeasibility is reported rather than concealed.

### UX

- Pull directions and failed regions are visible.
- In a formative test with at least five target users, at least four identify
  the first blocker and the displayed recovery action within 60 seconds without
  opening raw metrics.
- Advanced metrics remain available for expert inspection.
- Dead or future controls are absent or visibly disabled with a reason.
- Long-running work is cancellable and does not freeze the UI.

### Performance

- Benchmarked targets from M0 are met on the named baseline hardware.
- Deterministic budgets produce deterministic output.
- Exact verification is never skipped because a time target is exceeded.

### Documentation

- Help distinguishes rigid two-piece moldability, one-sided moldability,
  support-free printing, and flexible molds.
- Known limitations include planar seams, direction/search sampling
  incompleteness, zero-draft friction, source-quality requirements, and
  unmodeled process physics. This wording does not weaken the complete final
  fixed-direction proof for any axis the planner actually certifies.
- The report says exactly what was and was not verified.

## Open Decisions

These are implementation decisions for M0, not reasons to leave the product
contract vague:

1. Complete fixed-direction DHF proof representation: adaptive columns are
   useful search checks but do not cover a continuum. M0 must select
   a conservative projected-arrangement, exact castability, or equivalently
   complete fixed-direction formulation before strict status can ship.
2. Robust-predicate implementation and dependency choice for the complete DHF
   verifier.
3. Robust continuous-collision implementation for the specified linear group
   motion events; discrete translated poses are insufficient.
4. Baseline Apple Silicon model for performance gates.
5. Whether the first release exposes all three solution alternatives or only
   the selected priority.
6. The clearance/material/cast-process matrix used to pass the M7 physical gate
   for tapered assembly locators. The M6 engine may be exercised internally,
   but the public picker stays absent until that gate passes.
7. Whether Manifold or the existing triangle splitter is authoritative for
   finalist geometry when both succeed but differ within tolerance.

## Risks and Mitigations

| Risk | Consequence | Mitigation |
|---|---|---|
| Face-normal analysis is mistaken for proof | False moldability claim | Multi-stage exact gate and proxy-pass/exact-fail fixture |
| Discrete object-assembly samples miss an in-between collision | False assembly claim | Conservative continuous path gate for finalists |
| Global planes over-fragment the model | Bad seams and excess parts | Scoped cut tree before optimizer work |
| Planar search does not find a solution | User dead end | Honest bounded-search result, guided manual cuts, later gated freeform research |
| Search explosion | Long runtime or nondeterminism | Beam search, stable budgets, proxy caching, lexicographic pruning |
| Dense or dirty meshes break splitting | Missing or non-watertight pieces | Preflight, exact finalists, topology and conservation gates |
| Assembly locators reintroduce undercuts | Unreleasable cast piece | Default None, transactional application, full re-verification |
| Pretty seams beat validity | False green output | Hard constraints are never scalar weights |
| Low draft binds physically | Geometry passes but mold sticks | Separate low-draft metrics, optional hard draft, physical validation |
| Automatic result cuts important detail | Poor artistic result | Saliency cost, no-cut/preferred paint, manual local refinement |
| Semantic segmentation is trusted | Natural-looking but invalid parts | Semantic signals may propose seams only; exact geometry decides |
| Patent overlap | Distribution or roadmap risk | M0 FTO gate, no automatic mold output in this feature, counsel review |
| New volumetric dependency conflicts with Apache distribution | Licensing or architecture regression | Separate dependency review; planar solver uses current stack |
| Certificate becomes stale | Export no longer matches proof | Bind to canonical mesh, cut-tree, rigid-mold generation-input, ordered assembly-plan, and verifier hashes; recheck in exporter |

## Provenance and Repo Cross-Check

This specification is grounded in the current canonical checkout of this
repository.

Relevant implemented surfaces:

- `Partition.swift`: current settings and plane model.
- `PartitionPlanner.swift`: global sequential plane replay and build-volume
  planning.
- `PartitionGeometry.swift`: arbitrary-plane clipping, stitched loops, islands,
  holes, projection, and cap triangulation.
- `PartitionKeys.swift`: cap-authored pins and wedges.
- `PartitionPanel.swift` and `PartitionPlaneEditing.swift`: inspector and
  current manual editing.
- `PartitionExporter.swift`: mesh packaging and current simple map.
- `ContentView.swift`: Generate, cache, stale state, and export gating.
- `ModelSceneView.swift`: exploded preview and MotherMold undercut markers.
- `MoldUndercutAnalyzer.swift`: current MotherMold-specific directional and
  sampled extraction checks; not the rigid-mold partition certificate.
- `MoldPartitioner.swift` and `MotherMoldPlanner.swift`: current limited
  candidate-axis scoring.
- `ManifoldEngine.swift`: robust solid operations available for final checks.

Existing targeted tests passed during the research audit:

- 24 Partition tests;
- 5 undercut-focused MotherMold tests.

Those tests establish reusable foundations, not completion of this feature. The
missing test surface is enumerated above.

## Final Recommendation

Proceed, but call the feature **Split for Two-Piece Molds**, define it around
strict DHF certification for ideal rigid two-piece pulls, and build the proof
before the optimizer.

The first implementation should not attempt to reproduce the full 2021
volumetric research pipeline. It should first add the missing architectural
primitive - a scoped cut tree - then implement the independent, complete fixed-
direction DHF and group-assembly proof kernel. Only after that gate is green
should Refab Artist's working plane splitter be driven by deterministic search.
That path can deliver a useful and honest feature while exposing exactly where
planar decomposition stops working.

If the planar product proves valuable, the direct DHF literature provides a
clear research direction for a freeform solver. That later step should be
treated as a substantial geometry project with its own dependency, IP,
performance, and physical-validation gates, not as an incremental strategy
toggle.
