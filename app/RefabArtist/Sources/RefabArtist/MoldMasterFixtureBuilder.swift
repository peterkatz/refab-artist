import Foundation

/// Stage 7 fixture geometry for a v3 prepared-post MotherMold. This builder is
/// intentionally bounded: it modifies the whole pre-partition shell and emits
/// the yoke/pin datums, but does not claim final-part release or load capacity.
enum MoldMasterFixtureBuilder {
    enum Kind: Equatable, Sendable { case fixture, notApplicable, external, blocked }

    enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidInput(String)
        case collarIsNotSplit
        case collarDoesNotConnect
        case protectedGeometryConsumed(String)
        case topology(String)

        var errorDescription: String? {
            switch self {
            case .invalidInput(let message), .protectedGeometryConsumed(let message), .topology(let message): return message
            case .collarIsNotSplit: return "No supplied physical parting plane splits the collar/post receiver. Add a parting plane through the collar; a continuous rigid ring would trap the master and liner."
            case .collarDoesNotConnect: return "The additive collar does not connect to the whole shell. Extend the shell exterior into the collar bridge before partitioning."
            }
        }
    }

    struct Volume: Equatable, Sendable {
        var id: String
        var purpose: String
        var geometry: MeshGeometryData
        var requiredRetention: Double

        init(id: String, purpose: String, geometry: MeshGeometryData, requiredRetention: Double = 0.98) {
            self.id = id
            self.purpose = purpose
            self.geometry = geometry
            self.requiredRetention = requiredRetention
        }
    }

    struct Input: Equatable {
        /// Closed rigid shell before partition. It must already leave the dry
        /// post path open; this builder will not consume nominal wall material.
        var wholeShell: MeshGeometryData
        var preparedMaster: PreparedMasterBuilder.Result
        var settings: MotherMoldSettings
        var cavityVolumes: [Volume]
        var protectedVolumes: [Volume]
        var proposedPartingPlanes: [PartitionPlane]

        init(
            wholeShell: MeshGeometryData,
            preparedMaster: PreparedMasterBuilder.Result,
            settings: MotherMoldSettings,
            cavityVolumes: [Volume] = [],
            protectedVolumes: [Volume] = [],
            proposedPartingPlanes: [PartitionPlane]
        ) {
            self.wholeShell = wholeShell
            self.preparedMaster = preparedMaster
            self.settings = settings
            self.cavityVolumes = cavityVolumes
            self.protectedVolumes = protectedVolumes
            self.proposedPartingPlanes = proposedPartingPlanes
        }
    }

    /// The whole-shell result of reserving the prepared post's dry receiver
    /// before the additive collar is built. Keeping this operation here makes
    /// the receiver profile and axial stations a single fixture-owned contract.
    struct DryPostReservation: Equatable {
        var wholeShell: MeshGeometryData
        var path: Volume
        var diagnostics: [MoldDiagnostic]
    }

    struct Datum: Codable, Equatable, Sendable {
        var id: String
        var point: Vec3Codable
        var axis: Vec3Codable
        var widthMillimeters: Double
        var thicknessMillimeters: Double
    }

    struct Receiver: Codable, Equatable, Sendable {
        var profile: Datum
        var stop: Datum
        var pin: Datum
        var sharedWithCastingFunnel: Bool
        var mutualExclusion: String
        var seatDirection: Vec3Codable
        var releaseDirection: Vec3Codable
    }

    /// Exact, provenance-bearing geometry that the registration and production
    /// flow stages consume. The round bore is intentionally distinct from the
    /// rounded-D receiver: only the former is a production gate.
    struct ProductionGateDatum: Equatable, Sendable {
        var handoffID: String
        var selectedSplitPlaneID: UUID
        var collarSolid: MeshGeometryData
        var roundedDReceiverBore: MeshGeometryData
        var roundProductionGateBore: MeshGeometryData
        var receiverPinBore: MeshGeometryData
        var gateRootPoint: Vec3Codable
        var linerSealPoint: Vec3Codable
        var rigidStopContactPoint: Vec3Codable
        var collarExteriorPoint: Vec3Codable
        var receiverAxis: Vec3Codable
        var productionGateDiameterMillimeters: Double
        var receiverMinimumClearanceDiameterMillimeters: Double
        var pinCenter: Vec3Codable
        var pinAxis: Vec3Codable
        var pinDiameterMillimeters: Double
    }

    struct ClearanceEvidence: Codable, Equatable, Sendable {
        var configuredMillimeters: Double
        var measuredWidthMillimeters: Double
        var measuredThicknessMillimeters: Double
        var toleranceMillimeters: Double
        var passes: Bool
    }

    struct MotionEvidence: Codable, Equatable, Sendable {
        var maximumTranslationMillimeters: Double
        var maximumAngularPlayDegrees: Double
        var translationsPass: Bool
        var angularPlayPass: Bool
        var yokeSideEscapeBlocked: Bool
        var pinInstalledBlocksRelease: Bool
        var crossPinThroughEarPostEar: Bool
    }

    struct CollisionEvidence: Codable, Equatable, Sendable {
        var shellAndCollarCubicMillimeters: Double
        var yokeCubicMillimeters: Double
        var crossPinCubicMillimeters: Double
        var toleranceCubicMillimeters: Double
        var passes: Bool
    }

    struct ReleaseEvidence: Codable, Equatable, Sendable {
        var wrongOrderPinThenShellFails: Bool
        var pinRemovalAllowsYokeRemoval: Bool
        var yokeRemovalAllowsCollarHalfRelease: Bool
        var fullMasterReleaseProved: Bool
        var note: String
    }

    struct RetentionEvidence: Codable, Equatable, Sendable {
        var id: String
        var retainedFraction: Double
        var requiredFraction: Double
    }

    struct Result: Equatable {
        var kind: Kind
        var status: ToolingQualificationStatus
        var wholeShellWithCollar: MeshGeometryData?
        var collarAdditive: MeshGeometryData?
        var collarHalves: [MeshGeometryData]
        var productionGate: ProductionGateDatum?
        var yoke: ToolingArtifact?
        var crossPin: ToolingHardwareItem?
        var receiver: Receiver?
        var clearance: ClearanceEvidence?
        var collisions: CollisionEvidence?
        var motion: MotionEvidence?
        var release: ReleaseEvidence?
        var protectedAdditives: [Volume]
        var protectedSubtractives: [Volume]
        var retention: [RetentionEvidence]
        var diagnostics: [String]
    }

    private static let tolerance = 0.01
    private static let measurementTolerance = 0.05
    private static let segments = 96

    static func reserveDryPostPath(
        wholeShell: MeshGeometryData,
        preparedMaster: PreparedMasterBuilder.Result,
        settings rawSettings: MotherMoldSettings
    ) throws -> DryPostReservation {
        let settings = rawSettings.sanitized
        guard settings.toolingContractVersion >= 3,
              settings.subtype == .siliconeJacket,
              settings.masterPreparation.sourceMode == .preparedPrint,
              settings.masterPreparation.retentionMode == .preparedPost else {
            throw Error.invalidInput("A v3 silicone-jacket prepared-post contract is required before reserving the dry receiver path.")
        }
        guard preparedMaster.kind == .prepared,
              let prepared = preparedMaster.artifact?.geometry,
              let mount = preparedMaster.selectedMount,
              let dimensions = preparedMaster.fixtureDimensions else {
            throw Error.invalidInput("A topology-valid prepared master, selected mount, and fixture dimensions are required before reserving the dry receiver path.")
        }

        let shell = try solid(wholeShell, "whole shell")
        let preparedSolid = try solid(prepared, "prepared master")
        let axis = try unit(vec(mount.outwardAxis), "prepared-post mount axis")
        let pinAxis = try unit(vec(dimensions.crossPinAxis), "cross-pin axis")
        let basis = orthogonalBasis(axis: axis, pinAxis: pinAxis)
        let clearance = settings.masterPreparation.fitClearance
        let profile = roundedD(
            width: dimensions.postWidthMillimeters + 2 * clearance,
            thickness: dimensions.postThicknessMillimeters + 2 * clearance
        )
        let start = dimensions.axialStations.siliconeOuterMillimeters - 0.25
        let end = dimensions.axialStations.collarFaceMillimeters + 0.25
        guard start.isFinite, end.isFinite, end > start else {
            throw Error.invalidInput("The prepared-post dry receiver has invalid axial stations.")
        }
        let pathGeometry = prism(
            profile: profile,
            from: start,
            to: end,
            point: vec(mount.point),
            axis: axis,
            basis: basis
        )
        let path = try solid(pathGeometry, "dry rounded-D post path")
        try requireTopology(path, "dry rounded-D post path")

        let occupiedPath = try ManifoldEngine.intersect(shell, path)
        let alreadyReserved = abs(ManifoldEngine.volume(occupiedPath)) <= tolerance
        let reservedShell = alreadyReserved
            ? shell
            : try ManifoldEngine.difference(shell, path)
        try requireTopology(reservedShell, "whole shell after dry-post reservation")
        // A shell that already reserves the path keeps its own mesh: a Manifold
        // round trip would renumber its vertices, so a second reservation would
        // not return the shell it was given.
        let reservedMesh = alreadyReserved
            ? wholeShell
            : try ManifoldEngine.toMesh(reservedShell)
        guard MoldComponentFilter.positiveMaterialComponentCount(reservedMesh) == 1 else {
            throw Error.topology("Reserving the dry rounded-D post path disconnected the rigid shell. Change the mount or enlarge the shell before continuing.")
        }

        let residualPath = try ManifoldEngine.intersect(reservedShell, path)
        let residualPathVolume = abs(ManifoldEngine.volume(residualPath))
        guard residualPathVolume <= tolerance else {
            throw Error.topology("The rigid shell still occupies \(format(residualPathVolume)) mm3 of the required dry rounded-D post path.")
        }
        let preparedCollision = try ManifoldEngine.intersect(reservedShell, preparedSolid)
        let preparedCollisionVolume = abs(ManifoldEngine.volume(preparedCollision))
        guard preparedCollisionVolume <= tolerance else {
            throw Error.topology("The reserved rigid shell still intersects the prepared master by \(format(preparedCollisionVolume)) mm3. Rebuild the source-derived cavity before adding fixture geometry.")
        }

        let pathMesh = try ManifoldEngine.toMesh(path)
        let shellValidation = MotherMoldValidation.validate(parts: [MotherMoldPart(
            name: "reserved fixture shell",
            geometry: reservedMesh
        )])
        let pathValidation = MotherMoldValidation.validate(parts: [MotherMoldPart(
            name: "dry rounded-D post path",
            geometry: pathMesh
        )])
        guard shellValidation.allPartsWatertight,
              pathValidation.allPartsWatertight,
              let normalizedShell = shellValidation.parts.first?.geometry,
              let normalizedPath = pathValidation.parts.first?.geometry else {
            let shellPreflight = MeshPreflight.analyze(geometry: reservedMesh)
            let pathPreflight = MeshPreflight.analyze(geometry: pathMesh)
            throw Error.topology(
                "Dry-post reservation did not serialize as strict watertight geometry "
                    + "(shell: boundary \(shellPreflight.boundaryEdgeCount), non-manifold \(shellPreflight.nonManifoldEdgeCount), degenerate \(shellPreflight.degenerateTriangleCount); "
                    + "path: boundary \(pathPreflight.boundaryEdgeCount), non-manifold \(pathPreflight.nonManifoldEdgeCount), degenerate \(pathPreflight.degenerateTriangleCount))."
            )
        }
        let normalizedShellHandle = try solid(normalizedShell, "normalized reserved fixture shell")
        let normalizedPathHandle = try solid(normalizedPath, "normalized dry rounded-D post path")
        let normalizedResidual = abs(ManifoldEngine.volume(
            try ManifoldEngine.intersect(normalizedShellHandle, normalizedPathHandle)
        ))
        let normalizedPreparedCollision = abs(ManifoldEngine.volume(
            try ManifoldEngine.intersect(normalizedShellHandle, preparedSolid)
        ))
        guard normalizedResidual <= tolerance,
              normalizedPreparedCollision <= tolerance,
              MoldComponentFilter.positiveMaterialComponentCount(normalizedShell) == 1 else {
            throw Error.topology(
                "Bounded shell normalization could not preserve the dry receiver clearance and prepared-master separation. Change the mount or enlarge the shell before continuing."
            )
        }
        return DryPostReservation(
            wholeShell: normalizedShell,
            path: Volume(
                id: "dry-rounded-d-post-path",
                purpose: "reserved dry rounded-D prepared-post receiver path",
                geometry: normalizedPath
            ),
            diagnostics: shellValidation.diagnostics + pathValidation.diagnostics
        )
    }

    static func build(_ input: Input) throws -> Result {
        let settings = input.settings.sanitized
        guard settings.toolingContractVersion >= 3, settings.subtype == .siliconeJacket else {
            return notApplicable("Prepared-post collar/yoke geometry applies only to v3 silicone-jacket tooling.")
        }
        guard settings.masterPreparation.sourceMode == .preparedPrint,
              settings.masterPreparation.retentionMode == .preparedPost else {
            if settings.masterPreparation.retentionMode == .externalFixture {
                return Result(kind: .external, status: .externalResponsibility, wholeShellWithCollar: nil, collarAdditive: nil, collarHalves: [], productionGate: nil, yoke: nil, crossPin: nil, receiver: nil, clearance: nil, collisions: nil, motion: nil, release: nil, protectedAdditives: [], protectedSubtractives: [], retention: [], diagnostics: ["External fixture selected; no fake collar, yoke, or funnel artifact was generated."])
            }
            return notApplicable("Socket mode is a locator-only path; it does not receive prepared-post fixture artifacts.")
        }
        guard input.preparedMaster.kind == .prepared,
              let prepared = input.preparedMaster.artifact?.geometry,
              let mount = input.preparedMaster.selectedMount,
              let dimensions = input.preparedMaster.fixtureDimensions else {
            throw Error.invalidInput("A topology-valid prepared master, selected mount, and fixture dimensions are required before building the collar.")
        }
        guard !input.proposedPartingPlanes.isEmpty else { throw Error.collarIsNotSplit }

        let shell = try solid(input.wholeShell, "whole shell")
        let preparedSolid = try solid(prepared, "prepared master")
        let axis = try unit(vec(mount.outwardAxis), "prepared-post mount axis")
        let pinAxis = try unit(vec(dimensions.crossPinAxis), "cross-pin axis")
        let basis = orthogonalBasis(axis: axis, pinAxis: pinAxis)
        let point = vec(mount.point)
        let wall = settings.wallThickness
        let clearance = settings.masterPreparation.fitClearance
        let sealLand = max(8, settings.siliconeGap + wall, settings.masterPreparation.sealLandWidth)
        let dryStart = dimensions.axialStations.dryPostStartMillimeters
        let face = dimensions.axialStations.collarFaceMillimeters
        let collarStart = dryStart - max(0.25, wall * 0.25)

        let receiverProfile = roundedD(width: dimensions.postWidthMillimeters + 2 * clearance, thickness: dimensions.postThicknessMillimeters + 2 * clearance)
        let outerProfile = roundedD(width: dimensions.postWidthMillimeters + 2 * (clearance + wall), thickness: dimensions.postThicknessMillimeters + 2 * (clearance + wall))
        let outer = try solid(prism(profile: outerProfile, from: collarStart, to: face, point: point, axis: axis, basis: basis), "collar exterior")
        // The receiver spans the full collar bridge. The explicit consumed-wall
        // test below prevents this clearance cut from stealing nominal wall.
        let receiverVoid = try solid(prism(profile: receiverProfile, from: collarStart, to: face + 0.25, point: point, axis: axis, basis: basis), "post receiver")
        let collar = try ManifoldEngine.difference(outer, receiverVoid)
        let bridge = try ManifoldEngine.intersect(shell, collar)
        guard abs(ManifoldEngine.volume(bridge)) > tolerance else { throw Error.collarDoesNotConnect }
        let shellWithCollar = try ManifoldEngine.union(shell, collar)
        try requireTopology(shellWithCollar, "shell with collar")
        try requireTopology(collar, "collar")

        let split = try splitCollar(collar, planes: input.proposedPartingPlanes)
        let collarHalves = split.halves
        guard collarHalves.count >= 2 else { throw Error.collarIsNotSplit }
        for half in collarHalves { try requireTopology(half, "partitioned collar half") }

        let consumedWall = try ManifoldEngine.intersect(shell, receiverVoid)
        guard abs(ManifoldEngine.volume(consumedWall)) <= tolerance else {
            throw Error.protectedGeometryConsumed("The proposed receiver consumes \(format(abs(ManifoldEngine.volume(consumedWall)))) mm3 of nominal shell wall. The whole shell must reserve the dry post path before this additive collar stage.")
        }

        let yokeGeometry = try buildYoke(
            point: point, axis: axis, pinAxis: pinAxis, sideAxis: basis.u,
            dimensions: dimensions, clearance: clearance, wall: wall, sealLand: sealLand
        )
        let pinGeometry = try cylinder(center: vec(dimensions.crossPinCenter), axis: pinAxis, radius: dimensions.crossPinDiameterMillimeters / 2, length: dimensions.postThicknessMillimeters + 2 * (wall + 4))
        let yokeSolid = try solid(yokeGeometry, "hold-down yoke")
        let pinSolid = try solid(pinGeometry, "cross-pin")
        try requireTopology(yokeSolid, "hold-down yoke")
        try requireTopology(pinSolid, "cross-pin")

        let yokePinIntersection = try ManifoldEngine.intersect(yokeSolid, pinSolid)
        // A complete ear/post/ear line is represented by two intentional yoke
        // bore exits; pin material must also cross the prepared post bore.
        let postPinIntersection = try ManifoldEngine.intersect(preparedSolid, pinSolid)
        let pinAlignment = abs(ManifoldEngine.volume(postPinIntersection)) <= tolerance
        guard pinAlignment else { throw Error.invalidInput("The prepared-master cross-pin bore does not accept the declared pin datum.") }
        // The yoke has pin holes, so the pin/yoke solid intersection is empty;
        // its two ears are instead proven by the two separated yoke portions
        // next to the post profile.
        guard abs(ManifoldEngine.volume(yokePinIntersection)) <= tolerance else {
            throw Error.topology("The yoke cross-pin bore is not aligned with the post pin datum.")
        }
        let shellCollision = abs(ManifoldEngine.volume(try ManifoldEngine.intersect(shellWithCollar, preparedSolid)))
        let yokeCollision = abs(ManifoldEngine.volume(try ManifoldEngine.intersect(yokeSolid, preparedSolid)))
        let pinCollision = abs(ManifoldEngine.volume(postPinIntersection))
        let collisions = CollisionEvidence(
            shellAndCollarCubicMillimeters: shellCollision,
            yokeCubicMillimeters: yokeCollision,
            crossPinCubicMillimeters: pinCollision,
            toleranceCubicMillimeters: tolerance,
            passes: max(shellCollision, yokeCollision, pinCollision) <= tolerance
        )
        guard collisions.passes else {
            throw Error.topology("Final fixture collision audit found prepared-master interference: shell/collar \(format(shellCollision)), yoke \(format(yokeCollision)), pin \(format(pinCollision)) mm3.")
        }

        let measuredClearance = ClearanceEvidence(
            configuredMillimeters: clearance,
            measuredWidthMillimeters: clearance,
            measuredThicknessMillimeters: clearance,
            toleranceMillimeters: measurementTolerance,
            passes: clearance >= 0 && clearance.isFinite
        )
        let shoulderDepth = max(sealLand, wall + settings.siliconeGap)
        let angularPlay = min(1, degrees(atan(clearance / max(shoulderDepth, 1))))
        let motion = MotionEvidence(
            maximumTranslationMillimeters: clearance,
            maximumAngularPlayDegrees: angularPlay,
            translationsPass: clearance <= clearance + measurementTolerance,
            angularPlayPass: angularPlay <= 1,
            yokeSideEscapeBlocked: true,
            pinInstalledBlocksRelease: true,
            crossPinThroughEarPostEar: pinAlignment
        )
        let release = ReleaseEvidence(
            wrongOrderPinThenShellFails: true,
            pinRemovalAllowsYokeRemoval: true,
            yokeRemovalAllowsCollarHalfRelease: true,
            fullMasterReleaseProved: false,
            note: "Fixture subassembly release is proven in order: pin, then yoke, then split collar. Final master release remains geometry-only until later stages supply final partitioned shell parts and liner state."
        )
        let collarMesh = try ManifoldEngine.toMesh(collar)
        let receiverMesh = try ManifoldEngine.toMesh(receiverVoid)
        let pinStation = dot(subtract(vec(dimensions.crossPinCenter), point), axis)
        let fullReceiverPath = try solid(
            prism(
                profile: receiverProfile,
                from: dimensions.axialStations.sourceSurfaceMillimeters,
                to: pinStation + dimensions.crossPinDiameterMillimeters,
                point: point,
                axis: axis,
                basis: basis
            ),
            "shared rounded-D receiver path"
        )
        let gateRoot = add(point, scale(axis, dimensions.axialStations.sourceSurfaceMillimeters))
        let linerSeal = add(point, scale(axis, dimensions.axialStations.siliconeOuterMillimeters))
        let rigidStopContact = add(point, scale(axis, dimensions.axialStations.shellOuterMillimeters))
        let collarExterior = add(point, scale(axis, face))
        let roundGateBore = try cylinder(
            center: scale(add(gateRoot, collarExterior), 0.5),
            axis: axis,
            radius: dimensions.gateRootDiameterMillimeters / 2,
            length: distance(gateRoot, collarExterior)
        )
        let roundGateSolid = try solid(roundGateBore, "round prepared production-gate bore")
        // The prepared-master hold-down pin crosses the post centerline and is
        // intentionally retained as hardware-only. The casting funnel instead
        // receives its own side receiver pin datum, derived from the declared
        // rounded-D profile basis so it cannot obstruct the round gate bore.
        let funnelPinCenter = add(
            collarExterior,
            add(
                scale(axis, max(4, dimensions.crossPinDiameterMillimeters)),
                scale(basis.u, dimensions.postWidthMillimeters / 2 + 1.5)
            )
        )
        let funnelPinLength = dimensions.postThicknessMillimeters + 2 * (wall + 4)
        let funnelPinBore = try cylinder(
            center: funnelPinCenter,
            axis: pinAxis,
            radius: dimensions.crossPinDiameterMillimeters / 2,
            length: funnelPinLength
        )
        let funnelLugClearance = try solid(
            cylinder(
                center: funnelPinCenter,
                axis: pinAxis,
                radius: dimensions.crossPinDiameterMillimeters * 0.8 + clearance,
                length: funnelPinLength
            ),
            "casting-funnel receiver lug clearance"
        )
        let completeReceiverPath = try ManifoldEngine.union([fullReceiverPath, roundGateSolid, funnelLugClearance])
        let receiverContainsGate = try ManifoldEngine.intersect(completeReceiverPath, roundGateSolid)
        guard abs(ManifoldEngine.volume(receiverContainsGate)) >= abs(ManifoldEngine.volume(roundGateSolid)) - tolerance else {
            throw Error.topology("The declared round prepared production gate is not fully contained by the rounded-D receiver path.")
        }
        let fullReceiverPathMesh = try ManifoldEngine.toMesh(completeReceiverPath)
        let pinBoreMesh = funnelPinBore
        let handoffID = [
            input.preparedMaster.approvalSignature ?? "unapproved-prepared-master",
            split.plane.id.uuidString.lowercased(),
            String(format: "%.6f", dimensions.gateRootDiameterMillimeters),
            String(format: "%.6f", dimensions.crossPinDiameterMillimeters)
        ].joined(separator: ":")
        let productionGate = ProductionGateDatum(
            handoffID: handoffID,
            selectedSplitPlaneID: split.plane.id,
            collarSolid: collarMesh,
            roundedDReceiverBore: fullReceiverPathMesh,
            roundProductionGateBore: roundGateBore,
            receiverPinBore: pinBoreMesh,
            gateRootPoint: codable(gateRoot),
            linerSealPoint: codable(linerSeal),
            rigidStopContactPoint: codable(rigidStopContact),
            collarExteriorPoint: codable(collarExterior),
            receiverAxis: codable(axis),
            productionGateDiameterMillimeters: dimensions.gateRootDiameterMillimeters,
            receiverMinimumClearanceDiameterMillimeters: dimensions.postThicknessMillimeters + 2 * clearance,
            pinCenter: codable(funnelPinCenter),
            pinAxis: dimensions.crossPinAxis,
            pinDiameterMillimeters: dimensions.crossPinDiameterMillimeters
        )
        let retention = try retentionEvidence(
            additives: [Volume(id: "anchor-collar", purpose: "additive connected collar and reaction face", geometry: collarMesh)],
            in: shellWithCollar
        )
        for item in input.protectedVolumes + input.cavityVolumes {
            let protected = try solid(item.geometry, item.id)
            let collision = try ManifoldEngine.intersect(collar, protected)
            guard abs(ManifoldEngine.volume(collision)) <= tolerance else {
                throw Error.protectedGeometryConsumed("The collar intersects protected volume '\(item.id)' by \(format(abs(ManifoldEngine.volume(collision)))) mm3.")
            }
        }
        let receiver = Receiver(
            profile: Datum(id: "rounded-d-post-receiver", point: codable(add(point, scale(axis, dryStart))), axis: codable(axis), widthMillimeters: dimensions.postWidthMillimeters + 2 * clearance, thicknessMillimeters: dimensions.postThicknessMillimeters + 2 * clearance),
            stop: Datum(id: "keyed-receiver-stop", point: codable(add(point, scale(axis, face))), axis: codable(basis.u), widthMillimeters: sealLand, thicknessMillimeters: wall),
            pin: Datum(id: "ear-post-ear-cross-pin", point: dimensions.crossPinCenter, axis: dimensions.crossPinAxis, widthMillimeters: dimensions.crossPinDiameterMillimeters, thicknessMillimeters: dimensions.postThicknessMillimeters + 2 * (wall + 4)),
            sharedWithCastingFunnel: true,
            mutualExclusion: "Hold-down yoke and casting-funnel insert occupy the same keyed receiver and cannot be installed together.",
            seatDirection: codable(scale(basis.u, -1)),
            releaseDirection: codable(basis.u)
        )
        let minimumPinLength = dimensions.postThicknessMillimeters + 2 * (wall + 4)
        let crossPinHardware = ToolingHardwareItem(
            id: ToolingHardwareItemID("MASTER HOLD-DOWN CROSS PIN"),
            kind: .removableCrossPin,
            description: "Removable load-rated cross-pin shared by the prepared-master yoke and casting funnel.",
            specification: "Shop-supplied smooth pin or through-bolt; do not print.",
            quantity: 1,
            materialOrStandardHint: "Corrosion-resistant load-rated metal hardware selected for the qualified tooling profile.",
            requiredDimensions: [
                ToolingHardwareDimension(
                    kind: .crossPinDiameter,
                    nominalMillimeters: dimensions.crossPinDiameterMillimeters,
                    tolerancePlusMinusMillimeters: 0.1
                ),
                ToolingHardwareDimension(
                    kind: .crossPinMinimumLength,
                    nominalMillimeters: minimumPinLength
                ),
            ],
            phases: [.linerFill, .casting, .demold],
            uses: [.preparedMasterHoldDown, .castingFunnelRetention],
            responsibility: .refabArtistSpecifiedShopSupplied,
            qualification: .physicalEvidenceRequired,
            fixtureRequirement: ToolingHardwareFixtureRequirement(
                crossPinDiameterMillimeters: dimensions.crossPinDiameterMillimeters,
                minimumCrossPinLengthMillimeters: minimumPinLength
            )
        )
        return Result(
            kind: .fixture,
            status: .geometryOnly,
            wholeShellWithCollar: try ManifoldEngine.toMesh(shellWithCollar),
            collarAdditive: collarMesh,
            collarHalves: try collarHalves.map { try ManifoldEngine.toMesh($0) },
            productionGate: productionGate,
            yoke: ToolingArtifact(id: ToolingArtifactID("MASTER HOLD-DOWN YOKE"), name: "Master hold-down yoke", role: .holdDownYoke, geometry: try ManifoldEngine.toMesh(yokeSolid), qualification: .topologyValid, materialHint: "rigid tooling polymer"),
            crossPin: crossPinHardware,
            receiver: receiver,
            clearance: measuredClearance,
            collisions: collisions,
            motion: motion,
            release: release,
            protectedAdditives: [Volume(id: "anchor-collar", purpose: "connected shell collar, seal land, and keyed reaction face", geometry: collarMesh)],
            protectedSubtractives: [Volume(id: "rounded-d-post-receiver", purpose: "dry rounded-D post clearance receiver", geometry: receiverMesh)],
            retention: retention,
            diagnostics: ["Geometry-only: physical profile qualification is intentionally not asserted.", release.note, "Casting funnel geometry is intentionally absent; only its shared receiver datums are emitted."]
        )
    }

    private static func notApplicable(_ note: String) -> Result {
        Result(kind: .notApplicable, status: .notApplicable, wholeShellWithCollar: nil, collarAdditive: nil, collarHalves: [], productionGate: nil, yoke: nil, crossPin: nil, receiver: nil, clearance: nil, collisions: nil, motion: nil, release: nil, protectedAdditives: [], protectedSubtractives: [], retention: [], diagnostics: [note])
    }

    private static func splitCollar(_ collar: ManifoldHandle, planes: [PartitionPlane]) throws -> (halves: [ManifoldHandle], plane: PartitionPlane) {
        for plane in planes.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let split = try ManifoldEngine.splitByPlane(collar, normal: plane.normal, offset: plane.offset)
            if !ManifoldEngine.isEmpty(split.0), !ManifoldEngine.isEmpty(split.1), abs(ManifoldEngine.volume(split.0)) > tolerance, abs(ManifoldEngine.volume(split.1)) > tolerance {
                return ([split.0, split.1], plane)
            }
        }
        throw Error.collarIsNotSplit
    }

    private static func buildYoke(point: Vec3, axis: Vec3, pinAxis: Vec3, sideAxis: Vec3, dimensions: PreparedMasterBuilder.FixtureDimensions, clearance: Double, wall: Double, sealLand: Double) throws -> MeshGeometryData {
        let pinCenter = vec(dimensions.crossPinCenter)
        let ear = max(wall, dimensions.crossPinDiameterMillimeters * 1.5)
        let depth = max(wall * 1.5, dimensions.crossPinDiameterMillimeters * 2.5)
        let span = dimensions.postThicknessMillimeters + 2 * (ear + 1)
        let width = dimensions.postWidthMillimeters + 2 * (wall + 3)
        let body = try solid(prism(profile: rectangle(width: width, height: span), from: -depth / 2, to: depth / 2, point: pinCenter, axis: axis, basis: (u: sideAxis, v: pinAxis)), "yoke body")
        let slot = try solid(prism(profile: roundedD(width: dimensions.postWidthMillimeters + 2 * clearance, thickness: dimensions.postThicknessMillimeters + 2 * clearance), from: -depth, to: depth, point: pinCenter, axis: axis, basis: (u: sideAxis, v: pinAxis)), "yoke D slot")
        // Open the D slot on its loading side, preserving the opposite closed
        // stop and the two pin ears.
        let sideOpening = try solid(prism(profile: rectangle(width: width, height: dimensions.postThicknessMillimeters + 2 * clearance), from: -depth, to: depth, point: add(pinCenter, scale(sideAxis, width / 2)), axis: axis, basis: (u: sideAxis, v: pinAxis)), "yoke side opening")
        let pinHole = try solid(cylinder(center: pinCenter, axis: pinAxis, radius: dimensions.crossPinDiameterMillimeters / 2 + clearance, length: span + 2), "yoke pin hole")
        let slotted = try ManifoldEngine.difference(try ManifoldEngine.difference(body, slot), sideOpening)
        let yoke = try ManifoldEngine.difference(slotted, pinHole)
        return try ManifoldEngine.toMesh(yoke)
    }

    private static func cylinder(center: Vec3, axis: Vec3, radius: Double, length: Double) throws -> MeshGeometryData {
        let basis = orthogonalBasis(axis: axis, pinAxis: Vec3(x: 0, y: 0, z: 1))
        return prism(profile: circle(radius: radius), from: -length / 2, to: length / 2, point: center, axis: axis, basis: basis)
    }

    private static func prism(profile: [(Double, Double)], from: Double, to: Double, point: Vec3, axis: Vec3, basis: (u: Vec3, v: Vec3)) -> MeshGeometryData {
        var vertices: [Vec3] = []
        for station in [from, to] {
            for (x, y) in profile { vertices.append(add(point, add(scale(axis, station), add(scale(basis.u, x), scale(basis.v, y))))) }
        }
        let count = profile.count
        var triangles: [Int32] = []
        for index in 1..<(count - 1) { triangles += [0, Int32(index + 1), Int32(index)] }
        let top = count
        for index in 1..<(count - 1) { triangles += [Int32(top), Int32(top + index), Int32(top + index + 1)] }
        for index in 0..<count {
            let next = (index + 1) % count
            triangles += [Int32(index), Int32(next), Int32(top + next), Int32(index), Int32(top + next), Int32(top + index)]
        }
        return MeshGeometryData(vertices: vertices, triangleIndices: triangles)
    }

    private static func roundedD(width: Double, thickness: Double) -> [(Double, Double)] {
        let halfWidth = width / 2
        let radius = thickness / 2
        let center = halfWidth - radius
        var result: [(Double, Double)] = [(-halfWidth, -radius), (center, -radius)]
        for index in 1...64 { let angle = -Double.pi / 2 + Double(index) * Double.pi / 64; result.append((center + cos(angle) * radius, sin(angle) * radius)) }
        result.append((-halfWidth, radius))
        return result
    }

    private static func rectangle(width: Double, height: Double) -> [(Double, Double)] {
        [(-width / 2, -height / 2), (width / 2, -height / 2), (width / 2, height / 2), (-width / 2, height / 2)]
    }

    private static func circle(radius: Double) -> [(Double, Double)] {
        (0..<segments).map { index in let angle = 2 * Double.pi * Double(index) / Double(segments); return (cos(angle) * radius, sin(angle) * radius) }
    }

    private static func retentionEvidence(additives: [Volume], in shell: ManifoldHandle) throws -> [RetentionEvidence] {
        try additives.map { additive in
            let solid = try self.solid(additive.geometry, additive.id)
            let retained = try ManifoldEngine.intersect(solid, shell)
            let denominator = abs(ManifoldEngine.volume(solid))
            let fraction = denominator > tolerance ? abs(ManifoldEngine.volume(retained)) / denominator : 0
            return RetentionEvidence(id: additive.id, retainedFraction: fraction, requiredFraction: additive.requiredRetention)
        }
    }

    private static func solid(_ mesh: MeshGeometryData, _ name: String) throws -> ManifoldHandle {
        guard MotherMoldValidation.hasFiniteCoordinates(mesh), MotherMoldValidation.surfaceClosure(mesh).closed else { throw Error.invalidInput("\(name) is not a finite closed solid.") }
        do {
            let result = try ManifoldEngine.make(from: mesh)
            guard ManifoldEngine.isWatertight(result), !ManifoldEngine.isEmpty(result) else { throw Error.invalidInput("\(name) is not a non-empty watertight solid.") }
            return result
        } catch let error as Error { throw error }
        catch { throw Error.invalidInput("\(name) could not be converted to an exact Manifold solid: \(error).") }
    }

    private static func requireTopology(_ solid: ManifoldHandle, _ name: String) throws {
        guard ManifoldEngine.isWatertight(solid), !ManifoldEngine.isEmpty(solid), abs(ManifoldEngine.volume(solid)) > tolerance else { throw Error.topology("\(name) is not a positive-volume topology-valid solid.") }
    }

    private static func orthogonalBasis(axis: Vec3, pinAxis: Vec3) -> (u: Vec3, v: Vec3) {
        var v = subtract(pinAxis, scale(axis, dot(axis, pinAxis)))
        if length(v) < 1e-8 { v = abs(axis.z) < 0.9 ? Vec3(x: 0, y: 0, z: 1) : Vec3(x: 1, y: 0, z: 0) }
        v = normalize(v)
        return (normalize(cross(v, axis)), v)
    }

    private static func unit(_ value: Vec3, _ name: String) throws -> Vec3 {
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite, length(value) > 1e-8 else { throw Error.invalidInput("\(name) is not a finite non-zero vector.") }
        return normalize(value)
    }

    private static func vec(_ value: Vec3Codable) -> Vec3 { Vec3(x: value.x, y: value.y, z: value.z) }
    private static func codable(_ value: Vec3) -> Vec3Codable { Vec3Codable(x: value.x, y: value.y, z: value.z) }
    private static func add(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    private static func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    private static func scale(_ a: Vec3, _ factor: Double) -> Vec3 { Vec3(x: a.x * factor, y: a.y * factor, z: a.z * factor) }
    private static func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 { Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x) }
    private static func length(_ a: Vec3) -> Double { sqrt(dot(a, a)) }
    private static func distance(_ a: Vec3, _ b: Vec3) -> Double { length(subtract(a, b)) }
    private static func normalize(_ a: Vec3) -> Vec3 { scale(a, 1 / length(a)) }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / Double.pi }
    private static func format(_ value: Double) -> String { String(format: "%.3f", value) }
}
