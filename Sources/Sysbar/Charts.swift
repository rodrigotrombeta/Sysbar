// Chart building blocks for the detail panels, drawn with Shapes (cheap to
// redraw every tick, no GPU buffers).

import SwiftUI

/// A history chart with a labelled grid (0 / 25 / 50 / 75 / 100 % of max),
/// newest sample on the right — like Activity Monitor / iStat Menus.
struct HistoryChart: View {
    struct Series {
        var values: [Double]
        var color: Color
        var fill = true
    }

    let series: [Series]
    /// Top of the Y axis. nil = auto from the data (at least `minimumMax`).
    var maxValue: Double? = 1
    var minimumMax: Double = 1
    var label: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    var height: CGFloat = 86
    var capacity = SystemStatsSampler.historyLimit

    private var top: Double {
        if let maxValue { return maxValue }
        let peak = series.flatMap(\.values).max() ?? 0
        return max(minimumMax, peak * 1.1)
    }

    var body: some View {
        let top = self.top
        HStack(alignment: .top, spacing: 6) {
            GeometryReader { geo in
                ForEach([1.0, 0.75, 0.5, 0.25, 0], id: \.self) { level in
                    Text(label(top * level))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: geo.size.width, alignment: .trailing)
                        .position(x: geo.size.width / 2, y: geo.size.height * (1 - level))
                }
            }
            .frame(width: 44)

            ZStack {
                GridShape().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                ForEach(series.indices, id: \.self) { i in
                    let s = series[i]
                    if s.fill {
                        ChartPath(values: s.values, top: top, capacity: capacity, closed: true)
                            .fill(LinearGradient(colors: [s.color.opacity(0.28), s.color.opacity(0.03)],
                                                 startPoint: .top, endPoint: .bottom))
                    }
                    ChartPath(values: s.values, top: top, capacity: capacity, closed: false)
                        .stroke(s.color, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                }
            }
        }
        .frame(height: height)
        .padding(.vertical, 6)
        .padding(.trailing, 8)
        .padding(.leading, 2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

private struct GridShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for level in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let y = rect.minY + rect.height * level
            p.move(to: CGPoint(x: rect.minX, y: y))
            p.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return p
    }
}

/// Right-aligned series: `capacity` slots across the width, newest at the end.
struct ChartPath: Shape {
    let values: [Double]
    let top: Double
    let capacity: Int
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let points = Array(values.suffix(capacity))
        guard points.count > 1, top > 0 else { return p }
        let step = rect.width / CGFloat(max(1, capacity - 1))
        let startX = rect.maxX - step * CGFloat(points.count - 1)
        for (i, v) in points.enumerated() {
            let y = rect.maxY - rect.height * CGFloat(min(1, max(0, v / top)))
            let pt = CGPoint(x: startX + step * CGFloat(i), y: y)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        if closed {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: startX, y: rect.maxY))
            p.closeSubpath()
        }
        return p
    }
}

/// "Label ........ 28%" with a capsule bar underneath.
struct MeterRow: View {
    let label: String
    let value: String
    let fraction: Double
    var color: Color = .blue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12))
                Spacer(minLength: 4)
                Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(color)
                        .frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, fraction)))))
                }
            }
            .frame(height: 6)
        }
    }
}

/// Simple "Label ...... value" row.
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 12).monospacedDigit()).foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).padding(.top, 4)
    }
}

/// A small inline sparkline (no axis), for per-core / per-device rows.
struct MiniChart: View {
    let values: [Double]
    let color: Color
    var body: some View {
        ZStack {
            ChartPath(values: values, top: 1, capacity: SystemStatsSampler.historyLimit, closed: true)
                .fill(color.opacity(0.25))
            ChartPath(values: values, top: 1, capacity: SystemStatsSampler.historyLimit, closed: false)
                .stroke(color, lineWidth: 1)
        }
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.05)))
    }
}
