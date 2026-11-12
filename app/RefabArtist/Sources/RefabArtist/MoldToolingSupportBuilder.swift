import Foundation

/// A rigid contribution to one phase-specific tooling assembly.  Mass and
/// balance data are evidence, not estimates: leaving either absent intentionally
/// prevents a bare support verdict from becoming stable.
struct MoldToolingSupportRigidArtifact: Equatable {
    var id: ToolingArtifactID
    var geometry: MeshGeometryData
    var massGrams: Double?
    var centerOfGravity: Vec3Codable?
    var permitsCradleContact: Bool

    init(
        id: ToolingArtifactID,
        geometry: MeshGeometryData,
        massGrams: Double? = nil,
        centerOfGravity: Vec3Codable? = nil,
        permitsCradleContact: Bool = true
    ) {
        self.id = id
        self.geometry = geometry
        self.massGrams = massGrams
        self.centerOfGravity = centerOfGravity
        self.permitsCradleContact = permitsCradleContact
    }
}

/// The exact, gate-reachable liquid space for a phase.  The solid must already
/// include the funnel/gate/vent volume that can actually fill in this phase.
struct MoldToolingSupportLiquidVolume: Equatable {
    var id: String
    var reachableGeometry: MeshGeometryData
    var densityGramsPerCC: Double?

    init(id: String, reachableGeometry: MeshGeometryData, densityGramsPerCC: Double?) {
        self.id = id
        self.reachableGeometry = reachableGeometry
        self.densityGramsPerCC = densityGramsPerCC
    }
}

struct MoldToolingSupportReservedVolume: Equatable {
    var id: String
    var purpose: String
    var geometry: MeshGeometryData

    init(id: String, purpose: String, geometry: MeshGeometryData) {
        self.id = id
        self.purpose = purpose
        self.geometry = geometry
    }
}

/// Build-space evidence is intentionally separate from calibrated load
/// evidence.  A stand can fit a printer and still remain geometry-only.
struct MoldToolingSupportPrinterEnvelope: Equatable {
    var profileID: String
    var buildExtentsMillimeters: Vec3Codable
    var minimumFeatureMillimeters: Double

    init(profileID: String, buildExtentsMillimeters: Vec3Codable, minimumFeatureMillimeters: Double) {
        self.profileID = profileID
        self.buildExtentsMillimeters = buildExtentsMillimeters
        self.minimumFeatureMillimeters = minimumFeatureMillimeters
    }
}

/// Physically calibrated capacity for one exact cradle geometry/profile pair.
/// All ratings are required because the phase proof is a combined vertical,
/// lateral, overturning, and pad/strap reaction proof rather than a cosmetic
/// geometry check.
struct MoldToolingSupportLoadEvidence: Equatable {
    var profileID: String
    var cradleGeometryFingerprint: String
    var envelope: ToolingSupportLoadEnvelope
    var ratedVerticalNewtons: Double
    var ratedLateralNewtons: Double
    var ratedOverturningNewtonMillimeters: Double
    var ratedContactOrStrapNewtons: Double

    init(
        profileID: String,
        cradleGeometryFingerprint: String,
        envelope: ToolingSupportLoadEnvelope,
        ratedVerticalNewtons: Double,
        ratedLateralNewtons: Double,
        ratedOverturningNewtonMillimeters: Double,
        ratedContactOrStrapNewtons: Double
    ) {
        self.profileID = profileID
        self.cradleGeometryFingerprint = cradleGeometryFingerprint
        self.envelope = envelope
        self.ratedVerticalNewtons = ratedVerticalNewtons
        self.ratedLateralNewtons = ratedLateralNewtons
        self.ratedOverturningNewtonMillimeters = ratedOverturningNewtonMillimeters
        self.ratedContactOrStrapNewtons = ratedContactOrStrapNewtons
    }
}

struct MoldToolingSupportPhaseInput: Equatable {
    var phase: ToolingPhase
    var gravityUpAxis: Vec3Codable
    var rigidArtifacts: [MoldToolingSupportRigidArtifact]
    var liquid: MoldToolingSupportLiquidVolume
    var supportMode: ToolingSupportMode
    var manualSupportPlane: SupportPlaneSettings?
    var minimumSupportMarginMillimeters: Double
    var reservedVolumes: [MoldToolingSupportReservedVolume]
    var printerEnvelope: MoldToolingSupportPrinterEnvelope?
    var loadEvidence: MoldToolingSupportLoadEvidence?
    var seed: Int

    init(
        phase: ToolingPhase,
        gravityUpAxis: Vec3Codable,
        rigidArtifacts: [MoldToolingSupportRigidArtifact],
        liquid: MoldToolingSupportLiquidVolume,
        supportMode: ToolingSupportMode = .automatic,
        manualSupportPlane: SupportPlaneSettings? = nil,
        minimumSupportMarginMillimeters: Double = 0,
        reservedVolumes: [MoldToolingSupportReservedVolume] = [],
        printerEnvelope: MoldToolingSupportPrinterEnvelope? = nil,
        loadEvidence: MoldToolingSupportLoadEvidence? = nil,
        seed: Int = 0
    ) {
        self.phase = phase
        self.gravityUpAxis = gravityUpAxis
        self.rigidArtifacts = rigidArtifacts
        self.liquid = liquid
        self.supportMode = supportMode
        self.manualSupportPlane = manualSupportPlane
        self.minimumSupportMarginMillimeters = minimumSupportMarginMillimeters
        self.reservedVolumes = reservedVolumes
        self.printerEnvelope = printerEnvelope
        self.loadEvidence = loadEvidence
        self.seed = seed
    }
}

enum MoldToolingSupportQualificationState: String, Equatable {
    case stableWithoutCradle
    case supportGeometryOnly
    case printerFitNotChecked
    case qualified
    case blocked
}

enum MoldToolingSupportContactRole: String, Equatable {
    case gravitySupport
    case lateralRestraint
}

struct MoldToolingSupportContact: Equatable {
    var point: Vec3Codable
    var regionAreaSquareMillimeters: Double
    var rigidArtifactIDs: [ToolingArtifactID]
    var tangentNormal: Vec3Codable?
    var tangentGapMillimeters: Double?
    var role: MoldToolingSupportContactRole

    init(
        point: Vec3Codable,
        regionAreaSquareMillimeters: Double,
        rigidArtifactIDs: [ToolingArtifactID],
        tangentNormal: Vec3Codable? = nil,
        tangentGapMillimeters: Double? = nil,
        role: MoldToolingSupportContactRole = .gravitySupport
    ) {
        self.point = point
        self.regionAreaSquareMillimeters = regionAreaSquareMillimeters
        self.rigidArtifactIDs = rigidArtifactIDs
        self.tangentNormal = tangentNormal
        self.tangentGapMillimeters = tangentGapMillimeters
        self.role = role
    }
}

struct MoldToolingSupportMassInterval: Equatable {
    var stateID: String
    var minimumMassGrams: Double
    var maximumMassGrams: Double?
    var centerOfGravityKnown: Bool
}

struct MoldToolingSupportMassState: Equatable {
    var id: String
    var fillPlaneOffsetMillimeters: Double
    var fillFraction: Double
    var liquidVolumeCubicMillimeters: Double
    var liquidCentroid: Vec3Codable?
    var massGrams: Double?
    var centerOfGravity: Vec3Codable?
    var projectedMarginMillimeters: Double?
    var tiltMarginRequiredMillimeters: Double?
}

struct MoldToolingSupportResult: Equatable {
    var summary: ToolingSupportSummary
    var qualificationState: MoldToolingSupportQualificationState
    var artifacts: [ToolingArtifact]
    var contacts: [MoldToolingSupportContact]
    var strapClampPoints: [Vec3Codable]
    var massStates: [MoldToolingSupportMassState]
    var massIntervals: [MoldToolingSupportMassInterval]
    var diagnostics: [MoldDiagnostic]
    var cradleGeometryFingerprint: String?
    var independentConstraintRank: Int = 0
}

