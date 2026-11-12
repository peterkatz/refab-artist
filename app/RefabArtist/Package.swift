// swift-tools-version: 6.0

import PackageDescription

// Vendored Manifold (https://github.com/elalish/manifold, Apache-2.0) static
// libraries. Built from tag v3.5.1 for arm64/macOS15 — see
// Vendor/Manifold/README.md for the exact reproducible cmake invocation. The
// plain-C headers are co-located in Sources/CManifold/include/manifold so the
// CManifold module resolves them without extra include flags.
let manifoldLib = "Vendor/Manifold/lib"

// Linked into BOTH the executable and the test target (tests exercise the
// bridge directly). Order matters for static archives: manifoldc -> manifold
// -> Clipper2, then libc++ for the C++ runtime the archives were built against.
let manifoldLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L", manifoldLib,
        "-lmanifoldc",
        "-lmanifold",
        "-lClipper2",
        "-lc++",
    ])
]

let package = Package(
    name: "RefabArtist",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "RefabArtist", targets: ["RefabArtist"])
    ],
    targets: [
        .target(
            name: "CManifold",
            path: "Sources/CManifold"
        ),
        .executableTarget(
            name: "RefabArtist",
            dependencies: ["CManifold"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: manifoldLinkerSettings
        ),
        .testTarget(
            name: "RefabArtistTests",
            dependencies: ["RefabArtist", "CManifold"],
            linkerSettings: manifoldLinkerSettings
        )
    ]
)
