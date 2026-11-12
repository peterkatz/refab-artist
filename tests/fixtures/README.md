# Refab Artist fixture corpus

These are Refab Artist's own test 3D models. The Swift test suite, the
functional and assembly gates, and the dense-mesh stress checks all consume
them.

The corpus deliberately spans five categories so the construction modes are
exercised across the full input distribution:

| category | folder | what it stresses |
|---|---|---|
| **primitives** | `primitives/` | format coverage, axis-aligned baseline, the simplest possible mesh |
| **stress** | `stress/` | very-high-tri, very-low-tri, open-shell, multi-shell, multi-component |
| **pathological** | `pathological/` | intentionally invalid geometry — preflight + error-path coverage |
| **organic** | `organic/` | smooth curved surfaces, freeform silhouettes |
| **real-world** | `real-world/` | shapes a user would actually fabricate |

Top-level legacy files (`cube_ascii.stl`, `cube.obj`,
`rectangular_prism_ascii.stl`, `square_pyramid_ascii.stl`) predate this corpus
and are referenced by the existing Swift test suite. Their provenance is
captured in `MANIFEST.md` alongside the categorized fixtures.

## License posture

Every fixture in this corpus is **CC0** / public-domain-dedicated, generated
locally from one of the Python scripts under `_scripts/`. No fixture is
taken from another application's bundled resources or sample files,
from third-party model repositories (Thingiverse, Stanford 3D Scanning,
Sketchfab, etc.), or from any user project file. Re-running the scripts under
`_scripts/` reproduces the corpus byte-identically (modulo the binary STL
floating-point representation, which is fixed by the writer).

The one exception is the project owner's own hand scans under
`app/RefabArtist/Tests/Fixtures/hand-scans/` and the healed models derived
from them. The owner published them with his permission under the project
licence (GPL-3.0); `MANIFEST.md` records their provenance and SHA-256
hashes. Models that belong to other people stay out of the repository: a
check that wants one reads it from a path named by an environment variable
and skips, saying so, when the variable is not set.

The scripts ship in this repo specifically so the provenance chain has zero
broken links — if anyone questions a fixture, they can re-run the generator
and `diff` the output.

## Naming convention

```
<category>/<descriptor>_<scale-hint>_<format-hint>.<ext>
```

- `descriptor` describes the shape (`cube`, `sphere`, `simple_chair`).
- `scale-hint` is OPTIONAL and uses millimeters: `50mm`, `d50mm`
  (diameter), `R30_r10mm` (torus major/minor radii), `T20_M2`
  (gear teeth/module).
- `format-hint` is OPTIONAL and disambiguates dual-encoding fixtures:
  `_ascii` vs `_binary` for the two STL flavors of the same geometry.
- `ext` is `.stl` (ASCII or binary; the STL format itself is the same) or
  `.obj`. Refab Artist imports both formats.

## Coordinate system and units

- **Up axis: +Z.** All fixtures are oriented so +Z is up.
- **Units: millimeters.** Fixture dimensions in filenames are mm. Importers
  that normalize units should leave these meshes unchanged.
- **Origin: centered horizontally** for solids that don't have an obvious
  "bottom". For solids that do (`simple_chair`, `low_poly_head`), the base
  sits at `z=0` and the model rises into +Z.

## Format coverage

- **Binary STL** — every primitive, stress, pathological, organic, and
  real-world fixture is provided as binary STL. Most-used format in CAD
  pipelines; smallest on disk.
- **ASCII STL** — `primitives/cube_50mm_ascii.stl` + the four top-level
  legacy fixtures. Enough ASCII coverage to exercise the parser without
  doubling the corpus byte count.
- **OBJ** — `primitives/cube_50mm.obj` + the legacy `cube.obj`. Same shape
  as the cube STL fixtures so OBJ vs STL parsing differences can be isolated
  from geometry differences.

## Size budget

The hard ceiling for any single fixture is ~10 MB; the only one approaching
it is `stress/sphere_dense_d50mm.stl` at ~5.4 MB (intentional — that's the
>100k-triangle stress case). The total corpus is well under 30 MB.

If a future Phase 6 stress fixture needs to be larger, generate it on the
fly from a script and `.gitignore` it (don't commit the bytes); commit only
the generator.

## Adding fixtures

1. Pick a category (primitive / stress / pathological / organic / real-world);
   add a new one only if existing categories don't fit.
2. Add the generation logic to the matching `_scripts/gen_<category>.py`
   (or write a new script — keep one script per category for discoverability).
3. Run the script; the new file lands under the matching folder.
4. Run `_scripts/verify.py` — every STL must parse cleanly.
5. Append a row to `MANIFEST.md` with the new fixture's path, byte size,
   SHA-256-12, triangle count, license, and intended use.
6. If the fixture is pathological, document the specific invariant it
   violates in `pathological/README.md`.

The corpus is versioned with the repo. Treat it as code — a fixture change
that changes test or gate results should land in its own PR with the
reasoning.