enum MoldToolingSupportBuilderError: LocalizedError, Equatable {
    case invalidPhase
    case zeroGravityAxis
    case invalidMinimumMargin
    case invalidLiquidDensity
    case invalidPrinterEnvelope
    case noRigidGeometry
    case invalidRigidGeometry(String)
    case invalidLiquidGeometry(String)
    case clippingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPhase: return "Support analysis is only defined for liner-fill or casting phases."
        case .zeroGravityAxis: return "The phase gravity-up axis must be a finite non-zero vector."
        case .invalidMinimumMargin: return "The minimum support margin must be finite and non-negative."
        case .invalidLiquidDensity: return "A supplied liquid density must be finite and greater than zero g/cc."
        case .invalidPrinterEnvelope: return "The printer envelope must have finite positive build dimensions and a non-negative minimum feature."
        case .noRigidGeometry: return "The phase assembly has no rigid geometry to support."
        case .invalidRigidGeometry(let id): return "Rigid artifact \(id) is not a closed, non-empty solid."
        case .invalidLiquidGeometry(let id): return "Reachable liquid volume \(id) is not a closed, non-empty solid."
        case .clippingFailed(let detail): return "Exact liquid clipping failed: \(detail)"
        }
    }
}

/// Exact phase support analysis.  It intentionally has no bounding-box volume
/// or stability fallback: every liquid state uses Manifold clipping and every
/// free-standing verdict uses the measured support polygon.
enum MoldToolingSupportBuilder {
    private static let epsilon = 1.0e-6
    private static let contactTolerance = 0.05
    private static let gravity = 9.80665
    private static let tiltRadians = 10.0 * .pi / 180.0

