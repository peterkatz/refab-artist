import Foundation

/// Calibrated limits for one printed hold-down geometry/profile. These are
/// evidence inputs, not estimates derived from the presence of a printed post.
struct HoldDownCapacityEnvelopeInput: Codable, Equatable, Sendable {
    var profileID: String
    var ratedAxialForceNewtons: Double
    var ratedShearForceNewtons: Double
    var ratedBendingMomentNewtonMillimeters: Double
    var ratedTorsionMomentNewtonMillimeters: Double

    init(
        profileID: String,
        ratedAxialForceNewtons: Double,
        ratedShearForceNewtons: Double,
        ratedBendingMomentNewtonMillimeters: Double,
        ratedTorsionMomentNewtonMillimeters: Double
    ) {
        self.profileID = profileID
        self.ratedAxialForceNewtons = ratedAxialForceNewtons
        self.ratedShearForceNewtons = ratedShearForceNewtons
        self.ratedBendingMomentNewtonMillimeters = ratedBendingMomentNewtonMillimeters
        self.ratedTorsionMomentNewtonMillimeters = ratedTorsionMomentNewtonMillimeters
    }
}

enum HoldDownCapacityEvidence: String, Codable, Equatable, Sendable {
    case none
    case calibrated
    case externalFixture
}

/// The external-fixture state is deliberately distinct from a calibrated
/// printed hold-down. An external capacity can be recorded and compared, but
/// its result remains external responsibility rather than a print qualification.
struct HoldDownCapacityInput: Codable, Equatable, Sendable {
    var evidence: HoldDownCapacityEvidence
    var envelope: HoldDownCapacityEnvelopeInput?

    init(
        evidence: HoldDownCapacityEvidence = .none,
        envelope: HoldDownCapacityEnvelopeInput? = nil
    ) {
        self.evidence = evidence
        self.envelope = envelope
    }
}

struct MoldHoldDownQualificationInput {
    /// The active source mesh. This evaluator never modifies it.
    var sourceMaster: MeshGeometryData
    var linerFillUpAxis: Vec3Codable
    var holdDownPoint: Vec3Codable
    var mountAxis: Vec3Codable
    var siliconeDensityGramsPerCC: Double
    var masterMassGrams: Double?
    var masterCenterOfGravity: Vec3Codable?
    var capacity: HoldDownCapacityInput
    /// The PRD fluid/gravity uncertainty factor. The production default is 3x.
    var fluidLoadSafetyFactor: Double
    /// A deterministic six-direction minimum handling load at the farthest
    /// source point from the fixture datum.
    var handlingForceNewtons: Double

    init(
        sourceMaster: MeshGeometryData,
        linerFillUpAxis: Vec3Codable,
        holdDownPoint: Vec3Codable,
        mountAxis: Vec3Codable,
        siliconeDensityGramsPerCC: Double,
        masterMassGrams: Double? = nil,
        masterCenterOfGravity: Vec3Codable? = nil,
        capacity: HoldDownCapacityInput = HoldDownCapacityInput(),
        fluidLoadSafetyFactor: Double = 3,
        handlingForceNewtons: Double = 10
    ) {
        self.sourceMaster = sourceMaster
        self.linerFillUpAxis = linerFillUpAxis
        self.holdDownPoint = holdDownPoint
        self.mountAxis = mountAxis
        self.siliconeDensityGramsPerCC = siliconeDensityGramsPerCC
        self.masterMassGrams = masterMassGrams
        self.masterCenterOfGravity = masterCenterOfGravity
        self.capacity = capacity
        self.fluidLoadSafetyFactor = fluidLoadSafetyFactor
        self.handlingForceNewtons = handlingForceNewtons
    }
}

