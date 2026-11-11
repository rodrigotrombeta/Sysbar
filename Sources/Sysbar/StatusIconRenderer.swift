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
    private static let gap: CGFloat = 2
    private static let widgetSpacing: CGFloat = 6
    /// Points shown in the menubar chart (the right-most part of the history).
    private static let chartPoints = 30

    struct Config {
        var metrics: [IconMetric]
        var style: IconStyle
        var colorMode: IconColorMode
        var showLabel: Bool
    }

    static func image(
        snapshot: SystemStatsSnapshot,
        config: Config,
        appearance: NSAppearance?
    ) -> NSImage {
        let widths = config.metrics.map { _ in width(for: config) }
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
        image.isTemplate = config.colorMode == .monochrome
        return image
    }

    // MARK: - Layout

    private static func width(for config: Config) -> CGFloat {
        let label = config.showLabel ? labelWidth + gap : 0
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
        let accent = color(for: metric, value: value, mode: config.colorMode)
        let textColor = config.colorMode == .monochrome ? NSColor.black : NSColor.labelColor
        var x = originX

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
            drawBar(value: value ?? 0, color: accent, frameColor: textColor,
                    rect: NSRect(x: x, y: 0, width: barWidth, height: height))
        case .percent:
            break
        }
    }

    private static func color(for metric: IconMetric, value: Double?, mode: IconColorMode) -> NSColor {
        switch mode {
        case .monochrome: return .black
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

    private static func drawBar(value: Double, color: NSColor, frameColor: NSColor, rect: NSRect) {
        let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5)
        frameColor.withAlphaComponent(0.45).setStroke()
        frame.lineWidth = 0.75
        frame.stroke()

        let inner = rect.insetBy(dx: 1.5, dy: 1.5)
        let fillHeight = inner.height * CGFloat(min(1, max(0, value)))
        guard fillHeight > 0 else { return }
        color.setFill()
        NSBezierPath(rect: NSRect(x: inner.minX, y: inner.minY,
                                  width: inner.width, height: fillHeight)).fill()
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
