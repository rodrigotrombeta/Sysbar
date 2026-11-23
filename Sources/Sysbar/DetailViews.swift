// Detailed metrics shown beside the main panel when hovering a section
// (and kept open when the section is clicked).

import SwiftUI

let detailWidth: CGFloat = 400

private let blue = Color(nsColor: .systemBlue)
private let red = Color(nsColor: .systemRed)
private let green = Color(nsColor: .systemGreen)
private let orange = Color(nsColor: .systemOrange)
private let cyan = Color(nsColor: .systemCyan)

private func pct(_ v: Double?) -> String { StatsFormat.percent(v) }
private func rate(_ v: Double) -> String { SystemStatsSampler.formatRate(v) }
private func bytes(_ v: UInt64) -> String { SystemStatsSampler.formatBytes(v) }

extension SystemStatKind {
    var detailTitle: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return tr("Memory", "Memória")
        case .disk: return tr("Disk", "Disco")
        case .network: return tr("Network", "Rede")
        case .processes: return tr("Top processes", "Processos")
        }
    }
}

/// Window content for one detail panel: header with pin/close + body.
struct DetailContainer: View {
    let model: AppModel
    let kind: SystemStatKind

    var body: some View {
        let pinned = model.pinnedDetails.contains(kind)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(kind.detailTitle).font(.system(size: 13, weight: .bold))
                Spacer()
                if pinned { OpacityButton(model: model, key: kind.rawValue) }
                Button { model.toggleDetailPin(kind) } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }
                .help(pinned ? tr("Unpin details", "Desafixar detalhes")
                             : tr("Keep these details open", "Manter estes detalhes abertos"))
                if pinned {
                    Button { model.closeDetail(kind) } label: { Image(systemName: "xmark") }
                        .help(tr("Close", "Fechar"))
                }
            }
            .buttonStyle(.borderless)
            // Drag the title row to move the panel anywhere; moving a hover
            // preview pins it, so it stays where it was dropped.
            .background(WindowDragArea {
                if !model.pinnedDetails.contains(kind) { model.toggleDetailPin(kind) }
            }
            .help(tr("Drag to move", "Arraste para mover")))

            switch kind {
            case .cpu: CPUDetail(model: model)
            case .gpu: GPUDetail(model: model)
            case .memory: MemoryDetail(model: model)
            case .disk: DiskDetail(model: model)
            case .network: NetworkDetail(model: model)
            case .processes: ProcessesDetail(model: model)
            }
        }
        .padding(14)
        .frame(width: detailWidth, alignment: .leading)
    }
}

// MARK: - CPU

private struct CPUDetail: View {
    @Bindable var model: AppModel

    var body: some View {
        let s = model.snapshot
        let cores = s.coreUsage.count
        let e = s.eCoreCount
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(s.cpuName) · \(cores) \(tr("cores", "núcleos")) (\(e)E + \(cores - e)P)")
                    .font(.system(size: 13))
                Spacer()
                Text(pct(s.cpuTotalUsage)).font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            Grid(horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    MeterRow(label: tr("User", "Usuário"), value: pct(s.cpuUser),
                             fraction: s.cpuUser ?? 0, color: blue)
                    MeterRow(label: tr("System", "Sistema"), value: pct(s.cpuSystem),
                             fraction: s.cpuSystem ?? 0, color: red)
                }
                GridRow {
                    MeterRow(label: "E-cores", value: pct(s.eCoreUsage),
                             fraction: s.eCoreUsage ?? 0, color: orange)
                    MeterRow(label: "P-cores", value: pct(s.pCoreUsage),
                             fraction: s.pCoreUsage ?? 0, color: blue)
                }
            }
            SectionTitle(text: tr("CPU utilization history", "Histórico de uso da CPU"))
            HistoryChart(series: [.init(values: s.eHistory, color: orange),
                                  .init(values: s.pHistory, color: blue)])
            InfoRow(label: tr("Load avg", "Carga média"),
                    value: SystemStatsSampler.formatLoadAverages(s.loadAverages))
            InfoRow(label: tr("Thermal", "Térmico"), value: StatsFormat.thermal(s.thermalState))
            InfoRow(label: tr("Uptime", "Tempo ligado"), value: SystemStatsSampler.formatUptime(s.uptimeSeconds))

