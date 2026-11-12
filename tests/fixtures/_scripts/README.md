# Fixture generator scripts

These Python scripts are the source of truth for every fixture under
`tests/fixtures/`. Re-running them reproduces the corpus from scratch.

The scripts ship in the repo so the provenance chain has zero broken links:
if anyone (the maintainer, a contributor, a future agent, a reviewer, etc.)
questions whether a fixture came from a clean source, they can re-run the
matching generator and `diff` the output. The scripts are the license
posture made auditable.

## Layout

```
_scripts/
├── README.md                 # this file
├── lib_mesh.py               # shared mesh-construction + STL/OBJ writers
├── gen_primitives.py         # cube (ASCII+binary STL+OBJ), sphere, cylinder, torus
├── gen_stress.py             # dense sphere, tetra, open shell, hollow, multi-component
├── gen_pathological.py       # non-manifold, self-intersecting, zero-area, thin feature
├── gen_organic.py            # lumpy blob, low-poly head
├── gen_real_world.py         # simple chair, spur gear
├── build_manifest.py         # rebuild tests/fixtures/MANIFEST.md from on-disk bytes
└── verify.py                 # parse-check every STL/OBJ in the corpus
```

## Dependencies

- Python 3.10+
- `numpy>=1.26` (already on most systems)
- `numpy-stl>=3.2`  (install with `pip3 install --user numpy-stl`)

No internet access required at generation time. No third-party fixture is
downloaded — every byte is synthesized from math in these scripts.

## Regenerating the entire corpus

From the repo root:

```bash
cd tests/fixtures/_scripts
python3 gen_primitives.py
python3 gen_stress.py
python3 gen_pathological.py
python3 gen_organic.py
python3 gen_real_world.py
python3 build_manifest.py
python3 verify.py
```

Output expectations:

- The five `gen_*.py` scripts each print `<category>/<name>: triangles=N
  vertices=M` for every fixture they emit.
- `build_manifest.py` prints `wrote .../MANIFEST.md (N fixtures, T bytes)`.
- `verify.py` prints a table of `(path, bytes, triangles, sha256-12)`
  and ends with `OK: all fixtures parsed`. **Non-zero exit means a fixture
  failed to parse — investigate before committing.**

## Determinism

The scripts are deterministic by construction. No RNG, no time-dependent
inputs, no environment lookups. Repeated runs on the same machine produce
byte-identical output.

Cross-machine determinism for **ASCII STL** and **OBJ** is total — they're
pure text written with `%.6f`. Cross-machine determinism for **binary STL**
is excellent but not bit-perfect: floating-point representation of `numpy`
`float32` values is stable across mainstream platforms (x86_64 + arm64,
macOS + Linux), but `numpy-stl`'s 80-byte header can drift across library
versions. We pin the header in `lib_mesh.write_stl_binary` to a fixed string
per fixture, which eliminates the only known drift source.

If a re-run produces a different SHA-256 than the committed `MANIFEST.md`,
that's a real change worth investigating — either a generator was edited
or `numpy-stl`'s on-disk format changed under us. Either way, the response
is to re-commit both the fixture(s) AND the updated manifest in the same
PR.

## Adding a generator

1. Add a new `gen_<category>.py` (or extend an existing one if the new
   fixture fits an existing category).
2. Import builders + writers from `lib_mesh`.
3. Write the fixture under `fixtures_root() / "<category>" / "<name>.<ext>"`.
4. Add the `(license, source, intended_use)` entry to `FIXTURE_META` in
   `build_manifest.py`.
5. Re-run `build_manifest.py` then `verify.py`.
6. Commit the generator AND the fixture AND the updated manifest in one
   PR.

## What goes here vs what goes outside `_scripts/`

**Inside `_scripts/`:** generator code, manifest builder, verifier, shared
mesh-construction library.

**Outside `_scripts/`:** the committed fixture bytes, the per-category
docs (e.g. `pathological/README.md`), the top-level `README.md` describing
the corpus, the `MANIFEST.md` table.

`_scripts/` is the "how"; everything else under `tests/fixtures/` is the
"what".
