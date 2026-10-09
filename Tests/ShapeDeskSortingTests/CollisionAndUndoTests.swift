import XCTest
import Foundation
import Darwin
@testable import ShapeDeskSorting

final class CollisionAndUndoTests: XCTestCase {
    func testExistingNamesAreNeverOverwrittenAndExtensionsArePreserved() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf", content: "incoming")
        try fixture.file("Docs/report.pdf", content: "existing")
        try fixture.file("Docs/report (1).pdf", content: "existing numbered")
        let result = await fixture.sorter().sort(using: StubClassifier())
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(try fixture.contents("Docs/report.pdf"), "existing")
        XCTAssertEqual(try fixture.contents("Docs/report (1).pdf"), "existing numbered")
        XCTAssertEqual(try fixture.contents("Docs/report (2).pdf"), "incoming")
    }

    func testAtomicExclusiveRenameSurvivesAConcurrentDestinationCreation() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf", content: "incoming")
        let counter = Counter()
        let destinationURL = fixture.desktop.appendingPathComponent("Docs/report.pdf")
        let files = fixture.files { sourceFD, source, destinationFD, destination in
            if counter.increment() == 1 { try Data("racing writer".utf8).write(to: destinationURL) }
            try DesktopFileSystem.exclusiveRename(sourceFD, source, destinationFD, destination)
        }
        let sorter = fixture.sorter(files: files)
        let result = await sorter.sort(using: StubClassifier())
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(try fixture.contents("Docs/report.pdf"), "racing writer")
        XCTAssertEqual(try fixture.contents("Docs/report (1).pdf"), "incoming")
        let undo = await fixture.sorter().undoLastSort()
        XCTAssertEqual(undo.restored, 1)
        XCTAssertEqual(try fixture.contents("report.pdf"), "incoming")
        XCTAssertEqual(try fixture.contents("Docs/report.pdf"), "racing writer")
    }

    func testDestinationSymlinksDirectoriesAndBrokenLinksCountAsCollisions() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf")
        let category = fixture.desktop.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: category.appendingPathComponent("report.pdf"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: category.appendingPathComponent("report (1).pdf").path,
                                                   withDestinationPath: "/missing/shapedesk-test-target")
        let result = await fixture.sorter().sort(using: StubClassifier())
        XCTAssertEqual(result.moved, 1)
        XCTAssertTrue(fixture.exists("Docs/report (2).pdf"))
    }

    func testCategorySymlinkAndCategoryFileCannotRedirectMoves() async throws {
        for useSymlink in [false, true] {
            let fixture = try DesktopFixture()
            try fixture.file("report.pdf")
            if useSymlink {
                let outside = fixture.base.appendingPathComponent("Outside")
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: fixture.desktop.appendingPathComponent("Docs"),
                                                           withDestinationURL: outside)
            } else { try fixture.file("Docs", content: "a file, not a folder") }
            let result = await fixture.sorter().sort(using: StubClassifier())
            XCTAssertEqual(result.moved, 0)
            XCTAssertTrue(fixture.exists("report.pdf"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("Outside/report.pdf").path))
        }
    }

    func testLongUnicodeAndExtensionlessCollisionNamesAreSafe() async throws {
        let fixture = try DesktopFixture()
        let longName = String(repeating: "é", count: 125) + ".pdf"
        try fixture.file(longName, content: "incoming unicode")
        try fixture.file("Docs/\(longName)", content: "existing unicode")
        try fixture.file("README", content: "incoming plain")
        try fixture.file("Docs/README", content: "existing plain")
        let result = await fixture.sorter().sort(using: StubClassifier())
        XCTAssertEqual(result.moved, 2)
        let name = DesktopFileSystem.collisionName(longName, index: 1)
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        XCTAssertTrue(name.hasSuffix(" (1).pdf"))
        XCTAssertEqual(try fixture.contents("Docs/\(name)"), "incoming unicode")
        XCTAssertEqual(try fixture.contents("Docs/README (1)"), "incoming plain")
    }

    func testUndoAfterRestartPreservesNewDesktopFilesUsingCollisionNames() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf", content: "sorted file")
        let result = await fixture.sorter().sort(using: StubClassifier())
        XCTAssertEqual(result.moved, 1)
        try fixture.file("report.pdf", content: "new desktop file")
        let restarted = fixture.sorter()
        let available = try await restarted.canUndo()
        XCTAssertTrue(available)
        let undo = await restarted.undoLastSort()
        XCTAssertEqual(undo.restored, 1)
        XCTAssertEqual(try fixture.contents("report.pdf"), "new desktop file")
        XCTAssertEqual(try fixture.contents("report (1).pdf"), "sorted file")
        let stillAvailable = try await restarted.canUndo()
        XCTAssertFalse(stillAvailable)
        let repeated = await restarted.undoLastSort()
        XCTAssertEqual(repeated.restored, 0)
    }

    func testUndoAlsoUsesAtomicCollisionProtection() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf", content: "sorted file")
        _ = await fixture.sorter().sort(using: StubClassifier())
        let raceURL = fixture.desktop.appendingPathComponent("report.pdf")
        let counter = Counter()
        let files = fixture.files { sourceFD, source, destinationFD, destination in
            if counter.increment() == 1 { try Data("new writer".utf8).write(to: raceURL) }
            try DesktopFileSystem.exclusiveRename(sourceFD, source, destinationFD, destination)
        }
        let undo = await fixture.sorter(files: files).undoLastSort()
        XCTAssertEqual(undo.restored, 1)
        XCTAssertEqual(try fixture.contents("report.pdf"), "new writer")
        XCTAssertEqual(try fixture.contents("report (1).pdf"), "sorted file")
    }

    func testUndoDoesNotMoveAReplacementFileWithTheSameName() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf")
        _ = await fixture.sorter().sort(using: StubClassifier())
        // Keep the old inode alive elsewhere so identity reuse cannot muddy the test.
        let original = fixture.desktop.appendingPathComponent("Docs/report.pdf")
        try FileManager.default.moveItem(at: original, to: fixture.base.appendingPathComponent("removed-original.pdf"))
        try fixture.file("Docs/report.pdf", content: "replacement")
        let undo = await fixture.sorter().undoLastSort()
        XCTAssertEqual(undo.restored, 0)
        XCTAssertEqual(undo.skipped, 1)
        XCTAssertEqual(try fixture.contents("Docs/report.pdf"), "replacement")
        XCTAssertFalse(fixture.exists("report.pdf"))
    }

    func testPartialUndoCanBeRetriedAfterUnlockingAFile() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("a.pdf")
        try fixture.file("b.pdf")
        _ = await fixture.sorter().sort(using: StubClassifier())
        let locked = fixture.desktop.appendingPathComponent("Docs/a.pdf")
        XCTAssertEqual(chflags(locked.path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(locked.path, 0) }
        let first = await fixture.sorter().undoLastSort()
        XCTAssertEqual(first.restored, 1)
        XCTAssertEqual(first.skipped, 1)
        XCTAssertEqual(chflags(locked.path, 0), 0)
        let second = await fixture.sorter().undoLastSort()
        XCTAssertEqual(second.restored, 1)
        XCTAssertEqual(second.skipped, 0)
        XCTAssertTrue(fixture.exists("a.pdf"))
        XCTAssertTrue(fixture.exists("b.pdf"))
    }

    func testUndoJournalFailureLeavesFileInItsSortedLocation() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf")
        _ = await fixture.sorter().sort(using: StubClassifier())
        let history = FaultingJournalStore(real: SortJournalStore(directory: fixture.history), failOnSave: 1)
        let failed = await fixture.sorter(store: history).undoLastSort()
        XCTAssertEqual(failed.restored, 0)
        XCTAssertEqual(failed.skipped, 1)
        XCTAssertTrue(fixture.exists("Docs/report.pdf"))
        let retried = await fixture.sorter().undoLastSort()
        XCTAssertEqual(retried.restored, 1)
    }

    func testInterruptedUndoReconcilesItsWriteAheadDestination() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf")
        _ = await fixture.sorter().sort(using: StubClassifier())
        let history = FaultingJournalStore(real: SortJournalStore(directory: fixture.history), failOnSave: 2)
        // The restore succeeds; the final resolved-bit save fails.
        let undo = await fixture.sorter(store: history).undoLastSort()
        XCTAssertEqual(undo.restored, 1)
        XCTAssertTrue(fixture.exists("report.pdf"))
        let restarted = fixture.sorter()
        let available = try await restarted.canUndo()
        XCTAssertFalse(available)
        let repeated = await restarted.undoLastSort()
        XCTAssertEqual(repeated.restored, 0)
        XCTAssertFalse(fixture.exists("report (1).pdf"))
    }

    func testNoOpOrFailedSortDoesNotErasePreviousUndo() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("first.pdf")
        _ = await fixture.sorter().sort(using: StubClassifier())
        try fixture.file("second.pdf")
        _ = await fixture.sorter().sort(using: StubClassifier(confidence: 0.8))
        let undo = await fixture.sorter().undoLastSort()
        XCTAssertEqual(undo.restored, 1)
        XCTAssertTrue(fixture.exists("first.pdf"))
        XCTAssertTrue(fixture.exists("second.pdf"))
    }

    func testCorruptHistoryFailsClosedWithoutMovingAnything() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf")
        try FileManager.default.createDirectory(at: fixture.history, withIntermediateDirectories: true)
        try Data("not valid JSON".utf8).write(to: fixture.history.appendingPathComponent("\(UUID().uuidString).json"))
        let result = await fixture.sorter().sort(using: StubClassifier())
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.moved, 0)
        XCTAssertTrue(fixture.exists("report.pdf"))
    }

    func testUnsafeJournalPathsAreRejected() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf")
        _ = await fixture.sorter().sort(using: StubClassifier())
        let store = SortJournalStore(directory: fixture.history)
        var journal = try XCTUnwrap(store.load().first)
        journal.records[0].destinationName = "../../outside.pdf"
        try store.save(journal)
        XCTAssertThrowsError(try store.load())
        let undo = await fixture.sorter().undoLastSort()
        XCTAssertEqual(undo.restored, 0)
        XCTAssertTrue(fixture.exists("Docs/report.pdf"))
    }

    func testHistoryWrittenBeforeDestinationFoldersStillUndoes() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf")
        _ = await fixture.sorter().sort(using: StubClassifier())
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.history,
            includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertNil(records[0]["folder"], "Sorting must keep writing the original record format")
        records[0].removeValue(forKey: "folder")
        json["records"] = records
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let undo = await fixture.sorter().undoLastSort()
        XCTAssertEqual(undo.restored, 1)
        XCTAssertTrue(fixture.exists("report.pdf"))
    }

    func testUnsafeOrMissingDestinationFoldersAreRejected() async throws {
        for folder in ["../outside", ".hidden", nil] as [String?] {
            let fixture = try DesktopFixture()
            try fixture.file("a.txt", content: "same")
            try fixture.file("b.txt", content: "same")
            let scan = try await DuplicateFinder.scan(files: fixture.files(), onProgress: { _ in })
            _ = await fixture.sorter().moveDuplicates(scan)
            let store = SortJournalStore(directory: fixture.history)
            var journal = try XCTUnwrap(store.load().first)
            journal.records[0].folder = folder
            try store.save(journal)
            XCTAssertThrowsError(try store.load(), String(describing: folder))
            let undo = await fixture.sorter().undoLastSort()
            XCTAssertEqual(undo.restored, 0)
        }
    }

    func testOpenFileCheckerDetectsARealOpenDescriptor() throws {
        let fixture = try DesktopFixture()
        let file = try fixture.file("open.pdf")
        let descriptor = open(file.path, O_RDONLY)
        defer { close(descriptor) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertTrue(try OpenFileUseChecker().isInUse(file))
        let closed = try fixture.file("closed.pdf")
        XCTAssertFalse(try OpenFileUseChecker().isInUse(closed))
    }

    func testInaccessibleCategoryDoesNotBlockUndoOfOtherCategories() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("a.pdf")
        try fixture.file("b.png")
        let classifier = StubClassifier { metadata in
            FileClassification(category: metadata.fileExtension == "pdf" ? .docs : .images,
                               confidence: 0.99, model: "test")
        }
        _ = await fixture.sorter().sort(using: classifier)
        let docs = fixture.desktop.appendingPathComponent("Docs")
        let relocated = fixture.base.appendingPathComponent("RelocatedDocs")
        try FileManager.default.moveItem(at: docs, to: relocated)
        try FileManager.default.createSymbolicLink(at: docs, withDestinationURL: relocated)
        let sorter = fixture.sorter()
        let available = try await sorter.canUndo()
        XCTAssertTrue(available)
        let undo = await sorter.undoLastSort()
        XCTAssertEqual(undo.restored, 1)
        XCTAssertEqual(undo.skipped, 1)
        XCTAssertTrue(fixture.exists("b.png"))
        XCTAssertFalse(fixture.exists("a.pdf"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: relocated.appendingPathComponent("a.pdf").path))
    }

    func testWriteAheadRecordIsOnDiskBeforeTheMoveStarts() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf")
        let store = SortJournalStore(directory: fixture.history)
        let files = fixture.files { sourceFD, source, destinationFD, destination in
            let journal = try XCTUnwrap(store.load().first)
            let record = try XCTUnwrap(journal.records.first)
            XCTAssertEqual(record.originalName, source)
            XCTAssertEqual(record.destinationName, destination)
            XCTAssertEqual(record.category, .docs)
            XCTAssertTrue(fixture.exists("report.pdf"))
            try DesktopFileSystem.exclusiveRename(sourceFD, source, destinationFD, destination)
        }
        let result = await fixture.sorter(files: files).sort(using: StubClassifier())
        XCTAssertEqual(result.moved, 1)
    }
}
