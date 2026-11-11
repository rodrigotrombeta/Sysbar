// Status item + menu. The menu's first item hosts the CPU/GPU/Memory panels
// (the same SwiftUI views as oMLX's "System Stats" submenu); the rest are
// settings for the animated icon.

import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let sampler = SystemStatsSampler()
    private var snapshot = SystemStatsSnapshot()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var menuIsOpen = false

    private let menu = NSMenu()
    private var statsHost: NSHostingView<SystemStatsPanelStack>!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Sysbar — System Stats"

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        snapshot = sampler.sample()
        rebuildMenu()
        updateIcon()
        restartTimer()
    }

    // MARK: - Sampling

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: Settings.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = Settings.interval * 0.1
        // .common so the icon and the open menu keep updating while the
        // menu's run loop is in tracking mode.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        snapshot = sampler.sample()
        updateIcon()
        if menuIsOpen {
            statsHost.rootView = statsView()
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let config = StatusIconRenderer.Config(
            metrics: Settings.metrics,
            style: Settings.style,
            colorMode: Settings.colorMode,
            showLabel: Settings.showLabel
        )
        button.image = StatusIconRenderer.image(
            snapshot: snapshot, config: config, appearance: button.effectiveAppearance
        )
    }

    private func statsView() -> SystemStatsPanelStack {
        SystemStatsPanelStack(kinds: SystemStatKind.allCases, snapshot: snapshot,
                              refreshInterval: Settings.interval)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        statsHost.rootView = statsView()
        statsHost.setFrameSize(statsHost.fittingSize)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        statsHost = NSHostingView(rootView: statsView())
        statsHost.setFrameSize(statsHost.fittingSize)
        let statsItem = NSMenuItem()
        statsItem.view = statsHost
        menu.addItem(statsItem)
        menu.addItem(.separator())

        // Which metrics animate the icon (multi-select).
        let metricsMenu = NSMenu()
        let selected = Settings.metrics
        for metric in IconMetric.allCases {
            let item = NSMenuItem(title: metric.title, action: #selector(toggleMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = metric.rawValue
            item.state = selected.contains(metric) ? .on : .off
            metricsMenu.addItem(item)
        }
        addSubmenu("Métricas no ícone", metricsMenu)

        let styleMenu = NSMenu()
        for style in IconStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = Settings.style == style ? .on : .off
            styleMenu.addItem(item)
        }
        styleMenu.addItem(.separator())
        let labelItem = NSMenuItem(title: "Mostrar rótulo", action: #selector(toggleLabel(_:)), keyEquivalent: "")
        labelItem.target = self
        labelItem.state = Settings.showLabel ? .on : .off
        styleMenu.addItem(labelItem)
        addSubmenu("Estilo do ícone", styleMenu)

        let colorMenu = NSMenu()
        for mode in IconColorMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = Settings.colorMode == mode ? .on : .off
            colorMenu.addItem(item)
        }
        addSubmenu("Cores", colorMenu)

        let intervalMenu = NSMenu()
        for interval in Settings.intervals {
            let title = interval < 1 ? "\(Int(interval * 1000)) ms" : "\(Int(interval)) s"
            let item = NSMenuItem(title: title, action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            item.state = Settings.interval == interval ? .on : .off
            intervalMenu.addItem(item)
        }
        addSubmenu("Intervalo de atualização", intervalMenu)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Abrir ao iniciar sessão", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let activity = NSMenuItem(title: "Abrir Monitor de Atividade", action: #selector(openActivityMonitor), keyEquivalent: "")
        activity.target = self
        menu.addItem(activity)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Sair do Sysbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addSubmenu(_ title: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func settingsChanged() {
        rebuildMenu()
        updateIcon()
    }

    // MARK: - Actions

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let metric = IconMetric(rawValue: raw) else { return }
        var metrics = Settings.metrics
        if let index = metrics.firstIndex(of: metric) {
            guard metrics.count > 1 else { NSSound.beep(); return } // keep at least one
            metrics.remove(at: index)
        } else {
            metrics.append(metric)
        }
        Settings.metrics = metrics
        settingsChanged()
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = IconStyle(rawValue: raw) else { return }
        Settings.style = style
        settingsChanged()
    }

    @objc private func toggleLabel(_ sender: NSMenuItem) {
        Settings.showLabel.toggle()
        settingsChanged()
    }

    @objc private func selectColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = IconColorMode(rawValue: raw) else { return }
        Settings.colorMode = mode
        settingsChanged()
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval else { return }
        Settings.interval = interval
        restartTimer()
        settingsChanged()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Não foi possível alterar o início automático"
            alert.informativeText = "\(error.localizedDescription)\n\nDica: mova o Sysbar.app para /Applications e tente de novo."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
