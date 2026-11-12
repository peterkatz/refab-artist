# MotherMold V2 Decisions

Date: 2026-07-10

This log records product and engineering decisions that supersede earlier
MotherMold scaffold, PRD, plan, or handoff language. Internal serialized names
remain compatible where noted, but the artist-facing behavior below is the
current contract.

## D1: Both subtypes use a controlled sacrificial fill gate

Silicone Jacket and Rigid Casting Shell both preserve the complete intended
cavity. Each receives one exterior funnel and a narrow through-channel owned by
one mold part. The automatic location must avoid parting planes and the funnel
may not overlap another part. A manual location on a seam is rejected without
modifying either part.

This supersedes the earlier proposal to truncate a rigid shell with a
cavity-sized open face. That approach removed artwork and could open the far
wall or floor. The funnel and channel are sacrificial after casting.

## D2: The generated master socket locates; it does not seal

The Silicone Jacket socket constrains the physical master in X, Y, and Z and
provides a seal land. Printed fit clearance is not a liquid seal. The Build
Status, workflow, hover help, and assembly guide all require the artist to apply
a compatible clay or reusable sealant continuously around the land before
pouring. The final mold must retain at least 98 percent of the measured locator
geometry or export is blocked.

External Fixture remains an explicit alternative. It means Refab Artist does not
locate the master, and the artist must provide and seal a stem, suspension, or
custom base fixture.

## D3: Registration keys are visibly and geometrically tapered

The UI and CLI call the options Tapered round and Tapered bar. Both use an
8-degree release taper with a tolerance-enlarged female pocket. Every requested
male/female pair is applied transactionally. Final geometry must retain the
complete expected boss volume and the complete clearance-pocket profile, not
only a centerline sample. Missing or damaged keys block export.

The serialized enum values `pins` and `dovetail` remain for project
compatibility. The MotherMold CLI accepts `tapered-round` and `tapered-bar` as
the primary names and retains the old values as aliases.

## D4: Counts refer to physical mating interfaces

A two-part mold has one physical mating interface. A four-part mold cut by two
planes has four physical interfaces, not two. Each interface must receive its
own two-sided flange plate, requested bolt pattern, and requested tapered key
pairs. Reporting and the assembly guide use part-pair identities rather than
counting infinite split planes.

## D5: Explode is a reversible inspection state

Explode is a labeled viewport toggle and is also available as Inspect interior
in the Assembly panel. It moves existing mold-part entities along their stored
pull directions while the master remains fixed. Pressing it again restores the
exact assembled transforms without rebuilding, reframing, mutating settings, or
changing export bytes. The Parts menu can isolate one mold part.

## D6: Undercut markers are opt-in inspection data

Red markers represent measured possible undercut regions. They are off by
default, are labeled Undercuts when enabled, and move with their owning mold
part in exploded view. Rigid molds also perform an actual translated collision
sweep along each pull axis. A missing or failed rigid demold proof blocks export
instead of being reported as clean.

## D7: Topology repair is proof-based

Only microscopic, planar stitch cracks may be capped. A real opening is never
filled by the repair path. A candidate mesh replaces the original only after it
passes the actual printable topology gate; a merely lower defect count is not a
repair. Final simplification stays below the default key clearance.

## D8: Draft is not a user control

The unimplemented Draft control is absent from the UI and CLI. The legacy
`draftAngle` field is decoded only so older project files continue to open. It
does not claim to change geometry.

## D9: Artist status comes before engineering detail

Build Status shows one plain-language blocker and a direct recovery action
before any metrics. Raw pipeline diagnostics are collapsed under Build details.
The Issues inspector does not say No global errors while MotherMold has a
blocking error. When a later hardware or validation gate fails after producing
valid parts, those parts remain available for inspection but Export is disabled.
A fatal planner failure that never produced valid parts cannot display geometry
that does not exist.

## Current scope boundary

Refab Artist verifies mold geometry, fixture retention, watertight parts, physical
interface coverage, fill path, requested vents, registration, and rigid demold
proof. Printer-specific support placement, resin/FDM process settings, and bed
fit remain final checks in the artist's printer slicer; the assembly guide says
so explicitly rather than implying those checks were performed.

## D10: Manual parting is explicit and count-checked

Selecting Manual seeds the required plane count in the UI so artists know how
many parting planes must be authored. They then edit each plane's axis and
offset directly. If the required manual planes are missing or the count is
wrong, the build blocks before partitioning instead of silently falling back to
Auto.

## D11: Partial flange coverage blocks export

Partial flange coverage is an error in the planner even when the flange builder
itself remains all-or-nothing. The result is inspection-only and export-blocked
until every physical interface has a clampable flange.

## D12: Equivalent parting planes have one canonical identity

