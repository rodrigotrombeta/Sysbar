// Clock: a month calendar and one clock per time zone in the dashboard, and
// the first two time zones in the menu bar ("24/11 13:19" over "24/11 09:19").

import AppKit
import SwiftUI

enum WorldClock {
    /// Time zones to show (identifiers), in order; the first two go to the
    /// menu bar. Defaults to this Mac's zone.
    static var zones: [TimeZone] {
        let ids = Settings.clockZones
        let zones = ids.compactMap(TimeZone.init(identifier:))
        return zones.isEmpty ? [TimeZone.current] : zones
    }

    /// "24/11 13:19" (or "24/11 1:19 PM") in `zone`.
    static func shortDateTime(_ date: Date, in zone: TimeZone) -> String {
        format(date, zone, "dd/MM " + timePattern)
    }

    /// "24/11".
    static func date(_ date: Date, in zone: TimeZone) -> String { format(date, zone, "dd/MM") }
    /// "13:19" or "1:19 PM".
    static func time(_ date: Date, in zone: TimeZone) -> String { format(date, zone, timePattern) }

    private static var timePattern: String { Settings.clock24h ? "HH:mm" : "h:mm a" }

    private static func format(_ date: Date, _ zone: TimeZone, _ pattern: String) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }

    static func weekday(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.locale = Locale(identifier: Settings.language == .portuguese ? "pt_BR" : "en_US")
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    /// "GMT+1", "GMT-3", "GMT+5:30".
    static func offset(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let h = abs(seconds) / 3600, m = (abs(seconds) % 3600) / 60
        return seconds == 0 ? "GMT" : "GMT\(sign)\(h)" + (m > 0 ? String(format: ":%02d", m) : "")
    }

    /// City name from the identifier ("America/Sao_Paulo" → "Sao Paulo").
    static func city(_ zone: TimeZone) -> String {
        (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier)
            .replacingOccurrences(of: "_", with: " ")
    }

    /// Flag of the zone's country, when known.
    static func flag(_ zone: TimeZone) -> String {
        guard let code = countryCodes[zone.identifier] else { return "🌐" }
        return code.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
            .map(String.init).joined()
    }

    /// Common zones; the picker also offers every other identifier.
    static let countryCodes: [String: String] = [
        "Europe/Amsterdam": "NL", "Europe/Brussels": "BE", "Europe/Paris": "FR", "Europe/Berlin": "DE",
        "Europe/Madrid": "ES", "Europe/Lisbon": "PT", "Europe/London": "GB", "Europe/Dublin": "IE",
        "Europe/Rome": "IT", "Europe/Zurich": "CH", "Europe/Vienna": "AT", "Europe/Stockholm": "SE",
        "Europe/Oslo": "NO", "Europe/Copenhagen": "DK", "Europe/Helsinki": "FI", "Europe/Warsaw": "PL",
        "Europe/Prague": "CZ", "Europe/Athens": "GR", "Europe/Istanbul": "TR", "Europe/Kyiv": "UA",
        "Europe/Moscow": "RU", "Europe/Luxembourg": "LU", "Europe/Munich": "DE",
        "America/Sao_Paulo": "BR", "America/Recife": "BR", "America/Fortaleza": "BR", "America/Manaus": "BR",
        "America/Bahia": "BR", "America/Belem": "BR", "America/Cuiaba": "BR", "America/Porto_Velho": "BR",
        "America/New_York": "US", "America/Chicago": "US", "America/Denver": "US", "America/Los_Angeles": "US",
        "America/Phoenix": "US", "America/Anchorage": "US", "Pacific/Honolulu": "US",
        "America/Toronto": "CA", "America/Vancouver": "CA", "America/Mexico_City": "MX",
        "America/Buenos_Aires": "AR", "America/Argentina/Buenos_Aires": "AR", "America/Santiago": "CL",
        "America/Bogota": "CO", "America/Lima": "PE", "America/Montevideo": "UY", "America/Caracas": "VE",
        "Asia/Tokyo": "JP", "Asia/Seoul": "KR", "Asia/Shanghai": "CN", "Asia/Hong_Kong": "HK",
        "Asia/Singapore": "SG", "Asia/Kolkata": "IN", "Asia/Calcutta": "IN", "Asia/Dubai": "AE",
        "Asia/Bangkok": "TH", "Asia/Jakarta": "ID", "Asia/Manila": "PH", "Asia/Taipei": "TW",
        "Asia/Jerusalem": "IL", "Asia/Riyadh": "SA", "Australia/Sydney": "AU", "Australia/Melbourne": "AU",
        "Australia/Perth": "AU", "Pacific/Auckland": "NZ", "Africa/Johannesburg": "ZA", "Africa/Cairo": "EG",
        "Africa/Lagos": "NG", "Africa/Nairobi": "KE", "Atlantic/Azores": "PT", "Atlantic/Reykjavik": "IS",
    ]
}

