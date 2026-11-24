// Battery: charge, health and power, read from the AppleSmartBattery IOKit
// service (public registry properties, no privileges needed), plus the
// dashboard section, the details panel and the menu bar glyph.

import AppKit
import IOKit
import SwiftUI

struct BatteryInfo: Sendable, Equatable {
    /// Charge, 0...1.
    var level: Double
    var isCharging: Bool
    var externalConnected: Bool
    var fullyCharged: Bool
    /// Minutes; nil while macOS is still estimating (65535).
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var cycleCount: Int?
    var designCycleCount: Int?
    /// mAh.
    var designCapacity: Int?
    var maxCapacity: Int?
    var currentCapacity: Int?
    /// mV, mA (negative while discharging).
    var voltage: Int?
    var amperage: Int?
    /// °C.
    var temperature: Double?
    var adapterWatts: Int?
    /// Power coming in from the adapter (mV, mA).
    var adapterVoltage: Int?
    var adapterCurrent: Int?
    var adapterName: String?

    /// Maximum capacity relative to design, capped at 100% like System Settings.
    var health: Double? {
        guard let design = designCapacity, design > 0, let max = maxCapacity else { return nil }
        return min(1, Double(max) / Double(design))
    }

    /// Battery power in watts (absolute value).
    var batteryWatts: Double? {
        guard let v = voltage, let a = amperage else { return nil }
        return abs(Double(v) * Double(a)) / 1_000_000
    }

    var adapterInWatts: Double? {
        guard let v = adapterVoltage, let a = adapterCurrent else { return nil }
        return Double(v) * Double(a) / 1_000_000
    }

    enum State { case charging, onHold, full, discharging }

    var state: State {
        if isCharging { return .charging }
        if externalConnected { return fullyCharged || level >= 0.995 ? .full : .onHold }
        return .discharging
    }

    var stateTitle: String {
        switch state {
        case .charging: return tr("Charging", "Carregando")
        case .onHold: return tr("On hold", "Em espera")
        case .full: return tr("Fully charged", "Carregada")
        case .discharging: return tr("On battery", "Na bateria")
        }
    }

    /// Glyph and level-bar color.
    var color: NSColor {
        if isCharging || externalConnected { return .systemGreen }
        if level <= 0.1 { return .systemRed }
        if level <= 0.2 { return .systemOrange }
        return .systemGreen
    }

    /// "Time to charge" / "Time remaining" and its value.
    var timeRow: (label: String, value: String) {
        switch state {
        case .charging:
            return (tr("Time to charge", "Tempo até carregar"),
                    minutesToFull.map(Self.hm) ?? tr("Calculating…", "Calculando…"))
        case .onHold:
            return (tr("Time to charge", "Tempo até carregar"), tr("On hold", "Em espera"))
        case .full:
            return (tr("Time to charge", "Tempo até carregar"), tr("Fully charged", "Carregada"))
        case .discharging:
            return (tr("Time remaining", "Tempo restante"),
                    minutesToEmpty.map(Self.hm) ?? tr("Calculating…", "Calculando…"))
        }
    }

    static func hm(_ minutes: Int) -> String { "\(minutes / 60):" + String(format: "%02d", minutes % 60) }

    // MARK: Reading

