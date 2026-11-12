import Foundation
import Testing
@testable import RefabArtist

struct UndoHistoryTests {
    @Test
    func recordUndoRedoRoundTrip() {
        var history = UndoHistory<Int>()
        let t = Date(timeIntervalSinceReferenceDate: 0)
        history.record(1, at: t)                            // state went 1 -> 2
        history.record(2, at: t.addingTimeInterval(5))      // state went 2 -> 3
        #expect(history.canUndo)
        #expect(!history.canRedo)

        let undone = history.undo(current: 3)
        #expect(undone == 2)
        #expect(history.canRedo)

        let redone = history.redo(current: 2)
        #expect(redone == 3)
        #expect(history.canUndo)
    }

    @Test
    func burstsCoalesceIntoOneStep() {
        var history = UndoHistory<Int>()
        let t = Date(timeIntervalSinceReferenceDate: 100)
        // A slider drag: many incremental changes inside the window.
        history.record(10, at: t)
        history.record(11, at: t.addingTimeInterval(0.1))
        history.record(12, at: t.addingTimeInterval(0.2))
        #expect(history.undoStack.count == 1)
        // One undo returns to the pre-burst state.
        #expect(history.undo(current: 13) == 10)
        #expect(!history.canUndo)
    }

    @Test
    func slowBurstKeepsCoalescingWhileChangesKeepComing() {
        var history = UndoHistory<Int>()
        let t = Date(timeIntervalSinceReferenceDate: 0)
        // Each change refreshes the burst clock: 0.5s apart with a 0.8s
        // window stays one step no matter how long the drag lasts.
        for i in 0..<10 {
            history.record(i, at: t.addingTimeInterval(Double(i) * 0.5))
        }
        #expect(history.undoStack.count == 1)
    }

    @Test
    func newRecordClearsRedoEvenWithinABurst() {
        var history = UndoHistory<Int>()
        let t = Date(timeIntervalSinceReferenceDate: 0)
        history.record(1, at: t)
        _ = history.undo(current: 2)
        #expect(history.canRedo)
        // A fresh edit right away (could land within a coalescing window).
        history.record(1, at: t.addingTimeInterval(0.1))
        #expect(!history.canRedo)
    }

    @Test
    func undoBreaksTheBurstSoTheNextEditIsItsOwnStep() {
        var history = UndoHistory<Int>()
        let t = Date(timeIntervalSinceReferenceDate: 0)
        history.record(1, at: t)
        _ = history.undo(current: 2)
        history.record(1, at: t.addingTimeInterval(0.1))
        #expect(history.undoStack.count == 1)
        history.record(5, at: t.addingTimeInterval(0.2))
        // Still within the window of the previous record — coalesces.
        #expect(history.undoStack.count == 1)
        history.record(7, at: t.addingTimeInterval(2.0))
        #expect(history.undoStack.count == 2)
    }

    @Test
    func depthLimitDropsOldestSteps()  {
        var history = UndoHistory<Int>()
        history.depthLimit = 3
        var t = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<6 {
            t = t.addingTimeInterval(10)
            history.record(i, at: t)
        }
        #expect(history.undoStack == [3, 4, 5])
    }

    @Test
    func resetDropsEverything() {
        var history = UndoHistory<Int>()
        history.record(1, at: Date(timeIntervalSinceReferenceDate: 0))
        _ = history.undo(current: 2)
        history.reset()
        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }
}
