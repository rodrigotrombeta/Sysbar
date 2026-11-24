// `Sysbar --screenshots <dir>` renders the README screenshots (main panel,
// settings and the screen-edge panel, light and dark) from live samples of
// this Mac, then exits. See scripts/readme-media.sh.

import AppKit
import SwiftUI

@MainActor
enum Screenshots {
    static func write(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let savedLanguage = Settings.language
        let store = SettingsStore.shared
        let savedMuted = store.mutedSections
        let savedMetrics = store.shownMetrics
        Settings.language = .english
        store.shownMetrics = [.cpu, .gpu, .memory, .disk, .network]
        defer {
            Settings.language = savedLanguage
            store.mutedSections = savedMuted
            store.shownMetrics = savedMetrics
        }

        let sampler = SystemStatsSampler()
        let processes = ProcessSampler()
        let model = AppModel()
        model.maxPanelHeight = 4000
        _ = processes.sample()
        // Fill the history charts.
        for i in 0..<40 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            model.snapshot = sampler.sample().anonymized()
            if i % 8 == 0 { model.processes = processes.sample().anonymized() }
        }
        model.processes = processes.sample().anonymized()
        model.snapshot.claude = ClaudeUsageStore.load()

        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            model.showSettings = false
            render(MainPanelView(model: model, context: PanelContext()), dark: dark,
                   to: dir.appendingPathComponent("panel-\(suffix).png"))
            model.showSettings = true
            render(MainPanelView(model: model, context: PanelContext()), dark: dark,
                   to: dir.appendingPathComponent("settings-\(suffix).png"))
            model.showSettings = false
        }

        // Screen-edge panel in Mute mode: GPU and Disk muted, CPU details pinned.
        SettingsStore.shared.mutedSections = [.gpu, .disk]
        model.pinnedDetails = [.cpu]
        let edge = PanelContext()
        edge.showsMute = true
        render(MainPanelView(model: model, context: edge), dark: true,
               to: dir.appendingPathComponent("edge-dark.png"))
        model.pinnedDetails = []
    }

    /// Draws `view` as a floating panel on a gradient backdrop and saves it.
    private static func render<V: View>(_ view: V, dark: Bool, to url: URL) {
        let colors = dark
            ? [Color(red: 0.07, green: 0.08, blue: 0.12), Color(red: 0.12, green: 0.10, blue: 0.20)]
            : [Color(red: 0.86, green: 0.89, blue: 0.95), Color(red: 0.93, green: 0.90, blue: 0.97)]
        let content = view
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(dark ? 0.15 : 0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(dark ? 0.5 : 0.2), radius: 16, y: 6)
            .padding(32)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, dark ? .dark : .light)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: content)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }
}

extension SystemStatsSnapshot {
    /// Hides this Mac's IP address in published screenshots and videos.
    func anonymized() -> SystemStatsSnapshot {
        var copy = self
        if copy.networkAddress != nil { copy.networkAddress = "192.168.1.20" }
        return copy
    }
}

extension ProcessSnapshot {
    /// Same numbers with neutral app names, so published screenshots and
    /// videos don't list the apps running on the Mac that rendered them.
    func anonymized() -> ProcessSnapshot {
        let names = ["Safari", "Xcode", "Mail", "Music", "Photos", "Finder", "Notes", "Messages",
                     "Preview", "Terminal", "Calendar", "Maps", "Keynote", "Pages", "Numbers"]
        func rename(_ rows: [ProcessRow]) -> [ProcessRow] {
            rows.enumerated().map { i, row in
                ProcessRow(pid: row.pid, name: names[i % names.count],
                           memoryBytes: row.memoryBytes, cpu: row.cpu)
            }
        }
        return ProcessSnapshot(topMemory: rename(topMemory), topCPU: rename(topCPU))
    }
}
