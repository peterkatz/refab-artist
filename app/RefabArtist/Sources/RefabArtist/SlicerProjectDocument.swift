import Foundation

struct SlicerProjectDocument: Codable, Equatable {
    static let currentVersion = 1
    static let fileExtension = "refabartist"
    /// Projects saved before the app became Refab Artist use this
    /// extension; their contents are the same, so they still open.
    static let legacyFileExtension = "slicerrebuild"

    var version: Int = Self.currentVersion
    var modelPath: String
    var settings: SlicerProjectSettings
}

struct SlicerProjectSettings: Codable, Equatable {
    var constructionMode: ConstructionMode
    var sliceAxis: SliceAxis
    /// Slice Direction fine-tune tilt (degrees) about the primary axis's
    /// first/second perpendicular axes; nil (legacy) means 0.
    var sliceTiltFirst: Double?
    var sliceTiltSecond: Double?
    var secondarySliceAxis: SliceAxis
    var materialThickness: Double
    var threeDSliceDepth: Double
    var slotClearance: Double
    var notchWidthOverrideEnabled: Bool
    var notchWidth: Double
    var slotAngleDegrees: Double
    var radialSliceCount: Int
    /// Radial 1st-axis distribution method; nil (legacy) means By Count.
    var radialFirstAxisByDistance: Bool?
    /// Radial 1st-axis ring count; nil (legacy) means 10.
    var radialFirstAxisCount: Int?
    /// Radial 1st-axis ring spacing in mm; nil (legacy) means 15.
    var radialFirstAxisSpacing: Double?
    /// Radial Notch Factor; nil (legacy) means the default, 0.1.
    var radialNotchFactor: Double?
    /// RadialReliefType raw value; nil (legacy) means square (the DEFAULT per
    /// NEO-106; old files that stored "horizontal" keep decoding as horizontal).
    var radialReliefType: String?
    /// Radial Slices' own tool diameter (mm), from before Tool Dia. became
    /// the one tool diameter; nil (legacy) means 0. Still written (equal to
    /// `toolDiameter`) and read only by `resolvedToolDiameter`.
    var radialToolDiameter: Double?
    var curvePrimaryAxis: SliceAxis
    var curveFirstAxisCount: Int
    var curveSliceCount: Int
    var curveAmplitude: Double
    var materialPreset: MaterialPreset
    var slotReliefEnabled: Bool
    /// Interlocked's own relief diameter (mm), from before Tool Dia. became
    /// the one tool diameter. Still written from `toolDiameter`, held to the
    /// 0.5–12 mm range older builds read it in (so Tool Dia. 0 is saved as
    /// 0.5), and read only by `resolvedToolDiameter`.
    var slotReliefDiameter: Double
    /// Manufacturing Settings → Tool Dia. (mm): the one tool diameter, which
    /// sizes the slot relief of every mode that cuts it. nil in projects
    /// saved before it existed (see `resolvedToolDiameter`).
    var toolDiameter: Double?
    var dowelsEnabled: Bool
    var dowelDiameter: Double
    var dowelInset: Double
    /// Flat [x0, y0, x1, y1, ...] manual dowel rod positions in plan
    /// coordinates. Optional so legacy projects keep decoding; nil/empty
    /// means automatic placement.
    var dowelManualPositions: [Double]?
    /// DowelShape raw value; nil (legacy) means round.
    var dowelShape: String?
    /// Automatic rod count; nil (legacy) means 2.
    var dowelAutomaticCount: Int?
    /// Automatic vs manual placement; nil (legacy) means automatic unless
    /// manual positions exist.
    var dowelUseAutomatic: Bool?
    /// Folded Panels simplification target; nil (legacy) means 250.
    var foldedDetailFaces: Int?
    /// NEO-104: Folded joinery (Joint Type + per-type parameters). Optional
    /// so legacy projects decode; nil means the Diamond preset.
    var foldedJoinery: JoineryParameters?
    /// NEO-104: Simplify Form "Split Panels"; nil (legacy) means off.
    var foldedSplitPanels: Bool?
    /// NEO-104: Flat [ax, ay, az, bx, by, bz, ...] seam mesh-edge endpoints
    /// (model coordinates); nil/empty means no user seams.
    var foldedSeamEdges: [Double]?
    var exportFormat: ExportFormat
    var exportLayoutSettings: ExportLayoutSettings
    var modelScaleFactor: Double
    /// [sx, sy, sz, rxDeg, ryDeg, rzDeg] — per-axis scale + rotation. Optional
    /// so legacy projects (single uniform factor) keep decoding.
    var modelTransform: [Double]?
    var importUnit: ImportUnitPreset
    /// Import-time up-axis correction. Optional so legacy projects decode;
    /// nil means the app's earlier behavior of assuming Z-up.
    var importUpAxis: ImportUpAxis?
    var customSliceDistributionEnabled: Bool
    var customSliceCount: Int
    /// Slice-solid render style (Cardboard / Plywood / Plastic). Optional so
    /// legacy project files decode cleanly; nil means `.cardboard` (default).
    var sliceSolidRenderStyle: String?
    /// NEO-103: Slice distribution method raw value; nil (legacy) means automatic.
    var sliceDistributionMethod: String?
    /// NEO-103: By-Distance spacing in mm; nil (legacy) means 5.0.
    var sliceByDistanceSpacingMm: Double?
    /// NEO-103: Custom slice positions (axis-space mm); nil/empty means no override.
    var customSlicePositions: [Double]?
    /// NEO-113: Active Modify Form tool raw value; nil (legacy) means none.
    var modifyTool: String?
    /// NEO-113: Hollow wall thickness in mm; nil (legacy) means 3.0.
    var modifyHollowWallMm: Double?
    /// NEO-113: Thicken offset in mm; nil (legacy) means 2.0.
    var modifyThickenMm: Double?
    /// NEO-115: Shrinkwrap detail 0…1; nil (legacy) means 0.5.
    var modifyShrinkwrapDetail: Double?
    /// Make Watertight method (`WatertightMethod` raw value); nil = not chosen
    /// (Fix in place; legacy Make Watertight projects — no top-height key
    /// either — restore as Rebuild as solid).
    var modifyWatertightMethod: String?
    /// Make Watertight runs underneath the active Hollow / Thicken; nil
    /// (legacy) = only when the active tool is Make Watertight itself.
    var modifyWatertightBase: Bool?
    /// Close openings top shape, mm (0 flat, > 0 dome, < 0 dish).
    var modifyWatertightTopHeightMm: Double?
    /// Make walls thickness, mm.
    var modifyWallThicknessMm: Double?
    /// Make Watertight per-opening choices, keyed by opening signature; nil
    /// (legacy) = none — every opening follows the global controls.
    var modifyOpeningChoices: [OpeningCapper.OpeningChoice]?
    /// Structures construction-mode configuration (Infill/Supports). Optional so
    /// legacy projects (and projects saved before Structures existed) decode
    /// cleanly; nil means `StructureSettings.defaultValue`. The OLD façade schema
    /// also decodes here via `StructureSettings.init(from:)` migration.
    var structureSettings: StructureSettings?
    /// MotherMold construction-mode configuration (casting-mold parts). Optional
    /// so legacy projects (and projects saved before MotherMold existed) decode
    /// cleanly; nil means `MotherMoldSettings.defaultValue`. Follows the same
    /// `decodeIfPresent ?? default` migration pattern as `structureSettings`.
    var motherMoldSettings: MotherMoldSettings?

