import XCTest
@testable import CleanDiffCore

/// End-to-end integration tests for the diff engine
final class IntegrationTests: XCTestCase {

    var diffEngine: MyersDiff!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        diffEngine = MyersDiff()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - End-to-End File Diff Tests

    func testDiffRealFiles() throws {
        // Create test files
        let leftContent = """
        line 1
        line 2
        line 3
        """

        let rightContent = """
        line 1
        modified line 2
        line 3
        line 4
        """

        let leftFile = tempDir.appendingPathComponent("left.txt")
        let rightFile = tempDir.appendingPathComponent("right.txt")

        try leftContent.write(to: leftFile, atomically: true, encoding: .utf8)
        try rightContent.write(to: rightFile, atomically: true, encoding: .utf8)

        // Read and diff
        let leftLines = try String(contentsOf: leftFile, encoding: .utf8).components(separatedBy: .newlines)
        let rightLines = try String(contentsOf: rightFile, encoding: .utf8).components(separatedBy: .newlines)

        let result = diffEngine.diff(left: leftLines, right: rightLines)

        XCTAssertTrue(result.hasChanges)
        XCTAssertGreaterThan(result.chunks.count, 0)
    }

    func testDiffEmptyFile() throws {
        let leftContent = ""
        let rightContent = "new content"

        let leftLines = leftContent.isEmpty ? [] : leftContent.components(separatedBy: .newlines)
        let rightLines = rightContent.components(separatedBy: .newlines)

        let result = diffEngine.diff(left: leftLines, right: rightLines)

        XCTAssertTrue(result.hasChanges)
        XCTAssertEqual(result.insertions, 1)
    }

    func testDiffLargeFile() {
        // Generate large files (1000 lines)
        let leftLines = (0..<1000).map { "line \($0)" }
        var rightLines = leftLines

        // Modify some lines in the middle
        rightLines[500] = "modified line 500"
        rightLines[501] = "modified line 501"
        rightLines.insert("inserted line", at: 250)
        rightLines.remove(at: 750)

        let result = diffEngine.diff(left: leftLines, right: rightLines)

        XCTAssertTrue(result.hasChanges)
        XCTAssertGreaterThan(result.modifications + result.insertions + result.deletions, 0)
    }

    func testDiffWithUnicodeContent() {
        let leftLines = ["Hello World", "Emoji: 🎉", "Japanese: 日本語"]
        let rightLines = ["Hello World", "Emoji: 🎊", "Japanese: 日本語", "Chinese: 中文"]

        let result = diffEngine.diff(left: leftLines, right: rightLines)

        XCTAssertTrue(result.hasChanges)
    }

    func testDiffWithWhitespaceVariations() {
        let options = MyersDiff.Options(ignoreWhitespace: true)
        let diffEngine = MyersDiff(options: options)

        let leftLines = ["  hello  ", "\tworld\t"]
        let rightLines = ["hello", "world"]

        let result = diffEngine.diff(left: leftLines, right: rightLines)

        XCTAssertFalse(result.hasChanges, "With ignoreWhitespace, these should be equal")
    }

    // MARK: - Three-Way Merge Tests

    func testThreeWayMergeNoConflict() {
        let base = ["line 1", "line 2", "line 3"]
        let left = ["line 1", "left modified", "line 3"]  // Changed line 2
        let right = ["line 1", "line 2", "line 3", "right added"]  // Added line 4

        let result = diffEngine.diff3(base: base, left: left, right: right)

        // These changes are in different locations, so no conflict
        XCTAssertFalse(result.hasConflicts)
    }

    func testThreeWayMergeWithConflict() {
        let base = ["line 1", "line 2", "line 3"]
        let left = ["line 1", "left version", "line 3"]
        let right = ["line 1", "right version", "line 3"]

        let result = diffEngine.diff3(base: base, left: left, right: right)

        XCTAssertTrue(result.hasConflicts)
        XCTAssertGreaterThan(result.conflictCount, 0)
    }

    // MARK: - Edge Cases

    func testDiffSingleLine() {
        let result = diffEngine.diff(left: ["only line"], right: ["only line"])
        XCTAssertFalse(result.hasChanges)
    }

    func testDiffCompletelyDifferent() {
        let left = ["a", "b", "c"]
        let right = ["x", "y", "z"]

        let result = diffEngine.diff(left: left, right: right)

        XCTAssertTrue(result.hasChanges)
        XCTAssertEqual(result.leftLines.count, 3)
        XCTAssertEqual(result.rightLines.count, 3)
    }

    func testDiffPreservesOriginalLines() {
        let left = ["  spaced  ", "UPPER", "lower"]
        let right = ["  spaced  ", "UPPER", "lower", "new"]

        let result = diffEngine.diff(left: left, right: right)

        // Original lines should be preserved in result
        XCTAssertEqual(result.leftLines, left)
        XCTAssertEqual(result.rightLines, right)
    }

    // MARK: - Performance Tests

    func testPerformanceLargeDiff() {
        let leftLines = (0..<5000).map { "line \($0)" }
        var rightLines = leftLines
        // Add some random changes
        for i in stride(from: 0, to: 5000, by: 100) {
            rightLines[i] = "modified \(i)"
        }

        measure {
            _ = diffEngine.diff(left: leftLines, right: rightLines)
        }
    }
}
