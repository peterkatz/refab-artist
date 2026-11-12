import Foundation
import Testing
import UniformTypeIdentifiers
@testable import RefabArtist

struct SlicerProjectDocumentTests {
    @Test
    func projectDocumentRoundTripsSettings() throws {
        let document = SlicerProjectDocument(
            modelPath: "/fixtures/cube.stl",
            settings: SlicerProjectSettings.sample
        )

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(SlicerProjectDocument.self, from: data)

        #expect(decoded == document)
        #expect(decoded.version == SlicerProjectDocument.currentVersion)
    }

    /// Projects save as .refabartist; ones saved under the earlier
    /// .slicerrebuild extension still show up in the Open panel.
    @Test
    func projectsSaveUnderTheNewExtensionAndStillOpenTheEarlierOne() {
        #expect(SlicerProjectDocument.fileExtension == "refabartist")
        #expect(FileDialogTypes.project.preferredFilenameExtension == "refabartist")
        #expect(FileDialogTypes.projectOpen.compactMap(\.preferredFilenameExtension) == ["refabartist", "slicerrebuild"])
        #expect(FileDialogTypes.projectOpen.allSatisfy { $0.conforms(to: .json) })
    }

    @Test
    func partitionSettingsRoundTripAndStayOptionalForLegacyFiles() throws {
        var settings = SlicerProjectSettings.sample
        settings.constructionMode = .partition
        var partition = PartitionSettings.defaultValue
        partition.buildVolume = PrinterVolume(width: 180, depth: 180, height: 180)
        partition.bedMargin = 4
        partition.key.type = .pins
        partition.key.tolerance = 0.3
        partition.packaging = .separateZip
        partition.manualPlanes = [PartitionPlane(normal: Vec3(x: 0, y: 0, z: 1), offset: 22, isManual: true)]
        settings.partitionSettings = partition

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SlicerProjectSettings.self, from: data)
        #expect(decoded.partitionSettings == partition)

