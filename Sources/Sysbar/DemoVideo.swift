// `Sysbar --demo-frames <dir>` renders a short promo animation as PNG
// frames from live samples of this Mac (encode them with ffmpeg; see
// scripts/demo-video.sh). The real SwiftUI panels are drawn in an
// off-screen window, so what you see is what the app shows.

import AppKit
import SwiftUI

@MainActor
final class DemoState: ObservableObject {
    enum Scene: Int { case intro, styles, panel, memory, outro }
    @Published var scene: Scene = .intro
    @Published var fade: Double = 1
    @Published var icon = NSImage()
    @Published var styleIcons: [(String, NSImage)] = []
}

@MainActor
enum DemoVideo {
    static let size = NSSize(width: 1440, height: 810)
    static let fps = 4.0
    /// Scene lengths in seconds.
    static let timeline: [(DemoState.Scene, Double)] = [
        (.intro, 5), (.styles, 5), (.panel, 10), (.memory, 7), (.outro, 4),
    ]

    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let savedLanguage = Settings.language
        Settings.language = .english
        defer { Settings.language = savedLanguage }

        let load = CPULoad()
        load.start()
        let sampler = SystemStatsSampler()
        let processes = ProcessSampler()
        let model = AppModel()
        let state = DemoState()
        model.maxPanelHeight = 700
        model.expandedCores = true
        _ = processes.sample()

        let appearance = NSAppearance(named: .darkAqua)!
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        let host = NSHostingView(rootView: DemoSceneView(model: model, state: state)
            .environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()

        // The renderer itself (and its CPU load) shouldn't top the lists.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        func sampleProcesses() -> ProcessSnapshot {
            var p = processes.sample()
            p.topMemory.removeAll { $0.pid == ownPID }
            p.topCPU.removeAll { $0.pid == ownPID }
            return p
        }

        // Pre-roll so the history charts start full.
        for i in 0..<60 {
            pump(0.25)
            model.snapshot = sampler.sample()
            if i % 8 == 0 { model.processes = sampleProcesses() }
        }

        var frame = 0
        for (scene, seconds) in timeline {
            let count = Int(seconds * fps)
            state.scene = scene
            model.pinnedDetails = scene == .panel ? [.cpu, .gpu] : scene == .memory ? [.memory, .disk] : []
            for i in 0..<count {
                autoreleasepool {
                    model.snapshot = sampler.sample()
                    if i % 4 == 0 { model.processes = sampleProcesses() }
                    state.fade = min(1, Double(i + 1) / 3)
                    updateIcons(state, snapshot: model.snapshot, appearance: appearance)
                    pump(0.02)
                    host.layoutSubtreeIfNeeded()
                    save(host, to: dir.appendingPathComponent(String(format: "f%05d.png", frame)))
                }
                frame += 1
                pump(max(0.05, 1 / fps - 0.1))
            }
        }
        load.stop()
        window.orderOut(nil)
        print("Wrote \(frame) frames to \(dir.path)")
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func config(_ items: [(IconMetric, IconStyle, IconColorMode)]) -> StatusIconRenderer.Config {
        StatusIconRenderer.Config(
            metrics: items.map(\.0),
            styles: Dictionary(uniqueKeysWithValues: items.map { ($0.0, $0.1) }),
            colorModes: Dictionary(uniqueKeysWithValues: items.map { ($0.0, $0.2) }),
            showLabel: true)
    }

    private static func updateIcons(_ state: DemoState, snapshot: SystemStatsSnapshot, appearance: NSAppearance) {
        let main = config([(.cpu, .line, .metric), (.gpu, .bar, .metric), (.memory, .pie, .metric),
                           (.disk, .io, .monochrome), (.network, .speed, .monochrome)])
        state.icon = rasterize(StatusIconRenderer.image(snapshot: snapshot, config: main, appearance: appearance),
                               appearance: appearance)
        let variants: [(String, IconMetric, IconStyle, IconColorMode)] = [
            ("CPU · line", .cpu, .line, .metric),
            ("CPU · bar", .cpu, .bar, .utilization),
            ("CPU · line + %", .cpu, .linePercent, .monochrome),
            ("E / P cores", .eCores, .bar, .metric),
            ("GPU · line", .gpu, .line, .metric),
            ("GPU · %", .gpu, .percent, .utilization),
            ("Memory · pie", .memory, .pie, .metric),
            ("Memory · bar", .memory, .bar, .metric),
            ("Disk · I/O", .disk, .io, .metric),
            ("Disk · pie", .disk, .pie, .monochrome),
            ("Network · I/O", .network, .io, .metric),
            ("Network · speed", .network, .speed, .monochrome),
        ]
        state.styleIcons = variants.map { name, metric, style, color in
            let cfg: StatusIconRenderer.Config = metric == .eCores
                ? config([(.eCores, style, color), (.pCores, style, color)])
                : config([(metric, style, color)])
            return (name, rasterize(StatusIconRenderer.image(snapshot: snapshot, config: cfg, appearance: appearance),
                                    appearance: appearance))
        }
    }