    /// Partition construction-mode configuration (bed-sized splitting). Optional
    /// so legacy projects decode cleanly; nil means `PartitionSettings.defaultValue`.
    var partitionSettings: PartitionSettings?
    /// Inflatables construction-mode configuration. Optional so legacy projects
    /// decode cleanly; nil means `InflatablesSettings.defaultValue`.
    var inflatablesSettings: InflatablesSettings?

    init(
        constructionMode: ConstructionMode,
        sliceAxis: SliceAxis,
        sliceTiltFirst: Double? = nil,
        sliceTiltSecond: Double? = nil,
        secondarySliceAxis: SliceAxis,
        materialThickness: Double,
        threeDSliceDepth: Double = 10.0,
        slotClearance: Double,
        notchWidthOverrideEnabled: Bool = false,
        notchWidth: Double = 3.0,
        slotAngleDegrees: Double,
        radialSliceCount: Int,
        radialFirstAxisByDistance: Bool? = nil,
        radialFirstAxisCount: Int? = nil,
        radialFirstAxisSpacing: Double? = nil,
        radialNotchFactor: Double? = nil,
        radialReliefType: String? = nil,
        radialToolDiameter: Double? = nil,
        curvePrimaryAxis: SliceAxis = .y,
        curveFirstAxisCount: Int = 7,
        curveSliceCount: Int,
        curveAmplitude: Double,
        materialPreset: MaterialPreset,
        slotReliefEnabled: Bool,
        slotReliefDiameter: Double,
        toolDiameter: Double? = nil,
        dowelsEnabled: Bool,
        dowelDiameter: Double,
        dowelInset: Double,
        dowelManualPositions: [Double]? = nil,
        dowelShape: String? = nil,
        dowelAutomaticCount: Int? = nil,
        dowelUseAutomatic: Bool? = nil,
        foldedDetailFaces: Int? = nil,
        foldedJoinery: JoineryParameters? = nil,
        foldedSplitPanels: Bool? = nil,
        foldedSeamEdges: [Double]? = nil,
        exportFormat: ExportFormat,
        exportLayoutSettings: ExportLayoutSettings,
        modelScaleFactor: Double,
        modelTransform: [Double]? = nil,
        importUnit: ImportUnitPreset,
        importUpAxis: ImportUpAxis? = nil,
        customSliceDistributionEnabled: Bool,
        customSliceCount: Int,
        sliceSolidRenderStyle: String? = nil,
        sliceDistributionMethod: String? = nil,
        sliceByDistanceSpacingMm: Double? = nil,
        customSlicePositions: [Double]? = nil,
        modifyTool: String? = nil,
        modifyHollowWallMm: Double? = nil,
        modifyThickenMm: Double? = nil,
        modifyShrinkwrapDetail: Double? = nil,
        modifyWatertightMethod: String? = nil,
        modifyWatertightBase: Bool? = nil,
        modifyWatertightTopHeightMm: Double? = nil,
        modifyWallThicknessMm: Double? = nil,
        modifyOpeningChoices: [OpeningCapper.OpeningChoice]? = nil,
        structureSettings: StructureSettings? = nil,
        partitionSettings: PartitionSettings? = nil,
        motherMoldSettings: MotherMoldSettings? = nil,
        inflatablesSettings: InflatablesSettings? = nil
    ) {
        self.constructionMode = constructionMode
        self.sliceAxis = sliceAxis
        self.sliceTiltFirst = sliceTiltFirst
        self.sliceTiltSecond = sliceTiltSecond
        self.secondarySliceAxis = secondarySliceAxis
        self.materialThickness = materialThickness
        self.threeDSliceDepth = threeDSliceDepth
        self.slotClearance = slotClearance
        self.notchWidthOverrideEnabled = notchWidthOverrideEnabled
        self.notchWidth = notchWidth
        self.slotAngleDegrees = slotAngleDegrees
        self.radialSliceCount = radialSliceCount
        self.radialFirstAxisByDistance = radialFirstAxisByDistance
        self.radialFirstAxisCount = radialFirstAxisCount
        self.radialFirstAxisSpacing = radialFirstAxisSpacing
        self.radialNotchFactor = radialNotchFactor
        self.radialReliefType = radialReliefType
        self.radialToolDiameter = radialToolDiameter
        self.curvePrimaryAxis = curvePrimaryAxis
        self.curveFirstAxisCount = curveFirstAxisCount
        self.curveSliceCount = curveSliceCount
        self.curveAmplitude = curveAmplitude
        self.materialPreset = materialPreset
        self.slotReliefEnabled = slotReliefEnabled
        self.slotReliefDiameter = slotReliefDiameter
        self.toolDiameter = toolDiameter
        self.dowelsEnabled = dowelsEnabled
        self.dowelDiameter = dowelDiameter
        self.dowelInset = dowelInset
        self.dowelManualPositions = dowelManualPositions
        self.dowelShape = dowelShape
        self.dowelAutomaticCount = dowelAutomaticCount
        self.dowelUseAutomatic = dowelUseAutomatic
        self.foldedDetailFaces = foldedDetailFaces
        self.foldedJoinery = foldedJoinery
        self.foldedSplitPanels = foldedSplitPanels
        self.foldedSeamEdges = foldedSeamEdges
        self.exportFormat = exportFormat
        self.exportLayoutSettings = exportLayoutSettings
        self.modelScaleFactor = modelScaleFactor
        self.modelTransform = modelTransform
        self.importUnit = importUnit
        self.importUpAxis = importUpAxis
        self.customSliceDistributionEnabled = customSliceDistributionEnabled
        self.customSliceCount = customSliceCount
        self.sliceSolidRenderStyle = sliceSolidRenderStyle
        self.sliceDistributionMethod = sliceDistributionMethod
        self.sliceByDistanceSpacingMm = sliceByDistanceSpacingMm
        self.customSlicePositions = customSlicePositions
        self.modifyTool = modifyTool
        self.modifyHollowWallMm = modifyHollowWallMm
        self.modifyThickenMm = modifyThickenMm
        self.modifyShrinkwrapDetail = modifyShrinkwrapDetail
        self.modifyWatertightMethod = modifyWatertightMethod
        self.modifyWatertightBase = modifyWatertightBase
        self.modifyWatertightTopHeightMm = modifyWatertightTopHeightMm
        self.modifyWallThicknessMm = modifyWallThicknessMm
        self.modifyOpeningChoices = modifyOpeningChoices
        self.structureSettings = structureSettings
        self.partitionSettings = partitionSettings
        self.motherMoldSettings = motherMoldSettings
        self.inflatablesSettings = inflatablesSettings
    }

