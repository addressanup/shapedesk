import AppKit
import CoreGraphics

/// Spells text with icons. The text is drawn in a thin weight and reduced to
/// the centerlines of its strokes. Icons go on stroke ends and sharp corners
/// first, then fill the remaining stroke length evenly. Ends and corners are
/// what make a letter recognizable when it only gets a handful of icons.
enum TextShape {

    private static let fontSize: CGFloat = 200

    /// A one-line word is very flat, so long words are stretched vertically
    /// (up to this factor) to use more of the screen height.
    private static let maxStretch = 1.6

    /// - Parameter aspect: width / height of the area the text will be fit into.
    static func points(for text: String, count n: Int, aspect: Double) -> [CGPoint] {
        // Capitals survive icon resolution; lowercase bowls and tails collapse.
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !word.isEmpty, n > 0, let glyphs = rasterize(word) else { return [] }

        var line = centerline(glyphs)
        guard let first = line.first else { return [] }
        let anchors = endsAndCorners(of: line, width: glyphs.width, height: glyphs.height)

        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in line {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let textAspect = (maxX - minX) / max(maxY - minY, 1)
        let stretch = min(max(textAspect / max(aspect, 0.1), 1), maxStretch)
        if stretch > 1 {
            line = line.map { CGPoint(x: $0.x, y: $0.y * stretch) }
        }

        var chosen: [CGPoint]
        if anchors.count >= n {
            // Not even enough icons for every end and corner: spread over those.
            let corners = anchors.map { line[$0] }
            chosen = farthestPointSample(corners, seeds: [], count: n).map { corners[$0] }
        } else {
            var picked = farthestPointSample(line, seeds: anchors, count: n)
            relax(&picked, fixed: anchors.count, on: line)
            chosen = picked.map { line[$0] }
        }
        // More icons than stroke pixels: stack the extras.
        var i = 0
        while chosen.count < n {
            chosen.append(chosen[i])
            i += 1
        }

        // Reading order, so icons fill the word left to right.
        chosen.sort { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        return chosen
    }

    // MARK: - Strokes

    private struct Bitmap {
        let width: Int
        let height: Int
        let mask: [Bool]
    }

    /// The text drawn white on black, as a y-down mask of stroke pixels.
    private static func rasterize(_ text: String) -> Bitmap? {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .thin),
            .foregroundColor: NSColor.white,
            // Extra tracking keeps neighboring letters from reading as one
            // shape once each stroke is only a few icons long.
            .kern: fontSize * 0.25
        ])
        // Keeps the neighborhood scans below inside the bitmap.
        let pad: CGFloat = 40
        let size = attributed.size()
        let w = Int((size.width + 2 * pad).rounded(.up))
        let h = Int((size.height + 2 * pad).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }

        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attributed.draw(at: NSPoint(x: pad, y: pad))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = ctx.data else { return nil }
        let rowBytes = ctx.bytesPerRow
        let gray = data.bindMemory(to: UInt8.self, capacity: rowBytes * h)

