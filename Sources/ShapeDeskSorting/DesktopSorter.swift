import Foundation

/// One actor owns the pipeline. A separate nonblocking disk lock also excludes
/// another ShapeDesk process, including during awaits of the remote classifier.
public actor DesktopSorter {
    public typealias Progress = @Sendable (SortStatistics) async -> Void
    public typealias UndoProgress = @Sendable (UndoStatistics) async -> Void
    private let files: DesktopFileSystem
    private let history: any JournalStoring
    private let selection: SortSelection?
    private var running = false

    public init(desktop: URL, historyDirectory: URL) {
        files = DesktopFileSystem(desktop: desktop)
        history = SortJournalStore(directory: historyDirectory)
        selection = nil
    }

    public init(selection: SortSelection, historyDirectory: URL) {
        files = DesktopFileSystem(desktop: selection.folder)
        history = SortJournalStore(directory: historyDirectory)
        self.selection = selection
    }

    init(files: DesktopFileSystem, history: any JournalStoring) {
        self.files = files
        self.history = history
        selection = nil
    }

    public func canUndo() throws -> Bool {
        guard !running else { return false }
        let lock = try history.lock()
        defer { withExtendedLifetime(lock) {} }
        return try undoJournal() != nil
    }

    @discardableResult
    public func sort(using classifier: any FileClassifying, onProgress: Progress = { _ in }) async -> SortStatistics {
        var stats = SortStatistics()
        guard !running else {
            stats.phase = .failed
            stats.message = SortingError.busy.localizedDescription
            await onProgress(stats)
            return stats
        }
        running = true
        defer { running = false }
        do {
            let lock = try history.lock()
            defer { withExtendedLifetime(lock) {} }
            _ = try history.load() // Fail closed if undo history cannot be read.
            let rootIdentity = try files.rootIdentity()
            if let selection, rootIdentity != selection.folderIdentity { throw SortingError.changed }
            var journal = SortJournal(desktopPath: files.desktop.path, desktopIdentity: rootIdentity)
            stats.phase = .scanning
            stats.message = "Scanning files…"
            await onProgress(stats)
            var snapshots: [FileSnapshot] = []
            for name in try files.names() {
                try Task.checkCancellation()
                if let names = selection?.fileNames, !names.contains(name) { continue }
                do {
                    guard let snapshot = try files.snapshot(name: name, rootIdentity: rootIdentity) else { continue }
                    if let expected = selection?.fileIdentities[name], expected != snapshot.identity {
                        throw SortingError.changed
                    }
                    stats.totalScanned += 1
                    snapshots.append(snapshot)
                } catch {
                    stats.totalScanned += 1
                    skip(&stats, name: name, error: error)
                }
                await onProgress(stats)
            }
            stats.phase = .sorting
            for snapshot in snapshots {
                try Task.checkCancellation()
                stats.currentFile = snapshot.metadata.name
                stats.message = "Classifying \(snapshot.metadata.name)…"
                await onProgress(stats)
                var category: FileCategory?
                do {
                    let decision = try await classifier.classify(snapshot.metadata)
                    try Task.checkCancellation()
                    category = decision.category
                    guard decision.confidence.isFinite, (0...1).contains(decision.confidence) else {
                        throw JevError.invalidResponse
                    }
                    if decision.permitsMove {
                        var record = MoveRecord(originalName: snapshot.metadata.name,
                            category: decision.category, destinationName: snapshot.metadata.name,
                            identity: snapshot.identity, confidence: decision.confidence, model: decision.model)
                        let index = journal.records.count
                        _ = try files.move(snapshot, toFolder: decision.category.rawValue,
                                           rootIdentity: rootIdentity) { destination in
                            record.destinationName = destination
                            if journal.records.count == index { journal.records.append(record) }
                            else { journal.records[index] = record }
                            try history.save(journal)
                        }
                        stats.moved += 1
                        if decision.model == LocalRules.model { stats.sortedLocally += 1 }
                        stats.categories[decision.category, default: CategoryStatistics()].moved += 1
                        stats.message = "Moved \(snapshot.metadata.name) to \(decision.category.rawValue)."
                    } else {
                        stats.skipped += 1
                        stats.categories[decision.category, default: CategoryStatistics()].skipped += 1
                        stats.message = "Left \(snapshot.metadata.name) in place: confidence must exceed 80%."
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    skip(&stats, name: snapshot.metadata.name, category: category, error: error)
                }
                await onProgress(stats)
            }
            stats.phase = .completed
            stats.message = "Sorted \(stats.moved) of \(stats.totalScanned) files; \(stats.skipped) left in place."
        } catch {
            // All unprocessed files remain untouched, including on cancellation.
            stats.skipped += stats.remaining
            if Task.isCancelled || error is CancellationError {
                stats.phase = .cancelled
                stats.message = "Stopped. \(stats.moved) files moved; \(stats.skipped) left in place."
            } else {
                stats.phase = .failed
                stats.message = error.localizedDescription
                stats.lastIssue = error.localizedDescription
            }
        }
        stats.currentFile = nil
        await onProgress(stats)
        return stats
    }

    /// Moves every copy except each group's keeper into `folder`, through the same
    /// journaled, identity-checked moves as sorting, so `undoLastSort` restores them.
    /// A group whose keeper changed or vanished since the scan is left alone.
    @discardableResult
    public func moveDuplicates(_ scan: DuplicateScan, into folder: String = DuplicateFinder.folderName,
                               onProgress: @Sendable (DuplicateMoveStatistics) async -> Void = { _ in }) async -> DuplicateMoveStatistics {
        var stats = DuplicateMoveStatistics()
        stats.total = scan.extraCopies
        guard !running else {
            stats.phase = .failed
            stats.message = SortingError.busy.localizedDescription
            await onProgress(stats)
            return stats
        }
        running = true
        defer { running = false }
        do {
            let lock = try history.lock()
            defer { withExtendedLifetime(lock) {} }
            _ = try history.load() // Fail closed if undo history cannot be read.
            let rootIdentity = try files.rootIdentity()
            guard rootIdentity == scan.rootIdentity, files.desktop.path == scan.folder.path else { throw SortingError.changed }
            var journal = SortJournal(desktopPath: files.desktop.path, desktopIdentity: rootIdentity)
            stats.phase = .moving
            stats.message = "Moving duplicate copies…"
            await onProgress(stats)
            for group in scan.groups {
                try Task.checkCancellation()
                let extras = group.files.filter { $0.name != group.keeper }
                guard let keeper = group.files.first(where: { $0.name == group.keeper }),
                      try files.isUnchanged(keeper.snapshot, rootIdentity: rootIdentity) else {
                    stats.skipped += extras.count
                    stats.lastIssue = "\(group.keeper): the copy to keep changed, so its duplicates stayed in place."
                    await onProgress(stats)
                    continue
                }
                for file in extras {
                    try Task.checkCancellation()
                    do {
                        var record = MoveRecord(originalName: file.name, category: nil, folder: folder,
                            destinationName: file.name, identity: file.snapshot.identity,
                            confidence: 1, model: DuplicateFinder.model)
                        let index = journal.records.count
                        _ = try files.move(file.snapshot, toFolder: folder, rootIdentity: rootIdentity) { destination in
                            record.destinationName = destination
                            if journal.records.count == index { journal.records.append(record) }
                            else { journal.records[index] = record }
                            try history.save(journal)
                        }
                        stats.moved += 1
                        stats.movedBytes += file.byteSize
                        stats.message = "Moved \(file.name) to \(folder)."
                    } catch {
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                        stats.skipped += 1
                        stats.lastIssue = "\(file.name): \(error.localizedDescription)"
                    }
                    await onProgress(stats)
                }
            }
            stats.phase = .completed
            stats.message = "Moved \(stats.moved) duplicate \(stats.moved == 1 ? "copy" : "copies") to \(folder)"
                + (stats.skipped > 0 ? "; \(stats.skipped) left in place." : ".")
        } catch {
            stats.skipped = stats.total - stats.moved
            if Task.isCancelled || error is CancellationError {
                stats.phase = .cancelled
                stats.message = "Stopped. \(stats.moved) copies moved; the rest stayed in place."
            } else {
                stats.phase = .failed
                stats.message = error.localizedDescription
                stats.lastIssue = error.localizedDescription
            }
        }
        await onProgress(stats)
        return stats
    }

    @discardableResult
    public func undoLastSort(onProgress: UndoProgress = { _ in }) async -> UndoStatistics {
        var stats = UndoStatistics()
        guard !running else {
            stats.message = SortingError.busy.localizedDescription
            await onProgress(stats)
            return stats
        }
        running = true
        defer { running = false }
        do {
            let lock = try history.lock()
            defer { withExtendedLifetime(lock) {} }
            guard var journal = try undoJournal() else {
                stats.message = "No sorted files to undo."
                await onProgress(stats)
                return stats
            }
            stats.isRunning = true
            stats.total = journal.records.filter { !$0.resolved }.count
            stats.message = "Restoring files…"
            await onProgress(stats)
            var lastIssue: String?
            for index in journal.records.indices.reversed() where !journal.records[index].resolved {
                try Task.checkCancellation()
                let record = journal.records[index]
                do {
                    switch try files.location(of: record, rootIdentity: journal.desktopIdentity) {
                    case .atOriginal, .restored:
                        // Failed forward rename or completed undo interrupted before
                        // saving its resolved bit. Neither needs another rename.
                        journal.records[index].resolved = true
                        stats.total -= 1
                    case .atDestination:
                        let name = try files.restore(record, rootIdentity: journal.desktopIdentity) { restoredName in
                            journal.records[index].restoredName = restoredName
                            try history.save(journal)
                        }
                        journal.records[index].resolved = true
                        stats.restored += 1
                        stats.message = "Restored \(name)."
                    case .missing:
                        throw SortingError.missing
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    stats.skipped += 1
                    lastIssue = "\(record.originalName): \(error.localizedDescription)"
                    stats.message = lastIssue!
                }
                await onProgress(stats)
            }
            // Every successful restore already has a durable destination intent.
            // Failure here never loses the ability to reconcile on the next run.
            try history.save(journal)
            stats.message = "Restored \(stats.restored) files; \(stats.skipped) could not be restored."
            if let lastIssue { stats.message += " \(lastIssue)" }
        } catch {
            stats.skipped += max(0, stats.total - stats.restored - stats.skipped)
            stats.message = Task.isCancelled || error is CancellationError
                ? "Undo stopped. Restored \(stats.restored) files."
                : "Restored \(stats.restored) files. \(error.localizedDescription)"
        }
        stats.isRunning = false
        await onProgress(stats)
        return stats
    }

    private func undoJournal() throws -> SortJournal? {
        for journal in try history.load() where journal.desktopPath == files.desktop.path {
            for record in journal.records where !record.resolved {
                do {
                    switch try files.location(of: record, rootIdentity: journal.desktopIdentity) {
                    case .atDestination, .missing: return journal
                    case .atOriginal, .restored: continue
                    }
                } catch {
                    // An inaccessible/replaced category must not prevent undoing
                    // the other files in this run. Report it per file in undo.
                    return journal
                }
            }
        }
        return nil
    }

    private func skip(_ stats: inout SortStatistics, name: String,
                      category: FileCategory? = nil, error: Error) {
        stats.skipped += 1
        stats.errors += 1
        if let category { stats.categories[category, default: CategoryStatistics()].skipped += 1 }
        stats.lastIssue = "\(name): \(error.localizedDescription)"
        stats.message = "Left \(name) in place. \(error.localizedDescription)"
    }
}
