// Draws the animated status-bar icon in the style of exelban/stats: a tiny
// stacked label next to a framed line chart / bar / percentage, one widget
// per selected metric, redrawn every sampling tick.

import AppKit

enum StatusIconRenderer {
    static let height: CGFloat = 18
    private static let labelWidth: CGFloat = 7
    private static let chartWidth: CGFloat = 32
    private static let barWidth: CGFloat = 7
    private static let percentWidth: CGFloat = 28
    private static let pieWidth: CGFloat = 18
    private static let speedWidth: CGFloat = 50
    /// I/O charts never scale below this (bytes/s), so idle noise stays flat.
    private static let ioFloor: Double = 256_000
    private static let gap: CGFloat = 2
    private static let widgetSpacing: CGFloat = 6
    /// Points shown in the menubar chart (the right-most part of the history).
    private static let chartPoints = 30

    struct Config {
        var metrics: [IconMetric]
        var style: IconStyle
        var colorModes: [IconMetric: IconColorMode]
        var showLabel: Bool

        func colorMode(_ metric: IconMetric) -> IconColorMode { colorModes[metric] ?? .metric }

        /// All-monochrome icons are template images (the system tints them);
        /// mixed icons draw their monochrome widgets in labelColor instead.
        var isTemplate: Bool { metrics.allSatisfy { colorMode($0) == .monochrome } }
    }

    static func image(
        snapshot: SystemStatsSnapshot,
        config: Config,
        appearance: NSAppearance?
    ) -> NSImage {
        let widths = config.metrics.map { width(for: $0, config: config) }
        let total = widths.reduce(0, +) + widgetSpacing * CGFloat(max(0, widths.count - 1))
        let size = NSSize(width: ceil(total), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            let draw = {
                var x: CGFloat = 0
                for (index, metric) in config.metrics.enumerated() {
                    drawWidget(metric: metric, snapshot: snapshot, config: config, originX: x)
                    x += widths[index] + widgetSpacing
                }
            }
            if let appearance {
                appearance.performAsCurrentDrawingAppearance(draw)
            } else {
                draw()
            }
            return true
        }
        image.isTemplate = config.isTemplate
        return image
    }

    // MARK: - Layout

    private static func width(for metric: IconMetric, config: Config) -> CGFloat {
        let label = config.showLabel ? labelWidth + gap : 0
        if metric == .network {
            return label + (Settings.networkStyle == .chart ? chartWidth : speedWidth)
        }
        if let chart = metric.chartKind {
            switch chart {
            case .pie: return label + pieWidth
            case .bar: return label + barWidth
            case .io: return label + chartWidth
            }
        }
        switch config.style {
        case .lineChart: return label + chartWidth
        case .barChart: return label + barWidth
        case .percent: return percentWidth
        case .lineAndPercent: return label + chartWidth + gap + percentWidth - 2
        }
    }

    // MARK: - Drawing

