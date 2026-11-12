import Foundation
import CryptoKit

/// The sole v3 manufacturing-package writer. It owns contract validation,
/// serialized geometry measurements, manifest construction, archive audit, and
/// atomic publication; callers must not emit a v3 archive by another route.
enum MotherMoldToolingPackageWriter {
    struct Result: Equatable {
        var destination: URL
        var manifest: MotherMoldToolingManifest
        var archiveSHA256: String
    }

    enum Error: LocalizedError, Equatable {
        case wrongDestinationExtension(String)
        case unsupportedContract(Int)
        case packagingNotManufacturingZip
        case blockingDiagnostics([String])
        case unreleasableContract(state: MotherMoldToolingContractState, reasons: [String])
        case missingArtifacts([String])
        case invalidArtifact(String)
        case invalidPath(String)
        case duplicatePath(String)
        case roleConflict(String)
        case invalidGeometry(String)
        case zipLimit(String)
        case archiveAudit(String)
        case publication(String)

        var errorDescription: String? {
            switch self {
            case .wrongDestinationExtension(let value): return "MotherMold tooling packages require a .zip destination, not \(value)."
            case .unsupportedContract(let version): return "MotherMold tooling package v3 requires tooling contract version 3; plan declares \(version)."
            case .packagingNotManufacturingZip: return "MotherMold tooling package v3 requires a manufacturingZip request."
            case .blockingDiagnostics(let messages): return "MotherMold tooling package is blocked: \(messages.joined(separator: " "))"
            case .unreleasableContract(let state, let reasons): return "MotherMold tooling plan is not releasable (\(state.rawValue)): \(reasons.joined(separator: " "))"
            case .missingArtifacts(let names): return "MotherMold tooling package is incomplete: \(names.joined(separator: "; ")). Generate the missing measured tooling geometry before export."
            case .invalidArtifact(let message): return "MotherMold tooling artifact is invalid: \(message)"
            case .invalidPath(let path): return "MotherMold tooling package contains an unsafe archive path: \(path)."
            case .duplicatePath(let path): return "MotherMold tooling package contains duplicate archive member \(path)."
            case .roleConflict(let message): return "MotherMold tooling package has a role conflict: \(message)."
            case .invalidGeometry(let message): return "MotherMold tooling geometry failed serialized validation: \(message)."
            case .zipLimit(let message): return "MotherMold tooling package exceeds ZipWriter limits before write: \(message). ZIP64 is not supported by this writer."
            case .archiveAudit(let message): return "MotherMold tooling archive audit failed: \(message)."
            case .publication(let message): return "MotherMold tooling package could not be published: \(message)."
            }
        }
    }

