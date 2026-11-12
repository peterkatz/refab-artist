# Physical Calibration Runbook

P6.4 proves the software with one real laser-cut plywood fixture. This runbook
prepares the candidate export and measurement log. The final pass/fail still
requires the project maintainer to cut the file, assemble it, and record the physical result.

## Calibration Case

Use the smallest slotted fixture that exercises real joinery:

| Field | Value |
| --- | --- |
| Case ID | `p64_cube50_interlocked_3mm` |
| Fixture | `tests/fixtures/primitives/cube_50mm_ascii.stl` |
| Mode | Interlocked Slices |
| Primary axis | Z |
| Secondary axis | X |
| Material | 3 mm plywood |
| Material thickness | 3.00 mm |
| Slot clearance | 0.10 mm |
| Expected slot width | 3.10 mm |
| Sheet size | 600 mm x 400 mm |
| Export format | DXF |

Why this case:

- It is small enough for a quick, low-risk laser job.
- It produces actual interlocking slots, so the test exercises fit rather than
  only contour correctness.
- The cube fixture is deterministic, project-owned, and easy to measure.
- 3 mm plywood is the lowest-friction baseline material already represented by
  Refab Artist's material presets.

## Generate The Cut File

Run this from the repo root:

```bash
bash scripts/prepare-physical-calibration.sh
```

The script writes:

- `build/physical-calibration/p64_cube50_interlocked_3mm/p64_cube50_interlocked_3mm.dxf`
- `build/physical-calibration/p64_cube50_interlocked_3mm/p64_cube50_interlocked_3mm.measurement.json`
- `build/physical-calibration/p64_cube50_interlocked_3mm/p64_cube50_interlocked_3mm.measurement-log.md`

The script is equivalent to:

```bash
swift run --package-path app/RefabArtist RefabArtist \
  --headless-export \
  --mode interlocked \
  --format dxf \
  --fixture tests/fixtures/primitives/cube_50mm_ascii.stl \
  --output build/physical-calibration/p64_cube50_interlocked_3mm/p64_cube50_interlocked_3mm.dxf \
  --measurement build/physical-calibration/p64_cube50_interlocked_3mm/p64_cube50_interlocked_3mm.measurement.json \
  --axis z \
  --secondary-axis x \
  --thickness 3 \
  --slot-clearance 0.10 \
  --sheet-width 600 \
  --sheet-height 400
```

The generated measurement JSON should report:

- Mode: `interlocked`
- Slice count: 20
- Slot count: 200
- Slot width: 3.10 mm
- DXF line count: 884
- DXF text count: 20

## Laser-Cutter Instructions

Use the generated DXF as-is:

- Import at 1:1 scale.
- Do not add additional kerf compensation in laser software for the first run.
- Do not resize the drawing.
- Cut the whole case from one sheet of nominal 3 mm plywood.
- Keep all parts, including any parts that cut poorly, until the log is filled.

Record the actual laser settings in the generated measurement log. At minimum,
capture machine/software, material source, measured material thickness, power,
speed, passes, and whether the cutter software applied any extra compensation.

## Measurement Procedure

Before assembly:

1. Measure actual sheet thickness with calipers.
2. Measure at least three slots from different parts.
3. Record whether the DXF imported at 1:1 scale.
4. Record whether all parts released cleanly from the sheet.

During assembly:

1. Dry-fit parts by hand.
2. Record fit force as `too loose`, `hand-fit`, `tight`, or `impossible`.
3. Record cracks, delamination, sanding/tool cleanup, or visibly wrong slots.
4. Identify the worst offending part or slot.

The calibration passes only if the fixture hand-assembles without cracking,
holds shape under light handling, and does not require sanding or manual slot
cleanup. If it fails, keep the log: the next pass should change one parameter
at a time, usually slot clearance.

## Owner Boundary

Codex can generate and verify the candidate export, but cannot complete P6.4.
Completion requires the physical cut/fit result and the filled measurement log.