struct MoldHoldDownFillState: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var fillFraction: Double
    var fillPlaneOffsetMillimeters: Double
    var displacedSiliconeVolumeCubicMillimeters: Double
    var centerOfBuoyancy: Vec3Codable?
    /// Fluid buoyancy plus known master weight, before the design factor and
    /// handling load are added.
    var measuredWrench: ForceMomentWrench
    /// A conservative moment bound when mass is known but its balance datum is
    /// not. It is measured from actual source vertices, never a bounding box.
    var unmeasuredMasterMomentBoundNewtonMillimeters: Double?

    init(
        id: String,
        fillFraction: Double,
        fillPlaneOffsetMillimeters: Double,
        displacedSiliconeVolumeCubicMillimeters: Double,
        centerOfBuoyancy: Vec3Codable?,
        measuredWrench: ForceMomentWrench,
        unmeasuredMasterMomentBoundNewtonMillimeters: Double? = nil
    ) {
        self.id = id
        self.fillFraction = fillFraction
        self.fillPlaneOffsetMillimeters = fillPlaneOffsetMillimeters
        self.displacedSiliconeVolumeCubicMillimeters = displacedSiliconeVolumeCubicMillimeters
        self.centerOfBuoyancy = centerOfBuoyancy
        self.measuredWrench = measuredWrench
        self.unmeasuredMasterMomentBoundNewtonMillimeters = unmeasuredMasterMomentBoundNewtonMillimeters
    }
}

struct MoldHoldDownQualificationResult: Codable, Equatable, Sendable {
    var sourceVolumeCubicMillimeters: Double
    var sourceCentroid: Vec3Codable
    var fillStates: [MoldHoldDownFillState]
    var wrenchEnvelope: HoldDownWrenchEnvelope

    init(
        sourceVolumeCubicMillimeters: Double,
        sourceCentroid: Vec3Codable,
        fillStates: [MoldHoldDownFillState],
        wrenchEnvelope: HoldDownWrenchEnvelope
    ) {
        self.sourceVolumeCubicMillimeters = sourceVolumeCubicMillimeters
        self.sourceCentroid = sourceCentroid
        self.fillStates = fillStates
        self.wrenchEnvelope = wrenchEnvelope
    }
}

enum MoldHoldDownQualificationError: LocalizedError, Equatable, Sendable {
    case emptySource
    case invalidTriangleIndex
    case nonFiniteSource
    case sourceNotWatertight(String)
    case degenerateSource
    case nonFiniteInput(String)
    case zeroAxis(String)
    case invalidSiliconeDensity
    case invalidSafetyFactor
    case invalidHandlingForce
    case invalidCapacity(String)
    case clippingFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySource:
            return "Select a closed source master before measuring hold-down loads."
        case .invalidTriangleIndex:
            return "The source master has a triangle that references a missing vertex. Repair or reimport the master."
        case .nonFiniteSource:
            return "The source master contains NaN or infinite coordinates. Repair or reimport the master."
        case .sourceNotWatertight(let detail):
            return "The source master is not a watertight solid (\(detail)). Repair the master before hold-down qualification."
        case .degenerateSource:
            return "The source master has zero or invalid enclosed volume and cannot displace silicone."
        case .nonFiniteInput(let field):
            return "\(field) must contain finite coordinates or values."
        case .zeroAxis(let field):
            return "\(field) must be a non-zero direction. Choose a liner-fill or mount axis."
        case .invalidSiliconeDensity:
            return "Silicone density must be a finite value greater than zero g/cc."
        case .invalidSafetyFactor:
            return "The fluid load safety factor must be finite and at least 1."
        case .invalidHandlingForce:
            return "The handling force must be finite and non-negative."
        case .invalidCapacity(let detail):
            return "Hold-down capacity is invalid: \(detail)"
        case .clippingFailed(let detail):
            return "Could not measure submerged master volume with exact solid clipping: \(detail)"
        }
    }
}

/// Computes fill-state buoyancy and fixture wrench evidence from exact clipped
/// Manifold solids. There is intentionally no bounding-box volume fallback.
enum MoldHoldDownQualification {
    private static let gravityMetersPerSecondSquared = 9.80665
    private static let volumeEpsilon = 1.0e-8

