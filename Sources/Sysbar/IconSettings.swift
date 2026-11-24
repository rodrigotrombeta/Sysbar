// What the status-bar icon shows and how, persisted in UserDefaults.

import AppKit
import Observation
import SwiftUI

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
            return [.pie, .bar, .line, .percent, .amount, .io]
        case .disk:
            return [.pie, .bar, .percent, .amount, .io]
        case .network:
            return [.io, .speed]
        }
    }

    /// Used and free bytes, for the "Used / free" text style.
    func amounts(in s: SystemStatsSnapshot) -> (used: UInt64, free: UInt64)? {
        switch self {
        case .memory:
            let m = s.memory
            guard m.totalBytes > 0 else { return nil }
            return (m.usedBytes, m.totalBytes > m.usedBytes ? m.totalBytes - m.usedBytes : 0)
        case .disk:
            return s.disk.map { ($0.usedBytes, $0.freeBytes) }
        default:
            return nil
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
    case line, bar, pie, percent, linePercent, io, speed, amount

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
        case .amount: return tr("Used / free (GB)", "Usado / livre (GB)")
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

/// Every user setting, loaded once from UserDefaults and written back on
/// change. It is @Observable, so SwiftUI views that read a setting (directly
/// or through `tr()`) update in place when it changes, with no identity reset.
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Metrics shown in the menu bar, as saved (any order).
    var shownMetrics: [IconMetric] {
        didSet { defaults.set(shownMetrics.map(\.rawValue), forKey: "iconMetrics") }
    }
    /// Left-to-right order of every metric in the menu bar (shown or not).
    var order: [IconMetric] {
        didSet { defaults.set(order.map(\.rawValue), forKey: "iconOrder") }
    }
    /// Style per metric raw value.
    var styles: [String: String] {
        didSet { defaults.set(styles, forKey: "iconStyles") }
    }
    /// Color mode per metric raw value.
    var colorModes: [String: String] {
        didSet { defaults.set(colorModes, forKey: "iconColorModes") }
    }
    var showLabel: Bool {
        didSet { defaults.set(showLabel, forKey: "iconShowLabel") }
    }
    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appAppearance") }
    }
    /// Opacity of every Sysbar panel (background, text, graphics).
    var opacity: OpacitySet {
        didSet { defaults.set(try? JSONEncoder().encode(opacity), forKey: "opacity") }
    }
    /// Text color of the panels as sRGB components; nil = system (white /
    /// black with the usual grays for secondary text).
    var textColor: [Double]? {
        didSet { defaults.set(textColor, forKey: "textColor") }
    }
    /// Detail panels set to "Separate": their own opacity instead of the
    /// global one (keys are section kinds).
    var separateOpacity: Set<String> {
        didSet { defaults.set(Array(separateOpacity).sorted(), forKey: "separateOpacityPanels") }
    }
    /// Each detail panel's own opacity, kept while it's set back to Global.
    var panelOpacities: [String: OpacitySet] {
        didSet { defaults.set(try? JSONEncoder().encode(panelOpacities), forKey: "panelOpacitySets") }
    }
    /// Edge panel spans the whole height of the screen (square corners)
    /// instead of floating at its content height.
    var pinFull: Bool {
        didSet { defaults.set(pinFull, forKey: "pinFull") }
    }
    /// Show the detailed disk breakdown in the menu bar disk pie/bar.
    var diskDetailedInIcon: Bool {
        didSet { defaults.set(diskDetailedInIcon, forKey: "diskDetailedInIcon") }
    }
    var language: Language {
        didSet { defaults.set(language.rawValue, forKey: "language") }
    }
    var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") }
    }
    /// nil = not pinned.
    var pinSide: PinSide? {
        didSet { defaults.set(pinSide?.rawValue, forKey: "pinSide") }
    }
    var interval: TimeInterval {
        didSet { defaults.set(interval, forKey: "refreshInterval") }
    }
    /// Sections of the edge-pinned panel that don't open their details on
    /// hover ("Mute mode"; clicking still pins them).
    var mutedSections: Set<SystemStatKind> {
        didSet { defaults.set(mutedSections.map(\.rawValue).sorted(), forKey: "mutedSections") }
    }
    /// Top-to-bottom order of the panel sections (CPU, GPU, Memory, …).
    var sectionOrder: [SystemStatKind] {
        didSet { defaults.set(sectionOrder.map(\.rawValue), forKey: "sectionOrder") }
    }
    /// Mirror of SMAppService status (not persisted); refreshed after
    /// register/unregister and whenever Settings is shown.
    var openAtLogin = false

    private init() {
        let d = UserDefaults.standard
        shownMetrics = (d.stringArray(forKey: "iconMetrics") ?? [IconMetric.cpu.rawValue])
            .compactMap(IconMetric.init(rawValue:))
        let saved = (d.stringArray(forKey: "iconOrder") ?? []).compactMap(IconMetric.init(rawValue:))
        var seen = Set<IconMetric>()
        let unique = saved.filter { seen.insert($0).inserted }
        order = unique + IconMetric.allCases.filter { !seen.contains($0) }
        styles = d.dictionary(forKey: "iconStyles") as? [String: String] ?? [:]
        colorModes = d.dictionary(forKey: "iconColorModes") as? [String: String] ?? [:]
        showLabel = d.object(forKey: "iconShowLabel") as? Bool ?? true
        appearance = d.string(forKey: "appAppearance").flatMap(AppAppearance.init(rawValue:)) ?? .system
        // Earlier builds stored a single value ("panelOpacity").
        opacity = d.data(forKey: "opacity").flatMap { try? JSONDecoder().decode(OpacitySet.self, from: $0) }
            ?? OpacitySet(all: d.object(forKey: "panelOpacity") as? Double ?? 1)
        separateOpacity = Set(d.stringArray(forKey: "separateOpacityPanels") ?? [])
        textColor = (d.array(forKey: "textColor") as? [Double]).flatMap { $0.count == 3 ? $0 : nil }
        panelOpacities = d.data(forKey: "panelOpacitySets")
            .flatMap { try? JSONDecoder().decode([String: OpacitySet].self, from: $0) } ?? [:]
        diskDetailedInIcon = d.bool(forKey: "diskDetailedInIcon")
        pinFull = d.bool(forKey: "pinFull")
        language = d.string(forKey: "language").flatMap(Language.init(rawValue:)) ?? .systemDefault
        autoCheckUpdates = d.object(forKey: "autoCheckUpdates") as? Bool ?? true
        pinSide = d.string(forKey: "pinSide").flatMap(PinSide.init(rawValue:))
        mutedSections = Set((d.stringArray(forKey: "mutedSections") ?? []).compactMap(SystemStatKind.init(rawValue:)))
        let savedSections = (d.stringArray(forKey: "sectionOrder") ?? []).compactMap(SystemStatKind.init(rawValue:))
        var seenSections = Set<SystemStatKind>()
        let uniqueSections = savedSections.filter { seenSections.insert($0).inserted }
        sectionOrder = uniqueSections + SystemStatKind.allCases.filter { !seenSections.contains($0) }
        let v = d.double(forKey: "refreshInterval")
        interval = Settings.intervals.contains(v) ? v : 1
    }
}

