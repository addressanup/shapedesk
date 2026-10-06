import XCTest
import Foundation
@testable import ShapeDeskSorting

final class FinderSelectionTests: XCTestCase {
    private func folder(_ fixture: DesktopFixture, _ path: String) throws -> URL {
        let url = fixture.base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func finderURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path + "/", isDirectory: true)
    }

    func testFinderFolderFallsBackToDesktop() throws {
        let fixture = try DesktopFixture()
        let home = fixture.base, desktop = fixture.desktop
        XCTAssertNil(SortSelection.finderFolder(nil, desktop: desktop, home: home))
        XCTAssertNil(SortSelection.finderFolder(desktop, desktop: desktop, home: home))
        XCTAssertNil(SortSelection.finderFolder(finderURL(desktop), desktop: desktop, home: home))
        XCTAssertNil(SortSelection.finderFolder(finderURL(fixture.base.appendingPathComponent("Missing")),
                                                desktop: desktop, home: home))
        XCTAssertNil(SortSelection.finderFolder(try fixture.file("one.pdf"), desktop: desktop, home: home))
    }

    func testFinderFolderFollowsVisibleFoldersInHomeAndCloudStorage() throws {
        let fixture = try DesktopFixture()
        let home = fixture.base, desktop = fixture.desktop
        let urls = try [fixture.base] + ["Projects", "Projects/Client A",
                     "Library/Mobile Documents/com~apple~CloudDocs/Notes",
                     "Library/CloudStorage/Dropbox/Inbox"].map { try folder(fixture, $0) }
        for url in urls {
            let selection = SortSelection.finderFolder(finderURL(url), desktop: desktop, home: home)
            XCTAssertNil(selection?.fileNames, url.path)
            let name = url.standardizedFileURL.lastPathComponent
            XCTAssertEqual(selection?.description, "Files in \(name)", url.path)
        }
    }

    func testFinderFolderIgnoresLibraryHiddenPackagesLinksAndOutsideHome() throws {
        let fixture = try DesktopFixture()
        let home = fixture.base, desktop = fixture.desktop
        var secret = try folder(fixture, "Secret")
        var values = URLResourceValues()
        values.isHidden = true
        try secret.setResourceValues(values)
        let projects = try folder(fixture, "Projects")
        let link = fixture.base.appendingPathComponent("Shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: projects)
        let rejected = try [folder(fixture, "Library"), folder(fixture, "Library/Preferences"),
                            folder(fixture, ".config"), folder(fixture, "Projects/.git/objects"),
                            secret, folder(fixture, "Secret/Inside"),
                            folder(fixture, "Projects/Example.app/Contents"),
                            folder(fixture, "Library/CloudStorage/Dropbox/.cache/blobs"),
                            link, fixture.base.deletingLastPathComponent()]
        for url in rejected {
            XCTAssertNil(SortSelection.finderFolder(finderURL(url), desktop: desktop, home: home), url.path)
        }
    }

    func testFinderFolderComparesIdentityAndRecognizesCategoryFolders() throws {
        let fixture = try DesktopFixture()
        let home = fixture.base, desktop = fixture.desktop
        let projects = try folder(fixture, "Projects")
        let first = SortSelection.finderFolder(finderURL(projects), desktop: desktop, home: home)
        XCTAssertEqual(first, SortSelection.finderFolder(finderURL(projects), desktop: desktop, home: home))
        try FileManager.default.moveItem(at: projects, to: fixture.base.appendingPathComponent("Moved"))
        let moved = try folder(fixture, "Projects")
        XCTAssertNotEqual(first, SortSelection.finderFolder(finderURL(moved), desktop: desktop, home: home))
        let docs = try XCTUnwrap(SortSelection.finderFolder(finderURL(try folder(fixture, "Projects/Docs")),
                                                          desktop: desktop, home: home))
        XCTAssertTrue(docs.isCategoryFolder(of: projects))
        let notes = try XCTUnwrap(SortSelection.finderFolder(finderURL(try folder(fixture, "Projects/Notes")),
                                                           desktop: desktop, home: home))
        XCTAssertFalse(notes.isCategoryFolder(of: projects))
        XCTAssertFalse(docs.isCategoryFolder(of: fixture.base))
        let images = try XCTUnwrap(SortSelection.finderFolder(finderURL(try folder(fixture, "Desktop/Images")),
                                                            desktop: desktop, home: home))
        XCTAssertTrue(images.isCategoryFolder(of: fixture.desktop))
    }

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
