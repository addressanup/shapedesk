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
    private var menuBar: MenuBarPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarPanel(symbolName: "square.grid.3x3.topleft.filled",
                               label: "ShapeDesk",
                               onOpen: { [vm, self] in
                                   vm.refresh()
                                   if vm.panelTab == .sort { refreshSortTarget() }
                               }) {
            ContentView(onSortTab: { [weak self] in self?.refreshSortTarget() })
                .environmentObject(vm).environmentObject(sorting)
        }
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

    private func presentSort() {
        vm.panelTab = .sort
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
    @EnvironmentObject private var vm: ViewModel
    @EnvironmentObject private var sorting: SortingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ShapeDesk").font(.headline)
                Spacer()
                Text("\(vm.iconCount) icons")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Button { vm.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Re-count desktop icons")
                .disabled(vm.busy || sorting.isBusy)
            }

            Picker("Mode", selection: $vm.panelTab) {
                ForEach(PanelTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if vm.panelTab == .shapes {
                ShapeControls().disabled(sorting.isBusy)
            } else {
                ScrollView {
                    SortPanelView(model: sorting, otherOperationRunning: vm.busy, onFinish: vm.refresh)
                        .padding(.vertical, 4)
                }
                .frame(minHeight: 430, idealHeight: 540, maxHeight: 620)
                .onAppear(perform: onSortTab)
            }

            Divider()
            HStack {
                if vm.panelTab == .shapes {
                    Button("Reset to grid") { vm.reset() }
                        .disabled(vm.busy || sorting.isBusy)
                        .help("Re-arrange icons into Finder's plain sorted grid")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .disabled(vm.busy || sorting.isBusy)
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
