import SwiftUI
import ShapeDeskSorting

private let deskTint = Color(red: 0.20, green: 0.48, blue: 0.37)

struct AISortWorkspace: View {
    @ObservedObject var model: SortingViewModel
    @ObservedObject var vm: ViewModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.3x3.topleft.filled")
                    .font(.title2).foregroundStyle(deskTint)
                Text("ShapeDesk").font(.headline)
                Spacer()
                Picker("Workspace", selection: $model.page) {
                    ForEach(SortingViewModel.Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            ScrollView {
                Group {
                    if model.page == .sort {
                        AISortView(model: model, otherOperationRunning: vm.busy, onFinish: vm.refresh)
                    } else {
                        ProAccountView(model: model)
                    }
                }
                .padding(28).frame(maxWidth: 740, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(deskTint)
        .task { await model.load() }
    }
}

struct AISortView: View {
    @ObservedObject var model: SortingViewModel
    let otherOperationRunning: Bool
    let onFinish: @MainActor () -> Void
    private var hasResults: Bool { model.statistics.phase != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A place for every file.").font(.system(size: 27, weight: .semibold)).tracking(-0.7)
                    Text("Let AI take care of the little piles.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { model.page = .account } label: {
                    Label(model.accountTitle, systemImage: model.maySort ? "checkmark.circle.fill" : "person.crop.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless).padding(.top, 5)
            }

            HStack(spacing: 12) {
                Image(systemName: model.isFinderSelection ? "folder.fill" : "desktopcomputer")
                    .font(.system(size: 25)).foregroundStyle(deskTint).frame(width: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.targetTitle).font(.headline).lineLimit(2)
                    Text("Visible files only · Subfolders stay in place")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Change") {
                    Button("Desktop") { model.selectDesktop() }
                    Button("Choose a folder…") { model.chooseFolder() }
                }
                .fixedSize().disabled(model.isBusy || otherOperationRunning)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

            if let error = model.serviceError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if hasResults {
                HStack(spacing: 0) {
                    SortCount(label: "Scanned", count: model.statistics.totalScanned)
                    Spacer()
                    SortCount(label: "Moved", count: model.statistics.moved)
                    Spacer()
                    SortCount(label: "Kept in place", count: model.statistics.skipped)
                }
                .accessibilityElement(children: .combine)
            }

            if model.isBusy {
                if model.isUndoing {
                    ProgressView(value: Double(model.undoStatistics.restored + model.undoStatistics.skipped),
                                 total: Double(max(1, model.undoStatistics.total)))
                        .accessibilityLabel("Restoring files")
                } else if model.statistics.phase == .scanning {
                    ProgressView("Finding files…")
                } else {
                    ProgressView(value: Double(model.statistics.processed),
                                 total: Double(max(1, model.statistics.totalScanned)))
                        .accessibilityLabel("Sorting files")
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(hasResults ? "This sort" : "Eight folders. Less searching.")
                    .font(.subheadline.weight(.semibold))
                if hasResults { CategoryBreakdown(statistics: model.statistics) }
                else {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 12) {
                        ForEach(FileCategory.allCases) { category in
                            Label(category.rawValue, systemImage: category.symbol)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if hasResults || model.isUndoing {
                    Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Only confident matches move. Everything else stays where it is.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !model.isBusy && !model.isUndoing, let issue = model.statistics.lastIssue {
                    Text(issue).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(issue)
                }
                if !model.maySort && !model.isLoading && !model.isBusy {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle")
                        Text(model.sortUnavailableMessage).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                if model.isBusy {
                    Button("Stop sorting") { model.stop() }.controlSize(.large)
                } else if !model.hasLicense && !model.isOwnerPreview && !model.maySort {
                    Button("Get ShapeDesk Pro") { model.page = .account }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button(model.isFinderSelection ? "Sort selection" : "Sort Desktop") { model.start(onFinish: onFinish) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!model.maySort || model.isLoading || otherOperationRunning)
                }
                Spacer()
                Button("Undo last sort") { model.undo(onFinish: onFinish) }
                    .disabled(!model.canUndo || model.isBusy || otherOperationRunning)
            }

            Divider()
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
                Text("AI reads filenames and file details, never file contents. Files move only above 80% confidence. You can undo every sort.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let usage = model.entitlement {
                HStack {
                    Text("\(usage.remaining.formatted()) AI checks left this month").font(.caption.weight(.medium))
                    Spacer()
                    Button("View usage") { model.page = .account }.buttonStyle(.link).font(.caption)
                }
            } else {
                Text("Also in Finder: right-click files or a folder → Services → Sort with ShapeDesk.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ProAccountView: View {
    @ObservedObject var model: SortingViewModel
    @State private var showRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("A calmer desktop, included.").font(.system(size: 27, weight: .semibold)).tracking(-0.7)
                Text("ShapeDesk Pro").font(.subheadline).foregroundStyle(.secondary)
            }
            if model.isOwnerPreview {
                Label("Local development preview", systemImage: "hammer").font(.headline)
            } else if model.hasLicense {
                HStack {
                    Label(model.accountTitle, systemImage: model.entitlement?.active == true ? "checkmark.circle.fill" : "person.crop.circle")
                        .font(.headline).foregroundStyle(deskTint)
                    Spacer()
                    if model.entitlement?.accessType == "stripe" { Text("$5 / month").foregroundStyle(.secondary) }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.plan?.price ?? "$5").font(.system(size: 42, weight: .semibold)).tracking(-1.3)
                    Text("/ month").foregroundStyle(.secondary)
                    Spacer()
                    if model.plan?.billingMode == "test" { Text("Test checkout").font(.caption).foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 11) {
                    ProBenefit(symbol: "folder.badge.gearshape", text: "1,000 AI file checks each month")
                    ProBenefit(symbol: "finder", text: "Sort from Finder or the app")
                    ProBenefit(symbol: "arrow.uturn.backward", text: "Safe moves and undo, even offline")
                    ProBenefit(symbol: "desktopcomputer", text: "One subscription, up to 3 Macs")
                }
            }

            if let usage = model.entitlement {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(usage.remaining, format: .number).font(.system(size: 32, weight: .semibold)).monospacedDigit()
                        Text("checks remaining").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(usage.used.formatted()) / \(usage.limit.formatted()) used").font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(min(usage.used, usage.limit)), total: Double(usage.limit))
                        .accessibilityLabel("Monthly AI usage")
                    Text("Resets \(usage.resetsAt, format: .dateTime.month(.wide).day()) · UTC calendar month")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }

            if model.pendingPurchase != nil && !model.hasLicense {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Finish activating Pro").font(.headline)
                    Text("Your checkout is saved on this Mac. Complete payment in your browser, then come back here.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Continue checkout") { model.subscribe() }
                        Button("I’ve completed checkout") { model.finishCheckout() }.buttonStyle(.borderedProminent)
                    }
                    .disabled(model.isBusy || model.isLoading)
                }
            } else if !model.hasLicense && !model.isOwnerPreview {
                VStack(alignment: .leading, spacing: 9) {
                    Button("Subscribe with Stripe") { model.subscribe() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.plan?.checkoutEnabled != true || model.isLoading || model.isBusy)
                    Text(model.plan?.checkoutEnabled == true ? "Secure checkout opens in your browser. Cancel future renewals anytime." : "Checkout is being prepared. Refresh to check availability.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if model.hasLicense {
                HStack {
                    if model.entitlement?.canManageBilling == true {
                        Button("Manage billing") { model.manageBilling() }.buttonStyle(.borderedProminent)
                    }
                    Button("Copy recovery key") { model.copyRecoveryKey() }
                    Spacer()
                    Button("Deactivate this Mac") { model.deactivate() }.buttonStyle(.link)
                }
                .disabled(model.isBusy || model.isLoading)
                Text("Save your recovery key to activate Pro on another Mac. Deactivating a Mac frees its slot and keeps your subscription.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(alignment: .top) {
                if model.isLoading { ProgressView().controlSize(.small) }
                Text(model.settingsMessage).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Refresh") {
                    if model.pendingPurchase != nil { model.finishCheckout() } else { model.refreshSubscription() }
                }
                .disabled(model.isBusy || model.isLoading)
            }

            if !model.hasLicense && model.pendingPurchase == nil && !model.isOwnerPreview {
                DisclosureGroup("Already subscribed? Restore access", isExpanded: $showRestore) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ShapeDesk recovery key").font(.caption.weight(.medium))
                        SecureField("Paste the recovery key saved from your other Mac", text: $model.licenseDraft)
                            .textFieldStyle(.roundedBorder).onSubmit { model.activate() }
                            .accessibilityLabel("ShapeDesk recovery key")
                        Button("Activate this Mac") { model.activate() }
                            .disabled(model.licenseDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isLoading || model.isBusy)
                    }.padding(.top, 10)
                }
            }
            Divider()
            Text("Each completed AI classification uses one check, including files kept in place. Failed AI requests use no checks. Unused checks don’t roll over. Desktop shapes and undo remain free.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("File names, types, sizes and dates are processed by ShapeDesk and TypeSafe Jev. Contents and full paths stay on your Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProBenefit: View {
    let symbol: String
    let text: String
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: symbol).frame(width: 20).foregroundStyle(deskTint) }
    }
}

private struct SortCount: View {
    let label: String
    let count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count, format: .number).font(.system(size: 28, weight: .semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CategoryBreakdown: View {
    let statistics: SortStatistics
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
            GridRow {
                Text("Folder")
                Text("Moved")
                Text("Kept")
            }.foregroundStyle(.secondary)
            ForEach(FileCategory.allCases) { category in
                GridRow {
                    Label(category.rawValue, systemImage: category.symbol).frame(maxWidth: .infinity, alignment: .leading)
                    Text(statistics.categories[category]?.moved ?? 0, format: .number)
                    Text(statistics.categories[category]?.skipped ?? 0, format: .number)
                }.accessibilityElement(children: .combine)
            }
            if statistics.unclassifiedSkipped > 0 {
                GridRow {
                    Text("Unclassified")
                    Text("—")
                    Text(statistics.unclassifiedSkipped, format: .number)
                }
            }
        }.font(.caption).monospacedDigit()
    }
}

private extension FileCategory {
    var symbol: String {
        switch self {
        case .screenshots: return "viewfinder"
        case .recordings: return "record.circle"
        case .videos: return "film"
        case .audio: return "waveform"
        case .images: return "photo"
        case .docs: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "archivebox"
        }
    }
}