    private static func drawWidget(
        metric: IconMetric,
        snapshot: SystemStatsSnapshot,
        config: Config,
        originX: CGFloat
    ) {
        let value = metric.value(in: snapshot)
        let mode = config.colorMode(metric)
        let ink: NSColor = config.isTemplate ? .black : .labelColor
        let accent = color(for: metric, value: value, mode: mode, ink: ink)
        let textColor = ink
        let mono = mode == .monochrome
        var x = originX

        if metric == .network {
            if config.showLabel {
                drawStackedLabel(metric.shortLabel, color: textColor,
                                 rect: NSRect(x: x, y: 0, width: labelWidth, height: height))
                x += labelWidth + gap
            }
            let io = metric.ioHistory(in: snapshot)
            if Settings.networkStyle == .chart {
                drawIOChart(read: io.read, write: io.write,
                            readColor: mono ? ink : .systemBlue,
                            writeColor: mono ? ink : .systemRed,
                            frameColor: textColor,
                            rect: NSRect(x: x, y: 0, width: chartWidth, height: height))
            } else {
                drawSpeed(down: snapshot.networkIO?.read, up: snapshot.networkIO?.write,
                          textColor: textColor,
                          downColor: mono ? ink : .systemBlue,
                          upColor: mono ? ink : .systemRed,
                          rect: NSRect(x: x, y: 0, width: speedWidth, height: height))
            }
            return
        }

        if let chart = metric.chartKind {
            if config.showLabel {
                drawStackedLabel(metric.shortLabel, color: textColor,
                                 rect: NSRect(x: x, y: 0, width: labelWidth, height: height))
                x += labelWidth + gap
            }
            switch chart {
            case .pie:
                drawPie(segments: segments(for: metric, snapshot: snapshot, value: value,
                                           accent: accent, mode: mode),
                        track: trackColor(mode, ink: ink),
                        rect: NSRect(x: x, y: 0, width: pieWidth, height: height))
            case .bar:
                drawBar(segments: segments(for: metric, snapshot: snapshot, value: value,
                                           accent: accent, mode: mode),
                        track: trackColor(mode, ink: ink), frameColor: textColor,
                        rect: NSRect(x: x, y: 0, width: barWidth, height: height))
            case .io:
                let io = metric.ioHistory(in: snapshot)
                drawIOChart(read: io.read, write: io.write,
                            readColor: mono ? ink : .systemBlue,
                            writeColor: mono ? ink : .systemRed,
                            frameColor: textColor,
                            rect: NSRect(x: x, y: 0, width: chartWidth, height: height))
            }
            return
        }

        if config.style == .percent {
            drawPercentBlock(
                label: config.showLabel ? metric.shortLabel : nil,
                value: value, color: textColor,
                rect: NSRect(x: x, y: 0, width: percentWidth, height: height)
            )
            return
        }

        if config.showLabel {
            drawStackedLabel(metric.shortLabel, color: textColor,
                             rect: NSRect(x: x, y: 0, width: labelWidth, height: height))
            x += labelWidth + gap
        }

        switch config.style {
        case .lineChart, .lineAndPercent:
            let rect = NSRect(x: x, y: 0, width: chartWidth, height: height)
            drawLineChart(values: metric.history(in: snapshot), color: accent,
                          frameColor: textColor, rect: rect)
            x += chartWidth + gap
            if config.style == .lineAndPercent {
                drawPercentBlock(label: nil, value: value, color: textColor,
                                 rect: NSRect(x: x - 2, y: 0, width: percentWidth, height: height))
            }
        case .barChart:
            drawBar(segments: [(value ?? 0, accent)], track: .clear, frameColor: textColor,
                    rect: NSRect(x: x, y: 0, width: barWidth, height: height))
        case .percent:
            break
        }
    }

    private static func color(for metric: IconMetric, value: Double?, mode: IconColorMode,
                              ink: NSColor) -> NSColor {
        switch mode {
        case .monochrome: return ink
        case .metric: return metric.color
        case .utilization:
            let v = value ?? 0
            if v < 0.6 { return .systemGreen }
            if v < 0.85 { return .systemOrange }
            return .systemRed
        }
    }

