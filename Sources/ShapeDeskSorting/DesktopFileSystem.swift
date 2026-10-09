import Foundation
import CryptoKit
import UniformTypeIdentifiers
import Darwin

final class FileDescriptor {
    let value: Int32
    init(_ value: Int32, action: String) throws {
        guard value >= 0 else { throw SortingError.io(action, errno) }
        self.value = value
    }
    deinit { Darwin.close(value) }
}

extension FileIdentity {
    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        birthSeconds = Int64(info.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
    }
}

protocol FileUseChecking {
    func isInUse(_ url: URL) throws -> Bool
}

/// Advisory locks alone do not catch editors and recording apps that keep files open.
/// A bounded lsof check complements the nonblocking lock and final metadata check.
struct OpenFileUseChecker: FileUseChecking {
    func isInUse(_ url: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", "--", url.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 3) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw SortingError.inUse
        }
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0 { return true }
        guard process.terminationStatus == 1, errorData.isEmpty else { throw SortingError.inUse }
        return false
    }
}

/// Every move uses directory-relative descriptors and RENAME_EXCL. FileManager's
/// exists-then-move pattern cannot protect against another writer winning a race.
final class DesktopFileSystem {
    typealias Rename = (Int32, String, Int32, String) throws -> Void
    let desktop: URL
    private let useChecker: any FileUseChecking
    private let minimumAge: TimeInterval
    private let rename: Rename

    init(desktop: URL, useChecker: any FileUseChecking = OpenFileUseChecker(),
         minimumAge: TimeInterval = 2, rename: @escaping Rename = exclusiveRename) {
        self.desktop = desktop.standardizedFileURL.resolvingSymlinksInPath()
        self.useChecker = useChecker
        self.minimumAge = minimumAge
        self.rename = rename
    }

    static func exclusiveRename(_ sourceFD: Int32, _ source: String,
                                _ destinationFD: Int32, _ destination: String) throws {
        guard renameatx_np(sourceFD, source, destinationFD, destination, UInt32(RENAME_EXCL)) == 0 else {
            throw SortingError.io("Moving file", errno)
        }
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// Destination folders are always visible, direct children of the root.
    static func validFolder(_ name: String?) -> Bool {
        guard let name else { return false }
        return validName(name) && !name.hasPrefix(".")
    }

    private func openRoot(expected: FileIdentity? = nil) throws -> FileDescriptor {
        let root = try FileDescriptor(open(desktop.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
                                      action: "Opening folder")
        if let expected, try identity(of: root) != expected { throw SortingError.unsafePath }
        return root
    }

    func rootIdentity() throws -> FileIdentity { try identity(of: openRoot()) }

    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: desktop,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// nil excludes directories (including our target folders), links, aliases and
    /// Finder-hidden files. Enumeration never descends into any directory.
    func snapshot(name: String, rootIdentity: FileIdentity) throws -> FileSnapshot? {
        guard Self.validName(name), !name.hasPrefix(".") else { return nil }
        let root = try openRoot(expected: rootIdentity)
        let info = try information(name, in: root)
        guard (info.st_mode & S_IFMT) == S_IFREG, (info.st_flags & UInt32(UF_HIDDEN)) == 0 else { return nil }
        let url = desktop.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isHiddenKey, .isAliasFileKey])
        guard values.isHidden != true, values.isAliasFile != true else { return nil }
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        return FileSnapshot(metadata: FileMetadata(name: name, fileExtension: ext,
            byteSize: info.st_size, contentType: type?.identifier, mimeType: type?.preferredMIMEType,
            createdAt: Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec)),
            modifiedAt: Date(timeIntervalSince1970: Self.modificationTime(info))),
            identity: FileIdentity(info), modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    /// Called after classification. The journal callback must complete durably
    /// before rename. There is deliberately no fallible bookkeeping after success.
    func move(_ snapshot: FileSnapshot, toFolder folder: String, rootIdentity: FileIdentity,
              prepare: (String) throws -> Void) throws -> String {
        guard Self.validFolder(folder) else { throw SortingError.unsafePath }
        let root = try openRoot(expected: rootIdentity)
        let name = snapshot.metadata.name
        let source = try lockFile(name: name, in: root, url: desktop.appendingPathComponent(name),
                                  identity: snapshot.identity)
        try unchanged(snapshot, descriptor: source)
        let destination = try destinationDirectory(folder, root: root, create: true)
        defer { withExtendedLifetime((root, source, destination)) {} }
        for index in 0..<10_000 {
            try Task.checkCancellation()
            let target = Self.collisionName(name, index: index)
            if try exists(target, in: destination) { continue }
            try prepare(target)
            try Task.checkCancellation()
            try unchanged(snapshot, descriptor: source)
            try checkName(name, in: root, identity: snapshot.identity)
            try checkName(folder, in: root, identity: identity(of: destination))
            do {
                try rename(root.value, name, destination.value, target)
                return target
            } catch SortingError.io(_, let code) where code == EEXIST {
                continue // Another process claimed this name; never replace it.
            }
        }
        throw SortingError.io("No unused filename available", EEXIST)
    }

