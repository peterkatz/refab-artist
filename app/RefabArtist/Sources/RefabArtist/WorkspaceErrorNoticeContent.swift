struct WorkspaceErrorNoticeContent: Equatable {
    enum Severity: Equatable {
        case warning
        case error
    }

    var severity: Severity
    var systemImage: String
    var title: String
    var message: String
    var detail: String?

    static func exportFailed(
        _ message: String,
        format: String,
        constructionMode: String
    ) -> WorkspaceErrorNoticeContent {
        WorkspaceErrorNoticeContent(
            severity: .error,
            systemImage: "exclamationmark.triangle",
            title: "Export failed",
            message: "\(constructionMode) \(format) export did not finish.",
            detail: message
        )
    }

    static func meshPreflight(_ report: MeshPreflightReport) -> WorkspaceErrorNoticeContent? {
        guard !report.isWatertight else {
            return nil
        }

        return WorkspaceErrorNoticeContent(
            severity: .warning,
            systemImage: "wrench.and.screwdriver",
            title: "Mesh needs repair",
            message: "Generated parts may be incomplete until the model is repaired.",
            detail: [
                count("invalid reference", "invalid references", report.invalidTriangleReferenceCount),
                count("degenerate triangle", "degenerate triangles", report.degenerateTriangleCount),
                count("open edge", "open edges", report.boundaryEdgeCount),
                count("non-manifold edge", "non-manifold edges", report.nonManifoldEdgeCount)
            ]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    static func slotFitRisk(
        slotWidth: Double,
        materialThickness: Double
    ) -> WorkspaceErrorNoticeContent? {
        guard materialThickness > 0 else {
            return nil
        }

        let minimumUsableWidth = max(0.25, materialThickness * 0.25)
        guard slotWidth < minimumUsableWidth else {
            return nil
        }

        return WorkspaceErrorNoticeContent(
            severity: .warning,
            systemImage: "rectangle.compress.vertical",
            title: "Slot fit risk",
            message: "The current slot width is much narrower than the material thickness.",
            detail: "Slot width \(Vec3.format(slotWidth)) mm for \(Vec3.format(materialThickness)) mm material."
        )
    }

    private static func count(_ singular: String, _ plural: String, _ value: Int) -> String? {
        guard value > 0 else {
            return nil
        }
        return "\(value) \(value == 1 ? singular : plural)"
    }
}
