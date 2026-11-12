import Testing
@testable import RefabArtist

/// Every dowel add/move/delete transition, proven without a running view.
struct DowelEditingTests {
    // A square material region covering [-50,50] in both axes.
    private static func coversSquare(_ p: Vec2) -> Bool {
        abs(p.x) <= 50 && abs(p.y) <= 50
    }

    // MARK: - Add

    @Test func addPlacesARodWhereMaterialCovers() {
        let result = DowelEditing.add(Vec2(x: 10, y: 10), to: [], threshold: 6, covers: Self.coversSquare)
        #expect(result == [Vec2(x: 10, y: 10)])
    }

    @Test func addRejectedOffMaterial() {
        let result = DowelEditing.add(Vec2(x: 80, y: 0), to: [], threshold: 6, covers: Self.coversSquare)
        #expect(result == nil)
    }

    @Test func addRejectedOnTopOfExistingRod() {
        let existing = [Vec2(x: 0, y: 0)]
        // Within threshold (6mm) of the existing rod → rejected, no duplicate.
        let result = DowelEditing.add(Vec2(x: 3, y: 0), to: existing, threshold: 6, covers: Self.coversSquare)
        #expect(result == nil)
    }

    @Test func addJustOutsideThresholdSucceeds() {
        let existing = [Vec2(x: 0, y: 0)]
        let result = DowelEditing.add(Vec2(x: 7, y: 0), to: existing, threshold: 6, covers: Self.coversSquare)
        #expect(result?.count == 2)
    }

    // MARK: - Remove

    @Test func removeTakesTheNearestRodNotTheFirst() {
        // Two rods within threshold of the click; the NEAREST must go.
        let rods = [Vec2(x: 5, y: 0), Vec2(x: 1, y: 0)]
        let result = DowelEditing.remove(near: Vec2(x: 0, y: 0), from: rods, threshold: 8)
        #expect(result == [Vec2(x: 5, y: 0)])
    }

    @Test func removeRejectedWhenNothingNear() {
        let rods = [Vec2(x: 40, y: 40)]
        let result = DowelEditing.remove(near: Vec2(x: 0, y: 0), from: rods, threshold: 6)
        #expect(result == nil)
    }

    @Test func removingTheLastRodLeavesAnEmptyListThatStaysEmpty() {
        // The NEO-113 bug: deleting the last rod must NOT resurrect automatic.
        // Here the result is the authoritative empty manual list.
        let result = DowelEditing.remove(near: Vec2(x: 0, y: 0), from: [Vec2(x: 0, y: 0)], threshold: 6)
        #expect(result == [])
    }

    // MARK: - Move

    @Test func moveRelocatesTheGrabbedRod() {
        let rods = [Vec2(x: 0, y: 0), Vec2(x: 30, y: 0)]
        let result = DowelEditing.move(from: Vec2(x: 1, y: 0), to: Vec2(x: -20, y: 10),
                                       in: rods, threshold: 6, covers: Self.coversSquare)
        #expect(result == [Vec2(x: -20, y: 10), Vec2(x: 30, y: 0)])
    }

    @Test func moveRejectedIntoEmptyAir() {
        let rods = [Vec2(x: 0, y: 0)]
        let result = DowelEditing.move(from: Vec2(x: 0, y: 0), to: Vec2(x: 90, y: 90),
                                       in: rods, threshold: 6, covers: Self.coversSquare)
        #expect(result == nil) // off-material target → no change, rod doesn't vanish
    }

    @Test func moveRejectedWhenNoRodGrabbed() {
        let rods = [Vec2(x: 40, y: 40)]
        let result = DowelEditing.move(from: Vec2(x: 0, y: 0), to: Vec2(x: 10, y: 10),
                                       in: rods, threshold: 6, covers: Self.coversSquare)
        #expect(result == nil)
    }

    @Test func moveGrabsNearestRod() {
        let rods = [Vec2(x: 5, y: 0), Vec2(x: 1, y: 0)]
        let result = DowelEditing.move(from: Vec2(x: 0, y: 0), to: Vec2(x: 0, y: 20),
                                       in: rods, threshold: 8, covers: Self.coversSquare)
        // The nearest (1,0) moved; (5,0) untouched.
        #expect(result == [Vec2(x: 5, y: 0), Vec2(x: 0, y: 20)])
    }

    // MARK: - Full session

    @Test func addMoveDeleteSequenceIsCoherent() {
        var rods: [Vec2] = []
        rods = DowelEditing.add(Vec2(x: 0, y: 0), to: rods, threshold: 6, covers: Self.coversSquare) ?? rods
        rods = DowelEditing.add(Vec2(x: 20, y: 0), to: rods, threshold: 6, covers: Self.coversSquare) ?? rods
        rods = DowelEditing.add(Vec2(x: -20, y: 0), to: rods, threshold: 6, covers: Self.coversSquare) ?? rods
        #expect(rods.count == 3)
        rods = DowelEditing.move(from: Vec2(x: 20, y: 0), to: Vec2(x: 20, y: 30), in: rods, threshold: 6, covers: Self.coversSquare) ?? rods
        #expect(rods.contains(Vec2(x: 20, y: 30)))
        rods = DowelEditing.remove(near: Vec2(x: 0, y: 0), from: rods, threshold: 6) ?? rods
        rods = DowelEditing.remove(near: Vec2(x: -20, y: 0), from: rods, threshold: 6) ?? rods
        rods = DowelEditing.remove(near: Vec2(x: 20, y: 30), from: rods, threshold: 6) ?? rods
        #expect(rods.isEmpty) // deleted all; stays empty
    }
}