    static func evaluate(_ input: MoldHoldDownQualificationInput) throws -> MoldHoldDownQualificationResult {
        let validated = try validate(input)
        let source: ManifoldHandle
        do {
            source = try ManifoldEngine.make(from: input.sourceMaster)
        } catch let error as ManifoldEngineError {
            throw MoldHoldDownQualificationError.sourceNotWatertight(error.userMessage)
        } catch {
            throw MoldHoldDownQualificationError.sourceNotWatertight(error.localizedDescription)
        }

        guard ManifoldEngine.isWatertight(source), !ManifoldEngine.isEmpty(source) else {
            throw MoldHoldDownQualificationError.sourceNotWatertight("Manifold did not produce a closed solid")
        }

        let sourceMesh: MeshGeometryData
        do {
            sourceMesh = try ManifoldEngine.toMesh(source)
        } catch {
            throw MoldHoldDownQualificationError.clippingFailed(error.localizedDescription)
        }
        let sourceIntegral = try integrate(sourceMesh)
        guard sourceIntegral.volume > volumeEpsilon, let sourceCentroid = sourceIntegral.centroid else {
            throw MoldHoldDownQualificationError.degenerateSource
        }

        let fillOffsets = fillPlaneOffsets(vertices: sourceMesh.vertices, up: validated.up)
        let farthestPoint = farthestSourcePoint(sourceMesh.vertices, from: validated.holdDownPoint)
        let handlingDirections = orthogonalHandlingDirections(around: validated.mountAxis)
        let hasMeasuredMassProperties = input.masterMassGrams != nil && input.masterCenterOfGravity != nil
        let knownWeight = input.masterMassGrams.map { -$0 * gravityMetersPerSecondSquared / 1_000.0 }
        let knownCenterOfGravity = input.masterCenterOfGravity.map(vec3)
        let unknownMomentBound = unknownMasterMomentBound(
            weightNewtons: knownWeight,
            hasCenterOfGravity: knownCenterOfGravity != nil,
            farthestPoint: farthestPoint,
            holdDownPoint: validated.holdDownPoint
        )

        var fillStates: [MoldHoldDownFillState] = []
        var loadCases: [WrenchLoadCase] = []
        fillStates.reserveCapacity(fillOffsets.count)
        loadCases.reserveCapacity(fillOffsets.count * handlingDirections.count)

        for (index, offset) in fillOffsets.enumerated() {
            let fraction = fillFraction(offset: offset, minimum: fillOffsets[0], maximum: fillOffsets[fillOffsets.count - 1])
            let submerged: VolumeIntegral
            if index == 0 {
                submerged = .zero
            } else if index == fillOffsets.count - 1 {
                submerged = sourceIntegral
            } else {
                do {
                    // trimByPlane keeps dot(p, n) >= d. Negating the fill-up
                    // vector retains the silicone-reachable side below the plane.
                    let clipped = try ManifoldEngine.trimByPlane(
                        source,
                        normal: scale(validated.up, -1),
                        offset: -offset
                    )
                    submerged = ManifoldEngine.isEmpty(clipped) ? .zero : try integrate(ManifoldEngine.toMesh(clipped))
                } catch let error as MoldHoldDownQualificationError {
                    throw error
                } catch {
                    throw MoldHoldDownQualificationError.clippingFailed(error.localizedDescription)
                }
            }

            let buoyancyMagnitude = input.siliconeDensityGramsPerCC
                * submerged.volume
                * gravityMetersPerSecondSquared
                / 1_000_000.0
            let buoyancyForce = scale(validated.up, buoyancyMagnitude)
            var force = buoyancyForce
            var moment = Vec3(x: 0, y: 0, z: 0)
            if let center = submerged.centroid {
                moment = add(moment, cross(subtract(center, validated.holdDownPoint), buoyancyForce))
            }
            if let knownWeight {
                let weightForce = scale(validated.up, knownWeight)
                force = add(force, weightForce)
                if let knownCenterOfGravity {
                    moment = add(moment, cross(subtract(knownCenterOfGravity, validated.holdDownPoint), weightForce))
                }
            }

            let stateID = String(format: "liner-fill-%04d", index)
            let measuredWrench = ForceMomentWrench(
                forceNewtons: codable(force),
                momentNewtonMillimeters: codable(moment)
            )
            fillStates.append(MoldHoldDownFillState(
                id: stateID,
                fillFraction: fraction,
                fillPlaneOffsetMillimeters: offset,
                displacedSiliconeVolumeCubicMillimeters: submerged.volume,
                centerOfBuoyancy: submerged.centroid.map(codable),
                measuredWrench: measuredWrench,
                unmeasuredMasterMomentBoundNewtonMillimeters: unknownMomentBound
            ))

            let designFluidForce = scale(force, input.fluidLoadSafetyFactor)
            let designFluidMoment = scale(moment, input.fluidLoadSafetyFactor)
            for (directionIndex, direction) in handlingDirections.enumerated() {
                let handlingForce = scale(direction, input.handlingForceNewtons)
                let handlingMoment = cross(
                    subtract(farthestPoint, validated.holdDownPoint),
                    handlingForce
                )
                let designWrench = ForceMomentWrench(
                    forceNewtons: codable(add(designFluidForce, handlingForce)),
                    momentNewtonMillimeters: codable(add(designFluidMoment, handlingMoment))
                )
                let utilization = input.capacity.envelope.map {
                    combinedUtilization(
                        wrench: designWrench,
                        mountAxis: validated.mountAxis,
                        capacity: $0
                    )
                }
                loadCases.append(WrenchLoadCase(
                    id: "\(stateID)-handling-\(directionIndex)",
                    phase: .linerFill,
                    fillFraction: fraction,
                    wrench: designWrench,
                    utilization: utilization
                ))
            }
        }

        let maximumUtilization = loadCases.compactMap(\.utilization).max()
        let worstCase = loadCases.enumerated().max { lhs, rhs in
            let left = lhs.element.utilization ?? -.infinity
            let right = rhs.element.utilization ?? -.infinity
            return left == right ? lhs.offset > rhs.offset : left < right
        }?.element
        let qualification = qualificationState(
            capacity: input.capacity,
            hasMeasuredMassProperties: hasMeasuredMassProperties,
            maximumUtilization: maximumUtilization
        )
        let notes = qualificationNotes(
            capacity: input.capacity,
            hasMeasuredMassProperties: hasMeasuredMassProperties,
            hasKnownMass: input.masterMassGrams != nil,
            hasKnownCenterOfGravity: input.masterCenterOfGravity != nil,
            maximumUtilization: maximumUtilization
        )

        return MoldHoldDownQualificationResult(
            sourceVolumeCubicMillimeters: sourceIntegral.volume,
            sourceCentroid: codable(sourceCentroid),
            fillStates: fillStates,
            wrenchEnvelope: HoldDownWrenchEnvelope(
                version: 1,
                qualification: qualification,
                loadCases: loadCases,
                worstCaseID: worstCase?.id,
                maximumUtilization: maximumUtilization,
                notes: notes
            )
        )
    }

