// Claude Code limits: main panel section, detail panel and the chart.
//
// The chart puts both windows on one time axis, "% of the window elapsed"
// (start → reset), so the 5-hour and the weekly window can be compared: the
// solid line is the usage so far, the dashed one continues at the current
// pace to the reset. The gray diagonal is an even pace (100 % exactly at the
// reset): above it you're using faster than that. A projection crossing the
// red 100 % line means you'd hit the limit before the reset.

import SwiftUI

let claudeFiveColor = Color(nsColor: .systemOrange)
let claudeWeekColor = Color(nsColor: .systemPurple)

private func riskColor(_ risk: Int) -> Color {
    switch risk {
    case 2: return Color(nsColor: .systemRed)
    case 1: return Color(nsColor: .systemOrange)
    default: return Color(nsColor: .systemGreen)
    }
}

private func shortTime(_ date: Date) -> String {
    let sameDay = Calendar.current.isDateInToday(date)
    return date.formatted(sameDay ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute())
}

private func duration(_ seconds: TimeInterval) -> String {
    let m = Int(max(0, seconds) / 60)
    if m < 60 { return "\(m) min" }
    if m < 48 * 60 { return "\(m / 60)h \(m % 60)m" }
    return "\(m / 1440)d \((m % 1440) / 60)h"
}

/// One sentence: will this window hit its limit at the current pace?
func claudeVerdict(_ w: ClaudeWindow, now: Date = Date()) -> String {
    if w.percent >= 100 {
        return tr("Limit reached · resets \(shortTime(w.resetsAt))",
                  "Limite atingido · renova \(shortTime(w.resetsAt))")
    }
    guard let p = w.projection(now: now) else {
        return tr("Not used yet in this window", "Ainda sem uso nesta janela")
    }
    if let hit = p.hitsLimitAt {
        return tr("At this pace: limit at \(shortTime(hit)), \(duration(w.resetsAt.timeIntervalSince(hit))) before reset",
                  "Neste ritmo: limite às \(shortTime(hit)), \(duration(w.resetsAt.timeIntervalSince(hit))) antes de renovar")
    }
    return tr("At this pace: ~\(Int(p.atReset.rounded()))% at reset (\(shortTime(w.resetsAt)))",
              "Neste ritmo: ~\(Int(p.atReset.rounded()))% ao renovar (\(shortTime(w.resetsAt)))")
}

// MARK: - Chart

struct ClaudeLimitChart: View {
    let usage: ClaudeUsage
    var height: CGFloat = 90
    var showLegend = true

