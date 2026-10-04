import SwiftUI

@main
struct ShapeDeskApp: App {
    @StateObject private var vm = ViewModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(vm)
                .onAppear { vm.refresh() }
        } label: {
            Image(systemName: "square.grid.3x3.topleft.filled")
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject private var vm: ViewModel

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
            }

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

            Divider()

            HStack {
                Button("Reset to grid") { vm.reset() }
                    .disabled(vm.busy)
                    .help("Re-arrange icons into Finder's plain sorted grid")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
