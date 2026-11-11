// The panel that opens from the menu bar icon (and the screen-edge pinned
// panel): a header that is always on top (pin, Activity Monitor, appearance,
// settings, quit), then the CPU / GPU / Memory / Disk / Network / Top
// processes sections — or the settings, which never close the panel.

import SwiftUI

/// Section frames in the panel's (top-left based) window coordinates, used
/// by the window controller for hover tracking and detail placement.
struct SectionFramesKey: PreferenceKey {
    static var defaultValue: [SystemStatKind: CGRect] = [:]
    static func reduce(value: inout [SystemStatKind: CGRect], nextValue: () -> [SystemStatKind: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Callbacks from one hosted panel to its window controller.
final class PanelContext {
    var onSectionFrames: ([SystemStatKind: CGRect]) -> Void = { _ in }
    var onTapSection: (SystemStatKind) -> Void = { _ in }
}

struct MainPanelView: View {
    @ObservedObject var model: AppModel
    let context: PanelContext
    @State private var contentHeight: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(model: model)
            Divider().padding(.horizontal, 10)
            ScrollView(.vertical, showsIndicators: contentHeight > model.maxPanelHeight) {
                Group {
                    if model.showSettings {
                        SettingsView(model: model)
                    } else {
                        sections
                    }
                }
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                })
            }
            .frame(height: min(contentHeight, model.maxPanelHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        }
        .frame(width: panelWidth)
        .onPreferenceChange(SectionFramesKey.self) { context.onSectionFrames($0) }
        .id(model.revision)
    }

    private var sections: some View {
        VStack(spacing: 0) {
            ForEach(Array(SystemStatKind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { SectionRule() }
                SectionHost(model: model, kind: kind, context: context)
            }
        }
        .padding(.bottom, 6)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One section: reports its frame, shows a pin badge when its details are
/// pinned, and pins/unpins the details on click.
private struct SectionHost: View {
    @ObservedObject var model: AppModel
    let kind: SystemStatKind
    let context: PanelContext

    var body: some View {
        let s = model.snapshot
        let pinned = model.pinnedDetails.contains(kind)
        Group {
            switch kind {
            case .cpu: CPUStatsPanel(snapshot: s, refreshInterval: Settings.interval)
            case .gpu: GPUStatsPanel(snapshot: s, refreshInterval: Settings.interval)
            case .memory: MemoryStatsPanel(snapshot: s)
            case .disk: DiskStatsPanel(snapshot: s, refreshInterval: Settings.interval)
            case .network: NetworkStatsPanel(snapshot: s, refreshInterval: Settings.interval)
            case .processes: TopProcessesPanel(rows: Array(model.processes.topMemory.prefix(5)),
                                               total: s.memory.totalBytes)
            }
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: pinned ? "pin.fill" : "chevron.left.2")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(pinned ? Color.accentColor : Color.secondary.opacity(0.5))
                .padding(.top, 9)
                .padding(.trailing, 12)
                .help(tr("Hover for details · click to keep them open",
                         "Passe o mouse para ver detalhes · clique para fixá-los"))
        }
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(pinned ? Color.accentColor.opacity(0.08) : Color.clear)
            .padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onTapGesture { context.onTapSection(kind) }
        .background(GeometryReader { geo in
            Color.clear.preference(key: SectionFramesKey.self, value: [kind: geo.frame(in: .global)])
        })
    }
}

/// Top 5 processes by memory (main panel section).
struct TopProcessesPanel: View {
    let rows: [ProcessRow]
    let total: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Top memory", "Top memória").uppercased())
                .font(.system(size: StatsTheme.caption, weight: .bold))
                .kerning(1)
                .foregroundStyle(Color(nsColor: .systemBlue))
                .frame(maxWidth: .infinity, alignment: .center)
            ProcessList(rows: rows, metric: .memory, total: total)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: panelWidth)
    }
}

// MARK: - Header

private struct PanelHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text("Sysbar").font(.system(size: 13, weight: .bold))
            Spacer()
            Menu {
                Button(tr("Pin to left edge", "Fixar na lateral esquerda")) { model.pin(.left) }
                Button(tr("Pin to right edge", "Fixar na lateral direita")) { model.pin(.right) }
                if Settings.pinSide != nil {
                    Divider()
                    Button(tr("Unpin", "Desafixar")) { model.pin(nil) }
                }
            } label: {
                Image(systemName: Settings.pinSide == nil ? "pin" : "pin.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("Pin to screen edge", "Fixar na lateral da tela"))

            Button(action: model.openActivityMonitor) { Image(systemName: "waveform.path.ecg") }
                .help(tr("Open Activity Monitor", "Abrir Monitor de Atividade"))
            Button(action: model.cycleAppearance) { Image(systemName: Settings.appearance.symbol) }
                .help(tr("Appearance: ", "Aparência: ") + Settings.appearance.title)
            Button { model.showSettings.toggle() } label: {
                Image(systemName: model.showSettings ? "gearshape.fill" : "gearshape")
            }
            .help(tr("Settings", "Configurações"))
            Button(action: model.quit) { Image(systemName: "power") }
                .help(tr("Quit Sysbar", "Sair do Sysbar"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Menu bar icon", "Ícone na barra de menus"))
                .font(.system(size: 12, weight: .bold))
            Text(tr("Top to bottom = left to right. Use the arrows to reorder.",
                    "De cima para baixo = da esquerda para a direita. Use as setas para reordenar."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let order = Settings.order
            ForEach(Array(order.enumerated()), id: \.element) { index, metric in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Toggle(metric.title, isOn: model.metricShown(metric))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 4)
                        Button { model.moveMetric(metric, by: -1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .help(tr("Move left in the menu bar", "Mover para a esquerda na barra de menus"))
                        Button { model.moveMetric(metric, by: 1) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == order.count - 1)
                        .help(tr("Move right in the menu bar", "Mover para a direita na barra de menus"))
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 6) {
                        Picker("", selection: model.metricStyle(metric)) {
                            ForEach(metric.styles) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        Picker("", selection: model.metricColor(metric)) {
                            ForEach(IconColorMode.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }
                    .controlSize(.small)
                    .padding(.leading, 20)
                    .disabled(!Settings.metrics.contains(metric))
                }
            }
            Toggle(tr("Show label (CPU, GPU, RAM…)", "Mostrar rótulo (CPU, GPU, RAM…)"), isOn: model.showLabel)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            Divider()
            Text(tr("General", "Geral")).font(.system(size: 12, weight: .bold))
            LabeledContent(tr("Refresh", "Atualização")) {
                Picker("", selection: model.interval) {
                    ForEach(Settings.intervals, id: \.self) { v in
                        Text(v < 1 ? "\(Int(v * 1000)) ms" : "\(Int(v)) s").tag(v)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            LabeledContent(tr("Language", "Idioma")) {
                Picker("", selection: model.language) {
                    ForEach(Language.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            LabeledContent(tr("Appearance", "Aparência")) {
                Picker("", selection: model.appearance) {
                    ForEach(AppAppearance.allCases) { Image(systemName: $0.symbol).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            Toggle(tr("Open at login", "Abrir ao iniciar sessão"), isOn: LoginItem.binding(model))
                .toggleStyle(.checkbox)

            Divider()
            Text(tr("Updates", "Atualizações")).font(.system(size: 12, weight: .bold))
            Toggle(tr("Check for updates automatically", "Verificar atualizações automaticamente"),
                   isOn: model.autoCheckUpdates)
                .toggleStyle(.checkbox)
            HStack {
                Text(tr("Version ", "Versão ") + UpdateChecker.currentVersion)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(tr("Check for Updates…", "Verificar atualizações…")) { model.checkForUpdates() }
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(14)
        .frame(width: panelWidth, alignment: .leading)
    }
}