    var body: some View {
        let now = Date()
        let windows: [(ClaudeWindow, Color)] = [
            usage.sevenDay.map { ($0, claudeWeekColor) },
            usage.fiveHour.map { ($0, claudeFiveColor) },
        ].compactMap { $0 }
        let top = max(100, windows.compactMap { $0.0.projection(now: now)?.atReset }.max().map { min($0, 160) } ?? 100)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                GeometryReader { geo in
                    ForEach([100.0, 50.0, 0.0], id: \.self) { level in
                        Text("\(Int(level))%")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .frame(width: geo.size.width, alignment: .trailing)
                            .position(x: geo.size.width / 2, y: geo.size.height * (1 - level / top))
                    }
                }
                .frame(width: 30)

                GeometryReader { geo in
                    ClaudePlot(windows: windows, top: top, now: now, size: geo.size)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }
            .frame(height: height)
            .graphicsLayer()

            HStack {
                Text(tr("window start", "início da janela"))
                Spacer()
                Text(tr("reset →", "renovação →"))
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            .padding(.leading, 36)

            if showLegend {
                HStack(spacing: 10) {
                    LegendDot(color: claudeFiveColor, label: tr("5-hour", "5 horas"))
                    LegendDot(color: claudeWeekColor, label: tr("Weekly", "Semanal"))
                    Text(tr("- - at this pace", "- - neste ritmo")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The plot area of `ClaudeLimitChart`.
private struct ClaudePlot: View {
    let windows: [(ClaudeWindow, Color)]
    let top: Double
    let now: Date
    let size: CGSize

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: size.width * x, y: size.height * (1 - min(y, top) / top))
    }

    var body: some View {
        ZStack {
            // Even pace: 0 % at the start, 100 % at the reset.
            Path { p in p.move(to: point(0, 0)); p.addLine(to: point(1, 100)) }
                .stroke(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            // The limit.
            Path { p in p.move(to: point(0, 100)); p.addLine(to: point(1, 100)) }
                .stroke(Color(nsColor: .systemRed).opacity(0.8), lineWidth: 1)
            ForEach(windows.indices, id: \.self) { i in
                series(windows[i].0, color: windows[i].1)
            }
        }
    }

    @ViewBuilder
    private func series(_ w: ClaudeWindow, color: Color) -> some View {
        let pts = linePoints(w, now: now)
        // Usage so far.
        Path { p in
            guard let first = pts.first else { return }
            p.move(to: point(first.0, first.1))
            for q in pts.dropFirst() { p.addLine(to: point(q.0, q.1)) }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        // Projection at the current pace to the reset.
        if let proj = w.projection(now: now), let last = pts.last, last.0 < 1 {
            Path { p in
                p.move(to: point(last.0, last.1))
                p.addLine(to: point(1, proj.atReset))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            if let hit = proj.hitsLimitAt, w.percent < 100 {
                Circle().fill(Color(nsColor: .systemRed))
                    .frame(width: 7, height: 7)
                    .position(point(min(1, max(0, hit.timeIntervalSince(w.start) / w.duration)), 100))
            }
        }
        // Now.
        if let last = pts.last {
            Circle().fill(color).frame(width: 6, height: 6).position(point(last.0, last.1))
        }
    }

    /// (elapsed fraction, percent) points from the window start to now.
    private func linePoints(_ w: ClaudeWindow, now: Date) -> [(Double, Double)] {
        var pts: [(Double, Double)] = [(0, 0)]
        for h in w.history { pts.append((w.elapsedFraction(at: h.date), h.percent)) }
        pts.append((w.elapsedFraction(at: now), w.percent))
        return pts.sorted { $0.0 < $1.0 }
    }
}

// MARK: - Rows

private struct ClaudeWindowRow: View {
    let title: String
    let window: ClaudeWindow?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle().fill(color).frame(width: 7, height: 7).graphicsLayer()
                Text(title).font(.system(size: 12))
                Spacer()
                Text(window.map { "\(Int($0.percent.rounded()))%" } ?? "–")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            if let window {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule().fill(color)
                            .frame(width: max(3, geo.size.width * min(1, window.percent / 100)))
                        // Where an even pace would be now.
                        Rectangle().fill(Color.primary.opacity(0.5))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width * window.elapsedFraction() - 0.75)
                    }
                }
                .frame(height: 6)
                .graphicsLayer()
                Text(claudeVerdict(window))
                    .font(.system(size: 10.5))
                    .foregroundStyle(riskColor(window.risk()))
                    .textLayer()
            }
        }
    }
}

// MARK: - Main panel section

struct ClaudeStatsPanel: View {
    let model: AppModel
    private var usage: ClaudeUsage? { model.snapshot.claude }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("CLAUDE")
                    .font(.system(size: StatsTheme.caption, weight: .bold))
                    .kerning(1)
                    .foregroundStyle(Color(nsColor: .systemBlue))
                Image(systemName: "flask")
                    .font(.system(size: StatsTheme.caption))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .help(ClaudeBetaNote.text)
            }
            .textLayer()
            .frame(maxWidth: .infinity, alignment: .center)
            if let usage {
                ClaudeWindowRow(title: tr("5-hour limit", "Limite de 5 horas"), window: usage.fiveHour, color: claudeFiveColor)
                ClaudeWindowRow(title: tr("Weekly limit", "Limite semanal"), window: usage.sevenDay, color: claudeWeekColor)
                ClaudeLimitChart(usage: usage, height: 70, showLegend: false)
                ClaudeUpdatedRow(model: model, usage: usage)
            } else {
                ClaudeNotConnected()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: panelWidth)
    }
}

