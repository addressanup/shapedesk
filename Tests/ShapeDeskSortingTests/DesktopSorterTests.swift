import XCTest
import Foundation
import Darwin
@testable import ShapeDeskSorting

final class DesktopSorterTests: XCTestCase {
    func testStrictConfidenceThresholdAndInvalidNumbers() async throws {
        let cases: [(Double, Bool)] = [
            (0, false), (0.79, false), (0.8.nextDown, false), (0.8, false),
            (0.8.nextUp, true), (0.99, true), (1, true),
            (-0.1, false), (1.01, false), (.nan, false), (.infinity, false), (-.infinity, false)
        ]
        for (confidence, expectedMove) in cases {
            let fixture = try DesktopFixture()
            try fixture.file("report.pdf")
            let result = await fixture.sorter().sort(using: StubClassifier(confidence: confidence))
            XCTAssertEqual(result.moved, expectedMove ? 1 : 0, "confidence \(confidence)")
            XCTAssertEqual(result.skipped, expectedMove ? 0 : 1)
            XCTAssertEqual(fixture.exists("report.pdf"), !expectedMove)
            XCTAssertEqual(fixture.exists("Docs/report.pdf"), expectedMove)
            XCTAssertEqual(result.totalScanned, result.processed)
        }
    }

    func testScansOnlyTopLevelVisibleRegularFilesAndExtractsMetadata() async throws {
        let fixture = try DesktopFixture()
        let image = try fixture.file("Photo.PNG", content: "image bytes")
        try fixture.file(".secret.txt")
        try fixture.file("Images/already-sorted.png")
        try fixture.file("Projects/nested.swift")
        let hidden = try fixture.file("finder-hidden.txt")
        XCTAssertEqual(chflags(hidden.path, UInt32(UF_HIDDEN)), 0)
        defer { chflags(hidden.path, 0) }
        try FileManager.default.createSymbolicLink(at: fixture.desktop.appendingPathComponent("shortcut.png"),
                                                   withDestinationURL: image)
        let classifier = StubClassifier(category: .images)
        let result = await fixture.sorter().sort(using: classifier)
        let inputs = await classifier.inputs
        XCTAssertEqual(result.totalScanned, 1)
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].name, "Photo.PNG")
        XCTAssertEqual(inputs[0].fileExtension, "png")
        XCTAssertEqual(inputs[0].byteSize, 11)
        XCTAssertEqual(inputs[0].contentType, "public.png")
        XCTAssertEqual(inputs[0].mimeType, "image/png")
        XCTAssertTrue(fixture.exists(".secret.txt"))
        XCTAssertTrue(fixture.exists("Projects/nested.swift"))
        XCTAssertTrue(fixture.exists("Images/already-sorted.png"))
        let second = await fixture.sorter().sort(using: classifier)
        XCTAssertEqual(second.totalScanned, 0, "Target directories must never be re-scanned")
    }

    func testClassifierErrorLeavesFileAndContinuesWithNextFile() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("a-fail.pdf")
        try fixture.file("b-pass.pdf")
        let classifier = StubClassifier { metadata in
            if metadata.name == "a-fail.pdf" { throw URLError(.timedOut) }
            return FileClassification(category: .docs, confidence: 0.99, model: "test")
        }
        let result = await fixture.sorter().sort(using: classifier)
        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.errors, 1)
        XCTAssertEqual(try fixture.contents("a-fail.pdf"), "original contents")
        XCTAssertTrue(fixture.exists("Docs/b-pass.pdf"))
    }

    func testMoveFailureLeavesOriginalAndContinues() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("a-fail.pdf")
        try fixture.file("b-pass.pdf")
        let files = fixture.files { sourceFD, source, destinationFD, destination in
            if source == "a-fail.pdf" { throw SortingError.io("Busy file", EBUSY) }
            try DesktopFileSystem.exclusiveRename(sourceFD, source, destinationFD, destination)
        }
        let result = await fixture.sorter(files: files).sort(using: StubClassifier())
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.errors, 1)
        XCTAssertTrue(fixture.exists("a-fail.pdf"))
        XCTAssertFalse(fixture.exists("Docs/a-fail.pdf"))
        let undo = await fixture.sorter().undoLastSort()
        XCTAssertEqual(undo.restored, 1)
        XCTAssertEqual(undo.skipped, 0)
    }

    func testJournalFailurePreventsMoveAndPreservesUndoForLaterSuccesses() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("a-fail.pdf")
        try fixture.file("b-pass.pdf")
        let history = FaultingJournalStore(real: SortJournalStore(directory: fixture.history), failOnSave: 1)
        let result = await fixture.sorter(store: history).sort(using: StubClassifier())
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.errors, 1)
        XCTAssertTrue(fixture.exists("a-fail.pdf"))
        XCTAssertTrue(fixture.exists("Docs/b-pass.pdf"))
        let undo = await fixture.sorter().undoLastSort()
        XCTAssertEqual(undo.restored, 1)
        XCTAssertEqual(undo.skipped, 0)
    }

    func testLockedReadOnlyOpenPartialAndRecentFilesStayPut() async throws {
        let fixture = try DesktopFixture()
        let locked = try fixture.file("locked.pdf")
        XCTAssertEqual(chflags(locked.path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(locked.path, 0) }
        let readOnly = try fixture.file("readonly.pdf")
        XCTAssertEqual(chmod(readOnly.path, 0o444), 0)
        try fixture.file("busy-recording.mov")
        try fixture.file("unfinished.crdownload")
        let recent = try fixture.file("recent.txt")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: recent.path)
        try fixture.file("safe.pdf")
        let result = await fixture.sorter(files: fixture.files(useChecker: BusyFiles(), minimumAge: 2))
            .sort(using: StubClassifier())
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.skipped, 5)
        for name in ["locked.pdf", "readonly.pdf", "busy-recording.mov", "unfinished.crdownload", "recent.txt"] {
            XCTAssertTrue(fixture.exists(name), name)
        }
    }

    func testAdvisoryLockIsRespected() async throws {
        let fixture = try DesktopFixture()
        let file = try fixture.file("held.pdf")
        let fd = open(file.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let result = await fixture.sorter().sort(using: StubClassifier())
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(fixture.exists("held.pdf"))
    }

    func testChangedAndDeletedFilesDuringClassificationAreNotMoved() async throws {
        let fixture = try DesktopFixture()
        let changed = try fixture.file("changed.pdf")
        let deleted = try fixture.file("deleted.pdf")
        let classifier = StubClassifier { metadata in
            if metadata.name == "changed.pdf" { try Data("new contents".utf8).write(to: changed) }
            if metadata.name == "deleted.pdf" { try FileManager.default.removeItem(at: deleted) }
            return FileClassification(category: .docs, confidence: 1, model: "test")
        }
        let result = await fixture.sorter().sort(using: classifier)
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(try fixture.contents("changed.pdf"), "new contents")
        XCTAssertFalse(fixture.exists("Docs/deleted.pdf"))
    }

    func testProgressIsOrderedAndCategoryTotalsMatchFilesystem() async throws {
        let fixture = try DesktopFixture()
        for category in FileCategory.allCases { try fixture.file("\(category.rawValue).dat") }
        try fixture.file("uncertain.dat")
        let recorder = ProgressRecorder()
        let classifier = StubClassifier { metadata in
            let category = FileCategory(rawValue: String(metadata.name.dropLast(4))) ?? .other
            return FileClassification(category: category,
                confidence: metadata.name == "uncertain.dat" ? 0.8 : 0.99, model: "test")
        }
        let result = await fixture.sorter().sort(using: classifier) { await recorder.append($0) }
        let updates = await recorder.updates
        XCTAssertEqual(updates.first?.phase, .scanning)
        XCTAssertEqual(updates.last, result)
        XCTAssertEqual(result.totalScanned, 9)
        XCTAssertEqual(result.moved, 8)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(updates.contains { $0.moved > 0 && $0.remaining > 0 })
        for pair in zip(updates, updates.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.totalScanned, pair.1.totalScanned)
            XCTAssertLessThanOrEqual(pair.0.moved, pair.1.moved)
            XCTAssertLessThanOrEqual(pair.1.processed, pair.1.totalScanned)
        }
        for category in FileCategory.allCases { XCTAssertEqual(result.categories[category]?.moved, 1) }
        XCTAssertEqual(result.categories[.other]?.skipped, 1)
    }

    func testCancellationDuringRequestLeavesUnprocessedFilesAndAllowsAnotherRun() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("a.pdf")
        try fixture.file("b.pdf")
        let requested = expectation(description: "Classification started")
        let classifier = StubClassifier { _ in
            requested.fulfill()
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return FileClassification(category: .docs, confidence: 1, model: "test")
        }
        let sorter = fixture.sorter()
        let operation = Task { await sorter.sort(using: classifier) }
        await fulfillment(of: [requested], timeout: 2)
        operation.cancel()
        let result = await operation.value
        XCTAssertEqual(result.phase, .cancelled)
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertTrue(fixture.exists("a.pdf"))
        let second = await sorter.sort(using: StubClassifier())
        XCTAssertEqual(second.moved, 2)
    }

    func testConcurrentInstancesCannotSortAtSameTime() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("a.pdf")
        let requested = expectation(description: "Request in progress")
        let slow = StubClassifier { _ in
            requested.fulfill()
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return FileClassification(category: .docs, confidence: 1, model: "test")
        }
        let firstSorter = fixture.sorter()
        let first = Task { await firstSorter.sort(using: slow) }
        await fulfillment(of: [requested], timeout: 2)
        let sameActor = await firstSorter.sort(using: StubClassifier())
        XCTAssertEqual(sameActor.phase, .failed)
        let otherInstance = await fixture.sorter().sort(using: StubClassifier())
        XCTAssertEqual(otherInstance.phase, .failed)
        XCTAssertEqual(otherInstance.moved, 0)
        first.cancel()
        _ = await first.value
    }

    func testEmptyAndMissingDesktopProduceUsefulFinalStates() async throws {
        let fixture = try DesktopFixture()
        let empty = await fixture.sorter().sort(using: StubClassifier())
        XCTAssertEqual(empty.phase, .completed)
        XCTAssertEqual(empty.totalScanned, 0)
        try FileManager.default.removeItem(at: fixture.desktop)
        let missing = await fixture.sorter().sort(using: StubClassifier())
        XCTAssertEqual(missing.phase, .failed)
        XCTAssertEqual(missing.moved, 0)
    }
}