Plane normals are normalized, sign-canonicalized, and sorted before partitioning.
Reversing a normal while reversing its offset, or supplying the same manual
planes in a different order, must produce the same named parts, demold axes,
interfaces, flanges, and keys. Manual mode still requires exactly the requested
number of planes and never falls back to Auto.

## D13: Export independently proves the requested mold contract

The exporter does not trust planner diagnostics or cached success flags alone.
It revalidates serialized topology and pairwise disjointness, then checks the
current settings against the final part count, plane count, every requested
flange plate and bolt bore, every tapered key pair, the fill gate, exact vent
count, and jacket locator retention. Missing proof blocks every output format
with a rebuild instruction.

## D14: Key taper and survival are measured as complete profiles

Round and bar keys keep the specified 8-degree release taper. If the available
engagement is shallow, Refab Artist shortens the key without flattening the taper;
if no valid tapered profile fits, the complete interface transaction rolls back.
Final proof measures the complete expected boss and clearance-pocket volumes,
including their side walls and tip, so a surviving centerline cannot hide a
clipped or obstructed key.

## D15: Generated hardware may not consume protected mold material

Flanges are assembled transactionally from immutable input parts. Seam clearance
is applied only to generated flange material, the original shell and locator are
restored exactly, and at least 99.9 percent of immutable input plus 98 percent of
each counted flange contribution must survive. Spout and vent candidates also
must preserve at least 98 percent of a generated jacket locator. Any failure
rolls back the candidate or complete hardware stage instead of exporting damage.

## D16: Source and prepared positive are distinct artifacts

The imported bytes and active/healed source geometry remain immutable. Any
anchor, gate, vent landing, alignment, or repair addition creates a separately
named Prepared Master. Every intentional art-surface change is a typed,
highlighted modification region whose exact final signature requires approval
before manufacturing export.

## D17: A modified positive is mandatory manufacturing output

When the selected jacket workflow modifies the positive, the exact serialized
Prepared Master is included in the manufacturing package and independently
passes topology, containment, source-preservation, and file-round-trip gates. A
raw imported mesh never substitutes for it.

## D18: New digital jackets use positive mechanical retention

The recommended digital-master workflow uses a non-circular prepared-master
post, split collar, captured yoke, and through-hardware. It must constrain all
six rigid-body degrees of freedom and provide a positive anti-lift path. Friction,
fit clearance, and sealant do not count as structural hold-downs.

## D19: Existing physical positives remain supported honestly

An unmodified physical original may use a measured locator or modeled external
fixture. Locator-only is production-positive only when measured mass, center of
gravity, contact footprint, buoyancy, and tipping evidence pass. Otherwise the
UI and package require an external hold-down without claiming Refab Artist supplied
one.

## D20: Silicone-liner registration is separate from shell registration

Tapered shell keys align rigid mold parts. Reusable silicone liners receive
their own measured, drafted liner-to-shell registration plus a split gate lip.
Requested features are transactional and all reuse checks run on the exact
trimmed production-liner state.

## D21: Liner creation and production casting are separate processes

The one-time Liner Fill path and vents are not production-casting paths. The
production tool has its own gate, pinned funnel seal, and independently analyzed
casting vents. Required casting vents use separately removable rods that come
out before the shell or positive moves.

## D22: Reusable-tooling export is a self-describing package

New jacket tooling exports through one authoritative Manufacturing ZIP writer.
The archive contains every manufacturing geometry artifact, stable part IDs,
manifest, hardware schedule, and exact offline visual guide. Every non-manifest
member is role-typed and hashed; undeclared, missing, duplicate, unsafe, or
round-trip-invalid members block publication.

## D23: No tooling stage may fail silently

Post, collar, yoke, funnel, vent, liner-registration, support, and package stages
either produce measured evidence or a typed blocking/actionable status. Auto may
propose recovery geometry, but it never substitutes a weaker fixture, changes
artwork, or drops a requested feature without showing the result and invalidating
approval.

## D24: Reuse and strength claims require physical evidence

Geometry-complete does not mean load-qualified or production-ready. Hold-down
and cradle profiles require calibrated combined-load envelopes and timed proof
tests. Production language additionally requires the documented leak, ordered
removal, liner reseating, funnel seal, casting-vent, and repeated-casting matrix.

## D25: Liner filling and casting have explicit supported orientations

Liner Fill and Casting use separate gravity vectors, fluid mass/centroid
histories, support polygons, and air-path analyses. If the assembled tool is not
stable throughout an empty-to-full phase, Refab Artist generates a phase-labeled,
load-qualified cradle or leaves production status blocked with a direct support
action.

## D26: The master hold-down cross-pin is standard removable hardware

The keyed-post workflow uses a removable metal or otherwise load-rated standard
cross-pin through the prepared-master post and printed yoke. Refab Artist models
its clearance and load path, lists its required diameter and length in the
hardware schedule, and may include reference geometry for inspection. It does
not export the pin as a printable manufacturing STL or count an uncalibrated
printed pin as structural qualification.
