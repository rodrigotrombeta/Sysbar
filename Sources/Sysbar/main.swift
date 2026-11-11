import AppKit
import SwiftUI

MainActor.assumeIsolated {
    // `Sysbar --preview <dir>` writes PNGs of every icon style and the stats
    // panel, then exits (handy for checking the drawing without the menubar).
    let args = CommandLine.arguments
    if let flag = args.firstIndex(of: "--preview"), flag + 1 < args.count {
        Preview.write(to: URL(fileURLWithPath: args[flag + 1]))
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

@MainActor
enum Preview {
    static func write(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sampler = SystemStatsSampler()
        var snapshot = sampler.sample()
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.25)
            snapshot = sampler.sample()
        }

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: appearanceName)!
            let suffix = appearanceName == .aqua ? "light" : "dark"
            for style in IconStyle.allCases {
                for mode in IconColorMode.allCases {
                    let config = StatusIconRenderer.Config(
                        metrics: [.cpu, .gpu, .memory], style: style,
                        colorMode: mode, showLabel: true)
                    let icon = StatusIconRenderer.image(snapshot: snapshot, config: config,
                                                        appearance: appearance)
                    save(onBar: icon, appearance: appearance,
                         to: dir.appendingPathComponent("icon-\(style.rawValue)-\(mode.rawValue)-\(suffix).png"))
                }
            }
            let renderer = ImageRenderer(content:
                SystemStatsPanelStack(kinds: SystemStatKind.allCases, snapshot: snapshot,
                                      refreshInterval: 0.25)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, appearanceName == .aqua ? .light : .dark))
            renderer.scale = 2
            appearance.performAsCurrentDrawingAppearance {
                if let cg = renderer.cgImage {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("panel-\(suffix).png"))
                }
            }
        }
    }

    /// Draws the icon on a menubar-coloured strip, tinting template images
    /// the way the system would.
    private static func save(onBar icon: NSImage, appearance: NSAppearance, to url: URL) {
        let size = NSSize(width: icon.size.width + 16, height: 24)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 4),
                                   pixelsHigh: Int(size.height * 4), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            let dark = appearance.name == .darkAqua
            (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            let rect = NSRect(x: 8, y: 3, width: icon.size.width, height: icon.size.height)
            if icon.isTemplate {
                let tinted = NSImage(size: icon.size, flipped: false) { r in
                    icon.draw(in: r)
                    (dark ? NSColor.white : NSColor.black).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect)
            } else {
                icon.draw(in: rect)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
