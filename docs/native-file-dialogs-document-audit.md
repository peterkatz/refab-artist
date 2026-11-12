# Native File Dialogs + Document Architecture Audit

Issue: P5.2 / NEO-42
Date: 2026-06-02

## Summary

Refab Artist already uses native AppKit panels for the current file workflows. This audit keeps that behavior, centralizes the dialog type contracts, and records why a full SwiftUI `DocumentGroup` migration should be deferred until the app has an explicit document model with dirty-state tracking.

## Dialog Coverage

| Workflow | Native panel | Type contract | Current behavior |
| --- | --- | --- | --- |
| Import model | `NSOpenPanel` | `.stl`, `.obj` | Single file only, no directories, loads mesh into the active window. |
| Open project | `NSOpenPanel` | `.refabartist`, and the earlier `.slicerrebuild`, as JSON-conforming UTTypes | Reads the saved settings file, then re-inspects the referenced model path. |
| Save project | `NSSavePanel` | `.refabartist` as JSON-conforming UTType | Writes `SlicerProjectDocument` JSON atomically. |
| Export output | `NSSavePanel` | Active `ExportFormat` extension | Writes the selected DXF/EPS/PDF/SVG/OBJ/STL output. |
| Export assembly guide | `NSSavePanel` | `.txt` / `public.plain-text` | Writes a plain-text assembly guide. |
| Headless export | No UI panel | CLI paths | Uses explicit `--fixture` and `--output` paths for automation and gate workflows. |

## Change Made

`FileDialogTypes` now owns the file-dialog UTTypes used by the app. That keeps the native panel filters testable and prevents ad-hoc `UTType(filenameExtension:) ?? .data` fallbacks from spreading through view code.

The project file type is intentionally created from the `.refabartist` extension with JSON conformance. The file remains a plain JSON payload, but the native open/save panels can filter and name it as a project document instead of a generic data file. Projects saved before the app was renamed use the `.slicerrebuild` extension; their contents are the same, so the Open panel accepts both (`FileDialogTypes.projectOpen`).

## Document Architecture Decision

Do not migrate to SwiftUI `DocumentGroup` / `FileDocument` yet.

Reasons:

- `SlicerProjectDocument` stores settings plus an absolute model path; it is not the app's source-of-truth document state.
- The active window state lives in `ContentView` `@State`, not in an observable document controller.
- The app does not yet track dirty state, current project URL, autosave, duplicate/revert, recent documents, or sandbox security-scoped bookmarks.
- Exports are derived artifacts, not documents. They should stay explicit save-panel flows.
- Headless export and the gate tooling depend on explicit filesystem paths and should remain outside document-window behavior.

## Recommended Next Architecture Step

If document architecture is taken beyond this audit, introduce a document controller around a single app state model before adopting `DocumentGroup`. The minimum safe shape is:

- `SlicerProjectState`: observable state for model URL, scale/unit, construction parameters, export settings, viewport selection, and dirty flag.
- `SlicerProjectDocument`: persistence wrapper that serializes the state and stores model references as security-scoped bookmarks or a packaged relative asset.
- App commands from P5.1 should call controller actions rather than private view methods once that controller exists.
- Save/open panels should update current document URL and dirty state; export panels should remain one-shot derived-output actions.

Until that state split exists, the current native panels are the correct implementation level.