    var sanitized: SlicerProjectSettings {
        var copy = self
        copy.materialThickness = max(0.5, materialThickness)
        copy.threeDSliceDepth = min(max(threeDSliceDepth, 0.5), 100.0)
        copy.slotClearance = min(max(slotClearance, -2.0), 8.0)
        copy.notchWidth = min(max(notchWidth, 0.1), 50.0)
        copy.slotAngleDegrees = min(max(slotAngleDegrees, 0.0), 60.0)
        copy.radialSliceCount = min(max(radialSliceCount, 1), 72)
        if let count = radialFirstAxisCount {
            copy.radialFirstAxisCount = min(max(count, 1), 72)
        }
        if let spacing = radialFirstAxisSpacing {
            copy.radialFirstAxisSpacing = min(max(spacing, 1.0), 100.0)
        }
        if let factor = radialNotchFactor {
            copy.radialNotchFactor = min(max(factor, 0.1), 2.0)
        }
        if let td = radialToolDiameter {
            copy.radialToolDiameter = min(max(td, 0.0), 100.0)
        }
        copy.curveFirstAxisCount = min(max(curveFirstAxisCount, 1), 72)
        copy.curveSliceCount = min(max(curveSliceCount, 2), 72)
        copy.slotReliefDiameter = min(max(slotReliefDiameter, 0.5), 12.0)
        if let td = toolDiameter {
            copy.toolDiameter = min(max(td.isFinite ? td : 0, 0.0), 100.0)
        }
        copy.dowelDiameter = min(max(dowelDiameter, 1.0), 20.0)
        copy.dowelInset = min(max(dowelInset, 1.0), 40.0)
        if let count = dowelAutomaticCount {
            copy.dowelAutomaticCount = min(max(count, 1), 12)
        }
        if let detail = foldedDetailFaces {
            copy.foldedDetailFaces = min(max(detail, 12), 2000)
        }
        copy.foldedJoinery = foldedJoinery?.sanitized
        if let seams = foldedSeamEdges {
            // Drop trailing partial edges and non-finite garbage.
            let sextets = stride(from: 0, to: seams.count - seams.count % 6, by: 6)
                .map { Array(seams[$0..<($0 + 6)]) }
                .filter { $0.allSatisfy(\.isFinite) }
                .flatMap { $0 }
            copy.foldedSeamEdges = sextets.isEmpty ? nil : sextets
        }
        if let positions = dowelManualPositions {
            // Drop a trailing unpaired value and non-finite garbage.
            let pairs = stride(from: 0, to: positions.count - positions.count % 2, by: 2)
                .map { [positions[$0], positions[$0 + 1]] }
                .filter { $0.allSatisfy(\.isFinite) }
                .flatMap { $0 }
            copy.dowelManualPositions = pairs.isEmpty ? nil : pairs
        }
        copy.exportFormat = ExportFormatSupport.normalized(format: exportFormat, for: constructionMode)
        copy.sliceTiltFirst = sliceTiltFirst.map(SliceDirection.sanitized)
        copy.sliceTiltSecond = sliceTiltSecond.map(SliceDirection.sanitized)
        copy.exportLayoutSettings = exportLayoutSettings.sanitized
        copy.modelScaleFactor = MeshScaler.sanitizedFactor(modelScaleFactor)
        copy.customSliceCount = min(max(customSliceCount, 1), 240)
        // Unknown style raw values are dropped to nil so legacy files decode cleanly
        if let styleRaw = sliceSolidRenderStyle,
           SliceSolidRenderStyle(rawValue: styleRaw) == nil {
            copy.sliceSolidRenderStyle = nil
        }
        copy.structureSettings = structureSettings?.sanitized
        copy.partitionSettings = partitionSettings?.sanitized
        copy.motherMoldSettings = motherMoldSettings?.sanitized
        copy.inflatablesSettings = inflatablesSettings?.sanitized
        return copy
    }

