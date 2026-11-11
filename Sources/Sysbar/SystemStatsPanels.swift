// Adapted from oMLX (https://github.com/jundot/omlx), apps/omlx-mac/Sources/
// Menubar/SystemStatsPanels.swift — Apache License 2.0. Changes: oMLX theme,
// design tokens and localization replaced by system colors/fonts; the
// sparkline (from MenubarMetricPopover.swift) is inlined below.
//
// The three panels inside the menubar's System Stats submenu: CPU, GPU,
// and Memory. Each is a value-driven SwiftUI view fed a SystemStatsSnapshot
// by MenubarController's sampling timer, hosted in an NSMenuItem custom
// view. Value-driven (no observation) so updates render synchronously even
// while the menu run loop is in tracking mode.

import SwiftUI

private let panelWidth: CGFloat = 270

// MARK: - CPU

struct CPUStatsPanel: View {
    let snapshot: SystemStatsSnapshot
    let refreshInterval: TimeInterval

    private let theme = StatsTheme()

    private var eColor: Color { Color(nsColor: .systemOrange) }
    private var pColor: Color { Color(nsColor: .systemBlue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatsPanelHeader(title: "CPU")
            UsageBarRow(
                label: tr("E-cores", "E-cores"),
                value: StatsFormat.percent(snapshot.eCoreUsage),
                fraction: snapshot.eCoreUsage ?? 0,
                color: eColor
            )
            UsageBarRow(
                label: tr("P-cores", "P-cores"),
                value: StatsFormat.percent(snapshot.pCoreUsage),
                fraction: snapshot.pCoreUsage ?? 0,
                color: pColor
            )
            StatsPanelCaption(
                text: tr("E (amber) / P (blue) usage", "Uso E (âmbar) / P (azul)"),
                window: StatsFormat.window(sampleCount: snapshot.eHistory.count,
                                           interval: refreshInterval)
            )
            ZStack {
                MetricSparkline(values: snapshot.pHistory, color: pColor,
                                height: 26, domain: 0...1)
                MetricSparkline(values: snapshot.eHistory, color: eColor,
                                height: 26, domain: 0...1)
            }
            Divider()
            StatsValueRow(
                label: tr("Thermal", "Térmico"),
                value: StatsFormat.thermal(snapshot.thermalState)
            )
            StatsValueRow(
                label: tr("Load avg", "Carga média"),
                value: SystemStatsSampler.formatLoadAverages(snapshot.loadAverages)
            )
            StatsValueRow(
                label: tr("Uptime", "Tempo ligado"),
                value: SystemStatsSampler.formatUptime(snapshot.uptimeSeconds)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: panelWidth)
    }
}

// MARK: - GPU

struct GPUStatsPanel: View {
    let snapshot: SystemStatsSnapshot
    let refreshInterval: TimeInterval

    private let theme = StatsTheme()

    private var gpuColor: Color { Color(nsColor: .systemGreen) }
    private var gpuMemColor: Color { Color(nsColor: .systemCyan) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatsPanelHeader(title: "GPU")
            UsageBarRow(
                label: "GPU",
                value: StatsFormat.percent(snapshot.gpuUsage),
                fraction: snapshot.gpuUsage ?? 0,
                color: gpuColor
            )
            UsageBarRow(
                label: tr("GPU memory", "Memória da GPU"),
                value: snapshot.gpuMemoryInUseBytes.map {
                    SystemStatsSampler.formatBytes($0) + tr(" in use", " em uso")
                } ?? "–",
                fraction: gpuMemoryFraction,
                color: gpuMemColor
            )
            StatsPanelCaption(
                text: tr("GPU (green) / GPU mem (cyan)", "GPU (verde) / mem. GPU (ciano)"),
                window: StatsFormat.window(sampleCount: snapshot.gpuHistory.count,
                                           interval: refreshInterval)
            )
            MetricSparkline(values: snapshot.gpuHistory, color: gpuColor,
                            height: 26, domain: 0...1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: panelWidth)
    }