    static func validateAndWrite(
        plan: MotherMoldPlan,
        modelName: String,
        destination: URL
    ) throws -> Result {
        try validatePlan(plan, destination: destination)
        let geometry = try geometryCandidates(plan: plan)
        try preflightEstimatedZip(geometry: geometry)

        var members = try geometry.map { candidate in
            try measuredGeometryMember(candidate)
        }
        let guideArtifacts = geometry.map { candidate in
            MotherMoldGuideRenderer.GuideArtifact(
                id: candidate.id,
                displayID: candidate.displayID,
                role: candidate.toolingRole,
                geometry: candidate.geometry,
                quantity: candidate.quantity
            )
        }
        let guide = try MotherMoldGuideRenderer.render(plan: plan, modelName: modelName, artifacts: guideArtifacts)
        members += guide.map { Member(path: $0.path, data: $0.data, role: $0.role, toolingRole: nil, content: $0.content, mediaType: $0.mediaType, geometry: nil) }
        members.append(Member(path: "README.txt", data: Data(readme(modelName: modelName, artifactCount: geometry.count, contract: plan.toolingExportContract).utf8), role: .assemblyGuide, toolingRole: nil, content: .text, mediaType: "text/plain; charset=utf-8", geometry: nil))
        members += try referenceMembers(plan: plan)
        try validateMemberLayout(members)
        try preflightZip(members: members)

        let manifest = try makeManifest(plan: plan, members: members)
        let manifestData = try manifest.deterministicJSON(prettyPrinted: true)
        let archiveMembers = ([ZipWriter.Entry(name: "manifest.json", data: manifestData)] + members.sorted { $0.path < $1.path }.map { ZipWriter.Entry(name: $0.path, data: $0.data) })
        try preflightZip(entries: archiveMembers)

        let temporary = temporarySibling(of: destination)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try ZipWriter.write(entries: archiveMembers, to: temporary)
            try auditArchive(at: temporary, manifest: manifest, expected: archiveMembers)
            try publish(temporary: temporary, destination: destination)
        } catch let error as Error {
            throw error
        } catch {
            throw Error.publication(error.localizedDescription)
        }
        let archive = try Data(contentsOf: destination)
        return Result(destination: destination, manifest: manifest, archiveSHA256: sha256(archive))
    }

    private struct GeometryCandidate {
        var path: String
        var id: ToolingArtifactID
        var displayID: String
        var toolingRole: ToolingArtifactRole
        var geometry: MeshGeometryData
        var qualification: ManufacturingQualification
        var materialHint: String?
        var quantity: Int
        var assembledTransform: Matrix4x4Codable
        var recommendedPrintTransform: Matrix4x4Codable?
    }

    private struct Member {
        var path: String
        var data: Data
        var role: PackageMemberRole
        var toolingRole: ToolingArtifactRole?
        var content: PackageMemberContent
        var mediaType: String
        var geometry: (SerializedGeometryMetrics, ToolingManifestGeometryMember)?

        var packageMember: PackageMember {
            PackageMember(path: path, role: role, toolingRole: toolingRole, mediaType: mediaType, content: content, byteCount: UInt64(data.count), sha256: sha256(data), geometryMetrics: geometry?.0, sourceDependencyStatus: content == .sourceBytes ? "provenance-only; external dependencies are not implied" : nil)
        }
    }

    private static func validatePlan(_ plan: MotherMoldPlan, destination: URL) throws {
        let ext = destination.pathExtension.lowercased()
        guard ext == "zip" else { throw Error.wrongDestinationExtension(ext.isEmpty ? "no extension" : ".\(ext)") }
        guard plan.toolingContractVersion == 3, plan.toolingExportContract.toolingContractVersion == 3 else { throw Error.unsupportedContract(plan.toolingContractVersion) }
        guard plan.requestedPackaging == .manufacturingZip else { throw Error.packagingNotManufacturingZip }
        let diagnostics = plan.diagnostics.filter { $0.severity == .error }.map(\.message)
        guard diagnostics.isEmpty else { throw Error.blockingDiagnostics(diagnostics) }
        guard plan.toolingExportContract.schema == MotherMoldToolingContract.schema,
              plan.toolingExportContract.schemaVersion == MotherMoldToolingContract.currentSchemaVersion,
              plan.toolingExportContract.blockingReasons.isEmpty,
              [.geometryOnly, .printerValidated, .productionProfileQualified].contains(plan.toolingExportContract.state) else {
            throw Error.unreleasableContract(state: plan.toolingExportContract.state, reasons: plan.toolingExportContract.blockingReasons)
        }
        if [.printerValidated, .productionProfileQualified].contains(plan.toolingExportContract.state) {
            guard let profile = plan.manufacturingProfile,
                  !profile.printerProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !profile.materialProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  profile.profileSnapshotSHA256.count == 64,
                  profile.profileSnapshotSHA256.allSatisfy({ $0.isHexDigit }) else {
                throw Error.unreleasableContract(
                    state: plan.toolingExportContract.state,
                    reasons: ["Printer-validated status requires complete printer/material profile IDs and a SHA-256 profile snapshot."]
                )
            }
        }
        guard !plan.parts.isEmpty else { throw Error.missingArtifacts(["no print shell parts"]) }
        try validateHardwareSchedule(plan)
    }

    private static func validateHardwareSchedule(_ plan: MotherMoldPlan) throws {
        let hardwareIDs = plan.hardwareItems.map(\.id)
        guard Set(hardwareIDs).count == hardwareIDs.count else {
            throw Error.roleConflict("duplicate tooling hardware ID")
        }
        for item in plan.hardwareItems {
            guard !item.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.specification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.materialOrStandardHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.quantity > 0,
                  !item.phases.isEmpty,
                  Set(item.phases.map(\.rawValue)).count == item.phases.count,
                  !item.uses.isEmpty,
                  Set(item.uses).count == item.uses.count else {
                throw Error.invalidArtifact("hardware schedule item \(item.id.rawValue) is incomplete")
            }
            let kinds = item.requiredDimensions.map(\.kind)
            guard Set(kinds).count == kinds.count,
                  item.requiredDimensions.allSatisfy({ dimension in
                      dimension.nominalMillimeters.isFinite && dimension.nominalMillimeters > 0
                          && (dimension.tolerancePlusMinusMillimeters.map { $0.isFinite && $0 >= 0 } ?? true)
                  }) else {
                throw Error.invalidArtifact("hardware schedule item \(item.id.rawValue) has invalid required dimensions")
            }
        }

        guard requiresPreparedPostHoldDown(plan) else { return }
        let crossPins = plan.hardwareItems.filter(\.isPreparedMasterHoldDownCrossPin)
        guard crossPins.count == 1, crossPins.first?.quantity == 1 else {
            throw Error.missingArtifacts([
                crossPins.isEmpty
                    ? "missing required removable hold-down cross-pin hardware"
                    : "expected exactly one removable hold-down cross-pin hardware",
            ])
        }
        let crossPin = crossPins[0]
        guard crossPin.matchesFixtureRequirement() else {
            throw Error.missingArtifacts(["removable hold-down cross-pin hardware does not match its declared fixture requirement"])
        }
        if plan.toolingExportContract.state == .geometryOnly,
           crossPin.qualification == .shopQualified {
            throw Error.unreleasableContract(
                state: .geometryOnly,
                reasons: ["Geometry-only export cannot claim shop-qualified hold-down hardware."]
            )
        }
    }

    private static func requiresPreparedPostHoldDown(_ plan: MotherMoldPlan) -> Bool {
        guard plan.toolingContractVersion == 3,
              plan.toolingExportContract.requiredArtifactRoles.contains(.holdDownYoke) else {
            return false
        }
        return [
            MasterRetentionEvidence.preparedPostGeometryOnly,
            .preparedPostQualified,
        ].contains(plan.masterPreparation.retentionEvidence)
    }

    private static func geometryCandidates(plan: MotherMoldPlan) throws -> [GeometryCandidate] {
        var candidates: [GeometryCandidate] = []
        let shellQualification: ManufacturingQualification = [
            MotherMoldToolingContractState.printerValidated,
            .productionProfileQualified,
        ].contains(plan.toolingExportContract.state) ? .printerProfileValidated : .topologyValid
        for (index, part) in plan.parts.sorted(by: { $0.name < $1.name }).enumerated() {
            guard part.isWatertight else { throw Error.invalidGeometry("shell part \(part.name) is not marked watertight") }
            candidates.append(GeometryCandidate(path: "print/\(safePartStem(part.name)).stl", id: ToolingArtifactID("MOLD \(partLabel(index))"), displayID: "MOLD \(partLabel(index))", toolingRole: .moldPart, geometry: part.geometry, qualification: shellQualification, materialHint: nil, quantity: 1, assembledTransform: .identity, recommendedPrintTransform: nil))
        }
        let artifacts = plan.manufacturingToolingArtifacts.sorted { $0.id < $1.id }
        let ids = artifacts.map(\.id)
        guard Set(ids).count == ids.count else { throw Error.roleConflict("duplicate tooling artifact ID") }
        if [.printerValidated, .productionProfileQualified].contains(plan.toolingExportContract.state),
           let unvalidated = artifacts.first(where: { $0.qualification != .printerProfileValidated }) {
            throw Error.unreleasableContract(
                state: plan.toolingExportContract.state,
                reasons: ["\(unvalidated.id.rawValue) has not been validated against the selected printer profile."]
            )
        }
        for artifact in artifacts {
            guard artifact.role.isManufacturingArtifact else { throw Error.roleConflict("reference artifact \(artifact.id.rawValue) was supplied as printable tooling") }
            guard artifact.quantity > 0 else { throw Error.invalidArtifact("\(artifact.id.rawValue) has non-positive quantity") }
            let path = "print/\(artifactStem(artifact, all: artifacts)).stl"
            candidates.append(GeometryCandidate(path: path, id: artifact.id, displayID: artifact.id.rawValue, toolingRole: artifact.role, geometry: artifact.geometry, qualification: artifact.qualification, materialHint: artifact.materialHint, quantity: artifact.quantity, assembledTransform: artifact.assembledTransform, recommendedPrintTransform: artifact.recommendedPrintTransform))
        }
        try validateRequiredArtifacts(plan: plan, candidates: candidates)
        return candidates.sorted { $0.path < $1.path }
    }

    private static func validateRequiredArtifacts(plan: MotherMoldPlan, candidates: [GeometryCandidate]) throws {
        let roles = candidates.map(\.toolingRole)
        var missing = plan.toolingExportContract.requiredArtifactRoles.filter { !roles.contains($0) }.map { "missing required \($0.rawValue)" }
        for role in [ToolingArtifactRole.preparedMaster, .holdDownYoke, .castingFunnel] where plan.toolingExportContract.requiredArtifactRoles.contains(role) {
            if roles.filter({ $0 == role }).count != 1 { missing.append("expected exactly one \(role.rawValue)") }
        }
        let requiredCradles = Set(plan.linerFillSupport.cradleArtifactIDs + plan.castingSupport.cradleArtifactIDs)
        let exportedCradles = Set(candidates.filter { $0.toolingRole == .supportCradle }.map(\.id))
        for id in requiredCradles.subtracting(exportedCradles).sorted() { missing.append("missing required support cradle \(id.rawValue)") }
        let requiredVentCount = plan.productionCastingVents.filter { $0.state == .geometryVerified }.count
        if candidates.filter({ $0.toolingRole == .productionVentFormer }).count < requiredVentCount { missing.append("missing required production vent former geometry") }
        guard missing.isEmpty else { throw Error.missingArtifacts(missing.sorted()) }
    }

    private static func measuredGeometryMember(_ candidate: GeometryCandidate) throws -> Member {
        try validateInputGeometry(candidate.geometry, label: candidate.id.rawValue)
        let data = try asciiData(serialiseSTL(candidate.geometry, solidName: safeStem(candidate.id.rawValue)))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mothermold-measure-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        let rereadData = try Data(contentsOf: temporary)
        let rereadGeometry = try parseExactASCIISTL(rereadData, label: candidate.id.rawValue)
        let metrics = try geometryMetrics(rereadGeometry, label: candidate.id.rawValue)
        return Member(path: candidate.path, data: data, role: .toolingGeometry, toolingRole: candidate.toolingRole, content: .geometry, mediaType: "model/stl", geometry: (metrics, ToolingManifestGeometryMember(artifactID: candidate.id, qualification: candidate.qualification, quantity: candidate.quantity, materialHint: candidate.materialHint, assembledTransform: candidate.assembledTransform, recommendedPrintTransform: candidate.recommendedPrintTransform)))
    }

    private static func referenceMembers(plan: MotherMoldPlan) throws -> [Member] {
        guard plan.includeReferenceMeshes else { return [] }
        var output: [Member] = []
        for artifact in plan.referenceToolingArtifacts.sorted(by: { $0.id < $1.id }) {
            let path: String
            switch artifact.role { case .referenceAsPouredLiner: path = "reference/as-poured-silicone-liner.obj"; case .referenceProductionLiner: path = "reference/production-silicone-liner.obj"; default: throw Error.roleConflict("unsupported reference role \(artifact.role.rawValue)") }
            output.append(try measuredReferenceMember(artifact: artifact, path: path))
        }
        let activeSource = ToolingArtifact(
            id: ToolingArtifactID("ACTIVE SOURCE"),
            name: "Active source master",
            role: .referenceActiveSource,
            geometry: plan.activeSourceMaster,
            qualification: .referenceOnly
        )
        output.append(try measuredReferenceMember(
            artifact: activeSource,
            path: "reference/active-source-master.obj",
            acceptsClosedValidatedSource: true
        ))
        if let sourcePath = plan.sourceModelPath, let data = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)) {
            let ext = URL(fileURLWithPath: sourcePath).pathExtension.lowercased()
            guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw Error.invalidArtifact("source reference extension is unsafe") }
            output.append(Member(path: "reference/imported-source.\(ext)", data: data, role: .sourceProvenance, toolingRole: .referenceImportedSource, content: .sourceBytes, mediaType: "application/octet-stream", geometry: nil))
        }
        return output
    }

    private static func measuredReferenceMember(
        artifact: ToolingArtifact,
        path: String,
        acceptsClosedValidatedSource: Bool = false
    ) throws -> Member {
        let data = try asciiData(serialiseOBJ(artifact.geometry, name: safeStem(artifact.id.rawValue)))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mothermold-reference-measure-\(UUID().uuidString).obj")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        let reread: MeshSummary
        do { reread = try MeshInspector.inspect(url: temporary) } catch { throw Error.invalidGeometry("\(artifact.id.rawValue) reference could not be re-read: \(error.localizedDescription)") }
        let metrics = try acceptsClosedValidatedSource
            ? sourceGeometryMetrics(reread.geometry, label: artifact.id.rawValue)
            : geometryMetrics(reread.geometry, label: artifact.id.rawValue)
        let metadata = ToolingManifestGeometryMember(artifactID: artifact.id, qualification: .referenceOnly, quantity: artifact.quantity, materialHint: artifact.materialHint, assembledTransform: artifact.assembledTransform, recommendedPrintTransform: artifact.recommendedPrintTransform)
        return Member(path: path, data: data, role: .referenceGeometry, toolingRole: artifact.role, content: .geometry, mediaType: "model/obj", geometry: (metrics, metadata))
    }

    private static func makeManifest(plan: MotherMoldPlan, members: [Member]) throws -> MotherMoldToolingManifest {
        let activeMetrics = try sourceGeometryMetrics(
            plan.activeSourceMaster,
            label: "active source master"
        )
        let preparedMetrics = members.first(where: { $0.toolingRole == .preparedMaster })?.geometry?.0
        let sourceHash = sha256(try asciiData(serialiseSTL(plan.activeSourceMaster, solidName: "active-source-master")))
        let importedHash = members.first(where: { $0.toolingRole == .referenceImportedSource }).map { sha256($0.data) }
        let records = members.sorted { $0.path < $1.path }.map { ToolingManifestMember(member: $0.packageMember, geometry: $0.geometry?.1) }
        let profile = plan.manufacturingProfile.map {
            ToolingManifestProfile(
                printerProfileID: $0.printerProfileID,
                materialProfileID: $0.materialProfileID,
                profileSnapshotSHA256: $0.profileSnapshotSHA256
            )
        }
        return MotherMoldToolingManifest(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", toolingContractVersion: 3, deterministicSeed: plan.deterministicSeed, source: ToolingManifestSource(importedSourceSHA256: importedHash, activeSourceGeometrySHA256: sourceHash, activeSourceMetrics: activeMetrics, preparedMasterMetrics: preparedMetrics), manufacturingProfile: profile, members: records, hardwareItems: plan.hardwareItems, shell: ToolingShellSummary(partCount: plan.parts.count, interfaceCount: plan.flangedSeamCount, flangePlateCount: plan.flangePlatesPlaced, boltHoleCount: plan.effectiveBoltHoleCount, shellRegistrationKeyCount: plan.registrationKeysPlaced), masterPreparation: plan.masterPreparation, holdDownWrenchEnvelope: plan.holdDownWrenchEnvelope, linerRegistration: plan.linerRegistration, linerFillPath: plan.linerFillPath, productionCastingPath: plan.productionCastingPath, productionCastingVents: plan.productionCastingVents.sorted { $0.id < $1.id }, linerFillSupport: plan.linerFillSupport, castingSupport: plan.castingSupport, exportContract: plan.toolingExportContract, blockingDiagnostics: [], warningDiagnostics: plan.diagnostics.filter { $0.severity == .warning }.map(\.message).sorted())
    }

    private static func validateMemberLayout(_ members: [Member]) throws {
        var seen = Set<String>()
        var rolePaths: [String: String] = [:]
        for member in members {
            guard normalized(member.path) == member.path else { throw Error.invalidPath(member.path) }
            guard seen.insert(member.path).inserted else { throw Error.duplicatePath(member.path) }
            if let toolingRole = member.toolingRole, ![.moldPart, .productionVentFormer, .supportCradle, .fixturePart].contains(toolingRole) {
                if let current = rolePaths[toolingRole.rawValue] { throw Error.roleConflict("\(toolingRole.rawValue) at both \(current) and \(member.path)") }
                rolePaths[toolingRole.rawValue] = member.path
            }
            if member.content == .geometry && member.geometry == nil && member.role == .toolingGeometry { throw Error.invalidGeometry("\(member.path) has no measured metrics") }
            if member.content != .geometry && member.geometry != nil { throw Error.roleConflict("non-geometry member \(member.path) carries geometry metrics") }
        }
    }

    private static func geometryMetrics(_ geometry: MeshGeometryData, label: String) throws -> SerializedGeometryMetrics {
        try validateInputGeometry(geometry, label: label)
        let preflight = MeshPreflight.analyze(geometry: geometry)
        let components = connectedComponents(geometry)
        let volume = MoldComponentFilter.signedVolume(geometry)
        let windingIsConsistent = hasConsistentWinding(geometry)
        guard preflight.isWatertight,
              components == 1,
              volume > 0,
              windingIsConsistent else {
            throw Error.invalidGeometry("\(label) must be one watertight, consistently wound, positive-volume solid")
        }
        return SerializedGeometryMetrics(
            vertexCount: geometry.vertices.count,
            triangleCount: geometry.triangleIndices.count / 3,
            connectedComponentCount: components,
            signedVolumeCubicMillimeters: volume,
            isWatertight: preflight.isWatertight,
            hasFiniteCoordinates: true,
            hasConsistentWinding: windingIsConsistent,
            bounds: bounds(of: geometry)
        )
    }

    /// Source/reference geometry follows the same entry-gate semantics as the
    /// planner: boundary-free geometry accepted by Manifold is a closed solid,
    /// while residual self-contact is recorded rather than misreported as a
    /// printable-artifact failure.
    private static func sourceGeometryMetrics(
        _ geometry: MeshGeometryData,
        label: String
    ) throws -> SerializedGeometryMetrics {
        try validateInputGeometry(geometry, label: label)
        let preflight = MeshPreflight.analyze(geometry: geometry)
        let handle: ManifoldHandle
        do {
            handle = try ManifoldEngine.make(from: geometry)
        } catch {
            throw Error.invalidGeometry("\(label) is not a closed Manifold solid")
        }
        let closed = preflight.invalidTriangleReferenceCount == 0
            && preflight.degenerateTriangleCount == 0
            && preflight.boundaryEdgeCount == 0
            && ManifoldEngine.isWatertight(handle)
            && !ManifoldEngine.isEmpty(handle)
        guard closed else {
            throw Error.invalidGeometry("\(label) is not a boundary-free validated source solid")
        }
        let volume = ManifoldEngine.volume(handle)
        return SerializedGeometryMetrics(
            vertexCount: geometry.vertices.count,
            triangleCount: geometry.triangleIndices.count / 3,
            connectedComponentCount: connectedComponents(geometry),
            signedVolumeCubicMillimeters: volume,
            isWatertight: true,
            hasFiniteCoordinates: true,
            hasConsistentWinding: hasConsistentWinding(geometry),
            bounds: bounds(of: geometry)
        )
    }

    private static func validateInputGeometry(_ geometry: MeshGeometryData, label: String) throws {
        guard !geometry.vertices.isEmpty, geometry.triangleIndices.count >= 3, geometry.triangleIndices.count.isMultiple(of: 3) else { throw Error.invalidGeometry("\(label) has no complete triangles") }
        guard geometry.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw Error.invalidGeometry("\(label) has non-finite coordinates") }
        guard geometry.triangleIndices.allSatisfy({ geometry.vertices.indices.contains(Int($0)) }) else { throw Error.invalidGeometry("\(label) has invalid triangle indices") }
    }

    private static func connectedComponents(_ geometry: MeshGeometryData) -> Int {
        let count = geometry.triangleIndices.count / 3
        guard count > 0 else { return 0 }
        var parent = Array(0..<count)
        func find(_ value: Int) -> Int { var root = value; while parent[root] != root { root = parent[root] }; var cursor = value; while parent[cursor] != root { let next = parent[cursor]; parent[cursor] = root; cursor = next }; return root }
        func unite(_ lhs: Int, _ rhs: Int) { let a = find(lhs), b = find(rhs); if a != b { parent[max(a, b)] = min(a, b) } }
        var owners: [Int: Int] = [:]
        for triangle in 0..<count { for offset in 0..<3 { let vertex = Int(geometry.triangleIndices[triangle * 3 + offset]); if let prior = owners[vertex] { unite(triangle, prior) } else { owners[vertex] = triangle } } }
        return Set((0..<count).map(find)).count
    }

    private struct UndirectedIndexEdge: Hashable {
        var low: Int32
        var high: Int32

        init(_ first: Int32, _ second: Int32) {
            low = Swift.min(first, second)
            high = Swift.max(first, second)
        }
    }

    private static func hasConsistentWinding(_ geometry: MeshGeometryData) -> Bool {
        var directions: [UndirectedIndexEdge: (forward: Int, reverse: Int)] = [:]
        for start in stride(from: 0, to: geometry.triangleIndices.count, by: 3) {
            let a = geometry.triangleIndices[start]
            let b = geometry.triangleIndices[start + 1]
            let c = geometry.triangleIndices[start + 2]
            for (first, second) in [(a, b), (b, c), (c, a)] {
                let edge = UndirectedIndexEdge(first, second)
                var count = directions[edge] ?? (0, 0)
                if first == edge.low {
                    count.forward += 1
                } else {
                    count.reverse += 1
                }
                directions[edge] = count
            }
        }
        return !directions.isEmpty && directions.values.allSatisfy {
            $0.forward == 1 && $0.reverse == 1
        }
    }

    private static func bounds(of geometry: MeshGeometryData) -> ToolingBounds? {
        guard let first = geometry.vertices.first else { return nil }
        var min = first, max = first
        for point in geometry.vertices { min.x = Swift.min(min.x, point.x); min.y = Swift.min(min.y, point.y); min.z = Swift.min(min.z, point.z); max.x = Swift.max(max.x, point.x); max.y = Swift.max(max.y, point.y); max.z = Swift.max(max.z, point.z) }
        return ToolingBounds(minimum: Vec3Codable(x: min.x, y: min.y, z: min.z), maximum: Vec3Codable(x: max.x, y: max.y, z: max.z))
    }

    private static func preflightEstimatedZip(geometry: [GeometryCandidate]) throws {
        let overhead: UInt64 = 1_000_000
        let estimate = geometry.reduce(UInt64(0)) { partial, candidate in partial + UInt64(candidate.geometry.triangleIndices.count / 3) * 512 + 128 }
        guard estimate + overhead <= UInt64(UInt32.max) else { throw Error.zipLimit("estimated archive is larger than 4 GiB") }
        guard geometry.count + 8 <= Int(UInt16.max) else { throw Error.zipLimit("estimated member count exceeds 65,535") }
    }

    private static func preflightZip(members: [Member]) throws { try preflightZip(entries: members.map { ZipWriter.Entry(name: $0.path, data: $0.data) }) }
    private static func preflightZip(entries: [ZipWriter.Entry]) throws {
        guard entries.count <= Int(UInt16.max) else { throw Error.zipLimit("member count \(entries.count) exceeds 65,535") }
        var total: UInt64 = 22
        for entry in entries {
            let name = entry.name.lengthOfBytes(using: .utf8)
            guard name <= Int(UInt16.max) else { throw Error.zipLimit("member name \(entry.name) exceeds UInt16 length") }
            guard entry.data.count <= Int(UInt32.max) else { throw Error.zipLimit("member \(entry.name) exceeds UInt32 size") }
            total += UInt64(30 + name + entry.data.count + 46 + name)
        }
        guard total <= UInt64(UInt32.max) else { throw Error.zipLimit("predicted archive is \(total) bytes, above UInt32 limit") }
    }

    private static func auditArchive(at url: URL, manifest: MotherMoldToolingManifest, expected: [ZipWriter.Entry]) throws {
        let listData = try runUnzip(["-Z1", url.path])
        let listed = String(decoding: listData, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }.sorted()
        let expectedNames = expected.map(\.name).sorted()
        guard listed == expectedNames else { throw Error.archiveAudit("member inventory differs from declared archive inventory") }
        let declared = manifest.members.map { $0.member.path }.sorted()
        guard declared == expectedNames.filter({ $0 != "manifest.json" }) else { throw Error.archiveAudit("manifest inventory does not exactly declare non-manifest archive members") }
        for entry in expected {
            let bytes = try runUnzip(["-p", url.path, entry.name])
            guard bytes == entry.data else { throw Error.archiveAudit("member bytes differ after readback: \(entry.name)") }
            if entry.name != "manifest.json", let member = manifest.members.first(where: { $0.member.path == entry.name })?.member {
                guard member.sha256 == sha256(bytes), member.byteCount == UInt64(bytes.count) else { throw Error.archiveAudit("hash or byte count differs for \(entry.name)") }
            }
        }
        let manifestBytes = try runUnzip(["-p", url.path, "manifest.json"])
        let expectedManifestBytes = try manifest.deterministicJSON(prettyPrinted: true)
        guard manifestBytes == expectedManifestBytes else { throw Error.archiveAudit("manifest bytes differ after readback") }
    }

    private static func runUnzip(_ arguments: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe(); process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() } catch { throw Error.archiveAudit("unable to start /usr/bin/unzip") }
        // Drain stdout before waiting so a realistic STL cannot fill the pipe
        // buffer and deadlock the child process.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw Error.archiveAudit(
                "/usr/bin/unzip exited with status \(process.terminationStatus): \(detail)"
            )
        }
        return data
    }

    private static func publish(temporary: URL, destination: URL) throws {
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: temporary) } else { try manager.moveItem(at: temporary, to: destination) }
        } catch { throw Error.publication(error.localizedDescription) }
    }

    private static func readme(modelName: String, artifactCount: Int, contract: MotherMoldToolingContract) -> String {
        "Refab Artist MotherMold tooling package for \(modelName)\n\nOpen guide/assembly-and-reuse.html first.\nManufacturing artifacts: \(artifactCount).\nReadiness: \(contract.state.rawValue) / \(contract.qualification.rawValue).\n\nPhysical printer fit, strength, sealing, cure, and reuse qualification remain shop responsibilities.\n"
    }

    private static func temporarySibling(of destination: URL) -> URL { destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).mothermold-tmp-\(UUID().uuidString)") }
    private static func normalized(_ path: String) -> String? {
        guard !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.isEmpty,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            return nil
        }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return nil
        }
        return pieces.joined(separator: "/")
    }
    private static func safeStem(_ value: String) -> String { let result = value.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" }; return String(result).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
    private static func safePartStem(_ value: String) -> String { let result = value.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" }; return String(result).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
    private static func artifactStem(_ artifact: ToolingArtifact, all: [ToolingArtifact]) -> String { switch artifact.role { case .preparedMaster: return "prepared-master"; case .holdDownYoke: return "master-hold-down-yoke"; case .castingFunnel: return "production-casting-funnel"; case .productionVentFormer: return "production-vent-former-\(ordinal(artifact, in: all))"; case .supportCradle: return "\(safeStem(artifact.name)).stl".replacingOccurrences(of: ".stl", with: ""); default: return safeStem(artifact.name) } }
    private static func ordinal(_ artifact: ToolingArtifact, in all: [ToolingArtifact]) -> String { String(format: "%02d", all.filter { $0.role == artifact.role }.sorted { $0.id < $1.id }.firstIndex(where: { $0.id == artifact.id })! + 1) }
    private static func partLabel(_ index: Int) -> String { let letter = Character(UnicodeScalar(65 + index % 26)!); return index < 26 ? String(letter) : "\(letter)\(index / 26 + 1)" }
    private static func asciiData(_ text: String) throws -> Data { guard text.unicodeScalars.allSatisfy({ $0.value < 128 }), let data = text.data(using: .ascii) else { throw Error.invalidArtifact("writer produced non-ASCII text") }; return data }
    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func serialiseSTL(_ geometry: MeshGeometryData, solidName: String) -> String {
        var lines = ["solid \(solidName)"]
        for index in stride(from: 0, to: geometry.triangleIndices.count, by: 3) { let a = geometry.vertices[Int(geometry.triangleIndices[index])], b = geometry.vertices[Int(geometry.triangleIndices[index + 1])], c = geometry.vertices[Int(geometry.triangleIndices[index + 2])]; let n = normal(a, b, c); lines += ["  facet normal \(number(n.x)) \(number(n.y)) \(number(n.z))", "    outer loop", "      vertex \(number(a.x)) \(number(a.y)) \(number(a.z))", "      vertex \(number(b.x)) \(number(b.y)) \(number(b.z))", "      vertex \(number(c.x)) \(number(c.y)) \(number(c.z))", "    endloop", "  endfacet"] }
        lines.append("endsolid \(solidName)"); return lines.joined(separator: "\n") + "\n"
    }
    private static func parseExactASCIISTL(_ data: Data, label: String) throws -> MeshGeometryData {
        guard let text = String(data: data, encoding: .ascii) else { throw Error.invalidGeometry("\(label) STL bytes are not ASCII") }
        var vertices: [Vec3] = []
        var indices: [Int32] = []
        var indexByVertex: [Vec3: Int32] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "vertex" else { continue }
            guard fields.count == 4, let x = Double(fields[1]), let y = Double(fields[2]), let z = Double(fields[3]) else {
                throw Error.invalidGeometry("\(label) STL has malformed vertex data")
            }
            let vertex = Vec3(x: x, y: y, z: z)
            if let existing = indexByVertex[vertex] {
                indices.append(existing)
            } else {
                let index = Int32(vertices.count)
                vertices.append(vertex)
                indexByVertex[vertex] = index
                indices.append(index)
            }
        }
        guard indices.count.isMultiple(of: 3) else { throw Error.invalidGeometry("\(label) STL has incomplete facets") }
        return MeshGeometryData(vertices: vertices, triangleIndices: indices)
    }
    private static func serialiseOBJ(_ geometry: MeshGeometryData, name: String) -> String { var lines = ["# Refab Artist reference geometry", "o \(name)"]; lines += geometry.vertices.map { "v \(number($0.x)) \(number($0.y)) \(number($0.z))" }; for index in stride(from: 0, to: geometry.triangleIndices.count, by: 3) { lines.append("f \(Int(geometry.triangleIndices[index]) + 1) \(Int(geometry.triangleIndices[index + 1]) + 1) \(Int(geometry.triangleIndices[index + 2]) + 1)") }; return lines.joined(separator: "\n") + "\n" }
    private static func normal(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Vec3 { let ux = b.x-a.x, uy = b.y-a.y, uz = b.z-a.z, vx = c.x-a.x, vy = c.y-a.y, vz = c.z-a.z; let x = uy*vz-uz*vy, y = uz*vx-ux*vz, z = ux*vy-uy*vx, length = (x*x+y*y+z*z).squareRoot(); return length > 0 ? Vec3(x: x/length, y: y/length, z: z/length) : Vec3(x: 0, y: 0, z: 0) }
    private static func number(_ value: Double) -> String { String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value) }
}
