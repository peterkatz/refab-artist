#!/usr/bin/env bash
# Reproducible build of the vendored Manifold static libraries.
#
# Produces (arm64 / macOS 15):
#   lib/libmanifoldc.a   - the plain-C API the Swift CManifold shim links against
#   lib/libmanifold.a    - the core C++ engine
#   lib/libClipper2.a    - 2D polygon backend (Boost license) required by the
#                          C bindings (CrossSection is mandatory for manifoldc in
#                          v3.5.1: bindings/CMakeLists.txt returns early without it)
#
# Re-run this script then re-copy the three archives + bindings/c headers into
# this directory (see README.md). It checks out an EXACT tag/commit so the .a
# artifacts are byte-reproducible against the recorded compiler.
set -euo pipefail

MANIFOLD_TAG="v3.5.1"
MANIFOLD_COMMIT="cc8a7f66d7d5a560da94346258c5b546af27811e"
# The Clipper2 commit that Manifold v3.5.1's cmake/manifoldDeps.cmake fetches
# (CLIPPER2_VERSION 2.0.1). THIRD_PARTY_NOTICES.md records it.
CLIPPER2_COMMIT="46f639177fe418f9689e8ddb74f08a870c71f5b4"

WORK="$(mktemp -d)"
echo "Building Manifold $MANIFOLD_TAG in $WORK"
cd "$WORK"

git clone --depth 1 --branch "$MANIFOLD_TAG" https://github.com/elalish/manifold
cd manifold
# Sanity-check the commit matches what we vendored.
test "$(git rev-parse HEAD)" = "$MANIFOLD_COMMIT" \
  || { echo "Commit mismatch! expected $MANIFOLD_COMMIT"; exit 1; }

# NOTE: MANIFOLD_CROSS_SECTION must be ON — the C bindings (manifoldc) require it
# in v3.5.1. MANIFOLD_DOWNLOADS=ON only fetches Clipper2 (Boost-licensed, static).
# MANIFOLD_PAR=OFF -> no TBB, single-threaded, fully self-contained static archive.
cmake -B build \
  -DBUILD_SHARED_LIBS=OFF \
  -DMANIFOLD_PAR=OFF \
  -DMANIFOLD_CROSS_SECTION=ON \
  -DMANIFOLD_CBIND=ON \
  -DMANIFOLD_TEST=OFF \
  -DMANIFOLD_PYBIND=OFF \
  -DMANIFOLD_JSBIND=OFF \
  -DMANIFOLD_DEBUG=OFF \
  -DMANIFOLD_DOWNLOADS=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0

cmake --build build -j"$(sysctl -n hw.ncpu)"

# libClipper2.a must come from the fetched commit, not from a Clipper2 that
# cmake found installed on this machine.
test "$(git -C build/_deps/clipper2-src rev-parse HEAD)" = "$CLIPPER2_COMMIT" \
  || { echo "Clipper2 commit mismatch! expected $CLIPPER2_COMMIT"; exit 1; }

echo
echo "Built archives:"
find build -name 'libmanifoldc.a' -o -name 'libmanifold.a' -o -name 'libClipper2.a'
echo
echo "Copy into this directory with:"
echo "  cp build/bindings/c/libmanifoldc.a build/src/libmanifold.a build/_deps/clipper2-build/libClipper2.a <vendor>/lib/"
echo "  cp bindings/c/include/manifold/manifoldc.h bindings/c/include/manifold/types.h <vendor>/include/manifold/"
echo "  (also copy the same two headers into Sources/CManifold/include/manifold/)"