    private var gpuMemoryFraction: Double {
        guard let inUse = snapshot.gpuMemoryInUseBytes,
              snapshot.memory.totalBytes > 0
        else {
            return 0
        }
        return min(1, Double(inUse) / Double(snapshot.memory.totalBytes))
    }
}

// MARK: - Memory

struct MemoryStatsPanel: View {
    let snapshot: SystemStatsSnapshot

    private let theme = StatsTheme()

    private var appColor: Color { Color(nsColor: MemoryPalette.app) }
    private var wiredColor: Color { Color(nsColor: MemoryPalette.wired) }
    private var compressedColor: Color { Color(nsColor: MemoryPalette.compressed) }

    var body: some View {
        let memory = snapshot.memory
        VStack(alignment: .leading, spacing: 6) {
            StatsPanelHeader(title: tr("Memory", "Memória"))
            HStack {
                Text("\(StatsFormat.gib(memory.usedBytes)) / \(StatsFormat.wholeGiB(memory.totalBytes)) GB")
                    .font(StatsTheme.mono(StatsTheme.callout, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                Text(StatsFormat.percent(memory.usedFraction))
                    .font(StatsTheme.mono(StatsTheme.callout))
                    .foregroundStyle(theme.textSecondary)
            }
            SegmentedUsageBar(
                total: memory.totalBytes,
                segments: [
                    (memory.appBytes, appColor),
                    (memory.wiredBytes, wiredColor),
                    (memory.compressedBytes, compressedColor),
                ]
            )
            legendRow(color: appColor,
                      label: tr("App", "Apps"),
                      bytes: memory.appBytes)
            legendRow(color: wiredColor,
                      label: tr("Wired", "Fixa"),
                      bytes: memory.wiredBytes)
            legendRow(color: compressedColor,
                      label: tr("Compressed", "Comprimida"),
                      bytes: memory.compressedBytes)
            legendRow(color: theme.textTertiary.opacity(0.4),
                      label: tr("Free", "Livre"),
                      bytes: memory.freeBytes)
            StatsValueRow(label: "Swap",
                          value: StatsFormat.gib(memory.swapUsedBytes) + " GB")
            StatsValueRow(
                label: tr("Page in / out", "Paginação E/S"),
                value: "\(SystemStatsSampler.formatRate(snapshot.memoryIO?.read)) · \(SystemStatsSampler.formatRate(snapshot.memoryIO?.write))"
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: panelWidth)
    }

    private func legendRow(color: Color, label: String, bytes: UInt64) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(StatsTheme.text(11.5))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Text(StatsFormat.gib(bytes) + " GB")
                .font(StatsTheme.mono(11.5))
                .foregroundStyle(theme.text)
        }
    }
}

// MARK: - Disk (Sysbar addition)

struct DiskStatsPanel: View {
    let snapshot: SystemStatsSnapshot
    let refreshInterval: TimeInterval

    private let theme = StatsTheme()
    private var usageColor: Color { Color(nsColor: .systemBlue) }
    private var readColor: Color { Color(nsColor: .systemBlue) }
    private var writeColor: Color { Color(nsColor: .systemRed) }

