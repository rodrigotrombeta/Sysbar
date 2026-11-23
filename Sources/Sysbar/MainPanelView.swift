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
    /// The screen-edge panel shows the per-section pin and Mute mode buttons.
    var showsMute = false
}

struct MainPanelView: View {
    let model: AppModel
    let context: PanelContext
    @State private var contentHeight: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(model: model, showsMute: context.showsMute)
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
    }

    private var sections: some View {
        VStack(spacing: 0) {
            let order = Settings.sectionOrder
            ForEach(Array(order.enumerated()), id: \.element) { index, kind in
                if index > 0 { SectionRule() }
                SectionHost(model: model, kind: kind, context: context,
                            index: index)
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
/// pinned, and pins/unpins the details on click. Drag its title row up or
/// down to move it.
private struct SectionHost: View {
    let model: AppModel
    let kind: SystemStatKind
    let context: PanelContext
    let index: Int
    @State private var dropTargeted = false

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
        .overlay(alignment: .top) { dragHandle }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                if context.showsMute {
                    // Edge-pinned panel: explicit button to keep the details open.
                    Button { context.onTapSection(kind) } label: {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(pinned ? Color.accentColor : Color.secondary.opacity(0.5))
                            .frame(width: 14, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(pinned ? tr("Unpin details", "Desafixar detalhes")
                                 : tr("Keep these details open", "Manter estes detalhes abertos"))
                    let muted = Settings.isMuted(kind)
                    Button { model.toggleMute(kind) } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(muted ? Color.accentColor : Color.secondary.opacity(0.5))
                            .frame(width: 14, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(muted ? tr("Unmute: show details on hover", "Reativar: mostrar detalhes ao passar o mouse")
                                : tr("Mute: don't show details on hover", "Silenciar: não mostrar detalhes ao passar o mouse"))
                }
                // The edge panel has its own pin button, so << stays a hint.
                let pinBadge = pinned && !context.showsMute
                Image(systemName: pinBadge ? "pin.fill" : "chevron.left.2")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(pinBadge ? Color.accentColor : Color.secondary.opacity(0.5))
                    .help(tr("Hover for details · click to keep them open",
                             "Passe o mouse para ver detalhes · clique para fixá-los"))
            }
            .padding(.top, 9)
            .padding(.trailing, 12)
        }
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(pinned ? Color.accentColor.opacity(0.08) : Color.clear)
            .padding(.horizontal, 4))
        .overlay {
            // A dragged section dropped here takes this section's place.
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { context.onTapSection(kind) }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = SystemStatKind(rawValue: raw),
                  dragged != kind else { return false }
            model.moveSection(dragged, to: index)
            return true
        } isTargeted: { dropTargeted = $0 }
        .background(GeometryReader { geo in
            Color.clear.preference(key: SectionFramesKey.self, value: [kind: geo.frame(in: .global)])
        })
    }

    /// The title row of the section: hold and drag it up or down.
    private var dragHandle: some View {
        Color.clear
            .frame(height: 30)
            .contentShape(Rectangle())
            .draggable(kind.rawValue) {
                Text(kind.detailTitle.uppercased())
                    .font(.system(size: StatsTheme.caption, weight: .bold))
                    .kerning(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .help(tr("Drag to move this section up or down",
                     "Arraste para mover esta seção para cima ou para baixo"))
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
            ProcessList(rows: rows, metric: .memory, total: total, compact: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: panelWidth)
    }
}

// MARK: - Header

private struct PanelHeader: View {
    let model: AppModel
    let showsMute: Bool

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

            if showsMute {
                let allMuted = Settings.allMuted
                Button(action: model.toggleMuteAll) {
                    Image(systemName: allMuted ? "speaker.slash.fill" : "speaker.slash")
                        .foregroundStyle(allMuted ? Color.accentColor : Color.primary)
                }
                .help(allMuted ? tr("Unmute all: show details on hover", "Reativar tudo: mostrar detalhes ao passar o mouse")
                               : tr("Mute all: don't show details on hover", "Silenciar tudo: não mostrar detalhes ao passar o mouse"))
            }
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

/// One metric in the "Menu bar icon" list: shown toggle, style and color
/// pickers, and a ≡ handle to drag it to another place in the order.
private struct MetricSettingsRow: View {
    let model: AppModel
    let metric: IconMetric
    let index: Int
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Toggle(metric.title, isOn: model.metricShown(metric))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 18)
                    .contentShape(Rectangle())
                    .draggable(metric.rawValue) {
                        Text(metric.title)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .onHover { inside in
                        if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                    }
                    .help(tr("Drag to reorder", "Arraste para reordenar"))
            }
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
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(targeted ? Color.accentColor.opacity(0.15) : Color.clear)
            .padding(.horizontal, -4))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = IconMetric(rawValue: raw),
                  dragged != metric else { return false }
            model.moveMetric(dragged, to: index)
            return true
        } isTargeted: { targeted = $0 }
    }
}

private struct SettingsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Menu bar icon", "Ícone na barra de menus"))
                .font(.system(size: 12, weight: .bold))
            Text(tr("Top to bottom = left to right. Drag ≡ to reorder.",
                    "De cima para baixo = da esquerda para a direita. Arraste ≡ para reordenar."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let order = Settings.order
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(order.enumerated()), id: \.element) { index, metric in
                    MetricSettingsRow(model: model, metric: metric, index: index)
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
        .onAppear { LoginItem.refresh() }
    }
}