/// Shown until the first reading arrives.
/// The limits come from an undocumented Anthropic endpoint.
struct ClaudeBetaNote: View {
    static var text: String {
        tr("Beta: Anthropic's usage address is undocumented and may change.",
           "Em testes: o endereço de uso da Anthropic não é documentado e pode mudar.")
    }

    var body: some View {
        Label(Self.text, systemImage: "flask")
            .font(.system(size: 10))
            .foregroundStyle(Color(nsColor: .systemOrange))
            .textLayer()
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ClaudeNotConnected: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Settings.claudeFetch
                 ? tr("Waiting for the first answer from Anthropic… (status in Settings ⚙︎)",
                      "Aguardando a primeira resposta da Anthropic… (status em Configurações ⚙︎)")
                 : ClaudeUsageStore.isConnected()
                 ? tr("Waiting for Claude Code's status line (terminal only). Turn on \"Fetch limits from Anthropic\" in Settings (⚙︎) for automatic updates.",
                      "Aguardando a linha de status do Claude Code (só no terminal). Ligue \"Buscar limites na Anthropic\" em Configurações (⚙︎) para atualizar sozinho.")
                 : tr("Turn on \"Fetch limits from Anthropic\" in Settings (⚙︎).",
                      "Ligue \"Buscar limites na Anthropic\" em Configurações (⚙︎)."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Detail panel

struct ClaudeDetail: View {
    let model: AppModel

    var body: some View {
        let usage = model.snapshot.claude
        VStack(alignment: .leading, spacing: 8) {
            if let usage {
                ClaudeWindowRow(title: tr("5-hour limit", "Limite de 5 horas"), window: usage.fiveHour, color: claudeFiveColor)
                ClaudeWindowRow(title: tr("Weekly limit", "Limite semanal"), window: usage.sevenDay, color: claudeWeekColor)
                SectionTitle(text: tr("Usage vs. time in each window", "Uso vs. tempo em cada janela"))
                ClaudeLimitChart(usage: usage, height: 150)
                Text(tr("Solid: used so far. Dashed: where the current pace leads at the reset. Gray diagonal: an even pace (100 % right at the reset). A red dot marks when you'd hit the limit.",
                        "Linha cheia: uso até agora. Tracejada: aonde o ritmo atual leva até a renovação. Diagonal cinza: ritmo uniforme (100 % exatamente na renovação). O ponto vermelho marca quando você atingiria o limite."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ClaudeUpdatedRow(model: model, usage: usage)
            } else {
                ClaudeNotConnected()
            }
        }
    }
}

/// "Last reading 3 min ago" and a refresh button. Readings come from Claude
/// Code (each time it updates its status line); refresh re-reads them and
/// recomputes the pace now.
private struct ClaudeUpdatedRow: View {
    let model: AppModel
    let usage: ClaudeUsage

    var body: some View {
        HStack(spacing: 6) {
            Text(tr("Last reading \(usage.updatedAt.formatted(.relative(presentation: .named)))",
                    "Última leitura \(usage.updatedAt.formatted(.relative(presentation: .named)))"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Button { model.refreshClaude() } label: {
                Label(tr("Refresh", "Atualizar"), systemImage: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help(tr("Re-read Claude Code's latest reading and recompute the pace. New readings arrive when Claude Code updates its status line (while you use it).",
                     "Relê a última leitura do Claude Code e recalcula o ritmo. Leituras novas chegam quando o Claude Code atualiza a linha de status (enquanto você o usa)."))
        }
    }
}
