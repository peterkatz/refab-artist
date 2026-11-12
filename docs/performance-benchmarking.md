# Performance Benchmarking

P6.3 provides a repeatable local benchmark harness for Refab Artist's headless export pipeline. It measures wall-clock time on the current machine and writes raw JSON plus an optional Markdown summary. The benchmark is intentionally not a CI threshold: CPU model, thermal state, Swift build configuration, and filesystem cache can move timings enough that CI gating would be noisy.

## Command

Run from the repo root:

```sh
python3 tools/benchmark_exports.py \
  --iterations 5 \
  --warmups 1 \
  --json /tmp/refabartist-benchmark/benchmark.json \
  --markdown /tmp/refabartist-benchmark/benchmark.md \
  --output-dir /tmp/refabartist-benchmark/runs
```

The tool builds `app/RefabArtist` in release mode before timing exports. To reuse an existing build:

```sh
swift build --package-path app/RefabArtist -c release
python3 tools/benchmark_exports.py --skip-build --iterations 5
```

List available benchmark cases:

```sh
python3 tools/benchmark_exports.py --list-cases
```

Run one case:

```sh
python3 tools/benchmark_exports.py --case stacked_dense_sphere_svg --iterations 3
```

## Default Cases

The default set covers representative hot paths without running every mode/format combination:

| Case | Fixture | Mode | Format | Purpose |
|---|---|---|---|---|
| `stacked_dense_sphere_svg` | `tests/fixtures/stress/sphere_dense_d50mm.stl` | Stacked | SVG | Dense 107k-triangle import plus stacked contour/vector export. |
| `interlocked_gear_svg` | `tests/fixtures/real-world/spur_gear_T20_M2.stl` | Interlocked | SVG | Feature-rich real-world outline plus interlocked slot planning. |
| `three_d_torus_stl` | `tests/fixtures/primitives/torus_R30_r10mm.stl` | 3D Slices | STL | Genus-1 model through 3D slice mesh export. |
| `folded_chair_obj` | `tests/fixtures/real-world/simple_chair.stl` | Folded Panels | OBJ | Representative multi-part folded panel mesh export. |

## Output

`benchmark.json` records each case's arguments, per-iteration elapsed seconds, output byte counts, and compacted headless measurement data. `benchmark.md` renders a table with min, median, mean, and max seconds per case. Use median time for comparisons unless investigating a single outlier.

For release notes or Linear updates, paste the Markdown table and include:

- machine model and macOS version
- git commit SHA
- Swift version from `swift --version`
- whether the run used `--skip-build`

## Interpreting Runs

Run the same command at least twice before calling a change a regression. A useful local regression check is:

1. Run the benchmark on `main`.
2. Run the same command on the candidate branch after a clean release build.
3. Compare median seconds case-by-case.
4. Investigate changes above 20 percent before merging, especially on `stacked_dense_sphere_svg`.

No hard threshold is encoded because the same branch can vary across machines and thermal states. The harness exists to make those comparisons cheap and repeatable.