// MARK: - Dashboard section

struct ClockStatsPanel: View {
    let model: AppModel
    /// Off in the detail panel, which has its own title.
    var inDetail = false

    var body: some View {
        // Re-rendered every tick (the snapshot changes), so the clocks move.
        let now = model.snapshot.uptimeSeconds >= 0 ? Date() : Date()
        VStack(alignment: .leading, spacing: 8) {
            if !inDetail {
                Text(tr("CLOCK", "RELÓGIO"))
                    .font(.system(size: StatsTheme.caption, weight: .bold))
                    .kerning(1)
                    .foregroundStyle(Color(nsColor: .systemBlue))
                    .textLayer()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            ForEach(WorldClock.zones, id: \.identifier) { zone in
                ClockRow(zone: zone, now: now)
            }
        }
        .padding(.horizontal, inDetail ? 0 : 14)
        .padding(.vertical, inDetail ? 0 : 8)
        .frame(width: inDetail ? nil : panelWidth)
    }
}

struct CalendarStatsPanel: View {
    let model: AppModel
    var inDetail = false
    @State private var monthOffset = 0

    var body: some View {
        let now = model.snapshot.uptimeSeconds >= 0 ? Date() : Date()
        VStack(alignment: .leading, spacing: 8) {
            if !inDetail {
                Text(tr("CALENDAR", "CALENDÁRIO"))
                    .font(.system(size: StatsTheme.caption, weight: .bold))
                    .kerning(1)
                    .foregroundStyle(Color(nsColor: .systemBlue))
                    .textLayer()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            MonthCalendar(now: now, monthOffset: $monthOffset)
        }
        .padding(.horizontal, inDetail ? 0 : 14)
        .padding(.vertical, inDetail ? 0 : 8)
        .frame(width: inDetail ? nil : panelWidth)
    }
}

private struct MonthCalendar: View {
    let now: Date
    @Binding var monthOffset: Int

