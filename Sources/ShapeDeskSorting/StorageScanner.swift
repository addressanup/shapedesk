import Foundation
import CoreServices

public struct StorageItem: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case file, folder, package, app }
    public let url: URL
    public let name: String
    public let kind: Kind
    /// Bytes on disk, including everything inside folders and packages. Nil until measured.
    public var size: Int64?
    /// Spotlight's "Last opened", recorded when an app launches or a document is opened.
    public let lastOpened: Date?
    public let added: Date?
    public var id: URL { url }
    /// Decides whether the item counts as unused: when it was last opened, or
    /// for something never opened, when it arrived.
    public var lastActivity: Date? { lastOpened ?? added }

    public func isUnused(since cutoff: Date) -> Bool { (lastActivity ?? .distantPast) < cutoff }
}

/// Reads sizes and usage for the items directly inside a folder. Folder sizes
/// include their contents, but only the top level is ever listed.
public enum StorageScanner {
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        .isHiddenKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .addedToDirectoryDateKey,
        .creationDateKey, .localizedNameKey]

    public static var applicationFolders: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Visible items in `folder`. Links are skipped so nothing outside is counted.
    /// Files come with their size; folders and packages are measured with `size(of:)`.
    public static func items(in folder: URL, lastOpened: ((URL) -> Date?)? = nil) throws -> [StorageItem] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                    options: [.skipsHiddenFiles])
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isSymbolicLink != true, values.isHidden != true else { return nil }
                let kind: StorageItem.Kind = values.isDirectory != true ? .file
                    : values.isPackage != true ? .folder
                    : url.pathExtension.lowercased() == "app" ? .app : .package
                return StorageItem(url: url,
                                   name: kind == .app ? values.localizedName ?? url.lastPathComponent : url.lastPathComponent,
                                   kind: kind,
                                   size: kind == .file ? allocated(values) : nil,
                                   lastOpened: lastOpened?(url),
                                   added: values.addedToDirectoryDate ?? values.creationDate)
            }
    }

    /// Apps installed directly in the application folders.
    public static func applications(in folders: [URL] = applicationFolders,
                                    lastOpened: @escaping (URL) -> Date? = lastOpened) -> [StorageItem] {
        folders.flatMap { (try? items(in: $0, lastOpened: lastOpened)) ?? [] }.filter { $0.kind == .app }
    }

    /// Bytes on disk for a file, or for everything inside a folder or package.
    /// Links are never followed. Unreadable parts are skipped. Honors task cancellation.
    public static func size(of url: URL) throws -> Int64 {
        let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let root = try url.resourceValues(forKeys: fileKeys.union([.isDirectoryKey, .isSymbolicLinkKey]))
        guard root.isDirectory == true, root.isSymbolicLink != true else { return allocated(root) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(fileKeys),
                                                              options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var visited = 0
        while let child = enumerator.nextObject() as? URL {
            visited += 1
            if visited.isMultiple(of: 256) { try Task.checkCancellation() }
            guard let values = try? child.resourceValues(forKeys: fileKeys), values.isRegularFile == true else { continue }
            total += allocated(values)
        }
        return total
    }

    public static func lastOpened(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    private static func allocated(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
