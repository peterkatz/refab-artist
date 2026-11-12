#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STRUCTURES_REGENERATE_FAST_FIXTURE=1 \
swift test \
  --package-path "$ROOT/app/RefabArtist" \
  --scratch-path /tmp/refabartist-swiftpm-structures-fixture \
  --filter 'StructureInfillEngineTests/testRegenerateHandStandEx3Healed50kFixture'

ls -lh "$ROOT/app/RefabArtist/Tests/Fixtures/handStand_ex3_healed_50k.obj"
