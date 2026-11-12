import Foundation

struct PartitionRegionID: RawRepresentable, Codable, Equatable, Hashable, Comparable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: PartitionRegionID, rhs: PartitionRegionID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func root(sourceGeometryFingerprint: String) -> PartitionRegionID {
        var hasher = PartitionStableHasher()
        hasher.append("partition-region-root-v1")
        hasher.append(sourceGeometryFingerprint)
        return PartitionRegionID(rawValue: "region-\(hasher.finalized)")
    }

    static func child(of nodeID: PartitionCutNodeID, side: PartitionCutSide) -> PartitionRegionID {
        var hasher = PartitionStableHasher()
        hasher.append("partition-region-child-v1")
        hasher.append(nodeID.rawValue)
        hasher.append(side.rawValue)
        return PartitionRegionID(rawValue: "region-\(hasher.finalized)")
    }
}

struct PartitionCutNodeID: RawRepresentable, Codable, Equatable, Hashable, Comparable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: PartitionCutNodeID, rhs: PartitionCutNodeID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum CutSource: String, Codable, Equatable {
    case automatic
    case manual
}

struct PartitionCutNode: Codable, Equatable, Identifiable {
    var id: PartitionCutNodeID
    var targetRegionID: PartitionRegionID
    var plane: CanonicalPlane
    var negativeChildID: PartitionRegionID
    var positiveChildID: PartitionRegionID
    var source: CutSource
    var isLocked: Bool

    static func automatic(
        plannerVersion: Int,
        targetRegionID: PartitionRegionID,
        plane: CanonicalPlane,
        siblingOrdinal: Int,
        isLocked: Bool
    ) -> PartitionCutNode {
        var hasher = PartitionStableHasher()
        hasher.append("partition-cut-automatic-v1")
        hasher.append(plannerVersion)
        hasher.append(targetRegionID.rawValue)
        hasher.appendCanonicalFloatingPoint(plane.normal.x)
        hasher.appendCanonicalFloatingPoint(plane.normal.y)
        hasher.appendCanonicalFloatingPoint(plane.normal.z)
        hasher.appendCanonicalFloatingPoint(plane.offset)
        hasher.append(siblingOrdinal)
        let nodeID = PartitionCutNodeID(rawValue: "cut-\(hasher.finalized)")
        return PartitionCutNode(
            id: nodeID,
            targetRegionID: targetRegionID,
            plane: plane,
            negativeChildID: .child(of: nodeID, side: .negative),
            positiveChildID: .child(of: nodeID, side: .positive),
            source: .automatic,
            isLocked: isLocked
        )
    }

    /// Manual IDs are supplied by the persisted editor transaction that
    /// creates the node. This initializer never consults time or randomness.
    static func manual(
        id: PartitionCutNodeID,
        targetRegionID: PartitionRegionID,
        plane: CanonicalPlane,
        isLocked: Bool
    ) -> PartitionCutNode {
        PartitionCutNode(
            id: id,
            targetRegionID: targetRegionID,
            plane: plane,
            negativeChildID: .child(of: id, side: .negative),
            positiveChildID: .child(of: id, side: .positive),
            source: .manual,
            isLocked: isLocked
        )
    }
}

enum PartitionCutTreeValidationIssue: Equatable, CustomStringConvertible {
    case emptyRootRegionID
    case emptyNodeID(index: Int)
    case duplicateNodeID(PartitionCutNodeID)
    case duplicateTargetRegionID(PartitionRegionID)
    case childIDsAreNotDerived(nodeID: PartitionCutNodeID)
    case duplicateRegionID(PartitionRegionID)
    case targetAppearsBeforeParent(PartitionRegionID)
    case orphanNode(PartitionCutNodeID)
    case cycle(PartitionRegionID)
    case notDepthFirst
    case tooManyNodes(Int)