    /// On Apple Silicon the temperature lives in the AppleSmartBatteryPack
    /// child's BatteryData.
    nonisolated private static func packData() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryPack"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        guard let data = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return [:] }
        return data
    }

    /// nil on Macs without a battery.
    nonisolated static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var ref: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &ref, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = ref?.takeRetainedValue() as? [String: Any],
              (p["BatteryInstalled"] as? Bool) ?? true
        else { return nil }
        let data = p["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String, _ dict: [String: Any]? = nil) -> Int? {
            ((dict ?? p)[key] as? NSNumber)?.intValue
        }
        func time(_ key: String) -> Int? {
            guard let m = int(key), m > 0, m < 65535 else { return nil }
            return m
        }
        let current = int("CurrentCapacity") ?? 0
        let maxPercent = max(1, int("MaxCapacity") ?? 100)
        let adapter = p["AdapterDetails"] as? [String: Any]
        let telemetry = p["PowerTelemetryData"] as? [String: Any]
        let external = (p["ExternalConnected"] as? Bool) ?? false
        var temp: Double?
        if let t = int("Temperature") ?? int("VirtualTemperature") ?? int("Temperature", data)
            ?? int("Temperature", packData()) {
            temp = Double(t) / 100
        }

        return BatteryInfo(
            level: min(1, Double(current) / Double(maxPercent)),
            isCharging: (p["IsCharging"] as? Bool) ?? false,
            externalConnected: external,
            fullyCharged: (p["FullyCharged"] as? Bool) ?? false,
            minutesToEmpty: time("AvgTimeToEmpty") ?? (external ? nil : time("TimeRemaining")),
            minutesToFull: time("AvgTimeToFull"),
            cycleCount: int("CycleCount"),
            designCycleCount: int("DesignCycleCount9C"),
            designCapacity: int("DesignCapacity", data) ?? int("DesignCapacity"),
            maxCapacity: int("NominalChargeCapacity", data) ?? int("NominalChargeCapacity")
                ?? int("AppleRawMaxCapacity", data) ?? int("AppleRawMaxCapacity"),
            currentCapacity: int("AppleRawCurrentCapacity", data) ?? int("AppleRawCurrentCapacity"),
            voltage: int("Voltage") ?? int("AppleRawBatteryVoltage"),
            amperage: int("InstantAmperage") ?? int("Amperage"),
            temperature: temp,
            adapterWatts: external ? int("Watts", adapter) : nil,
            adapterVoltage: external ? (int("SystemVoltageIn", telemetry) ?? int("AdapterVoltage", adapter)) : nil,
            adapterCurrent: external ? int("SystemCurrentIn", telemetry) : nil,
            adapterName: external ? (adapter?["Name"] as? String ?? adapter?["Description"] as? String) : nil
        )
    }
}

/// Battery level history: one point per `step` seconds, for a few hours
/// (independent of the chart window: charge changes slowly).
@MainActor
final class BatteryHistory {
    static let shared = BatteryHistory()
    static let step: TimeInterval = 180
    static let points = 160  // 8 h

    private(set) var values: [Double] = []
    private var lastAppend: TimeInterval = -.infinity

    func record(_ level: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAppend >= Self.step else { return }
        lastAppend = now
        values.append(level)
        if values.count > Self.points { values.removeFirst(values.count - Self.points) }
    }
}

// MARK: - Views

private let green = Color(nsColor: .systemGreen)

/// Battery outline filled to the level, with a bolt/plug when on power.
struct BatteryGlyph: View {
    let info: BatteryInfo
    var width: CGFloat = 120

    var body: some View {
        let h = width * 0.46
        let stroke = max(1.5, width / 50)
        HStack(spacing: width * 0.02) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: h * 0.28)
                    .strokeBorder(Color.secondary, lineWidth: stroke)
                RoundedRectangle(cornerRadius: h * 0.2)
                    .fill(Color(nsColor: info.color))
                    .frame(width: max(h * 0.2, (width - stroke * 4) * info.level))
                    .padding(stroke * 2)
                    .graphicsLayer()
                if info.externalConnected {
                    Image(systemName: info.isCharging ? "bolt.fill" : "powerplug.fill")
                        .font(.system(size: h * 0.42, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: width, height: h)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary)
                .frame(width: width * 0.04, height: h * 0.32)
        }
    }
}

/// Dashboard section.
struct BatteryStatsPanel: View {
    let snapshot: SystemStatsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatsPanelHeader(title: tr("Battery", "Bateria"))
            if let b = snapshot.battery {
                UsageBarRow(label: b.stateTitle, value: StatsFormat.percent(b.level),
                            fraction: b.level, color: Color(nsColor: b.color))
                let time = b.timeRow
                StatsValueRow(label: time.label, value: time.value)
                StatsValueRow(label: tr("Source", "Fonte"),
                              value: b.externalConnected ? tr("Power adapter", "Carregador") : tr("Battery", "Bateria"))
                if let w = b.externalConnected ? b.adapterInWatts : b.batteryWatts {
                    StatsValueRow(label: tr("Power", "Potência"), value: String(format: "%.1f W", w))
                }
                StatsValueRow(label: tr("Health · Cycles", "Saúde · Ciclos"),
                              value: "\(StatsFormat.percent(b.health)) · \(b.cycleCount.map(String.init) ?? "–")")
            } else {
                StatsValueRow(label: tr("No battery", "Sem bateria"), value: "–")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: panelWidth)
    }
}

