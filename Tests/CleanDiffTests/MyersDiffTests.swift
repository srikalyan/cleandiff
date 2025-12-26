import XCTest
@testable import CleanDiffCore

final class MyersDiffTests: XCTestCase {

    var diffEngine: MyersDiff!

    override func setUp() {
        super.setUp()
        diffEngine = MyersDiff()
    }

    func testEmptyInputs() {
        let result = diffEngine.diff(left: [], right: [])
        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertFalse(result.hasChanges)
    }

    func testIdenticalInputs() {
        let lines = ["line 1", "line 2", "line 3"]
        let result = diffEngine.diff(left: lines, right: lines)

        XCTAssertFalse(result.hasChanges)
        XCTAssertEqual(result.insertions, 0)
        XCTAssertEqual(result.deletions, 0)
    }

    func testSimpleInsertion() {
        let left = ["line 1", "line 3"]
        let right = ["line 1", "line 2", "line 3"]

        let result = diffEngine.diff(left: left, right: right)

        XCTAssertTrue(result.hasChanges)
        XCTAssertEqual(result.insertions, 1)
        XCTAssertEqual(result.deletions, 0)
    }

    func testSimpleDeletion() {
        let left = ["line 1", "line 2", "line 3"]
        let right = ["line 1", "line 3"]

        let result = diffEngine.diff(left: left, right: right)

        XCTAssertTrue(result.hasChanges)
        XCTAssertEqual(result.insertions, 0)
        XCTAssertEqual(result.deletions, 1)
    }

    func testReplacement() {
        let left = ["line 1", "old line", "line 3"]
        let right = ["line 1", "new line", "line 3"]

        let result = diffEngine.diff(left: left, right: right)

        XCTAssertTrue(result.hasChanges)
        XCTAssertEqual(result.modifications, 1)
    }

    func testCompleteReplacement() {
        let left = ["a", "b", "c"]
        let right = ["x", "y", "z"]

        let result = diffEngine.diff(left: left, right: right)

        XCTAssertTrue(result.hasChanges)
    }

    func testInsertAtBeginning() {
        let left = ["line 2", "line 3"]
        let right = ["line 1", "line 2", "line 3"]

        let result = diffEngine.diff(left: left, right: right)

        XCTAssertTrue(result.hasChanges)
        XCTAssertEqual(result.insertions, 1)
    }

    func testInsertAtEnd() {
        let left = ["line 1", "line 2"]
        let right = ["line 1", "line 2", "line 3"]

        let result = diffEngine.diff(left: left, right: right)

        XCTAssertTrue(result.hasChanges)
        XCTAssertEqual(result.insertions, 1)
    }

    func testIgnoreWhitespace() {
        let options = MyersDiff.Options(ignoreWhitespace: true)
        let diffEngine = MyersDiff(options: options)

        let left = ["  line 1  ", "line 2"]
        let right = ["line 1", "line 2"]

        let result = diffEngine.diff(left: left, right: right)

        // With whitespace ignored, lines should match
        XCTAssertFalse(result.hasChanges)
    }

    func testIgnoreCase() {
        let options = MyersDiff.Options(ignoreCase: true)
        let diffEngine = MyersDiff(options: options)

        let left = ["LINE 1", "line 2"]
        let right = ["line 1", "LINE 2"]

        let result = diffEngine.diff(left: left, right: right)

        // With case ignored, lines should match
        XCTAssertFalse(result.hasChanges)
    }
}

final class ThreeWayDiffTests: XCTestCase {

    var diffEngine: MyersDiff!

    override func setUp() {
        super.setUp()
        diffEngine = MyersDiff()
    }

    func testNoConflicts() {
        let base = ["line 1", "line 2", "line 3"]
        let left = ["line 1", "modified by left", "line 3"]
        let right = base  // No changes on right

        let result = diffEngine.diff3(base: base, left: left, right: right)

        XCTAssertFalse(result.hasConflicts)
    }

    func testConflictingChanges() {
        let base = ["line 1", "line 2", "line 3"]
        let left = ["line 1", "left change", "line 3"]
        let right = ["line 1", "right change", "line 3"]

        let result = diffEngine.diff3(base: base, left: left, right: right)

        XCTAssertTrue(result.hasConflicts)
    }
}
