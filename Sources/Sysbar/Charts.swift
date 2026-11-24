// Chart building blocks for the detail panels, drawn with Shapes (cheap to
// redraw every tick, no GPU buffers).

import SwiftUI

// MARK: - Opacity layers

private struct TextOpacityKey: EnvironmentKey { static let defaultValue = 1.0 }
private struct GraphicsOpacityKey: EnvironmentKey { static let defaultValue = 1.0 }

extension EnvironmentValues {
    /// Opacity of text and icons in a panel (see `OpacitySet`).
    var textOpacity: Double {
        get { self[TextOpacityKey.self] }
        set { self[TextOpacityKey.self] = newValue }
    }
    /// Opacity of charts, bars and pies in a panel.
    var graphicsOpacity: Double {
        get { self[GraphicsOpacityKey.self] }
        set { self[GraphicsOpacityKey.self] = newValue }
    }
}

/// Root of a panel's content: text in the default (hierarchical) styles
/// fades through the foreground style; explicitly colored text uses
/// `.textLayer()`, charts `.graphicsLayer()`.
private struct PanelOpacityModifier: ViewModifier {
    let key: String?
    func body(content: Content) -> some View {
        let o = Settings.opacity(for: key)
        content
            .foregroundStyle((Settings.textColor ?? Color.primary).opacity(o.text))
            .environment(\.textOpacity, o.text)
            .environment(\.graphicsOpacity, o.graphics)
    }
}

/// Header buttons (pin, opacity, settings…) never fade below 35%, and
/// Settings not at all, so the controls to undo a 0% stay reachable.
private struct ControlsLayer: ViewModifier {
    let minimum: Double
    @Environment(\.textOpacity) private var opacity
    func body(content: Content) -> some View {
        let o = max(opacity, minimum)
        content
            .foregroundStyle((Settings.textColor ?? Color.primary).opacity(o))
            .environment(\.textOpacity, o)
            .environment(\.graphicsOpacity, minimum >= 1 ? 1 : o)
    }
}

private struct TextLayer: ViewModifier {
    @Environment(\.textOpacity) private var opacity
    func body(content: Content) -> some View { content.opacity(opacity) }
}

private struct GraphicsLayer: ViewModifier {
    @Environment(\.graphicsOpacity) private var opacity
    func body(content: Content) -> some View { content.opacity(opacity) }
}

extension View {
    /// Applies the text and graphics opacity: global, or a detail panel's
    /// own (key = section kind) when it's set to Separate.
    func panelOpacity(_ key: String? = nil) -> some View { modifier(PanelOpacityModifier(key: key)) }
    /// Header controls: at least 35% visible.
    func controlsLayer() -> some View { modifier(ControlsLayer(minimum: 0.35)) }
    /// Settings: never faded.
    func unfaded() -> some View { modifier(ControlsLayer(minimum: 1)) }
    /// Text with its own color (not faded by the foreground style).
    func textLayer() -> some View { modifier(TextLayer()) }
    /// Charts, bars and pies.
    func graphicsLayer() -> some View { modifier(GraphicsLayer()) }
}

extension Array where Element == Double {
    /// Largest / smallest value, ignoring gaps (NaN).
    var finiteMax: Double? { lazy.filter(\.isFinite).max() }
    var finiteMin: Double? { lazy.filter(\.isFinite).min() }

    /// Index ranges of consecutive real values (gaps are NaN).
    var finiteRuns: [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (i, v) in enumerated() {
            if v.isFinite { if start == nil { start = i } } else if let s = start { runs.append(s..<i); start = nil }
        }
        if let s = start { runs.append(s..<count) }
        return runs
    }
}

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
    /// Seconds covered by the full width (`capacity` points), for the time axis.
    var span: TimeInterval = Settings.chartWindow

    private var top: Double {
        if let maxValue { return maxValue }
        let peak = series.flatMap(\.values).finiteMax ?? 0
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
            .graphicsLayer()
        }
        .frame(height: height)
        .padding(.top, 6)
        .padding(.trailing, 8)
        .padding(.leading, 2)
        .withTimeAxis(span)
    }
}

