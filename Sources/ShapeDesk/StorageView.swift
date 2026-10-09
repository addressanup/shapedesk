import SwiftUI
import ShapeDeskSorting

/// The Storage tab: sizes, duplicates and not-opened items for the folder open in Finder.
struct StorageView: View {
    @ObservedObject var model: StorageViewModel
    let isPro: Bool
    let isCheckingPro: Bool
    let otherOperationRunning: Bool
    let onGetPro: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: model.isFromFinder ? "folder.fill" : "desktopcomputer")
                    .font(.system(size: 19)).foregroundStyle(deskTint).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title).font(.headline).lineLimit(1)
                        .help((model.folder.path as NSString).abbreviatingWithTildeInPath)
                    Text(model.isFromFinder ? "From Finder · Top level only" : "Top level only")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isFromFinder {
                    Button("Use Desktop") { model.useDesktop() }.disabled(model.isMoving)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

            if isPro {
                Picker("Tool", selection: $model.tool) {
                    ForEach(StorageViewModel.Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().disabled(model.isMoving)
                switch model.tool {
                case .sizes: SizesSection(model: model)
                case .duplicates: DuplicatesSection(model: model, otherOperationRunning: otherOperationRunning)
                case .unused: UnusedSection(model: model)
                }
            } else if isCheckingPro {
                ProgressView("Checking ShapeDesk Pro…").controlSize(.small)
            } else {
                ProStorageCard(onGetPro: onGetPro)
                if model.canUndoDuplicates {
                    HStack {
                        Text("Undo is always free.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Undo last duplicate move") { model.undoDuplicates() }
                            .disabled(model.isMoving || otherOperationRunning)
                    }
                }
            }

            if let message = model.message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: model.tool) { _ in model.toolChanged() }
        .onChange(of: model.age) { _ in model.ageChanged() }
        .onChange(of: isPro) { if $0 { model.refreshIfNeeded() } }
    }
}

private struct ProStorageCard: View {
    let onGetPro: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("See what's using your space.").font(.title3.weight(.semibold)).tracking(-0.7)
                Text("Storage is included with ShapeDesk Pro.").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 11) {
                StorageBenefit(symbol: "chart.bar.xaxis", text: "Sizes of everything in a folder")
                StorageBenefit(symbol: "doc.on.doc", text: "Duplicate copies, moved aside with undo")
                StorageBenefit(symbol: "clock.arrow.circlepath", text: "Files and apps you haven't opened lately")
            }
            Button("Get ShapeDesk Pro", action: onGetPro).buttonStyle(.borderedProminent)
        }
    }
}

private struct StorageBenefit: View {
    let symbol: String
    let text: String
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: symbol).frame(width: 20).foregroundStyle(deskTint) }
    }
}

// MARK: - Sizes

private struct SizesSection: View {
    @ObservedObject var model: StorageViewModel