    func restore(_ record: MoveRecord, rootIdentity: FileIdentity,
                 prepare: (String) throws -> Void) throws -> String {
        guard Self.validName(record.originalName), Self.validName(record.destinationName),
              let folder = record.folderName, Self.validFolder(folder) else {
            throw SortingError.unsafePath
        }
        let root = try openRoot(expected: rootIdentity)
        let directory = try destinationDirectory(folder, root: root, create: false)
        let sourceURL = desktop.appendingPathComponent(folder)
            .appendingPathComponent(record.destinationName)
        let source = try lockFile(name: record.destinationName, in: directory,
                                  url: sourceURL, identity: record.identity)
        // Keep the descriptor (and its exclusive lock) alive through the rename.
        defer { withExtendedLifetime((root, source, directory)) {} }
        for index in 0..<10_000 {
            try Task.checkCancellation()
            let name = Self.collisionName(record.originalName, index: index)
            if try exists(name, in: root) { continue }
            try prepare(name)
            try Task.checkCancellation()
            try checkName(record.destinationName, in: directory, identity: record.identity)
            try checkName(folder, in: root, identity: identity(of: directory))
            do {
                try rename(directory.value, record.destinationName, root.value, name)
                return name
            } catch SortingError.io(_, let code) where code == EEXIST {
                continue
            }
        }
        throw SortingError.io("No unused filename available for undo", EEXIST)
    }

    enum RecordLocation { case atDestination, atOriginal, restored, missing }

    func location(of record: MoveRecord, rootIdentity: FileIdentity) throws -> RecordLocation {
        guard Self.validName(record.originalName), Self.validName(record.destinationName),
              let folder = record.folderName, Self.validFolder(folder),
              record.restoredName.map(Self.validName) ?? true else { throw SortingError.unsafePath }
        let root = try openRoot(expected: rootIdentity)
        if let name = record.restoredName, try matches(name, in: root, identity: record.identity) { return .restored }
        if try matches(record.originalName, in: root, identity: record.identity) { return .atOriginal }
        do {
            let directory = try destinationDirectory(folder, root: root, create: false)
            if try matches(record.destinationName, in: directory, identity: record.identity) { return .atDestination }
        } catch SortingError.io(_, let code) where code == ENOENT {
            return .missing
        }
        return .missing
    }

    /// True when the scanned file is still in place with the same identity, size
    /// and modification time.
    func isUnchanged(_ snapshot: FileSnapshot, rootIdentity: FileIdentity) throws -> Bool {
        let root = try openRoot(expected: rootIdentity)
        do {
            let info = try information(snapshot.metadata.name, in: root)
            return FileIdentity(info) == snapshot.identity && info.st_size == snapshot.metadata.byteSize
                && Int64(info.st_mtimespec.tv_sec) == snapshot.modifiedSeconds
                && Int64(info.st_mtimespec.tv_nsec) == snapshot.modifiedNanoseconds
        } catch SortingError.io(_, let code) where code == ENOENT {
            return false
        }
    }