    /// Bakes the icon into a bitmap (tinting template images white, as the
    /// dark menu bar does) so it can be shown enlarged.
    private static func rasterize(_ icon: NSImage, appearance: NSAppearance) -> NSImage {
        let scale: CGFloat = 4
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(icon.size.width * scale),
                                   pixelsHigh: Int(icon.size.height * scale), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = icon.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            let rect = NSRect(origin: .zero, size: icon.size)
            icon.draw(in: rect)
            if icon.isTemplate {
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: icon.size)
        image.addRepresentation(rep)
        return image
    }

    private static func save(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Busy threads with a slowly varying duty cycle, so the charts move.
final class CPULoad: @unchecked Sendable {
    private var running = false
    private let lock = NSLock()

    func start() {
        lock.withLock { running = true }
        let start = Date()
        let threads = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        for index in 0..<threads {
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    let t = Date().timeIntervalSince(start)
                    // Waves that sweep across the cores.
                    let duty = max(0.05, 0.5 + 0.45 * sin(t * 0.7 + Double(index) * 0.6))
                    let busyUntil = Date().addingTimeInterval(0.02 * duty)
                    var x = 0.0
                    while Date() < busyUntil { x += sin(x + 1) }
                    _ = x
                    Thread.sleep(forTimeInterval: 0.02 * (1 - duty))
                }
            }
        }
    }

    func stop() { lock.withLock { running = false } }
}

// MARK: - Scenes

private let accent = Color(red: 0.36, green: 0.85, blue: 0.55)

private struct DemoSceneView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: DemoState

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.12),
                                    Color(red: 0.12, green: 0.10, blue: 0.20)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Group {
                switch state.scene {
                case .intro: intro
                case .styles: styles
                case .panel: panelScene(details: [.cpu, .gpu], caption: "Hover a section for details.\nClick to keep them open.")
                case .memory: panelScene(details: [.memory, .disk], caption: "Memory pressure,\nswap, disk I/O\nand more.")
                case .outro: outro
                }
            }
            .opacity(state.fade)
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
    }

    private var menuBar: some View {
        HStack {
            Spacer()
            Image(nsImage: state.icon)
                .padding(.trailing, 24)
        }
        .frame(height: 28)
        .background(Color.black.opacity(0.55))
    }

    private var intro: some View {
        VStack(spacing: 26) {
            Text("Sysbar").font(.system(size: 64, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text("A tiny macOS menu bar system monitor")
                .font(.system(size: 26, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            Image(nsImage: state.icon)
                .resizable().interpolation(.high)
                .frame(width: state.icon.size.width * 3, height: state.icon.size.height * 3)
                .padding(.horizontal, 28).padding(.vertical, 18)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.55)))
                .padding(.top, 20)
            Text("CPU · GPU · Memory · Disk · Network — live in your menu bar")
                .font(.system(size: 20)).foregroundStyle(accent)
        }
    }

    private var styles: some View {
        VStack(spacing: 30) {
            Text("Pick the metrics, a style and a color for each")
                .font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(300), spacing: 24), count: 4), spacing: 22) {
                ForEach(Array(state.styleIcons.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 10) {
                        Image(nsImage: item.1)
                            .resizable().interpolation(.high)
                            .frame(width: item.1.size.width * 2.4, height: item.1.size.height * 2.4)
                            .frame(height: 64)
                        Text(item.0).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(width: 300, height: 120)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.45)))
                }
            }
        }
    }

    private func card<V: View>(_ content: V) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    private func panelScene(details: [SystemStatKind], caption: String) -> some View {
        VStack(spacing: 0) {
            menuBar
            HStack(alignment: .top, spacing: 12) {
                Text(caption)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineSpacing(6)
                    .frame(width: 270, alignment: .leading)
                    .padding(.top, 40)
                Spacer(minLength: 0)
                ForEach(details, id: \.self) { kind in
                    card(DetailContainer(model: model, kind: kind))
                }
                card(MainPanelView(model: model, context: PanelContext()))
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
    }

    private var outro: some View {
        VStack(spacing: 22) {
            Text("Sysbar").font(.system(size: 64, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text("Free & open source · ~1 MB · ~30 MB RAM · macOS 14+")
                .font(.system(size: 24, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            Text("Pin it to a screen edge · English / Português · Light / Dark")
                .font(.system(size: 20)).foregroundStyle(.white.opacity(0.6))
            Text("github.com/rodrigotrombeta/Sysbar")
                .font(.system(size: 30, weight: .semibold, design: .monospaced)).foregroundStyle(accent)
                .padding(.top, 16)
        }
    }
}
