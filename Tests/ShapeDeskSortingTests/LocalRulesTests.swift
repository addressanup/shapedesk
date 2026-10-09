import XCTest
import Foundation
@testable import ShapeDeskSorting

final class LocalRulesTests: XCTestCase {
    private func metadata(_ name: String) -> FileMetadata {
        FileMetadata(name: name, fileExtension: (name as NSString).pathExtension.lowercased(), byteSize: 1,
                     contentType: nil, mimeType: nil, createdAt: Date(), modifiedAt: Date())
    }

    func testObviousFilesAreClassifiedOnDevice() {
        let expected: [String: FileCategory] = [
            "Screenshot 2026-10-09 at 10.12.13.png": .screenshots,
            "Screen Shot 2019-01-02 at 9.00.00 AM.png": .screenshots,
            "CleanShot 2026-10-09 at 10.12.13@2x.png": .screenshots,
            "Bildschirmfoto 2026-10-09 um 10.12.13.png": .screenshots,
            "Screen Recording 2026-10-09 at 10.12.13.mov": .recordings,
            "CleanShot 2026-10-09 at 10.12.13.mp4": .recordings,
            "main.swift": .code, "notebook.ipynb": .code, "deploy.SH": .code,
            "Invoice.pdf": .docs, "Budget.xlsx": .docs, "Essay.pages": .docs,
            "Installer.dmg": .other, "backup.tar.gz": .other,
            "IMG_1234.HEIC": .images, "PXL_20261009_101213.jpg": .images, "DSC01234.ARW": .images,
            "anything.dng": .images,
            "IMG_5678.MOV": .videos, "GX010123.MP4": .videos,
            "Song.mp3": .audio, "Album Track.flac": .audio,
        ]
        for (name, category) in expected {
            XCTAssertEqual(LocalRules.category(for: metadata(name)), category, name)
        }
    }

    func testAmbiguousFilesAreLeftToTheAI() {
        for name in ["Photo.png", "IMG_1234.PNG", "Bildschirmfoto.png", "Screenshot of chart.png",
                     "notes.txt", "README.md", "data.json", "page.html", "clip.mov", "memo.m4a",
                     "Zoom meeting.mp3", "voice note.flac", "server.key", "episode.ts", "unknown"] {
            XCTAssertNil(LocalRules.category(for: metadata(name)), name)
        }
    }

    func testRulesFirstClassifierOnlyAsksTheAIAboutTheRest() async throws {
        let ai = StubClassifier(category: .images, confidence: 0.95)
        let classifier = RulesFirstClassifier(fallback: ai)
        let local = try await classifier.classify(metadata("Screenshot 2026-10-09 at 10.12.13.png"))
        XCTAssertEqual(local.category, .screenshots)
        XCTAssertEqual(local.confidence, 1)
        XCTAssertEqual(local.model, LocalRules.model)
        let remote = try await classifier.classify(metadata("Photo.png"))
        XCTAssertEqual(remote.category, .images)
        let asked = await ai.inputs.map(\.name)
        XCTAssertEqual(asked, ["Photo.png"])
    }

    func testSortCountsLocalMovesAndUndoesThem() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("Screenshot 2026-10-09 at 10.12.13.png")
        try fixture.file("Photo.png")
        let classifier = RulesFirstClassifier(fallback: StubClassifier(category: .images))
        let result = await fixture.sorter().sort(using: classifier)
        XCTAssertEqual(result.moved, 2)
        XCTAssertEqual(result.sortedLocally, 1)
        XCTAssertTrue(fixture.exists("Screenshots/Screenshot 2026-10-09 at 10.12.13.png"))
        XCTAssertTrue(fixture.exists("Images/Photo.png"))
        let undo = await fixture.sorter().undoLastSort()
        XCTAssertEqual(undo.restored, 2)
    }
}
