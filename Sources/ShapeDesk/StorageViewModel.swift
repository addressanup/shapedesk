import AppKit
import ShapeDeskSorting

/// Sizes, duplicates and not-opened items for the folder open in Finder (or the
/// Desktop). One background operation runs at a time; read-only scans are
/// cancelled when they become irrelevant, moves are never cancelled implicitly.
@MainActor
final class StorageViewModel: ObservableObject {
    enum Tool: String, CaseIterable { case sizes = "Sizes", duplicates = "Duplicates", unused = "Not Opened" }

    enum Age: Int, CaseIterable, Identifiable {
        case month = 30, quarter = 90, halfYear = 180, year = 365
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .month: return "30 days"
            case .quarter: return "90 days"
            case .halfYear: return "6 months"
            case .year: return "a year"
            }
        }
    }

    @Published var tool: Tool = .sizes
    @Published var age: Age = .quarter
    @Published private(set) var folder: URL
    @Published private(set) var isFromFinder = false
    @Published private(set) var isScanning = false
    @Published private(set) var isMoving = false
    @Published private(set) var measuring: URL?
    @Published private(set) var message: String?

    @Published private(set) var path: [URL] = []
    @Published private(set) var sizes: [StorageItem] = []

    @Published private(set) var scan: DuplicateScan?
    @Published private(set) var scanProgress: DuplicateScanProgress?
    @Published private(set) var moveStats = DuplicateMoveStatistics()
    @Published private(set) var undoMessage: String?
    @Published private(set) var canUndoDuplicates = false

    @Published private(set) var files: [StorageItem] = []
    @Published private(set) var apps: [StorageItem] = []
    @Published private(set) var trashing: URL?

    var notify: (String, String) -> Void = { _, _ in }
    /// Storage tools are part of ShapeDesk Pro; undo never is.
    var isEntitled: () -> Bool = { false }
    private var loaded: [Tool: URL] = [:]
    private var sizeCache: [URL: [StorageItem]] = [:]
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private let desktop: URL
    private let history: URL

    init() {
        let manager = FileManager.default
        desktop = manager.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        history = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShapeDesk/DuplicateHistory", isDirectory: true)
        folder = desktop
    }

    var title: String { Self.same(folder, desktop) ? "Desktop" : FileManager.default.displayName(atPath: folder.path) }
    var currentFolder: URL { path.last ?? folder }
    var busy: Bool { isScanning || isMoving }
    var unusedFiles: [StorageItem] { files.filter { $0.isUnused(since: cutoff) }.sorted(by: Self.largestFirst) }
    var unusedApps: [StorageItem] { apps.filter { $0.isUnused(since: cutoff) }.sorted(by: Self.largestFirst) }
    private var cutoff: Date { Date().addingTimeInterval(-Double(age.rawValue) * 86_400) }

    // MARK: Target

    func followFinder(_ finderFolder: @escaping @Sendable () throws -> URL?) async {
        guard !isMoving else { return }
        let desktop = self.desktop, home = FileManager.default.homeDirectoryForCurrentUser
        let found = await Task.detached { SortSelection.finderFolder(try? finderFolder(), desktop: desktop, home: home)?.folder }.value
        guard !isMoving else { return }
        // Peeking into the Duplicates folder or a sorted category keeps the folder around it.
        if let found, Self.same(found.deletingLastPathComponent(), folder),
           found.lastPathComponent == DuplicateFinder.folderName || FileCategory(rawValue: found.lastPathComponent) != nil {
            return
        }
        setFolder(found ?? desktop, fromFinder: found != nil)
    }

    func useDesktop() { setFolder(desktop, fromFinder: false) }

    private func setFolder(_ url: URL, fromFinder: Bool) {
        guard !isMoving else { return }
        isFromFinder = fromFinder
        guard !Self.same(url, folder) else { return }
        cancelScan()
        folder = url
        path = []
        sizes = []
        files = []
        scan = nil
        moveStats = DuplicateMoveStatistics()
        undoMessage = nil
        message = nil
        loaded = [:]
        sizeCache = [:]
        canUndoDuplicates = false
        Task { await refreshUndo() }
        refreshIfNeeded()
    }

    /// Loads the selected tool's results when they are missing or belong to another folder.
    func refreshIfNeeded() {
        guard isEntitled(), !isMoving else { return }
        switch tool {
        case .sizes: if loaded[.sizes] != folder { loadSizes() }
        case .unused: if loaded[.unused] != folder { loadUnused() }
        case .duplicates: break // Reads file contents, so it only runs on request.
        }
    }

    func toolChanged() {
        guard !isMoving else { return }
        cancelScan()
        refreshIfNeeded()
    }

    func stop() {
        if isMoving { operation?.cancel() } else { cancelScan() }
    }

    // MARK: Sizes

    func loadSizes(refresh: Bool = false) {
        guard isEntitled(), !isMoving else { return }
        cancelScan()
        let target = currentFolder
        loaded[.sizes] = folder
        message = nil
        if refresh { sizeCache[target] = nil }
        if let cached = sizeCache[target] { sizes = cached; return }
        sizes = []
        run { model in
            var items = try await Self.background { try StorageScanner.items(in: target) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            model.sizes = items
            for index in items.indices where items[index].size == nil {
                let url = items[index].url
                model.measuring = url
                items[index].size = try await Self.measure(url)
                model.sizes = items
            }
            items.sort(by: Self.largestFirst)
            model.sizes = items
            model.sizeCache[target] = items
        }
    }

    func open(_ item: StorageItem) {
        guard item.kind == .folder, !isMoving else { return }
        path.append(item.url)
        loadSizes()
    }

    func goUp() {
        guard !path.isEmpty, !isMoving else { return }
        path.removeLast()
        loadSizes()
    }

    // MARK: Duplicates

    func findDuplicates() {
        guard isEntitled(), !isMoving else { return }
        cancelScan()
        let folder = self.folder
        scan = nil
        moveStats = DuplicateMoveStatistics()
        undoMessage = nil
        message = nil
        scanProgress = DuplicateScanProgress()
        let id = UUID()
        run(id: id) { model in
            model.scan = try await Self.background {
                try await DuplicateFinder.scan(folder: folder) { progress in
                    await MainActor.run { if model.operationID == id { model.scanProgress = progress } }
                }
            }
            model.scanProgress = nil
        }
    }

    func keep(_ name: String, in group: DuplicateGroup.ID) {
        guard !isMoving, let index = scan?.groups.firstIndex(where: { $0.id == group }) else { return }
        scan?.groups[index].keeper = name
    }

    func moveDuplicates() {
        guard isEntitled(), let scan, scan.extraCopies > 0, !busy else { return }
        isMoving = true
        moveStats = DuplicateMoveStatistics()
        undoMessage = nil
        message = nil
        let sorter = DesktopSorter(desktop: scan.folder, historyDirectory: history)
        operation = Task { [weak self] in
            let stats = await sorter.moveDuplicates(scan) { progress in
                await MainActor.run { self?.moveStats = progress }
            }
            guard let self else { return }
            moveStats = stats
            self.scan = nil
            finishMove()
            await refreshUndo()
            notify("Duplicates moved", stats.message)
        }
    }

    /// Always available, with or without Pro, like undo for AI Sort.
    func undoDuplicates() {
        guard canUndoDuplicates, !isMoving else { return }
        cancelScan()
        isMoving = true
        message = nil
        let sorter = DesktopSorter(desktop: folder, historyDirectory: history)
        operation = Task { [weak self] in
            let stats = await sorter.undoLastSort()
            guard let self else { return }
            undoMessage = stats.message
            moveStats = DuplicateMoveStatistics()
            scan = nil
            finishMove()
            await refreshUndo()
            notify("Duplicates restored", stats.message)
        }
    }

    func refreshUndo() async {
        let folder = self.folder
        let available = (try? await DesktopSorter(desktop: folder, historyDirectory: history).canUndo()) ?? false
        if Self.same(folder, self.folder) { canUndoDuplicates = available }
    }

    private func finishMove() {
        isMoving = false
        operation = nil
        // Moves change what Sizes and Not Opened would show.
        loaded = [:]
        sizeCache = [:]
    }

    // MARK: Not opened

    func loadUnused() {
        guard isEntitled(), !isMoving else { return }
        cancelScan()
        loaded[.unused] = folder
        message = nil
        files = []
        apps = []
        let folder = self.folder
        // A running app may have launched long ago without being "opened" since.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
        run { model in
            let (files, apps) = try await Self.background {
                (try StorageScanner.items(in: folder, lastOpened: StorageScanner.lastOpened).filter { $0.kind != .folder },
                 StorageScanner.applications().filter { !running.contains($0.url.resolvingSymlinksInPath().path) })
            }
            model.files = files
            model.apps = apps
            try await model.measureUnused()
        }
    }

    func ageChanged() {
        guard tool == .unused, !busy, loaded[.unused] == folder else { return }
        run { try await $0.measureUnused() }
    }

    /// Measures only what the current age shows, re-reading the age after each item.
    private func measureUnused() async throws {
        while let item = (files + apps).first(where: { $0.size == nil && $0.isUnused(since: cutoff) }) {
            measuring = item.url
            let size = try await Self.measure(item.url)
            if let index = files.firstIndex(where: { $0.url == item.url }) { files[index].size = size }
            if let index = apps.firstIndex(where: { $0.url == item.url }) { apps[index].size = size }
        }
    }

    func moveToTrash(_ item: StorageItem) {
        guard trashing == nil, !isMoving else { return }
        trashing = item.url
        let url = item.url
        Task { [weak self] in
            do {
                try await Self.background {
                    do { try FinderBridge.moveToTrash(url) }
                    catch let error as ScriptError where error.isPermissionError {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                }
                self?.files.removeAll { $0.url == url }
                self?.apps.removeAll { $0.url == url }
                self?.sizeCache = [:]
                self?.loaded[.sizes] = nil
            } catch {
                let reason = (error as? ScriptError)?.message ?? error.localizedDescription
                self?.message = "\(item.name) stayed in place. \(reason)"
            }
            self?.trashing = nil
        }
    }

    // MARK: Plumbing

    /// Runs a cancellable read-only scan. A scan that was replaced never writes results.
    private func run(id: UUID = UUID(), _ work: @escaping @MainActor (StorageViewModel) async throws -> Void) {
        operationID = id
        isScanning = true
        operation = Task { [weak self] in
            guard let self else { return }
            do { try await work(self) }
            catch is CancellationError { return }
            catch { if operationID == id { message = error.localizedDescription } }
            guard operationID == id else { return }
            measuring = nil
            isScanning = false
            operation = nil
        }
    }

    private func cancelScan() {
        guard !isMoving else { return }
        operation?.cancel()
        operation = nil
        operationID = UUID()
        isScanning = false
        measuring = nil
        scanProgress = nil
    }

    /// Unreadable items count as empty instead of ending the scan.
    private static func measure(_ url: URL) async throws -> Int64 {
        do { return try await background { try StorageScanner.size(of: url) } }
        catch is CancellationError { throw CancellationError() }
        catch { return 0 }
    }

    /// Blocking file work belongs off the main actor; cancelling the caller cancels it.
    private static func background<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return value
    }

    private static func largestFirst(_ a: StorageItem, _ b: StorageItem) -> Bool {
        let x = a.size ?? -1, y = b.size ?? -1
        return x == y ? a.name.localizedStandardCompare(b.name) == .orderedAscending : x > y
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
