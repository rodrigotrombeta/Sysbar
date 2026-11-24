// Shared, observable state for every SwiftUI panel (main panel, screen-edge
// panel, detail panels). The AppDelegate owns it and pushes a new snapshot
// each tick. Settings live in `SettingsStore`, which is observable too, so
// views that read a setting (or call `tr()`) update in place when it changes.

import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    var snapshot = SystemStatsSnapshot()
    var processes = ProcessSnapshot()
    var showSettings = false {
        didSet { if showSettings != oldValue { showSettingsChanged(showSettings) } }
    }
    /// Detail panels the user pinned by clicking a section, in pin order.
    var pinnedDetails: [SystemStatKind] = []
    var expandedCores = false
    var expandedGPUs = false
    /// Tallest the main panel may be before it scrolls.
    var maxPanelHeight: CGFloat = 800
    /// Root helper that lists every user's processes (see ProcessHelper).
    var allProcesses: ProcessHelperClient.State = .off
    /// "Detailed" disk usage, measured on demand.
    var diskBreakdown: DiskBreakdown?
    var measuringDisk = false

    // Actions, wired by the AppDelegate.
    @ObservationIgnored var settingsChanged: () -> Void = {}
    @ObservationIgnored var showSettingsChanged: (Bool) -> Void = { _ in }
    @ObservationIgnored var pin: (PinSide?) -> Void = { _ in }
    @ObservationIgnored var togglePinKeepingOpen: () -> Void = {}
    @ObservationIgnored var applyIconOpens: () -> Void = {}
    @ObservationIgnored var openActivityMonitor: () -> Void = {}
    @ObservationIgnored var quit: () -> Void = {}
    @ObservationIgnored var checkForUpdates: () -> Void = {}
    @ObservationIgnored var toggleDetailPin: (SystemStatKind) -> Void = { _ in }
    @ObservationIgnored var closeDetail: (SystemStatKind) -> Void = { _ in }
    @ObservationIgnored var showAllProcesses: (Bool) -> Void = { _ in }
    /// Mute mode changed: hover-opened details of muted sections close.
    @ObservationIgnored var muteChanged: () -> Void = {}

    /// Measures the detailed disk usage off the main thread.
    func measureDisk() {
        guard !measuringDisk else { return }
        measuringDisk = true
        Task.detached(priority: .utility) {
            let result = DiskBreakdown.measure()
            await MainActor.run {
                self.diskBreakdown = result ?? self.diskBreakdown
                self.measuringDisk = false
                self.bump()
            }
        }
    }

    /// Status of the fetch from Anthropic (Settings shows it).
    var claudeFetchStatus: ClaudeUsageFetcher.Status = .idle
    @ObservationIgnored var fetchClaude: () -> Void = {}

    /// Page shown by the panels that aren't tied to one page; remembered,
    /// so the panel reopens on the page you were on.
    var currentPage = UserDefaults.standard.integer(forKey: "currentPage") {
        didSet { UserDefaults.standard.set(currentPage, forKey: "currentPage") }
    }

    func sectionPage(_ kind: SystemStatKind) -> Binding<Int> {
        Binding(get: { Settings.isOnDashboard(kind) ? Settings.page(of: kind) : -1 },
                set: { page in
                    Settings.setOnDashboard(page >= 0, kind)
                    if page >= 0 { Settings.setPage(page, for: kind) }
                })
    }

    var pageCount: Binding<Int> {
        Binding(get: { Settings.pageCount }, set: {
            Settings.pageCount = $0
            if self.currentPage >= $0 { self.currentPage = 0 }
        })
    }

    func pageName(_ page: Int) -> Binding<String> {
        Binding(get: { page < SettingsStore.shared.pageNames.count ? SettingsStore.shared.pageNames[page] : "" },
                set: { Settings.setPageName($0, for: page) })
    }

    /// Moves a page up (-1) or down (+1); the selected page follows it.
    func movePage(_ page: Int, by delta: Int) {
        let target = page + delta
        guard (0..<Settings.pageCount).contains(target) else { return }
        Settings.swapPages(page, target)
        if currentPage == page { currentPage = target } else if currentPage == target { currentPage = page }
        pagesChanged()
    }

    var pinAllPages: Binding<Bool> {
        Binding(get: { Settings.pinAllPages }, set: {
            Settings.pinAllPages = $0
            // "All pages" pins right away, so every page opens as a column.
            if $0 && Settings.pinSide == nil {
                self.pin(Settings.lastPinSide)
            } else {
                self.pagesChanged()
            }
        })
    }

    /// Pages or pinning changed: rebuild the pinned columns.
    @ObservationIgnored var pagesChanged: () -> Void = {}

    /// Moves a pinned page's column (nil = the single pinned panel) to an edge.
    func sendPage(_ page: Int?, to side: PinSide) {
        if let page, page > 0 {
            Settings.setSide(side, forPage: page)
            pagesChanged()
            return
        }
        // The main page: other pages that follow its edge keep theirs.
        for other in 1..<max(1, Settings.pageCount) {
            Settings.setSide(Settings.side(forPage: other), forPage: other)
        }
        Settings.pinSide = side
        pagesChanged()
    }

    var iconOpens: Binding<String> {
        Binding(get: { Settings.iconOpens }, set: {
            Settings.iconOpens = $0
            // Float / Full apply right away to the open panel.
            Settings.pinFull = $0 == "full"
            self.applyIconOpens()
        })
    }

    var iconSpacing: Binding<Double> {
        Binding(get: { Settings.iconSpacing }, set: { Settings.iconSpacing = $0.rounded(); self.bump() })
    }

    var chartWindow: Binding<TimeInterval> {
        Binding(get: { Settings.chartWindow }, set: { Settings.chartWindow = $0 })
    }

    var clockFontSize: Binding<Double> {
        Binding(get: { Settings.clockFontSize }, set: { Settings.clockFontSize = $0; self.bump() })
    }

    func onDashboard(_ kind: SystemStatKind) -> Binding<Bool> {
        Binding(get: { Settings.isOnDashboard(kind) }, set: { Settings.setOnDashboard($0, kind) })
    }

    // Clocks: edits start from the shown list (this Mac's zone by default).
    func addClock(_ id: String) {
        var ids = WorldClock.zones.map(\.identifier)
        guard !ids.contains(id) else { return }
        ids.append(id)
        Settings.clockZones = ids
        bump()
    }

    func removeClock(_ id: String) {
        Settings.clockZones = WorldClock.zones.map(\.identifier).filter { $0 != id }
        bump()
    }

    func moveClock(_ id: String, by delta: Int) {
        var ids = WorldClock.zones.map(\.identifier)
        guard let i = ids.firstIndex(of: id), ids.indices.contains(i + delta) else { return }
        ids.swapAt(i, i + delta)
        Settings.clockZones = ids
        bump()
    }

    func refreshClaude() {
        if Settings.claudeFetch { fetchClaude() }
        refreshClaudeFromDisk()
    }

    func refreshClaudeFromDisk() {
        snapshot.claudeAccounts = ClaudeUsageStore.reloadAll()
        snapshot.claude = snapshot.claudeAccounts.first
    }

    func claudeAccountName(_ account: String) -> Binding<String> {
        Binding(get: { Settings.claudeAccountNames[account] ?? "" },
                set: { Settings.claudeAccountNames[account] = $0.isEmpty ? nil : $0 })
    }

    func moveSection(_ kind: SystemStatKind, to index: Int) {
        Settings.moveSection(kind, to: index)
    }

    func toggleMute(_ kind: SystemStatKind) {
        Settings.toggleMute(kind)
        muteChanged()
    }

    func toggleMuteAll() {
        Settings.setAllMuted(!Settings.allMuted)
        muteChanged()
    }

    /// A setting that affects AppKit (timer, window appearance, status icon)
    /// changed; SwiftUI views update on their own.
    func bump() {
        settingsChanged()
    }

    // MARK: Bindings to Settings

    func metricShown(_ metric: IconMetric) -> Binding<Bool> {
        Binding(
            get: { Settings.metrics.contains(metric) },
            set: { on in
                var list = Settings.metrics
                if on, !list.contains(metric) { list.append(metric) }
                if !on { list.removeAll { $0 == metric } }
                Settings.metrics = list
                self.bump()
            })
    }

    func moveMetric(_ metric: IconMetric, to index: Int) {
        Settings.move(metric, to: index)
        bump()
    }

    func metricStyle(_ metric: IconMetric) -> Binding<IconStyle> {
        Binding(get: { Settings.style(for: metric) },
                set: { Settings.setStyle($0, for: metric); self.bump() })
    }

    func metricColor(_ metric: IconMetric) -> Binding<IconColorMode> {
        Binding(get: { Settings.colorMode(for: metric) },
                set: { Settings.setColorMode($0, for: metric); self.bump() })
    }

    var showLabel: Binding<Bool> {
        Binding(get: { Settings.showLabel }, set: { Settings.showLabel = $0; self.bump() })
    }

    var interval: Binding<TimeInterval> {
        Binding(get: { Settings.interval }, set: { Settings.interval = $0; self.bump() })
    }

    var language: Binding<Language> {
        Binding(get: { Settings.language }, set: { Settings.language = $0; self.bump() })
    }

    var appearance: Binding<AppAppearance> {
        Binding(get: { Settings.appearance }, set: { Settings.appearance = $0; self.bump() })
    }

    /// One panel's opacity ("edge" or a section kind).
    /// Opacity of every panel (Settings and the edge panel's button).
    var opacity: Binding<OpacitySet> { opacity(for: nil) }

    /// A panel's opacity: global, or its own when set to Separate.
    func opacity(for key: String?) -> Binding<OpacitySet> {
        Binding(get: { Settings.opacity(for: key) },
                set: { Settings.setOpacity($0, for: key); self.bump() })
    }

    func separateOpacity(_ key: String) -> Binding<Bool> {
        Binding(get: { Settings.isSeparateOpacity(key) },
                set: { Settings.setSeparateOpacity($0, for: key); self.bump() })
    }

    var pinFull: Binding<Bool> {
        Binding(get: { Settings.pinFull }, set: { Settings.pinFull = $0 })
    }

    var diskDetailedInIcon: Binding<Bool> {
        Binding(get: { Settings.diskDetailedInIcon }, set: { Settings.diskDetailedInIcon = $0; self.bump() })
    }

    /// Detailed disk slices for the menu bar icon, while the last
    /// measurement is recent; nil = plain used vs free.
    var menuBarDiskSegments: [(Double, NSColor)]? {
        guard Settings.diskDetailedInIcon, let b = diskBreakdown, b.isFresh else { return nil }
        return b.iconSegments
    }

    var textColor: Binding<Color?> {
        Binding(get: { Settings.textColor }, set: { Settings.textColor = $0; self.bump() })
    }

    var autoCheckUpdates: Binding<Bool> {
        Binding(get: { Settings.autoCheckUpdates }, set: { Settings.autoCheckUpdates = $0 })
    }

    func cycleAppearance() {
        Settings.appearance = Settings.appearance.next
        bump()
    }
}
