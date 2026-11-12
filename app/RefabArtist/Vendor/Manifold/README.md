# Vendored Manifold (static, arm64 / macOS 15)

This directory holds a checked-in **static** build of
[Manifold](https://github.com/elalish/manifold) (Apache-2.0) so the app links the
geometry engine with **no runtime dylib dependency** (verified by `otool -L`).
No cloud CI: the `.a` artifacts are committed, rebuilt locally via `build.sh`.

## Source

| | |
|---|---|
| Repo | https://github.com/elalish/manifold |
| Tag | `v3.5.1` |
| Commit | `cc8a7f66d7d5a560da94346258c5b546af27811e` |
| License | Apache-2.0 (see `LICENSE-Manifold`) |
| Clipper2 | commit `46f639177fe418f9689e8ddb74f08a870c71f5b4` (`CLIPPER2_VERSION` 2.0.1), fetched by the Manifold build; Boost Software License 1.0 (see `LICENSE-Clipper2`) |
| Built for | `arm64`, `-mmacosx-version-min=15.0` |
| Toolchain | Apple clang 21.0.0 (Xcode), cmake 4.2.3 |

## Exact build invocation

See `build.sh`. Key cmake flags:

```
-DBUILD_SHARED_LIBS=OFF -DMANIFOLD_PAR=OFF -DMANIFOLD_CROSS_SECTION=ON
-DMANIFOLD_CBIND=ON -DMANIFOLD_TEST=OFF -DMANIFOLD_PYBIND=OFF -DMANIFOLD_JSBIND=OFF
-DMANIFOLD_DEBUG=OFF -DMANIFOLD_DOWNLOADS=ON -DCMAKE_BUILD_TYPE=Release
-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
```

### Why these differ from the original plan

The plan (docs/plan-structures-rebuild.md §1b) proposed
`-DMANIFOLD_CROSS_SECTION=OFF -DMANIFOLD_DOWNLOADS=OFF`. In Manifold **v3.5.1**
the plain-C bindings *require* CrossSection: `bindings/CMakeLists.txt` does
`if(NOT MANIFOLD_CROSS_SECTION) return()` and `bindings/c` compiles `cross.cpp` /
`rect.cpp`. So CrossSection is ON, which pulls **Clipper2** (Boost license —
permissive, compatible). `MANIFOLD_DOWNLOADS=ON` is therefore needed solely to
fetch Clipper2, which is built **static** and vendored here as `libClipper2.a`.
`MANIFOLD_PAR=OFF` keeps TBB out entirely, so the archive set is self-contained.

## Contents

```
lib/libmanifoldc.a   plain-C API (manifoldc) — primary link target
lib/libmanifold.a    core C++ engine
lib/libClipper2.a    2D polygon backend (Boost license)
include/manifold/    manifoldc.h, types.h (the plain-C headers)
LICENSE-Manifold     upstream Apache-2.0 license
LICENSE-Clipper2     Clipper2's Boost Software License 1.0
build.sh             reproducible rebuild script
```

The same two C headers are also copied into
`../../Sources/CManifold/include/manifold/` so the `CManifold` SwiftPM module
resolves `#include "manifold/manifoldc.h"` without extra include flags.

## How it is linked

`Package.swift` adds a C shim target `CManifold` (umbrella header over
`manifoldc.h`) and passes linker flags to the executable + test targets:

```
-L Vendor/Manifold/lib -lmanifoldc -lmanifold -lClipper2 -lc++
```

Archive order matters: `manifoldc` → `manifold` → `Clipper2`, then system
`libc++` for the C++ runtime. Swift stays in **default mode** (no C++ interop).

## Memory-management note (load-bearing)

The C constructors (e.g. `manifold_cube`, `manifold_intersection`) **placement-new**
their result into a caller-provided `mem` arena. The matching teardown is
`manifold_destruct_*` (destructor only) + freeing the arena yourself — **not**
`manifold_delete_*`, which calls `delete` (free) on the pointer and aborts with
"pointer being freed was not allocated" when the arena came from Swift's
allocator. `ManifoldEngine.swift` follows the destruct + deallocate pairing.
