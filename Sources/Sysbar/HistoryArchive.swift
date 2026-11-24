// Keeps the last 24 hours of every chart series, whatever span the charts
// show, so a longer span chosen later starts already filled — and saves it
// to disk, so it survives a restart of Sysbar.
//
// Two tiers per series: 1-second averages for the last hour and 1-minute
// averages for the last 24 hours (about 5,000 points per series, 8 bytes
// each). Anything older is dropped: on load, on every save and as points
// are added. Time with no samples (Sysbar closed, the Mac asleep) comes
// back as gaps (NaN), which the charts leave empty.

import Foundation

@MainActor
final class HistoryArchive {
    private struct Point {
        /// Seconds since `base` (Float keeps a point at 8 bytes).
        var t: Float
        var v: Float
    }

    private struct Tier {
        let step: TimeInterval
        let span: TimeInterval
        var points: [Point] = []
        var sum: Double = 0
        var count = 0
        var bucket: Int = .min

        init(step: TimeInterval, span: TimeInterval) {
            self.step = step
            self.span = span
        }

        mutating func add(_ value: Double, at t: TimeInterval) {
            let b = Int((t / step).rounded(.down))
            if b != bucket, count > 0 { flush(now: t) }
            bucket = b
            sum += value
            count += 1
        }

        /// Closes the current bucket into a point (at the bucket's end).
        mutating func flush(now: TimeInterval) {
            guard count > 0 else { return }
            points.append(Point(t: Float(Double(bucket + 1) * step), v: Float(sum / Double(count))))
            sum = 0
            count = 0
            prune(now: now)
        }

        /// Drops everything older than the tier's span.
        mutating func prune(now: TimeInterval) {
            let cutoff = Float(now - span)
            guard let first = points.first, first.t < cutoff else { return }
            let keep = points.firstIndex { $0.t >= cutoff } ?? points.count
            points.removeFirst(keep)
        }

        /// Points so far, plus the open bucket's average.
        func all() -> [Point] {
            count > 0 ? points + [Point(t: Float(Double(bucket + 1) * step), v: Float(sum / Double(count)))] : points
        }
    }

    static let fineSpan: TimeInterval = 3600
    static let coarseSpan: TimeInterval = 24 * 3600
    private static let saveEvery: TimeInterval = 300

    /// Wall-clock origin of the point times.
    private var base = Date().timeIntervalSince1970
    private var series: [String: (fine: Tier, coarse: Tier)] = [:]
    private var lastSave = Date().timeIntervalSince1970

    private var now: TimeInterval { Date().timeIntervalSince1970 - base }

    private static func newSeries() -> (fine: Tier, coarse: Tier) {
        (Tier(step: 1, span: fineSpan), Tier(step: 60, span: coarseSpan))
    }

    /// Saved to / loaded from disk (the app; not previews or screenshots).
    private let persistent: Bool

    init(persistent: Bool) {
        self.persistent = persistent
        if persistent { load() }
    }

    func record(_ key: String, _ value: Double) {
        guard value.isFinite else { return }
        let t = now
        if series[key] == nil { series[key] = Self.newSeries() }
        // Mutated in place: copying a tier out would copy its whole array.
        series[key]!.fine.add(value, at: t)
        series[key]!.coarse.add(value, at: t)
        if persistent, Date().timeIntervalSince1970 - lastSave >= Self.saveEvery { save() }
    }

    /// Number of per-index series recorded under `prefix` ("core0", "core1"…).
    func indexedCount(_ prefix: String) -> Int {
        var n = 0
        while series["\(prefix)\(n)"] != nil { n += 1 }
        return n
    }

