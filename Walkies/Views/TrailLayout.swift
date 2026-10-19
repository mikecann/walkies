import CoreGraphics
import Foundation

/// Samples in screen points, so footsteps stay legible at every map zoom. The phase
/// continues across vertices and offscreen segments instead of restarting at each GPS fix.
nonisolated enum TrailLayout {
    struct Stamp {
        var point: CGPoint
        /// Direction of travel in screen coordinates, in radians from the positive x axis.
        var angle: Double
        var index: Int

        var isLeft: Bool { index.isMultiple(of: 2) }
    }

    static func stamps(along points: [CGPoint], spacing: Double = 12, in bounds: CGRect) -> [Stamp] {
        guard points.count > 1, spacing.isFinite, spacing > 0 else { return [] }
        var distance = 0.0
        var stamps: [Stamp] = []
        for i in points.indices.dropFirst() {
            let a = points[i - 1], b = points[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = hypot(dx, dy)
            guard length.isFinite, length > 0 else { continue }
            defer { distance += length }
            guard let range = visibleRange(from: a, to: b, in: bounds) else { continue }
            let first = max(0, Int(ceil((distance + length * range.lowerBound - spacing / 2) / spacing)))
            let end = distance + length * range.upperBound
            var index = first
            while Double(index) * spacing + spacing / 2 <= end {
                let offset = Double(index) * spacing + spacing / 2 - distance
                // A sample at a vertex belongs to the incoming segment only.
                if offset > 0 || i == 1 {
                    stamps.append(Stamp(
                        point: CGPoint(x: a.x + dx * offset / length, y: a.y + dy * offset / length),
                        angle: atan2(dy, dx), index: index
                    ))
                }
                index += 1
            }
        }
        return stamps
    }

    /// Liang-Barsky clipping avoids generating millions of offscreen footsteps when
    /// the tilted camera projects a distant route segment close to its horizon.
    static func visibleRange(from a: CGPoint, to b: CGPoint, in bounds: CGRect) -> ClosedRange<Double>? {
        guard !bounds.isNull, a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return nil }
        let dx = b.x - a.x, dy = b.y - a.y
        var low = 0.0, high = 1.0
        for (p, q) in [(-dx, a.x - bounds.minX), (dx, bounds.maxX - a.x), (-dy, a.y - bounds.minY), (dy, bounds.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return nil }
            } else {
                let t = q / p
                if p < 0 { low = max(low, t) } else { high = min(high, t) }
                if low > high { return nil }
            }
        }
        return low...high
    }
}