    /// SHA-256 of a scanned file's contents (or of its first `limit` bytes).
    /// The descriptor is checked against the snapshot before and after reading,
    /// and files whose data is not on this Mac are refused rather than downloaded.
    func digest(of snapshot: FileSnapshot, rootIdentity: FileIdentity, limit: Int = .max) throws -> Data {
        let root = try openRoot(expected: rootIdentity)
        let name = snapshot.metadata.name
        let file = try FileDescriptor(openat(root.value, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC),
                                      action: "Opening file safely")
        try unchanged(snapshot, descriptor: file)
        var info = stat()
        guard fstat(file.value, &info) == 0 else { throw SortingError.io("Checking file", errno) }
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw SortingError.inUse }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var remaining = limit
        while remaining > 0 {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file.value, $0.baseAddress, min($0.count, remaining)) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw SortingError.io("Reading file", errno) }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            remaining -= count
        }
        try unchanged(snapshot, descriptor: file)
        return Data(hasher.finalize())
    }

    private func lockFile(name: String, in directory: FileDescriptor, url: URL,
                          identity: FileIdentity) throws -> FileDescriptor {
        let info = try information(name, in: directory)
        guard FileIdentity(info) == identity, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1 else { throw SortingError.changed }
        let forbiddenFlags = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
        guard info.st_flags & forbiddenFlags == 0, info.st_mode & S_IWUSR != 0 else { throw SortingError.locked }
        let partialExtensions: Set<String> = ["download", "crdownload", "partial", "part", "tmp", "temp"]
        guard !partialExtensions.contains(url.pathExtension.lowercased()),
              Date().timeIntervalSince1970 - Self.modificationTime(info) >= minimumAge else { throw SortingError.inUse }
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
            throw SortingError.inUse
        }
        guard try !useChecker.isInUse(url) else { throw SortingError.inUse }
        let file = try FileDescriptor(openat(directory.value, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC),
                                      action: "Opening file safely")
        guard flock(file.value, LOCK_EX | LOCK_NB) == 0 else { throw SortingError.locked }
        guard try self.identity(of: file) == identity else { throw SortingError.changed }
        return file
    }

    private func destinationDirectory(_ folder: String, root: FileDescriptor, create: Bool) throws -> FileDescriptor {
        if create && mkdirat(root.value, folder, 0o755) != 0 && errno != EEXIST {
            throw SortingError.io("Creating \(folder) folder", errno)
        }
        return try FileDescriptor(openat(root.value, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
                                  action: "Opening \(folder) folder safely")
    }

    private func unchanged(_ snapshot: FileSnapshot, descriptor: FileDescriptor) throws {
        var info = stat()
        guard fstat(descriptor.value, &info) == 0 else { throw SortingError.io("Checking file", errno) }
        guard FileIdentity(info) == snapshot.identity, info.st_size == snapshot.metadata.byteSize,
              Int64(info.st_mtimespec.tv_sec) == snapshot.modifiedSeconds,
              Int64(info.st_mtimespec.tv_nsec) == snapshot.modifiedNanoseconds else { throw SortingError.changed }
    }

    private func checkName(_ name: String, in directory: FileDescriptor, identity: FileIdentity) throws {
        guard try matches(name, in: directory, identity: identity) else { throw SortingError.changed }
    }

    private func matches(_ name: String, in directory: FileDescriptor, identity: FileIdentity) throws -> Bool {
        do { return try FileIdentity(information(name, in: directory)) == identity }
        catch SortingError.io(_, let code) where code == ENOENT { return false }
    }

    private func information(_ name: String, in directory: FileDescriptor) throws -> stat {
        guard Self.validName(name) else { throw SortingError.unsafePath }
        var info = stat()
        guard fstatat(directory.value, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SortingError.io("Reading file metadata", errno)
        }
        return info
    }

    private func identity(of descriptor: FileDescriptor) throws -> FileIdentity {
        var info = stat()
        guard fstat(descriptor.value, &info) == 0 else { throw SortingError.io("Checking file identity", errno) }
        return FileIdentity(info)
    }

    private func exists(_ name: String, in directory: FileDescriptor) throws -> Bool {
        do { _ = try information(name, in: directory); return true }
        catch SortingError.io(_, let code) where code == ENOENT { return false }
    }

    private static func modificationTime(_ info: stat) -> TimeInterval {
        Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    static func collisionName(_ original: String, index: Int) -> String {
        guard index > 0 else { return original }
        let url = URL(fileURLWithPath: original)
        var ext = url.pathExtension
        var stem = ext.isEmpty ? original : url.deletingPathExtension().lastPathComponent
        let suffix = " (\(index))"
        // A valid original can already use all 255 UTF-8 bytes. Truncate by
        // Character so the collision suffix never splits a Unicode scalar.
        while ext.utf8.count > 100 { ext.removeLast() }
        let ending = suffix + (ext.isEmpty ? "" : ".\(ext)")
        while stem.utf8.count + ending.utf8.count > 255 { stem.removeLast() }
        return stem + ending
    }
}
