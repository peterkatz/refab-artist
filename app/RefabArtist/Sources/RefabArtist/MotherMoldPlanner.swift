import Foundation

/// Human-readable milestones emitted by the planner without exposing a fake
/// percentage. The order is a UI and test contract; append only with an
/// explicit product migration.
enum MoldBuildStage: Int, CaseIterable, Sendable {
    case preparingMaster = 1
    case buildingCavity
    case buildingShell
    case splitting
    case keysAndRim
    case pourHoleAndVents
    case checkingWatertightness
    case packaging

    var ordinal: Int { rawValue }

    var label: String {
        switch self {
        case .preparingMaster: return "Preparing master"
        case .buildingCavity: return "Building cavity"
        case .buildingShell: return "Building shell"
        case .splitting: return "Splitting"
        case .keysAndRim: return "Keys & rim"
        case .pourHoleAndVents: return "Pour hole & vents"
        case .checkingWatertightness: return "Checking watertightness"
        case .packaging: return "Packaging"
        }
    }
}

enum MotherMoldBuildProgressPresentation {
    static func elapsedText(seconds: TimeInterval) -> String {
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let wholeSeconds = Int(safeSeconds.rounded(.down))
        return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }

    static func statusLine(stage: MoldBuildStage, elapsedSeconds: TimeInterval) -> String {
        "\(stage.label)… \(stage.ordinal) of \(MoldBuildStage.allCases.count) · \(elapsedText(seconds: elapsedSeconds)) elapsed"
    }
}

// MARK: - Shared result types

/// One generated mold part: its geometry plus identity for export and preview.
struct MotherMoldPart: Equatable {
    /// Stable, export-friendly name, e.g. "mold-part-A". Used as the STL solid
    /// name / OBJ object name and the assembly-map label.
    var name: String
    /// The watertight (target) part solid.
    var geometry: MeshGeometryData
    /// Per-part watertightness as reported by `MoldValidation`.
    var isWatertight: Bool
    /// Tight axis-aligned bounds of `geometry`, nil if empty.
    var bounds: Bounds3D?

    init(name: String, geometry: MeshGeometryData, isWatertight: Bool = false, bounds: Bounds3D? = nil) {
        self.name = name
        self.geometry = geometry
        self.isWatertight = isWatertight
        self.bounds = bounds
    }
}

/// Severity of a planner diagnostic.
enum MoldDiagnosticSeverity: String, Equatable, Sendable {
    case info
    case warning
    case error
}

/// Stable routing metadata for Build Status. UI actions must use this value,
/// never search localized message text for words such as "key" or "socket".
enum MoldDiagnosticSubsystem: String, Equatable, Sendable {
    case source
    case cavity
    case shell
    case parting
    case flange
    case shellRegistration
    case masterPreparation
    case holdDown
    case linerRegistration
    case linerFill
    case productionCasting
    case support
    case package
    case physicalQualification
    case legacy
}

struct MoldDiagnosticCode: RawRepresentable, Equatable, Hashable, Sendable {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let legacyMessage = MoldDiagnosticCode(rawValue: "legacy.message")
    static let toolingIncomplete = MoldDiagnosticCode(rawValue: "tooling.incomplete")
    static let modificationApprovalRequired = MoldDiagnosticCode(rawValue: "master.modificationApprovalRequired")
    static let externalFixtureEvidenceRequired = MoldDiagnosticCode(rawValue: "holdDown.externalEvidenceRequired")
    static let physicalEvidenceRequired = MoldDiagnosticCode(rawValue: "qualification.physicalEvidenceRequired")
}

enum MoldRecoveryAction: String, Equatable, Sendable {
    case makeWatertight
    case rebuild
    case inspectPreparedMaster
    case approveModifications
    case choosePreparedPost
    case defineExternalFixture
    case adjustParting
    case adjustLinerRegistration
    case reorientLinerFill
    case reorientCasting
    case adjustProductionGate
    case adjustProductionVents
    case selectPrinterProfile
    case sendToPartition
    case reviewAssemblyGuide
}

/// A single human-facing message from the pipeline (undercut report, unkeyable
/// seam, non-watertight part, non-watertight master, etc.).
struct MoldDiagnostic: Equatable {
    var severity: MoldDiagnosticSeverity
    var message: String
    var subsystem: MoldDiagnosticSubsystem
    var code: MoldDiagnosticCode
    var recoveryActions: [MoldRecoveryAction]

    init(
        _ severity: MoldDiagnosticSeverity,
        _ message: String,
        subsystem: MoldDiagnosticSubsystem = .legacy,
        code: MoldDiagnosticCode = .legacyMessage,
        recoveryActions: [MoldRecoveryAction] = []
    ) {
        self.severity = severity
        self.message = message
        self.subsystem = subsystem
        self.code = code
        self.recoveryActions = recoveryActions
    }
}

/// Deterministic output of one MotherMold build. Holds the per-part geometry,
/// the parting planes actually used (auto-resolved or manual), diagnostics for
/// the Fit/Warnings panel, and the settings + master fingerprint the plan was
/// built from (for staleness checks).
struct MotherMoldPlan: Equatable {
    var parts: [MotherMoldPart]
    /// Parting planes actually used (after auto-resolution).
    var partingPlanes: [PartitionPlane]
    /// The cavity surface used (subtype-aware); kept for preview/validation.
    var cavity: MeshGeometryData
    /// Master shown semi-transparent in the preview.
    var master: MeshGeometryData
    var diagnostics: [MoldDiagnostic]
    /// Final outward pull direction for each part, parallel to `parts`. Used by
    /// inspection views and retained independently of viewport state.
    var demoldAxes: [Vec3] = []
    /// Measured undercut regions retained for visual inspection.
    var undercutReports: [MoldUndercutAnalyzer.PartUndercutReport] = []
    /// How the physical master is held for a silicone-jacket pour.
    var masterMount: MoldMasterMountBuilder.Summary = .notApplicable
    /// Physical mating interfaces that actually received clamping flange plates.
    var flangedSeamCount: Int = 0
    /// Number of part-side flange plates that are present in the final plan.
    var flangePlatesPlaced: Int = 0
    /// Number of bolt bores that removed plate material and survived validation.
    var effectiveBoltHoleCount: Int = 0
    /// Number of mating registration-key pairs actually added to the parts.
    var registrationKeysPlaced: Int = 0
    /// Final measured key locations that survived every later geometry stage.
    var registrationKeySites: [MoldKeyBuilder.RegistrationKeySite] = []
    /// True when the spout bore actually pierced at least one part.
    var spoutBored: Bool = false
    /// Vents whose bore pierced at least one part.
    var ventsBoredCount: Int = 0
    /// Estimated silicone volume in cubic centimeters for silicone-jacket builds.
    var estimatedSiliconeCC: Double? = nil
    /// Estimated printed rigid-plastic volume in cubic centimeters.
    var printedPlasticCC: Double = 0

    // MARK: Reusable tooling contract

    /// Contract version used to build this plan. Version 2 plans remain valid
    /// legacy shell exports; version 3 plans require the manufacturing package.
    var toolingContractVersion: Int = 2
    /// Packaging requested when the plan was generated. This is evidence for
    /// status/export validation, not a replacement for the current UI setting.
    var requestedPackaging: MoldPackaging = .separateZip
    /// Seed copied from sanitized settings so package generation is reproducible.
    var deterministicSeed: Int = 0
    /// Original source location retained only for provenance/reference copying.
    /// The geometry in `master` remains the immutable active planning source.
    var sourceModelPath: String? = nil
    var sourceModelFormat: String? = nil
    var sourceModelByteCount: Int? = nil
    var includeReferenceMeshes: Bool = false
    var manufacturingProfile: ToolingManufacturingProfileRef? = nil
    /// Derived positive that the artist actually prints and uses. It is never
    /// inserted into `parts`, which remains rigid-shell geometry only.
    var preparedMaster: ToolingArtifact? = nil
    /// Yokes, funnels, vent formers, and other non-shell manufacturing tools.
    var fixtureArtifacts: [ToolingArtifact] = []
    /// Phase-specific stands or cradles, kept separate for package and preview.
    var supportArtifacts: [ToolingArtifact] = []
    /// Shop-supplied hardware and consumables, kept separate from printable
    /// tooling artifacts so they cannot enter the STL inventory.
    var hardwareItems: [ToolingHardwareItem] = []
    /// Exact reference-only liner states. These are inspectable but not printable.
    var asPouredLiner: ToolingArtifact? = nil
    var productionLiner: ToolingArtifact? = nil
    /// Every intentional difference between the active and prepared positives.
    var masterModificationRegions: [MasterModificationRegion] = []
    var masterPreparation: MasterPreparationSummary = .notApplicable
    var holdDownWrenchEnvelope: HoldDownWrenchEnvelope = .notApplicable
    var linerRegistration: LinerRegistrationSummary = .notApplicable
    var linerFillPath: MoldFlowPathSummary = .notApplicable(phase: .linerFill)
    var productionCastingPath: MoldFlowPathSummary = .notApplicable(phase: .casting)
    var productionCastingVents: [MoldFlowPathSummary] = []
    var linerFillSupport: ToolingSupportSummary = .notApplicable(phase: .linerFill)
    var castingSupport: ToolingSupportSummary = .notApplicable(phase: .casting)
    /// Populated from a validated serialization result when the caller needs to
    /// present the exact package inventory. Planned geometry alone never fills
    /// hashes or byte counts.
    var packageMembers: [PackageMember] = []
    /// Single readiness summary consumed by UI, headless measurements, and the
    /// authoritative package writer. Physical qualification remains explicit.
    var toolingExportContract: MotherMoldToolingContract = .notApplicable

    static let empty = MotherMoldPlan(
        parts: [],
        partingPlanes: [],
        cavity: MeshGeometryData(vertices: [], triangleIndices: []),
        master: MeshGeometryData(vertices: [], triangleIndices: []),
        diagnostics: []
    )

    /// Convenience for export: one export layer per part.
    var exportLayers: [SliceMeshExportLayer] {
        parts.map {
            SliceMeshExportLayer(
                name: $0.name,
                mesh: ViewportMeshRenderData.flatShadedMesh(from: $0.geometry)
            )
        }
    }

