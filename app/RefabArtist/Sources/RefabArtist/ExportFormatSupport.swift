enum ExportFormatSupport {
    static func availableFormats(for mode: ConstructionMode) -> [ExportFormat] {
        switch mode {
        case .threeD, .structures, .partition, .motherMold:
            // 3D Slices produces a surface-preserving LAYERED MESH, not flat
            // laser-cut parts — so it exports as a mesh only, with no flat
            // cut-sheet layout. No DXF/PDF/SVG/EPS sheet for 3D.
            //
            // Structures (Manifold infill) is likewise a single watertight mesh
            // clipped to the model skin — STL/OBJ only. MotherMold emits the
            // separate watertight mold parts as STL/OBJ solids — never a sheet.
            return [.stl, .obj]
        case .inflatables:
            return [.dxf, .svg, .pdf, .stl, .obj]
        case .stacked, .interlocked, .radial, .curve, .foldedPanels:
            return ExportFormat.allCases
        }
    }

    static func normalized(format: ExportFormat, for mode: ConstructionMode) -> ExportFormat {
        let formats = availableFormats(for: mode)
        if formats.contains(format) {
            return format
        }
        return formats[0]
    }
}
