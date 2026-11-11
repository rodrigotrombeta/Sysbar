// Generates Resources/AppIcon.icns: a rounded dark tile with a framed,
// filled line chart and three usage bars (echoing the menubar widgets).
// Usage: swift scripts/make-icon.swift   (run from the repo root)

import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Tile (Big Sur-style grid: 824pt body inside 1024 canvas).
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.24, alpha: 1),
               ending: NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1))!
        .draw(in: tilePath, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Chart frame.
    let chart = NSRect(x: 190 * s, y: 400 * s, width: 644 * s, height: 400 * s)
    let frame = NSBezierPath(roundedRect: chart, xRadius: 40 * s, yRadius: 40 * s)
    NSColor.white.withAlphaComponent(0.06).setFill()
    frame.fill()
    NSColor.white.withAlphaComponent(0.55).setStroke()
    frame.lineWidth = 14 * s
    frame.stroke()

    // Line series.
    let values: [CGFloat] = [0.22, 0.30, 0.26, 0.42, 0.35, 0.55, 0.48, 0.80, 0.62, 0.70, 0.52, 0.66]
    let plot = chart.insetBy(dx: 30 * s, dy: 34 * s)
    let step = plot.width / CGFloat(values.count - 1)
    let line = NSBezierPath()
    for (i, v) in values.enumerated() {
        let p = NSPoint(x: plot.minX + step * CGFloat(i), y: plot.minY + plot.height * v)
        i == 0 ? line.move(to: p) : line.line(to: p)
    }
    let area = line.copy() as! NSBezierPath
    area.line(to: NSPoint(x: plot.maxX, y: plot.minY))
    area.line(to: NSPoint(x: plot.minX, y: plot.minY))
    area.close()
    let green = NSColor(calibratedRed: 0.20, green: 0.84, blue: 0.45, alpha: 1)
    NSGradient(starting: green.withAlphaComponent(0.65), ending: green.withAlphaComponent(0.08))!
        .draw(in: area, angle: -90)
    green.setStroke()
    line.lineWidth = 18 * s
    line.lineJoinStyle = .round
    line.lineCapStyle = .round
    line.stroke()

    // Usage bars: CPU (blue), GPU (green), RAM (purple).
    let bars: [(CGFloat, NSColor)] = [
        (0.45, NSColor(calibratedRed: 0.24, green: 0.56, blue: 1.0, alpha: 1)),
        (0.80, green),
        (0.62, NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.95, alpha: 1)),
    ]
    let barX = 190 * s
    let barWidth = 644 * s
    for (i, bar) in bars.enumerated() {
        let y = (320 - CGFloat(i) * 72) * s
        let track = NSRect(x: barX, y: y, width: barWidth, height: 36 * s)
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: track, xRadius: 18 * s, yRadius: 18 * s).fill()
        bar.1.setFill()
        NSBezierPath(roundedRect: NSRect(x: barX, y: y, width: barWidth * bar.0, height: 36 * s),
                     xRadius: 18 * s, yRadius: 18 * s).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! drawIcon(size: px).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
try! drawIcon(size: 512).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon.png"))
print(task.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
