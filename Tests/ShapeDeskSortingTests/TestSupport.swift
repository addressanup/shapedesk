import XCTest
import Foundation
import Darwin
@testable import ShapeDeskSorting

final class DesktopFixture {
    let base: URL
    let desktop: URL
    let history: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ShapeDesk-tests-\(UUID().uuidString)")
        desktop = base.appendingPathComponent("Desktop")
        history = base.appendingPathComponent("History")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func file(_ name: String, content: String = "original contents") throws -> URL {
        let url = desktop.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: url.path)
        return url
    }

    func contents(_ name: String) throws -> String {
        try String(contentsOf: desktop.appendingPathComponent(name), encoding: .utf8)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: desktop.appendingPathComponent(name).path)
    }

    func files(useChecker: any FileUseChecking = UnusedFiles(), minimumAge: TimeInterval = 0,
               rename: @escaping DesktopFileSystem.Rename = DesktopFileSystem.exclusiveRename) -> DesktopFileSystem {
        DesktopFileSystem(desktop: desktop, useChecker: useChecker, minimumAge: minimumAge, rename: rename)
    }

    func sorter(files: DesktopFileSystem? = nil, store: (any JournalStoring)? = nil) -> DesktopSorter {
        DesktopSorter(files: files ?? self.files(), history: store ?? SortJournalStore(directory: history))
    }
}

struct UnusedFiles: FileUseChecking {
    func isInUse(_ url: URL) throws -> Bool { false }
}

struct BusyFiles: FileUseChecking {
    func isInUse(_ url: URL) throws -> Bool { url.lastPathComponent.hasPrefix("busy") }
}

actor StubClassifier: FileClassifying {
    private(set) var inputs: [FileMetadata] = []
    private let handler: @Sendable (FileMetadata) async throws -> FileClassification

    init(category: FileCategory = .docs, confidence: Double = 0.99) {
        handler = { _ in FileClassification(category: category, confidence: confidence, model: "test-model") }
    }

    init(handler: @escaping @Sendable (FileMetadata) async throws -> FileClassification) {
        self.handler = handler
    }

    func classify(_ metadata: FileMetadata) async throws -> FileClassification {
        inputs.append(metadata)
        return try await handler(metadata)
    }
}

actor ProgressRecorder {
    private(set) var updates: [SortStatistics] = []
    func append(_ value: SortStatistics) { updates.append(value) }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

struct FaultingJournalStore: JournalStoring {
    let real: SortJournalStore
    let counter = Counter()
    let failOnSave: Int
    func lock() throws -> FileDescriptor { try real.lock() }
    func load() throws -> [SortJournal] { try real.load() }
    func save(_ journal: SortJournal) throws {
        if counter.increment() == failOnSave { throw SortingError.io("Simulated disk full", ENOSPC) }
        try real.save(journal)
    }
}