    var body: some View {
        let measured = model.sizes.compactMap(\.size)
        let largest = max(measured.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if !model.path.isEmpty {
                    Button { model.goUp() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless).help("Back to the enclosing folder").disabled(model.isMoving)
                }
                Text(FileManager.default.displayName(atPath: model.currentFolder.path))
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if model.isScanning { ProgressView().controlSize(.small) }
                Text(measured.reduce(0, +).formatted(.byteCount(style: .file)))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button { model.loadSizes(refresh: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Measure again").disabled(model.isMoving)
            }
            if model.sizes.isEmpty {
                Text(model.isScanning ? "Measuring…" : "Nothing here.").font(.callout).foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 2) {
                ForEach(model.sizes) { item in
                    SizeRow(item: item, fraction: Double(item.size ?? 0) / Double(largest),
                            isMeasuring: model.measuring == item.url) { model.open(item) }
                }
            }
            Text("Space used on disk. Folder sizes include everything inside; click a folder to look inside it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SizeRow: View {
    let item: StorageItem
    let fraction: Double
    let isMeasuring: Bool
    let open: () -> Void

    var body: some View {
        if item.kind == .folder {
            Button(action: open) { row }.buttonStyle(.plain).help("Show what's inside \(item.name)")
        } else {
            row.help((item.url.path as NSString).abbreviatingWithTildeInPath)
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            FileIcon(url: item.url)
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(item.size.map { $0.formatted(.byteCount(style: .file)) } ?? (isMeasuring ? "Measuring…" : "—"))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                .opacity(item.kind == .folder ? 1 : 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 6).fill(deskTint.opacity(0.14))
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .contentShape(Rectangle())
        .contextMenu { RevealButton(url: item.url) }
    }
}

// MARK: - Duplicates

private struct DuplicatesSection: View {
    @ObservedObject var model: StorageViewModel
    let otherOperationRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress = model.scanProgress {
                ProgressView(value: progress.fraction).accessibilityLabel("Comparing files")
                Text(progress.currentFile.map { "Comparing \($0)…" } ?? "Finding files…")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Stop") { model.stop() }
            } else if model.isMoving {
                ProgressView(value: Double(model.moveStats.processed), total: Double(max(1, model.moveStats.total)))
                    .accessibilityLabel("Moving duplicates")
                Text(model.moveStats.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button("Stop") { model.stop() }
            } else if let scan = model.scan {
                results(scan)
            } else {
                if model.moveStats.phase != .idle {
                    Label(model.moveStats.message, systemImage: model.moveStats.phase == .completed
                          ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .fixedSize(horizontal: false, vertical: true)
                    if let issue = model.moveStats.lastIssue {
                        Text(issue).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(issue)
                    }
                } else if let undo = model.undoMessage {
                    Label(undo, systemImage: "arrow.uturn.backward.circle").fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Find files in this folder with exactly the same contents. Extra copies move into a Duplicates folder here, and you can undo the move.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button("Find duplicates") { model.findDuplicates() }
                    .buttonStyle(.borderedProminent).disabled(otherOperationRunning)
            }

            HStack {
                Spacer()
                Button("Undo last move") { model.undoDuplicates() }
                    .disabled(!model.canUndoDuplicates || model.busy || otherOperationRunning)
            }
            Divider()
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock.doc").foregroundStyle(.secondary)
                Text("Files are compared byte for byte on your Mac. Nothing is deleted: extra copies wait in the Duplicates folder.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func results(_ scan: DuplicateScan) -> some View {
        if scan.groups.isEmpty {
            Label("No duplicates among \(scan.scannedFiles.formatted()) files.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(deskTint)
            Button("Check again") { model.findDuplicates() }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(scan.wastedBytes.formatted(.byteCount(style: .file)))
                    .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                Text("in \(scan.extraCopies) extra \(scan.extraCopies == 1 ? "copy" : "copies")").foregroundStyle(.secondary)
                Spacer()
                Button { model.findDuplicates() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Check again")
            }
            Text("The checked copy stays. Click another copy to keep it instead.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVStack(spacing: 8) {
                ForEach(scan.groups) { group in
                    DuplicateGroupCard(group: group) { model.keep($0, in: group.id) }
                }
            }
            Button("Move \(scan.extraCopies) \(scan.extraCopies == 1 ? "copy" : "copies") to Duplicates") {
                model.moveDuplicates()
            }
            .buttonStyle(.borderedProminent).disabled(otherOperationRunning)
        }
        if scan.unreadableFiles > 0 {
            Text("\(scan.unreadableFiles) \(scan.unreadableFiles == 1 ? "file wasn't" : "files weren't") compared because \(scan.unreadableFiles == 1 ? "it's" : "they're") locked, changing or not downloaded.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    let keep: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(group.files.count) copies · \(group.byteSize.formatted(.byteCount(style: .file))) each")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(group.files) { file in
                let kept = file.name == group.keeper
                Button { keep(file.name) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: kept ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(kept ? deskTint : Color.secondary)
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(kept ? "Keep" : "Move").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Created \(file.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .accessibilityAddTraits(kept ? .isSelected : [])
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Not opened

private struct UnusedSection: View {
    @ObservedObject var model: StorageViewModel
    @State private var confirming: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Not opened in", selection: $model.age) {
                    ForEach(StorageViewModel.Age.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Spacer()
                if model.isScanning { ProgressView().controlSize(.small) }
                Button { model.loadUnused() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Check again").disabled(model.isMoving)
            }
            UnusedList(title: "In \(model.title)", items: model.unusedFiles,
                       empty: "Every file here was opened in the last \(model.age.title).",
                       model: model, confirming: $confirming)
            UnusedList(title: "Applications", items: model.unusedApps,
                       empty: "Every app was opened in the last \(model.age.title).",
                       model: model, confirming: $confirming)
            Divider()
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("Uses the “Last opened” date macOS keeps. Items you've never opened count from when they arrived. Running apps are left out, and Move to Trash can be put back from the Trash.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct UnusedList: View {
    let title: String
    let items: [StorageItem]
    let empty: String
    @ObservedObject var model: StorageViewModel
    @Binding var confirming: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count) · \(items.compactMap(\.size).reduce(0, +).formatted(.byteCount(style: .file)))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if items.isEmpty {
                Text(model.isScanning ? "Checking…" : empty).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                UnusedRow(item: item, isMeasuring: model.measuring == item.url, isTrashing: model.trashing == item.url,
                          isConfirming: confirming == item.url,
                          confirm: { confirming = item.url }, cancel: { confirming = nil },
                          trash: { confirming = nil; model.moveToTrash(item) })
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct UnusedRow: View {
    let item: StorageItem
    let isMeasuring: Bool
    let isTrashing: Bool
    let isConfirming: Bool
    let confirm: () -> Void
    let cancel: () -> Void
    let trash: () -> Void

    private var lastUsed: String {
        if let opened = item.lastOpened { return "Opened \(opened.formatted(.relative(presentation: .named)))" }
        if let added = item.added { return "Never opened · added \(added.formatted(.relative(presentation: .named)))" }
        return "Never opened"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FileIcon(url: item.url)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Text(lastUsed).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(item.size.map { $0.formatted(.byteCount(style: .file)) } ?? (isMeasuring ? "Measuring…" : "—"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if isTrashing {
                    ProgressView().controlSize(.small)
                } else {
                    Menu {
                        RevealButton(url: item.url)
                        Button("Move to Trash…", action: confirm)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Actions for \(item.name)")
                }
            }
            if isConfirming {
                HStack {
                    Text("Move \(item.kind == .app ? "this app" : "this item") to the Trash?").font(.caption)
                    Spacer()
                    Button("Cancel", action: cancel)
                    Button("Move to Trash", role: .destructive, action: trash).buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
        .contextMenu { RevealButton(url: item.url) }
    }
}

// MARK: - Shared

private struct FileIcon: View {
    let url: URL
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

private struct RevealButton: View {
    let url: URL
    var body: some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
