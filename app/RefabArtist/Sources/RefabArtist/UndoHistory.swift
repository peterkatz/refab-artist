import Foundation

/// Snapshot-based undo/redo with time-window coalescing (NEO-114).
///
/// Generic over the snapshot type so the mechanics are unit-testable without
/// ContentView. The caller records the state as it was BEFORE each change;
/// undo/redo exchange the current state for a stacked one.
///
/// Coalescing: a burst of changes (a slider drag is dozens of onChange
/// events) becomes ONE undo step — the first change in a burst records the
/// pre-burst snapshot; later changes within `coalescingWindow` only refresh
/// the burst clock (and still clear the redo stack, since any edit
/// invalidates redo).
struct UndoHistory<Snapshot> {
    private(set) var undoStack: [Snapshot] = []
    private(set) var redoStack: [Snapshot] = []
    private var lastRecordTime: Date?
    var coalescingWindow: TimeInterval = 0.8
    var depthLimit = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Record the state as it was BEFORE a change happening at `now`.
    mutating func record(_ before: Snapshot, at now: Date = Date()) {
        defer { lastRecordTime = now }
        redoStack.removeAll()
        if let last = lastRecordTime, now.timeIntervalSince(last) < coalescingWindow {
            return // same burst — its pre-state is already on the stack
        }
        undoStack.append(before)
        if undoStack.count > depthLimit {
            undoStack.removeFirst(undoStack.count - depthLimit)
        }
    }

    /// Pop the snapshot to restore, banking `current` for redo. The next
    /// record after an undo always starts a fresh burst.
    mutating func undo(current: Snapshot) -> Snapshot? {
        guard let snapshot = undoStack.popLast() else { return nil }
        redoStack.append(current)
        lastRecordTime = nil
        return snapshot
    }

    mutating func redo(current: Snapshot) -> Snapshot? {
        guard let snapshot = redoStack.popLast() else { return nil }
        undoStack.append(current)
        lastRecordTime = nil
        return snapshot
    }

    /// Drop all history (model import / project open — new baseline).
    mutating func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastRecordTime = nil
    }
}
