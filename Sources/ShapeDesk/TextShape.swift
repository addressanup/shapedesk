import AppKit
import CoreGraphics

/// Renders a word into an offscreen bitmap and picks `n` well-spread points
/// inside the glyphs, so desktop icons spell out the text.
enum TextShape {

    static func points(for text: String, count n: Int) -> [CGPoint] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, n > 0 else { return [] }

        let W = 1200, H = 360
        let baseSize: CGFloat = 300

        // Measure once, then scale the font so the text fits the canvas.
        let probe = NSAttributedString(string: trimmed, attributes: [
            .font: NSFont.systemFont(ofSize: baseSize, weight: .heavy)
        ])
        let probeSize = probe.size()
        let scale = min((CGFloat(W) - 40) / probeSize.width, (CGFloat(H) - 40) / probeSize.height)

        let attributed = NSAttributedString(string: trimmed, attributes: [
            .font: NSFont.systemFont(ofSize: baseSize * scale, weight: .heavy),
            .foregroundColor: NSColor.white
        ])

        let image = NSImage(size: NSSize(width: W, height: H))
        image.lockFocus()
        NSColor.black.set()
        NSRect(x: 0, y: 0, width: W, height: H).fill()
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: (CGFloat(W) - size.width) / 2,
                                    y: (CGFloat(H) - size.height) / 2))
        image.unlockFocus()

        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Bitmap row 0 is the top of the image, so (x, y) is already in
        // y-down screen-style coordinates.
        var pixels: [CGPoint] = []
        for y in 0..<h {
            for x in 0..<w {
                if data[(y * w + x) * 4 + 3] > 128 {
                    pixels.append(CGPoint(x: x, y: y))
                }
            }
        }
        guard !pixels.isEmpty else { return [] }

        // Cap the candidate pool so greedy selection stays fast.
        if pixels.count > 40_000 {
            let strideN = pixels.count / 40_000
            pixels = Swift.stride(from: 0, to: pixels.count, by: strideN).map { pixels[$0] }
        }

        // Greedy farthest-ish selection: accept a pixel only if it is at least
        // `minDist` from everything already chosen; relax if we run short.
        var minX = pixels[0].x, maxX = pixels[0].x, minY = pixels[0].y, maxY = pixels[0].y
        for p in pixels {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let area = max((maxX - minX) * (maxY - minY), 1)
        var minDist = sqrt(area / Double(n)) * 0.85

        var chosen: [CGPoint] = []
        for _ in 0..<6 {
            chosen.removeAll(keepingCapacity: true)
            var shuffled = pixels
            shuffled.shuffle()
            outer: for p in shuffled {
                for c in chosen {
                    if hypot(p.x - c.x, p.y - c.y) < minDist { continue outer }
                }
                chosen.append(p)
                if chosen.count == n { break }
            }
            if chosen.count >= n { break }
            minDist *= 0.7
        }

        // Last resort: pad with evenly strided pixels.
        if chosen.count < n {
            var i = 0
            let step = max(1, pixels.count / max(1, n - chosen.count))
            while chosen.count < n {
                chosen.append(pixels[i % pixels.count])
                i += step
            }
        }

        // Reading order looks better than random assignment.
        chosen.sort { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        return Array(chosen.prefix(n))
    }
}