    var description: String {
        switch self {
        case .emptyRootRegionID:
            return "The cut tree root region ID is empty."
        case .emptyNodeID(let index):
            return "Cut node at index \(index) has an empty ID."
        case .duplicateNodeID(let id):
            return "Cut node ID \(id.rawValue) appears more than once."
        case .duplicateTargetRegionID(let id):
            return "Region \(id.rawValue) is cut more than once."
        case .childIDsAreNotDerived(let nodeID):
            return "Cut node \(nodeID.rawValue) has child IDs inconsistent with its persisted identity."
        case .duplicateRegionID(let id):
            return "Region ID \(id.rawValue) is created more than once."
        case .targetAppearsBeforeParent(let id):
            return "Target region \(id.rawValue) appears before its parent creates it."
        case .orphanNode(let id):
            return "Cut node \(id.rawValue) is not reachable from the root region."
        case .cycle(let id):
            return "The cut tree cycles through region \(id.rawValue)."
        case .notDepthFirst:
            return "Cut nodes are not serialized in depth-first order."
        case .tooManyNodes(let count):
            return "Cut tree has \(count) nodes; Split by Undercuts supports at most 31."
        }
    }
}

struct PartitionCutTree: Codable, Equatable {
    var rootRegionID: PartitionRegionID
    var nodes: [PartitionCutNode]

    var structuralValidationIssues: [PartitionCutTreeValidationIssue] {
        var issues: [PartitionCutTreeValidationIssue] = []
        if rootRegionID.rawValue.isEmpty { issues.append(.emptyRootRegionID) }
        // Bound attacker-controlled project payloads before walking them. This
        // also prevents the issue de-duplication below from becoming quadratic
        // for a huge invalid tree during quarantine decode.
        if nodes.count > 31 { return [.tooManyNodes(nodes.count)] }

        var seenNodeIDs = Set<PartitionCutNodeID>()
        var seenTargets = Set<PartitionRegionID>()
        var createdRegions: Set<PartitionRegionID> = [rootRegionID]
        var availableLeaves: Set<PartitionRegionID> = [rootRegionID]
        for (index, node) in nodes.enumerated() {
            if node.id.rawValue.isEmpty { issues.append(.emptyNodeID(index: index)) }
            if !seenNodeIDs.insert(node.id).inserted { issues.append(.duplicateNodeID(node.id)) }
            if !seenTargets.insert(node.targetRegionID).inserted {
                issues.append(.duplicateTargetRegionID(node.targetRegionID))
            }
            let expectedNegative = PartitionRegionID.child(of: node.id, side: .negative)
            let expectedPositive = PartitionRegionID.child(of: node.id, side: .positive)
            if node.negativeChildID != expectedNegative || node.positiveChildID != expectedPositive {
                issues.append(.childIDsAreNotDerived(nodeID: node.id))
            }
            if availableLeaves.remove(node.targetRegionID) == nil {
                issues.append(.targetAppearsBeforeParent(node.targetRegionID))
            }
            for child in [node.negativeChildID, node.positiveChildID] {
                if !createdRegions.insert(child).inserted { issues.append(.duplicateRegionID(child)) }
                availableLeaves.insert(child)
            }
        }

        var nodesByTarget: [PartitionRegionID: PartitionCutNode] = [:]
        for node in nodes where nodesByTarget[node.targetRegionID] == nil {
            nodesByTarget[node.targetRegionID] = node
        }
        var visiting = Set<PartitionRegionID>()
        var visited = Set<PartitionCutNodeID>()
        func visit(_ regionID: PartitionRegionID) {
            guard let node = nodesByTarget[regionID] else { return }
            guard visiting.insert(regionID).inserted else {
                issues.append(.cycle(regionID))
                return
            }
            visited.insert(node.id)
            visit(node.negativeChildID)
            visit(node.positiveChildID)
            visiting.remove(regionID)
        }
        visit(rootRegionID)
        for node in nodes where !visited.contains(node.id) {
            issues.append(.orphanNode(node.id))
        }
        if !isSerializedDepthFirst(nodesByTarget: nodesByTarget) {
            issues.append(.notDepthFirst)
        }

        var unique: [PartitionCutTreeValidationIssue] = []
        for issue in issues where !unique.contains(issue) { unique.append(issue) }
        return unique
    }

    /// A preorder may visit either child subtree first. Once traversal enters
    /// one child, it must consume that complete subtree before its sibling.
    /// Parent-before-child and reachability are checked separately above.
    private func isSerializedDepthFirst(
        nodesByTarget: [PartitionRegionID: PartitionCutNode]
    ) -> Bool {
        var cursor = 0

        func consume(_ regionID: PartitionRegionID) {
            guard cursor < nodes.count,
                  nodes[cursor].targetRegionID == regionID,
                  let node = nodesByTarget[regionID] else { return }
            cursor += 1

            if cursor < nodes.count,
               nodes[cursor].targetRegionID == node.positiveChildID {
                consume(node.positiveChildID)
                consume(node.negativeChildID)
            } else {
                consume(node.negativeChildID)
                consume(node.positiveChildID)
            }
        }

        consume(rootRegionID)
        return cursor == nodes.count
    }

