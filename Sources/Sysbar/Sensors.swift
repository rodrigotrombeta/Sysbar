// Temperatures, voltages, currents and power from the SMC (System
// Management Controller), read through the AppleSMC IOKit service like
// Stats and iStat Menus do. No privileges needed. The SMC's key names are
// undocumented: sensors are grouped by key family (CPU, GPU, battery…),
// not mapped to individual cores.

import Foundation
import IOKit
import SwiftUI

struct SensorReading: Sendable, Equatable {
    enum Group: String, Sendable, CaseIterable {
        case cpu, gpu, ssd, battery, wifi
    }
    /// SMC key, e.g. "Tp00".
    let key: String
    /// Display name, e.g. "CPU super core 1".
    let name: String
    let group: Group
    let value: Double
}

struct SensorsSnapshot: Sendable, Equatable {
    /// In table order: system sensors, CPU, GPU.
    var temperatures: [SensorReading] = []
    /// Watts / volts / amps by what they measure (only those present).
    var systemPower: Double?
    var dcInPower: Double?
    var batteryPower: Double?
    var dcInVoltage: Double?
    var rail12V: Double?
    var dcInCurrent: Double?

    func readings(_ g: SensorReading.Group) -> [SensorReading] { temperatures.filter { $0.group == g } }
    func group(_ g: SensorReading.Group) -> [Double] { readings(g).map(\.value) }
    func average(_ g: SensorReading.Group) -> Double? {
        let v = group(g); return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
    func hottest(_ g: SensorReading.Group) -> Double? { group(g).max() }
}

extension SensorReading.Group {
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ssd: return "SSD"
        case .battery: return tr("Battery", "Bateria")
        case .wifi: return "Wi-Fi"
        }
    }
}