    /// The defaults of the two technique-level tool diameters older projects
    /// carry: Radial's Tool Diameter and Interlocked's Relief diameter.
    static let legacyRadialToolDiameterDefault = 0.0
    static let legacySlotReliefDiameterDefault = 3.0

    /// The Tool Dia. this project is cut with, or nil to keep the current
    /// one.
    ///
    /// A project that saved Tool Dia. (`toolDiameter`) uses it. An older
    /// project saved a tool diameter per mode instead; one of those is
    /// carried over when its relief was turned on (Radial: a Relief Type
    /// other than Square; Interlocked: Slot relief) or when it differs from
    /// its default (Radial 0 mm, Interlocked 3 mm), so the project cuts the
    /// relief it cut before. When both qualify, the project's own mode
    /// wins, then Radial's. When neither does, nil.
    var resolvedToolDiameter: Double? {
        if let toolDiameter { return toolDiameter }
        let radialDiameter = radialToolDiameter ?? Self.legacyRadialToolDiameterDefault
        let radialReliefOn = radialReliefType
            .flatMap(RadialReliefType.init(rawValue:))?.requiresToolDiameter ?? false
        let radial: Double? = radialReliefOn || radialDiameter != Self.legacyRadialToolDiameterDefault
            ? radialDiameter : nil
        let interlocked: Double? = slotReliefEnabled || slotReliefDiameter != Self.legacySlotReliefDiameterDefault
            ? slotReliefDiameter : nil
        return constructionMode == .interlocked ? (interlocked ?? radial) : (radial ?? interlocked)
    }
}