    /// The source accepted by the planner. The compatibility name `master` is
    /// retained while v3 call sites migrate to the explicit product language.
    var activeSourceMaster: MeshGeometryData {
        get { master }
        set { master = newValue }
    }

    var manufacturingToolingArtifacts: [ToolingArtifact] {
        (preparedMaster.map { [$0] } ?? []) + fixtureArtifacts + supportArtifacts
    }

    var referenceToolingArtifacts: [ToolingArtifact] {
        [asPouredLiner, productionLiner].compactMap { $0 }
    }
}

/// Errors that abort the whole build (vs. per-part diagnostics that don't).
enum MotherMoldPlannerError: LocalizedError, Equatable {
    case cancelled
    case masterNotWatertight
    case masterNotWatertightDetails(String)
    case emptyMaster
    case cavityFailed(String)
    case shellFailed(String)
    case partitionFailed(String)
    case incorrectPartCount(requested: Int, produced: Int)
    case disconnectedParts([String])
    case partsNotWatertight([String])

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Build cancelled."
        case .masterNotWatertight:
            return "The master mesh is not watertight. MotherMold requires a watertight master; repair it before building a mold."
        case .masterNotWatertightDetails(let message):
            return message
        case .emptyMaster:
            return "The master mesh is empty."
        case .cavityFailed(let m): return "Cavity stage failed: \(m)"
        case .shellFailed(let m): return "Shell stage failed: \(m)"
        case .partitionFailed(let m): return "Partition stage failed: \(m)"
        case .incorrectPartCount(let requested, let produced):
            return "MotherMold requested \(requested) printable parts but partitioning produced \(produced). The build was blocked instead of exporting a whole-shell fallback."
        case .disconnectedParts(let names):
            return "MotherMold produced disconnected geometry inside part(s): \(names.joined(separator: ", ")). Each mold part must be one printable solid."
        case .partsNotWatertight(let names):
            let list = names.joined(separator: ", ")
            return "MotherMold produced non-watertight part(s): \(list). Every exported part must be watertight; the build was blocked. This usually means the master has features finer than the wall thickness, so the offset self-intersects — try a thinner wall, fewer parts, a simpler master, or the silicone-jacket subtype (which smooths fine detail)."
        }
    }
}

// MARK: - Planner

/// Orchestrates the full MotherMold pipeline, in order:
/// 1. watertight gate (MeshPreflight — never auto-heals)
/// 2. cavity surface (MoldCavityBuilder)
/// 3. shell thicken + open + floor (MoldShellBuilder)
/// 4. parting-plane resolution + split (MoldPartitioner)
/// 5. undercut analysis (MoldUndercutAnalyzer)
/// 6. flanges + bolt holes (MoldFlangeBuilder)
/// 7. spout + vents (MoldFeatureBuilder)
/// 8. registration keys on the finished, bored flanges (MoldKeyBuilder)
/// 9. per-part validation (MoldValidation)
///
/// Deterministic from `settings.seed`. Runs off the main thread (the caller
/// wraps `planThrowing` in a detached Task, mirroring `generateStructure`).
enum MotherMoldPlanner {
    /// Stage 1 — the master watertight gate, judged on `model.preflight` (in
    /// the GUI that is the truthful, unit-independent report of the imported
    /// model; headless it is the raw import preflight). Throws when the master
    /// is empty, open, or closed but not a solid Manifold accepts; returns the
    /// info diagnostic of a closed master accepted through Manifold validation.
    static func validateMaster(_ model: MeshSummary) throws -> [MoldDiagnostic] {
        var allDiagnostics: [MoldDiagnostic] = []
        guard !model.geometry.vertices.isEmpty,
              !model.geometry.triangleIndices.isEmpty else {
            throw MotherMoldPlannerError.emptyMaster
        }
        if !model.preflight.isWatertight {
            let pf = model.preflight
            if pf.boundaryEdgeCount == 0 {
                do {
                    let validated = try ManifoldEngine.make(from: model.geometry)
                    withExtendedLifetime(validated) {}
                    allDiagnostics.append(MoldDiagnostic(
                        .info,
                        "Master accepted via Manifold validation (\(pf.nonManifoldEdgeCount) residual self-contact edge\(pf.nonManifoldEdgeCount == 1 ? "" : "s"))."
                    ))
                } catch {
                    throw MotherMoldPlannerError.masterNotWatertightDetails(
                        "The master mesh is closed but Manifold could not validate it as a solid "
                        + "(boundary edges: \(pf.boundaryEdgeCount), non-manifold edges: \(pf.nonManifoldEdgeCount), "
                        + "degenerate triangles: \(pf.degenerateTriangleCount), invalid references: \(pf.invalidTriangleReferenceCount)). "
                        + "Run Make Watertight before building a mold. Manifold error: \(error)."
                    )
                }
            } else {
                throw MotherMoldPlannerError.masterNotWatertightDetails(
                    "The master mesh is not closed enough for MotherMold "
                    + "(boundary edges: \(pf.boundaryEdgeCount), non-manifold edges: \(pf.nonManifoldEdgeCount), "
                    + "degenerate triangles: \(pf.degenerateTriangleCount), invalid references: \(pf.invalidTriangleReferenceCount)). "
                    + "Run Make Watertight before building a mold."
                )
            }
        }
        return allDiagnostics
    }

