#!/usr/bin/env bash
# Precompile the MatCap surface shader to a portable .metallib that is committed
# as a bundled resource, so normal `swift build` / package_app.sh never need the
# Metal toolchain. Re-run this only when Matcap.metal changes.
#   Requires once: xcodebuild -downloadComponent MetalToolchain
set -euo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --show-sdk-path)"
INC="$SDK/System/Library/Frameworks/RealityKit.framework/Versions/A/Headers"
OUT="../../app/RefabArtist/Sources/RefabArtist/Resources/matcap.metallib"
xcrun metal -c Matcap.metal -o /tmp/neo_matcap.air -I"$INC"
xcrun metallib /tmp/neo_matcap.air -o "$OUT"
echo "wrote $OUT"
