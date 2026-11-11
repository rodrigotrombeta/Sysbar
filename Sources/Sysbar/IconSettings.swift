// What the status-bar icon shows and how, persisted in UserDefaults.

import AppKit

/// A metric that can drive (animate) the status-bar icon.
enum IconMetric: String, CaseIterable {
    case cpu, eCores, pCores, gpu, gpuMemory, memory

    /// Menu title.
    var title: String {
        switch self {
        case .cpu: return "CPU (total)"
        case .eCores: return "CPU E-cores"
        case .pCores: return "CPU P-cores"
        case .gpu: return "GPU"
        case .gpuMemory: return "Memória da GPU"
        case .memory: return "Memória (RAM)"
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
        }
    }
}

enum IconStyle: String, CaseIterable {
    case lineChart, barChart, percent, lineAndPercent

    var title: String {
        switch self {
        case .lineChart: return "Gráfico de linha"
        case .barChart: return "Barra"
        case .percent: return "Porcentagem"
        case .lineAndPercent: return "Gráfico + porcentagem"
        }
    }
}

enum IconColorMode: String, CaseIterable {
    case monochrome, metric, utilization

    var title: String {
        switch self {
        case .monochrome: return "Monocromático"
        case .metric: return "Cor da métrica"
        case .utilization: return "Por utilização (verde → vermelho)"
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

    static var colorMode: IconColorMode {
        get { defaults.string(forKey: "iconColorMode").flatMap(IconColorMode.init(rawValue:)) ?? .monochrome }
        set { defaults.set(newValue.rawValue, forKey: "iconColorMode") }
    }

    static var showLabel: Bool {
        get { defaults.object(forKey: "iconShowLabel") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "iconShowLabel") }
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
