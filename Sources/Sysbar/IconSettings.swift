// What the status-bar icon shows and how, persisted in UserDefaults.

import AppKit
import Observation
import SwiftUI

/// A metric that can drive (animate) the status-bar icon.
enum IconMetric: String, CaseIterable, Identifiable {
    case cpu, eCores, pCores, gpu, gpuMemory, memory, disk, network, claude, clock, battery

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
        case .claude: return tr("Claude Code limits", "Limites do Claude Code")
        case .clock: return tr("Clock (first 2 time zones)", "Relógio (2 primeiros fusos)")
        case .battery: return tr("Battery", "Bateria")
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
        case .claude: return "CC"
        case .clock: return ""
        case .battery: return "BAT"
        }
    }

    var color: NSColor {
        switch self {
        case .cpu: return .systemBlue
        case .eCores: return .systemGreen
        case .pCores: return .systemBlue
        case .gpu: return .systemGreen
        case .gpuMemory: return .systemCyan
        case .memory: return .systemPurple
        case .disk: return .systemBlue
        case .network: return .systemBlue
        case .claude: return .systemOrange
        case .clock: return .labelColor
        case .battery: return .systemGreen
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
        case .claude:
            return [.limits]
        case .clock:
            return [.clock]
        case .battery:
            return [.battery, .batteryIcon, .batteryVertical, .batteryIconVertical, .percent]
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
        case .claude: return s.claude?.fiveHour.map { $0.percent / 100 }
        case .clock: return nil
        case .battery: return s.battery?.level
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
        case .disk, .network, .claude, .clock, .battery: return []
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
    case line, bar, pie, percent, linePercent, io, speed, amount, limits, clock, battery, batteryIcon, batteryVertical, batteryIconVertical

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
        case .limits: return tr("5h / weekly %", "5h / semanal %")
        case .clock: return tr("Date and time", "Data e hora")
        case .battery: return tr("% + battery", "% + bateria")
        case .batteryIcon: return tr("Battery icon", "Ícone de bateria")
        case .batteryVertical: return tr("% + battery (vertical)", "% + bateria (vertical)")
        case .batteryIconVertical: return tr("Battery icon (vertical)", "Ícone de bateria (vertical)")
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
    /// Dashboard pages: how many, their names ("" = the number), which page
    /// each section is on, and how pinning works.
    var pageCount: Int {
        didSet { defaults.set(pageCount, forKey: "pageCount") }
    }
    var pageNames: [String] {
        didSet { defaults.set(pageNames, forKey: "pageNames") }
    }
    var sectionPages: [String: Int] {
        didSet { defaults.set(sectionPages, forKey: "sectionPages") }
    }
    /// Pin every page (one column each) instead of only the main page.
    var pinAllPages: Bool {
        didSet { defaults.set(pinAllPages, forKey: "pinAllPages") }
    }
    /// Edge of each page after the first when all pages are pinned.
    var pageSides: [String: String] {
        didSet { defaults.set(pageSides, forKey: "pageSides") }
    }
    /// Space between the menu bar widgets (pt).
    var iconSpacing: Double {
        didSet { defaults.set(iconSpacing, forKey: "iconSpacing") }
    }
    /// Time span of the history charts, in seconds.
    var chartWindow: TimeInterval {
        didSet { defaults.set(chartWindow, forKey: "chartWindow") }
    }
    /// Names given to Claude Code accounts (by account id; "" = main).
    var claudeAccountNames: [String: String] {
        didSet { defaults.set(claudeAccountNames, forKey: "claudeAccountNames") }
    }
    /// Fetch the Claude limits from Anthropic (ClaudeUsageFetcher).
    var claudeFetch: Bool {
        didSet { defaults.set(claudeFetch, forKey: "claudeFetch") }
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
        didSet {
            defaults.set(pinSide?.rawValue, forKey: "pinSide")
            if let pinSide { defaults.set(pinSide.rawValue, forKey: "lastPinSide") }
        }
    }
    /// What clicking the menu bar icon opens: "float" or "full".
    var iconOpens: String {
        didSet { defaults.set(iconOpens, forKey: "iconOpens") }
    }
    var interval: TimeInterval {
        didSet { defaults.set(interval, forKey: "refreshInterval") }
    }
    /// Sections of the edge-pinned panel that don't open their details on
    /// hover ("Mute mode"; clicking still pins them).
    /// Time zone identifiers of the clocks, in order (empty = this Mac's).
    var clockZones: [String] {
        didSet { defaults.set(clockZones, forKey: "clockZones") }
    }
    /// Font size of the menu bar clock (pt).
    var clockFontSize: Double {
        didSet { defaults.set(clockFontSize, forKey: "clockFontSize") }
    }
    /// Sections hidden from the dashboard (Settings › Dashboard).
    var hiddenSections: Set<SystemStatKind> {
        didSet { defaults.set(hiddenSections.map(\.rawValue).sorted(), forKey: "hiddenSections") }
    }
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
        claudeFetch = d.bool(forKey: "claudeFetch")
        chartWindow = d.object(forKey: "chartWindow") as? Double ?? 60
        iconSpacing = d.object(forKey: "iconSpacing") as? Double ?? 6
        pageCount = min(6, max(1, d.object(forKey: "pageCount") as? Int ?? 1))
        pageNames = d.stringArray(forKey: "pageNames") ?? []
        sectionPages = d.dictionary(forKey: "sectionPages") as? [String: Int] ?? [:]
        pinAllPages = d.bool(forKey: "pinAllPages")
        pageSides = d.dictionary(forKey: "pageSides") as? [String: String] ?? [:]
        // "menu" (under the icon) was removed: the icon opens Float or Full.
        iconOpens = d.string(forKey: "iconOpens") == "full" ? "full" : "float"
        claudeAccountNames = d.dictionary(forKey: "claudeAccountNames") as? [String: String] ?? [:]
        textColor = (d.array(forKey: "textColor") as? [Double]).flatMap { $0.count == 3 ? $0 : nil }
        panelOpacities = d.data(forKey: "panelOpacitySets")
            .flatMap { try? JSONDecoder().decode([String: OpacitySet].self, from: $0) } ?? [:]
        diskDetailedInIcon = d.bool(forKey: "diskDetailedInIcon")
        pinFull = d.bool(forKey: "pinFull")
        language = d.string(forKey: "language").flatMap(Language.init(rawValue:)) ?? .systemDefault
        autoCheckUpdates = d.object(forKey: "autoCheckUpdates") as? Bool ?? true
        pinSide = d.string(forKey: "pinSide").flatMap(PinSide.init(rawValue:))
        clockZones = d.stringArray(forKey: "clockZones") ?? []
        clockFontSize = min(12, max(8, d.object(forKey: "clockFontSize") as? Double ?? 8.5))
        hiddenSections = Set((d.stringArray(forKey: "hiddenSections") ?? []).compactMap(SystemStatKind.init(rawValue:)))
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

    // MARK: Pages

    static var pageCount: Int {
        get { store.pageCount }
        set { store.pageCount = min(6, max(1, newValue)) }
    }

    /// Page value for "on every page" (Both / All pages).
    static let allPages = -2

    /// Page a section is on (0-based, within the current page count), or
    /// `allPages`.
    static func page(of kind: SystemStatKind) -> Int {
        let page = store.sectionPages[kind.rawValue] ?? 0
        return page == allPages ? allPages : min(page, store.pageCount - 1)
    }

    static func isOnPage(_ kind: SystemStatKind, _ page: Int) -> Bool {
        isOnDashboard(kind) && (Settings.page(of: kind) == page || Settings.page(of: kind) == allPages)
    }

    static var iconOpens: String {
        get { store.iconOpens }
        set { store.iconOpens = newValue }
    }

    /// Edge used when the icon opens a pinned panel: the last one chosen.
    static var lastPinSide: PinSide {
        UserDefaults.standard.string(forKey: "lastPinSide").flatMap(PinSide.init(rawValue:)) ?? .right
    }

    static func setPage(_ page: Int, for kind: SystemStatKind) {
        store.sectionPages[kind.rawValue] = page
    }

    /// The page's name, or its number.
    static func pageTitle(_ page: Int) -> String {
        let name = page < store.pageNames.count ? store.pageNames[page].trimmingCharacters(in: .whitespaces) : ""
        return name.isEmpty ? "\(page + 1)" : name
    }

    /// Swaps two pages: their names, sections and pinned edges.
    static func swapPages(_ a: Int, _ b: Int) {
        guard a != b, (0..<store.pageCount).contains(a), (0..<store.pageCount).contains(b) else { return }
        var names = store.pageNames
        while names.count < store.pageCount { names.append("") }
        names.swapAt(a, b)
        store.pageNames = names
        store.sectionPages = store.sectionPages.mapValues { $0 == a ? b : $0 == b ? a : $0 }
        // Page 0's edge is the main pin side; the others are stored by index.
        let sideA = side(forPage: a), sideB = side(forPage: b)
        for (page, side) in [(a, sideB), (b, sideA)] {
            if page == 0 { if store.pinSide != nil { store.pinSide = side } } else { setSide(side, forPage: page) }
        }
    }

    static func setPageName(_ name: String, for page: Int) {
        var names = store.pageNames
        while names.count <= page { names.append("") }
        names[page] = name
        store.pageNames = names
    }

    static var pinAllPages: Bool {
        get { store.pinAllPages }
        set { store.pinAllPages = newValue }
    }

    /// Pages that get their own pinned column (nil = one panel that shows
    /// the selected page).
    static var pinnedPages: [Int?] {
        guard store.pinSide != nil else { return [] }
        return store.pinAllPages && store.pageCount > 1 ? Array(0..<store.pageCount) : [nil]
    }

    /// Edge of a pinned page: the main pin side for page 0 (and the single
    /// panel), its own choice for the others.
    static func side(forPage page: Int?) -> PinSide {
        let main = store.pinSide ?? lastPinSide
        guard let page, page > 0 else { return main }
        return store.pageSides["\(page)"].flatMap(PinSide.init(rawValue:)) ?? main
    }

    static func setSide(_ side: PinSide, forPage page: Int) {
        store.pageSides["\(page)"] = side.rawValue
    }

    /// Several pinned columns are always full height.
    static var edgeFull: Bool { store.pinFull || pinnedPages.count > 1 }

    static var iconSpacing: Double {
        get { store.iconSpacing }
        set { store.iconSpacing = min(20, max(0, newValue)) }
    }

    static let chartWindows: [TimeInterval] = [60, 300, 900, 1800, 3600, 3 * 3600, 6 * 3600, 12 * 3600, 24 * 3600]

    static var chartWindow: TimeInterval {
        get { store.chartWindow }
        set { store.chartWindow = newValue }
    }

    static var claudeAccountNames: [String: String] {
        get { store.claudeAccountNames }
        set { store.claudeAccountNames = newValue }
    }

    static var claudeFetch: Bool {
        get { store.claudeFetch }
        set { store.claudeFetch = newValue }
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

    static func isOnDashboard(_ kind: SystemStatKind) -> Bool { !store.hiddenSections.contains(kind) }

    static func setOnDashboard(_ on: Bool, _ kind: SystemStatKind) {
        if on { store.hiddenSections.remove(kind) } else { store.hiddenSections.insert(kind) }
    }

    static var clockFontSize: Double {
        get { store.clockFontSize }
        set { store.clockFontSize = min(12, max(8, newValue)) }
    }

    static var clockZones: [String] {
        get { store.clockZones }
        set { store.clockZones = newValue }
    }

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
