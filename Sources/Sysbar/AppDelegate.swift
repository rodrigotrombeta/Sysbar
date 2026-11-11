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
    private let pinned = PinnedPanelController()

    private let menu = NSMenu()
    /// Exists only while the menu is open: a live NSHostingView left attached
    /// to a closed menu kept ~80 MB of graphics memory alive.
    private var statsHost: NSHostingView<SystemStatsPanelStack>?
    private let statsItem = NSMenuItem()

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

        pinned.onToggleSide = { [weak self] in
            Settings.pinSide = Settings.pinSide == .left ? .right : .left
            self?.applyPin()
        }
        pinned.onUnpin = { [weak self] in
            Settings.pinSide = nil
            self?.applyPin()
        }
        pinned.onActivityMonitor = { [weak self] in self?.openActivityMonitor() }
        pinned.onCycleAppearance = { [weak self] in
            Settings.appearance = Settings.appearance.next
            self?.settingsChanged()
        }
        applyPin()
    }

    private func applyPin() {
        if let side = Settings.pinSide {
            pinned.show(snapshot: snapshot, interval: Settings.interval, side: side)
        } else {
            pinned.hide()
        }
        rebuildMenu()
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
            statsHost?.rootView = statsView()
        }
        if let side = Settings.pinSide {
            pinned.update(snapshot: snapshot, interval: Settings.interval, side: side)
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let config = StatusIconRenderer.Config(
            metrics: Settings.metrics,
            style: Settings.style,
            colorModes: Dictionary(uniqueKeysWithValues:
                IconMetric.allCases.map { ($0, Settings.colorMode(for: $0)) }),
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        attachStatsHost()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuIsOpen = true
        attachStatsHost()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuIsOpen = false
        // Release the SwiftUI view (and its render buffers) while closed.
        statsItem.view = nil
        statsHost = nil
    }

    private func attachStatsHost() {
        if let statsHost {
            statsHost.rootView = statsView()
        } else {
            let host = NSHostingView(rootView: statsView())
            host.appearance = Settings.appearance.nsAppearance
            statsHost = host
            statsItem.view = host
        }
        statsHost?.setFrameSize(statsHost?.fittingSize ?? .zero)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        statsItem.view = nil
        statsHost = nil
        menu.addItem(statsItem)
        menu.addItem(.separator())

        // Which metrics animate the icon (multi-select). Memory and Disk are
        // submenus: show/hide plus their own chart type.
        let metricsMenu = NSMenu()
        let selected = Settings.metrics
        for metric in IconMetric.allCases {
            if metric == .network {
                let parent = NSMenuItem(title: metric.title, action: nil, keyEquivalent: "")
                parent.state = selected.contains(metric) ? .on : .off
                let sub = NSMenu()
                sub.addItem(menuItem(tr("Show in icon", "Mostrar no ícone"), #selector(toggleMetric(_:)),
                                     metric.rawValue, on: selected.contains(metric)))
                sub.addItem(.separator())
                for style in NetworkStyle.allCases {
                    sub.addItem(menuItem(style.title, #selector(selectNetworkStyle(_:)),
                                         style.rawValue, on: Settings.networkStyle == style))
                }
                parent.submenu = sub
                metricsMenu.addItem(parent)
            } else if metric.hasOwnChart {
                if metric == .memory { metricsMenu.addItem(.separator()) }
                let parent = NSMenuItem(title: metric.title, action: nil, keyEquivalent: "")
                parent.state = selected.contains(metric) ? .on : .off
                let sub = NSMenu()
                let show = menuItem(tr("Show in icon", "Mostrar no ícone"), #selector(toggleMetric(_:)),
                                    metric.rawValue, on: selected.contains(metric))
                sub.addItem(show)
                sub.addItem(.separator())
                for chart in MetricChart.allCases {
                    sub.addItem(menuItem(chart.title, #selector(selectChart(_:)),
                                         "\(metric.rawValue):\(chart.rawValue)",
                                         on: metric.chartKind == chart))
                }
                parent.submenu = sub
                metricsMenu.addItem(parent)
            } else {
                metricsMenu.addItem(menuItem(metric.title, #selector(toggleMetric(_:)),
                                             metric.rawValue, on: selected.contains(metric)))
            }
        }
        addSubmenu(tr("Icon metrics", "Métricas no ícone"), metricsMenu)

        let styleMenu = NSMenu()
        for style in IconStyle.allCases {
            styleMenu.addItem(menuItem(style.title, #selector(selectStyle(_:)), style.rawValue,
                                       on: Settings.style == style))
        }
        styleMenu.addItem(.separator())
        styleMenu.addItem(menuItem(tr("Show label", "Mostrar rótulo"), #selector(toggleLabel(_:)),
                                   nil, on: Settings.showLabel))
        addSubmenu(tr("Icon style", "Estilo do ícone"), styleMenu)

        // Colors: one submenu per metric, plus "All metrics" to set them at once.
        let colorMenu = NSMenu()
        let modes = IconMetric.allCases.map(Settings.colorMode(for:))
        let allItem = NSMenuItem(title: tr("All metrics", "Todas as métricas"), action: nil, keyEquivalent: "")
        let allMenu = NSMenu()
        for mode in IconColorMode.allCases {
            allMenu.addItem(menuItem(mode.title, #selector(selectColor(_:)), "*:\(mode.rawValue)",
                                     on: modes.allSatisfy { $0 == mode }))
        }
        allItem.submenu = allMenu
        colorMenu.addItem(allItem)
        colorMenu.addItem(.separator())
        for metric in IconMetric.allCases {
            let current = Settings.colorMode(for: metric)
            let item = NSMenuItem(title: metric.title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for mode in IconColorMode.allCases {
                sub.addItem(menuItem(mode.title, #selector(selectColor(_:)),
                                     "\(metric.rawValue):\(mode.rawValue)", on: current == mode))
            }
            item.submenu = sub
            colorMenu.addItem(item)
        }
        addSubmenu(tr("Colors", "Cores"), colorMenu)

        let appearanceMenu = NSMenu()
        for appearance in AppAppearance.allCases {
            let item = menuItem(appearance.title, #selector(selectAppearance(_:)), appearance.rawValue,
                                on: Settings.appearance == appearance)
            item.image = NSImage(systemSymbolName: appearance.symbol, accessibilityDescription: nil)
            appearanceMenu.addItem(item)
        }
        addSubmenu(tr("Appearance", "Aparência"), appearanceMenu)

        let intervalMenu = NSMenu()
        for interval in Settings.intervals {
            let title = interval < 1 ? "\(Int(interval * 1000)) ms" : "\(Int(interval)) s"
            intervalMenu.addItem(menuItem(title, #selector(selectInterval(_:)), interval,
                                          on: Settings.interval == interval))
        }
        addSubmenu(tr("Refresh interval", "Intervalo de atualização"), intervalMenu)

        let languageMenu = NSMenu()
        for language in Language.allCases {
            languageMenu.addItem(menuItem(language.title, #selector(selectLanguage(_:)),
                                          language.rawValue, on: Settings.language == language))
        }
        addSubmenu(tr("Language", "Idioma (Language)"), languageMenu)

        menu.addItem(.separator())

        let pinMenu = NSMenu()
        for side in PinSide.allCases {
            pinMenu.addItem(menuItem(side.title, #selector(selectPin(_:)), side.rawValue,
                                     on: Settings.pinSide == side))
        }
        pinMenu.addItem(.separator())
        pinMenu.addItem(menuItem(tr("Unpin", "Desafixar"), #selector(selectPin(_:)), "none",
                                 on: Settings.pinSide == nil))
        let pinItem = NSMenuItem(title: tr("Pin to screen edge", "Fixar na lateral da tela"),
                                 action: nil, keyEquivalent: "")
        pinItem.image = NSImage(systemSymbolName: Settings.pinSide == nil ? "pin" : "pin.fill",
                                accessibilityDescription: nil)
        pinItem.submenu = pinMenu
        menu.addItem(pinItem)

        let activity = menuItem(tr("Open Activity Monitor", "Abrir Monitor de Atividade"),
                                #selector(openActivityMonitor), nil, on: false)
        activity.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        activity.keyEquivalent = "a"
        menu.addItem(activity)

        menu.addItem(menuItem(tr("Open at login", "Abrir ao iniciar sessão"), #selector(toggleLogin(_:)),
                              nil, on: SMAppService.mainApp.status == .enabled))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("Quit Sysbar", "Sair do Sysbar"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applyAppearance(to: menu)
    }

    /// Light / Dark / System for the menu (and every submenu) and the
    /// pinned panel. The menu bar icon itself always follows the menu bar.
    private func applyAppearance(to menu: NSMenu) {
        menu.appearance = Settings.appearance.nsAppearance
        statsHost?.appearance = Settings.appearance.nsAppearance
        for item in menu.items {
            if let sub = item.submenu { applyAppearance(to: sub) }
        }
    }

    private func menuItem(_ title: String, _ action: Selector, _ object: Any?, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        item.state = on ? .on : .off
        return item
    }

    private func addSubmenu(_ title: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func settingsChanged() {
        rebuildMenu()
        updateIcon()
        if let side = Settings.pinSide {
            pinned.show(snapshot: snapshot, interval: Settings.interval, side: side)
        }
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

    @objc private func selectChart(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count == 2, let metric = IconMetric(rawValue: parts[0]),
              let chart = MetricChart(rawValue: parts[1]) else { return }
        if metric == .memory { Settings.memoryChart = chart }
        if metric == .disk { Settings.diskChart = chart }
        // Picking a chart implies you want to see it.
        if !Settings.metrics.contains(metric) { Settings.metrics = Settings.metrics + [metric] }
        settingsChanged()
    }

    @objc private func selectPin(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        Settings.pinSide = PinSide(rawValue: raw)
        applyPin()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = Language(rawValue: raw) else { return }
        Settings.language = language
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
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count == 2, let mode = IconColorMode(rawValue: parts[1]) else { return }
        if parts[0] == "*" {
            IconMetric.allCases.forEach { Settings.setColorMode(mode, for: $0) }
        } else if let metric = IconMetric(rawValue: parts[0]) {
            Settings.setColorMode(mode, for: metric)
        }
        settingsChanged()
    }

    @objc private func selectNetworkStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = NetworkStyle(rawValue: raw) else { return }
        Settings.networkStyle = style
        if !Settings.metrics.contains(.network) { Settings.metrics = Settings.metrics + [.network] }
        settingsChanged()
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let appearance = AppAppearance(rawValue: raw) else { return }
        Settings.appearance = appearance
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
            alert.messageText = tr("Could not change Open at login", "Não foi possível alterar o início automático")
            alert.informativeText = error.localizedDescription + tr("\n\nTip: move Sysbar.app to /Applications and try again.", "\n\nDica: mova o Sysbar.app para /Applications e tente de novo.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