    private static func validate(_ input: MoldHoldDownQualificationInput) throws -> ValidatedInput {
        guard !input.sourceMaster.vertices.isEmpty, !input.sourceMaster.triangleIndices.isEmpty else {
            throw MoldHoldDownQualificationError.emptySource
        }
        guard input.sourceMaster.triangleIndices.count.isMultiple(of: 3) else {
            throw MoldHoldDownQualificationError.invalidTriangleIndex
        }
        guard input.sourceMaster.vertices.allSatisfy(isFinite) else {
            throw MoldHoldDownQualificationError.nonFiniteSource
        }
        for index in input.sourceMaster.triangleIndices {
            guard index >= 0, Int(index) < input.sourceMaster.vertices.count else {
                throw MoldHoldDownQualificationError.invalidTriangleIndex
            }
        }
        guard input.siliconeDensityGramsPerCC.isFinite, input.siliconeDensityGramsPerCC > 0 else {
            throw MoldHoldDownQualificationError.invalidSiliconeDensity
        }
        guard input.fluidLoadSafetyFactor.isFinite, input.fluidLoadSafetyFactor >= 1 else {
            throw MoldHoldDownQualificationError.invalidSafetyFactor
        }
        guard input.handlingForceNewtons.isFinite, input.handlingForceNewtons >= 0 else {
            throw MoldHoldDownQualificationError.invalidHandlingForce
        }
        if let mass = input.masterMassGrams {
            guard mass.isFinite, mass >= 0 else {
                throw MoldHoldDownQualificationError.nonFiniteInput("Master mass")
            }
        }
        if let center = input.masterCenterOfGravity {
            guard isFinite(center) else {
                throw MoldHoldDownQualificationError.nonFiniteInput("Master center of gravity")
            }
        }
        let up = try normalized(input.linerFillUpAxis, field: "Liner-fill up axis")
        let mountAxis = try normalized(input.mountAxis, field: "Mount axis")
        let holdDownPoint = try finitePoint(input.holdDownPoint, field: "Hold-down point")
        try validateCapacity(input.capacity)
        return ValidatedInput(up: up, mountAxis: mountAxis, holdDownPoint: holdDownPoint)
    }