        // Bitmap memory starts with the top row, so y already points down
        // like Finder coordinates.
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                mask[y * w + x] = gray[y * rowBytes + x] > 128
            }
        }
        return Bitmap(width: w, height: h, mask: mask)
    }

    /// Thins the strokes to one-pixel centerlines (Zhang–Suen), so icons sit
    /// mid-stroke instead of zigzagging between its edges.
    private static func centerline(_ glyphs: Bitmap) -> [CGPoint] {
        let w = glyphs.width, h = glyphs.height
        var on = glyphs.mask
        var doomed = [Bool](repeating: false, count: w * h)
        // Neighbors clockwise from north (P2...P9 in Zhang–Suen's notation).
        let around = [-w, -w + 1, 1, w + 1, w, w - 1, -1, -w - 1]

        var changed = true
        while changed {
            changed = false
            for pass in 0..<2 {
                var removals: [Int] = []
                for y in 1..<(h - 1) {
                    for x in 1..<(w - 1) where on[y * w + x] {
                        let i = y * w + x
                        var bits = 0
                        for (k, o) in around.enumerated() where on[i + o] { bits |= 1 << k }
                        let neighbors = bits.nonzeroBitCount
                        guard neighbors >= 2, neighbors <= 6 else { continue }
                        var transitions = 0
                        for k in 0..<8 where bits & (1 << k) == 0 && bits & (1 << ((k + 1) % 8)) != 0 {
                            transitions += 1
                        }
                        guard transitions == 1 else { continue }
                        let n = bits & 1 != 0, e = bits & 4 != 0
                        let s = bits & 16 != 0, west = bits & 64 != 0
                        let keep = pass == 0
                            ? (n && e && s) || (e && s && west)
                            : (n && e && west) || (n && s && west)
                        if !keep { removals.append(i) }
                    }
                }
                for i in removals { doomed[i] = true }
                for i in removals {
                    // Removing a pixel together with all of its neighbors
                    // would erase a tiny part (the dot of "!") outright.
                    if around.contains(where: { on[i + $0] && !doomed[i + $0] }) {
                        on[i] = false
                        changed = true
                    }
                }
                for i in removals { doomed[i] = false }
            }
        }

        var line: [CGPoint] = []
        for y in 0..<h {
            for x in 0..<w where on[y * w + x] {
                line.append(CGPoint(x: x, y: y))
            }
        }
        return line
    }

    /// Indices of stroke ends and sharp corners on the centerline.
    ///
    /// A point qualifies when its nearby centerline is lopsided (the centroid
    /// sits well off the point) and a ring around it is crossed by strokes in
    /// one direction (an end) or in two directions that bend (a corner).
    /// Points near a junction look lopsided too, since the branch pulls the
    /// centroid toward it, but their rings are crossed in three or more
    /// directions.
    private static func endsAndCorners(of line: [CGPoint], width w: Int, height h: Int) -> [Int] {
        var onLine = [Bool](repeating: false, count: w * h)
        for p in line { onLine[Int(p.y) * w + Int(p.x)] = true }
        func isLine(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < w && y < h && onLine[y * w + x]
        }

        let r = Int(fontSize * 0.08)
        let disc = discOffsets(radius: r)

        let ringRadius = Double(fontSize) * 0.12
        let reach = Int(ringRadius.rounded(.up)) + 1
        var ring: [(dx: Int, dy: Int, angle: Double)] = []
        for dy in -reach...reach {
            for dx in -reach...reach where abs(hypot(Double(dx), Double(dy)) - ringRadius) <= 1 {
                ring.append((dx, dy, atan2(Double(dy), Double(dx))))
            }
        }
        ring.sort { $0.angle < $1.angle }
        // Ring hits closer than this (in radians) belong to the same stroke.
        let sameBranch = 2.5 / ringRadius

        var found: [(index: Int, score: Double)] = []
        for (i, p) in line.enumerated() {
            let x = Int(p.x), y = Int(p.y)
            var sx = 0, sy = 0, hits = 0
            for (dx, dy) in disc where isLine(x + dx, y + dy) {
                sx += dx; sy += dy; hits += 1
            }
            // Ends score about 0.5, right-angle corners about 0.35.
            let score = hypot(Double(sx), Double(sy)) / Double(hits) / Double(r)
            guard score >= 0.15 else { continue }

            // Directions in which strokes leave the ring, as summed unit vectors.
            var branches: [(dirX: Double, dirY: Double)] = []
            var firstAngle: Double?
            var lastAngle = -Double.infinity
            for o in ring where isLine(x + o.dx, y + o.dy) {
                if o.angle - lastAngle > sameBranch {
                    branches.append((0, 0))
                }
                branches[branches.count - 1].dirX += cos(o.angle)
                branches[branches.count - 1].dirY += sin(o.angle)
                firstAngle = firstAngle ?? o.angle
                lastAngle = o.angle
            }
            // A stroke crossing the ring at ±180° is split in two; rejoin it.
            if branches.count > 1, let firstAngle,
               firstAngle + 2 * .pi - lastAngle <= sameBranch {
                let tail = branches.removeLast()
                branches[0].dirX += tail.dirX
                branches[0].dirY += tail.dirY
            }

            var qualifies = branches.count <= 1
            if branches.count == 2 {
                let a = atan2(branches[0].dirY, branches[0].dirX)
                let b = atan2(branches[1].dirY, branches[1].dirX)
                var between = abs(a - b)
                if between > .pi { between = 2 * .pi - between }
                qualifies = .pi - between > 0.7   // bends by more than ~40°
            }
            if qualifies {
                found.append((i, score))
            }
        }

        // Keep the strongest point per neighborhood. The neighborhood spans
        // the whole ring because a sharp point (the top of an A) still reads
        // as a corner some way down each of its strokes.
        var anchors: [Int] = []
        for f in found.sorted(by: { $0.score > $1.score })
        where anchors.allSatisfy({ squaredDistance(line[$0], line[f.index]) > ringRadius * ringRadius }) {
            anchors.append(f.index)
        }
        return anchors
    }

    private static func discOffsets(radius r: Int) -> [(dx: Int, dy: Int)] {
        var disc: [(dx: Int, dy: Int)] = []
        for dy in -r...r {
            for dx in -r...r where dx * dx + dy * dy <= r * r {
                disc.append((dx, dy))
            }
        }
        return disc
    }

    // MARK: - Spreading icons

    /// Starting from `seeds`, repeatedly adds the candidate farthest from
    /// everything picked so far. Returns indices into `candidates`.
    private static func farthestPointSample(_ candidates: [CGPoint], seeds: [Int],
                                            count n: Int) -> [Int] {
        guard !candidates.isEmpty else { return [] }
        var chosen = seeds
        if chosen.isEmpty, let start = candidates.indices.min(by: {
            candidates[$0].x + candidates[$0].y < candidates[$1].x + candidates[$1].y
        }) {
            chosen = [start]
        }
        var nearest = [Double](repeating: .infinity, count: candidates.count)
        for c in chosen {
            for i in candidates.indices {
                nearest[i] = min(nearest[i], squaredDistance(candidates[i], candidates[c]))
            }
        }
        while chosen.count < n {
            var best = 0
            for i in nearest.indices where nearest[i] > nearest[best] { best = i }
            if nearest[best] == 0 { break }
            chosen.append(best)
            for i in candidates.indices {
                nearest[i] = min(nearest[i], squaredDistance(candidates[i], candidates[best]))
            }
        }
        return chosen
    }

    /// Lloyd relaxation along the strokes: each free point moves to the
    /// middle of the stretch of stroke closest to it, which evens out the
    /// uneven gaps farthest-point sampling leaves. The first `fixed` points
    /// (ends and corners) stay put.
    private static func relax(_ chosen: inout [Int], fixed: Int, on line: [CGPoint],
                              iterations: Int = 10) {
        guard chosen.count > fixed else { return }
        for _ in 0..<iterations {
            var cells = [[Int]](repeating: [], count: chosen.count)
            for i in line.indices {
                var best = 0, bestD = Double.infinity
                for (k, c) in chosen.enumerated() {
                    let d = squaredDistance(line[i], line[c])
                    if d < bestD { bestD = d; best = k }
                }
                cells[best].append(i)
            }
            for k in fixed..<chosen.count where !cells[k].isEmpty {
                var cx = 0.0, cy = 0.0
                for i in cells[k] { cx += line[i].x; cy += line[i].y }
                let centroid = CGPoint(x: cx / Double(cells[k].count), y: cy / Double(cells[k].count))
                // Snap back onto the stroke.
                if let onStroke = cells[k].min(by: {
                    squaredDistance(line[$0], centroid) < squaredDistance(line[$1], centroid)
                }) {
                    chosen[k] = onStroke
                }
            }
        }
    }

    private static func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }
}
