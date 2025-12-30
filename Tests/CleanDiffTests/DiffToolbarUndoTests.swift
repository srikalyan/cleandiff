import XCTest
import ViewInspector
@testable import CleanDiff

@MainActor
final class DiffToolbarUndoTests: XCTestCase {
    func testUndoButtonDisabledWhenNoUndoActions() throws {
        // Clear the shared undo manager first
        UndoManagerTracker.shared.documentUndoManager.removeAllActions()
        UndoManagerTracker.shared.refreshState()

        let viewModel = ComparisonViewModel(
            comparison: Comparison(
                leftURL: FileManager.default.temporaryDirectory.appendingPathComponent("left.txt"),
                rightURL: FileManager.default.temporaryDirectory.appendingPathComponent("right.txt")
            )
        )
        let view = DiffToolbar(viewModel: viewModel, wordWrap: .constant(false))

        let undoButton = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "undo-button")
            .button()
        XCTAssertTrue(undoButton.isDisabled())
    }

    func testUndoButtonInvokesUndo() throws {
        // Clear first to start clean
        UndoManagerTracker.shared.documentUndoManager.removeAllActions()

        final class UndoRecorder {
            var undoCount = 0
            func mark() { undoCount += 1 }
        }

        let recorder = UndoRecorder()
        let manager = UndoManagerTracker.shared.documentUndoManager
        manager.registerUndo(withTarget: recorder) { target in
            target.mark()
        }
        UndoManagerTracker.shared.refreshState()

        let viewModel = ComparisonViewModel(
            comparison: Comparison(
                leftURL: FileManager.default.temporaryDirectory.appendingPathComponent("left.txt"),
                rightURL: FileManager.default.temporaryDirectory.appendingPathComponent("right.txt")
            )
        )
        let view = DiffToolbar(viewModel: viewModel, wordWrap: .constant(false))

        let undoButton = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "undo-button")
            .button()
        XCTAssertFalse(undoButton.isDisabled())
        try undoButton.tap()

        XCTAssertEqual(recorder.undoCount, 1)
    }

    func testRedoButtonEnabledAfterUndoAndInvokesRedo() throws {
        // Clear first to start clean
        UndoManagerTracker.shared.documentUndoManager.removeAllActions()

        final class UndoRecorder {
            var actionCount = 0
            func mark() { actionCount += 1 }
        }

        let recorder = UndoRecorder()
        let manager = UndoManagerTracker.shared.documentUndoManager
        manager.registerUndo(withTarget: recorder) { target in
            target.mark()
            manager.registerUndo(withTarget: target) { redoTarget in
                redoTarget.mark()
            }
        }

        manager.undo() // Creates a redo action.
        UndoManagerTracker.shared.refreshState()
        XCTAssertTrue(manager.canRedo)

        let viewModel = ComparisonViewModel(
            comparison: Comparison(
                leftURL: FileManager.default.temporaryDirectory.appendingPathComponent("left.txt"),
                rightURL: FileManager.default.temporaryDirectory.appendingPathComponent("right.txt")
            )
        )
        let view = DiffToolbar(viewModel: viewModel, wordWrap: .constant(false))

        let redoButton = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "redo-button")
            .button()
        XCTAssertFalse(redoButton.isDisabled())
        try redoButton.tap()

        XCTAssertEqual(recorder.actionCount, 2)
    }
}
