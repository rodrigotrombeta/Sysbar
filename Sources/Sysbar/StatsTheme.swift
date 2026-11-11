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

struct MetricSparkline: View {
    let values: [Double]
    let color: Color
    var height: CGFloat = 22
    /// Fixed Y range for bounded series (e.g. 0...1 usage fractions).
    /// nil auto-scales to the data so small variations stay visible.
    var domain: ClosedRange<Double>? = nil

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, size.width > 0, size.height > 0 else {
                return
            }
            let low = domain?.lowerBound ?? (values.min() ?? 0)
            let high = domain?.upperBound ?? (values.max() ?? 0)
            let span = domain.map { $0.upperBound - $0.lowerBound }
                ?? (high - low) * 1.05
            let isFlat = span <= .ulpOfOne
            let stepX = size.width / CGFloat(values.count - 1)

            let lineWidth: CGFloat = 1.2
            let plotTop = lineWidth / 2
            let plotHeight = size.height - lineWidth

            var trace = Path()
            for (index, value) in values.enumerated() {
                let normalized = isFlat ? 0.5 : (value - low) / span
                let point = CGPoint(
                    x: CGFloat(index) * stepX,
                    y: plotTop + plotHeight * (1 - CGFloat(normalized))
                )
                if index == 0 {
                    trace.move(to: point)
                } else {
                    trace.addLine(to: point)
                }
            }

            var fill = trace
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.22), color.opacity(0.02)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(trace, with: .color(color), lineWidth: lineWidth)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
