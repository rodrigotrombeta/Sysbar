// What the status-bar icon shows and how, persisted in UserDefaults.

import AppKit

/// A metric that can drive (animate) the status-bar icon.
enum IconMetric: String, CaseIterable {
    case cpu, eCores, pCores, gpu, gpuMemory, memory, disk

    /// Menu title.
    var title: String {
        switch self {
        case .cpu: return tr("CPU (total)", "CPU (total)")
        case .eCores: return tr("CPU E-cores", "CPU E-cores")
        case .pCores: return tr("CPU P-cores", "CPU P-cores")
        case .gpu: return "GPU"
        case .gpuMemory: return tr("GPU memory", "Memória da GPU")
        case .memory: return tr("Memory", "Memória")
        case .disk: return tr("Disk", "Disco")
        }
    }

    /// Tiny label drawn next to the chart (stacked vertically, Stats-style).
    var shortLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .eCores: return "E"
        case .pCores: return "P"
        case .gpu: return "GPU"
        case .gpuMemory: return "VM"
        case .memory: return "RAM"
        case .disk: return "SSD"
        }
    }

    var color: NSColor {
        switch self {
        case .cpu: return .systemBlue
        case .eCores: return .systemOrange
        case .pCores: return .systemBlue
        case .gpu: return .systemGreen
        case .gpuMemory: return .systemCyan
        case .memory: return .systemPurple
        case .disk: return .systemIndigo
        }
    }

    /// Memory and Disk pick their own chart (pie / bar / I/O); the other
    /// metrics follow the global icon style.
    var hasOwnChart: Bool { self == .memory || self == .disk }

    var chartKind: MetricChart? {
        switch self {
        case .memory: return Settings.memoryChart
        case .disk: return Settings.diskChart
        default: return nil
        }
    }

    func value(in s: SystemStatsSnapshot) -> Double? {
        switch self {
        case .cpu: return s.cpuTotalUsage
        case .eCores: return s.eCoreUsage
        case .pCores: return s.pCoreUsage
        case .gpu: return s.gpuUsage
        case .gpuMemory: return s.gpuMemoryFraction
        case .memory: return s.memory.totalBytes > 0 ? s.memory.usedFraction : nil
        case .disk: return s.disk?.usedFraction
        }
    }

    func history(in s: SystemStatsSnapshot) -> [Double] {
        switch self {
        case .cpu: return s.cpuHistory
        case .eCores: return s.eHistory
        case .pCores: return s.pHistory
        case .gpu: return s.gpuHistory
        case .gpuMemory: return s.gpuMemoryHistory
        case .memory: return s.memoryHistory
        case .disk: return []
        }
    }

    /// Read/write (or page-in/page-out) rate histories, bytes/s.
    func ioHistory(in s: SystemStatsSnapshot) -> (read: [Double], write: [Double]) {
        switch self {
        case .memory: return (s.memoryInHistory, s.memoryOutHistory)
        case .disk: return (s.diskReadHistory, s.diskWriteHistory)
        default: return ([], [])
        }
    }
}

/// Chart used by the Memory and Disk widgets.
enum MetricChart: String, CaseIterable {
    case pie, bar, io

    var title: String {
        switch self {
        case .pie: return tr("Pie chart", "Gráfico de pizza")
        case .bar: return tr("Bar", "Barra")
        case .io: return tr("I/O (read / write)", "I/O (leitura / escrita)")
        }
    }
}

enum IconStyle: String, CaseIterable {
    case lineChart, barChart, percent, lineAndPercent

    var title: String {
        switch self {
        case .lineChart: return tr("Line chart", "Gráfico de linha")
        case .barChart: return tr("Bar", "Barra")
        case .percent: return tr("Percentage", "Porcentagem")
        case .lineAndPercent: return tr("Chart + percentage", "Gráfico + porcentagem")
        }
    }
}

enum IconColorMode: String, CaseIterable {
    case monochrome, metric, utilization

    var title: String {
        switch self {
        case .monochrome: return tr("Monochrome", "Monocromático")
        case .metric: return tr("Metric color", "Cor da métrica")
        case .utilization: return tr("By utilization (green → red)", "Por utilização (verde → vermelho)")
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static var metrics: [IconMetric] {
        get {
            let raw = defaults.stringArray(forKey: "iconMetrics") ?? [IconMetric.cpu.rawValue]
            let parsed = raw.compactMap(IconMetric.init(rawValue:))
            // Keep the canonical order regardless of toggle order.
            let ordered = IconMetric.allCases.filter(parsed.contains)
            return ordered.isEmpty ? [.cpu] : ordered
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: "iconMetrics") }
    }

    static var style: IconStyle {
        get { defaults.string(forKey: "iconStyle").flatMap(IconStyle.init(rawValue:)) ?? .lineChart }
        set { defaults.set(newValue.rawValue, forKey: "iconStyle") }
    }

    static var memoryChart: MetricChart {
        get { defaults.string(forKey: "memoryChart").flatMap(MetricChart.init(rawValue:)) ?? .bar }
        set { defaults.set(newValue.rawValue, forKey: "memoryChart") }
    }

    static var diskChart: MetricChart {
        get { defaults.string(forKey: "diskChart").flatMap(MetricChart.init(rawValue:)) ?? .pie }
        set { defaults.set(newValue.rawValue, forKey: "diskChart") }
    }

    static var colorMode: IconColorMode {
        get { defaults.string(forKey: "iconColorMode").flatMap(IconColorMode.init(rawValue:)) ?? .monochrome }
        set { defaults.set(newValue.rawValue, forKey: "iconColorMode") }
    }

    static var showLabel: Bool {
        get { defaults.object(forKey: "iconShowLabel") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "iconShowLabel") }
    }

    static var language: Language {
        get { defaults.string(forKey: "language").flatMap(Language.init(rawValue:)) ?? .systemDefault }
        set { defaults.set(newValue.rawValue, forKey: "language") }
    }

    static let intervals: [TimeInterval] = [0.5, 1, 2, 3, 5]

    static var interval: TimeInterval {
        get {
            let v = defaults.double(forKey: "refreshInterval")
            return intervals.contains(v) ? v : 1
        }
        set { defaults.set(newValue, forKey: "refreshInterval") }
    }
}