    /// Throwing entry point used by the GUI Generate action and headless export.
    /// `settings` is sanitized internally. Returns a deterministic plan.
    static func planThrowing(
        model: MeshSummary,
        settings rawSettings: MotherMoldSettings,
        progress: (@Sendable (MoldBuildStage) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> MotherMoldPlan {
        try beginStage(.preparingMaster, progress: progress, isCancelled: isCancelled)
        let settings = rawSettings.sanitized

        var allDiagnostics: [MoldDiagnostic] = []

        // Stage 1 — watertight gate. Never auto-heal (MeshHealer uses MC), but
        // accept closed healer-grade masters that Manifold can validate as a
        // solid. Imported healed scans can carry residual self-contact edge
        // counts even though the surface is closed; refusing them here made the
        // Make Watertight flow unusable for MotherMold.
        allDiagnostics += try validateMaster(model)
        let masterGeometry = model.geometry

        // Reusable v3 tooling has a different physical sequence from the
        // legacy rigid/silicone shell path. Keep the latter intact rather than
        // allowing its mount and spout stages to leak into the v3 contract.
        if settings.usesReusableToolingContract {
            return try planReusableTooling(
                model: model,
                settings: settings,
                immutableSource: masterGeometry,
                sourceDiagnostics: allDiagnostics,
                progress: progress,
                isCancelled: isCancelled
            )
        }

        // Stage 2 — cavity surface.
        try beginStage(.buildingCavity, progress: progress, isCancelled: isCancelled)
        let cavity: MeshGeometryData
        do {
            cavity = try MoldCavityBuilder.buildCavity(
                master: masterGeometry,
                settings: settings
            )
        } catch {
            throw MotherMoldPlannerError.cavityFailed(
                (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }

        // Stage 3 — shell (Manifold offset wall + open + optional floor).
        try beginStage(.buildingShell, progress: progress, isCancelled: isCancelled)
        let shellResult: MoldShellBuilder.ShellResult
        do {
            shellResult = try MoldShellBuilder.buildShell(
                cavity: cavity,
                master: masterGeometry,
                settings: settings
            )
        } catch {
            throw MotherMoldPlannerError.shellFailed(
                (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
        allDiagnostics.append(contentsOf: shellResult.diagnostics)

        // Stage 3.5 — locate the physical master for a silicone pour. The
        // generated land is a place for the artist to apply a liquid seal; fit
        // clearance alone is deliberately never described as watertight.
        // Rigid-negative/slip-shell builds do not contain a master during casting.
        let masterMountResult = MoldMasterMountBuilder.apply(
            shell: shellResult.solid,
            master: masterGeometry,
            settings: settings
        )
        allDiagnostics.append(contentsOf: masterMountResult.diagnostics)

        if settings.parting.mode == .manual,
           settings.parting.planes.count != settings.parts.planeCount {
            throw MotherMoldPlannerError.partitionFailed(
                "Manual parting requires exactly \(settings.parts.planeCount) plane(s), but \(settings.parting.planes.count) were supplied. The build was blocked before partitioning instead of falling back to Auto."
            )
        }

        // Stage 4 — parting-plane resolution + split.
        try beginStage(.splitting, progress: progress, isCancelled: isCancelled)
        let planes = MoldPartitioner.resolvePlanes(
            shell: masterMountResult.solid,
            reference: cavity,
            settings: settings
        )
        var partitionResult: MoldPartitioner.PartitionResult
        do {
            partitionResult = try MoldPartitioner.partition(
                shell: masterMountResult.solid,
                planes: planes,
                settings: settings
            )
        } catch {
            throw MotherMoldPlannerError.partitionFailed(
                (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
        let requestedPartCount = 1 << settings.parts.planeCount
        if settings.parting.mode == .auto,
           partitionResult.parts.count == requestedPartCount {
            let initialResult = partitionResult
            var bestResult = partitionResult
            var bestScore = autoPartingScore(
                result: partitionResult,
                cavity: cavity,
                openPlane: shellResult.openPlane,
                settings: settings
            )
            var evaluatedCount = 1
            for candidatePlanes in primaryPartingPlaneCandidates(
                reference: cavity,
                planeCount: settings.parts.planeCount
            ) where candidatePlanes != partitionResult.planes {
                guard let candidate = try? MoldPartitioner.partition(
                    shell: masterMountResult.solid,
                    planes: candidatePlanes,
                    settings: settings
                ), candidate.parts.count == requestedPartCount else {
                    continue
                }
                evaluatedCount += 1
                let score = autoPartingScore(
                    result: candidate,
                    cavity: cavity,
                    openPlane: shellResult.openPlane,
                    settings: settings
                )
                if autoPartingScore(score, isBetterThan: bestScore) {
                    bestResult = candidate
                    bestScore = score
                }
            }
            if bestResult.planes != initialResult.planes {
                allDiagnostics.append(MoldDiagnostic(
                    .info,
                    String(
                        format: "Auto parting switched from %@ to %@ after evaluating %d primary candidate(s): %d undercut region(s), max depth %.2f mm, %d extra component(s).",
                        planePairLabel(initialResult.planes),
                        planePairLabel(bestResult.planes),
                        evaluatedCount,
                        bestScore.undercutRegionCount,
                        bestScore.maximumUndercutDepth,
                        bestScore.connectivity.componentCount
                    )
                ))
                partitionResult = bestResult
            } else {
                allDiagnostics.append(MoldDiagnostic(
                    .info,
                    String(
                        format: "Auto parting evaluated %d primary candidate(s); %@ ranked best with %d undercut region(s), max depth %.2f mm.",
                        evaluatedCount,
                        planePairLabel(bestResult.planes),
                        bestScore.undercutRegionCount,
                        bestScore.maximumUndercutDepth
                    )
                ))
            }
        }
        allDiagnostics.append(contentsOf: partitionResult.diagnostics)

        guard partitionResult.parts.count == requestedPartCount else {
            throw MotherMoldPlannerError.incorrectPartCount(
                requested: requestedPartCount,
                produced: partitionResult.parts.count
            )
        }
        var workingParts = partitionResult.parts
        let workingPlanes = partitionResult.planes
        let expectedPhysicalInterfaceCount = workingPlanes.count * max(1, workingParts.count / 2)

        // Stage 5 — undercut analysis.
        try beginStage(.keysAndRim, progress: progress, isCancelled: isCancelled)
        // Demold axes: for a 2-part mold the two halves pull apart along the
        // open-plane normal; for 4-part they pull along two axes. Approximate
        // from the parting planes (or the open plane for a single part).
        let demoldAxes = demoldAxesFor(
            parts: workingParts,
            planes: workingPlanes,
            openPlane: shellResult.openPlane
        )
        let undercutSummary = MoldUndercutAnalyzer.analyze(
            parts: workingParts,
            demoldAxes: demoldAxes,
            cavity: cavity,
            settings: settings,
            planes: workingPlanes
        )
        allDiagnostics.append(contentsOf: undercutSummary.diagnostics)

        // Stage 6 — flanges + bolt holes. Registration is deliberately applied
        // afterward so keys are placed against the final broad mating surfaces;
        // the conformal wall alone is too narrow for useful registration.
        let flangeResult: MoldFlangeBuilder.FlangeResult
        do {
            flangeResult = try MoldFlangeBuilder.applyFlanges(
                parts: workingParts,
                planes: workingPlanes,
                flange: settings.flange,
                cavity: cavity,
                seed: settings.seed,
                protectedLocator: masterMountResult.locatorGeometry
            )
        } catch {
            allDiagnostics.append(MoldDiagnostic(.error,
                "Flange stage failed (\((error as? LocalizedError)?.errorDescription ?? "\(error)")); omitting flanges."))
            flangeResult = MoldFlangeBuilder.FlangeResult(parts: workingParts, diagnostics: [])
        }
        allDiagnostics.append(contentsOf: flangeResult.diagnostics)
        workingParts = flangeResult.parts
        if settings.flange.enabled, workingParts.count >= 2, flangeResult.flangedSeamCount == 0 {
            allDiagnostics.append(MoldDiagnostic(.error,
                "Clamping flanges were requested but could not be built on any seam — the parts have no way to clamp shut against pour pressure."))
        } else if settings.flange.enabled,
                  workingParts.count >= 2,
                  flangeResult.flangedSeamCount < expectedPhysicalInterfaceCount {
            allDiagnostics.append(MoldDiagnostic(.error,
                "Only \(flangeResult.flangedSeamCount) of \(expectedPhysicalInterfaceCount) physical mating interface(s) received flanges; the build is inspection-only and export is blocked until every interface has a clampable flange."))
        }

        // Stage 7 — spout + vents. These subtractive features run before keys so
        // a late bore cannot silently drill away a registration boss or pocket.
        try beginStage(.pourHoleAndVents, progress: progress, isCancelled: isCancelled)
        let featureResult: MoldFeatureBuilder.FeatureResult
        do {
            featureResult = try MoldFeatureBuilder.applyFeatures(
                parts: workingParts,
                cavity: cavity,
                openPlane: shellResult.openPlane,
                settings: settings,
                seed: settings.seed,
                partingPlanes: workingPlanes,
                protectedLocator: masterMountResult.locatorGeometry
            )
        } catch {
            allDiagnostics.append(MoldDiagnostic(.error,
                "Feature stage failed (\((error as? LocalizedError)?.errorDescription ?? "\(error)")); omitting spout/vents."))
            featureResult = MoldFeatureBuilder.FeatureResult(
                parts: workingParts,
                spoutLocation: nil,
                ventLocations: [],
                diagnostics: []
            )
        }
        allDiagnostics.append(contentsOf: featureResult.diagnostics)
        workingParts = featureResult.parts
        if !featureResult.spoutBored {
            let message: String
            if settings.spout.mode == .manual {
                message = "Pour path needs attention. The manual spout could not place a sealed funnel and fill channel without violating a mold interface or generated locator. Move it onto a clear upper surface of one mold part and rebuild."
            } else {
                message = "Pour path needs attention. Refab Artist could not place a sealed funnel and fill channel on one mold part. Switch Spout to Manual, move it away from seams, and rebuild."
            }
            allDiagnostics.append(MoldDiagnostic(.error, message))
        }
        if featureResult.ventsBoredCount < settings.spout.ventCount {
            allDiagnostics.append(MoldDiagnostic(.error,
                "Pour system needs attention. Only \(featureResult.ventsBoredCount) of \(settings.spout.ventCount) requested air vent(s) could be bored. Reduce Vent count or diameter, or reorient the model, then rebuild; export is blocked."))
        }

        // Stage 8 — registration keys on the completed, bored flange faces.
        // Boundary-aware placement now sees spout and vent openings and keeps
        // keys clear of them. No later intentional boolean removes material.
        try beginStage(.checkingWatertightness, progress: progress, isCancelled: isCancelled)
        let requestedKeyCount = settings.key.type == .none
            ? 0
            : expectedPhysicalInterfaceCount * max(1, settings.key.sanitized.pinsPerSeam)
        let keyResult: MoldKeyBuilder.KeyResult
        do {
            keyResult = try MoldKeyBuilder.applyKeys(
                parts: workingParts,
                planes: workingPlanes,
                key: settings.key
            )
        } catch {
            allDiagnostics.append(MoldDiagnostic(.error,
                "Registration stage failed (\((error as? LocalizedError)?.errorDescription ?? "\(error)")); the mold is inspection-only."))
            keyResult = MoldKeyBuilder.KeyResult(parts: workingParts, diagnostics: [])
        }
        allDiagnostics.append(contentsOf: keyResult.diagnostics)
        workingParts = keyResult.parts
        if keyResult.registrationKeysPlaced != requestedKeyCount {
            allDiagnostics.append(MoldDiagnostic(
                .error,
                "Registration requested \(requestedKeyCount) mating key pair\(requestedKeyCount == 1 ? "" : "s"), but only \(keyResult.registrationKeysPlaced) survived. Widen the flange, reduce the key size/count, or choose no keys explicitly."
            ))
        }

        // Stage 8.5 — repair only a part that actually fails preflight. Running
        // the fan sealer on already-valid Manifold output can reinterpret
        // coincident feature edges and create defects that were not present.
        workingParts = workingParts.map { part in
            var p = part
            let before = MotherMoldValidation.printablePreflight(part.geometry)
            guard !before.isWatertight else { return p }
            let sealed = MoldMeshSealer.seal(part.geometry)
            let after = MotherMoldValidation.printablePreflight(sealed)
            // A lower defect count is not a valid repair contract. A partial
            // stitch can destroy the original Manifold topology and leave the
            // stricter Stage 9 normalizer with nothing recoverable to load.
            // Adopt only a candidate that clears the actual printable gate.
            if after.isWatertight {
                p.geometry = sealed
            }
            return p
        }

        var debrisFragments = 0
        var debrisVolume = 0.0
        workingParts = workingParts.map { part in
            var p = part
            let vertexFiltered = MoldComponentFilter.dropDebris(p.geometry)
            if vertexFiltered.droppedCount > 0 {
                debrisFragments += vertexFiltered.droppedCount
                debrisVolume += vertexFiltered.droppedVolume
                p.geometry = vertexFiltered.geometry
            }
            let faceFiltered = MoldComponentFilter.dropFaceDisconnectedTinyDebris(p.geometry)
            if faceFiltered.droppedCount > 0 {
                debrisFragments += faceFiltered.droppedCount
                debrisVolume += faceFiltered.droppedVolume
                p.geometry = faceFiltered.geometry
            }
            return p
        }
        if debrisFragments > 0 {
            allDiagnostics.append(MoldDiagnostic(.info,
                String(format: "Removed %d floating debris fragment(s) (%.0f mm³ total) left by boolean stages.",
                       debrisFragments, debrisVolume)))
        }

        let disconnectedParts: [String] = workingParts.compactMap { part -> String? in
            let filtered = MoldComponentFilter.dropFaceDisconnectedDebris(part.geometry)
            guard filtered.droppedCount > 0 else { return nil }
            return String(
                format: "%@ (%d extra component(s), %.3f mm^3 secondary volume)",
                part.name,
                filtered.droppedCount,
                filtered.droppedVolume
            )
        }
        guard disconnectedParts.isEmpty else {
            throw MotherMoldPlannerError.disconnectedParts(disconnectedParts)
        }

        // Stage 9 — per-part validation (MeshPreflight per part, no auto-heal).
        let validationResult = MotherMoldValidation.validate(parts: workingParts)
        allDiagnostics.append(contentsOf: validationResult.diagnostics)

        // Hard gate: the spec requires EVERY exported part to be watertight.
        // Validation only attaches a flag + diagnostic; the planner is where we
        // refuse to hand back a leaky build. Aborting here means a non-watertight
        // result can never reach the exporter (headless or GUI).
        if !validationResult.allPartsWatertight {
            let leaky = validationResult.parts
                .filter { !$0.isWatertight }
                .map { part in
                    let preflight = MeshPreflight.analyze(geometry: part.geometry)
                    return "\(part.name) (boundary \(preflight.boundaryEdgeCount), non-manifold \(preflight.nonManifoldEdgeCount), degenerate \(preflight.degenerateTriangleCount))"
                }
            throw MotherMoldPlannerError.partsNotWatertight(leaky)
        }
        let survivingKeySites = MoldKeyBuilder.survivingSites(
            keyResult.sites,
            in: validationResult.parts
        )
        if survivingKeySites.count != requestedKeyCount {
            allDiagnostics.append(MoldDiagnostic(
                .error,
                "Final geometry retained \(survivingKeySites.count) of \(requestedKeyCount) requested mating key pair\(requestedKeyCount == 1 ? "" : "s"). A boss or pocket was removed by a later stage; export is blocked."
            ))
        }
        let overlaps = positiveOverlapDescriptions(validationResult.parts)
        if !overlaps.isEmpty {
            allDiagnostics.append(MoldDiagnostic(
                .error,
                "Assembled mold parts overlap after final keying: \(overlaps.joined(separator: ", "))."
            ))
        }
        var finalMasterMount = masterMountResult.summary
        if finalMasterMount.mode == .flatBaseSocket, finalMasterMount.isResolved {
            if let locator = masterMountResult.locatorGeometry,
               let retained = MoldFeatureBuilder.retainedProtectedLocatorFraction(
                    locator: locator,
                    in: validationResult.parts
               ) {
                finalMasterMount.finalLocatorRetention = retained
                if retained < MoldFeatureBuilder.minimumProtectedLocatorRetention {
                    allDiagnostics.append(MoldDiagnostic(
                        .error,
                        String(
                            format: "Master fixture needs attention. Only %.0f%% of the generated locator survived the final mold operations. Reorient the base or choose External fixture, then rebuild.",
                            retained * 100
                        )
                    ))
                } else {
                    allDiagnostics.append(MoldDiagnostic(
                        .info,
                        String(format: "Generated master locator verified in the final printable parts (%.1f%% retained).", retained * 100)
                    ))
                }
            } else {
                allDiagnostics.append(MoldDiagnostic(
                    .error,
                    "Master fixture needs attention. Refab Artist could not verify the generated locator in the final mold parts. Reorient the base or choose External fixture, then rebuild."
                ))
            }
        }
        try beginStage(.packaging, progress: progress, isCancelled: isCancelled)
        let material = materialEstimates(
            parts: validationResult.parts,
            cavity: cavity,
            master: masterGeometry,
            settings: settings
        )
        allDiagnostics.append(MoldDiagnostic(.info, materialEstimateMessage(material)))

        var plan = MotherMoldPlan(
            parts: validationResult.parts,
            partingPlanes: workingPlanes,
            cavity: cavity,
            master: masterGeometry,
            diagnostics: allDiagnostics,
            demoldAxes: demoldAxes,
            undercutReports: undercutSummary.reports,
            masterMount: finalMasterMount,
            flangedSeamCount: flangeResult.flangedSeamCount,
            flangePlatesPlaced: flangeResult.flangePlatesPlaced,
            effectiveBoltHoleCount: flangeResult.effectiveBoltHoleCount,
            registrationKeysPlaced: survivingKeySites.count,
            registrationKeySites: survivingKeySites,
            spoutBored: featureResult.spoutBored,
            ventsBoredCount: featureResult.ventsBoredCount,
            estimatedSiliconeCC: material.estimatedSiliconeCC,
            printedPlasticCC: material.printedPlasticCC
        )
        plan.toolingContractVersion = settings.toolingContractVersion
        plan.requestedPackaging = settings.packaging
        plan.deterministicSeed = settings.seed
        plan.sourceModelPath = model.path
        plan.sourceModelFormat = model.format
        plan.sourceModelByteCount = model.byteCount
        plan.includeReferenceMeshes = settings.includeReferenceMeshes
        plan.manufacturingProfile = settings.manufacturingProfile
        applyInitialToolingContract(to: &plan, settings: settings)
        try throwIfCancelled(isCancelled)
        return plan
    }

    /// v3 is intentionally a separate transaction. Its fixture and flow
    /// datums are created before partitioning and then handed forward exactly;
    /// it must never borrow the legacy socket or spout feature stages.
    private static func planReusableTooling(
        model: MeshSummary,
        settings: MotherMoldSettings,
        immutableSource: MeshGeometryData,
        sourceDiagnostics: [MoldDiagnostic],
        progress: (@Sendable (MoldBuildStage) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> MotherMoldPlan {
        var diagnostics = sourceDiagnostics

        let prepared: PreparedMasterBuilder.Result
        do {
            prepared = try PreparedMasterBuilder.build(source: immutableSource, settings: settings)
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("prepared-master", error))
        }
        guard prepared.kind == .prepared, prepared.artifact != nil else {
            throw MotherMoldPlannerError.partitionFailed("prepared-master stage did not emit a prepared positive for the reusable prepared-post contract.")
        }
        guard let physicalSource = prepared.normalizedSource else {
            throw MotherMoldPlannerError.partitionFailed("prepared-master stage did not retain the exact physical source union for downstream tooling.")
        }

        try beginStage(.buildingCavity, progress: progress, isCancelled: isCancelled)
        let cavity: MeshGeometryData
        do {
            cavity = try MoldCavityBuilder.buildCavity(master: physicalSource, settings: settings)
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("source-derived cavity/shell", error))
        }
        try beginStage(.buildingShell, progress: progress, isCancelled: isCancelled)
        let shell: MoldShellBuilder.ShellResult
        do {
            shell = try MoldShellBuilder.buildShell(cavity: cavity, master: physicalSource, settings: settings)
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("source-derived cavity/shell", error))
        }
        diagnostics.append(contentsOf: shell.diagnostics)

        try beginStage(.splitting, progress: progress, isCancelled: isCancelled)
        let reservation: MoldMasterFixtureBuilder.DryPostReservation
        do {
            reservation = try MoldMasterFixtureBuilder.reserveDryPostPath(
                wholeShell: shell.solid,
                preparedMaster: prepared,
                settings: settings
            )
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("dry prepared-post path reservation", error))
        }
        let reservedShell = reservation.wholeShell
        diagnostics.append(contentsOf: reservation.diagnostics)

        if settings.parting.mode == .manual,
           settings.parting.planes.count != settings.parts.planeCount {
            throw MotherMoldPlannerError.partitionFailed(
                "Manual parting requires exactly \(settings.parts.planeCount) plane(s), but \(settings.parting.planes.count) were supplied."
            )
        }
        let fixtureSplitLine = prepared.selectedMount.map {
            (
                point: Vec3(x: $0.point.x, y: $0.point.y, z: $0.point.z),
                direction: Vec3(x: $0.outwardAxis.x, y: $0.outwardAxis.y, z: $0.outwardAxis.z)
            )
        }
        let resolvedPlanes = MoldPartitioner.resolvePlanes(
            shell: reservedShell,
            reference: cavity,
            settings: settings,
            requiredSplitLine: fixtureSplitLine
        )
        guard !resolvedPlanes.isEmpty else {
            throw MotherMoldPlannerError.partitionFailed("parting-plane resolution produced no exact split plane for the reserved fixture shell.")
        }

        let fixture: MoldMasterFixtureBuilder.Result
        do {
            fixture = try MoldMasterFixtureBuilder.build(.init(
                wholeShell: reservedShell,
                preparedMaster: prepared,
                settings: settings,
                cavityVolumes: [.init(id: "source-derived-cavity", purpose: "immutable source-derived silicone cavity", geometry: cavity)],
                protectedVolumes: [],
                proposedPartingPlanes: resolvedPlanes
            ))
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("prepared-post fixture", error))
        }
        guard fixture.kind == .fixture,
              let shellWithCollar = fixture.wholeShellWithCollar,
              let productionGate = fixture.productionGate,
              let yoke = fixture.yoke,
              let crossPin = fixture.crossPin else {
            throw MotherMoldPlannerError.partitionFailed("prepared-post fixture did not emit its collar, exact gate datum, yoke, and hardware pin.")
        }
        diagnostics.append(contentsOf: fixture.diagnostics.map {
            MoldDiagnostic(.info, $0, subsystem: .holdDown, code: MoldDiagnosticCode(rawValue: "fixture.geometry"))
        })

        let partition: MoldPartitioner.PartitionResult
        do {
            partition = try MoldPartitioner.partition(shell: shellWithCollar, planes: resolvedPlanes, settings: settings)
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("fixture-shell partition", error))
        }
        let requestedPartCount = 1 << settings.parts.planeCount
        guard partition.parts.count == requestedPartCount else {
            throw MotherMoldPlannerError.incorrectPartCount(requested: requestedPartCount, produced: partition.parts.count)
        }
        diagnostics.append(contentsOf: partition.diagnostics)
        let demoldAxes = demoldAxesFor(
            parts: partition.parts,
            planes: partition.planes,
            openPlane: shell.openPlane
        )
        guard demoldAxes.count == partition.parts.count else {
            throw MotherMoldPlannerError.partitionFailed("partition did not provide one demold axis per fixture shell part.")
        }
        try beginStage(.keysAndRim, progress: progress, isCancelled: isCancelled)
        let undercuts = MoldUndercutAnalyzer.analyze(
            parts: partition.parts,
            demoldAxes: demoldAxes,
            cavity: cavity,
            settings: settings,
            planes: partition.planes
        )
        diagnostics.append(contentsOf: undercuts.diagnostics)

        let initialProtectedAuditSet: ProtectedToolingAuditSet
        do {
            initialProtectedAuditSet = try reusableProtectedAuditSet(
                fixture: fixture,
                reservation: reservation
            )
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("protected fixture audit", error))
        }

        let expectedInterfaces = partition.planes.count * max(1, partition.parts.count / 2)
        let flange: MoldFlangeBuilder.FlangeResult
        do {
            flange = try MoldFlangeBuilder.applyFlanges(
                parts: partition.parts,
                planes: partition.planes,
                flange: settings.flange,
                cavity: cavity,
                seed: settings.seed,
                protectedAuditSet: initialProtectedAuditSet
            )
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("flange and bolt", error))
        }
        diagnostics.append(contentsOf: flange.diagnostics)
        if settings.flange.enabled,
           (flange.flangedSeamCount != expectedInterfaces || flange.effectiveBoltHoleCount == 0) {
            let detail = flange.diagnostics
                .filter { $0.severity == .error }
                .map(\.message)
                .joined(separator: " ")
            throw MotherMoldPlannerError.partitionFailed(
                "fixture shell requires \(expectedInterfaces) clampable interface(s), but flanging produced \(flange.flangedSeamCount) interface(s) and \(flange.effectiveBoltHoleCount) surviving bolt bore(s)."
                    + (detail.isEmpty ? "" : " \(detail)")
            )
        }
        guard let flangeProtectedAuditSet = flange.protectedAuditSet else {
            throw MotherMoldPlannerError.partitionFailed("flange stage did not return its typed protected-geometry audit set.")
        }

        let registrationShellParts = zip(flange.parts, demoldAxes).map {
            MoldLinerRegistrationShellPart(
                id: ToolingArtifactID($0.0.name),
                part: $0.0,
                demoldAxis: Vec3Codable(x: $0.1.x, y: $0.1.y, z: $0.1.z)
            )
        }
        let fixtureDatum = try MoldLinerRegistrationGateLipDatum(fixture: fixture)
        func registrationInput(_ registrationSettings: LinerRegistrationSettings) -> MoldLinerRegistrationInput {
            MoldLinerRegistrationInput(
                finalShellParts: registrationShellParts,
                nominalLinerSurface: cavity,
                totalLinerOffset: settings.siliconeGap,
                settings: registrationSettings,
                wallThickness: settings.wallThickness,
                partingPlanes: partition.planes,
                reservedGeometry: reusableReservedGeometry(fixture: fixture, reservation: reservation),
                gateLipDatum: fixtureDatum,
                protectedAuditSet: flangeProtectedAuditSet
            )
        }
        let registration: MoldLinerRegistrationResult
        do {
            registration = try MoldLinerRegistrationBuilder.build(registrationInput(settings.linerRegistration))
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("liner registration", error))
        }
        let registrationProtectedAuditSet = registration.protectedAuditSet
        try requireProtectedAudit(
            registrationProtectedAuditSet,
            parts: registration.shellParts.map(\.part),
            stage: .linerRegistration
        )

        try beginStage(.pourHoleAndVents, progress: progress, isCancelled: isCancelled)
        let handoff: MoldFlowPathBuilder.ExactFixtureRegistrationHandoff
        do {
            handoff = try MoldFlowPathBuilder.exactFixtureRegistrationHandoff(
                fixture: fixture,
                registration: registration
            )
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("fixture-registration handoff", error))
        }

        guard let basePreparedGeometry = prepared.artifact?.geometry else {
            throw MotherMoldPlannerError.partitionFailed("prepared-master artifact was lost before flow planning.")
        }
        let linerAxis = settings.masterPreparation.linerFillUpAxis.map(vec)
            ?? axis(from: shell.openPlane.normal)
        let castingAxis = settings.productionFlow.castingUpAxis.map(vec)
            ?? vec(productionGate.receiverAxis)
        let proposal: MoldFlowPathBuilder.Proposal
        do {
            proposal = try MoldFlowPathBuilder.propose(.init(
                shellParts: registration.shellParts.map(\.part),
                immutableSource: physicalSource,
                cavityEnvelope: cavity,
                oneTimePourPositive: basePreparedGeometry,
                partingPlanes: partition.planes,
                demoldAxes: demoldAxes,
                preparedPost: handoff.preparedPost,
                funnelInterface: handoff.funnelInterface,
                linerFillUpAxis: linerAxis,
                castingUpAxis: castingAxis,
                settings: reusableFlowSettings(settings),
                verifiedLinerAdditives: registration.siliconeAdditives,
                protectedLinerRegions: registration.protectedRegions,
                reservedToolingVolumes: fixture.protectedAdditives.map(\.geometry) + fixture.protectedSubtractives.map(\.geometry),
                protectedAuditSet: registrationProtectedAuditSet,
                seed: settings.seed
            ))
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("flow proposal", error))
        }
        let linerStates: MoldLinerStateBuilderResult
        let flow: MoldFlowPathBuilder.Result
        do {
            linerStates = try MoldLinerStateBuilder.build(MoldFlowPathBuilder.linerStateInput(for: proposal))
            flow = try MoldFlowPathBuilder.finalize(.init(
                proposal: proposal,
                asPouredLiner: linerStates.asPouredLiner.geometry,
                productionLiner: linerStates.productionLiner.geometry
            ))
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("flow finalization", error))
        }
        diagnostics.append(contentsOf: flow.diagnostics)
        try requireProtectedAudit(
            flow.protectedAuditSet,
            parts: flow.shellParts,
            stage: .flow
        )

        try beginStage(.checkingWatertightness, progress: progress, isCancelled: isCancelled)
        let finalizedPrepared: PreparedMasterBuilder.Result
        do {
            finalizedPrepared = try PreparedMasterBuilder.finalize(
                base: prepared,
                source: immutableSource,
                settings: settings,
                additions: flow.preparedMasterAdditions
            )
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("prepared-master finalization", error))
        }
        guard let finalPreparedArtifact = finalizedPrepared.artifact else {
            throw MotherMoldPlannerError.partitionFailed("prepared-master finalization did not produce printable geometry.")
        }