    static func evaluate(_ input: MoldToolingSupportPhaseInput) throws -> MoldToolingSupportResult {
        let up = try validate(input)
        let rigid = try input.rigidArtifacts.map { artifact -> (MoldToolingSupportRigidArtifact, VolumeIntegral) in
            let manifold = try manifold(for: artifact.geometry, invalid: .invalidRigidGeometry(artifact.id.rawValue))
            let canonicalGeometry = try ManifoldEngine.toMesh(manifold)
            var canonicalArtifact = artifact
            canonicalArtifact.geometry = canonicalGeometry
            return (canonicalArtifact, try integral(canonicalGeometry))
        }
        let liquidManifold = try manifold(for: input.liquid.reachableGeometry, invalid: .invalidLiquidGeometry(input.liquid.id))
        let liquidMesh = try ManifoldEngine.toMesh(liquidManifold)
        let liquidIntegral = try integral(liquidMesh)
        guard liquidIntegral.volume > epsilon else { throw MoldToolingSupportBuilderError.invalidLiquidGeometry(input.liquid.id) }

        let rigidVertices = rigid.flatMap { $0.0.geometry.vertices }
        guard !rigidVertices.isEmpty else { throw MoldToolingSupportBuilderError.noRigidGeometry }
        let lowestRigidOffset = rigidVertices.map { dot($0, up) }.min() ?? 0
        if let manual = input.manualSupportPlane {
            let manualNormal = vec(manual.normal)
            let manualOffset = dot(vec(manual.origin), up)
            guard finite(manualNormal), length(manualNormal) > epsilon,
                  abs(abs(dot(normalized(manualNormal), up)) - 1) <= 1e-5,
                  abs(manualOffset - lowestRigidOffset) <= contactTolerance else {
                return earlyBlocked(input: input, up: up, message: "The manual support plane is not horizontal under this phase gravity vector or does not meet the assembly's lowest rigid contact surface.")
            }
        }
        let supportPlane = try candidatePlane(input: input, up: up, rigidVertices: rigidVertices)
        let barePatches = horizontalPatches(
            artifacts: rigid.map(\.0),
            planeOffset: supportPlane.offset,
            up: up
        )
        let bareContacts = barePatches.map { contact(for: $0, role: .gravitySupport) }
        let bareHull = convexHull(barePatches.flatMap { $0.vertices.map { project($0, basis: supportPlane.basis) } })
        let span = assemblySpan(rigidVertices)
        let requiredMargin = max(input.minimumSupportMarginMillimeters, 10, span * 0.05)

        let offsets = fillOffsets(vertices: liquidMesh.vertices, up: up)
        var massStates: [MoldToolingSupportMassState] = []
        var intervals: [MoldToolingSupportMassInterval] = []
        massStates.reserveCapacity(offsets.count)
        intervals.reserveCapacity(offsets.count)

        let completeRigidMass = rigid.allSatisfy { $0.0.massGrams != nil && $0.0.centerOfGravity != nil }
        let completeLiquidMass = input.liquid.densityGramsPerCC != nil
        for (index, offset) in offsets.enumerated() {
            let liquidState: VolumeIntegral
            do {
                if index == 0 {
                    liquidState = .zero
                } else if index == offsets.count - 1 {
                    liquidState = liquidIntegral
                } else {
                    let clip = try ManifoldEngine.trimByPlane(liquidManifold, normal: scale(up, -1), offset: -offset)
                    liquidState = ManifoldEngine.isEmpty(clip) ? .zero : try integral(ManifoldEngine.toMesh(clip))
                }
            } catch {
                throw MoldToolingSupportBuilderError.clippingFailed(error.localizedDescription)
            }

            let fraction = liquidIntegral.volume > epsilon ? liquidState.volume / liquidIntegral.volume : 0
            let stateID = "\(input.phase.rawValue)-\(String(format: "%04d", index))"
            let exact = completeRigidMass && completeLiquidMass
            var knownMass = 0.0
            var moment = Vec3(x: 0, y: 0, z: 0)
            for (artifact, _) in rigid {
                if let mass = artifact.massGrams, let center = artifact.centerOfGravity {
                    knownMass += mass
                    moment = add(moment, scale(vec(center), mass))
                }
            }
            if let density = input.liquid.densityGramsPerCC, let center = liquidState.centroid {
                let liquidMass = density * liquidState.volume / 1_000.0
                knownMass += liquidMass
                moment = add(moment, scale(center, liquidMass))
            }

            let center = exact && knownMass > epsilon ? scale(moment, 1 / knownMass) : nil
            let margin = center.flatMap { polygonMargin(project($0, basis: supportPlane.basis), hull: bareHull) }
            let height = center.map { max(0, dot(subtract($0, supportPlane.point), up)) }
            let tiltMargin = height.map { $0 * tan(tiltRadians) }
            massStates.append(MoldToolingSupportMassState(
                id: stateID,
                fillPlaneOffsetMillimeters: offset,
                fillFraction: fraction,
                liquidVolumeCubicMillimeters: liquidState.volume,
                liquidCentroid: liquidState.centroid.map(codable),
                massGrams: exact ? knownMass : nil,
                centerOfGravity: center.map(codable),
                projectedMarginMillimeters: margin,
                tiltMarginRequiredMillimeters: tiltMargin
            ))
            intervals.append(MoldToolingSupportMassInterval(
                stateID: stateID,
                minimumMassGrams: knownMass,
                maximumMassGrams: exact ? knownMass : nil,
                centerOfGravityKnown: exact
            ))
        }

        let bareGeometryPasses = bareHull.count >= 3 && polygonArea(bareHull) > epsilon
        let bareStable = completeRigidMass && completeLiquidMass && bareGeometryPasses && massStates.allSatisfy {
            guard let margin = $0.projectedMarginMillimeters, let tilt = $0.tiltMarginRequiredMillimeters else { return false }
            return margin >= requiredMargin - epsilon && margin >= tilt - epsilon
        }

        let bareNotes = supportNotes(
            contacts: bareContacts,
            hull: bareHull,
            requiredMargin: requiredMargin,
            massComplete: completeRigidMass && completeLiquidMass,
            stable: bareStable
        )
        if bareStable {
            let summary = ToolingSupportSummary(
                phase: input.phase,
                state: .stableWithoutCradle,
                gravityUpAxis: codable(up),
                massStates: massStates.map(toolingMassState),
                supportContacts: bareContacts.map(\.point),
                minimumSupportMarginMillimeters: massStates.compactMap(\.projectedMarginMillimeters).min(),
                notes: bareNotes
            )
            return MoldToolingSupportResult(
                summary: summary,
                qualificationState: .stableWithoutCradle,
                artifacts: [], contacts: bareContacts, strapClampPoints: [], massStates: massStates, massIntervals: intervals,
                diagnostics: [], cradleGeometryFingerprint: nil
            )
        }

        if input.supportMode == .manual {
            return blockedResult(
                input: input, up: up, states: massStates, intervals: intervals,
                contacts: bareContacts, requiredMargin: requiredMargin,
                message: "The manual support plane did not pass every measured support-polygon, mass, and 10-degree tilt gate.",
                action: .reorientLinerFill
            )
        }

        guard let cradle = try generateCradle(
            input: input,
            artifacts: rigid.map(\.0),
            up: up,
            supportPlane: supportPlane,
            rigidVertices: rigidVertices,
            requiredMargin: requiredMargin
        ) else {
            let permitsExternalSupport = rigid.contains { $0.0.permitsCradleContact }
            if permitsExternalSupport && (!completeRigidMass || !completeLiquidMass) {
                let contactStatus = bareGeometryPasses
                    ? "The assembled mold has a measured non-collinear support polygon"
                    : "The assembled mold does not have a measured stable bare support polygon"
                let message = "\(contactStatus), and mass or center-of-gravity data is incomplete. No unobstructed cradle could be generated; phase stability remains unqualified and external support or clamping is required until physical measurements are supplied."
                let diagnostic = MoldDiagnostic(
                    .warning,
                    message,
                    subsystem: .support,
                    code: .physicalEvidenceRequired,
                    recoveryActions: [.reviewAssemblyGuide]
                )
                let summary = ToolingSupportSummary(
                    phase: input.phase,
                    state: .pendingMeasurement,
                    gravityUpAxis: codable(up),
                    massStates: massStates.map(toolingMassState),
                    supportContacts: bareContacts.map(\.point),
                    minimumSupportMarginMillimeters: nil,
                    notes: bareNotes + [message]
                )
                return MoldToolingSupportResult(
                    summary: summary,
                    qualificationState: .supportGeometryOnly,
                    artifacts: [],
                    contacts: bareContacts,
                    strapClampPoints: [],
                    massStates: massStates,
                    massIntervals: intervals,
                    diagnostics: [diagnostic],
                    cradleGeometryFingerprint: nil
                )
            }
            return blockedResult(
                input: input, up: up, states: massStates, intervals: intervals,
                contacts: bareContacts, requiredMargin: requiredMargin,
                message: "No phase cradle could positively locate on three non-collinear non-art contact regions without obstructing a reserved port, fastener, or demold sweep.",
                action: input.phase == .linerFill ? .reorientLinerFill : .reorientCasting
            )
        }

        let finalMargins = massStates.compactMap { state -> Double? in
            guard let center = state.centerOfGravity else { return nil }
            return polygonMargin(project(vec(center), basis: cradle.baseBasis), hull: cradle.supportHull)
        }
        let maxTiltRequirement = massStates.compactMap(\.tiltMarginRequiredMillimeters).max() ?? .infinity
        let finalMargin = finalMargins.min()
        if completeRigidMass && completeLiquidMass && (finalMargin == nil || finalMargin! < requiredMargin - epsilon || finalMargin! < maxTiltRequirement - epsilon) {
            return blockedResult(
                input: input, up: up, states: massStates, intervals: intervals,
                contacts: cradle.contacts, requiredMargin: requiredMargin,
                message: "The generated phase cradle did not prove a complete mass envelope, required support margin, and 10-degree tilt margin.",
                action: input.phase == .linerFill ? .reorientLinerFill : .reorientCasting
            )
        }

        let fingerprint = geometryFingerprint(cradle.geometry)
        let fitState = printerFitState(cradle.geometry, printer: input.printerEnvelope)
        guard fitState != .blocked else {
            return blockedResult(
                input: input, up: up, states: massStates, intervals: intervals,
                contacts: cradle.contacts, requiredMargin: requiredMargin,
                message: "The generated phase cradle does not fit the selected printer/material envelope.",
                action: .selectPrinterProfile
            )
        }
        let reactions = supportReactions(massStates: massStates, plane: cradle.basePlane, up: up)
        let calibratedLoadsMatch = completeRigidMass && completeLiquidMass && qualification(
            evidence: input.loadEvidence,
            fingerprint: fingerprint,
            printer: input.printerEnvelope,
            reactions: reactions
        )
        // Bounds alone do not validate generated minimum features or a print
        // orientation, so this builder cannot promote the artifact/profile pair.
        let state: MoldToolingSupportQualificationState = .printerFitNotChecked
        let toolingState: ToolingSupportState = .supportGeometryOnly
        let artifact = ToolingArtifact(
            id: ToolingArtifactID(input.phase == .linerFill ? "LINER FILL STAND" : "CASTING STAND"),
            name: input.phase == .linerFill ? "LINER FILL STAND" : "CASTING STAND",
            role: .supportCradle,
            geometry: cradle.geometry,
            qualification: .topologyValid,
            materialHint: "Phase-labeled support cradle",
            quantity: 1
        )
        var notes = bareNotes
        notes.append("Generated \(artifact.name) has a unique seating orientation: three non-collinear finite gravity pads plus \(cradle.constraintRank) independent rigid lateral/yaw constraints measured from eligible non-art surfaces.")
        if !completeRigidMass || !completeLiquidMass { notes.append("Mass or center-of-gravity evidence is incomplete; strap/clamp attachment points are available, but no strap is structural or load-qualified without matching calibrated evidence.") }
        notes.append(calibratedLoadsMatch ? "Calibrated vertical, lateral, overturning, and contact/strap loads match this geometry, but printer feature/orientation validation remains separate." : "No matching calibrated load envelope; support remains geometry-only.")
        if input.printerEnvelope == nil {
            notes.append("Printer fit not checked because no printer/material envelope was supplied.")
        } else {
            notes.append("The cradle fits the supplied build bounds, but minimum-feature and recommended-orientation evidence is profile-unverified.")
        }
        let summary = ToolingSupportSummary(
            phase: input.phase,
            state: toolingState,
            gravityUpAxis: codable(up),
            massStates: massStates.map(toolingMassState),
            supportContacts: cradle.contacts.map(\.point),
            minimumSupportMarginMillimeters: finalMargin,
            cradleArtifactIDs: [artifact.id],
            loadEnvelope: input.loadEvidence?.envelope,
            notes: notes
        )
        return MoldToolingSupportResult(
            summary: summary, qualificationState: state, artifacts: [artifact], contacts: cradle.contacts, strapClampPoints: cradle.strapClampPoints,
            massStates: massStates, massIntervals: intervals, diagnostics: [], cradleGeometryFingerprint: fingerprint,
            independentConstraintRank: cradle.constraintRank
        )
    }
}

private extension MoldToolingSupportBuilder {
    struct VectorBasis { var origin: Vec3; var u: Vec3; var v: Vec3; var normal: Vec3 }
    struct Plane { var point: Vec3; var offset: Double; var basis: VectorBasis }
    struct Point2: Equatable { var x: Double; var y: Double }
    struct VolumeIntegral { var volume: Double; var centroid: Vec3?; static let zero = VolumeIntegral(volume: 0, centroid: nil) }
    struct SurfacePatch { var artifactID: ToolingArtifactID; var vertices: [Vec3]; var centroid: Vec3; var area: Double; var normal: Vec3 }
    struct ContactClaim { var patch: SurfacePatch; var role: MoldToolingSupportContactRole }
    struct Cradle { var geometry: MeshGeometryData; var contacts: [MoldToolingSupportContact]; var strapClampPoints: [Vec3Codable]; var supportHull: [Point2]; var baseBasis: VectorBasis; var basePlane: Plane; var constraintRank: Int }

