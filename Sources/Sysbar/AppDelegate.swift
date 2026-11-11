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

        // Which metrics animate the icon (multi-select). Memory and Disk are
        // submenus: show/hide plus their own chart type.
        let metricsMenu = NSMenu()
        let selected = Settings.metrics
        for metric in IconMetric.allCases {
            if metric.hasOwnChart {
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

        let colorMenu = NSMenu()
        for mode in IconColorMode.allCases {
            colorMenu.addItem(menuItem(mode.title, #selector(selectColor(_:)), mode.rawValue,
                                       on: Settings.colorMode == mode))
        }
        addSubmenu(tr("Colors", "Cores"), colorMenu)

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

        menu.addItem(menuItem(tr("Open at login", "Abrir ao iniciar sessão"), #selector(toggleLogin(_:)),
                              nil, on: SMAppService.mainApp.status == .enabled))
        menu.addItem(menuItem(tr("Open Activity Monitor", "Abrir Monitor de Atividade"),
                              #selector(openActivityMonitor), nil, on: false))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("Quit Sysbar", "Sair do Sysbar"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
            alert.messageText = tr("Could not change Open at login", "Não foi possível alterar o início automático")
            alert.informativeText = error.localizedDescription + tr("\n\nTip: move Sysbar.app to /Applications and try again.", "\n\nDica: mova o Sysbar.app para /Applications e tente de novo.")
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