/// Static facade over `SettingsStore.shared`, so non-UI code keeps reading
/// `Settings.x`; reads from a view body are still observed.
enum Settings {
    private static var store: SettingsStore { .shared }
    private static let defaults = UserDefaults.standard

    static var metrics: [IconMetric] {
        get {
            let shown = store.shownMetrics
            // Shown in the user's chosen order, regardless of toggle order.
            return store.order.filter(shown.contains)
        }
        set { store.shownMetrics = newValue }
    }

    static var order: [IconMetric] {
        get { store.order }
        set { store.order = newValue }
    }

    /// Moves a metric to `index` in the order (drag and drop in Settings).
    static func move(_ metric: IconMetric, to index: Int) {
        var list = order
        guard let from = list.firstIndex(of: metric) else { return }
        list.remove(at: from)
        list.insert(metric, at: min(max(index, 0), list.count))
        if list != order { order = list }
    }

    /// Style per metric. Upgrades from the old global/per-chart keys.
    static func style(for metric: IconMetric) -> IconStyle {
        if let raw = store.styles[metric.rawValue], let style = IconStyle(rawValue: raw),
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
        store.styles[metric.rawValue] = style.rawValue
    }

    /// Color mode per metric (default: colored). Falls back to the old
    /// single global setting for users upgrading from an earlier version.
    static func colorMode(for metric: IconMetric) -> IconColorMode {
        if let raw = store.colorModes[metric.rawValue], let mode = IconColorMode(rawValue: raw) { return mode }
        return defaults.string(forKey: "iconColorMode").flatMap(IconColorMode.init(rawValue:)) ?? .metric
    }

    static func setColorMode(_ mode: IconColorMode, for metric: IconMetric) {
        store.colorModes[metric.rawValue] = mode.rawValue
    }

    static var showLabel: Bool {
        get { store.showLabel }
        set { store.showLabel = newValue }
    }

    static var appearance: AppAppearance {
        get { store.appearance }
        set { store.appearance = newValue }
    }

