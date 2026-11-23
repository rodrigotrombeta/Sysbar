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
    /// Opacity of every panel (Settings and each pinned panel's button).
    var opacity: Binding<OpacitySet> {
        Binding(get: { Settings.opacity }, set: { Settings.opacity = $0; self.bump() })
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

    var autoCheckUpdates: Binding<Bool> {
        Binding(get: { Settings.autoCheckUpdates }, set: { Settings.autoCheckUpdates = $0 })
    }

    func cycleAppearance() {
        Settings.appearance = Settings.appearance.next
        bump()
    }
}
