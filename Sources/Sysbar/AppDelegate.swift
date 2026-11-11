// Status item + sampling loop. Clicking the icon opens the main panel (a
// custom panel instead of an NSMenu, so toggling settings never closes it);
// the panel can also be pinned to a screen edge.

import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sampler = SystemStatsSampler()
    private let processSampler = ProcessSampler()
    private let model = AppModel()
    private var statusItem: NSStatusItem!
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
    private var modelObserver: AnyCancellable?

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
        // Re-fit panels whenever their content may have changed size.
        modelObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitPanels() }
        }

        tick()
        restartTimer()
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
        popover.isVisible ? closePopover() : openPopover()
    }

    private func openPopover() {
        model.processes = processSampler.sample()
        fitPanels()
        NSApp.activate(ignoringOtherApps: true)
        popover.show()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
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
        details.closeUnpinned()
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        globalClickMonitor = nil
        keyMonitor = nil
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
        model.revision &+= 1
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
            get: { SMAppService.mainApp.status == .enabled },
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
                model.revision &+= 1
            })
    }
}
