import SwiftUI

struct SlicerCommandActions {
    /// NEO-114: snapshot undo/redo over project state. The handlers forward
    /// to a focused text field's own undo first, so the menu items stay
    /// enabled whenever a window is up (standard macOS behavior).
    var undo: () -> Void
    var redo: () -> Void
    var importModel: () -> Void
    var loadSampleModel: () -> Void
    var openProject: () -> Void
    var saveProject: () -> Void
    var exportCurrent: () -> Void
    var exportAssemblyGuide: () -> Void
    /// Print… (Cmd+P): NSPrintOperation on the cut sheets rendered via the
    /// existing PDF exporter, with a Print Range + Rotate By accessory
    /// (NEO-109).
    var printSheets: () -> Void
    /// Export Sliced Mesh… (its own menu item): the
    /// panelized 3D mesh of the folded model as OBJ/STL, distinct from the
    /// 2D cut plans (NEO-104).
    var exportSlicedMesh: () -> Void
    var toggleSidebar: () -> Void
    var showModelView: () -> Void
    var showSheetPreview: () -> Void
    var showCombinedView: () -> Void
    var previewModelOnly: () -> Void
    var previewSlicesOnly: () -> Void
    var previewModelAndSlices: () -> Void
    var canSaveProject: Bool
    var canExport: Bool
    var canExportAssemblyGuide: Bool
    var canPrint: Bool
    var canExportSlicedMesh: Bool
    var canShowSheetPreview: Bool
    var hasModel: Bool
    var canUndo: Bool
    var canRedo: Bool
}

struct SlicerKeyboardModifiers: OptionSet, Hashable {
    let rawValue: Int

    static let command = SlicerKeyboardModifiers(rawValue: 1 << 0)
    static let option = SlicerKeyboardModifiers(rawValue: 1 << 1)
    static let shift = SlicerKeyboardModifiers(rawValue: 1 << 2)
    static let control = SlicerKeyboardModifiers(rawValue: 1 << 3)

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if contains(.command) {
            modifiers.insert(.command)
        }
        if contains(.option) {
            modifiers.insert(.option)
        }
        if contains(.shift) {
            modifiers.insert(.shift)
        }
        if contains(.control) {
            modifiers.insert(.control)
        }
        return modifiers
    }
}

struct SlicerKeyboardShortcut: Equatable, Hashable {
    var character: Character
    var modifiers: SlicerKeyboardModifiers

    init(_ character: Character, modifiers: SlicerKeyboardModifiers) {
        self.character = character
        self.modifiers = modifiers
    }
}

struct SlicerKeyboardShortcutBinding: Equatable {
    var commandName: String
    var shortcut: SlicerKeyboardShortcut
}

enum SlicerAppShortcut {
    static let undo = SlicerKeyboardShortcut("z", modifiers: [.command])
    static let redo = SlicerKeyboardShortcut("z", modifiers: [.command, .shift])
    static let importModel = SlicerKeyboardShortcut("o", modifiers: [.command, .shift])
    static let loadSampleModel = SlicerKeyboardShortcut("o", modifiers: [.command, .option])
    static let openProject = SlicerKeyboardShortcut("o", modifiers: [.command])
    static let saveProject = SlicerKeyboardShortcut("s", modifiers: [.command])
    static let exportCurrent = SlicerKeyboardShortcut("e", modifiers: [.command])
    static let exportAssemblyGuide = SlicerKeyboardShortcut("e", modifiers: [.command, .shift])
    static let printSheets = SlicerKeyboardShortcut("p", modifiers: [.command])
    static let toggleSidebar = SlicerKeyboardShortcut("s", modifiers: [.command, .option])
    static let showModelView = SlicerKeyboardShortcut("1", modifiers: [.command])
    static let showSheetPreview = SlicerKeyboardShortcut("2", modifiers: [.command])
    static let showCombinedView = SlicerKeyboardShortcut("3", modifiers: [.command])
    static let previewModelOnly = SlicerKeyboardShortcut("1", modifiers: [.command, .option])
    static let previewSlicesOnly = SlicerKeyboardShortcut("2", modifiers: [.command, .option])
    static let previewModelAndSlices = SlicerKeyboardShortcut("3", modifiers: [.command, .option])

