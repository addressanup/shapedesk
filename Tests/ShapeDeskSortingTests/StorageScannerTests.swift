import XCTest
import Foundation
@testable import ShapeDeskSorting

final class StorageScannerTests: XCTestCase {
    private func allocated(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    func testListsVisibleTopLevelItemsWithoutFollowingLinks() throws {
        let fixture = try DesktopFixture()
        try fixture.file("report.pdf")
        try fixture.file("Projects/deep/nested.swift")
        try fixture.file("Tool.app/Contents/Info.plist")
        try fixture.file(".secret")
        try FileManager.default.createSymbolicLink(at: fixture.desktop.appendingPathComponent("Shortcut"),
                                                   withDestinationURL: fixture.base)
        let items = try StorageScanner.items(in: fixture.desktop)
        let kinds = Dictionary(uniqueKeysWithValues: items.map { ($0.url.lastPathComponent, $0.kind) })
        XCTAssertEqual(kinds, ["report.pdf": .file, "Projects": .folder, "Tool.app": .app])
        XCTAssertNotNil(items.first { $0.kind == .file }?.size)
        XCTAssertNil(items.first { $0.kind == .folder }?.size, "Folders are measured separately")
    }

    func testFolderSizeIncludesEverythingInsideAndHonorsCancellation() async throws {
        let fixture = try DesktopFixture()
        let files = try [fixture.file("Projects/a.bin", content: String(repeating: "a", count: 20_000)),
                         fixture.file("Projects/deep/b.bin", content: String(repeating: "b", count: 9_000)),
                         fixture.file("Projects/.hidden", content: "c")]
        let expected = try files.reduce(Int64(0)) { try $0 + allocated($1) }
        let projects = fixture.desktop.appendingPathComponent("Projects")
        XCTAssertEqual(try StorageScanner.size(of: projects), expected)
        XCTAssertEqual(try StorageScanner.size(of: files[0]), try allocated(files[0]))
        for index in 0..<300 { try fixture.file("Many/\(index).txt") }
        let task = Task { () throws -> Int64 in
            withUnsafeCurrentTask { $0?.cancel() }
            return try StorageScanner.size(of: fixture.desktop.appendingPathComponent("Many"))
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled measurement must stop")
        } catch is CancellationError {}
    }

    func testUnusedUsesLastOpenedThenDateAdded() throws {
        let fixture = try DesktopFixture()
        let opened = try fixture.file("opened-recently.pdf")
        try fixture.file("opened-long-ago.pdf")
        try fixture.file("Folder/inside.txt")
        let now = Date()
        let items = try StorageScanner.items(in: fixture.desktop) { url in
            url == opened ? now : url.lastPathComponent == "opened-long-ago.pdf" ? now.addingTimeInterval(-400 * 86_400) : nil
        }
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        let unused = items.filter { $0.isUnused(since: cutoff) }.map(\.url.lastPathComponent)
        XCTAssertEqual(unused, ["opened-long-ago.pdf"], "Never-opened items count from when they were added")
        let neverOpened = StorageItem(url: opened, name: "x", kind: .file, size: 1, lastOpened: nil,
                                      added: now.addingTimeInterval(-100 * 86_400))
        XCTAssertTrue(neverOpened.isUnused(since: cutoff))
    }

    func testApplicationsAreTopLevelAppBundlesOnly() throws {
        let fixture = try DesktopFixture()
        try fixture.file("Editor.app/Contents/Info.plist")
        try fixture.file("Vendor/Nested.app/Contents/Info.plist")
        try fixture.file("readme.txt")
        let apps = StorageScanner.applications(in: [fixture.desktop, fixture.base.appendingPathComponent("Missing")]) { _ in nil }
        XCTAssertEqual(apps.map(\.url.lastPathComponent), ["Editor.app"])
    }

    func testReleaseVersionsCompareNumerically() {
        XCTAssertTrue(UpdateCheck.isNewer("v1.4", than: "1.3"))
        XCTAssertTrue(UpdateCheck.isNewer("v1.10", than: "1.9"))
        XCTAssertTrue(UpdateCheck.isNewer("1.3.1", than: "1.3"))
        XCTAssertFalse(UpdateCheck.isNewer("v1.3", than: "1.3"))
        XCTAssertFalse(UpdateCheck.isNewer("v1.3.0", than: "1.3"))
        XCTAssertFalse(UpdateCheck.isNewer("v1.2.9", than: "1.3"))
        XCTAssertFalse(UpdateCheck.isNewer("nightly", than: "1.3"))
        XCTAssertEqual(UpdateCheck.numbers("v2.0-beta.1"), [2, 0])
    }
}
