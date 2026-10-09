import Foundation

/// Deterministic rules for files whose category is beyond doubt. They follow the
/// category definitions sent to the AI, and anything ambiguous (a plain .png
/// could be a screenshot, an .m4a a voice memo, a .ts a video) is left to the AI.
public enum LocalRules {
    public static let model = "local-rules"

    private static let screenshot = try! NSRegularExpression(pattern:
        #"^(Screenshot|Screen Shot|CleanShot|Bildschirmfoto|Capture d’écran|Captura de pantalla|Schermata|Schermafbeelding|Skärmavbild|Captura de Tela|スクリーンショット) ?\d{4}-\d{2}-\d{2}"#)
    private static let screenRecording = try! NSRegularExpression(pattern:
        #"^(Screen Recording|CleanShot|Bildschirmaufnahme|Enregistrement de l’écran|Grabación de pantalla) ?\d{4}-\d{2}-\d{2}"#)
    /// Default names from phones and cameras (IMG_1234, PXL_2024…, DSC01234, GOPR0001…).
    private static let camera = try! NSRegularExpression(pattern:
        #"^(IMG|DSC|DSCF|DSCN|PXL|MVIMG|GOPR|GX\d{2}|DJI|MVI|VID)[_-]?\d{3,}"#, options: .caseInsensitive)
    private static let recordingWords = ["record", "meeting", "zoom", "teams", "call", "voice",
                                         "memo", "interview", "webinar", "podcast", "standup"]

    private static let screenStills: Set = ["png", "jpg", "jpeg", "heic", "tif", "tiff"]
    private static let screenVideos: Set = ["mov", "mp4", "m4v"]
    private static let code: Set = ["swift", "py", "js", "mjs", "cjs", "jsx", "tsx", "go", "rs", "c", "h", "cc",
                                    "cpp", "cxx", "hpp", "m", "mm", "java", "kt", "kts", "rb", "php", "cs",
                                    "scala", "sh", "bash", "zsh", "fish", "ps1", "lua", "pl", "sql", "ipynb",
                                    "vue", "svelte", "dart", "ex", "exs", "erl", "hs", "clj", "groovy", "jl", "zig"]
    private static let documents: Set = ["pdf", "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx",
                                         "rtf", "odt", "ods", "odp", "epub"]
    private static let archives: Set = ["zip", "dmg", "pkg", "mpkg", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "iso"]
    private static let rawPhotos: Set = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "pef"]
    private static let cameraPhotos: Set = ["heic", "heif", "jpg", "jpeg"]
    private static let cameraVideos: Set = ["mov", "mp4", "m4v", "mts", "avi"]
    private static let music: Set = ["mp3", "flac", "aif", "aiff", "ogg", "opus", "wma"]

    public static func category(for metadata: FileMetadata) -> FileCategory? {
        let ext = metadata.fileExtension.lowercased()
        let stem = (metadata.name as NSString).deletingPathExtension
        if screenStills.contains(ext), matches(screenshot, stem) { return .screenshots }
        if screenVideos.contains(ext), matches(screenRecording, stem) { return .recordings }
        if code.contains(ext) { return .code }
        if documents.contains(ext) { return .docs }
        if archives.contains(ext) { return .other }
        if rawPhotos.contains(ext) || (cameraPhotos.contains(ext) && matches(camera, stem)) { return .images }
        if cameraVideos.contains(ext), matches(camera, stem) { return .videos }
        let lowered = stem.lowercased()
        if music.contains(ext), !recordingWords.contains(where: lowered.contains) { return .audio }
        return nil
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