/// Details panel.
struct BatteryDetail: View {
    let model: AppModel

    var body: some View {
        if let b = model.snapshot.battery {
            content(b)
        } else {
            Text(tr("This Mac has no battery.", "Este Mac não tem bateria."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func content(_ b: BatteryInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 6) {
                BatteryGlyph(info: b, width: 110)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int((b.level * 100).rounded()))")
                        .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    Text("%").font(.system(size: 16)).foregroundStyle(.secondary)
                }
                .textLayer()
                Label(b.stateTitle, systemImage: b.externalConnected ? "powerplug.fill" : "battery.75percent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .textLayer()
            }
            .frame(maxWidth: .infinity)

            let history = BatteryHistory.shared.values
            SectionTitle(text: tr("Charge history", "Histórico de carga")
                         + (history.count > 1 ? " · " + StatsFormat.duration(Double(history.count - 1) * BatteryHistory.step) : ""))
            // A single point is drawn as a flat line until the next one.
            HistoryChart(series: [.init(values: history.count == 1 ? history + history : history, color: green)],
                         height: 64)

            SectionTitle(text: tr("Details", "Detalhes"))
            InfoRow(label: tr("Source", "Fonte"),
                    value: b.externalConnected ? tr("Power adapter", "Carregador") : tr("Battery", "Bateria"))
            let time = b.timeRow
            InfoRow(label: time.label, value: time.value)

            SectionTitle(text: tr("Battery", "Bateria"))
            if let health = b.health {
                MeterRow(label: tr("Health", "Saúde"), value: StatsFormat.percent(health),
                         fraction: health, color: green)
            }
            InfoRow(label: tr("Max capacity", "Capacidade máxima"), value: b.maxCapacity.map { "\($0) mAh" } ?? "–")
            InfoRow(label: tr("Design capacity", "Capacidade de fábrica"), value: b.designCapacity.map { "\($0) mAh" } ?? "–")
            InfoRow(label: tr("Current charge", "Carga atual"), value: b.currentCapacity.map { "\($0) mAh" } ?? "–")
            InfoRow(label: tr("Cycles", "Ciclos"),
                    value: (b.cycleCount.map(String.init) ?? "–") + (b.designCycleCount.map { " / \($0)" } ?? ""))
            InfoRow(label: tr("Power", "Potência"), value: b.batteryWatts.map { String(format: "%.2f W", $0) } ?? "–")
            InfoRow(label: tr("Current", "Corrente"), value: b.amperage.map { "\($0) mA" } ?? "–")
            InfoRow(label: tr("Voltage", "Tensão"), value: b.voltage.map { String(format: "%.2f V", Double($0) / 1000) } ?? "–")
            InfoRow(label: tr("Temperature", "Temperatura"), value: b.temperature.map { String(format: "%.1f °C", $0) } ?? "–")

            if b.externalConnected {
                SectionTitle(text: tr("Power adapter", "Carregador"))
                InfoRow(label: tr("Is charging", "Carregando"), value: b.isCharging ? tr("Yes", "Sim") : tr("No", "Não"),
                        valueColor: b.isCharging ? green : .primary)
                InfoRow(label: tr("Power", "Potência"),
                        value: (b.adapterInWatts.map { String(format: "%.2f W", $0) } ?? "–")
                            + (b.adapterWatts.map { " / \($0) W" } ?? ""))
                InfoRow(label: tr("Current", "Corrente"), value: b.adapterCurrent.map { "\($0) mA" } ?? "–")
                InfoRow(label: tr("Voltage", "Tensão"), value: b.adapterVoltage.map { String(format: "%.2f V", Double($0) / 1000) } ?? "–")
            }
        }
    }
}
