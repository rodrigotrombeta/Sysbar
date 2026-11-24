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
                .controlsLayer()
            Divider().padding(.horizontal, 10)
            ScrollView(.vertical, showsIndicators: contentHeight > model.maxPanelHeight) {
                Group {
                    if model.showSettings {
                        SettingsView(model: model)
                            .unfaded()
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
        // "Pin full": the edge window spans the screen height; keep the
        // content at the top.
        .frame(maxHeight: context.showsMute && Settings.pinFull ? .infinity : nil, alignment: .top)
        .panelOpacity()
        .onPreferenceChange(SectionFramesKey.self) { context.onSectionFrames($0) }
    }

    private var sections: some View {
        VStack(spacing: 0) {
            let order = Settings.sectionOrder
            let visible = order.filter(Settings.isOnDashboard)
            ForEach(visible, id: \.self) { kind in
                let index = order.firstIndex(of: kind) ?? 0
                if kind != visible.first { SectionRule() }
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
            case .claude: ClaudeStatsPanel(model: model)
            case .clock: ClockStatsPanel(model: model)
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
                            .textLayer()
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
                            .textLayer()
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
                    .textLayer()
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
                .textLayer()
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
                .fixedSize()
                .layoutPriority(1)
            Spacer(minLength: 4)
            PinButton(model: model)

            if showsMute {
                OpacityButton(model: model)
                let allMuted = Settings.allMuted
                Button(action: model.toggleMuteAll) {
                    Image(systemName: allMuted ? "speaker.slash.fill" : "speaker.slash")
                        .foregroundStyle(allMuted ? Color.accentColor : Color.primary)
                        .textLayer()
                }
                .help(allMuted ? tr("Unmute all: show details on hover", "Reativar tudo: mostrar detalhes ao passar o mouse")
                               : tr("Mute all: don't show details on hover", "Silenciar tudo: não mostrar detalhes ao passar o mouse"))
            }
            // The edge panel's header has the opacity and Mute all buttons
            // too; Activity Monitor stays in the menu bar panel only.
            if !showsMute {
                Button(action: model.openActivityMonitor) { Image(systemName: "waveform.path.ecg") }
                    .help(tr("Open Activity Monitor", "Abrir Monitor de Atividade"))
            }
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
            Text(tr("Dashboard", "Dashboard")).font(.system(size: 12, weight: .bold))
            Text(tr("Sections shown in the Sysbar panel (the menu bar icon is set above).",
                    "Seções mostradas no painel do Sysbar (o ícone da barra de menus é definido acima)."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 4) {
                ForEach(SystemStatKind.allCases, id: \.self) { kind in
                    Toggle(kind.detailTitle, isOn: model.onDashboard(kind))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }
            }
            ClockZonesEditor(model: model)

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
            LabeledContent(tr("Pinned panel", "Painel fixado")) {
                Picker("", selection: model.pinFull) {
                    Text(tr("Float", "Flutuante")).tag(false)
                    Text(tr("Full height", "Altura toda")).tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 170)
                .help(tr("Float: the pinned panel floats at its content height. Full height: it fills the whole side of the screen.",
                         "Flutuante: o painel fixado flutua com a altura do conteúdo. Altura toda: ocupa a lateral inteira da tela."))
            }
            TextColorRow(color: model.textColor)
            Text(tr("Opacity", "Opacidade")).font(.system(size: 12))
            OpacityControls(value: model.opacity)
                .padding(.leading, 8)
            Toggle(tr("Open at login", "Abrir ao iniciar sessão"), isOn: LoginItem.binding(model))
                .toggleStyle(.checkbox)

            Divider()
            ClaudeConnectionRow(model: model)
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

/// Header pin button: a small panel with "Pin to left/right edge" and,
/// beside each, Float / Full to pin in that style right away.
private struct PinButton: View {
    let model: AppModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: Settings.pinSide == nil ? "pin" : "pin.fill")
        }
        .buttonStyle(.borderless)
        .help(tr("Pin to screen edge", "Fixar na lateral da tela"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                row(tr("Pin to left edge", "Fixar na lateral esquerda"), .left)
                row(tr("Pin to right edge", "Fixar na lateral direita"), .right)
                if Settings.pinSide != nil {
                    Divider().gridCellColumns(2)
                    Button(tr("Unpin", "Desafixar")) { choose(nil, full: Settings.pinFull) }
                        .buttonStyle(.borderless)
                }
            }
            .font(.system(size: 12))
            .padding(12)
            // The popover is its own window: don't inherit the panel's fading.
            .foregroundStyle(Color.primary)
            .environment(\.textOpacity, 1)
            .environment(\.graphicsOpacity, 1)
        }
    }

    private func row(_ label: String, _ side: PinSide) -> some View {
        GridRow {
            Text(label)
            HStack(spacing: 4) {
                option(tr("Float", "Flutuante"), side: side, full: false)
                option(tr("Full", "Altura toda"), side: side, full: true)
            }
        }
    }

    private func option(_ title: String, side: PinSide, full: Bool) -> some View {
        let current = Settings.pinSide == side && Settings.pinFull == full
        return Button { choose(side, full: full) } label: {
            Text(title)
                .font(.system(size: 11, weight: current ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(current ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(full ? tr("The panel fills the whole side of the screen.", "O painel ocupa a lateral inteira da tela.")
                   : tr("The panel floats at its content height.", "O painel flutua com a altura do conteúdo."))
    }

    private func choose(_ side: PinSide?, full: Bool) {
        open = false
        Settings.pinFull = full
        model.pin(side)
    }
}

/// Text color of the panels: System, a few presets or any color.
private struct TextColorRow: View {
    @Binding var color: Color?

    private static let presets: [(String, Color)] = [
        ("White", .white), ("Black", .black),
        ("Green", Color(red: 0.35, green: 0.95, blue: 0.55)),
        ("Amber", Color(red: 1, green: 0.75, blue: 0.25)),
        ("Cyan", Color(red: 0.35, green: 0.85, blue: 1)),
        ("Pink", Color(red: 1, green: 0.5, blue: 0.8)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("Text color", "Cor do texto")).font(.system(size: 12))
            HStack(spacing: 6) {
                Button(tr("System", "Sistema")) { color = nil }
                    .controlSize(.small)
                    .fixedSize()
                    .buttonStyle(.bordered)
                    .tint(color == nil ? .accentColor : nil)
                ForEach(Self.presets, id: \.0) { name, preset in
                    Button { color = preset } label: {
                        Circle().fill(preset)
                            .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.5))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).padding(-3)
                                .opacity(matches(preset) ? 1 : 0))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
                Button { showWheel.toggle() } label: {
                    Image(systemName: showWheel ? "chevron.up.circle" : "paintpalette")
                }
                .buttonStyle(.borderless)
                .help(tr("Color wheel", "Roda de cores"))
            }
            if showWheel {
                ColorWheel(color: Binding(get: { color ?? .white }, set: { color = $0 }))
                    .padding(.top, 4)
            }
        }
    }

    @State private var showWheel = false

    private func matches(_ preset: Color) -> Bool {
        guard let color, let a = NSColor(color).usingColorSpace(.sRGB),
              let b = NSColor(preset).usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }
}

/// Hue/saturation wheel plus a brightness slider.
private struct ColorWheel: View {
    @Binding var color: Color
    private let size: CGFloat = 110

    var body: some View {
        let hsb = components
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(AngularGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
                        Color(hue: 1 - $0, saturation: 1, brightness: 1)
                    },
                    center: .center, angle: .degrees(0)))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)],
                                             center: .center, startRadius: 0, endRadius: size / 2))
                Circle().fill(Color.black.opacity(1 - hsb.b))
                Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5)
                // Current color marker.
                Circle().strokeBorder(Color.white, lineWidth: 2)
                    .background(Circle().fill(color))
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: cos(-hsb.h * 2 * .pi) * hsb.s * size / 2,
                            y: sin(-hsb.h * 2 * .pi) * hsb.s * size / 2)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { pick($0.location, brightness: hsb.b) })

            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Brightness", "Brilho")).font(.system(size: 11))
                Slider(value: Binding(get: { hsb.b },
                                      set: { color = Color(hue: hsb.h, saturation: hsb.s, brightness: $0) }),
                       in: 0.15...1)
                    .controlSize(.small).frame(width: 110)
            }
        }
    }

    private var components: (h: Double, s: Double, b: Double) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return (0, 0, 1) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }

    private func pick(_ point: CGPoint, brightness: Double) {
        let dx = point.x - size / 2, dy = point.y - size / 2
        let s = min(1, sqrt(dx * dx + dy * dy) / (size / 2))
        var hue = -atan2(dy, dx) / (2 * .pi)
        if hue < 0 { hue += 1 }
        color = Color(hue: hue, saturation: s, brightness: max(0.15, brightness))
    }
}

