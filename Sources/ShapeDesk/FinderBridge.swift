import Foundation
import CoreGraphics

struct ScriptError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    /// True when macOS blocked us from controlling Finder (Automation permission).
    var isPermissionError: Bool {
        message.contains("1743") || message.contains("not allowed") ||
        message.contains("Not authorized") || message.contains("not permitted")
    }
}

struct DesktopIcon {
    let name: String
    var position: CGPoint   // Finder coordinates: origin at top-left of the main screen
}

/// Talks to Finder through AppleScript (via /usr/bin/osascript) to read and
/// set the real positions of desktop icons.
enum FinderBridge {

    /// Which property actually moves a desktop icon on this macOS version.
    /// Probed once per session; some versions prefer `desktop position`.
    private static var positionProperty: String?

    // MARK: - osascript runner

    /// Runs an AppleScript, passed on stdin so large animation scripts can't
    /// hit the argument-size limit.
    @discardableResult
    private static func run(_ lines: [String]) throws -> (out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let source = lines.joined(separator: "\n") + "\n"
        inPipe.fileHandleForWriting.write(source.data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw ScriptError(message: err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), err)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Reading the desktop

    static func desktopIconNames() throws -> [String] {
        let r = try run([
            "set AppleScript's text item delimiters to linefeed",
            "tell application \"Finder\" to get name of every item of desktop as string"
        ])
        if r.out.isEmpty { return [] }
        return r.out.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// Positions of all desktop icons, aligned with `desktopIconNames()` order.
    /// `desktop position` is the property that holds real coordinates for
    /// desktop items (plain `position` returns {-1, -1} there).
    static func desktopPositions() throws -> [CGPoint] {
        let r = try run([
            "set AppleScript's text item delimiters to \",\"",
            "tell application \"Finder\" to get desktop position of every item of desktop as string"
        ])
        let numbers = r.out.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap(Double.init)
        guard numbers.count >= 2, numbers.count.isMultiple(of: 2) else { return [] }
        var points: [CGPoint] = []
        var i = 0
        while i + 1 < numbers.count {
            points.append(CGPoint(x: numbers[i], y: numbers[i + 1]))
            i += 2
        }
        return points
    }

    static func insertionFolder() throws -> URL? {
        let r = try run([
            "with timeout of 3 seconds",
            "tell application \"Finder\" to set folderAlias to (insertion location as alias)",
            "end timeout",
            "POSIX path of folderAlias"
        ])
        return r.out.isEmpty ? nil : URL(fileURLWithPath: r.out, isDirectory: true)
    }

    // MARK: - Writing positions

    /// Detects whether `desktop position` or plain `position` works on this
    /// system, using the first icon as a harmless probe (sets it to its
    /// current position).
    private static func resolvePositionProperty(icon: DesktopIcon) throws -> String {
        if let cached = positionProperty { return cached }
        let x = Int(icon.position.x), y = Int(icon.position.y)
        let name = escape(icon.name)
        do {
            try run(["tell application \"Finder\" to set desktop position of item \"\(name)\" of desktop to {\(x), \(y)}"])
            positionProperty = "desktop position"
        } catch {
            try run(["tell application \"Finder\" to set position of item \"\(name)\" of desktop to {\(x), \(y)}"])
            positionProperty = "position"
        }
        return positionProperty!
    }

    /// Moves every icon in one AppleScript call.
    static func setPositions(_ items: [(name: String, point: CGPoint)], property: String) throws {
        guard !items.isEmpty else { return }
        try run(moveScript(frames: [items], property: property))
    }

    /// One Finder script that applies each frame of moves in order.
    ///
    /// Waiting for Finder's reply to every single move costs ~18 ms, which
    /// made a 40-icon frame take ~0.75 s. So each frame's moves are sent
    /// without waiting (a move that fails is simply skipped), and one cheap
    /// query at the end of the frame waits until Finder has applied them all.
    /// That keeps frames in order and evenly paced, ~90 ms for 40 icons.
    private static func moveScript(frames: [[(name: String, point: CGPoint)]],
                                   property: String) -> [String] {
        var lines = ["tell application \"Finder\""]
        for frame in frames {
            lines.append("ignoring application responses")
            for item in frame {
                lines.append("set \(property) of item \"\(escape(item.name))\" of desktop to {\(Int(item.point.x)), \(Int(item.point.y))}")
            }
            lines.append("end ignoring")
            lines.append("count items of desktop")
        }
        lines.append("end tell")
        return lines
    }

    /// Full layout pass: reads icons, moves each to its target point, with an
    /// optional eased animation from the current positions.
    static func apply(targets: [(name: String, point: CGPoint)], animated: Bool,
                      progress: @escaping (String) -> Void) throws {
        guard !targets.isEmpty else { return }

        let current = try desktopPositions()
        let probe = DesktopIcon(name: targets[0].name,
                                position: current.first ?? targets[0].point)
        let property = try resolvePositionProperty(icon: probe)

        let canAnimate = animated && current.count == targets.count
        if !canAnimate {
            progress("Placing icons…")
            try setPositions(targets, property: property)
            return
        }

        let frameCount = 14
        let frames: [[(name: String, point: CGPoint)]] = (1...frameCount).map { f in
            let t = Double(f) / Double(frameCount)
            let eased = t * t * (3 - 2 * t)   // smoothstep
            return targets.indices.map { i in
                let from = current[i], to = targets[i].point
                return (targets[i].name, CGPoint(
                    x: from.x + (to.x - from.x) * eased,
                    y: from.y + (to.y - from.y) * eased
                ))
            }
        }
        progress("Animating…")
        try run(moveScript(frames: frames, property: property))
    }

    /// "Clean Up By Name" replacement: sorted grid, right-aligned columns,
    /// top to bottom — the way Finder normally stacks a fresh desktop.
    static func gridTargets(names: [String], in rect: CGRect,
                            spacing: Double = 100) -> [(name: String, point: CGPoint)] {
        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let rows = max(1, Int((rect.height - 80) / spacing))
        return sorted.enumerated().map { idx, name in
            let col = idx / rows
            let row = idx % rows
            let x = rect.maxX - 60 - Double(col) * spacing
            let y = rect.minY + 40 + Double(row) * spacing
            return (name, CGPoint(x: x, y: y))
        }
    }
}
