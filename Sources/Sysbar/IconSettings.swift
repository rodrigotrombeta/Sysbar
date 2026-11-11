// What the status-bar icon shows and how, persisted in UserDefaults.

import AppKit

/// A metric that can drive (animate) the status-bar icon.
enum IconMetric: String, CaseIterable, Identifiable {
    case cpu, eCores, pCores, gpu, gpuMemory, memory, disk, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return tr("CPU (total)", "CPU (total)")
        case .eCores: return tr("CPU E-cores", "CPU E-cores")
        case .pCores: return tr("CPU P-cores", "CPU P-cores")
        case .gpu: return "GPU"
        case .gpuMemory: return tr("GPU memory", "Memória da GPU")
        case .memory: return tr("Memory", "Memória")
        case .disk: return tr("Disk", "Disco")
        case .network: return tr("Network", "Rede")
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
        case .network: return "NET"
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
        case .disk: return .systemBlue
        case .network: return .systemBlue
        }
    }

    /// Styles that make sense for this metric, in menu order.
    var styles: [IconStyle] {
        switch self {
        case .cpu, .eCores, .pCores, .gpu, .gpuMemory:
            return [.line, .bar, .pie, .percent, .linePercent]
        case .memory:
            return [.pie, .bar, .line, .percent, .io]
        case .disk:
            return [.pie, .bar, .percent, .io]
        case .network:
            return [.io, .speed]
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
        case .network: return nil
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
        case .disk, .network: return []
        }
    }

    /// Read/write (or page-in/page-out, download/upload) rate histories, bytes/s.
    func ioHistory(in s: SystemStatsSnapshot) -> (read: [Double], write: [Double]) {
        switch self {
        case .memory: return (s.memoryInHistory, s.memoryOutHistory)
        case .disk: return (s.diskReadHistory, s.diskWriteHistory)
        case .network: return (s.networkInHistory, s.networkOutHistory)
        default: return ([], [])
        }
    }
}

/// How one metric is drawn in the menu bar.
enum IconStyle: String, CaseIterable, Identifiable {
    case line, bar, pie, percent, linePercent, io, speed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: return tr("Line chart", "Gráfico de linha")
        case .bar: return tr("Bar", "Barra")
        case .pie: return tr("Pie chart", "Gráfico de pizza")
        case .percent: return tr("Percentage", "Porcentagem")
        case .linePercent: return tr("Chart + %", "Gráfico + %")
        case .io: return tr("I/O chart", "Gráfico de I/O")
        case .speed: return tr("Speed (text)", "Velocidade (texto)")
        }
    }
}

enum IconColorMode: String, CaseIterable, Identifiable {
    case monochrome, metric, utilization

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monochrome: return tr("Monochrome", "Monocromático")
        case .metric: return tr("Colored", "Colorido")
        case .utilization: return tr("By utilization", "Por utilização")
        }
    }
}

/// Appearance of the panels.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return tr("System", "Sistema")
        case .light: return tr("Light", "Claro")
        case .dark: return tr("Dark", "Escuro")
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var next: AppAppearance {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static var metrics: [IconMetric] {
        get {
            let raw = defaults.stringArray(forKey: "iconMetrics") ?? [IconMetric.cpu.rawValue]
            let parsed = raw.compactMap(IconMetric.init(rawValue:))
            // Shown in the user's chosen order, regardless of toggle order.
            return order.filter(parsed.contains)
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: "iconMetrics") }
    }

    /// Left-to-right order of every metric in the menu bar (shown or not).
    static var order: [IconMetric] {
        get {
            let saved = (defaults.stringArray(forKey: "iconOrder") ?? [])
                .compactMap(IconMetric.init(rawValue:))
            var seen = Set<IconMetric>()
            let unique = saved.filter { seen.insert($0).inserted }
            return unique + IconMetric.allCases.filter { !seen.contains($0) }
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: "iconOrder") }
    }

    /// Moves a metric one or more places left (negative) or right (positive).
    static func move(_ metric: IconMetric, by offset: Int) {
        var list = order
        guard let from = list.firstIndex(of: metric) else { return }
        let to = min(max(from + offset, 0), list.count - 1)
        guard to != from else { return }
        list.remove(at: from)
        list.insert(metric, at: to)
        order = list
    }

    /// Style per metric. Upgrades from the old global/per-chart keys.
    static func style(for metric: IconMetric) -> IconStyle {
        let map = defaults.dictionary(forKey: "iconStyles") as? [String: String] ?? [:]
        if let raw = map[metric.rawValue], let style = IconStyle(rawValue: raw),
           metric.styles.contains(style) {
            return style
        }
        let legacy: IconStyle?
        switch metric {
        case .memory:
            legacy = defaults.string(forKey: "memoryChart").flatMap(IconStyle.init(rawValue:))
        case .disk:
            legacy = defaults.string(forKey: "diskChart").flatMap(IconStyle.init(rawValue:))
        case .network:
            legacy = defaults.string(forKey: "networkStyle") == "speed" ? .speed : nil
        default:
            switch defaults.string(forKey: "iconStyle") {
            case "barChart": legacy = .bar
            case "percent": legacy = .percent
            case "lineAndPercent": legacy = .linePercent
            default: legacy = nil
            }
        }
        if let legacy, metric.styles.contains(legacy) { return legacy }
        return metric.styles[0]
    }

    static func setStyle(_ style: IconStyle, for metric: IconMetric) {
        var map = defaults.dictionary(forKey: "iconStyles") as? [String: String] ?? [:]
        map[metric.rawValue] = style.rawValue
        defaults.set(map, forKey: "iconStyles")
    }

    /// Color mode per metric (default: colored). Falls back to the old
    /// single global setting for users upgrading from an earlier version.
    static func colorMode(for metric: IconMetric) -> IconColorMode {
        let map = defaults.dictionary(forKey: "iconColorModes") as? [String: String] ?? [:]
        if let raw = map[metric.rawValue], let mode = IconColorMode(rawValue: raw) { return mode }
        return defaults.string(forKey: "iconColorMode").flatMap(IconColorMode.init(rawValue:)) ?? .metric
    }

    static func setColorMode(_ mode: IconColorMode, for metric: IconMetric) {
        var map = defaults.dictionary(forKey: "iconColorModes") as? [String: String] ?? [:]
        map[metric.rawValue] = mode.rawValue
        defaults.set(map, forKey: "iconColorModes")
    }

    static var showLabel: Bool {
        get { defaults.object(forKey: "iconShowLabel") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "iconShowLabel") }
    }

    static var appearance: AppAppearance {
        get { defaults.string(forKey: "appAppearance").flatMap(AppAppearance.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appAppearance") }
    }

    static var language: Language {
        get { defaults.string(forKey: "language").flatMap(Language.init(rawValue:)) ?? .systemDefault }
        set { defaults.set(newValue.rawValue, forKey: "language") }
    }

    /// nil = not pinned.
    static var pinSide: PinSide? {
        get { defaults.string(forKey: "pinSide").flatMap(PinSide.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: "pinSide") }
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