    static func validate(_ input: MoldToolingSupportPhaseInput) throws -> Vec3 {
        guard input.phase == .linerFill || input.phase == .casting else { throw MoldToolingSupportBuilderError.invalidPhase }
        let up = vec(input.gravityUpAxis)
        guard finite(up), length(up) > epsilon else { throw MoldToolingSupportBuilderError.zeroGravityAxis }
        guard input.minimumSupportMarginMillimeters.isFinite, input.minimumSupportMarginMillimeters >= 0 else { throw MoldToolingSupportBuilderError.invalidMinimumMargin }
        if let density = input.liquid.densityGramsPerCC, (!density.isFinite || density <= 0) { throw MoldToolingSupportBuilderError.invalidLiquidDensity }
        if let printer = input.printerEnvelope {
            let e = vec(printer.buildExtentsMillimeters)
            guard finite(e), e.x > 0, e.y > 0, e.z > 0, printer.minimumFeatureMillimeters.isFinite, printer.minimumFeatureMillimeters >= 0 else {
                throw MoldToolingSupportBuilderError.invalidPrinterEnvelope
            }
        }
        guard !input.rigidArtifacts.isEmpty else { throw MoldToolingSupportBuilderError.noRigidGeometry }
        return (normalized(up))
    }

    static func manifold(for geometry: MeshGeometryData, invalid: MoldToolingSupportBuilderError) throws -> ManifoldHandle {
        guard MotherMoldValidation.hasFiniteCoordinates(geometry), MotherMoldValidation.surfaceClosure(geometry).closed else { throw invalid }
        do {
            let handle = try ManifoldEngine.make(from: geometry)
            guard ManifoldEngine.isWatertight(handle), !ManifoldEngine.isEmpty(handle) else { throw invalid }
            return handle
        } catch let error as MoldToolingSupportBuilderError { throw error }
        catch { throw invalid }
    }

    static func candidatePlane(input: MoldToolingSupportPhaseInput, up: Vec3, rigidVertices: [Vec3]) throws -> Plane {
        let minOffset = rigidVertices.map { dot($0, up) }.min() ?? 0
        if let manual = input.manualSupportPlane {
            let normal = vec(manual.normal)
            guard finite(normal), length(normal) > epsilon, abs(abs(dot(normalized(normal), up)) - 1) <= 1e-5 else { return plane(offset: minOffset, up: up) }
            let offset = dot(vec(manual.origin), up)
            return plane(offset: offset, up: up)
        }
        return plane(offset: minOffset, up: up)
    }

    static func plane(offset: Double, up: Vec3) -> Plane {
        let origin = scale(up, offset)
        let helper = abs(up.z) < 0.9 ? Vec3(x: 0, y: 0, z: 1) : Vec3(x: 1, y: 0, z: 0)
        let u = normalized(cross(helper, up))
        let v = normalized(cross(up, u))
        return Plane(point: origin, offset: offset, basis: VectorBasis(origin: origin, u: u, v: v, normal: up))
    }

    /// Contact evidence is a finite triangle patch lying on the support plane.
    /// Edge crossings are deliberately excluded: they are points/lines, not a
    /// region that can carry a measured reaction.
    static func horizontalPatches(artifacts: [MoldToolingSupportRigidArtifact], planeOffset: Double, up: Vec3) -> [SurfacePatch] {
        surfacePatches(artifacts: artifacts).compactMap { patch in
            guard patch.vertices.allSatisfy({ abs(dot($0, up) - planeOffset) <= contactTolerance }),
                  abs(abs(dot(patch.normal, up)) - 1) <= 1e-4 else { return nil }
            return patch
        }.sorted { lexicographic($0.centroid, $1.centroid) }
    }

    static func surfacePatches(artifacts: [MoldToolingSupportRigidArtifact]) -> [SurfacePatch] {
        artifacts.flatMap { artifact -> [SurfacePatch] in
            var patches: [SurfacePatch] = []
            var index = 0
            while index + 2 < artifact.geometry.triangleIndices.count {
                let ids = [Int(artifact.geometry.triangleIndices[index]), Int(artifact.geometry.triangleIndices[index + 1]), Int(artifact.geometry.triangleIndices[index + 2])]
                guard ids.allSatisfy(artifact.geometry.vertices.indices.contains) else { index += 3; continue }
                let vertices = ids.map { artifact.geometry.vertices[$0] }
                let doubledAreaVector = cross(subtract(vertices[1], vertices[0]), subtract(vertices[2], vertices[0]))
                let doubledArea = length(doubledAreaVector)
                guard doubledArea > epsilon else { index += 3; continue }
                let centroid = scale(add(add(vertices[0], vertices[1]), vertices[2]), 1 / 3)
                let normal = scale(doubledAreaVector, 1 / doubledArea)
                patches.append(SurfacePatch(artifactID: artifact.id, vertices: vertices, centroid: centroid, area: doubledArea / 2, normal: normal))
                index += 3
            }
            return patches
        }
    }

    static func contact(for patch: SurfacePatch, role: MoldToolingSupportContactRole) -> MoldToolingSupportContact {
        MoldToolingSupportContact(
            point: codable(patch.centroid),
            regionAreaSquareMillimeters: patch.area,
            rigidArtifactIDs: [patch.artifactID],
            tangentNormal: codable(patch.normal),
            tangentGapMillimeters: 0,
            role: role
        )
    }

    static func fillOffsets(vertices: [Vec3], up: Vec3) -> [Double] {
        let values = Array(Set(vertices.map { (dot($0, up) * 1_000_000).rounded() / 1_000_000 })).sorted()
        guard let first = values.first, let last = values.last else { return [0] }
        var result = Set(values)
        var next = ceil(first)
        while next < last - epsilon { result.insert(next); next += 1 }
        result.insert(first); result.insert(last)
        return result.sorted()
    }

    static func integral(_ mesh: MeshGeometryData) throws -> VolumeIntegral {
        var volume = 0.0
        var moment = Vec3(x: 0, y: 0, z: 0)
        var i = 0
        while i + 2 < mesh.triangleIndices.count {
            let a = Int(mesh.triangleIndices[i]), b = Int(mesh.triangleIndices[i + 1]), c = Int(mesh.triangleIndices[i + 2])
            guard mesh.vertices.indices.contains(a), mesh.vertices.indices.contains(b), mesh.vertices.indices.contains(c) else {
                throw MoldToolingSupportBuilderError.clippingFailed("mesh contains an invalid triangle index")
            }
            let va = mesh.vertices[a], vb = mesh.vertices[b], vc = mesh.vertices[c]
            let signed = dot(va, cross(vb, vc)) / 6
            volume += signed
            moment = add(moment, scale(add(add(va, vb), vc), signed / 4))
            i += 3
        }
        guard abs(volume) > epsilon else { return .zero }
        if volume < 0 { volume = -volume; moment = scale(moment, -1) }
        return VolumeIntegral(volume: volume, centroid: scale(moment, 1 / volume))
    }