/// Which SMC keys are which sensor, per chip generation (0 = Intel,
/// 1…6 = Apple M1…M6). From Stats (github.com/exelban/stats,
/// Modules/Sensors/values.swift): Copyright (c) 2019 Serhiy Mytrovtsiy,
/// MIT License — full text in THIRD_PARTY_STATS_LICENSE.txt.
enum SensorTable {
    static let entries: [(key: String, name: String, group: SensorReading.Group, generations: [Int])] = [
        ("TC0D", "CPU diode", .cpu, [0]),
        ("TC0E", "CPU diode virtual", .cpu, [0]),
        ("TC0F", "CPU diode filtered", .cpu, [0]),
        ("TC0H", "CPU heatsink", .cpu, [0]),
        ("TC0P", "CPU proximity", .cpu, [0]),
        ("TCAD", "CPU package", .cpu, [0]),
        ("TCAC", "CPU A core die", .cpu, [0]),
        ("TCBC", "CPU B core die", .cpu, [0]),
        ("TCAH", "CPU A heatsink", .cpu, [0]),
        ("TCBH", "CPU B heatsink", .cpu, [0]),
        ("TCGC", "GPU Intel Graphics", .gpu, [0]),
        ("TG0D", "GPU diode", .gpu, [0]),
        ("TGDD", "GPU AMD Radeon", .gpu, [0]),
        ("TG0H", "GPU heatsink", .gpu, [0]),
        ("TG0P", "GPU proximity", .gpu, [0]),
        ("TW0P", "Airport", .wifi, [0]),
        ("Tp09", "CPU efficiency core 1", .cpu, [1]),
        ("Tp0T", "CPU efficiency core 2", .cpu, [1]),
        ("Tp01", "CPU performance core 1", .cpu, [1]),
        ("Tp05", "CPU performance core 2", .cpu, [1]),
        ("Tp0D", "CPU performance core 3", .cpu, [1]),
        ("Tp0H", "CPU performance core 4", .cpu, [1]),
        ("Tp0L", "CPU performance core 5", .cpu, [1]),
        ("Tp0P", "CPU performance core 6", .cpu, [1]),
        ("Tp0X", "CPU performance core 7", .cpu, [1]),
        ("Tp0b", "CPU performance core 8", .cpu, [1]),
        ("Tg05", "GPU 1", .gpu, [1]),
        ("Tg0D", "GPU 2", .gpu, [1]),
        ("Tg0L", "GPU 3", .gpu, [1]),
        ("Tg0T", "GPU 4", .gpu, [1]),
        ("Tp1h", "CPU efficiency core 1", .cpu, [2]),
        ("Tp1t", "CPU efficiency core 2", .cpu, [2]),
        ("Tp1p", "CPU efficiency core 3", .cpu, [2]),
        ("Tp1l", "CPU efficiency core 4", .cpu, [2]),
        ("Tp01", "CPU performance core 1", .cpu, [2]),
        ("Tp05", "CPU performance core 2", .cpu, [2]),
        ("Tp09", "CPU performance core 3", .cpu, [2]),
        ("Tp0D", "CPU performance core 4", .cpu, [2]),
        ("Tp0X", "CPU performance core 5", .cpu, [2]),
        ("Tp0b", "CPU performance core 6", .cpu, [2]),
        ("Tp0f", "CPU performance core 7", .cpu, [2]),
        ("Tp0j", "CPU performance core 8", .cpu, [2]),
        ("Tg0f", "GPU 1", .gpu, [2]),
        ("Tg0j", "GPU 2", .gpu, [2]),
        ("Te05", "CPU efficiency core 1", .cpu, [3]),
        ("Te0L", "CPU efficiency core 2", .cpu, [3]),
        ("Te0P", "CPU efficiency core 3", .cpu, [3]),
        ("Te0S", "CPU efficiency core 4", .cpu, [3]),
        ("Tf04", "CPU performance core 1", .cpu, [3]),
        ("Tf09", "CPU performance core 2", .cpu, [3]),
        ("Tf0A", "CPU performance core 3", .cpu, [3]),
        ("Tf0B", "CPU performance core 4", .cpu, [3]),
        ("Tf0D", "CPU performance core 5", .cpu, [3]),
        ("Tf0E", "CPU performance core 6", .cpu, [3]),
        ("Tf44", "CPU performance core 7", .cpu, [3]),
        ("Tf49", "CPU performance core 8", .cpu, [3]),
        ("Tf4A", "CPU performance core 9", .cpu, [3]),
        ("Tf4B", "CPU performance core 10", .cpu, [3]),
        ("Tf4D", "CPU performance core 11", .cpu, [3]),
        ("Tf4E", "CPU performance core 12", .cpu, [3]),
        ("Tf14", "GPU 1", .gpu, [3]),
        ("Tf18", "GPU 2", .gpu, [3]),
        ("Tf19", "GPU 3", .gpu, [3]),
        ("Tf1A", "GPU 4", .gpu, [3]),
        ("Tf24", "GPU 5", .gpu, [3]),
        ("Tf28", "GPU 6", .gpu, [3]),
        ("Tf29", "GPU 7", .gpu, [3]),
        ("Tf2A", "GPU 8", .gpu, [3]),
        ("Te05", "CPU efficiency core 1", .cpu, [4]),
        ("Te0S", "CPU efficiency core 2", .cpu, [4]),
        ("Te09", "CPU efficiency core 3", .cpu, [4]),
        ("Te0H", "CPU efficiency core 4", .cpu, [4]),
        ("Tp01", "CPU performance core 1", .cpu, [4]),
        ("Tp05", "CPU performance core 2", .cpu, [4]),
        ("Tp09", "CPU performance core 3", .cpu, [4]),
        ("Tp0D", "CPU performance core 4", .cpu, [4]),
        ("Tp0V", "CPU performance core 5", .cpu, [4]),
        ("Tp0Y", "CPU performance core 6", .cpu, [4]),
        ("Tp0b", "CPU performance core 7", .cpu, [4]),
        ("Tp0e", "CPU performance core 8", .cpu, [4]),
        ("Tg0K", "GPU 3", .gpu, [4]),
        ("Tg0L", "GPU 4", .gpu, [4]),
        ("Tg0d", "GPU 5", .gpu, [4]),
        ("Tg0e", "GPU 6", .gpu, [4]),
        ("Tg0j", "GPU 7", .gpu, [4]),
        ("Tg0k", "GPU 8", .gpu, [4]),
        ("Tp00", "CPU super core 1", .cpu, [5]),
        ("Tp04", "CPU super core 2", .cpu, [5]),
        ("Tp08", "CPU super core 3", .cpu, [5]),
        ("Tp0C", "CPU super core 4", .cpu, [5]),
        ("Tp0G", "CPU super core 5", .cpu, [5]),
        ("Tp0K", "CPU super core 6", .cpu, [5]),
        ("Tp0O", "CPU performance core 1", .cpu, [5]),
        ("Tp0R", "CPU performance core 2", .cpu, [5]),
        ("Tp0U", "CPU performance core 3", .cpu, [5]),
        ("Tp0X", "CPU performance core 4", .cpu, [5]),
        ("Tp0a", "CPU performance core 5", .cpu, [5]),
        ("Tp0d", "CPU performance core 6", .cpu, [5]),
        ("Tp0g", "CPU performance core 7", .cpu, [5]),
        ("Tp0j", "CPU performance core 8", .cpu, [5]),
        ("Tp0m", "CPU performance core 9", .cpu, [5]),
        ("Tp0p", "CPU performance core 10", .cpu, [5]),
        ("Tp0u", "CPU performance core 11", .cpu, [5]),
        ("Tp0y", "CPU performance core 12", .cpu, [5]),
        ("Tg0U", "GPU 1", .gpu, [5]),
        ("Tg0X", "GPU 2", .gpu, [5]),
        ("Tg0d", "GPU 3", .gpu, [5]),
        ("Tg0g", "GPU 4", .gpu, [5]),
        ("Tg0j", "GPU 5", .gpu, [5]),
        ("Tg1Y", "GPU 6", .gpu, [5]),
        ("Tg1c", "GPU 7", .gpu, [5]),
        ("Tg1g", "GPU 8", .gpu, [5]),
        ("Tp0j", "CPU super core 1", .cpu, [6]),
        ("Tp0g", "CPU super core 2", .cpu, [6]),
        ("Tp09", "CPU super core 3", .cpu, [6]),
        ("Tp07", "CPU super core 4", .cpu, [6]),
        ("Tp0m", "CPU performance core 1", .cpu, [6]),
        ("Tp0L", "CPU performance core 2", .cpu, [6]),
        ("Tp0I", "CPU performance core 3", .cpu, [6]),
        ("Tp0d", "CPU performance core 4", .cpu, [6]),
        ("Tp0E", "CPU performance core 5", .cpu, [6]),
        ("Tp0G", "CPU performance core 6", .cpu, [6]),
        ("Tp0b", "CPU performance core 7", .cpu, [6]),
        ("Tp05", "CPU performance core 8", .cpu, [6]),
        ("Te07", "CPU efficiency core 1", .cpu, [6]),
        ("Te08", "CPU efficiency core 2", .cpu, [6]),
        ("Te09", "CPU efficiency core 3", .cpu, [6]),
        ("Te0c", "CPU efficiency core 4", .cpu, [6]),
        ("Te0h", "CPU efficiency core 5", .cpu, [6]),
        ("Te0i", "CPU efficiency core 6", .cpu, [6]),
        ("Tg1e", "GPU 1", .gpu, [6]),
        ("Tg0d", "GPU 2", .gpu, [6]),
        ("Tg0c", "GPU 3", .gpu, [6]),
        ("Tg0b", "GPU 4", .gpu, [6]),
        ("Tg1c", "GPU 5", .gpu, [6]),
        ("Tg1d", "GPU 6", .gpu, [6]),
        ("Tg07", "GPU 7", .gpu, [6]),
        ("Tg1f", "GPU 8", .gpu, [6]),
        ("Tg09", "GPU 9", .gpu, [6]),
        ("Tg0a", "GPU 10", .gpu, [6]),
        ("Tg1g", "GPU 11", .gpu, [6]),
        ("Tg1h", "GPU 12", .gpu, [6]),
        ("TH0x", "NAND", .ssd, [1, 2, 3, 4, 5, 6]),
        ("TB1T", "Battery 1", .battery, [1, 2, 3, 4, 5, 6]),
        ("TB2T", "Battery 2", .battery, [1, 2, 3, 4, 5, 6]),
        ("TW0P", "Airport", .wifi, [1, 2, 3, 4, 5, 6]),
    ]