        let requestedKeys = settings.key.type == .none
            ? 0
            : expectedInterfaces * max(1, settings.key.sanitized.pinsPerSeam)
        let keys: MoldKeyBuilder.KeyResult
        do {
            keys = try MoldKeyBuilder.applyKeys(
                parts: flow.shellParts,
                planes: partition.planes,
                key: settings.key,
                protectedAuditSet: flow.protectedAuditSet
            )
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("post-flow seam keys", error))
        }
        diagnostics.append(contentsOf: keys.diagnostics)
        guard keys.registrationKeysPlaced == requestedKeys else {
            throw MotherMoldPlannerError.partitionFailed(
                "post-flow keying retained \(keys.registrationKeysPlaced) of \(requestedKeys) requested mating key pair(s)."
            )
        }
        guard let finalProtectedAuditSet = keys.protectedAuditSet else {
            throw MotherMoldPlannerError.partitionFailed("key stage did not return its typed protected-geometry audit set.")
        }
        let validation = MotherMoldValidation.validate(
            parts: keys.parts,
            protectedAuditSet: finalProtectedAuditSet
        )
        diagnostics.append(contentsOf: validation.diagnostics)
        guard validation.allPartsWatertight else {
            throw MotherMoldPlannerError.partsNotWatertight(validation.parts.filter { !$0.isWatertight }.map(\.name))
        }
        guard validation.protectedAudit?.passes != false else {
            throw MotherMoldPlannerError.partitionFailed(
                validation.protectedAudit?.diagnostics.joined(separator: " ")
                    ?? "Final protected-tooling audit failed."
            )
        }
        let survivingKeys = MoldKeyBuilder.survivingSites(keys.sites, in: validation.parts)
        guard survivingKeys.count == requestedKeys else {
            throw MotherMoldPlannerError.partitionFailed(
                "final validation retained \(survivingKeys.count) of \(requestedKeys) requested mating key pair(s)."
            )
        }
        let overlaps = positiveOverlapDescriptions(validation.parts)
        guard overlaps.isEmpty else {
            throw MotherMoldPlannerError.partitionFailed("assembled final shell parts overlap after post-flow keying: \(overlaps.joined(separator: ", ")).")
        }

        try beginStage(.packaging, progress: progress, isCancelled: isCancelled)
        let protectedSupportReservations = finalProtectedAuditSet.records
            .filter { $0.behavior == .subtractive }
            .map {
                MoldToolingSupportReservedVolume(
                    id: "protected-\($0.id)",
                    purpose: "preserve \($0.kind.rawValue) clearance",
                    geometry: $0.geometry
                )
            }
        let linerSupportReservations = protectedSupportReservations + [
            MoldToolingSupportReservedVolume(
                id: "prepared-master",
                purpose: "prepared master installed during liner fabrication",
                geometry: finalPreparedArtifact.geometry
            ),
            MoldToolingSupportReservedVolume(
                id: "hold-down-yoke",
                purpose: "hold-down yoke installed during liner fabrication",
                geometry: yoke.geometry
            ),
        ] + flow.ventFormers.map {
            MoldToolingSupportReservedVolume(
                id: "\($0.id.rawValue)-removal-sweep",
                purpose: "production vent former and straight extraction sweep",
                geometry: $0.removalSweep
            )
        }
        let castingSupportReservations = protectedSupportReservations + flow.fixtureArtifacts
            .filter { $0.role == .castingFunnel }
            .map {
                MoldToolingSupportReservedVolume(
                    id: $0.id.rawValue,
                    purpose: "installed production casting funnel",
                    geometry: $0.geometry
                )
            }
        let support = try reusableSupport(
            shellParts: validation.parts,
            asPouredLiner: linerStates.asPouredLiner.geometry,
            productionLiner: linerStates.productionLiner.geometry,
            linerAxis: flow.linerFillSummary.gravityUpAxis ?? Vec3Codable(x: linerAxis.x, y: linerAxis.y, z: linerAxis.z),
            castingAxis: flow.castingGateSummary.gravityUpAxis ?? Vec3Codable(x: castingAxis.x, y: castingAxis.y, z: castingAxis.z),
            linerReservedVolumes: linerSupportReservations,
            castingReservedVolumes: castingSupportReservations,
            settings: settings
        )
        diagnostics.append(contentsOf: support.diagnostics)

        let holdDown: MoldHoldDownQualificationResult
        do {
            guard let mount = finalizedPrepared.selectedMount else {
                throw MotherMoldPlannerError.partitionFailed("prepared-master finalization did not retain the selected hold-down mount datum.")
            }
            holdDown = try MoldHoldDownQualification.evaluate(.init(
                sourceMaster: physicalSource,
                linerFillUpAxis: flow.linerFillSummary.gravityUpAxis ?? Vec3Codable(x: linerAxis.x, y: linerAxis.y, z: linerAxis.z),
                holdDownPoint: mount.point,
                mountAxis: mount.outwardAxis,
                siliconeDensityGramsPerCC: settings.material.siliconeDensityGramsPerCC,
                masterMassGrams: settings.masterPreparation.masterWeightGrams,
                masterCenterOfGravity: settings.masterPreparation.masterCenterOfGravity,
                capacity: holdDownCapacity(settings.masterPreparation),
                fluidLoadSafetyFactor: settings.material.upliftSafetyFactor
            ))
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("hold-down qualification", error))
        }

        let material = materialEstimates(parts: validation.parts, cavity: cavity, master: physicalSource, settings: settings)
        diagnostics.append(MoldDiagnostic(.info, materialEstimateMessage(material)))
        var fixtureArtifacts = [yoke] + flow.fixtureArtifacts
        fixtureArtifacts.sort { $0.id < $1.id }
        var plan = MotherMoldPlan(
            parts: validation.parts,
            partingPlanes: partition.planes,
            cavity: cavity,
            master: immutableSource,
            diagnostics: diagnostics,
            demoldAxes: demoldAxes,
            undercutReports: undercuts.reports,
            masterMount: .notApplicable,
            flangedSeamCount: flange.flangedSeamCount,
            flangePlatesPlaced: flange.flangePlatesPlaced,
            effectiveBoltHoleCount: flange.effectiveBoltHoleCount,
            registrationKeysPlaced: survivingKeys.count,
            registrationKeySites: survivingKeys,
            estimatedSiliconeCC: material.estimatedSiliconeCC,
            printedPlasticCC: material.printedPlasticCC
        )
        plan.toolingContractVersion = settings.toolingContractVersion
        plan.requestedPackaging = settings.packaging
        plan.deterministicSeed = settings.seed
        plan.sourceModelPath = model.path
        plan.sourceModelFormat = model.format
        plan.sourceModelByteCount = model.byteCount
        plan.includeReferenceMeshes = settings.includeReferenceMeshes
        plan.manufacturingProfile = settings.manufacturingProfile
        plan.preparedMaster = finalPreparedArtifact
        plan.fixtureArtifacts = fixtureArtifacts
        plan.supportArtifacts = support.artifacts
        plan.hardwareItems = [crossPin]
        plan.asPouredLiner = linerStates.asPouredLiner
        plan.productionLiner = linerStates.productionLiner
        plan.masterModificationRegions = finalizedPrepared.modificationRegions
        plan.masterPreparation = finalizedPrepared.summary
        plan.holdDownWrenchEnvelope = holdDown.wrenchEnvelope
        plan.linerRegistration = registration.summary
        plan.linerFillPath = flow.linerFillSummary
        plan.productionCastingPath = flow.castingGateSummary
        plan.productionCastingVents = flow.productionVentSummaries
        plan.linerFillSupport = support.liner.summary
        plan.castingSupport = support.casting.summary
        plan.toolingExportContract = reusableToolingContract(
            settings: settings,
            prepared: finalizedPrepared,
            fixture: fixture,
            holdDown: holdDown.wrenchEnvelope,
            linerSupport: support.liner,
            castingSupport: support.casting,
            flow: flow
        )
        try throwIfCancelled(isCancelled)
        return plan
    }

    private static func beginStage(
        _ stage: MoldBuildStage,
        progress: (@Sendable (MoldBuildStage) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws {
        try throwIfCancelled(isCancelled)
        progress?(stage)
    }

    private static func throwIfCancelled(
        _ isCancelled: (@Sendable () -> Bool)?
    ) throws {
        if isCancelled?() == true {
            throw MotherMoldPlannerError.cancelled
        }
    }

    /// Non-throwing convenience that converts a thrown error into a single error
    /// diagnostic on an otherwise-empty plan. Mirrors the structures generator's
    /// soft-failure surface for the inspector.
    static func plan(
        model: MeshSummary,
        settings: MotherMoldSettings
    ) -> MotherMoldPlan {
        do {
            return try planThrowing(model: model, settings: settings)
        } catch {
            var p = MotherMoldPlan.empty
            p.master = model.geometry
            p.diagnostics = [
                MoldDiagnostic(.error, (error as? LocalizedError)?.errorDescription ?? "\(error)")
            ]
            return p
        }
    }

    // MARK: - Private helpers

    private struct PartitionConnectivityScore {
        var componentCount: Int
        var secondaryVolume: Double
    }

    /// Establishes honest v3 state before the dedicated preparation, liner,
    /// flow, and support builders populate their measured artifacts. Keeping
    /// this state in the plan prevents UI/headless/export paths from inferring
    /// readiness from the presence of rigid shell parts alone.
    private static func applyInitialToolingContract(
        to plan: inout MotherMoldPlan,
        settings: MotherMoldSettings
    ) {
        guard settings.usesReusableToolingContract else {
            plan.toolingExportContract = .notApplicable
            return
        }

        let preparedSource = settings.masterPreparation.sourceMode == .preparedPrint
        let retentionEvidence: MasterRetentionEvidence
        switch settings.masterPreparation.retentionMode {
        case .preparedPost:
            retentionEvidence = .preparedPostGeometryOnly
        case .flatBaseSocket:
            retentionEvidence = .socketLocatorOnly
        case .externalFixture:
            retentionEvidence = .externalFixtureDeclared
        }
        plan.masterPreparation = MasterPreparationSummary(
            state: .pending,
            retentionEvidence: retentionEvidence,
            notes: [preparedSource
                ? "Prepared positive geometry and approval evidence have not been generated yet."
                : "The existing physical positive remains an external manufacturing responsibility."]
        )
        plan.holdDownWrenchEnvelope = HoldDownWrenchEnvelope(
            version: 1,
            qualification: preparedSource ? .notMeasured : .external,
            notes: ["Fill-progress force and moment evidence has not been evaluated yet."]
        )
        plan.linerRegistration = LinerRegistrationSummary(
            state: settings.linerRegistration.mode == .none ? .disabled : .pendingMeasurement,
            requestedButtonCount: settings.linerRegistration.mode == .none
                ? 0
                : (1 << settings.parts.planeCount) * settings.linerRegistration.buttonsPerPart,
            gateLipEnabled: settings.linerRegistration.gateLipEnabled,
            gateLipDepthMillimeters: settings.linerRegistration.gateLipEnabled
                ? settings.linerRegistration.gateLipDepth
                : nil,
            notes: ["Registration geometry has not been added to the final liner and shell yet."]
        )
        plan.linerFillPath = MoldFlowPathSummary(
            id: "liner-fill-gate",
            phase: .linerFill,
            state: plan.spoutBored ? .geometryVerified : .blocked,
            label: "Liner fill gate",
            declaredDiameterMillimeters: settings.spout.spoutDiameter,
            notes: ["Current jacket gate is recorded as the one-time silicone-liner fill path."]
        )
        plan.productionCastingPath = MoldFlowPathSummary(
            id: "production-casting-gate",
            phase: .casting,
            state: .notGenerated,
            label: "Production casting gate",
            declaredDiameterMillimeters: settings.productionFlow.gateDiameter,
            notes: ["The reusable casting gate and removable funnel have not been generated yet."]
        )
        plan.linerFillSupport = ToolingSupportSummary(
            phase: .linerFill,
            state: .pendingMeasurement,
            notes: ["Liner-fill orientation and support margin have not been measured yet."]
        )
        plan.castingSupport = ToolingSupportSummary(
            phase: .casting,
            state: .pendingMeasurement,
            notes: ["Casting orientation and fluid-inclusive support margin have not been measured yet."]
        )

        var requiredRoles: [ToolingArtifactRole] = [.moldPart, .castingFunnel]
        if preparedSource {
            requiredRoles += [.preparedMaster, .holdDownYoke]
        }
        plan.toolingExportContract = MotherMoldToolingContract(
            toolingContractVersion: settings.toolingContractVersion,
            state: .incomplete,
            qualification: .blocked,
            requiredArtifactRoles: requiredRoles,
            blockingReasons: [
                preparedSource
                    ? "Prepared positive and hold-down tooling have not been generated."
                    : "External positive retention has not been confirmed.",
                "Production casting flow geometry has not been generated.",
                "Liner registration and phase support evidence are incomplete.",
            ],
            warnings: ["Physical printer-fit, load, leak, and reuse evidence is not yet qualified."]
        )
    }

    private struct ReusableSupportResults {
        var liner: MoldToolingSupportResult
        var casting: MoldToolingSupportResult

        var artifacts: [ToolingArtifact] {
            (liner.artifacts + casting.artifacts).sorted { $0.id < $1.id }
        }

        var diagnostics: [MoldDiagnostic] { liner.diagnostics + casting.diagnostics }
    }

    private static func reusableReservedGeometry(
        fixture: MoldMasterFixtureBuilder.Result,
        reservation: MoldMasterFixtureBuilder.DryPostReservation
    ) -> MoldLinerRegistrationReservedGeometry {
        let collar = fixture.protectedAdditives.map {
            MoldLinerRegistrationReservedFeature(id: $0.id, kind: .collar, solid: $0.geometry)
        } + [MoldLinerRegistrationReservedFeature(
            id: reservation.path.id,
            kind: .collar,
            solid: reservation.path.geometry
        )]
        let productionFlow: [MoldLinerRegistrationReservedFeature]
        if let datum = fixture.productionGate {
            productionFlow = [
                MoldLinerRegistrationReservedFeature(
                    id: "exact-round-production-gate",
                    kind: .productionFlow,
                    solid: datum.roundProductionGateBore
                ),
                MoldLinerRegistrationReservedFeature(
                    id: "exact-rounded-d-receiver",
                    kind: .productionFlow,
                    solid: datum.roundedDReceiverBore
                ),
            ]
        } else {
            productionFlow = []
        }
        return MoldLinerRegistrationReservedGeometry(collar: collar, productionFlow: productionFlow)
    }

    private static func reusableProtectedAuditSet(
        fixture: MoldMasterFixtureBuilder.Result,
        reservation: MoldMasterFixtureBuilder.DryPostReservation
    ) throws -> ProtectedToolingAuditSet {
        var records = fixture.protectedAdditives.map {
            ProtectedToolingAuditSet.Record(
                id: "fixture-additive-\($0.id)",
                kind: .collar,
                behavior: .additive,
                ownership: .assembly,
                geometry: $0.geometry,
                requiredRetention: $0.requiredRetention,
                provenance: [.fixture]
            )
        }
        records.append(ProtectedToolingAuditSet.Record(
            id: "fixture-void-\(reservation.path.id)",
            kind: .postReceiver,
            behavior: .subtractive,
            ownership: .assembly,
            geometry: reservation.path.geometry,
            requiredClearance: 0.98,
            provenance: [.fixture]
        ))
        records += fixture.protectedSubtractives.map {
            ProtectedToolingAuditSet.Record(
                id: "fixture-void-\($0.id)",
                kind: .postReceiver,
                behavior: .subtractive,
                ownership: .assembly,
                geometry: $0.geometry,
                requiredClearance: $0.requiredRetention,
                provenance: [.fixture]
            )
        }
        if let gate = fixture.productionGate {
            records.append(ProtectedToolingAuditSet.Record(
                id: "fixture-void-production-gate",
                kind: .productionGate,
                behavior: .subtractive,
                ownership: .assembly,
                geometry: gate.roundProductionGateBore,
                requiredClearance: 0.98,
                provenance: [.fixture]
            ))
        }
        return try ProtectedToolingAuditSet(records: records)
    }

    private static func requireProtectedAudit(
        _ auditSet: ProtectedToolingAuditSet,
        parts: [MotherMoldPart],
        stage: ProtectedToolingAuditSet.Stage
    ) throws {
        let audit = auditSet.audit(finalParts: parts, stage: stage)
        guard audit.passes else {
            throw MotherMoldPlannerError.partitionFailed(
                audit.diagnostics.joined(separator: " ")
            )
        }
    }

    private static func reusableFlowSettings(_ settings: MotherMoldSettings) -> MoldFlowPathBuilder.Settings {
        MoldFlowPathBuilder.Settings(
            linerFillDiameter: settings.spout.spoutDiameter,
            linerVentDiameter: settings.spout.ventDiameter,
            requestedLinerVentCount: settings.spout.ventCount,
            productionGateDiameter: settings.productionFlow.gateDiameter,
            productionVentDiameter: settings.productionFlow.ventDiameter
        )
    }

    private static func holdDownCapacity(
        _ preparation: MasterPreparationSettings
    ) -> HoldDownCapacityInput {
        // The persisted scalar describes an external fixture only; it lacks
        // the shear/moment envelope needed to qualify this printed yoke.
        guard preparation.externalFixtureCapacityNewtons != nil else {
            return HoldDownCapacityInput()
        }
        return HoldDownCapacityInput(evidence: .externalFixture)
    }

    private static func reusableSupport(
        shellParts: [MotherMoldPart],
        asPouredLiner: MeshGeometryData,
        productionLiner: MeshGeometryData,
        linerAxis: Vec3Codable,
        castingAxis: Vec3Codable,
        linerReservedVolumes: [MoldToolingSupportReservedVolume],
        castingReservedVolumes: [MoldToolingSupportReservedVolume],
        settings: MotherMoldSettings
    ) throws -> ReusableSupportResults {
        let rigid = shellParts.map {
            MoldToolingSupportRigidArtifact(id: ToolingArtifactID($0.name), geometry: $0.geometry)
        }
        let support = settings.toolingSupport
        do {
            let liner = try MoldToolingSupportBuilder.evaluate(.init(
                phase: .linerFill,
                gravityUpAxis: linerAxis,
                rigidArtifacts: rigid,
                liquid: .init(
                    id: "AS-POURED LINER",
                    reachableGeometry: asPouredLiner,
                    densityGramsPerCC: settings.material.siliconeDensityGramsPerCC
                ),
                supportMode: support.mode,
                manualSupportPlane: support.manualLinerFillSupportPlane,
                minimumSupportMarginMillimeters: support.minimumSupportMargin,
                reservedVolumes: linerReservedVolumes,
                seed: settings.seed
            ))
            let casting = try MoldToolingSupportBuilder.evaluate(.init(
                phase: .casting,
                gravityUpAxis: castingAxis,
                rigidArtifacts: rigid,
                liquid: .init(
                    id: "PRODUCTION LINER",
                    reachableGeometry: productionLiner,
                    densityGramsPerCC: settings.material.castingDensityGramsPerCC
                ),
                supportMode: support.mode,
                manualSupportPlane: support.manualCastingSupportPlane,
                minimumSupportMarginMillimeters: support.minimumSupportMargin,
                reservedVolumes: castingReservedVolumes,
                seed: settings.seed
            ))
            return ReusableSupportResults(liner: liner, casting: casting)
        } catch {
            throw MotherMoldPlannerError.partitionFailed(stageError("phase support", error))
        }
    }

    private static func reusableToolingContract(
        settings: MotherMoldSettings,
        prepared: PreparedMasterBuilder.Result,
        fixture: MoldMasterFixtureBuilder.Result,
        holdDown: HoldDownWrenchEnvelope,
        linerSupport: MoldToolingSupportResult,
        castingSupport: MoldToolingSupportResult,
        flow: MoldFlowPathBuilder.Result
    ) -> MotherMoldToolingContract {
        var roles: [ToolingArtifactRole] = [.moldPart, .preparedMaster, .holdDownYoke, .castingFunnel]
        if flow.fixtureArtifacts.contains(where: { $0.role == .productionVentFormer }) {
            roles.append(.productionVentFormer)
        }
        for role in (linerSupport.artifacts + castingSupport.artifacts).map(\.role) where !roles.contains(role) {
            roles.append(role)
        }

        var blockers: [String] = []
        if prepared.summary.state != .approved {
            blockers.append("The final prepared-master approval signature must be explicitly approved before manufacture.")
        }
        if holdDown.qualification == .blocked {
            blockers.append("Measured hold-down loading exceeds the supplied capacity envelope.")
        }
        if linerSupport.summary.state == .blocked {
            blockers.append("LINER FILL support is blocked by its measured phase-support evidence.")
        }
        if castingSupport.summary.state == .blocked {
            blockers.append("CASTING support is blocked by its measured phase-support evidence.")
        }
        var warnings = ["All v3 geometry stages completed and were measured transactionally; no approval or physical qualification was inferred."]
        if fixture.status != .productionProfileQualified {
            warnings.append("Fixture geometry is present, but printer-fit, leak, load, and reuse evidence remains a physical qualification task.")
        }
        if holdDown.qualification != .qualified {
            warnings.append("Hold-down wrench evidence is \(holdDown.qualification.rawValue); a calibrated printed-fixture capacity and complete master mass properties are required for production qualification.")
        }
        return MotherMoldToolingContract(
            toolingContractVersion: settings.toolingContractVersion,
            state: blockers.isEmpty ? .geometryOnly : .blocked,
            qualification: blockers.isEmpty ? .geometryOnly : .blocked,
            requiredArtifactRoles: roles,
            blockingReasons: blockers,
            warnings: warnings
        )
    }

    private static func stageError(_ stage: String, _ error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return "\(stage) stage failed: \(detail)"
    }

    private static func axis(from vector: Vec3) -> Vec3 {
        let magnitude = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
        guard magnitude > 1.0e-9 else { return Vec3(x: 0, y: 0, z: 1) }
        return Vec3(x: vector.x / magnitude, y: vector.y / magnitude, z: vector.z / magnitude)
    }

    private static func vec(_ value: Vec3Codable) -> Vec3 {
        Vec3(x: value.x, y: value.y, z: value.z)
    }

    private struct AutoPartingScore {
        var connectivity: PartitionConnectivityScore
        var undercutRegionCount: Int
        var maximumUndercutDepth: Double
        var totalUndercutDepth: Double
    }

    private static func partitionConnectivityScore(
        _ parts: [MotherMoldPart]
    ) -> PartitionConnectivityScore {
        var componentCount = 0
        var secondaryVolume = 0.0
        for part in parts {
            let sealed = MoldMeshSealer.seal(part.geometry)
            let vertexFiltered = MoldComponentFilter.dropDebris(sealed)
            let faceFiltered = MoldComponentFilter.dropFaceDisconnectedTinyDebris(vertexFiltered.geometry)
            let remaining = MoldComponentFilter.dropFaceDisconnectedDebris(faceFiltered.geometry)
            componentCount += remaining.droppedCount
            secondaryVolume += remaining.droppedVolume
        }
        return PartitionConnectivityScore(
            componentCount: componentCount,
            secondaryVolume: secondaryVolume
        )
    }

    private static func autoPartingScore(
        result: MoldPartitioner.PartitionResult,
        cavity: MeshGeometryData,
        openPlane: PartitionPlane,
        settings: MotherMoldSettings
    ) -> AutoPartingScore {
        let axes = demoldAxesFor(parts: result.parts, planes: result.planes, openPlane: openPlane)
        let undercuts = MoldUndercutAnalyzer.analyze(
            parts: result.parts,
            demoldAxes: axes,
            cavity: cavity,
            settings: settings,
            planes: result.planes
        )
        let depths = undercuts.reports.flatMap { $0.regions.map(\.depth) }
        return AutoPartingScore(
            connectivity: partitionConnectivityScore(result.parts),
            undercutRegionCount: depths.count,
            maximumUndercutDepth: depths.max() ?? 0,
            totalUndercutDepth: depths.reduce(0, +)
        )
    }

    private static func autoPartingScore(
        _ candidate: AutoPartingScore,
        isBetterThan current: AutoPartingScore
    ) -> Bool {
        let tolerance = 1.0e-6
        if candidate.connectivity.componentCount != current.connectivity.componentCount {
            return candidate.connectivity.componentCount < current.connectivity.componentCount
        }
        if abs(candidate.connectivity.secondaryVolume - current.connectivity.secondaryVolume) > tolerance {
            return candidate.connectivity.secondaryVolume < current.connectivity.secondaryVolume
        }
        if candidate.undercutRegionCount != current.undercutRegionCount {
            return candidate.undercutRegionCount < current.undercutRegionCount
        }
        if abs(candidate.maximumUndercutDepth - current.maximumUndercutDepth) > tolerance {
            return candidate.maximumUndercutDepth < current.maximumUndercutDepth
        }
        return candidate.totalUndercutDepth < current.totalUndercutDepth - tolerance
    }

    private static func primaryPartingPlaneCandidates(
        reference: MeshGeometryData,
        planeCount: Int
    ) -> [[PartitionPlane]] {
        guard !reference.vertices.isEmpty else { return [] }
        let sum = reference.vertices.reduce(Vec3(x: 0, y: 0, z: 0)) {
            Vec3(x: $0.x + $1.x, y: $0.y + $1.y, z: $0.z + $1.z)
        }
        let count = Double(reference.vertices.count)
        let center = Vec3(x: sum.x / count, y: sum.y / count, z: sum.z / count)
        let axes = [
            Vec3(x: 1, y: 0, z: 0),
            Vec3(x: 0, y: 1, z: 0),
            Vec3(x: 0, y: 0, z: 1),
        ]
        if planeCount == 1 {
            return axes.map { axis in
                let offset = axis.x * center.x + axis.y * center.y + axis.z * center.z
                return [PartitionPlane(normal: axis, offset: offset, isManual: false)]
            }
        }
        let pairs: [(Int, Int)] = [(0, 1), (0, 2), (1, 2)]
        var candidates: [[PartitionPlane]] = []
        for pair in pairs {
            var planes: [PartitionPlane] = []
            for axis in [axes[pair.0], axes[pair.1]] {
                let offset = axis.x * center.x + axis.y * center.y + axis.z * center.z
                planes.append(PartitionPlane(normal: axis, offset: offset, isManual: false))
            }
            candidates.append(planes)
        }
        return candidates
    }

    private static func planePairLabel(_ planes: [PartitionPlane]) -> String {
        let labels = planes.prefix(2).map { plane -> String in
            switch plane.axisAligned {
            case 0: return "X"
            case 1: return "Y"
            case 2: return "Z"
            default: return "oblique"
            }
        }
        return labels.joined(separator: "/")
    }

    /// Drop degenerate (zero-area) triangles, using the SAME area threshold as
    /// `MeshPreflight.isDegenerate` (|2·area|² ≤ 1e-10) so a triangle removed
    /// here is exactly one the watertight gate would have flagged. Vertices are
    /// left untouched (unreferenced ones are harmless). When the kept faces
    /// already form a closed surface this turns a "needs repair" part into a
    /// watertight one; when they don't, the boundary edges remain and Stage 9
    /// still (correctly) rejects the build.
    static func removingDegenerateTriangles(_ geometry: MeshGeometryData) -> MeshGeometryData {
        let verts = geometry.vertices
        let idx = geometry.triangleIndices
        var kept: [Int32] = []
        kept.reserveCapacity(idx.count)
        var t = 0
        while t + 2 < idx.count {
            let ia = Int(idx[t]), ib = Int(idx[t + 1]), ic = Int(idx[t + 2])
            if verts.indices.contains(ia), verts.indices.contains(ib), verts.indices.contains(ic) {
                let a = verts[ia], b = verts[ib], c = verts[ic]
                let abx = b.x - a.x, aby = b.y - a.y, abz = b.z - a.z
                let acx = c.x - a.x, acy = c.y - a.y, acz = c.z - a.z
                let cx = aby * acz - abz * acy
                let cy = abz * acx - abx * acz
                let cz = abx * acy - aby * acx
                if (cx * cx + cy * cy + cz * cz) > 1.0e-10 {
                    kept.append(idx[t]); kept.append(idx[t + 1]); kept.append(idx[t + 2])
                }
            }
            t += 3
        }
        return MeshGeometryData(vertices: verts, triangleIndices: kept)
    }

    /// Build a minimal `MeshSummary` wrapping the given `cavity` geometry, re-using
    /// the metadata from the original `model` (name/path/format/byteCount are
    /// informational and not used by `MoldShellBuilder`).
    private static func makeCavitySummary(
        from model: MeshSummary,
        cavity: MeshGeometryData
    ) -> MeshSummary {
        let preflight = MeshPreflight.analyze(geometry: cavity)
        var minV = Vec3(x: Double.infinity, y: .infinity, z: .infinity)
        var maxV = Vec3(x: -.infinity, y: -.infinity, z: -.infinity)
        for v in cavity.vertices {
            minV.x = Swift.min(minV.x, v.x)
            minV.y = Swift.min(minV.y, v.y)
            minV.z = Swift.min(minV.z, v.z)
            maxV.x = Swift.max(maxV.x, v.x)
            maxV.y = Swift.max(maxV.y, v.y)
            maxV.z = Swift.max(maxV.z, v.z)
        }
        let bounds: Bounds3D? = cavity.vertices.isEmpty
            ? nil
            : Bounds3D(min: minV, max: maxV)
        return MeshSummary(
            name: model.name,
            path: model.path,
            format: model.format,
            byteCount: model.byteCount,
            vertexObservationCount: cavity.vertices.count,
            faceCount: cavity.triangleIndices.count / 3,
            triangleCount: cavity.triangleIndices.count / 3,
            bounds: bounds,
            geometry: cavity,
            preflight: preflight
        )
    }

    /// Derive each part's pull direction from the partition half-spaces that part
    /// actually occupies. This is independent of the order Manifold returns split
    /// pieces, which is not a semantic contract.
    private static func demoldAxesFor(
        parts: [MotherMoldPart],
        planes: [PartitionPlane],
        openPlane: PartitionPlane
    ) -> [Vec3] {
        guard !parts.isEmpty else { return [] }

        if parts.count == 1 {
            return [normalized(openPlane.normal)]
        }

        guard !planes.isEmpty else {
            return parts.map { _ in normalized(openPlane.normal) }
        }

        return parts.map { part in
            var axis = Vec3(x: 0, y: 0, z: 0)
            for plane in planes {
                let equation = PartitionGeometry.PlaneEq(
                    normal: plane.normal,
                    offset: plane.offset
                )
                let sign = partKeepsPositive(part, plane: equation) ? 1.0 : -1.0
                axis.x += equation.n.x * sign
                axis.y += equation.n.y * sign
                axis.z += equation.n.z * sign
            }
            return normalized(axis, fallback: openPlane.normal)
        }
    }

    private static func partKeepsPositive(
        _ part: MotherMoldPart,
        plane: PartitionGeometry.PlaneEq
    ) -> Bool {
        let tolerance = 1.0e-6
        var positiveCount = 0
        var negativeCount = 0
        var signedSum = 0.0
        for vertex in part.geometry.vertices {
            let signed = PartitionGeometry.signed(vertex, plane)
            signedSum += signed
            if signed > tolerance { positiveCount += 1 }
            if signed < -tolerance { negativeCount += 1 }
        }
        if positiveCount != negativeCount { return positiveCount > negativeCount }
        return signedSum >= 0
    }

    private static func normalized(
        _ value: Vec3,
        fallback: Vec3 = Vec3(x: 0, y: 0, z: 1)
    ) -> Vec3 {
        let length = (value.x * value.x + value.y * value.y + value.z * value.z).squareRoot()
        if length > 1.0e-12 {
            return Vec3(x: value.x / length, y: value.y / length, z: value.z / length)
        }
        let fallbackLength = (fallback.x * fallback.x + fallback.y * fallback.y + fallback.z * fallback.z).squareRoot()
        guard fallbackLength > 1.0e-12 else { return Vec3(x: 0, y: 0, z: 1) }
        return Vec3(
            x: fallback.x / fallbackLength,
            y: fallback.y / fallbackLength,
            z: fallback.z / fallbackLength
        )
    }

    private static func materialEstimates(
        parts: [MotherMoldPart],
        cavity: MeshGeometryData,
        master: MeshGeometryData,
        settings: MotherMoldSettings
    ) -> (printedPlasticCC: Double, estimatedSiliconeCC: Double?) {
        let printedPlasticCC = parts
            .map { abs(MoldComponentFilter.signedVolume($0.geometry)) / 1000.0 }
            .reduce(0, +)
        guard settings.subtype == .siliconeJacket else {
            return (printedPlasticCC, nil)
        }
        let cavityCC = abs(MoldComponentFilter.signedVolume(cavity)) / 1000.0
        let masterCC = abs(MoldComponentFilter.signedVolume(master)) / 1000.0
        return (printedPlasticCC, max(0, cavityCC - masterCC))
    }

    private static func positiveOverlapDescriptions(_ parts: [MotherMoldPart]) -> [String] {
        var descriptions: [String] = []
        for firstIndex in parts.indices {
            for secondIndex in parts.indices where secondIndex > firstIndex {
                do {
                    let first = try ManifoldEngine.make(from: parts[firstIndex].geometry)
                    let second = try ManifoldEngine.make(from: parts[secondIndex].geometry)
                    let intersection = try ManifoldEngine.intersect(first, second)
                    let volume = abs(ManifoldEngine.volume(intersection))
                    if volume > 0.01 {
                        descriptions.append(String(
                            format: "%@/%@ %.3f mm^3",
                            parts[firstIndex].name,
                            parts[secondIndex].name,
                            volume
                        ))
                    }
                    withExtendedLifetime(first) {}
                    withExtendedLifetime(second) {}
                    withExtendedLifetime(intersection) {}
                } catch {
                    descriptions.append("\(parts[firstIndex].name)/\(parts[secondIndex].name) check failed")
                }
            }
        }
        return descriptions
    }

    private static func materialEstimateMessage(
        _ material: (printedPlasticCC: Double, estimatedSiliconeCC: Double?)
    ) -> String {
        if let silicone = material.estimatedSiliconeCC {
            return String(
                format: "Material estimates: Printed plastic %.1f cc; Estimated silicone %.1f cc.",
                material.printedPlasticCC,
                silicone
            )
        }
        return String(
            format: "Material estimates: Printed plastic %.1f cc.",
            material.printedPlasticCC
        )
    }
}
