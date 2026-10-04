import Foundation
import CoreGraphics

/// The built-in shapes, all generated as parametric polylines in a unit-ish
/// coordinate space (y down, matching screen coordinates), then resampled
/// to exactly one point per desktop icon.
enum ShapeKind: String, CaseIterable, Identifiable {
    case heart, circle, star, spiral, wave

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .heart:  return "heart.fill"
        case .circle: return "circle"
        case .star:   return "star.fill"
        case .spiral: return "hurricane"
        case .wave:   return "water.waves"
        }
    }
}

enum ShapeMath {

    /// Dense polyline describing the shape. `closed` shapes loop back to the
    /// first point; open shapes (spiral, wave) have distinct ends.
    static func densePolyline(for kind: ShapeKind, samples: Int = 3000) -> (points: [CGPoint], closed: Bool) {
        switch kind {
        case .circle:
            let pts = (0..<samples).map { i -> CGPoint in
                let t = 2 * Double.pi * Double(i) / Double(samples)
                return CGPoint(x: cos(t), y: sin(t))
            }
            return (pts, true)

        case .heart:
            // Classic parametric heart, y flipped for screen coordinates.
            let pts = (0..<samples).map { i -> CGPoint in
                let t = 2 * Double.pi * Double(i) / Double(samples)
                let x = 16 * pow(sin(t), 3)
                let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                return CGPoint(x: x / 17, y: -y / 17)
            }
            return (pts, true)

        case .star:
            var pts: [CGPoint] = []
            let outer = 1.0, inner = 0.45
            for i in 0..<10 {
                let r = i.isMultiple(of: 2) ? outer : inner
                let a = -Double.pi / 2 + Double(i) * Double.pi / 5
                pts.append(CGPoint(x: r * cos(a), y: r * sin(a)))
            }
            return (pts, true)

        case .spiral:
            let turns = 2.2
            let pts = (0..<samples).map { i -> CGPoint in
                let f = Double(i) / Double(samples - 1)
                let theta = turns * 2 * Double.pi * f
                let r = 0.04 + 0.96 * f
                return CGPoint(x: r * cos(theta), y: r * sin(theta))
            }
            return (pts, false)

        case .wave:
            let pts = (0..<samples).map { i -> CGPoint in
                let f = Double(i) / Double(samples - 1)
                let x = f * 2 - 1
                return CGPoint(x: x, y: 0.35 * sin(3 * Double.pi * x))
            }
            return (pts, false)
        }
    }

    /// Walks the polyline and places `n` points at even arc-length intervals,
    /// so icons spread uniformly along any shape.
    static func resample(_ polyline: [CGPoint], closed: Bool, count n: Int) -> [CGPoint] {
        guard n > 0, !polyline.isEmpty else { return [] }
        if n == 1 { return [polyline[polyline.count / 2]] }

        var pts = polyline
        if closed, let first = polyline.first { pts.append(first) }

        var cum = [0.0]
        for i in 1..<pts.count {
            cum.append(cum[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
        }
        let total = cum.last ?? 0
        guard total > 0 else { return Array(repeating: pts[0], count: n) }

        let step = closed ? total / Double(n) : total / Double(n - 1)
        var out: [CGPoint] = []
        var seg = 1
        for k in 0..<n {
            let target = min(step * Double(k), total)
            while seg < cum.count - 1 && cum[seg] < target { seg += 1 }
            let d0 = cum[seg - 1], d1 = cum[seg]
            let f = d1 > d0 ? (target - d0) / (d1 - d0) : 0
            out.append(CGPoint(
                x: pts[seg - 1].x + f * (pts[seg].x - pts[seg - 1].x),
                y: pts[seg - 1].y + f * (pts[seg].y - pts[seg - 1].y)
            ))
        }
        return out
    }

    /// Scales and centers points into a destination rect (in Finder
    /// coordinates, origin top-left), preserving aspect ratio.
    static func fit(_ points: [CGPoint], into rect: CGRect, fill: Double) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let bw = max(maxX - minX, 0.0001)
        let bh = max(maxY - minY, 0.0001)
        let scale = min(rect.width * fill / bw, rect.height * fill / bh)
        let cx = rect.midX - (minX + maxX) / 2 * scale
        let cy = rect.midY - (minY + maxY) / 2 * scale
        return points.map { CGPoint(x: $0.x * scale + cx, y: $0.y * scale + cy) }
    }

    /// Median nearest-neighbor distance; used to warn when icons will overlap.
    static func medianSpacing(_ points: [CGPoint]) -> Double {
        guard points.count > 1 else { return .infinity }
        var nearest: [Double] = []
        for i in points.indices {
            var best = Double.infinity
            for j in points.indices where j != i {
                best = min(best, hypot(points[i].x - points[j].x, points[i].y - points[j].y))
            }
            nearest.append(best)
        }
        nearest.sort()
        return nearest[nearest.count / 2]
    }
}