    var allRegionIDs: Set<PartitionRegionID> {
        var result: Set<PartitionRegionID> = [rootRegionID]
        for node in nodes {
            result.insert(node.negativeChildID)
            result.insert(node.positiveChildID)
        }
        return result
    }

    func replay(source: AttributedMesh) throws -> PartitionCutReplay {
        let issues = structuralValidationIssues
        guard issues.isEmpty else { throw PartitionCutTreeReplayError.invalidStructure(issues) }
        guard rootRegionID == .root(
            sourceGeometryFingerprint: source.sourceGeometryFingerprint
        ) else {
            throw PartitionCutTreeReplayError.sourceRootMismatch
        }

        var leaves: [PartitionRegionID: AttributedMesh] = [rootRegionID: source]
        for node in nodes {
            guard let target = leaves.removeValue(forKey: node.targetRegionID) else {
                throw PartitionCutTreeReplayError.missingTargetRegion(node.targetRegionID)
            }
            do {
                let split = try PartitionGeometry.splitAttributed(
                    target,
                    plane: node.plane,
                    cutNodeID: node.id
                )
                leaves[node.negativeChildID] = split.negative
                leaves[node.positiveChildID] = split.positive
            } catch {
                leaves[node.targetRegionID] = target
                throw PartitionCutTreeReplayError.splitFailed(
                    nodeID: node.id,
                    reason: error.localizedDescription
                )
            }
        }

        let orderedLeaves = leaves
            .map { PartitionCutLeaf(regionID: $0.key, mesh: $0.value) }
            .sorted { $0.regionID < $1.regionID }
        let seams = nodes.map { node in
            let negative = orderedLeaves.compactMap { leaf -> PartitionRegionID? in
                leaf.mesh.containsCutCap(nodeID: node.id, side: .negative) ? leaf.regionID : nil
            }
            let positive = orderedLeaves.compactMap { leaf -> PartitionRegionID? in
                leaf.mesh.containsCutCap(nodeID: node.id, side: .positive) ? leaf.regionID : nil
            }
            return PartitionSeamAdjacency(
                seamID: "seam-\(node.id.rawValue)",
                cutNodeID: node.id,
                negativePieceRegionIDs: negative,
                positivePieceRegionIDs: positive
            )
        }
        return PartitionCutReplay(leaves: orderedLeaves, seams: seams)
    }
}

enum PartitionCutTreeReplayError: LocalizedError {
    case invalidStructure([PartitionCutTreeValidationIssue])
    case sourceRootMismatch
    case missingTargetRegion(PartitionRegionID)
    case splitFailed(nodeID: PartitionCutNodeID, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidStructure(let issues):
            return issues.map(\.description).joined(separator: " ")
        case .sourceRootMismatch:
            return "Cut tree root does not match the attributed source identity."
        case .missingTargetRegion(let regionID):
            return "Scoped replay could not find target region \(regionID.rawValue)."
        case .splitFailed(let nodeID, let reason):
            return "Cut \(nodeID.rawValue) could not split its target region: \(reason)"
        }
    }
}

struct PartitionCutLeaf: Equatable {
    var regionID: PartitionRegionID
    var mesh: AttributedMesh
}

struct PartitionSeamAdjacency: Equatable {
    var seamID: String
    var cutNodeID: PartitionCutNodeID
    var negativePieceRegionIDs: [PartitionRegionID]
    var positivePieceRegionIDs: [PartitionRegionID]
}

struct PartitionCutReplay: Equatable {
    var leaves: [PartitionCutLeaf]
    var seams: [PartitionSeamAdjacency]

    func leaf(_ regionID: PartitionRegionID) -> AttributedMesh? {
        leaves.first { $0.regionID == regionID }?.mesh
    }
}

