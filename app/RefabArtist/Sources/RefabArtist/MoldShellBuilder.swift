import Foundation

/// Turns the cavity surface into a genuinely HOLLOW closed wall: the cavity is
/// carved out of an outward-offset copy of the master. The complete intended
/// cast remains enclosed; a later stage adds one narrow sacrificial fill gate.
/// An exterior base slab of the configured thickness can be added (default OFF).
///
/// The inner face of the resulting shell is the cavity; the outer face is the
/// cavity offset outward by the wall thickness. The interior between them is
/// empty (a wall, not a solid blob).
///
/// Algorithm summary
/// -----------------
/// 1. Import the exact cavity into Manifold.
/// 2. Offset a simplified master once by cavity clearance plus wall thickness.
/// 3. Subtract the cavity from that outer solid. This exact Manifold boolean is
///    robust on concave and multi-loop cross-sections and uses no level set.
/// 4. Preserve the closed result. The legacy `openPlane` value is only a +Z
///    reference for later fill-gate placement.
/// 5. Optionally union an exterior base slab, then read the solid back.
enum MoldShellBuilder {
    // MARK: - Result

    /// Result of the shell stage plus the legacy fill-direction reference plane.
    struct ShellResult: Equatable {
        var solid: MeshGeometryData
        /// +Z reference plane used by later automatic fill-gate placement.
        var openPlane: PartitionPlane
        var diagnostics: [MoldDiagnostic]

