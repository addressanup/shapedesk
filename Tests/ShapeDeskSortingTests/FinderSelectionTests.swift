import XCTest
import Foundation
@testable import ShapeDeskSorting

final class FinderSelectionTests: XCTestCase {
    func testSelectedFilesOnlyAndUndoAfterRestart() async throws {
        let fixture = try DesktopFixture()
        let one = try fixture.file("one.pdf"), two = try fixture.file("two.txt")
        try fixture.file("unselected.pdf")
        let selection = try SortSelection.resolve([one, two, one])
        XCTAssertEqual(selection.fileNames?.count, 2)
        let result = await DesktopSorter(selection: selection, historyDirectory: fixture.history).sort(using: StubClassifier())
        XCTAssertEqual(result.totalScanned, 2)
        XCTAssertEqual(result.moved, 2)
        XCTAssertTrue(fixture.exists("unselected.pdf"))
        let undo = await DesktopSorter(desktop: fixture.desktop, historyDirectory: fixture.history).undoLastSort()
        XCTAssertEqual(undo.restored, 2)
        XCTAssertTrue(fixture.exists("one.pdf"))
    }

    func testFolderSelectionRemainsShallow() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("one.pdf")
        try fixture.file("Docs/existing.pdf")
        try fixture.file("Nested/two.pdf")
        try fixture.file(".hidden")
        let selection = try SortSelection.resolve([fixture.desktop])
        XCTAssertNil(selection.fileNames)
        let sorter = DesktopSorter(selection: selection, historyDirectory: fixture.history)
        let result = await sorter.sort(using: StubClassifier())
        XCTAssertEqual(result.moved, 1)
        let again = await sorter.sort(using: StubClassifier())
        XCTAssertEqual(again.totalScanned, 0)
        XCTAssertTrue(fixture.exists("Nested/two.pdf"))
    }

    func testRejectsMixedFoldersHiddenSymlinksAndPackages() throws {
        let fixture = try DesktopFixture()
        let file = try fixture.file("one.pdf"), other = try fixture.file("Nested/two.pdf")
        let hidden = try fixture.file(".secret")
        let link = fixture.desktop.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let package = fixture.desktop.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        for selection in [[file, other], [file, fixture.desktop], [hidden], [link], [package], [], [URL(string: "https://example.com/file")!]] {
            XCTAssertThrowsError(try SortSelection.resolve(selection))
        }
    }

    func testReplacedSelectedFileNeverMoves() async throws {
        let fixture = try DesktopFixture()
        let file = try fixture.file("one.pdf")
        let selection = try SortSelection.resolve([file])
        try FileManager.default.moveItem(at: file, to: fixture.base.appendingPathComponent("old.pdf"))
        try fixture.file("one.pdf", content: "replacement")
        let classifier = StubClassifier()
        let result = await DesktopSorter(selection: selection, historyDirectory: fixture.history).sort(using: classifier)
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.skipped, 1)
        let calls = await classifier.inputs
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(try fixture.contents("one.pdf"), "replacement")
    }

    func testReplacedSelectedFolderFailsClosed() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("one.pdf")
        let selection = try SortSelection.resolve([fixture.desktop])
        try FileManager.default.moveItem(at: fixture.desktop, to: fixture.base.appendingPathComponent("original"))
        try fixture.file("replacement.pdf")
        let result = await DesktopSorter(selection: selection, historyDirectory: fixture.history).sort(using: StubClassifier())
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.moved, 0)
        XCTAssertTrue(fixture.exists("replacement.pdf"))
    }
}
