import Foundation

public enum FileCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case screenshots = "Screenshots"
    case recordings = "Recordings"
    case videos = "Videos"
    case audio = "Audio"
    case images = "Images"
    case docs = "Docs"
    case code = "Code"
    case other = "Other"

    public var id: String { rawValue }

    var definition: String {
        switch self {
        case .screenshots: return "Still screen captures, including macOS Screenshot or Screen Shot files. Takes precedence over Images."
        case .recordings: return "Screen recordings or identifiable meeting/voice recordings. Takes precedence over Videos and Audio."
        case .videos: return "Movies, clips and other video files without evidence of being a screen or meeting recording."
        case .audio: return "Music, sound effects and other audio files without evidence of being a meeting or voice recording."
        case .images: return "Photos, illustrations and other still images that are not screenshots."
        case .docs: return "Documents, PDFs, spreadsheets, presentations, notes and ordinary prose text."
        case .code: return "Source code, scripts, programming notebooks, markup and software configuration files."
        case .other: return "Files outside these categories, including archives, installers and unknown file types."
        }
    }
}

/// This is the entire remote state. Neither file contents nor full paths are sent.
public struct FileMetadata: Codable, Equatable, Sendable {
    public let name: String
    public let fileExtension: String
    public let byteSize: Int64
    public let contentType: String?
    public let mimeType: String?
    public let createdAt: Date
    public let modifiedAt: Date
}

public struct FileClassification: Sendable {
    public let category: FileCategory
    public let confidence: Double
    public let model: String

    public init(category: FileCategory, confidence: Double, model: String) {
        self.category = category
        self.confidence = confidence
        self.model = model
    }

    /// Deliberately strict: 0.8 itself must never authorize a move.
    public var permitsMove: Bool { confidence.isFinite && confidence > 0.8 && confidence <= 1 }
}

public protocol FileClassifying: Sendable {
    func classify(_ metadata: FileMetadata) async throws -> FileClassification
}

public struct CategoryStatistics: Equatable, Sendable {
    public internal(set) var moved = 0
    public internal(set) var skipped = 0
}

public struct SortStatistics: Equatable, Sendable {
    public enum Phase: String, Sendable { case idle, scanning, sorting, completed, cancelled, failed }
    public internal(set) var phase: Phase = .idle
    public internal(set) var totalScanned = 0
    public internal(set) var moved = 0
    public internal(set) var skipped = 0
    public internal(set) var errors = 0
    public internal(set) var currentFile: String?
    public internal(set) var lastIssue: String?
    public internal(set) var message = "Sort desktop files into folders with AI."
    public internal(set) var categories = Dictionary(uniqueKeysWithValues:
        FileCategory.allCases.map { ($0, CategoryStatistics()) })
    public var processed: Int { moved + skipped }
    public var remaining: Int { max(0, totalScanned - processed) }
    public var unclassifiedSkipped: Int { skipped - categories.values.reduce(0) { $0 + $1.skipped } }
    public init() {}
}

public struct UndoStatistics: Equatable, Sendable {
    public internal(set) var total = 0
    public internal(set) var restored = 0
    public internal(set) var skipped = 0
    public internal(set) var isRunning = false
    public internal(set) var message = ""
    public init() {}
}

enum SortingError: LocalizedError {
    case busy, changed, locked, inUse, unsafePath, missing, history(String), io(String, Int32)

    var errorDescription: String? {
        switch self {
        case .busy: return "Another sorting or undo operation is running."
        case .changed: return "The file changed during sorting; it was left alone."
        case .locked: return "The file is locked or not writable."
        case .inUse: return "The file is open, still downloading, or recently modified."
        case .unsafePath: return "A folder or file was replaced, is a link, or has an unsafe path."
        case .missing: return "The original file is no longer at its recorded location."
        case .history(let message): return "Undo history: \(message)"
        case .io(let action, let code): return "\(action): \(String(cString: strerror(code)))"
        }
    }
}

struct FileIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
}

struct FileSnapshot: Sendable {
    let metadata: FileMetadata
    let identity: FileIdentity
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

struct MoveRecord: Codable, Sendable {
    var id = UUID()
    let originalName: String
    let category: FileCategory
    var destinationName: String
    let identity: FileIdentity
    let confidence: Double
    let model: String
    /// Written before undo's rename, so an interrupted undo is also recoverable.
    var restoredName: String?
    var resolved = false
}

struct SortJournal: Codable, Sendable {
    var version = 1
    var id = UUID()
    var createdAt = Date()
    let desktopPath: String
    let desktopIdentity: FileIdentity
    var records: [MoveRecord] = []
}
