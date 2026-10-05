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
    private let vm = ViewModel()
    private let sorting = SortingViewModel()
    private var menuBar: MenuBarPanel?
    private var sortWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let openAI: () -> Void = { [weak self] in self?.showSortWindow() }
        menuBar = MenuBarPanel(symbolName: "square.grid.3x3.topleft.filled",
                               label: "ShapeDesk",
                               onOpen: { [vm] in vm.refresh() }) {
            ContentView(openAI: openAI).environmentObject(vm).environmentObject(sorting)
        }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    @objc func sortWithShapeDesk(_ pasteboard: NSPasteboard, userData: String?,
                                error errorPointer: AutoreleasingUnsafeMutablePointer<NSString>) {
        do {
            guard !vm.busy else { throw FinderServiceError.busy }
            let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            try sorting.select(SortSelection.resolve(urls))
            showSortWindow()
        } catch {
            errorPointer.pointee = error.localizedDescription as NSString
            sorting.reportSelectionError(error)
            showSortWindow()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let scheme = Bundle.main.bundleIdentifier == "com.shapedesk.staging" ? "shapedesk-test" : "shapedesk"
        guard urls.contains(where: { $0.scheme == scheme && $0.host == "billing" && $0.path == "/return" }) else { return }
        showSortWindow()
        sorting.returnFromBilling()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSortWindow()
        return true
    }

    private func showSortWindow() {
        menuBar?.close()
        if sortWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "ShapeDesk"
            window.title = "\(name) — AI Sort"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 560, height: 540)
            window.contentView = NSHostingView(rootView: AISortWorkspace(model: sorting, vm: vm))
            window.center()
            sortWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        sortWindow?.makeKeyAndOrderFront(nil)
    }

    private enum FinderServiceError: LocalizedError {
        case busy
        var errorDescription: String? { "Wait for the desktop arrangement to finish first." }
    }
}

struct ContentView: View {
    let openAI: () -> Void
    @EnvironmentObject private var vm: ViewModel
    @EnvironmentObject private var sorting: SortingViewModel
    @State private var selectedTab = Tab.shapes

    private enum Tab: String, CaseIterable { case shapes = "Shapes", sort = "AI Sort" }

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

            Picker("Mode", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if selectedTab == .shapes {
                ShapeControls().disabled(sorting.isBusy)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label("A place for every file.", systemImage: "folder.badge.gearshape").font(.headline)
                    Text("Sort your Desktop or files selected in Finder, with safe moves and undo.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let usage = sorting.entitlement {
                        Text("\(usage.remaining.formatted()) AI checks remaining").font(.caption)
                    }
                    Button("Open AI Sort") { openAI() }.buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 10)
            }

            Divider()
            HStack {
                if selectedTab == .shapes {
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
        .frame(width: 320)
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
