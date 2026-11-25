// Status item + sampling loop. Clicking the icon opens the main panel (a
// custom panel instead of an NSMenu, so toggling settings never closes it);
// the panel can also be pinned to a screen edge.

import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sampler = SystemStatsSampler(persistent: true)
    private let processSampler = ProcessSampler()
    private let processHelper = ProcessHelperClient()
    private let claudeFetcher = ClaudeUsageFetcher()
    private let model = AppModel()
    private let updater = UpdateChecker()
    private var statusItem: NSStatusItem!
    /// When a click outside last closed the popover. A click on the status
    /// item itself also reaches the outside-click monitor (on mouse down,
    /// before the item's action on mouse up), so the action must not reopen
    /// the popover right after that.
    private var lastOutsideClose = Date.distantPast
    private var timer: Timer?
    private var lastInterval: TimeInterval = 0

    private lazy var details = DetailManager(model: model)
    private lazy var popover = MainPanelController(
        model: model, details: details, placement: .popover,
        statusButton: { [weak self] in self?.statusItem.button })
    /// Pinned panels: one (the selected page), or one column per page.
    private var edgePanels: [MainPanelController] = []

    private var globalClickMonitor: Any?
    private var keyMonitor: Any?
    private var settingsGlobalMonitor: Any?
    private var settingsLocalMonitor: Any?

    func applicationWillTerminate(_ notification: Notification) {
        sampler.saveHistory()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.toolTip = "Sysbar"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        model.settingsChanged = { [weak self] in self?.applySettings() }
        MetricsExporter.shared.attach(model)
        MetricsExporter.shared.onStatusChange = { [weak self] in
            self?.model.metricsStatus = MetricsExporter.shared.status
        }
        MetricsExporter.shared.apply()
        // The Tailscale address can come and go: re-check now and then.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { MetricsExporter.shared.apply() }
        }
        model.pin = { [weak self] side in self?.pin(side) }
        model.togglePinKeepingOpen = { [weak self] in self?.togglePinKeepingOpen() }
        model.applyIconOpens = { [weak self] in
            guard let self else { return }
            // The menu is open and Float / Full was chosen: become that panel.
            if self.popover.isVisible {
                self.closePopover()
                self.openUnpinnedEdge()
            } else {
                self.fitPanels()
            }
        }
        model.openActivityMonitor = { [weak self] in self?.openActivityMonitor() }
        processHelper.onStateChange = { [weak self] state in self?.model.allProcesses = state }
        model.showAllProcesses = { [weak self] on in
            guard let self else { return }
            on ? self.processHelper.start() : self.processHelper.stop()
        }
        model.quit = { NSApp.terminate(nil) }
        model.checkForUpdates = { [weak self] in
            self?.closePopover()
            self?.updater.check(userInitiated: true)
        }
        observeLayout()
        model.showSettingsChanged = { [weak self] shown in
            DispatchQueue.main.async { self?.watchClicksOutsideSettings(shown) }
        }

        tick()
        restartTimer()
        updater.startAutomaticChecks()
        ClaudeUsageStore.refreshConnection()
        claudeFetcher.onChange = { [weak self] status in
            guard let self else { return }
            self.model.claudeFetchStatus = status
            if case .ok = status { self.model.refreshClaudeFromDisk() }
        }
        model.fetchClaude = { [weak self] in self?.claudeFetcher.fetch() }
        model.pagesChanged = { [weak self] in self?.syncEdgePanels() }
        syncEdgePanels()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitPanels() }
        }
    }

    // MARK: - Sampling

    private func restartTimer() {
        timer?.invalidate()
        lastInterval = Settings.interval
        let t = Timer(timeInterval: Settings.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = Settings.interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var panelsVisible: Bool {
        popover.isVisible || edgePanels.contains(where: \.isVisible) || details.anyVisible
    }

    private func tick() {
        var snapshot = sampler.sample()
        snapshot.claudeAccounts = ClaudeUsageStore.loadAll()
        snapshot.claude = snapshot.claudeAccounts.first
        claudeFetcher.tick()
        model.snapshot = snapshot
        // Process scanning only while something shows processes.
        if panelsVisible {
            if processHelper.isOn {
                processHelper.sample { [weak self] snapshot in
                    if let snapshot { self?.model.processes = snapshot }
                }
            } else {
                model.processes = processSampler.sample()
            }
        }
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        var config = StatusIconRenderer.Config.current
        config.diskSegments = model.menuBarDiskSegments
        if config.metrics.isEmpty {
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                accessibilityDescription: "Sysbar")
            image?.isTemplate = true
            button.image = image
            return
        }
        button.image = StatusIconRenderer.image(
            snapshot: model.snapshot, config: config, appearance: button.effectiveAppearance)
    }

    /// Re-fits the panels whenever something their size depends on changes
    /// (re-armed after each change, as Observation tracking is one-shot).
    private func observeLayout() {
        withObservationTracking {
            _ = model.snapshot
            _ = model.processes
            _ = model.showSettings
            _ = model.pinnedDetails
            _ = model.expandedCores
            _ = model.expandedGPUs
            _ = model.maxPanelHeight
            _ = Settings.language
            _ = Settings.pinSide
            _ = Settings.pinFull
            _ = Settings.pageCount
            _ = Settings.pinAllPages
            _ = SettingsStore.shared.pageSides
            _ = SettingsStore.shared.sectionPages
            _ = SettingsStore.shared.pageNames
            _ = SettingsStore.shared.hiddenSections
            _ = model.currentPage
            _ = Settings.sectionOrder
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.fitPanels()
                self?.observeLayout()
            }
        }
    }

    private func fitPanels() {
        if edgePanels.map(\.page) != (Settings.pinSide == nil ? (edgeOpenUnpinned ? [nil] : []) : Settings.pinnedPages) {
            syncEdgePanels()
        }
        let edgeScreen = edgePanels.first?.screen ?? popover.screen
        let visibleHeight = (popover.isVisible ? popover.screen : edgeScreen).visibleFrame.height
        // A full-height edge panel only leaves room for its header.
        let fullEdge = !popover.isVisible && !edgePanels.isEmpty && Settings.edgeFull
        // Header (+ page tabs) must fit too, or the window grows past the
        // menu bar.
        // Same with Settings open (tabs hidden), so opening it doesn't resize.
        let tabs: CGFloat = Settings.pageCount > 1 ? 34 : 0
        let maxHeight = max(300, visibleHeight - (fullEdge ? 44 : 70) - tabs)
        if abs(model.maxPanelHeight - maxHeight) > 1 { model.maxPanelHeight = maxHeight }
        if popover.isVisible { popover.layout() }
        placeColumns()
        details.fitAll()
    }

    private func applySettings() {
        if Settings.interval != lastInterval { restartTimer() }
        popover.panel.applyAppearance()
        edgePanels.forEach { $0.panel.applyAppearance() }
        details.applyAppearance()
        updateIcon()
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        // Pinned to a screen edge: the icon unpins and closes the panel.
        if Settings.pinSide != nil {
            pin(nil)
            return
        }
        // The icon opens an edge panel (Float or Full) that is NOT pinned: it
        // closes on a click outside, and its 📌 pins it.
        if edgeOpenUnpinned {
            closeUnpinnedEdge()
        } else if Date().timeIntervalSince(lastOutsideClose) > 0.5 {
            Settings.pinFull = Settings.iconOpens == "full"
            openUnpinnedEdge()
        }
        // else: this click already closed the panel on mouse down.
    }

    private func openPopover() {
        model.processes = processSampler.sample()
        popover.anchorToClick()
        fitPanels()
        NSApp.activate(ignoringOtherApps: true)
        popover.show()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastOutsideClose = Date()
                self?.closePopover()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.closePopover()
                return nil
            }
            return event
        }
    }

    /// An edge panel opened by the icon (Float / Full) but not pinned.
    private var edgeOpenUnpinned = false
    private var edgeClickMonitor: Any?

    private func openUnpinnedEdge() {
        model.processes = processSampler.sample()
        edgeOpenUnpinned = true
        if let id = NSScreen.underMouse?.displayID { Settings.pinScreenID = id }
        syncEdgePanels()
        fitPanels()
        edgeClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastOutsideClose = Date()
                self?.closeUnpinnedEdge()
            }
        }
    }

    private func closeUnpinnedEdge() {
        edgeOpenUnpinned = false
        if let edgeClickMonitor { NSEvent.removeMonitor(edgeClickMonitor) }
        edgeClickMonitor = nil
        model.showSettings = false
        syncEdgePanels()
        details.closeUnpinned()
    }

    /// The 📌 of an edge panel: pin it where it is, or unpin it and keep it
    /// open (it then closes on a click outside).
    private func togglePinKeepingOpen() {
        if Settings.pinSide != nil {
            let side = Settings.pinSide
            Settings.pinSide = nil
            if let side { UserDefaults.standard.set(side.rawValue, forKey: "lastPinSide") }
            openUnpinnedEdge()
        } else {
            if let edgeClickMonitor { NSEvent.removeMonitor(edgeClickMonitor) }
            edgeClickMonitor = nil
            edgeOpenUnpinned = false
            Settings.pinSide = Settings.lastPinSide
            syncEdgePanels()
        }
    }

    private func closePopover() {
        popover.close()
        model.showSettings = false
        details.closeUnpinned()
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        globalClickMonitor = nil
        keyMonitor = nil
    }

    // MARK: - Settings: leave on outside click

    /// While Settings is showing, a click anywhere outside the main panels
    /// (another app, the desktop, a detail panel) returns to the stats.
    private func watchClicksOutsideSettings(_ shown: Bool) {
        if let settingsGlobalMonitor { NSEvent.removeMonitor(settingsGlobalMonitor) }
        if let settingsLocalMonitor { NSEvent.removeMonitor(settingsLocalMonitor) }
        settingsGlobalMonitor = nil
        settingsLocalMonitor = nil
        guard shown else { return }
        settingsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.showSettings = false }
        }
        settingsLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            // Only Sysbar's own floating panels count; menus opened by the
            // settings pickers must not close Settings.
            if let window = event.window, window is KeyPanel,
               window !== self.popover.panel.window,
               !self.edgePanels.contains(where: { $0.panel.window === window }) {
                self.model.showSettings = false
            }
            return event
        }
    }

    // MARK: - Pin to screen edge

    private func pin(_ side: PinSide?) {
        if let edgeClickMonitor { NSEvent.removeMonitor(edgeClickMonitor) }
        edgeClickMonitor = nil
        edgeOpenUnpinned = false
        Settings.pinSide = side
        if side == nil {
            syncEdgePanels()
            details.closeUnpinned()
        } else {
            // Pin on the display where the user clicked the pin button.
            if let id = (NSScreen.underMouse ?? popover.screen).displayID {
                Settings.pinScreenID = id
            }
            closePopover()
            syncEdgePanels()
        }
    }

    /// Creates / removes the pinned panels to match the settings (none, one
    /// for the selected page, or one column per page) and places them.
    private func syncEdgePanels() {
        let wanted = Settings.pinSide == nil ? (edgeOpenUnpinned ? [nil] : []) : Settings.pinnedPages
        if edgePanels.map(\.page) != wanted {
            edgePanels.forEach { $0.close() }
            edgePanels = wanted.map { page in
                MainPanelController(model: model, details: details, placement: .edge, page: page,
                                    statusButton: { [weak self] in self?.statusItem.button })
            }
            edgePanels.forEach { $0.panel.applyAppearance() }
        }
        placeColumns()
        edgePanels.forEach { $0.show() }
    }

    /// Column index of each pinned page among those on the same edge.
    private func placeColumns() {
        var used: [PinSide: Int] = [:]
        for panel in edgePanels {
            let side = Settings.side(forPage: panel.page)
            panel.column = used[side, default: 0]
            used[side, default: 0] += 1
            if panel.isVisible { panel.layout() }
        }
    }

    func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

/// "Open at login" via SMAppService (works best from /Applications).
enum LoginItem {
    @MainActor
    static func binding(_ model: AppModel) -> Binding<Bool> {
        Binding(
            get: { SettingsStore.shared.openAtLogin },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    let alert = NSAlert()
                    alert.messageText = tr("Could not change Open at login",
                                           "Não foi possível alterar o início automático")
                    alert.informativeText = error.localizedDescription
                        + tr("\n\nTip: move Sysbar.app to /Applications and try again.",
                             "\n\nDica: mova o Sysbar.app para /Applications e tente de novo.")
                    alert.runModal()
                }
                refresh()
            })
    }

    /// Re-reads the real status (it can also change in System Settings).
    @MainActor
    static func refresh() {
        let on = SMAppService.mainApp.status == .enabled
        if SettingsStore.shared.openAtLogin != on { SettingsStore.shared.openAtLogin = on }
    }
}
