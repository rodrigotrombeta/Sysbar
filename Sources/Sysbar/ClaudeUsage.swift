// Claude Code usage limits (5-hour and weekly), as Claude Code itself reports
// them: its statusline command receives `rate_limits.five_hour` and
// `rate_limits.seven_day` ({used_percentage 0-100, resets_at epoch}) on stdin.
// Same source as github.com/Maciek-roboblog/Claude-Code-Usage-Monitor.
//
// "Connect to Claude Code" points Claude Code's statusLine at
// `Sysbar --claude-statusline`, which appends each reading to a small history
// file and then runs the user's previous statusline command (saved aside), so
// the status line looks the same. "Disconnect" puts the previous one back.
// Readings only arrive while Claude Code is in use.

import Foundation

struct ClaudeWindow: Sendable, Equatable {
    /// 0...100, as Claude Code reports it.
    var percent: Double
    var resetsAt: Date
    var duration: TimeInterval
    /// Readings in this window (oldest first): time and percent.
    var history: [ClaudePoint] = []

    var start: Date { resetsAt.addingTimeInterval(-duration) }

    /// 0...1 of the window elapsed at `date`.
    func elapsedFraction(at date: Date = Date()) -> Double {
        min(1, max(0, date.timeIntervalSince(start) / duration))
    }

    /// Projection at the current average pace since the window began.
    struct Projection: Equatable {
        /// Percent expected when the window resets.
        var atReset: Double
        /// When 100 % is reached, if before the reset.
        var hitsLimitAt: Date?
    }

    func projection(now: Date = Date()) -> Projection? {
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 60, percent > 0 else { return percent > 0 ? nil : Projection(atReset: 0) }
        let rate = percent / elapsed  // percent per second
        let atReset = rate * duration
        var hit: Date?
        if percent >= 100 {
            hit = history.first { $0.percent >= 100 }?.date ?? now
        } else if atReset > 100 {
            hit = start.addingTimeInterval(100 / rate)
        }
        return Projection(atReset: atReset, hitsLimitAt: hit)
    }

    /// 0 = fine, 1 = close (>= 85 % projected), 2 = projected to hit the limit.
    func risk(now: Date = Date()) -> Int {
        guard let p = projection(now: now) else { return 0 }
        if p.hitsLimitAt != nil { return 2 }
        return p.atReset >= 85 ? 1 : 0
    }
}

struct ClaudePoint: Sendable, Equatable {
    var date: Date
    var percent: Double
}

struct ClaudeUsage: Sendable, Equatable {
    var fiveHour: ClaudeWindow?
    var sevenDay: ClaudeWindow?
    /// Time of the last reading from Claude Code.
    var updatedAt: Date
}