private extension SlicerProjectSettings {
    enum CodingKeys: String, CodingKey {
        case constructionMode
        case sliceAxis
        case sliceTiltFirst
        case sliceTiltSecond
        case secondarySliceAxis
        case materialThickness
        case threeDSliceDepth
        case slotClearance
        case notchWidthOverrideEnabled
        case notchWidth
        case slotAngleDegrees
        case radialSliceCount
        case radialFirstAxisByDistance
        case radialFirstAxisCount
        case radialFirstAxisSpacing
        case radialNotchFactor
        case radialReliefType
        case radialToolDiameter
        case curvePrimaryAxis
        case curveFirstAxisCount
        case curveSliceCount
        case curveAmplitude
        case materialPreset
        case slotReliefEnabled
        case slotReliefDiameter
        case toolDiameter
        case dowelsEnabled
        case dowelDiameter
        case dowelInset
        case dowelManualPositions
        case dowelShape
        case dowelAutomaticCount
        case dowelUseAutomatic
        case foldedDetailFaces
        case foldedJoinery
        case foldedSplitPanels
        case foldedSeamEdges
        case exportFormat
        case exportLayoutSettings
        case modelScaleFactor
        case modelTransform
        case importUnit
        case importUpAxis
        case customSliceDistributionEnabled
        case customSliceCount
        case sliceSolidRenderStyle
        case sliceDistributionMethod
        case sliceByDistanceSpacingMm
        case customSlicePositions
        case modifyTool
        case modifyHollowWallMm
        case modifyThickenMm
        case modifyShrinkwrapDetail
        case modifyWatertightMethod
        case modifyWatertightBase
        case modifyWatertightTopHeightMm
        case modifyWallThicknessMm
        case modifyOpeningChoices
        case structureSettings
        case partitionSettings
        case motherMoldSettings
        case inflatablesSettings
    }
}

