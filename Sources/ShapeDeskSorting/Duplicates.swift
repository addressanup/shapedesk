import Foundation

public struct DuplicateFile: Identifiable, Equatable, Sendable {
    let snapshot: FileSnapshot
    public var id: String { name }
    public var name: String { snapshot.metadata.name }
    public var byteSize: Int64 { snapshot.metadata.byteSize }
    public var createdAt: Date { snapshot.metadata.createdAt }
}

/// Files in one folder with byte-for-byte identical contents.
public struct DuplicateGroup: Identifiable, Equatable, Sendable {
    public let id: String
    /// The copy most likely to be the original comes first.
    public let files: [DuplicateFile]
    /// Name of the copy that stays in place; every other copy is moved.
    public var keeper: String
    public var byteSize: Int64 { files.first?.byteSize ?? 0 }
    public var extraCopies: Int { files.count - 1 }
    public var wastedBytes: Int64 { byteSize * Int64(extraCopies) }
}

public struct DuplicateScan: Equatable, Sendable {
    public let folder: URL
    let rootIdentity: FileIdentity
    public var groups: [DuplicateGroup]
    public let scannedFiles: Int
    /// Files that could not be compared: locked, unreadable, changing or not downloaded.
    public let unreadableFiles: Int
    public var extraCopies: Int { groups.reduce(0) { $0 + $1.extraCopies } }
    public var wastedBytes: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }
}

/// Weighted by bytes to read, assuming every large candidate needs a full read;
/// files ruled out early count as done, so progress only moves forward.
public struct DuplicateScanProgress: Equatable, Sendable {
    public internal(set) var bytesDone: Int64 = 0
    public internal(set) var bytesTotal: Int64 = 0
    public internal(set) var currentFile: String?
    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
    public init() {}
}

public struct DuplicateMoveStatistics: Equatable, Sendable {
    public enum Phase: String, Sendable { case idle, moving, completed, cancelled, failed }
    public internal(set) var phase: Phase = .idle
    public internal(set) var total = 0
    public internal(set) var moved = 0
    public internal(set) var skipped = 0
    public internal(set) var movedBytes: Int64 = 0
    public internal(set) var lastIssue: String?
    public internal(set) var message = ""
    public var processed: Int { moved + skipped }
    public init() {}
}

/// Finds duplicates among the visible regular files directly inside a folder,
/// with the same filters as AI Sort. Subfolders are never read.
public enum DuplicateFinder {
    public static let folderName = "Duplicates"
    static let model = "sha256-duplicate"
    static let prefixLength = 64 * 1024

    public static func scan(folder: URL,
                            onProgress: @Sendable (DuplicateScanProgress) async -> Void = { _ in }) async throws -> DuplicateScan {
        try await scan(files: DesktopFileSystem(desktop: folder), onProgress: onProgress)
    }

    static func scan(files: DesktopFileSystem,
                     onProgress: @Sendable (DuplicateScanProgress) async -> Void) async throws -> DuplicateScan {
        let rootIdentity = try files.rootIdentity()
        var snapshots: [FileSnapshot] = []
        var identities = Set<FileIdentity>()
        var unreadable = 0
        for name in try files.names() {
            try Task.checkCancellation()
            do {
                // Two hard links to one file share an identity and free nothing when moved.
                guard let snapshot = try files.snapshot(name: name, rootIdentity: rootIdentity),
                      identities.insert(snapshot.identity).inserted else { continue }
                snapshots.append(snapshot)
            } catch { unreadable += 1 }
        }

        // Only files sharing a size can match, and empty files are not worth moving.
        var buckets = Dictionary(grouping: snapshots.filter { $0.metadata.byteSize > 0 }) { $0.metadata.byteSize }
            .values.filter { $0.count > 1 }.map { $0 }
        let largeBytes = { (buckets: [[FileSnapshot]]) in
            buckets.joined().filter { $0.metadata.byteSize > prefixLength }.reduce(Int64(0)) { $0 + $1.metadata.byteSize }
        }
        let large = largeBytes(buckets)
        var progress = DuplicateScanProgress()
        progress.bytesTotal = buckets.joined().reduce(large) { $0 + min($1.metadata.byteSize, Int64(prefixLength)) }
        await onProgress(progress)

        // A short prefix tells most same-size files apart before reading them whole.
        for pass in [prefixLength, Int.max] {
            var refined: [[FileSnapshot]] = []
            for bucket in buckets {
                var byDigest: [Data: [FileSnapshot]] = [:]
                for snapshot in bucket {
                    try Task.checkCancellation()
                    let size = snapshot.metadata.byteSize
                    if pass == .max && size <= prefixLength {
                        byDigest[Data(), default: []].append(snapshot) // The prefix pass read it whole.
                        continue
                    }
                    progress.currentFile = snapshot.metadata.name
                    await onProgress(progress)
                    do {
                        byDigest[try files.digest(of: snapshot, rootIdentity: rootIdentity, limit: pass), default: []]
                            .append(snapshot)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch { unreadable += 1 }
                    progress.bytesDone += min(size, Int64(pass))
                }
                refined += byDigest.values.filter { $0.count > 1 }
            }
            buckets = refined
            // Large files ruled out by their prefix never need a full read.
            if pass == prefixLength { progress.bytesDone += large - largeBytes(buckets) }
        }
        progress.currentFile = nil
        await onProgress(progress)

        let groups = buckets.map { bucket -> DuplicateGroup in
            let files = bucket.map(DuplicateFile.init).sorted(by: keepFirst)
            return DuplicateGroup(id: files[0].name, files: files, keeper: files[0].name)
        }.sorted { $0.wastedBytes == $1.wastedBytes ? $0.id < $1.id : $0.wastedBytes > $1.wastedBytes }
        return DuplicateScan(folder: files.desktop, rootIdentity: rootIdentity, groups: groups,
                             scannedFiles: snapshots.count, unreadableFiles: unreadable)
    }

    /// Prefers names without a copy marker ("report copy.pdf", "report (1).pdf"),
    /// then the oldest file, then the shortest name.
    static func keepFirst(_ a: DuplicateFile, _ b: DuplicateFile) -> Bool {
        let aCopy = isCopyName(a.name), bCopy = isCopyName(b.name)
        if aCopy != bCopy { return !aCopy }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        if a.name.count != b.name.count { return a.name.count < b.name.count }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    static func isCopyName(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        return stem.range(of: #"( copy( \d+)?| \(\d+\))$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
