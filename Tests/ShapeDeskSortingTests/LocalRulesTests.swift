import XCTest
import Foundation
@testable import ShapeDeskSorting

final class LocalRulesTests: XCTestCase {
    private func metadata(_ name: String, contentType: String? = nil, mimeType: String? = nil) -> FileMetadata {
        FileMetadata(name: name, fileExtension: (name as NSString).pathExtension.lowercased(), byteSize: 1,
                     contentType: contentType, mimeType: mimeType, createdAt: Date(), modifiedAt: Date())
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

    func testCommonFormatsHaveReliableCategoriesWithoutAI() {
        let formats: [FileCategory: [String]] = [
            .images: ["png", "PNG", "jpg", "jpeg", "heic", "heif", "webp", "gif", "avif", "bmp", "tiff",
                      "svg", "psd", "ico", "icns", "exr", "jxl", "cr3"],
            .videos: ["mov", "mp4", "m4v", "mkv", "webm", "avi", "mpg", "mpeg", "m2ts", "wmv", "3gp"],
            .audio: ["mp3", "wav", "m4a", "aac", "flac", "aiff", "ogg", "opus", "caf", "midi"],
            .docs: ["txt", "md", "markdown", "csv", "tsv", "log", "pdf", "docx", "xlsx", "pptx", "epub", "odt"],
            .code: ["swift", "py", "html", "css", "scss", "json", "jsonc", "jsonl", "yaml", "yml", "toml", "xml", "ini"],
            .other: ["zip", "dmg", "pkg", "7z", "gz", "xz", "zst", "cab"]
        ]
        for (category, extensions) in formats {
            for ext in extensions {
                XCTAssertEqual(LocalRules.category(for: metadata("example.\(ext)")), category, ext)
            }
        }
    }

    func testCaptureNamesTakePrecedenceOnlyForMatchingMediaTypes() {
        let expected: [String: FileCategory] = [
            "Screenshot of chart.png": .screenshots, "screenshot_123.WEBP": .screenshots,
            "screen-shot.png": .screenshots, "Bildschirmfoto.png": .screenshots,
            "スクリーンショット2026-10-13.png": .screenshots,
            "Screen Recording.webm": .recordings, "screen_recording_123.MKV": .recordings,
            "CleanShot 2026-10-13.mp4": .recordings,
            "Screenshot.pdf": .docs, "screen-recording.py": .code,
            "IMG_1234.PNG": .images, "Photo.png": .images
        ]
        for (name, category) in expected {
            XCTAssertEqual(LocalRules.category(for: metadata(name)), category, name)
        }
    }

    func testSystemTypesExtendCoverageWithoutTreatingEveryFileAsKnown() {
        XCTAssertEqual(LocalRules.category(for: metadata("photo", contentType: "public.png")), .images)
        XCTAssertEqual(LocalRules.category(for: metadata("clip.custom-video", contentType: "public.mpeg-4")), .videos)
        XCTAssertEqual(LocalRules.category(for: metadata("sound.custom-audio", mimeType: "audio/wav")), .audio)
        XCTAssertEqual(LocalRules.category(for: metadata("notes", mimeType: "text/plain")), .docs)
        XCTAssertEqual(LocalRules.category(for: metadata("archive", contentType: "public.zip-archive")), .other)
        XCTAssertEqual(LocalRules.category(for: metadata("photo.png", contentType: "public.audio")), .images)
        XCTAssertNil(LocalRules.category(for: metadata("data.custom-format", contentType: "public.data",
                                                      mimeType: "application/octet-stream")))
        XCTAssertNil(LocalRules.category(for: metadata("episode.ts", contentType: "public.mpeg-2-transport-stream",
                                                      mimeType: "video/mp2t")))
    }

    func testAmbiguousFilesAreLeftToTheAI() {
        for name in ["memo.m4a", "Zoom meeting.mov",
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
        let remote = try await classifier.classify(metadata("unknown"))
        XCTAssertEqual(remote.category, .images)
        let asked = await ai.inputs.map(\.name)
        XCTAssertEqual(asked, ["unknown"])
    }

    func testSortCountsLocalMovesAndUndoesThem() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("Screenshot 2026-10-09 at 10.12.13.png")
        try fixture.file("Photo.png")
        let classifier = RulesFirstClassifier(fallback: StubClassifier(category: .images))
        let result = await fixture.sorter().sort(using: classifier)
        XCTAssertEqual(result.moved, 2)
        XCTAssertEqual(result.sortedLocally, 2)
        XCTAssertTrue(fixture.exists("Screenshots/Screenshot 2026-10-09 at 10.12.13.png"))
        XCTAssertTrue(fixture.exists("Images/Photo.png"))
        let undo = await fixture.sorter().undoLastSort()
        XCTAssertEqual(undo.restored, 2)
    }

    func testMixedFileTypesSortAndUndoEvenWhenAICannotClassifyTheRest() async throws {
        let fixture = try DesktopFixture()
        let expected: [String: FileCategory] = [
            "Photo.PNG": .images, "artwork.webp": .images, "logo.svg": .images,
            "Screenshot of chart.avif": .screenshots, "clip.mkv": .videos,
            "Screen Recording.webm": .recordings, "sound.wav": .audio, "song.m4a": .audio,
            "notes.txt": .docs, "README.md": .docs, "data.csv": .docs,
            "config.json": .code, "page.html": .code, "backup.zst": .other
        ]
        for name in expected.keys { try fixture.file(name, content: "Contents of \(name)") }
        try fixture.file("unknown")
        try fixture.file("episode.ts")
        try fixture.file("Images/existing.png")
        try fixture.file("Project/nested.png")
        let ai = StubClassifier(category: .other, confidence: 0.8)
        let result = await fixture.sorter().sort(using: RulesFirstClassifier(fallback: ai))
        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.totalScanned, expected.count + 2)
        XCTAssertEqual(result.moved, expected.count)
        XCTAssertEqual(result.sortedLocally, expected.count)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(result.errors, 0)
        let asked = await ai.inputs.map(\.name)
        XCTAssertEqual(Set(asked), ["unknown", "episode.ts"])
        for (name, category) in expected {
            XCTAssertEqual(try fixture.contents("\(category.rawValue)/\(name)"), "Contents of \(name)")
        }
        XCTAssertTrue(fixture.exists("unknown"))
        XCTAssertTrue(fixture.exists("episode.ts"))
        XCTAssertTrue(fixture.exists("Images/existing.png"))
        XCTAssertTrue(fixture.exists("Project/nested.png"))

        let undo = await fixture.sorter().undoLastSort()
        XCTAssertEqual(undo.restored, expected.count)
        XCTAssertEqual(undo.skipped, 0)
        for name in expected.keys {
            XCTAssertEqual(try fixture.contents(name), "Contents of \(name)")
        }
    }

    func testExpandedRulesStillLeaveBusyRecentAndFailedFilesInPlace() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("photo.png")
        try fixture.file("busy.png")
        let recent = try fixture.file("recent.webp")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: recent.path)
        try fixture.file("unknown")
        let ai = StubClassifier { _ in throw URLError(.notConnectedToInternet) }
        let result = await fixture.sorter(files: fixture.files(useChecker: BusyFiles(), minimumAge: 2))
            .sort(using: RulesFirstClassifier(fallback: ai))
        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.sortedLocally, 1)
        XCTAssertEqual(result.skipped, 3)
        XCTAssertEqual(result.errors, 3)
        XCTAssertTrue(fixture.exists("Images/photo.png"))
        for name in ["busy.png", "recent.webp", "unknown"] {
            XCTAssertTrue(fixture.exists(name), name)
        }
    }
}
