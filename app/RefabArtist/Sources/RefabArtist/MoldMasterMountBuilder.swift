import Foundation

/// Builds the jacket-only fixture that keeps a physical master located while
/// silicone is poured. The default is a shallow negative socket at the master's
/// downward-facing base, joined to the rigid shell before partitioning so every
/// resulting piece receives the correct share of the fixture.
enum MoldMasterMountBuilder {
    struct Summary: Equatable {
        var mode: MasterMountMode?
        var isResolved: Bool
        var contactAreaMM2: Double
        var socketDepthMM: Double
        var fitClearanceMM: Double
        var sealLandWidthMM: Double
        var requiresSealant: Bool = false
        var locatorVolumeMM3: Double = 0
        var finalLocatorRetention: Double?

        static let notApplicable = Summary(
            mode: nil,
            isResolved: true,
            contactAreaMM2: 0,
            socketDepthMM: 0,
            fitClearanceMM: 0,
            sealLandWidthMM: 0,
            requiresSealant: false,
            locatorVolumeMM3: 0,
            finalLocatorRetention: nil
        )
    }

    struct Result: Equatable {
        var solid: MeshGeometryData
        /// Material added outside the original shell solely to locate the master.
        /// The planner intersects this with final parts so later stages cannot
        /// silently erase the fixture.
        var locatorGeometry: MeshGeometryData?
        var summary: Summary
        var diagnostics: [MoldDiagnostic]
    }

    static func requiresMount(for settings: MotherMoldSettings) -> Bool {
        settings.subtype == .siliconeJacket
    }