    /// Letters stacked top-to-bottom, like Stats' widget labels.
    private static func drawStackedLabel(_ text: String, color: NSColor, rect: NSRect) {
        let letters = Array(text)
        guard !letters.isEmpty else { return }
        let fontSize: CGFloat = letters.count >= 3 ? 6.5 : 7.5
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let lineHeight: CGFloat = letters.count >= 3 ? 6 : 7.5
        let blockHeight = lineHeight * CGFloat(letters.count)
        var y = rect.midY + blockHeight / 2 - lineHeight
        for letter in letters {
            let s = NSAttributedString(string: String(letter), attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: rect.midX - size.width / 2,
                               y: y + (lineHeight - size.height) / 2))
            y -= lineHeight
        }
    }

    private static func drawLineChart(values: [Double], color: NSColor, frameColor: NSColor, rect: NSRect) {
        let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        frameColor.withAlphaComponent(0.45).setStroke()
        frame.lineWidth = 0.75
        frame.stroke()

        let plot = rect.insetBy(dx: 1.5, dy: 1.5)
        let points = Array(values.suffix(chartPoints))
        guard points.count > 1 else { return }

        let step = plot.width / CGFloat(chartPoints - 1)
        // Right-aligned, so new samples enter from the right and scroll left.
        let startX = plot.maxX - step * CGFloat(points.count - 1)
        let line = NSBezierPath()
        for (i, v) in points.enumerated() {
            let p = NSPoint(x: startX + step * CGFloat(i),
                            y: plot.minY + plot.height * CGFloat(min(1, max(0, v))))
            i == 0 ? line.move(to: p) : line.line(to: p)
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot).addClip()
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        area.line(to: NSPoint(x: startX, y: plot.minY))
        area.close()
        color.withAlphaComponent(0.35).setFill()
        area.fill()
        color.setStroke()
        line.lineWidth = 1
        line.lineJoinStyle = .round
        line.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Fractions (0...1) and colors stacked in a pie or bar. Memory splits
    /// into App / Wired / Compressed in the colored modes (iStat-style).
    private static func segments(for metric: IconMetric, snapshot: SystemStatsSnapshot,
                                 value: Double?, accent: NSColor,
                                 mode: IconColorMode) -> [(Double, NSColor)] {
        if metric == .memory, mode != .monochrome, snapshot.memory.totalBytes > 0 {
            let m = snapshot.memory
            let total = Double(m.totalBytes)
            return [
                (Double(m.appBytes) / total, MemoryPalette.app),
                (Double(m.wiredBytes) / total, MemoryPalette.wired),
                (Double(m.compressedBytes) / total, MemoryPalette.compressed),
            ]
        }
        return [(value ?? 0, accent)]
    }

    private static func trackColor(_ mode: IconColorMode, ink: NSColor) -> NSColor {
        mode == .monochrome ? ink.withAlphaComponent(0.3) : MemoryPalette.track
    }

    /// Two right-aligned lines, Stats-style: "↓ 1.2 MB/s" over "↑ 34 KB/s".
    private static func drawSpeed(down: Double?, up: Double?, textColor: NSColor,
                                  downColor: NSColor, upColor: NSColor, rect: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        func line(_ arrow: String, _ value: Double?, _ arrowColor: NSColor, y: CGFloat) {
            let s = NSMutableAttributedString(
                string: arrow + " ",
                attributes: [.font: font, .foregroundColor: arrowColor, .paragraphStyle: para])
            s.append(NSAttributedString(
                string: SystemStatsSampler.formatRate(value),
                attributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: para]))
            s.draw(in: NSRect(x: rect.minX, y: y, width: rect.width, height: 10))
        }
        line("↑", up, upColor, y: rect.minY + 8)
        line("↓", down, downColor, y: rect.minY - 1)
    }

    private static func drawBar(segments: [(Double, NSColor)], track: NSColor,
                                frameColor: NSColor, rect: NSRect) {
        let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5)
        frameColor.withAlphaComponent(0.45).setStroke()
        frame.lineWidth = 0.75
        frame.stroke()

        let inner = rect.insetBy(dx: 1.5, dy: 1.5)
        var y = inner.minY
        for (fraction, color) in segments {
            let h = inner.height * CGFloat(min(1, max(0, fraction)))
            guard h > 0 else { continue }
            color.setFill()
            NSBezierPath(rect: NSRect(x: inner.minX, y: y, width: inner.width,
                                      height: min(h, inner.maxY - y))).fill()
            y += h
            if y >= inner.maxY { break }
        }
    }

    /// Solid disc (track color) with wedges filling to the edge, clockwise
    /// from 12 o'clock — like iStat Menus' pie.
    private static func drawPie(segments: [(Double, NSColor)], track: NSColor, rect: NSRect) {
        let diameter = min(rect.width, rect.height)
        let circle = NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                            width: diameter, height: diameter)
        track.setFill()
        NSBezierPath(ovalIn: circle).fill()

        let center = NSPoint(x: circle.midX, y: circle.midY)
        let radius = diameter / 2
        var start: CGFloat = 90
        for (fraction, color) in segments {
            let sweep = 360 * CGFloat(min(1, max(0, fraction)))
            guard sweep > 0.1 else { continue }
            let wedge = NSBezierPath()
            if sweep >= 359.9 {
                wedge.appendOval(in: circle)
            } else {
                wedge.move(to: center)
                wedge.appendArc(withCenter: center, radius: radius,
                                startAngle: start, endAngle: start - sweep, clockwise: true)
                wedge.close()
            }
            color.setFill()
            wedge.fill()
            start -= sweep
        }
    }

    /// Mirrored throughput chart: reads grow up from the midline, writes
    /// grow down, auto-scaled to the visible peak (like Stats' network chart).
    private static func drawIOChart(read: [Double], write: [Double],
                                    readColor: NSColor, writeColor: NSColor,
                                    frameColor: NSColor, rect: NSRect) {
        let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        frameColor.withAlphaComponent(0.45).setStroke()
        frame.lineWidth = 0.75
        frame.stroke()

        let plot = rect.insetBy(dx: 1.5, dy: 1.5)
        let mid = plot.midY
        let midLine = NSBezierPath()
        midLine.move(to: NSPoint(x: plot.minX, y: mid))
        midLine.line(to: NSPoint(x: plot.maxX, y: mid))
        frameColor.withAlphaComponent(0.25).setStroke()
        midLine.lineWidth = 0.5
        midLine.stroke()

        let r = Array(read.suffix(chartPoints))
        let w = Array(write.suffix(chartPoints))
        let peak = max(ioFloor, r.max() ?? 0, w.max() ?? 0)
        let half = plot.height / 2
        let step = plot.width / CGFloat(chartPoints - 1)

        func series(_ values: [Double], up: Bool, color: NSColor) {
            guard values.count > 1 else { return }
            let startX = plot.maxX - step * CGFloat(values.count - 1)
            let line = NSBezierPath()
            for (i, v) in values.enumerated() {
                let h = half * CGFloat(min(1, v / peak))
                let p = NSPoint(x: startX + step * CGFloat(i), y: up ? mid + h : mid - h)
                i == 0 ? line.move(to: p) : line.line(to: p)
            }
            let area = line.copy() as! NSBezierPath
            area.line(to: NSPoint(x: plot.maxX, y: mid))
            area.line(to: NSPoint(x: startX, y: mid))
            area.close()
            color.withAlphaComponent(0.35).setFill()
            area.fill()
            color.setStroke()
            line.lineWidth = 1
            line.lineJoinStyle = .round
            line.stroke()
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot).addClip()
        series(r, up: true, color: readColor)
        series(w, up: false, color: writeColor)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawPercentBlock(label: String?, value: Double?, color: NSColor, rect: NSRect) {
        let text = StatsFormat.percent(value)
        let para = NSMutableParagraphStyle()
        para.alignment = .center

        if let label {
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7, weight: .bold),
                .foregroundColor: color,
                .paragraphStyle: para,
            ]
            NSAttributedString(string: label, attributes: labelAttrs)
                .draw(in: NSRect(x: rect.minX, y: rect.minY + 9, width: rect.width, height: 9))
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: color,
                .paragraphStyle: para,
            ]
            NSAttributedString(string: text, attributes: valueAttrs)
                .draw(in: NSRect(x: rect.minX, y: rect.minY - 1.5, width: rect.width, height: 12))
        } else {
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: color,
                .paragraphStyle: para,
            ]
            let s = NSAttributedString(string: text, attributes: valueAttrs)
            let h = s.size().height
            s.draw(in: NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h))
        }
    }
}