/// Clock times under a history chart: its start, three quarter marks and
/// now. Seconds are shown for spans under 10 minutes.
extension View {
    /// The chart above its time axis, on the rounded chart background.
    func withTimeAxis(_ span: TimeInterval) -> some View {
        VStack(spacing: 3) {
            self
            TimeAxis(span: span).padding(.leading, 52).padding(.trailing, 8).padding(.bottom, 4)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

/// Fixed-height row of plain texts (no GeometryReader): it can't change the
/// panel's size as the times tick, so it never re-triggers panel layout.
struct TimeAxis: View {
    let span: TimeInterval

    private static let short: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let long: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        let now = Date()
        let format = span < 600 ? Self.long : Self.short
        HStack(spacing: 0) {
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { f in
                if f > 0 { Spacer(minLength: 2) }
                Text(format.string(from: now.addingTimeInterval(-span * (1 - f))))
            }
        }
        .font(.system(size: 8.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(height: 10)
    }
}

/// Stacked area history: each layer is filled from the layer below it up
/// to its own line, so the top edge is the total. Values are absolute
/// (e.g. bytes); `top` is the Y-axis maximum.
struct StackedHistoryChart: View {
    struct Layer {
        var values: [Double]
        var color: Color
    }

    let layers: [Layer]
    let top: Double
    var label: (Double) -> String
    var height: CGFloat = 86
    var capacity = SystemStatsSampler.historyLimit
    var span: TimeInterval = Settings.chartWindow

    var body: some View {
        let sums = cumulative
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
                ForEach(layers.indices, id: \.self) { i in
                    BandPath(upper: sums[i], lower: i == 0 ? [] : sums[i - 1], top: top, capacity: capacity)
                        .fill(layers[i].color.opacity(0.45))
                    ChartPath(values: sums[i], top: top, capacity: capacity, closed: false)
                        .stroke(layers[i].color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
            }
            .graphicsLayer()
        }
        .frame(height: height)
        .padding(.top, 6)
        .padding(.trailing, 8)
        .padding(.leading, 2)
        .withTimeAxis(span)
    }

    /// Running totals per layer, aligned on the newest sample.
    private var cumulative: [[Double]] {
        let count = layers.map(\.values.count).min() ?? 0
        var running = [Double](repeating: 0, count: count)
        return layers.map { layer in
            let values = layer.values.suffix(count)
            for (i, v) in values.enumerated() { running[i] += v }
            return running
        }
    }
}

/// Area between two right-aligned series (`lower` empty = the baseline).
private struct BandPath: Shape {
    let upper: [Double]
    let lower: [Double]
    let top: Double
    let capacity: Int

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let up = Array(upper.suffix(capacity))
        guard up.count > 1, top > 0 else { return p }
        let low = lower.isEmpty ? [Double](repeating: 0, count: up.count) : Array(lower.suffix(up.count))
        let step = rect.width / CGFloat(max(1, capacity - 1))
        let startX = rect.maxX - step * CGFloat(up.count - 1)
        func point(_ i: Int, _ v: Double) -> CGPoint {
            CGPoint(x: startX + step * CGFloat(i), y: rect.maxY - rect.height * CGFloat(min(1, max(0, v / top))))
        }
        // Gaps (NaN) in either edge split the band.
        let both = up.indices.map { i in up[i].isFinite && (i < low.count ? low[i].isFinite : false) ? up[i] : .nan }
        for run in both.finiteRuns {
            p.move(to: point(run.lowerBound, up[run.lowerBound]))
            for i in run.dropFirst() { p.addLine(to: point(i, up[i])) }
            for i in run.reversed() { p.addLine(to: point(i, low[i])) }
            p.closeSubpath()
        }
        return p
    }
}

/// Donut chart: slices clockwise from 12 o'clock, fractions of `total`.
struct DonutChart: View {
    struct Slice {
        var value: Double
        var color: Color
    }

    let slices: [Slice]
    let total: Double
    var lineWidth: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            ForEach(Array(ranges.enumerated()), id: \.offset) { i, range in
                Circle()
                    .trim(from: range.lowerBound, to: range.upperBound)
                    .stroke(slices[i].color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        .graphicsLayer()
        .padding(lineWidth / 2)
    }

    private var ranges: [ClosedRange<CGFloat>] {
        guard total > 0 else { return [] }
        var start: CGFloat = 0
        return slices.map { slice in
            let end = min(1, start + CGFloat(max(0, slice.value) / total))
            defer { start = end }
            return start...end
        }
    }
}

/// Colored square + label, for chart legends.
struct LegendDot: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9).graphicsLayer()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
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
        func x(_ i: Int) -> CGFloat { startX + step * CGFloat(i) }
        // One piece per run of samples; gaps (NaN) stay empty.
        for run in points.finiteRuns {
            for i in run {
                let pt = CGPoint(x: x(i), y: rect.maxY - rect.height * CGFloat(min(1, max(0, points[i] / top))))
                i == run.lowerBound ? p.move(to: pt) : p.addLine(to: pt)
            }
            if closed {
                p.addLine(to: CGPoint(x: x(run.upperBound - 1), y: rect.maxY))
                p.addLine(to: CGPoint(x: x(run.lowerBound), y: rect.maxY))
                p.closeSubpath()
            }
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
            .graphicsLayer()
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
                .textLayer()
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
        .graphicsLayer()
    }
}