    var body: some View {
        let calendar = Calendar.current
        let month = calendar.date(byAdding: .month, value: monthOffset,
                                  to: calendar.date(from: calendar.dateComponents([.year, .month], from: now))!)!
        let days = gridDays(month, calendar: calendar)
        VStack(spacing: 6) {
            HStack {
                Text(monthTitle(month)).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { monthOffset -= 1 } label: { Image(systemName: "arrow.left") }
                Button { monthOffset += 1 } label: { Image(systemName: "arrow.right") }
                if monthOffset != 0 {
                    Button { monthOffset = 0 } label: { Image(systemName: "smallcircle.filled.circle") }
                        .help(tr("Today", "Hoje"))
                }
            }
            .buttonStyle(.borderless)
            Grid(horizontalSpacing: 0, verticalSpacing: 4) {
                GridRow {
                    ForEach(weekdaySymbols(calendar), id: \.self) { d in
                        Text(d).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<6, id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { col in
                            dayCell(days[row * 7 + col], month: month, calendar: calendar)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func dayCell(_ day: Date, month: Date, calendar: Calendar) -> some View {
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let today = calendar.isDate(day, inSameDayAs: now)
        return Text("\(calendar.component(.day, from: day))")
            .font(.system(size: 11, weight: today ? .bold : .regular).monospacedDigit())
            .foregroundStyle(today ? AnyShapeStyle(Color.white) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: 22, height: 22)
            .background(Circle().fill(today ? Color(nsColor: .systemRed) : .clear))
            .frame(maxWidth: .infinity)
    }

    private func gridDays(_ month: Date, calendar: Calendar) -> [Date] {
        let weekday = calendar.component(.weekday, from: month)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -lead, to: month)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    private func weekdaySymbols(_ calendar: Calendar) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: Settings.language == .portuguese ? "pt_BR" : "en_US")
        let symbols = f.shortWeekdaySymbols ?? []
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first]).map { $0.replacingOccurrences(of: ".", with: "") }
    }

    private func monthTitle(_ month: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: Settings.language == .portuguese ? "pt_BR" : "en_US")
        f.dateFormat = "LLLL yyyy"
        return f.string(from: month).capitalized
    }
}

private struct ClockRow: View {
    let zone: TimeZone
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            AnalogClock(date: now, zone: zone).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(WorldClock.flag(zone)) \(WorldClock.city(zone))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text(WorldClock.shortDateTime(now, in: zone))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(WorldClock.offset(zone, at: now)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text(WorldClock.weekday(now, in: zone)).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

/// Hour, minute and (red) second hands.
private struct AnalogClock: View {
    let date: Date
    let zone: TimeZone

    var body: some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let s = Double(c.second ?? 0), m = Double(c.minute ?? 0) + s / 60, h = Double((c.hour ?? 0) % 12) + m / 60
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.35), lineWidth: 1)
            hand(angle: h / 12, length: 0.5, width: 2, color: .primary)
            hand(angle: m / 60, length: 0.75, width: 1.5, color: .primary)
            hand(angle: s / 60, length: 0.82, width: 0.8, color: Color(nsColor: .systemRed))
            Circle().fill(Color.primary).frame(width: 3, height: 3)
        }
        .graphicsLayer()
    }

    private func hand(angle: Double, length: CGFloat, width: CGFloat, color: Color) -> some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            Path { p in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let a = angle * 2 * .pi - .pi / 2
                p.move(to: center)
                p.addLine(to: CGPoint(x: center.x + cos(a) * r * length, y: center.y + sin(a) * r * length))
            }
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }
}

// MARK: - Settings

/// Add, remove and reorder the time zones.
struct ClockZonesEditor: View {
    let model: AppModel
    @State private var adding = TimeZone.current.identifier

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("Clocks (the first two go to the menu bar)", "Relógios (os dois primeiros vão para a barra de menus)"))
                .font(.system(size: 12))
            let zones = WorldClock.zones
            ForEach(Array(zones.enumerated()), id: \.element.identifier) { index, zone in
                HStack(spacing: 6) {
                    Text("\(WorldClock.flag(zone)) \(WorldClock.city(zone))").font(.system(size: 11.5))
                    Text(WorldClock.offset(zone, at: Date())).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.moveClock(zone.identifier, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                    Button { model.moveClock(zone.identifier, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == zones.count - 1)
                    Button { model.removeClock(zone.identifier) } label: { Image(systemName: "minus.circle") }
                        .disabled(zones.count == 1)
                }
                .buttonStyle(.borderless)
                .padding(.leading, 8)
            }
            HStack(spacing: 6) {
                Text(tr("Time format", "Formato da hora")).font(.system(size: 11.5))
                Picker("", selection: model.clock24h) {
                    Text("24h").tag(true)
                    Text("12h").tag(false)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            .padding(.leading, 8)
            HStack(spacing: 6) {
                Picker("", selection: $adding) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers.sorted(), id: \.self) { id in
                        Text(id.replacingOccurrences(of: "_", with: " ")).tag(id)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                Button(tr("Add", "Adicionar")) { model.addClock(adding) }
                    .controlSize(.small)
                    .disabled(WorldClock.zones.contains { $0.identifier == adding })
            }
            .padding(.leading, 8)
        }
    }
}
