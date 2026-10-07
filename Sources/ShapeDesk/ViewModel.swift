import SwiftUI
import AppKit

enum PanelTab: String, CaseIterable { case shapes = "Shapes", sort = "AI Sort" }

@MainActor
final class ViewModel: ObservableObject {
    @Published var panelTab: PanelTab = .shapes
    @Published var iconCount = 0
    @Published var status = "Click a shape to arrange your desktop."
    @Published var customText = "HELLO"
    @Published var fill: Double = 0.8
    @Published var animate = true
    @Published var busy = false

    /// Usable desktop area in Finder coordinates (origin top-left),
    /// excluding the menu bar and Dock.
    private var desktopRect: CGRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        let vis = screen.visibleFrame
        return CGRect(x: vis.minX,
                      y: frame.height - vis.maxY,
                      width: vis.width,
                      height: vis.height)
    }

    func refresh() {
        run("Counting desktop icons…") {
            let names = try FinderBridge.desktopIconNames()
            return (names, "Found \(names.count) desktop icons.")
        } finish: { [weak self] (names: [String], message: String) in
            self?.iconCount = names.count
            self?.status = message
        }
    }

    func apply(_ kind: ShapeKind) {
        run("Building \(kind.title)…") {
            let names = try FinderBridge.desktopIconNames()
            return (names, "")
        } finish: { [weak self] (names: [String], _: String) in
            self?.layout(names: names, label: kind.title) { n in
                let (dense, closed) = ShapeMath.densePolyline(for: kind)
                let pts = ShapeMath.resample(dense, closed: closed, count: n)
                return ShapeMath.fit(pts, into: self?.desktopRect ?? .zero,
                                     fill: self?.fill ?? 0.8)
            }
        }
    }

    func applyText() {
        let text = customText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Type something first."
            return
        }
        run("Rendering \"\(text)\"…") {
            let names = try FinderBridge.desktopIconNames()
            return (names, "")
        } finish: { [weak self] (names: [String], _: String) in
            let letters = text.filter { !$0.isWhitespace }.count
            let perLetter = names.count / max(letters, 1)
            let hint = perLetter < 7
                ? "That's only about \(perLetter) icons per letter, so a shorter word will read better."
                : nil
            self?.layout(names: names, label: "\"\(text)\"", hint: hint) { n in
                let rect = self?.desktopRect ?? .zero
                let raw = TextShape.points(for: text, count: n,
                                           aspect: rect.width / max(rect.height, 1))
                return ShapeMath.fit(raw, into: rect, fill: self?.fill ?? 0.8)
            }
        }
    }

    func reset() {
        run("Reading desktop…") {
            let names = try FinderBridge.desktopIconNames()
            return (names, "")
        } finish: { [weak self] names, _ in
            guard let self, !names.isEmpty else {
                self?.status = "No desktop icons to arrange."
                return
            }
            let targets = FinderBridge.gridTargets(names: names, in: self.desktopRect)
            self.move(targets: targets, label: "a tidy grid")
        }
    }

    // MARK: - Internals

    /// Shared tail of apply/applyText: build points, warn on tight spacing,
    /// then move the icons.
    private func layout(names: [String], label: String, hint: String? = nil,
                        makePoints: (Int) -> [CGPoint]) {
        guard !names.isEmpty else {
            status = "No desktop icons found. (Desktop & Documents Folders in iCloud can hide them.)"
            return
        }
        iconCount = names.count
        let points = makePoints(names.count)
        guard points.count == names.count else {
            status = "Couldn't build enough points for \(names.count) icons."
            return
        }
        let spacing = ShapeMath.medianSpacing(points)
        let targets = zip(names, points).map { ($0, $1) }
        move(targets: targets, label: label) { [weak self] in
            if let hint {
                self?.status += " " + hint
            }
            if spacing < 64 {
                self?.status += " Some icons may overlap — try a bigger Size."
            }
        }
    }

    private func move(targets: [(name: String, point: CGPoint)], label: String,
                      after: (() -> Void)? = nil) {
        run("Moving \(targets.count) icons…") {
            var lastProgress = ""
            try FinderBridge.apply(targets: targets, animated: self.animate) { p in
                lastProgress = p
                Task { @MainActor [weak self] in self?.status = p }
            }
            _ = lastProgress
            return (targets.count, "")
        } finish: { [weak self] count, _ in
            self?.status = "Arranged \(count) icons into \(label)."
            after?()
        }
    }

    /// Runs `work` on a background thread, then hands its value to `finish`
    /// on the main actor. All AppleScript goes through here.
    private func run<T>(_ busyStatus: String,
                        work: @escaping () throws -> (T, String),
                        finish: @escaping (T, String) -> Void) {
        guard !busy else { return }
        busy = true
        status = busyStatus
        Task.detached {
            do {
                let result = try work()
                await MainActor.run {
                    self.busy = false
                    finish(result.0, result.1)
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    if let e = error as? ScriptError, e.isPermissionError {
                        self.status = "macOS blocked Finder control. Allow ShapeDesk under System Settings → Privacy & Security → Automation, then retry."
                    } else {
                        self.status = "Error: \(error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription)"
                    }
                }
            }
        }
    }
}