    private static func validateCapacity(_ input: HoldDownCapacityInput) throws {
        switch input.evidence {
        case .none:
            guard input.envelope == nil else {
                throw MoldHoldDownQualificationError.invalidCapacity("a capacity envelope needs calibrated or external-fixture evidence")
            }
        case .calibrated:
            guard input.envelope != nil else {
                throw MoldHoldDownQualificationError.invalidCapacity("calibrated evidence requires a measured envelope")
            }
        case .externalFixture:
            break
        }
        guard let envelope = input.envelope else { return }
        guard !envelope.profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MoldHoldDownQualificationError.invalidCapacity("profile ID is empty")
        }
        let values = [
            envelope.ratedAxialForceNewtons,
            envelope.ratedShearForceNewtons,
            envelope.ratedBendingMomentNewtonMillimeters,
            envelope.ratedTorsionMomentNewtonMillimeters,
        ]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw MoldHoldDownQualificationError.invalidCapacity("all force and moment ratings must be finite and greater than zero")
        }
    }

    private static func fillPlaneOffsets(vertices: [Vec3], up: Vec3) -> [Double] {
        let eventOffsets = Array(Set(vertices.map { dot($0, up) })).sorted()
        guard let minimum = eventOffsets.first, let maximum = eventOffsets.last, maximum > minimum else {
            return eventOffsets
        }
        var offsets = Set(eventOffsets)
        for (lower, upper) in zip(eventOffsets, eventOffsets.dropFirst()) {
            var sample = lower + 1.0
            while sample < upper - 1.0e-9 {
                offsets.insert(sample)
                sample += 1.0
            }
        }
        offsets.insert(minimum)
        offsets.insert(maximum)
        return offsets.sorted()
    }

    private static func fillFraction(offset: Double, minimum: Double, maximum: Double) -> Double {
        guard maximum > minimum else { return 1 }
        return min(1, max(0, (offset - minimum) / (maximum - minimum)))
    }

    private static func qualificationState(
        capacity: HoldDownCapacityInput,
        hasMeasuredMassProperties: Bool,
        maximumUtilization: Double?
    ) -> WrenchQualificationState {
        if capacity.evidence == .externalFixture { return .external }
        guard hasMeasuredMassProperties else { return .notMeasured }
        guard capacity.evidence == .calibrated, let maximumUtilization else {
            return .geometryOnly
        }
        return maximumUtilization <= 1 ? .qualified : .blocked
    }

    private static func qualificationNotes(
        capacity: HoldDownCapacityInput,
        hasMeasuredMassProperties: Bool,
        hasKnownMass: Bool,
        hasKnownCenterOfGravity: Bool,
        maximumUtilization: Double?
    ) -> [String] {
        var notes = ["Submerged volumes are exact Manifold clips integrated by signed tetrahedra; no bounding-box volume was used."]
        if !hasKnownMass {
            notes.append("Master mass is unknown. Zero weight was used only for worst-uplift geometry, not as a positive qualification claim.")
        }
        if !hasKnownCenterOfGravity {
            notes.append("Master center of gravity is unknown. Its moment is bounded from source geometry and combined qualification remains unmeasured.")
        }
        if !hasMeasuredMassProperties {
            notes.append("Measure and record both master mass and center of gravity before load qualification.")
        }
        switch capacity.evidence {
        case .none:
            notes.append("No calibrated hold-down capacity envelope was supplied; this is geometry-only evidence.")
        case .calibrated:
            if let maximumUtilization, maximumUtilization > 1 {
                notes.append("The worst combined calibrated-envelope utilization exceeds 1.0; use larger hardware, another orientation, or an external fixture.")
            }
        case .externalFixture:
            notes.append("External fixture responsibility is recorded separately; it is not a qualification of the printed hold-down.")
            if capacity.envelope == nil {
                notes.append("Enter the external fixture restraint directions and tested capacity before relying on it.")
            }
        }
        return notes
    }

    private static func combinedUtilization(
        wrench: ForceMomentWrench,
        mountAxis: Vec3,
        capacity: HoldDownCapacityEnvelopeInput
    ) -> Double {
        let force = vec3(wrench.forceNewtons)
        let moment = vec3(wrench.momentNewtonMillimeters)
        let axial = dot(force, mountAxis)
        let shear = length(subtract(force, scale(mountAxis, axial)))
        let torsion = dot(moment, mountAxis)
        let bending = length(subtract(moment, scale(mountAxis, torsion)))
        return abs(axial) / capacity.ratedAxialForceNewtons
            + shear / capacity.ratedShearForceNewtons
            + bending / capacity.ratedBendingMomentNewtonMillimeters
            + abs(torsion) / capacity.ratedTorsionMomentNewtonMillimeters
    }

    private static func orthogonalHandlingDirections(around axis: Vec3) -> [Vec3] {
        let seed = abs(axis.x) < 0.9 ? Vec3(x: 1, y: 0, z: 0) : Vec3(x: 0, y: 1, z: 0)
        let first = normalize(cross(axis, seed))
        let second = normalize(cross(axis, first))
        return [axis, scale(axis, -1), first, scale(first, -1), second, scale(second, -1)]
    }

    private static func farthestSourcePoint(_ vertices: [Vec3], from point: Vec3) -> Vec3 {
        vertices.max { length(subtract($0, point)) < length(subtract($1, point)) } ?? point
    }

    private static func unknownMasterMomentBound(
        weightNewtons: Double?,
        hasCenterOfGravity: Bool,
        farthestPoint: Vec3,
        holdDownPoint: Vec3
    ) -> Double? {
        guard let weightNewtons, !hasCenterOfGravity else { return nil }
        return abs(weightNewtons) * length(subtract(farthestPoint, holdDownPoint))
    }

    private static func integrate(_ geometry: MeshGeometryData) throws -> VolumeIntegral {
        var signedVolume = 0.0
        var centroidNumerator = Vec3(x: 0, y: 0, z: 0)
        var index = 0
        while index + 2 < geometry.triangleIndices.count {
            let a = geometry.vertices[Int(geometry.triangleIndices[index])]
            let b = geometry.vertices[Int(geometry.triangleIndices[index + 1])]
            let c = geometry.vertices[Int(geometry.triangleIndices[index + 2])]
            let volume = dot(a, cross(b, c)) / 6.0
            signedVolume += volume
            centroidNumerator = add(centroidNumerator, scale(add(add(a, b), c), volume / 4.0))
            index += 3
        }
        guard signedVolume.isFinite, isFinite(centroidNumerator) else {
            throw MoldHoldDownQualificationError.degenerateSource
        }
        let orientation = signedVolume < 0 ? -1.0 : 1.0
        let volume = signedVolume * orientation
        guard volume > volumeEpsilon else { return .zero }
        let centroid = scale(centroidNumerator, orientation / volume)
        guard isFinite(centroid) else {
            throw MoldHoldDownQualificationError.degenerateSource
        }
        return VolumeIntegral(volume: volume, centroid: centroid)
    }

    private static func normalized(_ value: Vec3Codable, field: String) throws -> Vec3 {
        guard isFinite(value) else { throw MoldHoldDownQualificationError.nonFiniteInput(field) }
        let vector = vec3(value)
        guard length(vector) > 1.0e-12 else { throw MoldHoldDownQualificationError.zeroAxis(field) }
        return normalize(vector)
    }

    private static func finitePoint(_ value: Vec3Codable, field: String) throws -> Vec3 {
        guard isFinite(value) else { throw MoldHoldDownQualificationError.nonFiniteInput(field) }
        return vec3(value)
    }

    private static func isFinite(_ value: Vec3) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func isFinite(_ value: Vec3Codable) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func vec3(_ value: Vec3Codable) -> Vec3 {
        Vec3(x: value.x, y: value.y, z: value.z)
    }

    private static func codable(_ value: Vec3) -> Vec3Codable {
        Vec3Codable(x: value.x, y: value.y, z: value.z)
    }

    private static func add(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    private static func subtract(_ lhs: Vec3, _ rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    private static func scale(_ value: Vec3, _ scalar: Double) -> Vec3 {
        Vec3(x: value.x * scalar, y: value.y * scalar, z: value.z * scalar)
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

    private static func length(_ value: Vec3) -> Double {
        dot(value, value).squareRoot()
    }

    private static func normalize(_ value: Vec3) -> Vec3 {
        scale(value, 1 / length(value))
    }

    private struct ValidatedInput {
        var up: Vec3
        var mountAxis: Vec3
        var holdDownPoint: Vec3
    }

    private struct VolumeIntegral {
        static let zero = VolumeIntegral(volume: 0, centroid: nil)

        var volume: Double
        var centroid: Vec3?

        init(volume: Double, centroid: Vec3?) {
            self.volume = volume
            self.centroid = centroid
        }
    }
}
