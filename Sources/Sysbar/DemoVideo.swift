// `Sysbar --demo-frames <dir>` renders a short promo animation as PNG
// frames (DemoVideo.fps per second) from live samples of this Mac; encode
// them with ffmpeg (scripts/demo-video.sh, scripts/readme-media.sh). The
// real SwiftUI panels are drawn in an off-screen window, so what you see is
// what the app shows. Wallpapers are drawn here (no image files).

import AppKit
import SwiftUI

@MainActor
final class DemoState: ObservableObject {
    enum Scene: Int { case intro, styles, panel, opacity, disk, memory, outro }
    @Published var scene: Scene = .intro
    @Published var fade: Double = 1
    /// 0...1 through the current scene.
    @Published var progress: Double = 0
    @Published var icon = NSImage()
    @Published var diskIcon = NSImage()
    @Published var styleIcons: [(String, NSImage)] = []
    /// Wallpaper crossfade: current one, the next one and the blend to it.
    @Published var wallpaper = 0
    @Published var nextWallpaper = 1
    @Published var wallpaperBlend: Double = 0
    @Published var caption = ""
}

@MainActor
enum DemoVideo {
    static let size = NSSize(width: 1440, height: 810)
    static let fps = 12.0
    /// Live samples per second (charts scroll at this pace).
    static let samplesPerSecond = 4.0
    /// Scene lengths in seconds.
    static let timeline: [(DemoState.Scene, Double)] = [
        (.intro, 4), (.styles, 4), (.panel, 6), (.opacity, 11), (.disk, 9), (.memory, 6), (.outro, 4),
    ]

    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Settings the scenes change; restored at the end.
        let store = SettingsStore.shared
        let saved = (Settings.language, store.opacity, store.separateOpacity, store.pinFull, store.pinSide,
                     store.diskDetailedInIcon)
        let defaults = UserDefaults.standard
        let savedDisk = (defaults.object(forKey: "diskChartStyle"), defaults.object(forKey: "diskPieDetailed"))
        Settings.language = .english
        store.opacity = OpacitySet()
        store.separateOpacity = []
        store.pinFull = true
        defaults.set("pie", forKey: "diskChartStyle")
        defaults.set(false, forKey: "diskPieDetailed")
        defer {
            Settings.language = saved.0
            store.opacity = saved.1
            store.separateOpacity = saved.2
            store.pinFull = saved.3
            store.pinSide = saved.4
            store.diskDetailedInIcon = saved.5
            defaults.set(savedDisk.0, forKey: "diskChartStyle")
            defaults.set(savedDisk.1, forKey: "diskPieDetailed")
        }

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
            return p.anonymized()
        }

        // Disk breakdown for the disk scene (measured once, shown later).
        let breakdown = DiskBreakdown.measure()

        // Pre-roll so the history charts start full.
        for i in 0..<60 {
            pump(0.25)
            model.snapshot = sampler.sample().anonymized()
            if i % 8 == 0 { model.processes = sampleProcesses() }
        }

        var frame = 0
        let framesPerSample = max(1, Int((fps / samplesPerSecond).rounded()))
        for (scene, seconds) in timeline {
            let count = Int(seconds * fps)
            state.scene = scene
            model.pinnedDetails = scene == .panel ? [.cpu, .gpu] : []
            for i in 0..<count {
                autoreleasepool {
                    let t = Double(i) / Double(count)
                    let time = Double(i) / fps
                    if i % framesPerSample == 0 {
                        model.snapshot = sampler.sample().anonymized()
                        if i % (framesPerSample * 4) == 0 { model.processes = sampleProcesses() }
                    }
                    state.progress = t
                    state.fade = min(1, time / 0.3)
                    animate(scene, time: time, seconds: seconds, state: state, model: model,
                            breakdown: breakdown)
                    updateIcons(state, snapshot: model.snapshot, model: model, appearance: appearance)
                    pump(0.01)
                    host.layoutSubtreeIfNeeded()
                    save(host, to: dir.appendingPathComponent(String(format: "f%05d.png", frame)))
                }
                frame += 1
                pump(max(0.005, 1 / fps - 0.06))
            }
        }
        load.stop()
        window.orderOut(nil)
        print("Wrote \(frame) frames to \(dir.path)")
    }

    /// Per-frame changes of the opacity and disk scenes.
    private static func animate(_ scene: DemoState.Scene, time: Double, seconds: Double,
                                state: DemoState, model: AppModel, breakdown: DiskBreakdown?) {
        func ramp(_ from: Double, _ to: Double) -> Double { min(1, max(0, (time - from) / (to - from))) }
        switch scene {
        case .opacity:
            // Bright wallpapers, then a dark one where the background fades
            // to 0 % while text and graphics stay at 100 %.
            if time < 2.5 {
                state.wallpaper = 1; state.nextWallpaper = 0; state.wallpaperBlend = ramp(1.5, 2.5)
            } else {
                state.wallpaper = 0; state.nextWallpaper = 3; state.wallpaperBlend = ramp(2.5, 3.5)
            }
            var o = OpacitySet()
            o.background = 1 - ramp(4, 6.5)
            Settings.opacity = o
            state.caption = time < 3.5 ? "Pin it full height…"
                : time < 6.5 ? "…fade the background to 0 %…"
                : time < 8.5 ? "…text and charts stay at 100 %."
                : "Background, text and graphics opacity."
        case .disk:
            let detailed = time >= 2.5
            if UserDefaults.standard.bool(forKey: "diskPieDetailed") != detailed {
                UserDefaults.standard.set(detailed, forKey: "diskPieDetailed")
            }
            model.diskBreakdown = time >= 5 ? breakdown : nil
            if Settings.diskDetailedInIcon != (time >= 6) { Settings.diskDetailedInIcon = time >= 6 }
            model.measuringDisk = detailed && time < 5
            state.caption = time < 2.5 ? "Disk usage as a pie…"
                : time < 5 ? "…measure the details…"
                : "…and see them in the menu bar too."
        default:
            if Settings.opacity != OpacitySet() { Settings.opacity = OpacitySet() }
            state.wallpaper = 0
            state.nextWallpaper = 1
            state.wallpaperBlend = 0
        }
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

    private static func updateIcons(_ state: DemoState, snapshot: SystemStatsSnapshot, model: AppModel,
                                    appearance: NSAppearance) {
        let diskSegments = state.scene == .disk ? model.diskBreakdown?.iconSegments : nil
        var main = config([(.cpu, .line, .metric), (.gpu, .bar, .metric), (.memory, .pie, .metric),
                           (.disk, .pie, .metric), (.network, .speed, .monochrome)])
        main.diskSegments = diskSegments
        state.icon = rasterize(StatusIconRenderer.image(snapshot: snapshot, config: main, appearance: appearance),
                               appearance: appearance)
        var disk = config([(.disk, .pie, .metric)])
        disk.diskSegments = diskSegments
        state.diskIcon = rasterize(StatusIconRenderer.image(snapshot: snapshot, config: disk, appearance: appearance),
                                   appearance: appearance)
        guard state.scene == .styles || state.styleIcons.isEmpty else { return }
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

/// Abstract wallpapers drawn with gradients.
private struct Wallpaper: View {
    let index: Int

    var body: some View {
        switch index % 4 {
        case 0:
            ZStack {
                LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.35), Color(red: 0.45, green: 0.15, blue: 0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(Color(red: 0.95, green: 0.45, blue: 0.75).opacity(0.55))
                    .frame(width: 700).blur(radius: 120).offset(x: 380, y: -200)
                Circle().fill(Color(red: 0.25, green: 0.65, blue: 1).opacity(0.5))
                    .frame(width: 600).blur(radius: 120).offset(x: -420, y: 260)
            }
        case 1:
            ZStack {
                LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.30), Color(red: 0.80, green: 0.22, blue: 0.35),
                                        Color(red: 0.25, green: 0.10, blue: 0.30)],
                               startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(red: 1, green: 0.85, blue: 0.45).opacity(0.7))
                    .frame(width: 380).blur(radius: 40).offset(x: -250, y: 120)
            }
        case 3:
            // Dark: lets text and charts without a background stand out.
            ZStack {
                Color(red: 0.03, green: 0.03, blue: 0.06)
                Circle().fill(Color(red: 0.20, green: 0.15, blue: 0.45).opacity(0.35))
                    .frame(width: 900).blur(radius: 180).offset(x: -350, y: 200)
            }
        default:
            ZStack {
                LinearGradient(colors: [Color(red: 0.02, green: 0.25, blue: 0.28), Color(red: 0.05, green: 0.55, blue: 0.45)],
                               startPoint: .bottomLeading, endPoint: .topTrailing)
                Circle().fill(Color(red: 0.55, green: 1, blue: 0.75).opacity(0.35))
                    .frame(width: 800).blur(radius: 140).offset(x: -300, y: -250)
                Circle().fill(Color(red: 0.1, green: 0.4, blue: 0.9).opacity(0.45))
                    .frame(width: 600).blur(radius: 120).offset(x: 450, y: 250)
            }
        }
    }
}