enum ClaudeUsageStore {
    static let fiveHours: TimeInterval = 5 * 3600
    static let sevenDays: TimeInterval = 7 * 86400

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sysbar", isDirectory: true)
    }
    static var historyFile: URL { directory.appendingPathComponent("claude-usage.jsonl") }
    /// The statusLine setting Claude Code had before Sysbar connected.
    static var previousStatusLineFile: URL { directory.appendingPathComponent("claude-statusline-previous.json") }
    static var claudeSettings: URL {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent("settings.json")
    }

    // MARK: Reading (Sysbar)

    private static var cache: (modified: Date, usage: ClaudeUsage?)?

    /// Re-reads the history file now (the refresh button).
    static func reload() -> ClaudeUsage? {
        cache = nil
        return load()
    }

    /// Current usage from the history file (re-read only when it changes).
    static func load() -> ClaudeUsage? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: historyFile.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        if let cache, cache.modified == modified { return cache.usage }
        let usage = parse((try? String(contentsOf: historyFile, encoding: .utf8)) ?? "")
        cache = (modified, usage)
        return usage
    }

    static func parse(_ text: String) -> ClaudeUsage? {
        var five: [(Date, Double, Date)] = []
        var seven: [(Date, Double, Date)] = []
        var last: Date?
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = obj["t"] as? Double else { continue }
            let date = Date(timeIntervalSince1970: t)
            last = date
            if let w = obj["five"] as? [String: Double], let p = w["p"], let r = w["r"] {
                five.append((date, p, Date(timeIntervalSince1970: r)))
            }
            if let w = obj["seven"] as? [String: Double], let p = w["p"], let r = w["r"] {
                seven.append((date, p, Date(timeIntervalSince1970: r)))
            }
        }
        guard let last else { return nil }
        return ClaudeUsage(fiveHour: window(five, duration: fiveHours),
                           sevenDay: window(seven, duration: sevenDays),
                           updatedAt: last)
    }

    /// The latest window; once it has reset, a new empty one.
    private static func window(_ readings: [(Date, Double, Date)], duration: TimeInterval) -> ClaudeWindow? {
        guard let latest = readings.last else { return nil }
        let now = Date()
        var resetsAt = latest.2
        if resetsAt <= now {
            // Window over: usage restarted at 0 (Claude Code reports the new
            // window on its next update).
            while resetsAt <= now { resetsAt.addTimeInterval(duration) }
            return ClaudeWindow(percent: 0, resetsAt: resetsAt, duration: duration)
        }
        let start = resetsAt.addingTimeInterval(-duration)
        let points = readings
            .filter { $0.0 >= start && abs($0.2.timeIntervalSince(resetsAt)) < 120 }
            .map { ClaudePoint(date: $0.0, percent: $0.1) }
        return ClaudeWindow(percent: latest.1, resetsAt: resetsAt, duration: duration, history: points)
    }

    // MARK: Capturing (`Sysbar --claude-statusline`, run by Claude Code)

    /// Records the reading, then runs the previous statusline command with the
    /// same input and passes its output through.
    static func runStatusLine() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        record(input)
        if let command = previousCommand() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            if (try? process.run()) != nil {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
                process.waitUntilExit()
                exit(process.terminationStatus)
            }
        }
        exit(0)
    }

    static func record(_ input: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let limits = obj["rate_limits"] as? [String: Any] else { return }
        var entry: [String: Any] = ["t": Date().timeIntervalSince1970]
        for (key, name) in [("five_hour", "five"), ("seven_day", "seven")] {
            guard let w = limits[key] as? [String: Any],
                  let p = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let r = (w["resets_at"] as? NSNumber)?.doubleValue,
                  p >= 0, p <= 1000, r > 1_000_000_000 else { continue }  // skips the known bad reading
            entry[name] = ["p": p, "r": r]
        }
        append(entry)
    }

    /// Appends one reading ({"t", "five"?, "seven"?}) to the history file.
    static func append(_ entry: [String: Any]) {
        guard entry.count > 1, var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: historyFile) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: historyFile)
        }
        trimIfLarge()
    }

    /// Keeps the last 8 days once the file passes ~1 MB.
    private static func trimIfLarge() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: historyFile.path))?[.size] as? Int,
              size > 1_000_000, let text = try? String(contentsOf: historyFile, encoding: .utf8) else { return }
        let cutoff = Date().addingTimeInterval(-8 * 86400).timeIntervalSince1970
        let kept = text.split(separator: "\n").filter { line in
            guard let range = line.range(of: "\"t\":") else { return false }
            let number = line[range.upperBound...].prefix { "0123456789.".contains($0) }
            return (Double(number) ?? 0) >= cutoff
        }
        try? (kept.joined(separator: "\n") + "\n").write(to: historyFile, atomically: true, encoding: .utf8)
    }

    // MARK: Connecting to Claude Code

    static var statusLineCommand: String {
        "'\(executablePath)' --claude-statusline"
    }

    /// The running app (an older copy elsewhere wouldn't know the flag and
    /// would start a second Sysbar instead).
    private static var executablePath: String {
        Bundle.main.executablePath ?? "/Applications/Sysbar.app/Contents/MacOS/Sysbar"
    }

    /// At launch: if connected through a Sysbar that's gone or older (e.g.
    /// after moving or updating the app), point Claude Code at this one.
    static func refreshConnection() {
        guard isConnected(), var settings = readSettings(),
              var line = settings["statusLine"] as? [String: Any],
              (line["command"] as? String) != statusLineCommand else { return }
        line["command"] = statusLineCommand
        settings["statusLine"] = line
        try? writeSettings(settings)
    }

    static func isConnected() -> Bool {
        guard let settings = readSettings(),
              let line = settings["statusLine"] as? [String: Any],
              let command = line["command"] as? String else { return false }
        return command.contains("--claude-statusline")
    }

    /// Saves the current statusLine aside and points it at Sysbar.
    static func connect() throws {
        var settings = readSettings() ?? [:]
        if let current = settings["statusLine"], !isConnected() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let saved = try JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted])
            try saved.write(to: previousStatusLineFile)
        }
        var line: [String: Any] = ["type": "command", "command": statusLineCommand]
        if let previous = previousStatusLine(), let padding = previous["padding"] { line["padding"] = padding }
        settings["statusLine"] = line
        try writeSettings(settings)
    }

    /// Restores the statusLine Claude Code had before (or removes it).
    static func disconnect() throws {
        var settings = readSettings() ?? [:]
        settings["statusLine"] = previousStatusLine()
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: previousStatusLineFile)
    }

    private static func previousStatusLine() -> [String: Any]? {
        guard let data = try? Data(contentsOf: previousStatusLineFile) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func previousCommand() -> String? {
        guard let line = previousStatusLine(), (line["type"] as? String) == "command",
              let command = line["command"] as? String, !command.contains("--claude-statusline") else { return nil }
        return command
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeSettings) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        // Keep a copy of the file as it was, once.
        let backup = claudeSettings.appendingPathExtension("sysbar-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: claudeSettings, to: backup)
        }
        try data.write(to: claudeSettings, options: .atomic)
    }
}
