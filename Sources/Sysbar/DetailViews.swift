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
    @ObservedObject var model: AppModel
    let kind: SystemStatKind

    var body: some View {
        let pinned = model.pinnedDetails.contains(kind)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(kind.detailTitle).font(.system(size: 13, weight: .bold))
                Spacer()
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
        .id(model.revision)
    }
}

// MARK: - CPU

private struct CPUDetail: View {
    @ObservedObject var model: AppModel

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
    @ObservedObject var model: AppModel

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

private struct MemoryDetail: View {
    @ObservedObject var model: AppModel

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
    @ObservedObject var model: AppModel

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 8) {
            if let d = s.disk {
                MeterRow(label: d.name,
                         value: "\(bytes(d.usedBytes)) / \(bytes(d.totalBytes))",
                         fraction: d.usedFraction, color: blue)
                InfoRow(label: tr("Free", "Livre"), value: bytes(d.freeBytes))
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

// MARK: - Network

private struct NetworkDetail: View {
    @ObservedObject var model: AppModel

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
    @ObservedObject var model: AppModel

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
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(metric == .memory ? Color(nsColor: MemoryPalette.app) : blue)
                                .frame(width: max(2, geo.size.width * CGFloat(min(1, fraction))))
                        }
                    }
                    .frame(width: 60, height: 5)
                    Text(metric == .memory ? bytes(row.memoryBytes)
                                           : String(format: "%.1f%%", row.cpu * 100))
                        .font(.system(size: 11.5).monospacedDigit())
                        .frame(width: 70, alignment: .trailing)
                }
            }
        }
    }
}