    /// 0 for Intel, else the M-series generation from "Apple M5 Pro" etc.
    static func generation(cpuName: String) -> Int {
        guard let range = cpuName.range(of: #"Apple M(\d+)"#, options: .regularExpression) else { return 0 }
        return Int(cpuName[range].dropFirst("Apple M".count)) ?? 0
    }
}

/// Reads the SMC. Keys are listed once; afterwards only the useful ones
/// are read (one IOKit call each).
final class SMCReader {
    private struct KeyDataVer { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    /// Padded to the C struct's 12 bytes.
    private struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var attributes: UInt8 = 0, p1: UInt8 = 0, p2: UInt8 = 0, p3: UInt8 = 0 }
    /// SMCKeyData_t (80 bytes).
    private struct KeyData {
        var key: UInt32 = 0
        var vers = KeyDataVer()
        var pLimit = PLimit()
        var info = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var connection: io_connect_t = 0
    private var keys: [(name: String, code: UInt32, info: KeyInfo)] = []

    /// Power / voltage / current keys Sysbar shows (Apple Silicon names).
    private static let extraKeys = ["PSTR", "PDTR", "PPBR", "VD0R", "VP0R", "ID0R"]

    private let generation: Int

    init?(cpuName: String) {
        generation = SensorTable.generation(cpuName: cpuName)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        discover()
        if keys.isEmpty { close(); return nil }
    }

