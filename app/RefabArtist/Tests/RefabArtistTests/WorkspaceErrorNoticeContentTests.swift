import Testing
@testable import RefabArtist

struct WorkspaceErrorNoticeContentTests {
    @Test
    func exportFailureNamesModeFormatAndErrorMessage() {
        let notice = WorkspaceErrorNoticeContent.exportFailed(
            "The file could not be saved.",
            format: "DXF",
            constructionMode: "Stacked Slices"
        )

        #expect(notice.severity == .error)
        #expect(notice.title == "Export failed")
        #expect(notice.message == "Stacked Slices DXF export did not finish.")
        #expect(notice.detail == "The file could not be saved.")
    }

    @Test
    func watertightPreflightDoesNotCreateNotice() {
        let report = MeshPreflightReport(
            uniqueVertexCount: 8,
            duplicateVertexObservationCount: 0,
            invalidTriangleReferenceCount: 0,
            degenerateTriangleCount: 0,
            boundaryEdgeCount: 0,
            nonManifoldEdgeCount: 0
        )

        #expect(WorkspaceErrorNoticeContent.meshPreflight(report) == nil)
    }

    @Test
    func invalidPreflightCreatesActionableCounts() {
        let report = MeshPreflightReport(
            uniqueVertexCount: 6,
            duplicateVertexObservationCount: 0,
            invalidTriangleReferenceCount: 1,
            degenerateTriangleCount: 2,
            boundaryEdgeCount: 3,
            nonManifoldEdgeCount: 4
        )

        let notice = WorkspaceErrorNoticeContent.meshPreflight(report)

        #expect(notice?.severity == .warning)
        #expect(notice?.title == "Mesh needs repair")
        #expect(notice?.detail == "1 invalid reference, 2 degenerate triangles, 3 open edges, 4 non-manifold edges")
    }

    @Test
    func normalSlotWidthDoesNotCreateFitNotice() {
        let notice = WorkspaceErrorNoticeContent.slotFitRisk(slotWidth: 3.1, materialThickness: 3.0)

        #expect(notice == nil)
    }

    @Test
    func veryNarrowSlotWidthCreatesFitNotice() {
        let notice = WorkspaceErrorNoticeContent.slotFitRisk(slotWidth: 0.1, materialThickness: 5.0)

        #expect(notice?.severity == .warning)
        #expect(notice?.title == "Slot fit risk")
        #expect(notice?.detail == "Slot width 0.1 mm for 5 mm material.")
    }
}