    static func generateCradle(
        input: MoldToolingSupportPhaseInput, artifacts: [MoldToolingSupportRigidArtifact], up: Vec3, supportPlane: Plane, rigidVertices: [Vec3],
        requiredMargin: Double
    ) throws -> Cradle? {
        let eligible = artifacts.filter(\.permitsCradleContact)
        let allEligiblePatches = surfacePatches(artifacts: eligible)
        let assemblyHeight = rigidVertices.map { dot(subtract($0, supportPlane.point), up) }.max() ?? 0
        let conformalPatches = selectConformalPatches(
            from: allEligiblePatches,
            supportPlane: supportPlane,
            assemblyHeight: assemblyHeight,
            up: up
        )
        let gravityPatches: [SurfacePatch]
        let lateralPatches: [SurfacePatch]
        if conformalPatches.count >= 3 {
            gravityPatches = conformalPatches
            lateralPatches = []
        } else {
            let horizontal = horizontalPatches(artifacts: eligible, planeOffset: supportPlane.offset, up: up)
            gravityPatches = selectGravityPatches(from: horizontal, up: up)
            lateralPatches = selectLateralPatches(from: allEligiblePatches, up: up, basis: supportPlane.basis)
        }
        guard gravityPatches.count >= 3 else { return nil }
        let supportHull = convexHull(gravityPatches.flatMap { $0.vertices.map { project($0, basis: supportPlane.basis) } })
        guard polygonArea(supportHull) > epsilon else { return nil }
        let extensionMargin = requiredMargin + max(0, assemblyHeight) * tan(tiltRadians) + 12
        let allProjected = rigidVertices.map { project($0, basis: supportPlane.basis) }
        guard let minX = allProjected.map(\.x).min(), let maxX = allProjected.map(\.x).max(),
              let minY = allProjected.map(\.y).min(), let maxY = allProjected.map(\.y).max() else { return nil }
        let basePlane = plane(offset: supportPlane.offset - 4, up: up)
        let baseTopPlane = plane(offset: supportPlane.offset - 2, up: up)
        let baseCenter = point3(Point2(x: (minX + maxX) / 2, y: (minY + maxY) / 2), basis: basePlane.basis)
        let baseHull = [
            Point2(x: minX - extensionMargin, y: minY - extensionMargin), Point2(x: maxX + extensionMargin, y: minY - extensionMargin),
            Point2(x: maxX + extensionMargin, y: maxY + extensionMargin), Point2(x: minX - extensionMargin, y: maxY + extensionMargin)
        ]
        let base = orientedBox(center: baseCenter, basis: basePlane.basis, width: maxX - minX + 2 * extensionMargin, depth: maxY - minY + 2 * extensionMargin, height: 4)
        var solids = [base]
        let claims = gravityPatches.map { ContactClaim(patch: $0, role: .gravitySupport) }
            + lateralPatches.map { ContactClaim(patch: $0, role: .lateralRestraint) }
        var strapClampPoints: [Vec3Codable] = []
        for claim in claims {
            solids.append(contentsOf: contactSupportSolids(for: claim.patch, baseTopPlane: baseTopPlane))
        }
        // Attachment lugs are deliberately available on every generated cradle.
        // Their presence does not claim a load-rated strap; qualification still
        // requires the matching calibrated envelope below.
        for point2 in [baseHull[0], baseHull[1], baseHull[3]] {
            let anchor = add(point3(point2, basis: basePlane.basis), scale(up, 3))
            solids.append(orientedBox(center: anchor, basis: basePlane.basis, width: 4, depth: 4, height: 3))
            strapClampPoints.append(codable(anchor))
        }
        let handles = try solids.map { try ManifoldEngine.make(from: $0) }
        let union = try ManifoldEngine.union(handles)
        let geometry = try ManifoldEngine.toMesh(union)
        guard MoldComponentFilter.dropFaceDisconnectedDebris(geometry).droppedCount == 0 else { return nil }
        let cradleHandle = try ManifoldEngine.make(from: geometry)
        for reserved in input.reservedVolumes {
            let reservedHandle = try manifold(for: reserved.geometry, invalid: .invalidRigidGeometry(reserved.id))
            let overlap = try ManifoldEngine.intersect(cradleHandle, reservedHandle)
            if !ManifoldEngine.isEmpty(overlap), abs(ManifoldEngine.volume(overlap)) > epsilon { return nil }
        }
        for artifact in artifacts {
            let rigidHandle = try manifold(for: artifact.geometry, invalid: .invalidRigidGeometry(artifact.id.rawValue))
            let overlap = try ManifoldEngine.intersect(cradleHandle, rigidHandle)
            if !ManifoldEngine.isEmpty(overlap), abs(ManifoldEngine.volume(overlap)) > epsilon { return nil }
        }
        let measuredContacts = claims.compactMap { measuredContact(for: $0, in: geometry) }
        guard measuredContacts.count == claims.count,
              measuredContacts.allSatisfy({ $0.regionAreaSquareMillimeters > epsilon && ($0.tangentGapMillimeters ?? .infinity) <= contactTolerance }) else { return nil }
        let constraintRank = contactConstraintRank(measuredContacts, basis: basePlane.basis)
        guard constraintRank >= 3, contactDirectionsEncloseMotion(measuredContacts, basis: basePlane.basis) else { return nil }
        return Cradle(geometry: geometry, contacts: measuredContacts, strapClampPoints: strapClampPoints, supportHull: supportHull, baseBasis: basePlane.basis, basePlane: basePlane, constraintRank: constraintRank)
    }

    static func selectConformalPatches(
        from patches: [SurfacePatch],
        supportPlane: Plane,
        assemblyHeight: Double,
        up: Vec3
    ) -> [SurfacePatch] {
        guard assemblyHeight > epsilon else { return [] }
        let candidates = patches.filter { patch in
            let verticalReaction = -dot(patch.normal, up)
            let lateral = length(subtract(patch.normal, scale(up, dot(patch.normal, up))))
            let height = dot(subtract(patch.centroid, supportPlane.point), up)
            return verticalReaction >= 0.2 && lateral >= 0.15
                && height >= -contactTolerance && height <= assemblyHeight * 0.62 + contactTolerance
                && patch.area > epsilon
        }
        var representatives: [Int: (patch: SurfacePatch, score: Double)] = [:]
        for patch in candidates {
            let normal = Point2(x: dot(patch.normal, supportPlane.basis.u), y: dot(patch.normal, supportPlane.basis.v))
            let angle = atan2(normal.y, normal.x)
            let bin = angularBin(angle, count: 16)
            let verticalReaction = -dot(patch.normal, up)
            let lateral = hypot(normal.x, normal.y)
            let score = patch.area * (0.25 + min(verticalReaction, lateral))
            if let current = representatives[bin] {
                if score > current.score + epsilon || (abs(score - current.score) <= epsilon && lexicographic(patch.centroid, current.patch.centroid)) {
                    representatives[bin] = (patch, score)
                }
            } else {
                representatives[bin] = (patch, score)
            }
        }
        let reduced = representatives.keys.sorted().compactMap { representatives[$0]?.patch }
        guard reduced.count >= 3 else { return [] }
        var best: (score: Double, patches: [SurfacePatch])?
        for count in 3...min(4, reduced.count) {
            for combination in combinations(reduced, choose: count) {
                let selected = combination.map { inset($0, factor: 0.65) }
                let hull = convexHull(selected.flatMap { $0.vertices.map { project($0, basis: supportPlane.basis) } })
                let hullArea = polygonArea(hull)
                guard hullArea > epsilon,
                      lateralConstraintRank(selected, basis: supportPlane.basis) >= 3,
                      lateralDirectionsEncloseMotion(selected, basis: supportPlane.basis) else { continue }
                let score = hullArea + selected.reduce(0) { $0 + $1.area }
                if score > best?.score ?? 0 { best = (score, selected) }
            }
            if best != nil { break }
        }
        return best?.patches ?? []
    }

    static func selectGravityPatches(from patches: [SurfacePatch], up: Vec3) -> [SurfacePatch] {
        let candidates = patches.flatMap(subdivide)
        guard candidates.count >= 3 else { return [] }
        var best: (area: Double, indices: [Int])?
        for a in 0..<(candidates.count - 2) {
            for b in (a + 1)..<(candidates.count - 1) {
                for c in (b + 1)..<candidates.count {
                    let area = abs(dot(cross(subtract(candidates[b].centroid, candidates[a].centroid), subtract(candidates[c].centroid, candidates[a].centroid)), up))
                    if area > best?.area ?? 0 { best = (area, [a, b, c]) }
                }
            }
        }
        guard let best, best.area > epsilon else { return [] }
        return best.indices.map { candidates[$0] }
    }

