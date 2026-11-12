import CryptoKit
import Foundation

/// Derives the immutable-source prepared positive for reusable MotherMold tooling.
/// The result is geometry-only evidence; load qualification belongs to the
/// physically calibrated hold-down envelope.
enum PreparedMasterBuilder {
    enum Kind: Equatable, Sendable {
        case prepared
        case notApplicable
        case external
    }

    enum Error: Swift.Error, LocalizedError {
        case invalidSource(String)
        case invalidManualPlacement(String)
        case noSafePatch(String)
        case unsafeDimensions(String)
        case staleBase(String)
        case invalidAddition(String)
        case geometryFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidSource(let message), .invalidManualPlacement(let message),
                 .noSafePatch(let message), .unsafeDimensions(let message),
                 .staleBase(let message), .invalidAddition(let message),
                 .geometryFailed(let message):
                return message
            }
        }
    }

    /// Neutral geometry handoff used by production-flow workers. The enclosing
    /// builder and geometry contract are module-scoped, so this is visible to
    /// every integration worker in the RefabArtist target.
    public struct Addition: Equatable {
        public var region: MasterModificationRegion
        public var solid: MeshGeometryData

        public init(region: MasterModificationRegion, solid: MeshGeometryData) {
            self.region = region
            self.solid = solid
        }
    }

    struct MountSelection: Codable, Equatable, Sendable {
        var point: Vec3Codable
        var outwardAxis: Vec3Codable
        var sourcePatchAreaSquareMillimeters: Double
        var equivalentPatchDiameterMillimeters: Double
        var rmsPlanarityMillimeters: Double
        var requiredPatchAreaSquareMillimeters: Double
        var requiredEquivalentDiameterMillimeters: Double
        var maximumPlanarityMillimeters: Double
        var exteriorRouteClearanceMillimeters: Double
        var exteriorCollisionVolumeCubicMillimeters: Double
        var candidateScore: Double
        var deterministicTieBreak: String
        var placementMode: MountPlacementMode
    }

    struct AxialStations: Codable, Equatable, Sendable {
        var rootInnerMillimeters: Double
        var sourceSurfaceMillimeters: Double
        var rootFilletPeakMillimeters: Double
        var siliconeOuterMillimeters: Double
        var shellOuterMillimeters: Double
        var dryPostStartMillimeters: Double
        var collarFaceMillimeters: Double
        var pinCenterMillimeters: Double
        var freeEndMillimeters: Double
    }

    /// Exact dimensions consumed by later collar/yoke construction.
    struct FixtureDimensions: Codable, Equatable, Sendable {
        var gateRootDiameterMillimeters: Double
        var approvedRootFootprintDiameterMillimeters: Double
        var rootFilletRadiusMillimeters: Double
        var postWidthMillimeters: Double
        var postThicknessMillimeters: Double
        var postCornerRadiusMillimeters: Double
        var postFreeLengthMillimeters: Double
        var totalPostExtentMillimeters: Double
        var minimumPinLigamentMillimeters: Double
        var postWasAutoGrown: Bool
        var rootOverlapDepthMillimeters: Double
        var rootOverlapCubicMillimeters: Double
        var collarInnerWidthMillimeters: Double
        var collarInnerThicknessMillimeters: Double
        var collarLengthMillimeters: Double
        var crossPinDiameterMillimeters: Double
        var crossPinCenter: Vec3Codable
        var crossPinAxis: Vec3Codable
        var axialStations: AxialStations
    }

    struct SourcePreservation: Codable, Equatable, Sendable {
        var sourceVolumeCubicMillimeters: Double
        var removedVolumeCubicMillimeters: Double
        var addedVolumeCubicMillimeters: Double
    }

    struct RootConnectionEvidence: Codable, Equatable, Sendable {
        var intendedOverlapCubicMillimeters: Double
        var measuredOverlapCubicMillimeters: Double
        var overlapCoverageFraction: Double
        var connectedComponentCount: Int
        var hasCompleteConnectedFootprint: Bool
    }

    struct RadialProfileSample: Codable, Equatable, Sendable {
        var axialStationMillimeters: Double
        var measuredRadiusMillimeters: Double
        var roundnessErrorMillimeters: Double
    }

    struct SiliconeContactProfileEvidence: Codable, Equatable, Sendable {
        var nominalGateDiameterMillimeters: Double
        var approvedFootprintDiameterMillimeters: Double
        var measuredBlendRadiusMillimeters: Double
        var minimumRequiredBlendRadiusMillimeters: Double
        var linerOuterDiameterMillimeters: Double
        var linerOuterRoundnessErrorMillimeters: Double
        var isMonotoneTowardNominalGate: Bool
        var hasReentrantUndercut: Bool
        var isRoundAtLinerOuterStation: Bool
        var samples: [RadialProfileSample]
    }

    struct SourceSurfaceModificationAudit: Codable, Equatable, Sendable {
        var sampledPointCount: Int
        var changedAreaOutsideFootprintSquareMillimeters: Double
        var allowedChangedAreaSquareMillimeters: Double
        var maximumDistanceOutsideFootprintMillimeters: Double
        var allowedDistanceMillimeters: Double
        var passed: Bool
    }

    struct PinBoreValidation: Codable, Equatable, Sendable {
        var intendedThroughVolumeCubicMillimeters: Double
        var removedVolumeCubicMillimeters: Double
        var relativeVolumeError: Double
        var remainingToolIntersectionCubicMillimeters: Double
        var hasTwoExteriorOpenings: Bool
        var openingA: Vec3Codable
        var openingB: Vec3Codable
    }

    struct FinalGeometry: Codable, Equatable, Sendable {
        var hasFiniteCoordinates: Bool
        var hasValidIndices: Bool
        var isWatertight: Bool
        var connectedComponentCount: Int
        var signedVolumeCubicMillimeters: Double
        var triangleCount: Int
    }

    struct Result: Equatable {
        var kind: Kind
        /// Exact physical union used for manufacturing geometry. The untouched
        /// imported source remains separately hash-tracked and packaged.
        var normalizedSource: MeshGeometryData?
        var artifact: ToolingArtifact?
        var selectedMount: MountSelection?
        var fixtureDimensions: FixtureDimensions?
        var modificationRegions: [MasterModificationRegion]
        var additionGeometrySHA256ByRegionID: [String: String]
        var approvalSignature: String?
        var sourcePreservation: SourcePreservation?
        var rootConnection: RootConnectionEvidence?
        var siliconeContactProfile: SiliconeContactProfileEvidence?
        var sourceSurfaceModificationAudit: SourceSurfaceModificationAudit?
        var pinBoreRemovedVolumeCubicMillimeters: Double?
        var pinBoreValidation: PinBoreValidation?
        var finalGeometry: FinalGeometry?
        var summary: MasterPreparationSummary
    }

    private struct PointKey: Hashable, Comparable, CustomStringConvertible {
        var x: Int64
        var y: Int64
        var z: Int64

        init(_ point: Vec3) {
            x = Int64((point.x * 1_000_000).rounded())
            y = Int64((point.y * 1_000_000).rounded())
            z = Int64((point.z * 1_000_000).rounded())
        }

        static func < (lhs: PointKey, rhs: PointKey) -> Bool {
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.z < rhs.z
        }

        var description: String { "\(x),\(y),\(z)" }
    }

    private struct EdgeKey: Hashable, Comparable, CustomStringConvertible {
        var a: PointKey
        var b: PointKey

        init(_ first: Vec3, _ second: Vec3) {
            let firstKey = PointKey(first)
            let secondKey = PointKey(second)
            if firstKey < secondKey {
                a = firstKey
                b = secondKey
            } else {
                a = secondKey
                b = firstKey
            }
        }

        static func < (lhs: EdgeKey, rhs: EdgeKey) -> Bool {
            lhs.a == rhs.a ? lhs.b < rhs.b : lhs.a < rhs.a
        }

        var description: String { "\(a)>\(b)" }
    }

    private struct SurfaceTriangle {
        var vertices: [Vec3]
        var normal: Vec3
        var area: Double
        var centroid: Vec3
        var edges: [EdgeKey]
        var canonicalKey: String
    }

    private struct SurfaceData {
        var triangles: [SurfaceTriangle]
        var adjacency: [[Int]]
        var sourceSurfaceArea: Double
        var sourceSpan: Double
    }

    private struct SurfacePatch {
        var triangleIndices: [Int]
        var center: Vec3
        var normal: Vec3
        var area: Double
        var equivalentDiameter: Double
        var rmsPlanarity: Double
        var boundaryKey: String
    }

    private struct EffectiveDimensions {
        var gateDiameter: Double
        var rootFilletRadius: Double
        var rootFootprintRadius: Double
        var width: Double
        var thickness: Double
        var cornerRadius: Double
        var freeLength: Double
        var minimumPinLigament: Double
        var autoGrown: Bool
        var collarAllowance: Double
        var stations: AxialStations
    }

    private struct Candidate {
        var patch: SurfacePatch
        var point: Vec3
        var axis: Vec3
        var routeClearance: Double
        var collisionVolume: Double
        var score: Double
        var tieBreak: String
    }

    private struct RouteEvidence {
        var clearance: Double
        var collisionVolume: Double
    }

    private struct ApprovedFootprint {
        var center: Vec3
        var normal: Vec3
        var u: Vec3
        var v: Vec3
        var polygon: [(Double, Double)]
        var axialTolerance: Double
    }

    private static let sourcePreservationTolerance = 0.01
    private static let exteriorCollisionTolerance = 1.0e-5
    private static let mountTolerance = 0.25
    private static let boreRelativeTolerance = 0.0025
    private static let profileSegments = 96

    static func build(source: MeshGeometryData, settings rawSettings: MotherMoldSettings) throws -> Result {
        let settings = rawSettings.sanitized
        guard settings.toolingContractVersion >= 3, settings.subtype == .siliconeJacket else {
            return notApplicableResult(retention: .notApplicable, state: .notApplicable)
        }

        let preparation = settings.masterPreparation
        guard preparation.sourceMode == .preparedPrint else {
            let retention: MasterRetentionEvidence
            switch preparation.retentionMode {
            case .flatBaseSocket: retention = .socketLocatorOnly
            case .externalFixture: retention = .externalFixtureDeclared
            case .preparedPost: retention = .notApplicable
            }
            return notApplicableResult(
                retention: retention,
                state: preparation.retentionMode == .externalFixture ? .externalFixture : .notApplicable
            )
        }
        guard preparation.retentionMode == .preparedPost else {
            return preparation.retentionMode == .externalFixture
                ? notApplicableResult(retention: .externalFixtureDeclared, state: .externalFixture)
                : notApplicableResult(retention: .socketLocatorOnly, state: .notApplicable)
        }

        try validateInput(source)
        let sourceHandle: ManifoldHandle
        do {
            sourceHandle = try normalizedSourceSolid(source)
        } catch {
            throw Error.invalidSource(
                "The active source is not a closed solid (\(error)). Repair the active source before preparing a master."
            )
        }
        guard ManifoldEngine.isWatertight(sourceHandle), !ManifoldEngine.isEmpty(sourceHandle) else {
            throw Error.invalidSource("The active source is not a non-empty watertight solid. Repair it before preparing a master.")
        }
        let normalizedSource = try ManifoldEngine.toMesh(sourceHandle)

        let surface = try buildSurfaceData(normalizedSource)
        let effective = try resolveDimensions(settings: settings, sourceSpan: surface.sourceSpan)
        let selection = try selectMount(
            surface: surface,
            source: normalizedSource,
            sourceHandle: sourceHandle,
            settings: settings,
            effective: effective
        )
        let basis = orthonormalBasis(for: selection.axis)
        let postGeometry = phasedPostGeometry(
            point: selection.point,
            axis: selection.axis,
            basis: basis,
            effective: effective
        )
        let postHandle: ManifoldHandle
        do {
            postHandle = try ManifoldEngine.make(from: postGeometry)
        } catch {
            throw Error.geometryFailed("The phased round-root/rounded-D post is invalid (\(error)). Choose another mount patch or increase its dimensions.")
        }

        let rootIntersection = try ManifoldEngine.intersect(sourceHandle, postHandle)
        let rootOverlap = abs(ManifoldEngine.volume(rootIntersection))
        let rootArea = Double.pi * pow(effective.rootFootprintRadius, 2)
        let intendedRootOverlap = rootArea * abs(effective.stations.rootInnerMillimeters)
        let rootCoverage = rootOverlap / intendedRootOverlap
        let rootComponentCount: Int
        if ManifoldEngine.isEmpty(rootIntersection) {
            rootComponentCount = 0
        } else {
            let rootGeometry = try ManifoldEngine.toMesh(rootIntersection)
            rootComponentCount = connectedComponentCount(rootGeometry)
        }
        let hasCompleteRoot = rootCoverage >= 0.995 && rootComponentCount == 1
        guard hasCompleteRoot else {
            throw Error.noSafePatch(
                String(
                    format: "The selected patch does not provide a complete connected root footprint (%.2f%% of %.3f mm3, %d component(s)). Pick a solid patch without a crescent, hole, edge, or shallow sliver.",
                    rootCoverage * 100,
                    intendedRootOverlap,
                    rootComponentCount
                )
            )
        }
        let route = try routeEvidence(
            point: selection.point,
            axis: selection.axis,
            effective: effective,
            source: normalizedSource,
            sourceHandle: sourceHandle,
            postHandle: postHandle
        )
        guard route.collisionVolume <= exteriorCollisionTolerance else {
            throw Error.geometryFailed(
                String(
                    format: "The complete post route re-enters the source by %.3f mm3 outside the typed root footprint. Pick another patch or reorient the master.",
                    route.collisionVolume
                )
            )
        }

        let joined = try ManifoldEngine.union(sourceHandle, postHandle)
        guard ManifoldEngine.isWatertight(joined), !ManifoldEngine.isEmpty(joined) else {
            throw Error.geometryFailed("The phased post could not be joined to the source as one closed solid. Pick another patch.")
        }

        let pinCenter = add(selection.point, scaled(selection.axis, effective.stations.pinCenterMillimeters))
        let pinAxis = basis.v
        let pinRadius = preparation.crossPinDiameter / 2
        let openingExtension = max(1, preparation.crossPinDiameter * 0.25)
        let pinToolLength = effective.thickness + 2 * openingExtension
        let pinTool = cylinder(
            center: pinCenter,
            axis: pinAxis,
            radius: pinRadius,
            length: pinToolLength,
            segments: profileSegments
        )
        let pinHandle: ManifoldHandle
        do {
            pinHandle = try ManifoldEngine.make(from: pinTool)
        } catch {
            throw Error.geometryFailed("The configured cross-pin bore could not be constructed (\(error)).")
        }

        let pinIntersection = try ManifoldEngine.intersect(joined, pinHandle)
        let pinRemoval = abs(ManifoldEngine.volume(pinIntersection))
        let intendedPinRemoval = Double.pi * pinRadius * pinRadius * effective.thickness
        let pinRelativeError = abs(pinRemoval - intendedPinRemoval) / intendedPinRemoval
        guard pinRelativeError <= boreRelativeTolerance else {
            throw Error.geometryFailed(
                String(
                    format: "The cross-pin bore removed %.3f mm3; the intended complete through-section is %.3f mm3 (%.3f%% error). Increase the dry-post clearance or choose another patch.",
                    pinRemoval,
                    intendedPinRemoval,
                    pinRelativeError * 100
                )
            )
        }

        let outsidePin = try ManifoldEngine.difference(pinHandle, joined)
        guard !ManifoldEngine.isEmpty(outsidePin),
              let outsidePinGeometry = try? ManifoldEngine.toMesh(outsidePin),
              connectedComponentCount(outsidePinGeometry) == 2 else {
            throw Error.geometryFailed("The cross-pin tool does not emerge from both sides of the constant dry post. Increase bore extension or choose another post profile.")
        }

        let beforeBoreVolume = abs(ManifoldEngine.volume(joined))
        let preparedHandle = try ManifoldEngine.difference(joined, pinHandle)
        let afterBoreVolume = abs(ManifoldEngine.volume(preparedHandle))
        guard abs((beforeBoreVolume - afterBoreVolume) - pinRemoval) <= max(0.001, pinRemoval * 1.0e-5) else {
            throw Error.geometryFailed("The final prepared master does not retain the complete measured cross-pin subtraction.")
        }
        let remainingPin = try ManifoldEngine.intersect(preparedHandle, pinHandle)
        let remainingPinVolume = abs(ManifoldEngine.volume(remainingPin))
        guard remainingPinVolume <= 0.001 else {
            throw Error.geometryFailed(
                String(format: "The final cross-pin bore retains %.4f mm3 of obstructing material.", remainingPinVolume)
            )
        }

        let prepared = try printableReadback(of: preparedHandle)
        let missingSource = try ManifoldEngine.difference(sourceHandle, preparedHandle)
        let removedSourceVolume = abs(ManifoldEngine.volume(missingSource))
        guard removedSourceVolume <= sourcePreservationTolerance else {
            throw Error.geometryFailed(
                String(
                    format: "Prepared-master construction removed %.4f mm3 of active-source material, exceeding the 0.01 mm3 preservation limit.",
                    removedSourceVolume
                )
            )
        }

        let final = finalGeometry(for: prepared, handle: preparedHandle)
        guard final.hasFiniteCoordinates, final.hasValidIndices, final.isWatertight,
              final.connectedComponentCount == 1, final.signedVolumeCubicMillimeters > 0 else {
            // Name the concrete failing facts — "watertight: false" alone sent
            // the owner hunting through settings that could never fix it.
            let closure = MotherMoldValidation.surfaceClosure(prepared)
            let strict = MotherMoldValidation.printablePreflight(prepared)
            throw Error.geometryFailed(
                String(
                    format: "The final prepared master failed validation (finite: %@, indices: %@, watertight: %@ [boundary edges: %d, non-manifold edges: %d, degenerate triangles: %d, Manifold-proven: %@], material components: %d, signed volume: %.3f mm3). No fallback geometry was generated.",
                    final.hasFiniteCoordinates.description,
                    final.hasValidIndices.description,
                    final.isWatertight.description,
                    closure.boundary,
                    closure.nonManifold,
                    strict.degenerateTriangleCount,
                    (strict.manifoldValidated || ManifoldEngine.isWatertight(preparedHandle)).description,
                    final.connectedComponentCount,
                    final.signedVolumeCubicMillimeters
                )
            )
        }
        let rootConnection = try rootConnectionEvidence(
            sourceHandle: sourceHandle,
            preparedHandle: preparedHandle,
            point: selection.point,
            axis: selection.axis,
            effective: effective
        )
        guard rootConnection.hasCompleteConnectedFootprint else {
            throw Error.geometryFailed(
                String(
                    format: "The final prepared mesh retains only %.2f%% of the connected round root footprint in %d component(s). Pick a solid patch without a crescent, hole, edge, or shallow sliver.",
                    rootConnection.overlapCoverageFraction * 100,
                    rootConnection.connectedComponentCount
                )
            )
        }

        let rootBoundary = circleProfile(radius: effective.rootFootprintRadius, segments: 64).map { x, y in
            add(selection.point, add(scaled(basis.u, x), scaled(basis.v, y)))
        }
        let region = MasterModificationRegion(
            id: "anchor-gate-root",
            kind: .anchorAndGateRoot,
            center: codable(selection.point),
            surfaceArea: rootArea,
            boundary: rootBoundary.map(codable),
            purpose: "Approved round art-surface footprint of the tangent root fillet; nominal production gate diameter is recorded separately"
        )

        let siliconeProfile = try siliconeContactProfileEvidence(
            prepared: prepared,
            point: selection.point,
            axis: selection.axis,
            basis: basis,
            effective: effective
        )
        guard siliconeProfile.isMonotoneTowardNominalGate,
              !siliconeProfile.hasReentrantUndercut,
              siliconeProfile.measuredBlendRadiusMillimeters >= 1,
              siliconeProfile.isRoundAtLinerOuterStation else {
            throw Error.geometryFailed("The final silicone-contact profile failed monotonicity, blend-radius, undercut, or liner-outer roundness validation.")
        }
        let sourceSurfaceAudit = sourceSurfaceModificationAudit(
            source: normalizedSource,
            prepared: prepared,
            approvedRegions: [region],
            footprintAxialTolerance: max(0.05, max(0.5, effective.width * 0.02) + 0.05),
            sourceSurfaceArea: surface.sourceSurfaceArea
        )
        guard sourceSurfaceAudit.passed else {
            throw Error.geometryFailed(
                String(
                    format: "The prepared master changes %.3f mm2 of source surface outside the approved root footprint (limit %.3f mm2), with %.4f mm maximum sampled distance (limit 0.05 mm). Pick another route.",
                    sourceSurfaceAudit.changedAreaOutsideFootprintSquareMillimeters,
                    sourceSurfaceAudit.allowedChangedAreaSquareMillimeters,
                    sourceSurfaceAudit.maximumDistanceOutsideFootprintMillimeters
                )
            )
        }

        let crossPinCenter = codable(pinCenter)
        let fixture = FixtureDimensions(
            gateRootDiameterMillimeters: effective.gateDiameter,
            approvedRootFootprintDiameterMillimeters: effective.rootFootprintRadius * 2,
            rootFilletRadiusMillimeters: effective.rootFilletRadius,
            postWidthMillimeters: effective.width,
            postThicknessMillimeters: effective.thickness,
            postCornerRadiusMillimeters: effective.cornerRadius,
            postFreeLengthMillimeters: effective.freeLength,
            totalPostExtentMillimeters: effective.stations.freeEndMillimeters,
            minimumPinLigamentMillimeters: effective.minimumPinLigament,
            postWasAutoGrown: effective.autoGrown,
            rootOverlapDepthMillimeters: abs(effective.stations.rootInnerMillimeters),
            rootOverlapCubicMillimeters: quantized(rootConnection.measuredOverlapCubicMillimeters),
            collarInnerWidthMillimeters: effective.width + preparation.fitClearance * 2,
            collarInnerThicknessMillimeters: effective.thickness + preparation.fitClearance * 2,
            collarLengthMillimeters: effective.collarAllowance,
            crossPinDiameterMillimeters: preparation.crossPinDiameter,
            crossPinCenter: crossPinCenter,
            crossPinAxis: codable(pinAxis),
            axialStations: effective.stations
        )
        let artifact = ToolingArtifact(
            id: ToolingArtifactID("PREPARED MASTER"),
            name: "PREPARED MASTER",
            role: .preparedMaster,
            geometry: prepared,
            qualification: .topologyValid,
            materialHint: "Geometry complete - load capacity unverified"
        )
        let openingOffset = effective.thickness / 2 + openingExtension
        let boreValidation = PinBoreValidation(
            intendedThroughVolumeCubicMillimeters: intendedPinRemoval,
            removedVolumeCubicMillimeters: pinRemoval,
            relativeVolumeError: pinRelativeError,
            remainingToolIntersectionCubicMillimeters: remainingPinVolume,
            hasTwoExteriorOpenings: true,
            openingA: codable(add(pinCenter, scaled(pinAxis, openingOffset))),
            openingB: codable(add(pinCenter, scaled(pinAxis, -openingOffset)))
        )
        let sourceVolume = abs(ManifoldEngine.volume(sourceHandle))
        let preparedVolume = abs(ManifoldEngine.volume(preparedHandle))
        let selectedMount = MountSelection(
            point: codable(selection.point),
            outwardAxis: codable(selection.axis),
            sourcePatchAreaSquareMillimeters: quantized(selection.patch.area),
            equivalentPatchDiameterMillimeters: quantized(selection.patch.equivalentDiameter),
            rmsPlanarityMillimeters: quantized(selection.patch.rmsPlanarity),
            requiredPatchAreaSquareMillimeters: quantized(max(100, surface.sourceSurfaceArea * 0.005)),
            requiredEquivalentDiameterMillimeters: quantized(max(12, surface.sourceSpan * 0.08)),
            maximumPlanarityMillimeters: quantized(max(0.5, effective.width * 0.02)),
            exteriorRouteClearanceMillimeters: quantized(route.clearance),
            exteriorCollisionVolumeCubicMillimeters: quantized(route.collisionVolume),
            candidateScore: quantized(selection.score),
            deterministicTieBreak: selection.tieBreak,
            placementMode: preparation.placementMode
        )
        let sourceHash = sha256(canonicalGeometry(source))
        let preparedHash = sha256(canonicalGeometry(prepared))
        let approvalSignature = sha256(canonicalApprovalInput(
            sourceHash: sourceHash,
            preparedHash: preparedHash,
            settings: settings,
            selection: selectedMount,
            fixture: fixture,
            regions: [region],
            additionGeometryHashes: [:]
        ))
        let approved = settings.approvedModificationSignature == approvalSignature
        let summary = MasterPreparationSummary(
            state: approved ? .approved : .approvalRequired,
            retentionEvidence: .preparedPostGeometryOnly,
            sourceGeometrySHA256: sourceHash,
            preparedGeometrySHA256: preparedHash,
            approvalSignature: approvalSignature,
            modificationRegionIDs: [region.id],
            notes: approved
                ? ["Approved prepared-master geometry matches the active source, sanitized settings, measured patch, and all typed modification regions. Load qualification remains unverified."]
                : ["Prepared-master changes require artist approval before manufacturing export. Geometry is complete; load capacity remains unverified."]
        )

        withExtendedLifetime((
            sourceHandle, postHandle, rootIntersection, joined, pinHandle,
            pinIntersection, outsidePin, preparedHandle, remainingPin, missingSource
        )) {}
        return Result(
            kind: .prepared,
            normalizedSource: normalizedSource,
            artifact: artifact,
            selectedMount: selectedMount,
            fixtureDimensions: fixture,
            modificationRegions: [region],
            additionGeometrySHA256ByRegionID: [:],
            approvalSignature: approvalSignature,
            sourcePreservation: SourcePreservation(
                sourceVolumeCubicMillimeters: sourceVolume,
                removedVolumeCubicMillimeters: removedSourceVolume,
                addedVolumeCubicMillimeters: max(0, preparedVolume - sourceVolume)
            ),
            rootConnection: rootConnection,
            siliconeContactProfile: siliconeProfile,
            sourceSurfaceModificationAudit: sourceSurfaceAudit,
            pinBoreRemovedVolumeCubicMillimeters: pinRemoval,
            pinBoreValidation: boreValidation,
            finalGeometry: final,
            summary: summary
        )
    }

    /// Unions typed production-flow additions into a prepared master and
    /// re-establishes every geometry and approval invariant on the final solid.
    static func finalize(
        base: Result,
        source immutableSource: MeshGeometryData,
        settings rawSettings: MotherMoldSettings,
        additions: [Addition]
    ) throws -> Result {
        let settings = rawSettings.sanitized
        guard settings.toolingContractVersion >= 3,
              settings.subtype == .siliconeJacket,
              settings.masterPreparation.sourceMode == .preparedPrint,
              settings.masterPreparation.retentionMode == .preparedPost else {
            throw Error.staleBase("Prepared-master additions require the v3 preparedPrint/preparedPost contract. Rebuild the base result with the current sanitized settings.")
        }
        guard base.kind == .prepared,
              let baseArtifact = base.artifact,
              baseArtifact.id == ToolingArtifactID("PREPARED MASTER"),
              baseArtifact.name == "PREPARED MASTER",
              baseArtifact.role == .preparedMaster,
              let selection = base.selectedMount,
              let fixture = base.fixtureDimensions,
              let baseApprovalSignature = base.approvalSignature else {
            throw Error.staleBase("The finalizer requires a complete PREPARED MASTER base result. Rebuild preparation before applying production-vent additions.")
        }

        try validateInput(immutableSource)
        let sourceHandle: ManifoldHandle
        let baseHandle: ManifoldHandle
        do {
            sourceHandle = try normalizedSourceSolid(immutableSource)
            baseHandle = try ManifoldEngine.make(from: baseArtifact.geometry)
        } catch {
            throw Error.staleBase("The immutable source or prepared base is not an exact closed solid (\(error)). Rebuild preparation before finalization.")
        }
        guard ManifoldEngine.isWatertight(sourceHandle), !ManifoldEngine.isEmpty(sourceHandle),
              ManifoldEngine.isWatertight(baseHandle), !ManifoldEngine.isEmpty(baseHandle) else {
            throw Error.staleBase("The immutable source and prepared base must both be non-empty watertight solids.")
        }
        let normalizedSource = try ManifoldEngine.toMesh(sourceHandle)
        let baseFinal = finalGeometry(for: baseArtifact.geometry, handle: baseHandle)
        guard baseFinal.hasFiniteCoordinates, baseFinal.hasValidIndices, baseFinal.isWatertight,
              baseFinal.connectedComponentCount == 1, baseFinal.signedVolumeCubicMillimeters > 0 else {
            throw Error.staleBase("The prepared base is no longer one finite, indexed, watertight positive-volume solid. Rebuild it before applying additions.")
        }

        let sourceHash = sha256(canonicalGeometry(immutableSource))
        let basePreparedHash = sha256(canonicalGeometry(baseArtifact.geometry))
        guard base.summary.sourceGeometrySHA256 == sourceHash,
              base.summary.preparedGeometrySHA256 == basePreparedHash else {
            throw Error.staleBase("The prepared base hashes do not match the immutable source and base geometry supplied to finalization. Rebuild instead of applying a stale addition.")
        }
        let expectedBaseSignature = sha256(canonicalApprovalInput(
            sourceHash: sourceHash,
            preparedHash: basePreparedHash,
            settings: settings,
            selection: selection,
            fixture: fixture,
            regions: base.modificationRegions,
            additionGeometryHashes: base.additionGeometrySHA256ByRegionID
        ))
        guard expectedBaseSignature == baseApprovalSignature else {
            throw Error.staleBase("The prepared base was derived from different sanitized settings, geometry, or modification regions. Rebuild it before applying additions.")
        }

        let baseRegionIDs = base.modificationRegions.map(\.id)
        guard Set(baseRegionIDs).count == baseRegionIDs.count else {
            throw Error.staleBase("The prepared base contains duplicate modification-region IDs. Rebuild it before applying additions.")
        }
        let sortedAdditions = additions.sorted {
            if $0.region.id != $1.region.id { return $0.region.id < $1.region.id }
            return canonicalGeometry($0.solid) < canonicalGeometry($1.solid)
        }
        let additionRegionIDs = sortedAdditions.map(\.region.id)
        guard Set(additionRegionIDs).count == additionRegionIDs.count,
              Set(baseRegionIDs).isDisjoint(with: Set(additionRegionIDs)) else {
            throw Error.invalidAddition("Every addition requires a unique typed modification-region ID that is not already present on the prepared base.")
        }
        let baseProductionRegionIDs = Set(base.modificationRegions.filter {
            $0.kind == .productionVentLanding
        }.map(\.id))
        guard Set(base.additionGeometrySHA256ByRegionID.keys) == baseProductionRegionIDs else {
            throw Error.staleBase("The prepared base does not retain a geometry hash for every finalized production-vent addition. Rebuild it before adding more landings.")
        }

        var currentHandle = baseHandle
        var retainedAdditionHandles: [ManifoldHandle] = []
        retainedAdditionHandles.reserveCapacity(sortedAdditions.count)
        for addition in sortedAdditions {
            let footprint = try validateAdditionRegion(addition.region)
            let additionHandle = try validateAdditionSolid(addition)
            retainedAdditionHandles.append(additionHandle)

            let sourceOverlapHandle = try ManifoldEngine.intersect(sourceHandle, additionHandle)
            let sourceOverlap = abs(ManifoldEngine.volume(sourceOverlapHandle))
            guard sourceOverlap > exteriorCollisionTolerance else {
                throw Error.invalidAddition(
                    "Addition '\(addition.region.id)' does not positively overlap the immutable source at its typed production-vent landing. Move or extend the boss root into the source."
                )
            }
            let preparedOverlapHandle = try ManifoldEngine.intersect(currentHandle, additionHandle)
            let preparedOverlap = abs(ManifoldEngine.volume(preparedOverlapHandle))
            guard preparedOverlap > exteriorCollisionTolerance else {
                throw Error.invalidAddition(
                    "Addition '\(addition.region.id)' is disconnected from the prepared master. Move or extend it until there is positive measured overlap."
                )
            }
            let netAddedVolume = abs(ManifoldEngine.volume(additionHandle)) - preparedOverlap
            guard netAddedVolume > exteriorCollisionTolerance else {
                throw Error.invalidAddition(
                    "Addition '\(addition.region.id)' is stale or fully contained and contributes no positive final volume. Regenerate it from the current prepared master."
                )
            }
            let contactGeometry = try ManifoldEngine.toMesh(sourceOverlapHandle)
            try validateAdditionContact(
                regionID: addition.region.id,
                footprint: footprint,
                contactGeometry: contactGeometry,
                source: normalizedSource
            )

            let unioned = try ManifoldEngine.union(currentHandle, additionHandle)
            guard ManifoldEngine.isWatertight(unioned), !ManifoldEngine.isEmpty(unioned) else {
                throw Error.geometryFailed("Addition '\(addition.region.id)' did not produce a closed prepared-master union. No fallback was generated.")
            }
            currentHandle = unioned
        }

        let prepared = try printableReadback(of: currentHandle)
        let final = finalGeometry(for: prepared, handle: currentHandle)
        guard final.hasFiniteCoordinates, final.hasValidIndices, final.isWatertight,
              final.connectedComponentCount == 1, final.signedVolumeCubicMillimeters > 0 else {
            let closure = MotherMoldValidation.surfaceClosure(prepared)
            let strict = MotherMoldValidation.printablePreflight(prepared)
            throw Error.geometryFailed(
                String(
                    format: "The finalized PREPARED MASTER is not one finite, indexed, watertight positive-volume solid (boundary edges: %d, non-manifold edges: %d, degenerate triangles: %d, Manifold-proven: %@, material components: %d). No fallback was generated.",
                    closure.boundary,
                    closure.nonManifold,
                    strict.degenerateTriangleCount,
                    (strict.manifoldValidated || ManifoldEngine.isWatertight(currentHandle)).description,
                    final.connectedComponentCount
                )
            )
        }

        let missingBase = try ManifoldEngine.difference(baseHandle, currentHandle)
        let missingBaseVolume = abs(ManifoldEngine.volume(missingBase))
        guard missingBaseVolume <= sourcePreservationTolerance else {
            throw Error.geometryFailed(
                String(format: "Finalization removed %.4f mm3 of the validated prepared base, so the complete rounded-D post was not retained.", missingBaseVolume)
            )
        }
        let missingSource = try ManifoldEngine.difference(sourceHandle, currentHandle)
        let removedSourceVolume = abs(ManifoldEngine.volume(missingSource))
        guard removedSourceVolume <= sourcePreservationTolerance else {
            throw Error.geometryFailed(
                String(format: "Finalization removed %.4f mm3 of immutable-source material, exceeding the 0.01 mm3 preservation limit.", removedSourceVolume)
            )
        }

        let point = Vec3(x: selection.point.x, y: selection.point.y, z: selection.point.z)
        guard let axis = normalized(Vec3(
            x: selection.outwardAxis.x,
            y: selection.outwardAxis.y,
            z: selection.outwardAxis.z
        )) else {
            throw Error.staleBase("The prepared base has no finite non-zero mount axis. Rebuild it before finalization.")
        }
        let basis = orthonormalBasis(for: axis)
        let effective = effectiveDimensions(from: fixture)
        let rootConnection = try rootConnectionEvidence(
            sourceHandle: sourceHandle,
            preparedHandle: currentHandle,
            point: point,
            axis: axis,
            effective: effective
        )
        guard rootConnection.hasCompleteConnectedFootprint else {
            throw Error.geometryFailed("Finalization no longer retains the complete connected round root footprint. Regenerate the additions away from the anchor root.")
        }
        let siliconeProfile = try siliconeContactProfileEvidence(
            prepared: prepared,
            point: point,
            axis: axis,
            basis: basis,
            effective: effective
        )
        guard siliconeProfile.isMonotoneTowardNominalGate,
              !siliconeProfile.hasReentrantUndercut,
              siliconeProfile.measuredBlendRadiusMillimeters >= 1,
              siliconeProfile.isRoundAtLinerOuterStation else {
            throw Error.geometryFailed("Finalization altered the tangent silicone-contact profile or its round liner-outer section.")
        }
        let pinBore = try pinBoreValidation(
            preparedHandle: currentHandle,
            point: point,
            axis: axis,
            basis: basis,
            effective: effective,
            fixture: fixture
        )

        let finalRegions = (base.modificationRegions + sortedAdditions.map(\.region)).sorted { $0.id < $1.id }
        let sourceSurface = try buildSurfaceData(normalizedSource)
        let sourceSurfaceAudit = sourceSurfaceModificationAudit(
            source: normalizedSource,
            prepared: prepared,
            approvedRegions: finalRegions,
            footprintAxialTolerance: max(0.05, selection.maximumPlanarityMillimeters + 0.05),
            sourceSurfaceArea: sourceSurface.sourceSurfaceArea
        )
        guard sourceSurfaceAudit.passed else {
            throw Error.geometryFailed(
                String(
                    format: "Finalization changes %.3f mm2 of immutable-source surface outside all typed footprints (limit %.3f mm2), with %.4f mm maximum sampled distance (limit 0.05 mm). Remove the untyped contact or add the correct region.",
                    sourceSurfaceAudit.changedAreaOutsideFootprintSquareMillimeters,
                    sourceSurfaceAudit.allowedChangedAreaSquareMillimeters,
                    sourceSurfaceAudit.maximumDistanceOutsideFootprintMillimeters
                )
            )
        }

        let preparedHash = sha256(canonicalGeometry(prepared))
        var finalAdditionHashes = base.additionGeometrySHA256ByRegionID
        for addition in sortedAdditions {
            finalAdditionHashes[addition.region.id] = sha256(canonicalGeometry(addition.solid))
        }
        let approvalSignature = sha256(canonicalApprovalInput(
            sourceHash: sourceHash,
            preparedHash: preparedHash,
            settings: settings,
            selection: selection,
            fixture: fixture,
            regions: finalRegions,
            additionGeometryHashes: finalAdditionHashes
        ))
        let approved = settings.approvedModificationSignature == approvalSignature
        var artifact = baseArtifact
        artifact.id = ToolingArtifactID("PREPARED MASTER")
        artifact.name = "PREPARED MASTER"
        artifact.role = .preparedMaster
        artifact.geometry = prepared
        artifact.qualification = .topologyValid
        artifact.materialHint = "Geometry complete - load capacity unverified"
        let sourceVolume = abs(ManifoldEngine.volume(sourceHandle))
        let preparedVolume = abs(ManifoldEngine.volume(currentHandle))
        let summary = MasterPreparationSummary(
            state: approved ? .approved : .approvalRequired,
            retentionEvidence: .preparedPostGeometryOnly,
            sourceGeometrySHA256: sourceHash,
            preparedGeometrySHA256: preparedHash,
            approvalSignature: approvalSignature,
            modificationRegionIDs: finalRegions.map(\.id),
            notes: approved
                ? ["Approved finalized prepared-master geometry matches the immutable source, sanitized settings, and all typed modification regions. Load qualification remains unverified."]
                : ["Final prepared-master geometry, including production-vent landings, requires artist approval. Load capacity remains unverified."]
        )

        withExtendedLifetime((sourceHandle, baseHandle, retainedAdditionHandles, currentHandle, missingBase, missingSource)) {}
        return Result(
            kind: .prepared,
            normalizedSource: normalizedSource,
            artifact: artifact,
            selectedMount: selection,
            fixtureDimensions: fixture,
            modificationRegions: finalRegions,
            additionGeometrySHA256ByRegionID: finalAdditionHashes,
            approvalSignature: approvalSignature,
            sourcePreservation: SourcePreservation(
                sourceVolumeCubicMillimeters: sourceVolume,
                removedVolumeCubicMillimeters: removedSourceVolume,
                addedVolumeCubicMillimeters: max(0, preparedVolume - sourceVolume)
            ),
            rootConnection: rootConnection,
            siliconeContactProfile: siliconeProfile,
            sourceSurfaceModificationAudit: sourceSurfaceAudit,
            pinBoreRemovedVolumeCubicMillimeters: pinBore.removedVolumeCubicMillimeters,
            pinBoreValidation: pinBore,
            finalGeometry: final,
            summary: summary
        )
    }

    private static func notApplicableResult(
        retention: MasterRetentionEvidence,
        state: MasterPreparationState
    ) -> Result {
        Result(
            kind: state == .externalFixture ? .external : .notApplicable,
            normalizedSource: nil,
            artifact: nil,
            selectedMount: nil,
            fixtureDimensions: nil,
            modificationRegions: [],
            additionGeometrySHA256ByRegionID: [:],
            approvalSignature: nil,
            sourcePreservation: nil,
            rootConnection: nil,
            siliconeContactProfile: nil,
            sourceSurfaceModificationAudit: nil,
            pinBoreRemovedVolumeCubicMillimeters: nil,
            pinBoreValidation: nil,
            finalGeometry: nil,
            summary: MasterPreparationSummary(
                state: state,
                retentionEvidence: retention,
                notes: state == .externalFixture
                    ? ["External fixture selected; Refab Artist did not create a modified prepared master."]
                    : ["No prepared-master artifact applies to the selected source/retention mode."]
            )
        )
    }

    private static func validateInput(_ source: MeshGeometryData) throws {
        guard !source.vertices.isEmpty, source.triangleIndices.count >= 3,
              source.triangleIndices.count % 3 == 0 else {
            throw Error.invalidSource("The active source has no complete triangle mesh. Repair or re-import it before preparing a master.")
        }
        guard source.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw Error.invalidSource("The active source contains non-finite coordinates. Repair it before preparing a master.")
        }
        guard source.triangleIndices.allSatisfy({ source.vertices.indices.contains(Int($0)) }) else {
            throw Error.invalidSource("The active source has triangle indices outside its vertex array. Repair it before preparing a master.")
        }
    }

    private static func validateAdditionRegion(
        _ region: MasterModificationRegion
    ) throws -> ApprovedFootprint {
        guard region.kind == .productionVentLanding else {
            throw Error.invalidAddition(
                "Addition '\(region.id)' must use the productionVentLanding modification kind. Regenerate it with the neutral landing-boss contract."
            )
        }
        guard !region.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !region.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.invalidAddition("Every production-vent addition requires a stable non-empty region ID and purpose.")
        }
        let coordinates = [region.center] + region.boundary
        guard region.surfaceArea.isFinite, region.surfaceArea > 0,
              region.boundary.count >= 3,
              coordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw Error.invalidAddition(
                "Addition '\(region.id)' has an invalid typed region. Supply a finite positive-area boundary with at least three points."
            )
        }
        guard let footprint = approvedFootprint(for: region, axialTolerance: 0.55) else {
            throw Error.invalidAddition(
                "Addition '\(region.id)' has a degenerate modification boundary. Supply an ordered non-collinear footprint on the source surface."
            )
        }
        let center = Vec3(x: region.center.x, y: region.center.y, z: region.center.z)
        let maximumPlaneError = region.boundary.map {
            abs(dot(
                subtract(Vec3(x: $0.x, y: $0.y, z: $0.z), center),
                footprint.normal
            ))
        }.max() ?? .infinity
        guard maximumPlaneError <= 0.05 else {
            throw Error.invalidAddition(
                String(format: "Addition '%@' has a non-planar typed footprint (%.3f mm deviation; limit 0.05 mm). Regenerate its boundary.", region.id, maximumPlaneError)
            )
        }
        let measuredArea = polygonArea(footprint.polygon)
        let areaTolerance = max(0.1, region.surfaceArea * 0.02)
        guard measuredArea > 0,
              abs(measuredArea - region.surfaceArea) <= areaTolerance else {
            throw Error.invalidAddition(
                String(format: "Addition '%@' reports %.3f mm2 but its typed boundary measures %.3f mm2. Regenerate the stale region metadata.", region.id, region.surfaceArea, measuredArea)
            )
        }
        return footprint
    }

    private static func validateAdditionSolid(_ addition: Addition) throws -> ManifoldHandle {
        let solid = addition.solid
        guard !solid.vertices.isEmpty,
              solid.triangleIndices.count >= 3,
              solid.triangleIndices.count % 3 == 0,
              solid.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              solid.triangleIndices.allSatisfy({ solid.vertices.indices.contains(Int($0)) }) else {
            throw Error.invalidAddition(
                "Addition '\(addition.region.id)' has non-finite geometry or invalid triangle indices. Regenerate the closed landing boss."
            )
        }
        let closure = MotherMoldValidation.surfaceClosure(solid)
        guard closure.closed, connectedComponentCount(solid) == 1 else {
            throw Error.invalidAddition(
                "Addition '\(addition.region.id)' must be one connected closed solid before finalization."
            )
        }
        let handle: ManifoldHandle
        do {
            handle = try ManifoldEngine.make(from: solid)
        } catch {
            throw Error.invalidAddition(
                "Addition '\(addition.region.id)' is not an exact manifold solid (\(error)). Regenerate it without healing or voxel fallback."
            )
        }
        guard ManifoldEngine.isWatertight(handle), !ManifoldEngine.isEmpty(handle),
              ManifoldEngine.volume(handle) > exteriorCollisionTolerance else {
            throw Error.invalidAddition(
                "Addition '\(addition.region.id)' must have closed topology and positive measured volume."
            )
        }
        return handle
    }

    private static func validateAdditionContact(
        regionID: String,
        footprint: ApprovedFootprint,
        contactGeometry: MeshGeometryData,
        source: MeshGeometryData
    ) throws {
        guard connectedComponentCount(contactGeometry) == 1 else {
            throw Error.invalidAddition(
                "Addition '\(regionID)' contacts the immutable source in multiple disconnected regions. Split it into uniquely typed landing bosses."
            )
        }
        let sourceDistance = nearestSurfaceDistance(from: footprint.center, to: source)
        guard sourceDistance <= 0.05 else {
            throw Error.invalidAddition(
                String(format: "Addition '%@' has stale region metadata: its center is %.3f mm from the immutable source (limit 0.05 mm).", regionID, sourceDistance)
            )
        }
        guard contactGeometry.vertices.allSatisfy({
            projectedFootprintContains($0, footprint: footprint, edgeTolerance: 0.10)
        }) else {
            throw Error.invalidAddition(
                "Addition '\(regionID)' overlaps the immutable source outside its typed landing footprint. Regenerate the boss and region together."
            )
        }
    }

    private static func effectiveDimensions(from fixture: FixtureDimensions) -> EffectiveDimensions {
        EffectiveDimensions(
            gateDiameter: fixture.gateRootDiameterMillimeters,
            rootFilletRadius: fixture.rootFilletRadiusMillimeters,
            rootFootprintRadius: fixture.approvedRootFootprintDiameterMillimeters / 2,
            width: fixture.postWidthMillimeters,
            thickness: fixture.postThicknessMillimeters,
            cornerRadius: fixture.postCornerRadiusMillimeters,
            freeLength: fixture.postFreeLengthMillimeters,
            minimumPinLigament: fixture.minimumPinLigamentMillimeters,
            autoGrown: fixture.postWasAutoGrown,
            collarAllowance: fixture.collarLengthMillimeters,
            stations: fixture.axialStations
        )
    }

    private static func rootConnectionEvidence(
        sourceHandle: ManifoldHandle,
        preparedHandle: ManifoldHandle,
        point: Vec3,
        axis: Vec3,
        effective: EffectiveDimensions
    ) throws -> RootConnectionEvidence {
        let depth = abs(effective.stations.rootInnerMillimeters)
        let rootCenterStation = (effective.stations.rootInnerMillimeters
            + effective.stations.sourceSurfaceMillimeters) / 2
        let rootProbe = cylinder(
            center: add(point, scaled(axis, rootCenterStation)),
            axis: axis,
            radius: effective.rootFootprintRadius,
            length: depth,
            segments: profileSegments
        )
        let rootProbeHandle = try ManifoldEngine.make(from: rootProbe)
        let sourceRoot = try ManifoldEngine.intersect(sourceHandle, rootProbeHandle)
        let finalRoot = try ManifoldEngine.intersect(preparedHandle, sourceRoot)
        let measured = abs(ManifoldEngine.volume(finalRoot))
        let intended = Double.pi * pow(effective.rootFootprintRadius, 2) * depth
        let coverage = measured / intended
        let components: Int
        if ManifoldEngine.isEmpty(finalRoot) {
            components = 0
        } else {
            components = connectedComponentCount(try ManifoldEngine.toMesh(finalRoot))
        }
        withExtendedLifetime((rootProbeHandle, sourceRoot, finalRoot)) {}
        return RootConnectionEvidence(
            intendedOverlapCubicMillimeters: intended,
            measuredOverlapCubicMillimeters: measured,
            overlapCoverageFraction: coverage,
            connectedComponentCount: components,
            hasCompleteConnectedFootprint: coverage >= 0.995 && components == 1
        )
    }

    private static func pinBoreValidation(
        preparedHandle: ManifoldHandle,
        point: Vec3,
        axis: Vec3,
        basis: (u: Vec3, v: Vec3),
        effective: EffectiveDimensions,
        fixture: FixtureDimensions
    ) throws -> PinBoreValidation {
        let pinCenter = Vec3(
            x: fixture.crossPinCenter.x,
            y: fixture.crossPinCenter.y,
            z: fixture.crossPinCenter.z
        )
        guard let pinAxis = normalized(Vec3(
            x: fixture.crossPinAxis.x,
            y: fixture.crossPinAxis.y,
            z: fixture.crossPinAxis.z
        )) else {
            throw Error.staleBase("The prepared base has no finite non-zero cross-pin axis. Rebuild it before finalization.")
        }
        let pinDiameter = fixture.crossPinDiameterMillimeters
        let pinRadius = pinDiameter / 2
        let openingExtension = max(1, pinDiameter * 0.25)
        let pinTool = cylinder(
            center: pinCenter,
            axis: pinAxis,
            radius: pinRadius,
            length: effective.thickness + 2 * openingExtension,
            segments: profileSegments
        )
        let pinHandle = try ManifoldEngine.make(from: pinTool)
        let postHandle = try ManifoldEngine.make(from: phasedPostGeometry(
            point: point,
            axis: axis,
            basis: basis,
            effective: effective
        ))
        let intendedIntersection = try ManifoldEngine.intersect(postHandle, pinHandle)
        let measuredIntended = abs(ManifoldEngine.volume(intendedIntersection))
        let remaining = try ManifoldEngine.intersect(preparedHandle, pinHandle)
        let remainingVolume = abs(ManifoldEngine.volume(remaining))
        let removed = max(0, measuredIntended - remainingVolume)
        let intended = Double.pi * pinRadius * pinRadius * effective.thickness
        let relativeError = abs(removed - intended) / intended
        guard relativeError <= boreRelativeTolerance,
              remainingVolume <= 0.001 else {
            throw Error.geometryFailed(
                String(format: "The finalized cross-pin bore removes %.3f of %.3f mm3 (%.3f%% error) and retains %.4f mm3 of obstruction.", removed, intended, relativeError * 100, remainingVolume)
            )
        }
        let outsidePin = try ManifoldEngine.difference(pinHandle, postHandle)
        guard !ManifoldEngine.isEmpty(outsidePin),
              connectedComponentCount(try ManifoldEngine.toMesh(outsidePin)) == 2 else {
            throw Error.geometryFailed("The finalized cross-pin no longer has two openings wholly outside the constant rounded-D dry post.")
        }
        let openingOffset = effective.thickness / 2 + openingExtension
        withExtendedLifetime((pinHandle, postHandle, intendedIntersection, remaining, outsidePin)) {}
        return PinBoreValidation(
            intendedThroughVolumeCubicMillimeters: intended,
            removedVolumeCubicMillimeters: removed,
            relativeVolumeError: relativeError,
            remainingToolIntersectionCubicMillimeters: remainingVolume,
            hasTwoExteriorOpenings: true,
            openingA: codable(add(pinCenter, scaled(pinAxis, openingOffset))),
            openingB: codable(add(pinCenter, scaled(pinAxis, -openingOffset)))
        )
    }

    private static func resolveDimensions(
        settings: MotherMoldSettings,
        sourceSpan: Double
    ) throws -> EffectiveDimensions {
        let preparation = settings.masterPreparation
        let pin = preparation.crossPinDiameter
        let minimumLigament = max(3, 1.25 * pin)
        let minimumWidth = pin + 2 * minimumLigament
        let minimumFreeLength = max(18, 3 * pin + 8)
        let gateDiameter = min(30, max(6, settings.productionFlow.gateDiameter))
        let initialAutomaticWidth = min(24, max(14, 0.12 * sourceSpan))

        let width: Double
        let thickness: Double
        let freeLength: Double
        let autoGrown: Bool
        switch preparation.placementMode {
        case .auto:
            width = max(preparation.postWidth, preparation.postThickness, initialAutomaticWidth, minimumWidth)
            thickness = max(preparation.postThickness, width * 0.75)
            freeLength = max(preparation.postFreeLength, minimumFreeLength)
            autoGrown = width > preparation.postWidth + 1.0e-9
                || thickness > preparation.postThickness + 1.0e-9
                || freeLength > preparation.postFreeLength + 1.0e-9
        case .manual:
            guard preparation.postWidth >= minimumWidth else {
                throw Error.unsafeDimensions(
                    "The manual post is undersized: a \(String(format: "%.1f", pin)) mm pin requires \(String(format: "%.1f", minimumLigament)) mm ligament per side and at least \(String(format: "%.1f", minimumWidth)) mm post width. Increase the width or reduce the pin."
                )
            }
            guard preparation.postWidth >= preparation.postThickness else {
                throw Error.unsafeDimensions("The manual rounded-D post width must be at least its thickness. Increase width or reduce thickness.")
            }
            guard preparation.postFreeLength >= minimumFreeLength else {
                throw Error.unsafeDimensions(
                    "The manual free post must be at least \(String(format: "%.1f", minimumFreeLength)) mm so the cross-pin clears the collar face and free end by 1.5 diameters."
                )
            }
            width = preparation.postWidth
            thickness = preparation.postThickness
            freeLength = preparation.postFreeLength
            autoGrown = false
        }

        let collarAllowance = max(8, preparation.sealLandWidth)
        let rootFilletRadius = max(2, 0.15 * gateDiameter)
        guard settings.siliconeGap >= rootFilletRadius + 0.5 else {
            throw Error.unsafeDimensions(
                "The silicone gap must be at least \(String(format: "%.1f", rootFilletRadius + 0.5)) mm to contain the \(String(format: "%.1f", rootFilletRadius)) mm tangent root fillet followed by a constant round gate transition. Increase silicone gap or reduce gate diameter."
            )
        }
        let rootFootprintRadius = gateDiameter / 2 + rootFilletRadius
        let rootDepth = rootFilletRadius
        let sourceSurface = 0.0
        let rootFilletPeak = rootFilletRadius
        let siliconeOuter = settings.siliconeGap
        let shellOuter = siliconeOuter + settings.wallThickness
        let collarFace = shellOuter + collarAllowance
        let pinCenter = collarFace + freeLength / 2
        let freeEnd = collarFace + freeLength
        guard pinCenter - collarFace >= 1.5 * pin,
              freeEnd - pinCenter >= 1.5 * pin else {
            throw Error.unsafeDimensions("The cross-pin center cannot clear both the collar face and free end by 1.5 pin diameters. Increase free post length.")
        }

        return EffectiveDimensions(
            gateDiameter: gateDiameter,
            rootFilletRadius: rootFilletRadius,
            rootFootprintRadius: rootFootprintRadius,
            width: width,
            thickness: thickness,
            cornerRadius: 0.20 * thickness,
            freeLength: freeLength,
            minimumPinLigament: minimumLigament,
            autoGrown: autoGrown,
            collarAllowance: collarAllowance,
            stations: AxialStations(
                rootInnerMillimeters: -rootDepth,
                sourceSurfaceMillimeters: sourceSurface,
                rootFilletPeakMillimeters: rootFilletPeak,
                siliconeOuterMillimeters: siliconeOuter,
                shellOuterMillimeters: shellOuter,
                dryPostStartMillimeters: shellOuter,
                collarFaceMillimeters: collarFace,
                pinCenterMillimeters: pinCenter,
                freeEndMillimeters: freeEnd
            )
        )
    }

    private static func buildSurfaceData(_ source: MeshGeometryData) throws -> SurfaceData {
        let minPoint = source.vertices.reduce(source.vertices[0]) { current, point in
            Vec3(x: min(current.x, point.x), y: min(current.y, point.y), z: min(current.z, point.z))
        }
        let maxPoint = source.vertices.reduce(source.vertices[0]) { current, point in
            Vec3(x: max(current.x, point.x), y: max(current.y, point.y), z: max(current.z, point.z))
        }
        let windingSign = MoldComponentFilter.signedVolume(source) >= 0 ? 1.0 : -1.0
        var triangles: [SurfaceTriangle] = []
        var offset = 0
        while offset + 2 < source.triangleIndices.count {
            let vertices = (0..<3).map { source.vertices[Int(source.triangleIndices[offset + $0])] }
            let rawNormal = cross(subtract(vertices[1], vertices[0]), subtract(vertices[2], vertices[0]))
            let magnitude = length(rawNormal)
            guard magnitude > 1.0e-9 else {
                throw Error.invalidSource("The active source contains a degenerate triangle. Repair it before prepared-master patch analysis.")
            }
            let centroid = scaled(vertices.reduce(Vec3(x: 0, y: 0, z: 0), add), 1 / 3)
            let normal = scaled(rawNormal, windingSign / magnitude)
            let edges = [
                EdgeKey(vertices[0], vertices[1]),
                EdgeKey(vertices[1], vertices[2]),
                EdgeKey(vertices[2], vertices[0]),
            ]
            triangles.append(SurfaceTriangle(
                vertices: vertices,
                normal: normal,
                area: magnitude / 2,
                centroid: centroid,
                edges: edges,
                canonicalKey: vertices.map { PointKey($0).description }.sorted().joined(separator: "|")
            ))
            offset += 3
        }
        triangles.sort { $0.canonicalKey < $1.canonicalKey }

        var edgeOwners: [EdgeKey: [Int]] = [:]
        for (index, triangle) in triangles.enumerated() {
            for edge in triangle.edges { edgeOwners[edge, default: []].append(index) }
        }
        var adjacency = [[Int]](repeating: [], count: triangles.count)
        for owners in edgeOwners.values where owners.count > 1 {
            let sorted = owners.sorted { triangles[$0].canonicalKey < triangles[$1].canonicalKey }
            for lhs in sorted {
                for rhs in sorted where lhs != rhs { adjacency[lhs].append(rhs) }
            }
        }
        for index in adjacency.indices {
            adjacency[index] = Array(Set(adjacency[index])).sorted {
                triangles[$0].canonicalKey < triangles[$1].canonicalKey
            }
        }
        let surfaceArea = triangles.reduce(0) { $0 + $1.area }
        let sourceSpan = max(maxPoint.x - minPoint.x, max(maxPoint.y - minPoint.y, maxPoint.z - minPoint.z))
        return SurfaceData(
            triangles: triangles,
            adjacency: adjacency,
            sourceSurfaceArea: surfaceArea,
            sourceSpan: sourceSpan
        )
    }

    private static func selectMount(
        surface: SurfaceData,
        source: MeshGeometryData,
        sourceHandle: ManifoldHandle,
        settings: MotherMoldSettings,
        effective: EffectiveDimensions
    ) throws -> Candidate {
        let preparation = settings.masterPreparation
        let requiredArea = max(100, surface.sourceSurfaceArea * 0.005)
        let requiredDiameter = max(12, surface.sourceSpan * 0.08)
        let planarityLimit = max(0.5, effective.width * 0.02)

        func validatePatch(_ patch: SurfacePatch, manual: Bool) throws {
            guard patch.triangleIndices.count >= 2 else {
                let message = "A single source triangle cannot qualify as a mount patch. Pick an edge-connected measured surface region."
                throw manual ? Error.invalidManualPlacement(message) : Error.noSafePatch(message)
            }
            guard patch.area + 1.0e-6 >= requiredArea else {
                let message = String(
                    format: "The connected mount patch measures %.1f mm2; at least %.1f mm2 is required. Pick a broader accessible surface or reorient the master.",
                    patch.area,
                    requiredArea
                )
                throw manual ? Error.invalidManualPlacement(message) : Error.noSafePatch(message)
            }
            guard patch.equivalentDiameter + 1.0e-6 >= requiredDiameter else {
                let message = String(
                    format: "The connected mount patch has %.1f mm equivalent diameter; at least %.1f mm is required. Pick a broader accessible surface.",
                    patch.equivalentDiameter,
                    requiredDiameter
                )
                throw manual ? Error.invalidManualPlacement(message) : Error.noSafePatch(message)
            }
            guard patch.rmsPlanarity <= planarityLimit + 1.0e-6 else {
                let message = String(
                    format: "The connected mount patch has %.3f mm RMS planarity error; the %.3f mm limit is exceeded. Pick a flatter patch or reorient the master.",
                    patch.rmsPlanarity,
                    planarityLimit
                )
                throw manual ? Error.invalidManualPlacement(message) : Error.noSafePatch(message)
            }
        }

        switch preparation.placementMode {
        case .manual:
            guard let manualPoint = preparation.manualPoint, let manualAxis = preparation.manualAxis else {
                throw Error.invalidManualPlacement("Pick a mount area and an outward mount axis before building the prepared master.")
            }
            let requestedPoint = Vec3(x: manualPoint.x, y: manualPoint.y, z: manualPoint.z)
            guard let axis = normalized(Vec3(x: manualAxis.x, y: manualAxis.y, z: manualAxis.z)) else {
                throw Error.invalidManualPlacement("The manual mount axis has no direction. Pick an outward normal from the model surface.")
            }
            guard let nearest = nearestTriangle(to: requestedPoint, surface: surface) else {
                throw Error.invalidManualPlacement("The manual point could not be resolved to the active source surface.")
            }
            guard nearest.distance <= mountTolerance else {
                throw Error.invalidManualPlacement(
                    "The manual mount point is \(String(format: "%.2f", nearest.distance)) mm from the source surface. Pick the actual accessible surface."
                )
            }
            let patch = buildPatch(seed: nearest.index, surface: surface, planarityLimit: planarityLimit)
            try validatePatch(patch, manual: true)
            guard dot(axis, patch.normal) >= 0.85 else {
                throw Error.invalidManualPlacement("The manual axis does not point outward from the measured connected patch. Flip it or pick another patch.")
            }
            let point = nearest.point
            guard rootFootprintFits(point: point, axis: axis, radius: effective.rootFootprintRadius, patch: patch, surface: surface, tolerance: planarityLimit) else {
                throw Error.invalidManualPlacement("The round gate root does not fit inside the measured connected manual patch. Pick a point farther from its boundary.")
            }
            let basis = orthonormalBasis(for: axis)
            let post = phasedPostGeometry(point: point, axis: axis, basis: basis, effective: effective)
            let postHandle = try ManifoldEngine.make(from: post)
            let route = try routeEvidence(
                point: point,
                axis: axis,
                effective: effective,
                source: source,
                sourceHandle: sourceHandle,
                postHandle: postHandle
            )
            guard route.collisionVolume <= exteriorCollisionTolerance else {
                throw Error.invalidManualPlacement(
                    String(format: "The manual post route intersects the source by %.3f mm3 outside the round root. Pick another accessible route.", route.collisionVolume)
                )
            }
            let tieBreak = patch.boundaryKey + "|" + canonicalPoint(point) + "|" + canonicalPoint(axis)
            return Candidate(
                patch: patch,
                point: point,
                axis: axis,
                routeClearance: route.clearance,
                collisionVolume: route.collisionVolume,
                score: candidateScore(
                    patch: patch,
                    alignment: dot(axis, patch.normal),
                    requiredArea: requiredArea,
                    requiredDiameter: requiredDiameter,
                    planarityLimit: planarityLimit,
                    routeClearance: route.clearance
                ),
                tieBreak: tieBreak
            )

        case .auto:
            let preferredAxis = preferredMountAxis(preparation)
            var candidates: [Candidate] = []
            var coveredSeeds: Set<Int> = []
            var seenPatchKeys: Set<String> = []
            let orderedSeeds = surface.triangles.indices.sorted {
                surface.triangles[$0].canonicalKey < surface.triangles[$1].canonicalKey
            }
            for seed in orderedSeeds {
                if coveredSeeds.contains(seed) { continue }
                let seedAlignment = dot(surface.triangles[seed].normal, preferredAxis)
                guard seedAlignment >= 0.5 else { continue }
                let patch = buildPatch(seed: seed, surface: surface, planarityLimit: planarityLimit)
                let isUniformPlanarPatch = patch.rmsPlanarity <= 1.0e-6
                    && patch.triangleIndices.allSatisfy {
                        dot(surface.triangles[$0].normal, patch.normal) >= 1 - 1.0e-9
                    }
                if isUniformPlanarPatch { coveredSeeds.formUnion(patch.triangleIndices) }
                guard seenPatchKeys.insert(patch.boundaryKey).inserted else { continue }
                guard patch.triangleIndices.count >= 2,
                      patch.area + 1.0e-6 >= requiredArea,
                      patch.equivalentDiameter + 1.0e-6 >= requiredDiameter,
                      patch.rmsPlanarity <= planarityLimit + 1.0e-6,
                      dot(patch.normal, preferredAxis) >= 0.5 else { continue }
                let point = quantized(patch.center, step: 1.0e-6)
                let axis = quantized(patch.normal, step: 1.0e-9)
                guard rootFootprintFits(point: point, axis: axis, radius: effective.rootFootprintRadius, patch: patch, surface: surface, tolerance: planarityLimit) else {
                    continue
                }
                let basis = orthonormalBasis(for: axis)
                let post = phasedPostGeometry(point: point, axis: axis, basis: basis, effective: effective)
                guard let postHandle = try? ManifoldEngine.make(from: post),
                      let route = try? routeEvidence(
                        point: point,
                        axis: axis,
                        effective: effective,
                        source: source,
                        sourceHandle: sourceHandle,
                        postHandle: postHandle
                      ),
                      route.collisionVolume <= exteriorCollisionTolerance else {
                    continue
                }
                let alignment = dot(axis, preferredAxis)
                let score = candidateScore(
                    patch: patch,
                    alignment: alignment,
                    requiredArea: requiredArea,
                    requiredDiameter: requiredDiameter,
                    planarityLimit: planarityLimit,
                    routeClearance: route.clearance
                )
                let tieBreak = patch.boundaryKey + "|" + canonicalPoint(point) + "|" + canonicalPoint(axis)
                candidates.append(Candidate(
                    patch: patch,
                    point: point,
                    axis: axis,
                    routeClearance: route.clearance,
                    collisionVolume: route.collisionVolume,
                    score: score,
                    tieBreak: tieBreak
                ))
            }
            guard let selected = candidates.sorted(by: {
                if abs($0.score - $1.score) > 1.0e-9 { return $0.score > $1.score }
                return $0.tieBreak < $1.tieBreak
            }).first else {
                throw Error.noSafePatch(
                    String(
                        format: "Auto found no edge-connected accessible patch meeting area %.1f mm2, equivalent diameter %.1f mm, RMS planarity %.3f mm, round-root fit, and collision-free complete-post route. Reorient the master, pick manually, or choose an external fixture.",
                        requiredArea,
                        requiredDiameter,
                        planarityLimit
                    )
                )
            }
            return selected
        }
    }

    private static func buildPatch(
        seed: Int,
        surface: SurfaceData,
        planarityLimit: Double
    ) -> SurfacePatch {
        let seedTriangle = surface.triangles[seed]
        let normalThreshold = cos(30 * Double.pi / 180)
        var visited: Set<Int> = [seed]
        var queue = [seed]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            for neighbor in surface.adjacency[current] where !visited.contains(neighbor) {
                let triangle = surface.triangles[neighbor]
                guard dot(triangle.normal, seedTriangle.normal) >= normalThreshold else { continue }
                let maximumSeedPlaneDistance = triangle.vertices.map {
                    abs(dot(subtract($0, seedTriangle.centroid), seedTriangle.normal))
                }.max() ?? .infinity
                guard maximumSeedPlaneDistance <= planarityLimit * 2 else { continue }
                visited.insert(neighbor)
                queue.append(neighbor)
            }
        }

        let indices = visited.sorted { surface.triangles[$0].canonicalKey < surface.triangles[$1].canonicalKey }
        let area = indices.reduce(0) { $0 + surface.triangles[$1].area }
        let weightedCenter = indices.reduce(Vec3(x: 0, y: 0, z: 0)) {
            add($0, scaled(surface.triangles[$1].centroid, surface.triangles[$1].area))
        }
        let center = scaled(weightedCenter, 1 / area)
        let weightedNormal = indices.reduce(Vec3(x: 0, y: 0, z: 0)) {
            add($0, scaled(surface.triangles[$1].normal, surface.triangles[$1].area))
        }
        var normal = normalized(weightedNormal) ?? seedTriangle.normal
        if dot(normal, seedTriangle.normal) < 0 { normal = scaled(normal, -1) }

        var integralSquaredDistance = 0.0
        var edgeCounts: [EdgeKey: Int] = [:]
        for index in indices {
            let triangle = surface.triangles[index]
            let distances = triangle.vertices.map { dot(subtract($0, center), normal) }
            let meanSquare = (
                distances[0] * distances[0]
                + distances[1] * distances[1]
                + distances[2] * distances[2]
                + distances[0] * distances[1]
                + distances[1] * distances[2]
                + distances[2] * distances[0]
            ) / 6
            integralSquaredDistance += triangle.area * meanSquare
            for edge in triangle.edges { edgeCounts[edge, default: 0] += 1 }
        }
        let rms = sqrt(max(0, integralSquaredDistance / area))
        let boundary = edgeCounts.filter { $0.value == 1 }.map(\.key).sorted()
        let boundaryKey = boundary.map(\.description).joined(separator: ";")
            + "|a=" + canonicalNumber(area)
            + "|c=" + canonicalPoint(center)
            + "|n=" + canonicalPoint(normal)
        return SurfacePatch(
            triangleIndices: indices,
            center: quantized(center, step: 1.0e-9),
            normal: quantized(normal, step: 1.0e-9),
            area: quantized(area),
            equivalentDiameter: quantized(2 * sqrt(area / Double.pi)),
            rmsPlanarity: quantized(rms),
            boundaryKey: boundaryKey
        )
    }

    private static func nearestTriangle(
        to point: Vec3,
        surface: SurfaceData
    ) -> (index: Int, point: Vec3, distance: Double)? {
        var best: (index: Int, point: Vec3, distance: Double)?
        for index in surface.triangles.indices {
            let vertices = surface.triangles[index].vertices
            let closest = closestPoint(onTriangle: point, a: vertices[0], b: vertices[1], c: vertices[2])
            let distance = length(subtract(point, closest))
            if best == nil || distance < best!.distance - 1.0e-9
                || (abs(distance - best!.distance) <= 1.0e-9
                    && surface.triangles[index].canonicalKey < surface.triangles[best!.index].canonicalKey) {
                best = (index, closest, distance)
            }
        }
        return best
    }

    private static func rootFootprintFits(
        point: Vec3,
        axis: Vec3,
        radius: Double,
        patch: SurfacePatch,
        surface: SurfaceData,
        tolerance: Double
    ) -> Bool {
        let basis = orthonormalBasis(for: axis)
        let boundary = circleProfile(radius: radius, segments: 32).map { x, y in
            add(point, add(scaled(basis.u, x), scaled(basis.v, y)))
        }
        let permittedDistance = max(0.25, tolerance * 1.5)
        for boundaryPoint in boundary {
            var nearest = Double.infinity
            for index in patch.triangleIndices {
                let vertices = surface.triangles[index].vertices
                let closest = closestPoint(
                    onTriangle: boundaryPoint,
                    a: vertices[0], b: vertices[1], c: vertices[2]
                )
                nearest = min(nearest, length(subtract(boundaryPoint, closest)))
            }
            if nearest > permittedDistance { return false }
        }
        return true
    }

    private static func candidateScore(
        patch: SurfacePatch,
        alignment: Double,
        requiredArea: Double,
        requiredDiameter: Double,
        planarityLimit: Double,
        routeClearance: Double
    ) -> Double {
        let areaScore = min(10, patch.area / requiredArea) * 10
        let diameterScore = min(10, patch.equivalentDiameter / requiredDiameter) * 5
        let planarityScore = max(0, 1 - patch.rmsPlanarity / planarityLimit) * 20
        let clearanceScore = min(100, max(0, routeClearance)) * 0.1
        return quantized(alignment * 1_000 + areaScore + diameterScore + planarityScore + clearanceScore)
    }

    private static func preferredMountAxis(_ preparation: MasterPreparationSettings) -> Vec3 {
        if let up = preparation.linerFillUpAxis,
           let normalizedUp = normalized(Vec3(x: up.x, y: up.y, z: up.z)) {
            return scaled(normalizedUp, -1)
        }
        return Vec3(x: 0, y: 0, z: -1)
    }

    private static func routeEvidence(
        point: Vec3,
        axis: Vec3,
        effective: EffectiveDimensions,
        source: MeshGeometryData,
        sourceHandle: ManifoldHandle,
        postHandle: ManifoldHandle
    ) throws -> RouteEvidence {
        let outwardOffset = dot(point, axis) + 0.01
        let outwardPost = try ManifoldEngine.trimByPlane(postHandle, normal: axis, offset: outwardOffset)
        let approvedEnvelopeLength = effective.rootFilletRadius + 0.04
        let approvedEnvelope = cylinder(
            center: add(point, scaled(axis, effective.rootFilletRadius / 2)),
            axis: axis,
            radius: effective.rootFootprintRadius + 0.05,
            length: approvedEnvelopeLength,
            segments: profileSegments
        )
        let approvedEnvelopeHandle = try ManifoldEngine.make(from: approvedEnvelope)
        let unapprovedPost = try ManifoldEngine.difference(outwardPost, approvedEnvelopeHandle)
        let collision = try ManifoldEngine.intersect(sourceHandle, unapprovedPost)
        let collisionVolume = abs(ManifoldEngine.volume(collision))

        let clearanceOffset = dot(point, axis) + effective.stations.siliconeOuterMillimeters
        let clearancePost = try ManifoldEngine.trimByPlane(
            postHandle,
            normal: axis,
            offset: clearanceOffset
        )
        let clearanceGeometry = try ManifoldEngine.toMesh(clearancePost)
        var samplePoints = clearanceGeometry.vertices
        var postOffset = 0
        while postOffset + 2 < clearanceGeometry.triangleIndices.count {
            let a = clearanceGeometry.vertices[Int(clearanceGeometry.triangleIndices[postOffset])]
            let b = clearanceGeometry.vertices[Int(clearanceGeometry.triangleIndices[postOffset + 1])]
            let c = clearanceGeometry.vertices[Int(clearanceGeometry.triangleIndices[postOffset + 2])]
            samplePoints.append(scaled(add(add(a, b), c), 1 / 3))
            postOffset += 3
        }
        var clearance = Double.infinity
        var offset = 0
        while offset + 2 < source.triangleIndices.count {
            let a = source.vertices[Int(source.triangleIndices[offset])]
            let b = source.vertices[Int(source.triangleIndices[offset + 1])]
            let c = source.vertices[Int(source.triangleIndices[offset + 2])]
            for sample in samplePoints {
                let closest = closestPoint(onTriangle: sample, a: a, b: b, c: c)
                clearance = min(clearance, length(subtract(sample, closest)))
            }
            offset += 3
        }
        return RouteEvidence(clearance: clearance, collisionVolume: collisionVolume)
    }

    private static func phasedPostGeometry(
        point: Vec3,
        axis: Vec3,
        basis: (u: Vec3, v: Vec3),
        effective: EffectiveDimensions
    ) -> MeshGeometryData {
        let stations = effective.stations
        let gateRadius = effective.gateDiameter / 2
        let gateCircle = circleProfile(radius: gateRadius, segments: profileSegments)
        let footprintCircle = circleProfile(
            radius: effective.rootFootprintRadius,
            segments: profileSegments
        )
        let dProfile = roundedDProfile(
            width: effective.width,
            thickness: effective.thickness,
            cornerRadius: effective.cornerRadius,
            segments: profileSegments
        )
        var sections: [(station: Double, profile: [(Double, Double)])] = [
            (stations.rootInnerMillimeters, footprintCircle),
            (stations.sourceSurfaceMillimeters, footprintCircle),
        ]
        for sample in quarterRoundFilletSamples(effective: effective) {
            sections.append((
                sample.station,
                circleProfile(radius: sample.radius, segments: profileSegments)
            ))
        }
        sections += [
            (stations.siliconeOuterMillimeters, gateCircle),
            (stations.shellOuterMillimeters, dProfile),
            (stations.collarFaceMillimeters, dProfile),
            (stations.freeEndMillimeters, dProfile),
        ]
        return loft(sections: sections, point: point, axis: axis, basis: basis)
    }

    private static func quarterRoundFilletSamples(
        effective: EffectiveDimensions,
        count: Int = 16
    ) -> [(station: Double, radius: Double)] {
        let fillet = effective.rootFilletRadius
        return (1...count).map { index in
            let station = fillet * Double(index) / Double(count)
            let radialTerm = sqrt(max(0, fillet * fillet - pow(station - fillet, 2)))
            return (station, effective.rootFootprintRadius - radialTerm)
        }
    }

    private static func siliconeContactProfileEvidence(
        prepared: MeshGeometryData,
        point: Vec3,
        axis: Vec3,
        basis: (u: Vec3, v: Vec3),
        effective: EffectiveDimensions
    ) throws -> SiliconeContactProfileEvidence {
        let expectedFillet = quarterRoundFilletSamples(effective: effective)
        let expected = expectedFillet + [(
            station: effective.stations.siliconeOuterMillimeters,
            radius: effective.gateDiameter / 2
        )]
        var measuredSamples: [RadialProfileSample] = []
        measuredSamples.reserveCapacity(expected.count)
        for expectedSample in expected {
            let radii = prepared.vertices.compactMap { vertex -> Double? in
                let relative = subtract(vertex, point)
                let station = dot(relative, axis)
                guard abs(station - expectedSample.station) <= 1.0e-5 else { return nil }
                let radial = hypot(dot(relative, basis.u), dot(relative, basis.v))
                guard abs(radial - expectedSample.radius) <= 0.1 else { return nil }
                return radial
            }
            guard radii.count >= profileSegments / 2,
                  let minimum = radii.min(), let maximum = radii.max() else {
                throw Error.geometryFailed(
                    "The final prepared mesh does not retain a complete round silicone-contact section at z=\(String(format: "%.3f", expectedSample.station)) mm."
                )
            }
            measuredSamples.append(RadialProfileSample(
                axialStationMillimeters: expectedSample.station,
                measuredRadiusMillimeters: (minimum + maximum) / 2,
                roundnessErrorMillimeters: maximum - minimum
            ))
        }

        let monotoneTolerance = 0.02
        var hasReentrant = false
        for index in 1..<measuredSamples.count {
            if measuredSamples[index].measuredRadiusMillimeters
                > measuredSamples[index - 1].measuredRadiusMillimeters + monotoneTolerance {
                hasReentrant = true
                break
            }
        }
        let blendRadii = measuredSamples.prefix(expectedFillet.count).map { sample in
            hypot(
                sample.measuredRadiusMillimeters - effective.rootFootprintRadius,
                sample.axialStationMillimeters - effective.rootFilletRadius
            )
        }
        let measuredBlend = blendRadii.reduce(0, +) / Double(blendRadii.count)
        let linerOuter = measuredSamples.last!
        let linerDiameter = linerOuter.measuredRadiusMillimeters * 2
        let isRoundAtLinerOuter = linerOuter.roundnessErrorMillimeters <= 0.05
            && abs(linerDiameter - effective.gateDiameter) <= 0.05
        return SiliconeContactProfileEvidence(
            nominalGateDiameterMillimeters: effective.gateDiameter,
            approvedFootprintDiameterMillimeters: effective.rootFootprintRadius * 2,
            measuredBlendRadiusMillimeters: measuredBlend,
            minimumRequiredBlendRadiusMillimeters: 1,
            linerOuterDiameterMillimeters: linerDiameter,
            linerOuterRoundnessErrorMillimeters: linerOuter.roundnessErrorMillimeters,
            isMonotoneTowardNominalGate: !hasReentrant,
            hasReentrantUndercut: hasReentrant,
            isRoundAtLinerOuterStation: isRoundAtLinerOuter,
            samples: measuredSamples
        )
    }

    private static func sourceSurfaceModificationAudit(
        source: MeshGeometryData,
        prepared: MeshGeometryData,
        approvedRegions: [MasterModificationRegion],
        footprintAxialTolerance: Double,
        sourceSurfaceArea: Double
    ) -> SourceSurfaceModificationAudit {
        let approvedFootprints = approvedRegions.compactMap {
            approvedFootprint(for: $0, axialTolerance: footprintAxialTolerance)
        }
        var preparedTriangles: [(Vec3, Vec3, Vec3)] = []
        var preparedOffset = 0
        while preparedOffset + 2 < prepared.triangleIndices.count {
            preparedTriangles.append((
                prepared.vertices[Int(prepared.triangleIndices[preparedOffset])],
                prepared.vertices[Int(prepared.triangleIndices[preparedOffset + 1])],
                prepared.vertices[Int(prepared.triangleIndices[preparedOffset + 2])]
            ))
            preparedOffset += 3
        }

        var sampledPointCount = 0
        var changedArea = 0.0
        var maximumDistance = 0.0
        var sourceOffset = 0
        while sourceOffset + 2 < source.triangleIndices.count {
            let a = source.vertices[Int(source.triangleIndices[sourceOffset])]
            let b = source.vertices[Int(source.triangleIndices[sourceOffset + 1])]
            let c = source.vertices[Int(source.triangleIndices[sourceOffset + 2])]
            let area = length(cross(subtract(b, a), subtract(c, a))) / 2
            let samples = [
                a, b, c,
                scaled(add(add(a, b), c), 1 / 3),
                scaled(add(a, b), 0.5),
                scaled(add(b, c), 0.5),
                scaled(add(c, a), 0.5),
            ]
            var changedSampleCount = 0
            for sample in samples {
                let isInsideApprovedFootprint = approvedFootprints.contains {
                    footprintContains(sample, footprint: $0, edgeTolerance: 0.05)
                }
                if isInsideApprovedFootprint { continue }
                sampledPointCount += 1
                var distance = Double.infinity
                for triangle in preparedTriangles {
                    let closest = closestPoint(
                        onTriangle: sample,
                        a: triangle.0,
                        b: triangle.1,
                        c: triangle.2
                    )
                    distance = min(distance, length(subtract(sample, closest)))
                }
                maximumDistance = max(maximumDistance, distance)
                if distance > 1.0e-4 { changedSampleCount += 1 }
            }
            changedArea += area * Double(changedSampleCount) / Double(samples.count)
            sourceOffset += 3
        }
        let allowedArea = max(1, sourceSurfaceArea * 0.001)
        return SourceSurfaceModificationAudit(
            sampledPointCount: sampledPointCount,
            changedAreaOutsideFootprintSquareMillimeters: changedArea,
            allowedChangedAreaSquareMillimeters: allowedArea,
            maximumDistanceOutsideFootprintMillimeters: maximumDistance,
            allowedDistanceMillimeters: 0.05,
            passed: changedArea <= allowedArea + 1.0e-6 && maximumDistance <= 0.05 + 1.0e-6
        )
    }

    private static func approvedFootprint(
        for region: MasterModificationRegion,
        axialTolerance: Double
    ) -> ApprovedFootprint? {
        guard region.boundary.count >= 3 else { return nil }
        let center = Vec3(x: region.center.x, y: region.center.y, z: region.center.z)
        let relative = region.boundary.map {
            subtract(Vec3(x: $0.x, y: $0.y, z: $0.z), center)
        }
        var normal: Vec3?
        for index in relative.indices where normal == nil {
            let next = relative.index(after: index) % relative.count
            let candidate = cross(relative[index], relative[next])
            if length(candidate) > 1.0e-8 { normal = normalized(candidate) }
        }
        guard let normal else { return nil }
        let basis = orthonormalBasis(for: normal)
        let polygon = relative.map { (dot($0, basis.u), dot($0, basis.v)) }
        return ApprovedFootprint(
            center: center,
            normal: normal,
            u: basis.u,
            v: basis.v,
            polygon: polygon,
            axialTolerance: axialTolerance
        )
    }

    private static func footprintContains(
        _ point: Vec3,
        footprint: ApprovedFootprint,
        edgeTolerance: Double
    ) -> Bool {
        let relative = subtract(point, footprint.center)
        guard abs(dot(relative, footprint.normal)) <= footprint.axialTolerance else { return false }
        let projected = (dot(relative, footprint.u), dot(relative, footprint.v))
        if pointInPolygon(projected, polygon: footprint.polygon) { return true }
        for index in footprint.polygon.indices {
            let next = (index + 1) % footprint.polygon.count
            if distanceToSegment2D(projected, footprint.polygon[index], footprint.polygon[next]) <= edgeTolerance {
                return true
            }
        }
        return false
    }

    private static func pointInPolygon(
        _ point: (Double, Double),
        polygon: [(Double, Double)]
    ) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            if (a.1 > point.1) != (b.1 > point.1) {
                let crossingX = (b.0 - a.0) * (point.1 - a.1) / (b.1 - a.1) + a.0
                if point.0 < crossingX { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private static func distanceToSegment2D(
        _ point: (Double, Double),
        _ a: (Double, Double),
        _ b: (Double, Double)
    ) -> Double {
        let dx = b.0 - a.0
        let dy = b.1 - a.1
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1.0e-16 else { return hypot(point.0 - a.0, point.1 - a.1) }
        let projection = min(1, max(0, ((point.0 - a.0) * dx + (point.1 - a.1) * dy) / lengthSquared))
        return hypot(point.0 - (a.0 + projection * dx), point.1 - (a.1 + projection * dy))
    }

    private static func polygonArea(_ polygon: [(Double, Double)]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var twiceArea = 0.0
        for index in polygon.indices {
            let next = (index + 1) % polygon.count
            twiceArea += polygon[index].0 * polygon[next].1 - polygon[next].0 * polygon[index].1
        }
        return abs(twiceArea) / 2
    }

    private static func projectedFootprintContains(
        _ point: Vec3,
        footprint: ApprovedFootprint,
        edgeTolerance: Double
    ) -> Bool {
        let relative = subtract(point, footprint.center)
        let projected = (dot(relative, footprint.u), dot(relative, footprint.v))
        if pointInPolygon(projected, polygon: footprint.polygon) { return true }
        for index in footprint.polygon.indices {
            let next = (index + 1) % footprint.polygon.count
            if distanceToSegment2D(projected, footprint.polygon[index], footprint.polygon[next]) <= edgeTolerance {
                return true
            }
        }
        return false
    }

    private static func nearestSurfaceDistance(
        from point: Vec3,
        to geometry: MeshGeometryData
    ) -> Double {
        var distance = Double.infinity
        var offset = 0
        while offset + 2 < geometry.triangleIndices.count {
            let a = geometry.vertices[Int(geometry.triangleIndices[offset])]
            let b = geometry.vertices[Int(geometry.triangleIndices[offset + 1])]
            let c = geometry.vertices[Int(geometry.triangleIndices[offset + 2])]
            let closest = closestPoint(onTriangle: point, a: a, b: b, c: c)
            distance = min(distance, length(subtract(point, closest)))
            offset += 3
        }
        return distance
    }

    private static func circleProfile(radius: Double, segments: Int) -> [(Double, Double)] {
        (0..<segments).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(segments)
            return (cos(angle) * radius, sin(angle) * radius)
        }
    }

    private static func roundedDProfile(
        width: Double,
        thickness: Double,
        cornerRadius: Double,
        segments: Int
    ) -> [(Double, Double)] {
        let halfWidth = width / 2
        let halfThickness = thickness / 2
        let corner = min(cornerRadius, halfThickness * 0.45)
        let rightCenter = halfWidth - halfThickness
        var polygon: [(Double, Double)] = []
        polygon.append((-halfWidth + corner, -halfThickness))
        polygon.append((rightCenter, -halfThickness))
        for index in 1...32 {
            let angle = -Double.pi / 2 + Double(index) * Double.pi / 32
            polygon.append((rightCenter + cos(angle) * halfThickness, sin(angle) * halfThickness))
        }
        polygon.append((-halfWidth + corner, halfThickness))
        for index in 1...8 {
            let angle = Double.pi / 2 + Double(index) * Double.pi / 16
            polygon.append((
                -halfWidth + corner + cos(angle) * corner,
                halfThickness - corner + sin(angle) * corner
            ))
        }
        polygon.append((-halfWidth, -halfThickness + corner))
        for index in 1...8 {
            let angle = Double.pi + Double(index) * Double.pi / 16
            polygon.append((
                -halfWidth + corner + cos(angle) * corner,
                -halfThickness + corner + sin(angle) * corner
            ))
        }

        return (0..<segments).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(segments)
            let direction = (x: cos(angle), y: sin(angle))
            var radius = Double.infinity
            for edgeIndex in polygon.indices {
                let a = polygon[edgeIndex]
                let b = polygon[(edgeIndex + 1) % polygon.count]
                let edge = (x: b.0 - a.0, y: b.1 - a.1)
                let denominator = direction.x * edge.y - direction.y * edge.x
                if abs(denominator) < 1.0e-12 { continue }
                let t = (a.0 * edge.y - a.1 * edge.x) / denominator
                let s = (a.0 * direction.y - a.1 * direction.x) / denominator
                if t >= 0, s >= -1.0e-9, s <= 1 + 1.0e-9 { radius = min(radius, t) }
            }
            return (direction.x * radius, direction.y * radius)
        }
    }

    private static func loft(
        sections: [(station: Double, profile: [(Double, Double)])],
        point: Vec3,
        axis: Vec3,
        basis: (u: Vec3, v: Vec3)
    ) -> MeshGeometryData {
        let count = sections[0].profile.count
        precondition(sections.allSatisfy { $0.profile.count == count })
        var vertices: [Vec3] = []
        vertices.reserveCapacity(sections.count * count)
        for section in sections {
            for (x, y) in section.profile {
                vertices.append(add(
                    point,
                    add(add(scaled(basis.u, x), scaled(basis.v, y)), scaled(axis, section.station))
                ))
            }
        }
        var indices: [Int32] = []
        for index in 1..<(count - 1) { indices += [0, Int32(index + 1), Int32(index)] }
        let topStart = (sections.count - 1) * count
        for index in 1..<(count - 1) {
            indices += [Int32(topStart), Int32(topStart + index), Int32(topStart + index + 1)]
        }
        for sectionIndex in 0..<(sections.count - 1) {
            let lowerStart = sectionIndex * count
            let upperStart = (sectionIndex + 1) * count
            for index in 0..<count {
                let next = (index + 1) % count
                let lower = Int32(lowerStart + index)
                let lowerNext = Int32(lowerStart + next)
                let upper = Int32(upperStart + index)
                let upperNext = Int32(upperStart + next)
                indices += [lower, lowerNext, upperNext, lower, upperNext, upper]
            }
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }

    private static func cylinder(
        center: Vec3,
        axis: Vec3,
        radius: Double,
        length: Double,
        segments: Int
    ) -> MeshGeometryData {
        let basis = orthonormalBasis(for: axis)
        let profile = circleProfile(radius: radius, segments: segments)
        return loft(
            sections: [(-length / 2, profile), (length / 2, profile)],
            point: center,
            axis: axis,
            basis: basis
        )
    }

    private static func finalGeometry(
        for geometry: MeshGeometryData,
        handle: ManifoldHandle
    ) -> FinalGeometry {
        let finite = geometry.vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        let validIndices = geometry.triangleIndices.count % 3 == 0
            && geometry.triangleIndices.allSatisfy { geometry.vertices.indices.contains(Int($0)) }
        let closure = MotherMoldValidation.surfaceClosure(geometry)
        let strict = MotherMoldValidation.printablePreflight(geometry)
        // Closure contributes only its boundary-edge verdict here. Residual
        // non-manifold edges are healed-scan self-contact, which is acceptable
        // ONLY under `printablePreflight`'s Manifold-proof rule — requiring
        // `closure.nonManifold == 0` on top of it re-imposed the strict check
        // that rejected every healed organic master with "watertight: false".
        return FinalGeometry(
            hasFiniteCoordinates: finite,
            hasValidIndices: validIndices,
            isWatertight: ManifoldEngine.isWatertight(handle) && closure.boundary == 0 && strict.isWatertight,
            connectedComponentCount: MoldComponentFilter.positiveMaterialComponentCount(geometry),
            signedVolumeCubicMillimeters: ManifoldEngine.volume(handle),
            triangleCount: geometry.triangleIndices.count / 3
        )
    }

    /// Read the prepared solid back as a printable mesh. Organic tangent
    /// contacts can make Manifold emit microscopic zero-area triangles that
    /// fail the printable gate even though the solid itself is valid; recover
    /// with the same proof-based ladder `MoldMasterMountBuilder` uses —
    /// escalating sub-print-resolution simplify passes plus a seal pass — and
    /// accept a candidate only when it passes the real printable gate, stays
    /// one positive component, and preserves the handle's volume. The raw
    /// readback is returned unchanged when it already passes, or when no
    /// candidate genuinely clears the gate (the caller's validation then
    /// reports the honest failure).
    private static func printableReadback(
        of handle: ManifoldHandle
    ) throws -> MeshGeometryData {
        let raw = try ManifoldEngine.toMesh(handle)
        if MotherMoldValidation.printablePreflight(raw).isWatertight {
            return raw
        }
        let handleVolume = abs(ManifoldEngine.volume(handle))
        for tolerance in [1.0e-6, 1.0e-5, 1.0e-4] {
            guard let simplified = try? ManifoldEngine.simplify(handle, tolerance: tolerance),
                  let simplifiedMesh = try? ManifoldEngine.toMesh(simplified) else {
                continue
            }
            let simplifiedVolume = abs(ManifoldEngine.volume(simplified))
            withExtendedLifetime(simplified) {}
            guard abs(simplifiedVolume - handleVolume) <= max(0.01, handleVolume * 1.0e-4) else {
                continue
            }
            let candidates = [simplifiedMesh, MoldMeshSealer.seal(simplifiedMesh)]
            if let accepted = candidates.first(where: {
                MotherMoldValidation.printablePreflight($0).isWatertight
                    && MoldComponentFilter.positiveMaterialComponentCount($0) == 1
            }) {
                return accepted
            }
        }
        let sealed = MoldMeshSealer.seal(raw)
        if MotherMoldValidation.printablePreflight(sealed).isWatertight,
           MoldComponentFilter.positiveMaterialComponentCount(sealed) == 1 {
            return sealed
        }
        // Last rung: the mold-part validator's own normalization, which
        // separates positional self-contact and moves sliver vertices in
        // sub-micron steps. On a healed organic scan it clears the one
        // zero-area triangle the simplify and seal rungs can leave behind.
        // The same proof applies: printable, one component, same volume.
        let validation = MotherMoldValidation.validate(parts: [MotherMoldPart(
            name: "prepared master",
            geometry: raw
        )])
        if validation.allPartsWatertight,
           let normalized = validation.parts.first?.geometry,
           MotherMoldValidation.printablePreflight(normalized).isWatertight,
           MoldComponentFilter.positiveMaterialComponentCount(normalized) == 1,
           let normalizedHandle = try? ManifoldEngine.make(from: normalized) {
            let normalizedVolume = abs(ManifoldEngine.volume(normalizedHandle))
            withExtendedLifetime(normalizedHandle) {}
            if abs(normalizedVolume - handleVolume) <= max(0.01, handleVolume * 1.0e-4) {
                return normalized
            }
        }
        return raw
    }

    /// Resolve overlapping closed source shells without changing their physical
    /// union. This keeps exact cavities, merges intersecting scan components,
    /// and leaves genuinely disjoint positives disjoint for the later gate.
    private static func normalizedSourceSolid(_ geometry: MeshGeometryData) throws -> ManifoldHandle {
        let source = try ManifoldEngine.make(from: geometry)
        let components = try ManifoldEngine.decompose(source)
        let positive = components.filter { ManifoldEngine.volume($0) > 1.0e-8 }
        let negativeBoundaryCount = components.count - positive.count
        guard positive.count > 1, negativeBoundaryCount == 0 else {
            return source
        }
        return try ManifoldEngine.union(positive)
    }

    private static func connectedComponentCount(_ geometry: MeshGeometryData) -> Int {
        let triangleCount = geometry.triangleIndices.count / 3
        guard triangleCount > 0 else { return 0 }
        var parent = Array(0..<triangleCount)
        func find(_ value: Int) -> Int {
            var value = value
            while parent[value] != value {
                parent[value] = parent[parent[value]]
                value = parent[value]
            }
            return value
        }
        func unite(_ lhs: Int, _ rhs: Int) {
            let a = find(lhs), b = find(rhs)
            if a != b { parent[max(a, b)] = min(a, b) }
        }
        var owner: [Int32: Int] = [:]
        for triangle in 0..<triangleCount {
            for vertex in geometry.triangleIndices[(triangle * 3)..<(triangle * 3 + 3)] {
                if let other = owner[vertex] { unite(triangle, other) } else { owner[vertex] = triangle }
            }
        }
        return Set((0..<triangleCount).map(find)).count
    }

    /// Canonical surface description groups edge-connected coplanar triangles,
    /// so order and planar retessellation do not invalidate approval.
    private static func canonicalGeometry(_ geometry: MeshGeometryData) -> String {
        guard let surface = try? buildSurfaceData(geometry) else { return "invalid" }
        let normalThreshold = 1 - 1.0e-10
        var visited: Set<Int> = []
        var records: [String] = []
        for seed in surface.triangles.indices where !visited.contains(seed) {
            var component: Set<Int> = [seed]
            var queue = [seed]
            var cursor = 0
            let seedTriangle = surface.triangles[seed]
            while cursor < queue.count {
                let current = queue[cursor]
                cursor += 1
                for neighbor in surface.adjacency[current] where !component.contains(neighbor) {
                    let triangle = surface.triangles[neighbor]
                    guard dot(triangle.normal, seedTriangle.normal) >= normalThreshold else { continue }
                    let planeDistance = triangle.vertices.map {
                        abs(dot(subtract($0, seedTriangle.centroid), seedTriangle.normal))
                    }.max() ?? .infinity
                    guard planeDistance <= 1.0e-6 else { continue }
                    component.insert(neighbor)
                    queue.append(neighbor)
                }
            }
            visited.formUnion(component)
            let ordered = component.sorted { surface.triangles[$0].canonicalKey < surface.triangles[$1].canonicalKey }
            let area = ordered.reduce(0) { $0 + surface.triangles[$1].area }
            let center = scaled(ordered.reduce(Vec3(x: 0, y: 0, z: 0)) {
                add($0, scaled(surface.triangles[$1].centroid, surface.triangles[$1].area))
            }, 1 / area)
            let normal = normalized(ordered.reduce(Vec3(x: 0, y: 0, z: 0)) {
                add($0, scaled(surface.triangles[$1].normal, surface.triangles[$1].area))
            }) ?? seedTriangle.normal
            var edgeCounts: [EdgeKey: Int] = [:]
            for index in ordered {
                for edge in surface.triangles[index].edges { edgeCounts[edge, default: 0] += 1 }
            }
            let boundary = edgeCounts.filter { $0.value == 1 }.map(\.key).sorted().map(\.description).joined(separator: ";")
            records.append(
                "a=\(canonicalNumber(area))|c=\(canonicalPoint(center))|n=\(canonicalPoint(normal))|b=\(boundary)"
            )
        }
        return records.sorted().joined(separator: "||")
    }

    private static func canonicalApprovalInput(
        sourceHash: String,
        preparedHash: String,
        settings: MotherMoldSettings,
        selection: MountSelection,
        fixture: FixtureDimensions,
        regions: [MasterModificationRegion],
        additionGeometryHashes: [String: String]
    ) -> String {
        let preparation = settings.masterPreparation
        let requestedPoint = preparation.manualPoint.map {
            canonicalPoint(Vec3(x: $0.x, y: $0.y, z: $0.z))
        } ?? "nil"
        let requestedAxis = preparation.manualAxis.map {
            canonicalPoint(Vec3(x: $0.x, y: $0.y, z: $0.z))
        } ?? "nil"
        let fillAxis = preparation.linerFillUpAxis.map {
            canonicalPoint(Vec3(x: $0.x, y: $0.y, z: $0.z))
        } ?? "nil"
        let settingsPart: [String] = [
            String(settings.toolingContractVersion),
            String(settings.seed),
            preparation.sourceMode.rawValue,
            preparation.retentionMode.rawValue,
            preparation.placementMode.rawValue,
            canonicalNumber(preparation.postWidth),
            canonicalNumber(preparation.postThickness),
            canonicalNumber(preparation.postFreeLength),
            canonicalNumber(preparation.crossPinDiameter),
            canonicalNumber(preparation.fitClearance),
            canonicalNumber(preparation.sealLandWidth),
            canonicalNumber(settings.productionFlow.gateDiameter),
            canonicalNumber(settings.siliconeGap),
            canonicalNumber(settings.wallThickness),
            requestedPoint,
            requestedAxis,
            fillAxis,
            canonicalPoint(Vec3(x: selection.point.x, y: selection.point.y, z: selection.point.z)),
            canonicalPoint(Vec3(x: selection.outwardAxis.x, y: selection.outwardAxis.y, z: selection.outwardAxis.z)),
            canonicalNumber(selection.sourcePatchAreaSquareMillimeters),
            canonicalNumber(selection.equivalentPatchDiameterMillimeters),
            canonicalNumber(selection.rmsPlanarityMillimeters),
            canonicalNumber(selection.exteriorRouteClearanceMillimeters),
            canonicalNumber(selection.exteriorCollisionVolumeCubicMillimeters),
            canonicalNumber(selection.candidateScore),
            selection.deterministicTieBreak,
            selection.placementMode.rawValue,
            canonicalNumber(fixture.gateRootDiameterMillimeters),
            canonicalNumber(fixture.approvedRootFootprintDiameterMillimeters),
            canonicalNumber(fixture.rootFilletRadiusMillimeters),
            canonicalNumber(fixture.postWidthMillimeters),
            canonicalNumber(fixture.postThicknessMillimeters),
            canonicalNumber(fixture.postCornerRadiusMillimeters),
            canonicalNumber(fixture.postFreeLengthMillimeters),
            canonicalNumber(fixture.totalPostExtentMillimeters),
            canonicalNumber(fixture.minimumPinLigamentMillimeters),
            String(fixture.postWasAutoGrown),
            canonicalNumber(fixture.rootOverlapDepthMillimeters),
            canonicalNumber(fixture.rootOverlapCubicMillimeters),
            canonicalNumber(fixture.collarInnerWidthMillimeters),
            canonicalNumber(fixture.collarInnerThicknessMillimeters),
            canonicalNumber(fixture.collarLengthMillimeters),
            canonicalNumber(fixture.crossPinDiameterMillimeters),
            canonicalPoint(Vec3(x: fixture.crossPinCenter.x, y: fixture.crossPinCenter.y, z: fixture.crossPinCenter.z)),
            canonicalPoint(Vec3(x: fixture.crossPinAxis.x, y: fixture.crossPinAxis.y, z: fixture.crossPinAxis.z)),
            canonicalNumber(fixture.axialStations.rootInnerMillimeters),
            canonicalNumber(fixture.axialStations.sourceSurfaceMillimeters),
            canonicalNumber(fixture.axialStations.rootFilletPeakMillimeters),
            canonicalNumber(fixture.axialStations.siliconeOuterMillimeters),
            canonicalNumber(fixture.axialStations.shellOuterMillimeters),
            canonicalNumber(fixture.axialStations.dryPostStartMillimeters),
            canonicalNumber(fixture.axialStations.collarFaceMillimeters),
            canonicalNumber(fixture.axialStations.pinCenterMillimeters),
            canonicalNumber(fixture.axialStations.freeEndMillimeters),
        ]
        let regionPart = regions.sorted { $0.id < $1.id }.map { region in
            "\(region.id)|\(region.kind.rawValue)|\(canonicalPoint(Vec3(x: region.center.x, y: region.center.y, z: region.center.z)))|\(canonicalNumber(region.surfaceArea))|\(region.boundary.map { canonicalPoint(Vec3(x: $0.x, y: $0.y, z: $0.z)) }.joined(separator: ","))|\(region.purpose)"
        }.joined(separator: "||")
        let additionPart = additionGeometryHashes.keys.sorted().map {
            "\($0)=\(additionGeometryHashes[$0]!)"
        }.joined(separator: "|")
        return "source=\(sourceHash)|prepared=\(preparedHash)|settings=\(settingsPart.joined(separator: "|"))|regions=\(regionPart)|additions=\(additionPart)"
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalPoint(_ point: Vec3) -> String {
        "\(canonicalNumber(point.x)),\(canonicalNumber(point.y)),\(canonicalNumber(point.z))"
    }

    private static func canonicalNumber(_ value: Double) -> String {
        String(Int64((value * 1_000_000).rounded()))
    }

    private static func quantized(_ value: Double, step: Double = 1.0e-6) -> Double {
        (value / step).rounded() * step
    }

    private static func quantized(_ point: Vec3, step: Double) -> Vec3 {
        Vec3(
            x: quantized(point.x, step: step),
            y: quantized(point.y, step: step),
            z: quantized(point.z, step: step)
        )
    }

    private static func codable(_ point: Vec3) -> Vec3Codable {
        Vec3Codable(x: point.x, y: point.y, z: point.z)
    }

    private static func closestPoint(onTriangle point: Vec3, a: Vec3, b: Vec3, c: Vec3) -> Vec3 {
        let ab = subtract(b, a), ac = subtract(c, a), ap = subtract(point, a)
        let d1 = dot(ab, ap), d2 = dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = subtract(point, b)
        let d3 = dot(ab, bp), d4 = dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return add(a, scaled(ab, d1 / (d1 - d3))) }
        let cp = subtract(point, c)
        let d5 = dot(ab, cp), d6 = dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return add(a, scaled(ac, d2 / (d2 - d6))) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            return add(b, scaled(subtract(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6))))
        }
        let denominator = 1 / (va + vb + vc)
        return add(a, add(scaled(ab, vb * denominator), scaled(ac, vc * denominator)))
    }

    private static func orthonormalBasis(for axis: Vec3) -> (u: Vec3, v: Vec3) {
        let unitAxis = normalized(axis) ?? Vec3(x: 0, y: 0, z: 1)
        let reference = abs(unitAxis.z) < 0.9 ? Vec3(x: 0, y: 0, z: 1) : Vec3(x: 1, y: 0, z: 0)
        let u = normalized(cross(reference, unitAxis)) ?? Vec3(x: 1, y: 0, z: 0)
        return (u, cross(unitAxis, u))
    }

    private static func add(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    private static func subtract(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func scaled(_ vector: Vec3, _ scalar: Double) -> Vec3 {
        Vec3(x: vector.x * scalar, y: vector.y * scalar, z: vector.z * scalar)
    }

    private static func dot(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func cross(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(
            x: lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.z * rhs.x - lhs.x * rhs.z,
            z: lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private static func length(_ vector: Vec3) -> Double { sqrt(dot(vector, vector)) }

    private static func normalized(_ vector: Vec3) -> Vec3? {
        let magnitude = length(vector)
        guard magnitude.isFinite, magnitude > 1.0e-9 else { return nil }
        return scaled(vector, 1 / magnitude)
    }
}
