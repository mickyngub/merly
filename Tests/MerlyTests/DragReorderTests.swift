import XCTest
@testable import Merly

final class DragReorderTests: XCTestCase {
    private let ids = ["a", "b", "c", "d"]
    private let heights: [String: CGFloat] = ["a": 90, "b": 90, "c": 90, "d": 90]

    func testCrossesSlotBoundariesInBothDirections() throws {
        var down = try XCTUnwrap(DragReorder(id: "b", orderedIDs: ids, heights: heights, spacing: 10))
        down.update(translation: 56)
        XCTAssertEqual(down.insertionIndex, 1)
        down.update(translation: 57)
        XCTAssertEqual(down.orderedIDs, ["a", "c", "b", "d"])

        var up = try XCTUnwrap(DragReorder(id: "c", orderedIDs: ids, heights: heights, spacing: 10))
        up.update(translation: -56)
        XCTAssertEqual(up.insertionIndex, 2)
        up.update(translation: -57)
        XCTAssertEqual(up.orderedIDs, ["a", "c", "b", "d"])
    }

    func testFullOutAndBackRestoresOriginalOrderAndOffset() throws {
        var drag = try XCTUnwrap(DragReorder(id: "b", orderedIDs: ids, heights: heights, spacing: 10))
        drag.update(translation: 250)
        XCTAssertEqual(drag.orderedIDs, ["a", "c", "d", "b"])
        drag.update(translation: -200)
        XCTAssertEqual(drag.orderedIDs, ["b", "a", "c", "d"])
        drag.update(translation: 0)
        XCTAssertEqual(drag.orderedIDs, ids)
        XCTAssertEqual(drag.offset, 0)
    }

    func testFastUpdatesCrossSeveralSlotsAtOnce() throws {
        var drag = try XCTUnwrap(DragReorder(id: "a", orderedIDs: ids, heights: heights, spacing: 10))
        drag.update(translation: 300)
        XCTAssertEqual(drag.insertionIndex, 3)
        XCTAssertEqual(drag.orderedIDs, ["b", "c", "d", "a"])
        drag.update(translation: 0)
        XCTAssertEqual(drag.insertionIndex, 0)
        XCTAssertEqual(drag.orderedIDs, ids)
    }

    func testStationaryUpdatesAndBoundaryHysteresisDoNotOscillate() throws {
        var drag = try XCTUnwrap(DragReorder(id: "b", orderedIDs: ids, heights: heights, spacing: 10))
        drag.update(translation: 57)
        let moved = drag
        for _ in 0..<20 {
            drag.update(translation: 57)
            XCTAssertEqual(drag, moved)
        }
        drag.update(translation: 50)
        XCTAssertEqual(drag.insertionIndex, 2)
        drag.update(translation: 44)
        XCTAssertEqual(drag.insertionIndex, 2)
        drag.update(translation: 43)
        XCTAssertEqual(drag.insertionIndex, 1)
        drag.update(translation: 50)
        XCTAssertEqual(drag.insertionIndex, 1)
    }

    func testVariableHeightsPreserveVisualTopThroughEveryMove() throws {
        let variableHeights: [String: CGFloat] = ["a": 30, "b": 180, "c": 70, "d": 120]
        var drag = try XCTUnwrap(DragReorder(
            id: "b", orderedIDs: ids, heights: variableHeights, spacing: 10
        ))
        XCTAssertEqual(drag.originalTop, 40)
        for translation in [25, 46, 120, 210, -30, -100, 0] as [CGFloat] {
            drag.update(translation: translation)
            XCTAssertEqual(drag.slotTop + drag.offset, drag.originalTop + translation, accuracy: 0.0001)
        }
        XCTAssertEqual(drag.orderedIDs, ids)
        drag.update(translation: 47)
        XCTAssertEqual(drag.insertionIndex, 2)
        XCTAssertEqual(drag.slotTop, 120)
        XCTAssertEqual(drag.offset, -33)
    }

