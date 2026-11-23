// Status item + sampling loop. Clicking the icon opens the main panel (a
// custom panel instead of an NSMenu, so toggling settings never closes it);
// the panel can also be pinned to a screen edge.

import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sampler = SystemStatsSampler()
    private let processSampler = ProcessSampler()
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
    private lazy var edgePanel = MainPanelController(
        model: model, details: details, placement: .edge,
        statusButton: { [weak self] in self?.statusItem.button })

    private var globalClickMonitor: Any?
    private var keyMonitor: Any?
    private var settingsGlobalMonitor: Any?
    private var settingsLocalMonitor: Any?

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
        model.pin = { [weak self] side in self?.pin(side) }
        model.openActivityMonitor = { [weak self] in self?.openActivityMonitor() }
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
        if Settings.pinSide != nil { edgePanel.show() }

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
        popover.isVisible || edgePanel.isVisible || details.anyVisible
    }

    private func tick() {
        let snapshot = sampler.sample()
        model.snapshot = snapshot
        // Process scanning only while something shows processes.
        if panelsVisible {
            model.processes = processSampler.sample()
        }
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let config = StatusIconRenderer.Config.current
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
            _ = Settings.sectionOrder
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.fitPanels()
                self?.observeLayout()
            }
        }
    }

    private func fitPanels() {
        let visibleHeight = (popover.isVisible ? popover.screen : edgePanel.screen).visibleFrame.height
        let maxHeight = max(300, visibleHeight - 70)
        if abs(model.maxPanelHeight - maxHeight) > 1 { model.maxPanelHeight = maxHeight }
        if popover.isVisible { popover.layout() }
        if edgePanel.isVisible { edgePanel.layout() }
        details.fitAll()
    }

    private func applySettings() {
        if Settings.interval != lastInterval { restartTimer() }
        popover.panel.applyAppearance()
        edgePanel.panel.applyAppearance()
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
        if popover.isVisible {
            closePopover()
        } else if Date().timeIntervalSince(lastOutsideClose) > 0.5 {
            openPopover()
        }
        // else: this click already closed the popover on mouse down.
    }

    private func openPopover() {
        model.processes = processSampler.sample()
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
               window !== self.popover.panel.window, window !== self.edgePanel.panel.window {
                self.model.showSettings = false
            }
            return event
        }
    }

    // MARK: - Pin to screen edge

    private func pin(_ side: PinSide?) {
        Settings.pinSide = side
        if side == nil {
            edgePanel.close()
            details.closeUnpinned()
        } else {
            closePopover()
            edgePanel.show()
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
