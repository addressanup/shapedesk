import AppKit
import Carbon.HIToolbox
import ServiceManagement
import ShapeDeskSorting

@MainActor
final class AppSettings: ObservableObject {
    enum Key {
        static let shortcut = "GlobalShortcut"
        static let notify = "NotifyWhenFinished"
        static let localRules = "SortObviousFilesLocally"
        static let autoUpdate = "CheckForUpdatesAutomatically"
        static let lastUpdateCheck = "LastUpdateCheck"
    }

    enum UpdateState: Equatable { case idle, checking, upToDate, available(AppRelease), failed }

    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var loginMessage: String?
    @Published private(set) var shortcut: KeyCombo?
    @Published private(set) var shortcutMessage: String?
    @Published private(set) var isRecordingShortcut = false
    @Published private(set) var update: UpdateState = .idle

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private let hotKey: GlobalHotKey
    private var recorder: Any?

    init(onShortcut: @escaping @MainActor () -> Void) {
        UserDefaults.standard.register(defaults: [Key.notify: true, Key.localRules: true, Key.autoUpdate: true])
        hotKey = GlobalHotKey(action: onShortcut)
        // Absent means the default shortcut; an empty value means the person cleared it.
        switch UserDefaults.standard.object(forKey: Key.shortcut) {
        case nil: shortcut = .standard
        case let data as Data: shortcut = try? JSONDecoder().decode(KeyCombo.self, from: data)
        default: shortcut = nil
        }
    }

    func start() {
        applyShortcut()
        refreshLoginItem()
        if UserDefaults.standard.bool(forKey: Key.autoUpdate) { checkForUpdates() }
    }

    // MARK: Login item

    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
        if loginNeedsApproval { loginMessage = "Allow ShapeDesk in System Settings → General → Login Items." }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage = nil
        } catch {
            loginMessage = "macOS couldn't change the login item. \(error.localizedDescription)"
        }
        refreshLoginItem()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: Shortcut

    func clearShortcut() {
        stopRecording()
        shortcut = nil
        UserDefaults.standard.set(Data(), forKey: Key.shortcut)
        applyShortcut()
    }

    /// Captures the next key press in the panel as the new shortcut. Escape cancels.
    func startRecording() {
        guard !isRecordingShortcut else { return }
        isRecordingShortcut = true
        shortcutMessage = nil
        hotKey.register(nil) // So pressing the current shortcut records it instead of closing the panel.
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecording()
            } else if let combo = KeyCombo(event: event) {
                self.shortcut = combo
                UserDefaults.standard.set(try? JSONEncoder().encode(combo), forKey: Key.shortcut)
                self.stopRecording()
            } else {
                self.shortcutMessage = "Include ⌘, ⌃ or ⌥ in the shortcut."
            }
            return nil
        }
    }

    func stopRecording() {
        guard isRecordingShortcut else { return }
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        isRecordingShortcut = false
        applyShortcut()
    }

    /// macOS lets several apps register one combination, so a failure here means
    /// the combination itself was refused, not that another app owns it.
    private func applyShortcut() {
        shortcutMessage = hotKey.register(shortcut) ? nil
            : "macOS didn't accept \(shortcut?.label ?? "this shortcut"). Record a different one."
    }

    // MARK: Updates

    /// Checks at launch, then when the panel opens at most daily (hourly after a
    /// failed check), unless forced.
    func checkForUpdates(force: Bool = false) {
        if update == .checking { return }
        let defaults = UserDefaults.standard
        if !force {
            guard defaults.bool(forKey: Key.autoUpdate) else { return }
            if update != .idle, let last = defaults.object(forKey: Key.lastUpdateCheck) as? Date,
               Date().timeIntervalSince(last) < (update == .failed ? 3_600 : 86_400) { return }
        }
        update = .checking
        defaults.set(Date(), forKey: Key.lastUpdateCheck)
        Task {
            do {
                let release = try await UpdateCheck.latest()
                update = UpdateCheck.isNewer(release.version, than: version) ? .available(release) : .upToDate
            } catch {
                update = .failed
            }
        }
    }

    var availableRelease: AppRelease? {
        if case .available(let release) = update { return release }
        return nil
    }
}