            SectionTitle(text: tr("Top processes (CPU)", "Processos (CPU)"))
            ProcessList(rows: Array(model.processes.topCPU.prefix(5)), metric: .cpu,
                        total: s.memory.totalBytes)

            DisclosureGroup(isExpanded: $model.expandedCores) {
                VStack(spacing: 4) {
                    ForEach(s.coreUsage.indices, id: \.self) { i in
                        let isE = i < e
                        HStack(spacing: 8) {
                            Text(isE ? "E\(i + 1)" : "P\(i - e + 1)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .frame(width: 26, alignment: .leading)
                            MiniChart(values: i < s.coreHistory.count ? s.coreHistory[i] : [],
                                      color: isE ? orange : blue)
                                .frame(height: 18)
                            Text(pct(s.coreUsage[i]))
                                .font(.system(size: 11).monospacedDigit())
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text(tr("Per core (\(cores))", "Por núcleo (\(cores))"))
                    .font(.system(size: 12, weight: .semibold))
            }
        }
    }
}

// MARK: - GPU

private struct GPUDetail: View {
    @Bindable var model: AppModel

    var body: some View {
        let s = model.snapshot
        let gpu = s.gpuDevices.first
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(gpu.map { "\($0.name)" + ($0.cores > 0 ? " (\($0.cores) \(tr("cores", "núcleos")))" : "") } ?? "GPU")
                    .font(.system(size: 13))
                Spacer()
                Text(pct(s.gpuUsage)).font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            Grid(horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    MeterRow(label: tr("GPU utilization", "Uso da GPU"), value: pct(gpu?.usage),
                             fraction: gpu?.usage ?? 0, color: green)
                    MeterRow(label: tr("Memory in use", "Memória em uso"),
                             value: gpu?.inUseBytes.map(bytes) ?? "–",
                             fraction: s.gpuMemoryFraction ?? 0, color: cyan)
                }
                GridRow {
                    MeterRow(label: tr("Renderer", "Renderer"), value: pct(gpu?.renderer),
                             fraction: gpu?.renderer ?? 0, color: blue)
                    MeterRow(label: tr("Tiler", "Tiler"), value: pct(gpu?.tiler),
                             fraction: gpu?.tiler ?? 0, color: blue)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    SectionTitle(text: tr("GPU utilization", "Uso da GPU"))
                    SectionTitle(text: tr("GPU memory", "Memória da GPU"))
                }
                GridRow {
                    HistoryChart(series: [.init(values: s.gpuHistory, color: green)], height: 64)
                    HistoryChart(series: [.init(values: s.gpuMemoryHistory, color: cyan)], height: 64)
                }
                GridRow {
                    SectionTitle(text: tr("Renderer", "Renderer"))
                    SectionTitle(text: tr("Tiler", "Tiler"))
                }
                GridRow {
                    HistoryChart(series: [.init(values: s.gpuRendererHistory, color: blue)], height: 64)
                    HistoryChart(series: [.init(values: s.gpuTilerHistory, color: blue)], height: 64)
                }
            }

            DisclosureGroup(isExpanded: $model.expandedGPUs) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(s.gpuDevices.indices, id: \.self) { i in
                        let d = s.gpuDevices[i]
                        HStack(spacing: 8) {
                            Text(d.name).font(.system(size: 11, weight: .medium))
                                .frame(width: 90, alignment: .leading)
                            MiniChart(values: i < s.gpuDeviceHistory.count ? s.gpuDeviceHistory[i] : [],
                                      color: green)
                                .frame(height: 22)
                            Text(pct(d.usage)).font(.system(size: 11).monospacedDigit())
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                    Text(tr("macOS only reports utilization per GPU device, not per GPU core; ANE usage and FPS aren't available through public APIs.",
                            "O macOS só informa o uso por GPU (dispositivo), não por núcleo da GPU; uso do ANE e FPS não estão disponíveis em APIs públicas."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } label: {
                Text(tr("Per GPU (\(s.gpuDevices.count))", "Por GPU (\(s.gpuDevices.count))"))
                    .font(.system(size: 12, weight: .semibold))
            }
        }
    }
}

// MARK: - Memory

private let appColor = Color(nsColor: MemoryPalette.app)
private let wiredColor = Color(nsColor: MemoryPalette.wired)
private let compressedColor = Color(nsColor: MemoryPalette.compressed)

private func average(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

private struct MemoryDetail: View {
    let model: AppModel

    var body: some View {
        let s = model.snapshot
        let m = s.memory
        let total = Double(max(1, m.totalBytes))
        let pressure: (String, Color) = {
            switch s.memoryPressure {
            case 4: return (tr("Critical", "Crítica"), red)
            case 2: return (tr("Warning", "Alerta"), orange)
            default: return (tr("Normal", "Normal"), green)
            }
        }()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(StatsFormat.gib(m.usedBytes)) / \(StatsFormat.wholeGiB(m.totalBytes)) GB")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Spacer()
                Text(tr("Pressure: ", "Pressão: ")).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(pressure.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(pressure.1)
            }
            Grid(horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    MeterRow(label: "App", value: StatsFormat.gib(m.appBytes) + " GB",
                             fraction: Double(m.appBytes) / total, color: Color(nsColor: MemoryPalette.app))
                    MeterRow(label: tr("Wired", "Fixa"), value: StatsFormat.gib(m.wiredBytes) + " GB",
                             fraction: Double(m.wiredBytes) / total, color: Color(nsColor: MemoryPalette.wired))
                }
                GridRow {
                    MeterRow(label: tr("Compressed", "Comprimida"), value: StatsFormat.gib(m.compressedBytes) + " GB",
                             fraction: Double(m.compressedBytes) / total, color: Color(nsColor: MemoryPalette.compressed))
                    MeterRow(label: "Swap",
                             value: StatsFormat.gib(m.swapUsedBytes) + " / " + StatsFormat.gib(m.swapTotalBytes) + " GB",
                             fraction: m.swapTotalBytes > 0 ? Double(m.swapUsedBytes) / Double(m.swapTotalBytes) : 0,
                             color: red)
                }
            }
            SectionTitle(text: tr("Memory by type", "Memória por tipo"))
            HStack(spacing: 10) {
                LegendDot(color: appColor, label: "App")
                LegendDot(color: wiredColor, label: tr("Wired", "Fixa"))
                LegendDot(color: compressedColor, label: tr("Compressed", "Comprimida"))
                LegendDot(color: red, label: "Swap")
                LegendDot(color: Color.primary.opacity(0.12), label: tr("Free", "Livre"))
            }
            // Stacked, as % of physical memory: smallest type at the bottom,
            // largest on top; each color fills from the layer below up to its
            // line, and the space above the top line is free memory.
            let layers = [StackedHistoryChart.Layer(values: s.memoryAppHistory, color: appColor),
                          .init(values: s.memoryWiredHistory, color: wiredColor),
                          .init(values: s.memoryCompressedHistory, color: compressedColor),
                          .init(values: s.memorySwapHistory, color: red)]
                .map { StackedHistoryChart.Layer(values: $0.values.map { $0 / total }, color: $0.color) }
                .sorted { average($0.values) < average($1.values) }
            let peak = (0..<(layers.map(\.values.count).min() ?? 0))
                .map { i in layers.reduce(0) { $0 + $1.values[$1.values.count - 1 - i] } }.max() ?? 0
            StackedHistoryChart(layers: layers, top: max(1, peak * 1.05),
                                label: { "\(Int(($0 * 100).rounded()))%" })
            SectionTitle(text: tr("Memory usage history", "Histórico de uso da memória"))
            HistoryChart(series: [.init(values: s.memoryHistory, color: Color(nsColor: .systemPurple))])
            SectionTitle(text: tr("Page in (blue) / out (red)", "Paginação entrada (azul) / saída (vermelho)"))
            HistoryChart(series: [.init(values: s.memoryInHistory, color: blue),
                                  .init(values: s.memoryOutHistory, color: red)],
                         maxValue: nil, minimumMax: 1_000_000, label: { rate($0) }, height: 60)
            SectionTitle(text: tr("Top processes (memory)", "Processos (memória)"))
            ProcessList(rows: Array(model.processes.topMemory.prefix(10)), metric: .memory,
                        total: m.totalBytes)
        }
    }
}

// MARK: - Disk

private struct DiskDetail: View {
    let model: AppModel
    @AppStorage("diskChartStyle") private var style = "pie"
    @AppStorage("diskPieDetailed") private var detailed = false

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $style) {
                Text(tr("Pie", "Pizza")).tag("pie")
                Text(tr("Progress", "Barra")).tag("progress")
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()

            if let d = s.disk {
                if style == "pie" {
                    DiskPie(model: model, disk: d, detailed: $detailed)
                } else {
                    MeterRow(label: d.name,
                             value: "\(bytes(d.usedBytes)) / \(bytes(d.totalBytes))",
                             fraction: d.usedFraction, color: blue)
                    InfoRow(label: tr("Free", "Livre"), value: bytes(d.freeBytes))
                }
            }
            Grid(horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    InfoRow(label: tr("Read", "Leitura"), value: rate(s.diskIO?.read ?? 0), valueColor: blue)
                    InfoRow(label: tr("Write", "Escrita"), value: rate(s.diskIO?.write ?? 0), valueColor: red)
                }
                GridRow {
                    InfoRow(label: tr("Read since boot", "Lido desde o boot"), value: bytes(s.diskTotalRead))
                    InfoRow(label: tr("Written since boot", "Gravado desde o boot"), value: bytes(s.diskTotalWritten))
                }
            }
            SectionTitle(text: tr("Read (blue) / Write (red)", "Leitura (azul) / Escrita (vermelho)"))
            HistoryChart(series: [.init(values: s.diskReadHistory, color: blue),
                                  .init(values: s.diskWriteHistory, color: red)],
                         maxValue: nil, minimumMax: 1_000_000, label: { rate($0) })
        }
    }
}