    static func apply(
        shell: MeshGeometryData,
        master: MeshGeometryData,
        settings rawSettings: MotherMoldSettings
    ) -> Result {
        let settings = rawSettings.sanitized
        guard requiresMount(for: settings) else {
            return Result(solid: shell, locatorGeometry: nil, summary: .notApplicable, diagnostics: [])
        }

        let mount = settings.masterMount
        if mount.mode == .externalFixture {
            return Result(
                solid: shell,
                locatorGeometry: nil,
                summary: Summary(
                    mode: .externalFixture,
                    isResolved: true,
                    contactAreaMM2: 0,
                    socketDepthMM: 0,
                    fitClearanceMM: 0,
                    sealLandWidthMM: 0,
                    requiresSealant: true,
                    locatorVolumeMM3: 0,
                    finalLocatorRetention: nil
                ),
                diagnostics: [MoldDiagnostic(
                    .warning,
                    "External master fixture selected. The printed mold does not locate the master; secure and seal the physical master with a stem, suspension, or custom base fixture before pouring silicone."
                )]
            )
        }

        guard let masterBounds = bounds(of: master.vertices) else {
            return unresolved(
                shell: shell,
                mount: mount,
                message: "A master base socket could not be built because the master has no vertices."
            )
        }

        let depth = min(mount.socketDepth, max(1, masterBounds.max.z - masterBounds.min.z))
        let baseLimit = masterBounds.min.z + depth
        let basePoints = master.vertices
            .filter { $0.z <= baseLimit + 1.0e-6 }
            .map { Vec2(x: $0.x, y: $0.y) }
        let hull = MoldFlangeBuilder.convexHull2D(basePoints)
        let contactArea = abs(MoldFlangeBuilder.polygonArea(hull))
        guard hull.count >= 3,
              let minX = hull.map(\.x).min(), let maxX = hull.map(\.x).max(),
              let minY = hull.map(\.y).min(), let maxY = hull.map(\.y).max() else {
            return unresolved(
                shell: shell,
                mount: mount,
                message: "The downward-facing master footprint is too small for a stable socket. Reorient the intended mounting face downward or choose External fixture."
            )
        }

        let masterSpan = max(
            masterBounds.max.x - masterBounds.min.x,
            masterBounds.max.y - masterBounds.min.y
        )
        let footprintX = maxX - minX
        let footprintY = maxY - minY
        let equivalentDiameter = contactArea > 0
            ? 2 * (contactArea / Double.pi).squareRoot()
            : 0
        let requiredSpan = max(4, masterSpan * 0.08)
        let requiredDiameter = max(6, masterSpan * 0.12)
        guard footprintX >= requiredSpan,
              footprintY >= requiredSpan,
              equivalentDiameter >= requiredDiameter else {
            return unresolved(
                shell: shell,
                mount: mount,
                message: String(
                    format: "The proposed master socket is unstable (%.1f x %.1f mm footprint, %.1f mm equivalent diameter). Reorient a broader mounting face downward, increase socket depth, or choose External fixture.",
                    footprintX,
                    footprintY,
                    equivalentDiameter
                ),
                contactArea: contactArea
            )
        }

        let sealLand = max(3, settings.siliconeGap + settings.wallThickness)
        let blockMinZ = masterBounds.min.z - settings.siliconeGap - settings.wallThickness - 1
        let blockMaxZ = baseLimit
        let xSpan = footprintX + sealLand * 2
        let ySpan = footprintY + sealLand * 2
        guard xSpan > 0, ySpan > 0, blockMaxZ > blockMinZ else {
            return unresolved(
                shell: shell,
                mount: mount,
                message: "The generated master socket dimensions are degenerate."
            )
        }

        do {
            let block = try ManifoldEngine.box(ManifoldBoxSpec(
                center: Vec3(
                    x: (minX + maxX) / 2,
                    y: (minY + maxY) / 2,
                    z: (blockMinZ + blockMaxZ) / 2
                ),
                extents: Vec3(x: xSpan, y: ySpan, z: blockMaxZ - blockMinZ)
            ))
            let masterHandle = try ManifoldEngine.make(from: master)
            let socketTool: ManifoldHandle
            if mount.fitClearance > 1.0e-6 {
                let reduced = (try? ManifoldEngine.simplify(
                    masterHandle,
                    tolerance: max(0.1, mount.fitClearance * 0.5)
                )) ?? masterHandle
                let clearanceBall = try ManifoldEngine.sphere(radius: mount.fitClearance)
                socketTool = try ManifoldEngine.minkowskiSum(reduced, clearanceBall)
                withExtendedLifetime(reduced) {}
                withExtendedLifetime(clearanceBall) {}
            } else {
                socketTool = masterHandle
            }
            let socket = try ManifoldEngine.difference(block, socketTool)
            let shellHandle = try ManifoldEngine.make(from: shell)
            let overlap = try ManifoldEngine.intersect(shellHandle, socket)
            let overlapVolume = abs(ManifoldEngine.volume(overlap))
            let shellVolume = abs(ManifoldEngine.volume(shellHandle))
            let minimumOverlap = max(1.0e-5, shellVolume * 1.0e-9)
            guard overlapVolume > minimumOverlap else {
                withExtendedLifetime(overlap) {}
                return unresolved(
                    shell: shell,
                    mount: mount,
                    message: "The generated master socket does not reach the rigid shell (measured overlap \(String(format: "%.6f", overlapVolume)) mm^3). Increase socket depth, reorient the base, or choose External fixture.",
                    contactArea: contactArea
                )
            }
            let addedLocator = try ManifoldEngine.difference(socket, shellHandle)
            let locatorVolume = abs(ManifoldEngine.volume(addedLocator))
            guard locatorVolume > minimumOverlap else {
                withExtendedLifetime(overlap) {}
                withExtendedLifetime(addedLocator) {}
                return unresolved(
                    shell: shell,
                    mount: mount,
                    message: "The generated socket touched the shell but added no usable locating material. Increase socket depth, reorient the base, or choose External fixture.",
                    contactArea: contactArea
                )
            }
            let locatorGeometry = try ManifoldEngine.toMesh(addedLocator)
            let mounted = try ManifoldEngine.union(shellHandle, socket)
            let rawGeometry = try ManifoldEngine.toMesh(mounted)
            // Keep the original Manifold readback unless a repair clears the
            // actual printable gate. A merely lower defect count can destroy
            // recoverable topology and make later partitioning less reliable.
            var geometry = rawGeometry
            var preflight = MotherMoldValidation.printablePreflight(geometry)
            if !preflight.isWatertight {
                // Organic tangent contacts can make Manifold emit microscopic
                // zero-area triangles. Collapse only sub-micron features; this is
                // five orders of magnitude below normal print resolution.
                for tolerance in [1.0e-6, 1.0e-5, 1.0e-4] {
                    guard let simplified = try? ManifoldEngine.simplify(
                        mounted,
                        tolerance: tolerance
                    ), let simplifiedMesh = try? ManifoldEngine.toMesh(simplified) else {
                        continue
                    }
                    let candidates = [simplifiedMesh, MoldMeshSealer.seal(simplifiedMesh)]
                    withExtendedLifetime(simplified) {}
                    if let accepted = candidates.first(where: {
                        MotherMoldValidation.printablePreflight($0).isWatertight
                    }) {
                        geometry = accepted
                        preflight = MotherMoldValidation.printablePreflight(accepted)
                    }
                    if preflight.isWatertight { break }
                }
            }
            withExtendedLifetime(block) {}
            withExtendedLifetime(masterHandle) {}
            withExtendedLifetime(socketTool) {}
            withExtendedLifetime(socket) {}
            withExtendedLifetime(shellHandle) {}
            withExtendedLifetime(overlap) {}
            withExtendedLifetime(addedLocator) {}
            withExtendedLifetime(mounted) {}

            guard !geometry.vertices.isEmpty else {
                return unresolved(
                    shell: shell,
                    mount: mount,
                    message: "The generated master socket became empty. Reorient the base or choose External fixture.",
                    contactArea: contactArea
                )
            }

            var mountDiagnostics: [MoldDiagnostic] = []
            if !preflight.isWatertight {
                // This is an intermediate mesh extracted from a valid Manifold
                // solid. Splitting, flange/key booleans, sealing, and the final
                // per-part gate still run afterward. Let those final exported
                // parts decide printability instead of discarding a connected
                // fixture because of microscopic extraction slivers here.
                mountDiagnostics.append(MoldDiagnostic(
                    .info,
                    "The connected master socket will receive final printability validation after the mold is split."
                ))
            }
            mountDiagnostics.append(MoldDiagnostic(
                .info,
                String(
                    format: "Master located by a %.1f mm-deep generated base socket (%.1f mm^2 footprint, %.2f mm fit clearance, %.1f mm seal land). Apply compatible clay or reusable sealant around the land before pouring.",
                    depth,
                    contactArea,
                    mount.fitClearance,
                    sealLand
                )
            ))
            return Result(
                solid: geometry,
                locatorGeometry: locatorGeometry,
                summary: Summary(
                    mode: .flatBaseSocket,
                    isResolved: true,
                    contactAreaMM2: contactArea,
                    socketDepthMM: depth,
                    fitClearanceMM: mount.fitClearance,
                    sealLandWidthMM: sealLand,
                    requiresSealant: true,
                    locatorVolumeMM3: locatorVolume,
                    finalLocatorRetention: nil
                ),
                diagnostics: mountDiagnostics
            )
        } catch {
            return unresolved(
                shell: shell,
                mount: mount,
                message: "The master base socket could not be generated (\(error)). Reorient the base or choose External fixture.",
                contactArea: contactArea
            )
        }
    }

