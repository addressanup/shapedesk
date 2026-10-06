import Foundation
import SwiftUI
import AppKit
import ShapeDeskSorting

@MainActor
final class SortingViewModel: ObservableObject {
    @Published private(set) var statistics = SortStatistics()
    @Published private(set) var undoStatistics = UndoStatistics()
    @Published private(set) var isBusy = false
    @Published private(set) var isUndoing = false
    @Published private(set) var isLoading = true
    @Published private(set) var canUndo = false
    @Published private(set) var hasLicense = false
    @Published private(set) var entitlement: ProEntitlement?
    @Published private(set) var plan: ProPlan?
    @Published private(set) var targetDescription = "Files on your Desktop"
    @Published private(set) var isFinderSelection = false
    @Published private(set) var status = "Ready to sort desktop files into category folders."
    @Published private(set) var settingsMessage = "Activate ShapeDesk Pro to use AI Sort."
    @Published var showSettings = false
    @Published var licenseDraft = ""
    @Published var page: Page = .sort
    @Published private(set) var pendingPurchase: ProPurchase?
    @Published private(set) var serviceError: String?
    @Published private(set) var needsReactivation = false

    enum Page: String, CaseIterable { case sort = "AI Sort", account = "Account" }

    private var sorter: DesktopSorter
    private let store = ProCredentialsStore()
    private let purchaseStore = ProCredentialsStore(account: "pending-purchase")
    private var credentials: ProCredentials?
    private let client: ProClient?
    private var operation: Task<Void, Never>?
    private var loaded = false
    private var billingReturnPending = false
    private var scopeID = UUID()
    private let desktop: URL
    private let history: URL

    var isOwnerPreview: Bool {
        #if SHAPEDESK_OWNER_PREVIEW
        true
        #else
        false
        #endif
    }