    static func subdivide(_ patch: SurfacePatch) -> [SurfacePatch] {
        let a = patch.vertices[0], b = patch.vertices[1], c = patch.vertices[2]
        let ab = scale(add(a, b), 0.5), bc = scale(add(b, c), 0.5), ca = scale(add(c, a), 0.5)
        return [[a, ab, patch.centroid], [b, bc, patch.centroid], [c, ca, patch.centroid]].map { vertices in
            SurfacePatch(artifactID: patch.artifactID, vertices: vertices, centroid: scale(add(add(vertices[0], vertices[1]), vertices[2]), 1 / 3), area: patch.area / 6, normal: patch.normal)
        }
    }

    static func inset(_ patch: SurfacePatch, factor: Double) -> SurfacePatch {
        let vertices = patch.vertices.map { add(patch.centroid, scale(subtract($0, patch.centroid), factor)) }
        return SurfacePatch(
            artifactID: patch.artifactID,
            vertices: vertices,
            centroid: patch.centroid,
            area: patch.area * factor * factor,
            normal: patch.normal
        )
    }

    static func selectLateralPatches(from patches: [SurfacePatch], up: Vec3, basis: VectorBasis) -> [SurfacePatch] {
        let candidates = patches.filter { abs(dot($0.normal, up)) <= 0.1 && $0.area > epsilon }.sorted {
            $0.area == $1.area ? lexicographic($0.centroid, $1.centroid) : $0.area > $1.area
        }
        // Keep the best face per angular direction before enumerating a small,
        // deterministic set.  This prevents many tessellation triangles from
        // one flat face masquerading as independent unilateral restraints.
        var representatives: [Int: [SurfacePatch]] = [:]
        for patch in candidates {
            let normal = Point2(x: dot(patch.normal, basis.u), y: dot(patch.normal, basis.v))
            let angle = atan2(normal.y, normal.x)
            let bin = angularBin(angle, count: 16)
            if representatives[bin, default: []].count < 2 { representatives[bin, default: []].append(patch) }
        }
        let reduced = representatives.keys.sorted().flatMap { representatives[$0] ?? [] }
        guard reduced.count >= 3 else { return [] }
        var best: (area: Double, patches: [SurfacePatch])?
        for count in 3...min(5, reduced.count) {
            for combination in combinations(reduced, choose: count) {
                guard lateralConstraintRank(combination, basis: basis) >= 3,
                      lateralDirectionsEncloseMotion(combination, basis: basis) else { continue }
                let area = combination.reduce(0) { $0 + $1.area }
                if area > best?.area ?? 0 { best = (area, combination) }
            }
            if best != nil { break }
        }
        return best?.patches.map { inset($0, factor: 0.35) } ?? []
    }

    static func angularBin(_ angle: Double, count: Int) -> Int {
        min(count - 1, max(0, Int((((angle + .pi) / (2 * .pi)) * Double(count)).rounded(.down))))
    }

    static func lateralDirectionsEncloseMotion(_ patches: [SurfacePatch], basis: VectorBasis) -> Bool {
        guard patches.count >= 3 else { return false }
        let angles = patches.map { atan2(dot($0.normal, basis.v), dot($0.normal, basis.u)) }.sorted()
        let wrapped = angles + [angles[0] + 2 * .pi]
        let largestGap = zip(wrapped, wrapped.dropFirst()).map { $1 - $0 }.max() ?? .infinity
        return largestGap < .pi - 1e-5
    }

    static func combinations(_ values: [SurfacePatch], choose count: Int) -> [[SurfacePatch]] {
        guard count > 0, count <= values.count else { return [] }
        var result: [[SurfacePatch]] = []
        func collect(_ start: Int, _ selected: [SurfacePatch]) {
            if selected.count == count { result.append(selected); return }
            let remaining = count - selected.count
            guard start <= values.count - remaining else { return }
            for index in start...(values.count - remaining) {
                collect(index + 1, selected + [values[index]])
            }
        }
        collect(0, [])
        return result
    }

    static func lateralConstraintRank(_ patches: [SurfacePatch], basis: VectorBasis) -> Int {
        let rows = patches.map { patch -> [Double] in
            let normal = Point2(x: dot(patch.normal, basis.u), y: dot(patch.normal, basis.v))
            let point = project(patch.centroid, basis: basis)
            return [normal.x, normal.y, point.x * normal.y - point.y * normal.x]
        }
        return matrixRank(rows)
    }

    static func matrixRank(_ input: [[Double]]) -> Int {
        var values = input
        guard !values.isEmpty else { return 0 }
        var pivotRow = 0
        for column in 0..<3 where pivotRow < values.count {
            guard let candidate = (pivotRow..<values.count).max(by: { abs(values[$0][column]) < abs(values[$1][column]) }), abs(values[candidate][column]) > epsilon else { continue }
            values.swapAt(pivotRow, candidate)
            let pivot = values[pivotRow][column]
            for row in (pivotRow + 1)..<values.count {
                let multiplier = values[row][column] / pivot
                for col in column..<3 { values[row][col] -= multiplier * values[pivotRow][col] }
            }
            pivotRow += 1
        }
        return pivotRow
    }

    static func triangularPrism(top: [Vec3], direction: Vec3, outward: Vec3) -> MeshGeometryData {
        precondition(top.count == 3)
        var top = top
        if dot(cross(subtract(top[1], top[0]), subtract(top[2], top[0])), outward) < 0 { top.swapAt(1, 2) }
        let bottom = top.map { add($0, direction) }
        return MeshGeometryData(
            vertices: bottom + top,
            triangleIndices: [0, 2, 1, 3, 4, 5, 0, 1, 4, 0, 4, 3, 1, 2, 5, 1, 5, 4, 2, 0, 3, 2, 3, 5]
        )
    }

    static func contactSupportSolids(for patch: SurfacePatch, baseTopPlane: Plane) -> [MeshGeometryData] {
        let padDepth = 3.0
        let outerCenter = add(patch.centroid, scale(patch.normal, padDepth))
        let baseAnchor = point3(project(outerCenter, basis: baseTopPlane.basis), basis: baseTopPlane.basis)
        let beamWidth = max(1.2, min(4, sqrt(patch.area) * 0.4))
        let pad = triangularPrism(
            top: patch.vertices,
            direction: scale(patch.normal, padDepth),
            outward: scale(patch.normal, -1)
        )
        guard length(subtract(baseAnchor, outerCenter)) > epsilon else { return [pad] }
        return [pad, orientedBeam(from: outerCenter, to: baseAnchor, width: beamWidth, overlap: 0.75)]
    }

    static func orientedBeam(from start: Vec3, to end: Vec3, width: Double, overlap: Double) -> MeshGeometryData {
        let delta = subtract(end, start)
        let axis = normalized(delta)
        let helper = abs(axis.z) < 0.9 ? Vec3(x: 0, y: 0, z: 1) : Vec3(x: 1, y: 0, z: 0)
        let u = normalized(cross(helper, axis))
        let v = normalized(cross(axis, u))
        let center = scale(add(start, end), 0.5)
        return orientedBox(
            center: center,
            basis: VectorBasis(origin: center, u: u, v: v, normal: axis),
            width: width,
            depth: width,
            height: length(delta) + 2 * overlap
        )
    }

