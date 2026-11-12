#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="${1:-"$ROOT_DIR/build/physical-calibration"}"
CASE_ID="p64_cube50_interlocked_3mm"
OUT_DIR="$OUT_ROOT/$CASE_ID"
FIXTURE="tests/fixtures/primitives/cube_50mm_ascii.stl"
DXF_PATH="$OUT_DIR/$CASE_ID.dxf"
MEASUREMENT_PATH="$OUT_DIR/$CASE_ID.measurement.json"
LOG_PATH="$OUT_DIR/$CASE_ID.measurement-log.md"

mkdir -p "$OUT_DIR"

cd "$ROOT_DIR"

swift run --package-path app/RefabArtist RefabArtist \
  --headless-export \
  --mode interlocked \
  --format dxf \
  --fixture "$FIXTURE" \
  --output "$DXF_PATH" \
  --measurement "$MEASUREMENT_PATH" \
  --axis z \
  --secondary-axis x \
  --thickness 3 \
  --slot-clearance 0.10 \
  --sheet-width 600 \
  --sheet-height 400

fixture_sha="$(shasum -a 256 "$FIXTURE" | awk '{print $1}')"
dxf_sha="$(shasum -a 256 "$DXF_PATH" | awk '{print $1}')"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "$LOG_PATH" <<EOF
# P6.4 Physical Calibration Log

Case: $CASE_ID
Generated: $generated_at

## Candidate Export

- Fixture: \`$FIXTURE\`
- Fixture SHA-256: \`$fixture_sha\`
- Mode: Interlocked Slices
- Primary axis: Z
- Secondary axis: X
- Material preset: Plywood 3 mm
- Material thickness: 3.00 mm
- Slot clearance: 0.10 mm
- Expected slot width: 3.10 mm
- Sheet size: 600 mm x 400 mm
- DXF: \`$DXF_PATH\`
- DXF SHA-256: \`$dxf_sha\`
- Measurement JSON: \`$MEASUREMENT_PATH\`

## Laser Setup

- Machine:
- Controller/software:
- Material supplier / sheet:
- Measured material thickness before cut:
- Kerf compensation applied by laser software: none / value:
- Power:
- Speed:
- Passes:
- Focus / Z offset:
- Air assist:

## Cut Result

- DXF imported at 1:1 scale: yes / no
- Number of parts cut:
- Parts released cleanly from sheet: yes / no
- Burn/charring severe enough to affect fit: yes / no
- Any part visibly warped or delaminated: yes / no

## Slot Measurements

Measure at least three slots with calipers before assembly.

| Location | Target width | Measured width | Notes |
| --- | ---: | ---: | --- |
| Primary part slot A | 3.10 mm |  |  |
| Primary part slot B | 3.10 mm |  |  |
| Secondary part slot A | 3.10 mm |  |  |

## Fit Check

- Dry-fit force: too loose / hand-fit / tight / impossible
- Assembles without cracking: yes / no
- Holds shape under light handling: yes / no
- Needs sanding or tool cleanup: yes / no
- Worst offending part/slot:
- Observed correction for next run:

## Verdict

- Pass / Fail / Retry needed:
- Summary:
EOF

cat <<EOF
P6.4 calibration package generated:
  DXF: $DXF_PATH
  Measurement JSON: $MEASUREMENT_PATH
  Measurement log: $LOG_PATH
EOF
