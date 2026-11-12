import Foundation
import Testing
@testable import RefabArtist

struct MotherMoldArtistUXM2CopyContractTests {
    @Test
    func mostTouchedTooltipsMatchTheArtistBriefVerbatim() {
        let expected: [(MotherMoldHelp.Field, String)] = [
            (.parts, "How many rigid pieces you'll pull apart to release the cast. Two is right for most models; four helps deep or wrap-around shapes."),
            (.partingMode, "Auto picks the split direction that demolds most cleanly. Manual lets you set each split plane yourself — you'll see the plane on the model as you adjust it."),
            (.partingAxis, "The direction the two sides pull apart. The plane on the model shows exactly where the seam will fall."),
            (.partingOffset, "Slides the split plane along its axis. Watch the plane on the model — the seam lands where the plane crosses the surface."),
            (.wallThickness, "Thickness of the printed shell. 4 mm suits most desktop prints; go thicker for big molds or heavy pours."),
            (.siliconeClearance, "How thick the silicone layer around your model will be. Thicker is stronger and uses more silicone; 6 mm suits most sculpture."),
            (.softening, "Smooths fine surface detail out of the shell cavity so the silicone — not the printed shell — captures it. Raise it if the shell fights demolding."),
            (.flatFloor, "Adds a flat base so the mold stands upright on the bench."),
            (.keyType, "Bumps and pockets along the seam that snap the parts into alignment — like the keys on a plaster mold. Tapered so they seat without forcing."),
            (.keySize, "Size of each key. Bigger keys align more positively but need a wider seam face."),
            (.keyDepth, "How far each key engages. Refab Artist shortens a key rather than punching through a thin wall."),
            (.keyTolerance, "Extra space around each key pocket so printed parts seat. Raise it if your printer runs tight; too much lets the halves shift."),
            (.matingFlange, "A flat rim along the seam with bolt holes, so the halves clamp shut against the pour. Without it, use straps or tape."),
            (.boltCount, "Through-holes for bolts or zip ties. Zero leaves the rim solid."),
            (.spoutMode, "Where the casting material goes in. Auto puts the funnel at the highest point of the mold; Manual lets you click a spot on the model."),
            (.spoutDiameter, "Width of the fill channel. Wider pours faster and suits thick materials; it leaves a bigger mark to trim off the cast."),
            (.ventCount, "Small holes at high points that let air escape while you pour. Without them, trapped air leaves voids in the cast."),
            (.masterFixture, "How your printed model is held steady while silicone cures around it. The printed socket grips its base; or hold it yourself with a stem or clay bed."),
            (.socketDepth, "How far the socket rises around the model's base. Deeper grips better but covers more of the lower surface."),
            (.socketFit, "Space between model and socket. Snug locates precisely; loose inserts easily but can wobble."),
            (.packaging, "How the printable files are grouped: one ZIP of STLs, one OBJ with named parts, or all parts laid out in a single STL."),
            (.assemblyGuide, "Writes a step-by-step guide: assembling, clamping, sealing, pouring, curing, and demolding."),
            (.buildButton, "Builds the mold parts from these settings and shows them in 3D. Nothing recomputes while you adjust — press when ready."),
        ]

        for (field, copy) in expected {
            #expect(field.text == copy)
        }
    }

    @Test
    func artistFacingLabelsUseCastingLanguage() throws {
        #expect(MoldSubtype.slipShell.label == "Rigid mold")
        #expect(MoldSubtype.siliconeJacket.label == "Silicone mold + shell")
        #expect(MasterMountMode.flatBaseSocket.label == "Printed base socket")
        #expect(MasterMountMode.externalFixture.label == "I'll hold it myself")

        let source = try contentViewSource()
        for required in [
            "sliderRow(\"Silicone thickness\"",
            "sliderRow(\"Detail softening\"",
            "sliderRow(\"Fit clearance\"",
            "stepperRow(\"Keys per seam\"",
            "Toggle(\"Clamping rim\"",
            "stepperRow(\"Bolt holes\"",
            "controlRow(\"Pour hole\"",
            "Picker(\"Pour hole mode\"",
            "sliderRow(\"Pour hole Ø\"",
            "controlRow(\"Master holder\"",
            "Label(\"Hold it myself\"",
        ] {
            #expect(source.contains(required))
        }
    }

    @Test
    func buildButtonAndOneOffReadinessUseTheSpecifiedCopy() throws {
        let source = try contentViewSource()
        #expect(source.contains(".help(MotherMoldHelp.Field.buildButton.text)"))
        #expect(source.contains("readiness.title(forProductionTooling: settings.usesReusableToolingContract)"))
        #expect(source.contains("case .blocked: return \"Blocked\""))
        #expect(source.contains("return \"Ready to print\""))

        let blocked = MotherMoldUIContract.PackageReadiness.blocked("reason")
        let ready = MotherMoldUIContract.PackageReadiness.geometryOnly("detail")
        #expect(blocked.title(forProductionTooling: false) == "Blocked")
        #expect(ready.title(forProductionTooling: false) == "Ready to print")
        #expect(blocked.title(forProductionTooling: true) == "Package blocked")
        #expect(ready.title(forProductionTooling: true) == "Package ready - geometry only")
    }

    private func contentViewSource() throws -> String {
        let source = Self.repoRoot()
            .appending(path: "app/RefabArtist/Sources/RefabArtist/ContentView.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appending(path: "docs/PRD.md").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
