import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let onDone: () -> Void
    @AppStorage(AppSettings.Key.notify) private var notify = true
    @AppStorage(AppSettings.Key.localRules) private var localRules = true
    @AppStorage(AppSettings.Key.autoUpdate) private var autoUpdate = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: onDone) {
                    Label("Back", systemImage: "chevron.left").font(.callout.weight(.medium))
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("Settings").font(.headline)
            }

            SettingsGroup("General") {
                Toggle("Open ShapeDesk at login", isOn: Binding(get: { settings.launchAtLogin },
                                                                set: { settings.setLaunchAtLogin($0) }))
                if let message = settings.loginMessage { Note(message) }
                if settings.loginNeedsApproval {
                    Button("Open Login Items…") { settings.openLoginItems() }.buttonStyle(.link).font(.caption)
                }
            }

            SettingsGroup("Keyboard shortcut") {
                HStack {
                    Text("Open or close ShapeDesk")
                    Spacer()
                    Button(settings.isRecordingShortcut ? "Type a shortcut…" : settings.shortcut?.label ?? "Record shortcut") {
                        if settings.isRecordingShortcut { settings.stopRecording() } else { settings.startRecording() }
                    }
                    .monospacedDigit()
                    .accessibilityHint("Press the new key combination, or Escape to cancel")
                    if settings.shortcut != nil && !settings.isRecordingShortcut {
                        Button { settings.clearShortcut() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove the shortcut")
                    }
                }
                Note(settings.shortcutMessage ?? "Works from any app. Press Escape to cancel recording.")
            }

            SettingsGroup("Notifications") {
                Toggle("Notify me when a sort or cleanup finishes", isOn: $notify)
                Note("Only while the panel is closed. Click the notification to see the result.")
            }

            SettingsGroup("AI Sort") {
                Toggle("Sort obvious files on this Mac", isOn: $localRules)
                Note("Screenshots, documents, code, archives and camera photos with standard names move without using an AI check.")
            }

            SettingsGroup("Updates") {
                HStack {
                    Text("ShapeDesk \(settings.version)")
                    Spacer()
                    switch settings.update {
                    case .checking: ProgressView().controlSize(.small)
                    case .available(let release):
                        Button("Get \(release.version)") { NSWorkspace.shared.open(release.url) }
                            .buttonStyle(.borderedProminent)
                    case .upToDate: Text("Up to date").foregroundStyle(.secondary)
                    case .failed: Text("Couldn't check").foregroundStyle(.secondary)
                    case .idle: EmptyView()
                    }
                    Button("Check now") { settings.checkForUpdates(force: true) }
                        .disabled(settings.update == .checking)
                }
                Toggle("Check for updates automatically", isOn: $autoUpdate)
            }
        }
        .onAppear { settings.refreshLoginItem() }
        .onDisappear { settings.stopRecording() }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