    func testSmallSlotsUseProportionalHysteresis() throws {
        var drag = try XCTUnwrap(DragReorder(
            id: "a", orderedIDs: ["a", "b"], heights: ["a": 10, "b": 10], spacing: 0
        ))
        drag.update(translation: 6)
        XCTAssertEqual(drag.insertionIndex, 0)
        drag.update(translation: 6.1)
        XCTAssertEqual(drag.insertionIndex, 1)
        drag.update(translation: 4)
        XCTAssertEqual(drag.insertionIndex, 1)
        drag.update(translation: 3.9)
        XCTAssertEqual(drag.insertionIndex, 0)
    }

    func testBoundsRetainPointerOffsetOutsideList() throws {
        var drag = try XCTUnwrap(DragReorder(id: "b", orderedIDs: ids, heights: heights, spacing: 10))
        drag.update(translation: 10_000)
        XCTAssertEqual(drag.insertionIndex, ids.count - 1)
        XCTAssertEqual(drag.slotTop + drag.offset, 10_100)
        drag.update(translation: -10_000)
        XCTAssertEqual(drag.insertionIndex, 0)
        XCTAssertEqual(drag.slotTop + drag.offset, -9_900)
    }

    func testSingleCardCannotChangeInsertionIndex() throws {
        var drag = try XCTUnwrap(DragReorder(
            id: "a", orderedIDs: ["a"], heights: ["a": 90], spacing: 10
        ))
        drag.update(translation: 200)
        XCTAssertEqual(drag.orderedIDs, ["a"])
        XCTAssertEqual(drag.insertionIndex, 0)
        XCTAssertEqual(drag.offset, 200)
    }

    func testInvalidGeometryAndIdentitiesAreRejected() {
        XCTAssertNil(DragReorder(id: "missing", orderedIDs: ids, heights: heights, spacing: 10))
        XCTAssertNil(DragReorder(id: "a", orderedIDs: [], heights: heights, spacing: 10))
        XCTAssertNil(DragReorder(id: "a", orderedIDs: ["a", "a"], heights: heights, spacing: 10))
        XCTAssertNil(DragReorder(id: "a", orderedIDs: ids, heights: ["a": 90], spacing: 10))
        for invalidHeight in [0, -1, .infinity, -.infinity, .nan] as [CGFloat] {
            var invalidHeights = heights
            invalidHeights["b"] = invalidHeight
            XCTAssertNil(DragReorder(id: "a", orderedIDs: ids, heights: invalidHeights, spacing: 10))
        }
        for invalidSpacing in [-1, .infinity, -.infinity, .nan] as [CGFloat] {
            XCTAssertNil(DragReorder(id: "a", orderedIDs: ids, heights: heights, spacing: invalidSpacing))
        }
        XCTAssertNil(DragReorder(
            id: "a", orderedIDs: ["a", "b", "c"],
            heights: ["a": 90, "b": .greatestFiniteMagnitude, "c": .greatestFiniteMagnitude],
            spacing: 0
        ))
    }

    func testNonfiniteTranslationAndDesiredTopOverflowAreIgnored() throws {
        var drag = try XCTUnwrap(DragReorder(id: "b", orderedIDs: ids, heights: heights, spacing: 10))
        drag.update(translation: 57)
        let moved = drag
        for invalidTranslation in [.infinity, -.infinity, .nan] as [CGFloat] {
            drag.update(translation: invalidTranslation)
            XCTAssertEqual(drag, moved)
        }

        var overflowing = try XCTUnwrap(DragReorder(
            id: "b", orderedIDs: ["a", "b"],
            heights: ["a": .greatestFiniteMagnitude, "b": 90], spacing: 0
        ))
        let original = overflowing
        overflowing.update(translation: .greatestFiniteMagnitude)
        XCTAssertEqual(overflowing, original)
    }
}
