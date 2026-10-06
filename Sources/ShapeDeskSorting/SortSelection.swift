import Foundation
import Darwin

/// An explicit Finder selection: one folder, or files sharing one parent folder.
/// Capture identities now so replacing a selection before Sort cannot widen its scope.
public struct SortSelection: Sendable, Equatable {
    public let folder: URL
    public let fileNames: Set<String>?
    let folderIdentity: FileIdentity
    let fileIdentities: [String: FileIdentity]

    public var description: String {
        if let fileNames {
            return "\(fileNames.count) selected \(fileNames.count == 1 ? "file" : "files") in \(folder.lastPathComponent)"
        }
        return "Files in \(folder.lastPathComponent)"
    }

    public static func resolve(_ urls: [URL]) throws -> SortSelection {
        let urls = Array(Set(urls.map(\.standardizedFileURL)))
        guard !urls.isEmpty else { throw SelectionError.empty }
        var files: [(URL, FileIdentity)] = []
        for url in urls {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
                throw SelectionError.unsupported
            }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey,
                .isPackageKey, .isDirectoryKey, .isRegularFileKey, .isHiddenKey])
            guard values.isSymbolicLink != true, values.isAliasFile != true,
                  values.isPackage != true, values.isHidden != true,
                  !url.lastPathComponent.hasPrefix(".") else { throw SelectionError.unsupported }
            if values.isDirectory == true {
                guard urls.count == 1 else { throw SelectionError.mixedFolders }
                let root = url.resolvingSymlinksInPath()
                return try SortSelection(folder: root, fileNames: nil,
                    folderIdentity: identity(root), fileIdentities: [:])
            }
            guard values.isRegularFile == true else { throw SelectionError.unsupported }
            files.append((url.resolvingSymlinksInPath(), try identity(url)))
        }
        let folder = files[0].0.deletingLastPathComponent()
        guard files.allSatisfy({ $0.0.deletingLastPathComponent() == folder }) else {
            throw SelectionError.mixedFolders
        }
        return try SortSelection(folder: folder, fileNames: Set(files.map { $0.0.lastPathComponent }),
            folderIdentity: identity(folder),
            fileIdentities: Dictionary(files.map { ($0.0.lastPathComponent, $0.1) },
                                      uniquingKeysWith: { first, _ in first }))
    }

    public static func finderFolder(_ url: URL?, desktop: URL, home: URL) -> SortSelection? {
        guard let url, let selection = try? resolve([url]), selection.fileNames == nil else { return nil }
        if let desktopIdentity = try? identity(desktop.standardizedFileURL.resolvingSymlinksInPath()),
           desktopIdentity == selection.folderIdentity { return nil }
        let home = home.standardizedFileURL.resolvingSymlinksInPath()
        let library = home.appendingPathComponent("Library")
        let volumes = URL(fileURLWithPath: "/Volumes")
        let path = selection.folder.pathComponents
        let inside = { (root: URL) in path.starts(with: root.pathComponents) }
        let root: URL
        if let cloud = [library.appendingPathComponent("Mobile Documents"),
                        library.appendingPathComponent("CloudStorage")].first(where: inside) {
            root = cloud
        } else if inside(home), !inside(library) {
            root = home
        } else if inside(volumes), path.count > volumes.pathComponents.count {
            root = volumes
        } else { return nil }
        var folder = selection.folder
        while folder.pathComponents.count > root.pathComponents.count {
            guard let values = try? folder.resourceValues(forKeys: [.isHiddenKey, .isPackageKey]),
                  values.isHidden == false, values.isPackage == false else { return nil }
            folder.deleteLastPathComponent()
        }
        return selection
    }

    public func isCategoryFolder(of folder: URL) -> Bool {
        fileNames == nil && FileCategory(rawValue: self.folder.lastPathComponent) != nil
            && self.folder.deletingLastPathComponent().path == folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func identity(_ url: URL) throws -> FileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw SortingError.io("Reading selection", errno) }
        return FileIdentity(info)
    }

    private enum SelectionError: LocalizedError {
        case empty, unsupported, mixedFolders
        var errorDescription: String? {
            switch self {
            case .empty: return "Select files or a folder in Finder first."
            case .unsupported: return "Select regular files or a folder. Hidden items, aliases and app packages are left alone."
            case .mixedFolders: return "Select files from one folder, or select a single folder to sort its contents."
            }
        }
    }
}