    var body: some View {
        let disk = snapshot.disk
        VStack(alignment: .leading, spacing: 6) {
            StatsPanelHeader(title: tr("Disk", "Disco"))
            UsageBarRow(
                label: disk?.name ?? tr("Disk", "Disco"),
                value: disk.map {
                    "\(Int((Double($0.usedBytes) / 1e9).rounded())) / \(Int((Double($0.totalBytes) / 1e9).rounded())) GB"
                } ?? "–",
                fraction: disk?.usedFraction ?? 0,
                color: usageColor
            )
            StatsValueRow(label: tr("Free", "Livre"),
                          value: disk.map { SystemStatsSampler.formatBytes($0.freeBytes) } ?? "–")
            StatsValueRow(label: tr("Read", "Leitura"),
                          value: SystemStatsSampler.formatRate(snapshot.diskIO?.read))
            StatsValueRow(label: tr("Write", "Escrita"),
                          value: SystemStatsSampler.formatRate(snapshot.diskIO?.write))
            StatsPanelCaption(
                text: tr("Read (blue) / Write (red)", "Leitura (azul) / Escrita (vermelho)"),
                window: StatsFormat.window(sampleCount: snapshot.diskReadHistory.count,
                                           interval: refreshInterval)
            )
            ZStack {
                MetricSparkline(values: snapshot.diskWriteHistory, color: writeColor,
                                height: 26, domain: 0...ioPeak)
                MetricSparkline(values: snapshot.diskReadHistory, color: readColor,
                                height: 26, domain: 0...ioPeak)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: panelWidth)
    }

    /// Shared Y scale for both series, never below 256 KB/s.
    private var ioPeak: Double {
        max(256_000, snapshot.diskReadHistory.max() ?? 0, snapshot.diskWriteHistory.max() ?? 0)
    }
}

// MARK: - Network (Sysbar addition)

struct NetworkStatsPanel: View {
    let snapshot: SystemStatsSnapshot
    let refreshInterval: TimeInterval

    private let theme = StatsTheme()
    private var downColor: Color { Color(nsColor: .systemBlue) }
    private var upColor: Color { Color(nsColor: .systemRed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatsPanelHeader(title: tr("Network", "Rede"))
            StatsValueRow(label: "↓ " + tr("Download", "Download"),
                          value: SystemStatsSampler.formatRate(snapshot.networkIO?.read))
            StatsValueRow(label: "↑ " + tr("Upload", "Upload"),
                          value: SystemStatsSampler.formatRate(snapshot.networkIO?.write))
            StatsValueRow(label: tr("Interface", "Interface"),
                          value: snapshot.networkInterface ?? "–")
            StatsValueRow(label: tr("IP address", "Endereço IP"),
                          value: snapshot.networkAddress ?? tr("Offline", "Desconectado"))
            StatsPanelCaption(
                text: tr("Download (blue) / Upload (red)", "Download (azul) / Upload (vermelho)"),
                window: StatsFormat.window(sampleCount: snapshot.networkInHistory.count,
                                           interval: refreshInterval)
            )
            ZStack {
                MetricSparkline(values: snapshot.networkOutHistory, color: upColor,
                                height: 26, domain: 0...peak)
                MetricSparkline(values: snapshot.networkInHistory, color: downColor,
                                height: 26, domain: 0...peak)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: panelWidth)
    }

    private var peak: Double {
        max(64_000, snapshot.networkInHistory.max() ?? 0, snapshot.networkOutHistory.max() ?? 0)
    }
}

// MARK: - Combined popover stack

/// The enabled panels stacked into one popover for the combined CPU/GPU/MEM
/// status item, separated like the System Stats submenu.
struct SystemStatsPanelStack: View {
    let kinds: [SystemStatKind]
    let snapshot: SystemStatsSnapshot
    let refreshInterval: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                if index > 0 {
                    SectionRule()
                }
                panel(for: kind)
            }
        }
        // Pin the stack to the panel width. Without this, any width-flexible
        // child (a divider) makes the hosting controller's fitting width
        // echo whatever the popover proposed — and a popover proposes its
        // default ~320 pt frame on first open, which then sticks, leaving a
        // dead right margin whenever two or more panels are stacked.
        .frame(width: panelWidth)
    }