extension SlicerProjectSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            constructionMode: try container.decode(ConstructionMode.self, forKey: .constructionMode),
            sliceAxis: try container.decode(SliceAxis.self, forKey: .sliceAxis),
            sliceTiltFirst: try container.decodeIfPresent(Double.self, forKey: .sliceTiltFirst),
            sliceTiltSecond: try container.decodeIfPresent(Double.self, forKey: .sliceTiltSecond),
            secondarySliceAxis: try container.decode(SliceAxis.self, forKey: .secondarySliceAxis),
            materialThickness: try container.decode(Double.self, forKey: .materialThickness),
            threeDSliceDepth: try container.decodeIfPresent(Double.self, forKey: .threeDSliceDepth) ?? 10.0,
            slotClearance: try container.decode(Double.self, forKey: .slotClearance),
            notchWidthOverrideEnabled: try container.decodeIfPresent(Bool.self, forKey: .notchWidthOverrideEnabled) ?? false,
            notchWidth: try container.decodeIfPresent(Double.self, forKey: .notchWidth) ?? 3.0,
            slotAngleDegrees: try container.decode(Double.self, forKey: .slotAngleDegrees),
            radialSliceCount: try container.decode(Int.self, forKey: .radialSliceCount),
            radialFirstAxisByDistance: try container.decodeIfPresent(Bool.self, forKey: .radialFirstAxisByDistance),
            radialFirstAxisCount: try container.decodeIfPresent(Int.self, forKey: .radialFirstAxisCount),
            radialFirstAxisSpacing: try container.decodeIfPresent(Double.self, forKey: .radialFirstAxisSpacing),
            radialNotchFactor: try container.decodeIfPresent(Double.self, forKey: .radialNotchFactor),
            radialReliefType: try container.decodeIfPresent(String.self, forKey: .radialReliefType),
            radialToolDiameter: try container.decodeIfPresent(Double.self, forKey: .radialToolDiameter),
            curvePrimaryAxis: try container.decodeIfPresent(SliceAxis.self, forKey: .curvePrimaryAxis) ?? .y,
            curveFirstAxisCount: try container.decodeIfPresent(Int.self, forKey: .curveFirstAxisCount) ?? 7,
            curveSliceCount: try container.decode(Int.self, forKey: .curveSliceCount),
            curveAmplitude: try container.decode(Double.self, forKey: .curveAmplitude),
            materialPreset: try container.decode(MaterialPreset.self, forKey: .materialPreset),
            slotReliefEnabled: try container.decode(Bool.self, forKey: .slotReliefEnabled),
            slotReliefDiameter: try container.decode(Double.self, forKey: .slotReliefDiameter),
            toolDiameter: try container.decodeIfPresent(Double.self, forKey: .toolDiameter),
            dowelsEnabled: try container.decode(Bool.self, forKey: .dowelsEnabled),
            dowelDiameter: try container.decode(Double.self, forKey: .dowelDiameter),
            dowelInset: try container.decode(Double.self, forKey: .dowelInset),
            dowelManualPositions: try container.decodeIfPresent([Double].self, forKey: .dowelManualPositions),
            dowelShape: try container.decodeIfPresent(String.self, forKey: .dowelShape),
            dowelAutomaticCount: try container.decodeIfPresent(Int.self, forKey: .dowelAutomaticCount),
            dowelUseAutomatic: try container.decodeIfPresent(Bool.self, forKey: .dowelUseAutomatic),
            foldedDetailFaces: try container.decodeIfPresent(Int.self, forKey: .foldedDetailFaces),
            foldedJoinery: try container.decodeIfPresent(JoineryParameters.self, forKey: .foldedJoinery),
            foldedSplitPanels: try container.decodeIfPresent(Bool.self, forKey: .foldedSplitPanels),
            foldedSeamEdges: try container.decodeIfPresent([Double].self, forKey: .foldedSeamEdges),
            exportFormat: try container.decode(ExportFormat.self, forKey: .exportFormat),
            exportLayoutSettings: try container.decode(ExportLayoutSettings.self, forKey: .exportLayoutSettings),
            modelScaleFactor: try container.decode(Double.self, forKey: .modelScaleFactor),
            modelTransform: try container.decodeIfPresent([Double].self, forKey: .modelTransform),
            importUnit: try container.decode(ImportUnitPreset.self, forKey: .importUnit),
            importUpAxis: try container.decodeIfPresent(ImportUpAxis.self, forKey: .importUpAxis),
            customSliceDistributionEnabled: try container.decode(Bool.self, forKey: .customSliceDistributionEnabled),
            customSliceCount: try container.decode(Int.self, forKey: .customSliceCount),
            sliceSolidRenderStyle: try container.decodeIfPresent(String.self, forKey: .sliceSolidRenderStyle),
            sliceDistributionMethod: try container.decodeIfPresent(String.self, forKey: .sliceDistributionMethod),
            sliceByDistanceSpacingMm: try container.decodeIfPresent(Double.self, forKey: .sliceByDistanceSpacingMm),
            customSlicePositions: try container.decodeIfPresent([Double].self, forKey: .customSlicePositions),
            modifyTool: try container.decodeIfPresent(String.self, forKey: .modifyTool),
            modifyHollowWallMm: try container.decodeIfPresent(Double.self, forKey: .modifyHollowWallMm),
            modifyThickenMm: try container.decodeIfPresent(Double.self, forKey: .modifyThickenMm),
            modifyShrinkwrapDetail: try container.decodeIfPresent(Double.self, forKey: .modifyShrinkwrapDetail),
            modifyWatertightMethod: try container.decodeIfPresent(String.self, forKey: .modifyWatertightMethod),
            modifyWatertightBase: try container.decodeIfPresent(Bool.self, forKey: .modifyWatertightBase),
            modifyWatertightTopHeightMm: try container.decodeIfPresent(Double.self, forKey: .modifyWatertightTopHeightMm),
            modifyWallThicknessMm: try container.decodeIfPresent(Double.self, forKey: .modifyWallThicknessMm),
            modifyOpeningChoices: try container.decodeIfPresent([OpeningCapper.OpeningChoice].self, forKey: .modifyOpeningChoices),
            structureSettings: try container.decodeIfPresent(StructureSettings.self, forKey: .structureSettings),
            partitionSettings: try container.decodeIfPresent(PartitionSettings.self, forKey: .partitionSettings),
            motherMoldSettings: try container.decodeIfPresent(MotherMoldSettings.self, forKey: .motherMoldSettings),
            inflatablesSettings: try container.decodeIfPresent(InflatablesSettings.self, forKey: .inflatablesSettings)
        )
    }
}