    var maySort: Bool { entitlement?.active == true && (entitlement?.remaining ?? 0) > 0 }
    var targetTitle: String { isFinderSelection ? targetDescription : "Desktop" }
    var accountTitle: String {
        if entitlement?.accessType == "owner" { return "Owner access" }
        if entitlement?.active == true { return "Pro active" }
        switch entitlement?.subscriptionStatus {
        case "past_due", "unpaid": return "Payment needed"
        case "canceled", "incomplete_expired": return "Subscription ended"
        case "paused": return "Subscription paused"
        default: break
        }
        return hasLicense ? "Your subscription" : "Get ShapeDesk Pro"
    }
    private var accountMessage: String {
        guard let entitlement else { return ProError.inactive.localizedDescription }
        if entitlement.active { return "ShapeDesk Pro is active on this Mac." }
        switch entitlement.subscriptionStatus {
        case "past_due", "unpaid": return "Update your payment method in Manage billing, then refresh to restore AI Sort. Undo is always available."
        case "canceled", "incomplete_expired": return "This subscription has ended. Manage billing shows your invoices. To subscribe again, deactivate this Mac and start a new checkout. Your undo history is kept."
        case "paused": return "Your subscription is paused. Open Manage billing to review it. Undo is always available."
        default: return "AI access is inactive. Open Manage billing or refresh to check your subscription. Undo is always available."
        }
    }
    private var deviceID: String {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "ShapeDeskProDeviceID") ?? UUID().uuidString
        defaults.set(id, forKey: "ShapeDeskProDeviceID")
        return id
    }
    var sortUnavailableMessage: String {
        if entitlement?.active == true && entitlement?.remaining == 0 {
            return ProError.quota.localizedDescription
        }
        return settingsMessage
    }

    init() {
        let manager = FileManager.default
        desktop = manager.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        history = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShapeDesk/SortHistory", isDirectory: true)
        sorter = DesktopSorter(desktop: desktop, historyDirectory: history)
        #if SHAPEDESK_OWNER_PREVIEW
        if let settings = try? OwnerPreviewSettings.load(),
           let previewClient = try? ProClient.ownerPreview(baseURL: settings.baseURL) {
            client = previewClient
            credentials = settings.credentials
        } else { client = nil }
        settingsMessage = "Connecting to your local AI service…"
        #else
        let endpoint = Bundle.main.object(forInfoDictionaryKey: "ShapeDeskAPIBaseURL") as? String
            ?? "https://api.shapedesk.space"
        client = URL(string: endpoint).flatMap { try? ProClient(baseURL: $0) }
        #endif
    }

    func select(_ selection: SortSelection) throws {
        guard !isBusy else { throw SelectionBusy() }
        sorter = DesktopSorter(selection: selection, historyDirectory: history)
        scopeID = UUID()
        targetDescription = selection.description
        isFinderSelection = true
        statistics = SortStatistics()
        canUndo = false
        status = selection.fileNames == nil
            ? "Ready. Only files directly inside this folder will be considered."
            : "Ready. Only the selected files will be considered."
        page = .sort
        serviceError = nil
        Task { await refreshUndo() }
    }

    func selectDesktop() {
        guard !isBusy else { return }
        sorter = DesktopSorter(desktop: desktop, historyDirectory: history)
        scopeID = UUID()
        targetDescription = "Files on your Desktop"
        isFinderSelection = false
        statistics = SortStatistics()
        canUndo = false
        status = "Ready to sort desktop files into category folders."
        Task { await refreshUndo() }
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        await refreshUndo()
        #if !SHAPEDESK_OWNER_PREVIEW
        do {
            let store = self.store
            credentials = try await Task.detached { try store.load() }.value
            hasLicense = credentials != nil
            let purchaseStore = self.purchaseStore
            pendingPurchase = try await Task.detached { try purchaseStore.loadPurchase() }.value
        } catch { settingsMessage = error.localizedDescription }
        #endif
        await refreshAccount()
        await refreshUndo()
        showSettings = !hasLicense
        finishLoading()
    }

    func chooseFolder() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "ShapeDesk sorts only the files directly inside this folder."
        panel.prompt = "Choose folder"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try self?.select(SortSelection.resolve([url])) }
                catch { self?.reportSelectionError(error) }
            }
        }
    }

    func reportSelectionError(_ error: Error) {
        serviceError = error.localizedDescription
        page = .sort
    }

    func subscribe() {
        guard !isBusy, !isLoading, !isOwnerPreview, !hasLicense, let client else { return }
        isLoading = true
        page = .account
        Task {
            do {
                var purchase = pendingPurchase ?? ProPurchase(deviceID: deviceID)
                let purchaseStore = self.purchaseStore
                // Persist the proof before contacting Stripe, so a crash cannot orphan paid access.
                let initialPurchase = purchase
                try await Task.detached { try purchaseStore.savePurchase(initialPurchase) }.value
                pendingPurchase = purchase
                let checkout = try await client.checkout(purchase)
                purchase.checkoutURL = checkout.url
                let saved = purchase
                try await Task.detached { try purchaseStore.savePurchase(saved) }.value
                pendingPurchase = purchase
                settingsMessage = "Complete the secure Stripe checkout, then return here to activate Pro."
                NSWorkspace.shared.open(checkout.url)
            } catch {
                settingsMessage = error.localizedDescription
                if error as? ProError == .checkoutExpired { await clearPendingPurchase() }
            }
            finishLoading()
        }
    }

    func finishCheckout() {
        guard !isBusy, !isLoading, let purchase = pendingPurchase, let client else { return }
        isLoading = true
        Task {
            do {
                let (credentials, usage) = try await client.completeCheckout(purchase)
                let store = self.store
                try await Task.detached { try store.save(credentials) }.value
                self.credentials = credentials
                entitlement = usage
                hasLicense = true
                await clearPendingPurchase()
                settingsMessage = usage.active ? "Pro is ready. Your recovery key is available below for another Mac." : accountMessage
            } catch {
                settingsMessage = error.localizedDescription
                if error as? ProError == .checkoutExpired { await clearPendingPurchase() }
            }
            finishLoading()
        }
    }

    private func clearPendingPurchase() async {
        let store = purchaseStore
        do { try await Task.detached { try store.remove() }.value; pendingPurchase = nil }
        catch { settingsMessage = error.localizedDescription }
    }

    func returnFromBilling() {
        page = .account
        guard !isLoading else { billingReturnPending = true; return }
        if pendingPurchase != nil { finishCheckout() } else { refreshSubscription() }
    }

    private func finishLoading() {
        isLoading = false
        if billingReturnPending {
            billingReturnPending = false
            returnFromBilling()
        }
    }

    func manageBilling() {
        guard !isBusy, !isLoading, let credentials, let client else { return }
        isLoading = true
        Task {
            do { NSWorkspace.shared.open(try await client.portal(credentials)) }
            catch { settingsMessage = error.localizedDescription }
            finishLoading()
        }
    }

    func copyRecoveryKey() {
        guard let credentials else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(credentials.licenseKey, forType: .string)
        settingsMessage = "Recovery key copied. Keep it somewhere private to activate another Mac."
    }

    func activate() {
        guard !isOwnerPreview, !isBusy, !isLoading, let client else { return }
        let key = licenseDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isLoading = true
        Task {
            do {
                let (credentials, usage) = try await client.activate(licenseKey: key, deviceID: deviceID)
                // Keep the key editable if Keychain fails; activating again reuses this device's slot.
                let store = self.store
                try await Task.detached { try store.save(credentials) }.value
                self.credentials = credentials
                entitlement = usage
                hasLicense = true
                needsReactivation = false
                licenseDraft = ""
                settingsMessage = accountMessage
                showSettings = false
            } catch { settingsMessage = error.localizedDescription }
            finishLoading()
        }
    }

    /// Re-registers this Mac with its saved recovery key after it was
    /// deactivated elsewhere, e.g. from the account page.
    func reactivate() {
        guard !isOwnerPreview, !isBusy, !isLoading, let client, let credentials else { return }
        isLoading = true
        Task {
            do {
                let (fresh, usage) = try await client.activate(licenseKey: credentials.licenseKey, deviceID: deviceID)
                let store = self.store
                try await Task.detached { try store.save(fresh) }.value
                self.credentials = fresh
                entitlement = usage
                hasLicense = true
                needsReactivation = false
                settingsMessage = accountMessage
            } catch { settingsMessage = error.localizedDescription }
            finishLoading()
        }
    }

    func openAccountPage() {
        guard let url = URL(string: "https://shapedesk.space/account") else { return }
        NSWorkspace.shared.open(url)
    }

    func deactivate() {
        guard !isOwnerPreview, !isBusy, !isLoading, let client, let credentials else { return }
        isLoading = true
        Task {
            do {
                try await client.deactivate(credentials)
                let store = self.store
                try await Task.detached { try store.remove() }.value
                self.credentials = nil
                entitlement = nil
                hasLicense = false
                needsReactivation = false
                settingsMessage = "This Mac is deactivated. Your subscription and undo history are unchanged."
            } catch { settingsMessage = error.localizedDescription }
            finishLoading()
        }
    }

    func refreshSubscription() {
        guard !isBusy, !isLoading else { return }
        isLoading = true
        Task { await refreshAccount(); finishLoading() }
    }

    func start(onFinish: @escaping @MainActor () -> Void) {
        guard !isBusy, !isLoading, maySort, let client, let credentials else { showSettings = true; return }
        let classifier = HostedClassifier(client: client, credentials: credentials, onUsage: { [weak self] usage in
            await self?.receive(usage)
        }, onFailure: { [weak self] error in await self?.receive(error) })
        isBusy = true
        isUndoing = false
        statistics = SortStatistics()
        let sorter = self.sorter
        operation = Task {
            await sorter.sort(using: classifier) { [weak self] update in await self?.receive(update) }
            await finishOperation(onFinish)
        }
    }

    func undo(onFinish: @escaping @MainActor () -> Void) {
        guard !isBusy, canUndo else { return }
        isBusy = true
        isUndoing = true
        let sorter = self.sorter
        operation = Task {
            await sorter.undoLastSort { [weak self] update in await self?.receive(update) }
            await finishOperation(onFinish)
        }
    }

    func stop() { operation?.cancel(); status = "Stopping after the current file operation…" }

    private func receive(_ update: SortStatistics) { statistics = update; status = update.message }
    private func receive(_ update: UndoStatistics) { undoStatistics = update; status = update.message }
    private func receive(_ usage: ProEntitlement) { entitlement = usage }
    private func receive(_ error: ProError) {
        if error == .quota || error == .inactive || error == .unavailable {
            entitlement = nil
            showSettings = true
            settingsMessage = isOwnerPreview && (error == .inactive || error == .unavailable)
                ? "Local AI service is unavailable. Restart it with owner-preview.sh, then click Refresh. Your files stay in place."
                : error.localizedDescription
        }
    }

    private func finishOperation(_ onFinish: @MainActor () -> Void) async {
        await refreshUndo()
        isBusy = false
        operation = nil
        onFinish()
    }

    private func refreshAccount() async {
        #if SHAPEDESK_OWNER_PREVIEW
        guard let client, let credentials else {
            settingsMessage = "Local AI setup is missing. Run owner-preview.sh on this Mac, then reopen ShapeDesk."
            return
        }
        do {
            entitlement = try await client.entitlement(credentials)
            settingsMessage = "Connected to your local AI service. Jev access is included for this owner preview."
        } catch {
            entitlement = nil
            settingsMessage = "Local AI service is unavailable. Restart it with owner-preview.sh, then click Refresh. Your files stay in place."
        }
        #else
        guard let client else { settingsMessage = ProError.unavailable.localizedDescription; return }
        do {
            plan = try await client.plan()
        } catch {
            plan = nil
            entitlement = nil
            settingsMessage = error.localizedDescription
            return
        }
        guard let credentials else {
            settingsMessage = pendingPurchase == nil
                ? "AI access is included. Subscribe once, then sort from ShapeDesk or Finder."
                : ProError.checkoutPending.localizedDescription
            return
        }
        do {
            entitlement = try await client.entitlement(credentials)
            needsReactivation = false
            settingsMessage = accountMessage
        } catch {
            entitlement = nil
            needsReactivation = (error as? ProError) == .inactive
            settingsMessage = needsReactivation
                ? "This Mac isn't active on your subscription. It may have been deactivated from your account page."
                : error.localizedDescription
        }
        #endif
    }

    private func refreshUndo() async {
        let scope = scopeID
        do {
            let available = try await sorter.canUndo()
            if scope == scopeID { canUndo = available }
        } catch {
            if scope == scopeID { canUndo = false; status = error.localizedDescription }
        }
    }

    private struct SelectionBusy: LocalizedError {
        var errorDescription: String? { "Wait for the current sort or undo to finish, or press Stop first." }
    }
}