    static func measuredContact(for claim: ContactClaim, in geometry: MeshGeometryData) -> MoldToolingSupportContact? {
        let patch = claim.patch
        let basis = surfaceBasis(origin: patch.centroid, normal: patch.normal)
        var clip = patch.vertices.map { project($0, basis: basis) }
        if signedPolygonArea(clip) < 0 { clip.reverse() }
        var measuredArea = 0.0
        var measuredGap = Double.infinity
        var index = 0
        while index + 2 < geometry.triangleIndices.count {
            let ids = [Int(geometry.triangleIndices[index]), Int(geometry.triangleIndices[index + 1]), Int(geometry.triangleIndices[index + 2])]
            guard ids.allSatisfy(geometry.vertices.indices.contains) else { index += 3; continue }
            let vertices = ids.map { geometry.vertices[$0] }
            let gap = vertices.map { abs(dot(subtract($0, patch.centroid), patch.normal)) }.max() ?? .infinity
            if gap <= contactTolerance {
                let overlap = clippedArea(subject: vertices.map { project($0, basis: basis) }, clip: clip)
                if overlap > epsilon {
                    measuredArea += overlap
                    measuredGap = min(measuredGap, gap)
                }
            }
            index += 3
        }
        guard measuredArea > epsilon, measuredGap <= contactTolerance else { return nil }
        return MoldToolingSupportContact(
            point: codable(patch.centroid),
            regionAreaSquareMillimeters: min(measuredArea, patch.area),
            rigidArtifactIDs: [patch.artifactID],
            tangentNormal: codable(patch.normal),
            tangentGapMillimeters: measuredGap,
            role: claim.role
        )
    }

    static func surfaceBasis(origin: Vec3, normal: Vec3) -> VectorBasis {
        let helper = abs(normal.z) < 0.9 ? Vec3(x: 0, y: 0, z: 1) : Vec3(x: 1, y: 0, z: 0)
        let u = normalized(cross(helper, normal))
        let v = normalized(cross(normal, u))
        return VectorBasis(origin: origin, u: u, v: v, normal: normal)
    }

    static func clippedArea(subject: [Point2], clip: [Point2]) -> Double {
        guard subject.count >= 3, clip.count >= 3 else { return 0 }
        var output = subject
        for index in clip.indices {
            let a = clip[index]
            let b = clip[(index + 1) % clip.count]
            let edge = subtract(b, a)
            let input = output
            output = []
            guard var previous = input.last else { return 0 }
            var previousInside = cross2(edge, subtract(previous, a)) >= -epsilon
            for current in input {
                let currentInside = cross2(edge, subtract(current, a)) >= -epsilon
                if currentInside != previousInside, let intersection = lineIntersection(previous, current, a, b) {
                    output.append(intersection)
                }
                if currentInside { output.append(current) }
                previous = current
                previousInside = currentInside
            }
        }
        return abs(signedPolygonArea(output))
    }

    static func lineIntersection(_ p: Point2, _ q: Point2, _ a: Point2, _ b: Point2) -> Point2? {
        let segment = subtract(q, p)
        let edge = subtract(b, a)
        let denominator = cross2(edge, segment)
        guard abs(denominator) > epsilon else { return nil }
        let t = -cross2(edge, subtract(p, a)) / denominator
        return Point2(x: p.x + segment.x * t, y: p.y + segment.y * t)
    }

    static func signedPolygonArea(_ points: [Point2]) -> Double {
        guard points.count >= 3 else { return 0 }
        return (0..<points.count).reduce(0.0) { sum, index in
            let next = (index + 1) % points.count
            return sum + points[index].x * points[next].y - points[next].x * points[index].y
        } / 2
    }

    static func contactConstraintRank(_ contacts: [MoldToolingSupportContact], basis: VectorBasis) -> Int {
        let rows = contacts.compactMap { contact -> [Double]? in
            guard let normalValue = contact.tangentNormal else { return nil }
            let normal3 = vec(normalValue)
            let normal = Point2(x: dot(normal3, basis.u), y: dot(normal3, basis.v))
            guard hypot(normal.x, normal.y) > epsilon else { return nil }
            let point = project(vec(contact.point), basis: basis)
            return [normal.x, normal.y, point.x * normal.y - point.y * normal.x]
        }
        return matrixRank(rows)
    }

    static func contactDirectionsEncloseMotion(_ contacts: [MoldToolingSupportContact], basis: VectorBasis) -> Bool {
        let angles = contacts.compactMap { contact -> Double? in
            guard let normalValue = contact.tangentNormal else { return nil }
            let normal = vec(normalValue)
            let x = dot(normal, basis.u), y = dot(normal, basis.v)
            return hypot(x, y) > epsilon ? atan2(y, x) : nil
        }.sorted()
        guard angles.count >= 3 else { return false }
        let wrapped = angles + [angles[0] + 2 * .pi]
        let largestGap = zip(wrapped, wrapped.dropFirst()).map { $1 - $0 }.max() ?? .infinity
        return largestGap < .pi - 1e-5
    }

    static func nonCollinearTriangle(_ hull: [Point2]) -> [Point2]? {
        guard hull.count >= 3 else { return nil }
        var best: (Double, [Point2])?
        for a in 0..<(hull.count - 2) {
            for b in (a + 1)..<(hull.count - 1) {
                for c in (b + 1)..<hull.count {
                    let area = abs(cross2(subtract(hull[b], hull[a]), subtract(hull[c], hull[a])))
                    if area > best?.0 ?? 0 { best = (area, [hull[a], hull[b], hull[c]]) }
                }
            }
        }
        return (best?.0 ?? 0) > epsilon ? best?.1 : nil
    }

    static func printerFitState(_ geometry: MeshGeometryData, printer: MoldToolingSupportPrinterEnvelope?) -> MoldToolingSupportQualificationState {
        guard let printer else { return .printerFitNotChecked }
        guard let bounds = bounds(geometry) else { return .blocked }
        let dims = subtract(bounds.max, bounds.min), envelope = vec(printer.buildExtentsMillimeters)
        guard dims.x <= envelope.x + epsilon, dims.y <= envelope.y + epsilon, dims.z <= envelope.z + epsilon else { return .blocked }
        // Build bounds are necessary but insufficient: this builder does not
        // prove a recommended orientation or every post-boolean minimum feature.
        return .printerFitNotChecked
    }

    static func supportReactions(massStates: [MoldToolingSupportMassState], plane: Plane, up: Vec3) -> (vertical: Double, lateral: Double, overturning: Double, contact: Double) {
        let maxMass = massStates.compactMap(\.massGrams).max() ?? .infinity
        let vertical = maxMass * gravity / 1_000 * 1.5
        let lateral = vertical * tan(tiltRadians)
        let height = massStates.compactMap { $0.centerOfGravity.map { dot(subtract(vec($0), plane.point), up) } }.max() ?? .infinity
        return (vertical, lateral, lateral * max(0, height), vertical / 3)
    }

    static func qualification(evidence: MoldToolingSupportLoadEvidence?, fingerprint: String, printer: MoldToolingSupportPrinterEnvelope?, reactions: (vertical: Double, lateral: Double, overturning: Double, contact: Double)) -> Bool {
        guard let evidence, let printer, evidence.profileID == printer.profileID,
              evidence.cradleGeometryFingerprint == fingerprint,
              evidence.envelope.qualification == .qualified,
              evidence.envelope.handlingSafetyFactor ?? 0 >= 1.5 else { return false }
        return evidence.ratedVerticalNewtons >= reactions.vertical - epsilon
            && evidence.ratedLateralNewtons >= reactions.lateral - epsilon
            && evidence.ratedOverturningNewtonMillimeters >= reactions.overturning - epsilon
            && evidence.ratedContactOrStrapNewtons >= reactions.contact - epsilon
    }

