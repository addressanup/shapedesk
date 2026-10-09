import SwiftUI
import ShapeDeskSorting

@main
struct ShapeDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI lives in MenuBarPanel. An App needs a scene, so this one is an
        // empty Settings scene with its menu command removed.
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let finder = "com.apple.finder"
    private let vm = ViewModel()
    private let sorting = SortingViewModel()
    private let storage = StorageViewModel()
    private let notifier = FinishNotifier()
    private lazy var settings = AppSettings { [weak self] in self?.menuBar?.toggleFromShortcut() }
    private var menuBar: MenuBarPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarPanel(symbolName: "square.grid.3x3.topleft.filled",
                               label: "ShapeDesk",
                               onOpen: { [vm, settings, self] in
                                   vm.refresh()
                                   switch vm.panelTab {
                                   case .sort: refreshSortTarget()
                                   case .storage: refreshStorageTarget()
                                   case .shapes: break
                                   }
                                   settings.checkForUpdates()
                               }) {
            ContentView(onSortTab: { [weak self] in self?.refreshSortTarget() },
                        onStorageTab: { [weak self] in self?.refreshStorageTarget() })
                .environmentObject(vm).environmentObject(sorting)
                .environmentObject(storage).environmentObject(settings)
        }
        // A shortcut being recorded must not stay half-done once the panel is gone.
        menuBar?.onClose = { [settings] in settings.stopRecording() }
        vm.screen = { [weak self] in self?.menuBar?.screen ?? NSScreen.main }
        notifier.isPanelOpen = { [weak self] in self?.menuBar?.isOpen ?? false }
        notifier.onClick = { [weak self] in self?.menuBar?.open() }
        notifier.start()
        sorting.notify = { [notifier] in notifier.post($0, $1) }
        storage.notify = { [notifier] in notifier.post($0, $1) }
        storage.isEntitled = { [sorting] in sorting.hasStorageAccess }
        settings.start()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// The dropdown's AI Sort tab can act as its own Finder-follow entry point:
    /// read the folder open in the frontmost Finder window. Force is off, so a
    /// target chosen through Services is never overridden here.
    private func refreshSortTarget() {
        let finderInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finder
        Task { await sorting.followFinder(force: false) { finderInFront ? try FinderBridge.insertionFolder() : nil } }
    }

    /// Storage follows Finder the same way, then loads whatever the open tool needs.
    private func refreshStorageTarget() {
        let finderInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finder
        Task {
            await storage.followFinder { finderInFront ? try FinderBridge.insertionFolder() : nil }
            storage.refreshIfNeeded()
        }
    }

    private func presentSort() {
        vm.panelTab = .sort
        vm.showSettings = false
        menuBar?.open()
    }

    @objc func sortWithShapeDesk(_ pasteboard: NSPasteboard, userData: String?,
                                error errorPointer: AutoreleasingUnsafeMutablePointer<NSString>) {
        do {
            guard !vm.busy else { throw FinderServiceError.busy }
            let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            try sorting.select(SortSelection.resolve(urls))
            presentSort()
        } catch {
            errorPointer.pointee = error.localizedDescription as NSString
            sorting.reportSelectionError(error)
            presentSort()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let scheme = Bundle.main.bundleIdentifier == "com.shapedesk.staging" ? "shapedesk-test" : "shapedesk"
        guard urls.contains(where: { $0.scheme == scheme && $0.host == "billing" && $0.path == "/return" }) else { return }
        presentSort()
        sorting.returnFromBilling()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentSort()
        return true
    }

    private enum FinderServiceError: LocalizedError {
        case busy
        var errorDescription: String? { "Wait for the desktop arrangement to finish first." }
    }
}

struct ContentView: View {
    let onSortTab: () -> Void
    let onStorageTab: () -> Void
    @EnvironmentObject private var vm: ViewModel
    @EnvironmentObject private var sorting: SortingViewModel
    @EnvironmentObject private var storage: StorageViewModel
    @EnvironmentObject private var settings: AppSettings

    private var fileOperationRunning: Bool { sorting.isBusy || storage.isMoving }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ShapeDesk").font(.headline)
                Spacer()
                if !vm.showSettings {
                    Text("\(vm.iconCount) icons")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Button { vm.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Re-count desktop icons")
                    .disabled(vm.busy || fileOperationRunning)
                }
                Button { vm.showSettings.toggle() } label: {
                    Image(systemName: vm.showSettings ? "gearshape.fill" : "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }

            if vm.showSettings {
                ScrollView {
                    SettingsView(settings: settings) { vm.showSettings = false }.padding(.vertical, 4)
                }
                .frame(minHeight: 430, idealHeight: 540, maxHeight: 620)
            } else {
                Picker("Mode", selection: $vm.panelTab) {
                    ForEach(PanelTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch vm.panelTab {
                case .shapes:
                    ShapeControls().disabled(fileOperationRunning)
                case .sort:
                    ScrollView {
                        SortPanelView(model: sorting, otherOperationRunning: vm.busy || storage.isMoving, onFinish: vm.refresh)
                            .padding(.vertical, 4)
                    }
                    .frame(minHeight: 430, idealHeight: 540, maxHeight: 620)
                    .onAppear(perform: onSortTab)
                case .storage:
                    ScrollView {
                        StorageView(model: storage, isPro: sorting.hasStorageAccess, isCheckingPro: sorting.isLoading,
                                    otherOperationRunning: vm.busy || sorting.isBusy) {
                            sorting.page = .account
                            vm.panelTab = .sort
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 430, idealHeight: 540, maxHeight: 620)
                    .onAppear(perform: onStorageTab)
                }
            }

            Divider()
            HStack {
                if vm.panelTab == .shapes && !vm.showSettings {
                    Button("Reset to grid") { vm.reset() }
                        .disabled(vm.busy || fileOperationRunning)
                        .help("Re-arrange icons into Finder's plain sorted grid")
                }
                Spacer()
                if let release = settings.availableRelease {
                    Button("Update to \(release.version)") { NSWorkspace.shared.open(release.url) }
                        .buttonStyle(.link)
                        .help("Open the release page for the new version")
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .disabled(vm.busy || fileOperationRunning)
            }
        }
        .padding(14)
        .frame(width: 360)
        .task { await sorting.load() }
    }
}

private struct ShapeControls: View {
    @EnvironmentObject private var vm: ViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(ShapeKind.allCases) { kind in
                    Button { vm.apply(kind) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: kind.symbol).font(.title2)
                            Text(kind.title).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.busy)
                }
            }

            HStack {
                TextField("Spell something…", text: $vm.customText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { vm.applyText() }
                Button("Spell it") { vm.applyText() }
                    .disabled(vm.busy)
            }

            HStack {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                Slider(value: $vm.fill, in: 0.4...0.95)
                Toggle("Animate", isOn: $vm.animate)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            Text(vm.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        }
    }
}
