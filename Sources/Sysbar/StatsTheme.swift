// Stand-ins for oMLX's theme/design tokens, plus the sparkline view used by
// the CPU and GPU panels (adapted from oMLX MenubarMetricPopover.swift,
// Apache License 2.0).

import AppKit
import SwiftUI

/// Memory breakdown colors (same scheme as iStat Menus / Activity Monitor
/// style): App green, Wired orange, Compressed magenta.
enum MemoryPalette {
    static let app = NSColor.systemGreen
    static let wired = NSColor.systemOrange
    static let compressed = NSColor(calibratedRed: 0.93, green: 0.22, blue: 0.93, alpha: 1)
    /// Unused part of pies/bars in colored modes.
    static let track = NSColor.systemGray.withAlphaComponent(0.55)
}

struct StatsTheme {
    static let callout: CGFloat = 12.5
    static let caption: CGFloat = 10.5

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    var text: Color { Color(nsColor: .labelColor) }
    var textSecondary: Color { Color(nsColor: .secondaryLabelColor) }
    var textTertiary: Color { Color(nsColor: .tertiaryLabelColor) }
    var accent: Color { Color(nsColor: .systemBlue) }
    var rowSep: Color { Color(nsColor: .separatorColor) }
}

/// Sparkline drawn with Shapes (not Canvas): Canvas re-rendered through
/// GPU-backed buffers every tick and cost tens of MB in a pinned panel.
struct MetricSparkline: View {
    let values: [Double]
    let color: Color
    var height: CGFloat = 22
    /// Fixed Y range for bounded series (e.g. 0...1 usage fractions).
    /// nil auto-scales to the data so small variations stay visible.
    var domain: ClosedRange<Double>? = nil

    var body: some View {
        ZStack {
            SparklineShape(values: values, domain: domain, closed: true)
                .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
            SparklineShape(values: values, domain: domain, closed: false)
                .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct SparklineShape: Shape {
    let values: [Double]
    let domain: ClosedRange<Double>?
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, rect.width > 0, rect.height > 0 else { return path }
        let low = domain?.lowerBound ?? (values.min() ?? 0)
        let high = domain?.upperBound ?? (values.max() ?? 0)
        let span = domain.map { $0.upperBound - $0.lowerBound } ?? (high - low) * 1.05
        let isFlat = span <= .ulpOfOne
        let stepX = rect.width / CGFloat(values.count - 1)
        // Inset by half the stroke so a series at 0% / 100% isn't clipped.
        let top: CGFloat = 0.6
        let plotHeight = rect.height - 1.2
        for (index, value) in values.enumerated() {
            let normalized = isFlat ? 0.5 : min(1, max(0, (value - low) / span))
            let point = CGPoint(x: CGFloat(index) * stepX,
                                y: top + plotHeight * (1 - CGFloat(normalized)))
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.closeSubpath()
        }
        return path
    }
}
