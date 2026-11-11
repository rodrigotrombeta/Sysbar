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
        let processes = ProcessSampler()
        let model = AppModel()
        _ = processes.sample()
        for _ in 0..<16 {
            Thread.sleep(forTimeInterval: 0.25)
            model.snapshot = sampler.sample()
        }
        model.processes = processes.sample()
        model.expandedCores = true
        model.expandedGPUs = true
        let snapshot = model.snapshot

        func config(_ metrics: [IconMetric], _ style: (IconMetric) -> IconStyle,
                    _ color: (IconMetric) -> IconColorMode) -> StatusIconRenderer.Config {
            StatusIconRenderer.Config(
                metrics: metrics,
                styles: Dictionary(uniqueKeysWithValues: metrics.map { ($0, style($0)) }),
                colorModes: Dictionary(uniqueKeysWithValues: metrics.map { ($0, color($0)) }),
                showLabel: true)
        }

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: appearanceName)!
            let suffix = appearanceName == .aqua ? "light" : "dark"
            // Every style of every metric, colored.
            for metric in IconMetric.allCases {
                for style in metric.styles {
                    let icon = StatusIconRenderer.image(
                        snapshot: snapshot, config: config([metric], { _ in style }, { _ in .metric }),
                        appearance: appearance)
                    save(onBar: icon, appearance: appearance,
                         to: dir.appendingPathComponent("icon-\(metric.rawValue)-\(style.rawValue)-\(suffix).png"))
                }
            }
            // Mixed per-metric colors (CPU colored, GPU mono, Memory colored, Disk mono).
            let mixed = config([.cpu, .gpu, .memory, .disk, .network],
                               { $0 == .memory || $0 == .disk ? .pie : $0.styles[0] },
                               { $0 == .gpu || $0 == .disk ? .monochrome : .metric })
            save(onBar: StatusIconRenderer.image(snapshot: snapshot, config: mixed, appearance: appearance),
                 appearance: appearance, to: dir.appendingPathComponent("mixed-\(suffix).png"))

            let scheme: ColorScheme = appearanceName == .aqua ? .light : .dark
            let savedLanguage = Settings.language
            for language in Language.allCases {
                Settings.language = language
                let sections = VStack(spacing: 0) {
                    CPUStatsPanel(snapshot: snapshot, refreshInterval: 0.25)
                    GPUStatsPanel(snapshot: snapshot, refreshInterval: 0.25)
                    MemoryStatsPanel(snapshot: snapshot)
                    DiskStatsPanel(snapshot: snapshot, refreshInterval: 0.25)
                    NetworkStatsPanel(snapshot: snapshot, refreshInterval: 0.25)
                    TopProcessesPanel(rows: Array(model.processes.topMemory.prefix(5)),
                                      total: snapshot.memory.totalBytes)
                }
                render(sections, scheme: scheme, appearance: appearance,
                       to: dir.appendingPathComponent("panel-\(language.rawValue)-\(suffix).png"))
                for kind in SystemStatKind.allCases {
                    render(DetailContainer(model: model, kind: kind), scheme: scheme, appearance: appearance,
                           to: dir.appendingPathComponent("detail-\(kind.rawValue)-\(language.rawValue)-\(suffix).png"))
                }
            }
            Settings.language = savedLanguage
        }
    }

    private static func render<V: View>(_ view: V, scheme: ColorScheme, appearance: NSAppearance, to url: URL) {
        let renderer = ImageRenderer(content: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        appearance.performAsCurrentDrawingAppearance {
            if let cg = renderer.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
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