    static let auditedBindings: [SlicerKeyboardShortcutBinding] = [
        SlicerKeyboardShortcutBinding(commandName: "Undo", shortcut: undo),
        SlicerKeyboardShortcutBinding(commandName: "Redo", shortcut: redo),
        SlicerKeyboardShortcutBinding(commandName: "Import Model", shortcut: importModel),
        SlicerKeyboardShortcutBinding(commandName: "Load Sample Model", shortcut: loadSampleModel),
        SlicerKeyboardShortcutBinding(commandName: "Open Project", shortcut: openProject),
        SlicerKeyboardShortcutBinding(commandName: "Save Project", shortcut: saveProject),
        SlicerKeyboardShortcutBinding(commandName: "Export Current Output", shortcut: exportCurrent),
        SlicerKeyboardShortcutBinding(commandName: "Export Assembly Guide", shortcut: exportAssemblyGuide),
        SlicerKeyboardShortcutBinding(commandName: "Print Cut Sheets", shortcut: printSheets),
        SlicerKeyboardShortcutBinding(commandName: "Toggle Sidebar", shortcut: toggleSidebar),
        SlicerKeyboardShortcutBinding(commandName: "Show 3D View", shortcut: showModelView),
        SlicerKeyboardShortcutBinding(commandName: "Show Sheet Preview", shortcut: showSheetPreview),
        SlicerKeyboardShortcutBinding(commandName: "Show 3D and Sheet", shortcut: showCombinedView),
        SlicerKeyboardShortcutBinding(commandName: "Preview Model Only", shortcut: previewModelOnly),
        SlicerKeyboardShortcutBinding(commandName: "Preview Generated Slices", shortcut: previewSlicesOnly),
        SlicerKeyboardShortcutBinding(commandName: "Preview Model and Slices", shortcut: previewModelAndSlices)
    ]
}

private struct SlicerCommandActionsKey: FocusedValueKey {
    typealias Value = SlicerCommandActions
}

extension FocusedValues {
    var slicerCommandActions: SlicerCommandActions? {
        get { self[SlicerCommandActionsKey.self] }
        set { self[SlicerCommandActionsKey.self] = newValue }
    }
}

struct SlicerAppCommands: Commands {
    @FocusedValue(\.slicerCommandActions) private var actions

    var body: some Commands {
        // NEO-114: project-state Undo/Redo. Enabled whenever the app has
        // actions wired — the handler routes ⌘Z to a focused text field's
        // own undo before touching project history, so text editing keeps
        // its standard behavior.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                actions?.undo()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.undo)
            .disabled(actions == nil)

            Button("Redo") {
                actions?.redo()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.redo)
            .disabled(actions == nil)
        }

        CommandGroup(replacing: .newItem) {
            Button("Import Model...") {
                actions?.importModel()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.importModel)
            .disabled(actions == nil)

            Button("Load Sample Model") {
                actions?.loadSampleModel()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.loadSampleModel)
            .disabled(actions == nil)

            Divider()

            Button("Open Project...") {
                actions?.openProject()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.openProject)
            .disabled(actions == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Project...") {
                actions?.saveProject()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.saveProject)
            .disabled(actions?.canSaveProject != true)

            Divider()

            Button("Export Current Output...") {
                actions?.exportCurrent()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.exportCurrent)
            .disabled(actions?.canExport != true)

            Button("Export Assembly Guide...") {
                actions?.exportAssemblyGuide()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.exportAssemblyGuide)
            .disabled(actions?.canExportAssemblyGuide != true)

            Divider()

            // NEO-109: Print… (Cmd+P) — prints the cut sheets via
            // NSPrintOperation on the PDF rendered by CutSheetDocumentExporter.
            // Enabled only when a cut sheet is ready (sliced + vector layout).
            Button("Print\u{2026}") {
                actions?.printSheets()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.printSheets)
            .disabled(actions?.canPrint != true)

            // NEO-104: "Export Sliced Mesh…" — the folded
            // model's panelized 3D mesh (OBJ/STL), separate from cut plans.
            Button("Export Sliced Mesh\u{2026}") {
                actions?.exportSlicedMesh()
            }
            .disabled(actions?.canExportSlicedMesh != true)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                actions?.toggleSidebar()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.toggleSidebar)
            .disabled(actions == nil)

            Divider()

            Button("Show 3D View") {
                actions?.showModelView()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.showModelView)
            .disabled(actions?.hasModel != true)

            Button("Show Sheet Preview") {
                actions?.showSheetPreview()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.showSheetPreview)
            .disabled(actions?.canShowSheetPreview != true)

            Button("Show 3D and Sheet") {
                actions?.showCombinedView()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.showCombinedView)
            .disabled(actions?.canShowSheetPreview != true)

            Divider()

            Button("Preview Model Only") {
                actions?.previewModelOnly()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.previewModelOnly)
            .disabled(actions?.hasModel != true)

            Button("Preview Generated Slices") {
                actions?.previewSlicesOnly()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.previewSlicesOnly)
            .disabled(actions?.hasModel != true)

            Button("Preview Model and Slices") {
                actions?.previewModelAndSlices()
            }
            .slicerKeyboardShortcut(SlicerAppShortcut.previewModelAndSlices)
            .disabled(actions?.hasModel != true)
        }
    }
}

private extension View {
    func slicerKeyboardShortcut(_ shortcut: SlicerKeyboardShortcut) -> some View {
        keyboardShortcut(KeyEquivalent(shortcut.character), modifiers: shortcut.modifiers.eventModifiers)
    }
}