    deinit { close() }

    private func close() {
        if connection != 0 { IOServiceClose(connection); connection = 0 }
    }

    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func name(_ v: UInt32) -> String {
        String(bytes: [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)], encoding: .ascii) ?? ""
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private func info(_ code: UInt32) -> KeyInfo? {
        var input = KeyData(); input.key = code; input.command = 9
        return call(&input)?.info
    }

    private func value(_ code: UInt32, _ info: KeyInfo) -> Double? {
        var input = KeyData(); input.key = code; input.info.dataSize = info.dataSize; input.command = 5
        guard let out = call(&input) else { return nil }
        let b = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(min(32, info.dataSize)))) }
        switch Self.name(info.dataType) {
        case "flt ":
            guard b.count == 4 else { return nil }
            return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "sp78":
            guard b.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "fpe2":
            guard b.count == 2 else { return nil }
            return Double(UInt16(b[0]) << 6 | UInt16(b[1]) >> 2)
        default:
            return nil
        }
    }

    /// The table's keys for this chip, plus power / voltage / current,
    /// that this Mac's SMC actually has.
    private func discover() {
        var names = SensorTable.entries.filter { $0.generations.contains(generation) }.map(\.key)
        names += Self.extraKeys
        for name in names where !keys.contains(where: { $0.name == name }) {
            let code = Self.code(name)
            guard let info = info(code), ["flt ", "sp78", "fpe2"].contains(Self.name(info.dataType)) else { continue }
            keys.append((name, code, info))
        }
    }

    func read() -> SensorsSnapshot {
        var s = SensorsSnapshot()
        for key in keys {
            guard let v = value(key.code, key.info), v.isFinite else { continue }
            switch key.name {
            case "PSTR": s.systemPower = v
            case "PDTR": s.dcInPower = v
            case "PPBR": s.batteryPower = v
            case "VD0R": s.dcInVoltage = v
            case "VP0R": s.rail12V = v
            case "ID0R": s.dcInCurrent = v
            default:
                // Unused sensors read 0; drop implausible values too.
                guard v > 5, v < 130,
                      let entry = SensorTable.entries.first(where: { $0.key == key.name && $0.generations.contains(generation) })
                else { continue }
                s.temperatures.append(SensorReading(key: key.name, name: entry.name, group: entry.group, value: v))
            }
        }
        return s
    }
}

// MARK: - Views

private func celsius(_ v: Double?) -> String { v.map { String(format: "%.1f °C", $0) } ?? "–" }
private func watts(_ v: Double?) -> String { v.map { String(format: "%.2f W", $0) } ?? "–" }

/// Color for a temperature: green below 60 °C, orange to 80, red above.
func temperatureColor(_ v: Double?) -> Color {
    guard let v else { return .secondary }
    return v < 60 ? Color(nsColor: .systemGreen) : v < 80 ? Color(nsColor: .systemOrange) : Color(nsColor: .systemRed)
}