    /// The series over the last `window` seconds as up to `points` averages,
    /// oldest first, starting at its first sample in the window. Time with
    /// no samples is NaN (a gap); buckets finer than the stored resolution
    /// repeat the previous value.
    func history(_ key: String, window: TimeInterval, points: Int) -> [Double] {
        guard let s = series[key], points > 0 else { return [] }
        let fine = window <= Self.fineSpan
        let source = fine ? s.fine.all() : s.coarse.all()
        let sourceStep = fine ? s.fine.step : s.coarse.step
        let end = now
        let from = end - window
        let step = window / Double(points)
        var sums = [Double](repeating: 0, count: points)
        var counts = [Int](repeating: 0, count: points)
        var lastTime = [Double](repeating: -.infinity, count: points)
        for p in source where Double(p.t) > from {
            let i = min(points - 1, max(0, Int((Double(p.t) - from) / step)))
            sums[i] += Double(p.v)
            counts[i] += 1
            lastTime[i] = Double(p.t)
        }
        guard let first = counts.firstIndex(where: { $0 > 0 }) else { return [] }
        // A run of empty buckets is a gap when no sample came for longer
        // than a few source steps (more than the normal spacing).
        let gapLimit = max(sourceStep * 3, step * 1.5)
        var out: [Double] = []
        out.reserveCapacity(points - first)
        var previous = sums[first] / Double(counts[first])
        var previousTime = lastTime[first]
        for i in first..<points {
            if counts[i] > 0 {
                previous = sums[i] / Double(counts[i])
                previousTime = lastTime[i]
                out.append(previous)
            } else {
                let bucketEnd = from + step * Double(i + 1)
                out.append(bucketEnd - previousTime > gapLimit ? .nan : previous)
            }
        }
        // Trailing NaN (no sample yet in the newest bucket) is just "now".
        while let last = out.last, last.isNaN { out.removeLast() }
        return out
    }

    // MARK: Disk

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sysbar/chart-history.bin")
    }

    private static let magic: UInt32 = 0x5342_4831  // "SBH1"

    /// Writes the pruned archive (nothing older than 24 h) atomically.
    func save() {
        lastSave = Date().timeIntervalSince1970
        guard persistent, let url = Self.fileURL else { return }
        let t = now
        var data = Data()
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        put(Self.magic)
        put(base)
        put(UInt32(series.count))
        for key in series.keys.sorted() {
            series[key]!.fine.prune(now: t)
            series[key]!.coarse.prune(now: t)
            let s = series[key]!
            let name = Data(key.utf8)
            put(UInt16(name.count))
            data.append(name)
            for tier in [s.fine, s.coarse] {
                put(UInt32(tier.points.count))
                tier.points.withUnsafeBytes { data.append(contentsOf: $0) }
            }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Loads the saved archive, re-based on the current time; points older
    /// than each tier's span are dropped. A damaged file is ignored.
    private func load() {
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url) else { return }
        var offset = 0
        func get<T>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
        guard get(UInt32.self) == Self.magic, let savedBase = get(Double.self),
              let count = get(UInt32.self) else { return }
        let shift = Float(savedBase - base)  // saved time + shift = time since our base
        var loaded: [String: (fine: Tier, coarse: Tier)] = [:]
        for _ in 0..<count {
            guard let nameLength = get(UInt16.self), offset + Int(nameLength) <= data.count else { return }
            let key = String(decoding: data[offset..<offset + Int(nameLength)], as: UTF8.self)
            offset += Int(nameLength)
            var s = Self.newSeries()
            for tierIndex in 0..<2 {
                guard let n = get(UInt32.self) else { return }
                let bytes = Int(n) * MemoryLayout<Point>.stride
                guard offset + bytes <= data.count else { return }
                var points = [Point](repeating: Point(t: 0, v: 0), count: Int(n))
                _ = points.withUnsafeMutableBytes { data.copyBytes(to: $0, from: offset..<offset + bytes) }
                offset += bytes
                points = points.map { Point(t: $0.t + shift, v: $0.v) }.filter { $0.v.isFinite }
                if tierIndex == 0 { s.fine.points = points } else { s.coarse.points = points }
            }
            s.fine.prune(now: 0)
            s.coarse.prune(now: 0)
            if !s.fine.points.isEmpty || !s.coarse.points.isEmpty { loaded[key] = s }
        }
        series = loaded
    }
}