/// Where Sysbar gets Claude Code's limits: from Anthropic (automatic) and/or
/// from Claude Code's terminal status line.
private struct ClaudeConnectionRow: View {
    let model: AppModel
    @State private var connected = ClaudeUsageStore.isConnected()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude Code").font(.system(size: 12, weight: .bold))
            ClaudeBetaNote()
            Toggle(tr("Fetch limits from Anthropic (every 5 min)", "Buscar limites na Anthropic (a cada 5 min)"),
                   isOn: Binding(get: { Settings.claudeFetch },
                                 set: { Settings.claudeFetch = $0; if $0 { model.fetchClaude() } }))
                .toggleStyle(.checkbox)
            Text(tr("Uses Claude Code's login (macOS asks once to let Sysbar read it from the Keychain) to ask api.anthropic.com for the 5-hour and weekly limits, like /usage does. The login is never stored by Sysbar.",
                    "Usa o login do Claude Code (o macOS pede uma vez para o Sysbar lê-lo no Chaves) para consultar os limites de 5 horas e semanal em api.anthropic.com, como o /usage faz. O Sysbar não guarda o login."))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if Settings.claudeFetch {
                switch model.claudeFetchStatus {
                case .fetching: Text(tr("Fetching…", "Buscando…")).font(.system(size: 10.5))
                case .ok(let date):
                    Text(tr("Last fetched \(date.formatted(date: .omitted, time: .shortened))",
                            "Última busca \(date.formatted(date: .omitted, time: .shortened))"))
                        .font(.system(size: 10.5)).foregroundStyle(.green)
                case .failed(let message): Text(message).font(.system(size: 10.5)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                case .idle: EmptyView()
                }
            }
            HStack(spacing: 8) {
                Text(tr("Terminal status line:", "Linha de status do terminal:")).font(.system(size: 10.5))
                Button(connected ? tr("Disconnect", "Desconectar") : tr("Connect", "Conectar")) {
                    do {
                        try connected ? ClaudeUsageStore.disconnect() : ClaudeUsageStore.connect()
                        error = nil
                    } catch let e {
                        error = e.localizedDescription
                    }
                    connected = ClaudeUsageStore.isConnected()
                }
                .controlSize(.small)
                .help(tr("Also records the limits Claude Code passes to its status line when you use it in a terminal (changes statusLine in ~/.claude/settings.json; Disconnect restores it).",
                         "Também registra os limites que o Claude Code passa à linha de status quando usado no terminal (muda o statusLine em ~/.claude/settings.json; Desconectar restaura)."))
            }
            if let error {
                Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
            }
        }
        .onAppear { connected = ClaudeUsageStore.isConnected() }
    }
}
