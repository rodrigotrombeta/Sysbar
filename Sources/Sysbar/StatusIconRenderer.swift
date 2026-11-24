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
    private static var widgetSpacing: CGFloat { CGFloat(Settings.iconSpacing) }
    /// Points shown in the menubar chart (the right-most part of the history).
    private static let chartPoints = 30

    struct Config {
        var metrics: [IconMetric]
        var styles: [IconMetric: IconStyle]
        var colorModes: [IconMetric: IconColorMode]
        var showLabel: Bool
        /// Detailed disk categories for the disk pie/bar; nil = used only.
        var diskSegments: [(Double, NSColor)]? = nil

        func style(_ metric: IconMetric) -> IconStyle { styles[metric] ?? metric.styles[0] }
        func colorMode(_ metric: IconMetric) -> IconColorMode { colorModes[metric] ?? .metric }

        /// All-monochrome icons are template images (the system tints them);
        /// mixed icons draw their monochrome widgets in labelColor instead.
        var isTemplate: Bool { metrics.allSatisfy { colorMode($0) == .monochrome } }

        static var current: Config {
            Config(
                metrics: Settings.metrics,
                styles: Dictionary(uniqueKeysWithValues: IconMetric.allCases.map { ($0, Settings.style(for: $0)) }),
                colorModes: Dictionary(uniqueKeysWithValues: IconMetric.allCases.map { ($0, Settings.colorMode(for: $0)) }),
                showLabel: Settings.showLabel
            )
        }
    }

    static func image(
        snapshot: SystemStatsSnapshot,
        config: Config,
        appearance: NSAppearance?
    ) -> NSImage {
        let widths = config.metrics.map { width(for: $0, config: config) }
        let total = widths.reduce(0, +) + widgetSpacing * CGFloat(max(0, widths.count - 1))
        // A large clock font makes the image taller; the other widgets stay
        // centered in it.
        let imageHeight = config.metrics.contains(.clock) ? max(height, clockHeight) : height
        let size = NSSize(width: ceil(total), height: imageHeight)

        let image = NSImage(size: size, flipped: false) { _ in
            let draw = {
                var x: CGFloat = 0
                for (index, metric) in config.metrics.enumerated() {
                    if metric == .clock {
                        drawClocks(textColor: config.isTemplate ? .black : .labelColor,
                                   rect: NSRect(x: x, y: 0, width: widths[index], height: imageHeight))
                    } else {
                        NSGraphicsContext.saveGraphicsState()
                        let shift = NSAffineTransform()
                        shift.translateX(by: 0, yBy: (imageHeight - height) / 2)
                        shift.concat()
                        drawWidget(metric: metric, snapshot: snapshot, config: config, originX: x)
                        NSGraphicsContext.restoreGraphicsState()
                    }
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
        switch config.style(metric) {
        case .line, .io: return label + chartWidth
        case .bar: return label + barWidth
        case .pie: return label + pieWidth
        case .percent: return percentWidth
        case .linePercent: return label + chartWidth + gap + percentWidth - 2
        case .speed: return label + speedWidth
        case .amount: return label + speedWidth
        case .limits: return label + 40
        case .clock: return clockWidth
        case .battery: return batteryTextWidth + gap + batteryWidth
        case .batteryIcon: return batteryWidth
        case .batteryVertical: return batteryTextWidth + gap + verticalBatteryWidth
        case .batteryIconVertical: return verticalBatteryWidth
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
        let style = config.style(metric)
        let mode = config.colorMode(metric)
        let ink: NSColor = config.isTemplate ? .black : .labelColor
        let accent = color(for: metric, value: value, mode: mode, ink: ink)
        let mono = mode == .monochrome
        var x = originX

        if style == .percent {
            drawPercentBlock(label: config.showLabel ? metric.shortLabel : nil,
                             value: value, color: ink,
                             rect: NSRect(x: x, y: 0, width: percentWidth, height: height))
            return
        }

        if [.battery, .batteryIcon, .batteryVertical, .batteryIconVertical].contains(style) {
            drawBattery(snapshot.battery, withText: style == .battery || style == .batteryVertical,
                        vertical: style == .batteryVertical || style == .batteryIconVertical, ink: ink, mono: mono,
                        rect: NSRect(x: x, y: 0, width: width(for: metric, config: config), height: height))
            return
        }

        if config.showLabel && !metric.shortLabel.isEmpty {
            drawStackedLabel(metric.shortLabel, color: ink,
                             rect: NSRect(x: x, y: 0, width: labelWidth, height: height))
            x += labelWidth + gap
        }

        switch style {
        case .line, .linePercent:
            drawLineChart(values: metric.history(in: snapshot), color: accent,
                          frameColor: ink, rect: NSRect(x: x, y: 0, width: chartWidth, height: height))
            if style == .linePercent {
                drawPercentBlock(label: nil, value: value, color: ink,
                                 rect: NSRect(x: x + chartWidth + gap - 2, y: 0,
                                              width: percentWidth, height: height))
            }
        case .bar:
            drawBar(segments: segments(for: metric, snapshot: snapshot, value: value,
                                       accent: accent, mode: mode, disk: config.diskSegments),
                    track: metric == .memory || metric == .disk ? trackColor(mode, ink: ink) : .clear,
                    frameColor: ink,
                    rect: NSRect(x: x, y: 0, width: barWidth, height: height))
        case .pie:
            drawPie(segments: segments(for: metric, snapshot: snapshot, value: value,
                                       accent: accent, mode: mode, disk: config.diskSegments),
                    track: trackColor(mode, ink: ink),
                    rect: NSRect(x: x, y: 0, width: pieWidth, height: height))
        case .io:
            let io = metric.ioHistory(in: snapshot)
            drawIOChart(read: io.read, write: io.write,
                        readColor: mono ? ink : .systemBlue,
                        writeColor: mono ? ink : .systemRed,
                        frameColor: ink,
                        rect: NSRect(x: x, y: 0, width: chartWidth, height: height))
        case .speed:
            drawSpeed(down: snapshot.networkIO?.read, up: snapshot.networkIO?.write,
                      textColor: ink,
                      downColor: mono ? ink : .systemBlue,
                      upColor: mono ? ink : .systemRed,
                      rect: NSRect(x: x, y: 0, width: speedWidth, height: height))
        case .amount:
            let amounts = metric.amounts(in: snapshot)
            drawAmounts(used: amounts?.used, free: amounts?.free, binary: metric == .memory, textColor: ink,
                        usedColor: mono ? ink : accent, freeColor: mono ? ink : ink.withAlphaComponent(0.55),
                        rect: NSRect(x: x, y: 0, width: speedWidth, height: height))
        case .clock:
            break  // drawn by image(), at its own height
        case .limits:
            drawLimits(snapshot.claude, textColor: ink, mono: mono,
                       rect: NSRect(x: x, y: 0, width: 40, height: height))
        case .percent, .battery, .batteryIcon, .batteryVertical, .batteryIconVertical:
            break
        }
    }

    // MARK: Battery

    private static let batteryWidth: CGFloat = 24
    private static let batteryTextWidth: CGFloat = 26
    private static let verticalBatteryWidth: CGFloat = 11

    /// "80%" then a battery outline filled to the level, with a bolt when
    /// charging or a plug when on power but not charging.
    private static func drawBattery(_ b: BatteryInfo?, withText: Bool, vertical: Bool = false,
                                    ink: NSColor, mono: Bool, rect: NSRect) {
        var x = rect.minX
        let level = b?.level ?? 0
        if withText {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            let para = NSMutableParagraphStyle()
            para.alignment = .right
            let s = NSAttributedString(string: b.map { "\(Int(($0.level * 100).rounded()))%" } ?? "–",
                                       attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: para])
            let h = s.size().height
            s.draw(in: NSRect(x: x, y: rect.midY - h / 2, width: batteryTextWidth, height: h))
            x += batteryTextWidth + gap
        }
        let clamped = CGFloat(min(1, max(0, level)))
        let body: NSRect
        let tip: NSRect
        if vertical {
            // Upright: tip on top, fills from the bottom.
            body = NSRect(x: x + 1, y: rect.midY - 8, width: verticalBatteryWidth - 2, height: 14.5)
            tip = NSRect(x: body.midX - 2, y: body.maxY + 0.5, width: 4, height: 1.6)
        } else {
            body = NSRect(x: x + 0.5, y: rect.midY - 5.5, width: batteryWidth - 3, height: 11)
            tip = NSRect(x: body.maxX + 0.5, y: rect.midY - 2, width: 1.8, height: 4)
        }
        let radius: CGFloat = vertical ? 2.5 : 3
        let outline = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        ink.withAlphaComponent(0.5).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        ink.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: tip, xRadius: 0.8, yRadius: 0.8).fill()
        let inner = body.insetBy(dx: 1.5, dy: 1.5)
        let fill = vertical
            ? NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: max(1.5, inner.height * clamped))
            : NSRect(x: inner.minX, y: inner.minY, width: max(1.5, inner.width * clamped), height: inner.height)
        (mono ? ink : (b?.color ?? ink)).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
        guard let b, b.externalConnected,
              let symbol = NSImage(systemSymbolName: b.isCharging ? "bolt.fill" : "powerplug.fill",
                                   accessibilityDescription: nil)?
                  .withSymbolConfiguration(.init(pointSize: vertical ? 5 : 7.5, weight: .black))
        else { return }
        // White symbol on the fill; in a template (monochrome) icon it is
        // punched out of the fill instead.
        let size = symbol.size
        let r = NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2,
                       width: size.width, height: size.height)
        let tinted = NSImage(size: size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: r, from: .zero, operation: mono ? .destinationOut : .sourceOver, fraction: 1)
    }

    // MARK: Clock

    private static var clockFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: CGFloat(Settings.clockFontSize), weight: .regular)
    }
    /// Gap between the two clock lines (digits have no descenders, so the
    /// lines are spaced by cap height, not full line height).
    private static var clockGap: CGFloat { max(2, clockFont.capHeight * 0.3) }
    /// Height of the two clock lines (the menu bar fits about 22 pt).
    private static var clockHeight: CGFloat { min(22, ceil(clockFont.capHeight * 2 + clockGap + 3)) }
    private static var clockWidth: CGFloat {
        ceil(("00/00 00:00" as NSString).size(withAttributes: [.font: clockFont]).width) + 2
    }

    /// "24/11 13:19" over "24/11 09:19": the first two clocks.
    private static func drawClocks(textColor: NSColor, rect: NSRect) {
        let font = clockFont
        let zones = Array(WorldClock.zones.prefix(2))
        let now = Date()
        let cap = font.capHeight
        let block = zones.count == 1 ? cap : cap * 2 + clockGap
        let bottom = rect.minY + (rect.height - block) / 2
        for (i, zone) in zones.enumerated() {
            let baseline = zones.count == 1 ? bottom : (i == 0 ? bottom + cap + clockGap : bottom)
            let text = NSAttributedString(string: WorldClock.shortDateTime(now, in: zone),
                                          attributes: [.font: font, .foregroundColor: textColor])
            let width = text.size().width
            text.draw(at: NSPoint(x: rect.maxX - width - 1, y: baseline + font.descender))
        }
    }

    /// Two lines, "42% 5h" over "18% 7d"; in color, each tag turns orange or
    /// red when that window is projected to come close to / hit its limit.
    private static func drawLimits(_ usage: ClaudeUsage?, textColor: NSColor, mono: Bool, rect: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        func line(_ tag: String, _ w: ClaudeWindow?, y: CGFloat) {
            let riskColor: NSColor = switch w?.risk() ?? 0 {
            case 2: .systemRed
            case 1: .systemOrange
            default: textColor.withAlphaComponent(0.6)
            }
            // "6% 5h": right-aligned, so the 5h / 7d tags line up.
            let s = NSMutableAttributedString(
                string: (w.map { "\(Int($0.percent.rounded()))%" } ?? "–") + " ",
                attributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: para])
            s.append(NSAttributedString(
                string: tag,
                attributes: [.font: font, .foregroundColor: mono ? textColor : riskColor, .paragraphStyle: para]))
            s.draw(in: NSRect(x: rect.minX, y: y, width: rect.width, height: 10))
        }
        line("5h", usage?.fiveHour, y: rect.minY + 8)
        line("7d", usage?.sevenDay, y: rect.minY - 1)
    }

    /// Two right-aligned lines: "U 17.1 GB" (used) over "F 6.9 GB" (free).
    private static func drawAmounts(used: UInt64?, free: UInt64?, binary: Bool, textColor: NSColor,
                                    usedColor: NSColor, freeColor: NSColor, rect: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        func line(_ tag: String, _ bytes: UInt64?, _ tagColor: NSColor, y: CGFloat) {
            let s = NSMutableAttributedString(
                string: tag + " ",
                attributes: [.font: font, .foregroundColor: tagColor, .paragraphStyle: para])
            s.append(NSAttributedString(
                string: bytes.map { shortBytes($0, binary: binary) } ?? "–",
                attributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: para]))
            s.draw(in: NSRect(x: rect.minX, y: y, width: rect.width, height: 10))
        }
        line("U", used, usedColor, y: rect.minY + 8)
        line("F", free, freeColor, y: rect.minY - 1)
    }

    /// "17.1 GB", "429 GB", "1.2 TB". Memory in binary units (like the
    /// panel and Activity Monitor), disks in decimal ones (like Finder).
    private static func shortBytes(_ bytes: UInt64, binary: Bool) -> String {
        let gb = Double(bytes) / (binary ? 1_073_741_824 : 1e9)
        if gb >= 1000 { return String(format: "%.1f TB", gb / 1000) }
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        return String(format: "%.1f GB", gb)
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
        let area = NSBezierPath()
        // One piece per run of samples; gaps (NaN) stay empty.
        for run in points.finiteRuns {
            let piece = NSBezierPath()
            for i in run {
                let p = NSPoint(x: startX + step * CGFloat(i),
                                y: plot.minY + plot.height * CGFloat(min(1, max(0, points[i]))))
                i == run.lowerBound ? piece.move(to: p) : piece.line(to: p)
            }
            line.append(piece)
            piece.line(to: NSPoint(x: startX + step * CGFloat(run.upperBound - 1), y: plot.minY))
            piece.line(to: NSPoint(x: startX + step * CGFloat(run.lowerBound), y: plot.minY))
            piece.close()
            area.append(piece)
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot).addClip()
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
                                 mode: IconColorMode,
                                 disk: [(Double, NSColor)]? = nil) -> [(Double, NSColor)] {
        if metric == .disk, mode != .monochrome, let disk { return disk }
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
        let peak = max(ioFloor, r.finiteMax ?? 0, w.finiteMax ?? 0)
        let half = plot.height / 2
        let step = plot.width / CGFloat(chartPoints - 1)

        func series(_ values: [Double], up: Bool, color: NSColor) {
            guard values.count > 1 else { return }
            let startX = plot.maxX - step * CGFloat(values.count - 1)
            let line = NSBezierPath()
            let area = NSBezierPath()
            for run in values.finiteRuns {
                let piece = NSBezierPath()
                for i in run {
                    let h = half * CGFloat(min(1, values[i] / peak))
                    let p = NSPoint(x: startX + step * CGFloat(i), y: up ? mid + h : mid - h)
                    i == run.lowerBound ? piece.move(to: p) : piece.line(to: p)
                }
                line.append(piece)
                piece.line(to: NSPoint(x: startX + step * CGFloat(run.upperBound - 1), y: mid))
                piece.line(to: NSPoint(x: startX + step * CGFloat(run.lowerBound), y: mid))
                piece.close()
                area.append(piece)
            }
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