    static func blockedResult(input: MoldToolingSupportPhaseInput, up: Vec3, states: [MoldToolingSupportMassState], intervals: [MoldToolingSupportMassInterval], contacts: [MoldToolingSupportContact], requiredMargin: Double?, message: String, action: MoldRecoveryAction) -> MoldToolingSupportResult {
        let diagnostic = MoldDiagnostic(.error, message, subsystem: .support, code: .toolingIncomplete, recoveryActions: [action])
        return MoldToolingSupportResult(
            summary: ToolingSupportSummary(phase: input.phase, state: .blocked, gravityUpAxis: codable(up), massStates: states.map(toolingMassState), supportContacts: contacts.map(\.point), minimumSupportMarginMillimeters: requiredMargin, notes: [message]),
            qualificationState: .blocked, artifacts: [], contacts: contacts, strapClampPoints: [], massStates: states, massIntervals: intervals,
            diagnostics: [diagnostic], cradleGeometryFingerprint: nil
        )
    }

    static func earlyBlocked(input: MoldToolingSupportPhaseInput, up: Vec3, message: String) -> MoldToolingSupportResult {
        let action: MoldRecoveryAction = input.phase == .linerFill ? .reorientLinerFill : .reorientCasting
        return blockedResult(input: input, up: up, states: [], intervals: [], contacts: [], requiredMargin: nil, message: message, action: action)
    }

    static func supportNotes(contacts: [MoldToolingSupportContact], hull: [Point2], requiredMargin: Double, massComplete: Bool, stable: Bool) -> [String] {
        let totalArea = contacts.reduce(0) { $0 + $1.regionAreaSquareMillimeters }
        var notes = ["Measured \(contacts.count) finite coplanar contact region(s), total area \(String(format: "%.3f", totalArea)) square mm; required projected margin is \(String(format: "%.3f", requiredMargin)) mm."]
        if hull.count < 3 || polygonArea(hull) <= epsilon { notes.append("Point, line, or rolling contact cannot support the assembly.") }
        if !massComplete { notes.append("Mass or center-of-gravity evidence is incomplete; bare assembly is not stable.") }
        if !stable { notes.append("Worst empty-to-full state does not pass both projected-margin and 10-degree tilt gates.") }
        return notes
    }

    static func toolingMassState(_ state: MoldToolingSupportMassState) -> ToolingMassState {
        ToolingMassState(id: state.id, fillFraction: state.fillFraction, massGrams: state.massGrams, centerOfGravity: state.centerOfGravity)
    }

    static func assemblySpan(_ vertices: [Vec3]) -> Double {
        guard let b = bounds(MeshGeometryData(vertices: vertices, triangleIndices: [])) else { return 0 }
        return max(b.max.x - b.min.x, b.max.y - b.min.y, b.max.z - b.min.z)
    }

    static func bounds(_ geometry: MeshGeometryData) -> Bounds3D? {
        guard let first = geometry.vertices.first else { return nil }
        return geometry.vertices.dropFirst().reduce(Bounds3D(min: first, max: first)) { partial, p in
            Bounds3D(min: Vec3(x: min(partial.min.x, p.x), y: min(partial.min.y, p.y), z: min(partial.min.z, p.z)), max: Vec3(x: max(partial.max.x, p.x), y: max(partial.max.y, p.y), z: max(partial.max.z, p.z)))
        }
    }

    static func orientedBox(center: Vec3, basis: VectorBasis, width: Double, depth: Double, height: Double) -> MeshGeometryData {
        let hx = width / 2, hy = depth / 2, hz = height / 2
        let corners = [(-hx, -hy, -hz), (hx, -hy, -hz), (hx, hy, -hz), (-hx, hy, -hz), (-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)].map { x, y, z in
            add(center, add(scale(basis.u, x), add(scale(basis.v, y), scale(basis.normal, z))))
        }
        return MeshGeometryData(vertices: corners, triangleIndices: [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7])
    }

    static func geometryFingerprint(_ geometry: MeshGeometryData) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        func append(_ value: String) { for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 } }
        for v in geometry.vertices { append(String(format: "%.9f,%.9f,%.9f;", v.x, v.y, v.z)) }
        for i in geometry.triangleIndices { append("\(i),") }
        return String(format: "%016llx", hash)
    }

    static func convexHull(_ points: [Point2]) -> [Point2] {
        let sorted = Array(Set(points.map { "\(Int(($0.x * 1_000_000).rounded())):\(Int(($0.y * 1_000_000).rounded()))" })).compactMap { key -> Point2? in
            let p = key.split(separator: ":").compactMap { Double($0) }; guard p.count == 2 else { return nil }; return Point2(x: p[0] / 1_000_000, y: p[1] / 1_000_000)
        }.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        func half(_ values: [Point2]) -> [Point2] {
            var result: [Point2] = []
            for point in values {
                while result.count >= 2 && cross2(subtract(result[result.count - 1], result[result.count - 2]), subtract(point, result[result.count - 1])) <= epsilon { result.removeLast() }
                result.append(point)
            }
            return result
        }
        var lower = half(sorted); lower.removeLast()
        var upper = half(sorted.reversed()); upper.removeLast()
        return lower + upper
    }

    static func polygonArea(_ hull: [Point2]) -> Double {
        guard hull.count >= 3 else { return 0 }
        return abs((0..<hull.count).reduce(0.0) { sum, i in sum + hull[i].x * hull[(i + 1) % hull.count].y - hull[(i + 1) % hull.count].x * hull[i].y }) / 2
    }

    static func polygonMargin(_ point: Point2, hull: [Point2]) -> Double? {
        guard hull.count >= 3, polygonArea(hull) > epsilon else { return nil }
        var inside = true, minimum = Double.infinity
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let edge = subtract(b, a), relative = subtract(point, a)
            if cross2(edge, relative) < -epsilon { inside = false }
            minimum = min(minimum, distanceToSegment(point, a, b))
        }
        return inside ? minimum : -minimum
    }

    static func project(_ point: Vec3, basis: VectorBasis) -> Point2 { Point2(x: dot(subtract(point, basis.origin), basis.u), y: dot(subtract(point, basis.origin), basis.v)) }
    static func point3(_ point: Point2, basis: VectorBasis) -> Vec3 { add(basis.origin, add(scale(basis.u, point.x), scale(basis.v, point.y))) }
    static func vec(_ v: Vec3Codable) -> Vec3 { Vec3(x: v.x, y: v.y, z: v.z) }
    static func codable(_ v: Vec3) -> Vec3Codable { Vec3Codable(x: v.x, y: v.y, z: v.z) }
    static func add(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func scale(_ a: Vec3, _ s: Double) -> Vec3 { Vec3(x: a.x * s, y: a.y * s, z: a.z * s) }
    static func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x) }
    static func length(_ a: Vec3) -> Double { sqrt(dot(a, a)) }
    static func normalized(_ a: Vec3) -> Vec3 { scale(a, 1 / length(a)) }
    static func finite(_ a: Vec3) -> Bool { a.x.isFinite && a.y.isFinite && a.z.isFinite }
    static func subtract(_ a: Point2, _ b: Point2) -> Point2 { Point2(x: a.x - b.x, y: a.y - b.y) }
    static func cross2(_ a: Point2, _ b: Point2) -> Double { a.x * b.y - a.y * b.x }
    static func distance(_ a: Point2, _ b: Point2) -> Double { hypot(a.x - b.x, a.y - b.y) }
    static func distanceToSegment(_ p: Point2, _ a: Point2, _ b: Point2) -> Double { let d = subtract(b, a); let dd = d.x * d.x + d.y * d.y; guard dd > epsilon else { return distance(p, a) }; let t = max(0, min(1, (subtract(p, a).x * d.x + subtract(p, a).y * d.y) / dd)); return distance(p, Point2(x: a.x + t * d.x, y: a.y + t * d.y)) }
    static func unique(_ values: [Vec3]) -> [Vec3] { values.reduce(into: []) { result, value in if !result.contains(where: { length(subtract($0, value)) <= contactTolerance }) { result.append(value) } } }
    static func lexicographic(_ a: Vec3, _ b: Vec3) -> Bool { a.x == b.x ? (a.y == b.y ? a.z < b.z : a.y < b.y) : a.x < b.x }
}