    @ViewBuilder
    private func panel(for kind: SystemStatKind) -> some View {
        switch kind {
        case .cpu:
            CPUStatsPanel(snapshot: snapshot, refreshInterval: refreshInterval)
        case .gpu:
            GPUStatsPanel(snapshot: snapshot, refreshInterval: refreshInterval)
        case .memory:
            MemoryStatsPanel(snapshot: snapshot)
        case .disk:
            DiskStatsPanel(snapshot: snapshot, refreshInterval: refreshInterval)
        case .network:
            NetworkStatsPanel(snapshot: snapshot, refreshInterval: refreshInterval)
        }
    }
}

// MARK: - Shared pieces

/// Panel-width section rule (14 pt inset each side, like a padded Divider).
/// Both frames are fixed widths on purpose: a width-flexible child at the
/// stack level would let the hosting controller's fitting width track the
/// popover's proposed frame instead of the panel width.
struct SectionRule: View {
    var containerWidth: CGFloat = panelWidth
    private let theme = StatsTheme()

    var body: some View {
        Rectangle()
            .fill(theme.rowSep)
            .frame(width: containerWidth - 28, height: 1)
            .frame(width: containerWidth)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
    }
}

private struct StatsPanelHeader: View {
    let title: String
    private let theme = StatsTheme()

    var body: some View {
        Text(title.uppercased())
            .font(StatsTheme.text(StatsTheme.caption, weight: .bold))
            .kerning(1)
            .foregroundStyle(theme.accent)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct StatsPanelCaption: View {
    let text: String
    let window: String
    private let theme = StatsTheme()

    var body: some View {
        Text(window.isEmpty ? text : "\(text) · \(window)")
            .font(StatsTheme.text(9.5))
            .foregroundStyle(theme.textTertiary)
    }
}

private struct UsageBarRow: View {
    let label: String
    let value: String
    let fraction: Double
    let color: Color
    private let theme = StatsTheme()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(StatsTheme.text(StatsTheme.callout, weight: .medium))
                    .foregroundStyle(theme.text)
                Spacer()
                Text(value)
                    .font(StatsTheme.mono(StatsTheme.callout))
                    .foregroundStyle(theme.text)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.textTertiary.opacity(0.18))
                    Capsule()
                        .fill(color)
                        .frame(width: max(
                            4, geo.size.width * min(1, max(0, fraction))
                        ))
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StatsValueRow: View {
    let label: String
    let value: String
    private let theme = StatsTheme()

    var body: some View {
        HStack {
            Text(label)
                .font(StatsTheme.text(StatsTheme.callout))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Text(value)
                .font(StatsTheme.mono(StatsTheme.callout))
                .foregroundStyle(theme.text)
        }
    }
}

private struct SegmentedUsageBar: View {
    let total: UInt64
    let segments: [(bytes: UInt64, color: Color)]
    private let theme = StatsTheme()

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    let fraction = total > 0
                        ? Double(segment.bytes) / Double(total)
                        : 0
                    if fraction > 0.001 {
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                Spacer(minLength: 0)
            }
            .background(theme.textTertiary.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 9)
        .accessibilityHidden(true)
    }
}

// MARK: - Formatting helpers (pure, unit-tested)

enum StatsFormat {
    static func gib(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824.0)
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return tr("Nominal", "Normal")
        case .fair: return tr("Fair", "Razoável")
        case .serious: return tr("Serious", "Sério")
        case .critical: return tr("Critical", "Crítico")
        @unknown default: return tr("Critical", "Crítico")
        }
    }

    /// 0.153 → "15%"; nil → "–"
    static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "–" }
        return "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    /// 51_539_607_552 → "48" (whole binary GiB for physical memory totals)
    static func wholeGiB(_ bytes: UInt64) -> String {
        "\(Int((Double(bytes) / 1_073_741_824).rounded()))"
    }

    /// History window caption: 60 samples at 1 s → "60s"; at 0.5 s → "30s".
    /// Empty history → empty string (caption shows no window).
    static func window(sampleCount: Int, interval: TimeInterval) -> String {
        guard sampleCount > 1, interval > 0 else { return "" }
        return "\(Int((Double(sampleCount) * interval).rounded()))s"
    }
}