    static var pinFull: Bool {
        get { store.pinFull }
        set { store.pinFull = newValue }
    }

    static var diskDetailedInIcon: Bool {
        get { store.diskDetailedInIcon }
        set { store.diskDetailedInIcon = newValue }
    }

    /// Opacity of every panel: main, edge and detail panels alike.
    static var opacity: OpacitySet {
        get { store.opacity }
        set { store.opacity = newValue }
    }

    /// Panel text color; nil = system.
    static var textColor: Color? {
        get { store.textColor.map { Color(.sRGB, red: $0[0], green: $0[1], blue: $0[2]) } }
        set {
            store.textColor = newValue.flatMap { color in
                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
                return [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
            }
        }
    }

    /// Opacity a panel uses: its own if set to Separate, else the global one
    /// (key nil = main/edge panel, always global).
    static func opacity(for key: String?) -> OpacitySet {
        guard let key, store.separateOpacity.contains(key) else { return store.opacity }
        return store.panelOpacities[key] ?? store.opacity
    }

    /// Writes where `opacity(for:)` reads from.
    static func setOpacity(_ value: OpacitySet, for key: String?) {
        if let key, store.separateOpacity.contains(key) {
            store.panelOpacities[key] = value
        } else {
            store.opacity = value
        }
    }

    static func isSeparateOpacity(_ key: String) -> Bool { store.separateOpacity.contains(key) }

    /// Separate starts from the panel's last own values, or the global ones.
    static func setSeparateOpacity(_ on: Bool, for key: String) {
        if on {
            if store.panelOpacities[key] == nil { store.panelOpacities[key] = store.opacity }
            store.separateOpacity.insert(key)
        } else {
            store.separateOpacity.remove(key)
        }
    }

    static var language: Language {
        get { store.language }
        set { store.language = newValue }
    }

    static var autoCheckUpdates: Bool {
        get { store.autoCheckUpdates }
        set { store.autoCheckUpdates = newValue }
    }

    static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: "lastUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastUpdateCheck") }
    }

    /// Version the user chose to skip in automatic update alerts.
    static var skippedVersion: String? {
        get { defaults.string(forKey: "skippedVersion") }
        set { defaults.set(newValue, forKey: "skippedVersion") }
    }

    /// Display the edge panel is pinned to (CGDirectDisplayID); nil = default.
    static var pinScreenID: UInt32? {
        get { (defaults.object(forKey: "pinScreenID") as? NSNumber)?.uint32Value }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: "pinScreenID") }
    }

    /// nil = not pinned.
    static var pinSide: PinSide? {
        get { store.pinSide }
        set { store.pinSide = newValue }
    }

    static var sectionOrder: [SystemStatKind] { store.sectionOrder }

    /// Moves a panel section to `index` (drag and drop in the panel).
    static func moveSection(_ kind: SystemStatKind, to index: Int) {
        var list = store.sectionOrder
        guard let from = list.firstIndex(of: kind) else { return }
        list.remove(at: from)
        list.insert(kind, at: min(max(index, 0), list.count))
        if list != store.sectionOrder { store.sectionOrder = list }
    }

    static func isMuted(_ kind: SystemStatKind) -> Bool { store.mutedSections.contains(kind) }

    static var allMuted: Bool { store.mutedSections.count == SystemStatKind.allCases.count }

    static func toggleMute(_ kind: SystemStatKind) {
        if store.mutedSections.contains(kind) {
            store.mutedSections.remove(kind)
        } else {
            store.mutedSections.insert(kind)
        }
    }

    static func setAllMuted(_ muted: Bool) {
        store.mutedSections = muted ? Set(SystemStatKind.allCases) : []
    }

    static let intervals: [TimeInterval] = [0.5, 1, 2, 3, 5]

    static var interval: TimeInterval {
        get { store.interval }
        set { store.interval = newValue }
    }
}

/// Opacity of a panel's background, text and graphics (charts, bars, pies).
/// With `sync` (off by default), one slider moves all three.
struct OpacitySet: Codable, Equatable {
    var background = 1.0
    var text = 1.0
    var graphics = 1.0
    /// Off by default: Background, Text and Graphics have their own sliders.
    var sync = false

    static let backgroundRange: ClosedRange<Double> = 0...1
    /// Text and graphics can go to 0 (e.g. only the charts, or nothing but
    /// the background); the header buttons and Settings stay visible.
    static let contentRange: ClosedRange<Double> = 0...1
    static let syncRange: ClosedRange<Double> = 0.3...1

    init() {}

    init(all value: Double) {
        let v = min(1, max(Self.syncRange.lowerBound, value))
        background = v
        text = v
        graphics = v
    }
}
