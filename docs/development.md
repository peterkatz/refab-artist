# Development

How to build, run, package and check Refab Artist. The shorter version for
contributors, with the ground rules, is in [CONTRIBUTING.md](../CONTRIBUTING.md).

The app is one Swift package, `app/RefabArtist`, written in Swift 6 for Apple
Silicon Macs on macOS 15 or newer. Manifold and Clipper2 are vendored as
prebuilt static libraries, so there is nothing else to install for the app.
The Python tooling (gates, benchmark, fixture and image generators) needs the
packages in `tools/requirements.txt`.

## Build and run

```sh
swift build --package-path app/RefabArtist                # debug build
swift build --package-path app/RefabArtist -c release     # optimised build
swift run --package-path app/RefabArtist RefabArtist      # opens the window
```

The debug build is several times slower than the release build on the
geometry pipeline; use release for benchmarks and for anything you hand to
someone else.

## Headless export

The same binary exports without opening a window. Give it `--headless-export`
and the model, mode and format to write:

```sh
app/RefabArtist/.build/release/RefabArtist --headless-export \
  --mode interlocked --format svg --thickness 3 --slice-count 6 \
  --fixture tests/fixtures/real-world/simple_chair.stl \
  --output /tmp/chair-interlocked.svg
```

Modes are `stacked`, `interlocked`, `radial`, `curve`, `threeD`,
`foldedPanels`, `structures`, `partition`, `motherMold` and `inflatables`.
Formats are `dxf`, `svg`, `pdf`, `eps`, `stl` and `obj`; the mode table in
the release notes (`docs/releases/`) says which a mode writes, and the specs
under `docs/specs/` give the detail for the cut-sheet modes and 3D Slices. The
other modes are described by their requirement documents (`docs/prd-*.md`,
and `docs/MOTHERMOLD_CONTRACT.md` for MotherMold). An option a mode does not read is an
error, not ignored. Run the binary only with `--headless-export` or one of the
`--*-audit` options: without them it opens the window.

## Packaging a local app

```sh
tools/package_app.sh
open "build/Refab Artist.app"
```

The script builds in release configuration and writes an ad hoc signed
`build/Refab Artist.app` (version from `REFAB_VERSION`, build number from
`REFAB_BUILD`; defaults `0.1.0` and `1`). It replaces any app already in
`build/`; `REFAB_OUTPUT_DIR` writes it somewhere else. The build itself runs
in `/tmp/refab-artist-build` (`REFAB_SCRATCH_PATH`), not in the package's
`.build/`, so that the app carries no path of your machine; the script strips
the debug map and checks the app with `tools/check_app_paths.sh`. The
headless binary under `app/RefabArtist/.build/release/` comes from
`swift build -c release`, not from this script. For a public binary,
signing and notarization, use `docs/signed-notarized-build.md`.

## Tests and gates

```sh
swift test --package-path app/RefabArtist     # Swift tests (about 45 minutes)
python3 -m pytest -q                          # Python tests
python3 scripts/functional_gate.py            # cuttability gate, committed exports
python3 scripts/assembly_gate.py              # assembly gate (needs a built binary)
python3 scripts/radial_geometry_gate.py       # organic Radial / Interlocked / Curve checks
```

`docs/functional-gate.md` explains the functional gate; the release steps are
in `docs/release-checklist.md`. The speed of the export pipeline is measured
with `tools/benchmark_exports.py` (`docs/performance-benchmarking.md`).

## Illustrations for the README

`tools/render_doc_images.py` draws the pictures in `docs/images/` from the
exports themselves (a cut sheet from the SVG, the assembled parts from the
OBJ), so they can be regenerated after a release build:

```sh
swift build --package-path app/RefabArtist -c release
python3 tools/render_doc_images.py all
```

They are illustrations of the exports, not screenshots of the app window.

## Viewport matcap images

The four surface styles of the model viewport (Clay, Satin, Glossy, Toon) are
lit-sphere images, `matcap_<style>.png`, in
`app/RefabArtist/Sources/RefabArtist/Resources/`. They are generated, not
hand-painted: `tools/generate_matcaps.py` draws each one from a stated lighting
model (key, fill and rim light, a Gaussian highlight, flat bands for Toon), and
the parameters of every style sit at the top of that file. To change a style,
edit its parameters and rewrite the images:

```sh
python3 tools/generate_matcaps.py             # rewrite the four PNGs
python3 tools/generate_matcaps.py --check     # exit 1 if they are stale
python3 tools/generate_matcaps.py --preview /tmp/matcaps   # sheet of test shapes
```

The script needs numpy and Pillow (`tools/requirements.txt`); the images and
the Metal shader (`tools/shaders/Matcap.metal`) share the contract written at
the top of the script. `tests/parsers/test_generate_matcaps.py` pins it.

## Artifact Policy

Do not commit other software's files (app bundles, binaries, interface files, icons, installers, help documents), output files produced by other software, or bulk generated reports. `scripts/check-no-foreign-assets.sh` checks for the first group (`docs/contributing-hooks.md`). Small project-owned test fixtures in `tests/fixtures/` are allowed for build smoke tests.