        // Legacy projects (saved before Partition existed) have no field and
        // must still decode, leaving partitionSettings nil.
        #expect(SlicerProjectSettings.sample.partitionSettings == nil)
    }

    @Test
    func modifyFormFieldsRoundTripAndStayOptionalForLegacyFiles() throws {
        var settings = SlicerProjectSettings.sample
        settings.modifyTool = ModifyFormTool.shrinkwrap.rawValue
        settings.modifyHollowWallMm = 4.5
        settings.modifyThickenMm = 1.5
        settings.modifyShrinkwrapDetail = 0.7
        let document = SlicerProjectDocument(modelPath: "/fixtures/cube.stl", settings: settings)

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(SlicerProjectDocument.self, from: data)
        #expect(decoded.settings.modifyTool == "shrinkwrap")
        #expect(decoded.settings.modifyHollowWallMm == 4.5)
        #expect(decoded.settings.modifyThickenMm == 1.5)
        #expect(decoded.settings.modifyShrinkwrapDetail == 0.7)

        // Legacy files without the fields decode to nil (no active tool).
        let legacy = SlicerProjectDocument(modelPath: "/fixtures/cube.stl", settings: SlicerProjectSettings.sample)
        let legacyData = try JSONEncoder().encode(legacy)
        var json = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        var settingsJSON = try #require(json["settings"] as? [String: Any])
        settingsJSON.removeValue(forKey: "modifyTool")
        settingsJSON.removeValue(forKey: "modifyHollowWallMm")
        settingsJSON.removeValue(forKey: "modifyThickenMm")
        json["settings"] = settingsJSON
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decodedLegacy = try JSONDecoder().decode(SlicerProjectDocument.self, from: stripped)
        #expect(decodedLegacy.settings.modifyTool == nil)
        #expect(decodedLegacy.settings.modifyHollowWallMm == nil)
    }

    @Test
    func openingChoicesRoundTripAndStayOptionalForLegacyFiles() throws {
        var settings = SlicerProjectSettings.sample
        let top = OpeningCapper.OpeningSignature(center: Vec3(x: 0, y: -148.2, z: 94.8), diameter: 151.6, normal: Vec3(x: 0, y: 0, z: 1))
        let bottom = OpeningCapper.OpeningSignature(center: Vec3(x: 0, y: -148.2, z: -30.2), diameter: 151.6, normal: Vec3(x: 0, y: 0, z: -1))
        let choices = [
            OpeningCapper.OpeningChoice(signature: top, leaveOpen: false, topHeight: 10, closedInWalls: false),
            OpeningCapper.OpeningChoice(signature: bottom, leaveOpen: true, topHeight: nil, closedInWalls: true),
        ]
        settings.modifyOpeningChoices = choices
        let document = SlicerProjectDocument(modelPath: "/fixtures/cube.stl", settings: settings)
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(SlicerProjectDocument.self, from: data)
        #expect(decoded.settings.modifyOpeningChoices == choices)

        // Legacy files (no field) decode to nil: every opening follows the
        // global controls, as before.
        #expect(SlicerProjectSettings.sample.modifyOpeningChoices == nil)
        let legacyData = try JSONEncoder().encode(SlicerProjectDocument(modelPath: "/fixtures/cube.stl", settings: .sample))
        let json = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        let settingsJSON = try #require(json["settings"] as? [String: Any])
        #expect(settingsJSON["modifyOpeningChoices"] == nil)
        let decodedLegacy = try JSONDecoder().decode(SlicerProjectDocument.self, from: legacyData)
        #expect(decodedLegacy.settings.modifyOpeningChoices == nil)
    }

    @Test
    func importUpAxisRoundTripsAndStaysOptionalForLegacyFiles() throws {
        var settings = SlicerProjectSettings.sample
        settings.importUpAxis = .y
        let document = SlicerProjectDocument(modelPath: "/fixtures/cube.stl", settings: settings)

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(SlicerProjectDocument.self, from: data)
        #expect(decoded.settings.importUpAxis == .y)

        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var settingsJSON = try #require(json["settings"] as? [String: Any])
        settingsJSON.removeValue(forKey: "importUpAxis")
        json["settings"] = settingsJSON
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decodedLegacy = try JSONDecoder().decode(SlicerProjectDocument.self, from: stripped)
        #expect(decodedLegacy.settings.importUpAxis == nil)
    }

    @Test
    func settingsSanitizeInvalidValuesAndUnsupportedExportFormat() {
        var settings = SlicerProjectSettings.sample
        settings.constructionMode = .interlocked
        settings.exportFormat = .stl
        settings.materialThickness = -1
        settings.threeDSliceDepth = 999
        settings.slotClearance = 100
        settings.notchWidth = 99
        settings.slotAngleDegrees = 99
        settings.radialSliceCount = 0
        settings.radialFirstAxisCount = 999
        settings.radialFirstAxisSpacing = 0.01
        settings.radialNotchFactor = 9
        settings.curveSliceCount = 99
        settings.modelScaleFactor = .nan
        settings.customSliceCount = 999

        let sanitized = settings.sanitized

        #expect(sanitized.exportFormat == .stl)
        #expect(sanitized.materialThickness == 0.5)
        #expect(sanitized.threeDSliceDepth == 100.0)
        #expect(sanitized.slotClearance == 8.0)
        #expect(sanitized.notchWidth == 50.0)
        #expect(sanitized.slotAngleDegrees == 60.0)
        #expect(sanitized.radialSliceCount == 1)
        #expect(sanitized.radialFirstAxisCount == 72)
        #expect(sanitized.radialFirstAxisSpacing == 1.0)
        #expect(sanitized.radialNotchFactor == 2.0)
        #expect(sanitized.curveSliceCount == 72)
        #expect(sanitized.modelScaleFactor == 1.0)
        #expect(sanitized.customSliceCount == 240)

        settings.radialNotchFactor = 0.01
        #expect(settings.sanitized.radialNotchFactor == 0.1)
    }

    @Test
    func settingsDecodeProjectFilesWithoutNotchWidthFields() throws {
        let encoded = """
        {
          "constructionMode": "interlocked",
          "sliceAxis": "z",
          "secondarySliceAxis": "x",
          "materialThickness": 3,
          "slotClearance": 0.15,
          "slotAngleDegrees": 12,
          "radialSliceCount": 16,
          "curveSliceCount": 10,
          "curveAmplitude": 8,
          "materialPreset": "plywood3mm",
          "slotReliefEnabled": true,
          "slotReliefDiameter": 3,
          "dowelsEnabled": true,
          "dowelDiameter": 4,
          "dowelInset": 8,
          "exportFormat": "svg",
          "exportLayoutSettings": {
            "partSpacing": 5,
            "pageMargin": 10,
            "sheetWidth": 600,
            "sheetHeight": 300
          },
          "modelScaleFactor": 1.25,
          "importUnit": "centimeters",
          "customSliceDistributionEnabled": true,
          "customSliceCount": 18
        }
        """

        let decoded = try JSONDecoder().decode(SlicerProjectSettings.self, from: Data(encoded.utf8))

        #expect(decoded.notchWidthOverrideEnabled == false)
        #expect(decoded.notchWidth == 3.0)
        #expect(decoded.threeDSliceDepth == 10.0)
        #expect(decoded.radialFirstAxisByDistance == nil)
        #expect(decoded.radialNotchFactor == nil)
        #expect(decoded.radialReliefType == nil)
        // Projects saved before Structures existed have no structureSettings key.
        #expect(decoded.structureSettings == nil)
    }

    // MARK: - Tool Dia. (one tool diameter)

    @Test
    func toolDiameterRoundTripsAndWinsOverTheOlderPerModeDiameters() throws {
        var settings = SlicerProjectSettings.sample
        settings.toolDiameter = 3.175
        settings.radialToolDiameter = 6
        settings.slotReliefDiameter = 2
        let decoded = try JSONDecoder().decode(
            SlicerProjectSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded.toolDiameter == 3.175)
        #expect(decoded.resolvedToolDiameter == 3.175)
    }

    @Test
    func olderProjectsCarryTheirPerModeToolDiameterOver() {
        // An Interlocked project with Slot relief on keeps its relief
        // diameter, even at the 3 mm default, so it cuts what it cut before.
        var interlocked = SlicerProjectSettings.sample
        interlocked.constructionMode = .interlocked
        interlocked.toolDiameter = nil
        interlocked.slotReliefEnabled = true
        interlocked.slotReliefDiameter = 3
        interlocked.radialToolDiameter = nil
        #expect(interlocked.resolvedToolDiameter == 3)

        // Its own mode's diameter wins over Radial's.
        interlocked.radialToolDiameter = 6.35
        #expect(interlocked.resolvedToolDiameter == 3)

        // A Radial project with a relief type keeps its tool, even 0 (it
        // cut no relief, and still does not).
        var radial = interlocked
        radial.constructionMode = .radial
        radial.radialReliefType = RadialReliefType.dogBone.rawValue
        radial.radialToolDiameter = 0
        #expect(radial.resolvedToolDiameter == 0)

        // Relief off everywhere: only a diameter that differs from its
        // default carries over.
        var stacked = SlicerProjectSettings.sample
        stacked.toolDiameter = nil
        stacked.slotReliefEnabled = false
        stacked.slotReliefDiameter = 3
        stacked.radialReliefType = nil
        stacked.radialToolDiameter = nil
        #expect(stacked.resolvedToolDiameter == nil)
        stacked.slotReliefDiameter = 4.5
        #expect(stacked.resolvedToolDiameter == 4.5)
        stacked.radialToolDiameter = 2
        #expect(stacked.resolvedToolDiameter == 2)
    }

    // MARK: - Structures persistence + migration

    @Test
    func structureSettingsRoundTripNewSchema() throws {
        var settings = SlicerProjectSettings.sample
        settings.structureSettings = StructureSettings(
            category: .infill,
            pattern: .gyroidLofted,
            parameters: InfillParameters(cellSizeMm: 12, wallThicknessMm: 2.4, gyroidBand: 0.8, seed: 7),
            density: StructureDensitySettings(
                source: .image,
                minCellMm: 4,
                maxCellMm: 18,
                imagePath: "/tmp/density.png",
                imageProjection: .yz,
                invertImage: true
            )
        )
        let document = SlicerProjectDocument(modelPath: "/fixtures/cube.stl", settings: settings)

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(SlicerProjectDocument.self, from: data)
        let s = try #require(decoded.settings.structureSettings)
        #expect(s.category == .infill)
        #expect(s.pattern == .gyroidLofted)
        #expect(s.parameters.cellSizeMm == 12)
        #expect(s.parameters.wallThicknessMm == 2.4)
        #expect(s.parameters.gyroidBand == 0.8)
        #expect(s.parameters.seed == 7)
        #expect(s.density.source == .image)
        #expect(s.density.minCellMm == 4)
        #expect(s.density.maxCellMm == 18)
        #expect(s.density.imagePath == "/tmp/density.png")
        #expect(s.density.imageProjection == .yz)
        #expect(s.density.invertImage == true)
    }

    @Test
    func structureSettingsMissingParametersFallsBackToDefaults() throws {
        // A new-schema blob that omits `parameters` entirely.
        let encoded = """
        { "category": "infill", "patternV2": "triangle" }
        """
        let decoded = try JSONDecoder().decode(StructureSettings.self, from: Data(encoded.utf8))
        #expect(decoded.category == .infill)
        #expect(decoded.pattern == .triangle)
        #expect(decoded.parameters == InfillParameters.defaultValue)
    }

    @Test
    func structureSettingsLegacyGyroidMigratesToLofted() throws {
        // A new-schema blob saved before the single 3D-marching-cubes "gyroid" was
        // split into Lofted/Tiled must migrate to the Lofted generator so saved
        // projects keep a working TPMS infill.
        let encoded = """
        { "category": "infill", "patternV2": "gyroid" }
        """
        let decoded = try JSONDecoder().decode(StructureSettings.self, from: Data(encoded.utf8))
        #expect(decoded.category == .infill)
        #expect(decoded.pattern == .gyroidLofted)
    }

    @Test
    func structureSettingsMissingKeyDecodesToDefaultValue() throws {
        // A project file that has no `structureSettings` key at all.
        let document = SlicerProjectDocument(
            modelPath: "/fixtures/cube.stl",
            settings: SlicerProjectSettings.sample
        )
        let data = try JSONEncoder().encode(document)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var settingsJSON = try #require(json["settings"] as? [String: Any])
        settingsJSON.removeValue(forKey: "structureSettings")
        json["settings"] = settingsJSON
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(SlicerProjectDocument.self, from: stripped)
        #expect(decoded.settings.structureSettings == nil)
    }

    /// MERGE-BLOCKING migration proof: an OLD-format StructureSettings payload
    /// (the deleted façade schema — intent/family/supportClass/placementMode/
    /// sourceMeshRole/shellRelationship/presetID/includeSourceMesh and a legacy
    /// `pattern` whose rawValue does not exist in the new `InfillPattern`) must
    /// DECODE without throwing and fall back to `.triangle` + defaults.
    @Test
    func oldFacadeStructureSettingsDecodesWithoutCrashing() throws {
        let oldBlob = """
        {
          "intent": "internalLattice",
          "placementMode": "fillVolume",
          "family": "ribLamella",
          "supportClass": "artSupport",
          "pattern": "honeycomb",
          "presetID": "porousSkinFine",
          "includeSourceMesh": true,
          "sourceMeshRole": "shell",
          "shellRelationship": "subtractive",
          "memberScale": 0.42,
          "density": 0.7,
          "irregularity": 0.3
        }
        """
        // Must not throw.
        let decoded = try JSONDecoder().decode(StructureSettings.self, from: Data(oldBlob.utf8))
        // Legacy `pattern: "honeycomb"` has no new mapping → falls back to triangle.
        #expect(decoded.pattern == .triangle)
        // Legacy lacked a `category` key → defaults to infill.
        #expect(decoded.category == .infill)
        // Legacy lacked new `parameters` → defaults.
        #expect(decoded.parameters == InfillParameters.defaultValue)
    }

    /// The same old façade payload nested inside a full project-settings blob must
    /// also decode (the path real saved projects take through SlicerProjectDocument).
    @Test
    func projectWithOldFacadeStructureSettingsDecodes() throws {
        let encoded = """
        {
          "constructionMode": "stacked",
          "sliceAxis": "z",
          "secondarySliceAxis": "x",
          "materialThickness": 3,
          "slotClearance": 0.15,
          "slotAngleDegrees": 12,
          "radialSliceCount": 16,
          "curveSliceCount": 10,
          "curveAmplitude": 8,
          "materialPreset": "plywood3mm",
          "slotReliefEnabled": true,
          "slotReliefDiameter": 3,
          "dowelsEnabled": true,
          "dowelDiameter": 4,
          "dowelInset": 8,
          "exportFormat": "svg",
          "exportLayoutSettings": {
            "partSpacing": 5, "pageMargin": 10, "sheetWidth": 600, "sheetHeight": 300
          },
          "modelScaleFactor": 1.0,
          "importUnit": "millimeters",
          "customSliceDistributionEnabled": false,
          "customSliceCount": 18,
          "structureSettings": {
            "intent": "artSupport",
            "family": "voronoi",
            "pattern": "gyroidSheet",
            "supportClass": "tree",
            "includeSourceMesh": false
          }
        }
        """
        let decoded = try JSONDecoder().decode(SlicerProjectSettings.self, from: Data(encoded.utf8))
        let s = try #require(decoded.structureSettings)
        #expect(s.pattern == .triangle)
        #expect(s.category == .infill)
        #expect(s.parameters == InfillParameters.defaultValue)
    }

    @Test
    func structureSettingsSanitizeClampsParameters() throws {
        var settings = SlicerProjectSettings.sample
        settings.structureSettings = StructureSettings(
            category: .infill,
            pattern: .triangle,
            parameters: InfillParameters(cellSizeMm: 9999, wallThicknessMm: 0.0, gyroidBand: 9.0, seed: 1)
        )
        let s = try #require(settings.sanitized.structureSettings)
        #expect(s.parameters.cellSizeMm == 200.0)
        #expect(s.parameters.wallThicknessMm == 0.2)
        #expect(s.parameters.gyroidBand == 2.0)
    }

    @Test
    func structureDensitySettingsDecodeTolerantlyAndSanitize() throws {
        let encoded = """
        {
          "category": "infill",
          "patternV2": "triangle",
          "parameters": { "cellSizeMm": 12 },
          "density": {
            "densitySource": "image",
            "minCellMm": 999,
            "maxCellMm": 0,
            "imagePath": "  /tmp/ramp.png  ",
            "imageProjection": "yz",
            "invertImage": true,
            "falloffMm": 9999,
            "nearSurfaceBandMm": -10
          }
        }
        """
        let decoded = try JSONDecoder().decode(StructureSettings.self, from: Data(encoded.utf8))
        let sanitized = decoded.sanitized

        #expect(sanitized.density.source == .image)
        #expect(sanitized.density.minCellMm == 1)
        #expect(sanitized.density.maxCellMm == 200)
        #expect(sanitized.density.imagePath == "/tmp/ramp.png")
        #expect(sanitized.density.imageProjection == .yz)
        #expect(sanitized.density.invertImage == true)
        #expect(sanitized.density.falloffMm == 500)
        #expect(sanitized.density.nearSurfaceBandMm == 1)

        var uniform = decoded
        uniform.density.source = .uniform
        let uniformSanitized = uniform.sanitized
        #expect(uniformSanitized.density.minCellMm == 12)
        #expect(uniformSanitized.density.maxCellMm == 12)
    }

    @Test
    func supportSettingsDecodeTolerantly() throws {
        // A partial payload with one junk enum must keep every recognizable field
        // — the synthesized decoder used to throw and silently reset ALL support
        // settings to defaults.
        let encoded = """
        {
          "supportMode": "bogusFutureMode",
          "tipSpacingMm": 9.5,
          "maxAngleDeg": 35,
          "contactOffsetMm": 0.7,
          "restPreference": "unknownValue",
          "futureKey": true
        }
        """
        let decoded = try JSONDecoder().decode(SupportSettings.self, from: Data(encoded.utf8))
        #expect(decoded.supportMode == .sculpture)
        #expect(decoded.tipSpacingMm == 9.5)
        #expect(decoded.maxAngleDeg == 35)
        #expect(decoded.contactOffsetMm == 0.7)
        #expect(decoded.restPreference == .plateOnly)
        #expect(decoded.tipDiameterMm == SupportSettings.defaultValue.tipDiameterMm)
    }

    @Test
    func skinSettingsDecodeTolerantlyAndSanitize() throws {
        let encoded = """
        {
          "skinStyle": "futureStyle",
          "skinPattern": "triangles",
          "strutDiameterMm": 99,
          "ribWidthMm": 0.1,
          "futureKey": true
        }
        """
        let decoded = try JSONDecoder().decode(SkinSettings.self, from: Data(encoded.utf8))
        #expect(decoded.skinStyle == .struts)
        #expect(decoded.skinPattern == .triangles)
        let sanitized = decoded.sanitized
        #expect(sanitized.strutDiameterMm == 10)
        #expect(sanitized.ribWidthMm == 0.5)
    }
}

private extension SlicerProjectSettings {
    static let sample = SlicerProjectSettings(
        constructionMode: .stacked,
        sliceAxis: .z,
        secondarySliceAxis: .x,
        materialThickness: 3.0,
        threeDSliceDepth: 10.0,
        slotClearance: 0.15,
        notchWidthOverrideEnabled: true,
        notchWidth: 3.25,
        slotAngleDegrees: 12.0,
        radialSliceCount: 16,
        curveSliceCount: 10,
        curveAmplitude: 8.0,
        materialPreset: .plywood3mm,
        slotReliefEnabled: true,
        slotReliefDiameter: 3.0,
        dowelsEnabled: true,
        dowelDiameter: 4.0,
        dowelInset: 8.0,
        exportFormat: .svg,
        exportLayoutSettings: .defaultValue,
        modelScaleFactor: 1.25,
        importUnit: .centimeters,
        customSliceDistributionEnabled: true,
        customSliceCount: 18
    )
}
