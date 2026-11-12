# AGENTS.md

## Project

Refab Artist is an original, Apple Silicon-native macOS app that turns 3D models into flat parts for laser, CNC or hand cutting, plus related mesh tools. GPL-3.0. Repo: `peterkatz/refab-artist`.
Contributions require the contributor agreement in `CONTRIBUTING.md`.

It is for makers with laser cutters, CNC routers or hand tools who build objects from sheet material on Apple Silicon Macs.

## Clean-room rule

- Never copy, decompile or disassemble other software, its UI resources, help text or output files.
- Implement from our own specs in `docs/specs/<mode>.md`, written in our own words from what Refab Artist should do.
- Only use third-party code under a GPL-compatible licence, and list it in `THIRD_PARTY_NOTICES.md`.
- When in doubt about whether something may be used, ask before using it.

## What stays out of the repo

- **Other software's assets.** App bundles, executables and libraries, interface files (NIB, XIB, storyboard), icons, help documents, installers, and anything extracted from them. They never enter git.
- **Code or text copied from other software.** No code, strings or symbol names copied from other software, and no third-party code without a compatible licence.
- **Fixtures without provenance.** Every model or generated output in `tests/fixtures/` needs a documented source in `tests/fixtures/MANIFEST.md`. Output files produced by other software are not fixtures.

`scripts/check-no-foreign-assets.sh` enforces the asset rules (see `docs/contributing-hooks.md`).

## Discipline rules (independent of legal — these produce better software)

- **Spec before code, per mode.** No new construction-mode implementation without a corresponding `docs/specs/<mode>.md` first. The spec is what anyone reading the project — contributor, user, future you — uses to understand what each mode does. When the code changes what a mode does, update its spec in the same change.
- **Functional gate before "done", per mode.** A mode isn't finished until it passes the functional-correctness gate — `scripts/functional_gate.py`, the gated cuttability invariants (fits-sheet, no-overlap, validity, biscuits-in-material, part-count, slots-fit-material). See `docs/functional-gate.md`. This is the definition of done.
- **No output parity target.** Refab Artist's output is judged by the gates, physical cut tests and the user, not by comparison with another program's files.

## Third-party code

`THIRD_PARTY_NOTICES.md` lists every component that was not written for this project, with its licence.

## Git Workflow

- `main` is the source of truth. Never push directly to `main`.
- Branch per change: `feat/<name>`, `fix/<name>`, `docs/<name>`, `chore/<name>`.
- Draft PR opened on first push.
- Never `git push --force` to `main`.
- One feature per PR. Don't bundle unrelated cleanup.

## Locations

- Working repo: your clone of the repository. Commands in this file run from its root.
- GitHub: `https://github.com/peterkatz/refab-artist`

## Build Direction

- Mac frontend: SwiftUI (current)
- 3D viewport: RealityKit
- 2D polygon operations: Clipper2 (Boost Software License 1.0)
- Mesh operations: Manifold (Apache-2.0), vendored as a static library. CGAL is not used (decision D2).
- Licence: source and distributed binary are GPL-3.0; Manifold and Clipper2 keep their own GPL-3.0-compatible licences (`THIRD_PARTY_NOTICES.md`). The project moved from Apache 2.0 to GPL-3.0 on 2026-10-04; older Apache 2.0 statements in dated docs are superseded.
- Optional later: dedicated C++ engine if Swift-only proves limiting (open decision; see PRD § Known open considerations)

## Documentation

Read in this order before any work:

1. `AGENTS.md` (this file)
2. `docs/PRD.md` — product spec, success criteria, approach, licensing
3. `docs/KANBAN.md` — every work item by phase with current state
4. `docs/HANDOFF.md` — live project context, next concrete work, decisions log

`docs/KANBAN.md`, `docs/HANDOFF.md` and `docs/archive/` are working documents of the development repository; public snapshots leave them out.

Historical, do not follow for current decisions:

- `docs/archive/project-plan-2026-05-04.md`
- `docs/archive/handoff-2026-05-04.md`
