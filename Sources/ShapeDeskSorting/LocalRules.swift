import Foundation
import UniformTypeIdentifiers

/// Prefer identifiable screenshots and recordings, then use the file's known
/// type for its general category. A PNG does not need AI just because it could
/// conceivably be a screenshot. Genuinely ambiguous and unknown types go to AI.
public enum LocalRules {
    public static let model = "local-rules"

    private static let screenshot = try! NSRegularExpression(pattern:
        #"^(Screenshot|Screen[ _-]?Shot|CleanShot|Bildschirmfoto|Capture d’écran|Captura de pantalla|Schermata|Schermafbeelding|Skärmavbild|Captura de Tela|スクリーンショット)(\b|[_\d])"#, options: .caseInsensitive)
    private static let screenRecording = try! NSRegularExpression(pattern:
        #"^(Screen[ _-]?Recording|CleanShot|Bildschirmaufnahme|Enregistrement de l’écran|Grabación de pantalla)(\b|[_\d])"#, options: .caseInsensitive)
    /// Default names from phones and cameras (IMG_1234, PXL_2024…, DSC01234, GOPR0001…).
    private static let camera = try! NSRegularExpression(pattern:
        #"^(IMG|DSC|DSCF|DSCN|PXL|MVIMG|GOPR|GX\d{2}|DJI|MVI|VID)[_-]?\d{3,}"#, options: .caseInsensitive)
    private static let recordingWords = ["record", "meeting", "zoom", "teams", "call", "voice",
                                         "memo", "interview", "webinar", "podcast", "standup"]

    private static let code: Set = ["swift", "py", "js", "mjs", "cjs", "jsx", "tsx", "go", "rs", "c", "h", "cc",
                                    "cpp", "cxx", "hpp", "m", "mm", "java", "kt", "kts", "rb", "php", "cs",
                                    "scala", "sh", "bash", "zsh", "fish", "ps1", "lua", "pl", "sql", "ipynb",
                                    "vue", "svelte", "dart", "ex", "exs", "erl", "hs", "clj", "groovy", "jl", "zig",
                                    "html", "htm", "css", "scss", "sass", "less", "json", "jsonc", "jsonl",
                                    "yaml", "yml", "toml", "xml", "ini", "conf", "config"]
    private static let documents: Set = ["pdf", "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx",
                                         "rtf", "odt", "ods", "odp", "epub", "txt", "text", "md", "markdown",
                                         "rst", "csv", "tsv", "log", "tex", "mobi"]
    private static let archives: Set = ["zip", "dmg", "pkg", "mpkg", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "iso",
                                        "bz", "tbz", "tbz2", "txz", "zst", "lz", "lzma", "cab"]
    private static let rawPhotos: Set = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "pef"]
    private static let images: Set = ["png", "jpg", "jpeg", "jpe", "heic", "heif", "gif", "webp", "avif",
                                      "tif", "tiff", "bmp", "svg", "svgz", "ico", "icns", "psd", "psb", "exr", "jxl"]
    private static let videos: Set = ["mov", "mp4", "m4v", "mts", "m2ts", "avi", "mkv", "webm", "mpg", "mpeg",
                                      "m2v", "wmv", "flv", "3gp", "3g2", "ogv"]
    private static let audio: Set = ["mp3", "flac", "aif", "aiff", "ogg", "opus", "wma", "wav", "wave", "m4a",
                                     "aac", "alac", "caf", "amr", "mid", "midi"]

    public static func category(for metadata: FileMetadata) -> FileCategory? {
        let ext = metadata.fileExtension.lowercased()
        let stem = (metadata.name as NSString).deletingPathExtension
        if code.contains(ext) { return .code }
        if documents.contains(ext) { return .docs }
        if archives.contains(ext) { return .other }
        // .ts can be TypeScript or MPEG transport stream; .key can be a
        // presentation or a cryptographic key. Extension-derived types alone
        // cannot resolve these conflicts.
        if ext == "ts" || ext == "key" { return nil }
        let type = [UTType(filenameExtension: ext),
                    metadata.contentType.flatMap { UTType($0) },
                    metadata.mimeType.flatMap { UTType(mimeType: $0) }]
            .compactMap { $0 }.first { !$0.isDynamic }
        if images.contains(ext) || rawPhotos.contains(ext) || type?.conforms(to: .image) == true {
            return matches(screenshot, stem) ? .screenshots : .images
        }
        if videos.contains(ext) || type?.conforms(to: .movie) == true {
            if matches(screenRecording, stem) { return .recordings }
            if matches(camera, stem) { return .videos }
            return suggestsRecording(stem) ? nil : .videos
        }
        if audio.contains(ext) || type?.conforms(to: .audio) == true {
            return suggestsRecording(stem) ? nil : .audio
        }
        if type?.conforms(to: .sourceCode) == true { return .code }
        if type?.conforms(to: .plainText) == true || type?.conforms(to: .pdf) == true
            || type?.conforms(to: .spreadsheet) == true || type?.conforms(to: .presentation) == true {
            return .docs
        }
        if type?.conforms(to: .archive) == true { return .other }
        return nil
    }

    private static func suggestsRecording(_ stem: String) -> Bool {
        let lowered = stem.lowercased()
        return recordingWords.contains(where: lowered.contains)
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// Sorts obvious files on the Mac without an AI check and asks `fallback`
/// about everything else. Moves still go through the same journaled pipeline.
public struct RulesFirstClassifier: FileClassifying {
    private let fallback: any FileClassifying

    public init(fallback: any FileClassifying) { self.fallback = fallback }

    public func classify(_ metadata: FileMetadata) async throws -> FileClassification {
        if let category = LocalRules.category(for: metadata) {
            return FileClassification(category: category, confidence: 1, model: LocalRules.model)
        }
        return try await fallback.classify(metadata)
    }
}
