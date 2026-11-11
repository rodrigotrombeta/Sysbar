// Shared, observable state for every SwiftUI panel (main panel, screen-edge
// panel, detail panels). The AppDelegate owns it and pushes a new snapshot
// each tick.

import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot = SystemStatsSnapshot()
    @Published var processes = ProcessSnapshot()
    /// Bumped whenever a setting changes so views re-read Settings / tr().
    @Published var revision = 0
    @Published var showSettings = false
    /// Detail panels the user pinned by clicking a section, in pin order.
    @Published var pinnedDetails: [SystemStatKind] = []
    @Published var expandedCores = false
    @Published var expandedGPUs = false
    /// Tallest the main panel may be before it scrolls.
    @Published var maxPanelHeight: CGFloat = 800

    // Actions, wired by the AppDelegate.
    var settingsChanged: () -> Void = {}
    var pin: (PinSide?) -> Void = { _ in }
    var openActivityMonitor: () -> Void = {}
    var quit: () -> Void = {}
    var toggleDetailPin: (SystemStatKind) -> Void = { _ in }
    var closeDetail: (SystemStatKind) -> Void = { _ in }

    func bump() {
        revision &+= 1
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

    func cycleAppearance() {
        Settings.appearance = Settings.appearance.next
        bump()
    }
}
