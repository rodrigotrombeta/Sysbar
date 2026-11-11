// Top processes by memory (physical footprint, the "Memory" column of
// Activity Monitor) and by CPU, via libproc. Without root, processes owned by
// other users (e.g. WindowServer) can't be read and are skipped. Only runs
// while a panel that shows processes is visible.

import AppKit
import Darwin

struct ProcessRow: Identifiable, Sendable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let memoryBytes: UInt64
    /// Fraction of one core (1.0 = 100%, like Activity Monitor).
    let cpu: Double
}

struct ProcessSnapshot: Sendable {
    var topMemory: [ProcessRow] = []
    var topCPU: [ProcessRow] = []
}

@MainActor
final class ProcessSampler {
    private var previousTimes: [pid_t: UInt64] = [:]
    private var previousSample: TimeInterval?
    private var names: [pid_t: String] = [:]
    private let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func sample(limit: Int = 15) -> ProcessSnapshot {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return ProcessSnapshot() }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return ProcessSnapshot() }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsedNs = previousSample.map { (now - $0) * 1e9 } ?? 0
        var times: [pid_t: UInt64] = [:]
        var rows: [(pid: pid_t, memory: UInt64, cpu: Double)] = []
        rows.reserveCapacity(Int(got))

        for pid in pids.prefix(Int(got)) where pid > 0 {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else { continue }
            let cpuTime = info.ri_user_time &+ info.ri_system_time
            times[pid] = cpuTime
            var cpu = 0.0
            if elapsedNs > 0, let prev = previousTimes[pid], cpuTime >= prev {
                cpu = Double(cpuTime - prev) * timebase / elapsedNs
            }
            rows.append((pid, info.ri_phys_footprint, cpu))
        }
        previousTimes = times
        previousSample = now
        names = names.filter { times[$0.key] != nil }

        var snapshot = ProcessSnapshot()
        snapshot.topMemory = rows.sorted { $0.memory > $1.memory }.prefix(limit).map {
            ProcessRow(pid: $0.pid, name: name(for: $0.pid), memoryBytes: $0.memory, cpu: $0.cpu)
        }
        snapshot.topCPU = rows.sorted { $0.cpu > $1.cpu }.prefix(limit).map {
            ProcessRow(pid: $0.pid, name: name(for: $0.pid), memoryBytes: $0.memory, cpu: $0.cpu)
        }
        return snapshot
    }

    private func name(for pid: pid_t) -> String {
        if let cached = names[pid] { return cached }
        var resolved: String
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            resolved = name
        } else {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                resolved = (String(cString: buffer) as NSString).lastPathComponent
            } else {
                var short = [CChar](repeating: 0, count: 64)
                proc_name(pid, &short, UInt32(short.count))
                resolved = String(cString: short)
            }
        }
        if resolved.isEmpty { resolved = "pid \(pid)" }
        names[pid] = resolved
        return resolved
    }
}
