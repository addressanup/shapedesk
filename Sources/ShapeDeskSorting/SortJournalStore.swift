import Foundation
import Darwin

protocol JournalStoring {
    func lock() throws -> FileDescriptor
    func load() throws -> [SortJournal]
    func save(_ journal: SortJournal) throws
}

/// A write-ahead journal: a move cannot begin until its exact source, destination
/// and file identity have reached disk. Intent records also recover a crash
/// between rename and the next UI update, without an unsafe post-move save.
struct SortJournalStore: JournalStoring {
    let directory: URL

    func lock() throws -> FileDescriptor {
        let dir = try openDirectory()
        let lock = try FileDescriptor(openat(dir.value, ".sort.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600),
                                      action: "Opening sorting lock")
        guard flock(lock.value, LOCK_EX | LOCK_NB) == 0 else { throw SortingError.busy }
        return lock
    }

    func load() throws -> [SortJournal] {
        let dir = try openDirectory()
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.map { url in
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else {
                throw SortingError.history("Unrecognized history file. No files were moved.")
            }
            let fd = try FileDescriptor(openat(dir.value, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC),
                                        action: "Reading undo history")
            var info = stat()
            guard fstat(fd.value, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 16_777_216 else {
                throw SortingError.history("Invalid history file. No files were moved.")
            }
            let handle = FileHandle(fileDescriptor: fd.value, closeOnDealloc: false)
            let data = try handle.readToEnd() ?? Data()
            let journal: SortJournal
            do { journal = try JSONDecoder().decode(SortJournal.self, from: data) }
            catch { throw SortingError.history("Could not read a saved operation. History has been preserved.") }
            guard journal.version == 1, url.lastPathComponent == "\(journal.id.uuidString).json",
                  journal.records.allSatisfy({
                      DesktopFileSystem.validName($0.originalName) && !$0.originalName.hasPrefix(".")
                      && DesktopFileSystem.validName($0.destinationName)
                      && ($0.restoredName.map(DesktopFileSystem.validName) ?? true)
                      && $0.confidence.isFinite && $0.confidence > 0.8 && $0.confidence <= 1
                  }) else { throw SortingError.history("Unsupported or unsafe undo record.") }
            return journal
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ journal: SortJournal) throws {
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 16_777_216 else {
            throw SortingError.history("This sort reached the history size limit. Remaining files were left in place.")
        }
        let dir = try openDirectory()
        let temporary = ".\(UUID().uuidString).tmp"
        let fd = try FileDescriptor(openat(dir.value, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600),
                                    action: "Creating undo record")
        defer { unlinkat(dir.value, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let amount = Darwin.write(fd.value, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw SortingError.io("Saving undo record", errno) }
                written += amount
            }
        }
        guard fsync(fd.value) == 0 else { throw SortingError.io("Syncing undo record", errno) }
        let destination = "\(journal.id.uuidString).json"
        guard renameat(dir.value, temporary, dir.value, destination) == 0 else {
            throw SortingError.io("Committing undo record", errno)
        }
        guard fsync(dir.value) == 0 else { throw SortingError.io("Syncing undo history", errno) }
    }

    private func openDirectory() throws -> FileDescriptor {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return try FileDescriptor(open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
                                  action: "Opening undo history safely")
    }
}
