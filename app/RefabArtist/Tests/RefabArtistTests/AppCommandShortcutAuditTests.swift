import Testing
@testable import RefabArtist

struct AppCommandShortcutAuditTests {
    @Test
    func fileMenuShortcutsMatchMacConventions() {
        #expect(SlicerAppShortcut.importModel == SlicerKeyboardShortcut("o", modifiers: [.command, .shift]))
        #expect(SlicerAppShortcut.loadSampleModel == SlicerKeyboardShortcut("o", modifiers: [.command, .option]))
        #expect(SlicerAppShortcut.openProject == SlicerKeyboardShortcut("o", modifiers: [.command]))
        #expect(SlicerAppShortcut.saveProject == SlicerKeyboardShortcut("s", modifiers: [.command]))
        #expect(SlicerAppShortcut.exportCurrent == SlicerKeyboardShortcut("e", modifiers: [.command]))
        #expect(SlicerAppShortcut.exportAssemblyGuide == SlicerKeyboardShortcut("e", modifiers: [.command, .shift]))
        // NEO-109: Print cut sheets (Cmd+P — system standard)
        #expect(SlicerAppShortcut.printSheets == SlicerKeyboardShortcut("p", modifiers: [.command]))
    }

    @Test
    func viewShortcutsUseNumberRowAndOptionAlternates() {
        #expect(SlicerAppShortcut.toggleSidebar == SlicerKeyboardShortcut("s", modifiers: [.command, .option]))
        #expect(SlicerAppShortcut.showModelView == SlicerKeyboardShortcut("1", modifiers: [.command]))
        #expect(SlicerAppShortcut.showSheetPreview == SlicerKeyboardShortcut("2", modifiers: [.command]))
        #expect(SlicerAppShortcut.showCombinedView == SlicerKeyboardShortcut("3", modifiers: [.command]))
        #expect(SlicerAppShortcut.previewModelOnly == SlicerKeyboardShortcut("1", modifiers: [.command, .option]))
        #expect(SlicerAppShortcut.previewSlicesOnly == SlicerKeyboardShortcut("2", modifiers: [.command, .option]))
        #expect(SlicerAppShortcut.previewModelAndSlices == SlicerKeyboardShortcut("3", modifiers: [.command, .option]))
    }

    @Test
    func auditedShortcutsHaveNoDuplicateBindings() {
        let shortcuts = SlicerAppShortcut.auditedBindings.map(\.shortcut)
        let uniqueShortcuts = Set(shortcuts)

        #expect(uniqueShortcuts.count == shortcuts.count)
    }

    @Test
    func auditedCommandsHaveUniqueNames() {
        let commandNames = SlicerAppShortcut.auditedBindings.map(\.commandName)
        let uniqueCommandNames = Set(commandNames)

        #expect(uniqueCommandNames.count == commandNames.count)
    }

    @Test
    func everyAuditedShortcutUsesCommandModifier() {
        let missingCommandModifier = SlicerAppShortcut.auditedBindings.filter { binding in
            !binding.shortcut.modifiers.contains(.command)
        }

        #expect(missingCommandModifier.isEmpty)
    }
}