/// Disk usage donut: Used / Free, or (Detailed) macOS, apps, swap, other,
/// purgeable and free, measured on demand.
private struct DiskPie: View {
    let model: AppModel
    let disk: SystemStatsSnapshot.Disk
    @Binding var detailed: Bool

    private struct Item {
        var label: String
        var value: UInt64
        var color: Color
    }

    private static let freeColor = Color.primary.opacity(0.12)

    var body: some View {
        let items = detailed ? (model.diskBreakdown.map(Self.detailedItems) ?? []) : simpleItems
        let total = Double(detailed ? (model.diskBreakdown?.total ?? disk.totalBytes) : disk.totalBytes)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(disk.name).font(.system(size: 12))
                Spacer()
                Text("\(bytes(disk.usedBytes)) / \(bytes(disk.totalBytes))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    DonutChart(slices: items.map { .init(value: Double($0.value), color: $0.color) },
                               total: total)
                    VStack(spacing: 0) {
                        Text("\(Int((disk.usedFraction * 100).rounded()))%")
                            .font(.system(size: 18, weight: .semibold).monospacedDigit())
                        Text(tr("used", "usado")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 118, height: 118)

                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $detailed) {
                        Text(tr("Simple", "Simples")).tag(false)
                        Text(tr("Detailed", "Detalhado")).tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()

                    if detailed && model.diskBreakdown == nil {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(tr("Calculating…", "Calculando…"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(items.indices, id: \.self) { i in
                            let item = items[i]
                            GridRow {
                                LegendDot(color: item.color, label: item.label)
                                Text("\(Int((Double(item.value) / max(1, total) * 100).rounded()))%")
                                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(bytes(item.value))
                                    .font(.system(size: 11).monospacedDigit())
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                    }
                    if detailed, let b = model.diskBreakdown {
                        HStack(spacing: 4) {
                            Text(model.measuringDisk ? tr("Calculating…", "Calculando…")
                                 : tr("Measured at ", "Medido às ")
                                    + b.measuredAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Button { model.measureDisk() } label: {
                                Image(systemName: "arrow.clockwise").font(.system(size: 10))
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.measuringDisk)
                            .help(tr("Measure again", "Medir de novo"))
                        }
                        Toggle(tr("Show in menu bar icon", "Mostrar no ícone da barra"),
                               isOn: model.diskDetailedInIcon)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                            .help(tr("The Disk pie/bar in the menu bar shows these categories for an hour after each measurement, then used vs free again.",
                                     "A pizza/barra de Disco na barra de menus mostra estas categorias por uma hora após cada medição; depois volta a usado vs livre."))
                        if Settings.diskDetailedInIcon && !b.isFresh {
                            Text(tr("Older than 1 hour: the icon shows used vs free. Measure again to update.",
                                    "Mais de 1 hora: o ícone mostra usado vs livre. Meça de novo para atualizar."))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .onAppear { if detailed && model.diskBreakdown == nil { model.measureDisk() } }
        .onChange(of: detailed) { _, on in if on && model.diskBreakdown == nil { model.measureDisk() } }
    }

    private var simpleItems: [Item] {
        [Item(label: tr("Used", "Usado"), value: disk.usedBytes, color: blue),
         Item(label: tr("Free", "Livre"), value: disk.freeBytes, color: Self.freeColor)]
    }

    private static func detailedItems(_ b: DiskBreakdown) -> [Item] {
        [Item(label: "macOS", value: b.system, color: Color(nsColor: DiskPalette.system)),
         Item(label: tr("Apps", "Apps"), value: b.applications, color: Color(nsColor: DiskPalette.apps)),
         Item(label: "Swap", value: b.swap, color: Color(nsColor: DiskPalette.swap)),
         Item(label: tr("Files & other", "Arquivos e outros"), value: b.other, color: Color(nsColor: DiskPalette.other)),
         Item(label: tr("Purgeable", "Liberável"), value: b.purgeable, color: Color(nsColor: DiskPalette.purgeable)),
         Item(label: tr("Free", "Livre"), value: b.free, color: freeColor)]
    }
}

// MARK: - Network

private struct NetworkDetail: View {
    let model: AppModel

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    InfoRow(label: "↓ Download", value: rate(s.networkIO?.read ?? 0), valueColor: blue)
                    InfoRow(label: "↑ Upload", value: rate(s.networkIO?.write ?? 0), valueColor: red)
                }
                GridRow {
                    InfoRow(label: tr("Peak ↓", "Pico ↓"), value: rate(s.networkInHistory.max() ?? 0))
                    InfoRow(label: tr("Peak ↑", "Pico ↑"), value: rate(s.networkOutHistory.max() ?? 0))
                }
                GridRow {
                    InfoRow(label: "Interface", value: s.networkInterface ?? "–")
                    InfoRow(label: "IP", value: s.networkAddress ?? tr("Offline", "Desconectado"))
                }
            }
            SectionTitle(text: tr("Download (blue) / Upload (red)", "Download (azul) / Upload (vermelho)"))
            HistoryChart(series: [.init(values: s.networkInHistory, color: blue),
                                  .init(values: s.networkOutHistory, color: red)],
                         maxValue: nil, minimumMax: 100_000, label: { rate($0) })
        }
    }
}

// MARK: - Processes

private struct ProcessesDetail: View {
    let model: AppModel

    var body: some View {
        let total = model.snapshot.memory.totalBytes
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: tr("Memory", "Memória"))
            ProcessList(rows: Array(model.processes.topMemory.prefix(15)), metric: .memory, total: total)
            SectionTitle(text: "CPU")
            ProcessList(rows: Array(model.processes.topCPU.prefix(10)), metric: .cpu, total: total)
            Text(tr("Processes of other users (e.g. WindowServer) need admin rights and aren't listed.",
                    "Processos de outros usuários (ex.: WindowServer) exigem permissão de administrador e não aparecem."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum ProcessMetric { case memory, cpu }

/// Name · bar · value rows.
struct ProcessList: View {
    let rows: [ProcessRow]
    let metric: ProcessMetric
    let total: UInt64
    /// Narrow main panel: no bar, so names have room next to two columns.
    var compact = false

    var body: some View {
        VStack(spacing: 4) {
            if rows.isEmpty {
                Text("…").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            // Bars are relative to the largest row, so differences are visible.
            let maxMemory = Double(rows.map(\.memoryBytes).max() ?? 1)
            let maxCPU = max(0.01, rows.map(\.cpu).max() ?? 0)
            ForEach(rows) { row in
                let fraction = metric == .memory
                    ? Double(row.memoryBytes) / max(1, maxMemory)
                    : row.cpu / maxCPU
                HStack(spacing: 8) {
                    Text(row.name).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if !compact {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule().fill(metric == .memory ? Color(nsColor: MemoryPalette.app) : blue)
                                    .frame(width: max(2, geo.size.width * CGFloat(min(1, fraction))))
                            }
                        }
                        .frame(width: 60, height: 5)
                    }
                    Text(metric == .memory ? bytes(row.memoryBytes)
                                           : String(format: "%.1f%%", row.cpu * 100))
                        .font(.system(size: 11.5).monospacedDigit())
                        .frame(width: metric == .memory ? 62 : 70, alignment: .trailing)
                    if metric == .memory {
                        // Share of physical memory (RAM).
                        Text(String(format: "%.1f%%", Double(row.memoryBytes) / Double(max(1, total)) * 100))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                            .help(tr("Share of total RAM", "Parcela do total de RAM"))
                    }
                }
            }
        }
    }
}

/// Moves its window when dragged (for borderless panels, which have no
/// title bar). `onDragStart` runs once per drag, before the window moves.
struct WindowDragArea: NSViewRepresentable {
    var onDragStart: () -> Void = {}

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onDragStart = onDragStart
        return view
    }

    func updateNSView(_ view: DragView, context: Context) { view.onDragStart = onDragStart }

    final class DragView: NSView {
        var onDragStart: () -> Void = {}
        private var mouseDownEvent: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownEvent, let window else { return }
            mouseDownEvent = nil
            onDragStart()
            window.performDrag(with: start)
        }

        override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }
    }
}

/// Header button of a pinned panel: opens a slider for that panel's opacity.
struct OpacityButton: View {
    let model: AppModel
    let key: String
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "circle.righthalf.filled") }
            .buttonStyle(.borderless)
            .help(tr("Opacity of this panel", "Opacidade deste painel"))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(tr("Opacity", "Opacidade")).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(Int((Settings.opacity(for: key) * 100).rounded()))%")
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: model.opacity(for: key), in: 0.3...1, step: 0.05)
                        .controlSize(.small)
                        .frame(width: 170)
                    Button(tr("Use the default (Settings)", "Usar o padrão (Configurações)")) {
                        model.resetOpacity(for: key)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                .padding(12)
            }
    }
}
