import XCTest
import Foundation
import Darwin
@testable import ShapeDeskSorting

final class DuplicateFinderTests: XCTestCase {
    private func scan(_ fixture: DesktopFixture) async throws -> DuplicateScan {
        try await DuplicateFinder.scan(files: fixture.files(), onProgress: { _ in })
    }

    private func setCreated(_ url: URL, secondsAgo: TimeInterval) throws {
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -secondsAgo)],
                                              ofItemAtPath: url.path)
    }

    func testFindsIdenticalTopLevelFilesOnly() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf", content: "same bytes")
        try fixture.file("report copy.pdf", content: "same bytes")
        try fixture.file("other.pdf", content: "diff bytes") // Same size, different contents.
        try fixture.file("empty-a.txt", content: "")
        try fixture.file("empty-b.txt", content: "")
        try fixture.file("Projects/report.pdf", content: "same bytes")
        try fixture.file(".hidden.pdf", content: "same bytes")
        let result = try await scan(fixture)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].files.map(\.name), ["report.pdf", "report copy.pdf"])
        XCTAssertEqual(result.groups[0].keeper, "report.pdf")
        XCTAssertEqual(result.extraCopies, 1)
        XCTAssertEqual(result.wastedBytes, 10)
        XCTAssertEqual(result.unreadableFiles, 0)
    }

    func testFilesSharingALongPrefixAreComparedInFull() async throws {
        let fixture = try DesktopFixture()
        let prefix = String(repeating: "a", count: DuplicateFinder.prefixLength + 10)
        try fixture.file("one.mov", content: prefix + "x")
        try fixture.file("two.mov", content: prefix + "y")
        try fixture.file("three.mov", content: prefix + "x")
        let result = try await scan(fixture)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].files.map(\.name)), ["one.mov", "three.mov"])
    }

    func testProgressOnlyMovesForwardAndFinishesComplete() async throws {
        let fixture = try DesktopFixture()
        let prefix = String(repeating: "b", count: DuplicateFinder.prefixLength + 10)
        try fixture.file("a.bin", content: prefix + "1")
        try fixture.file("b.bin", content: prefix + "1")
        try fixture.file("c.bin", content: "z" + prefix) // Ruled out by its prefix.
        try fixture.file("d.txt", content: "small")
        try fixture.file("e.txt", content: "small")
        let recorder = DuplicateProgressRecorder()
        _ = try await DuplicateFinder.scan(files: fixture.files()) { await recorder.append($0) }
        let fractions = await recorder.updates.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertEqual(fractions.last, 1)
    }

    func testHardLinksAreNotDuplicates() async throws {
        let fixture = try DesktopFixture()
        let original = try fixture.file("photo.jpg", content: "pixels")
        XCTAssertEqual(link(original.path, fixture.desktop.appendingPathComponent("photo link.jpg").path), 0)
        let result = try await scan(fixture)
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testKeeperPrefersNamesWithoutCopyMarkersThenTheOldestFile() async throws {
        let fixture = try DesktopFixture()
        try setCreated(fixture.file("notes (1).txt", content: "same"), secondsAgo: 9_000)
        try setCreated(fixture.file("notes copy 2.txt", content: "same"), secondsAgo: 8_000)
        try setCreated(fixture.file("notes-new.txt", content: "same"), secondsAgo: 100)
        try setCreated(fixture.file("notes.txt", content: "same"), secondsAgo: 5_000)
        let result = try await scan(fixture)
        XCTAssertEqual(result.groups[0].files.map(\.name),
                       ["notes.txt", "notes-new.txt", "notes (1).txt", "notes copy 2.txt"])
        XCTAssertTrue(DuplicateFinder.isCopyName("Report COPY.pdf"))
        XCTAssertFalse(DuplicateFinder.isCopyName("Invoice 2024.pdf"))
    }

    func testMovesExtraCopiesIntoDuplicatesAndUndoRestoresThem() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("a.pdf", content: "first")
        try fixture.file("a copy.pdf", content: "first")
        try fixture.file("a (1).pdf", content: "first")
        try fixture.file("b.png", content: "second")
        try fixture.file("b copy.png", content: "second")
        var result = try await scan(fixture)
        let group = try XCTUnwrap(result.groups.firstIndex { $0.files.count == 2 })
        result.groups[group].keeper = "b copy.png" // The person picked the other copy.
        let moved = await fixture.sorter().moveDuplicates(result)
        XCTAssertEqual(moved.phase, .completed)
        XCTAssertEqual(moved.moved, 3)
        XCTAssertEqual(moved.movedBytes, 16)
        XCTAssertTrue(fixture.exists("a.pdf"))
        XCTAssertTrue(fixture.exists("b copy.png"))
        XCTAssertEqual(try fixture.contents("Duplicates/a copy.pdf"), "first")
        XCTAssertEqual(try fixture.contents("Duplicates/a (1).pdf"), "first")
        XCTAssertEqual(try fixture.contents("Duplicates/b.png"), "second")

        let record = try XCTUnwrap(SortJournalStore(directory: fixture.history).load().first?.records.first)
        XCTAssertNil(record.category)
        XCTAssertEqual(record.folderName, "Duplicates")

        let sorter = fixture.sorter()
        let available = try await sorter.canUndo()
        XCTAssertTrue(available)
        let undo = await sorter.undoLastSort()
        XCTAssertEqual(undo.restored, 3)
        for name in ["a.pdf", "a copy.pdf", "a (1).pdf", "b.png", "b copy.png"] {
            XCTAssertTrue(fixture.exists(name), name)
        }
    }

    func testChangedKeeperOrChangedCopyStaysInPlace() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("keep.txt", content: "one")
        try fixture.file("keep copy.txt", content: "one")
        try fixture.file("move.txt", content: "two")
        try fixture.file("move copy.txt", content: "two")
        let result = try await scan(fixture)
        try fixture.file("keep.txt", content: "edited") // Keeper edited after the scan.
        try fixture.file("move copy.txt", content: "new") // A copy edited after the scan.
        let moved = await fixture.sorter().moveDuplicates(result)
        XCTAssertEqual(moved.moved, 0)
        XCTAssertEqual(moved.skipped, 2)
        for name in ["keep.txt", "keep copy.txt", "move.txt", "move copy.txt"] {
            XCTAssertTrue(fixture.exists(name), name)
        }
    }

    func testReplacedFolderFailsClosed() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("a.txt", content: "same")
        try fixture.file("b.txt", content: "same")
        let result = try await scan(fixture)
        let moved = fixture.base.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: fixture.desktop, to: moved)
        try FileManager.default.createDirectory(at: fixture.desktop, withIntermediateDirectories: true)
        try fixture.file("a.txt", content: "same")
        try fixture.file("b.txt", content: "same")
        let stats = await fixture.sorter().moveDuplicates(result)
        XCTAssertEqual(stats.phase, .failed)
        XCTAssertEqual(stats.moved, 0)
        XCTAssertTrue(fixture.exists("a.txt"))
        XCTAssertTrue(fixture.exists("b.txt"))
    }

    func testDuplicateHistoryIsSeparateFromSortHistory() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("same.txt", content: "dup")
        try fixture.file("same copy.txt", content: "dup")
        let duplicates = fixture.base.appendingPathComponent("DuplicateHistory")
        let scanned = try await scan(fixture)
        _ = await fixture.sorter(store: SortJournalStore(directory: duplicates)).moveDuplicates(scanned)
        try fixture.file("report.pdf")
        _ = await fixture.sorter().sort(using: StubClassifier())
        let sortUndo = await fixture.sorter().undoLastSort()
        XCTAssertEqual(sortUndo.restored, 2) // report.pdf and the kept same.txt
        XCTAssertTrue(fixture.exists("report.pdf"))
        XCTAssertTrue(fixture.exists("same.txt"))
        XCTAssertTrue(fixture.exists("Duplicates/same copy.txt"), "Undoing a sort must not undo a duplicate move")
        let duplicateUndo = await fixture.sorter(store: SortJournalStore(directory: duplicates)).undoLastSort()
        XCTAssertEqual(duplicateUndo.restored, 1)
        XCTAssertTrue(fixture.exists("same copy.txt"))
    }
}

actor DuplicateProgressRecorder {
    private(set) var updates: [DuplicateScanProgress] = []
    func append(_ value: DuplicateScanProgress) { updates.append(value) }
}