        static let empty = ShellResult(
            solid: MeshGeometryData(vertices: [], triangleIndices: []),
            openPlane: PartitionPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: 0, isManual: false),
            diagnostics: []
        )
    }

    // MARK: - Private helpers

    /// Compute the axis-aligned bounding box directly from an array of vertices,
    /// avoiding the full `MeshPreflight.analyze` cost. Returns nil if empty.
    private static func bounds(of vertices: [Vec3]) -> Bounds3D? {
        guard let first = vertices.first else { return nil }
        var minV = first
        var maxV = first
        for v in vertices.dropFirst() {
            if v.x < minV.x { minV.x = v.x }
            if v.y < minV.y { minV.y = v.y }
            if v.z < minV.z { minV.z = v.z }
            if v.x > maxV.x { maxV.x = v.x }
            if v.y > maxV.y { maxV.y = v.y }
            if v.z > maxV.z { maxV.z = v.z }
        }
        return Bounds3D(min: minV, max: maxV)
    }

    private struct PourPlaneChoice {
        var plane: PartitionPlane
        var diagnostics: [MoldDiagnostic]
    }

    private static func choosePourPlane(
        cavity: MeshGeometryData,
        cavityBounds: Bounds3D,
        settings: MotherMoldSettings
    ) -> PourPlaneChoice {
        _ = cavity
        _ = settings
        return PourPlaneChoice(
            plane: PartitionPlane(
                normal: Vec3(x: 0, y: 0, z: 1),
                offset: cavityBounds.max.z,
                isManual: false
            ),
            diagnostics: []
        )
    }

    /// Build a flat floor slab to cap the bottom of the shell. The slab is a
    /// Manifold box (NOT a level-set) whose top face sits at `floorTopZ` and
    /// whose bottom face is `floorThickness` below it. The box is sized in X/Y
    /// to the full footprint of the outer shell plus a margin so it covers the
    /// entire base when intersected.
    ///
    /// Returns nil (no floor added) if any parameter is degenerate.
    private static func buildFloorSlab(
        shellBounds: Bounds3D,
        floorTopZ: Double,
        floorThickness: Double,
        margin: Double = 5.0
    ) throws -> ManifoldHandle? {
        guard floorThickness > 0, floorThickness.isFinite else { return nil }
        let xSpan = (shellBounds.max.x - shellBounds.min.x) + margin * 2
        let ySpan = (shellBounds.max.y - shellBounds.min.y) + margin * 2
        guard xSpan > 0, ySpan > 0 else { return nil }

        // Box centered at the slab mid-point.
        let cx = (shellBounds.min.x + shellBounds.max.x) / 2.0
        let cy = (shellBounds.min.y + shellBounds.max.y) / 2.0
        let cz = floorTopZ - floorThickness / 2.0

        let spec = ManifoldBoxSpec(
            center: Vec3(x: cx, y: cy, z: cz),
            extents: Vec3(x: xSpan, y: ySpan, z: floorThickness)
        )
        return try ManifoldEngine.box(spec)
    }

    // MARK: - Public API

    /// Build the walled shell from a cavity surface.
    ///
    /// - Parameters:
    ///   - cavity: cavity surface from `MoldCavityBuilder`.
    ///   - cavitySummary: a `MeshSummary` wrapping `cavity` (MeshModifier.thicken
    ///     operates on summaries); the caller supplies it to avoid re-inspecting.
    ///   - settings: wall thickness, floor toggle + thickness, subtype.
    static func buildShell(
        cavity: MeshGeometryData,
        master: MeshGeometryData,
        settings: MotherMoldSettings
    ) throws -> ShellResult {
        var diagnostics: [MoldDiagnostic] = []

        // Pour plane is referenced to the CAVITY (inner surface) top so the
        // opening sits at the top of the master, not the outer wall.
        guard let cavityBounds = bounds(of: cavity.vertices) else {
            throw MotherMoldPlannerError.shellFailed("Cavity has no vertices.")
        }
        let pourChoice = choosePourPlane(
            cavity: cavity,
            cavityBounds: cavityBounds,
            settings: settings
        )
        let pourPlane = pourChoice.plane
        diagnostics.append(contentsOf: pourChoice.diagnostics)
        let wall = max(0.1, settings.wallThickness)

        // Build the genuinely HOLLOW wall entirely in Manifold:
        //     outer = cavity ⊕ ball(wall)      (Minkowski outward offset)
        //     shell = outer − cavity            (Manifold boolean difference)
        // This is robust on CONCAVE / THIN masters (between fingers, ears, etc.)
        // where the old mitre-true vertex offset self-intersected and tore the
        // wall open (failing the watertight gate). The inner face of the shell is
        // the EXACT cavity (conformal for the slip shell); the outer face is the
        // cavity offset out by the wall, convex edges rounded to the wall radius.
        // NO marching cubes / NO level set.
        // Outer offset distance, measured from the MASTER. For the slip shell the
        // cavity IS the master, so the wall is just `wall`. For the silicone
        // jacket the cavity is master ⊕ ball(gap+smoothing), so the outer must be
        // master ⊕ ball(gap+smoothing+wall) for the wall to come out `wall` thick.
        let cavityOffset = (settings.subtype == .siliconeJacket)
            ? settings.siliconeGap + max(0, settings.smoothing)
            : 0
        let outerOffset = cavityOffset + wall

        let shellHandle: ManifoldHandle
        do {
            // Inner solid = the EXACT cavity (keeps the slip inner conformal).
            let cavityHandle = try ManifoldEngine.make(from: cavity)
            // Outer solid = the CLEAN master offset outward by the full distance
            // in a SINGLE Minkowski. Offsetting the master directly (rather than
            // re-offsetting the already-offset silicone cavity) avoids compounding
            // Minkowski artifacts into pinches/holes that tore the split parts.
            // The master needs no fine detail for the outer wall, so simplify it
            // first to keep the sum fast on dense masters.
            let masterHandle = try ManifoldEngine.make(from: master)
            let simplifyTolerance = max(0.25, outerOffset * 0.2)
            let reduced = (try? ManifoldEngine.simplify(masterHandle, tolerance: simplifyTolerance)) ?? masterHandle
            let ball = try ManifoldEngine.sphere(radius: outerOffset)
            let outerHandle = try ManifoldEngine.minkowskiSum(reduced, ball)
            shellHandle = try ManifoldEngine.difference(outerHandle, cavityHandle)
            withExtendedLifetime(cavityHandle) {}
            withExtendedLifetime(masterHandle) {}
            withExtendedLifetime(reduced) {}
            withExtendedLifetime(ball) {}
            withExtendedLifetime(outerHandle) {}
            if ManifoldEngine.isEmpty(shellHandle) {
                throw ManifoldEngineError.emptyResult
            }
        } catch {
            throw MotherMoldPlannerError.shellFailed(
                "Hollow-wall construction failed in Manifold (\(error)). "
                + "The master may be too thin for the requested wall thickness, or not a clean manifold."
            )
        }

        // Keep the complete cavity for both subtypes. Cutting the rigid shell at
        // an arbitrary plane truncates the intended casting. A later feature
        // stage adds a controlled sacrificial gate without changing the master.
        let completeShellHandle = shellHandle

        // 5. Optional floor cap.
        //    The floor is a solid box slab below the cavity's min-Z, unioned into
        //    the trimmed shell to seal the bottom. This is NOT a marching-cubes
        //    operation; it is a Manifold boolean union of two box primitives.
        var finalHandle = completeShellHandle
        if settings.floor && settings.floorThickness > 0 {
            // Outer bounds ≈ the cavity grown by the wall thickness (outer =
            // cavity ⊕ ball(wall)); the floor slab sits just below that.
            let outerBounds = Bounds3D(
                min: Vec3(x: cavityBounds.min.x - wall, y: cavityBounds.min.y - wall, z: cavityBounds.min.z - wall),
                max: Vec3(x: cavityBounds.max.x + wall, y: cavityBounds.max.y + wall, z: cavityBounds.max.z + wall)
            )
            do {
                if let floorHandle = try buildFloorSlab(
                    shellBounds: outerBounds,
                    floorTopZ: outerBounds.min.z,
                    floorThickness: settings.floorThickness
                ) {
                    let withFloor = try ManifoldEngine.union(finalHandle, floorHandle)
                    withExtendedLifetime(finalHandle) {}
                    withExtendedLifetime(floorHandle) {}
                    finalHandle = withFloor
                }
            } catch {
                diagnostics.append(MoldDiagnostic(
                    .warning,
                    "Floor cap could not be added (\(error)). The shell bottom will remain open."
                ))
            }
        }

        // 6. Extract the final solid from Manifold.
        let finalGeo: MeshGeometryData
        do {
            finalGeo = try ManifoldEngine.toMesh(finalHandle)
            withExtendedLifetime(finalHandle) {}
        } catch {
            withExtendedLifetime(finalHandle) {}
            throw MotherMoldPlannerError.shellFailed("Shell mesh extraction failed (\(error)).")
        }

        guard !finalGeo.vertices.isEmpty else {
            throw MotherMoldPlannerError.shellFailed(
                "Shell pipeline produced an empty mesh."
            )
        }

        return ShellResult(solid: finalGeo, openPlane: pourPlane, diagnostics: diagnostics)
    }
}