/// Dashboard section.
struct SensorsStatsPanel: View {
    let snapshot: SystemStatsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatsPanelHeader(title: tr("Sensors", "Sensores"))
            if let s = snapshot.sensors {
                ForEach([SensorReading.Group.cpu, .gpu], id: \.self) { g in
                    if let hot = s.hottest(g) {
                        UsageBarRow(label: g.title + tr(" (hottest)", " (mais quente)"), value: celsius(hot),
                                    fraction: hot / 100, color: temperatureColor(hot))
                    }
                }
                ForEach([SensorReading.Group.ssd, .battery, .wifi], id: \.self) { g in
                    if let avg = s.average(g) { StatsValueRow(label: g.title, value: celsius(avg)) }
                }
                if let p = s.systemPower {
                    StatsValueRow(label: tr("System power", "Potência do sistema"), value: String(format: "%.1f W", p))
                }
                StatsPanelCaption(text: tr("CPU (green→red) temperature", "Temperatura da CPU"),
                                  window: StatsFormat.window(sampleCount: snapshot.cpuTemperatureHistory.count,
                                                             interval: Settings.interval))
                MetricSparkline(values: snapshot.cpuTemperatureHistory, color: temperatureColor(s.hottest(.cpu)),
                                height: 26, domain: 20...100)
            } else {
                StatsValueRow(label: tr("Sensors unavailable", "Sensores indisponíveis"), value: "–")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: panelWidth)
    }
}

/// Details panel.
struct SensorsDetail: View {
    let model: AppModel

    private func row(_ name: String, _ value: Double?, bold: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(name.replacingOccurrences(of: "performance", with: "perf."))
                .font(.system(size: 11, weight: bold ? .semibold : .regular))
                .foregroundStyle(bold ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(value.map { String(format: "%.1f°", $0) } ?? "–")
                .font(.system(size: 11, weight: bold ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(temperatureColor(value)).textLayer()
        }
        .help(name)
    }

    var body: some View {
        let snap = model.snapshot
        if let s = snap.sensors {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: tr("Temperature history (hottest)", "Histórico de temperatura (mais quente)"))
                HistoryChart(series: [.init(values: snap.cpuTemperatureHistory, color: Color(nsColor: .systemOrange)),
                                      .init(values: snap.gpuTemperatureHistory, color: Color(nsColor: .systemGreen))],
                             maxValue: 100, label: { "\(Int($0.rounded()))°" })
                HStack(spacing: 12) {
                    LegendDot(color: Color(nsColor: .systemOrange), label: "CPU")
                    LegendDot(color: Color(nsColor: .systemGreen), label: "GPU")
                }

                SectionTitle(text: tr("Temperature", "Temperatura"))
                // Like Stats: every sensor (two columns, so the panel stays
                // short), then average / hottest CPU and GPU.
                let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible())]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                    ForEach([SensorReading.Group.wifi, .ssd, .battery, .cpu, .gpu], id: \.self) { g in
                        ForEach(s.readings(g), id: \.key) { r in row(r.name, r.value) }
                    }
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                    ForEach([SensorReading.Group.cpu, .gpu], id: \.self) { g in
                        row(tr("Average ", "Média ") + g.title, s.average(g), bold: true)
                        row(tr("Hottest ", "Mais quente ") + g.title, s.hottest(g), bold: true)
                    }
                }
                .padding(.top, 2)

                SectionTitle(text: tr("Power", "Potência"))
                InfoRow(label: tr("System total", "Total do sistema"), value: watts(s.systemPower))
                InfoRow(label: "DC In", value: watts(s.dcInPower))
                InfoRow(label: tr("Battery", "Bateria"), value: watts(s.batteryPower))
                SectionTitle(text: tr("Voltage · current", "Tensão · corrente"))
                InfoRow(label: "DC In", value: s.dcInVoltage.map { String(format: "%.2f V", $0) } ?? "–")
                InfoRow(label: tr("12 V rail", "Trilho 12 V"), value: s.rail12V.map { String(format: "%.2f V", $0) } ?? "–")
                InfoRow(label: tr("DC In current", "Corrente DC In"), value: s.dcInCurrent.map { String(format: "%.2f A", $0) } ?? "–")

            }
        } else {
            Text(tr("This Mac's sensors can't be read.", "Os sensores deste Mac não podem ser lidos."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