struct PersistedCutTreeEnvelope: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sourceGeometryFingerprint: String
    let rawTree: JSONValue
    let typedTree: PartitionCutTree?
    let diagnostics: [String]

    var isQuarantined: Bool { typedTree == nil }

    init(
        schemaVersion: Int = PersistedCutTreeEnvelope.currentSchemaVersion,
        sourceGeometryFingerprint: String,
        rawTree: JSONValue
    ) {
        self.schemaVersion = schemaVersion
        self.sourceGeometryFingerprint = sourceGeometryFingerprint
        self.rawTree = rawTree
        let resolution = Self.resolve(rawTree: rawTree, schemaVersion: schemaVersion)
        if sourceGeometryFingerprint.isEmpty {
            typedTree = nil
            diagnostics = resolution.diagnostics
                + ["Authored cut tree source fingerprint is missing."]
        } else {
            typedTree = resolution.tree
            diagnostics = resolution.diagnostics
        }
    }

    init(
        tree: PartitionCutTree,
        sourceGeometryFingerprint: String
    ) throws {
        guard !sourceGeometryFingerprint.isEmpty else {
            throw PersistedCutTreeEnvelopeError.invalidTree([
                "Authored cut tree source fingerprint is missing."
            ])
        }
        let issues = tree.structuralValidationIssues
        guard issues.isEmpty else {
            throw PersistedCutTreeEnvelopeError.invalidTree(issues.map(\.description))
        }
        schemaVersion = Self.currentSchemaVersion
        self.sourceGeometryFingerprint = sourceGeometryFingerprint
        rawTree = try Self.jsonValue(tree)
        typedTree = tree
        diagnostics = []
    }

    init(from decoder: Decoder) throws {
        let envelopeValue = try JSONValue(from: decoder)
        guard case .object(let object) = envelopeValue else {
            schemaVersion = 0
            sourceGeometryFingerprint = ""
            rawTree = envelopeValue
            typedTree = nil
            diagnostics = ["Authored cut tree envelope is not a JSON object."]
            return
        }
        let decodedSchemaVersion: Int
        if case .number(let number)? = object["schemaVersion"],
           number.isFinite,
           number.rounded() == number,
           number >= Double(Int.min), number <= Double(Int.max) {
            decodedSchemaVersion = Int(number)
        } else {
            decodedSchemaVersion = 0
        }
        let decodedFingerprint: String
        if case .string(let fingerprint)? = object["sourceGeometryFingerprint"] {
            decodedFingerprint = fingerprint
        } else {
            decodedFingerprint = ""
        }
        let decodedRawTree = object["rawTree"] ?? .null
        let resolution = Self.resolve(
            rawTree: decodedRawTree,
            schemaVersion: decodedSchemaVersion
        )
        var resolvedTree = resolution.tree
        var resolvedDiagnostics = resolution.diagnostics
        if decodedFingerprint.isEmpty {
            resolvedTree = nil
            resolvedDiagnostics.append("Authored cut tree source fingerprint is missing.")
        }
        schemaVersion = decodedSchemaVersion
        sourceGeometryFingerprint = decodedFingerprint
        rawTree = decodedRawTree
        typedTree = resolvedTree
        diagnostics = resolvedDiagnostics
    }

    /// Authored-tree edits replace the complete envelope value so the raw JSON,
    /// executable typed tree, and diagnostics can never diverge.
    func replacing(
        schemaVersion: Int? = nil,
        sourceGeometryFingerprint: String? = nil,
        rawTree: JSONValue
    ) -> PersistedCutTreeEnvelope {
        PersistedCutTreeEnvelope(
            schemaVersion: schemaVersion ?? self.schemaVersion,
            sourceGeometryFingerprint: sourceGeometryFingerprint
                ?? self.sourceGeometryFingerprint,
            rawTree: rawTree
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sourceGeometryFingerprint, forKey: .sourceGeometryFingerprint)
        try container.encode(rawTree, forKey: .rawTree)
    }

    func validateSourceBound(
        source: AttributedMesh,
        sourceGeometryFingerprint: String,
        faceConstraints: PartitionFaceConstraints,
        lockedPullDirections: [PartitionRegionID: Vec3],
        maxPieces: Int = 32
    ) -> PartitionCutTreeSourceValidation {
        guard let tree = typedTree else {
            return PartitionCutTreeSourceValidation(
                replay: nil,
                diagnostics: diagnostics.isEmpty ? ["Authored cut tree is quarantined."] : diagnostics
            )
        }
        guard self.sourceGeometryFingerprint == sourceGeometryFingerprint else {
            return PartitionCutTreeSourceValidation(
                replay: nil,
                diagnostics: [
                    "Authored cut tree source fingerprint does not match the effective source."
                ]
            )
        }
        guard source.sourceGeometryFingerprint == sourceGeometryFingerprint else {
            return PartitionCutTreeSourceValidation(
                replay: nil,
                diagnostics: ["Attributed source identity does not match the effective source fingerprint."]
            )
        }
        let expectedRoot = PartitionRegionID.root(
            sourceGeometryFingerprint: sourceGeometryFingerprint
        )
        guard tree.rootRegionID == expectedRoot else {
            return PartitionCutTreeSourceValidation(
                replay: nil,
                diagnostics: ["Authored cut tree root does not match the effective source fingerprint."]
            )
        }
        guard tree.nodes.count + 1 <= min(max(maxPieces, 1), 32) else {
            return PartitionCutTreeSourceValidation(
                replay: nil,
                diagnostics: ["Authored cut tree exceeds the active maximum piece count."]
            )
        }

        let replay: PartitionCutReplay
        do {
            replay = try tree.replay(source: source)
        } catch {
            return PartitionCutTreeSourceValidation(
                replay: nil,
                diagnostics: [error.localizedDescription]
            )
        }

        var validationDiagnostics: [String] = []
        let availableSourceFaces = source.sourceFaceIDs
            .union(source.omittedDegenerateSourceFaceIDs)
        let requestedFaces = Set(faceConstraints.noCutSourceFaceIDs)
            .union(faceConstraints.preferredSeamFaces.map(\.sourceFaceID))
        for faceID in requestedFaces.sorted() where !availableSourceFaces.contains(faceID) {
            validationDiagnostics.append(
                "Face constraint references missing source face \(faceID.rawValue)."
            )
        }
        let leafIDs = Set(replay.leaves.map(\.regionID))
        for (regionID, direction) in lockedPullDirections.sorted(by: { $0.key < $1.key }) {
            if !leafIDs.contains(regionID) {
                validationDiagnostics.append(
                    "A locked pull direction references missing leaf region \(regionID.rawValue)."
                )
            }
            let squaredLength = direction.x * direction.x
                + direction.y * direction.y
                + direction.z * direction.z
            if !direction.x.isFinite || !direction.y.isFinite || !direction.z.isFinite
                || !squaredLength.isFinite || squaredLength <= 1.0e-24 {
                validationDiagnostics.append(
                    "Locked pull direction for \(regionID.rawValue) is not finite and nonzero."
                )
            }
        }
        return PartitionCutTreeSourceValidation(
            replay: validationDiagnostics.isEmpty ? replay : nil,
            diagnostics: validationDiagnostics
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sourceGeometryFingerprint
        case rawTree
    }

    private static func resolve(
        rawTree: JSONValue,
        schemaVersion: Int
    ) -> (tree: PartitionCutTree?, diagnostics: [String]) {
        guard schemaVersion == currentSchemaVersion else {
            return (nil, ["Unsupported authored cut tree schema version \(schemaVersion)."])
        }
        do {
            let data = try JSONEncoder().encode(rawTree)
            let tree = try JSONDecoder().decode(PartitionCutTree.self, from: data)
            let issues = tree.structuralValidationIssues
            guard issues.isEmpty else { return (nil, issues.map(\.description)) }
            return (tree, [])
        } catch {
            return (nil, ["Authored cut tree typed decode failed: \(error.localizedDescription)"])
        }
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

enum PersistedCutTreeEnvelopeError: LocalizedError {
    case invalidTree([String])

    var errorDescription: String? {
        switch self {
        case .invalidTree(let diagnostics): return diagnostics.joined(separator: " ")
        }
    }
}

struct PartitionCutTreeSourceValidation: Equatable {
    var replay: PartitionCutReplay?
    var diagnostics: [String]

    var isValid: Bool { replay != nil && diagnostics.isEmpty }
}

private extension AttributedMesh {
    func containsCutCap(nodeID: PartitionCutNodeID, side: PartitionCutSide) -> Bool {
        triangles.contains { triangle in
            if case .cut(let triangleNodeID, let triangleSide) = triangle.provenance {
                return triangleNodeID == nodeID && triangleSide == side
            }
            return false
        }
    }
}