private struct DemoSceneView: View {
    let model: AppModel
    @ObservedObject var state: DemoState

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.12),
                                    Color(red: 0.12, green: 0.10, blue: 0.20)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if state.scene == .opacity {
                Wallpaper(index: state.wallpaper)
                Wallpaper(index: state.nextWallpaper).opacity(state.wallpaperBlend)
            }
            Group {
                switch state.scene {
                case .intro: intro
                case .styles: styles
                case .panel: panelScene(details: [.cpu, .gpu], caption: "Hover a section for details.\nClick to keep them open.")
                case .opacity: opacityScene
                case .disk: diskScene
                case .memory: panelScene(details: [.memory, .processes],
                                         caption: "Memory by type,\nand each process'\nshare of RAM.")
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

    /// A panel as the app draws it; `background` < 1 fades only its backdrop.
    private func card<V: View>(_ content: V, background: Double = 1, corner: CGFloat = 12) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: corner)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(background)))
            .overlay(RoundedRectangle(cornerRadius: corner).stroke(Color.white.opacity(0.12 * background)))
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .shadow(color: .black.opacity(0.45 * background), radius: 18, y: 8)
    }

    private func captionText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(.white)
            .lineSpacing(6)
            .shadow(color: .black.opacity(0.5), radius: 6)
            .frame(width: 290, alignment: .leading)
    }

    private func panelScene(details: [SystemStatKind], caption: String) -> some View {
        VStack(spacing: 0) {
            menuBar
            HStack(alignment: .top, spacing: 12) {
                captionText(caption).padding(.top, 40)
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

    /// Full-height edge panel and two details over changing wallpapers,
    /// with the background (then the text) fading out.
    private var opacityScene: some View {
        let edge = PanelContext()
        edge.showsMute = true
        let bg = Settings.opacity.background
        return VStack(spacing: 0) {
            menuBar
            HStack(alignment: .top, spacing: 14) {
                captionText(state.caption).padding(.top, 60).padding(.leading, 30)
                Spacer(minLength: 0)
                VStack(spacing: 14) {
                    card(DetailContainer(model: model, kind: .network), background: bg)
                    card(DetailContainer(model: model, kind: .disk), background: bg)
                }
                .padding(.top, 20)
                card(MainPanelView(model: model, context: edge), background: bg, corner: 0)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var diskScene: some View {
        VStack(spacing: 0) {
            menuBar
            HStack(alignment: .center, spacing: 40) {
                VStack(alignment: .leading, spacing: 30) {
                    captionText(state.caption)
                    HStack(spacing: 14) {
                        Image(nsImage: state.diskIcon)
                            .resizable().interpolation(.high)
                            .frame(width: state.diskIcon.size.width * 3.2, height: state.diskIcon.size.height * 3.2)
                            .padding(16)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.5)))
                        Text("menu bar icon").font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                card(DetailContainer(model: model, kind: .disk))
                    .scaleEffect(1.4)
                    .frame(width: 560)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var outro: some View {
        VStack(spacing: 22) {
            Text("Sysbar").font(.system(size: 64, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text("Free & open source · ~1.5 MB · ~35 MB RAM · macOS 14+")
                .font(.system(size: 24, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            Text("Pin float or full height · Opacity · Disk breakdown · English / Português")
                .font(.system(size: 20)).foregroundStyle(.white.opacity(0.6))
            Text("github.com/rodrigotrombeta/Sysbar")
                .font(.system(size: 30, weight: .semibold, design: .monospaced)).foregroundStyle(accent)
                .padding(.top, 16)
        }
    }
}