    private static func unresolved(
        shell: MeshGeometryData,
        mount: MasterMountSettings,
        message: String,
        contactArea: Double = 0
    ) -> Result {
        Result(
            solid: shell,
            locatorGeometry: nil,
            summary: Summary(
                mode: mount.mode,
                isResolved: false,
                contactAreaMM2: contactArea,
                socketDepthMM: mount.socketDepth,
                fitClearanceMM: mount.fitClearance,
                sealLandWidthMM: 0,
                requiresSealant: true,
                locatorVolumeMM3: 0,
                finalLocatorRetention: nil
            ),
            diagnostics: [MoldDiagnostic(.error, message)]
        )
    }

    private static func bounds(of vertices: [Vec3]) -> Bounds3D? {
        guard var minValue = vertices.first else { return nil }
        var maxValue = minValue
        for vertex in vertices.dropFirst() {
            minValue.x = min(minValue.x, vertex.x)
            minValue.y = min(minValue.y, vertex.y)
            minValue.z = min(minValue.z, vertex.z)
            maxValue.x = max(maxValue.x, vertex.x)
            maxValue.y = max(maxValue.y, vertex.y)
            maxValue.z = max(maxValue.z, vertex.z)
        }
        return Bounds3D(min: minValue, max: maxValue)
    }
}
